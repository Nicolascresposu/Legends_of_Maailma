extends Control
class_name CollectionScreen

## Sign-in, collection browsing and deck building.
##
## The server owns ownership and legality: this screen shows what the player
## owns, lets them assemble a list, and reports the readiness the server
## computes. It never decides for itself whether a deck may be played.

signal play_requested()
## The player wants to trade cards with a friend.
signal trade_requested()
## An admin wants the admin panel.
signal admin_requested()
signal closed()
## The player pointed the client at a different server.
signal server_changed(http_base: String)

## Cards on one page of the collection, laid out in rows of `PAGE_COLUMNS`.
const CARDS_PER_PAGE := 8
const PAGE_COLUMNS := 4
const PAGE_GAP := 14.0
## The cost filter's last button stands for this cost and above.
const MAX_COST_FILTER := 7
const CRAFT_CARD_WIDTH := 260.0

## Each hero's class, which decides the class cards a deck may hold.
##
## Mirrors the server's hero definitions, as the hero picker below already
## does; the server still judges every deck, so a stale entry here could only
## mislabel a button, never admit an illegal deck.
const HERO_CLASSES := {"healer": "PRIEST", "striker": "WIZARD"}
const CLASS_NAMES := {"PRIEST": "Priest", "WIZARD": "Wizard"}

var accounts: AccountClient
var library: CardLibrary

var collection: Array = []
var decks: Array = []
## Card id -> copies currently in the deck being edited.
var draft: Dictionary = {}
var editing_deck_id := ""
var selected_hero := "healer"
## The format the deck being edited is built for. Legality is still the
## server's call; this only says which question to ask it.
var selected_format := "STANDARD"
## The player's Fragment balance, as the server last reported it.
var fragments := 0
## Packs currently openable, as the server last reported them.
var available_packs: Array = []
## The crafting view: every card, owned or not, and a click crafts rather
## than adds to the deck.
var crafting := false
## The collection page showing, from 0.
var page := 0
## Only cards of this cost are shown; -1 for every cost, and
## `MAX_COST_FILTER` for that cost and above.
var cost_filter := -1
var search := ""
## The card open in the crafting panel, or "" when it is closed.
var crafting_card_id := ""

var _root: VBoxContainer
var _auth_box: VBoxContainer
## The inputs and buttons, hidden while a saved session is being checked.
var _auth_form: HBoxContainer
## Accounts signed in on this machine before, for quick sign-in.
var _saved_box: VBoxContainer
var _saved_list: VBoxContainer
var _auto_sign_in: CheckBox
var _server_input: LineEdit
var _main_box: HBoxContainer
var _email_input: LineEdit
var _name_input: LineEdit
var _password_input: LineEdit
var _auth_status: Label
var _who_label: Label
## Holds the page's cards, placed by hand so they keep the card's shape.
var _page_grid: Control
var _page_label: Label
var _prev_page: Button
var _next_page: Button
var _crafting_button: Button
var _mode_hint: Label
var _cost_buttons: Array[Button] = []
var _search_input: LineEdit
var _craft_overlay: Control
var _craft_box: HBoxContainer
var _deck_list: VBoxContainer
var _draft_list: VBoxContainer
var _draft_name: LineEdit
var _hero_picker: OptionButton
var _readiness_label: RichTextLabel
var _count_label: Label
var _fragments_label: Label
var _format_picker: OptionButton
var _pack_row: HBoxContainer
var _economy_status: Label
var _admin_button: Button

func setup(account_client: AccountClient, card_library: CardLibrary) -> void:
	accounts = account_client
	library = card_library
	accounts.signed_in.connect(_on_signed_in)
	accounts.sign_in_failed.connect(_on_sign_in_failed)
	accounts.restore_started.connect(_on_restore_started)
	accounts.restore_failed.connect(_on_restore_failed)
	accounts.signed_out.connect(_on_signed_out)
	accounts.collection_loaded.connect(_on_collection_loaded)
	accounts.decks_loaded.connect(_on_decks_loaded)
	accounts.deck_saved.connect(_on_deck_saved)
	accounts.deck_error.connect(_on_deck_error)
	accounts.readiness_assessed.connect(_on_readiness)
	accounts.request_failed.connect(_on_deck_error)
	accounts.fragments_changed.connect(_on_fragments_changed)
	accounts.economy_result.connect(_on_economy_result)
	accounts.economy_refused.connect(_on_economy_refused)
	accounts.packs_loaded.connect(_on_packs_loaded)
	accounts.pack_opened.connect(_on_pack_opened)
	_build()

func _build() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	add_child(margin)

	_root = VBoxContainer.new()
	_root.add_theme_constant_override("separation", 10)
	margin.add_child(_root)

	_root.add_child(_build_auth())
	_main_box = _build_main()
	_root.add_child(_main_box)
	_main_box.visible = false
	# Last, so it draws over the page it opens from.
	add_child(_build_craft_overlay())

