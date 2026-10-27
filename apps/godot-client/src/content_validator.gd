extends RefCounted

## Evaluates the JSON Schema vocabulary used by the shared content schema.
## The generated schema is packaged as GDScript, including in desktop exports.
const Schema := preload("res://src/content_schema.gd")
const Library := preload("res://src/card_library.gd")
const FILES := ["expansion", "cards", "packs"]
const SUPPORTED := ["$ref", "type", "const", "enum", "oneOf", "discriminator", "properties", "required", "additionalProperties", "minProperties", "items", "minItems", "uniqueItems", "pattern", "minimum", "exclusiveMinimum", "title", "description", "$comment"]

static func definition(key: String) -> Dictionary:
	return Schema.SCHEMA["definitions"][key]

static func resolve_schema(rule: Dictionary) -> Dictionary:
	if rule.has("$ref"):
		return definition(str(rule["$ref"]).get_slice("/", 2))
	return rule

static func validate_shape(data: Dictionary) -> Array[String]:
	var errors: Array[String] = []
	for key in FILES:
		check(data.get(key), definition(key), key + ".json", errors)
	return errors

static func check(value: Variant, unresolved: Dictionary, path: String, errors: Array[String]) -> void:
	var rule := resolve_schema(unresolved)
	for keyword in rule:
		if not SUPPORTED.has(keyword):
			errors.append("%s: this creator does not support schema keyword %s; update the client" % [path, keyword])
			return
	if rule.has("type") and not _matches(value, str(rule["type"])):
		errors.append("%s: must be %s" % [path, rule["type"]])
		return
	if rule.has("const") and value != rule["const"]:
		errors.append("%s: must be %s" % [path, str(rule["const"])])
	if rule.has("enum") and not rule["enum"].has(value):
		errors.append("%s: choose one of %s" % [path, ", ".join(rule["enum"])])
	if rule.has("oneOf"):
		var tag := str((rule.get("discriminator", {}) as Dictionary).get("propertyName", "type"))
		var selected := str(value.get(tag, "")) if value is Dictionary else ""
		for variant: Dictionary in rule["oneOf"]:
			if str(variant.get("properties", {}).get(tag, {}).get("const", "")) == selected:
				check(value, variant, path, errors)
				return
		errors.append("%s.%s: unsupported or missing type %s" % [path, tag, selected])
		return
	if value is Dictionary:
		var properties: Dictionary = rule.get("properties", {})
		for key in rule.get("required", []):
			if not value.has(key):
				errors.append("%s.%s: required" % [path, key])
		if value.size() < int(rule.get("minProperties", 0)):
			errors.append("%s: needs at least %d value(s)" % [path, rule["minProperties"]])
		for key in value:
			if properties.has(key):
				check(value[key], properties[key], path + "." + str(key), errors)
			elif rule.get("additionalProperties", true) == false:
				errors.append("%s.%s: unknown field" % [path, key])
	elif value is Array:
		if value.size() < int(rule.get("minItems", 0)):
			errors.append("%s: needs at least %d item(s)" % [path, rule["minItems"]])
		for index in value.size():
			if rule.has("items"):
				check(value[index], rule["items"], "%s[%d]" % [path, index], errors)
			if rule.get("uniqueItems", false) and value.find(value[index]) != index:
				errors.append("%s[%d]: duplicate value" % [path, index])
	elif value is String:
		if rule.has("pattern"):
			var regex := RegEx.new()
			regex.compile(str(rule["pattern"]))
			if regex.search(value) == null:
				errors.append("%s: cannot be blank" % path)
	elif typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT:
		if rule.has("minimum") and value < rule["minimum"]:
			errors.append("%s: must be at least %s" % [path, rule["minimum"]])
		if rule.has("exclusiveMinimum") and value <= rule["exclusiveMinimum"]:
			errors.append("%s: must be greater than %s" % [path, rule["exclusiveMinimum"]])

static func _matches(value: Variant, kind: String) -> bool:
	match kind:
		"object": return value is Dictionary
		"array": return value is Array
		"string": return value is String
		"boolean": return typeof(value) == TYPE_BOOL
		"integer": return typeof(value) == TYPE_INT or (typeof(value) == TYPE_FLOAT and is_finite(value) and floor(value) == value)
		"number": return (typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT) and is_finite(float(value))
	return false

