extends Control

## Maailma TCG presentation client.
##
## The client renders state and offers the server's legal actions. It never
## decides legality: dragging a card or creature only ever offers targets the
## server has already declared legal, and every choice is sent for validation.
##
## Interaction follows Hearthstone's model. Press a hand card or one of your
## creatures and drag: valid destinations light up, a dotted arrow follows the
## cursor, and releasing over a lit destination commits the action. A plain
## click selects instead, so the same move works without holding the button.

const SLOT_SIZE := Vector2(148, 112)
const CARD_SIZE := Vector2(132, 132)
const ARTIFACT_TILE := Vector2(92, 84)
const MAX_LOG_LINES := 120
## Pointer travel before a press becomes a drag rather than a click.
const DRAG_THRESHOLD := 10.0

const COLOR_EMPTY := Color(0.16, 0.17, 0.21)
const COLOR_FRIENDLY := Color(0.16, 0.30, 0.24)
const COLOR_ENEMY := Color(0.34, 0.18, 0.20)
const COLOR_SELECTED := Color(0.95, 0.76, 0.28)
const COLOR_TARGET := Color(0.38, 0.62, 0.90)
const COLOR_READY := Color(0.45, 0.85, 0.55)
const COLOR_HOVER := Color(0.62, 0.82, 1.0)

var client: MatchClient
var accounts: AccountClient
var library := CardLibrary.new()
var collection_screen: CollectionScreen
var game_root: Control
## The active deck fetched for the signed-in player, empty when playing
## anonymously. Falls back to the starter list so the client still works
## without an account.
var active_deck_cards: Array = []
var active_deck_hero := ""

var state: Dictionary = {}
var legal_actions: Array = []
var player_id := "player-a"
var opponent_id := ""
var log_lines: Array[String] = []

## Current selection: either a hand card instance id or a board entity id.
var selected_card := ""
var selected_entity := ""
## Destinations the selection can commit to, rebuilt whenever it changes.
var slot_targets: Dictionary = {}
var entity_targets: Dictionary = {}

## Drag state. `_press_origin` is in this Control's coordinate space.
var _pressed_source := ""
var _pressed_is_card := false
var _press_origin := Vector2.ZERO
var _dragging := false
var _hovered_key := ""

## Screen rects of every droppable thing, rebuilt after each layout pass.
## Maps a target key to {rect, kind, id, valid}.
var _drop_zones: Dictionary = {}

var status_label: Label
var connection_dot: Panel
var turn_banner: Label
var match_input: LineEdit
var player_input: LineEdit
var server_input: LineEdit
var hero_selector: OptionButton
var board_container: VBoxContainer
var hand_container: HBoxContainer
var action_container: VBoxContainer
var action_hint: Label
var log_label: RichTextLabel
var end_turn_button: Button
var create_pvp_button: Button
var create_pve_button: Button
var join_button: Button
var arrow: TargetingArrow

func _ready() -> void:
	client = MatchClient.new()
	add_child(client)
	client.connection_changed.connect(_on_connection_changed)
	client.match_state_received.connect(_on_match_state)
	client.legal_actions_received.connect(_on_legal_actions)
	client.game_events_received.connect(_on_game_events)
	client.match_ended.connect(_on_match_ended)
	client.server_error.connect(_on_server_error)
	client.match_created.connect(_on_match_created)
	client.cards_received.connect(func(payload: Variant) -> void: library.ingest(payload))
	client.request_failed.connect(func(detail: String) -> void: _set_status(detail, true))
	library.loaded.connect(_on_library_loaded)

	accounts = AccountClient.new()
	add_child(accounts)
	accounts.signed_in.connect(_on_signed_in)
	accounts.signed_out.connect(_on_account_signed_out)
	accounts.decks_loaded.connect(_on_decks_loaded)

	_build_interface()

	# Accounts are optional: the collection screen opens first, but the match
	# view is still reachable without signing in.
	collection_screen = CollectionScreen.new()
	add_child(collection_screen)
	collection_screen.setup(accounts, library)
	collection_screen.play_requested.connect(_show_match_view)
	_show_collection_view()

	client.fetch_cards()
	# Resume a session saved by a previous run, if there is one. The collection
	# screen shows the sign-in form when there is not.
	accounts.restore_session()

# --- Interface construction -------------------------------------------------

func _build_interface() -> void:
	# Everything the match view owns hangs off `game_root`, so the collection
	# screen can replace it wholesale.
	game_root = Control.new()
	game_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	game_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(game_root)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 14)
	game_root.add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	margin.add_child(root)

	root.add_child(_build_connection_bar())
	root.add_child(_build_status_bar())

	var game_row := HBoxContainer.new()
	game_row.add_theme_constant_override("separation", 12)
	game_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(game_row)

	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 8)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.size_flags_vertical = Control.SIZE_EXPAND_FILL
	game_row.add_child(left)

	var board_scroll := ScrollContainer.new()
	board_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	board_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	left.add_child(board_scroll)
	board_container = VBoxContainer.new()
	board_container.add_theme_constant_override("separation", 6)
	board_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	board_scroll.add_child(board_container)

	left.add_child(_section_title("Your hand"))
	var hand_scroll := ScrollContainer.new()
	hand_scroll.custom_minimum_size.y = CARD_SIZE.y + 18
	hand_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	hand_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	left.add_child(hand_scroll)
	hand_container = HBoxContainer.new()
	hand_container.add_theme_constant_override("separation", 6)
	hand_scroll.add_child(hand_container)

	game_row.add_child(_build_side_panel())

	# The arrow sits above everything and never takes pointer input.
	arrow = TargetingArrow.new()
	game_root.add_child(arrow)

