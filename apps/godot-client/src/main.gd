extends Control

## Maailma TCG presentation client.
##
## The client renders state and offers the server's legal actions. It never
## decides legality: dragging a card or creature only ever offers targets the
## server has already declared legal, and every choice is sent for validation.
##
## Interaction follows Hearthstone's model. Hand cards fan out at the bottom
## and show large under the pointer. Drag one, or click it to pick it up, and
## it follows the cursor: let go over the battlefield to play it, on the lit
## slot under the cursor or the nearest one. A card that needs a target parks
## above the hand and fires a dotted arrow instead. Press one of your creatures
## and drag to aim its arrow at a lit target, or click it, then click a target.

## Cards in hand are drawn as cards, and Creatures in play as a large art
## oval, so slots and hand cards are both portrait. The ring carries the colour that
## says a card is ready, selected or a target: round a hand card it is the
## frame's own, round its body, and round a creature, the oval's own.
const FRAME_WIDTH := 96.0
const FRAME_RING := 4
const SLOT_SIZE := Vector2(104, 138)
const CARD_SIZE := Vector2(104, 138)
const ARTIFACT_TILE := Vector2(92, 84)
const WEAPON_TILE := Vector2(104, 84)
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
## Collection/trading follow the current catalogue; match rendering stays pinned.
var catalog_library := CardLibrary.new()
var collection_screen: CollectionScreen
var trade_screen: TradeScreen
var game_root: Control
## Chooses the deck every match is entered with.
const DeckPicker := preload("res://src/deck_picker.gd")
var deck_picker: Control
## What the player was doing when the picker opened, so the chosen deck goes
## to the right request: {"kind": "create", "scenario": id} or
## {"kind": "join", "match_id": id}.
var _pending_entry: Dictionary = {}
## The open seat's placeholder, as the server names it, so a waiting match can
## say it is waiting rather than show a nameless opponent.
const OPEN_SEAT_ID := "open-seat"

## The admin UI: a panel for accounts and matches, and an edit bar in the match
## view. Offered only to admins, and only while switched on — the toggle lets
## an admin see the client exactly as a player does.
const AdminScreen := preload("res://src/admin_screen.gd")
const AdminMatchTools := preload("res://src/admin_match_tools.gd")
const ADMIN_UI_PATH := "user://admin_ui.cfg"
var admin_screen: Control
var admin_toggle: Button
var admin_bar: PanelContainer
var admin_match_tools: Node
var admin_ui_enabled := true

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
## How a held hand card plays: "place" follows the pointer and lands where it
## is let go; "aim" parks above the hand and fires the arrow at a target.
var _card_mode := ""
## A clicked card stays held without the button, until the next click.
var _sticky := false
## The release of the click that set a sticky card down is not another drop.
var _swallow_release := false
var _hovered_key := ""
## Where the pointer was last seen, so a board rebuilt underneath it can decide
## whether what it was revealing is still there.
var _hover_at := Vector2.ZERO

## Screen rects of every droppable thing, rebuilt after each layout pass.
## Maps a target key to {rect, kind, id, valid}.
var _drop_zones: Dictionary = {}

var status_label: Label
var connection_dot: Panel
var turn_banner: Label
var match_input: LineEdit
var player_input: LineEdit
var server_input: LineEdit
var board_container: VBoxContainer
## The battlefield's scroll area: letting a card go anywhere over it plays it.
var board_area: Control
var hand_view: HandView
var action_container: VBoxContainer
var action_hint: Label
var log_label: RichTextLabel
var end_turn_button: Button
var create_pvp_button: Button
var create_pve_button: Button
var join_button: Button
var arrow: TargetingArrow
var reveal: CardReveal
var play_effect: CardPlayEffect
var combat_effect: CombatEffect
var last_breath_effect: LastBreathEffect
var _pending_last_breath_deaths: Dictionary = {}
## Preserve server order while an attack is playing. Its state is revealed at
## impact; the next attack waits until these tokens have returned home.
var _presentation_queue: Array[Dictionary] = []
var _presenting := false
var _combat_preparing := false
var _presentation_generation := 0
## Entry start times survive board rebuilds; -1 waits for the falling oval.
var _guard_arrivals: Dictionary = {}

