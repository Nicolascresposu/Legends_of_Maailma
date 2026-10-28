extends SceneTree

## No server required. All writes stay in a fresh temporary user-data folder.
const Files := preload("res://src/expansion_files.gd")
const Validator := preload("res://src/content_validator.gd")
const Creator := preload("res://src/expansion_creator.gd")
const Form := preload("res://src/content_form.gd")
const Admin := preload("res://src/admin_screen.gd")
const Schema := preload("res://src/content_schema.gd")
var failures: Array[String] = []
var test_root := ""
var creator: Control
var checks := 0
var _settings_existed := false
var _settings := PackedByteArray()

func _init() -> void:
	await process_frame
	_settings_existed = FileAccess.file_exists(Creator.SETTINGS)
	if _settings_existed:
		_settings = FileAccess.get_file_as_bytes(Creator.SETTINGS)
	test_root = ProjectSettings.globalize_path("user://").path_join("creator-tests-%s" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(test_root)
	print("== expansion creator ==")
	_test_files()
	_test_starter_content()
	await _test_ui()
	await _test_art()
	await _test_renames()
	await _test_admin()
	if checks < 50:
		failures.append("Test aborted before the file and UI checks completed")
	await _screenshots()
	creator.queue_free()
	await process_frame
	if _settings_existed:
		var file := FileAccess.open(Creator.SETTINGS, FileAccess.WRITE)
		file.store_buffer(_settings)
		file.close()
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(Creator.SETTINGS))
	_remove_test_tree(test_root)
	for failure in failures:
		print("FAIL: " + failure)
	print("RESULT: %s (%d failures)" % ["PASS" if failures.is_empty() else "FAIL", failures.size()])
	quit(0 if failures.is_empty() else 1)

## One starter deck per class, of `card_id`: a content folder is only
## complete with them, so a test root's first expansion carries them.
func _starters(card_id: String, expansion_id: String) -> Array:
	var decks: Array = []
	for class_id: String in Schema.CLASSES:
		decks.append({"id": class_id + "_STARTER", "name": class_id.capitalize() + " starter", "classId": class_id, "expansionId": expansion_id, "cards": [{"cardId": card_id, "copies": 2}]})
	# As read from a file, so a round trip compares equal: JSON numbers load as floats.
	return JSON.parse_string(JSON.stringify(decks))

func _fixture(id: String = "TEST") -> Dictionary:
	var core := Files.load_folder(Files.default_root().path_join("core"))
	var data: Dictionary = core["data"]
	data["expansion"]["id"] = id
	data["cards"] = [data["cards"][0]]
	data["cards"][0]["id"] = id.to_lower() + "_wolf"
	data["cards"][0]["expansionId"] = id
	data["packs"][0]["id"] = id + "_PACK"
	data["packs"][0]["expansionId"] = id
	# Core's starter decks and scenarios name Core's cards; a fixture has its own.
	data["starterDecks"] = []
	data["scenarios"] = []
	return data

