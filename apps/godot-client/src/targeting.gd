extends RefCounted
class_name Targeting

## Works out what the current selection can legally interact with.
##
## Every answer is derived from the server's legal action list — the client
## never invents a target. A selection is either a hand card or a board entity;
## from that, this reports which board slots accept a drop, which entities can
## be targeted, and which action to send once the player commits.

## Hero entity ids are "<playerId>:hero"; creatures use their instance id.
const HERO_SUFFIX := ":hero"

static func hero_entity_id(player_id: String) -> String:
	return player_id + HERO_SUFFIX

static func is_hero_entity(entity_id: String) -> bool:
	return entity_id.ends_with(HERO_SUFFIX)

## The player that owns a hero entity id, or "" when it is not a hero.
static func hero_owner(entity_id: String) -> String:
	if not is_hero_entity(entity_id):
		return ""
	return entity_id.substr(0, entity_id.length() - HERO_SUFFIX.length())

## A stable key for a battlefield slot, used to match drop targets.
static func slot_key(owner_id: String, row: String, column: int) -> String:
	return "%s/%s/%d" % [owner_id, row, column]

## Actions that originate from a hand card.
static func actions_for_card(legal_actions: Array, card_instance_id: String) -> Array:
	var out: Array = []
	for action in legal_actions:
		if typeof(action) != TYPE_DICTIONARY:
			continue
		if str(action.get("cardInstanceId", "")) == card_instance_id:
			out.append(action)
	return out

## Actions that originate from a board entity (attacks, moves, swaps).
##
## A HERO_ATTACK names no attacker: the acting side's Hero is implied. So it
## belongs to the selection when the selected entity is that side's Hero.
static func actions_for_entity(legal_actions: Array, entity_id: String) -> Array:
	var out: Array = []
	var hero_side := hero_owner(entity_id)
	for action in legal_actions:
		if typeof(action) != TYPE_DICTIONARY:
			continue
		if str(action.get("type", "")) == "HERO_ATTACK":
			if hero_side != "" and str(action.get("actorId", "")) == hero_side:
				out.append(action)
			continue
		if str(action.get("attackerId", "")) == entity_id \
				or str(action.get("creatureId", "")) == entity_id \
				or str(action.get("firstCreatureId", "")) == entity_id:
			out.append(action)
	return out

## Hero-power actions, which have no originating card or creature.
static func hero_power_actions(legal_actions: Array) -> Array:
	var out: Array = []
	for action in legal_actions:
		if typeof(action) == TYPE_DICTIONARY and str(action.get("type", "")) == "USE_HERO_POWER":
			out.append(action)
	return out

## Slot keys an action list can be dropped onto, mapped to that action.
##
## `owner_id` is the side whose battlefield the position refers to. A summon or
## a move always lands on the acting player's own battlefield.
static func slot_targets(actions: Array, owner_id: String) -> Dictionary:
	var out: Dictionary = {}
	for action in actions:
		if typeof(action) != TYPE_DICTIONARY:
			continue
		var position: Variant = action.get("position", action.get("destination", null))
		if typeof(position) != TYPE_DICTIONARY:
			continue
		var key := slot_key(
			owner_id,
			str((position as Dictionary).get("row", "")),
			int((position as Dictionary).get("column", -1))
		)
		# First match wins: a slot maps to exactly one action per selection.
		if not out.has(key):
			out[key] = action
	return out

## Entity ids an action list can target, mapped to that action.
static func entity_targets(actions: Array) -> Dictionary:
	var out: Dictionary = {}
	for action in actions:
		if typeof(action) != TYPE_DICTIONARY:
			continue
		var target := str(action.get("targetId", ""))
		if target == "":
			# A swap names its partner rather than a target.
			target = str(action.get("secondCreatureId", ""))
		if target != "" and not out.has(target):
			out[target] = action
	return out

## True when the list contains an action needing no target or position at all,
## such as a hero power with targetMode NONE or a creature summon with a fixed
## position. Used to decide whether a plain click is enough to commit.
static func untargeted_action(actions: Array) -> Variant:
	for action in actions:
		if typeof(action) != TYPE_DICTIONARY:
			continue
		var has_position := typeof(action.get("position", null)) == TYPE_DICTIONARY \
			or typeof(action.get("destination", null)) == TYPE_DICTIONARY
		var has_target := str(action.get("targetId", "")) != "" \
			or str(action.get("secondCreatureId", "")) != ""
		if not has_position and not has_target:
			return action
	return null

## Describes what the player should do next with the current selection.
static func prompt_for(actions: Array, owner_id: String) -> String:
	var slots := slot_targets(actions, owner_id)
	var entities := entity_targets(actions)
	if not slots.is_empty() and not entities.is_empty():
		return "Drop on a highlighted slot, or drag onto a highlighted target."
	if not slots.is_empty():
		return "Drop on a highlighted slot."
	if not entities.is_empty():
		return "Drag onto a highlighted target."
	if untargeted_action(actions) != null:
		return "Release to confirm."
	return "No legal play for this selection."
