extends VBoxContainer

## Local JSON authoring, hosted by the admin panel. Drafts use their own library.
const Files := preload("res://src/expansion_files.gd")
const Validator := preload("res://src/content_validator.gd")
const Form := preload("res://src/content_form.gd")
const Frame := preload("res://src/card_frame.gd")
const Library := preload("res://src/card_library.gd")
const SETTINGS := "user://expansion_creator.cfg"
const Publisher := preload("res://src/content_publisher.gd")
const References := preload("res://src/content_references.gd")
const Schema := preload("res://src/content_schema.gd")
## A card's art choice that deletes its art on Save.
const REMOVE_ART := "<remove>"
## How far art can be zoomed in, from filling its window at 1.
const MAX_ART_ZOOM := 5.0
## How much one scroll-wheel step zooms art.
const ART_ZOOM_STEP := 1.1
## Each list of definitions an expansion holds, with the schema definition of
## one entry and the tab that edits it.
const KINDS := {
	"cards": {"definition": "card", "title": "Cards"},
	"packs": {"definition": "pack", "title": "Packs"},
	"starterDecks": {"definition": "starterDeck", "title": "Starter decks"},
	"scenarios": {"definition": "scenario", "title": "Scenarios"},
}
signal published(version: String)
var _publishing_accounts: AccountClient
var _publisher: Control

func setup_publishing(accounts: AccountClient) -> void:
	_publishing_accounts = accounts
	if _publisher != null:
		_publisher.setup(accounts, func() -> Dictionary: return draft.duplicate(true))

var content_root := ""
var draft: Dictionary = {}
var dirty := false
var source_path := ""
var source_stamp := ""
var _entries: Array = []
var _entry_index := -1
## The selected entry of each kind, -1 for none.
var _selection := {"cards": -1, "packs": -1, "starterDecks": -1, "scenarios": -1}
var _card_index: int:
	get: return _selection["cards"]
	set(value): _selection["cards"] = value
var _current_expansion_id := ""
var _root_input: LineEdit
var _folder_input: LineEdit
var _expansions: ItemList
var _cards: ItemList
var _packs: ItemList
var _tabs: TabContainer
var _metadata: VBoxContainer
var _card_form: VBoxContainer
var _pack_form: VBoxContainer
## Each kind's entry list and the form beside it.
var _lists: Dictionary = {}
var _bodies: Dictionary = {}
var _renames_dialog: ConfirmationDialog
var _renames_action: Callable
var _preview: VBoxContainer
var _preview_library = Library.new()
var _preview_timer: Timer
var _issues: ItemList
var _status: Label
var _location: Label
var _file_dialog: FileDialog
var _file_action := ""
var _discard: ConfirmationDialog
var _discard_action: Callable
var _overwrite: ConfirmationDialog
var _overwrite_action: Callable
var _art_dialog: FileDialog
## One entry per draft card: the ID its art is saved under ("from", empty for a
## new card) and the art chosen since ("pick": an image path, REMOVE_ART, or
## empty to keep it), with the framing set since, if any ("crop": the part of
## the image shown). Art files are written only on Save.
var _card_art: Array = []
var _zoom_slider: HSlider

