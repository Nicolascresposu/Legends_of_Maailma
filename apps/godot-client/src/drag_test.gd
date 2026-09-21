extends SceneTree

## Drives the real main scene with synthetic mouse input to verify the
## Hearthstone-style drag targeting end to end.
##
## Requires a running server:
##   godot --path apps/godot-client --script src/drag_test.gd
##
## Needs a real (non-headless) run: hit-testing depends on laid-out rects.

var main: Control
var failures: Array[String] = []

func _init() -> void:
	await process_frame
	main = (load("res://main.tscn") as PackedScene).instantiate()
	get_root().add_child(main)
	await process_frame
	await process_frame

	main._create_match("BANDIT_AMBUSH")
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

	_check("dragged a card onto a battlefield slot", played)

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
				summoned = await _drag_card_to_slot(card_zone)
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

	_check("an action can target a hero", hero_key != "")
	if hero_key != "":
		_check("the hero strip is a registered drop zone", main._drop_zones.has(hero_key))
		if main._drop_zones.has(hero_key):
			var hfrom: Vector2 = (hero_source["rect"] as Rect2).get_center()
			var hto: Vector2 = (main._drop_zones[hero_key]["rect"] as Rect2).get_center()
			main._on_pointer_down(hfrom)
			main._on_pointer_move(hfrom + Vector2(0, -40))
			_check("arrow visible while aiming at a hero", main.arrow.visible)
			main._on_pointer_move(hto)
			_check("hero highlights as a valid target", main._hovered_key == hero_key)
			main._on_pointer_up(hto)
			for i in range(120):
				await process_frame
			_check("selection cleared after committing",
				main.selected_card == "" and main.selected_entity == "")

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

	main._on_pointer_down(from)
	main._on_pointer_move(from + Vector2(0, -30))
	_check("arrow became visible during card drag", main.arrow.visible)
	_check("drag registered a selection", main.selected_card == cid)
	main._on_pointer_move(to)
	_check("hovering a valid slot is recorded", main._hovered_key == slot_key)
	main._on_pointer_up(to)
	_check("arrow hidden after release", not main.arrow.visible)
	for i in range(120):
		await process_frame
	return true

func _drag_entity_to_target(ent: Dictionary, targets: Dictionary) -> bool:
	var eid: String = str(ent.get("id", ""))
	var target_key: String = targets.keys()[0]
	if not main._drop_zones.has(target_key):
		print("[probe] target not in drop zones: ", target_key)
		return false
	var from: Vector2 = (ent["rect"] as Rect2).get_center()
	var to: Vector2 = (main._drop_zones[target_key]["rect"] as Rect2).get_center()
	print("[probe] dragging creature ", eid, " onto ", target_key)
	main._on_pointer_down(from)
	main._on_pointer_move(from + Vector2(0, -30))
	_check("arrow visible during creature drag", main.arrow.visible)
	main._on_pointer_move(to)
	_check("valid entity target highlighted", main._hovered_key == target_key)
	main._on_pointer_up(to)
	for i in range(120):
		await process_frame
	return true

func _check(label: String, condition: bool) -> void:
	print("  [%s] %s" % ["ok" if condition else "XX", label])
	if not condition:
		failures.append(label)