## Context contains sibling expansions, never cards from the running server.
static func validate(data: Dictionary, context: Array = []) -> Array[String]:
	var errors := validate_shape(data)
	if not errors.is_empty():
		return errors
	var documents: Array = [{"data": data, "prefix": ""}]
	for entry: Dictionary in context:
		var problems := validate_shape(entry["data"])
		if not problems.is_empty():
			for problem in problems:
				errors.append(str(entry.get("folder", "Other expansion")) + "/" + problem)
		else:
			documents.append({"data": entry["data"], "prefix": str(entry.get("folder", "Other expansion")) + "/"})
	var seen := {"expansion": {}, "cards": {}, "packs": {}}
	var cards_by_id: Dictionary = {}
	for document: Dictionary in documents:
		var draft: Dictionary = document["data"]
		var prefix: String = document["prefix"]
		for kind in FILES:
			var entries: Array = [draft[kind]] if kind == "expansion" else draft[kind]
			for index in entries.size():
				var item: Dictionary = entries[index]
				var path: String = prefix + kind + ".json" + ("[%d]" % index if kind != "expansion" else "")
				var id: String = item["id"]
				if seen[kind].has(id):
					errors.append("%s.id: duplicate id %s (also %s)" % [path, id, seen[kind][id]])
				seen[kind][id] = path
				if kind != "expansion" and item["expansionId"] != draft["expansion"]["id"]:
					errors.append("%s.expansionId: must be %s" % [path, draft["expansion"]["id"]])
				if kind == "cards":
					cards_by_id[id] = item
	for document: Dictionary in documents:
		var draft: Dictionary = document["data"]
		var prefix: String = document["prefix"]
		for index in draft["cards"].size():
			var card: Dictionary = draft["cards"][index]
			var path := "%scards.json[%d]" % [prefix, index]
			if card.has("classId") and not Schema.CLASSES.has(card["classId"]):
				errors.append("%s.classId: unknown class %s" % [path, card["classId"]])
			for field in ["description", "flavour"]:
				if card.has(field):
					_markup_errors(str(card[field]), path + "." + field, errors)
			var keywords: Array = card.get("keywords", []).duplicate()
			if card.get("range", "") == "RANGED":
				keywords.append("RANGED")
			var bold := ""
			for span: Dictionary in Library.description_spans(card["description"]):
				if span["bold"]:
					bold += str(span["text"]).to_lower() + " "
			for keyword: String in keywords:
				var label := keyword.replace("_", " ").to_lower()
				if not bold.contains(label):
					errors.append("%s.description: print %s in **bold**" % [path, label.capitalize()])
			var effects: Array = []
			for entry: Dictionary in card["effects"]:
				effects.append(entry if card["type"] == "ACTION" else entry["effect"])
			if card["type"] == "LOCATION":
				_location_errors(card, path, errors)
				effects.append_array(card.get("activation", {}).get("effects", []))
			for effect: Dictionary in effects:
				if effect["type"] == "SUMMON" and cards_by_id.get(effect["definitionId"], {}).get("type", "") != "CREATURE":
					errors.append("%s.effects: SUMMON must reference an existing Creature (%s)" % [path, effect["definitionId"]])
		for index in draft["packs"].size():
			var pack: Dictionary = draft["packs"][index]
			var total := 0
			for slot: Dictionary in pack["rarityRules"]["slots"]:
				total += int(slot["count"])
			if total != int(pack["cardCount"]):
				errors.append("%spacks.json[%d].cardCount: slots total %d, expected %d" % [prefix, index, total, pack["cardCount"]])
	return errors

## The checks `validateLocationDefinition` makes on the server: the schema
## takes each field alone, these take them together.
static func _location_errors(card: Dictionary, path: String, errors: Array[String]) -> void:
	var durable := card.has("durability")
	var activated := card.has("activation")
	if not durable and not card.has("duration"):
		errors.append("%s: a Location needs a durability, a duration or both" % path)
	if durable and not activated:
		errors.append("%s.activation: a Location with durability needs an activation" % path)
	if activated and not durable:
		errors.append("%s.durability: a Location with an activation needs durability to spend" % path)
	if activated and card["activation"].get("targetMode", "NONE") == "NONE":
		for effect: Dictionary in card["activation"].get("effects", []):
			if effect.get("target", "") == "PLAY_TARGET":
				errors.append("%s.activation.targetMode: an activation aimed at PLAY_TARGET needs a targetMode" % path)
				break
	for entry: Dictionary in card["effects"]:
		if entry.get("trigger", "") not in ["TURN_STARTED", "TURN_ENDED"]:
			errors.append("%s.effects: a Location's effects trigger on TURN_STARTED or TURN_ENDED" % path)
			break

static func _markup_errors(text: String, path: String, errors: Array[String]) -> void:
	var bold := false
	var italic := false
	var index := 0
	while index < text.length():
		if text[index] == "\\" and index + 1 < text.length():
			index += 2
			continue
		if text[index] == "*":
			if index + 1 < text.length() and text[index + 1] == "*":
				bold = not bold
				index += 2
				continue
			italic = not italic
		index += 1
	if bold or italic:
		errors.append("%s: close the bold/italic markup" % path)