func _ready() -> void:
	name = "Expansions"
	add_theme_constant_override("separation", 8)
	var root_row := HBoxContainer.new()
	add_child(root_row)
	_root_input = LineEdit.new()
	_root_input.placeholder_text = "Choose packages/card-definitions/content"
	_root_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root_row.add_child(_root_input)
	_button(root_row, "Open content folder…", func() -> void: _choose_directory("root"))
	_button(root_row, "Load path", func() -> void:
		confirm_discard(func() -> void: open_root(_root_input.text.strip_edges())))
	var actions := HBoxContainer.new()
	add_child(actions)
	_button(actions, "New expansion", func() -> void: confirm_discard(new_expansion))
	_button(actions, "Import expansion…", func() -> void: _choose_directory("import"))
	_button(actions, "Save", save_draft)
	_button(actions, "Export expansion…", func() -> void: _choose_directory("export"))
	_button(actions, "Validate", validate_draft)
	_location = Label.new()
	_location.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_location.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	actions.add_child(_location)
	_publisher = Publisher.new()
	if _publishing_accounts != null:
		_publisher.setup(_publishing_accounts, func() -> Dictionary: return draft.duplicate(true))
	_publisher.published.connect(func(version: String) -> void: published.emit(version))
	_publisher.issues.connect(_show_errors)
	_publisher.server_draft_received.connect(func(document: Dictionary) -> void:
		confirm_discard(func() -> void:
			_set_draft(document, "", "", true)
			_folder_input.text = Files.suggested_folder(str(document["expansion"]["id"]))
			_folder_input.editable = true
			_entry_index = -1
			_refresh_expansions()
			_say("Opened server version as a local draft.")))
	add_child(_publisher)

	var workspace := HSplitContainer.new()
	workspace.size_flags_vertical = Control.SIZE_EXPAND_FILL
	workspace.split_offset = 0
	add_child(workspace)
	_expansions = ItemList.new()
	_expansions.custom_minimum_size.x = 185
	_expansions.size_flags_horizontal = Control.SIZE_FILL
	workspace.add_child(_expansions)
	_expansions.item_selected.connect(func(index: int) -> void:
		if index != _entry_index or source_path == "":
			confirm_discard(func() -> void: _load_entry(index)))
	var editor := VBoxContainer.new()
	editor.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	workspace.add_child(editor)
	var folder_row := HBoxContainer.new()
	editor.add_child(folder_row)
	var folder_label := Label.new()
	folder_label.text = "Expansion folder"
	folder_row.add_child(folder_label)
	_folder_input = LineEdit.new()
	_folder_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_folder_input.placeholder_text = "e.g. frozen-frontier"
	_folder_input.tooltip_text = "An immediate folder inside the selected content root. Existing folders keep their name."
	folder_row.add_child(_folder_input)
	_folder_input.text_changed.connect(func(_text: String) -> void: _mark_dirty())
	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	editor.add_child(_tabs)
	_metadata = _scroll_tab("Expansion")
	for kind: String in KINDS:
		_build_entity_tab(KINDS[kind]["title"], kind)
	_issues = ItemList.new()
	_issues.custom_minimum_size.y = 85
	_issues.visible = false
	_issues.tooltip_text = "Select a validation issue to open its card or pack."
	_issues.item_selected.connect(_open_issue)
	editor.add_child(_issues)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.text = "Open a content folder or create an expansion."
	add_child(_status)
	var note := Label.new()
	note.text = "Save edits local JSON. Preview publish applies a reviewed server version for new matches. Database policy overrides still apply."
	note.add_theme_font_size_override("font_size", 12)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(note)

	_preview_timer = Timer.new()
	_preview_timer.one_shot = true
	_preview_timer.wait_time = 0.12
	_preview_timer.timeout.connect(_render_preview)
	add_child(_preview_timer)
	_file_dialog = FileDialog.new()
	_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	_file_dialog.dir_selected.connect(_directory_selected)
	add_child(_file_dialog)
	_art_dialog = FileDialog.new()
	_art_dialog.title = "Choose card art"
	_art_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_art_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_art_dialog.filters = PackedStringArray(["*.png, *.webp, *.jpg, *.jpeg, *.svg ; Images"])
	_art_dialog.file_selected.connect(func(path: String) -> void: choose_art(path))
	add_child(_art_dialog)
	_discard = ConfirmationDialog.new()
	_discard.title = "Unsaved expansion"
	_discard.dialog_text = "Discard this expansion's unsaved changes?"
	_discard.ok_button_text = "Discard changes"
	_discard.confirmed.connect(func() -> void:
		var action := _discard_action
		_discard_action = Callable()
		_discard_changes()
		if action.is_valid():
			action.call())
	_discard.canceled.connect(func() -> void:
		_discard_action = Callable()
		_refresh_expansions())
	add_child(_discard)
	_overwrite = ConfirmationDialog.new()
	_overwrite.title = "Replace expansion files?"
	_overwrite.ok_button_text = "Replace JSON files"
	_overwrite.confirmed.connect(func() -> void:
		if _overwrite_action.is_valid():
			_overwrite_action.call()
		_overwrite_action = Callable())
	_overwrite.canceled.connect(func() -> void: _overwrite_action = Callable())
	add_child(_overwrite)
	_renames_dialog = ConfirmationDialog.new()
	_renames_dialog.title = "Rename card IDs?"
	_renames_dialog.ok_button_text = "Rename and save"
	_renames_dialog.confirmed.connect(func() -> void:
		if _renames_action.is_valid():
			_renames_action.call()
		_renames_action = Callable())
	_renames_dialog.canceled.connect(func() -> void:
		_renames_action = Callable()
		_say("Not saved. The renamed card IDs are still unsaved."))
	add_child(_renames_dialog)

func opened() -> void:
	_publisher.opened()
	if not draft.is_empty():
		return
	if content_root != "":
		open_root(content_root)
		return
	var settings := ConfigFile.new()
	settings.load(SETTINGS)
	var path := str(settings.get_value("creator", "content_root", Files.default_root()))
	_root_input.text = path
	if DirAccess.dir_exists_absolute(path):
		open_root(path)

func confirm_discard(action: Callable) -> void:
	if not dirty:
		action.call()
		return
	_discard_action = action
	_discard.popup_centered()

func _discard_changes() -> void:
	if source_path != "":
		var result := Files.load_folder(source_path)
		if result["ok"]:
			_set_draft(result["data"], source_path, result["stamp"], false)
			return
	if not _entries.is_empty():
		_load_entry(0)
		return
	draft = {}
	source_path = ""
	source_stamp = ""
	dirty = false
	_clear(_metadata)
	for kind: String in KINDS:
		_refresh_entities(kind)
	_folder_input.text = ""
	_update_location()