func _build_auth() -> Control:
	_auth_box = VBoxContainer.new()
	_auth_box.add_theme_constant_override("separation", 6)

	var title := Label.new()
	title.text = "Maailma — sign in"
	title.add_theme_font_size_override("font_size", 20)
	_auth_box.add_child(title)

	_saved_box = VBoxContainer.new()
	_saved_box.add_theme_constant_override("separation", 4)
	_auth_box.add_child(_saved_box)
	var saved_title := Label.new()
	saved_title.text = "Saved accounts"
	saved_title.add_theme_font_size_override("font_size", 13)
	_saved_box.add_child(saved_title)
	_saved_list = VBoxContainer.new()
	_saved_list.add_theme_constant_override("separation", 4)
	_saved_box.add_child(_saved_list)

	_auth_form = HBoxContainer.new()
	_auth_form.add_theme_constant_override("separation", 6)
	_auth_box.add_child(_auth_form)
	var row := _auth_form

	_email_input = LineEdit.new()
	_email_input.placeholder_text = "Email"
	_email_input.custom_minimum_size.x = 220
	row.add_child(_email_input)

	_name_input = LineEdit.new()
	_name_input.placeholder_text = "Display name (new accounts)"
	_name_input.custom_minimum_size.x = 220
	row.add_child(_name_input)

	_password_input = LineEdit.new()
	_password_input.placeholder_text = "Password"
	_password_input.secret = true
	_password_input.custom_minimum_size.x = 200
	row.add_child(_password_input)

	var login_button := Button.new()
	login_button.text = "Sign in"
	login_button.pressed.connect(_do_login)
	row.add_child(login_button)

	var register_button := Button.new()
	register_button.text = "Create account"
	register_button.pressed.connect(_do_register)
	row.add_child(register_button)

	# Sign-in happens here, so the server address has to be changeable here too.
	var server_row := HBoxContainer.new()
	server_row.add_theme_constant_override("separation", 6)
	_auth_box.add_child(server_row)
	var server_label := Label.new()
	server_label.text = "Server"
	server_label.add_theme_font_size_override("font_size", 11)
	server_row.add_child(server_label)
	_server_input = LineEdit.new()
	_server_input.text = accounts.http_base
	_server_input.placeholder_text = "127.0.0.1:3000"
	_server_input.tooltip_text = (
		"Where the Node server is listening. Also settable with --server=host:port"
		+ " or the MAAILMA_SERVER environment variable."
	)
	_server_input.custom_minimum_size.x = 220
	_server_input.text_submitted.connect(func(value: String) -> void: _apply_server(value))
	_server_input.focus_exited.connect(func() -> void: _apply_server(_server_input.text))
	server_row.add_child(_server_input)

	_auto_sign_in = CheckBox.new()
	_auto_sign_in.text = "Sign in automatically"
	_auto_sign_in.tooltip_text = "Start signed in to the last account used, while its session lasts."
	_auto_sign_in.button_pressed = SessionStore.auto_sign_in()
	_auto_sign_in.toggled.connect(func(on: bool) -> void: SessionStore.set_auto_sign_in(on))
	server_row.add_child(_auto_sign_in)

	_auth_status = Label.new()
	_auth_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_auth_status.text = "New accounts start with the starter cards."
	_auth_box.add_child(_auth_status)
	_render_saved_accounts()
	return _auth_box

## One row per remembered account: its name to sign in with, and Forget.
func _render_saved_accounts() -> void:
	for child in _saved_list.get_children():
		child.queue_free()
	var list := SessionStore.accounts()
	_saved_box.visible = not list.is_empty()
	for account in list:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		_saved_list.add_child(row)

		var pick := Button.new()
		pick.text = "%s  ·  %s" % [account.display_name, account.email]
		if account.token == "":
			pick.text += "  (password needed)"
		pick.tooltip_text = account.server
		pick.alignment = HORIZONTAL_ALIGNMENT_LEFT
		# A fixed width keeps every Forget in one column; long names are clipped.
		pick.clip_text = true
		pick.custom_minimum_size.x = 420
		pick.pressed.connect(_quick_sign_in.bind(account))
		row.add_child(pick)

		var forget := Button.new()
		forget.text = "Forget"
		forget.tooltip_text = "Remove this account from this computer, and end its session."
		forget.pressed.connect(func() -> void:
			accounts.forget_account(account)
			_render_saved_accounts())
		row.add_child(forget)

## Signs in to a remembered account: straight in while its session lives,
## otherwise by filling in what is known and asking for the password.
func _quick_sign_in(account: SessionStore.Account) -> void:
	_show_server(account.server)
	if account.token != "":
		accounts.resume(account)
		return
	_ask_password(account.email, "Enter the password for %s." % account.display_name)

func _ask_password(email: String, message: String) -> void:
	_email_input.text = email
	_password_input.text = ""
	_password_input.grab_focus()
	_auth_status.text = message

## Shows an account's server in the field and points the match client at it,
## so the match view talks to the server the account belongs to.
func _show_server(base: String) -> void:
	if base == "" or _server_input.text == base:
		return
	_server_input.text = base
	server_changed.emit(base)

## Points the account client at a new address and remembers it.
func _apply_server(raw: String) -> void:
	var base := ClientConfig.normalize(raw)
	if base == "" or base == accounts.http_base:
		return
	accounts.http_base = base
	ClientConfig.save(base)
	_server_input.text = base
	server_changed.emit(base)