func _ready() -> void:
	client = MatchClient.new()
	add_child(client)
	client.connection_changed.connect(_on_connection_changed)
	client.match_state_received.connect(_on_match_state)
	client.legal_actions_received.connect(_on_legal_actions)
	client.game_events_received.connect(_on_game_events)
	client.match_ended.connect(_on_match_ended)
	client.server_error.connect(_on_server_error)
	client.cards_received.connect(func(payload: Variant) -> void:
		catalog_library.ingest(payload)
		if client.match_content_version == "":
			library.ingest(payload))
	client.match_cards_received.connect(func(cards: Array) -> void: library.ingest(cards))
	client.request_failed.connect(func(detail: String) -> void: _set_status(detail, true))
	library.loaded.connect(_on_library_loaded)

	accounts = AccountClient.new()
	add_child(accounts)
	accounts.signed_in.connect(_on_signed_in)
	accounts.signed_out.connect(_on_account_signed_out)
	accounts.decks_loaded.connect(_on_decks_loaded)
	accounts.match_started.connect(_on_match_started)
	accounts.match_refused.connect(_on_match_refused)

	_build_interface()

	# The collection screen opens first. The match view can be opened without
	# signing in, but a match is only ever entered signed in, with a ready deck.
	collection_screen = CollectionScreen.new()
	add_child(collection_screen)
	collection_screen.setup(accounts, catalog_library)
	collection_screen.play_requested.connect(_show_match_view)
	# Keep the two address fields in step: they configure the same thing.
	collection_screen.server_changed.connect(_on_server_changed)
	collection_screen.trade_requested.connect(_show_trade_view)

	trade_screen = TradeScreen.new()
	trade_screen.visible = false
	add_child(trade_screen)
	trade_screen.setup(accounts, catalog_library)
	trade_screen.closed.connect(_show_collection_view)
	collection_screen.admin_requested.connect(_show_admin_view)

	admin_screen = AdminScreen.new()
	admin_screen.visible = false
	admin_screen.setup(accounts, catalog_library)
	add_child(admin_screen)
	admin_screen.closed.connect(_show_collection_view)
	admin_screen.play_requested.connect(_play_admin_match)
	admin_screen.content_published.connect(func(_version: String) -> void:
		client.fetch_cards()
		accounts.fetch_collection()
		accounts.fetch_expansions()
		accounts.fetch_packs())

	# A corner switch between the admin UI and the one every player sees.
	admin_ui_enabled = _load_admin_ui_enabled()
	admin_toggle = Button.new()
	admin_toggle.toggle_mode = true
	admin_toggle.tooltip_text = "Switch between the admin UI and the normal player UI."
	admin_toggle.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	admin_toggle.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	admin_toggle.grow_vertical = Control.GROW_DIRECTION_BEGIN
	admin_toggle.position -= Vector2(10, 10)
	admin_toggle.toggled.connect(_on_admin_toggled)
	add_child(admin_toggle)
	_apply_admin_ui()

	# Added last, so it draws over the board it asks about.
	deck_picker = DeckPicker.new()
	add_child(deck_picker)
	deck_picker.setup(catalog_library)
	catalog_library.loaded.connect(func() -> void:
		collection_screen._render_collection()
		collection_screen._render_draft()
		trade_screen._render_all())
	deck_picker.picked.connect(_on_deck_picked)
	deck_picker.cancelled.connect(func() -> void:
		_pending_entry = {}
		_set_status("No match started."))
	deck_picker.build_requested.connect(func() -> void:
		_pending_entry = {}
		_show_collection_view())
	_show_collection_view()
	print("[maailma] server: %s (%s)" % [ClientConfig.http_base(), ClientConfig.source()])

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

	# Admin edits for the match being played. Hidden unless the admin UI is on.
	admin_bar = PanelContainer.new()
	var admin_style := StyleBoxFlat.new()
	admin_style.bg_color = Color(0.20, 0.16, 0.08)
	admin_style.border_color = Color(0.85, 0.74, 0.44)
	admin_style.set_border_width_all(1)
	admin_style.set_corner_radius_all(4)
	admin_style.set_content_margin_all(6)
	admin_bar.add_theme_stylebox_override("panel", admin_style)
	admin_bar.visible = false
	root.add_child(admin_bar)
	admin_match_tools = AdminMatchTools.new()
	admin_match_tools.setup(accounts, library)
	admin_bar.add_child(admin_match_tools)

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
	board_area = board_scroll

	# Not in a scroll container: a hovered or held card rises out of the hand
	# over the board, and a scroll container would clip it.
	hand_view = HandView.new()
	hand_view.setup(library)
	left.add_child(hand_view)

	game_row.add_child(_build_side_panel())

	# Both overlays sit above the board and never take pointer input. The
	# reveal is added first so the targeting arrow draws over it.
	reveal = CardReveal.new()
	reveal.setup(library)
	game_root.add_child(reveal)

	# A played card breaking up, over the board and the hand it leaves.
	play_effect = CardPlayEffect.new()
	play_effect.z_index = HandView.Z_HELD + 1
	play_effect.landed.connect(_on_oval_landed)
	game_root.add_child(play_effect)

	combat_effect = CombatEffect.new()
	combat_effect.z_index = HandView.Z_HELD + 2
	combat_effect.clip_contents = true
	combat_effect.impacted.connect(_apply_combat_updates)
	game_root.add_child(combat_effect)
	last_breath_effect = LastBreathEffect.new()
	last_breath_effect.z_index = HandView.Z_HELD + 3
	last_breath_effect.clip_contents = true
	game_root.add_child(last_breath_effect)

	arrow = TargetingArrow.new()
	# Over the held hand card it is fired from, which draws above the board.
	arrow.z_index = HandView.Z_ZOOM + 5
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

func _on_server_changed(base: String) -> void:
	client.http_base = base
	if server_input != null:
		server_input.text = base
	_set_status("Server set to %s." % base)

func _show_collection_view() -> void:
	if deck_picker != null:
		deck_picker.close()
	if admin_screen != null:
		admin_screen.visible = false
	collection_screen.visible = true
	trade_screen.visible = false
	game_root.visible = false
	_cancel_drag()

func _show_trade_view() -> void:
	admin_screen.visible = false
	collection_screen.visible = false
	trade_screen.visible = true
	game_root.visible = false
	_cancel_drag()

## The admin panel. Only reachable with the admin UI on, as an admin.
func _show_admin_view() -> void:
	if not (accounts.is_admin() and admin_ui_enabled):
		return
	deck_picker.close()
	collection_screen.visible = false
	trade_screen.visible = false
	game_root.visible = false
	admin_screen.visible = true
	admin_screen.opened()
	_cancel_drag()

## Opens a match the admin panel started or picked, as the signed-in player.
func _play_admin_match(match_id: String) -> void:
	_reset_combat_presentation()
	_show_match_view()
	match_input.text = match_id
	player_id = str(accounts.user.get("id", player_id))
	client.join(match_id, player_id, "", false)

func _on_admin_toggled(enabled: bool) -> void:
	admin_ui_enabled = enabled
	var config := ConfigFile.new()
	config.set_value("admin", "ui_enabled", enabled)
	config.save(ADMIN_UI_PATH)
	_apply_admin_ui()

func _load_admin_ui_enabled() -> bool:
	var config := ConfigFile.new()
	if config.load(ADMIN_UI_PATH) != OK:
		return true
	return bool(config.get_value("admin", "ui_enabled", true))

## Shows or hides every piece of the admin UI to match who is signed in and
## whether the toggle is on. Safe to call at any time.
func _apply_admin_ui() -> void:
	if admin_toggle == null:
		return
	var is_admin := accounts.is_admin()
	var on := is_admin and admin_ui_enabled
	admin_toggle.visible = is_admin
	admin_toggle.set_pressed_no_signal(admin_ui_enabled)
	admin_toggle.text = "Admin UI: on" if admin_ui_enabled else "Admin UI: off"
	collection_screen.set_admin_available(on)
	var in_match := not state.is_empty() and client.match_id != ""
	admin_bar.visible = on and in_match
	if admin_bar.visible:
		admin_match_tools.show_match(client.match_id, state, player_id)
	# Switching off, or signing in as someone who is not an admin, closes the panel.
	if admin_screen.visible and not on:
		_show_collection_view()

func _show_match_view() -> void:
	admin_screen.visible = false
	collection_screen.visible = false
	trade_screen.visible = false
	game_root.visible = true
	# Fresh readiness for the deck picker: a deck may have become playable, or
	# stopped being, since it was last read.
	if accounts.is_signed_in():
		accounts.fetch_decks()

