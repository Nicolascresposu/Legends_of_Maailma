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
## Emitted while a saved session is being checked, so the UI can say so.
signal restore_started()
## Emitted when a saved session turns out to be unusable; the UI falls back to
## the sign-in form. `silent` is true when nothing was saved to begin with.
signal restore_failed(message: String, silent: bool)
signal collection_loaded(cards: Array)
signal decks_loaded(decks: Array)
signal deck_saved(deck: Dictionary)
signal deck_error(message: String)
signal readiness_assessed(readiness: Dictionary)
signal request_failed(message: String)
## The player's Fragment balance changed, or was read for the first time.
signal fragments_changed(fragments: int)
## A craft or disenchant landed. `result` carries the new balance and count.
signal economy_result(operation: String, result: Dictionary)
## An economy request was refused, with the server's own code so the UI can
## explain the refusal rather than relay an English sentence.
signal economy_refused(code: String, message: String)
signal expansions_loaded(expansions: Array)
signal packs_loaded(packs: Array)
signal pack_opened(pack: Dictionary)
signal trades_loaded(trades: Array)
signal trade_updated(trade: Dictionary)
signal trade_history_loaded(history: Array)
## A trade request was refused. Kept apart from `economy_refused` so the trade
## screen and the collection screen each explain only their own refusals.
signal trade_refused(code: String, message: String)
signal friends_loaded(friends: Array)
## Friend requests addressed to this player that are still waiting on them.
signal friend_requests_loaded(requests: Array)
## A friend request was sent or answered; the lists should be re-read.
signal friendship_changed()
signal friendship_refused(code: String, message: String)
## The server created a match, or seated this player in one, with the deck
## they chose. `waiting` is true while a PvP match still needs an opponent.
signal match_started(match_id: String, player_id: String, waiting: bool)
## Starting or joining a match was refused — most often because the chosen
## deck is not ready, which the server explains in `message`.
signal match_refused(code: String, message: String)

## Resolved from the command line, the environment, or a saved address.
var http_base := ClientConfig.http_base()
var token := ""
var user: Dictionary = {}

## One HTTPRequest per concern: a single node handles one call at a time, so
## sharing would drop whichever request started second.
var _auth_request: HTTPRequest
var _collection_request: HTTPRequest
var _deck_request: HTTPRequest
var _deck_mutate_request: HTTPRequest
var _assess_request: HTTPRequest
var _me_request: HTTPRequest
var _economy_request: HTTPRequest
var _economy_mutate_request: HTTPRequest
var _expansion_request: HTTPRequest
var _pack_request: HTTPRequest
var _pack_open_request: HTTPRequest
var _trade_request: HTTPRequest
var _trade_mutate_request: HTTPRequest
var _trade_history_request: HTTPRequest
var _friends_request: HTTPRequest
var _friend_requests_request: HTTPRequest
var _friend_mutate_request: HTTPRequest
var _play_request: HTTPRequest

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
	if _me_request == null:
		_me_request = HTTPRequest.new()
		_me_request.request_completed.connect(_on_me_completed)
		add_child(_me_request)
	if _economy_request == null:
		_economy_request = HTTPRequest.new()
		_economy_request.request_completed.connect(_on_balance_completed)
		add_child(_economy_request)
	if _economy_mutate_request == null:
		_economy_mutate_request = HTTPRequest.new()
		_economy_mutate_request.request_completed.connect(_on_economy_mutated)
		add_child(_economy_mutate_request)
	if _expansion_request == null:
		_expansion_request = HTTPRequest.new()
		_expansion_request.request_completed.connect(_on_expansions_completed)
		add_child(_expansion_request)
	if _pack_request == null:
		_pack_request = HTTPRequest.new()
		_pack_request.request_completed.connect(_on_packs_completed)
		add_child(_pack_request)
	if _pack_open_request == null:
		_pack_open_request = HTTPRequest.new()
		_pack_open_request.request_completed.connect(_on_pack_opened)
		add_child(_pack_open_request)
	if _trade_request == null:
		_trade_request = HTTPRequest.new()
		_trade_request.request_completed.connect(_on_trades_completed)
		add_child(_trade_request)
	if _trade_mutate_request == null:
		_trade_mutate_request = HTTPRequest.new()
		_trade_mutate_request.request_completed.connect(_on_trade_mutated)
		add_child(_trade_mutate_request)
	if _trade_history_request == null:
		_trade_history_request = HTTPRequest.new()
		_trade_history_request.request_completed.connect(_on_trades_completed)
		add_child(_trade_history_request)
	if _friends_request == null:
		_friends_request = HTTPRequest.new()
		_friends_request.request_completed.connect(_on_friends_completed)
		add_child(_friends_request)
	if _friend_requests_request == null:
		_friend_requests_request = HTTPRequest.new()
		_friend_requests_request.request_completed.connect(_on_friend_requests_completed)
		add_child(_friend_requests_request)
	if _friend_mutate_request == null:
		_friend_mutate_request = HTTPRequest.new()
		_friend_mutate_request.request_completed.connect(_on_friendship_mutated)
		add_child(_friend_mutate_request)
	if _play_request == null:
		_play_request = HTTPRequest.new()
		_play_request.request_completed.connect(_on_play_completed)
		add_child(_play_request)