func _build_main() -> HBoxContainer:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	box.size_flags_vertical = Control.SIZE_EXPAND_FILL

	# --- Collection ---
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 6)
	box.add_child(left)

	var header := HBoxContainer.new()
	left.add_child(header)
	var collection_title := Label.new()
	collection_title.text = "Collection"
	collection_title.add_theme_font_size_override("font_size", 16)
	collection_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(collection_title)
	# The balance sits beside the collection because that is where it is spent.
	_fragments_label = Label.new()
	_fragments_label.text = "0 Fragments"
	header.add_child(_fragments_label)
	_who_label = Label.new()
	header.add_child(_who_label)
	var trade := Button.new()
	trade.text = "Trade"
	trade.tooltip_text = "Trade cards with your friends."
	trade.pressed.connect(func() -> void: trade_requested.emit())
	header.add_child(trade)
	_admin_button = Button.new()
	_admin_button.text = "Admin"
	_admin_button.tooltip_text = "Accounts and live matches, for testing."
	_admin_button.visible = false
	_admin_button.pressed.connect(func() -> void: admin_requested.emit())
	header.add_child(_admin_button)
	var switch := Button.new()
	switch.text = "Switch account"
	switch.tooltip_text = "Back to the sign-in screen. This account stays signed in, to pick again."
	switch.pressed.connect(func() -> void:
		accounts.switch_account()
		_auth_status.text = "Pick an account, or sign in to another.")
	header.add_child(switch)
	var sign_out := Button.new()
	sign_out.text = "Sign out"
	sign_out.tooltip_text = "End this session. The account stays saved, but needs its password again."
	sign_out.pressed.connect(func() -> void: accounts.sign_out())
	header.add_child(sign_out)

	# Packs, and whatever the last economy action had to say. Both live above
	# the list because both change what the list shows.
	_pack_row = HBoxContainer.new()
	_pack_row.add_theme_constant_override("separation", 6)
	left.add_child(_pack_row)

	_economy_status = Label.new()
	_economy_status.add_theme_font_size_override("font_size", 11)
	left.add_child(_economy_status)

	# Which cards the pages hold: the view, a cost, a name.
	var filters := HBoxContainer.new()
	filters.add_theme_constant_override("separation", 4)
	left.add_child(filters)
	_crafting_button = Button.new()
	_crafting_button.text = "Crafting"
	_crafting_button.toggle_mode = true
	_crafting_button.tooltip_text = "Show every card, owned or not, to craft or disenchant."
	_crafting_button.toggled.connect(_set_crafting)
	filters.add_child(_crafting_button)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	filters.add_child(spacer)
	for cost in range(MAX_COST_FILTER + 1):
		var button := Button.new()
		button.text = "%d+" % cost if cost == MAX_COST_FILTER else str(cost)
		button.toggle_mode = true
		button.custom_minimum_size.x = 30
		button.tooltip_text = "Only cards costing %s Taika" % button.text
		button.pressed.connect(_set_cost_filter.bind(cost))
		filters.add_child(button)
		_cost_buttons.append(button)
	_search_input = LineEdit.new()
	_search_input.placeholder_text = "Search"
	_search_input.custom_minimum_size.x = 140
	_search_input.clear_button_enabled = true
	_search_input.text_changed.connect(func(text: String) -> void:
		search = text.strip_edges()
		page = 0
		_render_collection())
	filters.add_child(_search_input)

	_mode_hint = Label.new()
	_mode_hint.add_theme_font_size_override("font_size", 11)
	_mode_hint.add_theme_color_override("font_color", Color(0.66, 0.69, 0.76))
	left.add_child(_mode_hint)

	# The page, with an arrow either side to turn it; the wheel turns it too.
	var book := HBoxContainer.new()
	book.size_flags_vertical = Control.SIZE_EXPAND_FILL
	book.add_theme_constant_override("separation", 6)
	left.add_child(book)
	_prev_page = _page_arrow("‹", "Previous page", -1)
	book.add_child(_prev_page)
	_page_grid = Control.new()
	_page_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_page_grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_page_grid.clip_contents = true
	_page_grid.resized.connect(_layout_page)
	_page_grid.gui_input.connect(_on_page_input)
	book.add_child(_page_grid)
	_next_page = _page_arrow("›", "Next page", 1)
	book.add_child(_next_page)

	_page_label = Label.new()
	_page_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_page_label.add_theme_font_size_override("font_size", 12)
	left.add_child(_page_label)
	_update_mode_hint()

	# --- Deck being built ---
	var right := VBoxContainer.new()
	right.custom_minimum_size.x = 400
	right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 6)
	box.add_child(right)

	var deck_title := Label.new()
	deck_title.text = "Deck"
	deck_title.add_theme_font_size_override("font_size", 16)
	right.add_child(deck_title)

	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 6)
	right.add_child(name_row)
	_draft_name = LineEdit.new()
	_draft_name.placeholder_text = "Deck name"
	_draft_name.text = "My Deck"
	_draft_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_row.add_child(_draft_name)
	_hero_picker = OptionButton.new()
	_hero_picker.add_item("The Mender", 0)
	_hero_picker.add_item("The Striker", 1)
	_hero_picker.item_selected.connect(
		func(index: int) -> void:
			selected_hero = "striker" if index == 1 else "healer"
			# The hero decides the deck's class, so which cards may be added —
			# and whether the draft is still legal — changes with it.
			_render_draft()
	)
	name_row.add_child(_hero_picker)

	# Standard and Wild draw on the same collection; only the question differs.
	_format_picker = OptionButton.new()
	_format_picker.add_item("Standard", 0)
	_format_picker.add_item("Wild", 1)
	_format_picker.item_selected.connect(
		func(index: int) -> void:
			selected_format = "WILD" if index == 1 else "STANDARD"
			_request_readiness()
	)
	name_row.add_child(_format_picker)

	_count_label = Label.new()
	right.add_child(_count_label)

	_readiness_label = RichTextLabel.new()
	_readiness_label.bbcode_enabled = true
	_readiness_label.fit_content = true
	_readiness_label.custom_minimum_size.y = 76
	right.add_child(_readiness_label)

	var draft_scroll := ScrollContainer.new()
	# A fixed band: expanding here would let a 30-card list push the buttons
	# below it off the bottom of the panel.
	draft_scroll.size_flags_vertical = Control.SIZE_FILL
	draft_scroll.custom_minimum_size.y = 210
	right.add_child(draft_scroll)
	_draft_list = VBoxContainer.new()
	_draft_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_draft_list.add_theme_constant_override("separation", 3)
	draft_scroll.add_child(_draft_list)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 6)
	right.add_child(buttons)
	var save := Button.new()
	save.text = "Save deck"
	save.pressed.connect(_save_draft)
	buttons.add_child(save)
	var fill := Button.new()
	fill.text = "Fill from collection"
	fill.tooltip_text = "Add owned cards until the deck reaches 30."
	fill.pressed.connect(_autofill)
	buttons.add_child(fill)
	var clear := Button.new()
	clear.text = "Clear"
	clear.pressed.connect(func() -> void:
		draft.clear()
		editing_deck_id = ""
		_render_draft()
	)
	buttons.add_child(clear)

	var deck_header := Label.new()
	deck_header.text = "Saved decks"
	deck_header.add_theme_font_size_override("font_size", 14)
	right.add_child(deck_header)
	var deck_scroll := ScrollContainer.new()
	deck_scroll.custom_minimum_size.y = 120
	right.add_child(deck_scroll)
	_deck_list = VBoxContainer.new()
	_deck_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_deck_list.add_theme_constant_override("separation", 3)
	deck_scroll.add_child(_deck_list)

	var play := Button.new()
	play.text = "To the battlefield →"
	play.custom_minimum_size.y = 34
	play.pressed.connect(func() -> void: play_requested.emit())
	right.add_child(play)
	return box

# --- Authentication ---------------------------------------------------------

func _do_login() -> void:
	_auth_status.text = "Signing in…"
	accounts.login(_email_input.text.strip_edges(), _password_input.text)

func _do_register() -> void:
	_auth_status.text = "Creating your account…"
	accounts.register(
		_email_input.text.strip_edges(),
		_name_input.text.strip_edges(),
		_password_input.text
	)