func open_root(path: String) -> bool:
	var result := Files.catalog(path)
	if not DirAccess.dir_exists_absolute(path):
		_show_errors(result["errors"])
		return false
	content_root = ProjectSettings.globalize_path(path).simplify_path().trim_suffix("/")
	_root_input.text = content_root
	_entries = result["entries"]
	_entry_index = -1
	if not _entries.is_empty():
		_load_entry(0)
	else:
		new_expansion()
	_refresh_expansions()
	if not result["errors"].is_empty():
		_show_errors(result["errors"])
	var settings := ConfigFile.new()
	settings.set_value("creator", "content_root", content_root)
	settings.save(SETTINGS)
	return true

func _load_entry(index: int) -> void:
	if index < 0 or index >= _entries.size():
		return
	var entry: Dictionary = _entries[index]
	# Re-read here, so reopening picks up hand edits made since folder discovery.
	var result := Files.load_folder(entry["path"])
	if not result["ok"]:
		_show_errors(result["errors"])
		return
	_entry_index = index
	_set_draft(result["data"], entry["path"], result["stamp"], false)
	_folder_input.text = entry["folder"]
	_folder_input.editable = false
	_refresh_expansions()
	_say("Opened " + str(entry["path"]))

func new_expansion() -> void:
	var expansion: Dictionary = Form.default_value(Validator.definition("expansion"))
	expansion["id"] = "NEW_EXPANSION"
	expansion["name"] = "New expansion"
	expansion["policy"]["standard"] = true
	_set_draft({"expansion": expansion, "cards": [], "packs": [], "starterDecks": [], "scenarios": []}, "", "", true)
	_folder_input.text = "new-expansion"
	_folder_input.editable = true
	_entry_index = -1
	_refresh_expansions()
	_tabs.current_tab = 0
	_say("New draft. Set its name and stable ID, then add cards and packs.")

func import_folder(path: String) -> bool:
	var result := Files.load_folder(path)
	if not result["ok"]:
		_show_errors(result["errors"])
		return false
	_set_draft(result["data"], "", "", true)
	_folder_input.text = Files.suggested_folder(str(draft["expansion"]["id"]))
	_folder_input.editable = true
	_entry_index = -1
	_refresh_expansions()
	_say("Imported as an unsaved draft from " + path)
	return true

func _set_draft(data: Dictionary, path: String, stamp: String, unsaved: bool) -> void:
	draft = data.duplicate(true)
	source_path = path
	source_stamp = stamp
	_current_expansion_id = str(draft["expansion"]["id"])
	for kind: String in KINDS:
		# A document from before a kind existed simply has none of it.
		if not draft.has(kind):
			draft[kind] = []
		_selection[kind] = 0 if not draft[kind].is_empty() else -1
	_card_art = draft["cards"].map(func(card: Dictionary) -> Dictionary: return {"from": str(card["id"]), "pick": ""})
	_clear(_metadata)
	var form = Form.new()
	form.setup(Validator.definition("expansion"), draft["expansion"])
	form.changed.connect(func(updated: Variant) -> void:
		var next_id: String = updated["id"]
		if next_id != _current_expansion_id:
			for kind: String in KINDS:
				for item: Dictionary in draft[kind]:
					item["expansionId"] = next_id
			if source_path == "" and _folder_input.text == Files.suggested_folder(_current_expansion_id):
				_folder_input.text = Files.suggested_folder(next_id)
			_current_expansion_id = next_id
			for kind: String in KINDS:
				_render_entity(kind)
		draft["expansion"] = updated
		_mark_dirty())
	_metadata.add_child(form)
	for kind: String in KINDS:
		_refresh_entities(kind)
	dirty = unsaved
	_issues.visible = false
	_update_location()

func _build_entity_tab(title: String, kind: String) -> void:
	var tab := HBoxContainer.new()
	tab.name = title
	_tabs.add_child(tab)
	var left := VBoxContainer.new()
	left.custom_minimum_size.x = 175
	tab.add_child(left)
	var actions := HBoxContainer.new()
	left.add_child(actions)
	_button(actions, "Add", func() -> void: add_entity(kind))
	_button(actions, "Duplicate", func() -> void: duplicate_entity(kind))
	_button(left, "Remove selected", func() -> void: _confirm_remove(kind))
	var list := ItemList.new()
	list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_child(list)
	list.item_selected.connect(func(index: int) -> void:
		_set_selected(kind, index)
		_render_entity(kind))
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	tab.add_child(scroll)
	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(body)
	_lists[kind] = list
	_bodies[kind] = body
	if kind == "cards":
		_cards = list
		_card_form = body
		_preview = VBoxContainer.new()
		_preview.custom_minimum_size.x = 235
		tab.add_child(_preview)
	elif kind == "packs":
		_packs = list
		_pack_form = body

func _scroll_tab(title: String) -> VBoxContainer:
	var scroll := ScrollContainer.new()
	scroll.name = title
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_tabs.add_child(scroll)
	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(body)
	return body

