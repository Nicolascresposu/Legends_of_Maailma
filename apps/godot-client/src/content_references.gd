extends RefCounted

## Where content names a card by its ID, so a card's ID can change without
## leaving anything pointing at the old one: a SUMMON's card, a starter deck's
## entries, and what a scenario's sides start with.

## Fields holding one card ID.
const ID_FIELDS := ["definitionId", "cardId", "startingWeapon"]
## Fields holding a list of card IDs.
const ID_LISTS := ["startingCards", "startingArtifacts"]

## Replaces every reference to a key of `renames` (old ID → new ID) inside
## `value`, in place, and returns how many it replaced.
static func rewrite(value: Variant, renames: Dictionary) -> int:
	var count := 0
	if value is Dictionary:
		for key in value:
			var child: Variant = value[key]
			if key in ID_FIELDS and child is String and renames.has(child):
				value[key] = renames[child]
				count += 1
			elif key in ID_LISTS and child is Array:
				for index in child.size():
					if child[index] is String and renames.has(child[index]):
						child[index] = renames[child[index]]
						count += 1
			else:
				count += rewrite(child, renames)
	elif value is Array:
		for item in value:
			count += rewrite(item, renames)
	return count