func _on_signed_in(who: Dictionary) -> void:
	_auth_box.visible = false
	_main_box.visible = true
	_who_label.text = str(who.get("displayName", ""))
	accounts.fetch_collection()
	accounts.fetch_decks()
	accounts.fetch_fragments()
	accounts.fetch_packs()

## A saved session is being checked: hide the form so it does not flash away.
func _on_restore_started() -> void:
	_show_server(accounts.http_base)
	_auth_box.visible = true
	_main_box.visible = false
	_auth_form.visible = false
	_saved_box.visible = false
	_auth_status.text = "Signing you back in…"
	_auth_status.remove_theme_color_override("font_color")

## No usable saved session, so fall back to the form. Nothing is said when
## there was simply nothing saved.
func _on_restore_failed(message: String, silent: bool) -> void:
	_auth_form.visible = true
	_render_saved_accounts()
	if silent:
		_auth_status.text = "New accounts start with the starter cards."
		return
	if accounts.restoring != null:
		_ask_password(accounts.restoring.email, message)
		return
	_auth_status.text = message

func _on_sign_in_failed(message: String) -> void:
	_auth_form.visible = true
	_render_saved_accounts()
	_auth_status.text = message
	_auth_status.add_theme_color_override("font_color", Color(0.88, 0.42, 0.45))

func _on_signed_out() -> void:
	_auth_box.visible = true
	_main_box.visible = false
	_auth_form.visible = true
	_render_saved_accounts()
	_auth_status.text = "Signed out."
	collection = []
	decks = []
	draft.clear()
	close_crafting()

# --- Collection -------------------------------------------------------------

func _on_collection_loaded(cards: Array) -> void:
	collection = cards
	_render_collection()
	_render_crafting()

## The cards the pages hold, cheapest first and then by name, as a
## Hearthstone collection is ordered.
##
## Building a deck shows the cards owned that its class may hold; the
## crafting view shows every card, owned or not, of every class.
func visible_entries() -> Array:
	var shown: Array = []
	var needle := search.to_lower()
	for entry in collection:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var card_id := str(entry.get("cardId", ""))
		if not crafting and (int(entry.get("owned", 0)) <= 0 or not _fits_deck_class(entry)):
			continue
		var cost := library.cost(card_id)
		if cost_filter >= 0 and (cost < cost_filter if cost_filter == MAX_COST_FILTER else cost != cost_filter):
			continue
		if needle != "" and not library.card_name(card_id).to_lower().contains(needle):
			continue
		shown.append(entry)
	shown.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var a_id := str(a.get("cardId", ""))
		var b_id := str(b.get("cardId", ""))
		if library.cost(a_id) != library.cost(b_id):
			return library.cost(a_id) < library.cost(b_id)
		return library.card_name(a_id).naturalnocasecmp_to(library.card_name(b_id)) < 0)
	return shown

func page_count() -> int:
	return maxi(1, ceili(visible_entries().size() / float(CARDS_PER_PAGE)))

## The cards on the page showing, in order.
func page_cards() -> Array[CollectionCard]:
	var cards: Array[CollectionCard] = []
	for child in _page_grid.get_children():
		if child is CollectionCard:
			cards.append(child)
	return cards

func _render_collection() -> void:
	_clear(_page_grid)
	var shown := visible_entries()
	var pages := maxi(1, ceili(shown.size() / float(CARDS_PER_PAGE)))
	page = clampi(page, 0, pages - 1)
	for entry in shown.slice(page * CARDS_PER_PAGE, (page + 1) * CARDS_PER_PAGE):
		var card_id := str(entry.get("cardId", ""))
		var tile := CollectionCard.make(library, card_id, int(entry.get("owned", 0)), _look_for(entry))
		tile.tooltip_text = _card_tooltip(entry)
		tile.clicked.connect(_on_card_clicked.bind(card_id))
		_page_grid.add_child(tile)
	if shown.is_empty():
		var empty := Label.new()
		empty.text = "No cards here." if crafting else "No cards here. Cards you own appear here; Crafting shows the rest."
		empty.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
		empty.grow_horizontal = Control.GROW_DIRECTION_BOTH
		empty.grow_vertical = Control.GROW_DIRECTION_BOTH
		_page_grid.add_child(empty)
	_page_label.text = "Page %d / %d" % [page + 1, pages]
	_prev_page.disabled = page <= 0
	_next_page.disabled = page >= pages - 1
	_layout_page()

## Places the page's cards in a grid as large as the space allows, keeping the
## card's shape, with the whole grid centred.
func _layout_page() -> void:
	var cards := page_cards()
	if cards.is_empty() or _page_grid.size.x <= 0.0:
		return
	var rows := ceili(CARDS_PER_PAGE / float(PAGE_COLUMNS))
	var cell := Vector2(
		(_page_grid.size.x - PAGE_GAP * (PAGE_COLUMNS - 1)) / PAGE_COLUMNS,
		(_page_grid.size.y - PAGE_GAP * (rows - 1)) / rows - CollectionCard.COUNT_HEIGHT
	)
	var width := floorf(minf(cell.x, cell.y * CardFrame.ASPECT))
	if width <= 0.0:
		return
	var card_size := Vector2(width, roundf(width / CardFrame.ASPECT))
	var step := card_size + Vector2(PAGE_GAP, PAGE_GAP + CollectionCard.COUNT_HEIGHT)
	var block := step * Vector2(PAGE_COLUMNS, rows) - Vector2(PAGE_GAP, PAGE_GAP)
	var origin := ((_page_grid.size - block) * 0.5).floor()
	for index in cards.size():
		var at := origin + step * Vector2(index % PAGE_COLUMNS, floorf(index / float(PAGE_COLUMNS)))
		cards[index].place(at, card_size)

func _page_arrow(text: String, tip: String, direction: int) -> Button:
	var arrow := Button.new()
	arrow.text = text
	arrow.tooltip_text = tip
	arrow.custom_minimum_size = Vector2(34, 0)
	arrow.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	arrow.add_theme_font_size_override("font_size", 28)
	arrow.pressed.connect(turn_page.bind(direction))
	return arrow

func turn_page(direction: int) -> void:
	var target := clampi(page + direction, 0, page_count() - 1)
	if target == page:
		return
	page = target
	_render_collection()

