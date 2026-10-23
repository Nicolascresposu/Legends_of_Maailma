extends Control

## The admin debug panel: look inside any account, put it into whatever state
## a test needs, and edit live matches.
##
## Only ever shown to an admin, and only while the admin UI is switched on.
## Account/match tools call the admin API. The expansion creator edits local
## JSON drafts/files and publishes reviewed versions through the admin API.

signal closed()
## The admin started a debug match they play in themselves: open it.
signal play_requested(match_id: String)
signal content_published(version: String)

const AdminMatchTools := preload("res://src/admin_match_tools.gd")
const ExpansionCreator := preload("res://src/expansion_creator.gd")

var accounts: AccountClient
var library: CardLibrary

## The registry: every card, hero, scenario and pack, unreleased included.
var _registry: Dictionary = {}
## The accounts the last search found, and the one being worked on.
var _users: Array = []
var _selected_user := ""
var _overview: Dictionary = {}
## The live matches, and the one being inspected.
var _matches: Array = []
var _selected_match := ""

var _status: Label
var _search: LineEdit
var _user_list: VBoxContainer
var _overview_label: RichTextLabel
var _admin_toggle: Button
var _fragments_input: SpinBox
var _fragments_delta: SpinBox
var _card_picker: OptionButton
var _card_count: SpinBox
var _include_unreleased: CheckBox
var _hero_picker: OptionButton
var _deck_list: VBoxContainer
var _pack_picker: OptionButton
var _friend_picker: OptionButton
var _scenario_picker: OptionButton
var _debug_hero_picker: OptionButton
var _ledger_label: RichTextLabel
var _account_body: VBoxContainer
var _match_list: VBoxContainer
var _match_label: RichTextLabel
var _match_tools: Node
var _match_body: VBoxContainer
var _expansion_creator: Control

func setup(account_client: AccountClient, card_library: CardLibrary) -> void:
	accounts = account_client
	library = card_library
	accounts.admin_response.connect(_on_admin_response)

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var backdrop := ColorRect.new()
	# Light enough that the default buttons read as buttons against it.
	backdrop.color = Color(0.24, 0.25, 0.29)
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(backdrop)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 14)
	add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 8)
	margin.add_child(root)

	var header := HBoxContainer.new()
	root.add_child(header)
	var title := Label.new()
	title.text = "Admin"
	title.add_theme_font_size_override("font_size", 18)
	header.add_child(title)
	_status = Label.new()
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.clip_text = true
	header.add_child(_status)
	var back := Button.new()
	back.text = "Back"
	back.pressed.connect(func() -> void:
		_expansion_creator.confirm_discard(func() -> void: closed.emit()))
	header.add_child(back)

	var tabs := TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(tabs)
	tabs.add_child(_build_accounts_tab())
	tabs.add_child(_build_matches_tab())
	_expansion_creator = ExpansionCreator.new()
	_expansion_creator.setup_publishing(accounts)
	_expansion_creator.published.connect(func(version: String) -> void:
		accounts.admin(HTTPClient.METHOD_GET, "/registry", null, "admin:registry")
		content_published.emit(version))
	tabs.add_child(_expansion_creator)
	tabs.tab_changed.connect(func(index: int) -> void:
		if index == 1:
			refresh_matches()
		elif index == 2:
			_expansion_creator.opened())

## Called each time the panel is shown: fresh data, never a stale snapshot.
func opened() -> void:
	if _registry.is_empty():
		accounts.admin(HTTPClient.METHOD_GET, "/registry", null, "admin:registry")
	_search_users()
	if _selected_user != "":
		_load_user(_selected_user)
	refresh_matches()

# --- Accounts tab ------------------------------------------------------------

