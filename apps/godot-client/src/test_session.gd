extends RefCounted

## Test support: a fresh account with a ready deck, for tests that need to
## play a match.
##
## A match is only ever entered with one of the player's own ready decks, so a
## test that wants a board to look at first has to be a player who has one.
## This goes through the real collection screen, as a player would.

## Registers a new account, builds a deck from the cards it was given, and
## returns the saved deck's id — or "" if any step failed, with the reason
## printed.
static func sign_in_with_ready_deck(tree: SceneTree, main: Node, hero_id: String = "healer") -> String:
	var screen: CollectionScreen = main.collection_screen
	var tag := "t%d%d" % [Time.get_ticks_msec() % 100000, randi() % 1000]
	screen._email_input.text = "%s@example.test" % tag
	screen._name_input.text = tag
	screen._password_input.text = "a-sufficiently-long-password"
	screen._do_register()
	for i in range(240):
		await tree.process_frame
		if main.accounts.is_signed_in():
			break
	if not main.accounts.is_signed_in():
		print("  [test] could not register: ", screen._auth_status.text)
		return ""

	for i in range(180):
		await tree.process_frame
		if not screen.collection.is_empty():
			break
	# The deck's class follows its hero, and autofill keeps to that class.
	screen.selected_hero = hero_id
	screen._autofill()
	screen._draft_name.text = "Test Deck"
	screen._save_draft()
	for i in range(240):
		await tree.process_frame
		for deck in screen.decks:
			var readiness: Dictionary = (deck as Dictionary).get("readiness", {})
			if bool(readiness.get("playable", false)):
				return str((deck as Dictionary).get("id", ""))
	print("  [test] no ready deck was saved")
	return ""
