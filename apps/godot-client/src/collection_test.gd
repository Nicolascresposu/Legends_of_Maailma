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

	# The collection is a book of pages, cheapest first, holding only the cards
	# owned until the crafting view opens.
	await process_frame
	var shown := screen.visible_entries()
	_check("a page shows up to eight cards", screen.page_cards().size() == mini(8, shown.size()))
	_check("building a deck shows only owned cards",
		shown.all(func(entry: Dictionary) -> bool: return int(entry.get("owned", 0)) > 0))
	_check("the cards are in cost order", _in_cost_order(shown))
	_check("the cards are laid out on the page",
		screen.page_cards().all(func(tile: CollectionCard) -> bool: return tile.frame.size.x > 60.0))
	print("  deck-building pages: %d" % screen.page_count())
	if screen.page_count() > 1:
		var first_card := screen.page_cards()[0].card_id
		_wheel(screen._page_grid, MOUSE_BUTTON_WHEEL_DOWN)
		_check("the wheel turns the page",
			screen.page == 1 and screen.page_cards()[0].card_id != first_card)
		screen.turn_page(-1)

	var clicked_id := screen.page_cards()[0].card_id
	_click(screen.page_cards()[0], MOUSE_BUTTON_LEFT)
	_check("a left click adds a copy to the deck", int(screen.draft.get(clicked_id, 0)) == 1)
	_click(screen.page_cards()[0], MOUSE_BUTTON_RIGHT)
	_check("a right click takes it out again", not screen.draft.has(clicked_id))

	# The crafting view shows every card, and says by its look which can be made.
	screen._crafting_button.button_pressed = true
	_check("the crafting view shows unowned cards too",
		screen.visible_entries().size() == screen.collection.size())
	var looks_right := true
	var locked := 0
	for p in range(screen.page_count()):
		screen.page = p
		screen._render_collection()
		for tile in screen.page_cards():
			var entry := screen._entry_for(tile.card_id)
			if int(entry.get("owned", 0)) > 0:
				looks_right = looks_right and tile.look == CollectionCard.Look.NORMAL
			elif screen._can_craft(entry):
				looks_right = looks_right and tile.look == CollectionCard.Look.CRAFTABLE \
					and tile.is_processing() and tile.frame.material != null
			else:
				looks_right = looks_right and tile.look == CollectionCard.Look.LOCKED \
					and tile.frame.modulate.a < 1.0
				locked += 1
	_check("owned, craftable and uncraftable cards each wear their look", looks_right)
	# A new account cannot afford a Legendary.
	_check("a card that cannot be crafted yet is greyed out", locked > 0)
	screen.page = 0
	screen._render_collection()
	var to_craft := screen.page_cards()[0]
	_click(to_craft, MOUSE_BUTTON_LEFT)
	_check("crafting, a click opens the card's crafting panel",
		screen._craft_overlay.visible and screen.crafting_card_id == to_craft.card_id)
	_check("crafting, a click adds nothing to the deck", screen.draft.is_empty())
	screen.close_crafting()
	_check("the crafting panel closes", not screen._craft_overlay.visible)
	screen._crafting_button.button_pressed = false
	_check("leaving crafting shows the deck's cards again",
		screen.visible_entries().size() == shown.size())

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
	screen._add_card("chicken", 2)
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

func _in_cost_order(entries: Array) -> bool:
	for i in range(1, entries.size()):
		if main.library.cost(str(entries[i - 1].get("cardId", ""))) > main.library.cost(str(entries[i].get("cardId", ""))):
			return false
	return true

## Presses and releases `button` over the middle of `control`, through the
## viewport, as the mouse would.
func _click(control: Control, button: MouseButton) -> void:
	# Input arrives in window coordinates, which a headless window — far
	# smaller than the canvas it stretches — does not share with the canvas.
	var at := get_root().get_final_transform() * control.get_global_rect().get_center()
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = button
		event.pressed = pressed
		event.position = at
		event.global_position = at
		get_root().push_input(event)

func _wheel(control: Control, button: MouseButton) -> void:
	_click(control, button)

func _check(label: String, condition: bool) -> void:
	print("  [%s] %s" % ["ok" if condition else "XX", label])
	if not condition:
		failures.append(label)
