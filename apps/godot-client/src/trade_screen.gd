extends Control
class_name TradeScreen

## Trading cards with friends.
##
## The server decides everything that matters: whether a card may be traded,
## whether both players agreed to the same offer, and whether each still owns
## what they promised. This screen lists friends and trades, lets a player put
## together their own side of an offer, and accepts exactly the revision it is
## showing — never simply "the trade".

signal closed()

## How often an open screen re-reads its trades. Nothing is pushed for trades,
## so a friend's edits and acceptances are only seen by asking again.
const POLL_SECONDS := 4.0

const COLOR_ERROR := Color(0.88, 0.42, 0.45)
const COLOR_GOOD := Color(0.45, 0.85, 0.55)

var accounts: AccountClient
var library: CardLibrary

var friends: Array = []
var friend_requests: Array = []
## Every trade the player is part of, newest first, as the server last said.
var trades: Array = []
var collection: Array = []
## The trade being looked at. Its contents are always read from `trades`.
var selected_trade_id := ""
## Card id -> copies on the player's own side, as being edited. It starts as
## what the server holds and is only sent when the player asks.
var draft: Dictionary = {}
## True while `draft` differs from what the server holds for the player's side.
var draft_dirty := false
## Trade id -> status when last seen, so a trade finishing is noticed.
var _last_status: Dictionary = {}

var _poll: Timer
var _status: Label
var _friend_name_input: LineEdit
var _request_list: VBoxContainer
var _friend_list: VBoxContainer
var _trade_list: VBoxContainer
var _detail_title: Label
var _detail_state: RichTextLabel
var _offer_row: HBoxContainer
var _my_offer_title: Label
var _my_offer_list: VBoxContainer
var _their_offer_title: Label
var _their_offer_list: VBoxContainer
var _action_row: HBoxContainer
var _send_button: Button
var _revert_button: Button
var _accept_button: Button
var _unaccept_button: Button
var _cancel_button: Button
var _cards_title: Label
var _cards_scroll: ScrollContainer
var _card_list: VBoxContainer

func setup(account_client: AccountClient, card_library: CardLibrary) -> void:
	accounts = account_client
	library = card_library
	accounts.signed_out.connect(_on_signed_out)
	accounts.collection_loaded.connect(_on_collection_loaded)
	accounts.trades_loaded.connect(_on_trades_loaded)
	accounts.trade_updated.connect(_on_trade_updated)
	accounts.trade_refused.connect(_on_trade_refused)
	accounts.friends_loaded.connect(_on_friends_loaded)
	accounts.friend_requests_loaded.connect(_on_friend_requests_loaded)
	accounts.friendship_changed.connect(_on_friendship_changed)
	accounts.friendship_refused.connect(_on_friendship_refused)
	accounts.request_failed.connect(_on_request_failed)
	_build()
	visibility_changed.connect(_on_visibility_changed)

func _build() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	margin.add_child(root)
	root.add_child(_build_header())

	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 12)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(body)
	body.add_child(_build_sidebar())
	body.add_child(_build_detail())

	_poll = Timer.new()
	_poll.wait_time = POLL_SECONDS
	_poll.timeout.connect(_refresh_lists)
	add_child(_poll)
	_render_all()

func _build_header() -> Control:
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	var title := Label.new()
	title.text = "Trading"
	title.add_theme_font_size_override("font_size", 20)
	header.add_child(title)

	_status = Label.new()
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	header.add_child(_status)

	var refresh := Button.new()
	refresh.text = "Refresh"
	refresh.pressed.connect(refresh_all)
	header.add_child(refresh)

	var back := Button.new()
	back.text = "← Collection"
	back.pressed.connect(func() -> void: closed.emit())
	header.add_child(back)
	return header