func _on_signed_in(who: Dictionary) -> void:
	# The account's display name is the player id the server will use.
	player_id = str(who.get("id", player_id))
	player_input.text = str(who.get("displayName", player_id))
	player_input.editable = false
	_apply_admin_ui()
	_set_status("Signed in as %s." % str(who.get("displayName", "")))

func _on_account_signed_out() -> void:
	# Trading needs an account, so signing out lands back on the sign-in form.
	if trade_screen.visible:
		_show_collection_view()
	player_input.editable = true
	_pending_entry = {}
	_apply_admin_ui()
	if deck_picker != null:
		deck_picker.close()

func _on_decks_loaded(list: Array) -> void:
	deck_picker.set_decks(list)

# --- Connection actions -----------------------------------------------------

## Every match is played with one of the player's own decks, so starting one
## means signing in and picking a ready deck first. There is no default deck.
func _create_match(scenario_id: String) -> void:
	_apply_inputs()
	if not _require_account():
		return
	_pending_entry = {"kind": "create", "scenario": scenario_id}
	deck_picker.open("Choose a deck to play")
	accounts.fetch_decks()

## Joins a match by id. Asked first without a deck: a player already seated
## there is let straight back in, and only a player taking the open seat is
## asked to choose one.
func _join_match() -> void:
	_apply_inputs()
	var target := match_input.text.strip_edges()
	if target.is_empty():
		_set_status("Paste a match ID to join.", true)
		return
	if not _require_account():
		return
	_pending_entry = {"kind": "join", "match_id": target}
	_set_status("Joining match…")
	accounts.join_open_match(target)

## Starts a match with a chosen deck, without the picker. The picker calls this
## once a deck is chosen, and tests call it directly.
func start_match_with_deck(scenario_id: String, deck_id: String) -> void:
	_pending_entry = {"kind": "create", "scenario": scenario_id}
	_set_status("Starting match…")
	accounts.start_match(scenario_id, deck_id)

func join_match_with_deck(match_id: String, deck_id: String) -> void:
	_pending_entry = {"kind": "join", "match_id": match_id}
	_set_status("Joining match…")
	accounts.join_open_match(match_id, deck_id)

func _require_account() -> bool:
	if accounts.is_signed_in():
		return true
	_set_status("Sign in and build a deck to play: open the Collection.", true)
	return false

func _on_deck_picked(deck_id: String) -> void:
	match str(_pending_entry.get("kind", "")):
		"create":
			start_match_with_deck(str(_pending_entry.get("scenario", "")), deck_id)
		"join":
			join_match_with_deck(str(_pending_entry.get("match_id", "")), deck_id)

func _on_match_started(match_id: String, seated_as: String, waiting: bool) -> void:
	_reset_combat_presentation()
	_pending_entry = {}
	player_id = seated_as
	match_input.text = match_id
	if waiting:
		_append_log("[b]Match created.[/b] Waiting for an opponent — copy the match ID and send it to them.")
		_set_status("Waiting for an opponent to join.")
	else:
		_append_log("[b]Match joined.[/b]")
	# The hero comes from the deck, so there is none to select here.
	client.join(match_id, player_id, "", false)

func _on_match_refused(code: String, message: String) -> void:
	# Taking an open seat needs a deck; that is the prompt, not a failure.
	if code == "DECK_REQUIRED" and str(_pending_entry.get("kind", "")) == "join":
		deck_picker.open("Choose a deck to join with")
		accounts.fetch_decks()
		return
	_pending_entry = {}
	var explanation := message
	match code:
		"DECK_REQUIRED":
			explanation = "Choose one of your decks to play with."
		"DECK_NOT_PLAYABLE":
			explanation = "That deck is not ready to play. " + message
		"DECK_NOT_FOUND":
			explanation = "That deck no longer exists."
		"SEAT_TAKEN":
			explanation = "That match already has two players."
		"MATCH_NOT_FOUND":
			explanation = "No match with that ID."
		"UNAUTHENTICATED":
			explanation = "Sign in to play."
	_set_status(explanation, true)

func _apply_inputs() -> void:
	_apply_server_address(server_input.text)
	player_id = player_input.text.strip_edges()

## Points both clients at an address and remembers it for the next run.
##
## Previously this set only the match client, so signing in always went to the
## default address no matter what the field said.
func _apply_server_address(raw: String) -> void:
	var base := ClientConfig.normalize(raw)
	if base == "":
		return
	client.http_base = base
	accounts.http_base = base
	ClientConfig.save(base)
	# Show the normalized form, so "localhost:4000" reads back in full.
	if server_input.text != base:
		server_input.text = base

func _copy_match_id() -> void:
	var value := match_input.text.strip_edges()
	if value.is_empty():
		_set_status("No match ID to copy yet.", true)
		return
	DisplayServer.clipboard_set(value)
	_set_status("Match ID copied to the clipboard.")

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
	_queue_presentation("state", new_state)

func _present_match_state(new_state: Dictionary) -> void:
	_present_last_breath_deaths(new_state)
	if not state.is_empty():
		for side: Dictionary in new_state.get("sides", {}).values():
			for id in side.get("creatures", {}):
				var creature: Dictionary = side["creatures"][id]
				if CombatEffect._creature(state, str(id)).is_empty() \
						and library.keywords(str(creature.get("definitionId", ""))).has("GUARD"):
					_guard_arrivals[str(id)] = -1.0
	state = new_state
	for id in _guard_arrivals.keys():
		if CombatEffect._creature(state, str(id)).is_empty():
			_guard_arrivals.erase(id)
	# A new board invalidates what a held card was aiming at; it goes back.
	if _dragging:
		_end_drag()
	_clear_selection()
	_render_state()
	_apply_admin_ui()

func _on_legal_actions(target_player: String, actions: Array) -> void:
	if target_player != player_id:
		return
	_queue_presentation("actions", actions)

func _present_legal_actions(actions: Array) -> void:
	legal_actions = actions
	# A selection made before this arrived may no longer be legal.
	_refresh_targets()
	_render_state()
	_render_actions()

func _on_game_events(events: Array) -> void:
	_queue_presentation("events", events)

