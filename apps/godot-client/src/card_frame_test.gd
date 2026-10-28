extends SceneTree

## Checks the framed card at the sizes the client draws it.
##
## Needs no server — the card library is fed a fixed payload:
##   godot --headless --path apps/godot-client --script src/card_frame_test.gd
## Run it windowed with `-- --screenshot-dir=<dir>` to save what it drew.

const WOLF := {
	"id": "chicken", "name": "Wolf", "type": "CREATURE", "cost": 2, "rarity": "COMMON",
	"attack": 2, "health": 3, "tags": ["BEAST"], "keywords": ["SWIFT"],
	"description": "**Swift**",
}
const NO_ART := {
	"id": "nameless_recruit", "name": "Nameless Recruit", "type": "CREATURE", "cost": 1, "rarity": "BASIC",
	"attack": 1, "health": 1, "tags": [], "keywords": [],
	"description": "No special abilities.",
}
const WORDY := {
	"id": "wordy_warden", "name": "A Card With Rather A Lot To Say", "type": "CREATURE", "cost": 4, "rarity": "LEGENDARY",
	"attack": 3, "health": 4, "tags": ["HUMAN"],
	"keywords": ["GUARD", "ARRIVAL", "WARD", "LIFESTEAL"],
	"description": "**Guard**, **Ward**, **Lifesteal**\n**Arrival:** Give adjacent friendly Creatures +1 Health, then give every other friendly Creature +1 Attack until the end of your turn, and restore 2 Health to your Hero for each Creature that was given Health this way.",
}
## A description of the length that used to leave the box's sides empty.
const MERCY := {
	"id": "mercy", "name": "Mercy-4", "type": "CREATURE", "cost": 4, "rarity": "EPIC",
	"attack": 3, "health": 4, "tags": ["ANIMA", "CONSTRUCT"], "keywords": [],
	"description": "**Last Breath:** Restore 2 Health to your Hero and deal 1 damage to a random opponent.",
}
const SPELL := {
	"id": "firebolt", "name": "Firebolt", "type": "ACTION", "cost": 1, "rarity": "RARE",
	"tags": [], "keywords": [], "description": "Deal 2 damage.",
}
const WEAPON := {
	"id": "longbow", "name": "Longbow", "type": "WEAPON", "cost": 3, "rarity": "EPIC",
	"attack": 2, "durability": 3, "range": "RANGED", "tags": ["BOW"],
	"description": "**Ranged**",
}
const ARTIFACT := {
	"id": "totem", "name": "Totem", "type": "ARTIFACT", "cost": 2, "rarity": "COMMON",
	"durability": 3, "tags": [], "description": "At the end of your turn, heal 1.",
}
## A Location with both measures, and one with each alone.
const LOCATION := {
	"id": "old_keep", "name": "The Old Keep", "type": "LOCATION", "cost": 3, "rarity": "RARE",
	"durability": 2, "duration": 3,
	"tags": [], "description": "Give adjacent friendly Creatures +1 Health.",
}
const TIMED_LOCATION := {
	"id": "spring", "name": "Spring", "type": "LOCATION", "cost": 2, "duration": 2,
	"tags": [], "description": "At the start of your turn, restore 2 Health to your Hero.",
}
const SHIELDED_LOCATION := {
	"id": "tower", "name": "Tower", "type": "LOCATION", "cost": 2, "durability": 3,
	"tags": [], "description": "Deal 1 damage to an enemy character.",
}
const UNKNOWN := {
	"id": "mystery", "name": "Mystery", "type": "SOMETHING_NEW", "cost": 0,
	"tags": [], "description": "",
}

## The widths the client uses: a board slot, a hand card, the hover reveal.
const BOARD_WIDTH := 96.0
const REVEAL_WIDTH := 240.0

var failures: Array[String] = []