func _build_sidebar() -> Control:
	var left := VBoxContainer.new()
	left.custom_minimum_size.x = 320
	left.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 6)

	left.add_child(_title("Friends", 16))
	var add_row := HBoxContainer.new()
	add_row.add_theme_constant_override("separation", 6)
	left.add_child(add_row)
	_friend_name_input = LineEdit.new()
	_friend_name_input.placeholder_text = "Friend's display name"
	_friend_name_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_friend_name_input.text_submitted.connect(func(_value: String) -> void: _send_friend_request())
	add_row.add_child(_friend_name_input)
	var add := Button.new()
	add.text = "Add friend"
	add.pressed.connect(_send_friend_request)
	add_row.add_child(add)

	_request_list = VBoxContainer.new()
	_request_list.add_theme_constant_override("separation", 3)
	left.add_child(_request_list)

	var friend_scroll := ScrollContainer.new()
	friend_scroll.custom_minimum_size.y = 170
	left.add_child(friend_scroll)
	_friend_list = VBoxContainer.new()
	_friend_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_friend_list.add_theme_constant_override("separation", 3)
	friend_scroll.add_child(_friend_list)

	left.add_child(_title("Trades", 16))
	var trade_scroll := ScrollContainer.new()
	trade_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.add_child(trade_scroll)
	_trade_list = VBoxContainer.new()
	_trade_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_trade_list.add_theme_constant_override("separation", 3)
	trade_scroll.add_child(_trade_list)
	return left

func _build_detail() -> Control:
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 6)

	_detail_title = _title("", 16)
	right.add_child(_detail_title)
	_detail_state = RichTextLabel.new()
	_detail_state.bbcode_enabled = true
	_detail_state.fit_content = true
	right.add_child(_detail_state)

	# The two sides sit next to each other so the exchange reads at a glance.
	_offer_row = HBoxContainer.new()
	_offer_row.add_theme_constant_override("separation", 12)
	right.add_child(_offer_row)
	var mine := _offer_column()
	_my_offer_title = mine[0]
	_my_offer_list = mine[1]
	var theirs := _offer_column()
	_their_offer_title = theirs[0]
	_their_offer_list = theirs[1]

	_action_row = HBoxContainer.new()
	_action_row.add_theme_constant_override("separation", 6)
	right.add_child(_action_row)
	_send_button = _action("Send offer", _send_offer)
	_revert_button = _action("Revert", _revert_draft)
	_revert_button.tooltip_text = "Discard your unsent changes"
	_accept_button = _action("Accept", _accept)
	_unaccept_button = _action("Withdraw acceptance", _unaccept)
	_cancel_button = _action("Cancel trade", _cancel)
	_cancel_button.tooltip_text = "End this trade. Nothing moves."

	_cards_title = _title("Your cards", 14)
	right.add_child(_cards_title)
	_cards_scroll = ScrollContainer.new()
	_cards_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(_cards_scroll)
	_card_list = VBoxContainer.new()
	_card_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_card_list.add_theme_constant_override("separation", 3)
	_cards_scroll.add_child(_card_list)
	return right

## Returns `[title, list]` for one side of the offer.
func _offer_column() -> Array:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.15, 0.16, 0.20)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(8)
	panel.add_theme_stylebox_override("panel", style)
	_offer_row.add_child(panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 3)
	column.custom_minimum_size.y = 150
	panel.add_child(column)
	var title := _title("", 14)
	column.add_child(title)
	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 3)
	column.add_child(list)
	return [title, list]

