extends SceneTree

## Checks the hand's fan, hover, holding and playing, without a server.
##
##   godot --headless --path apps/godot-client --script src/hand_view_test.gd
## Run it windowed with `-- --screenshot-dir=<dir>` to save what it drew.

const WOLF := {
	"id": "wolf", "name": "Wolf", "type": "CREATURE", "cost": 2,
	"attack": 2, "health": 3, "tags": ["BEAST"], "keywords": ["SWIFT"],
	"description": "**Swift**",
}
const WORDY := {
	"id": "wordy_warden", "name": "A Card With Rather A Lot To Say", "type": "CREATURE", "cost": 4,
	"attack": 3, "health": 4, "tags": ["HUMAN"],
	"keywords": ["GUARD", "ARRIVAL", "WARD", "LIFESTEAL"],
	"description": "**Guard**, **Ward**, **Lifesteal**\n**Arrival:** Give adjacent friendly Creatures +1 Health, then give every other friendly Creature +1 Attack until the end of your turn, and restore 2 Health to your Hero for each Creature that was given Health this way.",
}
const SPELL := {
	"id": "firebolt", "name": "Firebolt", "type": "ACTION", "cost": 1,
	"tags": [], "keywords": [], "description": "Deal 2 damage.",
}

var failures: Array[String] = []
var library := CardLibrary.new()
var hand: HandView

func _init() -> void:
	await process_frame
	print("== hand view test ==")
	library.ingest([WOLF, WORDY, SPELL])

	hand = HandView.new()
	hand.setup(library)
	get_root().add_child(hand)
	hand.position = Vector2(40, 560)
	hand.size = Vector2(900, HandView.HEIGHT)

	# Three cards fan out symmetrically, side by side.
	_deal(["a", "b", "c"])
	await _settle()
	var left := hand.rest_rect("a")
	var middle := hand.rest_rect("b")
	var right := hand.rest_rect("c")
	_check("a small hand sits side by side", left.end.x <= middle.position.x + 1.0)
	_check("the fan is centred",
		absf((middle.get_center().x - hand.global_position.x) - hand.size.x * 0.5) < 1.0)
	_check("the outer cards drop below the middle one",
		left.position.y > middle.position.y and is_equal_approx(left.position.y, right.position.y))
	_check("the outer cards lean outward",
		hand.panel_for("a").rotation < 0.0 and hand.panel_for("c").rotation > 0.0
			and is_zero_approx(hand.panel_for("b").rotation))
	_check("each card is found where it rests", hand.card_at(middle.get_center()) == "b")
	_check("nothing is found off the hand", hand.card_at(middle.get_center() - Vector2(0, 200)) == "")

	# A full hand overlaps rather than running off the side.
	var ids: Array[String] = []
	for index in 10:
		ids.append("card%d" % index)
	_deal(ids)
	await _settle()
	var first := hand.rest_rect("card0")
	var last := hand.rest_rect("card9")
	_check("a full hand fits the view",
		first.position.x >= hand.global_position.x and last.end.x <= hand.global_position.x + hand.size.x)
	_check("a full hand overlaps", hand.rest_rect("card1").position.x < first.end.x)
	# Where two cards overlap, the one drawn on top is the one picked.
	var overlap := Vector2(hand.rest_rect("card1").position.x + 4.0, hand.rest_rect("card1").get_center().y)
	_check("an overlap picks the card on top", hand.card_at(overlap) == "card1")
	_check("cards that left the hand are gone", hand.panel_for("a") == null)

	# Hovering shows the card large, standing on the hand, and spreads the rest.
	_deal(["a", "b", "c"])
	await _settle()
	var before_left := hand.panel_for("a").position.x
	hand.hover("b")
	await _settle()
	_check("hovering shows the card large", hand.is_zoomed())
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		# The preview's outline/shadow once submitted thousands of tiny shapes.
		# Check rendering work instead of machine-dependent frame timings.
		var calls := Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
		_check("a hover preview stays within the draw-call budget", calls > 0 and calls < 1000)
		var cached := CardFrame._outline_layers.size()
		hand.clear_hover()
		hand.hover("b")
		await _settle()
		await RenderingServer.frame_post_draw
		_check("reopening the preview reuses its outline textures", CardFrame._outline_layers.size() == cached)
	var zoom := Rect2(hand._zoom.global_position, hand._zoom.size * hand._zoom.scale)
	_check("the large card is several times the hand card",
		zoom.size.x >= HandView.CARD_SIZE.x * 2.0)
	_check("the large card stands on the bottom of the hand",
		absf(zoom.end.y - hand.get_global_rect().end.y) < 1.0)
	_check("the large card stays on screen",
		zoom.position.x >= 0.0 and zoom.position.y >= 0.0
			and zoom.end.x <= hand.get_viewport_rect().size.x)
	_check("the hovered card straightens and lifts",
		is_zero_approx(hand.panel_for("b").rotation) and hand.panel_for("b").position.y < middle.position.y - hand.global_position.y)
	_check("its neighbours make room", hand.panel_for("a").position.x < before_left)
	_check("the large card takes no pointer input", _ignores_mouse(hand._zoom))
	# "b" is the spell: it has no frame, but zooms all the same.
	_check("a card that is not a creature also shows large", hand.is_zoomed())
	_check("a card with nothing to explain shows no notes", not hand._notes.visible)
	# "c" is the creature, whose keyword is explained beside it.
	hand.hover("c")
	await _settle()
	_check("keywords are explained beside the large card", hand._notes.visible)
	hand.clear_hover()
	await _settle()
	_check("leaving the hand puts it away", not hand.is_zoomed())

	# Rules too long for the card's box are printed in full beside it.
	_deal(["w"], "wordy_warden")
	await _settle()
	hand.hover("w")
	await _settle()
	var printed := false
	for label in _find_rich(hand._notes):
		if label.get_parsed_text().contains("adjacent"):
			printed = true
	_check("long rules are printed beside the large card", printed)
	hand.clear_hover()

	# A held card follows the pointer, out of the fan, and the fan closes up.
	_deal(["a", "b", "c"])
	await _settle()
	var rest_c := hand.rest_rect("c")
	hand.pick_up("b", hand.rest_rect("b").get_center())
	var target := hand.global_position + Vector2(450, -300)
	hand.move_held(target)
	await _settle()
	_check("a held card follows the pointer",
		hand.panel_for("b").get_global_rect().get_center().distance_to(target) < 2.0)
	_check("a held card draws over the board", hand.panel_for("b").z_index >= HandView.Z_HELD)
	_check("a held card cannot be hovered", hand.card_at(hand.rest_rect("a").get_center()) == "a" and not hand.is_zoomed())
	_check("the fan closes up behind it", hand.rest_rect("c").position.x < rest_c.position.x)
	hand.set_held_ready(true)
	await process_frame
	_check("a card that would play lights up", hand._glow.visible)
	hand.park_held()
	await _settle()
	_check("a parked card waits above the hand",
		hand.panel_for("b").get_global_rect().get_center().distance_to(hand.park_point()) < 2.0
			and hand.park_point().y < hand.global_position.y)
	_check("a parked card does not glow", not hand._glow.visible)

	# Put back, it returns to its place.
	hand.return_held()
	await _settle()
	_check("a card put back returns to its place",
		hand.panel_for("b").get_global_rect().get_center().distance_to(hand.rest_rect("b").get_center()) < 2.0)

	# Played, it fades where it was let go and stays out until the server says.
	hand.pick_up("a", hand.rest_rect("a").get_center())
	hand.move_held(target)
	await _settle()
	hand.spend_held()
	await _settle()
	_check("a played card fades out", hand.panel_for("a").modulate.a < 0.05)
	_check("a played card leaves the fan", hand.card_at(hand.rest_rect("b").get_center()) != "a"
		and hand.rest_rect("a") == Rect2())
	# The board re-renders before the server's answer: it stays played.
	_deal(["a", "b", "c"])
	await _settle()
	_check("a played card stays out across a re-render", hand.is_spent("a"))
	# The server refuses it: it comes back.
	hand.restore_spent()
	await _settle()
	_check("a refused card comes back", not hand.is_spent("a") and hand.panel_for("a").modulate.a > 0.95)
	# The server takes it: it is gone.
	hand.pick_up("a", hand.rest_rect("a").get_center())
	hand.spend_held()
	_deal(["b", "c"])
	_check("a card the server took is gone", hand.panel_for("a") == null)

	_deal([])
	_check("an empty hand says so", hand._empty.visible)

	var shots := _arg("--screenshot-dir=")
	if shots != "" and DisplayServer.get_name() != "headless":
		_deal(["a", "b", "c", "d", "e", "f", "g"])
		await _settle()
		hand.hover("d")
		await _settle()
		await RenderingServer.frame_post_draw
		var path := shots.path_join("hand_view.png")
		get_root().get_texture().get_image().save_png(path)
		print("  saved ", path)

	print("%d failure(s)" % failures.size())
	for failure in failures:
		print("  FAIL: ", failure)
	print("RESULT: ", "PASS" if failures.is_empty() else "FAIL")
	quit(0 if failures.is_empty() else 1)

