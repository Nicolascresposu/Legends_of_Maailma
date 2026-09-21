extends Node
class_name MatchClient

## Transport for the authoritative server: REST for setup, WebSocket for play.
##
## This node owns connection state and message framing only. It never decides
## legality — every action is sent to the server and echoed back as state.

signal connection_changed(status: int, detail: String)
signal match_state_received(state: Dictionary)
signal legal_actions_received(player_id: String, actions: Array)
signal game_events_received(events: Array)
signal match_ended(winner_id: String)
signal server_error(code: String, message: String)
signal match_created(match_id: String)
signal cards_received(cards: Variant)
signal request_failed(detail: String)

enum Status { DISCONNECTED, CONNECTING, CONNECTED, RECONNECTING }

const RECONNECT_DELAY_SECONDS := 2.0
const MAX_RECONNECT_ATTEMPTS := 5

var http_base := "http://127.0.0.1:3000"
var match_id := ""
var player_id := ""

var _socket: WebSocketPeer = null
var _status: int = Status.DISCONNECTED
var _reconnect_attempts := 0
var _reconnect_timer := 0.0
var _should_reconnect := false
var _create_request: HTTPRequest
var _cards_request: HTTPRequest

func _ready() -> void:
	_ensure_requests()
	set_process(true)

## Builds the HTTP nodes on first use.
##
## `add_child` does not run `_ready` synchronously, so a caller that creates the
## client and immediately requests data would otherwise hit null nodes.
func _ensure_requests() -> void:
	if _create_request == null:
		_create_request = HTTPRequest.new()
		_create_request.request_completed.connect(_on_create_completed)
		add_child(_create_request)
	# A dedicated request node per endpoint: HTTPRequest handles one call at a
	# time, so sharing one node would drop whichever request started second.
	if _cards_request == null:
		_cards_request = HTTPRequest.new()
		_cards_request.request_completed.connect(_on_cards_completed)
		add_child(_cards_request)

func status() -> int:
	return _status

func is_connected_to_match() -> bool:
	return _status == Status.CONNECTED

func websocket_url() -> String:
	# Derive the socket URL from the REST base so only one address is configured.
	var base := http_base
	if base.begins_with("https://"):
		return "wss://" + base.substr(8) + "/matches"
	if base.begins_with("http://"):
		return "ws://" + base.substr(7) + "/matches"
	return "ws://" + base + "/matches"

func fetch_cards() -> void:
	_ensure_requests()
	# HTTPRequest refuses to run until it is inside the tree; wait one frame if a
	# caller asks before the client has been added.
	if not is_inside_tree():
		await tree_entered
		await get_tree().process_frame
	var error := _cards_request.request(http_base + "/api/cards")
	if error != OK:
		request_failed.emit("Could not reach the server for card data.")

func create_match(scenario_id: String, player: String, hero_id: String, deck: Array) -> void:
	_ensure_requests()
	if not is_inside_tree():
		await tree_entered
		await get_tree().process_frame
	player_id = player
	var opponent_is_ai := scenario_id != "STANDARD_PVP"
	var body := {
		"scenarioId": scenario_id,
		"players": [
			{"playerId": player, "heroDefinitionId": hero_id, "deck": deck, "controller": "HUMAN"},
			{
				"playerId": "bandits" if opponent_is_ai else "player-b",
				"heroDefinitionId": "striker",
				"deck": deck,
				"controller": "AI" if opponent_is_ai else "HUMAN",
			},
		],
	}
	var error := _create_request.request(
		http_base + "/api/matches",
		["Content-Type: application/json"],
		HTTPClient.METHOD_POST,
		JSON.stringify(body)
	)
	if error != OK:
		request_failed.emit("Could not reach the server. Is `npm run dev` running?")

func _on_create_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		request_failed.emit("Could not reach the server. Is `npm run dev` running?")
		return
	var text := body.get_string_from_utf8()
	var response: Variant = JSON.parse_string(text)
	if response_code != 201 or typeof(response) != TYPE_DICTIONARY:
		var detail := text
		if typeof(response) == TYPE_DICTIONARY:
			detail = str((response as Dictionary).get("message", text))
		request_failed.emit("Could not create match: " + detail)
		return
	match_created.emit(str((response as Dictionary).get("matchId", "")))