func _action(text: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.pressed.connect(callback)
	_action_row.add_child(button)
	return button

func _title(text: String, font_size: int) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	return label

# --- Refreshing --------------------------------------------------------------

## Re-reads everything this screen shows.
func refresh_all() -> void:
	if not accounts.is_signed_in():
		return
	_refresh_lists()
	accounts.fetch_collection()

func _refresh_lists() -> void:
	if not accounts.is_signed_in():
		return
	accounts.fetch_trades()
	accounts.fetch_friends()
	accounts.fetch_friend_requests()

## Polls only while the screen is open.
func _on_visibility_changed() -> void:
	if visible and accounts.is_signed_in():
		refresh_all()
		_poll.start()
	else:
		_poll.stop()

func _on_signed_out() -> void:
	_poll.stop()
	friends = []
	friend_requests = []
	trades = []
	collection = []
	selected_trade_id = ""
	draft.clear()
	draft_dirty = false
	_last_status.clear()
	_set_status("")
	_render_all()

func _on_collection_loaded(cards: Array) -> void:
	collection = cards
	_render_cards()

func _on_request_failed(message: String) -> void:
	if visible:
		_set_status(message, true)

# --- Friends -----------------------------------------------------------------

func _on_friends_loaded(list: Array) -> void:
	friends = list
	_render_friends()

func _on_friend_requests_loaded(list: Array) -> void:
	friend_requests = list
	_render_requests()

func _send_friend_request() -> void:
	var name := _friend_name_input.text.strip_edges()
	if name.is_empty():
		_set_status("Type a display name first.", true)
		return
	_set_status("Sending a friend request to %s…" % name)
	accounts.request_friend(name)

func _on_friendship_changed() -> void:
	_friend_name_input.text = ""
	_set_status("Friends updated.")
	accounts.fetch_friends()
	accounts.fetch_friend_requests()

func _on_friendship_refused(code: String, message: String) -> void:
	var explanation := message
	match code:
		"USER_NOT_FOUND":
			explanation = "No player goes by that name."
		"SELF_FRIENDSHIP":
			explanation = "You cannot add yourself."
		"ALREADY_FRIENDS":
			explanation = "You are already friends."
		"REQUEST_PENDING":
			explanation = "That request is already waiting for an answer."
		"REQUEST_REJECTED":
			explanation = "That request could not be sent."
		"UNREACHABLE":
			explanation = "Could not reach the server."
	_set_status(explanation, true)

func _render_requests() -> void:
	_clear(_request_list)
	for entry in friend_requests:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var request: Dictionary = entry
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 5)
		var label := Label.new()
		label.text = "%s wants to be friends" % str(request.get("fromDisplayName", "Someone"))
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.add_theme_color_override("font_color", Color(0.95, 0.80, 0.45))
		row.add_child(label)
		var friendship_id := str(request.get("friendshipId", ""))
		var accept := Button.new()
		accept.text = "Accept"
		accept.pressed.connect(
			func() -> void: accounts.respond_to_friend_request(friendship_id, true)
		)
		row.add_child(accept)
		var decline := Button.new()
		decline.text = "Decline"
		decline.pressed.connect(
			func() -> void: accounts.respond_to_friend_request(friendship_id, false)
		)
		row.add_child(decline)
		_request_list.add_child(row)

func _render_friends() -> void:
	_clear(_friend_list)
	if friends.is_empty():
		var empty := Label.new()
		empty.text = "(no friends yet — add one by display name)"
		empty.add_theme_font_size_override("font_size", 11)
		_friend_list.add_child(empty)
		return
	for entry in friends:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var friend: Dictionary = entry
		var friend_id := str(friend.get("userId", ""))
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 5)
		var label := Label.new()
		label.text = str(friend.get("displayName", friend_id))
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(label)

		# One open trade per friend is plenty to keep track of, so a friend
		# already being traded with leads back to that trade.
		var button := Button.new()
		var existing := _open_trade_with(friend_id)
		if existing.is_empty():
			button.text = "Trade"
			button.pressed.connect(_start_trade.bind(friend_id, label.text))
		else:
			button.text = "Open trade"
			var trade_id := str(existing.get("id", ""))
			button.pressed.connect(func() -> void: _select_trade(trade_id))
		row.add_child(button)
		_friend_list.add_child(row)

func _start_trade(friend_id: String, display_name: String) -> void:
	_set_status("Opening a trade with %s…" % display_name)
	accounts.create_trade(friend_id)

# --- Trades ------------------------------------------------------------------

func _on_trades_loaded(list: Array) -> void:
	# A poll sent just before a mutation can land just after it. Keep whichever
	# copy of each trade is newer, so the screen never steps back a revision.
	var held: Dictionary = {}
	for entry in trades:
		if typeof(entry) == TYPE_DICTIONARY:
			held[str(entry.get("id", ""))] = entry
	var merged: Array = []
	for entry in list:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var mine: Variant = held.get(str(entry.get("id", "")))
		var newer := mine != null \
			and str(mine.get("updatedAt", "")) > str(entry.get("updatedAt", ""))
		merged.append(mine if newer else entry)
	trades = merged
	_notice_completions()
	_sync_draft()
	_render_all()

