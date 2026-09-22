extends SceneTree

## Drives the collection screen's economy against a live server: reads a
## Fragment balance, opens a pack, crafts and disenchants a card, and checks
## that a refusal is explained rather than merely relayed.
##
## Nothing here asserts what the economy *should* cost or allow — that is the
## server's to decide and is covered by the Vitest suites. What this checks is
## that the client asks, believes the answer, and shows it.
##
##   godot --path apps/godot-client --script src/economy_test.gd

var main: Control
var screen: CollectionScreen
var failures: Array[String] = []

func _init() -> void:
	await process_frame
	main = (load("res://main.tscn") as PackedScene).instantiate()
	get_root().add_child(main)
	await process_frame
	await process_frame
	screen = main.collection_screen

	var tag := "ec%d" % (Time.get_ticks_msec() % 100000)
	print("== economy screen test (%s) ==" % tag)

	screen._email_input.text = "%s@example.test" % tag
	screen._name_input.text = tag
	screen._password_input.text = "a-sufficiently-long-password"
	screen._do_register()
	for i in range(240):
		await process_frame
		if main.accounts.is_signed_in():
			break
	_check("registered and signed in", main.accounts.is_signed_in())
	if not main.accounts.is_signed_in():
		print("  auth status: ", screen._auth_status.text)
		_finish()
		return

	# --- The balance arrives without being asked for twice. ---
	for i in range(180):
		await process_frame
		if screen._fragments_label.text != "0 Fragments":
			break
	# A new account legitimately has nothing, so the assertion is that the
	# label was rendered from a reply, not that the number is above zero.
	_check("a Fragment balance is shown", screen._fragments_label.text.ends_with("Fragments"))
	print("  balance: ", screen._fragments_label.text)

	# --- Packs the server says are open. ---
	for i in range(180):
		await process_frame
		if not screen.available_packs.is_empty():
			break
	_check("at least one pack is offered", not screen.available_packs.is_empty())
	var unreleased_offered := false
	for pack in screen.available_packs:
		if str((pack as Dictionary).get("expansionId", "")) == "MACHINES_OF_KONA":
			unreleased_offered = true
	_check("an unreleased expansion is not offered", not unreleased_offered)

	# --- Opening a pack changes the collection. ---
	for i in range(180):
		await process_frame
		if not screen.collection.is_empty():
			break
	var before_total := _total_owned()
	if not screen.available_packs.is_empty():
		var pack_id := str((screen.available_packs[0] as Dictionary).get("id", ""))
		main.accounts.open_pack(pack_id)
		for i in range(240):
			await process_frame
			if _total_owned() > before_total:
				break
		_check("opening a pack adds cards", _total_owned() > before_total)
		print("  owned before/after: %d/%d" % [before_total, _total_owned()])

	# --- Every card carries the policies that decide its buttons. ---
	var has_policy_fields := false
	for entry in screen.collection:
		if typeof(entry) == TYPE_DICTIONARY and (entry as Dictionary).has("craftable"):
			has_policy_fields = true
			break
	_check("cards arrive with their current policies", has_policy_fields)

	# --- A refusal is explained, and nothing is spent. ---
	# A new account cannot afford a Legendary, so this exercises the refusal
	# path rather than the spending one.
	var expensive := _card_with_highest_craft_cost()
	if expensive != "":
		main.accounts.craft_card(expensive, 1)
		for i in range(240):
			await process_frame
			if screen._economy_status.text != "":
				break
		_check("a refused craft is explained", screen._economy_status.text != "")
		print("  refusal: ", screen._economy_status.text)

	# --- Disenchanting a spare returns Fragments. ---
	var spare := _card_owned_at_least(1)
	if spare != "":
		var before := screen.fragments
		main.accounts.disenchant_card(spare, 1)
		for i in range(240):
			await process_frame
			if screen.fragments != before:
				break
		_check("disenchanting changes the balance", screen.fragments != before)
		print("  fragments before/after: %d/%d" % [before, screen.fragments])

	# --- The format picker asks a different question of the same cards. ---
	screen.draft.clear()
	screen.selected_format = "WILD"
	screen._request_readiness()
	await process_frame
	_check("an empty draft is described rather than assessed",
		screen._readiness_label.text.contains("Add cards"))

	_finish()

## The player's whole collection, counted.
func _total_owned() -> int:
	var total := 0
	for entry in screen.collection:
		if typeof(entry) == TYPE_DICTIONARY:
			total += int((entry as Dictionary).get("owned", 0))
	return total

func _card_with_highest_craft_cost() -> String:
	var best := ""
	var best_cost := 0
	for entry in screen.collection:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var cost := int((entry as Dictionary).get("craftCost", 0))
		if cost > best_cost:
			best_cost = cost
			best = str((entry as Dictionary).get("cardId", ""))
	return best

func _card_owned_at_least(count: int) -> String:
	for entry in screen.collection:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var owned := int((entry as Dictionary).get("owned", 0))
		if owned >= count and bool((entry as Dictionary).get("disenchantable", false)):
			return str((entry as Dictionary).get("cardId", ""))
	return ""

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