func _build_connection_bar() -> Control:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 6)

	connection_dot = Panel.new()
	connection_dot.custom_minimum_size = Vector2(14, 14)
	connection_dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_tint(connection_dot, Color(0.55, 0.55, 0.58))
	bar.add_child(connection_dot)

	server_input = LineEdit.new()
	server_input.text = client.http_base
	server_input.tooltip_text = "Server address"
	server_input.custom_minimum_size.x = 170
	bar.add_child(server_input)

	player_input = LineEdit.new()
	player_input.text = player_id
	player_input.placeholder_text = "Player ID"
	player_input.custom_minimum_size.x = 110
	bar.add_child(player_input)

	hero_selector = OptionButton.new()
	hero_selector.add_item("The Mender (heal)", 0)
	hero_selector.add_item("The Striker (burn)", 1)
	hero_selector.tooltip_text = "Chosen when you create or first join a match."
	bar.add_child(hero_selector)

	match_input = LineEdit.new()
	match_input.placeholder_text = "Match ID — paste to join an existing match"
	match_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(match_input)

	var copy_button := Button.new()
	copy_button.text = "Copy ID"
	copy_button.tooltip_text = "Copy the match ID so a second client can join."
	copy_button.pressed.connect(_copy_match_id)
	bar.add_child(copy_button)

	join_button = Button.new()
	join_button.text = "Join"
	join_button.pressed.connect(_join_match)
	bar.add_child(join_button)

	create_pvp_button = Button.new()
	create_pvp_button.text = "Create PvP"
	create_pvp_button.pressed.connect(_create_match.bind("STANDARD_PVP"))
	bar.add_child(create_pvp_button)

	create_pve_button = Button.new()
	create_pve_button.text = "Create Bandit Ambush"
	create_pve_button.pressed.connect(_create_match.bind("BANDIT_AMBUSH"))
	bar.add_child(create_pve_button)

	var collection_button := Button.new()
	collection_button.text = "Collection"
	collection_button.tooltip_text = "Sign in, browse your cards and build decks."
	collection_button.pressed.connect(_show_collection_view)
	bar.add_child(collection_button)
	return bar

func _build_status_bar() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	turn_banner = Label.new()
	turn_banner.text = "No match yet"
	turn_banner.add_theme_font_size_override("font_size", 17)
	box.add_child(turn_banner)
	status_label = Label.new()
	status_label.text = "Start the Node server (npm run dev), then create or join a match."
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(status_label)
	return box

func _build_side_panel() -> Control:
	var panel := VBoxContainer.new()
	panel.add_theme_constant_override("separation", 8)
	panel.custom_minimum_size.x = 340
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL

	end_turn_button = Button.new()
	end_turn_button.text = "End Turn"
	end_turn_button.custom_minimum_size.y = 36
	end_turn_button.disabled = true
	end_turn_button.pressed.connect(_end_turn)
	panel.add_child(end_turn_button)

	panel.add_child(_section_title("Available actions"))
	action_hint = Label.new()
	action_hint.text = "Drag a card onto the board, or drag one of your creatures onto a target."
	action_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	action_hint.add_theme_font_size_override("font_size", 11)
	panel.add_child(action_hint)

	var action_scroll := ScrollContainer.new()
	action_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	action_scroll.custom_minimum_size.y = 200
	panel.add_child(action_scroll)
	action_container = VBoxContainer.new()
	action_container.add_theme_constant_override("separation", 4)
	action_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	action_scroll.add_child(action_container)

	panel.add_child(_section_title("Match log"))
	log_label = RichTextLabel.new()
	log_label.bbcode_enabled = true
	log_label.scroll_following = true
	log_label.custom_minimum_size.y = 180
	log_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(log_label)
	return panel

## JSON numbers arrive as floats; render whole numbers without a decimal point.
func _num(value: Variant) -> String:
	match typeof(value):
		TYPE_FLOAT:
			return str(int(round(value as float)))
		TYPE_INT:
			return str(value)
	return str(value)

func _section_title(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 14)
	return label

func _show_collection_view() -> void:
	collection_screen.visible = true
	game_root.visible = false
	_cancel_drag()

func _show_match_view() -> void:
	collection_screen.visible = false
	game_root.visible = true
	# Play with whatever the player has selected as active.
	if accounts.is_signed_in():
		accounts.fetch_decks()

func _on_signed_in(who: Dictionary) -> void:
	# The account's display name is the player id the server will use.
	player_id = str(who.get("id", player_id))
	player_input.text = str(who.get("displayName", player_id))
	player_input.editable = false
	_set_status("Signed in as %s." % str(who.get("displayName", "")))

func _on_account_signed_out() -> void:
	player_input.editable = true
	active_deck_cards = []
	active_deck_hero = ""