func _present_game_events(events: Array) -> void:
	for event in events:
		if typeof(event) != TYPE_DICTIONARY:
			continue
		if str(event.get("type", "")) == "CREATURE_DIED" \
				and library.keywords(str(event.get("cardDefinitionId", ""))).has("LAST_BREATH"):
			_pending_last_breath_deaths[str(event.get("sourceId", ""))] = true
		# Some events are bookkeeping the player need not read — a resolved
		# marker whose damage lines already told the story. They format to "".
		var line := ActionFormatter.event_line(event, state, library)
		if line != "":
			_append_log(line)
	for event in events:
		if typeof(event) != TYPE_DICTIONARY or str(event.get("type", "")) != "ATTACK_STARTED":
			continue
		var source_id := str(event.get("sourceId", ""))
		var target_id := str(event.get("targetId", ""))
		# Only creature-to-creature combat. Hidden match views need no animation.
		if CombatEffect._creature(state, source_id).is_empty() \
				or CombatEffect._creature(state, target_id).is_empty() or not game_root.visible:
			continue
		var generation := _presentation_generation
		_combat_preparing = true
		_cancel_drag()
		# Several AI messages can arrive in one socket poll, including a summon
		# immediately before an attack. Let its new containers lay out first.
		await get_tree().process_frame
		await get_tree().process_frame
		if generation != _presentation_generation:
			return
		var source := _combat_token(source_id)
		var target := _combat_token(target_id)
		if source == null or target == null:
			_combat_preparing = false
			continue
		var source_rect := source.get_global_rect()
		var target_rect := target.get_global_rect()
		var board_rect := board_area.get_global_rect()
		# Frame both fighters when they fit; otherwise focus on the defender.
		# The flight is clipped to the board so a distant back-row attacker can
		# enter from offscreen without being drawn over the hand or side panel.
		var span := source_rect.merge(target_rect)
		if board_area is ScrollContainer:
			var scroll := board_area as ScrollContainer
			var focus_y := span if span.size.y <= board_rect.size.y else target_rect
			var focus_x := span if span.size.x <= board_rect.size.x else target_rect
			var shift := Vector2(maxf(0.0, focus_x.end.x - board_rect.end.x),
				maxf(0.0, focus_y.end.y - board_rect.end.y))
			if focus_y.position.y < board_rect.position.y:
				shift.y = focus_y.position.y - board_rect.position.y
			if focus_x.position.x < board_rect.position.x:
				shift.x = focus_x.position.x - board_rect.position.x
			scroll.scroll_vertical += ceili(shift.y)
			scroll.scroll_horizontal += ceili(shift.x)
			if not shift.is_zero_approx():
				await get_tree().process_frame
				if generation != _presentation_generation:
					return
				source = _combat_token(source_id)
				target = _combat_token(target_id)
				if source == null or target == null:
					_combat_preparing = false
					continue
			source_rect = source.get_global_rect()
			target_rect = target.get_global_rect()
		_combat_preparing = false
		combat_effect.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
		combat_effect.position = game_root.get_global_transform().affine_inverse() * board_rect.position
		combat_effect.size = board_rect.size / game_root.get_global_transform().get_scale()
		var source_card: Dictionary = source.get_parent().get_meta("reveal_card", {})
		var target_card: Dictionary = target.get_parent().get_meta("reveal_card", {})
		combat_effect.play(library, source_id, source_card, source_rect,
			target_id, target_card, target_rect, game_root)
		_refresh_combat_bystanders()
		source.modulate.a = 0.0
		target.modulate.a = 0.0
		_render_actions()
		await combat_effect.finished
		if generation != _presentation_generation:
			return
		_render_state()
		_render_actions()

func _on_match_ended(winner_id: String) -> void:
	_queue_presentation("ended", winner_id)

func _present_match_ended(winner_id: String) -> void:
	var outcome := _match_outcome(winner_id)
	turn_banner.text = "Match over — " + outcome
	_append_log("[b]%s[/b]" % outcome)
	end_turn_button.disabled = true
	_cancel_drag()

func _match_outcome(winner_id: String) -> String:
	if winner_id == "":
		return "The match ends in a draw."
	return "You win!" if winner_id == player_id else "You lose."

func _combat_locked() -> bool:
	return _combat_preparing or (combat_effect != null and combat_effect.is_busy())

func _queue_presentation(kind: String, payload: Variant) -> void:
	_presentation_queue.append({"kind": kind, "payload": payload})
	if combat_effect.has_impacted():
		_apply_combat_updates()
	_drain_presentation_queue()

func _drain_presentation_queue() -> void:
	if _presenting:
		return
	_presenting = true
	while not _presentation_queue.is_empty():
		var message: Dictionary = _presentation_queue.pop_front()
		if message["kind"] == "events":
			await _present_game_events(message["payload"])
		else:
			_apply_presentation(message)
	_presenting = false

func _apply_presentation(message: Dictionary) -> void:
	match str(message["kind"]):
		"state":
			_present_match_state(message["payload"])
			combat_effect.resolve(library, state)
		"actions":
			_present_legal_actions(message["payload"])
		"ended":
			_present_match_ended(str(message["payload"]))

func _apply_combat_updates() -> void:
	# Consume just this attack's result, stopping before the next event batch.
	# Also runs for a result that arrives after the animation reaches impact.
	while not _presentation_queue.is_empty() and _presentation_queue[0]["kind"] != "events":
		_apply_presentation(_presentation_queue.pop_front())

func _reset_combat_presentation() -> void:
	_presentation_generation += 1
	_presentation_queue.clear()
	_combat_preparing = false
	_guard_arrivals.clear()
	_pending_last_breath_deaths.clear()
	last_breath_effect.cancel()
	combat_effect.cancel()

## Death events are recorded before combat starts, but shown only when its
## authoritative state is applied at impact. Other damage resolves at once.
func _present_last_breath_deaths(new_state: Dictionary) -> void:
	for id: String in _pending_last_breath_deaths.keys():
		if not CombatEffect._creature(new_state, id).is_empty():
			continue
		_pending_last_breath_deaths.erase(id)
		if not game_root.visible:
			continue
		var area := Rect2()
		if combat_effect.owns(id):
			area = combat_effect.creature_rect(id)
		else:
			var token := _combat_token(id)
			if token != null:
				area = token.get_global_rect()
		if area.has_area():
			var board_rect := board_area.get_global_rect()
			last_breath_effect.position = game_root.get_global_transform().affine_inverse() * board_rect.position
			last_breath_effect.size = board_rect.size / game_root.get_global_transform().get_scale()
			last_breath_effect.play(area)

func _combat_token(entity_id: String) -> CreatureToken:
	return _find_combat_token(board_container, entity_id)

