extends RefCounted
class_name CardLibrary

## Client-side cache of the server's card definitions.
##
## The server owns card data; the client fetches it once and uses it purely for
## presentation (names, costs, keywords, rules text). Nothing here affects rules.

signal loaded()

## What each keyword does, in the player's words.
##
## The server sends keywords as bare identifiers — "GUARD", "SWIFT" — because
## the rules are the engine's, not the client's. Spelling them out is
## presentation, so the glossary lives here. It describes the engine's actual
## behaviour; a keyword with no entry simply shows its name.
const KEYWORD_TEXT := {
	"ARRIVAL": "Triggers an effect when this Creature enters play.",
	"LAST_BREATH": "Triggers an effect when this Creature dies.",
	"GUARD": "Protects your Hero and adjacent Creatures from attack.",
	"SWIFT": "Can attack Creatures the turn it is summoned, but not the Hero.",
	"CHARGE": "Can attack and move the turn it is summoned.",
	"RANGED": "Can attack from the back row, and past the Creature in front.",
	"WARD": "Absorbs the next damage this Creature would take.",
	"HIDDEN": "Cannot be targeted directly until it acts.",
	"LIFESTEAL": "Damage this Creature deals heals your Hero.",
}

## Weapon keywords, explained the same way Creature keywords are.
##
## Melee is the default and goes unexplained on the card; Ranged changes how a
## Weapon plays, so it gets a line of its own.
const WEAPON_KEYWORD_TEXT := {
	"RANGED": "Hero attacks with this Weapon can target Creatures in either row and ignore front-row shielding. Ranged attacks against Creatures do not receive retaliation. Guard still applies.",
}

## The glossary line for a keyword: its name, then what it does.
##
## RANGED appears in both glossaries and means different things: on a Creature
## it is about where the Creature may stand, on a Weapon about what the Hero
## may hit and whether it is hit back. The caller says which it is asking
## about rather than the two silently overriding one another.
static func keyword_line(keyword: String, on_weapon: bool = false) -> String:
	var key := keyword.to_upper()
	if on_weapon and WEAPON_KEYWORD_TEXT.has(key):
		return "%s — %s" % [keyword, WEAPON_KEYWORD_TEXT[key]]
	if not KEYWORD_TEXT.has(key):
		return keyword
	return "%s — %s" % [keyword, KEYWORD_TEXT[key]]

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

func base_durability(definition_id: String) -> int:
	return int(get_card(definition_id).get("durability", 0))

## "MELEE" or "RANGED" for a Weapon, "" for anything else.
##
## Read straight from the server's definition: the client never guesses reach
## from a card's name or tags, for the same reason the engine does not.
func weapon_range(definition_id: String) -> String:
	return str(get_card(definition_id).get("range", ""))

func is_ranged_weapon(definition_id: String) -> bool:
	return weapon_range(definition_id) == "RANGED"

## The type line under a Weapon's name: "Weapon" or "Weapon — Ranged".
func weapon_type_line(definition_id: String) -> String:
	if is_ranged_weapon(definition_id):
		return "Weapon — Ranged"
	return "Weapon"

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
	elif kind == "WEAPON":
		lines.append(weapon_type_line(definition_id))
		lines.append("%d Attack · %d Durability" % [
			base_attack(definition_id), base_durability(definition_id)
		])
		if is_ranged_weapon(definition_id):
			lines.append("")
			lines.append(keyword_line("RANGED", true))
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