func _build_accounts_tab() -> Control:
	var tab := HBoxContainer.new()
	tab.name = "Accounts"
	tab.add_theme_constant_override("separation", 12)

	var left := VBoxContainer.new()
	left.custom_minimum_size.x = 260
	tab.add_child(left)
	var search_row := HBoxContainer.new()
	left.add_child(search_row)
	_search = LineEdit.new()
	_search.placeholder_text = "Name or email"
	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search.text_submitted.connect(func(_text: String) -> void: _search_users())
	search_row.add_child(_search)
	var go := Button.new()
	go.text = "Search"
	go.pressed.connect(_search_users)
	search_row.add_child(go)
	var me := Button.new()
	me.text = "Me"
	me.tooltip_text = "Work on your own account."
	me.pressed.connect(func() -> void: _select_user(str(accounts.user.get("id", ""))))
	search_row.add_child(me)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.add_child(scroll)
	_user_list = VBoxContainer.new()
	_user_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_user_list)

	var right_scroll := ScrollContainer.new()
	right_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	tab.add_child(right_scroll)
	_account_body = VBoxContainer.new()
	_account_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_account_body.add_theme_constant_override("separation", 6)
	right_scroll.add_child(_account_body)

	_overview_label = _rich()
	_account_body.add_child(_overview_label)

	var account_row := _row("Account")
	_admin_toggle = _button(account_row, "Make admin", _toggle_admin)
	var sign_in_as := _button(account_row, "Sign in as", _impersonate)
	sign_in_as.tooltip_text = "Become this player in this client. Sign out to become yourself again."
	_button(account_row, "Sign out everywhere", func() -> void:
		_user_call(HTTPClient.METHOD_DELETE, "/sessions", null, "Signed them out."))

	var fragments_row := _row("Fragments")
	_fragments_input = _spin(0, 1000000)
	fragments_row.add_child(_fragments_input)
	_button(fragments_row, "Set", func() -> void:
		_user_call(HTTPClient.METHOD_PUT, "/fragments",
			{"balance": int(_fragments_input.value)}, "Balance set."))
	_fragments_delta = _spin(-1000000, 1000000)
	fragments_row.add_child(_fragments_delta)
	_button(fragments_row, "Add", func() -> void:
		_user_call(HTTPClient.METHOD_POST, "/fragments",
			{"amount": int(_fragments_delta.value)}, "Fragments adjusted."))

	var card_row := _row("Card")
	_card_picker = _picker(card_row, 220)
	_card_count = _spin(0, 99)
	_card_count.value = 2
	card_row.add_child(_card_count)
	_button(card_row, "Set count", func() -> void:
		var card_id := _picked(_card_picker)
		if card_id == "":
			return
		_user_call(HTTPClient.METHOD_PUT, "/collection/" + card_id.uri_encode(),
			{"quantity": int(_card_count.value)}, "Card count set."))

	var bulk_row := _row("Collection")
	_include_unreleased = CheckBox.new()
	_include_unreleased.text = "include unreleased"
	_button(bulk_row, "Grant a playset of everything", func() -> void:
		_user_call(HTTPClient.METHOD_POST, "/collection/grant-all",
			{"includeUnreleased": _include_unreleased.button_pressed}, "Cards granted."))
	bulk_row.add_child(_include_unreleased)
	_button(bulk_row, "Reset to starter cards", func() -> void:
		_user_call(HTTPClient.METHOD_POST, "/collection/reset", {}, "Collection reset."))

	var deck_row := _row("Decks")
	_hero_picker = _picker(deck_row, 160)
	_button(deck_row, "Create starter deck", func() -> void:
		var hero_id := _picked(_hero_picker)
		if hero_id != "":
			_user_call(HTTPClient.METHOD_POST, "/decks/starter", {"heroId": hero_id},
				"Starter deck created."))
	_deck_list = VBoxContainer.new()
	_account_body.add_child(_deck_list)

	var pack_row := _row("Packs")
	_pack_picker = _picker(pack_row, 200)
	_button(pack_row, "Open for them", func() -> void:
		var pack_id := _picked(_pack_picker)
		if pack_id != "":
			_user_call(HTTPClient.METHOD_POST, "/packs/%s/open" % pack_id.uri_encode(), {},
				"Pack opened."))

	var friend_row := _row("Friends")
	_friend_picker = _picker(friend_row, 200)
	_button(friend_row, "Make friends", func() -> void:
		var other := _picked(_friend_picker)
		if other != "" and _selected_user != "":
			accounts.admin(HTTPClient.METHOD_POST, "/friendships",
				{"userA": _selected_user, "userB": other}, "admin:user-change:Now friends."))

	var match_row := _row("Debug match")
	_scenario_picker = _picker(match_row, 170)
	_debug_hero_picker = _picker(match_row, 150)
	_button(match_row, "Start with starter deck", _start_debug_match)

	_account_body.add_child(_heading("Recent ledger"))
	_ledger_label = _rich()
	_account_body.add_child(_ledger_label)
	_account_body.visible = false
	return tab

func _search_users() -> void:
	var query := _search.text.strip_edges().uri_encode()
	accounts.admin(HTTPClient.METHOD_GET, "/users?search=%s&limit=100" % query, null, "admin:users")

func _select_user(user_id: String) -> void:
	if user_id == "":
		return
	_selected_user = user_id
	_load_user(user_id)

func _load_user(user_id: String) -> void:
	accounts.admin(HTTPClient.METHOD_GET, "/users/" + user_id.uri_encode(), null, "admin:overview")

