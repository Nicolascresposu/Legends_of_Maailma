extends Control

const HTTP_BASE := "http://127.0.0.1:3000"
const WS_URL := "ws://127.0.0.1:3000/matches"

var socket := WebSocketPeer.new()
var match_id := ""
var player_id := "player-a"
var state: Dictionary = {}
var legal_actions: Array = []

var status_label: Label
var match_input: LineEdit
var player_input: LineEdit
var hero_selector: OptionButton
var board_container: VBoxContainer
var hand_container: HBoxContainer
var action_container: VBoxContainer
var http: HTTPRequest

func _ready() -> void:
	build_interface()
	set_process(true)

func build_interface() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 18)
	margin.add_theme_constant_override("margin_right", 18)
	margin.add_theme_constant_override("margin_top", 18)
	margin.add_theme_constant_override("margin_bottom", 18)
	add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 12)
	margin.add_child(root)

	var connection_row := HBoxContainer.new()
	root.add_child(connection_row)
	player_input = LineEdit.new()
	player_input.text = player_id
	player_input.placeholder_text = "Player ID"
	connection_row.add_child(player_input)
	hero_selector = OptionButton.new()
	hero_selector.add_item("The Mender", 0)
	hero_selector.add_item("The Striker", 1)
	connection_row.add_child(hero_selector)
	match_input = LineEdit.new()
	match_input.placeholder_text = "Match ID"
	match_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	connection_row.add_child(match_input)
	var connect_button := Button.new()
	connect_button.text = "Join"
	connect_button.pressed.connect(join_match)
	connection_row.add_child(connect_button)
	var create_button := Button.new()
	create_button.text = "Create PvP"
	create_button.pressed.connect(create_match.bind("STANDARD_PVP"))
	connection_row.add_child(create_button)
	var adventure_button := Button.new()
	adventure_button.text = "Create Bandit Ambush"
	adventure_button.pressed.connect(create_match.bind("BANDIT_AMBUSH"))
	connection_row.add_child(adventure_button)

	status_label = Label.new()
	status_label.text = "Start the Node server, then create or join a match."
	root.add_child(status_label)

	var game_row := HBoxContainer.new()
	game_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(game_row)
	board_container = VBoxContainer.new()
	board_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	board_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	game_row.add_child(board_container)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.x = 390
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	game_row.add_child(scroll)
	action_container = VBoxContainer.new()
	action_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(action_container)

	var hand_title := Label.new()
	hand_title.text = "Hand"
	root.add_child(hand_title)
	hand_container = HBoxContainer.new()
	root.add_child(hand_container)

	http = HTTPRequest.new()
	http.request_completed.connect(_on_create_completed)
	add_child(http)

func _process(_delta: float) -> void:
	if socket.get_ready_state() == WebSocketPeer.STATE_CLOSED:
		return
	socket.poll()
	while socket.get_available_packet_count() > 0:
		var message = JSON.parse_string(socket.get_packet().get_string_from_utf8())
		if typeof(message) == TYPE_DICTIONARY:
			handle_server_message(message)

func create_match(scenario_id: String = "STANDARD_PVP") -> void:
	player_id = player_input.text.strip_edges()
	if player_id.is_empty():
		player_id = "player-a"
	var body := {
		"scenarioId": scenario_id,
		"seed": "godot-demo",
		"players": [
			{"playerId": player_id, "heroDefinitionId": selected_hero_id(), "deck": starter_deck()},
			{"playerId": "player-b" if scenario_id == "STANDARD_PVP" else "bandits", "heroDefinitionId": "striker", "deck": starter_deck(), "controller": "HUMAN" if scenario_id == "STANDARD_PVP" else "AI"}
		]
	}
	status_label.text = "Creating match…"
	http.request(HTTP_BASE + "/api/matches", ["Content-Type: application/json"], HTTPClient.METHOD_POST, JSON.stringify(body))

