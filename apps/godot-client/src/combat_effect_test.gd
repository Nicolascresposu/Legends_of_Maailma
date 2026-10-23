extends SceneTree

## Serverless animation timing and real-main-scene event sequencing checks.
## godot --headless --path apps/godot-client --script src/combat_effect_test.gd
## Use -- --screenshot-dir=<dir> in a windowed run for a combat filmstrip.
class Harness extends "res://src/main.gd":
	func _ready() -> void:
		pass

const SLOT := Vector2(104, 138)
const WOLF := {"id": "wolf", "name": "Wolf", "type": "CREATURE", "cost": 2,
	"attack": 2, "health": 3, "tags": [], "keywords": []}
const BEAR := {"id": "brown_bear", "name": "Bear", "type": "CREATURE", "cost": 5,
	"attack": 8, "health": 9, "tags": [], "keywords": []}
const SOURCE := {"definition_id": "brown_bear", "attack": 8, "health": 9, "max_health": 9}
const TARGET := {"definition_id": "wolf", "attack": 2, "health": 3, "max_health": 3}
const ATTACK := {"type": "ATTACK_STARTED", "sourceId": "a", "targetId": "b"}

var failures: Array[String] = []
var library := CardLibrary.new()
var hits := 0
var finishes := 0

func _init() -> void:
	await process_frame
	print("== combat effect test ==")
	library.ingest([WOLF, BEAR])
	await _effect_test()
	await _integration_test()
	var shots := _arg("--screenshot-dir=")
	if shots != "" and DisplayServer.get_name() != "headless":
		await _filmstrip(shots)
	for failure in failures:
		print("  FAIL: ", failure)
	print("RESULT: ", "PASS" if failures.is_empty() else "FAIL", " (%d failures)" % failures.size())
	quit(0 if failures.is_empty() else 1)

func _effect_test() -> void:
	var stage := Control.new()
	stage.position = Vector2(7, 11)
	get_root().add_child(stage)
	var effect := CombatEffect.new()
	stage.add_child(effect)
	effect.impacted.connect(func() -> void: hits += 1)
	effect.finished.connect(func() -> void: finishes += 1)
	var start := Rect2(Vector2(200, 400), SLOT)
	var target := Rect2(Vector2(320, 100), SLOT)
	effect.play(library, "a", SOURCE, start, "b", TARGET, target, stage)
	effect.set_process(false)
	var attacker := effect._attacker
	var defender := effect._defender
	_check("both creatures are owned while fighting", effect.owns("a") and effect.owns("b"))
	_check("the animation blocks clicks", effect.mouse_filter == Control.MOUSE_FILTER_STOP)
	effect._process(CombatEffect.WINDUP)
	var centre := attacker.token.position + SLOT * 0.5
	_check("windup pulls away from the defender", (centre - attacker.home).dot(effect._direction) < -15.0)
	_check("windup lifts the creature", attacker.token.scale.x > 1.05)
	_check("no premature damage or shake", hits == 0 and stage.position == Vector2(7, 11))
	effect._process(CombatEffect.LUNGE + 0.001)
	_check("impact fires once at contact", hits == 1 and effect.has_impacted())
	_check("the attacker reaches the target", (attacker.token.position + SLOT * 0.5).distance_to(effect._contact) < 0.1)
	_check("big creatures shake the stage", stage.position.distance_to(Vector2(7, 11)) > 1.0)
	_check("dust is emitted at impact", effect._dust.size() >= 30)
	effect.resolve(library, _state(7, false))
	_check("surviving stats change at impact", attacker.token._health_value.text == "7")
	_check("a dead defender survives visually for the impact", defender.dead and is_instance_valid(defender.token))
	effect._process(0.08)
	_check("the defender recoils", defender.token.position.distance_to(defender.home - SLOT * 0.5) > 1.0)
	_check("dead creatures fade after the hit", defender.token.modulate.a > 0.0 and defender.token.modulate.a < 1.0)
	effect._process(0.23)
	_check("the surviving attacker returns exactly home", (attacker.token.position + SLOT * 0.5).distance_to(attacker.home) < 0.1)
	_check("shake settles without drift", stage.position == Vector2(7, 11))
	effect._process(1.0)
	_check("the effect finishes once and releases input", not effect.is_busy() and finishes == 1 and hits == 1
		and effect.mouse_filter == Control.MOUSE_FILTER_IGNORE)
	_check("small creatures have no shake", CombatEffect.weight_for(TARGET) == 0.0)
	_check("impact strength grows and is capped", CombatEffect.weight_for(SOURCE) > CombatEffect.weight_for(TARGET)
		and CombatEffect.weight_for({"attack": 100, "health": 100}) == 1.0)
	# Reversed direction, simultaneous deaths, and cancellation mid-shake.
	effect.play(library, "b", TARGET, target, "a", SOURCE, start, stage)
	effect.set_process(false)
	effect._process(CombatEffect.IMPACT_AT + 0.02)
	effect.resolve(library, {"sides": {}})
	_check("simultaneous deaths are retained for the hit", effect._attacker.dead and effect._defender.dead)
	effect.cancel()
	_check("cancellation restores the original screen position", stage.position == Vector2(7, 11) and not effect.is_busy())
	stage.queue_free()
	await process_frame