func _test_files() -> void:
	var shipped := Files.catalog(Files.default_root())
	_check("finds every shipped expansion", shipped["ok"] and shipped["entries"].size() == 3)
	var total := 0
	for entry: Dictionary in shipped["entries"]:
		var context: Array = shipped["entries"].filter(func(other: Dictionary) -> bool: return other["folder"] != entry["folder"])
		_check("validates shipped " + str(entry["folder"]), Validator.validate(entry["data"], context).is_empty())
		total += entry["data"]["cards"].size()
	_check("loads all 33 cards", total == 33)
	var root := test_root.path_join("content")
	DirAccess.make_dir_recursive_absolute(root)
	var data := _fixture()
	data["starterDecks"] = _starters("test_wolf", "TEST")
	var result := Files.save(root, "test", data)
	_check("saves a new expansion", result["ok"])
	var path := root.path_join("test")
	var original := Files.fingerprint(path)
	var loaded := Files.load_folder(path)
	_check("round trips metadata, cards and packs", loaded["ok"] and loaded["data"] == data)
	Files.save(root, "test", data, original)
	_check("saving unchanged data preserves original file bytes", Files.fingerprint(path) == original)
	var invalid := data.duplicate(true)
	invalid["cards"][0]["cost"] = "two"
	_check("rejects a string cost", not Files.save(root, "test", invalid, original)["ok"])
	_check("invalid draft does not touch files", Files.fingerprint(path) == original)
	_check("requires explicit overwrite for imported collisions", Files.save(root, "test", data).get("needs_overwrite", false))
	_check("blocks paths outside the selected content root", not Files.save(root, "../escape", data)["ok"])
	_check("rejects duplicate expansion and card IDs", not Files.save(root, "duplicate", data)["ok"])
	var other := _fixture("OTHER")
	other["cards"][0]["id"] = data["cards"][0]["id"]
	_check("rejects card ID collisions across expansions", not Files.save(root, "other", other)["ok"])
	var changed := data.duplicate(true)
	changed["expansion"]["name"] = "Hand edited"
	Files.write_folder(path, changed, original)
	_check("detects external file changes", not Files.save(root, "test", data, original)["ok"])
	_check("external edit survives stale save", Files.load_folder(path)["data"]["expansion"]["name"] == "Hand edited")
	var cross := _fixture("CROSS")
	cross["cards"][0]["effects"] = [{"trigger": "ARRIVAL", "effect": {"type": "SUMMON", "definitionId": "test_wolf"}}]
	_check("validates cross-expansion summons", Files.save(root, "cross", cross)["ok"])
	cross["cards"][0]["effects"][0]["effect"]["definitionId"] = "missing"
	_check("rejects broken summon references", not Files.save(root, "cross", cross)["ok"])
	for mutation: Dictionary in [
		{"key": "type", "value": "SPELL"}, {"key": "keywords", "value": ["FLYING"]},
		{"key": "health", "value": 1.5}, {"key": "unknownField", "value": 3},
		{"key": "rarity", "value": "MYTHIC"}, {"key": "classId", "value": "MISSING"},
		{"key": "description", "value": "**unclosed"},
	]:
		invalid = data.duplicate(true)
		invalid["cards"][0][mutation["key"]] = mutation["value"]
		_check("rejects invalid " + str(mutation["key"]), not Validator.validate(invalid).is_empty())
	invalid = data.duplicate(true)
	invalid["cards"][0]["keywords"] = []
	invalid["cards"][0]["description"] = ""
	_check("allows a blank description on a card with no keywords", Validator.validate(invalid).is_empty())
	invalid["cards"][0]["keywords"] = ["GUARD"]
	_check("requires a description to print a card's keywords", not Validator.validate(invalid).is_empty())
	invalid = data.duplicate(true)
	invalid["expansion"]["policy"].erase("released")
	_check("requires every policy flag", not Validator.validate(invalid).is_empty())
	invalid = data.duplicate(true)
	invalid["packs"][0]["cardCount"] = 9
	_check("checks pack slot totals", not Validator.validate(invalid).is_empty())
	invalid = data.duplicate(true)
	invalid["packs"][0]["rarityRules"]["slots"][0]["weights"]["BASIC"] = 1
	_check("excludes Basic cards from pack weights", not Validator.validate(invalid).is_empty())
	var effects: Array = [
		{"type": "DEAL_DAMAGE", "amount": 1, "target": "PLAY_TARGET"},
		{"type": "HEAL", "amount": 1, "target": "OWNER_HERO"},
		{"type": "DRAW_CARD", "amount": 1},
		{"type": "BUFF", "attack": -1, "health": 0, "target": "SELF"},
		{"type": "APPLY_STATUS", "status": "ROOTED", "duration": 1, "target": "PLAY_TARGET"},
		{"type": "SUMMON", "definitionId": "test_wolf"},
		{"type": "MOVE", "target": "SELF", "destination": {"row": "BACK", "column": 0}},
		{"type": "DESTROY", "target": "ENEMY_WEAPON"},
		{"type": "GAIN_TAIKA", "amount": 1},
	]
	var valid := data.duplicate(true)
	valid["cards"][0]["effects"] = effects.map(func(effect: Dictionary) -> Dictionary: return {"trigger": "ARRIVAL", "effect": effect})
	_check("supports all engine effect types", Validator.validate(valid).is_empty())
	# Force the third replacement to fail after the first two succeed.
	var rollback := test_root.path_join("rollback")
	Files.write_folder(rollback, data)
	DirAccess.remove_absolute(rollback.path_join("packs.json"))
	DirAccess.make_dir_absolute(rollback.path_join("packs.json"))
	var before_expansion := FileAccess.get_sha256(rollback.path_join("expansion.json"))
	var before_cards := FileAccess.get_sha256(rollback.path_join("cards.json"))
	result = Files.write_folder(rollback, changed, Files.fingerprint(rollback))
	_check("reports a failed file replacement", not result["ok"])
	_check("rolls back earlier replacements", FileAccess.get_sha256(rollback.path_join("expansion.json")) == before_expansion and FileAccess.get_sha256(rollback.path_join("cards.json")) == before_cards)
	_check("leaves no staged files after rollback",
		Array(DirAccess.get_files_at(rollback)).all(func(file: String) -> bool: return not file.contains(".creator-")))