func _on_decks_loaded(list: Array) -> void:
	# Remember the active deck so matches use it instead of the starter list.
	active_deck_cards = []
	active_deck_hero = ""
	for deck in list:
		if typeof(deck) != TYPE_DICTIONARY:
			continue
		if not bool(deck.get("isActive", false)):
			continue
		var readiness: Variant = deck.get("readiness", {})
		var playable := typeof(readiness) != TYPE_DICTIONARY 			or bool((readiness as Dictionary).get("playable", true))
		if not playable:
			_set_status("Your active deck is not ready; using the starter deck.", true)
			return
		var cards: Variant = deck.get("cardIds", [])
		if typeof(cards) == TYPE_ARRAY:
			active_deck_cards = (cards as Array).duplicate()
		active_deck_hero = str(deck.get("heroId", ""))
		return

# --- Connection actions -----------------------------------------------------

func _create_match(scenario_id: String) -> void:
	_apply_inputs()
	if player_id.is_empty():
		_set_status("Enter a Player ID first.", true)
		return
	_set_status("Creating match…")
	var deck := active_deck_cards if not active_deck_cards.is_empty() else _starter_deck()
	var hero := active_deck_hero if active_deck_hero != "" else _selected_hero_id()
	client.create_match(scenario_id, player_id, hero, deck)

func _on_match_created(new_match_id: String) -> void:
	match_input.text = new_match_id
	_append_log("[b]Match created.[/b] ID copied to the field — paste it into a second client for PvP.")
	# A brand-new match is the one moment hero selection is accepted.
	client.join(new_match_id, player_id, _selected_hero_id(), true)

func _join_match() -> void:
	_apply_inputs()
	var target := match_input.text.strip_edges()
	if target.is_empty() or player_id.is_empty():
		_set_status("Match ID and Player ID are both required.", true)
		return
	# Joining an existing match must not re-select a Hero: the server rejects
	# hero changes once the first action has been logged.
	client.join(target, player_id, _selected_hero_id(), false)

func _apply_inputs() -> void:
	client.http_base = server_input.text.strip_edges()
	player_id = player_input.text.strip_edges()

func _copy_match_id() -> void:
	var value := match_input.text.strip_edges()
	if value.is_empty():
		_set_status("No match ID to copy yet.", true)
		return
	DisplayServer.clipboard_set(value)
	_set_status("Match ID copied to the clipboard.")

func _selected_hero_id() -> String:
	return "striker" if hero_selector.selected == 1 else "healer"

## The starter deck the server validates against (30 cards: 15 × 2).
func _starter_deck() -> Array:
	var ids := [
		"wolf", "brown_bear", "hawk", "giant_rat", "hunting_spider",
		"elf_archer", "dwarf_defender", "human_mercenary", "field_medic",
		"apprentice_mage", "maintenance_anima", "mercy_4", "healing_potion",
		"firebolt", "arcane_battery",
	]
	var deck: Array = []
	for id in ids:
		deck.append(id)
		deck.append(id)
	return deck

# --- Server callbacks -------------------------------------------------------

func _on_connection_changed(status: int, detail: String) -> void:
	match status:
		MatchClient.Status.CONNECTED:
			_tint(connection_dot, COLOR_READY)
		MatchClient.Status.CONNECTING, MatchClient.Status.RECONNECTING:
			_tint(connection_dot, Color(0.95, 0.76, 0.28))
		_:
			_tint(connection_dot, Color(0.75, 0.30, 0.32))
	var is_busy := status == MatchClient.Status.CONNECTING or status == MatchClient.Status.RECONNECTING
	join_button.disabled = is_busy
	create_pvp_button.disabled = is_busy
	create_pve_button.disabled = is_busy
	_set_status(detail, status == MatchClient.Status.DISCONNECTED)

func _on_library_loaded() -> void:
	# Names arriving after the first render: repaint so ids become card names.
	if not state.is_empty():
		_render_state()
		_render_actions()

func _on_match_state(new_state: Dictionary) -> void:
	state = new_state
	_clear_selection()
	_render_state()

func _on_legal_actions(target_player: String, actions: Array) -> void:
	if target_player != player_id:
		return
	legal_actions = actions
	# A selection made before this arrived may no longer be legal.
	_refresh_targets()
	_render_state()
	_render_actions()

func _on_game_events(events: Array) -> void:
	for event in events:
		if typeof(event) == TYPE_DICTIONARY:
			_append_log(ActionFormatter.event_line(event, state, library))

func _on_match_ended(winner_id: String) -> void:
	var outcome := "You win!" if winner_id == player_id else "You lose."
	if winner_id == "":
		outcome = "The match ends in a draw."
	turn_banner.text = "Match over — " + outcome
	_append_log("[b]%s[/b]" % outcome)
	end_turn_button.disabled = true
	_cancel_drag()

func _on_server_error(code: String, message: String) -> void:
	_set_status("%s: %s" % [code, message], true)
	_append_log("[color=#e06c75]%s — %s[/color]" % [code, message])
	_cancel_drag()

# --- Rendering --------------------------------------------------------------