func _integration_test() -> void:
	var main := Harness.new()
	get_root().add_child(main)
	main.client = MatchClient.new()
	main.accounts = AccountClient.new()
	main.add_child(main.client)
	main.add_child(main.accounts)
	main.library.ingest([WOLF, BEAR])
	main._build_interface()
	main.player_id = "one"
	main._on_match_state(_state(9, true))
	await _frames(4)
	var result := _state(7, false)
	main._on_game_events([ATTACK])
	main._on_match_state(result)
	main._on_legal_actions("one", [{"type": "END_TURN", "actorId": "one"}])
	await _frames(4)
	var effect: CombatEffect = main.combat_effect
	effect.set_process(false)
	_check("the real main scene starts combat from a server event", effect.is_busy())
	if not effect.is_busy():
		main.queue_free()
		await process_frame
		return
	_check("lethal state is held until impact", not CombatEffect._creature(main.state, "b").is_empty())
	_check("both originals hide behind the animation", main._combat_token("a").modulate.a == 0.0
		and main._combat_token("b").modulate.a == 0.0)
	_check("combat cannot submit stale actions", not main._submit({"type": "END_TURN"}))
	effect._process(CombatEffect.IMPACT_AT)
	_check("the authoritative death is applied at the hit", CombatEffect._creature(main.state, "b").is_empty())
	_check("the copied survivor shows the result", effect._attacker.token._health_value.text == "7")
	_check("rerendering at impact keeps the survivor hidden", main._combat_token("a").modulate.a == 0.0)
	# A new batch waits for the first animation, even in the same socket poll.
	main._on_game_events([{"type": "TURN_STARTED", "actorId": "two"}])
	var later := result.duplicate(true)
	later["turn"] = 2
	main._on_match_state(later)
	_check("later batches stay queued", int(main.state["turn"]) == 1)
	effect._process(1.0)
	await _frames(3)
	_check("queued messages resume in server order", int(main.state["turn"]) == 2 and main._presentation_queue.is_empty())
	_check("the surviving original returns", main._combat_token("a").modulate.a == 1.0)
	_check("input and legal actions resume", not main._combat_locked() and not main.end_turn_button.disabled)
	# The next attack's state can arrive after impact rather than in its poll.
	main._on_match_state(_state(9, true))
	main._on_game_events([ATTACK])
	await _frames(4)
	effect.set_process(false)
	effect._process(CombatEffect.IMPACT_AT)
	main._on_match_state(result)
	_check("late results apply immediately after impact", CombatEffect._creature(main.state, "b").is_empty()
		and effect._attacker.token._health_value.text == "7")
	effect._process(1.0)
	await _frames(2)
	# A queued opponent attack must animate against the preceding result.
	main._on_match_state(_state(9, true))
	main._on_game_events([ATTACK])
	main._on_match_state(_state(7, true))
	main._on_game_events([{"type": "ATTACK_STARTED", "sourceId": "b", "targetId": "a"}])
	var terminal := _state(0, false)
	terminal["sides"]["one"]["creatures"].clear()
	terminal["sides"]["one"]["battlefield"]["slots"]["FRONT"] = [null]
	terminal["phase"] = "FINISHED"
	terminal["winnerId"] = "two"
	main._on_match_state(terminal)
	main._on_match_ended("two")
	await _frames(4)
	effect.set_process(false)
	effect._process(CombatEffect.IMPACT_AT)
	_check("the first of consecutive attacks applies only its own state", not CombatEffect._creature(main.state, "a").is_empty()
		and str(main.state.get("phase", "")) != "FINISHED")
	effect._process(1.0)
	await _frames(4)
	effect.set_process(false)
	_check("an opponent's queued attack plays next", effect.is_busy() and effect._attacker.id == "b")
	effect._process(CombatEffect.IMPACT_AT)
	_check("the second attack applies its own deaths", effect._attacker.dead and effect._defender.dead)
	effect._process(1.0)
	await _frames(2)
	_check("match outcome survives the final animation", main.turn_banner.text.contains("You lose") and main.end_turn_button.disabled)
	# Ranged combat can cross more rows than a short viewport can show.
	var distant := _state(9, true)
	distant["sides"]["one"]["battlefield"]["slots"] = {"FRONT": [null], "BACK": ["a"]}
	main._on_match_state(distant)
	main._on_game_events([ATTACK])
	await _frames(5)
	effect.set_process(false)
	_check("offscreen back-row combat still animates inside the board", effect.is_busy()
		and effect.clip_contents and effect.size == main.board_area.size)
	effect._process(1.0)
	await _frames(2)
	main._on_match_state(_state(9, true))
	main._on_game_events([ATTACK])
	await _frames(4)
	effect.set_process(false)
	effect._process(CombatEffect.IMPACT_AT)
	main._reset_combat_presentation()
	await _frames(2)
	_check("switching matches cancels pending presentation", not effect.is_busy() and main._presentation_queue.is_empty()
		and main.game_root.position == Vector2.ZERO)
	main.queue_free()
	await process_frame