## One call against the selected account, then a fresh read of it.
func _user_call(method: int, path: String, body: Variant, done: String) -> void:
	if _selected_user == "":
		_say("Pick an account first.", true)
		return
	accounts.admin(method, "/users/%s%s" % [_selected_user.uri_encode(), path], body,
		"admin:user-change:" + done)

func _toggle_admin() -> void:
	var is_admin := bool((_overview.get("user", {}) as Dictionary).get("isAdmin", false))
	_user_call(HTTPClient.METHOD_PATCH, "", {"isAdmin": not is_admin},
		"Admin rights removed." if is_admin else "Admin rights granted.")

func _impersonate() -> void:
	if _selected_user == "":
		_say("Pick an account first.", true)
		return
	accounts.admin(HTTPClient.METHOD_POST, "/users/%s/sessions" % _selected_user.uri_encode(),
		{}, "admin:impersonate")

func _start_debug_match() -> void:
	var scenario := _picked(_scenario_picker)
	var hero := _picked(_debug_hero_picker)
	if _selected_user == "" or scenario == "" or hero == "":
		_say("Pick an account, a scenario and a hero.", true)
		return
	accounts.admin(HTTPClient.METHOD_POST, "/matches",
		{"userId": _selected_user, "scenarioId": scenario, "heroId": hero}, "admin:debug-match")

func _render_users() -> void:
	_clear(_user_list)
	_friend_picker.clear()
	for entry in _users:
		var account: Dictionary = entry
		var id := str(account.get("id", ""))
		var button := Button.new()
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.text = "%s%s — %d Fragments" % [
			str(account.get("displayName", "")),
			" ★" if bool(account.get("isAdmin", false)) else "",
			int(account.get("fragments", 0)),
		]
		button.tooltip_text = str(account.get("email", ""))
		button.toggle_mode = true
		button.button_pressed = id == _selected_user
		button.pressed.connect(_select_user.bind(id))
		_user_list.add_child(button)
		_friend_picker.add_item(str(account.get("displayName", "")))
		_friend_picker.set_item_metadata(_friend_picker.item_count - 1, id)

func _render_overview() -> void:
	_account_body.visible = not _overview.is_empty()
	if _overview.is_empty():
		return
	var user: Dictionary = _overview.get("user", {})
	var collection: Dictionary = _overview.get("collection", {})
	var social: Dictionary = _overview.get("social", {})
	var lines: Array[String] = [
		"[b]%s[/b]%s   %s" % [
			str(user.get("displayName", "")),
			"  [color=#e8c46a]admin[/color]" if bool(user.get("isAdmin", false)) else "",
			str(user.get("email", "")),
		],
		"id %s" % str(user.get("id", "")),
		"%d Fragments · %d distinct cards, %d copies · %d active session(s)" % [
			int(user.get("fragments", 0)),
			int(collection.get("distinctCards", 0)),
			int(collection.get("totalCopies", 0)),
			int(_overview.get("activeSessions", 0)),
		],
		"%d friend(s) · %d open trade(s) · %d live match(es)" % [
			(social.get("friends", []) as Array).size(),
			(_overview.get("openTrades", []) as Array).size(),
			(_overview.get("matches", []) as Array).size(),
		],
	]
	_overview_label.text = "\n".join(lines)
	_admin_toggle.text = "Remove admin" if bool(user.get("isAdmin", false)) else "Make admin"
	_fragments_input.value = int(user.get("fragments", 0))

	_clear(_deck_list)
	for entry in _overview.get("decks", []):
		var deck: Dictionary = entry
		var readiness: Dictionary = deck.get("readiness", {})
		var row := HBoxContainer.new()
		var label := Label.new()
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.text = "   %s — %s — %s" % [
			str(deck.get("name", "")),
			str(deck.get("heroId", "")),
			"ready" if bool(readiness.get("playable", false)) else "not ready",
		]
		row.add_child(label)
		var deck_id := str(deck.get("id", ""))
		_button(row, "Delete", func() -> void:
			_user_call(HTTPClient.METHOD_DELETE, "/decks/" + deck_id.uri_encode(), null,
				"Deck deleted."))
		_deck_list.add_child(row)

	var ledger: Array[String] = []
	for entry in _overview.get("recentLedger", []):
		var row: Dictionary = entry
		var metadata: Variant = row.get("metadata", {})
		var action := ""
		if typeof(metadata) == TYPE_DICTIONARY:
			action = str((metadata as Dictionary).get("action", ""))
		ledger.append("%s  %s%s  cards %+d  fragments %+d" % [
			str(row.get("createdAt", "")).substr(0, 19),
			str(row.get("type", "")),
			" (%s)" % action if action != "" else "",
			int(row.get("quantity", 0)),
			int(row.get("fragmentDelta", 0)),
		])
	_ledger_label.text = "\n".join(ledger) if not ledger.is_empty() else "Nothing yet."