func _on_cards_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		return
	cards_received.emit(JSON.parse_string(body.get_string_from_utf8()))

## Opens a socket and joins. `select_hero` is only sent for a fresh match: the
## server rejects hero changes once play has begun, so rejoining must not ask.
func join(target_match_id: String, target_player_id: String, hero_id: String, select_hero: bool) -> void:
	match_id = target_match_id
	player_id = target_player_id
	_should_reconnect = true
	_reconnect_attempts = 0
	_pending_hero_id = hero_id if select_hero else ""
	_open_socket()

var _pending_hero_id := ""

func _open_socket() -> void:
	_socket = WebSocketPeer.new()
	var error := _socket.connect_to_url(websocket_url())
	if error != OK:
		_socket = null
		_set_status(Status.DISCONNECTED, "WebSocket connection failed.")
		return
	_set_status(Status.CONNECTING if _reconnect_attempts == 0 else Status.RECONNECTING, "Connecting…")

func disconnect_from_match() -> void:
	_should_reconnect = false
	if _socket != null:
		_socket.close()
		_socket = null
	_set_status(Status.DISCONNECTED, "Disconnected.")

func submit_action(action: Dictionary) -> bool:
	return _send({"type": "SUBMIT_ACTION", "matchId": match_id, "action": action})

func select_hero(hero_id: String) -> bool:
	return _send({
		"type": "SELECT_HERO",
		"matchId": match_id,
		"playerId": player_id,
		"heroDefinitionId": hero_id,
	})

func _send(message: Dictionary) -> bool:
	if _socket == null or _socket.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return false
	_socket.send_text(JSON.stringify(message))
	return true

func _process(delta: float) -> void:
	if _socket == null:
		if _should_reconnect and _status == Status.RECONNECTING:
			_reconnect_timer -= delta
			if _reconnect_timer <= 0.0:
				_open_socket()
		return

	_socket.poll()
	var ready_state := _socket.get_ready_state()

	if ready_state == WebSocketPeer.STATE_OPEN:
		if _status != Status.CONNECTED:
			_reconnect_attempts = 0
			_set_status(Status.CONNECTED, "Connected.")
			_send({"type": "JOIN_MATCH", "matchId": match_id, "playerId": player_id})
			if _pending_hero_id != "":
				select_hero(_pending_hero_id)
				_pending_hero_id = ""
		while _socket.get_available_packet_count() > 0:
			var payload: Variant = JSON.parse_string(_socket.get_packet().get_string_from_utf8())
			if typeof(payload) == TYPE_DICTIONARY:
				_dispatch(payload)
	elif ready_state == WebSocketPeer.STATE_CLOSED:
		# A closed peer cannot be reused; drop it and schedule a fresh attempt.
		_socket = null
		if _should_reconnect and _reconnect_attempts < MAX_RECONNECT_ATTEMPTS:
			_reconnect_attempts += 1
			_reconnect_timer = RECONNECT_DELAY_SECONDS
			_set_status(
				Status.RECONNECTING,
				"Connection lost. Reconnecting (%d/%d)…" % [_reconnect_attempts, MAX_RECONNECT_ATTEMPTS]
			)
		else:
			_should_reconnect = false
			_set_status(Status.DISCONNECTED, "Disconnected from the server.")

func _dispatch(message: Dictionary) -> void:
	match str(message.get("type", "")):
		"MATCH_STATE":
			var state: Variant = message.get("state", {})
			if typeof(state) == TYPE_DICTIONARY:
				match_state_received.emit(state)
		"LEGAL_ACTIONS":
			var actions: Variant = message.get("actions", [])
			legal_actions_received.emit(
				str(message.get("playerId", "")),
				actions if typeof(actions) == TYPE_ARRAY else []
			)
		"GAME_EVENTS":
			var events: Variant = message.get("events", [])
			if typeof(events) == TYPE_ARRAY:
				game_events_received.emit(events)
		"TURN_CHANGED":
			pass  # MATCH_STATE already carries turn and active player.
		"MATCH_ENDED":
			match_ended.emit(str(message.get("winnerId", "")))
		"ERROR":
			server_error.emit(str(message.get("code", "ERROR")), str(message.get("message", "")))

func _set_status(new_status: int, detail: String) -> void:
	_status = new_status
	connection_changed.emit(new_status, detail)