func _render_state() -> void:
	_clear(board_container)
	_clear(hand_container)
	_drop_zones.clear()
	if state.is_empty():
		return
	var sides: Variant = state.get("sides", {})
	if typeof(sides) != TYPE_DICTIONARY or not (sides as Dictionary).has(player_id):
		turn_banner.text = "Waiting for match state…"
		return
	var order: Variant = state.get("playerOrder", [])
	opponent_id = ""
	if typeof(order) == TYPE_ARRAY:
		for candidate in (order as Array):
			if str(candidate) != player_id:
				opponent_id = str(candidate)
				break
	var mine: Dictionary = (sides as Dictionary)[player_id]
	var opponent: Dictionary = (sides as Dictionary).get(opponent_id, {})

	var active := str(state.get("activePlayerId", ""))
	var is_my_turn := active == player_id
	turn_banner.text = "Turn %s — %s" % [
		_num(state.get("turn", 0)),
		"Your turn" if is_my_turn else "Opponent's turn (%s)" % active,
	]
	turn_banner.add_theme_color_override(
		"font_color", COLOR_READY if is_my_turn else Color(0.85, 0.72, 0.42)
	)

	if not opponent.is_empty():
		board_container.add_child(_hero_strip(opponent_id, opponent, false))
		_render_side(opponent, ["BACK", "FRONT"], false)
	var separator := HSeparator.new()
	board_container.add_child(separator)
	_render_side(mine, ["FRONT", "BACK"], true)
	board_container.add_child(_hero_strip(player_id, mine, true))

	_render_hand(mine)
	# Rects are only correct once the containers have laid out.
	call_deferred("_rebuild_drop_zones")

## Hero, Taika, deck and hand counts for one side. The strip is a drop target:
## heroes are addressed as "<playerId>:hero" and can be attacked or healed.
func _hero_strip(side_id: String, side: Dictionary, is_mine: bool) -> Control:
	var hero_id := Targeting.hero_entity_id(side_id)
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_PASS
	var is_target := entity_targets.has(hero_id)
	if is_target:
		_tint(panel, COLOR_TARGET if _hovered_key != hero_id else COLOR_HOVER)
	else:
		_tint(panel, COLOR_FRIENDLY if is_mine else COLOR_ENEMY)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(row)

	var hero: Dictionary = side.get("hero", {})
	var hero_name := ActionFormatter._hero_display_name(str(hero.get("definitionId", "")))
	var name_label := Label.new()
	name_label.text = "%s — %s" % [side_id, hero_name]
	if is_mine:
		name_label.text += "  (you)"
	row.add_child(name_label)

	var health := Label.new()
	health.text = "♥ %s / %s" % [_num(hero.get("currentHealth", "?")), _num(hero.get("maxHealth", "?"))]
	row.add_child(health)

	var taika: Dictionary = side.get("taika", {})
	var taika_label := Label.new()
	taika_label.text = "Taika %s / %s" % [_num(taika.get("current", 0)), _num(taika.get("maximum", 0))]
	row.add_child(taika_label)

	var counts := Label.new()
	var deck: Variant = side.get("deck", [])
	var hand: Variant = side.get("hand", [])
	counts.text = "Deck %d · Hand %d" % [
		(deck as Array).size() if typeof(deck) == TYPE_ARRAY else 0,
		(hand as Array).size() if typeof(hand) == TYPE_ARRAY else 0,
	]
	row.add_child(counts)

	var artifacts: Variant = side.get("artifacts", [])
	if typeof(artifacts) == TYPE_ARRAY and (artifacts as Array).size() > 0:
		var artifact_label := Label.new()
		artifact_label.text = "Artifacts %d" % (artifacts as Array).size()
		row.add_child(artifact_label)
		# Artifacts are in play, so they show their art like creatures do.
		for artifact in (artifacts as Array):
			if typeof(artifact) == TYPE_DICTIONARY:
				row.add_child(_artifact_tile(artifact))

	if bool(hero.get("powerUsedThisTurn", false)):
		var used := Label.new()
		used.text = "Hero Power used"
		used.add_theme_color_override("font_color", Color(0.7, 0.7, 0.74))
		row.add_child(used)

	if is_target:
		var prompt := Label.new()
		prompt.text = "◀ target"
		prompt.add_theme_color_override("font_color", Color(0.95, 0.98, 1.0))
		row.add_child(prompt)

	panel.set_meta("target_kind", "entity")
	panel.set_meta("target_id", hero_id)
	return panel

## A small in-play artifact tile: art where there is art, durability always.
func _artifact_tile(artifact: Dictionary) -> Control:
	var definition_id := str(artifact.get("definitionId", ""))
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_PASS
	panel.custom_minimum_size = ARTIFACT_TILE
	panel.tooltip_text = library.tooltip(definition_id)
	_tint(panel, COLOR_EMPTY)

	var column := VBoxContainer.new()
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override("separation", 1)
	panel.add_child(column)

	var title := Label.new()
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title.add_theme_font_size_override("font_size", 10)
	title.text = library.card_name(definition_id)
	column.add_child(title)

	var banner := CardArt.make_banner(definition_id, CardArt.BOARD_ART_HEIGHT)
	if banner != null:
		column.add_child(banner)

	var durability := Label.new()
	durability.mouse_filter = Control.MOUSE_FILTER_IGNORE
	durability.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	durability.add_theme_font_size_override("font_size", 10)
	durability.text = "◈ %s" % _num(artifact.get("durability", "?"))
	column.add_child(durability)
	return panel

