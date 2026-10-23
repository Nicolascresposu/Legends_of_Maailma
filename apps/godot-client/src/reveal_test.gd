extends SceneTree

## Drives the real main scene to verify the hover reveal on cards in play.
##
## Requires a running server:
##   godot --path apps/godot-client --script src/reveal_test.gd
##
## Needs a real (non-headless) run: hover hit-testing depends on laid-out rects.

const TestSession := preload("res://src/test_session.gd")

var main: Control
var failures: Array[String] = []

func _init() -> void:
	await process_frame
	# Start without a saved session: restoring one would rename the player
	# partway through startup, and the board only renders for a player the
	# match knows about.
	SessionStore.clear()
	main = (load("res://main.tscn") as PackedScene).instantiate()
	get_root().add_child(main)
	await process_frame
	await process_frame

	# A match is entered with one of the player's own ready decks.
	var deck_id: String = await TestSession.sign_in_with_ready_deck(self, main)
	_check("signed in with a ready deck", deck_id != "")
	main._show_match_view()
	main.start_match_with_deck("BANDIT_AMBUSH", deck_id)
	for i in range(600):
		await process_frame
		if not main.state.is_empty() and not main.legal_actions.is_empty():
			break

	_check("a match is running", not main.state.is_empty())
	_check("the card library loaded", main.library.is_loaded())

	# The board starts empty, so play forward until something is in play to
	# hover — whichever side summoned it, since the reveal is not ours alone.
	var zone := await _find_reveal_zone()
	for attempt in range(14):
		if not zone.is_empty():
			break
		await _summon_or_pass()
		zone = await _find_reveal_zone()
	if zone.is_empty():
		print("  [--] no card reached play this run; skipped")
		_report()
		return

	var key: String = str(zone.get("id", ""))
	var rect: Rect2 = zone["rect"]
	var at := rect.get_center()

	# On the board a creature is only its art oval; the whole card is what the
	# reveal is for.
	var creature_zone: Dictionary = {}
	for candidate_key in main._drop_zones:
		var candidate: Dictionary = main._drop_zones[candidate_key]
		if str(candidate.get("kind", "")) == "reveal" and CardFrame.supports(
				main.library, str((candidate["card"] as Dictionary).get("definition_id", ""))):
			creature_zone = candidate
			break
	if creature_zone.is_empty():
		print("  [--] no creature in play this run; token check skipped")
	else:
		var drawn_as_token := false
		var drawn_as_card := false
		for child in (creature_zone["control"] as Control).get_children():
			drawn_as_token = drawn_as_token or child is CreatureToken
			drawn_as_card = drawn_as_card or child is CardFrame
		_check("a creature in play is drawn as its oval, not its card",
			drawn_as_token and not drawn_as_card)

	# Pointing at a card does not reveal it at once: the dwell is what stops a
	# pointer crossing the board from flashing every card it passes.
	main._on_hover_move(at)
	_check("hovering does not reveal immediately", not main.reveal.is_revealing())

	await _wait(CardReveal.DELAY + 0.2)
	main._on_hover_move(at)
	_check("the card reveals after the dwell", main.reveal.is_revealing())
	_check("the reveal is visible", main.reveal.visible)

	# The reveal must show the hovered card, and show it in full: the rules
	# text is the thing a small board panel cannot fit.
	var definition_id := str((zone["card"] as Dictionary).get("definition_id", ""))
	# A creature is revealed as its card: the name is on its ribbon, and the
	# description in its text box, or beneath it when too long for the box.
	var framed: bool = main.reveal._card.visible
	_check("a creature is revealed as its card",
		framed == CardFrame.supports(main.library, definition_id))
	var shown_name: String = main.reveal._card._name.text if framed else main.reveal._title.text
	_check("the reveal names the hovered card", shown_name == main.library.card_name(definition_id))
	var rules_label: RichTextLabel = main.reveal._rules
	if framed and not main.reveal._rules.visible:
		rules_label = main.reveal._card._text
	var plain: String = main.library.description_plain(definition_id)
	_check("every card has a description", plain.strip_edges() != "")
	_check("the reveal shows the card's description",
		rules_label.is_visible_in_tree() and rules_label.get_parsed_text().contains(plain))
	# The markup must reach the label as formatting, not as literal asterisks.
	_check("the description's markup is rendered, not printed",
		not rules_label.get_parsed_text().contains("*"))
	# Flavour is shown, but in its own place: never mixed into the rules.
	var story: String = main.library.flavour_plain(definition_id)
	if story == "":
		_check("a card without flavour shows none", not main.reveal._flavour.visible)
	else:
		_check("the reveal shows the card's flavour on its own line",
			main.reveal._flavour.visible
				and main.reveal._flavour.get_parsed_text().contains(story)
				and not main.reveal._rules.get_parsed_text().contains(story))

	# Keywords are the reason the reveal beats the board panel, which shows the
	# bare names: each one must be spelled out.
	var keyword_list: Array = main.library.keywords(definition_id)
	if keyword_list.is_empty():
		_check("a card with no keywords shows no keyword line",
			not main.reveal._keywords.visible)
	else:
		_check("the description prints its keywords in bold",
			rules_label.text.contains("[b]"))
		var explained := true
		for keyword in keyword_list:
			var line: String = CardLibrary.keyword_line(str(keyword))
			if line == str(keyword) or not main.reveal._keywords.text.contains(line):
				explained = false
		_check("each keyword is explained, not just named", explained)

	# It sits beside the card, not over it — the point is comparing the two.
	var panel_rect := Rect2(main.reveal._panel.global_position, main.reveal._panel.size)
	_check("the reveal does not cover the card it describes",
		not panel_rect.intersects(rect))
	var view := main.get_viewport_rect().size
	_check("the reveal stays on screen",
		panel_rect.position.x >= 0.0 and panel_rect.position.y >= 0.0
			and panel_rect.end.x <= view.x and panel_rect.end.y <= view.y)

	# Moving off the board takes it down again.
	main._on_hover_move(Vector2(view.x - 2.0, 2.0))
	_check("leaving the card hides the reveal", not main.reveal.is_revealing())

	# A drag must never be obstructed by the reveal, so bring it back up first.
	main._on_hover_move(at)
	await _wait(CardReveal.DELAY + 0.2)
	main._on_hover_move(at)
	if main.reveal.is_revealing():
		var card_zone := await _find_zone("drag_card")
		if card_zone.is_empty():
			print("  [--] nothing draggable this run; drag check skipped")
		else:
			main._press_origin = (card_zone["rect"] as Rect2).get_center()
			main._begin_drag(str(card_zone.get("id", "")), true)
			_check("starting a drag hides the reveal", not main.reveal.is_revealing())
			main._cancel_drag()
	else:
		print("  [--] reveal did not come back up; drag check skipped")

	_report()

