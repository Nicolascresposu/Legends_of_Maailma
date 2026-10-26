extends SceneTree

## Live, serverless comparison using the game's actual CombatEffect.
## godot --path apps/godot-client --script src/combat_preview.gd
const SLOT := Vector2(104, 138)
const PRESETS := [3, 5, 7, 9, 10]
const NAMES := ["No shake", "100% shake", "200% shake", "300% shake", "350% shake"]
const NEIGHBOR_POSITIONS := [Vector2(0.12, 0.30), Vector2(0.38, 0.30), Vector2(0.60, 0.72), Vector2(0.84, 0.72)]

class Board extends Control:
	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.10, 0.13, 0.17))
		for x in range(0, int(size.x), 40):
			draw_line(Vector2(x, 0), Vector2(x, size.y), Color(0.19, 0.23, 0.28))
		for y in range(0, int(size.y), 40):
			draw_line(Vector2(0, y), Vector2(size.x, y), Color(0.19, 0.23, 0.28))
	func _notification(what: int) -> void:
		if what == NOTIFICATION_RESIZED:
			queue_redraw()

var library := CardLibrary.new()
var effect: CombatEffect
var stage: Board
var attacker: CreatureToken
var defender: CreatureToken
var neighbors: Array[CreatureToken] = []
var attack_input: SpinBox
var health_input: SpinBox
var metrics: Label
var replay: Button
var loop: CheckBox
var repeat_timer: Timer

func _init() -> void:
	await process_frame
	get_root().title = "Maailma — Combat effect preview"
	get_root().min_size = Vector2i(1000, 650)
	library.ingest([
		{"id": "brown_bear", "name": "Attacker", "type": "CREATURE", "attack": 3, "health": 3, "keywords": []},
		{"id": "wolf", "name": "Defender", "type": "CREATURE", "attack": 2, "health": 3, "keywords": []},
	])
	var margin := MarginContainer.new()
	get_root().add_child(margin)
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for edge in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + edge, 24)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 14)
	margin.add_child(column)
	var title := Label.new()
	title.text = "Combat effect preview"
	title.add_theme_font_size_override("font_size", 26)
	column.add_child(title)
	var help := Label.new()
	help.text = "Strength follows Attack only. Keys 1–5 compare presets; Space replays. The grid moves with the shake."
	column.add_child(help)
	var presets := HBoxContainer.new()
	presets.add_theme_constant_override("separation", 10)
	column.add_child(presets)
	for index in PRESETS.size():
		var button := Button.new()
		button.text = "%d: %s (%d/%d)" % [index + 1, NAMES[index], PRESETS[index], PRESETS[index]]
		button.shortcut = _shortcut(KEY_1 + index)
		button.pressed.connect(_preset.bind(index))
		presets.add_child(button)
	var controls := HBoxContainer.new()
	controls.add_theme_constant_override("separation", 14)
	column.add_child(controls)
	attack_input = _stat(controls, "Attack")
	health_input = _stat(controls, "Max health (visual only)")
	replay = Button.new()
	replay.text = "Replay (Space)"
	replay.shortcut = _shortcut(KEY_SPACE)
	replay.pressed.connect(_play)
	controls.add_child(replay)
	loop = CheckBox.new()
	loop.text = "Loop"
	loop.button_pressed = true
	loop.toggled.connect(func(on: bool) -> void:
		if on and not effect.is_busy():
			_play()
		elif not on:
			repeat_timer.stop())
	controls.add_child(loop)
	metrics = Label.new()
	column.add_child(metrics)
	var board_frame := PanelContainer.new()
	board_frame.size_flags_vertical = Control.SIZE_EXPAND_FILL
	board_frame.clip_contents = true
	column.add_child(board_frame)
	stage = Board.new()
	stage.mouse_filter = Control.MOUSE_FILTER_IGNORE
	board_frame.add_child(stage)
	attacker = CreatureToken.make(library, _card(), SLOT)
	defender = CreatureToken.make(library, {"definition_id": "wolf"}, SLOT)
	for token in [attacker, defender]:
		token.size = SLOT
		stage.add_child(token)
	for index in NEIGHBOR_POSITIONS.size():
		var token := CreatureToken.make(library, {"definition_id": "wolf"}, SLOT)
		token.size = SLOT
		token.ring_color = Color(0.34, 0.18, 0.20) if index < 2 else Color(0.16, 0.30, 0.24)
		stage.add_child(token)
		neighbors.append(token)
	effect = CombatEffect.new()
	stage.add_child(effect)
	effect.finished.connect(_finished)
	stage.resized.connect(_layout)
	repeat_timer = Timer.new()
	repeat_timer.one_shot = true
	repeat_timer.timeout.connect(_play)
	get_root().add_child(repeat_timer)
	_stats_changed(0)
	await process_frame
	await process_frame
	_layout()
	_play()

func _stat(row: Control, caption: String) -> SpinBox:
	var label := Label.new()
	label.text = caption
	row.add_child(label)
	var input := SpinBox.new()
	input.min_value = 1
	input.max_value = 30
	input.value = 3
	input.custom_minimum_size.x = 85
	input.value_changed.connect(_stats_changed)
	row.add_child(input)
	return input

func _shortcut(key: int) -> Shortcut:
	var event := InputEventKey.new()
	event.keycode = key
	var shortcut := Shortcut.new()
	shortcut.events = [event]
	return shortcut

func _card() -> Dictionary:
	return {"definition_id": "brown_bear", "attack": int(attack_input.value) if attack_input != null else 3,
		"health": int(health_input.value) if health_input != null else 3,
		"max_health": int(health_input.value) if health_input != null else 3}

func _preset(index: int) -> void:
	attack_input.set_value_no_signal(PRESETS[index])
	health_input.set_value_no_signal(PRESETS[index])
	_stats_changed(0)
	_play()

func _stats_changed(_value: float) -> void:
	if effect == null:
		return
	effect.cancel()
	attacker.show_card(library, _card())
	var weight := CombatEffect.weight_for(_card())
	var shake := CombatEffect.shake_for(_card())
	metrics.text = "Shake: %.1f%%    |    Peak shake: %.2f px    |    Shake duration: %.2f s\nDust: %d puffs    |    Dust lifetime: up to %.2f s    |    Minion precession: %s" % [
		shake / CombatEffect.SHAKE_BASE_PIXELS * 100.0, shake, CombatEffect.shake_duration_for(_card()),
		18 + int(weight * 18.0), CombatEffect.DUST_LIFE, "yes" if attack_input.value >= CombatEffect.HEAVY_ATTACK else "no"]

func _layout() -> void:
	# Cancel before layout so resizing cannot strand the stage at a shake offset.
	effect.cancel()
	attacker.position = stage.size * Vector2(0.30, 0.70) - SLOT * 0.5
	defender.position = stage.size * Vector2(0.65, 0.30) - SLOT * 0.5
	for index in neighbors.size():
		neighbors[index].position = stage.size * NEIGHBOR_POSITIONS[index] - SLOT * 0.5

func _play() -> void:
	if effect.is_busy():
		return
	repeat_timer.stop()
	effect.play(library, "attacker", _card(), attacker.get_global_rect(), "defender",
		{"definition_id": "wolf"}, defender.get_global_rect(), stage)
	effect.set_bystanders(neighbors)
	attacker.visible = false
	defender.visible = false
	replay.disabled = true

func _finished() -> void:
	attacker.visible = true
	defender.visible = true
	replay.disabled = false
	if loop.button_pressed:
		repeat_timer.start(0.8)
