extends SceneTree

## Checks the client's Weapon presentation and targeting, without a server.
##
##   godot --path apps/godot-client --headless --script src/weapon_test.gd
##
## Everything here is pure presentation logic fed a hand-built payload, so it
## needs neither a running match nor a laid-out window. What it must prove is
## that the client reads Weapon rules from the server's data rather than
## inventing them: reach comes from `range`, never from a name or a tag, and a
## Hero only becomes an attacker when the server has offered a HERO_ATTACK.

var failures: Array[String] = []

const CARD_PAYLOAD := [
	{
		"id": "iron_sword",
		"name": "Iron Sword",
		"type": "WEAPON",
		"cost": 2,
		"attack": 2,
		"durability": 2,
		"range": "MELEE",
		"tags": ["SWORD"],
		"text": "",
	},
	{
		"id": "hunting_bow",
		"name": "Hunting Bow",
		"type": "WEAPON",
		"cost": 3,
		"attack": 2,
		"durability": 2,
		"range": "RANGED",
		"tags": ["BOW"],
		"text": "Ranged",
	},
	{
		"id": "elf_archer",
		"name": "Elf Archer",
		"type": "CREATURE",
		"cost": 3,
		"attack": 2,
		"health": 2,
		"tags": ["ELF"],
		"keywords": ["RANGED"],
		"text": "RANGED",
	},
]

func _init() -> void:
	var library := CardLibrary.new()
	library.ingest(CARD_PAYLOAD)
	_check("the library loaded", library.is_loaded())

	# --- reach comes from `range`, not from the card's name or tags ----------
	_check("melee weapon reports MELEE", library.weapon_range("iron_sword") == "MELEE")
	_check("ranged weapon reports RANGED", library.weapon_range("hunting_bow") == "RANGED")
	_check("iron sword is not ranged", not library.is_ranged_weapon("iron_sword"))
	_check("hunting bow is ranged", library.is_ranged_weapon("hunting_bow"))
	# A Bow tag must not by itself make something ranged, and a Creature with
	# the RANGED keyword is not a Weapon at all.
	_check("creature range is empty", library.weapon_range("elf_archer") == "")

	# --- the type line names Ranged, and leaves Melee unsaid -----------------
	_check("melee type line", library.weapon_type_line("iron_sword") == "Weapon")
	_check("ranged type line", library.weapon_type_line("hunting_bow") == "Weapon — Ranged")

	# --- stats --------------------------------------------------------------
	_check("weapon attack", library.base_attack("iron_sword") == 2)
	_check("weapon durability", library.base_durability("iron_sword") == 2)

	# --- tooltips -----------------------------------------------------------
	var bow_tip := library.tooltip("hunting_bow")
	_check("ranged tooltip names the type", bow_tip.contains("Weapon — Ranged"))
	_check("ranged tooltip shows stats", bow_tip.contains("2 Attack · 2 Durability"))
	_check("ranged tooltip explains retaliation", bow_tip.contains("do not receive retaliation"))
	_check("ranged tooltip keeps Guard true", bow_tip.contains("Guard still applies"))
	var sword_tip := library.tooltip("iron_sword")
	_check("melee tooltip shows stats", sword_tip.contains("2 Attack · 2 Durability"))
	_check("melee tooltip does not claim Ranged", not sword_tip.contains("Ranged"))

	# The two glossaries disagree about RANGED on purpose, and the caller says
	# which one it means.
	var creature_line := CardLibrary.keyword_line("RANGED")
	var weapon_line := CardLibrary.keyword_line("RANGED", true)
	_check("creature RANGED keeps its own meaning", creature_line.contains("back row"))
	_check("weapon RANGED has its own meaning", weapon_line.contains("either row"))
	_check("the two glossaries differ", creature_line != weapon_line)

	_check_targeting()
	_finish()

## A Hero is an attack source only when the server offers a HERO_ATTACK.
func _check_targeting() -> void:
	var hero_a := Targeting.hero_entity_id("a")
	var hero_b := Targeting.hero_entity_id("b")
	var legal: Array = [
		{"type": "HERO_ATTACK", "actorId": "a", "targetId": "creature_3"},
		{"type": "HERO_ATTACK", "actorId": "a", "targetId": hero_b},
		{"type": "ATTACK", "actorId": "a", "attackerId": "creature_1", "targetId": hero_b},
		{"type": "END_TURN", "actorId": "a"},
	]

	var mine := Targeting.actions_for_entity(legal, hero_a)
	_check("the acting Hero offers both its attacks", mine.size() == 2)
	# The opposing Hero is a target, never a source.
	_check("the enemy Hero is not a source", Targeting.actions_for_entity(legal, hero_b).is_empty())
	# A creature's attack must not be attributed to the Hero.
	var creature_actions := Targeting.actions_for_entity(legal, "creature_1")
	_check("a Creature keeps its own attack", creature_actions.size() == 1)

	var targets := Targeting.entity_targets(mine)
	_check("the Creature target lights up", targets.has("creature_3"))
	_check("the enemy Hero lights up", targets.has(hero_b))
	_check("no stray targets", targets.size() == 2)
	_check(
		"a Hero attack needs a target chosen",
		Targeting.untargeted_action(mine) == null
	)

	# With no Weapon, the server sends no HERO_ATTACK and the Hero is inert.
	var unarmed: Array = [{"type": "END_TURN", "actorId": "a"}]
	_check(
		"an unarmed Hero is not a source",
		Targeting.actions_for_entity(unarmed, hero_a).is_empty()
	)

func _finish() -> void:
	print("\n%d failure(s)" % failures.size())
	for f in failures:
		print("  FAIL: ", f)
	print("RESULT: ", "PASS" if failures.is_empty() else "FAIL")
	quit(0 if failures.is_empty() else 1)

func _check(label: String, condition: bool) -> void:
	print("  [%s] %s" % ["ok" if condition else "XX", label])
	if not condition:
		failures.append(label)
