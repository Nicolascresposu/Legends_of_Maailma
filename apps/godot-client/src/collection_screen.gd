extends Control
class_name CollectionScreen

## Sign-in, collection browsing and deck building.
##
## The server owns ownership and legality: this screen shows what the player
## owns, lets them assemble a list, and reports the readiness the server
## computes. It never decides for itself whether a deck may be played.

signal play_requested()
signal closed()
## The player pointed the client at a different server.
signal server_changed(http_base: String)

const CARD_TILE := Vector2(190, 104)

var accounts: AccountClient
var library: CardLibrary

var collection: Array = []
var decks: Array = []
## Card id -> copies currently in the deck being edited.
var draft: Dictionary = {}
var editing_deck_id := ""
var selected_hero := "healer"

var _root: VBoxContainer
var _auth_box: VBoxContainer
## The inputs and buttons, hidden while a saved session is being checked.
var _auth_form: HBoxContainer
var _server_input: LineEdit
var _main_box: HBoxContainer
var _email_input: LineEdit
var _name_input: LineEdit
var _password_input: LineEdit
var _auth_status: Label
var _who_label: Label
var _card_list: VBoxContainer
var _deck_list: VBoxContainer
var _draft_list: VBoxContainer
var _draft_name: LineEdit
var _hero_picker: OptionButton
var _readiness_label: RichTextLabel
var _count_label: Label

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

func _build_auth() -> Control:
	_auth_box = VBoxContainer.new()
	_auth_box.add_theme_constant_override("separation", 6)

	var title := Label.new()
	title.text = "Maailma — sign in"
	title.add_theme_font_size_override("font_size", 20)
	_auth_box.add_child(title)

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

	_auth_status = Label.new()
	_auth_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_auth_status.text = "New accounts start with the starter cards."
	_auth_box.add_child(_auth_status)
	return _auth_box

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
	_who_label = Label.new()
	header.add_child(_who_label)
	var sign_out := Button.new()
	sign_out.text = "Sign out"
	sign_out.pressed.connect(func() -> void: accounts.sign_out())
	header.add_child(sign_out)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.add_child(scroll)
	_card_list = VBoxContainer.new()
	_card_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_card_list.add_theme_constant_override("separation", 4)
	scroll.add_child(_card_list)

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
		func(index: int) -> void: selected_hero = "striker" if index == 1 else "healer"
	)
	name_row.add_child(_hero_picker)

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

## A saved session is being checked: hide the form so it does not flash away.
func _on_restore_started() -> void:
	_auth_box.visible = true
	_main_box.visible = false
	_auth_form.visible = false
	_auth_status.text = "Signing you back in…"
	_auth_status.remove_theme_color_override("font_color")

## No usable saved session, so fall back to the form. Nothing is said when
## there was simply nothing saved.
func _on_restore_failed(message: String, silent: bool) -> void:
	_auth_form.visible = true
	if silent:
		_auth_status.text = "New accounts start with the starter cards."
		return
	_auth_status.text = message

func _on_sign_in_failed(message: String) -> void:
	_auth_form.visible = true
	_auth_status.text = message
	_auth_status.add_theme_color_override("font_color", Color(0.88, 0.42, 0.45))

func _on_signed_out() -> void:
	_auth_box.visible = true
	_main_box.visible = false
	_auth_status.text = "Signed out."
	collection = []
	decks = []
	draft.clear()

# --- Collection -------------------------------------------------------------

func _on_collection_loaded(cards: Array) -> void:
	collection = cards
	_render_collection()

func _render_collection() -> void:
	_clear(_card_list)
	for entry in collection:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		_card_list.add_child(_collection_row(entry))

func _collection_row(entry: Dictionary) -> Control:
	var card_id := str(entry.get("cardId", ""))
	var owned := int(entry.get("owned", 0))
	var limit := int(entry.get("copyLimit", 2))
	var in_deck := int(draft.get(card_id, 0))

	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	# Unowned cards stay visible but read as locked.
	style.bg_color = Color(0.17, 0.28, 0.22) if owned > 0 else Color(0.20, 0.17, 0.19)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(6)
	panel.add_theme_stylebox_override("panel", style)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	panel.add_child(row)

	# The collection is a list of rows, so art reads better as a thumbnail here
	# than as the banner used on a card tile.
	var art := CardArt.texture_for(card_id)
	if art != null:
		var thumb := TextureRect.new()
		thumb.texture = art
		thumb.custom_minimum_size = Vector2(52, 34)
		thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		thumb.clip_contents = true
		thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		# An unowned card's art is dimmed alongside its text.
		if owned == 0:
			thumb.modulate = Color(0.55, 0.55, 0.60)
		row.add_child(thumb)

	var label := Label.new()
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var kind := library.card_type(card_id)
	var stats := ""
	if kind == "CREATURE":
		stats = "  %d/%d" % [library.base_attack(card_id), library.base_health(card_id)]
	label.text = "%s   %d Taika%s" % [library.card_name(card_id), library.cost(card_id), stats]
	if owned == 0:
		label.modulate = Color(0.70, 0.70, 0.74)
	row.add_child(label)

	var owned_label := Label.new()
	owned_label.text = "owned %d/%d" % [owned, limit]
	owned_label.add_theme_font_size_override("font_size", 11)
	row.add_child(owned_label)

	var in_deck_label := Label.new()
	in_deck_label.text = "in deck %d" % in_deck
	in_deck_label.add_theme_font_size_override("font_size", 11)
	row.add_child(in_deck_label)

	var add := Button.new()
	add.text = "+"
	add.tooltip_text = library.tooltip(card_id)
	# A card may be added up to its copy limit even when unowned: the deck is
	# saved either way, and readiness explains what is missing.
	add.disabled = in_deck >= limit
	add.pressed.connect(_add_card.bind(card_id, limit))
	row.add_child(add)

	var remove := Button.new()
	remove.text = "−"
	remove.disabled = in_deck <= 0
	remove.pressed.connect(_remove_card.bind(card_id))
	row.add_child(remove)
	return panel

func _add_card(card_id: String, limit: int) -> void:
	var current := int(draft.get(card_id, 0))
	if current >= limit:
		return
	draft[card_id] = current + 1
	_render_draft()

func _remove_card(card_id: String) -> void:
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
	var keys := draft.keys()
	keys.sort()
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
	# Ask the server for the authoritative verdict.
	if total > 0:
		accounts.assess(draft_card_ids())
	else:
		_readiness_label.text = "Add cards to build a deck."

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
	return "\n".join(lines)

## Tops the deck up to 30 using only cards the player actually owns.
func _autofill() -> void:
	for entry in collection:
		if typeof(entry) != TYPE_DICTIONARY:
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
	accounts.save_deck(name, selected_hero, draft_card_ids(), editing_deck_id)

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