func add_entity(kind: String) -> void:
	if draft.is_empty():
		new_expansion()
	var item: Dictionary = Form.default_value(Validator.definition(KINDS[kind]["definition"]))
	var expansion_id := str(draft["expansion"]["id"])
	item["id"] = _unique_id(kind, {
		"cards": "new_card",
		"packs": expansion_id + "_PACK",
		"starterDecks": "NEW_STARTER",
		"scenarios": "NEW_SCENARIO",
	}[kind])
	item["name"] = {"cards": "New card", "packs": "New pack", "starterDecks": "New starter deck", "scenarios": "New scenario"}[kind]
	item["expansionId"] = expansion_id
	if kind == "cards":
		item["collectible"] = true
		item["rarity"] = "COMMON"
		item["description"] = "No special abilities."
		item["cost"] = 1
		item["attack"] = 1
	elif kind == "packs":
		item["cardCount"] = 5
		item["rarityRules"] = {"slots": [
			{"count": 4, "weights": {"COMMON": 70, "RARE": 23, "EPIC": 6, "LEGENDARY": 1}},
			{"count": 1, "weights": {"RARE": 80, "EPIC": 17, "LEGENDARY": 3}},
		]}
	elif kind == "starterDecks":
		item["classId"] = Schema.CLASSES[0]
	elif kind == "scenarios":
		# The sides a Standard Duel is played with, which most scenarios start from.
		item["battlefield"] = {"width": 3}
		for side in ["sideA", "sideB"]:
			item[side] = {"heroDefinitionId": Schema.HEROES[0], "heroHealth": 30, "startingTaika": 1, "maxTaika": 10, "controller": "HUMAN"}
		item["victoryConditions"] = [{"type": "ENEMY_HERO_DEFEATED"}]
	draft[kind].append(item)
	if kind == "cards":
		_art_entry(draft[kind].size() - 1)
	_set_selected(kind, draft[kind].size() - 1)
	_refresh_entities(kind)
	_mark_dirty()

func duplicate_entity(kind: String) -> void:
	var index := _selected(kind)
	if draft.is_empty() or index < 0:
		return
	var item: Dictionary = draft[kind][index].duplicate(true)
	item["id"] = _unique_id(kind, str(item["id"]) + "_copy")
	item["name"] = str(item["name"]) + " (copy)"
	draft[kind].append(item)
	if kind == "cards":
		# The copy starts with the same picture, saved under its own ID.
		_art_entry(draft[kind].size() - 1).merge({"pick": _art_source(index), "texture": _art_texture(index), "crop": _art_crop(index)}, true)
	_set_selected(kind, draft[kind].size() - 1)
	_refresh_entities(kind)
	_mark_dirty()

func _confirm_remove(kind: String) -> void:
	var index := _selected(kind)
	if draft.is_empty() or index < 0:
		return
	var dialog := ConfirmationDialog.new()
	dialog.title = "Remove %s?" % draft[kind][index]["name"]
	dialog.dialog_text = "This removes the definition when you save. Existing decks and collections may still reference its ID."
	add_child(dialog)
	dialog.confirmed.connect(func() -> void:
		draft[kind].remove_at(index)
		if kind == "cards" and index < _card_art.size():
			_card_art.remove_at(index)
		_set_selected(kind, mini(index, draft[kind].size() - 1))
		_refresh_entities(kind)
		_mark_dirty()
		dialog.queue_free())
	dialog.canceled.connect(dialog.queue_free)
	dialog.popup_centered()

func _unique_id(kind: String, base: String) -> String:
	var ids: Array = []
	for entry: Dictionary in _entries:
		for item: Dictionary in entry["data"].get(kind, []):
			ids.append(item["id"])
	for item: Dictionary in draft[kind]:
		ids.append(item["id"])
	var candidate := base
	var number := 2
	while ids.has(candidate):
		candidate = "%s_%d" % [base, number]
		number += 1
	return candidate

func _selected(kind: String) -> int:
	return _selection[kind]

func _set_selected(kind: String, index: int) -> void:
	_selection[kind] = index

func _refresh_expansions() -> void:
	_expansions.clear()
	for index in _entries.size():
		var entry: Dictionary = _entries[index]
		_expansions.add_item(str(entry["data"]["expansion"]["name"]))
		_expansions.set_item_tooltip(index, entry["path"])
		if Files.same_path(source_path, entry["path"]):
			_expansions.select(index)

func _refresh_entities(kind: String) -> void:
	var list: ItemList = _lists[kind]
	list.clear()
	if not draft.is_empty():
		for item: Dictionary in draft[kind]:
			list.add_item(str(item["name"]))
		if _selected(kind) >= 0:
			list.select(_selected(kind))
	_render_entity(kind)

func _render_entity(kind: String) -> void:
	var body: VBoxContainer = _bodies[kind]
	_clear(body)
	var index := _selected(kind)
	if draft.is_empty() or index < 0:
		var empty := Label.new()
		empty.text = {
			"cards": "Add a card to begin.",
			"packs": "Add a pack, or leave this set without packs.",
			"starterDecks": "Each class needs one starter deck, in any expansion. Most expansions leave this empty.",
			"scenarios": "Add a scenario, or leave this set without any.",
		}[kind]
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		body.add_child(empty)
		if kind == "cards":
			_clear(_preview)
		return
	var form = Form.new()
	form.setup(Validator.definition(KINDS[kind]["definition"]), draft[kind][index])
	form.changed.connect(func(updated: Variant) -> void:
		draft[kind][index] = updated
		var list: ItemList = _lists[kind]
		list.set_item_text(index, str(updated.get("name", updated.get("id", "Untitled"))))
		_mark_dirty())
	body.add_child(form)
	if kind == "cards":
		_render_preview()