## True only once the server has confirmed who the token belongs to.
##
## A token being present is not enough: during a restore it is set before
## `/me` has replied, and treating that as signed in would show the collection
## to a session that may yet be rejected.
func is_signed_in() -> bool:
	return token != "" and not user.is_empty()

## True while a saved token is set but not yet confirmed.
func is_restoring() -> bool:
	return token != "" and user.is_empty()

## True while a request node is still waiting on its previous call.
func _busy(request: HTTPRequest) -> bool:
	return request.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED

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
	# Signing out must not leave a token that would resume on the next run.
	SessionStore.clear()
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
	# Remember the session so the next run starts signed in.
	SessionStore.save(
		token,
		str(user.get("displayName", "")),
		http_base,
		str(payload.get("expiresAt", ""))
	)
	signed_in.emit(user)

# --- Restoring a saved session ----------------------------------------------

## Tries to resume the session saved by a previous run.
##
## The token is only trusted once `/me` accepts it, so a revoked or expired
## session lands on the sign-in form rather than a half-working collection.
func restore_session() -> void:
	var saved := SessionStore.load_saved()
	if saved == null:
		restore_failed.emit("", true)
		return
	# The token belongs to the server that issued it.
	if saved.server != "":
		http_base = saved.server
	token = saved.token
	restore_started.emit()
	await _await_tree()
	var error := _me_request.request(http_base + "/api/auth/me", _headers(false))
	if error != OK:
		token = ""
		restore_failed.emit("Could not reach the server; sign in again.", false)

func _on_me_completed(
	result: int, response_code: int, _h: PackedStringArray, body: PackedByteArray
) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		# The server may simply be down, so the saved session is kept on disk
		# and only the in-memory token is dropped: the next launch tries again.
		token = ""
		restore_failed.emit("Could not reach the server; sign in again.", false)
		return
	if response_code != 200:
		# The server rejected it, so it will never work again.
		token = ""
		SessionStore.clear()
		restore_failed.emit("Your session has expired; sign in again.", false)
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	var who: Variant = (parsed as Dictionary).get("user", {}) if typeof(parsed) == TYPE_DICTIONARY else {}
	if typeof(who) != TYPE_DICTIONARY or str((who as Dictionary).get("id", "")) == "":
		token = ""
		SessionStore.clear()
		restore_failed.emit("Your session has expired; sign in again.", false)
		return
	user = who
	signed_in.emit(user)

# --- Collection -------------------------------------------------------------

## Set when a read was asked for while another was in flight. That reply may
## predate whatever prompted the second ask, so one more read follows it.
var _collection_stale := false

