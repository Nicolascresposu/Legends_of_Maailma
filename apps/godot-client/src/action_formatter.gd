extends RefCounted
class_name ActionFormatter

## Turns server-approved actions into readable labels.
##
## The server decides which actions are legal; this only decides how they read.

const GROUP_ORDER := ["Play a card", "Attack", "Use a Location", "Reposition", "Hero Power", "Turn"]

## JSON numbers arrive as floats; render whole numbers without a decimal point.
static func num(value: Variant) -> String:
	match typeof(value):
		TYPE_FLOAT:
			return str(int(round(value as float)))
		TYPE_INT:
			return str(value)
	return str(value)

static func position_text(position: Variant) -> String:
	if typeof(position) != TYPE_DICTIONARY:
		return "?"
	var row := str((position as Dictionary).get("row", "?")).capitalize()
	return "%s %d" % [row, int((position as Dictionary).get("column", 0))]

## Resolves an entity id to a readable name using the current match state.
static func entity_name(entity_id: String, state: Dictionary, library: CardLibrary) -> String:
	if entity_id == "":
		return "?"
	var sides: Variant = state.get("sides", {})
	if typeof(sides) == TYPE_DICTIONARY:
		for side_id in (sides as Dictionary):
			var side: Variant = (sides as Dictionary)[side_id]
			if typeof(side) != TYPE_DICTIONARY:
				continue
			# A Hero is addressed as "<playerId>:hero", not by the bare player id.
			if entity_id == Targeting.hero_entity_id(str(side_id)):
				var hero: Variant = (side as Dictionary).get("hero", {})
				var hero_name := "Hero"
				if typeof(hero) == TYPE_DICTIONARY:
					hero_name = _hero_display_name(str((hero as Dictionary).get("definitionId", "")))
				return "%s (%s)" % [hero_name, side_id]
			var creatures: Variant = (side as Dictionary).get("creatures", {})
			if typeof(creatures) == TYPE_DICTIONARY and (creatures as Dictionary).has(entity_id):
				var creature: Dictionary = (creatures as Dictionary)[entity_id]
				var definition_id := str(creature.get("definitionId", entity_id))
				var display := library.card_name(definition_id) if library != null else definition_id
				return "%s at %s" % [display, position_text(creature.get("position", {}))]
			var locations: Variant = (side as Dictionary).get("locations", {})
			if typeof(locations) == TYPE_DICTIONARY and (locations as Dictionary).has(entity_id):
				var location: Dictionary = (locations as Dictionary)[entity_id]
				var location_definition := str(location.get("definitionId", entity_id))
				var location_name := library.card_name(location_definition) if library != null else location_definition
				return "%s at %s" % [location_name, position_text(location.get("position", {}))]
	return entity_id

static func _hero_display_name(definition_id: String) -> String:
	match definition_id:
		"healer": return "The Mender"
		"striker": return "The Striker"
	return definition_id if definition_id != "" else "Hero"

static func card_name_for_instance(
	card_instance_id: String, state: Dictionary, player_id: String, library: CardLibrary
) -> String:
	var sides: Variant = state.get("sides", {})
	if typeof(sides) == TYPE_DICTIONARY and (sides as Dictionary).has(player_id):
		var side: Variant = (sides as Dictionary)[player_id]
		if typeof(side) == TYPE_DICTIONARY:
			var hand: Variant = (side as Dictionary).get("hand", [])
			if typeof(hand) == TYPE_ARRAY:
				for card in (hand as Array):
					if typeof(card) == TYPE_DICTIONARY and str(card.get("instanceId", "")) == card_instance_id:
						var definition_id := str(card.get("definitionId", ""))
						return library.card_name(definition_id) if library != null else definition_id
	return card_instance_id

## Which grouping header an action belongs under.
static func group_of(action: Dictionary) -> String:
	match str(action.get("type", "")):
		"PLAY_CARD": return "Play a card"
		"ATTACK", "HERO_ATTACK": return "Attack"
		"ACTIVATE_LOCATION": return "Use a Location"
		"MOVE_CREATURE", "SWAP_CREATURES": return "Reposition"
		"USE_HERO_POWER": return "Hero Power"
		"END_TURN": return "Turn"
	return "Other"

