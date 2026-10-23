extends VBoxContainer

## Admin edits to a live match: put any card into a hand, set any Hero's or
## Creature's Attack and Health.
##
## Used twice — in the admin panel, for any match, and as a bar in the match
## view, for the one being played. The server applies the edit and pushes the
## new state to everyone in the match, so this never changes the board itself.

## An edit was applied; `summary` is the match as the server now reports it.
signal edited(summary: Dictionary)

var accounts: AccountClient
var library: CardLibrary

## The match being edited, and its latest state.
var match_id := ""
var _state: Dictionary = {}
## The viewer's own player id, so their side reads "You" rather than an id.
var _me := ""
## Every card the server knows, unreleased included, from the admin registry.
var _cards: Array = []
var _registry_requested := false

var _player_picker: OptionButton
var _card_picker: OptionButton
var _entity_picker: OptionButton
var _attack_input: LineEdit
var _health_input: LineEdit
var _status: Label
var _player_ids: Array[String] = []
var _entity_ids: Array[String] = []

func setup(account_client: AccountClient, card_library: CardLibrary) -> void:
	accounts = account_client
	library = card_library
	accounts.admin_response.connect(_on_admin_response)

func _ready() -> void:
	add_theme_constant_override("separation", 4)

	var hand_row := HBoxContainer.new()
	hand_row.add_theme_constant_override("separation", 6)
	add_child(hand_row)
	hand_row.add_child(_label("Add"))
	_card_picker = OptionButton.new()
	_card_picker.custom_minimum_size.x = 200
	_card_picker.fit_to_longest_item = false
	hand_row.add_child(_card_picker)
	hand_row.add_child(_label("to"))
	_player_picker = OptionButton.new()
	_player_picker.custom_minimum_size.x = 140
	hand_row.add_child(_player_picker)
	var add := Button.new()
	add.text = "Add to hand"
	add.pressed.connect(_add_card)
	hand_row.add_child(add)

	var stats_row := HBoxContainer.new()
	stats_row.add_theme_constant_override("separation", 6)
	add_child(stats_row)
	stats_row.add_child(_label("Set"))
	_entity_picker = OptionButton.new()
	_entity_picker.custom_minimum_size.x = 220
	_entity_picker.fit_to_longest_item = false
	stats_row.add_child(_entity_picker)
	_attack_input = LineEdit.new()
	_attack_input.placeholder_text = "Attack"
	_attack_input.custom_minimum_size.x = 64
	stats_row.add_child(_attack_input)
	_health_input = LineEdit.new()
	_health_input.placeholder_text = "Health"
	_health_input.custom_minimum_size.x = 64
	stats_row.add_child(_health_input)
	var set_button := Button.new()
	set_button.text = "Set stats"
	set_button.tooltip_text = "Leave a field empty to keep it. A Hero's Attack is its Weapon's."
	set_button.pressed.connect(_set_stats)
	stats_row.add_child(set_button)

	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 11)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_status)

## Points the tools at a match. Called again whenever its state changes, so
## the pickers list what is actually on the board.
func show_match(id: String, state: Dictionary, me: String = "") -> void:
	# The card list is fetched on first use rather than at startup, so a
	# client that never opens the admin UI never calls the admin API.
	if _cards.is_empty() and not _registry_requested:
		_registry_requested = true
		accounts.admin(HTTPClient.METHOD_GET, "/registry", null, _tag("registry"))
	match_id = id
	_state = state
	_me = me
	_fill_players()
	_fill_entities()

func _fill_players() -> void:
	var keep := _selected(_player_picker, _player_ids)
	_player_picker.clear()
	_player_ids.clear()
	for player in _state.get("playerOrder", []):
		var id := str(player)
		_player_ids.append(id)
		_player_picker.add_item(_player_label(id))
	_restore(_player_picker, _player_ids, keep)

