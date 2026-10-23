extends SceneTree

## Drives the real main scene with synthetic mouse input to verify the
## Hearthstone-style drag targeting end to end.
##
## Requires a running server:
##   godot --path apps/godot-client --script src/drag_test.gd
##
## Needs a real (non-headless) run: hit-testing depends on laid-out rects.

const TestSession := preload("res://src/test_session.gd")

var main: Control
var failures: Array[String] = []

func _init() -> void:
	await process_frame
	# A fresh account every run: a restored session would rename the player
	# partway through startup.
	SessionStore.clear()
	main = (load("res://main.tscn") as PackedScene).instantiate()
	get_root().add_child(main)
	await process_frame
	await process_frame

	# A match is entered with one of the player's own ready decks.
	var deck_id: String = await TestSession.sign_in_with_ready_deck(self, main)
	if deck_id == "":
		_check("signed in with a ready deck", false)
		_finish()
		return
	main._show_match_view()
	main.start_match_with_deck("BANDIT_AMBUSH", deck_id)
	for i in range(300):
		await process_frame
		if not main.state.is_empty() and not main.legal_actions.is_empty():
			break

	# Play forward until a creature summon is available.
	var played := false
	for attempt in range(14):
		var card_zone := await _find_zone("drag_card")
		var has_slot_play := false
		if not card_zone.is_empty():
			var cid: String = str(card_zone.get("id", ""))
			var acts := Targeting.actions_for_card(main.legal_actions, cid)
			has_slot_play = not Targeting.slot_targets(acts, main.player_id).is_empty()
		if has_slot_play:
			played = await _drag_card_to_slot(card_zone)
			if played:
				break
		if not main.end_turn_button.disabled:
			main.end_turn_button.emit_signal("pressed")
		for i in range(80):
			await process_frame

	# Whether a summonable card is ever in hand with Taika to spare depends on
	# the draw, so a run without one is reported rather than failed.
	if played:
		_check("dragged a card onto a battlefield slot", true)
	else:
		print("  [--] no card summon became available this run; skipped")

	# Now look for an attack: drag one of our creatures onto a lit target.
	var attacked := false
	for attempt in range(30):
		var ent := await _find_zone("drag_entity")
		if not ent.is_empty():
			var eid: String = str(ent.get("id", ""))
			var acts := Targeting.actions_for_entity(main.legal_actions, eid)
			var targets := Targeting.entity_targets(acts)
			if not targets.is_empty():
				attacked = await _drag_entity_to_target(ent, targets)
				if attacked:
					break
		# Keep summoning so creatures actually reach our board.
		var card_zone := await _find_zone("drag_card")
		var summoned := false
		if not card_zone.is_empty():
			var cid2: String = str(card_zone.get("id", ""))
			var acts2 := Targeting.actions_for_card(main.legal_actions, cid2)
			if not Targeting.slot_targets(acts2, main.player_id).is_empty():
				summoned = await _click_card_to_slot(card_zone)
		if not summoned and not main.end_turn_button.disabled:
			main.end_turn_button.emit_signal("pressed")
		for i in range(80):
			await process_frame
	# Whether an attack ever becomes available depends on how the AI plays, so
	# a run without one is reported rather than failed.
	if attacked:
		_check("dragged a creature onto a target entity", true)
	else:
		print("  [--] no attack became available this run; skipped")

	# Hero targeting: find an action aimed at a hero and drag onto the strip.
	var hero_key := ""
	var hero_source: Dictionary = {}
	for attempt in range(20):
		await process_frame
		await process_frame
		main._rebuild_drop_zones()
		for key in main._drop_zones:
			var zone: Dictionary = main._drop_zones[key]
			var kind := str(zone.get("kind", ""))
			var acts: Array = []
			if kind == "drag_entity":
				acts = Targeting.actions_for_entity(main.legal_actions, str(zone.get("id", "")))
			elif kind == "drag_card":
				acts = Targeting.actions_for_card(main.legal_actions, str(zone.get("id", "")))
			else:
				continue
			for t in Targeting.entity_targets(acts):
				if Targeting.is_hero_entity(str(t)):
					hero_key = str(t)
					hero_source = zone
					break
			if hero_key != "":
				break
		if hero_key != "":
			break
		if not main.end_turn_button.disabled:
			main.end_turn_button.emit_signal("pressed")
		for i in range(80):
			await process_frame

	if hero_key == "":
		print("  [--] no hero-targeting action became available this run; skipped")
	if hero_key != "":
		# The board scrolls, and only what is in view can be aimed at: bring
		# the hero into view, as a player would.
		var hero_strip := _control_for(main.board_container, hero_key)
		if hero_strip != null:
			main.board_area.ensure_control_visible(hero_strip)
		await process_frame
		await process_frame
		main._rebuild_drop_zones()
		var refreshed_source := str(hero_source.get("kind", "")) + ":" + str(hero_source.get("id", ""))
		for k in main._drop_zones:
			var z: Dictionary = main._drop_zones[k]
			if str(z.get("kind", "")) + ":" + str(z.get("id", "")) == refreshed_source:
				hero_source = z
				break
		_check("the hero strip is a registered drop zone", main._drop_zones.has(hero_key))
		if main._drop_zones.has(hero_key):
			# Let the board lay out before reading rects: an unlaid-out control
			# reports a zero-origin rect, which no pointer position can match.
			await process_frame
			await process_frame
			main._rebuild_drop_zones()
			var hfrom: Vector2 = (hero_source["rect"] as Rect2).get_center()
			var hto: Vector2 = (main._drop_zones[hero_key]["rect"] as Rect2).get_center()
			# Begin the drag from the known source rather than a hit-test: which
			# overlapping hand card a raw press lands on is not what this check
			# is about, and picking the wrong one makes the result meaningless.
			main._press_origin = hfrom
			main._begin_drag(str(hero_source.get("id", "")),
				str(hero_source.get("kind", "")) == "drag_card")
			_check("the hero is offered as a target", main.entity_targets.has(hero_key))
			# A targeting card fires its arrow once it leaves the hand.
			main._on_pointer_move(hto)
			_check("arrow visible while aiming at a hero", main.arrow.visible)
			_check("hero highlights as a valid target", main._hovered_key == hero_key)
			main._on_pointer_up(hto)
			for i in range(120):
				await process_frame
			_check("selection cleared after committing",
				main.selected_card == "" and main.selected_entity == "")

	_finish()

