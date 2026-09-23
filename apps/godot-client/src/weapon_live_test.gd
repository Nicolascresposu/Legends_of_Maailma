extends SceneTree

## Plays a Weapon through the real client against a live server.
##
##   godot --path apps/godot-client --headless --script src/weapon_live_test.gd
##
## The unit test beside this one checks presentation from a hand-built payload.
## This one proves the whole path: the server's definitions reach the library,
## a Weapon card equips, the equipped Weapon appears in the authoritative state
## the client renders from, the server offers HERO_ATTACK, and the attack it
## resolves spends Durability. Nothing here decides a rule — it only checks that
## what the server said arrived intact.

var client: MatchClient
var library := CardLibrary.new()
var state: Dictionary = {}
var actions: Array = []
var events: Array = []
var failures: Array[String] = []
var match_id := ""

const PLAYER := "weapon-probe-a"

func _init() -> void:
	client = MatchClient.new()
	get_root().add_child(client)
	client.cards_received.connect(func(p: Variant) -> void: library.ingest(p))
	client.match_created.connect(func(id: String) -> void: match_id = id)
	client.match_state_received.connect(func(s: Dictionary) -> void: state = s)
	client.legal_actions_received.connect(func(_p: String, a: Array) -> void: actions = a)
	client.game_events_received.connect(func(e: Array) -> void: events.append_array(e))
	client.server_error.connect(func(c: String, m: String) -> void:
		_fail("server error %s: %s" % [c, m]))
	client.request_failed.connect(func(d: String) -> void: _fail("request failed: " + d))

	print("== Weapon live test ==")
	await process_frame
	client.fetch_cards()
	client.create_match("BANDIT_AMBUSH", PLAYER, "healer", _deck_with_weapons())

	if not await _await(func() -> bool: return match_id != "" and library.is_loaded()):
		_fail("no match and card library within timeout — is the server running?")
		_finish()
		return
	_check("a match was created", match_id != "")

	# Actions travel over the socket, so the match must be joined before any
	# state or legal actions arrive.
	client.join(match_id, PLAYER, "healer", true)
	if not await _await(func() -> bool: return not state.is_empty()):
		_fail("no authoritative state arrived over the socket")
		_finish()
		return

	# --- the server's own Weapon data reached the client ---------------------
	_check("the library knows Iron Sword", library.has("iron_sword"))
	_check("Iron Sword is a WEAPON", library.card_type("iron_sword") == "WEAPON")
	_check("its reach comes from the server", library.weapon_range("iron_sword") == "MELEE")
	_check("Hunting Bow reads as RANGED", library.weapon_range("hunting_bow") == "RANGED")
	_check("a Weapon carries Durability", library.base_durability("iron_sword") == 2)

	# --- play the Weapon -----------------------------------------------------
	if not await _await(func() -> bool: return not actions.is_empty()):
		_fail("no legal actions arrived")
		_finish()
		return

	# The opening hand is small and the deck order is seeded, so a Weapon may
	# not be in hand yet. End turns until one is drawn rather than skipping the
	# part of the test that matters.
	var play := _find_weapon_play()
	for attempt in range(12):
		if not play.is_empty():
			break
		if not await _pass_turn():
			break
		play = _find_weapon_play()
	if play.is_empty():
		_fail("no Weapon reached hand in 12 turns — the deck is half Weapons")
		_finish()
		return

	var before_taika := _taika()
	events.clear()
	client.submit_action(play)
	if not await _await(func() -> bool: return _equipped_weapon() != null):
		_fail("the Weapon never appeared in authoritative state")
		_finish()
		return

	var equipped: Dictionary = _equipped_weapon()
	var definition_id := str(equipped.get("definitionId", ""))
	_check("the Weapon equipped", definition_id != "")
	_check("playing it spent Taika", _taika() < before_taika)
	_check("it reports full Durability", int(equipped.get("currentDurability", 0)) \
		== library.base_durability(definition_id))
	_check("it reports its Attack", int(equipped.get("currentAttack", -1)) \
		== library.base_attack(definition_id))
	_check("the Hero has not attacked yet", int(_hero().get("attacksUsedThisTurn", -1)) == 0)
	_check("an equip event arrived", _saw_event("WEAPON_EQUIPPED"))

	# --- the Hero becomes an attacker ---------------------------------------
	if not await _await(func() -> bool: return not _hero_attacks().is_empty()):
		_fail("the server offered no HERO_ATTACK for an armed Hero")
		_finish()
		return
	var hero_attacks := _hero_attacks()
	_check("the server offers Hero attacks", not hero_attacks.is_empty())

	var hero_id := Targeting.hero_entity_id(PLAYER)
	var sourced := Targeting.actions_for_entity(actions, hero_id)
	_check("the client sees the Hero as an attacker", sourced.size() == hero_attacks.size())
	var targets := Targeting.entity_targets(sourced)
	_check("its targets light up", not targets.is_empty())

	# --- resolve one attack --------------------------------------------------
	var durability_before := int(equipped.get("currentDurability", 0))
	events.clear()
	client.submit_action(hero_attacks[0] as Dictionary)
	if not await _await(func() -> bool:
			return int(_hero().get("attacksUsedThisTurn", 0)) > 0):
		_fail("the Hero attack never resolved")
		_finish()
		return

	_check("the attack was spent", int(_hero().get("attacksUsedThisTurn", 0)) == 1)
	var after: Variant = _equipped_weapon()
	if after == null:
		# A 1-Durability Weapon breaks on its only swing; that is correct too.
		_check("a spent Weapon left the slot", _saw_event("WEAPON_BROKEN"))
	else:
		_check("Durability was spent",
			int((after as Dictionary).get("currentDurability", 99)) == durability_before - 1)
		_check("a durability event arrived", _saw_event("WEAPON_DURABILITY_CHANGED"))
	_check("the server narrated the attack", _saw_event("HERO_ATTACK_STARTED"))

	# The Hero must not be offered a second attack.
	await _settle()
	_check("no second attack is offered", _hero_attacks().is_empty())
	_finish()

