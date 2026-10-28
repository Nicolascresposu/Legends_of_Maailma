extends VBoxContainer

## Recursive, schema-driven form. Every control edits a draft, never a file.
signal changed(value: Variant)
const Validator := preload("res://src/content_validator.gd")
const Schema := preload("res://src/content_schema.gd")
var value: Variant
var rule: Dictionary

func setup(schema: Dictionary, initial: Variant) -> void:
	rule = Validator.resolve_schema(schema)
	value = initial.duplicate(true) if initial is Dictionary or initial is Array else initial
	_build()

static func default_value(unresolved: Dictionary) -> Variant:
	var schema := Validator.resolve_schema(unresolved)
	if schema.has("const"):
		return schema["const"]
	if schema.has("enum"):
		return schema["enum"][0]
	if schema.has("oneOf"):
		return default_value(schema["oneOf"][0])
	match str(schema.get("type", "")):
		"object":
			var object: Dictionary = {}
			for key in schema.get("required", []):
				object[key] = default_value(schema["properties"][key])
			return object
		"array": return []
		"integer", "number": return schema.get("minimum", 1)
		"boolean": return false
	return ""

func _build() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 8)
	if rule.has("oneOf"):
		_build_union()
	elif str(rule.get("type", "")) == "object":
		_build_object()
	elif str(rule.get("type", "")) == "array":
		_build_array()
	else:
		_build_scalar()

func _build_union() -> void:
	var picker := OptionButton.new()
	picker.name = "Type"
	var selected := 0
	for index in rule["oneOf"].size():
		var variant: Dictionary = rule["oneOf"][index]
		var type_name: String = variant["properties"]["type"]["const"]
		picker.add_item(type_name.replace("_", " ").capitalize())
		if value is Dictionary and value.get("type", "") == type_name:
			selected = index
	picker.select(selected)
	add_child(picker)
	picker.item_selected.connect(func(index: int) -> void:
		var variant: Dictionary = rule["oneOf"][index]
		var next: Dictionary = default_value(variant)
		# Preserve common fields across types, but effects have different shapes.
		for key in value:
			if key != "type" and key != "effects" and variant["properties"].has(key):
				next[key] = value[key]
		value = next
		changed.emit(value)
		_build.call_deferred())
	var form = get_script().new()
	form.setup(rule["oneOf"][selected], value)
	form.changed.connect(func(updated: Variant) -> void:
		value = updated
		changed.emit(value))
	add_child(form)

func _build_object() -> void:
	if not value is Dictionary:
		value = default_value(rule)
	var required: Array = rule.get("required", [])
	var keys: Array = rule.get("properties", {}).keys()
	if rule.get("properties", {}).get("type", {}).get("const", "") in ["CREATURE", "ACTION", "ARTIFACT", "WEAPON", "LOCATION"]:
		keys = ["id", "name", "cost", "attack", "health", "durability", "duration", "range", "targetMode", "targetTag", "activation", "rarity", "source", "expansionId", "classId", "collectible", "tags", "keywords", "description", "flavour", "artist", "effects", "auras"]
	for key: String in keys:
		if not rule["properties"].has(key):
			continue
		var property: Dictionary = rule["properties"][key]
		if key == "type" or key == "schemaVersion":
			continue
		if key == "classId":
			property = {"type": "string", "enum": Schema.CLASSES}
		elif key == "heroDefinitionId":
			property = {"type": "string", "enum": Schema.HEROES}
		elif key == "expansionId":
			property = {"const": value.get(key, "")}
		var resolved := Validator.resolve_schema(property)
		var scalar: bool = not resolved.has("oneOf") and resolved.get("type", "") not in ["object", "array"] and key not in ["description", "flavour"]
		var row: BoxContainer = HBoxContainer.new() if scalar else VBoxContainer.new()
		row.name = key
		add_child(row)
		if resolved.get("type", "") == "boolean":
			var toggle := CheckBox.new()
			toggle.text = _label(key)
			toggle.button_pressed = bool(value.get(key, false))
			toggle.toggled.connect(func(enabled: bool) -> void:
				value[key] = enabled
				changed.emit(value))
			row.add_child(toggle)
			continue
		if not required.has(key):
			var toggle := CheckBox.new()
			toggle.text = _label(key) + (" (optional)" if key != "classId" else " (off = neutral)")
			toggle.button_pressed = value.has(key)
			row.add_child(toggle)
			toggle.toggled.connect(func(enabled: bool) -> void:
				if enabled:
					value[key] = default_value(property)
				else:
					value.erase(key)
				changed.emit(value)
				_build.call_deferred())
			if not value.has(key):
				continue
		else:
			var label := Label.new()
			label.text = _label(key)
			if scalar:
				label.custom_minimum_size.x = 115
			label.add_theme_color_override("font_color", Color("d9c28d"))
			row.add_child(label)
		var form = get_script().new()
		form.name = key
		form.setup(property, value.get(key, default_value(property)))
		form.changed.connect(func(updated: Variant) -> void:
			value[key] = updated
			changed.emit(value))
		row.add_child(form)
		if key == "id":
			form.tooltip_text = "Stable ID that other content, decks and collections refer to. Renaming a card updates every reference to it in this content folder when you save; decks and collections on a server keep the old ID."