## A trade just landed from a mutation: fold it in and look at it.
func _on_trade_updated(trade: Dictionary) -> void:
	if trade.is_empty():
		return
	var trade_id := str(trade.get("id", ""))
	var replaced := false
	for i in range(trades.size()):
		if typeof(trades[i]) == TYPE_DICTIONARY and str(trades[i].get("id", "")) == trade_id:
			trades[i] = trade
			replaced = true
			break
	if not replaced:
		trades.push_front(trade)
	if selected_trade_id != trade_id:
		selected_trade_id = trade_id
		draft_dirty = false
	# An offer that was just sent is now the server's, and the draft follows it
	# again. One refused, or edited further meanwhile, stays unsent.
	draft_dirty = _draft_differs()
	if str(trade.get("status", "")) == "OPEN":
		_set_status("Trade updated.")
	_notice_completions()
	_sync_draft()
	_render_all()

## Reports trades that finished since they were last seen, and re-reads the
## collection when cards may have moved.
func _notice_completions() -> void:
	var moved := false
	for entry in trades:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var trade: Dictionary = entry
		var trade_id := str(trade.get("id", ""))
		var status := str(trade.get("status", ""))
		var before := str(_last_status.get(trade_id, ""))
		_last_status[trade_id] = status
		# Only leaving OPEN is news; a trade first seen already closed is history.
		if before != "OPEN" or status == "OPEN":
			continue
		var other := _other_name(trade)
		match status:
			"ACCEPTED":
				moved = true
				_set_status("Trade with %s complete." % other)
			"FAILED":
				var reason := _explain(
					str(trade.get("failureCode", "")), str(trade.get("failureMessage", ""))
				)
				_set_status("Trade with %s failed: %s" % [other, reason], true)
			"CANCELLED":
				_set_status("Trade with %s was cancelled. Nothing moved." % other)
	if moved:
		accounts.fetch_collection()

func _on_trade_refused(code: String, message: String) -> void:
	_set_status(_explain(code, message), true)
	# A refusal may mean the offer or a policy moved under us: re-read both.
	accounts.fetch_trades()
	accounts.fetch_collection()

## The client's own words for a refusal, keyed on the server's code.
func _explain(code: String, message: String) -> String:
	match code:
		"CARD_NOT_TRADEABLE":
			return "Those cards cannot be traded right now."
		"EXPANSION_NOT_RELEASED":
			return "That card is not available."
		"TRADE_REVISION_CHANGED":
			return "The offer changed. Review it and accept again."
		"INSUFFICIENT_CARD_QUANTITY":
			return "Someone no longer owns every card they offered."
		"TRADE_NOT_OPEN":
			return "That trade is already closed."
		"TRADE_NOT_FOUND":
			return "That trade no longer exists."
		"SELF_TRADE":
			return "You cannot trade with yourself."
		"USER_NOT_FOUND":
			return "That player no longer exists."
		"INVALID_OFFER", "INVALID_QUANTITY":
			return "That offer is not valid: %s" % message
		"UNREACHABLE":
			return "Could not reach the server."
	return message if message != "" else "That trade could not be updated."

func _render_trades() -> void:
	_clear(_trade_list)
	if trades.is_empty():
		var empty := Label.new()
		empty.text = "(no trades yet)"
		empty.add_theme_font_size_override("font_size", 11)
		_trade_list.add_child(empty)
		return
	# Open trades first: they are the ones that need something from someone.
	var open: Array = []
	var closed: Array = []
	for entry in trades:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		if str(entry.get("status", "")) == "OPEN":
			open.append(entry)
		else:
			closed.append(entry)
	for trade in open + closed:
		_trade_list.add_child(_trade_row(trade))

func _trade_row(trade: Dictionary) -> Control:
	var trade_id := str(trade.get("id", ""))
	var button := Button.new()
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.toggle_mode = true
	button.button_pressed = trade_id == selected_trade_id
	var mine := _my_offer(trade)
	var theirs := _their_offer(trade)
	var status := str(trade.get("status", ""))
	var summary := "%s — %s  (%d ⇄ %d)" % [
		_other_name(trade),
		_status_word(status),
		_copies(mine.get("cards", [])),
		_copies(theirs.get("cards", [])),
	]
	if status == "OPEN":
		if bool(theirs.get("accepted", false)) and not bool(mine.get("accepted", false)):
			summary += "  • your turn"
		elif bool(mine.get("accepted", false)):
			summary += "  • waiting"
	button.text = summary
	if status != "OPEN":
		button.modulate = Color(0.75, 0.75, 0.80)
	button.pressed.connect(func() -> void: _select_trade(trade_id))
	return button