func _render_side(side: Dictionary, rows: Array, is_mine: bool) -> void:
	var battlefield: Dictionary = side.get("battlefield", {})
	var config: Dictionary = battlefield.get("config", {})
	var width := int(config.get("width", 0))
	if width <= 0:
		return
	var owner_id := str(side.get("playerId", ""))
	var slots: Dictionary = battlefield.get("slots", {})
	var creatures: Dictionary = side.get("creatures", {})
	for row_name in rows:
		var grid := GridContainer.new()
		grid.columns = width
		grid.add_theme_constant_override("h_separation", 6)
		grid.add_theme_constant_override("v_separation", 6)
		# Center each row so both sides' battlefields line up column-for-column.
		var centering := HBoxContainer.new()
		centering.alignment = BoxContainer.ALIGNMENT_CENTER
		centering.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		centering.add_theme_constant_override("separation", 8)
		board_container.add_child(centering)
		var row_label := Label.new()
		row_label.text = str(row_name).capitalize()
		row_label.custom_minimum_size.x = 52
		row_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row_label.add_theme_font_size_override("font_size", 11)
		row_label.add_theme_color_override("font_color", Color(0.62, 0.65, 0.72))
		centering.add_child(row_label)
		centering.add_child(grid)
		var row_slots: Variant = slots.get(row_name, [])
		for column in range(width):
			var occupant: Variant = null
			if typeof(row_slots) == TYPE_ARRAY and column < (row_slots as Array).size():
				occupant = (row_slots as Array)[column]
			grid.add_child(
				_slot_panel(owner_id, str(row_name), column, occupant, creatures, is_mine)
			)

func _slot_panel(
	owner_id: String,
	row_name: String,
	column: int,
	occupant: Variant,
	creatures: Dictionary,
	is_mine: bool
) -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = SLOT_SIZE
	panel.mouse_filter = Control.MOUSE_FILTER_PASS

	var label := Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	panel.add_child(label)

	if occupant == null:
		var key := Targeting.slot_key(owner_id, row_name, column)
		var is_open: bool = slot_targets.has(key)
		label.text = "＋" if is_open else ""
		panel.tooltip_text = "%s %d — empty" % [row_name.capitalize(), column]
		# Every slot registers as a drop zone; whether it accepts the current
		# selection is decided at drop time, not at layout time.
		panel.set_meta("target_kind", "slot")
		panel.set_meta("target_id", key)
		if is_open:
			_tint(panel, COLOR_HOVER if _hovered_key == key else COLOR_TARGET)
		else:
			_tint(panel, COLOR_EMPTY)
		return panel

	var creature_id := str(occupant)
	var creature: Dictionary = creatures.get(creature_id, {})
	var definition_id := str(creature.get("definitionId", creature_id))
	var display_name := library.card_name(definition_id)
	var keyword_list := library.keywords(definition_id)

	# Markers only matter for your own creatures: they say why one cannot act.
	# The engine clears these at the owner's turn start, so an enemy creature
	# keeps them until its own turn comes round.
	var marks := ""
	if is_mine:
		if bool(creature.get("combatActionUsed", false)):
			marks = "\nacted"
		elif bool(creature.get("summonedThisTurn", false)):
			marks = "\nsick"
	var health := _num(creature.get("currentHealth", "?"))
	var max_health := _num(creature.get("maxHealth", "?"))
	# Show max health only while damaged, so a healthy creature stays uncluttered.
	var health_text := health if health == max_health else "%s/%s" % [health, max_health]

	var banner := CardArt.make_banner(definition_id, CardArt.BOARD_ART_HEIGHT)
	if banner != null:
		# With art present, the slot reads title / art / stats like a hand card.
		# The plain label is reused for the stats line beneath the banner.
		panel.remove_child(label)
		# Named `stack` because `column` is already this function's board index.
		var stack := VBoxContainer.new()
		stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
		stack.add_theme_constant_override("separation", 1)
		panel.add_child(stack)

		var title := Label.new()
		title.mouse_filter = Control.MOUSE_FILTER_IGNORE
		title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		title.add_theme_font_size_override("font_size", 11)
		title.text = display_name
		stack.add_child(title)
		stack.add_child(banner)
		stack.add_child(label)
		label.text = "⚔ %s  ♥ %s%s" % [
			_num(creature.get("currentAttack", "?")),
			health_text,
			marks,
		]
	else:
		label.text = "%s\n⚔ %s  ♥ %s%s" % [
			display_name,
			_num(creature.get("currentAttack", "?")),
			health_text,
			marks,
		]
	if not keyword_list.is_empty():
		label.text += "\n" + ", ".join(keyword_list)
	panel.tooltip_text = library.tooltip(definition_id)

	var is_target: bool = entity_targets.has(creature_id)
	if creature_id == selected_entity:
		_tint(panel, COLOR_SELECTED)
	elif is_target:
		_tint(panel, COLOR_HOVER if _hovered_key == creature_id else COLOR_TARGET)
	elif is_mine and _entity_can_act(creature_id):
		_tint(panel, COLOR_READY)
	else:
		_tint(panel, COLOR_FRIENDLY if is_mine else COLOR_ENEMY)

	panel.set_meta("target_kind", "entity")
	panel.set_meta("target_id", creature_id)
	# Your own creatures can start a drag; enemies can only be dropped onto.
	if is_mine:
		panel.set_meta("drag_entity", creature_id)
	return panel

func _render_hand(side: Dictionary) -> void:
	var hand: Variant = side.get("hand", [])
	if typeof(hand) != TYPE_ARRAY or (hand as Array).is_empty():
		var empty := Label.new()
		empty.text = "(no cards in hand)"
		hand_container.add_child(empty)
		return
	var taika: Dictionary = side.get("taika", {})
	var available := int(taika.get("current", 0))
	for card in (hand as Array):
		if typeof(card) != TYPE_DICTIONARY:
			continue
		hand_container.add_child(_hand_card(card, available))