func _refresh_combat_bystanders() -> void:
	var tokens: Array[CreatureToken] = []
	_collect_combat_bystanders(board_container, tokens)
	combat_effect.set_bystanders(tokens)

func _collect_combat_bystanders(node: Node, tokens: Array[CreatureToken]) -> void:
	for child in node.get_children():
		if child is CreatureToken:
			var entity_id := str(node.get_meta("reveal_key", ""))
			if not combat_effect.owns(entity_id):
				tokens.append(child)
		else:
			_collect_combat_bystanders(child, tokens)

func _find_combat_token(node: Node, entity_id: String) -> CreatureToken:
	if node is Control and str(node.get_meta("reveal_key", "")) == entity_id:
		for child in node.get_children():
			if child is CreatureToken:
				return child
	for child in node.get_children():
		var found := _find_combat_token(child, entity_id)
		if found != null:
			return found
	return null

func _on_server_error(code: String, message: String) -> void:
	_set_status("%s: %s" % [code, message], true)
	_append_log("[color=#e06c75]%s — %s[/color]" % [code, message])
	_cancel_drag()
	# A refused play leaves its card in the hand, so bring it straight back,
	# and let any oval still on its way to the board fade where it is.
	hand_view.restore_spent()
	play_effect.cancel_all()

# --- Rendering --------------------------------------------------------------

func _render_state() -> void:
	combat_effect.set_bystanders([])
	_clear(board_container)
	_drop_zones.clear()
	if state.is_empty():
		hand_view.clear_cards()
		return
	var sides: Variant = state.get("sides", {})
	if typeof(sides) != TYPE_DICTIONARY or not (sides as Dictionary).has(player_id):
		turn_banner.text = "Waiting for match state…"
		hand_view.clear_cards()
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
	if opponent_id == OPEN_SEAT_ID:
		turn_banner.text = "Waiting for an opponent to join — share the match ID"
	if str(state.get("phase", "")) == "FINISHED":
		turn_banner.text = "Match over — " + _match_outcome(str(state.get("winnerId", "")))
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

	# The equipped Weapon sits with the Hero it arms, not on the battlefield.
	var equipped: Variant = hero.get("equippedWeapon", null)
	if typeof(equipped) == TYPE_DICTIONARY:
		row.add_child(_weapon_tile(equipped as Dictionary))

	if bool(hero.get("powerUsedThisTurn", false)):
		var used := Label.new()
		used.text = "Hero Power used"
		used.add_theme_color_override("font_color", Color(0.7, 0.7, 0.74))
		row.add_child(used)

	# An armed Hero with an attack left is a drag source, exactly like a
	# Creature that can still act. Whether it may actually swing is the
	# server's call: this only lights up when it has offered a HERO_ATTACK.
	if is_mine and _entity_can_act(hero_id):
		panel.set_meta("drag_entity", hero_id)
		if not is_target and hero_id != selected_entity:
			_tint(panel, COLOR_READY)
	if hero_id == selected_entity:
		_tint(panel, COLOR_SELECTED)

	if is_target:
		var prompt := Label.new()
		prompt.text = "◀ target"
		prompt.add_theme_color_override("font_color", Color(0.95, 0.98, 1.0))
		row.add_child(prompt)

	panel.set_meta("target_kind", "entity")
	panel.set_meta("target_id", hero_id)
	return panel

## The equipped Weapon beside its Hero: name, Attack, Durability, and Ranged
## where it applies. Melee is the ordinary case and goes unlabelled.
func _weapon_tile(weapon: Dictionary) -> Control:
	var definition_id := str(weapon.get("definitionId", ""))
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_PASS
	panel.custom_minimum_size = WEAPON_TILE
	_tint(panel, COLOR_EMPTY)

	# Revealed on hover like any other card in play, keyed by instance so a
	# replacement is told apart from the Weapon it replaced.
	panel.set_meta("reveal_key", str(weapon.get("instanceId", definition_id)))
	panel.set_meta("reveal_card", {
		"definition_id": definition_id,
		"attack": weapon.get("currentAttack", library.base_attack(definition_id)),
		"durability": weapon.get("currentDurability", library.base_durability(definition_id)),
	})

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

	if library.is_ranged_weapon(definition_id):
		var ranged := Label.new()
		ranged.mouse_filter = Control.MOUSE_FILTER_IGNORE
		ranged.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		ranged.add_theme_font_size_override("font_size", 9)
		ranged.add_theme_color_override("font_color", Color(0.62, 0.82, 1.0))
		ranged.text = "Ranged"
		column.add_child(ranged)

	var stats := Label.new()
	stats.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stats.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	stats.add_theme_font_size_override("font_size", 10)
	stats.text = "⚔ %s   ◈ %s" % [
		_num(weapon.get("currentAttack", "?")),
		_num(weapon.get("currentDurability", "?")),
	]
	column.add_child(stats)
	return panel