func _test_ui() -> void:
	var backdrop := ColorRect.new()
	backdrop.color = Color("252c35")
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	get_root().add_child(backdrop)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 14)
	get_root().add_child(margin)
	creator = Creator.new()
	margin.add_child(creator)
	await process_frame
	var root := test_root.path_join("ui-content")
	DirAccess.make_dir_recursive_absolute(root)
	Files.save(root, "test", _fixture())
	_check("opens a content folder in the creator", creator.open_root(root))
	_check("opening is clean", not creator.dirty and creator.draft["cards"].size() == 1)
	var initial := Files.fingerprint(root.path_join("test"))
	var metadata_form: Control = creator._metadata.get_child(0)
	_edit_text(metadata_form, "name", "Edited locally")
	_check("form edits update the draft", creator.dirty and creator.draft["expansion"]["name"] == "Edited locally")
	_check("form edits stay in memory", Files.fingerprint(root.path_join("test")) == initial)
	creator.save_draft()
	_check("Save writes the actual JSON files", not creator.dirty and Files.load_folder(root.path_join("test"))["data"]["expansion"]["name"] == "Edited locally")
	metadata_form = creator._metadata.get_child(0)
	_edit_text(metadata_form, "name", "Abandoned edit")
	creator.confirm_discard(func() -> void: pass)
	creator._discard.hide()
	creator._discard.confirmed.emit()
	_check("discard restores the saved draft, not just its clean flag", creator.draft["expansion"]["name"] == "Edited locally" and not creator.dirty)
	creator.export_folder(root.path_join("duplicate-export"))
	_check("export cannot introduce duplicate IDs into the active content root", not DirAccess.dir_exists_absolute(root.path_join("duplicate-export")))
	metadata_form = creator._metadata.get_child(0)
	_edit_text(metadata_form, "id", "RENAMED")
	_check("expansion ID changes update card and pack assignments", creator.draft["cards"][0]["expansionId"] == "RENAMED" and creator.draft["packs"][0]["expansionId"] == "RENAMED")
	_edit_text(metadata_form, "id", "TEST")
	creator.add_entity("cards")
	_check("adds a valid creature", creator.draft["cards"].size() == 2 and creator.draft["cards"][1]["type"] == "CREATURE")
	var card_form: Control = creator._card_form.get_child(0)
	var type_picker: OptionButton = card_form.get_child(0)
	type_picker.select(1)
	type_picker.item_selected.emit(1)
	await process_frame
	await process_frame
	_check("type picker creates an Action with its required fields", creator.draft["cards"][1]["type"] == "ACTION" and creator.draft["cards"][1].has("targetMode") and not creator.draft["cards"][1].has("health"))
	var fields: Control = card_form.get_child(1)
	_edit_text(fields, "name", "Snowfall")
	_check("card fields update without saving", creator.draft["cards"][1]["name"] == "Snowfall")
	var artist_toggle: CheckBox = fields.get_node("artist").get_child(0)
	artist_toggle.button_pressed = true
	await process_frame
	await process_frame
	card_form = creator._card_form.get_child(0)
	fields = card_form.get_child(1)
	_edit_text(fields, "artist", "Aino Virtanen")
	_check("the optional art credit is edited through the form", creator.draft["cards"][1]["artist"] == "Aino Virtanen" and creator.validate_draft())
	creator._render_preview()
	_check("the preview shows the art credit", creator._preview.find_children("*", "Label", true, false).any(func(label: Label) -> bool: return label.text == "Art: Aino Virtanen"))
	creator.draft["cards"][1]["artist"] = " "
	_check("a blank art credit is rejected", not creator.validate_draft())
	creator.draft["cards"][1].erase("artist")
	creator._refresh_entities("cards")
	card_form = creator._card_form.get_child(0)
	fields = card_form.get_child(1)
	var effects_form: Control = fields.get_node("effects").get_child(1)
	(effects_form.get_child(0) as Button).pressed.emit()
	await process_frame
	await process_frame
	var effect_form: Control = effects_form.get_child(0).get_child(0).get_child(1)
	var effect_picker: OptionButton = effect_form.get_child(0)
	effect_picker.select(1)
	effect_picker.item_selected.emit(1)
	await process_frame
	await process_frame
	var amount: SpinBox = effect_form.get_child(1).get_node("amount").get_child(1).get_child(0)
	amount.value = 3
	_check("nested effect controls update the card", creator.draft["cards"][1]["effects"][0]["type"] == "HEAL" and creator.draft["cards"][1]["effects"][0]["amount"] == 3)
	creator.duplicate_entity("cards")
	_check("duplicates have distinct IDs", creator.draft["cards"][1]["id"] != creator.draft["cards"][2]["id"])
	creator.add_entity("packs")
	_check("new packs have valid slot totals", creator.validate_draft())
	var pack_form: Control = creator._pack_form.get_child(0)
	var rules: Control = pack_form.get_node("rarityRules").get_child(1)
	var slots: Control = rules.get_node("slots").get_child(1)
	var slot: Control = slots.get_child(0).get_child(0).get_child(1)
	var count: SpinBox = slot.get_node("count").get_child(1).get_child(0)
	count.value = 5
	_check("pack rule editing reports mismatched totals", not creator.validate_draft())
	var card_count: SpinBox = pack_form.get_node("cardCount").get_child(1).get_child(0)
	card_count.value = 6
	_check("pack totals can be corrected through the form", creator.validate_draft())
	var export_path := test_root.path_join("exported")
	creator.export_folder(export_path)
	_check("exports all three JSON files", Files.load_folder(export_path)["ok"])
	_check("export elsewhere leaves source changes unsaved", creator.dirty)
	creator.save_draft()
	_check("saves new cards and packs", not creator.dirty and Files.load_folder(root.path_join("test"))["data"]["cards"].size() == 3)
	creator.import_folder(export_path)
	_check("import remains an unsaved draft", creator.dirty and creator.source_path == "")
	var existing := Files.fingerprint(root.path_join("test"))
	creator.save_draft()
	_check("import collision opens an overwrite confirmation", creator._overwrite.visible)
	_check("confirmation has not overwritten anything", Files.fingerprint(root.path_join("test")) == existing)
	creator._overwrite.hide()
	creator._overwrite.confirmed.emit()
	_check("confirmed import becomes a saved local expansion", not creator.dirty and creator.source_path != "")
	creator.new_expansion()
	var discarded := [false]
	creator.confirm_discard(func() -> void: discarded[0] = true)
	_check("guards unsaved drafts", creator._discard.visible and not discarded[0])
	creator._discard.hide()
	creator._discard.canceled.emit()
	_check("cancel keeps the unsaved draft", creator.dirty and not discarded[0])
	creator.confirm_discard(func() -> void: discarded[0] = true)
	creator._discard.hide()
	creator._discard.confirmed.emit()
	_check("explicit discard continues the requested action", discarded[0])
	var fresh = Creator.new()
	get_root().add_child(fresh)
	fresh.new_expansion()
	fresh.opened()
	_check("returning to the tab preserves a draft created before opening a folder", fresh.dirty and fresh.draft["expansion"]["id"] == "NEW_EXPANSION" and fresh.content_root == "")
	fresh.queue_free()
	creator.new_expansion()
	creator.add_entity("cards")
	creator.draft["cards"][0]["cost"] = -1
	_check("validation blocks malformed drafts in the UI", not creator.validate_draft() and creator._issues.visible)
	creator._issues.item_selected.emit(0)
	_check("selecting a card issue opens the Cards tab", creator._tabs.current_tab == 1)
	# Make the three card frame variants as well as Creature form constructible.
	for variant in ["ARTIFACT", "WEAPON"]:
		var schema: Dictionary = Validator.definition("card")["oneOf"][2 if variant == "ARTIFACT" else 3]
		var card: Dictionary = Form.default_value(schema)
		card.merge({"id": variant.to_lower(), "name": variant.capitalize(), "expansionId": creator.draft["expansion"]["id"], "description": "No special abilities."}, true)
		creator.draft["cards"] = [card]
		creator._card_index = 0
		creator._refresh_entities("cards")
		_check("renders " + variant + " preview", creator._preview.get_child_count() >= 2)