# --- Matches tab -------------------------------------------------------------

func _build_matches_tab() -> Control:
	var tab := HBoxContainer.new()
	tab.name = "Matches"
	tab.add_theme_constant_override("separation", 12)

	var left := VBoxContainer.new()
	left.custom_minimum_size.x = 260
	tab.add_child(left)
	var refresh := Button.new()
	refresh.text = "Refresh"
	refresh.pressed.connect(refresh_matches)
	left.add_child(refresh)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.add_child(scroll)
	_match_list = VBoxContainer.new()
	_match_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_match_list)

	_match_body = VBoxContainer.new()
	_match_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_match_body.add_theme_constant_override("separation", 8)
	tab.add_child(_match_body)
	_match_label = _rich()
	_match_body.add_child(_match_label)
	var actions := HBoxContainer.new()
	_match_body.add_child(actions)
	var play := _button(actions, "Play it", _play_selected)
	play.tooltip_text = "Open this match in the match view. Only works for a match you are a player in."
	_button(actions, "End match", func() -> void:
		if _selected_match != "":
			accounts.admin(HTTPClient.METHOD_DELETE, "/matches/" + _selected_match.uri_encode(),
				null, "admin:end-match"))
	_match_tools = AdminMatchTools.new()
	_match_tools.setup(accounts, library)
	_match_tools.edited.connect(func(_summary: Dictionary) -> void: _load_match(_selected_match))
	_match_body.add_child(_match_tools)
	_match_body.visible = false
	return tab

func _play_selected() -> void:
	if _selected_match != "":
		play_requested.emit(_selected_match)

func refresh_matches() -> void:
	accounts.admin(HTTPClient.METHOD_GET, "/matches", null, "admin:matches")

func _load_match(match_id: String) -> void:
	if match_id == "":
		return
	_selected_match = match_id
	accounts.admin(HTTPClient.METHOD_GET, "/matches/" + match_id.uri_encode(), null, "admin:match")

func _render_matches() -> void:
	_clear(_match_list)
	if _matches.is_empty():
		var none := Label.new()
		none.text = "No live matches."
		_match_list.add_child(none)
	for entry in _matches:
		var summary: Dictionary = entry
		var id := str(summary.get("matchId", ""))
		var players: Array[String] = []
		for player in summary.get("players", []):
			players.append("%s (%s ♥%d)" % [
				str((player as Dictionary).get("playerId", "")).substr(0, 8),
				str((player as Dictionary).get("heroId", "")),
				int((player as Dictionary).get("health", 0)),
			])
		var button := Button.new()
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.text = "%s · turn %d · %s" % [
			str(summary.get("scenarioId", "")), int(summary.get("turn", 0)), " vs ".join(players),
		]
		button.tooltip_text = id
		button.toggle_mode = true
		button.button_pressed = id == _selected_match
		button.pressed.connect(_load_match.bind(id))
		_match_list.add_child(button)

func _render_match(detail: Dictionary) -> void:
	_match_body.visible = true
	var summary: Dictionary = detail.get("summary", {})
	var state: Dictionary = detail.get("state", {})
	var lines: Array[String] = [
		"[b]%s[/b]  turn %d · %s%s" % [
			str(summary.get("scenarioId", "")),
			int(summary.get("turn", 0)),
			str(summary.get("phase", "")),
			"  · [color=#e8c46a]%d admin edit(s)[/color]" % int(state.get("debugEdits", 0))
				if int(state.get("debugEdits", 0)) > 0 else "",
		],
		"id %s · active %s" % [
			str(summary.get("matchId", "")), str(summary.get("activePlayerId", "")).substr(0, 8),
		],
	]
	var sides: Dictionary = state.get("sides", {})
	for player in state.get("playerOrder", []):
		var side: Dictionary = sides.get(str(player), {})
		var hero: Dictionary = side.get("hero", {})
		lines.append("%s — %s ♥%s · hand %d · deck %d · %d creature(s)" % [
			str(player).substr(0, 8),
			str(hero.get("definitionId", "")),
			str(int(hero.get("currentHealth", 0))),
			(side.get("hand", []) as Array).size(),
			(side.get("deck", []) as Array).size(),
			(side.get("creatures", {}) as Dictionary).size(),
		])
	_match_label.text = "\n".join(lines)
	_match_tools.show_match(_selected_match, state, str(accounts.user.get("id", "")))

