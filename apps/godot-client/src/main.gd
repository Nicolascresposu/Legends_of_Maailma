extends Control

## Maailma TCG presentation client.
##
## The client renders state and offers the server's legal actions. It never
## decides legality: selecting a creature or card filters that action list, and
## every choice is sent to the server for validation.

const SLOT_SIZE := Vector2(148, 96)
const CARD_SIZE := Vector2(132, 92)
const MAX_LOG_LINES := 120

const COLOR_EMPTY := Color(0.16, 0.17, 0.21)
const COLOR_FRIENDLY := Color(0.16, 0.30, 0.24)
const COLOR_ENEMY := Color(0.34, 0.18, 0.20)
const COLOR_SELECTED := Color(0.95, 0.76, 0.28)
const COLOR_TARGET := Color(0.38, 0.62, 0.90)
const COLOR_READY := Color(0.45, 0.85, 0.55)

var client: MatchClient
var library := CardLibrary.new()

var state: Dictionary = {}
var legal_actions: Array = []
var player_id := "player-a"
var opponent_id := ""
var selected_entity := ""
var selected_card := ""
var log_lines: Array[String] = []

@onready var _focus_default := player_id

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

	_build_interface()
	client.fetch_cards()

# --- Interface construction -------------------------------------------------

func _build_interface() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 14)
	add_child(margin)

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
	action_hint.text = "Select one of your creatures or a card to narrow this list."
	action_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	action_hint.add_theme_font_size_override("font_size", 11)
	panel.add_child(action_hint)

	var action_scroll := ScrollContainer.new()
	action_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	action_scroll.custom_minimum_size.y = 220
	panel.add_child(action_scroll)
	action_container = VBoxContainer.new()
	action_container.add_theme_constant_override("separation", 4)
	action_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	action_scroll.add_child(action_container)

	panel.add_child(_section_title("Match log"))
	log_label = RichTextLabel.new()
	log_label.bbcode_enabled = true
	log_label.scroll_following = true
	log_label.custom_minimum_size.y = 190
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

# --- Connection actions -----------------------------------------------------

func _create_match(scenario_id: String) -> void:
	_apply_inputs()
	if player_id.is_empty():
		_set_status("Enter a Player ID first.", true)
		return
	_set_status("Creating match…")
	client.create_match(scenario_id, player_id, _selected_hero_id(), _starter_deck())

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
	selected_entity = ""
	selected_card = ""
	_render_state()

func _on_legal_actions(target_player: String, actions: Array) -> void:
	if target_player != player_id:
		return
	legal_actions = actions
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

func _on_server_error(code: String, message: String) -> void:
	_set_status("%s: %s" % [code, message], true)
	_append_log("[color=#e06c75]%s — %s[/color]" % [code, message])

# --- Rendering --------------------------------------------------------------

func _render_state() -> void:
	_clear(board_container)
	_clear(hand_container)
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

## Hero, Taika, deck and hand counts for one side.
func _hero_strip(side_id: String, side: Dictionary, is_mine: bool) -> Control:
	var panel := PanelContainer.new()
	_tint(panel, COLOR_FRIENDLY if is_mine else COLOR_ENEMY)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
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

	if str(hero.get("powerUsedThisTurn", false)) == "true":
		var used := Label.new()
		used.text = "Hero Power used"
		used.add_theme_color_override("font_color", Color(0.7, 0.7, 0.74))
		row.add_child(used)
	return panel

func _render_side(side: Dictionary, rows: Array, is_mine: bool) -> void:
	var battlefield: Dictionary = side.get("battlefield", {})
	var config: Dictionary = battlefield.get("config", {})
	var width := int(config.get("width", 0))
	if width <= 0:
		return
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
			grid.add_child(_slot_button(str(row_name), column, occupant, creatures, is_mine))