func _on_page_input(event: InputEvent) -> void:
	var wheel := event as InputEventMouseButton
	if wheel == null or not wheel.pressed:
		return
	if wheel.button_index == MOUSE_BUTTON_WHEEL_UP:
		turn_page(-1)
		_page_grid.accept_event()
	elif wheel.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		turn_page(1)
		_page_grid.accept_event()

func _set_crafting(on: bool) -> void:
	crafting = on
	if _crafting_button.button_pressed != on:
		_crafting_button.set_pressed_no_signal(on)
	page = 0
	if not on:
		close_crafting()
	_update_mode_hint()
	_render_collection()

## Shows only cards of `cost`; choosing the cost already chosen shows them all.
func _set_cost_filter(cost: int) -> void:
	cost_filter = -1 if cost_filter == cost else cost
	for index in _cost_buttons.size():
		_cost_buttons[index].set_pressed_no_signal(index == cost_filter)
	page = 0
	_render_collection()

func _update_mode_hint() -> void:
	if crafting:
		_mode_hint.text = "Crafting: click a card to craft or disenchant it. Glowing cards can be crafted now."
	else:
		_mode_hint.text = "Left-click a card to add it to the deck, right-click to take it out."

## How a card is drawn. Building a deck, a card is darkened once every copy
## the deck may take is in it; crafting, an unowned card glows blue if it can
## be crafted now and is greyed if it cannot.
func _look_for(entry: Dictionary) -> CollectionCard.Look:
	var owned := int(entry.get("owned", 0))
	if crafting:
		if owned > 0:
			return CollectionCard.Look.NORMAL
		return CollectionCard.Look.CRAFTABLE if _can_craft(entry) else CollectionCard.Look.LOCKED
	return CollectionCard.Look.NORMAL if _addable(entry) > 0 else CollectionCard.Look.SPENT

## Whether a copy can be crafted right now: the expansion allows it, the card
## is not Basic, and the balance covers it. The server still decides.
func _can_craft(entry: Dictionary) -> bool:
	return str(entry.get("rarity", "")) != "BASIC" \
		and bool(entry.get("craftable", false)) \
		and fragments >= int(entry.get("craftCost", 0))

## Copies of a card a click could still add to the deck: those owned, up to
## its copy limit, that are not in it yet — none for another class's card.
func _addable(entry: Dictionary) -> int:
	if not _fits_deck_class(entry):
		return 0
	var card_id := str(entry.get("cardId", ""))
	var allowed := mini(int(entry.get("owned", 0)), int(entry.get("copyLimit", 2)))
	return allowed - int(draft.get(card_id, 0))

func _card_tooltip(entry: Dictionary) -> String:
	var card_id := str(entry.get("cardId", ""))
	return "%s\n\n%s\nOwned %d · in deck %d" % [
		library.tooltip(card_id),
		_card_marks(entry),
		int(entry.get("owned", 0)),
		int(draft.get(card_id, 0)),
	]

## Building a deck, a left click adds a copy and a right click takes one out;
## crafting, a left click opens the card's crafting panel.
func _on_card_clicked(button_index: int, card_id: String) -> void:
	var entry := _entry_for(card_id)
	if entry.is_empty():
		return
	if crafting:
		if button_index == MOUSE_BUTTON_LEFT:
			open_crafting(card_id)
		return
	if button_index == MOUSE_BUTTON_LEFT:
		if _addable(entry) > 0:
			_add_card(card_id, int(entry.get("copyLimit", 2)))
	elif button_index == MOUSE_BUTTON_RIGHT and draft.has(card_id):
		_remove_card(card_id)

# --- Crafting panel ---------------------------------------------------------

func _build_craft_overlay() -> Control:
	_craft_overlay = Control.new()
	_craft_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_craft_overlay.visible = false
	# A click on the dimmed page around the panel closes it.
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
			close_crafting())
	_craft_overlay.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_craft_overlay.add_child(center)
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.09, 0.10, 0.13, 0.97)
	style.border_color = Color(0.85, 0.74, 0.44)
	style.set_border_width_all(2)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(18)
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)
	_craft_box = HBoxContainer.new()
	_craft_box.add_theme_constant_override("separation", 18)
	panel.add_child(_craft_box)
	return _craft_overlay

func open_crafting(card_id: String) -> void:
	crafting_card_id = card_id
	_render_crafting()

func close_crafting() -> void:
	crafting_card_id = ""
	_render_crafting()

func _unhandled_input(event: InputEvent) -> void:
	if _craft_overlay.visible and event.is_action_pressed("ui_cancel"):
		close_crafting()
		get_viewport().set_input_as_handled()

## Draws the open card large, with what is owned and the buttons to craft
## and disenchant it; redrawn as the collection and balance change under it.
func _render_crafting() -> void:
	_clear(_craft_box)
	var entry := _entry_for(crafting_card_id) if crafting_card_id != "" else {}
	_craft_overlay.visible = not entry.is_empty()
	if entry.is_empty():
		return
	var card_id := crafting_card_id
	var frame := CardFrame.make(library, {"definition_id": card_id}, CRAFT_CARD_WIDTH, true)
	_craft_box.add_child(frame)

	var side := VBoxContainer.new()
	side.custom_minimum_size.x = 240
	side.alignment = BoxContainer.ALIGNMENT_CENTER
	side.add_theme_constant_override("separation", 10)
	_craft_box.add_child(side)
	var title := Label.new()
	title.text = library.card_name(card_id)
	title.add_theme_font_size_override("font_size", 20)
	side.add_child(title)
	var marks := Label.new()
	marks.text = _card_marks(entry)
	marks.add_theme_color_override("font_color", Color(0.66, 0.69, 0.76))
	side.add_child(marks)
	# Rules too long for the card's box are printed here in full.
	if not frame.rules_fit:
		var rules := RichTextLabel.new()
		rules.bbcode_enabled = true
		rules.fit_content = true
		rules.text = library.description_bbcode(card_id)
		side.add_child(rules)
	var owned := Label.new()
	owned.text = "You own %d · a deck may hold %d" % [
		int(entry.get("owned", 0)), int(entry.get("copyLimit", 2)),
	]
	side.add_child(owned)
	side.add_child(_craft_controls(entry))
	var balance := Label.new()
	balance.text = "%d Fragments" % fragments
	balance.add_theme_font_size_override("font_size", 12)
	balance.add_theme_color_override("font_color", Color(0.66, 0.69, 0.76))
	side.add_child(balance)
	var close := Button.new()
	close.text = "Close"
	close.pressed.connect(close_crafting)
	side.add_child(close)