func _test_art() -> void:
	# Art is written to a scratch folder, never the client's own art/cards/.
	var art_dir := test_root.path_join("art")
	DirAccess.make_dir_recursive_absolute(art_dir)
	CardArt.art_dir = art_dir
	CardArt.clear_cache()
	# Saved art goes in a folder named after the expansion's content folder.
	var expansion_art := art_dir.path_join("test")
	var picture := Image.create(80, 40, false, Image.FORMAT_RGBA8)
	picture.fill(Color.RED)
	var pick := test_root.path_join("picked art.png")
	picture.save_png(pick)
	var not_image := test_root.path_join("notes.txt")
	FileAccess.open(not_image, FileAccess.WRITE).store_string("not an image")
	var root := test_root.path_join("art-content")
	DirAccess.make_dir_recursive_absolute(root)
	Files.save(root, "test", _fixture())
	var art_creator = Creator.new()
	get_root().add_child(art_creator)
	await process_frame
	art_creator.open_root(root)
	_check("a card without art previews without a picture", _preview_art(art_creator) == null)
	art_creator._tabs.current_tab = 1
	await process_frame
	await process_frame
	var remove_button: Button = art_creator._preview.find_children("*", "Button", true, false).filter(func(button: Button) -> bool: return button.text == "Remove art")[0]
	# The window's bottom-right corner holds the Admin UI switch.
	_check("art buttons stay clear of the window's bottom corner", remove_button.get_global_rect().end.y < get_root().get_visible_rect().size.y - 80)
	_check("rejects a file that is not an image", not art_creator.choose_art(not_image) and not art_creator.dirty)
	_check("choosing art stages it", art_creator.choose_art(pick) and art_creator.dirty)
	_check("staged art shows in the preview", _preview_art(art_creator) != null)
	_check("staged art writes nothing before Save", not FileAccess.file_exists(expansion_art.path_join("test_wolf.png")))
	art_creator.confirm_discard(func() -> void: pass)
	art_creator._discard.hide()
	art_creator._discard.confirmed.emit()
	_check("discard drops staged art", _preview_art(art_creator) == null and not FileAccess.file_exists(expansion_art.path_join("test_wolf.png")))
	art_creator.choose_art(pick)
	art_creator.save_draft()
	_check("Save copies art under the card ID", not art_creator.dirty and FileAccess.file_exists(expansion_art.path_join("test_wolf.png")))
	_check("saved art is used wherever the card is drawn", CardArt.texture_for("test_wolf") != null)
	CardArt.clear_cache()
	_check("art not yet imported by the editor still loads", CardArt.texture_for("test_wolf") != null)
	_check("unframed art is shown whole", CardArt.texture_for("test_wolf").get_size() == Vector2(80, 40) and not FileAccess.file_exists(expansion_art.path_join("test_wolf.crop.json")))
	var frame := _preview_frame(art_creator)
	_check("unframed art starts at the lowest zoom", is_equal_approx(art_creator.art_zoom(frame), 1.0))
	art_creator.frame_art(frame, Vector2.ZERO, 2.0)
	var zoomed: Rect2 = frame._art.region
	_check("zooming stages framing and previews it", art_creator.dirty and zoomed.size.x < 0.5 and is_equal_approx(art_creator.art_zoom(frame), 2.0))
	_check("staged framing writes nothing before Save", not FileAccess.file_exists(expansion_art.path_join("test_wolf.crop.json")))
	art_creator.frame_art(frame, Vector2(10, 0))
	_check("dragging the art right shows more of its left", frame._art.region.position.x < zoomed.position.x and is_equal_approx(frame._art.region.size.x, zoomed.size.x))
	art_creator.frame_art(frame, Vector2(-100000, -100000))
	_check("art cannot be dragged past its edge", is_equal_approx(frame._art.region.end.x, 1.0) and is_equal_approx(frame._art.region.end.y, 1.0))
	art_creator.save_draft()
	var framed := CardArt.texture_for("test_wolf")
	_check("Save writes the framing beside the art", not art_creator.dirty and FileAccess.file_exists(expansion_art.path_join("test_wolf.crop.json")))
	_check("framed art shows only its framed part", framed != null and framed.get_width() < 40 and CardArt.source_texture_for("test_wolf").get_size() == Vector2(80, 40))
	CardArt.clear_cache()
	_check("framing is read back from disk", CardArt.texture_for("test_wolf").get_size() == framed.get_size())
	_check("reopened framing previews where it was left", is_equal_approx(art_creator.art_zoom(_preview_frame(art_creator)), 2.0))
	var fields: Control = art_creator._card_form.get_child(0).get_child(1)
	_edit_text(fields, "id", "test_grey_wolf")
	_check("a renamed card keeps previewing its art", _preview_art(art_creator) != null)
	art_creator.save_draft()
	_check("Save moves art to the renamed card ID", FileAccess.file_exists(expansion_art.path_join("test_grey_wolf.png")) and not FileAccess.file_exists(expansion_art.path_join("test_wolf.png")))
	_check("Save moves framing with renamed art", FileAccess.file_exists(expansion_art.path_join("test_grey_wolf.crop.json")) and not FileAccess.file_exists(expansion_art.path_join("test_wolf.crop.json")))
	art_creator.reset_framing()
	_check("resetting framing previews the whole fit again", art_creator.dirty and is_equal_approx(art_creator.art_zoom(_preview_frame(art_creator)), 1.0))
	art_creator.save_draft()
	_check("Save drops reset framing", not FileAccess.file_exists(expansion_art.path_join("test_grey_wolf.crop.json")) and CardArt.texture_for("test_grey_wolf").get_size() == Vector2(80, 40))
	art_creator.frame_art(_preview_frame(art_creator), Vector2.ZERO, 3.0)
	art_creator.save_draft()
	art_creator.duplicate_entity("cards")
	art_creator.save_draft()
	_check("a duplicated card keeps its original's art", FileAccess.file_exists(expansion_art.path_join(str(art_creator.draft["cards"][1]["id"]) + ".png")) and FileAccess.file_exists(expansion_art.path_join("test_grey_wolf.png")))
	_check("a duplicated card keeps its original's framing", CardArt.crop_for(str(art_creator.draft["cards"][1]["id"])).is_equal_approx(CardArt.crop_for("test_grey_wolf")) and FileAccess.file_exists(expansion_art.path_join("test_grey_wolf.crop.json")))
	var jpeg := test_root.path_join("replacement.jpg")
	picture.save_jpg(jpeg)
	art_creator.choose_art(jpeg)
	art_creator.save_draft()
	_check("new art in another format replaces the old file", FileAccess.file_exists(expansion_art.path_join(str(art_creator.draft["cards"][1]["id"]) + ".jpg")) and not FileAccess.file_exists(expansion_art.path_join(str(art_creator.draft["cards"][1]["id"]) + ".png")))
	_check("new art starts unframed", not FileAccess.file_exists(expansion_art.path_join(str(art_creator.draft["cards"][1]["id"]) + ".crop.json")))
	art_creator._card_index = 0
	art_creator._render_entity("cards")
	art_creator.clear_art()
	_check("removing art stages it", art_creator.dirty and _preview_art(art_creator) == null and FileAccess.file_exists(expansion_art.path_join("test_grey_wolf.png")))
	art_creator.save_draft()
	_check("Save deletes removed art", not FileAccess.file_exists(expansion_art.path_join("test_grey_wolf.png")) and CardArt.texture_for("test_grey_wolf") == null)
	_check("Save deletes removed art's framing", not FileAccess.file_exists(expansion_art.path_join("test_grey_wolf.crop.json")))
	art_creator.queue_free()
	await process_frame
	picture.save_png(art_dir.path_join("loose_card.png"))
	CardArt.clear_cache()
	_check("art directly in the art folder is still found", CardArt.texture_for("loose_card") != null and CardArt.relative(CardArt.path_for("loose_card")) == "loose_card.png")
	CardArt.link("loose_card", pick, "test")
	_check("relinked art moves into its expansion folder", FileAccess.file_exists(expansion_art.path_join("loose_card.png")) and not FileAccess.file_exists(art_dir.path_join("loose_card.png")))
	CardArt.clear_cache()
	_check("art in an expansion folder is found by card ID alone", CardArt.relative(CardArt.path_for("loose_card")) == "test/loose_card.png")
	CardArt.art_dir = CardArt.ART_DIR
	CardArt.clear_cache()