func _slot_button(
	row_name: String, column: int, occupant: Variant, creatures: Dictionary, is_mine: bool
) -> Control:
	var button := Button.new()
	button.custom_minimum_size = SLOT_SIZE
	button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	button.clip_text = true

	if occupant == null:
		var is_open := _slot_is_targetable(row_name, column)
		# An unreachable empty slot stays quiet; a reachable one invites a click.
		button.text = "＋" if is_open else ""
		button.disabled = not is_open
		button.tooltip_text = "%s %d — empty" % [row_name.capitalize(), column]
		if is_open:
			_tint_button(button, COLOR_TARGET)
			button.pressed.connect(_on_slot_pressed.bind(row_name, column))
		else:
			_tint_button(button, COLOR_EMPTY)
		return button

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
	button.text = "%s\n⚔ %s  ♥ %s%s" % [
		display_name,
		_num(creature.get("currentAttack", "?")),
		health_text,
		marks,
	]
	if not keyword_list.is_empty():
		button.text += "\n" + ", ".join(keyword_list)
	button.tooltip_text = library.tooltip(definition_id)

	if creature_id == selected_entity:
		_tint_button(button, COLOR_SELECTED)
	elif is_mine and _entity_has_actions(creature_id):
		_tint_button(button, COLOR_READY)
	elif _entity_is_targetable(creature_id):
		_tint_button(button, COLOR_TARGET)

	button.pressed.connect(_on_entity_pressed.bind(creature_id))
	return button

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
	var button := Button.new()
	button.custom_minimum_size = CARD_SIZE
	button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	button.clip_text = true
	var cost := library.cost(definition_id)
	var kind := library.card_type(definition_id)
	var line := "%s\n%d Taika" % [library.card_name(definition_id), cost]
	if kind == "CREATURE":
		line += "\n%d/%d" % [library.base_attack(definition_id), library.base_health(definition_id)]
	elif kind != "":
		line += "\n" + kind.capitalize()
	button.text = line
	button.tooltip_text = library.tooltip(definition_id)

	var playable := _card_has_actions(instance_id)
	if instance_id == selected_card:
		_tint_button(button, COLOR_SELECTED)
	elif playable:
		_tint_button(button, COLOR_READY)
	else:
		button.modulate = Color(0.68, 0.68, 0.72)
		# Say why a card cannot be played, rather than just greying it out.
		if cost > available_taika:
			button.text += "\n(needs %d)" % cost
			button.tooltip_text += "\n\nNot enough Taika: %d of %d." % [available_taika, cost]
		else:
			button.tooltip_text += "\n\nNo legal play for this card right now."
	button.pressed.connect(_on_card_pressed.bind(instance_id))
	return button

# --- Selection and actions --------------------------------------------------

func _on_entity_pressed(entity_id: String) -> void:
	selected_card = ""
	selected_entity = "" if selected_entity == entity_id else entity_id
	_render_state()
	_render_actions()

func _on_card_pressed(card_instance_id: String) -> void:
	selected_entity = ""
	selected_card = "" if selected_card == card_instance_id else card_instance_id
	_render_state()
	_render_actions()

func _on_slot_pressed(row_name: String, column: int) -> void:
	# An empty slot is only clickable when the current selection can reach it.
	for action in legal_actions:
		if typeof(action) != TYPE_DICTIONARY:
			continue
		var position: Variant = action.get("position", action.get("destination", null))
		if typeof(position) != TYPE_DICTIONARY:
			continue
		if str((position as Dictionary).get("row", "")) != row_name:
			continue
		if int((position as Dictionary).get("column", -1)) != column:
			continue
		if _action_matches_selection(action):
			_submit(action)
			return

func _action_matches_selection(action: Dictionary) -> bool:
	if selected_card != "":
		return str(action.get("cardInstanceId", "")) == selected_card
	if selected_entity != "":
		return str(action.get("creatureId", "")) == selected_entity
	return false

