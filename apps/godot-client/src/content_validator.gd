extends RefCounted

## Evaluates the JSON Schema vocabulary used by the shared content schema.
## The generated schema is packaged as GDScript, including in desktop exports.
const Schema := preload("res://src/content_schema.gd")
const Library := preload("res://src/card_library.gd")
const FILES := ["expansion", "cards", "packs"]
## Files a folder may leave out; a missing one holds nothing.
const OPTIONAL := ["starterDecks", "scenarios"]
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
	for key in OPTIONAL:
		check(data.get(key, []), definition(key), key + ".json", errors)
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
	var seen := {"expansion": {}, "cards": {}, "packs": {}, "starterDecks": {}, "scenarios": {}}
	var cards_by_id: Dictionary = {}
	# Every tag some card carries, so a rule naming one nothing carries — a typo,
	# almost always — is caught rather than matching nothing in play.
	var carried: Dictionary = {}
	for document: Dictionary in documents:
		var draft: Dictionary = document["data"]
		var prefix: String = document["prefix"]
		for kind in FILES + OPTIONAL:
			var entries: Array = [draft[kind]] if kind == "expansion" else draft.get(kind, [])
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
					for tag in item.get("tags", []):
						carried[tag] = true
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
			_tag_errors(card, path, carried, errors)
		for index in draft["packs"].size():
			var pack: Dictionary = draft["packs"][index]
			var total := 0
			for slot: Dictionary in pack["rarityRules"]["slots"]:
				total += int(slot["count"])
			if total != int(pack["cardCount"]):
				errors.append("%spacks.json[%d].cardCount: slots total %d, expected %d" % [prefix, index, total, pack["cardCount"]])
		var decks: Array = draft.get("starterDecks", [])
		for index in decks.size():
			_starter_deck_errors(decks[index], "%sstarterDecks.json[%d]" % [prefix, index], cards_by_id, errors)
		var scenarios: Array = draft.get("scenarios", [])
		for index in scenarios.size():
			_scenario_errors(scenarios[index], "%sscenarios.json[%d]" % [prefix, index], cards_by_id, errors)
	# Whether every class has its starter deck is a question about the whole
	# catalogue, so it is only asked when the other expansions are here too.
	if not context.is_empty():
		for class_id: String in Schema.CLASSES:
			var found: Array = []
			for document: Dictionary in documents:
				for deck: Dictionary in document["data"].get("starterDecks", []):
					if deck["classId"] == class_id:
						found.append(deck["id"])
			if found.is_empty():
				errors.append("class %s: has no starter deck" % class_id)
			elif found.size() > 1:
				errors.append("class %s: has %d starter decks (%s)" % [class_id, found.size(), ", ".join(found)])
	return errors

## The checks `validateStarterDecks` makes on the server, deck by deck.
static func _starter_deck_errors(deck: Dictionary, path: String, cards_by_id: Dictionary, errors: Array[String]) -> void:
	var class_id: String = deck["classId"]
	if not Schema.CLASSES.has(class_id):
		errors.append("%s.classId: unknown class %s" % [path, class_id])
	var listed: Dictionary = {}
	for entry: Dictionary in deck["cards"]:
		var card_id: String = entry["cardId"]
		if listed.has(card_id):
			errors.append("%s.cards: lists %s more than once" % [path, card_id])
		listed[card_id] = true
		if not cards_by_id.has(card_id):
			errors.append("%s.cards: unknown card %s" % [path, card_id])
			continue
		var card: Dictionary = cards_by_id[card_id]
		if not card.get("collectible", false):
			errors.append("%s.cards: %s is not collectible" % [path, card_id])
		if card.has("classId") and card["classId"] != class_id:
			errors.append("%s.cards: %s is a %s card, not %s" % [path, card_id, card["classId"], class_id])
		if card.get("rarity", "") == "LEGENDARY" and int(entry["copies"]) > 1:
			errors.append("%s.cards: %s is Legendary, so the deck may hold only one" % [path, card_id])

const TYPE_NAMES := {"CREATURE": "a Creature", "ACTION": "an Action", "WEAPON": "a Weapon", "ARTIFACT": "an Artifact", "LOCATION": "a Location"}