func _preview_art(target: Control) -> Texture2D:
	var frame := _preview_frame(target)
	return frame._art.texture if frame != null else null

func _preview_frame(target: Control) -> CardFrame:
	for child in target._preview.get_children():
		if child is CardFrame:
			return child
	return null

func _edit_text(form: Control, field: String, text: String) -> void:
	var row := form.get_node(field)
	var input = row.get_child(row.get_child_count() - 1).get_child(0)
	input.text = text
	if input is LineEdit:
		input.text_changed.emit(text)
	else:
		input.text_changed.emit()

func _test_admin() -> void:
	var accounts := AccountClient.new()
	get_root().add_child(accounts)
	var admin := Admin.new()
	admin.setup(accounts, CardLibrary.new())
	get_root().add_child(admin)
	await process_frame
	var tabs: TabContainer = admin.find_children("*", "TabContainer", true, false)[0]
	_check("admin panel includes the Expansions tab", tabs.get_tab_count() == 3 and tabs.get_tab_title(2) == "Expansions")
	tabs.current_tab = 2
	await process_frame
	_check("selecting the admin tab opens the local creator", not admin._expansion_creator.draft.is_empty())
	admin._expansion_creator.new_expansion()
	var closed := [false]
	admin.closed.connect(func() -> void: closed[0] = true)
	for button: Button in admin.find_children("*", "Button", true, false):
		if button.text == "Back":
			button.pressed.emit()
	_check("admin Back guards an unsaved expansion", not closed[0] and admin._expansion_creator._discard.visible)
	admin._expansion_creator._discard.hide()
	admin._expansion_creator._discard.confirmed.emit()
	_check("admin Back continues after explicit discard", closed[0])
	admin.queue_free()
	accounts.queue_free()
	await process_frame