func _init() -> void:
	await process_frame
	print("== card frame test ==")
	var library := CardLibrary.new()
	library.ingest([
		WOLF, NO_ART, WORDY, MERCY, SPELL, WEAPON, ARTIFACT, LOCATION, TIMED_LOCATION, SHIELDED_LOCATION, UNKNOWN,
		{"id": "lio_like", "name": "Lio", "type": "CREATURE", "cost": 3, "attack": 2, "health": 3,
			"tags": ["DWARF", "MECHANIC", "REBEL"], "keywords": [], "description": "None."},
	])

	_check("creatures are framed", CardFrame.supports(library, "chicken"))
	_check("spells are framed", CardFrame.supports(library, "firebolt"))
	_check("weapons are framed", CardFrame.supports(library, "longbow"))
	_check("artifacts are framed", CardFrame.supports(library, "totem"))
	_check("locations are framed", CardFrame.supports(library, "old_keep"))
	_check("a type the client does not know is not framed", not CardFrame.supports(library, "mystery"))

	var row := HBoxContainer.new()
	row.position = Vector2(16, 16)
	row.add_theme_constant_override("separation", 12)
	get_root().add_child(row)

	# A creature in play: live stats, hurt and buffed.
	var hurt := CardFrame.make(library, {
		"definition_id": "chicken", "attack": 3, "health": 1, "max_health": 3, "marks": "sick",
	}, BOARD_WIDTH)
	row.add_child(hurt)
	# A hand card with no live stats, which the player cannot pay for.
	var printed := CardFrame.make(library, {"definition_id": "nameless_recruit", "unaffordable": true}, BOARD_WIDTH)
	row.add_child(printed)
	var crowded := CardFrame.make(library, {"definition_id": "wordy_warden"}, BOARD_WIDTH)
	row.add_child(crowded)
	var revealed := CardFrame.make(library, {"definition_id": "chicken"}, REVEAL_WIDTH, true)
	row.add_child(revealed)
	var revealed_wordy := CardFrame.make(library, {"definition_id": "wordy_warden"}, REVEAL_WIDTH, true)
	row.add_child(revealed_wordy)

	var second_row := HBoxContainer.new()
	second_row.position = Vector2(16, 16 + roundf(REVEAL_WIDTH / CardFrame.ASPECT) + 16)
	second_row.add_theme_constant_override("separation", 12)
	get_root().add_child(second_row)
	var spell := CardFrame.make(library, {"definition_id": "firebolt"}, BOARD_WIDTH)
	second_row.add_child(spell)
	# An equipped Weapon, worn down by a swing.
	var worn := CardFrame.make(library, {"definition_id": "longbow", "attack": 2, "durability": 1}, BOARD_WIDTH)
	second_row.add_child(worn)
	var revealed_spell := CardFrame.make(library, {"definition_id": "firebolt"}, REVEAL_WIDTH, true)
	second_row.add_child(revealed_spell)
	var revealed_weapon := CardFrame.make(library, {"definition_id": "longbow"}, REVEAL_WIDTH, true)
	second_row.add_child(revealed_weapon)

	var third_row := HBoxContainer.new()
	third_row.position = second_row.position + Vector2(0, roundf(REVEAL_WIDTH / CardFrame.ASPECT) + 16)
	third_row.add_theme_constant_override("separation", 12)
	get_root().add_child(third_row)
	# An Artifact in play with nothing left, beside one as printed.
	var spent := CardFrame.make(library, {"definition_id": "totem", "durability": 0}, BOARD_WIDTH)
	third_row.add_child(spent)
	# A Location in play, used once and a turn older.
	var location := CardFrame.make(library, {"definition_id": "old_keep", "durability": 1, "duration": 2}, BOARD_WIDTH)
	third_row.add_child(location)
	var timed := CardFrame.make(library, {"definition_id": "spring"}, BOARD_WIDTH)
	third_row.add_child(timed)
	var shielded := CardFrame.make(library, {"definition_id": "tower"}, BOARD_WIDTH)
	third_row.add_child(shielded)
	var revealed_artifact := CardFrame.make(library, {"definition_id": "totem"}, REVEAL_WIDTH, true)
	third_row.add_child(revealed_artifact)
	var revealed_location := CardFrame.make(library, {"definition_id": "old_keep"}, REVEAL_WIDTH, true)
	third_row.add_child(revealed_location)

	# A ready card's ring, which the card draws round its own body.
	for ringed in [hurt, spell, worn, spent, location]:
		ringed.ring_color = Color(0.45, 0.85, 0.55)
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
	var mercy := CardFrame.make(library, {"definition_id": "mercy"}, REVEAL_WIDTH, true)
	row.add_child(mercy)
	await process_frame
	_check("a description of a few lines fits the box", mercy.rules_fit)
	_check("the rules run wider than the old box between the badges",
		_widest_line(mercy) > mercy._frame.size.x * 0.5)
	_check("the label draws the lines as they were broken",
		mercy._text.get_line_count() == mercy._text.get_parsed_text().split("\n").size())
	for card: CardFrame in [mercy, revealed_wordy, crowded]:
		_check("%s's lines keep clear of the badges" % card._name.text, _lines_clear_badges(card))
	_check("the rules start no higher than the box", mercy._text_margin.content_margin_top >= 0.0)
	var wordy_size := revealed_wordy._text.get_theme_font_size("normal_font_size")
	var wordy_lines := revealed_wordy._text.get_parsed_text().split("\n")
	_check("a description too long for the box shrinks until every word of it is on the card",
		" ".join(revealed_wordy._text.get_parsed_text().split("\n")).replace("  ", " ")
				== library.description_plain("wordy_warden").replace("\n", " ")
			and wordy_size < CardFrame.MIN_RULES_SIZE
			and revealed_wordy._text_margin.content_margin_top
				+ wordy_lines.size() * revealed_wordy._text.get_theme_font("normal_font").get_height(wordy_size)
				<= revealed_wordy._text.size.y + 0.5
			and revealed_wordy._text.get_line_count() == wordy_lines.size())
	_check("the frame takes no pointer input", _ignores_mouse(hurt))
	# The creature image has a clear margin below the card and none above it;
	# it is the card, not the image, that is centred.
	_check("a creature's body fills the card's height, centred", _fills(hurt, false))
	_check("the art oval is reported where it is drawn", hurt.art_rect() == hurt._art.get_rect())
	var box := CardFrame._region(CardFrame.TEXT_BOX, revealed._frame.get_rect())
	# The rules end where the tags' band begins; the tags sit centred on that band.
	var tag_line := revealed._tags.get_rect().get_center().y
	_check("a card's tags print along the bottom of its text box",
		revealed._tags.visible and revealed._tags.text == "Beast"
			and tag_line > revealed._text.get_rect().end.y and tag_line < box.end.y
			and is_equal_approx(
				tag_line, (revealed._text.get_rect().end.y + box.end.y) * 0.5))
	_check("a small card prints its tags too", hurt._tags.visible and hurt._tags.text == "Beast")
	_check("a Weapon's tags are not printed", not revealed_weapon._tags.visible and library.tags("longbow") == ["BOW"])
	_check("a card without tags prints none, and its rules keep the whole box",
		not printed._tags.visible
			and printed._text.get_rect().is_equal_approx(
				CardFrame._region(CardFrame.TEXT_BOX, printed._frame.get_rect())))
	_check("several tags print on one line, as words",
		library.tag_line("lio_like") == "Dwarf · Mechanic · Rebel")

	_check("a spell keeps the card's shape",
		is_equal_approx(roundf(BOARD_WIDTH / CardFrame.ASPECT), spell.size.y))
	_check("a spell is drawn on the spell frame",
		spell._frame.texture != null and spell._frame.texture == CardFrame._texture(CardFrame.SPELL_FRAME_PATH))
	_check("a spell shows no stats",
		not spell._attack_value.visible and not spell._health_value.visible and not spell._durability_value.visible)
	_check("a spell still shows its cost", spell._cost_value.visible and spell._cost_value.text == "1")
	_check("a detailed spell prints its description",
		revealed_spell._text.get_parsed_text().contains("Deal 2 damage"))
	_check("a weapon is drawn on the weapon frame",
		worn._frame.texture != null and worn._frame.texture == CardFrame._texture(CardFrame.WEAPON_FRAME_PATH))
	_check("a weapon keeps the card's size", is_equal_approx(roundf(BOARD_WIDTH / CardFrame.ASPECT), worn.size.y))
	_check("a weapon's body fills the card's width, centred", _fills(worn, true))
	_check("a weapon shows Attack and Durability, not Health",
		worn._attack_value.visible and worn._durability_value.visible and not worn._health_value.visible
		and not worn._attack.visible and not worn._health.visible)
	_check("a weapon shows its live stats", worn._attack_value.text == "2" and worn._durability_value.text == "1")
	_check("a worn Durability is coloured as hurt",
		worn._durability_value.get_theme_color("font_color") == CardFrame.COLOR_HURT)
	_check("a weapon in hand shows its printed Durability", revealed_weapon._durability_value.text == "3")
	_check("a small weapon card says it is Ranged", worn._text.get_parsed_text().contains("Ranged"))

	_check("an artifact is drawn on the artifact frame",
		spent._frame.texture != null and spent._frame.texture == CardFrame._texture(CardFrame.ARTIFACT_FRAME_PATH))
	_check("an artifact shows Durability on its shield, and nothing else",
		spent._durability.visible and spent._durability_value.visible and not spent._attack_value.visible
		and not spent._health_value.visible)
	_check("an artifact in hand shows its printed Durability", revealed_artifact._durability_value.text == "3")
	_check("an artifact with no Durability left shows the cracked shield",
		spent._durability.texture != null
		and spent._durability.texture == CardFrame._texture(CardFrame.DURABILITY_ZERO_PATH)
		and spent._durability_value.text == "0")
	_check("a whole artifact shows the whole shield",
		revealed_artifact._durability.texture == CardFrame._texture(CardFrame.DURABILITY_PATH))
	_check("a location is drawn on the location frame",
		location._frame.texture != null and location._frame.texture == CardFrame._texture(CardFrame.LOCATION_FRAME_PATH))
	_check("a location shows no Attack or Health",
		not location._attack_value.visible and not location._health_value.visible
		and not location._attack.visible and not location._health.visible)
	_check("a location with both measures shows the hourglass and the shield",
		location._hourglass.visible and location._duration_value.visible
		and location._durability.visible and location._durability_value.visible)
	_check("the hourglass image loads",
		location._hourglass.texture != null and location._hourglass.texture == CardFrame._texture(CardFrame.HOURGLASS_PATH))
	_check("the hourglass is on the left and the shield on the right",
		location._hourglass.get_rect().get_center().x < location.size.x * 0.5
		and location._durability.get_rect().get_center().x > location.size.x * 0.5)
	_check("a location in play shows what it has left",
		location._duration_value.text == "2" and location._durability_value.text == "1")
	_check("a location worn down is coloured as hurt",
		location._duration_value.get_theme_color("font_color") == CardFrame.COLOR_HURT
		and location._durability_value.get_theme_color("font_color") == CardFrame.COLOR_HURT)
	_check("a location in hand shows its printed measures",
		revealed_location._duration_value.text == "3" and revealed_location._durability_value.text == "2")
	_check("a location with only a duration shows only the hourglass",
		timed._hourglass.visible and timed._duration_value.text == "2"
		and not timed._durability.visible and not timed._durability_value.visible)
	_check("a location with only Durability shows only the shield",
		shielded._durability.visible and shielded._durability_value.text == "3"
		and not shielded._hourglass.visible and not shielded._duration_value.visible)
	_check("a detailed location prints its description",
		revealed_location._text.get_parsed_text().contains("+1 Health"))

	var gems := {"COMMON": hurt, "RARE": spell, "EPIC": worn, "LEGENDARY": crowded}
	for rarity: String in gems:
		var gem: TextureRect = gems[rarity]._rarity
		_check("a %s card shows its own gem" % rarity.capitalize(),
			gem.visible and gem.texture != null
				and gem.texture == CardFrame._texture(CardFrame.RARITY_GEM_PATHS[rarity]))
	_check("each rarity has a gem of its own",
		hurt._rarity.texture != spell._rarity.texture and spell._rarity.texture != worn._rarity.texture
			and worn._rarity.texture != crowded._rarity.texture)
	_check("the gem is drawn over the name and the text",
		hurt._rarity.get_index() > hurt._name.get_index() and hurt._rarity.get_index() > hurt._text.get_index()
			and hurt._rarity.get_index() > hurt._tags.get_index())
	_check("a Basic card prints no gem", not printed._rarity.visible)
	_check("a card of unknown rarity prints no gem", not shielded._rarity.visible)
	# Centred across the card, on the seam between the name and the text box.
	for card: CardFrame in [hurt, revealed, spell, worn, spent, location]:
		var at := card._rarity.position + CardFrame.RARITY_CENTRE * card._rarity.size
		var layout: Dictionary = CardFrame.LAYOUTS[card._kind]
		var frame := card._frame.get_rect()
		_check("the %s gem sits in the middle, between name and text" % card._kind.to_lower(),
			absf(at.x - card.size.x * 0.5) < 1.0
				and at.y > CardFrame._region(layout["name"], frame).get_center().y
				and at.y < CardFrame._region(layout["text"], frame).position.y)

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