func _build_array() -> void:
	if not value is Array:
		value = []
	for index in value.size():
		var panel := PanelContainer.new()
		var box := VBoxContainer.new()
		panel.add_child(box)
		add_child(panel)
		var row := HBoxContainer.new()
		box.add_child(row)
		var label := Label.new()
		label.text = "Entry %d" % (index + 1)
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(label)
		var remove := Button.new()
		remove.text = "Remove"
		row.add_child(remove)
		remove.pressed.connect(func() -> void:
			value.remove_at(index)
			changed.emit(value)
			_build.call_deferred())
		var form = get_script().new()
		form.setup(rule["items"], value[index])
		form.changed.connect(func(updated: Variant) -> void:
			value[index] = updated
			changed.emit(value))
		box.add_child(form)
	var add := Button.new()
	add.text = "Add entry"
	add.alignment = HORIZONTAL_ALIGNMENT_LEFT
	add_child(add)
	add.pressed.connect(func() -> void:
		value.append(default_value(rule["items"]))
		changed.emit(value)
		_build.call_deferred())

func _build_scalar() -> void:
	if rule.has("enum"):
		var picker := OptionButton.new()
		for entry in rule["enum"]:
			picker.add_item(str(entry))
		picker.select(maxi(0, rule["enum"].find(value)))
		picker.item_selected.connect(func(index: int) -> void:
			value = rule["enum"][index]
			changed.emit(value))
		add_child(picker)
	elif rule.has("const"):
		var label := Label.new()
		label.text = str(rule["const"])
		add_child(label)
	elif rule.get("type", "") == "boolean":
		var toggle := CheckBox.new()
		toggle.button_pressed = bool(value)
		toggle.text = "Enabled"
		toggle.toggled.connect(func(enabled: bool) -> void:
			value = enabled
			changed.emit(value))
		add_child(toggle)
	elif rule.get("type", "") in ["integer", "number"]:
		var number := SpinBox.new()
		number.min_value = float(rule.get("minimum", rule.get("exclusiveMinimum", -1000000)))
		number.max_value = 1000000
		number.allow_greater = true
		number.step = 1.0 if rule["type"] == "integer" else 0.01
		number.value = float(value) if value != null else 0.0
		number.value_changed.connect(func(updated: float) -> void:
			value = int(updated) if rule["type"] == "integer" else updated
			changed.emit(value))
		add_child(number)
	elif name in ["description", "flavour"]:
		var input := TextEdit.new()
		input.text = str(value) if value != null else ""
		input.custom_minimum_size.y = 85
		input.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
		input.text_changed.connect(func() -> void:
			value = input.text
			changed.emit(value))
		add_child(input)
	else:
		var input := LineEdit.new()
		input.text = str(value) if value != null else ""
		input.text_changed.connect(func(updated: String) -> void:
			value = updated
			changed.emit(value))
		add_child(input)

static func _label(key: String) -> String:
	if key == "id":
		return "ID"
	var pattern := RegEx.new()
	pattern.compile("([a-z])([A-Z])")
	return pattern.sub(key, "$1 $2", true).replace("_", " ").capitalize().replace(" Id", " ID")