## A small in-play artifact tile: art where there is art, durability always.
func _artifact_tile(artifact: Dictionary) -> Control:
	var definition_id := str(artifact.get("definitionId", ""))
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_PASS
	panel.custom_minimum_size = ARTIFACT_TILE
	_tint(panel, COLOR_EMPTY)

	# Artifacts are in play, so they reveal on hover like creatures do. Their
	# instance id keys the reveal where there is one, so two copies of the same
	# artifact are told apart.
	panel.set_meta("reveal_key", str(artifact.get("instanceId", definition_id)))
	panel.set_meta("reveal_card", {
		"definition_id": definition_id,
		"durability": artifact.get("durability", 0),
	})

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

	if occupant == null:
		var label := Label.new()
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		panel.add_child(label)
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

	# Markers only matter for your own creatures: they say why one cannot act.
	# The engine clears these at the owner's turn start, so an enemy creature
	# keeps them until its own turn comes round.
	var marks := ""
	if is_mine:
		if bool(creature.get("combatActionUsed", false)):
			marks = "acted"
		elif bool(creature.get("summonedThisTurn", false)):
			marks = "sick"
	var shown := {
		"definition_id": definition_id,
		"attack": creature.get("currentAttack", library.base_attack(definition_id)),
		"health": creature.get("currentHealth", library.base_health(definition_id)),
		"max_health": creature.get("maxHealth", library.base_health(definition_id)),
		"statuses": creature.get("statuses", []),
		"marks": marks,
	}
	# In play a creature is its art in a large oval, with its live stats on the
	# badges, as a Hearthstone minion is; resting on it reveals the whole card.
	panel.set_meta("token", true)
	var token := CreatureToken.make(library, shown, SLOT_SIZE)
	panel.add_child(token)
	# A creature just summoned here is still falling in as its card's oval: its
	# token shows once the oval is down, and if the oval is already down and
	# waiting for it, the token takes over now.
	var slot_key := Targeting.slot_key(owner_id, row_name, column)
	panel.set_meta("slot_key", slot_key)
	if play_effect.is_flying(slot_key):
		token.modulate.a = 0.0
		token.guard_entrance(-1.0)
	else:
		if play_effect.is_waiting(slot_key):
			if token._guard.visible and not _guard_arrivals.has(creature_id):
				_guard_arrivals[creature_id] = -1.0
			play_effect.release(slot_key)
		if _guard_arrivals.has(creature_id):
			_reveal_guard(token, creature_id)
	if combat_effect.owns(creature_id):
		token.modulate.a = 0.0
	# The hover reveal replaces the built-in tooltip for cards in play: it shows
	# the whole card, large enough to read its rules, and without the
	# delay-and-follow behaviour of a cursor tooltip.
	panel.set_meta("reveal_key", creature_id)
	panel.set_meta("reveal_card", shown)

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
	hand_view.begin_update()
	var hand: Variant = side.get("hand", [])
	var taika: Dictionary = side.get("taika", {})
	var available := int(taika.get("current", 0))
	if typeof(hand) == TYPE_ARRAY:
		for card in (hand as Array):
			if typeof(card) != TYPE_DICTIONARY:
				continue
			var definition_id := str(card.get("definitionId", ""))
			var panel := _hand_card(card, available)
			var playable := panel.has_meta("drag_card")
			# What the large card on hover shows besides the card itself.
			hand_view.put_card(str(card.get("instanceId", "")), panel, {
				"definition_id": definition_id,
				"playable": playable,
				"unaffordable": library.cost(definition_id) > available,
				"ring": COLOR_READY if playable else COLOR_EMPTY,
				"note": str(panel.get_meta("hand_note", "")),
			})
	hand_view.end_update()

func _hand_card(card: Dictionary, available_taika: int) -> Control:
	var instance_id := str(card.get("instanceId", ""))
	var definition_id := str(card.get("definitionId", ""))
	var panel := PanelContainer.new()
	panel.custom_minimum_size = CARD_SIZE
	panel.mouse_filter = Control.MOUSE_FILTER_PASS

	var cost := library.cost(definition_id)
	# A card is drawn on its type's frame; its cost badge says when it cannot
	# be paid for, which is what the "needs" line says on a card of a type
	# with no frame.
	var label: Label = null
	if CardFrame.supports(library, definition_id):
		panel.set_meta("framed", true)
		panel.add_child(CardFrame.make(library, {
			"definition_id": definition_id,
			"unaffordable": cost > available_taika,
		}, FRAME_WIDTH))
	else:
		label = _hand_card_text(panel, definition_id)
	var line := "%d Taika" % cost
	var kind := library.card_type(definition_id)
	if kind != "":
		line += "\n" + kind.capitalize()
	# No tooltip: hovering shows the card large, with this note beside it.

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
			panel.set_meta("hand_note", "Not enough Taika: %d of %d." % [available_taika, cost])
		else:
			panel.set_meta("hand_note", "No legal play for this card right now.")
	if playable:
		panel.set_meta("drag_card", instance_id)
	if label != null:
		label.text = line
	return panel

## Title, art banner and a detail label for a hand card with no frame: one of
## a type the client has no frame for. Returns the label, for the caller to
## fill.
func _hand_card_text(panel: PanelContainer, definition_id: String) -> Label:
	# The whole column ignores the mouse so a press reaches the panel and
	# starts a drag.
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
	return label

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
	_refresh_combat_bystanders()
	_drop_zones.clear()
	_collect_zones(board_container)
	# The board scrolls, and what is scrolled out of view may lie behind the
	# hand: only what can be seen can be aimed at or revealed.
	var visible_board := board_area.get_global_rect()
	for key in _drop_zones.keys():
		var clipped := (_drop_zones[key]["rect"] as Rect2).intersection(visible_board)
		if clipped.has_area():
			_drop_zones[key]["rect"] = clipped
		else:
			_drop_zones.erase(key)
	# Hand cards are where they rest in the fan, not where they are drawn this
	# frame: a hovered card lifts, and a held one is off following the pointer.
	for id in hand_view.card_ids():
		if bool(hand_view.info_for(id).get("playable", false)):
			_drop_zones["card:" + id] = {
				"rect": hand_view.rest_rect(id),
				"kind": "drag_card",
				"id": id,
			}
	_refresh_reveal()

## Keeps a showing reveal honest after the board is rebuilt: a card that has
## left play stops being revealed, and one whose stats changed re-reads them.
func _refresh_reveal() -> void:
	if reveal == null or not reveal.is_revealing():
		return
	# Hit-test the last point the pointer was seen at rather than asking the
	# OS where the cursor is: the two agree in normal play, but synthetic
	# input drives this code without moving the real cursor.
	var zone := _reveal_zone_at(_hover_at)
	if zone.is_empty():
		reveal.hide_reveal()
		return
	var card: Variant = zone.get("card", {})
	reveal.refresh(
		str(zone.get("id", "")),
		card if typeof(card) == TYPE_DICTIONARY else {},
		zone["rect"] as Rect2
	)

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
			if control.has_meta("reveal_key"):
				_drop_zones["reveal:" + str(control.get_meta("reveal_key"))] = {
					"rect": control.get_global_rect(),
					"kind": "reveal",
					"id": str(control.get_meta("reveal_key")),
					"card": control.get_meta("reveal_card"),
					"control": control,
				}
		_collect_zones(child)

# --- Pointer interaction ----------------------------------------------------

func _gui_input(event: InputEvent) -> void:
	if _combat_locked():
		return
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
	elif event is InputEventMouseMotion:
		var at := (event as InputEventMouseMotion).global_position
		if _dragging or _pressed_source != "":
			_on_pointer_move(at)
		else:
			_on_hover_move(at)

