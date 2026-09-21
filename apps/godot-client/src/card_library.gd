extends RefCounted
class_name CardLibrary

## Client-side cache of the server's card definitions.
##
## The server owns card data; the client fetches it once and uses it purely for
## presentation (names, costs, keywords, rules text). Nothing here affects rules.

signal loaded()

var _cards: Dictionary = {}
var _is_loaded := false

func is_loaded() -> bool:
	return _is_loaded

## Stores the `/api/cards` payload, keyed by definition id.
func ingest(payload: Variant) -> void:
	if typeof(payload) != TYPE_ARRAY:
		return
	_cards.clear()
	for entry in payload:
		if typeof(entry) == TYPE_DICTIONARY and entry.has("id"):
			_cards[str(entry["id"])] = entry
	_is_loaded = true
	loaded.emit()

func has(definition_id: String) -> bool:
	return _cards.has(definition_id)

func get_card(definition_id: String) -> Dictionary:
	return _cards.get(definition_id, {})

## Display name, falling back to the raw id so unknown cards stay debuggable.
func card_name(definition_id: String) -> String:
	var card := get_card(definition_id)
	return str(card.get("name", definition_id))

func cost(definition_id: String) -> int:
	return int(get_card(definition_id).get("cost", 0))

func card_type(definition_id: String) -> String:
	return str(get_card(definition_id).get("type", ""))

func text(definition_id: String) -> String:
	return str(get_card(definition_id).get("text", ""))

func keywords(definition_id: String) -> Array:
	var card := get_card(definition_id)
	var list: Variant = card.get("keywords", [])
	return list if typeof(list) == TYPE_ARRAY else []

func tags(definition_id: String) -> Array:
	var card := get_card(definition_id)
	var list: Variant = card.get("tags", [])
	return list if typeof(list) == TYPE_ARRAY else []

## Base stats, used for hand cards that have no board instance yet.
func base_attack(definition_id: String) -> int:
	return int(get_card(definition_id).get("attack", 0))

func base_health(definition_id: String) -> int:
	return int(get_card(definition_id).get("health", 0))

## A multi-line tooltip describing a card in full.
func tooltip(definition_id: String) -> String:
	if not has(definition_id):
		return definition_id
	var card := get_card(definition_id)
	var lines: Array[String] = []
	lines.append("%s  (%d Taika)" % [card_name(definition_id), cost(definition_id)])
	var kind := card_type(definition_id)
	if kind == "CREATURE":
		lines.append("Creature — %d/%d" % [base_attack(definition_id), base_health(definition_id)])
	elif kind != "":
		lines.append(kind.capitalize())
	var tag_list := tags(definition_id)
	if not tag_list.is_empty():
		lines.append("Tags: " + ", ".join(tag_list))
	var keyword_list := keywords(definition_id)
	if not keyword_list.is_empty():
		lines.append("Keywords: " + ", ".join(keyword_list))
	var rules := text(definition_id)
	if rules != "":
		lines.append("")
		lines.append(rules)
	return "\n".join(lines)