func fetch_collection() -> void:
	await _await_tree()
	if _busy(_collection_request):
		_collection_stale = true
		return
	var error := _collection_request.request(http_base + "/api/collection", _headers(false))
	if error != OK:
		request_failed.emit("Could not load your collection.")

func _on_collection_completed(
	result: int, response_code: int, _h: PackedStringArray, body: PackedByteArray
) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		_collection_stale = false
		request_failed.emit("Could not load your collection.")
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var cards: Variant = (parsed as Dictionary).get("cards", [])
	collection_loaded.emit(cards if typeof(cards) == TYPE_ARRAY else [])
	if _collection_stale:
		_collection_stale = false
		fetch_collection()

## Checks a card list without saving, so a builder can show readiness live.
##
## The format is part of the question: the same thirty cards can be an illegal
## Standard deck and a legal Wild one, and the server decides which. So is the
## hero, whose class decides which class cards the list may hold.
func assess(card_ids: Array, format: String = "STANDARD", hero_id: String = "") -> void:
	await _await_tree()
	var body := {"cardIds": card_ids, "format": format}
	if hero_id != "":
		body["heroId"] = hero_id
	# A deck builder asks after every edit. Only the latest list matters, so an
	# ask made mid-flight replaces any still waiting and is sent once the
	# current one returns — rather than being dropped, which left the verdict
	# on screen describing an earlier version of the deck.
	if _busy(_assess_request):
		_assess_waiting = body
		return
	_send_assess(body)

## The newest assessment asked for while another was in flight, or empty.
var _assess_waiting: Dictionary = {}

func _send_assess(body: Dictionary) -> void:
	var error := _assess_request.request(
		http_base + "/api/collection/assess",
		_headers(),
		HTTPClient.METHOD_POST,
		JSON.stringify(body)
	)
	if error != OK:
		request_failed.emit("Could not check that deck.")

func _on_assess_completed(
	result: int, response_code: int, _h: PackedStringArray, body: PackedByteArray
) -> void:
	# A newer list is waiting: this verdict is already out of date, so it is
	# not shown, and the newer one is asked about instead.
	if not _assess_waiting.is_empty():
		var next := _assess_waiting
		_assess_waiting = {}
		call_deferred("_send_assess", next)
		return
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var readiness: Variant = (parsed as Dictionary).get("readiness", {})
	readiness_assessed.emit(readiness if typeof(readiness) == TYPE_DICTIONARY else {})

# --- Decks ------------------------------------------------------------------

## Set when the deck list was asked for mid-read; one more read follows.
var _decks_stale := false

func fetch_decks() -> void:
	await _await_tree()
	# The collection screen and the match deck picker both ask for this list,
	# often in the same frame; a second ask is folded into a follow-up read
	# rather than dropped.
	if _busy(_deck_request):
		_decks_stale = true
		return
	var error := _deck_request.request(http_base + "/api/decks", _headers(false))
	if error != OK:
		request_failed.emit("Could not load your decks.")

func _on_decks_completed(
	result: int, response_code: int, _h: PackedStringArray, body: PackedByteArray
) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		_decks_stale = false
		request_failed.emit("Could not load your decks.")
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) == TYPE_DICTIONARY:
		var list: Variant = (parsed as Dictionary).get("decks", [])
		decks_loaded.emit(list if typeof(list) == TYPE_ARRAY else [])
	if _decks_stale:
		_decks_stale = false
		fetch_decks()

func save_deck(
	name: String,
	hero_id: String,
	card_ids: Array,
	deck_id: String = "",
	format: String = "STANDARD"
) -> void:
	await _await_tree()
	var body := {"name": name, "heroId": hero_id, "cardIds": card_ids, "format": format}
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

# --- Fragments, crafting and disenchanting ----------------------------------
#
# The client sends requests and shows what came back. It never decides whether
# a craft is allowed, what it costs, or what a player ends up owning: every one
# of those is the server's answer, and each reply carries the new balance so the
# UI never has to compute one for itself.

## What the last mutation was, so the reply can be reported as what it was.
var _pending_economy_operation := ""

