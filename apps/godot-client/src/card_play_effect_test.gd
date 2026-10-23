extends SceneTree

class Harness extends "res://src/main.gd":
	func _ready() -> void:
		pass

## Checks a played card breaking up and its oval falling into its slot,
## without a server.
##
##   godot --headless --path apps/godot-client --script src/card_play_effect_test.gd
## Run it windowed with `-- --screenshot-dir=<dir>` to save a filmstrip of it.

const WOLF := {
	"id": "wolf", "name": "Wolf", "type": "CREATURE", "cost": 2,
	"attack": 2, "health": 3, "tags": ["BEAST"], "keywords": ["SWIFT"],
	"description": "**Swift**",
}
const SPELL := {
	"id": "firebolt", "name": "Firebolt", "type": "ACTION", "cost": 1,
	"tags": [], "keywords": [], "description": "Deal 2 damage.",
}
const SLOT := Vector2(104, 138)
const STEP := 1.0 / 60.0

var failures: Array[String] = []
var library := CardLibrary.new()
var landings: Array[String] = []

func _init() -> void:
	await process_frame
	print("== card play effect test ==")
	seed(7)
	library.ingest([WOLF, SPELL])
	var effect := CardPlayEffect.new()
	get_root().add_child(effect)
	# Time is the test's to move, not the frame's.
	effect.set_process(false)
	effect.landed.connect(func(key: String) -> void: landings.append(key))

	# A creature dropped on a slot: the card breaks up around its oval.
	var held := await _held_card("wolf", Vector2(200, 520), 0.12)
	var landing := _landing(Vector2(200, 120))
	effect.play(_card("wolf"), held, landing, "slot-a")
	var burst: CardPlayEffect.Burst = effect._bursts[0]
	_check("the card breaks into many shards", burst.shards.size() > 40)
	_check("a creature's oval survives", burst.oval.has_area())
	var shard_area := 0.0
	for shard in burst.shards:
		shard_area += absf(CardPlayEffect._area(shard.points))
	var oval_area := PI * burst.oval.size.x * burst.oval.size.y / 4.0
	var card_area := burst.card_size.x * burst.card_size.y
	_check("the shards are the card around the oval, not the oval",
		absf(shard_area - (card_area - oval_area)) < card_area * 0.03)
	_check("the oval is on its way", effect.is_flying("slot-a") and not effect.is_waiting("slot-a"))
	_check("the effect takes no pointer input", effect.mouse_filter == Control.MOUSE_FILTER_IGNORE)

	_advance(effect, CardPlayEffect.HOLD + CardPlayEffect.FALL * 0.5)
	_check("it has not landed halfway down", landings.is_empty())
	var pose: Dictionary = effect._oval_pose(burst)
	_check("halfway down it is between the card and the slot",
		(pose["centre"] as Vector2).y < (burst.to_global * burst.oval.get_center()).y
			and (pose["centre"] as Vector2).y > landing.get_center().y - CardPlayEffect.LIFT_PIXELS)
	_advance(effect, CardPlayEffect.FALL * 0.5 + STEP)
	_check("it lands once, on its slot", landings == ["slot-a"])
	_check("landed, it waits for its token", not effect.is_flying("slot-a") and effect.is_waiting("slot-a"))
	_advance(effect, CardPlayEffect.BUMP + STEP)
	pose = effect._oval_pose(burst)
	_check("it comes to rest on the token's oval",
		(pose["centre"] as Vector2).distance_to(landing.get_center()) < 0.5
			and (pose["size"] as Vector2).distance_to(landing.size) < 0.5
			and absf(float(pose["turn"])) < 0.001)
	_check("every shard is gone by then", _shards_gone(burst))
	_check("unreleased, it stays", effect._oval_alpha(burst) == 1.0)
	effect.release("slot-a")
	_advance(effect, CardPlayEffect.FADE + CardPlayEffect.DUST_TIME + STEP)
	_check("released, it fades into the token and is gone", not effect.is_busy())

	# The token never arrives: it gives up when the hand would.
	held = await _held_card("wolf", Vector2(400, 520), 0.0)
	effect.play(_card("wolf"), held, _landing(Vector2(400, 120)), "slot-b")
	_advance(effect, CardPlayEffect.HOLD + CardPlayEffect.FALL + CardPlayEffect.WAIT_MAX
		+ CardPlayEffect.FADE + STEP * 2.0)
	_check("an oval nobody releases does not stay forever", not effect.is_busy())

	# A refused play: the oval fades where it is, mid-air.
	held = await _held_card("wolf", Vector2(600, 520), 0.0)
	effect.play(_card("wolf"), held, _landing(Vector2(600, 120)), "slot-c")
	_advance(effect, CardPlayEffect.HOLD + 0.1)
	effect.cancel_all()
	_advance(effect, CardPlayEffect.FADE + STEP)
	_check("a refused play's oval fades in flight", effect._oval_alpha(effect._bursts[0]) == 0.0)
	_advance(effect, 1.0)
	_check("and is gone", not effect.is_busy())

	# A spell crumbles entirely: nothing survives to fall anywhere.
	held = await _held_card("firebolt", Vector2(800, 520), 0.0)
	landings.clear()
	effect.play(_card("firebolt"), held)
	_check("a card that is not summoned leaves no oval", not effect._bursts[0].oval.has_area())
	_advance(effect, 0.6)
	_check("it crumbles away completely", not effect.is_busy() and landings.is_empty())
	await _guard_landing_test()

	var shots := _arg("--screenshot-dir=")
	if shots != "" and DisplayServer.get_name() != "headless":
		await _filmstrip(shots)

	print("%d failure(s)" % failures.size())
	for failure in failures:
		print("  FAIL: ", failure)
	print("RESULT: ", "PASS" if failures.is_empty() else "FAIL")
	quit(0 if failures.is_empty() else 1)

