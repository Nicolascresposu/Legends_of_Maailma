extends RefCounted
class_name CardLibrary

## Client-side cache of the server's card definitions.
##
## The server owns card data; the client fetches it once and uses it purely for
## presentation (names, costs, keywords, descriptions). Nothing here affects rules.

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

## The card's description exactly as the server sent it, markup included.
func description(definition_id: String) -> String:
	return str(get_card(definition_id).get("description", ""))

## The description as BBCode, for a RichTextLabel.
func description_bbcode(definition_id: String) -> String:
	return markup_to_bbcode(description(definition_id))

## The description without markup, for tooltips and plain Labels.
func description_plain(definition_id: String) -> String:
	return markup_to_plain(description(definition_id))

## The card's flavour text, markup included; "" for a card with none.
##
## Kept apart from the description on the server so that every word of a
## description is a rule, and the client can style story text as story.
func flavour(definition_id: String) -> String:
	return str(get_card(definition_id).get("flavour", ""))

## Flavour as BBCode, set in italics as a whole the way flavour is printed.
func flavour_bbcode(definition_id: String) -> String:
	var markup := flavour(definition_id)
	if markup.strip_edges() == "":
		return ""
	return "[i]%s[/i]" % markup_to_bbcode(markup)

func flavour_plain(definition_id: String) -> String:
	return markup_to_plain(flavour(definition_id))

## Splits description markup into runs of one emphasis each.
##
## Mirrors `parseDescription` in the card-definitions package, which validates
## every card at load: `**` toggles bold, `*` toggles italic, and a backslash
## makes the next character literal. Each run is
## `{"text": String, "bold": bool, "italic": bool}`.
static func description_spans(markup: String) -> Array:
	var spans: Array = []
	var bold := false
	var italic := false
	var run := ""
	var index := 0
	while index < markup.length():
		var character := markup[index]
		if character == "\\" and index + 1 < markup.length():
			run += markup[index + 1]
			index += 2
			continue
		if character != "*":
			run += character
			index += 1
			continue
		if run != "":
			spans.append({"text": run, "bold": bold, "italic": italic})
			run = ""
		if index + 1 < markup.length() and markup[index + 1] == "*":
			bold = not bold
			index += 2
		else:
			italic = not italic
			index += 1
	if run != "":
		spans.append({"text": run, "bold": bold, "italic": italic})
	return spans

## Description markup as BBCode.
##
## Each run opens and closes its own tags, so emphasis that overlaps in the
## markup still nests correctly here. A literal `[` is escaped so card text
## can never be read as a BBCode tag.
static func markup_to_bbcode(markup: String) -> String:
	var out := ""
	for span in description_spans(markup):
		var piece := str(span["text"]).replace("[", "[lb]")
		if span["italic"]:
			piece = "[i]%s[/i]" % piece
		if span["bold"]:
			piece = "[b]%s[/b]" % piece
		out += piece
	return out

## Description markup with the markup removed.
static func markup_to_plain(markup: String) -> String:
	var out := ""
	for span in description_spans(markup):
		out += str(span["text"])
	return out

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
	# Built-in tooltips cannot style text, so the description loses its bold
	# and italic here; the hover reveal is where it is shown formatted.
	var rules := description_plain(definition_id)
	if rules != "":
		lines.append("")
		lines.append(rules)
	var story := flavour_plain(definition_id)
	if story != "":
		lines.append("")
		lines.append(story)
	return "\n".join(lines)