## Set when the balance was asked for mid-read; one more read follows.
var _fragments_stale := false

func fetch_fragments() -> void:
	await _await_tree()
	if _busy(_economy_request):
		_fragments_stale = true
		return
	var error := _economy_request.request(http_base + "/api/economy", _headers(false))
	if error != OK:
		request_failed.emit("Could not load your Fragments.")

func _on_balance_completed(
	result: int, response_code: int, _h: PackedStringArray, body: PackedByteArray
) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		_fragments_stale = false
		request_failed.emit("Could not load your Fragments.")
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) == TYPE_DICTIONARY:
		fragments_changed.emit(int((parsed as Dictionary).get("fragments", 0)))
	if _fragments_stale:
		_fragments_stale = false
		fetch_fragments()

## A fresh id per attempt, so a retry after a lost reply cannot craft twice.
func _new_request_id(prefix: String) -> String:
	return "%s-%d-%d" % [prefix, Time.get_ticks_msec(), randi()]

func craft_card(card_id: String, quantity: int = 1, request_id: String = "") -> void:
	_queue_economy("CRAFT", "/api/economy/craft", {
		"cardId": card_id,
		"quantity": quantity,
		"requestId": request_id if request_id != "" else _new_request_id("craft"),
	})

func disenchant_card(card_id: String, quantity: int = 1, request_id: String = "") -> void:
	_queue_economy("DISENCHANT", "/api/economy/disenchant", {
		"cardId": card_id,
		"quantity": quantity,
		"requestId": request_id if request_id != "" else _new_request_id("dust"),
	})

## Disenchants every copy held above the playable limit. Always explicit: the
## client asks for this, it never happens because spares were noticed.
func disenchant_extras(request_id: String = "") -> void:
	_queue_economy("DISENCHANT_EXTRAS", "/api/economy/extras", {
		"requestId": request_id if request_id != "" else _new_request_id("extras"),
	})

## Economy mutations waiting their turn: {operation, path, body}.
##
## One request node carries one call at a time, and a second call on a busy
## node is dropped outright — which for a craft or a disenchant means a click
## that silently did nothing. So they queue, and run in the order asked.
var _economy_queue: Array = []
var _economy_in_flight := false

func _queue_economy(operation: String, path: String, body: Dictionary) -> void:
	await _await_tree()
	_economy_queue.append({"operation": operation, "path": path, "body": body})
	_pump_economy()

func _pump_economy() -> void:
	if _economy_in_flight or _economy_queue.is_empty():
		return
	var next: Dictionary = _economy_queue.pop_front()
	_pending_economy_operation = str(next["operation"])
	var error := _economy_mutate_request.request(
		http_base + str(next["path"]),
		_headers(),
		HTTPClient.METHOD_POST,
		JSON.stringify(next["body"])
	)
	if error != OK:
		_pending_economy_operation = ""
		economy_refused.emit("UNREACHABLE", "Could not reach the server.")
		call_deferred("_pump_economy")
		return
	_economy_in_flight = true

func _on_economy_mutated(
	result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray
) -> void:
	_economy_in_flight = false
	_handle_economy_reply(result, response_code, headers, body)
	# Deferred, so the node has fully settled from this reply before the next.
	call_deferred("_pump_economy")

func _handle_economy_reply(
	result: int, response_code: int, _h: PackedStringArray, body: PackedByteArray
) -> void:
	var operation := _pending_economy_operation
	_pending_economy_operation = ""
	if result != HTTPRequest.RESULT_SUCCESS:
		economy_refused.emit("UNREACHABLE", "Could not reach the server.")
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	var payload: Dictionary = parsed if typeof(parsed) == TYPE_DICTIONARY else {}
	if response_code != 200:
		# The server's own code travels with the message, so the UI can say
		# "this set cannot be crafted yet" rather than echoing a sentence.
		economy_refused.emit(
			str(payload.get("code", "ECONOMY_ERROR")),
			str(payload.get("message", "That could not be completed."))
		)
		return
	var outcome: Variant = payload.get("result", {})
	var dict: Dictionary = outcome if typeof(outcome) == TYPE_DICTIONARY else {}
	if dict.has("fragmentBalance"):
		fragments_changed.emit(int(dict["fragmentBalance"]))
	economy_result.emit(operation, dict)