## Tracks the pointer across the board and reveals whatever it rests on.
##
## Hit-testing the cached rects rather than each panel's `mouse_entered` keeps
## this working through the panels' mouse-ignoring children, and reuses the map
## the drag code already maintains.
func _on_hover_move(at: Vector2) -> void:
	if reveal == null:
		return
	_hover_at = at
	# A hand card shows large in the hand itself, so it needs no reveal.
	var in_hand := hand_view.card_at(at)
	hand_view.hover(in_hand)
	if in_hand != "":
		reveal.hide_reveal()
		return
	# Rects go stale whenever the board re-renders, which happens on every
	# state update, so refresh before trusting a miss. The board is a dozen
	# panels, so this is cheaper than tracking when it last changed.
	_rebuild_drop_zones()
	var zone := _reveal_zone_at(at)
	if zone.is_empty():
		reveal.hide_reveal()
		return
	var card: Variant = zone.get("card", {})
	reveal.request(
		str(zone.get("id", "")),
		card if typeof(card) == TYPE_DICTIONARY else {},
		zone["rect"] as Rect2
	)

## The revealable card under a point; the smallest wins, so an artifact tile
## inside a hero strip is not masked by the strip around it.
func _reveal_zone_at(at: Vector2) -> Dictionary:
	var best: Dictionary = {}
	var best_area := INF
	for key in _drop_zones:
		var zone: Dictionary = _drop_zones[key]
		if str(zone.get("kind", "")) != "reveal":
			continue
		var rect: Rect2 = zone["rect"]
		if not rect.has_point(at):
			continue
		var area := rect.size.x * rect.size.y
		if area < best_area:
			best_area = area
			best = zone
	return best

func _on_pointer_down(at: Vector2) -> void:
	_rebuild_drop_zones()
	# Hand cards overlap, so the hand says which one is on top under the
	# pointer rather than the first rect that contains it.
	var card_id := hand_view.card_at(at)
	if card_id != "":
		if not _drop_zones.has("card:" + card_id):
			var note := str(hand_view.info_for(card_id).get("note", ""))
			if note != "":
				_set_status(note, true)
			return
		_pressed_source = card_id
		_pressed_is_card = true
		_press_origin = at
		_dragging = false
		return
	var zone := _zone_at(at, ["drag_entity"])
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
	if selected_card != "":
		if _card_mode == "place":
			hand_view.move_held(at)
			var drop_key := _card_drop_key(at)
			_set_hovered(drop_key)
			hand_view.set_held_ready(drop_key != "" or _plays_untargeted_at(at))
			return
		if _over_hand(at):
			# Back over the hand the card follows again, and letting go there
			# puts it back, as in Hearthstone.
			hand_view.move_held(at)
			arrow.finish()
			_set_hovered("")
			return
		if not arrow.active:
			hand_view.park_held()
			arrow.begin(hand_view.park_point() - arrow.global_position)
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
		if selected_card != "":
			_drop_card(at)
		else:
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

	# A click on a hand card picks it up: it follows the pointer, without the
	# button held, until the next click plays it or puts it back.
	if _pressed_source != "" and _pressed_is_card:
		_begin_drag(_pressed_source, true)
		_sticky = _dragging
		if _dragging:
			_on_pointer_move(at)
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
		_begin_card_drag(source_id)
		return
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
	# The reveal would sit over the very targets the drag is aiming at.
	if reveal != null:
		reveal.hide_reveal()
	var zone_key := "drag:" + source_id
	var origin := _press_origin
	if _drop_zones.has(zone_key):
		origin = (_drop_zones[zone_key]["rect"] as Rect2).get_center()
	arrow.begin(origin - arrow.global_position)
	# Light up the newly valid destinations without rebuilding the board, so
	# the rects this drag hit-tests against stay alive.
	_repaint_highlights()
	_render_actions()

## Picks a hand card up. It follows the pointer whatever it plays as: a card
## with somewhere to land ("place") is put down where it is let go, and one
## that only targets ("aim") parks above the hand once it leaves it, and the
## arrow takes over. Nothing is sent until the card is let go.
func _begin_card_drag(card_id: String) -> void:
	selected_card = card_id
	selected_entity = ""
	_refresh_targets()
	if _selection_actions().is_empty():
		_clear_selection()
		_pressed_source = ""
		return
	_card_mode = "aim" if slot_targets.is_empty() and not entity_targets.is_empty() else "place"
	_dragging = true
	if reveal != null:
		reveal.hide_reveal()
	hand_view.pick_up(card_id, _press_origin)
	_repaint_highlights()
	_render_actions()

## Lets a held card go at `at`, playing it if that is somewhere it can land.
func _drop_card(at: Vector2) -> void:
	var card_id := selected_card
	var played := false
	# The slot a creature is summoned to, which its oval falls into.
	var landing_slot := ""
	if _card_mode == "place":
		var key := _card_drop_key(at)
		if key != "":
			if slot_targets.has(key):
				landing_slot = key
			played = _commit_target(key)
		elif _plays_untargeted_at(at):
			played = _submit(_untargeted_for_selection() as Dictionary)
	elif not _over_hand(at):
		var hovered := _target_zone_at(at)
		if not hovered.is_empty():
			played = _commit_target(str(hovered.get("key", "")))
		else:
			_set_status("No legal target there.", true)
	if played:
		_play_card_effect(card_id, landing_slot)
		hand_view.spend_held(false)
	_clear_selection()

## Breaks the played card up where it was let go. A creature summoned to a slot
## leaves its art oval, which falls into that slot.
func _play_card_effect(card_id: String, landing_slot: String) -> void:
	var held := hand_view.panel_for(card_id)
	var card := _hand_entry(card_id)
	if held == null or card.is_empty():
		return
	var side: Dictionary = (state.get("sides", {}) as Dictionary).get(player_id, {})
	var available := int((side.get("taika", {}) as Dictionary).get("current", 0))
	# A fresh copy of the card for the effect to break up: the hand keeps its
	# own, to bring back if the server refuses the play.
	var copy := _hand_card(card, available)
	var landing := Rect2()
	if landing_slot != "" and _drop_zones.has(landing_slot):
		var slot: Variant = _drop_zones[landing_slot].get("control", null)
		if slot is Control and is_instance_valid(slot):
			# Where the token's oval will be, once the creature is in the slot.
			var area := (slot as Control).get_global_rect()
			landing = Rect2(
				area.position + CreatureToken.OVAL.position * area.size,
				CreatureToken.OVAL.size * area.size
			)
	play_effect.play(copy, held, landing, landing_slot if landing.has_area() else "")