## Whether `card`'s visible body spans its full width (or height) and is
## centred along the other.
func _fills(card: CardFrame, across: bool) -> bool:
	var body := card.body_rect()
	var centred := body.get_center().distance_to(card.size * 0.5) < 0.5
	if across:
		return centred and absf(body.size.x - card.size.x) < 0.5 and body.size.y <= card.size.y + 0.5
	return centred and absf(body.size.y - card.size.y) < 0.5 and body.size.x <= card.size.x + 0.5

## The widest line of `card`'s rules, measured in the bold face so emphasis
## never makes a line look narrower than it is.
func _widest_line(card: CardFrame) -> float:
	var font := card._text.get_theme_font("bold_font")
	var size := card._text.get_theme_font_size("normal_font_size")
	var widest := 0.0
	for line in card._text.get_parsed_text().split("
"):
		widest = maxf(widest, font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x)
	return widest

## Whether every line of `card`'s rules is no wider than the box allows at the
## height it is drawn: the narrower width beside the badges.
func _lines_clear_badges(card: CardFrame) -> bool:
	var layout: Dictionary = CardFrame.LAYOUTS[card._kind]
	var box := card._text.get_rect()
	var size := card._text.get_theme_font_size("normal_font_size")
	var line_height := card._text.get_theme_font("normal_font").get_height(size)
	var top := box.position.y + card._text_margin.content_margin_top
	var lines := card._text.get_parsed_text().split("\n")
	var font := card._text.get_theme_font("normal_font")
	for index in lines.size():
		var line_top := top + index * line_height
		var allowed := box.size.x
		for step: Rect2 in layout["narrow"]:
			if line_top + line_height * 0.8 > CardFrame._region(step, card._frame.get_rect()).position.y:
				allowed = CardFrame._region(step, card._frame.get_rect()).size.x
		if font.get_string_size(lines[index], HORIZONTAL_ALIGNMENT_LEFT, -1, size).x > allowed:
			return false
	return true

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