func _test_starter_content() -> void:
	var core := Files.load_folder(Files.default_root().path_join("core"))
	_check("Core ships its starter decks and scenarios as content",
		core["data"]["starterDecks"].size() == Schema.CLASSES.size() and not core["data"]["scenarios"].is_empty())
	var root := test_root.path_join("starter-content")
	DirAccess.make_dir_recursive_absolute(root)
	var data := _fixture()
	_check("an expansion without starter decks reads as having none", data["starterDecks"].is_empty())
	Files.save(root, "test", data)
	_check("an empty optional file is not written",
		not FileAccess.file_exists(root.path_join("test/starterDecks.json")) and not FileAccess.file_exists(root.path_join("test/scenarios.json")))
	var other := _fixture("OTHER")
	_check("a content folder must give every class a starter deck",
		Files.validate(other, root, root.path_join("other")).has("class PRIEST: has no starter deck"))
	data["starterDecks"] = _starters("missing_card", "TEST")
	var errors := Validator.validate(data)
	_check("a starter deck naming a missing card says which",
		errors.has("starterDecks.json[0].cards: unknown card missing_card"))
	data["starterDecks"] = []
	data["scenarios"] = [{"id": "DUEL", "name": "Duel", "expansionId": "TEST", "battlefield": {"width": 3},
		"sideA": {"heroDefinitionId": "healer", "heroHealth": 30, "startingTaika": 1, "maxTaika": 10, "startingWeapon": "test_wolf"},
		"sideB": {"heroDefinitionId": "nobody", "heroHealth": 30, "startingTaika": 1, "maxTaika": 10}}]
	errors = Validator.validate(data)
	_check("a scenario's starting Weapon must be a Weapon", errors.has("scenarios.json[0].sideA: test_wolf must be a Weapon"))
	_check("a scenario's Hero must exist", errors.has("scenarios.json[0].sideB.heroDefinitionId: unknown hero nobody"))