# --- Replies -------------------------------------------------------------------

func _on_admin_response(tag: String, ok: bool, payload: Dictionary) -> void:
	if not tag.begins_with("admin:"):
		return
	if not ok:
		_say(str(payload.get("message", "Refused.")), true)
		return
	if tag == "admin:registry":
		_registry = payload
		_fill_registry_pickers()
	elif tag == "admin:users":
		_users = payload.get("users", [])
		_render_users()
	elif tag == "admin:overview":
		_overview = payload
		_render_overview()
	elif tag.begins_with("admin:user-change:"):
		_say(tag.trim_prefix("admin:user-change:"))
		_load_user(_selected_user)
		_search_users()
	elif tag == "admin:impersonate":
		# Become that player. The rest of the client follows the sign-in; an
		# account that is not an admin no longer sees this panel.
		_say("Signed in as %s." % str((payload.get("user", {}) as Dictionary).get("displayName", "")))
		accounts.adopt_session(payload, false)
	elif tag == "admin:debug-match":
		var summary: Dictionary = payload.get("match", {})
		var match_id := str(summary.get("matchId", ""))
		_say("Debug match started: %s" % match_id)
		refresh_matches()
		if _selected_user == str(accounts.user.get("id", "")):
			play_requested.emit(match_id)
	elif tag == "admin:matches":
		_matches = payload.get("matches", [])
		_render_matches()
	elif tag == "admin:match":
		_render_match(payload)
	elif tag == "admin:end-match":
		_say("Match ended.")
		_selected_match = ""
		_match_body.visible = false
		refresh_matches()

func _fill_registry_pickers() -> void:
	_card_picker.clear()
	var cards: Array = (_registry.get("cards", []) as Array).duplicate()
	cards.sort_custom(func(a: Variant, b: Variant) -> bool:
		return str((a as Dictionary).get("name", "")) < str((b as Dictionary).get("name", "")))
	for card in cards:
		_add_option(_card_picker, "%s (%s)" % [str(card.get("name", "")), str(card.get("id", ""))],
			str(card.get("id", "")))
	for picker in [_hero_picker, _debug_hero_picker]:
		(picker as OptionButton).clear()
		for hero in _registry.get("heroes", []):
			_add_option(picker, str(hero.get("name", "")), str(hero.get("id", "")))
	_pack_picker.clear()
	for pack in _registry.get("packs", []):
		_add_option(_pack_picker, str(pack.get("name", "")), str(pack.get("id", "")))
	_scenario_picker.clear()
	for scenario in _registry.get("scenarios", []):
		_add_option(_scenario_picker, str(scenario.get("name", "")), str(scenario.get("id", "")))

# --- Widgets -------------------------------------------------------------------

func _row(title: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var label := Label.new()
	label.text = title
	label.custom_minimum_size.x = 96
	label.add_theme_color_override("font_color", Color(0.85, 0.74, 0.44))
	row.add_child(label)
	_account_body.add_child(row)
	return row

func _heading(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", Color(0.85, 0.74, 0.44))
	return label

func _button(parent: Node, text: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.pressed.connect(action)
	parent.add_child(button)
	return button

func _spin(low: float, high: float) -> SpinBox:
	var spin := SpinBox.new()
	spin.min_value = low
	spin.max_value = high
	spin.step = 1
	spin.custom_minimum_size.x = 96
	return spin

func _picker(parent: Node, width: float) -> OptionButton:
	var picker := OptionButton.new()
	picker.custom_minimum_size.x = width
	picker.fit_to_longest_item = false
	parent.add_child(picker)
	return picker

func _add_option(picker: OptionButton, text: String, id: String) -> void:
	picker.add_item(text)
	picker.set_item_metadata(picker.item_count - 1, id)

func _picked(picker: OptionButton) -> String:
	if picker.selected < 0:
		_say("Pick something first.", true)
		return ""
	return str(picker.get_item_metadata(picker.selected))

func _rich() -> RichTextLabel:
	var label := RichTextLabel.new()
	label.bbcode_enabled = true
	label.fit_content = true
	label.scroll_active = false
	label.selection_enabled = true
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return label

func _clear(node: Node) -> void:
	for child in node.get_children():
		node.remove_child(child)
		child.queue_free()

func _say(text: String, is_error: bool = false) -> void:
	_status.text = text
	_status.add_theme_color_override(
		"font_color", Color(0.9, 0.45, 0.45) if is_error else Color(0.55, 0.85, 0.6)
	)