func _status_word(status: String) -> String:
	match status:
		"OPEN":
			return "open"
		"ACCEPTED":
			return "completed"
		"CANCELLED":
			return "cancelled"
		"FAILED":
			return "failed"
	return status.to_lower()

func _select_trade(trade_id: String) -> void:
	if trade_id == selected_trade_id:
		_render_trades()  # Keep the toggle showing the selection.
		return
	selected_trade_id = trade_id
	draft_dirty = false
	_sync_draft()
	_render_all()

# --- The selected trade ------------------------------------------------------

## Resets the draft to the server's copy of the player's side, unless the
## player is part-way through editing it.
func _sync_draft() -> void:
	var trade := _selected_trade()
	# A closed trade can no longer be edited, so unsent changes to it are moot.
	if trade.is_empty() or str(trade.get("status", "")) != "OPEN":
		draft_dirty = false
	if draft_dirty:
		return
	draft = _server_offer(trade)

## The player's side of `trade` as the server holds it, as card id -> copies.
func _server_offer(trade: Dictionary) -> Dictionary:
	var offer: Dictionary = {}
	if trade.is_empty():
		return offer
	var cards: Variant = _my_offer(trade).get("cards", [])
	if typeof(cards) != TYPE_ARRAY:
		return offer
	for entry in (cards as Array):
		if typeof(entry) == TYPE_DICTIONARY:
			offer[str(entry.get("cardId", ""))] = int(entry.get("quantity", 0))
	return offer

func _draft_differs() -> bool:
	var trade := _selected_trade()
	if trade.is_empty():
		return false
	return draft != _server_offer(trade)

func _render_detail() -> void:
	var trade := _selected_trade()
	var has_trade := not trade.is_empty()
	_offer_row.visible = has_trade
	_action_row.visible = has_trade
	_cards_title.visible = has_trade
	_cards_scroll.visible = has_trade
	if not has_trade:
		_detail_title.text = "No trade selected"
		_detail_state.text = (
			"Pick a friend and press [b]Trade[/b] to start one, or choose a trade from the list."
			+ "\n\nBoth players build their side of the offer, and cards only move once both"
			+ " accept the same version of it."
		)
		return

	var status := str(trade.get("status", ""))
	var is_open := status == "OPEN"
	var mine := _my_offer(trade)
	var theirs := _their_offer(trade)
	var other := _other_name(trade)
	var i_accepted := bool(mine.get("accepted", false))
	var they_accepted := bool(theirs.get("accepted", false))

	_detail_title.text = "Trade with %s" % other
	var lines: Array[String] = []
	match status:
		"OPEN":
			lines.append("Offer version %d." % int(trade.get("revision", 0)))
			lines.append(_accept_line("You", i_accepted) + "   " + _accept_line(other, they_accepted))
			if draft_dirty:
				lines.append("[color=#e8a06a]You have unsent changes. Send them before accepting.[/color]")
			elif they_accepted and not i_accepted:
				lines.append("%s has accepted this offer. Accept it to complete the trade." % other)
			lines.append(
				"[font_size=11]Changing either side clears both acceptances."
				+ " Offered cards are not held back; the trade fails if one has gone by then.[/font_size]"
			)
		"ACCEPTED":
			lines.append("[color=#7fd88c]Completed.[/color] The cards below have changed hands.")
		"CANCELLED":
			lines.append("Cancelled. Nothing moved.")
		"FAILED":
			var reason := _explain(
				str(trade.get("failureCode", "")), str(trade.get("failureMessage", ""))
			)
			lines.append("[color=#e06c75]Failed: %s[/color]  Nothing moved." % reason)
	_detail_state.text = "\n".join(lines)

	_my_offer_title.text = "You give" + ("  ✓" if i_accepted else "")
	_their_offer_title.text = "%s gives" % other + ("  ✓" if they_accepted else "")
	_render_my_offer(is_open)
	_render_offer_list(_their_offer_list, theirs.get("cards", []))

	var both_empty := draft.is_empty() and _copies(theirs.get("cards", [])) == 0
	_send_button.visible = is_open
	_send_button.disabled = not draft_dirty
	_revert_button.visible = is_open and draft_dirty
	_accept_button.visible = is_open and not i_accepted
	_accept_button.disabled = draft_dirty or both_empty
	_accept_button.tooltip_text = (
		"Send your changes first" if draft_dirty
		else "Nothing is on offer yet" if both_empty
		else "Agree to exactly this offer"
	)
	_unaccept_button.visible = is_open and i_accepted
	_cancel_button.visible = is_open
	_cards_title.visible = is_open
	_cards_scroll.visible = is_open