## Renaming a card in the creator follows every reference to it — a SUMMON,
## a starter deck, a scenario — into every expansion, after asking.
func _test_renames() -> void:
	var root := test_root.path_join("rename-content")
	DirAccess.make_dir_recursive_absolute(root)
	# Saving moves art too, so it stays in a scratch folder.
	CardArt.art_dir = test_root.path_join("rename-art")
	DirAccess.make_dir_recursive_absolute(CardArt.art_dir)
	CardArt.clear_cache()
	var base := _fixture()
	base["starterDecks"] = _starters("test_wolf", "TEST")
	base["scenarios"] = [{"id": "DUEL", "name": "Duel", "expansionId": "TEST", "battlefield": {"width": 3},
		"sideA": {"heroDefinitionId": "healer", "heroHealth": 30, "startingTaika": 1, "maxTaika": 10, "startingCreatures": [{"definitionId": "test_wolf", "position": {"row": "FRONT", "column": 0}}]},
		"sideB": {"heroDefinitionId": "striker", "heroHealth": 30, "startingTaika": 1, "maxTaika": 10, "startingCards": ["test_wolf"]}}]
	_check("saves an expansion with starter decks and scenarios", Files.save(root, "test", base)["ok"])
	var other := _fixture("OTHER")
	other["cards"][0]["effects"] = [{"trigger": "ARRIVAL", "effect": {"type": "SUMMON", "definitionId": "test_wolf"}}]
	_check("saves an expansion summoning another's card", Files.save(root, "other", other)["ok"])
	var other_before := Files.fingerprint(root.path_join("other"))

	var renamer = Creator.new()
	get_root().add_child(renamer)
	await process_frame
	renamer.open_root(root)
	for index in renamer._entries.size():
		if renamer._entries[index]["folder"] == "test":
			renamer._load_entry(index)
	_check("the creator has tabs for starter decks and scenarios",
		renamer._tabs.get_tab_count() == 5 and renamer._tabs.get_tab_title(3) == "Starter decks")
	var fields: Control = renamer._card_form.get_child(0).get_child(1)
	_edit_text(fields, "id", "test_hen")
	renamer.save_draft()
	_check("renaming a card asks before saving", renamer._renames_dialog.visible)
	var text: String = renamer._renames_dialog.dialog_text
	_check("the question names the rename and everything it updates",
		text.contains("test_wolf → test_hen") and text.contains("starterDecks.json · Priest starter")
		and text.contains("scenarios.json · Duel") and text.contains("other/cards.json"))
	renamer._renames_dialog.hide()
	renamer._renames_dialog.canceled.emit()
	_check("declining saves nothing", renamer.dirty and Files.fingerprint(root.path_join("other")) == other_before
		and Files.load_folder(root.path_join("test"))["data"]["cards"][0]["id"] == "test_wolf")
	renamer.save_draft()
	renamer._renames_dialog.hide()
	renamer._renames_dialog.confirmed.emit()
	var saved: Dictionary = Files.load_folder(root.path_join("test"))["data"]
	var summoned: Dictionary = Files.load_folder(root.path_join("other"))["data"]
	_check("the renamed card is saved", not renamer.dirty and saved["cards"][0]["id"] == "test_hen")
	_check("its starter decks follow the rename", saved["starterDecks"].all(func(deck: Dictionary) -> bool: return deck["cards"][0]["cardId"] == "test_hen"))
	_check("its scenarios follow the rename", saved["scenarios"][0]["sideA"]["startingCreatures"][0]["definitionId"] == "test_hen"
		and saved["scenarios"][0]["sideB"]["startingCards"] == ["test_hen"])
	_check("another expansion's SUMMON follows the rename", summoned["cards"][0]["effects"][0]["effect"]["definitionId"] == "test_hen")
	_check("the content stays valid after the rename", Files.validate(summoned, root, root.path_join("other")).is_empty())
	# A rename nothing refers to saves without asking.
	renamer.add_entity("cards")
	renamer.save_draft()
	fields = renamer._card_form.get_child(0).get_child(1)
	_edit_text(fields, "id", "lonely_card")
	renamer.save_draft()
	_check("a rename nothing refers to saves without asking", not renamer._renames_dialog.visible and not renamer.dirty)
	renamer.queue_free()
	await process_frame
	CardArt.art_dir = CardArt.ART_DIR
	CardArt.clear_cache()

