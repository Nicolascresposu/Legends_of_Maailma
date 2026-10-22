extends SceneTree

## Checks the framed card at the sizes the client draws it.
##
## Needs no server — the card library is fed a fixed payload:
##   godot --headless --path apps/godot-client --script src/card_frame_test.gd
## Run it windowed with `-- --screenshot-dir=<dir>` to save what it drew.

const WOLF := {
	"id": "wolf", "name": "Wolf", "type": "CREATURE", "cost": 2,
	"attack": 2, "health": 3, "tags": ["BEAST"], "keywords": ["SWIFT"],
	"description": "**Swift**",
}
const NO_ART := {
	"id": "nameless_recruit", "name": "Nameless Recruit", "type": "CREATURE", "cost": 1,
	"attack": 1, "health": 1, "tags": [], "keywords": [],
	"description": "No special abilities.",
}
const WORDY := {
	"id": "wordy_warden", "name": "A Card With Rather A Lot To Say", "type": "CREATURE", "cost": 4,
	"attack": 3, "health": 4, "tags": ["HUMAN"],
	"keywords": ["GUARD", "ARRIVAL", "WARD", "LIFESTEAL"],
	"description": "**Guard**, **Ward**, **Lifesteal**\n**Arrival:** Give adjacent friendly Creatures +1 Health, then give every other friendly Creature +1 Attack until the end of your turn, and restore 2 Health to your Hero for each Creature that was given Health this way.",
}
const SPELL := {
	"id": "firebolt", "name": "Firebolt", "type": "SPELL", "cost": 1,
	"tags": [], "keywords": [], "description": "Deal 2 damage.",
}

## The widths the client uses: a board slot, a hand card, the hover reveal.
const BOARD_WIDTH := 96.0
const REVEAL_WIDTH := 240.0

var failures: Array[String] = []

func _init() -> void:
	await process_frame
	print("== card frame test ==")
	var library := CardLibrary.new()
	library.ingest([WOLF, NO_ART, WORDY, SPELL])

	_check("creatures are framed", CardFrame.supports(library, "wolf"))
	_check("spells are not framed yet", not CardFrame.supports(library, "firebolt"))

	var row := HBoxContainer.new()
	row.position = Vector2(16, 16)
	row.add_theme_constant_override("separation", 12)
	get_root().add_child(row)

	# A creature in play: live stats, hurt and buffed.
	var hurt := CardFrame.make(library, {
		"definition_id": "wolf", "attack": 3, "health": 1, "max_health": 3, "marks": "sick",
	}, BOARD_WIDTH)
	row.add_child(hurt)
	# A hand card with no live stats, which the player cannot pay for.
	var printed := CardFrame.make(library, {"definition_id": "nameless_recruit", "unaffordable": true}, BOARD_WIDTH)
	row.add_child(printed)
	var crowded := CardFrame.make(library, {"definition_id": "wordy_warden"}, BOARD_WIDTH)
	row.add_child(crowded)
	var revealed := CardFrame.make(library, {"definition_id": "wolf"}, REVEAL_WIDTH, true)
	row.add_child(revealed)
	var revealed_wordy := CardFrame.make(library, {"definition_id": "wordy_warden"}, REVEAL_WIDTH, true)
	row.add_child(revealed_wordy)
	await process_frame
	await process_frame

	_check("a card keeps the frame's shape",
		is_equal_approx(roundf(BOARD_WIDTH / CardFrame.ASPECT), hurt.size.y))
	_check("the frame image loads", hurt._frame.texture != null)
	_check("every badge image loads",
		hurt._cost.texture != null and hurt._attack.texture != null and hurt._health.texture != null)
	_check("a card with art shows it", hurt._art.texture != null)
	_check("a card without art shows none", printed._art.texture == null)
	_check("the name is on the ribbon", hurt._name.text == "Wolf")
	_check("live stats are shown", hurt._attack_value.text == "3" and hurt._health_value.text == "1")
	_check("a buffed Attack is coloured as a buff",
		hurt._attack_value.get_theme_color("font_color") == CardFrame.COLOR_BUFF)
	_check("a damaged creature's Health is coloured as hurt",
		hurt._health_value.get_theme_color("font_color") == CardFrame.COLOR_HURT)
	_check("printed stats are shown where there are no live ones",
		printed._attack_value.text == "1" and printed._health_value.text == "1")
	_check("printed stats are not coloured",
		printed._attack_value.get_theme_color("font_color") == Color.WHITE)
	_check("an unaffordable cost is coloured",
		printed._cost_value.get_theme_color("font_color") == CardFrame.COLOR_SHORT)
	_check("a small card names its keywords and markers",
		hurt._text.get_parsed_text().contains("Swift") and hurt._text.get_parsed_text().contains("sick"))
	_check("a small card leaves out sentences",
		not crowded._text.get_parsed_text().contains("adjacent"))
	_check("a detailed card prints its description",
		revealed._text.get_parsed_text().contains("Swift") and revealed.rules_fit)
	_check("a description too long for the box says so", not revealed_wordy.rules_fit)
	_check("the frame takes no pointer input", _ignores_mouse(hurt))

	var shots := _arg("--screenshot-dir=")
	if shots != "" and DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		var path := shots.path_join("card_frames.png")
		get_root().get_texture().get_image().save_png(path)
		print("  saved ", path)

	print("%d failure(s)" % failures.size())
	for failure in failures:
		print("  FAIL: ", failure)
	print("RESULT: ", "PASS" if failures.is_empty() else "FAIL")
	quit(0 if failures.is_empty() else 1)

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