# --- Expansions --------------------------------------------------------------

## The expansions a player may currently see, with their live policies.
##
## Unreleased sets never appear here: the server filters them out rather than
## trusting the client to hide them.
func fetch_expansions() -> void:
	await _await_tree()
	var error := _expansion_request.request(http_base + "/api/expansions", _headers(false))
	if error != OK:
		request_failed.emit("Could not load the expansions.")

func _on_expansions_completed(
	result: int, response_code: int, _h: PackedStringArray, body: PackedByteArray
) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		request_failed.emit("Could not load the expansions.")
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var list: Variant = (parsed as Dictionary).get("expansions", [])
	expansions_loaded.emit(list if typeof(list) == TYPE_ARRAY else [])

# --- Packs -------------------------------------------------------------------

func fetch_packs() -> void:
	await _await_tree()
	var error := _pack_request.request(http_base + "/api/packs", _headers(false))
	if error != OK:
		request_failed.emit("Could not load the available packs.")

func _on_packs_completed(
	result: int, response_code: int, _h: PackedStringArray, body: PackedByteArray
) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		request_failed.emit("Could not load the available packs.")
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var list: Variant = (parsed as Dictionary).get("packs", [])
	packs_loaded.emit(list if typeof(list) == TYPE_ARRAY else [])

func open_pack(pack_id: String, request_id: String = "") -> void:
	await _await_tree()
	var body := {"requestId": request_id if request_id != "" else _new_request_id("pack")}
	var error := _pack_open_request.request(
		http_base + "/api/packs/" + pack_id + "/open",
		_headers(),
		HTTPClient.METHOD_POST,
		JSON.stringify(body)
	)
	if error != OK:
		economy_refused.emit("UNREACHABLE", "Could not reach the server.")

func _on_pack_opened(
	result: int, response_code: int, _h: PackedStringArray, body: PackedByteArray
) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		economy_refused.emit("UNREACHABLE", "Could not reach the server.")
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	var payload: Dictionary = parsed if typeof(parsed) == TYPE_DICTIONARY else {}
	if response_code != 200:
		economy_refused.emit(
			str(payload.get("code", "PACK_ERROR")),
			str(payload.get("message", "That pack could not be opened."))
		)
		return
	var pack: Variant = payload.get("pack", {})
	pack_opened.emit(pack if typeof(pack) == TYPE_DICTIONARY else {})

# --- Trading -----------------------------------------------------------------
#
# Offers are assembled here and judged entirely on the server. The revision
# travels with every acceptance, so a client that accepted a stale offer is
# refused rather than being taken to have agreed to something it never showed.

## Safe to call on a timer: a poll that lands while the last is still in
## flight is skipped rather than reported as a failure.
func fetch_trades(status: String = "") -> void:
	await _await_tree()
	if _busy(_trade_request):
		return
	var url := http_base + "/api/trades"
	if status != "":
		url += "?status=" + status
	var error := _trade_request.request(url, _headers(false))
	if error != OK:
		request_failed.emit("Could not load your trades.")

func fetch_trade_history() -> void:
	await _await_tree()
	if _busy(_trade_history_request):
		return
	var error := _trade_history_request.request(
		http_base + "/api/trades/history", _headers(false)
	)
	if error != OK:
		request_failed.emit("Could not load your trade history.")

func _on_trades_completed(
	result: int, response_code: int, _h: PackedStringArray, body: PackedByteArray
) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		request_failed.emit("Could not load your trades.")
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var payload: Dictionary = parsed
	# Both listings share this handler, so the reply is told apart by what it
	# carries rather than by which call was made.
	if payload.has("history"):
		var history: Variant = payload["history"]
		trade_history_loaded.emit(history if typeof(history) == TYPE_ARRAY else [])
		return
	var list: Variant = payload.get("trades", [])
	trades_loaded.emit(list if typeof(list) == TYPE_ARRAY else [])