func _render_preview() -> void:
	_clear(_preview)
	if draft.is_empty() or _card_index < 0:
		return
	var card: Dictionary = draft["cards"][_card_index]
	_preview_library.ingest([card])
	var heading := Label.new()
	heading.text = "Card preview"
	_preview.add_child(heading)
	var frame = Frame.make(_preview_library, {"definition_id": str(card.get("id", ""))}, 230, true)
	_preview.add_child(frame)
	# The art controls sit right under the card: the column's foot is behind
	# the window's corner Admin UI switch.
	var texture := _art_texture(_card_index)
	frame.show_art(texture, _art_crop(_card_index))
	if texture != null:
		frame.mouse_filter = Control.MOUSE_FILTER_STOP
		frame.mouse_default_cursor_shape = Control.CURSOR_MOVE
		frame.tooltip_text = "Drag to move the art; scroll to zoom."
		frame.gui_input.connect(func(event: InputEvent) -> void: _frame_input(frame, event))
	var art_row := HBoxContainer.new()
	_preview.add_child(art_row)
	_button(art_row, "Choose art…", _choose_art)
	var remove := _button(art_row, "Remove art", clear_art)
	remove.disabled = texture == null
	var zoom_row := HBoxContainer.new()
	_preview.add_child(zoom_row)
	var zoom_label := Label.new()
	zoom_label.text = "Zoom"
	zoom_row.add_child(zoom_label)
	_zoom_slider = HSlider.new()
	_zoom_slider.min_value = 1.0
	_zoom_slider.max_value = MAX_ART_ZOOM
	_zoom_slider.step = 0.01
	_zoom_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_zoom_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_zoom_slider.editable = texture != null
	_zoom_slider.set_value_no_signal(art_zoom(frame))
	_zoom_slider.value_changed.connect(func(value: float) -> void: frame_art(frame, Vector2.ZERO, value))
	zoom_row.add_child(_zoom_slider)
	var reset := _button(zoom_row, "Reset", reset_framing)
	reset.tooltip_text = "Show the art centred and fitted to its window again."
	reset.disabled = texture == null or _art_crop(_card_index).is_equal_approx(CardArt.FULL)
	var art_note := Label.new()
	art_note.text = _art_status(_card_index)
	art_note.add_theme_font_size_override("font_size", 12)
	art_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	art_note.custom_minimum_size.x = 225
	_preview.add_child(art_note)
	var flavour := RichTextLabel.new()
	flavour.bbcode_enabled = true
	flavour.fit_content = true
	flavour.scroll_active = false
	flavour.custom_minimum_size.x = 225
	flavour.text = _preview_library.flavour_bbcode(str(card.get("id", "")))
	_preview.add_child(flavour)
	var credit := _preview_library.artist_credit(str(card.get("id", "")))
	if credit != "":
		var artist := Label.new()
		artist.text = credit
		artist.add_theme_font_size_override("font_size", 11)
		artist.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		artist.custom_minimum_size.x = 225
		_preview.add_child(artist)
	var details := Label.new()
	details.text = "%s · %s\n%s" % [card.get("rarity", ""), card.get("classId", "Neutral"), card.get("id", "")]
	details.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_preview.add_child(details)

## Stages `path` as the selected card's art; it is copied into place on Save.
func choose_art(path: String) -> bool:
	if draft.is_empty() or _card_index < 0:
		return false
	var texture := CardArt.load_image(path)
	if texture == null:
		_say("%s is not a PNG, WebP, JPEG or SVG image." % path.get_file(), true)
		return false
	_art_entry(_card_index).merge({"pick": path, "texture": texture, "crop": CardArt.FULL}, true)
	_mark_dirty()
	_render_preview()
	return true

## Stages removing the selected card's art; the file is deleted on Save.
func clear_art() -> void:
	if draft.is_empty() or _card_index < 0:
		return
	_art_entry(_card_index).merge({"pick": REMOVE_ART, "texture": null, "crop": CardArt.FULL}, true)
	_mark_dirty()
	_render_preview()

## Moves the selected card's art `drag` pixels across `frame`'s art window and
## zooms it to `zoom` (1 fills the window; 0 keeps the zoom), staging the
## framing for Save. The preview is redrawn in place, so a drag carries on.
func frame_art(frame: CardFrame, drag: Vector2, zoom := 0.0) -> void:
	var texture := _art_texture(_card_index)
	var window := frame.art_rect().size
	if texture == null or window.x <= 0.0 or window.y <= 0.0:
		return
	var shown := _shown_crop(texture, window)
	if zoom <= 0.0:
		zoom = art_zoom(frame)
	var size := CardArt.cover(texture.get_size(), window.x / window.y).size / clampf(zoom, 1.0, MAX_ART_ZOOM)
	# Dragging the picture right shows more of its left.
	var centre := shown.get_center() - drag / window * shown.size
	var crop := Rect2((centre - size * 0.5).clamp(Vector2.ZERO, Vector2.ONE - size), size)
	_art_entry(_card_index)["crop"] = crop
	frame.show_art(texture, crop)
	if _zoom_slider != null:
		_zoom_slider.set_value_no_signal(zoom)
	_mark_dirty(false)