## Deals `ids` into the hand, each a copy of `definition_id`, alternating a
## creature and a spell when none is given.
func _deal(ids: Array, definition_id := "") -> void:
	hand.begin_update()
	for index in ids.size():
		var shown := definition_id
		if shown == "":
			shown = "wolf" if index % 2 == 0 else "firebolt"
		var panel := PanelContainer.new()
		panel.custom_minimum_size = HandView.CARD_SIZE
		panel.add_child(CardFrame.make(library, {"definition_id": shown}, 96.0))
		hand.put_card(str(ids[index]), panel, {"definition_id": shown, "playable": true})
	hand.end_update()

## Long enough for every easing to arrive, and well short of the time a played
## card waits for the server before coming back.
func _settle() -> void:
	for frame in 10:
		await process_frame
	# Headless frames can run with almost no time passing; push the easing on.
	for frame in 20:
		hand._process(0.05)

func _find_rich(node: Node) -> Array[RichTextLabel]:
	var found: Array[RichTextLabel] = []
	for child in node.get_children():
		if child is RichTextLabel:
			found.append(child)
		found.append_array(_find_rich(child))
	return found

func _ignores_mouse(node: Node) -> bool:
	if node is Control and (node as Control).mouse_filter != Control.MOUSE_FILTER_IGNORE:
		return false
	for child in node.get_children():
		if not _ignores_mouse(child):
			return false
	return true

func _arg(prefix: String) -> String:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with(prefix):
			return argument.substr(prefix.length())
	return ""

func _check(label: String, condition: bool) -> void:
	print("  [%s] %s" % ["ok" if condition else "XX", label])
	if not condition:
		failures.append(label)