func _accept_line(who: String, accepted: bool) -> String:
	if accepted:
		return "[color=#7fd88c]%s: accepted[/color]" % who
	return "%s: not yet" % who

func _render_my_offer(editable: bool) -> void:
	_clear(_my_offer_list)
	if draft.is_empty():
		_my_offer_list.add_child(_muted("(nothing)"))
		return
	var keys := draft.keys()
	keys.sort()
	for card_id in keys:
		var row := HBoxContainer.new()
		var label := Label.new()
		label.text = "%d× %s" % [int(draft[card_id]), library.card_name(str(card_id))]
		label.tooltip_text = library.tooltip(str(card_id))
		label.mouse_filter = Control.MOUSE_FILTER_PASS
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(label)
		if editable:
			var minus := Button.new()
			minus.text = "−"
			minus.pressed.connect(_remove_card.bind(str(card_id)))
			row.add_child(minus)
		_my_offer_list.add_child(row)

func _render_offer_list(list: VBoxContainer, cards: Variant) -> void:
	_clear(list)
	if typeof(cards) != TYPE_ARRAY or (cards as Array).is_empty():
		list.add_child(_muted("(nothing)"))
		return
	for entry in (cards as Array):
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var card_id := str(entry.get("cardId", ""))
		var label := Label.new()
		label.text = "%d× %s" % [int(entry.get("quantity", 0)), library.card_name(card_id)]
		label.tooltip_text = library.tooltip(card_id)
		label.mouse_filter = Control.MOUSE_FILTER_PASS
		# Say so when the player would be receiving a card they have none of.
		if _owned_count(card_id) == 0:
			label.text += "   (new)"
			label.add_theme_color_override("font_color", COLOR_GOOD)
		list.add_child(label)

## The cards the player owns, each with a button to put a copy on offer.
func _render_cards() -> void:
	_clear(_card_list)
	var trade := _selected_trade()
	if trade.is_empty() or str(trade.get("status", "")) != "OPEN":
		return
	var any := false
	for entry in collection:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var owned := int(entry.get("owned", 0))
		if owned <= 0:
			continue
		any = true
		_card_list.add_child(_card_row(entry))
	if not any:
		_card_list.add_child(_muted("(you own no cards to offer)"))

func _card_row(entry: Dictionary) -> Control:
	var card_id := str(entry.get("cardId", ""))
	var owned := int(entry.get("owned", 0))
	var offering := int(draft.get(card_id, 0))
	var tradeable := bool(entry.get("tradeable", false))

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var art := CardArt.texture_for(card_id)
	if art != null:
		var thumb := TextureRect.new()
		thumb.texture = art
		thumb.custom_minimum_size = Vector2(44, 28)
		thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		thumb.clip_contents = true
		thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if not tradeable:
			thumb.modulate = Color(0.55, 0.55, 0.60)
		row.add_child(thumb)

	var label := Label.new()
	label.text = "%s   %s" % [library.card_name(card_id), str(entry.get("rarity", "")).capitalize()]
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if not tradeable:
		label.modulate = Color(0.70, 0.70, 0.74)
	row.add_child(label)

	var counts := Label.new()
	counts.text = "own %d · offering %d" % [owned, offering]
	counts.add_theme_font_size_override("font_size", 11)
	row.add_child(counts)

	# Tradeability comes from the policy the server sent with the card. The
	# server refuses the offer anyway if it has changed since.
	var add := Button.new()
	add.text = "+"
	add.tooltip_text = library.tooltip(card_id)
	if not tradeable:
		add.disabled = true
		add.tooltip_text = "This expansion cannot be traded right now"
	elif offering >= owned:
		add.disabled = true
		add.tooltip_text = "You are already offering every copy you own"
	add.pressed.connect(_add_card.bind(card_id))
	row.add_child(add)
	return row