func create_trade(opponent_id: String) -> void:
	await _await_tree()
	var error := _trade_mutate_request.request(
		http_base + "/api/trades",
		_headers(),
		HTTPClient.METHOD_POST,
		JSON.stringify({"opponentId": opponent_id})
	)
	if error != OK:
		trade_refused.emit("UNREACHABLE", "Could not reach the server.")

## Replaces the player's own side of the offer. `cards` is a list of
## `{cardId, quantity}` dictionaries.
func update_trade_offer(trade_id: String, cards: Array) -> void:
	await _await_tree()
	var error := _trade_mutate_request.request(
		http_base + "/api/trades/" + trade_id + "/offer",
		_headers(),
		HTTPClient.METHOD_PUT,
		JSON.stringify({"cards": cards})
	)
	if error != OK:
		trade_refused.emit("UNREACHABLE", "Could not reach the server.")

## Accepts one specific revision, never simply "the trade". An offer edited
## since the client drew it is refused rather than silently agreed to.
func accept_trade(trade_id: String, revision: int) -> void:
	await _await_tree()
	var error := _trade_mutate_request.request(
		http_base + "/api/trades/" + trade_id + "/accept",
		_headers(),
		HTTPClient.METHOD_POST,
		JSON.stringify({"revision": revision})
	)
	if error != OK:
		trade_refused.emit("UNREACHABLE", "Could not reach the server.")

## Withdraws this player's acceptance while the trade is still open.
func unaccept_trade(trade_id: String) -> void:
	await _await_tree()
	var error := _trade_mutate_request.request(
		http_base + "/api/trades/" + trade_id + "/unaccept",
		_headers(false),
		HTTPClient.METHOD_POST,
		""
	)
	if error != OK:
		trade_refused.emit("UNREACHABLE", "Could not reach the server.")

func cancel_trade(trade_id: String) -> void:
	await _await_tree()
	var error := _trade_mutate_request.request(
		http_base + "/api/trades/" + trade_id + "/cancel",
		_headers(false),
		HTTPClient.METHOD_POST,
		""
	)
	if error != OK:
		trade_refused.emit("UNREACHABLE", "Could not reach the server.")

func _on_trade_mutated(
	result: int, response_code: int, _h: PackedStringArray, body: PackedByteArray
) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		trade_refused.emit("UNREACHABLE", "Could not reach the server.")
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	var payload: Dictionary = parsed if typeof(parsed) == TYPE_DICTIONARY else {}
	if response_code != 200 and response_code != 201:
		trade_refused.emit(
			str(payload.get("code", "TRADE_ERROR")),
			str(payload.get("message", "That trade could not be updated."))
		)
		return
	var trade: Variant = payload.get("trade", {})
	trade_updated.emit(trade if typeof(trade) == TYPE_DICTIONARY else {})

# --- Friends -----------------------------------------------------------------
#
# Only what trading needs: who a player's friends are, and a way to make more.
# Whether two players may become friends is, as ever, the server's call.

func fetch_friends() -> void:
	await _await_tree()
	if _busy(_friends_request):
		return
	var error := _friends_request.request(http_base + "/api/social/friends", _headers(false))
	if error != OK:
		request_failed.emit("Could not load your friends.")

func _on_friends_completed(
	result: int, response_code: int, _h: PackedStringArray, body: PackedByteArray
) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		request_failed.emit("Could not load your friends.")
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var list: Variant = (parsed as Dictionary).get("friends", [])
	friends_loaded.emit(list if typeof(list) == TYPE_ARRAY else [])

func fetch_friend_requests() -> void:
	await _await_tree()
	if _busy(_friend_requests_request):
		return
	var error := _friend_requests_request.request(
		http_base + "/api/social/friends/requests", _headers(false)
	)
	if error != OK:
		request_failed.emit("Could not load your friend requests.")