func _guard_landing_test() -> void:
	var main := Harness.new()
	get_root().add_child(main)
	main.client = MatchClient.new()
	main.accounts = AccountClient.new()
	main.add_child(main.client)
	main.add_child(main.accounts)
	var guard := WOLF.duplicate(true)
	guard["keywords"] = ["GUARD"]
	main.library.ingest([guard])
	main._build_interface()
	main.player_id = "one"
	main._on_match_state(_guard_state(true))
	await process_frame
	_check("an existing Guard is shown fully on reconnect", main._combat_token("g")._guard.modulate.a == 1.0
		and not main._combat_token("g")._guard.is_processing())
	var slot_key := Targeting.slot_key("one", "FRONT", 0)
	for late_state in [false, true]:
		main._on_match_state(_guard_state(false))
		var held := await _held_card("wolf", Vector2(200, 520), 0.0)
		main.play_effect.set_process(false)
		main.play_effect.play(_card("wolf"), held, _landing(Vector2(200, 120)), slot_key)
		if not late_state:
			main._on_match_state(_guard_state(true))
			await process_frame
			_check("a Guard arriving before contact waits for the oval", main._combat_token("g").modulate.a == 0.0
				and main._combat_token("g")._guard.modulate.a == 0.0)
		_advance(main.play_effect, CardPlayEffect.HOLD + CardPlayEffect.FALL + STEP)
		if late_state:
			main._on_match_state(_guard_state(true))
			await process_frame
		var token := main._combat_token("g")
		_check("the landed creature appears before its Guard shield (late=%s)" % late_state,
			token.modulate.a == 1.0 and token._guard.modulate.a == 0.0 and token._guard.is_processing())
		# Force the same rebuild legal actions use during the real animation.
		await create_timer(CreatureToken.GUARD_DELAY + CreatureToken.GUARD_EXPAND).timeout
		main._render_state()
		token = main._combat_token("g")
		_check("a board rebuild resumes the pop (late=%s)" % late_state,
			token._guard.scale.x > 1.05 and token._guard.modulate.a == 1.0)
		await create_timer(CreatureToken.GUARD_SETTLE + 0.03).timeout
		main._render_state()
		main._on_match_state(_guard_state(true))
		token = main._combat_token("g")
		_check("later updates do not replay the shield (late=%s)" % late_state,
			token._guard.scale == Vector2.ONE and token._guard.modulate.a == 1.0 and not token._guard.is_processing())
		_advance(main.play_effect, 1.0)
	main.queue_free()
	await process_frame