func _screenshots() -> void:
	var destination := ""
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--screenshot-dir="):
			destination = argument.trim_prefix("--screenshot-dir=")
		elif argument.begins_with("--roundtrip-dir="):
			var directory := argument.trim_prefix("--roundtrip-dir=")
			for entry: Dictionary in Files.catalog(Files.default_root())["entries"]:
				var result := Files.write_folder(directory.path_join(entry["folder"]), entry["data"])
				_check("exports shared-schema fixture " + str(entry["folder"]), result["ok"])
	if destination == "":
		return
	creator.open_root(Files.default_root())
	for index in creator._entries.size():
		if creator._entries[index]["folder"] == "core":
			creator._load_entry(index)
	creator._tabs.current_tab = 1
	for i in range(12):
		await process_frame
	get_root().get_texture().get_image().save_png(destination.path_join("expansion-creator-cards.png"))
	creator._tabs.current_tab = 0
	for i in range(5):
		await process_frame
	get_root().get_texture().get_image().save_png(destination.path_join("expansion-creator-metadata.png"))
	creator._tabs.current_tab = 2
	for i in range(5):
		await process_frame
	get_root().get_texture().get_image().save_png(destination.path_join("expansion-creator-packs.png"))

func _remove_test_tree(path: String) -> void:
	var base := ProjectSettings.globalize_path("user://").path_join("creator-tests-")
	if not test_root.begins_with(base) or (path != test_root and not path.begins_with(test_root + "/")):
		push_error("Refusing unexpected test cleanup path")
		return
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for filename in directory.get_files():
		DirAccess.remove_absolute(path.path_join(filename))
	for folder in directory.get_directories():
		_remove_test_tree(path.path_join(folder))
	DirAccess.remove_absolute(path)

func _check(label: String, condition: bool) -> void:
	checks += 1
	print("  [%s] %s" % ["ok" if condition else "XX", label])
	if not condition:
		failures.append(label)