static func label_for(action: Dictionary, state: Dictionary, player_id: String, library: CardLibrary) -> String:
	match str(action.get("type", "")):
		"PLAY_CARD":
			var card := card_name_for_instance(
				str(action.get("cardInstanceId", "")), state, player_id, library
			)
			if action.has("position"):
				return "%s → %s" % [card, position_text(action.get("position"))]
			if action.has("targetId"):
				return "%s → %s" % [card, entity_name(str(action.get("targetId", "")), state, library)]
			return card
		"ATTACK":
			return "%s → %s" % [
				entity_name(str(action.get("attackerId", "")), state, library),
				entity_name(str(action.get("targetId", "")), state, library),
			]
		"HERO_ATTACK":
			return "Your Hero → %s" % entity_name(
				str(action.get("targetId", "")), state, library
			)
		"MOVE_CREATURE":
			return "%s → %s" % [
				entity_name(str(action.get("creatureId", "")), state, library),
				position_text(action.get("destination")),
			]
		"SWAP_CREATURES":
			return "%s ↔ %s" % [
				entity_name(str(action.get("firstCreatureId", "")), state, library),
				entity_name(str(action.get("secondCreatureId", "")), state, library),
			]
		"USE_HERO_POWER":
			if action.has("targetId"):
				return "Use Hero Power → " + entity_name(str(action.get("targetId", "")), state, library)
			return "Use Hero Power"
		"ACTIVATE_LOCATION":
			var location := entity_name(str(action.get("locationId", "")), state, library)
			if action.has("targetId"):
				return "%s → %s" % [location, entity_name(str(action.get("targetId", "")), state, library)]
			return location
		"END_TURN":
			return "End Turn"
	return JSON.stringify(action)

## Events that are bookkeeping, not news: a resolved marker whose damage lines
## already told the story. They format to "" and the feed skips them.
##
## Listed rather than left implicit so an empty line can be told apart from a
## missing one — any other event that formats to "" is a gap in this file.
const SILENT_EVENTS := ["HERO_ATTACK_RESOLVED"]

static func is_silent(kind: String) -> bool:
	return SILENT_EVENTS.has(kind)

