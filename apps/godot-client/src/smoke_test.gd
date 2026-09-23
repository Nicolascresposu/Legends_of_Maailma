extends SceneTree

## Headless smoke test for the client's networking and formatting layers.
##
## Run against a live server:
##   godot --headless --path apps/godot-client --script src/smoke_test.gd

var client: MatchClient
var library := CardLibrary.new()
var state: Dictionary = {}
var actions: Array = []
var failures: Array[String] = []
var checks := 0
var turns_taken := 0
var finished := false

func _init() -> void:
	client = MatchClient.new()
	get_root().add_child(client)
	client.cards_received.connect(func(p: Variant) -> void: library.ingest(p))
	client.match_created.connect(_on_created)
	client.match_state_received.connect(_on_state)
	client.legal_actions_received.connect(_on_actions)
	client.game_events_received.connect(_on_events)
	client.server_error.connect(func(c: String, m: String) -> void: _fail("server error %s: %s" % [c, m]))
	client.request_failed.connect(func(d: String) -> void: _fail("request failed: " + d))
	client.connection_changed.connect(func(s: int, d: String) -> void: print("  [conn] ", d))

	print("== Maailma client smoke test ==")
	_check("websocket url derives from http base",
		client.websocket_url() == "ws://127.0.0.1:3000/matches")
	client.http_base = "https://example.test:8443"
	_check("https base yields wss",
		client.websocket_url() == "wss://example.test:8443/matches")
	client.http_base = "http://127.0.0.1:3000"

	# Let the client enter the tree before issuing HTTP requests.
	await process_frame
	client.fetch_cards()
	# No deck: the server deals the starter deck of the hero's class.
	client.create_match("BANDIT_AMBUSH", "player-a", "healer", [])
	_timeout()

func _timeout() -> void:
	await create_timer(25.0).timeout
	if not finished:
		_fail("timed out before the match progressed")
		_finish()

func _on_created(match_id: String) -> void:
	_check("match id returned", match_id != "")
	print("  match ", match_id)
	client.join(match_id, "player-a", "healer", true)

func _on_state(new_state: Dictionary) -> void:
	state = new_state
	if not new_state.has("sides"):
		_fail("state missing sides")

func _on_events(events: Array) -> void:
	# Every event must render without crashing and without leaking raw ids.
	for event in events:
		var line := ActionFormatter.event_line(event, state, library)
		if line.strip_edges() == "":
			_fail("empty event line for " + str(event.get("type", "?")))

func _on_actions(player: String, list: Array) -> void:
	if finished or player != "player-a":
		return
	actions = list
	if actions.is_empty():
		return

	if turns_taken == 0:
		_check("card library loaded", library.is_loaded())
		_check("library resolves a real card name", library.card_name("wolf") == "Wolf")
		_check("library reports cost", library.cost("brown_bear") == 3)
		_check("unknown card falls back to its id", library.card_name("nope") == "nope")
		_check("tooltip mentions the card name", library.tooltip("wolf").contains("Wolf"))
		_check("every card arrives with a description",
			library.description("dwarf_defender").contains("**Guard**"))
		_check("tooltips show descriptions without markup",
			library.tooltip("dwarf_defender").contains("Guard\n")
				and not library.tooltip("dwarf_defender").contains("*"))
		_check("flavour arrives apart from the description",
			library.flavour("dwarf_defender") != ""
				and not library.description("dwarf_defender").contains(library.flavour("dwarf_defender")))
		_check("flavour is set in italics",
			library.flavour_bbcode("dwarf_defender").begins_with("[i]"))
		_check("a card without flavour renders none", library.flavour_bbcode("nope") == "")
		_check("bold markup becomes BBCode bold",
			CardLibrary.markup_to_bbcode("**Guard** now") == "[b]Guard[/b] now")
		_check("italic markup becomes BBCode italic",
			CardLibrary.markup_to_bbcode("*quiet*") == "[i]quiet[/i]")
		_check("bold italic nests cleanly",
			CardLibrary.markup_to_bbcode("***both***") == "[b][i]both[/i][/b]")
		_check("an escaped asterisk stays literal",
			CardLibrary.markup_to_plain("2\\*3") == "2*3")
		_check("a bracket in card text is not read as a tag",
			CardLibrary.markup_to_bbcode("[x]") == "[lb]x]")

		var labels_ok := true
		var groups := {}
		for action in actions:
			var label := ActionFormatter.label_for(action, state, "player-a", library)
			if label.strip_edges() == "" or label.begins_with("{"):
				labels_ok = false
			groups[ActionFormatter.group_of(action)] = true
		_check("every legal action has a readable label", labels_ok)
		_check("actions fall into known groups", groups.size() > 0)
		var has_end_turn := false
		for action in actions:
			if str(action.get("type", "")) == "END_TURN":
				has_end_turn = true
		_check("END_TURN offered", has_end_turn)

		# Hand cards must resolve to names, not instance ids.
		var side: Dictionary = state.get("sides", {}).get("player-a", {})
		var hand: Array = side.get("hand", [])
		_check("hand was dealt", hand.size() > 0)
		if hand.size() > 0:
			var first: Dictionary = hand[0]
			var resolved := ActionFormatter.card_name_for_instance(
				str(first.get("instanceId", "")), state, "player-a", library)
			_check("hand card resolves to a display name",
				resolved != str(first.get("instanceId", "")))

		# Art is looked up by card id from client assets; a card without a file
		# must fall back to text rather than rendering an empty tile.
		_check("art resolves for a card that has a file", CardArt.has_art("wolf"))
		_check("an unknown card has no art", not CardArt.has_art("definitely_not_a_card"))
		_check("an empty id has no art", CardArt.texture_for("") == null)
		_check("a banner is built when art exists", CardArt.make_banner("wolf", 40.0) != null)
		_check(
			"no banner is built without art",
			CardArt.make_banner("definitely_not_a_card", 40.0) == null
		)

		# Heroes are addressed as "<playerId>:hero", not by the bare player id.
		var hero_label := ActionFormatter.entity_name(
			Targeting.hero_entity_id("player-a"), state, library)
		_check("hero entity resolves to a hero name", hero_label.contains("Mender"))
		_check("a bare player id is not mistaken for a hero",
			ActionFormatter.entity_name("player-a", state, library) == "player-a")

	# Play out a few turns to exercise state handling and the AI opponent.
	if turns_taken >= 3:
		_finish()
		return
	turns_taken += 1
	var play_action: Variant = null
	for action in actions:
		if str(action.get("type", "")) == "PLAY_CARD":
			play_action = action
			break
	var chosen: Variant = play_action
	if chosen == null:
		for action in actions:
			if str(action.get("type", "")) == "END_TURN":
				chosen = action
	if chosen != null:
		_check("submitting turn %d" % turns_taken, client.submit_action(chosen))

func _finish() -> void:
	if finished:
		return
	finished = true
	print("\n%d checks run, %d failure(s)" % [checks, failures.size()])
	for failure in failures:
		print("  FAIL: ", failure)
	if failures.is_empty():
		print("RESULT: PASS")
	else:
		print("RESULT: FAIL")
	quit(0 if failures.is_empty() else 1)

func _check(label: String, condition: bool) -> void:
	checks += 1
	print("  [%s] %s" % ["ok" if condition else "XX", label])
	if not condition:
		failures.append(label)

func _fail(reason: String) -> void:
	checks += 1
	failures.append(reason)
	print("  [XX] ", reason)