## The Craft and Disenchant buttons for a card, each enabled only where the
## server's policies and the balance allow.
func _craft_controls(entry: Dictionary) -> HBoxContainer:
	var card_id := str(entry.get("cardId", ""))
	var owned := int(entry.get("owned", 0))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	# Crafting and disenchanting are offered only where the server says the
	# expansion currently allows them. This is presentation: the server refuses
	# the request anyway, and a policy may change between drawing and clicking.
	# A Basic card is refused for a reason of its own, so it says so.
	var is_basic := str(entry.get("rarity", "")) == "BASIC"
	var craft := Button.new()
	craft.text = "Craft %d" % int(entry.get("craftCost", 0))
	craft.tooltip_text = "Spend Fragments to make one copy"
	if is_basic:
		craft.text = "Craft"
		craft.disabled = true
		craft.tooltip_text = "Basic cards are free to everyone and cannot be crafted"
	elif not bool(entry.get("craftable", false)):
		craft.disabled = true
		craft.tooltip_text = "Crafting is not available for this expansion right now"
	elif fragments < int(entry.get("craftCost", 0)):
		craft.disabled = true
		craft.tooltip_text = "Not enough Fragments"
	craft.pressed.connect(func() -> void: accounts.craft_card(card_id, 1))
	row.add_child(craft)

	var dust := Button.new()
	dust.text = "+%d" % int(entry.get("disenchantValue", 0))
	dust.tooltip_text = "Disenchant one copy for Fragments"
	if is_basic:
		dust.text = "+0"
		dust.disabled = true
		dust.tooltip_text = "Basic cards are free to everyone and cannot be disenchanted"
	elif not bool(entry.get("disenchantable", false)):
		dust.disabled = true
		dust.tooltip_text = "Disenchanting is not available for this expansion right now"
	elif owned <= 0:
		dust.disabled = true
		dust.tooltip_text = "You own none of this card"
	dust.pressed.connect(func() -> void: accounts.disenchant_card(card_id, 1))
	row.add_child(dust)
	return row

## "[Wizard · Common]": a card's class, if it has one, and its rarity.
func _card_marks(entry: Dictionary) -> String:
	var parts: Array[String] = []
	var class_id := str(entry.get("classId", ""))
	if class_id != "" and class_id != "<null>":
		parts.append(_class_name(class_id))
	var rarity := str(entry.get("rarity", ""))
	if rarity != "":
		parts.append(rarity.capitalize())
	return "[%s]" % " · ".join(parts) if not parts.is_empty() else ""

## The class of the deck being edited: its hero's.
func _deck_class() -> String:
	return str(HERO_CLASSES.get(selected_hero, ""))

## Whether the deck being edited may hold this card: neutral cards always,
## class cards only in their own class's deck.
func _fits_deck_class(entry: Dictionary) -> bool:
	var class_id: Variant = entry.get("classId", null)
	if class_id == null or str(class_id) == "":
		return true
	return str(class_id) == _deck_class()

func _class_name(class_id: String) -> String:
	return str(CLASS_NAMES.get(class_id, class_id.capitalize()))

func _entry_for(card_id: String) -> Dictionary:
	for entry in collection:
		if typeof(entry) == TYPE_DICTIONARY and str(entry.get("cardId", "")) == card_id:
			return entry
	return {}

func _add_card(card_id: String, limit: int) -> void:
	var current := int(draft.get(card_id, 0))
	if current >= limit:
		return
	draft[card_id] = current + 1
	_render_draft()

func _remove_card(card_id: String) -> void:
	if not draft.has(card_id):
		return
	var current := int(draft.get(card_id, 0))
	if current <= 1:
		draft.erase(card_id)
	else:
		draft[card_id] = current - 1
	_render_draft()

# --- Deck draft -------------------------------------------------------------

func draft_card_ids() -> Array:
	var ids: Array = []
	for card_id in draft:
		for i in range(int(draft[card_id])):
			ids.append(card_id)
	return ids

func _render_draft() -> void:
	_clear(_draft_list)
	var total := 0
	# In cost order, as the collection's pages are.
	var keys := draft.keys()
	keys.sort_custom(func(a: Variant, b: Variant) -> bool:
		if library.cost(str(a)) != library.cost(str(b)):
			return library.cost(str(a)) < library.cost(str(b))
		return library.card_name(str(a)).naturalnocasecmp_to(library.card_name(str(b))) < 0)
	for card_id in keys:
		var count := int(draft[card_id])
		total += count
		var row := HBoxContainer.new()
		var label := Label.new()
		label.text = "%d× %s" % [count, library.card_name(str(card_id))]
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		# Flag copies beyond what the player owns, per-card.
		var owned := _owned_count(str(card_id))
		if owned < count:
			label.text += "   (own %d)" % owned
			label.add_theme_color_override("font_color", Color(0.93, 0.62, 0.40))
		# A card left over from before the hero changed, of the other class.
		var entry := _entry_for(str(card_id))
		if not entry.is_empty() and not _fits_deck_class(entry):
			label.text += "   (%s card)" % _class_name(str(entry.get("classId", "")))
			label.add_theme_color_override("font_color", Color(0.88, 0.42, 0.45))
		row.add_child(label)
		var minus := Button.new()
		minus.text = "−"
		minus.pressed.connect(_remove_card.bind(str(card_id)))
		row.add_child(minus)
		_draft_list.add_child(row)

	_count_label.text = "%d / 30 cards" % total
	_count_label.add_theme_color_override(
		"font_color", Color(0.45, 0.85, 0.55) if total == 30 else Color(0.93, 0.62, 0.40)
	)
	_render_collection()
	_request_readiness()

## Asks the server for the authoritative verdict, in the chosen format and as
## the chosen hero's class.
func _request_readiness() -> void:
	if draft.is_empty():
		_readiness_label.text = "Add cards to build a deck."
		return
	accounts.assess(draft_card_ids(), selected_format, selected_hero)

