extends SceneTree

## Serverless death timing, combat placement, and a one-second smoke filmstrip.
## godot --headless --path apps/godot-client --script src/last_breath_effect_test.gd
## Run windowed with -- --screenshot-dir=<dir> for visual review.
class Harness extends "res://src/main.gd":
	func _ready() -> void:
		pass

const SLOT := Vector2(104, 138)
const RAT := {"id": "giant_rat", "name": "Giant Rat", "type": "CREATURE", "cost": 1,
	"attack": 1, "health": 1, "keywords": ["LAST_BREATH"]}
const MERCY := {"id": "mercy_4", "name": "Mercy-4", "type": "CREATURE", "cost": 4,
	"attack": 3, "health": 4, "keywords": ["LAST_BREATH"]}
const BEAR := {"id": "brown_bear", "name": "Bear", "type": "CREATURE", "cost": 5,
	"attack": 8, "health": 9, "keywords": []}

var failures: Array[String] = []

func _init() -> void:
	await process_frame
	var main := Harness.new()
	get_root().add_child(main)
	main.client = MatchClient.new()
	main.accounts = AccountClient.new()
	main.add_child(main.client)
	main.add_child(main.accounts)
	main.library.ingest([RAT, MERCY, BEAR])
	main._build_interface()
	main.player_id = "one"
	main._on_match_state(_state(true, true))
	await _frames(4)
	var smoke: LastBreathEffect = main.last_breath_effect
	smoke.set_process(false)
	_check("loading a board does not produce death smoke", smoke._bursts.is_empty())
	# A spell or a Last Breath chain removes the creature without an attack.
	main._on_game_events([_death("b", "giant_rat")])
	_check("a death event waits for the authoritative removal", smoke._bursts.is_empty())
	main._on_match_state(_state(true, false))
	_check("non-combat Last Breath death starts the skull and smoke", smoke._bursts.size() == 1 and smoke._skull != null)
	main._on_match_state(_state(true, false))
	_check("repeated state updates do not duplicate the effect", smoke._bursts.size() == 1)
	smoke._process(0.999)
	_check("the effect remains for the full second", smoke._bursts.size() == 1)
	smoke._process(0.001)
	_check("the effect finishes at one second", smoke._bursts.is_empty())
	_check("death smoke never blocks board input", smoke.mouse_filter == Control.MOUSE_FILTER_IGNORE)
	# A removal without a death event must not be mistaken for Last Breath.
	main._on_match_state(_state(true, true))
	await _frames(2)
	main._on_match_state(_state(true, false))
	_check("a non-death removal has no smoke", smoke._bursts.is_empty())
	var ordinary := _state(true, true)
	ordinary["sides"]["two"]["creatures"]["b"]["definitionId"] = "brown_bear"
	main._on_match_state(ordinary)
	await _frames(2)
	main._on_game_events([_death("b", "brown_bear")])
	main._on_match_state(_state(true, false))
	_check("ordinary deaths do not show the Last Breath skull", smoke._bursts.is_empty())
	# Both participants die: effects begin at contact, at each actual position.
	main._on_match_state(_state(true, true))
	await _frames(3)
	main._on_game_events([{"type": "ATTACK_STARTED", "sourceId": "a", "targetId": "b"},
		_death("a", "mercy_4"), _death("b", "giant_rat")])
	main._on_match_state(_state(false, false))
	await _frames(4)
	var combat: CombatEffect = main.combat_effect
	combat.set_process(false)
	_check("combat smoke does not appear before impact", smoke._bursts.is_empty())
	combat._process(CombatEffect.IMPACT_AT)
	_check("simultaneous Last Breath deaths each get an effect", smoke._bursts.size() == 2)
	var source := combat.creature_rect("a")
	var expected := smoke.get_global_transform().affine_inverse() * (source.position
		+ (CreatureToken.OVAL.position + CreatureToken.OVAL.size * 0.5) * source.size)
	if smoke._bursts.size() == 2:
		_check("the attacking skull appears at contact", smoke._bursts[0].centre.distance_to(expected) < 0.1)
	combat._process(1.0)
	await _frames(2)
	_check("smoke survives combat cleanup", not combat.is_busy() and smoke._bursts.size() == 2)
	main._reset_combat_presentation()
	_check("changing matches clears smoke and pending deaths", smoke._bursts.is_empty()
		and main._pending_last_breath_deaths.is_empty())
	main.queue_free()
	await _frames(2)
	var shots := _arg("--screenshot-dir=")
	if shots != "" and DisplayServer.get_name() != "headless":
		await _filmstrip(shots)
	for failure in failures:
		print("  FAIL: ", failure)
	print("RESULT: ", "PASS" if failures.is_empty() else "FAIL", " (%d failures)" % failures.size())
	quit(0 if failures.is_empty() else 1)

func _death(id: String, definition: String) -> Dictionary:
	return {"type": "CREATURE_DIED", "sourceId": id, "cardDefinitionId": definition}

func _state(a_alive: bool, b_alive: bool) -> Dictionary:
	var sides := {}
	for player in ["one", "two"]:
		var mine: bool = player == "one"
		var id := "a" if mine else "b"
		var alive := a_alive if mine else b_alive
		var creatures := {}
		if alive:
			creatures[id] = {"instanceId": id, "definitionId": "mercy_4" if mine else "giant_rat",
				"currentAttack": 3 if mine else 1, "currentHealth": 4 if mine else 1,
				"maxHealth": 4 if mine else 1, "statuses": []}
		sides[player] = {"playerId": player, "hero": {"currentHealth": 30, "maxHealth": 30},
			"creatures": creatures, "hand": [], "deck": [], "taika": {"current": 3, "maximum": 3},
			"battlefield": {"config": {"width": 1}, "slots": {"FRONT": [id if alive else null], "BACK": [null]}}}
	return {"sides": sides, "playerOrder": ["one", "two"], "activePlayerId": "one", "turn": 1}

func _filmstrip(shots: String) -> void:
	var moments := [0.0, 0.10, 0.30, 0.60, 0.85, 0.99, 1.0]
	for index in moments.size():
		var x := 35.0 + index * 174.0
		var label := Label.new()
		label.text = "%.2fs" % moments[index]
		label.position = Vector2(x + 30, 160)
		get_root().add_child(label)
		var effect := LastBreathEffect.new()
		get_root().add_child(effect)
		effect.set_process(false)
		effect.play(Rect2(Vector2(x, 230), SLOT))
		effect._process(moments[index])
	await process_frame
	await RenderingServer.frame_post_draw
	var path := shots.path_join("last_breath_effect.png")
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
