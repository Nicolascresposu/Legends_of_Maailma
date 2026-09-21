extends Node
class_name AccountClient

## REST transport for accounts, collections and decks.
##
## Kept separate from `MatchClient`: that owns live match traffic, this owns
## everything a player does outside a match. The session token lives here and
## is attached to every authenticated request.

signal signed_in(user: Dictionary)
signal sign_in_failed(message: String)
signal signed_out()
signal collection_loaded(cards: Array)
signal decks_loaded(decks: Array)
signal deck_saved(deck: Dictionary)
signal deck_error(message: String)
signal readiness_assessed(readiness: Dictionary)
signal request_failed(message: String)

var http_base := "http://127.0.0.1:3000"
var token := ""
var user: Dictionary = {}

## One HTTPRequest per concern: a single node handles one call at a time, so
## sharing would drop whichever request started second.
var _auth_request: HTTPRequest
var _collection_request: HTTPRequest
var _deck_request: HTTPRequest
var _deck_mutate_request: HTTPRequest
var _assess_request: HTTPRequest

func _ready() -> void:
	_ensure_requests()

func _ensure_requests() -> void:
	if _auth_request == null:
		_auth_request = HTTPRequest.new()
		_auth_request.request_completed.connect(_on_auth_completed)
		add_child(_auth_request)
	if _collection_request == null:
		_collection_request = HTTPRequest.new()
		_collection_request.request_completed.connect(_on_collection_completed)
		add_child(_collection_request)
	if _deck_request == null:
		_deck_request = HTTPRequest.new()
		_deck_request.request_completed.connect(_on_decks_completed)
		add_child(_deck_request)
	if _deck_mutate_request == null:
		_deck_mutate_request = HTTPRequest.new()
		_deck_mutate_request.request_completed.connect(_on_deck_mutated)
		add_child(_deck_mutate_request)
	if _assess_request == null:
		_assess_request = HTTPRequest.new()
		_assess_request.request_completed.connect(_on_assess_completed)
		add_child(_assess_request)

func is_signed_in() -> bool:
	return token != ""

func _headers(with_body: bool = true) -> PackedStringArray:
	var headers := PackedStringArray()
	if with_body:
		headers.append("Content-Type: application/json")
	if token != "":
		headers.append("Authorization: Bearer " + token)
	return headers

## HTTPRequest refuses to run until it is inside the tree.
func _await_tree() -> void:
	_ensure_requests()
	if not is_inside_tree():
		await tree_entered
		await get_tree().process_frame

func register(email: String, display_name: String, password: String) -> void:
	await _await_tree()
	var body := {"email": email, "displayName": display_name, "password": password}
	var error := _auth_request.request(
		http_base + "/api/auth/register",
		_headers(),
		HTTPClient.METHOD_POST,
		JSON.stringify(body)
	)
	if error != OK:
		request_failed.emit("Could not reach the server.")

func login(email: String, password: String) -> void:
	await _await_tree()
	var body := {"email": email, "password": password}
	var error := _auth_request.request(
		http_base + "/api/auth/login",
		_headers(),
		HTTPClient.METHOD_POST,
		JSON.stringify(body)
	)
	if error != OK:
		request_failed.emit("Could not reach the server.")

func sign_out() -> void:
	if token == "":
		return
	await _await_tree()
	# Best effort: the local session is cleared whether or not the call lands.
	_auth_request.request(
		http_base + "/api/auth/logout", _headers(false), HTTPClient.METHOD_POST, ""
	)
	token = ""
	user = {}
	signed_out.emit()

func _on_auth_completed(
	result: int, response_code: int, _headers_out: PackedStringArray, body: PackedByteArray
) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		sign_in_failed.emit("Could not reach the server. Is `npm run dev` running?")
		return
	var text := body.get_string_from_utf8()
	if text == "":
		return  # Logout returns no content.
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		sign_in_failed.emit("Unexpected reply from the server.")
		return
	var payload: Dictionary = parsed
	if response_code != 200 and response_code != 201:
		sign_in_failed.emit(str(payload.get("message", "Sign-in failed")))
		return
	token = str(payload.get("token", ""))
	var who: Variant = payload.get("user", {})
	user = who if typeof(who) == TYPE_DICTIONARY else {}
	signed_in.emit(user)

