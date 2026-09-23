extends SceneTree

## Two clients, one PvP match: the host opens a seat, the guest takes it with a
## deck of their own, and both end up in the same live match.
##
## Requires a running server:
##   godot --headless --path apps/godot-client --script src/pvp_test.gd

const TestSession := preload("res://src/test_session.gd")

var host: Control
var guest: Control
var failures: Array[String] = []

func _init() -> void:
	await process_frame
	SessionStore.clear()
	print("== PvP open seat test ==")
	host = await _client()
	guest = await _client()

	var host_deck: String = await TestSession.sign_in_with_ready_deck(self, host, "healer")
	var guest_deck: String = await TestSession.sign_in_with_ready_deck(self, guest, "striker")
	_check("both players have a ready deck", host_deck != "" and guest_deck != "")
	if host_deck == "" or guest_deck == "":
		_finish()
		return

	# The host opens a PvP match; it waits for an opponent.
	host._show_match_view()
	host.start_match_with_deck("STANDARD_PVP", host_deck)
	for i in range(300):
		await process_frame
		if not host.state.is_empty():
			break
	var match_id: String = host.match_input.text
	_check("the host is given a match id", match_id != "")
	_check("the host sees the open seat", host.opponent_id == host.OPEN_SEAT_ID)
	_check("the host cannot act while the seat is open", host.legal_actions.is_empty())
	_check("the banner says the match is waiting", host.turn_banner.text.begins_with("Waiting"))

	# The guest joins by id, is asked for a deck, and picks one.
	guest._show_match_view()
	guest.match_input.text = match_id
	guest._join_match()
	for i in range(300):
		await process_frame
		if guest.deck_picker.is_open() and not guest.deck_picker.playable_deck_ids().is_empty():
			break
	_check("joining asks the guest for a deck", guest.deck_picker.is_open())
	_check("the guest's ready deck is offered",
		guest.deck_picker.playable_deck_ids().has(guest_deck))
	guest.deck_picker.pick(guest_deck)

	for i in range(400):
		await process_frame
		if not guest.state.is_empty() and host.opponent_id == guest.player_id:
			break
	var host_id: String = host.player_id
	var guest_id: String = guest.player_id
	_check("the guest is seated in the match", not guest.state.is_empty())
	_check("the host sees the guest take the seat", host.opponent_id == guest_id)
	_check("the guest sees the host", guest.opponent_id == host_id)
	var sides: Dictionary = host.state.get("sides", {})
	_check("each plays their own deck's hero",
		str((sides.get(host_id, {}) as Dictionary).get("hero", {}).get("definitionId", "")) == "healer"
			and str((sides.get(guest_id, {}) as Dictionary).get("hero", {}).get("definitionId", "")) == "striker")

	# Whoever goes first now has something to do.
	var active := str(host.state.get("activePlayerId", ""))
	var active_client: Control = host if active == host_id else guest
	for i in range(200):
		await process_frame
		if not active_client.legal_actions.is_empty():
			break
	_check("the player to move has legal actions", not active_client.legal_actions.is_empty())
	_finish()

func _client() -> Control:
	var main: Control = (load("res://main.tscn") as PackedScene).instantiate()
	get_root().add_child(main)
	await process_frame
	await process_frame
	return main

func _check(label: String, condition: bool) -> void:
	print("  [%s] %s" % ["ok" if condition else "XX", label])
	if not condition:
		failures.append(label)

func _finish() -> void:
	print("\n%d failure(s)" % failures.size())
	for f in failures:
		print("  FAIL: ", f)
	print("RESULT: ", "PASS" if failures.is_empty() else "FAIL")
	quit(0 if failures.is_empty() else 1)