func _owned_count(card_id: String) -> int:
	for entry in collection:
		if typeof(entry) == TYPE_DICTIONARY and str(entry.get("cardId", "")) == card_id:
			return int(entry.get("owned", 0))
	return 0

func _on_readiness(readiness: Dictionary) -> void:
	_readiness_label.text = _readiness_text(readiness)

## Formats the server's verdict: rule problems and ownership problems apart.
func _readiness_text(readiness: Dictionary) -> String:
	if readiness.is_empty():
		return ""
	if bool(readiness.get("playable", false)):
		return "[color=#7fd88c]Ready to play.[/color]"
	var lines: Array[String] = ["[color=#e8a06a]Not ready:[/color]"]
	var rule_errors: Variant = readiness.get("ruleErrors", [])
	if typeof(rule_errors) == TYPE_ARRAY:
		for problem in (rule_errors as Array):
			lines.append("• " + str(problem))
	var missing: Variant = readiness.get("missing", [])
	if typeof(missing) == TYPE_ARRAY:
		for entry in (missing as Array):
			if typeof(entry) != TYPE_DICTIONARY:
				continue
			lines.append("• %s: needs %d, you own %d" % [
				library.card_name(str(entry.get("cardId", ""))),
				int(entry.get("required", 0)),
				int(entry.get("owned", 0)),
			])
	# Rotation is called out separately, and worded as something that happened
	# to the deck rather than something wrong with it: these cards were legal
	# when the deck was built, and it is still perfectly good in Wild.
	var illegal: Variant = readiness.get("illegalInFormat", [])
	if typeof(illegal) == TYPE_ARRAY and not (illegal as Array).is_empty():
		var copies := 0
		var names: Array[String] = []
		for entry in (illegal as Array):
			if typeof(entry) != TYPE_DICTIONARY:
				continue
			copies += int((entry as Dictionary).get("copies", 0))
			names.append(library.card_name(str((entry as Dictionary).get("cardId", ""))))
		var format := str(readiness.get("format", selected_format))
		lines.append("[color=#e8c06a]⚠ %d card%s no longer legal in %s: %s[/color]" % [
			copies,
			"" if copies == 1 else "s",
			format.capitalize(),
			", ".join(names),
		])
		if format == "STANDARD":
			lines.append("  This deck can still be played in Wild.")
	return "\n".join(lines)

## Tops the deck up to 30 using only cards the player actually owns.
func _autofill() -> void:
	for entry in collection:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		# Only cards this deck's class may hold: filling with the other class's
		# cards would build a deck the server is certain to refuse.
		if not _fits_deck_class(entry):
			continue
		var card_id := str(entry.get("cardId", ""))
		var owned := int(entry.get("owned", 0))
		while int(draft.get(card_id, 0)) < owned and draft_card_ids().size() < 30:
			draft[card_id] = int(draft.get(card_id, 0)) + 1
		if draft_card_ids().size() >= 30:
			break
	_render_draft()

func _save_draft() -> void:
	var name := _draft_name.text.strip_edges()
	if name.is_empty():
		_readiness_label.text = "[color=#e06c75]Give the deck a name first.[/color]"
		return
	accounts.save_deck(name, selected_hero, draft_card_ids(), editing_deck_id, selected_format)

func _on_deck_saved(_deck: Dictionary) -> void:
	accounts.fetch_decks()

func _on_deck_error(message: String) -> void:
	_readiness_label.text = "[color=#e06c75]%s[/color]" % message

# --- Saved decks ------------------------------------------------------------

func _on_decks_loaded(list: Array) -> void:
	decks = list
	_render_decks()

func _render_decks() -> void:
	_clear(_deck_list)
	if decks.is_empty():
		var empty := Label.new()
		empty.text = "(no saved decks yet)"
		_deck_list.add_child(empty)
		return
	for deck in decks:
		if typeof(deck) != TYPE_DICTIONARY:
			continue
		_deck_list.add_child(_deck_row(deck))

func _deck_row(deck: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 5)

	var readiness: Variant = deck.get("readiness", {})
	var playable := typeof(readiness) == TYPE_DICTIONARY \
		and bool((readiness as Dictionary).get("playable", false))
	var cards: Variant = deck.get("cardIds", [])
	var size := (cards as Array).size() if typeof(cards) == TYPE_ARRAY else 0

	var label := Label.new()
	var mark := "✓" if playable else "!"
	label.text = "%s %s  (%d)" % [mark, str(deck.get("name", "deck")), size]
	if bool(deck.get("isActive", false)):
		label.text += "  ★ active"
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_color_override(
		"font_color", Color(0.75, 0.85, 0.78) if playable else Color(0.93, 0.62, 0.40)
	)
	if typeof(readiness) == TYPE_DICTIONARY:
		# The full explanation is one hover away.
		label.tooltip_text = _plain_readiness(readiness as Dictionary)
	row.add_child(label)

	var edit := Button.new()
	edit.text = "Edit"
	edit.pressed.connect(_load_deck.bind(deck))
	row.add_child(edit)

	var use := Button.new()
	use.text = "Use"
	use.disabled = not playable
	use.tooltip_text = "Only a ready deck can be your active deck." if not playable else ""
	use.pressed.connect(func() -> void: accounts.set_active_deck(str(deck.get("id", ""))))
	row.add_child(use)

	var remove := Button.new()
	remove.text = "✕"
	remove.pressed.connect(func() -> void: accounts.delete_deck(str(deck.get("id", ""))))
	row.add_child(remove)
	return row

func _plain_readiness(readiness: Dictionary) -> String:
	if bool(readiness.get("playable", false)):
		return "Ready to play."
	var lines: Array[String] = []
	var rule_errors: Variant = readiness.get("ruleErrors", [])
	if typeof(rule_errors) == TYPE_ARRAY:
		for problem in (rule_errors as Array):
			lines.append(str(problem))
	var missing: Variant = readiness.get("missing", [])
	if typeof(missing) == TYPE_ARRAY:
		for entry in (missing as Array):
			if typeof(entry) == TYPE_DICTIONARY:
				lines.append("%s: needs %d, owns %d" % [
					library.card_name(str(entry.get("cardId", ""))),
					int(entry.get("required", 0)),
					int(entry.get("owned", 0)),
				])
	return "\n".join(lines) if not lines.is_empty() else "Not ready."