# --- Collection -------------------------------------------------------------

func fetch_collection() -> void:
	await _await_tree()
	var error := _collection_request.request(http_base + "/api/collection", _headers(false))
	if error != OK:
		request_failed.emit("Could not load your collection.")

func _on_collection_completed(
	result: int, response_code: int, _h: PackedStringArray, body: PackedByteArray
) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		request_failed.emit("Could not load your collection.")
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var cards: Variant = (parsed as Dictionary).get("cards", [])
	collection_loaded.emit(cards if typeof(cards) == TYPE_ARRAY else [])

## Checks a card list without saving, so a builder can show readiness live.
func assess(card_ids: Array) -> void:
	await _await_tree()
	var error := _assess_request.request(
		http_base + "/api/collection/assess",
		_headers(),
		HTTPClient.METHOD_POST,
		JSON.stringify({"cardIds": card_ids})
	)
	if error != OK:
		request_failed.emit("Could not check that deck.")

func _on_assess_completed(
	result: int, response_code: int, _h: PackedStringArray, body: PackedByteArray
) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var readiness: Variant = (parsed as Dictionary).get("readiness", {})
	readiness_assessed.emit(readiness if typeof(readiness) == TYPE_DICTIONARY else {})

# --- Decks ------------------------------------------------------------------

func fetch_decks() -> void:
	await _await_tree()
	var error := _deck_request.request(http_base + "/api/decks", _headers(false))
	if error != OK:
		request_failed.emit("Could not load your decks.")

func _on_decks_completed(
	result: int, response_code: int, _h: PackedStringArray, body: PackedByteArray
) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		request_failed.emit("Could not load your decks.")
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var list: Variant = (parsed as Dictionary).get("decks", [])
	decks_loaded.emit(list if typeof(list) == TYPE_ARRAY else [])

func save_deck(name: String, hero_id: String, card_ids: Array, deck_id: String = "") -> void:
	await _await_tree()
	var body := {"name": name, "heroId": hero_id, "cardIds": card_ids}
	var url := http_base + "/api/decks"
	var method := HTTPClient.METHOD_POST
	if deck_id != "":
		url += "/" + deck_id
		method = HTTPClient.METHOD_PUT
	var error := _deck_mutate_request.request(url, _headers(), method, JSON.stringify(body))
	if error != OK:
		deck_error.emit("Could not save that deck.")

func set_active_deck(deck_id: String) -> void:
	await _await_tree()
	var error := _deck_mutate_request.request(
		http_base + "/api/decks/" + deck_id + "/active", _headers(false), HTTPClient.METHOD_POST, ""
	)
	if error != OK:
		deck_error.emit("Could not set the active deck.")

func delete_deck(deck_id: String) -> void:
	await _await_tree()
	var error := _deck_mutate_request.request(
		http_base + "/api/decks/" + deck_id, _headers(false), HTTPClient.METHOD_DELETE, ""
	)
	if error != OK:
		deck_error.emit("Could not delete that deck.")

func _on_deck_mutated(
	result: int, response_code: int, _h: PackedStringArray, body: PackedByteArray
) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		deck_error.emit("Could not reach the server.")
		return
	# A delete returns no content.
	if response_code == 204:
		deck_saved.emit({})
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	var payload: Dictionary = parsed if typeof(parsed) == TYPE_DICTIONARY else {}
	if response_code != 200 and response_code != 201:
		deck_error.emit(str(payload.get("message", "Could not save that deck")))
		return
	var deck: Variant = payload.get("deck", {})
	deck_saved.emit(deck if typeof(deck) == TYPE_DICTIONARY else {})
