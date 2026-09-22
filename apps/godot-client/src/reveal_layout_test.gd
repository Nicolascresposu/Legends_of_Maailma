extends SceneTree

## Checks that the hover reveal stays on screen however tall the card is.
##
## Needs no server — the card library is fed a fixed payload:
##   godot --headless --path apps/godot-client --script src/reveal_layout_test.gd
##
## The case that matters is a tall card revealed straight after a short one,
## low on the screen: the panel's final height is only known once its wrapped
## text has been laid out, and a reveal placed from the earlier, shorter
## measurement would hang off the bottom edge.

const SHORT := {
	"id": "short_card", "name": "Short", "type": "CREATURE", "cost": 1,
	"attack": 1, "health": 1, "tags": [], "keywords": [],
	"description": "No special abilities.",
}
const TALL := {
	"id": "tall_card", "name": "A Card With Rather A Lot To Say", "type": "CREATURE", "cost": 4,
	"attack": 3, "health": 4, "tags": ["HUMAN", "WARDEN"],
	"keywords": ["GUARD", "ARRIVAL", "WARD", "LIFESTEAL"],
	"description": "**Guard**, **Ward**, **Lifesteal**\n**Arrival:** Give adjacent friendly Creatures +1 Health, then give every other friendly Creature +1 Attack until the end of your turn, and restore 2 Health to your Hero for each Creature that was given Health this way.",
	"flavour": "The wall is only as strong as the one who stands beside you, and the one beside them, and the one beside them in turn, all the way down the line.",
}

var failures: Array[String] = []

func _init() -> void:
	await process_frame
	print("== reveal layout test ==")
	var library := CardLibrary.new()
	library.ingest([SHORT, TALL])
	var reveal := CardReveal.new()
	reveal.setup(library)
	get_root().add_child(reveal)
	await process_frame

	var view := reveal.get_viewport_rect().size
	# A card resting at the very bottom of the screen, as the player's own
	# back row does on a short window.
	var anchor := Rect2(Vector2(200.0, view.y - 90.0), Vector2(110.0, 80.0))

	# The short card first, so the tall one is measured against its layout.
	reveal.request("short", {"definition_id": "short_card"}, anchor)
	await _wait(CardReveal.DELAY + 0.1)
	_check("the short card is revealed", reveal.is_revealing())
	_check("the short card stays on screen", await _stays_on_screen(reveal, view))

	# Swapping while one is up reveals immediately — no dwell to hide behind.
	reveal.request("tall", {"definition_id": "tall_card"}, anchor)
	_check("the tall card replaces it", reveal.is_revealing() and reveal._shown_key == "tall")
	_check("the tall card stays on screen", await _stays_on_screen(reveal, view))
	# On screen is not enough: an oversized panel clamped to the top would pass
	# that check while trailing empty space off the bottom.
	_check("the panel hugs its content once laid out",
		is_equal_approx(reveal._panel.size.y, reveal._panel.get_combined_minimum_size().y))

	# And from nothing at all, the first reveal of a session.
	reveal.hide_reveal()
	reveal.request("tall-again", {"definition_id": "tall_card"}, anchor)
	await _wait(CardReveal.DELAY + 0.1)
	_check("a tall card revealed fresh stays on screen", await _stays_on_screen(reveal, view))

	print("%d failure(s)" % failures.size())
	for failure in failures:
		print("  FAIL: ", failure)
	print("RESULT: ", "PASS" if failures.is_empty() else "FAIL")
	quit(0 if failures.is_empty() else 1)

## Watches the panel for several frames, since the overflow appears only once
## layout catches up with the text; true if it never leaves the viewport.
func _stays_on_screen(reveal: CardReveal, view: Vector2) -> bool:
	var ok := true
	for frame in range(8):
		await process_frame
		var rect := Rect2(reveal._panel.global_position, reveal._panel.size)
		if rect.end.y > view.y + 0.5 or rect.position.y < -0.5:
			print("    frame %d: panel %s leaves a %s view" % [frame, rect, view])
			ok = false
	return ok

func _wait(seconds: float) -> void:
	await create_timer(seconds).timeout

func _check(label: String, condition: bool) -> void:
	print("  [%s] %s" % ["ok" if condition else "XX", label])
	if not condition:
		failures.append(label)
