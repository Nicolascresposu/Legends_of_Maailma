extends SceneTree

## Drives the trade screen against a live server with two accounts.
##
## One player uses the real screen; the friend is a second AccountClient
## driven directly. Between them they become friends, open a trade, build both
## sides, and complete it — with an acceptance invalidated along the way by
## the friend changing their offer.
##
## Whether a trade *should* execute is the server's call and is covered by
## tests/trading.test.ts. What this checks is that the screen shows what the
## server said and asks it the right questions.
##
##   godot --path apps/godot-client --script src/trade_test.gd

var main: Control
var screen: TradeScreen
var friend: AccountClient
var friend_trades: Array = []
var failures: Array[String] = []

func _init() -> void:
	await process_frame
	# A session saved by an earlier run would be restored alongside the new
	# account, and its friends and trades would muddle every check below.
	SessionStore.clear()
	main = (load("res://main.tscn") as PackedScene).instantiate()
	get_root().add_child(main)
	await process_frame
	await process_frame
	screen = main.trade_screen

	var tag := "tr%d" % (Time.get_ticks_msec() % 100000)
	var friend_name := tag + "f"
	print("== trade screen test (%s) ==" % tag)

	# --- Two accounts: this client's, and a friend's. ---
	var collection: CollectionScreen = main.collection_screen
	collection._email_input.text = "%s@example.test" % tag
	collection._name_input.text = tag
	collection._password_input.text = "a-sufficiently-long-password"
	collection._do_register()

	friend = AccountClient.new()
	friend.http_base = main.accounts.http_base
	get_root().add_child(friend)
	friend.trades_loaded.connect(func(list: Array) -> void: friend_trades = list)
	friend.register(
		"%s@example.test" % friend_name, friend_name, "a-sufficiently-long-password"
	)
	await _wait_until(func() -> bool:
		return main.accounts.is_signed_in() and friend.is_signed_in(), 8.0)
	_check("both players signed in", main.accounts.is_signed_in() and friend.is_signed_in())
	if not (main.accounts.is_signed_in() and friend.is_signed_in()):
		_finish()
		return

	# --- The Trade button leads to the trade screen. ---
	collection.trade_requested.emit()
	await process_frame
	_check("the trade screen opens", screen.visible and not collection.visible)
	_check("with nothing selected, the screen explains itself",
		screen._detail_title.text == "No trade selected")

	# --- A friend request arrives and is accepted from the screen. ---
	friend.request_friend(tag)
	await _wait_until(func() -> bool: return not screen.friend_requests.is_empty(), 10.0)
	_check("an incoming friend request is listed", not screen.friend_requests.is_empty())
	var accept_request := _button_in(screen._request_list, "Accept")
	_check("the request can be accepted", accept_request != null)
	if accept_request == null:
		_finish()
		return
	accept_request.pressed.emit()
	await _wait_until(func() -> bool: return _friend_named(friend_name), 10.0)
	_check("the new friend is listed", _friend_named(friend_name))

	# --- Opening a trade selects it. ---
	var start := _button_in(_friend_row(friend_name), "Trade")
	_check("a friend can be traded with", start != null)
	if start == null:
		_finish()
		return
	start.pressed.emit()
	await _wait_until(func() -> bool: return screen.selected_trade_id != "", 8.0)
	var trade_id := screen.selected_trade_id
	_check("the new trade is selected", trade_id != "")
	_check("it is titled after the friend",
		screen._detail_title.text == "Trade with %s" % friend_name)
	_check("the friend now leads back to that trade",
		_button_in(_friend_row(friend_name), "Open trade") != null)

	# --- Build and send this side of the offer. ---
	await _wait_until(func() -> bool: return not screen.collection.is_empty(), 8.0)
	var given := _tradeable_owned(screen.collection, "")
	var received := _tradeable_owned(screen.collection, given)
	_check("there are two different cards to trade", given != "" and received != "")
	if given == "" or received == "":
		_finish()
		return
	var given_before := screen._owned_count(given)
	var received_before := screen._owned_count(received)

	screen._add_card(given)
	_check("an edited offer is unsent", screen.draft_dirty)
	_check("an unsent offer cannot be accepted", screen._accept_button.disabled)
	screen._remove_card(given)
	_check("undoing the edit leaves nothing unsent", not screen.draft_dirty)
	screen._add_card(given)
	screen._send_offer()
	await _wait_until(func() -> bool:
		return _copies_of(screen._my_offer(screen._selected_trade()), given) == 1, 8.0)
	_check("the sent offer is what the server holds",
		_copies_of(screen._my_offer(screen._selected_trade()), given) == 1)
	_check("a sent offer is no longer unsent", not screen.draft_dirty)

	# --- Accept, then watch the friend's edit clear that acceptance. ---
	screen._accept()
	await _wait_until(func() -> bool:
		return bool(screen._my_offer(screen._selected_trade()).get("accepted", false)), 8.0)
	_check("this player's acceptance is recorded",
		bool(screen._my_offer(screen._selected_trade()).get("accepted", false)))
	_check("an accepted trade offers to withdraw", screen._unaccept_button.visible)

	friend.update_trade_offer(trade_id, [{"cardId": received, "quantity": 1}])
	await _wait_until(func() -> bool:
		var trade := screen._selected_trade()
		return _copies_of(screen._their_offer(trade), received) == 1 \
			and not bool(screen._my_offer(trade).get("accepted", false)), 12.0)
	_check("the friend's offer appears without a manual refresh",
		_copies_of(screen._their_offer(screen._selected_trade()), received) == 1)
	_check("the friend's edit cleared this player's acceptance",
		not bool(screen._my_offer(screen._selected_trade()).get("accepted", false)))

	# --- The friend accepts the new revision; the screen says whose turn it is. ---
	friend.fetch_trades()
	await _wait_until(func() -> bool: return not _trade_in(friend_trades, trade_id).is_empty(), 8.0)
	var revision := int(_trade_in(friend_trades, trade_id).get("revision", -1))
	friend.accept_trade(trade_id, revision)
	await _wait_until(func() -> bool:
		return bool(screen._their_offer(screen._selected_trade()).get("accepted", false)), 12.0)
	_check("the friend's acceptance is shown",
		bool(screen._their_offer(screen._selected_trade()).get("accepted", false)))
	_check("the trade list says it is this player's turn",
		_trade_row_text().contains("your turn"))

	# --- Accepting the same revision completes the trade. ---
	screen._accept()
	await _wait_until(func() -> bool:
		return str(screen._selected_trade().get("status", "")) == "ACCEPTED", 8.0)
	_check("the trade completes", str(screen._selected_trade().get("status", "")) == "ACCEPTED")
	_check("completion is announced", screen._status.text.contains("complete"))
	await _wait_until(func() -> bool:
		return screen._owned_count(received) == received_before + 1, 8.0)
	_check("the given card left the collection", screen._owned_count(given) == given_before - 1)
	_check("the received card arrived", screen._owned_count(received) == received_before + 1)
	_check("a completed trade cannot be edited", not screen._accept_button.visible
		and not screen._send_button.visible and not screen._cards_scroll.visible)
	await _wait_until(func() -> bool:
		return _button_in(_friend_row(friend_name), "Trade") != null, 8.0)
	_check("the friend can be traded with again",
		_button_in(_friend_row(friend_name), "Trade") != null)

	# --- Back to the collection. ---
	screen.closed.emit()
	await process_frame
	_check("leaving returns to the collection", collection.visible and not screen.visible)
	_check("the closed screen stops polling", screen._poll.is_stopped())

	_finish()