func _hand_card(card: Dictionary, available_taika: int) -> Control:
	var instance_id := str(card.get("instanceId", ""))
	var definition_id := str(card.get("definitionId", ""))
	var panel := PanelContainer.new()
	panel.custom_minimum_size = CARD_SIZE
	panel.mouse_filter = Control.MOUSE_FILTER_PASS

	# Title above, art banner in the middle, remaining detail below. The whole
	# column ignores the mouse so a press reaches the panel and starts a drag.
	var column := VBoxContainer.new()
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override("separation", 2)
	panel.add_child(column)

	var title := Label.new()
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title.add_theme_font_size_override("font_size", 12)
	title.text = library.card_name(definition_id)
	column.add_child(title)

	var banner := CardArt.make_banner(definition_id, CardArt.HAND_ART_HEIGHT)
	if banner != null:
		column.add_child(banner)

	var label := Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(label)

	var cost := library.cost(definition_id)
	var kind := library.card_type(definition_id)
	var line := "%d Taika" % cost
	if kind == "CREATURE":
		line += "\n%d/%d" % [library.base_attack(definition_id), library.base_health(definition_id)]
	elif kind != "":
		line += "\n" + kind.capitalize()
	panel.tooltip_text = library.tooltip(definition_id)

	var playable := not Targeting.actions_for_card(legal_actions, instance_id).is_empty()
	if instance_id == selected_card:
		_tint(panel, COLOR_SELECTED)
	elif playable:
		_tint(panel, COLOR_READY)
		panel.set_meta("drag_card", instance_id)
	else:
		_tint(panel, COLOR_EMPTY)
		panel.modulate = Color(0.72, 0.72, 0.76)
		# Say why a card cannot be played, rather than just greying it out.
		if cost > available_taika:
			line += "\n(needs %d)" % cost
			panel.tooltip_text += "\n\nNot enough Taika: %d of %d." % [available_taika, cost]
		else:
			panel.tooltip_text += "\n\nNo legal play for this card right now."
	if playable:
		panel.set_meta("drag_card", instance_id)
	label.text = line
	return panel

## Recolours existing target controls without rebuilding the board.
##
## Called while dragging: rebuilding would free the controls whose rects the
## drag is hit-testing against, so only the tints change.
func _repaint_highlights() -> void:
	for key in _drop_zones:
		var zone: Dictionary = _drop_zones[key]
		var kind := str(zone.get("kind", ""))
		if kind != "slot" and kind != "entity":
			continue
		var control: Variant = zone.get("control", null)
		if not (control is Control) or not is_instance_valid(control):
			continue
		var id := str(key)
		var is_target: bool = slot_targets.has(id) or entity_targets.has(id)
		if not is_target:
			continue
		_tint(control as Control, COLOR_HOVER if _hovered_key == id else COLOR_TARGET)

## Records the screen rect of every droppable or draggable control.
func _rebuild_drop_zones() -> void:
	_drop_zones.clear()
	_collect_zones(board_container)
	_collect_zones(hand_container)

func _collect_zones(node: Node) -> void:
	for child in node.get_children():
		if child is Control:
			var control := child as Control
			if control.has_meta("target_kind"):
				_drop_zones[str(control.get_meta("target_id"))] = {
					"rect": control.get_global_rect(),
					"kind": str(control.get_meta("target_kind")),
					"control": control,
				}
			if control.has_meta("drag_card"):
				_drop_zones["card:" + str(control.get_meta("drag_card"))] = {
					"rect": control.get_global_rect(),
					"kind": "drag_card",
					"id": str(control.get_meta("drag_card")),
					"control": control,
				}
			if control.has_meta("drag_entity"):
				_drop_zones["drag:" + str(control.get_meta("drag_entity"))] = {
					"rect": control.get_global_rect(),
					"kind": "drag_entity",
					"id": str(control.get_meta("drag_entity")),
					"control": control,
				}
		_collect_zones(child)

# --- Pointer interaction ----------------------------------------------------

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index != MOUSE_BUTTON_LEFT:
			if button.pressed and button.button_index == MOUSE_BUTTON_RIGHT:
				# Right click cancels, as in Hearthstone.
				_clear_selection()
				_render_state()
				_render_actions()
			return
		if button.pressed:
			_on_pointer_down(button.global_position)
		else:
			_on_pointer_up(button.global_position)
	elif event is InputEventMouseMotion and (_dragging or _pressed_source != ""):
		_on_pointer_move((event as InputEventMouseMotion).global_position)

func _on_pointer_down(at: Vector2) -> void:
	_rebuild_drop_zones()
	# Starting a drag on a target of the current selection commits instead.
	var zone := _zone_at(at, ["drag_card", "drag_entity"])
	if zone.is_empty():
		return
	_pressed_source = str(zone.get("id", ""))
	_pressed_is_card = str(zone.get("kind", "")) == "drag_card"
	_press_origin = at
	_dragging = false