func _fill_entities() -> void:
	var keep := _selected(_entity_picker, _entity_ids)
	_entity_picker.clear()
	_entity_ids.clear()
	var sides: Dictionary = _state.get("sides", {})
	for player in _state.get("playerOrder", []):
		var id := str(player)
		var side: Dictionary = sides.get(id, {})
		var hero: Dictionary = side.get("hero", {})
		_entity_ids.append("%s:hero" % id)
		_entity_picker.add_item("%s — Hero ♥%s" % [
			_player_label(id), _num(hero.get("currentHealth", "?")),
		])
		var creatures: Dictionary = side.get("creatures", {})
		for creature_id in creatures:
			var creature: Dictionary = creatures[creature_id]
			_entity_ids.append(str(creature_id))
			_entity_picker.add_item("%s — %s ⚔%s ♥%s" % [
				_player_label(id),
				library.card_name(str(creature.get("definitionId", ""))),
				_num(creature.get("currentAttack", "?")),
				_num(creature.get("currentHealth", "?")),
			])
	_restore(_entity_picker, _entity_ids, keep)

func _add_card() -> void:
	if match_id == "" or _card_picker.selected < 0 or _player_picker.selected < 0:
		_say("Pick a card and a player.", true)
		return
	var card_id := str(_card_picker.get_item_metadata(_card_picker.selected))
	accounts.admin(HTTPClient.METHOD_POST, "/matches/%s/hand" % match_id, {
		"playerId": _player_ids[_player_picker.selected],
		"cardId": card_id,
	}, _tag("edit"))

func _set_stats() -> void:
	if match_id == "" or _entity_picker.selected < 0:
		_say("Pick a Hero or Creature.", true)
		return
	var body := {"entityId": _entity_ids[_entity_picker.selected]}
	for pair in [["attack", _attack_input], ["health", _health_input]]:
		var text := (pair[1] as LineEdit).text.strip_edges()
		if text == "":
			continue
		if not text.is_valid_int():
			_say("%s must be a whole number." % str(pair[0]).capitalize(), true)
			return
		body[pair[0]] = int(text)
	if body.size() == 1:
		_say("Enter an Attack, a Health, or both.", true)
		return
	accounts.admin(HTTPClient.METHOD_POST, "/matches/%s/stats" % match_id, body, _tag("edit"))

func _on_admin_response(tag: String, ok: bool, payload: Dictionary) -> void:
	if tag == _tag("registry") or tag == "admin:registry":
		if ok:
			_cards = payload.get("cards", [])
			_fill_cards()
		else:
			_registry_requested = false
		return
	if tag != _tag("edit"):
		return
	if not ok:
		_say(str(payload.get("message", "That edit was refused.")), true)
		return
	_say("Done. This match has had %d admin edit(s)." % int(payload.get("debugEdits", 0)))
	_attack_input.text = ""
	_health_input.text = ""
	edited.emit(payload.get("summary", {}))

func _fill_cards() -> void:
	_card_picker.clear()
	var sorted := _cards.duplicate()
	sorted.sort_custom(func(a: Variant, b: Variant) -> bool:
		return str((a as Dictionary).get("name", "")) < str((b as Dictionary).get("name", "")))
	for card in sorted:
		var entry: Dictionary = card
		_card_picker.add_item("%s (%s)" % [str(entry.get("name", "")), str(entry.get("id", ""))])
		_card_picker.set_item_metadata(_card_picker.item_count - 1, str(entry.get("id", "")))

func _player_label(id: String) -> String:
	if id == _me:
		return "You"
	if id == "ai":
		return "AI"
	return id.substr(0, 8)

## Replies are routed by tag, and several of these tools can be alive at once.
func _tag(operation: String) -> String:
	return "match-tools:%d:%s" % [get_instance_id(), operation]

func _selected(picker: OptionButton, ids: Array[String]) -> String:
	if picker.selected < 0 or picker.selected >= ids.size():
		return ""
	return ids[picker.selected]

func _restore(picker: OptionButton, ids: Array[String], id: String) -> void:
	var index := ids.find(id)
	if index >= 0:
		picker.select(index)

func _say(text: String, is_error: bool = false) -> void:
	_status.text = text
	_status.add_theme_color_override(
		"font_color", Color(0.9, 0.45, 0.45) if is_error else Color(0.55, 0.85, 0.6)
	)

func _label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	return label

func _num(value: Variant) -> String:
	if typeof(value) == TYPE_FLOAT:
		return str(int(round(value as float)))
	return str(value)