## The checks `validateScenarios` makes on the server: the Heroes, and the
## cards each side starts with, must exist and be of the right type.
static func _scenario_errors(scenario: Dictionary, path: String, cards_by_id: Dictionary, errors: Array[String]) -> void:
	for side_name: String in ["sideA", "sideB"]:
		var side: Dictionary = scenario[side_name]
		var where := path + "." + side_name
		if not Schema.HEROES.has(side["heroDefinitionId"]):
			errors.append("%s.heroDefinitionId: unknown hero %s" % [where, side["heroDefinitionId"]])
		var expected: Array = []
		for card_id in side.get("startingCards", []):
			expected.append([card_id, ""])
		for placed: Dictionary in side.get("startingCreatures", []):
			expected.append([placed["definitionId"], "CREATURE"])
		for placed: Dictionary in side.get("startingLocations", []):
			expected.append([placed["definitionId"], "LOCATION"])
		for card_id in side.get("startingArtifacts", []):
			expected.append([card_id, "ARTIFACT"])
		if side.has("startingWeapon"):
			expected.append([side["startingWeapon"], "WEAPON"])
		for pair: Array in expected:
			if not cards_by_id.has(pair[0]):
				errors.append("%s: unknown card %s" % [where, pair[0]])
			elif pair[1] != "" and cards_by_id[pair[0]]["type"] != pair[1]:
				errors.append("%s: %s must be %s" % [where, pair[0], TYPE_NAMES[pair[1]]])

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
		if entry.get("trigger", "") not in LOCATION_TRIGGERS:
			errors.append("%s.effects: a Location's effects trigger on %s" % [path, " or ".join(LOCATION_TRIGGERS)])
			break

const LOCATION_TRIGGERS := ["TURN_STARTED", "TURN_ENDED", "FRIENDLY_CREATURE_SUMMONED", "FRIENDLY_CREATURE_DIED"]
const CREATURE_TRIGGERS := ["FRIENDLY_CREATURE_SUMMONED", "FRIENDLY_CREATURE_DIED"]
const CREATURELESS_TARGETS := ["OWNER_HERO", "ENEMY_HERO", "FRIENDLY_WEAPON", "ENEMY_WEAPON"]

## The checks `validateTagRules` and the carried-tag check make on the server.
static func _tag_errors(card: Dictionary, path: String, carried: Dictionary, errors: Array[String]) -> void:
	var tags: Array = []
	# Each effect with the trigger it answers, "" for an Action's or an activation's.
	var aimed: Array = []
	for entry: Dictionary in card["effects"]:
		if card["type"] == "ACTION":
			aimed.append([entry, ""])
		else:
			aimed.append([entry["effect"], str(entry["trigger"])])
			if entry.has("tag"):
				tags.append(entry["tag"])
				if entry["trigger"] not in CREATURE_TRIGGERS:
					errors.append("%s.effects: a trigger's tag only filters %s" % [path, " or ".join(CREATURE_TRIGGERS)])
	for effect: Dictionary in card.get("activation", {}).get("effects", []):
		aimed.append([effect, ""])
	for pair: Array in aimed:
		var effect: Dictionary = pair[0]
		var target := str(effect.get("target", ""))
		if effect.has("tag"):
			tags.append(effect["tag"])
			if target in CREATURELESS_TARGETS:
				errors.append("%s.effects: tag %s cannot narrow %s, which is never a Creature" % [path, effect["tag"], target])
		if effect.get("condition", {}).has("tag"):
			tags.append(effect["condition"]["tag"])
		if target == "TRIGGERING_CREATURE" and pair[1] not in CREATURE_TRIGGERS:
			errors.append("%s.effects: TRIGGERING_CREATURE needs a %s trigger" % [path, " or ".join(CREATURE_TRIGGERS)])
	for holder: Dictionary in [card, card.get("activation", {})]:
		if holder.has("targetTag"):
			tags.append(holder["targetTag"])
			if holder.get("targetMode", "NONE") == "NONE":
				errors.append("%s.targetTag: needs a targetMode other than NONE" % path)
	for aura: Dictionary in card.get("auras", []):
		if aura.has("tag"):
			tags.append(aura["tag"])
		if aura["type"] == "COST_AURA" and int(aura["amount"]) == 0:
			errors.append("%s.auras: a COST_AURA must change the cost, but its amount is 0" % path)
		if aura["type"] == "STAT_AURA" and int(aura["attack"]) == 0 and int(aura["health"]) == 0:
			errors.append("%s.auras: a STAT_AURA must give some attack or health" % path)
	for tag in tags:
		if not carried.has(tag):
			errors.append("%s: no card carries tag %s" % [path, tag])

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