func _load_deck(deck: Dictionary) -> void:
	draft.clear()
	var cards: Variant = deck.get("cardIds", [])
	if typeof(cards) == TYPE_ARRAY:
		for card_id in (cards as Array):
			var key := str(card_id)
			draft[key] = int(draft.get(key, 0)) + 1
	editing_deck_id = str(deck.get("id", ""))
	_draft_name.text = str(deck.get("name", ""))
	selected_hero = str(deck.get("heroId", "healer"))
	_hero_picker.select(1 if selected_hero == "striker" else 0)
	_render_draft()

func _clear(node: Node) -> void:
	for child in node.get_children():
		node.remove_child(child)
		child.queue_free()

# --- Fragments, crafting and packs ------------------------------------------
#
# Nothing here decides anything. The balance shown is the one the server last
# reported, the buttons are enabled from the policies it sent with each card,
# and every refusal is the server's own — the client only has to say it well.

func _on_fragments_changed(balance: int) -> void:
	fragments = balance
	_fragments_label.text = "%d Fragments" % balance
	# Affordability is drawn from the balance, so the cards follow it.
	_render_collection()
	_render_crafting()

func _on_economy_result(operation: String, result: Dictionary) -> void:
	match operation:
		"CRAFT":
			_economy_status.text = "Crafted %d × %s." % [
				int(result.get("quantity", 1)),
				library.card_name(str(result.get("cardId", ""))),
			]
		"DISENCHANT":
			_economy_status.text = "Disenchanted %d × %s for %d Fragments." % [
				int(result.get("quantity", 1)),
				library.card_name(str(result.get("cardId", ""))),
				int(result.get("fragmentDelta", 0)),
			]
		"DISENCHANT_EXTRAS":
			var disenchanted: Variant = result.get("disenchanted", [])
			var count := (disenchanted as Array).size() if typeof(disenchanted) == TYPE_ARRAY else 0
			_economy_status.text = "Disenchanted spares of %d card%s for %d Fragments." % [
				count,
				"" if count == 1 else "s",
				int(result.get("fragmentDelta", 0)),
			]
			# Spares the server declined to touch are named, so a skipped card
			# does not simply look forgotten.
			var skipped: Variant = result.get("skipped", [])
			if typeof(skipped) == TYPE_ARRAY and not (skipped as Array).is_empty():
				var names: Array[String] = []
				for entry in (skipped as Array):
					if typeof(entry) == TYPE_DICTIONARY:
						names.append(library.card_name(str((entry as Dictionary).get("cardId", ""))))
				_economy_status.text += "  Left alone: %s." % ", ".join(names)
		_:
			_economy_status.text = "Done."
	_economy_status.remove_theme_color_override("font_color")
	# The collection changed, so re-read it rather than guessing at the new counts.
	accounts.fetch_collection()

## Explains a refusal in the client's own words, keyed on the server's code.
##
## The code is what travels; the sentence is ours. A message written on the
## server would be the wrong one to show as soon as this screen is translated.
func _on_economy_refused(code: String, message: String) -> void:
	var explanation := message
	match code:
		"CARD_NOT_CRAFTABLE":
			explanation = "Crafting is not available for that expansion right now."
		"CARD_NOT_DISENCHANTABLE":
			explanation = "Disenchanting is not available for that expansion right now."
		"BASIC_CARD":
			explanation = "Basic cards are free to everyone, so they cannot be crafted or disenchanted."
		"EXPANSION_NOT_RELEASED":
			explanation = "That card is not available."
		"EXPANSION_NOT_AVAILABLE_IN_PACKS":
			explanation = "Those packs are not available right now."
		"INSUFFICIENT_FRAGMENTS":
			explanation = "You do not have enough Fragments."
		"INSUFFICIENT_CARD_QUANTITY":
			explanation = "You do not own that many copies."
		"UNREACHABLE":
			explanation = "Could not reach the server."
	_economy_status.text = explanation
	_economy_status.add_theme_color_override("font_color", Color(0.88, 0.42, 0.45))
	# A refusal may mean the policy moved under us, so re-read what is true now.
	accounts.fetch_collection()
	accounts.fetch_packs()

func _on_packs_loaded(list: Array) -> void:
	available_packs = list
	_render_packs()

func _render_packs() -> void:
	_clear(_pack_row)
	if available_packs.is_empty():
		var none := Label.new()
		none.text = "(no packs available)"
		none.add_theme_font_size_override("font_size", 11)
		_pack_row.add_child(none)
	else:
		for pack in available_packs:
			if typeof(pack) != TYPE_DICTIONARY:
				continue
			var button := Button.new()
			button.text = "Open %s" % str((pack as Dictionary).get("name", "Pack"))
			var pack_id := str((pack as Dictionary).get("id", ""))
			button.pressed.connect(func() -> void: accounts.open_pack(pack_id))
			_pack_row.add_child(button)

	# Disenchanting spares is always an explicit request, never something that
	# happens because the server noticed them.
	var extras := Button.new()
	extras.text = "Disenchant spares"
	extras.tooltip_text = "Turn every copy above the playable limit into Fragments"
	extras.pressed.connect(func() -> void: accounts.disenchant_extras())
	_pack_row.add_child(extras)

func _on_pack_opened(pack: Dictionary) -> void:
	var cards: Variant = pack.get("cards", [])
	var names: Array[String] = []
	if typeof(cards) == TYPE_ARRAY:
		for slot in (cards as Array):
			if typeof(slot) != TYPE_DICTIONARY:
				continue
			names.append(library.card_name(str((slot as Dictionary).get("cardId", ""))))
	_economy_status.text = "Opened %s: %s" % [
		str(pack.get("packId", "pack")),
		", ".join(names),
	]
	_economy_status.remove_theme_color_override("font_color")
	accounts.fetch_collection()

## Offers the admin panel or hides it; the main scene decides, from who is
## signed in and whether the admin UI is switched on.
func set_admin_available(available: bool) -> void:
	if _admin_button != null:
		_admin_button.visible = available