func _finish() -> void:
	print("\n%d failure(s)" % failures.size())
	for f in failures:
		print("  FAIL: ", f)
	print("RESULT: ", "PASS" if failures.is_empty() else "FAIL")
	quit(0 if failures.is_empty() else 1)

func _find_zone(kind: String) -> Dictionary:
	# Rects are only valid after the containers have laid out.
	await process_frame
	await process_frame
	main._rebuild_drop_zones()
	for key in main._drop_zones:
		var zone: Dictionary = main._drop_zones[key]
		if str(zone.get("kind", "")) == kind:
			return zone
	return {}

func _drag_card_to_slot(card_zone: Dictionary) -> bool:
	var cid: String = str(card_zone.get("id", ""))
	var acts := Targeting.actions_for_card(main.legal_actions, cid)
	var slots := Targeting.slot_targets(acts, main.player_id)
	if slots.is_empty():
		return false
	var slot_key: String = slots.keys()[0]
	if not main._drop_zones.has(slot_key):
		print("[probe] slot key not in drop zones: ", slot_key)
		return false
	var from: Vector2 = (card_zone["rect"] as Rect2).get_center()
	var to: Vector2 = (main._drop_zones[slot_key]["rect"] as Rect2).get_center()
	print("[probe] dragging card ", cid, " to ", slot_key)

	# Start from the known source: which overlapping control a raw press lands
	# on is not what this check is about, and getting a different card makes
	# the rest of the assertions meaningless.
	main._press_origin = from
	main._begin_drag(cid, true)
	_check("the card itself is held during the drag", main.hand_view.held_id() == cid)
	_check("drag registered a selection", main.selected_card == cid)
	# Let go anywhere over the battlefield, a card lands on the nearest lit
	# slot. The row labels sit left of every slot and are never a slot.
	var board_rect: Rect2 = main.board_area.get_global_rect()
	var off_slot := Vector2(board_rect.position.x + 6.0, to.y)
	_check("over the battlefield but off a slot, the nearest lit slot is chosen",
		slots.has(main._card_drop_key(off_slot)))
	main._on_pointer_move(to)
	_check("hovering a valid slot is recorded", main._hovered_key == slot_key)
	main._on_pointer_up(to)
	_check("the played card leaves the hand", main.hand_view.is_spent(cid))
	_check("the played card breaks up", main.play_effect.is_busy())
	_check("its oval falls toward the slot", main.play_effect.is_flying(slot_key))
	_check("arrow hidden after release", not main.arrow.visible)
	for i in range(120):
		await process_frame
	var token: CreatureToken = main._token_in_slot(main.board_container, slot_key)
	_check("the creature's token shows once its oval is down",
		token != null and is_equal_approx(token.modulate.a, 1.0))
	return true