## Waits for `condition` to hold, frame by frame, for at most `seconds`.
func _wait_until(condition: Callable, seconds: float) -> void:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if condition.call():
			return
		await process_frame

## The row in the friend list for `display_name`, or null.
func _friend_row(display_name: String) -> Node:
	for row in screen._friend_list.get_children():
		if row.is_queued_for_deletion():
			continue
		for child in row.get_children():
			if child is Label and (child as Label).text == display_name:
				return row
	return null

func _button_in(node: Node, text: String) -> Button:
	if node == null:
		return null
	for child in node.get_children():
		if child is Button and (child as Button).text == text and not child.is_queued_for_deletion():
			return child
		var found := _button_in(child, text)
		if found != null:
			return found
	return null

func _friend_named(display_name: String) -> bool:
	for entry in screen.friends:
		if str((entry as Dictionary).get("displayName", "")) == display_name:
			return true
	return false

func _tradeable_owned(cards: Array, other_than: String) -> String:
	for entry in cards:
		var card: Dictionary = entry
		var card_id := str(card.get("cardId", ""))
		if card_id != other_than and int(card.get("owned", 0)) > 0 and bool(card.get("tradeable", false)):
			return card_id
	return ""

func _copies_of(offer: Dictionary, card_id: String) -> int:
	for entry in offer.get("cards", []):
		if str((entry as Dictionary).get("cardId", "")) == card_id:
			return int((entry as Dictionary).get("quantity", 0))
	return 0

func _trade_in(list: Array, trade_id: String) -> Dictionary:
	for entry in list:
		if str((entry as Dictionary).get("id", "")) == trade_id:
			return entry
	return {}

func _trade_row_text() -> String:
	for child in screen._trade_list.get_children():
		if child is Button and not child.is_queued_for_deletion():
			return (child as Button).text
	return ""

func _finish() -> void:
	# Leave no session behind: the next test would resume this account, whose
	# collection the trade has just changed.
	SessionStore.clear()
	print("\n%d failure(s)" % failures.size())
	for f in failures:
		print("  FAIL: ", f)
	print("RESULT: ", "PASS" if failures.is_empty() else "FAIL")
	quit(0 if failures.is_empty() else 1)

func _check(label: String, condition: bool) -> void:
	print("  [%s] %s" % ["ok" if condition else "XX", label])
	if not condition:
		failures.append(label)
