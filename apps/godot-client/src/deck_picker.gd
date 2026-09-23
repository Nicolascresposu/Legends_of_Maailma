extends Control

## Chooses the deck a player enters a match with.
##
## Shown whenever a player starts or joins a match: a match is always played
## with one of the player's own decks, never a default. Only a deck the server
## reports as ready can be picked; the others are listed with the reason they
## are not, so the way forward is visible. The server judges the deck again
## when it arrives, so this screen is a convenience, never the gate.

## A ready deck was chosen.
signal picked(deck_id: String)
signal cancelled()
## The player wants to go and build or fix a deck.
signal build_requested()

const HERO_NAMES := {"healer": "The Mender", "striker": "The Striker"}

var library: CardLibrary

var _title: Label
var _note: Label
var _list: VBoxContainer
var _decks: Array = []
var _loaded := false

func setup(card_library: CardLibrary) -> void:
	library = card_library

func _init() -> void:
	visible = false
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# Blocks the board beneath while a choice is being made.
	mouse_filter = Control.MOUSE_FILTER_STOP

func _ready() -> void:
	var backdrop := ColorRect.new()
	backdrop.color = Color(0, 0, 0, 0.55)
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(backdrop)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(460, 0)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.11, 0.12, 0.15)
	style.border_color = Color(0.85, 0.74, 0.44)
	style.set_border_width_all(2)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(14)
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	panel.add_child(column)

	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 18)
	column.add_child(_title)

	_note = Label.new()
	_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_note.add_theme_color_override("font_color", Color(0.72, 0.74, 0.80))
	column.add_child(_note)

	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 6)
	column.add_child(_list)

	var footer := HBoxContainer.new()
	footer.alignment = BoxContainer.ALIGNMENT_END
	footer.add_theme_constant_override("separation", 6)
	column.add_child(footer)

	var build := Button.new()
	build.text = "Build a deck"
	build.tooltip_text = "Open the collection to build or fix a deck."
	build.pressed.connect(func() -> void:
		close()
		build_requested.emit())
	footer.add_child(build)

	var cancel := Button.new()
	cancel.text = "Cancel"
	cancel.pressed.connect(func() -> void:
		close()
		cancelled.emit())
	footer.add_child(cancel)

## Opens the picker. Decks arrive separately through `set_decks`, since they
## are fetched fresh each time: readiness may have changed since last shown.
func open(title: String) -> void:
	_title.text = title
	_loaded = false
	_decks = []
	visible = true
	_render()

func close() -> void:
	visible = false

func is_open() -> bool:
	return visible

## The player's decks, as the server reported them with readiness attached.
func set_decks(decks: Array) -> void:
	_decks = decks
	_loaded = true
	if visible:
		_render()

## The decks that may be picked right now.
func playable_deck_ids() -> Array:
	var ids: Array = []
	for deck in _decks:
		if typeof(deck) == TYPE_DICTIONARY and _is_playable(deck):
			ids.append(str(deck.get("id", "")))
	return ids

## Picks a deck as if its button were pressed. Refused unless it is ready.
func pick(deck_id: String) -> bool:
	if not playable_deck_ids().has(deck_id):
		return false
	close()
	picked.emit(deck_id)
	return true

func _render() -> void:
	for child in _list.get_children():
		_list.remove_child(child)
		child.queue_free()
	if not _loaded:
		_note.text = "Loading your decks…"
		return
	var ordered := _decks.duplicate()
	# The active deck first: it is the one the player most likely means.
	ordered.sort_custom(func(a: Variant, b: Variant) -> bool:
		return bool((a as Dictionary).get("isActive", false)) \
			and not bool((b as Dictionary).get("isActive", false)))
	for deck in ordered:
		if typeof(deck) == TYPE_DICTIONARY:
			_list.add_child(_deck_row(deck))
	if _decks.is_empty():
		_note.text = "You have no decks yet. Build one in the collection to play."
	elif playable_deck_ids().is_empty():
		_note.text = "None of your decks is ready to play. Fix one in the collection first."
	else:
		_note.text = "You play the deck's hero, with the deck's cards."

func _deck_row(deck: Dictionary) -> Control:
	var deck_id := str(deck.get("id", ""))
	var playable := _is_playable(deck)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var text := VBoxContainer.new()
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(text)

	var hero_id := str(deck.get("heroId", ""))
	var deck_name := Label.new()
	deck_name.text = "%s%s" % ["★ " if bool(deck.get("isActive", false)) else "", str(deck.get("name", ""))]
	text.add_child(deck_name)

	var detail := Label.new()
	detail.add_theme_font_size_override("font_size", 11)
	var hero_class := str(CollectionScreen.HERO_CLASSES.get(hero_id, ""))
	detail.text = "%s · %s · %s" % [
		str(HERO_NAMES.get(hero_id, hero_id)),
		str(CollectionScreen.CLASS_NAMES.get(hero_class, hero_class)),
		str(deck.get("format", "STANDARD")).capitalize(),
	]
	detail.add_theme_color_override("font_color", Color(0.66, 0.69, 0.76))
	text.add_child(detail)

	var status := Label.new()
	status.add_theme_font_size_override("font_size", 11)
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if playable:
		status.text = "Ready to play"
		status.add_theme_color_override("font_color", Color(0.50, 0.85, 0.55))
	else:
		status.text = "Not ready: " + _first_problem(deck)
		status.add_theme_color_override("font_color", Color(0.93, 0.62, 0.40))
	text.add_child(status)

	var play := Button.new()
	play.text = "Play"
	play.disabled = not playable
	play.tooltip_text = "" if playable else "Only a ready deck can be played."
	play.pressed.connect(func() -> void: pick(deck_id))
	row.add_child(play)
	return row

func _is_playable(deck: Dictionary) -> bool:
	var readiness: Variant = deck.get("readiness", {})
	return typeof(readiness) == TYPE_DICTIONARY and bool((readiness as Dictionary).get("playable", false))

## The one reason worth showing in a list row; the collection has the rest.
func _first_problem(deck: Dictionary) -> String:
	var readiness: Variant = deck.get("readiness", {})
	if typeof(readiness) != TYPE_DICTIONARY:
		return "its readiness is unknown"
	var errors: Variant = (readiness as Dictionary).get("ruleErrors", [])
	if typeof(errors) == TYPE_ARRAY and not (errors as Array).is_empty():
		return str((errors as Array)[0])
	var missing: Variant = (readiness as Dictionary).get("missing", [])
	if typeof(missing) == TYPE_ARRAY and not (missing as Array).is_empty():
		var first: Dictionary = (missing as Array)[0]
		var card_id := str(first.get("cardId", ""))
		var shown: String = library.card_name(card_id) if library != null else card_id
		return "you own %d of the %d %s it needs" % [
			int(first.get("owned", 0)), int(first.get("required", 0)), shown,
		]
	var rotated: Variant = (readiness as Dictionary).get("illegalInFormat", [])
	if typeof(rotated) == TYPE_ARRAY and not (rotated as Array).is_empty():
		return "it holds cards not legal in its format"
	return "it cannot be played"