func _on_pointer_move(at: Vector2) -> void:
	if _pressed_source == "" and not _dragging:
		return
	if not _dragging and at.distance_to(_press_origin) >= DRAG_THRESHOLD:
		# Promote the press into a drag, selecting its source.
		_begin_drag(_pressed_source, _pressed_is_card)
	if not _dragging:
		return
	var hovered := _target_zone_at(at)
	if hovered.is_empty():
		# A miss may mean the cached rects predate the last layout pass rather
		# than the pointer being over nothing; refresh once and look again.
		_rebuild_drop_zones()
		hovered = _target_zone_at(at)
	var key := str(hovered.get("key", ""))
	if key != _hovered_key:
		_hovered_key = key
		# Recolour in place: a full re-render would destroy the very controls
		# whose rects this drag is hit-testing against.
		_repaint_highlights()
	# Green over a legal target, red only when hovering something that is
	# explicitly not one, neutral while the arrow is still in flight.
	var valid: Variant = null
	if key != "":
		valid = true
	elif not _zone_at(at, ["slot", "entity"]).is_empty():
		valid = false
	arrow.point_at(at - arrow.global_position, valid)

func _on_pointer_up(at: Vector2) -> void:
	if _dragging:
		# Rects may have gone stale during the drag; refresh before committing
		# so a legitimate drop is never discarded as a miss.
		_rebuild_drop_zones()
		var hovered := _target_zone_at(at)
		if not hovered.is_empty():
			_commit_target(str(hovered.get("key", "")))
		else:
			_set_status("No legal target there.", true)
			_clear_selection()
		_end_drag()
		_render_state()
		_render_actions()
		return

	# A plain click: either pick up a source, or commit onto a lit target.
	if _pressed_source != "":
		var target := _target_zone_at(at)
		if not target.is_empty() and (selected_card != "" or selected_entity != ""):
			_commit_target(str(target.get("key", "")))
		else:
			_toggle_selection(_pressed_source, _pressed_is_card)
		_pressed_source = ""
		_render_state()
		_render_actions()
		return

	# Clicking a lit target with an existing selection commits it.
	var direct := _target_zone_at(at)
	if not direct.is_empty() and (selected_card != "" or selected_entity != ""):
		_commit_target(str(direct.get("key", "")))
		_render_state()
		_render_actions()

func _begin_drag(source_id: String, is_card: bool) -> void:
	if is_card:
		selected_card = source_id
		selected_entity = ""
	else:
		selected_entity = source_id
		selected_card = ""
	_refresh_targets()
	if slot_targets.is_empty() and entity_targets.is_empty():
		# Nothing to aim at; keep the selection but do not draw an arrow.
		var immediate: Variant = _untargeted_for_selection()
		if immediate != null:
			_submit(immediate as Dictionary)
			_clear_selection()
			return
		_set_status(Targeting.prompt_for(_selection_actions(), player_id), true)
		return
	_dragging = true
	var zone_key := ("card:" if is_card else "drag:") + source_id
	var origin := _press_origin
	if _drop_zones.has(zone_key):
		origin = (_drop_zones[zone_key]["rect"] as Rect2).get_center()
	arrow.begin(origin - arrow.global_position)
	# Light up the newly valid destinations without rebuilding the board, so
	# the rects this drag hit-tests against stay alive.
	_repaint_highlights()
	_render_actions()

func _end_drag() -> void:
	_dragging = false
	_pressed_source = ""
	_hovered_key = ""
	arrow.finish()

func _cancel_drag() -> void:
	_end_drag()
	_clear_selection()

func _toggle_selection(source_id: String, is_card: bool) -> void:
	var already := (selected_card == source_id) if is_card else (selected_entity == source_id)
	if already:
		_clear_selection()
		return
	if is_card:
		selected_card = source_id
		selected_entity = ""
	else:
		selected_entity = source_id
		selected_card = ""
	_refresh_targets()
	# A selection with exactly one untargeted action resolves immediately.
	var immediate: Variant = _untargeted_for_selection()
	if immediate != null and slot_targets.is_empty() and entity_targets.is_empty():
		_submit(immediate as Dictionary)
		_clear_selection()
		return
	_set_status(Targeting.prompt_for(_selection_actions(), player_id))

func _clear_selection() -> void:
	selected_card = ""
	selected_entity = ""
	slot_targets = {}
	entity_targets = {}
	_hovered_key = ""

func _selection_actions() -> Array:
	if selected_card != "":
		return Targeting.actions_for_card(legal_actions, selected_card)
	if selected_entity != "":
		return Targeting.actions_for_entity(legal_actions, selected_entity)
	return []

func _untargeted_for_selection() -> Variant:
	return Targeting.untargeted_action(_selection_actions())

## Recomputes the lit destinations for the current selection.
func _refresh_targets() -> void:
	var actions := _selection_actions()
	# A summon or a move always lands on your own battlefield.
	slot_targets = Targeting.slot_targets(actions, player_id)
	entity_targets = Targeting.entity_targets(actions)

func _commit_target(key: String) -> void:
	if key == "":
		return
	var action: Variant = slot_targets.get(key, entity_targets.get(key, null))
	if action == null:
		_set_status("That is not a legal target for this selection.", true)
		return
	_submit(action as Dictionary)
	_clear_selection()

## The drop zone under a point, restricted to the current selection's targets.
func _target_zone_at(at: Vector2) -> Dictionary:
	# Zones overlap — a hero strip spans the width of the board, and creature
	# panels sit inside it — so every candidate is considered and the smallest
	# valid one wins. Returning the first hit would let a wide zone mask a
	# precise one, or an invalid zone hide a valid one beneath it.
	var best: Dictionary = {}
	var best_area := INF
	for key in _drop_zones:
		var zone: Dictionary = _drop_zones[key]
		var kind := str(zone.get("kind", ""))
		if kind != "slot" and kind != "entity":
			continue
		var rect: Rect2 = zone["rect"]
		if not rect.has_point(at):
			continue
		var id := str(key)
		if not (slot_targets.has(id) or entity_targets.has(id)):
			continue
		var area := rect.size.x * rect.size.y
		if area < best_area:
			best_area = area
			best = {"key": id, "zone": zone}
	return best