func _guard_state(occupied: bool) -> Dictionary:
	var creatures := {}
	if occupied:
		creatures["g"] = {"instanceId": "g", "definitionId": "wolf", "currentAttack": 2,
			"currentHealth": 3, "maxHealth": 3, "statuses": []}
	return {"playerOrder": ["one"], "activePlayerId": "one", "turn": 1, "sides": {
		"one": {"playerId": "one", "hero": {"currentHealth": 30, "maxHealth": 30},
			"creatures": creatures, "hand": [], "deck": [], "taika": {"current": 3, "maximum": 3},
			"battlefield": {"config": {"width": 1}, "slots": {"FRONT": ["g" if occupied else null], "BACK": [null]}}},
	}}

## The same drop at several moments side by side, from the card intact to the
## oval at rest in its slot.
func _filmstrip(shots: String) -> void:
	var moments := [0.0, 0.05, 0.10, 0.17, 0.25, 0.33, 0.40, 0.62]
	var effects: Array[CardPlayEffect] = []
	for index in moments.size():
		var x := 70.0 + index * 150.0
		var slot := ColorRect.new()
		slot.color = Color(0.16, 0.17, 0.21)
		slot.position = Vector2(x, 120) - SLOT * 0.5
		slot.size = SLOT
		get_root().add_child(slot)
		var effect := CardPlayEffect.new()
		get_root().add_child(effect)
		effect.set_process(false)
		var held := await _held_card("wolf", Vector2(x, 420), 0.15)
		effect.play(_card("wolf"), held, _landing(Vector2(x, 120)), "shot")
		effects.append(effect)
		held.visible = false
	for index in moments.size():
		_advance(effects[index], moments[index])
	await process_frame
	await RenderingServer.frame_post_draw
	var path := shots.path_join("card_play_effect.png")
	get_root().get_texture().get_image().save_png(path)
	print("  saved ", path)

## A hand card as the hand draws it, centred on `at`, turned by `turn`.
func _held_card(definition_id: String, at: Vector2, turn: float) -> Control:
	var panel := _card(definition_id)
	get_root().add_child(panel)
	await process_frame
	await process_frame
	panel.pivot_offset = panel.size * 0.5
	panel.position = at - panel.size * 0.5
	panel.rotation = turn
	panel.visible = false
	return panel

func _card(definition_id: String) -> PanelContainer:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.45, 0.85, 0.55)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(4)
	panel.add_theme_stylebox_override("panel", style)
	panel.custom_minimum_size = SLOT
	if CardFrame.supports(library, definition_id):
		panel.add_child(CardFrame.make(library, {"definition_id": definition_id}, 96.0))
	else:
		var label := Label.new()
		label.text = library.card_name(definition_id)
		panel.add_child(label)
	return panel

## The token's oval in a slot centred on `at`.
func _landing(at: Vector2) -> Rect2:
	var slot := Rect2(at - SLOT * 0.5, SLOT)
	return Rect2(slot.position + CreatureToken.OVAL.position * SLOT, CreatureToken.OVAL.size * SLOT)

func _advance(effect: CardPlayEffect, seconds: float) -> void:
	var left := seconds
	while left > 0.0:
		effect._process(minf(STEP, left))
		left -= STEP

func _shards_gone(burst: CardPlayEffect.Burst) -> bool:
	for shard in burst.shards:
		if burst.age < shard.delay + shard.life:
			return false
	return true

func _arg(prefix: String) -> String:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with(prefix):
			return argument.substr(prefix.length())
	return ""

func _check(label: String, condition: bool) -> void:
	print("  [%s] %s" % ["ok" if condition else "XX", label])
	if not condition:
		failures.append(label)