func _slot_is_targetable(row_name: String, column: int) -> bool:
	if selected_card == "" and selected_entity == "":
		return false
	for action in legal_actions:
		if typeof(action) != TYPE_DICTIONARY:
			continue
		var position: Variant = action.get("position", action.get("destination", null))
		if typeof(position) != TYPE_DICTIONARY:
			continue
		if str((position as Dictionary).get("row", "")) == row_name \
				and int((position as Dictionary).get("column", -1)) == column \
				and _action_matches_selection(action):
			return true
	return false

func _entity_has_actions(entity_id: String) -> bool:
	for action in legal_actions:
		if typeof(action) != TYPE_DICTIONARY:
			continue
		if str(action.get("attackerId", "")) == entity_id \
				or str(action.get("creatureId", "")) == entity_id \
				or str(action.get("firstCreatureId", "")) == entity_id \
				or str(action.get("secondCreatureId", "")) == entity_id:
			return true
	return false

func _card_has_actions(card_instance_id: String) -> bool:
	for action in legal_actions:
		if typeof(action) != TYPE_DICTIONARY:
			continue
		if str(action.get("cardInstanceId", "")) == card_instance_id:
			return true
	return false

func _entity_is_targetable(entity_id: String) -> bool:
	if selected_entity == "" and selected_card == "":
		return false
	for action in legal_actions:
		if typeof(action) != TYPE_DICTIONARY:
			continue
		if str(action.get("targetId", "")) != entity_id:
			continue
		if selected_card != "" and str(action.get("cardInstanceId", "")) == selected_card:
			return true
		if selected_entity != "" and str(action.get("attackerId", "")) == selected_entity:
			return true
		if selected_entity != "" and str(action.get("secondCreatureId", "")) == selected_entity:
			return true
	return false

## Actions relevant to the current selection, or all of them when nothing is selected.
func _visible_actions() -> Array:
	if selected_card == "" and selected_entity == "":
		return legal_actions
	var filtered: Array = []
	for action in legal_actions:
		if typeof(action) != TYPE_DICTIONARY:
			continue
		var kind := str(action.get("type", ""))
		if kind == "END_TURN" or kind == "USE_HERO_POWER":
			filtered.append(action)
		elif selected_card != "" and str(action.get("cardInstanceId", "")) == selected_card:
			filtered.append(action)
		elif selected_entity != "" and (
			str(action.get("attackerId", "")) == selected_entity
			or str(action.get("creatureId", "")) == selected_entity
			or str(action.get("firstCreatureId", "")) == selected_entity
			or str(action.get("secondCreatureId", "")) == selected_entity
		):
			filtered.append(action)
	return filtered

func _render_actions() -> void:
	_clear(action_container)
	var is_my_turn := str(state.get("activePlayerId", "")) == player_id
	end_turn_button.disabled = not is_my_turn or legal_actions.is_empty()

	if legal_actions.is_empty():
		action_hint.text = "Waiting for the opponent…" if not is_my_turn else "No legal actions."
		return

	var visible := _visible_actions()
	if selected_card != "":
		action_hint.text = "Showing actions for the selected card. Click it again to clear."
	elif selected_entity != "":
		action_hint.text = "Showing actions for the selected creature. Click it again to clear."
	else:
		action_hint.text = "Select one of your creatures or a card to narrow this list."

	# Group actions so a long list stays scannable.
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
	selected_entity = ""
	selected_card = ""

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

func _tint_button(button: Button, color: Color) -> void:
	for state_name in ["normal", "hover", "pressed", "focus"]:
		var style := StyleBoxFlat.new()
		style.bg_color = color if state_name != "hover" else color.lightened(0.12)
		style.set_corner_radius_all(4)
		style.set_content_margin_all(4)
		button.add_theme_stylebox_override(state_name, style)

func _clear(node: Node) -> void:
	for child in node.get_children():
		node.remove_child(child)
		child.queue_free()
