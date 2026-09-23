extends SceneTree

## Drives the real collection screen against a live server: registers an
## account, browses the granted cards, builds a deck and reads back the
## server's readiness verdict.
##
##   godot --path apps/godot-client --script src/collection_test.gd

var main: Control
var screen: CollectionScreen
var failures: Array[String] = []

func _init() -> void:
	await process_frame
	# A brand-new account every run: a session saved by an earlier run would
	# otherwise be resumed, and it is not new — it may already own decks.
	SessionStore.clear()
	main = (load("res://main.tscn") as PackedScene).instantiate()
	get_root().add_child(main)
	await process_frame
	await process_frame
	screen = main.collection_screen

	var tag := "gd%d" % (Time.get_ticks_msec() % 100000)
	print("== collection screen test (%s) ==" % tag)

	_check("collection screen starts visible", screen.visible)
	_check("match view starts hidden", not main.game_root.visible)

	# Register, which should grant the starter cards.
	screen._email_input.text = "%s@example.test" % tag
	screen._name_input.text = tag
	screen._password_input.text = "a-sufficiently-long-password"
	screen._do_register()
	for i in range(240):
		await process_frame
		if main.accounts.is_signed_in():
			break
	_check("registered and signed in", main.accounts.is_signed_in())
	_check("a player is not offered the admin UI",
		not main.admin_toggle.visible and not screen._admin_button.visible)
	if not main.accounts.is_signed_in():
		print("  auth status: ", screen._auth_status.text)
		_finish()
		return

	for i in range(180):
		await process_frame
		if not screen.collection.is_empty():
			break
	_check("collection loaded", not screen.collection.is_empty())
	print("  collection size: ", screen.collection.size())

	var owned := 0
	var unowned := 0
	for entry in screen.collection:
		if int(entry.get("owned", 0)) > 0:
			owned += 1
		else:
			unowned += 1
	_check("starter cards are owned", owned > 0)
	# The two legendaries sit outside the starter grant.
	_check("unowned cards are still listed", unowned > 0)
	print("  owned kinds: %d, unowned kinds: %d" % [owned, unowned])
	_check("the screen rendered a row per card", screen._card_list.get_child_count() == screen.collection.size())

	# A new account has no deck yet, so it cannot play: starting a match only
	# offers the deck picker, and the picker has nothing it will accept.
	main._create_match("BANDIT_AMBUSH")
	for i in range(180):
		await process_frame
		if main.deck_picker._loaded:
			break
	_check("starting a match asks for a deck", main.deck_picker.is_open())
	_check("an account with no ready deck has nothing to play",
		main.deck_picker.playable_deck_ids().is_empty())
	_check("no deck, no match", not main.deck_picker.pick("any-deck") and main.state.is_empty())
	main.deck_picker.close()
	main._show_collection_view()

	# Build a deck from owned cards only.
	screen._autofill()
	for i in range(150):
		await process_frame
	var total := screen.draft_card_ids().size()
	print("  autofilled to ", total, " cards")
	_check("autofill reached a full deck", total == 30)
	_check("readiness reported", screen._readiness_label.text != "")
	print("  readiness: ", screen._readiness_label.text)
	_check("a full owned deck is playable", screen._readiness_label.text.contains("Ready"))
	_check("autofill keeps to the deck's class",
		not screen.draft.has("firebolt") and not screen.draft.has("apprentice_mage"))

	# The hero decides the class: the same Priest cards are illegal for a Wizard.
	screen._hero_picker.select(1)
	screen._hero_picker.item_selected.emit(1)
	for i in range(150):
		await process_frame
	print("  as a Wizard deck: ", screen._readiness_label.text)
	_check("another class's cards are named by the server",
		screen._readiness_label.text.contains("is a Priest card"))
	screen._hero_picker.select(0)
	screen._hero_picker.item_selected.emit(0)
	for i in range(150):
		await process_frame

	# Add a card the player does not own and confirm the server says so.
	var missing_id := ""
	for entry in screen.collection:
		if int(entry.get("owned", 0)) == 0:
			missing_id = str(entry.get("cardId", ""))
			break
	if missing_id != "":
		screen._add_card(missing_id, 2)
		for i in range(150):
			await process_frame
		print("  after adding unowned '%s': %s" % [missing_id, screen._readiness_label.text])
		_check("an unowned card makes the deck unready",
			not screen._readiness_label.text.contains("Ready to play"))
		_check("the missing card is named",
			screen._readiness_label.text.contains(main.library.card_name(missing_id)))
		screen._remove_card(missing_id)
		for i in range(120):
			await process_frame

	# Save it and confirm it comes back with readiness attached.
	screen._draft_name.text = "Probe Deck"
	screen._save_draft()
	for i in range(240):
		await process_frame
		if not screen.decks.is_empty():
			break
	_check("deck saved and listed", not screen.decks.is_empty())
	if not screen.decks.is_empty():
		var deck: Dictionary = screen.decks[0]
		print("  saved deck: ", deck.get("name", "?"), " cards=", (deck.get("cardIds", []) as Array).size())
		_check("saved deck carries readiness", deck.has("readiness"))
		var readiness: Dictionary = deck.get("readiness", {})
		_check("saved deck is playable", bool(readiness.get("playable", false)))
		_check("deck row rendered", screen._deck_list.get_child_count() > 0)

	# An incomplete deck must save but be flagged.
	screen.draft.clear()
	screen.editing_deck_id = ""
	screen._add_card("wolf", 2)
	screen._draft_name.text = "Tiny Probe"
	screen._save_draft()
	for i in range(240):
		await process_frame
		if screen.decks.size() > 1:
			break
	_check("an incomplete deck still saves", screen.decks.size() > 1)
	var flagged := false
	for deck in screen.decks:
		if str(deck.get("name", "")) == "Tiny Probe":
			var r: Dictionary = deck.get("readiness", {})
			flagged = not bool(r.get("playable", true))
			print("  tiny deck ruleErrors: ", r.get("ruleErrors", []))
	_check("the incomplete deck is flagged unplayable", flagged)

	# Switching to the match view must not disturb the session.
	screen.play_requested.emit()
	await process_frame
	_check("match view shown on play", main.game_root.visible)
	_check("collection hidden on play", not screen.visible)
	_finish()

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