func _add_card(card_id: String) -> void:
	draft[card_id] = int(draft.get(card_id, 0)) + 1
	draft_dirty = _draft_differs()
	_render_all()

func _remove_card(card_id: String) -> void:
	var current := int(draft.get(card_id, 0))
	if current <= 1:
		draft.erase(card_id)
	else:
		draft[card_id] = current - 1
	draft_dirty = _draft_differs()
	_render_all()

func _revert_draft() -> void:
	draft_dirty = false
	_sync_draft()
	_render_all()

func _send_offer() -> void:
	if selected_trade_id == "":
		return
	var cards: Array = []
	var keys := draft.keys()
	keys.sort()
	for card_id in keys:
		cards.append({"cardId": card_id, "quantity": int(draft[card_id])})
	_set_status("Sending your offer…")
	accounts.update_trade_offer(selected_trade_id, cards)

## Accepts the revision on screen. If the offer has moved on since it was
## drawn, the server refuses and the screen re-reads it.
func _accept() -> void:
	var trade := _selected_trade()
	if trade.is_empty() or draft_dirty:
		return
	_set_status("Accepting…")
	accounts.accept_trade(str(trade.get("id", "")), int(trade.get("revision", -1)))

func _unaccept() -> void:
	if selected_trade_id != "":
		accounts.unaccept_trade(selected_trade_id)

func _cancel() -> void:
	if selected_trade_id != "":
		accounts.cancel_trade(selected_trade_id)

# --- Helpers -----------------------------------------------------------------

func _render_all() -> void:
	_render_requests()
	_render_friends()
	_render_trades()
	_render_detail()
	_render_cards()

func _selected_trade() -> Dictionary:
	for entry in trades:
		if typeof(entry) == TYPE_DICTIONARY and str(entry.get("id", "")) == selected_trade_id:
			return entry
	return {}

func _open_trade_with(friend_id: String) -> Dictionary:
	for entry in trades:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var trade: Dictionary = entry
		var with_friend := str(_their_offer(trade).get("userId", "")) == friend_id
		if with_friend and str(trade.get("status", "")) == "OPEN":
			return trade
	return {}

## The player's own side of a trade.
func _my_offer(trade: Dictionary) -> Dictionary:
	return _side(trade, true)

func _their_offer(trade: Dictionary) -> Dictionary:
	return _side(trade, false)

func _side(trade: Dictionary, mine: bool) -> Dictionary:
	var me := str(accounts.user.get("id", ""))
	var offers: Variant = trade.get("offers", [])
	if typeof(offers) != TYPE_ARRAY:
		return {}
	for offer in (offers as Array):
		if typeof(offer) == TYPE_DICTIONARY and (str(offer.get("userId", "")) == me) == mine:
			return offer
	return {}

func _other_name(trade: Dictionary) -> String:
	var other := _their_offer(trade)
	return str(other.get("displayName", "another player"))

func _copies(cards: Variant) -> int:
	var total := 0
	if typeof(cards) == TYPE_ARRAY:
		for entry in (cards as Array):
			if typeof(entry) == TYPE_DICTIONARY:
				total += int(entry.get("quantity", 0))
	return total

func _owned_count(card_id: String) -> int:
	for entry in collection:
		if typeof(entry) == TYPE_DICTIONARY and str(entry.get("cardId", "")) == card_id:
			return int(entry.get("owned", 0))
	return 0

func _muted(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 11)
	label.modulate = Color(0.70, 0.70, 0.74)
	return label

func _set_status(text: String, is_error: bool = false) -> void:
	_status.text = text
	if is_error:
		_status.add_theme_color_override("font_color", COLOR_ERROR)
	else:
		_status.remove_theme_color_override("font_color")

func _clear(node: Node) -> void:
	for child in node.get_children():
		node.remove_child(child)
		child.queue_free()