func _zone_at(at: Vector2, kinds: Array) -> Dictionary:
	# Drag sources do not nest — a hand card and a creature panel never contain
	# one another — so the first rect containing the point is the right one.
	for key in _drop_zones:
		var zone: Dictionary = _drop_zones[key]
		if not kinds.has(str(zone.get("kind", ""))):
			continue
		if (zone["rect"] as Rect2).has_point(at):
			return zone
	return {}

func _entity_can_act(entity_id: String) -> bool:
	return not Targeting.actions_for_entity(legal_actions, entity_id).is_empty()

# --- Action list ------------------------------------------------------------

func _render_actions() -> void:
	_clear(action_container)
	var is_my_turn := str(state.get("activePlayerId", "")) == player_id
	end_turn_button.disabled = not is_my_turn or legal_actions.is_empty()

	if legal_actions.is_empty():
		action_hint.text = "Waiting for the opponent…" if not is_my_turn else "No legal actions."
		return

	if selected_card != "" or selected_entity != "":
		action_hint.text = Targeting.prompt_for(_selection_actions(), player_id) \
			+ "  Right-click or press Escape to cancel."
	else:
		action_hint.text = "Drag a card onto the board, or drag one of your creatures onto a target."

	# The list mirrors what dragging offers, and stays usable as a fallback.
	var visible := _selection_actions() if (selected_card != "" or selected_entity != "") \
		else legal_actions
	var grouped: Dictionary = {}
	for action in visible:
		if typeof(action) != TYPE_DICTIONARY:
			continue
		if str(action.get("type", "")) == "END_TURN":
			continue  # Always available via the dedicated button.
		var group := ActionFormatter.group_of(action)
		if not grouped.has(group):
			grouped[group] = []
		(grouped[group] as Array).append(action)

	var any_rendered := false
	for group in ActionFormatter.GROUP_ORDER:
		if not grouped.has(group):
			continue
		var actions: Array = grouped[group]
		if actions.is_empty():
			continue
		any_rendered = true
		var header := Label.new()
		header.text = "%s (%d)" % [group, actions.size()]
		header.add_theme_font_size_override("font_size", 12)
		header.add_theme_color_override("font_color", Color(0.72, 0.76, 0.85))
		action_container.add_child(header)
		for action in actions:
			var button := Button.new()
			button.text = ActionFormatter.label_for(action, state, player_id, library)
			button.tooltip_text = JSON.stringify(action)
			button.alignment = HORIZONTAL_ALIGNMENT_LEFT
			button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			button.pressed.connect(_submit.bind(action))
			action_container.add_child(button)

	if not any_rendered:
		var note := Label.new()
		note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		note.text = "Only ending the turn is available."
		# Early turns are usually Taika-starved; say so instead of leaving a blank panel.
		var side: Dictionary = (state.get("sides", {}) as Dictionary).get(player_id, {})
		var taika: Dictionary = side.get("taika", {})
		var available := int(taika.get("current", 0))
		var cheapest := _cheapest_hand_cost(side)
		if cheapest > available:
			note.text += "\nYour cheapest card costs %d Taika and you have %d." % [cheapest, available]
		action_container.add_child(note)

## Cost of the cheapest card in hand, or -1 when the hand is empty.
func _cheapest_hand_cost(side: Dictionary) -> int:
	var hand: Variant = side.get("hand", [])
	if typeof(hand) != TYPE_ARRAY:
		return -1
	var cheapest := -1
	for card in (hand as Array):
		if typeof(card) != TYPE_DICTIONARY:
			continue
		var cost := library.cost(str(card.get("definitionId", "")))
		if cheapest < 0 or cost < cheapest:
			cheapest = cost
	return cheapest

func _end_turn() -> void:
	for action in legal_actions:
		if typeof(action) == TYPE_DICTIONARY and str(action.get("type", "")) == "END_TURN":
			_submit(action)
			return
	_set_status("Ending the turn is not legal right now.", true)

func _submit(action: Dictionary) -> void:
	if not client.submit_action(action):
		_set_status("Not connected — press Join to reconnect.", true)
		return
	_clear_selection()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and (event as InputEventKey).pressed \
			and (event as InputEventKey).keycode == KEY_ESCAPE:
		_cancel_drag()
		_render_state()
		_render_actions()

# --- Small helpers ----------------------------------------------------------

func _set_status(text: String, is_error: bool = false) -> void:
	status_label.text = text
	status_label.add_theme_color_override(
		"font_color", Color(0.88, 0.42, 0.45) if is_error else Color(0.78, 0.80, 0.86)
	)

func _append_log(line: String) -> void:
	log_lines.append(line)
	if log_lines.size() > MAX_LOG_LINES:
		log_lines = log_lines.slice(log_lines.size() - MAX_LOG_LINES)
	log_label.text = "\n".join(log_lines)

func _tint(panel: Control, color: Color) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(4)
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 4
	style.content_margin_bottom = 4
	panel.add_theme_stylebox_override("panel", style)

func _clear(node: Node) -> void:
	for child in node.get_children():
		node.remove_child(child)
		child.queue_free()