func _on_create_completed(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var response = JSON.parse_string(body.get_string_from_utf8())
	if response_code != 201 or typeof(response) != TYPE_DICTIONARY:
		status_label.text = "Could not create match: " + body.get_string_from_utf8()
		return
	match_input.text = str(response.get("matchId", ""))
	join_match()

func join_match() -> void:
	match_id = match_input.text.strip_edges()
	player_id = player_input.text.strip_edges()
	if match_id.is_empty() or player_id.is_empty():
		status_label.text = "Match ID and Player ID are required."
		return
	socket = WebSocketPeer.new()
	var error := socket.connect_to_url(WS_URL)
	if error != OK:
		status_label.text = "WebSocket connection failed."
		return
	status_label.text = "Connecting…"
	for attempt in range(50):
		socket.poll()
		if socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
			break
		await get_tree().create_timer(0.05).timeout
	if socket.get_ready_state() != WebSocketPeer.STATE_OPEN:
		status_label.text = "Timed out while connecting."
		return
	send_message({"type": "JOIN_MATCH", "matchId": match_id, "playerId": player_id})
	send_message({"type": "SELECT_HERO", "matchId": match_id, "playerId": player_id, "heroDefinitionId": selected_hero_id()})

func handle_server_message(message: Dictionary) -> void:
	match str(message.get("type", "")):
		"MATCH_STATE":
			state = message.get("state", {})
			render_state()
		"LEGAL_ACTIONS":
			if str(message.get("playerId", "")) == player_id:
				legal_actions = message.get("actions", [])
				render_actions()
		"GAME_EVENTS":
			var events: Array = message.get("events", [])
			status_label.text = "Resolved %d event(s)." % events.size()
		"MATCH_ENDED":
			status_label.text = "Match ended. Winner: " + str(message.get("winnerId", "draw"))
		"ERROR":
			status_label.text = str(message.get("code", "ERROR")) + ": " + str(message.get("message", ""))

func render_state() -> void:
	clear_children(board_container)
	clear_children(hand_container)
	if state.is_empty():
		return
	var sides: Dictionary = state.get("sides", {})
	if not sides.has(player_id):
		return
	var order: Array = state.get("playerOrder", [])
	var opponent_id: String = str(order[1]) if str(order[0]) == player_id else str(order[0])
	var mine: Dictionary = sides[player_id]
	var opponent: Dictionary = sides[opponent_id]
	status_label.text = "Turn %s — active: %s | You: %s HP, %s/%s Taika | Enemy: %s HP" % [
		state.get("turn", 0), state.get("activePlayerId", ""), mine.hero.currentHealth,
		mine.taika.current, mine.taika.maximum, opponent.hero.currentHealth
	]
	render_side(opponent_id, opponent, ["BACK", "FRONT"])
	var separator := HSeparator.new()
	board_container.add_child(separator)
	render_side(player_id, mine, ["FRONT", "BACK"])
	for card in mine.get("hand", []):
		var label := Label.new()
		label.text = str(card.get("definitionId", "card"))
		label.custom_minimum_size = Vector2(120, 46)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		hand_container.add_child(label)

func render_side(side_id: String, side: Dictionary, rows: Array) -> void:
	var title := Label.new()
	title.text = side_id + " — Artifacts: " + str(side.get("artifacts", []).size())
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	board_container.add_child(title)
	var width: int = int(side.battlefield.config.width)
	for row_name in rows:
		var grid := GridContainer.new()
		grid.columns = width
		grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		board_container.add_child(grid)
		var slots: Array = side.battlefield.slots[row_name]
		for column in range(width):
			var panel := PanelContainer.new()
			panel.custom_minimum_size = Vector2(150, 90)
			grid.add_child(panel)
			var label := Label.new()
			label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			var creature_id = slots[column]
			if creature_id == null:
				label.text = "%s %d\n[empty]" % [row_name, column]
			else:
				var creature: Dictionary = side.creatures[str(creature_id)]
				label.text = "%s\n%s\n%d / %d HP" % [creature_id, creature.definitionId, creature.currentAttack, creature.currentHealth]
			panel.add_child(label)

func render_actions() -> void:
	clear_children(action_container)
	var title := Label.new()
	title.text = "Server-approved actions"
	action_container.add_child(title)
	for action in legal_actions:
		var button := Button.new()
		button.text = action_label(action)
		button.pressed.connect(submit_action.bind(action))
		action_container.add_child(button)

func submit_action(action: Dictionary) -> void:
	send_message({"type": "SUBMIT_ACTION", "matchId": match_id, "action": action})

func send_message(message: Dictionary) -> void:
	if socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		socket.send_text(JSON.stringify(message))
	else:
		status_label.text = "Connection is not open yet; press Join again."

func action_label(action: Dictionary) -> String:
	match str(action.get("type", "")):
		"PLAY_CARD": return "Play %s → %s %s" % [action.get("cardInstanceId", ""), action.get("position", ""), action.get("targetId", "")]
		"ATTACK": return "%s attacks %s" % [action.get("attackerId", ""), action.get("targetId", "")]
		"MOVE_CREATURE": return "Move %s → %s" % [action.get("creatureId", ""), action.get("destination", "")]
		"SWAP_CREATURES": return "Swap %s ↔ %s" % [action.get("firstCreatureId", ""), action.get("secondCreatureId", "")]
		"USE_HERO_POWER": return "Use Hero Power"
		"END_TURN": return "End Turn"
	return JSON.stringify(action)

func clear_children(node: Node) -> void:
	for child in node.get_children():
		child.queue_free()

func starter_deck() -> Array:
	var ids := ["wolf", "brown_bear", "hawk", "giant_rat", "hunting_spider", "elf_archer", "dwarf_defender", "human_mercenary", "field_medic", "apprentice_mage", "maintenance_anima", "mercy_4", "healing_potion", "firebolt", "arcane_battery"]
	var deck: Array = []
	for id in ids:
		deck.append(id)
		deck.append(id)
	return deck

func selected_hero_id() -> String:
	return "striker" if hero_selector.selected == 1 else "healer"