func _on_friend_requests_completed(
	result: int, response_code: int, _h: PackedStringArray, body: PackedByteArray
) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		request_failed.emit("Could not load your friend requests.")
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var list: Variant = (parsed as Dictionary).get("requests", [])
	friend_requests_loaded.emit(list if typeof(list) == TYPE_ARRAY else [])

## Friends are found by display name, the one thing a player can tell another.
func request_friend(display_name: String) -> void:
	await _await_tree()
	var error := _friend_mutate_request.request(
		http_base + "/api/social/friends/requests",
		_headers(),
		HTTPClient.METHOD_POST,
		JSON.stringify({"displayName": display_name})
	)
	if error != OK:
		friendship_refused.emit("UNREACHABLE", "Could not reach the server.")

func respond_to_friend_request(friendship_id: String, accept: bool) -> void:
	await _await_tree()
	var error := _friend_mutate_request.request(
		http_base + "/api/social/friends/requests/" + friendship_id + "/respond",
		_headers(),
		HTTPClient.METHOD_POST,
		JSON.stringify({"accept": accept})
	)
	if error != OK:
		friendship_refused.emit("UNREACHABLE", "Could not reach the server.")

func _on_friendship_mutated(
	result: int, response_code: int, _h: PackedStringArray, body: PackedByteArray
) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		friendship_refused.emit("UNREACHABLE", "Could not reach the server.")
		return
	if response_code != 200 and response_code != 201:
		var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
		var payload: Dictionary = parsed if typeof(parsed) == TYPE_DICTIONARY else {}
		friendship_refused.emit(
			str(payload.get("code", "FRIENDSHIP_ERROR")),
			str(payload.get("message", "That could not be completed."))
		)
		return
	friendship_changed.emit()

# --- Playing -----------------------------------------------------------------

## Starts a match in a scenario, playing one of this player's own decks.
##
## Against an AI the match begins at once; a PvP match waits with its second
## seat open for another player to join.
func start_match(scenario_id: String, deck_id: String) -> void:
	await _await_tree()
	if _busy(_play_request):
		match_refused.emit("BUSY", "Already starting a match.")
		return
	var error := _play_request.request(
		http_base + "/api/play",
		_headers(),
		HTTPClient.METHOD_POST,
		JSON.stringify({"scenarioId": scenario_id, "deckId": deck_id})
	)
	if error != OK:
		match_refused.emit("UNREACHABLE", "Could not reach the server.")

## Takes the open seat in someone's match with one of this player's decks.
##
## `deck_id` may be left empty to ask first: a player already seated there is
## simply let back in, and a player who needs a deck is told `DECK_REQUIRED`.
func join_open_match(match_id: String, deck_id: String = "") -> void:
	await _await_tree()
	if _busy(_play_request):
		match_refused.emit("BUSY", "Already joining a match.")
		return
	var body := {}
	if deck_id != "":
		body["deckId"] = deck_id
	var error := _play_request.request(
		http_base + "/api/play/%s/join" % match_id.uri_encode(),
		_headers(),
		HTTPClient.METHOD_POST,
		JSON.stringify(body)
	)
	if error != OK:
		match_refused.emit("UNREACHABLE", "Could not reach the server.")

func _on_play_completed(
	result: int, response_code: int, _h: PackedStringArray, body: PackedByteArray
) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		match_refused.emit("UNREACHABLE", "Could not reach the server.")
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	var payload: Dictionary = parsed if typeof(parsed) == TYPE_DICTIONARY else {}
	if response_code != 200 and response_code != 201:
		match_refused.emit(
			str(payload.get("code", "MATCH_REFUSED")),
			str(payload.get("message", "The match could not be started."))
		)
		return
	match_started.emit(
		str(payload.get("matchId", "")),
		str(payload.get("playerId", "")),
		bool(payload.get("waitingForOpponent", false))
	)