## Summons a creature if one can be summoned, otherwise ends the turn, so the
## board fills up over a few attempts whichever way the draw goes.
func _summon_or_pass() -> void:
	var card_zone := await _find_zone("drag_card")
	if not card_zone.is_empty():
		var cid: String = str(card_zone.get("id", ""))
		var acts := Targeting.actions_for_card(main.legal_actions, cid)
		var slots := Targeting.slot_targets(acts, main.player_id)
		if not slots.is_empty():
			var slot_key: String = slots.keys()[0]
			if main._drop_zones.has(slot_key):
				var to: Vector2 = (main._drop_zones[slot_key]["rect"] as Rect2).get_center()
				main._press_origin = (card_zone["rect"] as Rect2).get_center()
				main._begin_drag(cid, true)
				main._on_pointer_move(to)
				main._on_pointer_up(to)
				for i in range(120):
					await process_frame
				return
	if not main.end_turn_button.disabled:
		main.end_turn_button.emit_signal("pressed")
	for i in range(80):
		await process_frame

func _wait(seconds: float) -> void:
	var waited := 0.0
	while waited < seconds:
		await process_frame
		waited += get_root().get_process_delta_time()

func _find_reveal_zone() -> Dictionary:
	# Rects are only valid after the containers have laid out.
	await process_frame
	await process_frame
	main._rebuild_drop_zones()
	for key in main._drop_zones:
		var zone: Dictionary = main._drop_zones[key]
		if str(zone.get("kind", "")) == "reveal":
			return zone
	return {}

func _find_zone(kind: String) -> Dictionary:
	await process_frame
	await process_frame
	main._rebuild_drop_zones()
	for key in main._drop_zones:
		var zone: Dictionary = main._drop_zones[key]
		if str(zone.get("kind", "")) == kind:
			return zone
	return {}

func _check(label: String, condition: bool) -> void:
	print("  [%s] %s" % ["ok" if condition else "XX", label])
	if not condition:
		failures.append(label)

func _report() -> void:
	print("\n%d failure(s)" % failures.size())
	for f in failures:
		print("  FAIL: ", f)
	print("RESULT: ", "PASS" if failures.is_empty() else "FAIL")
	quit(0 if failures.is_empty() else 1)