## Plays a card the click way: one click picks it up, and it follows the
## pointer with no button held until a second click puts it down.
func _click_card_to_slot(card_zone: Dictionary) -> bool:
	var cid: String = str(card_zone.get("id", ""))
	var acts := Targeting.actions_for_card(main.legal_actions, cid)
	var slots := Targeting.slot_targets(acts, main.player_id)
	if slots.is_empty():
		return false
	var slot_key: String = slots.keys()[0]
	var from: Vector2 = (card_zone["rect"] as Rect2).get_center()
	# In a crowded hand the next card may cover this one's centre.
	if not main._drop_zones.has(slot_key) or main.hand_view.card_at(from) != cid:
		return await _drag_card_to_slot(card_zone)
	var to: Vector2 = (main._drop_zones[slot_key]["rect"] as Rect2).get_center()
	print("[probe] clicking card ", cid, " onto ", slot_key)
	main._on_pointer_down(from)
	main._on_pointer_up(from)
	_check("a clicked card is held without the button",
		main.hand_view.held_id() == cid and main._sticky)
	main._input(_motion(to))
	_check("a clicked card follows the pointer to a lit slot", main._hovered_key == slot_key)
	main._input(_button(to, true))
	main._input(_button(to, false))
	_check("a second click plays the card",
		main.hand_view.is_spent(cid) and main.hand_view.held_id() == "")
	_check("the second click's release is not taken as another",
		not main._swallow_release and not main._dragging)
	for i in range(120):
		await process_frame
	return true

func _motion(at: Vector2) -> InputEventMouseMotion:
	var event := InputEventMouseMotion.new()
	event.position = at
	event.global_position = at
	return event

func _button(at: Vector2, pressed: bool) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = at
	event.global_position = at
	return event

func _drag_entity_to_target(ent: Dictionary, targets: Dictionary) -> bool:
	var eid: String = str(ent.get("id", ""))
	var target_key: String = targets.keys()[0]
	if not main._drop_zones.has(target_key):
		print("[probe] target not in drop zones: ", target_key)
		return false
	var from: Vector2 = (ent["rect"] as Rect2).get_center()
	var to: Vector2 = (main._drop_zones[target_key]["rect"] as Rect2).get_center()
	print("[probe] dragging creature ", eid, " onto ", target_key)
	main._press_origin = from
	main._begin_drag(eid, false)
	_check("arrow visible during creature drag", main.arrow.visible)
	main._on_pointer_move(to)
	_check("valid entity target highlighted", main._hovered_key == target_key)
	main._on_pointer_up(to)
	for i in range(120):
		await process_frame
	return true

## The board control registered as the drop target `key`, or null.
func _control_for(node: Node, key: String) -> Control:
	for child in node.get_children():
		if child is Control and str((child as Control).get_meta("target_id", "")) == key:
			return child
		var found := _control_for(child, key)
		if found != null:
			return found
	return null

func _check(label: String, condition: bool) -> void:
	print("  [%s] %s" % ["ok" if condition else "XX", label])
	if not condition:
		failures.append(label)