## The card with `card_id` in the player's hand, as the state has it, or {}.
func _hand_entry(card_id: String) -> Dictionary:
	var side: Dictionary = (state.get("sides", {}) as Dictionary).get(player_id, {})
	var hand: Variant = side.get("hand", [])
	if typeof(hand) == TYPE_ARRAY:
		for card in (hand as Array):
			if typeof(card) == TYPE_DICTIONARY and str(card.get("instanceId", "")) == card_id:
				return card
	return {}

## An oval came down in its slot. If the server has already put the creature
## there, its token takes over now; otherwise the oval waits on the board, and
## the render that brings the creature releases it.
func _on_oval_landed(slot_key: String) -> void:
	var token := _token_in_slot(board_container, slot_key)
	if token != null:
		_reveal_guard(token, str(token.get_parent().get_meta("reveal_key", "")))
		if not combat_effect.owns(str(token.get_parent().get_meta("reveal_key", ""))):
			token.modulate.a = 1.0
		play_effect.release(slot_key)

func _reveal_guard(token: CreatureToken, creature_id: String) -> void:
	if not token._guard.visible:
		return
	var now := Time.get_ticks_msec() / 1000.0
	var started := float(_guard_arrivals.get(creature_id, -1.0))
	if started < 0.0:
		started = now
		_guard_arrivals[creature_id] = started
	var age := now - started
	token.guard_entrance(age)
	if age >= CreatureToken.GUARD_ENTRANCE:
		_guard_arrivals.erase(creature_id)

func _token_in_slot(node: Node, slot_key: String) -> CreatureToken:
	for child in node.get_children():
		if child is Control and str((child as Control).get_meta("slot_key", "")) == slot_key:
			for inner in child.get_children():
				if inner is CreatureToken:
					return inner
		var found := _token_in_slot(child, slot_key)
		if found != null:
			return found
	return null

## Where a placed card would land if let go at `at`: the lit target under the
## pointer, or anywhere over the battlefield, the lit slot nearest to it —
## Hearthstone puts a minion down wherever it is let go over the board.
func _card_drop_key(at: Vector2) -> String:
	var hovered := _target_zone_at(at)
	if hovered.is_empty():
		_rebuild_drop_zones()
		hovered = _target_zone_at(at)
	if not hovered.is_empty():
		return str(hovered.get("key", ""))
	if not _over_board(at):
		return ""
	var nearest := ""
	var nearest_distance := INF
	for key in slot_targets:
		if not _drop_zones.has(key):
			continue
		var distance := ((_drop_zones[key]["rect"] as Rect2).get_center()).distance_to(at)
		if distance < nearest_distance:
			nearest_distance = distance
			nearest = str(key)
	return nearest

## Whether letting the held card go at `at` plays it with no target, as a
## spell that needs none does when dropped on the battlefield.
func _plays_untargeted_at(at: Vector2) -> bool:
	return _over_board(at) and _untargeted_for_selection() != null

func _over_board(at: Vector2) -> bool:
	return board_area.get_global_rect().has_point(at) and not _over_hand(at)

func _over_hand(at: Vector2) -> bool:
	return hand_view.get_global_rect().has_point(at)

func _set_hovered(key: String) -> void:
	if key == _hovered_key:
		return
	_hovered_key = key
	_repaint_highlights()

func _end_drag() -> void:
	_dragging = false
	_pressed_source = ""
	_hovered_key = ""
	_card_mode = ""
	_sticky = false
	arrow.finish()
	# A card still held was not played, so it goes back to the hand.
	hand_view.return_held()

func _cancel_drag() -> void:
	_end_drag()
	_clear_selection()
	if reveal != null:
		reveal.hide_reveal()

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

## Sends the selection's action for `key`; true if it went to the server.
func _commit_target(key: String) -> bool:
	if key == "":
		return false
	var action: Variant = slot_targets.get(key, entity_targets.get(key, null))
	if action == null:
		_set_status("That is not a legal target for this selection.", true)
		return false
	var sent := _submit(action as Dictionary)
	_clear_selection()
	return sent

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
	if str(state.get("phase", "")) == "FINISHED":
		end_turn_button.disabled = true
		action_hint.text = "Match over."
		return
	if _combat_locked():
		end_turn_button.disabled = true
		action_hint.text = "Combat resolving..."
		return
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

## Sends an action; true if it went to the server.
func _submit(action: Dictionary) -> bool:
	if _combat_locked():
		return false
	if not client.submit_action(action):
		_set_status("Not connected — press Join to reconnect.", true)
		return false
	_clear_selection()
	return true

## While something is pressed or held, the pointer belongs to it wherever it
## goes. Otherwise a button under a held card would take the click meant to
## play it, and the card would stop following the pointer over the side panel.
func _input(event: InputEvent) -> void:
	if _combat_locked() or not game_root.visible or not (event is InputEventMouse):
		return
	var button := event as InputEventMouseButton
	if button != null and _swallow_release and button.button_index == MOUSE_BUTTON_LEFT \
			and not button.pressed:
		_swallow_release = false
		get_viewport().set_input_as_handled()
		return
	if not _dragging and _pressed_source == "":
		return
	var at := (event as InputEventMouse).global_position
	if event is InputEventMouseMotion:
		_on_pointer_move(at)
	elif button != null and button.button_index == MOUSE_BUTTON_RIGHT:
		if button.pressed:
			# Right click cancels, as in Hearthstone.
			_cancel_drag()
			_render_state()
			_render_actions()
	elif button != null and button.button_index == MOUSE_BUTTON_LEFT:
		if button.pressed and _sticky:
			# The click that sets a held card down; its release is not a second.
			_swallow_release = true
			_on_pointer_up(at)
		elif not button.pressed:
			_on_pointer_up(at)
	else:
		return
	get_viewport().set_input_as_handled()

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
	if panel.has_meta("token"):
		# A creature's oval carries the colour as a ring of its own; a
		# rectangle behind it would show at the corners.
		for child in panel.get_children():
			if child is CreatureToken:
				(child as CreatureToken).ring_color = color
		panel.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
		return
	if panel.has_meta("framed"):
		# Likewise a card: its frame is clear at the sides, so it draws the
		# ring round its own body. The margin keeps room for the ring.
		for child in panel.get_children():
			if child is CardFrame:
				(child as CardFrame).ring_color = color
				(child as CardFrame).ring_width = FRAME_RING
		var room := StyleBoxEmpty.new()
		room.set_content_margin_all(FRAME_RING)
		panel.add_theme_stylebox_override("panel", room)
		return
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