## Human-readable one-liners for the event feed.
static func event_line(event: Dictionary, state: Dictionary, library: CardLibrary) -> String:
	var kind := str(event.get("type", ""))
	var amount := int(event.get("amount", 0))
	var source := entity_name(str(event.get("sourceId", "")), state, library)
	var target := entity_name(str(event.get("targetId", "")), state, library)
	match kind:
		"TURN_STARTED":
			# The event carries the turn number; state may not have caught up yet.
			var turn: Variant = event.get("amount", state.get("turn", "?"))
			return "— Turn %s begins for %s —" % [num(turn), str(event.get("actorId", ""))]
		"TURN_ENDED":
			return "%s ends their turn." % str(event.get("actorId", ""))
		"CARD_DRAWN":
			return "%s draws a card." % str(event.get("actorId", ""))
		"CARD_PLAYED":
			return "%s plays %s." % [
				str(event.get("actorId", "")), library.card_name(str(event.get("cardDefinitionId", "")))
			]
		"CREATURE_SUMMONED":
			return "%s arrives at %s." % [
				library.card_name(str(event.get("cardDefinitionId", ""))),
				position_text(event.get("position", {})),
			]
		"CREATURE_MOVED":
			return "%s moves to %s." % [source, position_text(event.get("to", {}))]
		"CREATURE_SWAPPED":
			return "%s swaps with %s." % [source, target]
		"ATTACK_STARTED":
			return "%s attacks %s." % [source, target]
		"DAMAGE_DEALT":
			return "%s takes %d damage." % [target, amount]
		"DAMAGE_PREVENTED":
			return "Damage to %s is prevented." % target
		"HEALING_RECEIVED":
			return "%s heals %d." % [target, amount]
		"CREATURE_DIED":
			# The creature is already gone from state, so name it from the event.
			var dead := str(event.get("cardDefinitionId", ""))
			var dead_name := library.card_name(dead) if dead != "" else source
			return "%s is destroyed at %s." % [dead_name, position_text(event.get("position", {}))]
		"HERO_POWER_USED":
			return "%s uses their Hero Power." % str(event.get("actorId", ""))
		"WEAPON_EQUIPPED":
			return "%s equips %s." % [
				str(event.get("actorId", "")),
				library.card_name(str(event.get("cardDefinitionId", ""))),
			]
		"WEAPON_REPLACED":
			return "%s is put away." % library.card_name(str(event.get("cardDefinitionId", "")))
		"WEAPON_DURABILITY_CHANGED":
			# `amount` is a delta, and losing Durability is the ordinary case.
			if amount < 0:
				return "%s loses %d Durability." % [
					library.card_name(str(event.get("cardDefinitionId", ""))), -amount
				]
			return "%s gains %d Durability." % [
				library.card_name(str(event.get("cardDefinitionId", ""))), amount
			]
		"WEAPON_BROKEN":
			return "%s breaks." % library.card_name(str(event.get("cardDefinitionId", "")))
		"WEAPON_DESTROYED":
			return "%s is destroyed." % library.card_name(str(event.get("cardDefinitionId", "")))
		"LOCATION_PLACED":
			return "%s is built at %s." % [
				library.card_name(str(event.get("cardDefinitionId", ""))),
				position_text(event.get("position", {})),
			]
		"LOCATION_ACTIVATED":
			var used := library.card_name(str(event.get("cardDefinitionId", "")))
			if event.has("targetId"):
				return "%s is used on %s." % [used, target]
			return "%s is used." % used
		"LOCATION_DURABILITY_CHANGED":
			# `amount` is a delta, and losing Durability is the ordinary case.
			if amount < 0:
				return "%s loses %d Durability." % [
					library.card_name(str(event.get("cardDefinitionId", ""))), -amount
				]
			return "%s gains %d Durability." % [
				library.card_name(str(event.get("cardDefinitionId", ""))), amount
			]
		"LOCATION_DURATION_CHANGED":
			# `amount` is a delta: the hourglass running down a turn.
			return "Time runs short for %s." % library.card_name(str(event.get("cardDefinitionId", "")))
		"LOCATION_REMOVED":
			# The Location is already gone from state, so name it from the event.
			var gone := library.card_name(str(event.get("cardDefinitionId", "")))
			match str(event.get("reason", "")):
				"SPENT": return "%s crumbles." % gone
				"EXPIRED": return "%s's time runs out." % gone
			return "%s is destroyed." % gone
		"HERO_ATTACK_STARTED":
			return "%s attacks %s with %s." % [
				source,
				target,
				library.card_name(str(event.get("cardDefinitionId", ""))),
			]
		"HERO_ATTACK_RESOLVED":
			# Silent: see SILENT_EVENTS.
			return ""
		"ADMIN_EDIT":
			# Said plainly, so a tester reading the log knows what was not play.
			if str(event.get("reason", "")) == "ADD_CARD_TO_HAND":
				return "[Admin] %s is put into %s's hand." % [
					library.card_name(str(event.get("cardDefinitionId", ""))),
					str(event.get("actorId", "")),
				]
			return "[Admin] %s's stats are set." % target
		"STATUS_APPLIED":
			return "%s gains a status." % target
		"STATUS_REMOVED":
			return "%s loses a status." % target
		"TAIKA_CHANGED":
			# `amount` is a delta, not a total.
			if amount < 0:
				return "%s spends %d Taika." % [str(event.get("actorId", "")), -amount]
			return "%s gains %d Taika." % [str(event.get("actorId", "")), amount]
		"ARTIFACT_PLAYED":
			return "%s plays an Artifact." % str(event.get("actorId", ""))
		"ARTIFACT_DAMAGED":
			return "An Artifact loses durability."
		"ARTIFACT_DESTROYED":
			return "An Artifact is destroyed."
		"MATCH_STARTED":
			return "The match begins."
		"MATCH_ENDED":
			var winner := str(event.get("winnerId", ""))
			return "Match over. Winner: %s" % (winner if winner != "" else "draw")
	return kind.capitalize().replace("_", " ")