# --- helpers -----------------------------------------------------------------

## A legal 30-card deck that is half Weapons, so the opening hand almost
## always holds one. Two copies of each card keeps it inside the copy limit.
func _deck_with_weapons() -> Array:
	var deck: Array = []
	for id in [
		"iron_sword", "hunting_bow", "war_axe", "longbow", "rusty_dagger",
		"wolf", "brown_bear", "hawk", "giant_rat", "hunting_spider",
		# The Mender is a Priest, so the deck holds Priest and neutral cards only.
		"elf_archer", "dwarf_defender", "human_mercenary", "field_medic",
		"maintenance_anima",
	]:
		deck.append(id)
		deck.append(id)
	return deck

## Ends our turn and waits until it comes back round, so the next draw lands.
##
## The scenario seats an AI opposite, which takes its own turn: a client may
## only ever act for the seat it joined as, and the server enforces that.
func _pass_turn() -> bool:
	var drawn := _hand_size()
	if not client.submit_action({"type": "END_TURN", "actorId": PLAYER}):
		return false
	# Control returns to us once the AI has finished, with one more card drawn.
	return await _await(func() -> bool: return _is_our_turn() and _hand_size() != drawn)

func _is_our_turn() -> bool:
	return str(state.get("activePlayerId", "")) == PLAYER

func _hand_size() -> int:
	var hand: Variant = _side().get("hand", [])
	return (hand as Array).size() if typeof(hand) == TYPE_ARRAY else 0

func _side() -> Dictionary:
	var sides: Variant = state.get("sides", {})
	if typeof(sides) != TYPE_DICTIONARY:
		return {}
	return (sides as Dictionary).get(PLAYER, {})

func _hero() -> Dictionary:
	return _side().get("hero", {})

func _taika() -> int:
	return int((_side().get("taika", {}) as Dictionary).get("current", 0))

func _equipped_weapon() -> Variant:
	var equipped: Variant = _hero().get("equippedWeapon", null)
	return equipped if typeof(equipped) == TYPE_DICTIONARY else null

## The first legal action that plays a Weapon from hand.
func _find_weapon_play() -> Dictionary:
	var hand: Variant = _side().get("hand", [])
	if typeof(hand) != TYPE_ARRAY:
		return {}
	for card in (hand as Array):
		if typeof(card) != TYPE_DICTIONARY:
			continue
		if library.card_type(str((card as Dictionary).get("definitionId", ""))) != "WEAPON":
			continue
		var for_card := Targeting.actions_for_card(
			actions, str((card as Dictionary).get("instanceId", ""))
		)
		if not for_card.is_empty():
			return for_card[0] as Dictionary
	return {}

func _hero_attacks() -> Array:
	var out: Array = []
	for action in actions:
		if typeof(action) == TYPE_DICTIONARY and str(action.get("type", "")) == "HERO_ATTACK":
			out.append(action)
	return out

func _saw_event(kind: String) -> bool:
	for event in events:
		if typeof(event) == TYPE_DICTIONARY and str(event.get("type", "")) == kind:
			return true
	return false

## Waits for `condition`, polling frames. False when it never came true.
func _await(condition: Callable) -> bool:
	for i in range(600):
		await process_frame
		if condition.call():
			return true
	return false

## Lets any in-flight state and legal-action messages land.
func _settle() -> void:
	for i in range(30):
		await process_frame

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

func _fail(message: String) -> void:
	print("  [XX] ", message)
	failures.append(message)