func _state(health: int, defender_alive: bool) -> Dictionary:
	var sides := {}
	for player in ["one", "two"]:
		var mine: bool = player == "one"
		var id := "a" if mine else "b"
		var alive := mine or defender_alive
		var creatures := {}
		if alive:
			creatures[id] = {"instanceId": id, "definitionId": "brown_bear" if mine else "wolf",
				"currentAttack": 8 if mine else 2, "currentHealth": health if mine else 3,
				"maxHealth": 9 if mine else 3, "combatActionUsed": false}
		sides[player] = {"playerId": player, "hero": {"currentHealth": 30, "maxHealth": 30},
			"creatures": creatures, "hand": [], "deck": [], "taika": {"current": 3, "maximum": 3},
			"battlefield": {"config": {"width": 1}, "slots": {"FRONT": [id if alive else null], "BACK": [null]}}}
	return {"sides": sides, "playerOrder": ["one", "two"], "activePlayerId": "one", "turn": 1}

func _filmstrip(shots: String) -> void:
	var moments := [0.0, 0.14, 0.20, 0.23, 0.29, 0.40, 0.54]
	for index in moments.size():
		var x := 35.0 + index * 176.0
		var label := Label.new()
		label.text = "%.2fs" % moments[index]
		label.position = Vector2(x + 30, 55)
		get_root().add_child(label)
		var effect := CombatEffect.new()
		get_root().add_child(effect)
		effect.play(library, "a", SOURCE, Rect2(Vector2(x, 430), SLOT),
			"b", TARGET, Rect2(Vector2(x, 150), SLOT))
		effect.set_process(false)
		effect._process(moments[index])
	await process_frame
	await RenderingServer.frame_post_draw
	var path := shots.path_join("combat_effect.png")
	get_root().get_texture().get_image().save_png(path)
	print("  saved ", path)

func _frames(count: int) -> void:
	for index in count:
		await process_frame

func _arg(prefix: String) -> String:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with(prefix):
			return argument.substr(prefix.length())
	return ""

func _check(label: String, condition: bool) -> void:
	print("  [%s] %s" % ["ok" if condition else "XX", label])
	if not condition:
		failures.append(label)