## How far the selected card's art is zoomed in `frame`, 1 when it just fills
## the art window.
func art_zoom(frame: CardFrame) -> float:
	var texture := _art_texture(_card_index)
	var window := frame.art_rect().size
	if texture == null or window.x <= 0.0 or window.y <= 0.0:
		return 1.0
	var full := CardArt.cover(texture.get_size(), window.x / window.y).size
	return clampf(full.x / _shown_crop(texture, window).size.x, 1.0, MAX_ART_ZOOM)

## Stages showing the selected card's art centred and filling its window.
func reset_framing() -> void:
	if draft.is_empty() or _card_index < 0:
		return
	_art_entry(_card_index)["crop"] = CardArt.FULL
	_mark_dirty()
	_render_preview()

func _frame_input(frame: CardFrame, event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		if motion.button_mask & MOUSE_BUTTON_MASK_LEFT:
			frame_art(frame, motion.relative)
			frame.accept_event()
	elif event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.pressed and button.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			var step := ART_ZOOM_STEP if button.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / ART_ZOOM_STEP
			frame_art(frame, Vector2.ZERO, clampf(art_zoom(frame) * step, 1.0, MAX_ART_ZOOM))
			frame.accept_event()

## The part of `texture` an art window `window` big shows of the selected
## card's crop, as fractions of the image.
func _shown_crop(texture: Texture2D, window: Vector2) -> Rect2:
	var crop := _art_crop(_card_index)
	var shown := CardArt.cover(texture.get_size() * crop.size, window.x / window.y)
	return Rect2(crop.position + shown.position * crop.size, shown.size * crop.size)

func _choose_art() -> void:
	var source := _art_source(_card_index)
	_art_dialog.current_dir = ProjectSettings.globalize_path(source.get_base_dir() if source != "" else CardArt.art_dir)
	_art_dialog.popup_centered(Vector2i(850, 550))

## The art state of a draft card, made on first use for cards added directly.
func _art_entry(index: int) -> Dictionary:
	while _card_art.size() <= index:
		_card_art.append({"from": "", "pick": ""})
	return _card_art[index]

## The image file the card will show once saved, or "" for none.
func _art_source(index: int) -> String:
	var entry := _art_entry(index)
	if entry["pick"] == REMOVE_ART:
		return ""
	if entry["pick"] != "":
		return entry["pick"]
	var path := CardArt.path_for(str(draft["cards"][index].get("id", "")))
	return path if path != "" else CardArt.path_for(entry["from"])

## The whole image the card will show part of once saved, or null for none.
func _art_texture(index: int) -> Texture2D:
	var entry := _art_entry(index)
	if entry["pick"] == REMOVE_ART:
		return null
	if entry["pick"] != "":
		return entry.get("texture")
	var texture := CardArt.source_texture_for(str(draft["cards"][index].get("id", "")))
	return texture if texture != null else CardArt.source_texture_for(entry["from"])

## The part of its image the card will show once saved, as fractions of it.
func _art_crop(index: int) -> Rect2:
	var entry := _art_entry(index)
	if entry.has("crop"):
		return entry["crop"]
	var id := str(draft["cards"][index].get("id", ""))
	return CardArt.crop_for(id if CardArt.path_for(id) != "" else entry["from"])

func _art_status(index: int) -> String:
	var entry := _art_entry(index)
	var id := str(draft["cards"][index].get("id", ""))
	if entry["pick"] == REMOVE_ART:
		return "Art is deleted when you save."
	if entry["pick"] != "":
		return "%s is copied to art/cards/%s/%s.%s when you save." % [entry["pick"].get_file(), _art_folder(), id, entry["pick"].get_extension().to_lower()]
	var path := CardArt.path_for(id)
	if path != "":
		return "Art: art/cards/" + CardArt.relative(path)
	path = CardArt.path_for(entry["from"])
	if path != "":
		return "Art: art/cards/%s, moved to %s/%s.%s when you save." % [CardArt.relative(path), _art_folder(), id, path.get_extension()]
	return "No art. Choose an image to use as this card's art."

## Art is kept in a folder named after the expansion's content folder, as
## art/cards/<folder>/<card_id>.png.
func _art_folder() -> String:
	return _folder_input.text.strip_edges()

## Writes the staged art changes under each card's current ID. Returns
## validation-style issues, so selecting one opens its card.
func _apply_art() -> Array[String]:
	var errors: Array[String] = []
	var ids: Array = draft["cards"].map(func(card: Dictionary) -> String: return str(card["id"]))
	for index in draft["cards"].size():
		var entry := _art_entry(index)
		var id: String = ids[index]
		var from: String = entry["from"]
		# Art under an ID this card has left is moved or dropped, unless
		# another card has since taken that ID.
		var moved := from != "" and from != id and not ids.has(from)
		var error := ""
		if entry["pick"] == REMOVE_ART:
			CardArt.unlink(id)
			if moved:
				CardArt.unlink(from)
		elif entry["pick"] != "":
			error = CardArt.link(id, entry["pick"], _art_folder(), entry.get("crop", CardArt.FULL))
			if error == "" and moved:
				CardArt.unlink(from)
		elif moved and CardArt.path_for(id) == "":
			error = CardArt.rename(from, id, _art_folder())
		if error == "" and entry["pick"] == "" and entry.has("crop"):
			CardArt.set_crop(id, entry["crop"])
		if error != "":
			errors.append("cards.json[%d] art: %s" % [index, error])
		else:
			_card_art[index] = {"from": id, "pick": ""}
	return errors

## `rerender` false leaves the preview as it is, for a change already drawn.
func _mark_dirty(rerender := true) -> void:
	dirty = true
	_issues.visible = false
	_update_location()
	if rerender:
		_preview_timer.start()
	_say("Unsaved changes.")

func _update_location() -> void:
	_location.text = ("Unsaved draft" if source_path == "" else source_path) + (" *" if dirty else "")
	_location.tooltip_text = _location.text

func _destination() -> String:
	return content_root.path_join(_folder_input.text.strip_edges()).simplify_path() if content_root != "" else ""

func validate_draft() -> bool:
	if draft.is_empty():
		_say("Create or open an expansion first.", true)
		return false
	var errors := Files.validate(draft, content_root, _destination())
	if not errors.is_empty():
		_show_errors(errors)
		return false
	_issues.visible = false
	var counts: Array[String] = []
	for kind: String in KINDS:
		if kind in ["cards", "packs"] or not draft[kind].is_empty():
			counts.append("%d %s" % [draft[kind].size(), KINDS[kind]["title"].to_lower()])
	_say("Valid: %s." % ", ".join(counts))
	return true

func save_draft() -> void:
	if content_root == "":
		_say("Open a content folder before saving, or export the draft.", true)
		return
	var renames := _renames()
	if not renames.is_empty():
		var plan := _rename_plan(renames)
		if not plan["lines"].is_empty():
			_confirm_renames(renames, plan)
			return
	_save(draft)

## Card IDs changed since the draft was last saved, old → new. An old ID that
## some card still has — another took it over — was not renamed away.
func _renames() -> Dictionary:
	var ids: Dictionary = {}
	for card: Dictionary in draft["cards"]:
		ids[str(card["id"])] = true
	for entry: Dictionary in Files.catalog(content_root, _destination())["entries"]:
		for card: Dictionary in entry["data"]["cards"]:
			ids[str(card["id"])] = true
	var renames: Dictionary = {}
	for index in draft["cards"].size():
		var from: String = _art_entry(index)["from"]
		var to := str(draft["cards"][index]["id"])
		if from != "" and from != to and not ids.has(from):
			renames[from] = to
	return renames

## What renaming would change: the draft and the other expansions with every
## reference to a renamed card rewritten, the folders that changed, and a line
## per definition that changed, for the person saving to review.
func _rename_plan(renames: Dictionary) -> Dictionary:
	var lines: Array[String] = []
	var rewritten := draft.duplicate(true)
	lines.append_array(_rewrite_document(rewritten, renames, ""))
	var context: Array = []
	var changed: Array = []
	for entry: Dictionary in Files.catalog(content_root, _destination())["entries"]:
		var copy := entry.duplicate(true)
		var found := _rewrite_document(copy["data"], renames, str(entry["folder"]) + "/")
		if not found.is_empty():
			lines.append_array(found)
			changed.append(copy)
		context.append(copy)
	return {"draft": rewritten, "context": context, "changed": changed, "lines": lines}

func _rewrite_document(data: Dictionary, renames: Dictionary, prefix: String) -> Array[String]:
	var lines: Array[String] = []
	for kind: String in KINDS:
		for item: Dictionary in data.get(kind, []):
			if References.rewrite(item, renames) > 0:
				lines.append("%s%s.json · %s" % [prefix, kind, item.get("name", item.get("id", ""))])
	return lines

func _confirm_renames(renames: Dictionary, plan: Dictionary) -> void:
	var names: Array[String] = []
	for from: String in renames:
		names.append("%s → %s" % [from, renames[from]])
	_renames_dialog.dialog_text = "Renaming %s also updates what refers to it:\n\n%s\n\nDecks and collections already on a server keep the old ID." % [
		", ".join(names), "\n".join(plan["lines"]),
	]
	_renames_action = func() -> void:
		draft = plan["draft"]
		for kind: String in KINDS:
			_refresh_entities(kind)
		_save(draft, plan)
	_renames_dialog.popup_centered(Vector2i(560, 320))

## Saves `data` as this expansion and, for a rename, the other expansions it
## rewrote. Everything is validated before anything is written.
func _save(data: Dictionary, plan: Dictionary = {}) -> void:
	var folder := _folder_input.text.strip_edges()
	var context: Variant = plan.get("context", null)
	var changed: Array = plan.get("changed", [])
	var result := Files.save(content_root, folder, data, source_stamp if Files.same_path(_destination(), source_path) else "", false, context)
	if result.get("needs_overwrite", false):
		var snapshot := data.duplicate(true)
		var stamp: String = result["stamp"]
		var root := content_root
		_confirm_overwrite(result["path"], func() -> void:
			_finish_save(Files.save(root, folder, snapshot, stamp, true, context), changed))
	else:
		_finish_save(result, changed)

func _finish_save(result: Dictionary, changed: Array = []) -> void:
	if not result["ok"]:
		_show_errors(result["errors"])
		return
	source_path = result["path"]
	source_stamp = result["stamp"]
	# This expansion is saved; the others a rename reached follow, each refused
	# if it changed on disk since it was read.
	var errors: Array[String] = []
	for entry: Dictionary in changed:
		var written := Files.write_folder(entry["path"], entry["data"], entry["stamp"])
		if not written["ok"]:
			errors.append_array(written["errors"])
	var art_errors := _apply_art()
	art_errors.append_array(errors)
	# A failed art copy leaves the draft unsaved, so Save can be retried.
	dirty = not art_errors.is_empty()
	_folder_input.editable = false
	_entries = Files.catalog(content_root)["entries"]
	for index in _entries.size():
		if Files.same_path(_entries[index]["path"], source_path):
			_entry_index = index
	_refresh_expansions()
	_update_location()
	_say("Saved " + source_path + ". Use Preview publish to apply it to the running server.")
	if not art_errors.is_empty():
		_show_errors(art_errors)
	_render_preview()

func export_folder(path: String) -> void:
	if not validate_draft():
		return
	# Export destinations must be expansion folders, never the content root itself.
	if Files.same_path(path, content_root):
		_say("Choose an expansion subfolder as the export destination, not the content root.", true)
		return
	var snapshot := draft.duplicate(true)
	var local_target := Files.same_path(path.get_base_dir(), content_root)
	var stamp := source_stamp if Files.same_path(path, source_path) else ""
	var result := Files.save(content_root, path.get_file(), snapshot, stamp) if local_target else Files.write_folder(path, snapshot, stamp)
	if result.get("needs_overwrite", false):
		var overwrite_stamp: String = result["stamp"]
		var root := content_root
		_confirm_overwrite(path, func() -> void:
			var saved := Files.save(root, path.get_file(), snapshot, overwrite_stamp, true) if local_target else Files.write_folder(path, snapshot, overwrite_stamp, true)
			_finish_export(saved))
	else:
		_finish_export(result)

func _finish_export(result: Dictionary) -> void:
	if not result["ok"]:
		_show_errors(result["errors"])
		return
	if Files.same_path(str(result["path"]).get_base_dir(), content_root):
		_entries = Files.catalog(content_root)["entries"]
		_refresh_expansions()
	# Exporting elsewhere leaves an edited source draft unsaved.
	if Files.same_path(result["path"], source_path):
		source_stamp = result["stamp"]
		dirty = false
		_update_location()
	_say("Exported expansion.json, cards.json and packs.json to " + str(result["path"]))

func _confirm_overwrite(path: String, action: Callable) -> void:
	_overwrite_action = action
	_overwrite.dialog_text = "Replace expansion.json, cards.json and packs.json in:\n%s\n\nThis writes local files." % path
	_overwrite.popup_centered(Vector2i(560, 180))

func _choose_directory(action: String) -> void:
	_file_action = action
	_file_dialog.title = {"root": "Open content root", "import": "Import expansion folder", "export": "Export to expansion folder"}[action]
	if content_root != "":
		_file_dialog.current_dir = content_root
	_file_dialog.popup_centered(Vector2i(850, 550))

func _directory_selected(path: String) -> void:
	match _file_action:
		"root": confirm_discard(func() -> void: open_root(path))
		"import": confirm_discard(func() -> void: import_folder(path))
		"export": export_folder(path)

func _show_errors(errors: Array) -> void:
	_issues.clear()
	for error in errors:
		_issues.add_item(str(error))
	_issues.visible = not errors.is_empty()
	_say("%d validation or file issue(s). Select an issue to open its entry." % errors.size(), true)

func _open_issue(index: int) -> void:
	var text := _issues.get_item_text(index)
	var tab := 1
	for kind: String in KINDS:
		if text.begins_with(kind + ".json["):
			var entry := int(text.get_slice("[", 1).get_slice("]", 0))
			_set_selected(kind, entry)
			_refresh_entities(kind)
			_tabs.current_tab = tab
			return
		tab += 1
	if text.begins_with("expansion.json"):
		_tabs.current_tab = 0

func _say(message: String, error: bool = false) -> void:
	_status.text = message
	_status.add_theme_color_override("font_color", Color("ef9999") if error else Color("a8d9b4"))

func _button(parent: Node, text: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.pressed.connect(action)
	parent.add_child(button)
	return button

func _clear(node: Node) -> void:
	for child in node.get_children():
		node.remove_child(child)
		child.queue_free()
