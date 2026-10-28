extends Control
class_name CardFrame

## A card drawn as a printed card: its type's frame from `art/assets/`, the
## card's art in the frame's window, its name on the ribbon, its cost on the
## gem, its rarity on the gem in the middle, its stats — a Creature's Attack
## and Health, a Weapon's Attack and Durability, an Artifact's Durability —
## and its text in the box.
##
## Every part is placed as a fraction of the frame, so the same card draws at
## any size — a board slot, a hand card, or the large hover reveal. Nothing in
## it takes pointer input: the panel it sits in is what starts a drag.

const FRAME_PATH := "res://art/assets/creature_default.png"
const SPELL_FRAME_PATH := "res://art/assets/spell_default.png"
const WEAPON_FRAME_PATH := "res://art/assets/weapon_default.png"
const ARTIFACT_FRAME_PATH := "res://art/assets/artifact_default.png"
const LOCATION_FRAME_PATH := "res://art/assets/location_default.png"
const COST_PATH := "res://art/assets/taika_cost_gem.png"
const ATTACK_PATH := "res://art/assets/damage.png"
const HEALTH_PATH := "res://art/assets/health.png"
const DURABILITY_PATH := "res://art/assets/durability.png"
## The shield, cracked: an Artifact with no Durability left.
const DURABILITY_ZERO_PATH := "res://art/assets/durability_zero.png"
## A Location's duration: the turns it has left run out of the hourglass.
const HOURGLASS_PATH := "res://art/assets/hourglass.png"
## The rarity gem, coloured as Hearthstone's: white, blue, purple, orange. A
## Basic card prints none.
const RARITY_GEM_PATHS := {
	"COMMON": "res://art/assets/rarity_gem.png",
	"RARE": "res://art/assets/rarity_gem_rare.png",
	"EPIC": "res://art/assets/rarity_gem_epic.png",
	"LEGENDARY": "res://art/assets/rarity_gem_legendary.png",
}

## The frame images' width over their height: the Creature and Spell frames
## share this canvas. Every card is laid out at this shape, so cards of all
## types line up in a hand; `make` sizes it from a width. Each frame is drawn
## so its visible body — not the clear margin round it — fills the card as
## far as its shape allows, centred.
const ASPECT := 1080.0 / 1456.0

## How wide each badge is drawn, as a fraction of the frame's width, and where
## its number sits within the badge image, as fractions of the image: the
## centre of the gem, of the sword's roundel, and of the heart's face.
const COST_WIDTH := 0.27
const ATTACK_WIDTH := 0.24
const HEALTH_WIDTH := 0.2
const DURABILITY_WIDTH := 0.25
## The hourglass stands in the middle half of a square image, so it is drawn
## wider than it looks; its number sits on the glass's waist.
const HOURGLASS_WIDTH := 0.26
const COST_CENTRE := Vector2(0.5, 0.485)
const ATTACK_CENTRE := Vector2(0.49, 0.566)
const HEALTH_CENTRE := Vector2(0.487, 0.609)
const DURABILITY_CENTRE := Vector2(0.5, 0.47)
const HOURGLASS_CENTRE := Vector2(0.5, 0.5)
## The gem stands in the middle of a square image, its centre a little above
## the image's.
const RARITY_WIDTH := 0.14
const RARITY_CENTRE := Vector2(0.5, 0.484)

## Regions of the Creature frame, as fractions of its width and height: the
## art oval, the name on the ribbon beneath it, and the text box below that.
## The card itself is slimmer than its image, which is clear at the sides.
const BODY := Rect2(0.092, 0.0, 0.817, 0.96)
const ART_OVAL := Rect2(0.2237, 0.0601, 0.5488, 0.4827)
## The oval window is egg-shaped — fuller below than above — and cut flat by
## the ribbon, so no ellipse fits it; this outline is traced from the frame's
## gold edge, one point every 5 degrees.
const ART_OVAL_OUTLINE := [
	Vector2(0.999, 0.509), Vector2(1.000, 0.545), Vector2(0.998, 0.583), Vector2(0.995, 0.620),
	Vector2(0.990, 0.659), Vector2(0.980, 0.697), Vector2(0.968, 0.736), Vector2(0.953, 0.775),
	Vector2(0.935, 0.815), Vector2(0.909, 0.852), Vector2(0.882, 0.891), Vector2(0.849, 0.926),
	Vector2(0.810, 0.960), Vector2(0.767, 0.988), Vector2(0.714, 1.000), Vector2(0.657, 0.999),
	Vector2(0.604, 0.997), Vector2(0.552, 0.997), Vector2(0.502, 0.996), Vector2(0.451, 0.996),
	Vector2(0.400, 0.997), Vector2(0.346, 0.999), Vector2(0.290, 1.000), Vector2(0.235, 0.990),
	Vector2(0.192, 0.961), Vector2(0.154, 0.928), Vector2(0.120, 0.892), Vector2(0.092, 0.854),
	Vector2(0.068, 0.815), Vector2(0.049, 0.776), Vector2(0.032, 0.737), Vector2(0.020, 0.698),
	Vector2(0.012, 0.659), Vector2(0.005, 0.621), Vector2(0.002, 0.583), Vector2(0.000, 0.546),
	Vector2(0.001, 0.509), Vector2(0.003, 0.472), Vector2(0.008, 0.435), Vector2(0.014, 0.398),
	Vector2(0.024, 0.362), Vector2(0.035, 0.325), Vector2(0.049, 0.288), Vector2(0.067, 0.252),
	Vector2(0.087, 0.216), Vector2(0.113, 0.181), Vector2(0.141, 0.146), Vector2(0.174, 0.114),
	Vector2(0.212, 0.085), Vector2(0.253, 0.059), Vector2(0.298, 0.036), Vector2(0.346, 0.017),
	Vector2(0.396, 0.005), Vector2(0.449, 0.003), Vector2(0.502, 0.000), Vector2(0.554, 0.002),
	Vector2(0.607, 0.005), Vector2(0.658, 0.017), Vector2(0.706, 0.036), Vector2(0.750, 0.060),
	Vector2(0.791, 0.085), Vector2(0.828, 0.115), Vector2(0.861, 0.148), Vector2(0.889, 0.182),
	Vector2(0.913, 0.217), Vector2(0.933, 0.254), Vector2(0.951, 0.290), Vector2(0.967, 0.326),
	Vector2(0.976, 0.363), Vector2(0.985, 0.399), Vector2(0.991, 0.436), Vector2(0.995, 0.472),
]
const NAME_BAND := Rect2(0.21, 0.556, 0.58, 0.068)
## The text box runs to just inside the parchment's border; its lines narrow
## in steps as they pass down between the Attack and Health badges — past the
## sword's ribbon and the heart's crest, then between the two badges.
const TEXT_BOX := Rect2(0.16, 0.685, 0.68, 0.23)
const TEXT_NARROW := [Rect2(0.195, 0.83, 0.61, 0.085), Rect2(0.235, 0.86, 0.53, 0.055)]
## Where each badge's number sits, as fractions of the frame. Attack and
## Health sit on the card's lower corners, hanging a little past its bottom
## and sides as they do on a Hearthstone card.
const COST_AT := Vector2(0.17, 0.07)
## Each frame's rarity gem sits on the dark seam between its name and its
## text box, in the middle of the card, as a Hearthstone card's does.
const RARITY_AT := Vector2(0.5, 0.653)
const ATTACK_AT := Vector2(0.13, 0.915)
const HEALTH_AT := Vector2(0.84, 0.915)

## Regions of the Spell (Action) frame: a framed art panel, the name on the
## scroll beneath it, and the text box below that.
const SPELL_BODY := Rect2(0.034, 0.003, 0.933, 0.981)
const SPELL_ART := Rect2(0.226, 0.098, 0.548, 0.437)
const SPELL_ART_OUTLINE := [
	Vector2(0.03, 0.0), Vector2(0.97, 0.0), Vector2(1.0, 0.025), Vector2(1.0, 0.975),
	Vector2(0.97, 1.0), Vector2(0.03, 1.0), Vector2(0.0, 0.975), Vector2(0.0, 0.025),
]
const SPELL_NAME_BAND := Rect2(0.17, 0.556, 0.66, 0.07)
const SPELL_TEXT_BOX := Rect2(0.187, 0.695, 0.626, 0.175)
const SPELL_COST_AT := Vector2(0.115, 0.085)
## Set into the small diamond mount the frame has there.
const SPELL_RARITY_AT := Vector2(0.5, 0.648)

## Regions of the Weapon frame: a shield-shaped art window, the name plate,
## the text box, and the two roundels its Attack and Durability sit in.
const WEAPON_BODY := Rect2(0.01, 0.004, 0.98, 0.985)
const WEAPON_ART := Rect2(0.2585, 0.0856, 0.4822, 0.4579)
## The shield's top slopes up to two peaks either side of the frame's centre
## notch, and its corners are chamfered; traced from the dark line inside the
## gold edge.
const WEAPON_ART_OUTLINE := [
	Vector2(0.0, 0.162), Vector2(0.0185, 0.14), Vector2(0.415, 0.0), Vector2(0.5, 0.0685),
	Vector2(0.585, 0.0), Vector2(0.9815, 0.14), Vector2(1.0, 0.162), Vector2(1.0, 0.822),
	Vector2(0.9815, 0.847), Vector2(0.5, 1.0), Vector2(0.0185, 0.847), Vector2(0.0, 0.822),
]
const WEAPON_NAME_BAND := Rect2(0.24, 0.566, 0.52, 0.062)
## Its lines narrow in steps down the parchment's lower corners, which are
## cut in toward the chevron at its foot by the roundels' mounts.
const WEAPON_TEXT_BOX := Rect2(0.17, 0.672, 0.66, 0.163)
const WEAPON_TEXT_NARROW := [
	Rect2(0.19, 0.765, 0.62, 0.07), Rect2(0.225, 0.79, 0.55, 0.045), Rect2(0.25, 0.815, 0.5, 0.02),
]
const WEAPON_COST_AT := Vector2(0.115, 0.085)
const WEAPON_RARITY_AT := Vector2(0.5, 0.653)
const WEAPON_ATTACK_AT := Vector2(0.142, 0.862)
const WEAPON_DURABILITY_AT := Vector2(0.858, 0.862)

## Regions of the Artifact frame: an octagonal art window, the name plate, and
## the text box, with Durability on its shield badge on the card's lower right
## corner, hanging a little past its edges.
const ARTIFACT_BODY := Rect2(0.019, 0.001, 0.963, 0.968)
const ARTIFACT_ART := Rect2(0.165, 0.093, 0.667, 0.443)
const ARTIFACT_ART_OUTLINE := [
	Vector2(0.22, 0.0), Vector2(0.78, 0.0), Vector2(1.0, 0.26), Vector2(1.0, 0.74),
	Vector2(0.78, 1.0), Vector2(0.22, 1.0), Vector2(0.0, 0.74), Vector2(0.0, 0.26),
]
const ARTIFACT_NAME_BAND := Rect2(0.2, 0.562, 0.6, 0.058)
## Its lines narrow beside the Durability badge.
const ARTIFACT_TEXT_BOX := Rect2(0.112, 0.67, 0.776, 0.225)
const ARTIFACT_TEXT_NARROW := [Rect2(0.165, 0.868, 0.67, 0.027)]
const ARTIFACT_COST_AT := Vector2(0.115, 0.085)
const ARTIFACT_RARITY_AT := Vector2(0.5, 0.644)
const ARTIFACT_DURABILITY_AT := Vector2(0.92, 0.93)

## Regions of the Location frame: a pointed-arch art window, the name plate,
## and the text box, with the hourglass on the card's lower left corner and
## the Durability shield on its lower right — whichever of the two it has —
## each hanging a little past the card's edges.
const LOCATION_BODY := Rect2(0.008, 0.001, 0.984, 0.984)
const LOCATION_ART := Rect2(0.19, 0.114, 0.615, 0.438)
const LOCATION_ART_OUTLINE := [
	Vector2(0.5, 0.0), Vector2(0.656, 0.039), Vector2(0.776, 0.118), Vector2(0.857, 0.196),
	Vector2(0.925, 0.274), Vector2(0.964, 0.353), Vector2(1.0, 0.45), Vector2(1.0, 0.95),
	Vector2(0.95, 1.0), Vector2(0.05, 1.0), Vector2(0.0, 0.95), Vector2(0.0, 0.45),
	Vector2(0.036, 0.353), Vector2(0.075, 0.274), Vector2(0.143, 0.196), Vector2(0.224, 0.118),
	Vector2(0.344, 0.039),
]
const LOCATION_NAME_BAND := Rect2(0.19, 0.584, 0.62, 0.058)
## Its lines narrow between the hourglass and the shield.
const LOCATION_TEXT_BOX := Rect2(0.107, 0.69, 0.786, 0.195)
const LOCATION_TEXT_NARROW := [Rect2(0.125, 0.85, 0.75, 0.035), Rect2(0.155, 0.865, 0.69, 0.02)]
const LOCATION_COST_AT := Vector2(0.115, 0.085)
const LOCATION_RARITY_AT := Vector2(0.5, 0.664)
const LOCATION_DURATION_AT := Vector2(0.06, 0.935)
const LOCATION_DURABILITY_AT := Vector2(0.93, 0.935)

## Each framed card type's frame and where its parts go on it. The body is
## the card's visible extent within its image, which the ring hugs; the
## outline is the art window's shape, an empty one drawing it as an ellipse.
## The text box's lines take its full width, but one reaching down into a
## step of `narrow` takes only that step's width; the steps run from the
## highest down, and a frame with none keeps every line full.
const LAYOUTS := {
	"CREATURE": {
		"frame": FRAME_PATH, "body": BODY, "art": ART_OVAL, "outline": ART_OVAL_OUTLINE,
		"name": NAME_BAND, "text": TEXT_BOX, "narrow": TEXT_NARROW, "cost": COST_AT, "rarity": RARITY_AT,
	},
	"ACTION": {
		"frame": SPELL_FRAME_PATH, "body": SPELL_BODY, "art": SPELL_ART, "outline": SPELL_ART_OUTLINE,
		"name": SPELL_NAME_BAND, "text": SPELL_TEXT_BOX, "narrow": [], "cost": SPELL_COST_AT, "rarity": SPELL_RARITY_AT,
	},
	"WEAPON": {
		"frame": WEAPON_FRAME_PATH, "body": WEAPON_BODY, "art": WEAPON_ART, "outline": WEAPON_ART_OUTLINE,
		"name": WEAPON_NAME_BAND, "text": WEAPON_TEXT_BOX, "narrow": WEAPON_TEXT_NARROW, "cost": WEAPON_COST_AT, "rarity": WEAPON_RARITY_AT,
	},
	"ARTIFACT": {
		"frame": ARTIFACT_FRAME_PATH, "body": ARTIFACT_BODY, "art": ARTIFACT_ART, "outline": ARTIFACT_ART_OUTLINE,
		"name": ARTIFACT_NAME_BAND, "text": ARTIFACT_TEXT_BOX, "narrow": ARTIFACT_TEXT_NARROW, "cost": ARTIFACT_COST_AT, "rarity": ARTIFACT_RARITY_AT,
	},
	"LOCATION": {
		"frame": LOCATION_FRAME_PATH, "body": LOCATION_BODY, "art": LOCATION_ART, "outline": LOCATION_ART_OUTLINE,
		"name": LOCATION_NAME_BAND, "text": LOCATION_TEXT_BOX, "narrow": LOCATION_TEXT_NARROW, "cost": LOCATION_COST_AT, "rarity": LOCATION_RARITY_AT,
	},
}

const INK := Color(0.22, 0.14, 0.07)
const COLOR_BUFF := Color(0.52, 0.95, 0.60)
const COLOR_HURT := Color(1.0, 0.45, 0.42)
const COLOR_SHORT := Color(1.0, 0.45, 0.42)

## The smallest readable sizes. A name or tag line never shrinks below them,
## and is cut short past that; a card's rules shrink further rather than lose
## a word, and a detailed card reports rules smaller than readable through
## `rules_fit`, so the caller can show them again elsewhere.
const MIN_NAME_SIZE := 8
const MIN_TEXT_SIZE := 7
const MIN_RULES_SIZE := 9

## Full rules text in the box (the hover reveal), rather than keywords and
## markers only (a board or hand card, too small for sentences).
var detailed := false
## Whether the description fitted in the box at a readable size. Only
## meaningful on a detailed card.
var rules_fit := true
## A ring of colour round the card's visible body — ready, selected — drawn
## by the card itself, since a frame clear at its sides would let a rectangle
## behind it show as bars. Transparent draws no ring.
var ring_color := Color(0, 0, 0, 0):
	set(value):
		ring_color = value
		queue_redraw()
var ring_width := 4.0:
	set(value):
		ring_width = value
		queue_redraw()
## A drop shadow under the ring, for a card lifted above the others.
var ring_shadow := 0:
	set(value):
		ring_shadow = value
		queue_redraw()

## The card type whose frame is showing; a key of `LAYOUTS`.
var _kind := "CREATURE"
var _frame: TextureRect
var _art: ArtOval
## Hidden on a Basic card, and on one whose rarity the library does not know.
var _rarity: TextureRect
var _name: Label
var _text: RichTextLabel
## The card's tags — its tribes — on a line of their own along the bottom of
## the text box, as a tribe is printed on a Hearthstone card. Rules can ask
## for a tag, so it is shown on every card that has one, small or large.
var _tags: Label
var _cost: TextureRect
var _attack: TextureRect
var _health: TextureRect
var _durability: TextureRect
var _hourglass: TextureRect
var _cost_value: Label
var _attack_value: Label
var _health_value: Label
var _durability_value: Label
var _duration_value: Label

## The text the box shows, as words: each `{"pieces": [{text, bold, italic}],
## "space": bool}`, a word set in more than one emphasis — "**Guard**," —
## having a piece for each; `{"break": true}` is a line break in the text.
var _words: Array = []
## Lifts the rules down within the box, to centre them; set with the lines.
var _text_margin := StyleBoxEmpty.new()

## Loaded textures, so a board of cards loads each image once.
static var _textures: Dictionary = {}
## Normalized outer contours, traced once from each image's opaque pixels.
static var _outlines: Dictionary = {}
## Shared rasterized rings and shadows; hover animation only draws two quads.
static var _outline_layers: Dictionary = {}

## Whether a card is drawn with a frame: every card type the client knows
## has one.
static func supports(library: CardLibrary, definition_id: String) -> bool:
	return LAYOUTS.has(library.card_type(definition_id))

## A frame `width` wide showing `card`; see `show_card` for its fields.
static func make(library: CardLibrary, card: Dictionary, width: float, is_detailed := false) -> CardFrame:
	var frame := CardFrame.new()
	frame.detailed = is_detailed
	frame.custom_minimum_size = Vector2(width, roundf(width / ASPECT))
	# A container would otherwise stretch the card to fill it and break the
	# frame's shape; it stays at its own size, centred in whatever holds it.
	frame.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	frame.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	frame.show_card(library, card)
	return frame

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# The images are drawn far below their authored size; without mipmaps they
	# shimmer and lose their fine lines.
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS

	_frame = _image(FRAME_PATH)
	_frame.stretch_mode = TextureRect.STRETCH_SCALE
	add_child(_frame)

	_art = ArtOval.new()
	_art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_art)

	_name = Label.new()
	_name.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_name.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_name.add_theme_color_override("font_color", INK)
	add_child(_name)

	_text = RichTextLabel.new()
	_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_text.bbcode_enabled = true
	_text.scroll_active = false
	_text.clip_contents = true
	# The lines are broken and centred here, since how wide each may be
	# depends on where it falls; the label only draws them.
	_text.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_text.add_theme_stylebox_override("normal", _text_margin)
	_text.add_theme_color_override("default_color", INK)
	add_child(_text)

	_tags = Label.new()
	_tags.name = "Tags"
	_tags.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tags.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_tags.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_tags.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_tags.add_theme_color_override("font_color", INK)
	add_child(_tags)

	# Over the name and text, as a gem set into the frame would be: where a
	# long name or a full box runs into it, the gem stays whole.
	_rarity = _image(RARITY_GEM_PATHS["COMMON"])
	_rarity.name = "RarityGem"
	add_child(_rarity)

	_cost = _image(COST_PATH)
	add_child(_cost)
	_attack = _image(ATTACK_PATH)
	add_child(_attack)
	_health = _image(HEALTH_PATH)
	add_child(_health)
	_durability = _image(DURABILITY_PATH)
	add_child(_durability)
	_hourglass = _image(HOURGLASS_PATH)
	add_child(_hourglass)
	# The numbers go on last so no badge is drawn over another's number.
	_cost_value = _number()
	_attack_value = _number()
	_health_value = _number()
	_durability_value = _number()
	_duration_value = _number()

## Shows a card. `card` carries the same presentation fields as the hover
## reveal: definition_id, and where the card is in play, attack, health,
## max_health, durability, duration and marks. A card with none of the live fields shows
## its printed stats. `unaffordable` colours the cost, for a hand card the
## player cannot pay for yet.
func show_card(library: CardLibrary, card: Dictionary) -> void:
	var definition_id := str(card.get("definition_id", ""))
	_kind = library.card_type(definition_id)
	if not LAYOUTS.has(_kind):
		_kind = "CREATURE"
	var layout: Dictionary = LAYOUTS[_kind]
	_frame.texture = _texture(layout["frame"])
	_art.outline = layout["outline"]
	_name.text = library.card_name(definition_id)
	_art.texture = CardArt.texture_for(definition_id)
	_art.region = CardArt.FULL
	_tags.text = library.tag_line(definition_id)
	_tags.visible = _tags.text != ""
	var gem_path := str(RARITY_GEM_PATHS.get(library.rarity(definition_id), ""))
	_rarity.visible = gem_path != ""
	if _rarity.visible:
		_rarity.texture = _texture(gem_path)

	# A hand card's `cost` is what it costs now, which an aura may have
	# lowered; a discount shows in green, as a buffed stat does.
	var printed := library.cost(definition_id)
	var cost := int(card.get("cost", printed))
	_cost_value.text = str(cost)
	var cost_color := COLOR_BUFF if cost < printed else Color.WHITE
	_tint_number(_cost_value, COLOR_SHORT if bool(card.get("unaffordable", false)) else cost_color)

	# A Creature's Attack and Health sit on badges; a Weapon's Attack and
	# Durability in its frame's roundels; an Artifact's Durability on its
	# shield; a Location's duration on its hourglass and its Durability on its
	# shield, for whichever of the two it has; a Spell has none.
	var is_creature := _kind == "CREATURE"
	var is_weapon := _kind == "WEAPON"
	var is_artifact := _kind == "ARTIFACT"
	var is_location := _kind == "LOCATION"
	var shielded := is_artifact or (is_location and library.has_durability(definition_id))
	var timed := is_location and library.has_duration(definition_id)
	_attack.visible = is_creature
	_health.visible = is_creature
	_durability.visible = shielded
	_hourglass.visible = timed
	_attack_value.visible = is_creature or is_weapon
	_health_value.visible = is_creature
	_durability_value.visible = is_weapon or shielded
	_duration_value.visible = timed

	var base_attack := library.base_attack(definition_id)
	var attack := _int(card.get("attack", base_attack))
	_attack_value.text = str(attack)
	_tint_number(_attack_value, attack_color(attack, base_attack))
	if is_creature:
		var base_health := library.base_health(definition_id)
		var health := _int(card.get("health", base_health))
		var max_health := _int(card.get("max_health", maxi(health, base_health)))
		_health_value.text = str(health)
		_tint_number(_health_value, health_color(health, max_health, base_health))
	elif is_weapon or shielded:
		var base_durability := library.base_durability(definition_id)
		var durability := _int(card.get("durability", base_durability))
		_durability_value.text = str(durability)
		_tint_number(_durability_value, durability_color(durability, base_durability))
		_durability.texture = _texture(DURABILITY_ZERO_PATH if durability <= 0 else DURABILITY_PATH)
	if timed:
		var base_duration := library.base_duration(definition_id)
		var duration := _int(card.get("duration", base_duration))
		_duration_value.text = str(duration)
		_tint_number(_duration_value, durability_color(duration, base_duration))

	var spans: Array = []
	if detailed:
		spans = CardLibrary.description_spans(library.description(definition_id))
	else:
		# Sentences do not fit a small card, so it shows what the board always
		# showed: the keywords by name, and why a creature cannot act.
		var names: Array[String] = []
		for keyword in library.keywords(definition_id):
			names.append(str(keyword).capitalize())
		# A Weapon's reach is not a listed keyword, but reads like one.
		if is_weapon and library.is_ranged_weapon(definition_id):
			names.append("Ranged")
		if not names.is_empty():
			spans.append({"text": " · ".join(names), "bold": true, "italic": false})
		var marks := str(card.get("marks", ""))
		if marks != "":
			if not spans.is_empty():
				spans.append({"text": "\n", "bold": false, "italic": false})
			spans.append({"text": marks, "bold": false, "italic": true})
	_words = _split_words(spans)
	_layout()

## Shows `region` of `texture` — fractions of it — in the art window in place
## of the card's own art, for art that has been chosen or framed but not saved
## yet.
func show_art(texture: Texture2D, region := CardArt.FULL) -> void:
	_art.texture = texture
	_art.region = region

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_layout()

func _draw() -> void:
	draw_outline(self, Vector2.ZERO, ring_color, ring_width, ring_shadow)

## Draws behind the artwork, following the frame and its visible badges.
## The held-card cue uses the same cached textures in the hand's overlay.
func draw_outline(canvas: CanvasItem, offset: Vector2, color: Color, width: float, shadow := 0) -> void:
	if color.a <= 0.0 and shadow <= 0:
		return
	var durability_path := _durability.texture.resource_path if _durability.texture != null else ""
	# A Location's outline depends on which of its two badges it shows.
	var badges := "%s%s" % [int(_durability.visible), int(_hourglass.visible)]
	var key := "%s:%s:%s:%s:%s:%s" % [_kind, _card_size(), width, shadow, durability_path, badges]
	if not _outline_layers.has(key):
		_outline_layers[key] = _bake_outline(width, shadow)
	var layers: Dictionary = _outline_layers[key]
	var rect: Rect2 = layers["rect"]
	rect.position += offset
	if layers["shadow"] != null:
		canvas.draw_texture_rect(layers["shadow"], rect, false, Color.BLACK)
	if color.a > 0.0 and layers["ring"] != null:
		canvas.draw_texture_rect(layers["ring"], rect, false, color)

## SVG rasterization supplies round joins and antialiasing once, rather than
## submitting thousands of line/circle primitives on every rendered frame.
func _bake_outline(width: float, shadow: int) -> Dictionary:
	var contours: Array[PackedVector2Array] = []
	var bounds := Rect2(Vector2.ZERO, _card_size())
	for image: TextureRect in [_frame, _cost, _attack, _health, _durability, _hourglass]:
		if not image.visible or image.texture == null:
			continue
		var points := PackedVector2Array()
		for point: Vector2 in _texture_outline(image.texture):
			var at := image.position + point * image.size
			points.append(at)
			bounds = bounds.expand(at)
		if points.size() > 2:
			contours.append(points)
	bounds = bounds.grow(width + shadow + 2.0)
	bounds = Rect2(bounds.position.floor(), bounds.size.ceil() + Vector2.ONE)
	var paths := ""
	for points in contours:
		paths += "M"
		for index in points.size():
			var point := points[index] - bounds.position
			paths += "%s%.3f,%.3f" % ["" if index == 0 else "L", point.x, point.y]
		paths += "Z"
	return {
		"rect": bounds,
		"ring": _rasterize_outline(paths, bounds.size, width, 0),
		"shadow": _rasterize_outline(paths, bounds.size, width, shadow) if shadow > 0 else null,
	}

static func _rasterize_outline(paths: String, dimensions: Vector2, width: float, shadow: int) -> Texture2D:
	var svg := '<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d">' % [int(dimensions.x), int(dimensions.y)]
	var stroke := '<path d="%s" fill="none" stroke="white" stroke-width="%.3f" stroke-opacity="%.3f" stroke-linejoin="round" stroke-linecap="round"/>'
	if shadow > 0:
		for spread in range(shadow, 0, -2):
			svg += stroke % [paths, (width + spread) * 2.0, 0.08]
	else:
		svg += stroke % [paths, width * 2.0, 1.0]
	svg += "</svg>"
	var image := Image.new()
	var error := image.load_svg_from_string(svg, 2.0)
	if error != OK:
		push_error("Could not rasterize card outline: %s" % error)
		return null
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)

static func _texture_outline(texture: Texture2D) -> PackedVector2Array:
	var key := texture.resource_path
	if _outlines.has(key):
		return _outlines[key]
	var image := texture.get_image()
	if image.is_compressed():
		image.decompress()
	# Trace at card-display resolution, avoiding tiny specks in the source art.
	var fit := minf(256.0 / maxf(image.get_width(), image.get_height()), 1.0)
	image.resize(maxi(1, roundi(image.get_width() * fit)), maxi(1, roundi(image.get_height() * fit)))
	var mask := BitMap.new()
	mask.create_from_image_alpha(image, 0.5)
	var outline := PackedVector2Array()
	var largest := 0.0
	# Ignore detached flecks and interior holes in the source artwork.
	for polygon in mask.opaque_to_polygons(Rect2i(Vector2i.ZERO, image.get_size()), 1.0):
		var bounds := Rect2(polygon[0], Vector2.ZERO)
		for point in polygon:
			bounds = bounds.expand(point)
		var area := bounds.get_area()
		if area > largest:
			largest = area
			outline = polygon
	var dimensions := Vector2(image.get_size())
	for index in outline.size():
		outline[index] /= dimensions
	_outlines[key] = outline
	return outline

## Places every part for the card's current size, and fits its text.
func _layout() -> void:
	var card := _card_size()
	if card.x <= 0.0:
		return
	var layout: Dictionary = LAYOUTS[_kind]
	var frame := _frame_rect(card)
	queue_redraw()
	_frame.position = frame.position
	_frame.size = frame.size
	_place(_art, layout["art"], frame)
	var gem := frame.size.x * RARITY_WIDTH
	_rarity.size = Vector2(gem, gem)
	_rarity.position = frame.position + layout["rarity"] * frame.size - RARITY_CENTRE * _rarity.size

	# The name may spill past the ribbon's thin centre onto its curls; that
	# reads better than a name too small to make out.
	var band := _region(layout["name"], frame)
	var name_size := _fit_size(
		_name.text, band.size.x, INF, clampi(int(frame.size.y * 0.065), MIN_NAME_SIZE, 22), MIN_NAME_SIZE
	)
	_name.add_theme_font_size_override("font_size", name_size)
	# A label never draws shorter than its line, which on a small card is
	# taller than the ribbon; it is centred on the ribbon at whatever height
	# it takes.
	_name.size = Vector2(band.size.x, maxf(band.size.y, name_size * 1.5))
	_name.position = Vector2(band.position.x, band.get_center().y - _name.size.y * 0.5)

	# The tags take a band across the bottom of the text box, and the rules fit
	# into what is left above it.
	var box := _region(layout["text"], frame)
	var narrow: Array[Rect2] = []
	for step: Rect2 in layout["narrow"]:
		narrow.append(_region(step, frame))
	if _tags.visible:
		# One line at the box's foot, shrinking to fit between the badges as
		# the name does on its ribbon; past the smallest size it is cut short.
		var tag_width := narrow.back().size.x if not narrow.is_empty() else box.size.x
		var tag_size := _fit_size(
			_tags.text, tag_width, INF,
			clampi(int(frame.size.y * (0.032 if detailed else 0.05)), MIN_TEXT_SIZE, 13), MIN_TEXT_SIZE
		)
		var tag_band := minf(box.size.y * 0.4, tag_size * 1.5)
		_tags.add_theme_font_size_override("font_size", tag_size)
		# A label never draws shorter than its line; like the name, it is
		# centred on its band at whatever height it takes.
		_tags.size = Vector2(tag_width, maxf(tag_band, _tags.get_minimum_size().y))
		_tags.position = Vector2(box.get_center().x - tag_width * 0.5, box.end.y - tag_band * 0.5 - _tags.size.y * 0.5)
		box.size.y -= tag_band
	_text.position = box.position
	_text.size = box.size
	var largest := clampi(int(frame.size.y * (0.040 if detailed else 0.06)), MIN_TEXT_SIZE, 15)
	var smallest := MIN_RULES_SIZE if detailed else MIN_TEXT_SIZE
	# The largest size at which every word fits: a card's rules are never cut
	# short, however small that makes them. Below a readable size the caller
	# is told, so it can print them again beside the card.
	var rules := {}
	for font_size in range(largest, 0, -1):
		rules = _break_rules(box, narrow, font_size)
		if rules["fits"]:
			break
	rules_fit = rules["fits"] and int(rules["size"]) >= smallest
	for font_size in ["normal_font_size", "bold_font_size", "italics_font_size", "bold_italics_font_size"]:
		_text.add_theme_font_size_override(font_size, int(rules["size"]))
	_text_margin.content_margin_top = rules["top"] - box.position.y
	_text.text = "[center]%s[/center]" % _lines_bbcode(rules["lines"]) if not _words.is_empty() else ""

	var number_size := clampi(int(frame.size.x * 0.15), 9, 34)
	_badge(_cost, _cost_value, layout["cost"], COST_WIDTH, COST_CENTRE, frame, number_size)
	if _kind == "CREATURE":
		_badge(_attack, _attack_value, ATTACK_AT, ATTACK_WIDTH, ATTACK_CENTRE, frame, number_size)
		_badge(_health, _health_value, HEALTH_AT, HEALTH_WIDTH, HEALTH_CENTRE, frame, number_size)
	elif _kind == "WEAPON":
		var roundel := frame.size.x * ATTACK_WIDTH
		_place_number(_attack_value, frame.position + WEAPON_ATTACK_AT * frame.size, roundel, number_size)
		_place_number(_durability_value, frame.position + WEAPON_DURABILITY_AT * frame.size, roundel, number_size)
	elif _kind == "ARTIFACT":
		_badge(_durability, _durability_value, ARTIFACT_DURABILITY_AT, DURABILITY_WIDTH, DURABILITY_CENTRE, frame, number_size)
	elif _kind == "LOCATION":
		_badge(_hourglass, _duration_value, LOCATION_DURATION_AT, HOURGLASS_WIDTH, HOURGLASS_CENTRE, frame, number_size)
		_badge(_durability, _durability_value, LOCATION_DURABILITY_AT, DURABILITY_WIDTH, DURABILITY_CENTRE, frame, number_size)

## Where the frame image is drawn within the card: all of it for a frame of
## the card's own shape, otherwise as large as fits, centred.
##
## It is the body that is fitted, so a frame whose image has a wider margin on
## one side than the other still sits centred; the clear margin may spill
## past the card's edge.
func _frame_rect(card: Vector2) -> Rect2:
	var texture := _frame.texture
	if texture == null:
		return Rect2(Vector2.ZERO, card)
	var image := Vector2(texture.get_width(), texture.get_height())
	var body: Rect2 = LAYOUTS[_kind]["body"]
	var body_size := body.size * image
	var fit := minf(card.x / body_size.x, card.y / body_size.y)
	var drawn := image * fit
	return Rect2((card - body_size * fit) * 0.5 - body.position * drawn, drawn)

## The card's visible body, in its own coordinates.
func body_rect() -> Rect2:
	return _region(LAYOUTS[_kind]["body"], _frame_rect(_card_size()))

## The art window, in the card's own coordinates.
func art_rect() -> Rect2:
	return _region(LAYOUTS[_kind]["art"], _frame_rect(_card_size()))

## The card's size: its own once laid out, the size it asked for before then.
func _card_size() -> Vector2:
	return size if size.x > 0.0 else custom_minimum_size

## Draws `image` `width` (a fraction of the frame's width) wide, positioned so
## its `centre` lands on `at`, with `value` centred over that point.
func _badge(image: TextureRect, value: Label, at: Vector2, width: float, centre: Vector2, frame: Rect2, number_size: int) -> void:
	var texture := image.texture
	var drawn_width := frame.size.x * width
	var aspect := 1.0
	if texture != null:
		aspect = texture.get_width() / float(texture.get_height())
	image.size = Vector2(drawn_width, drawn_width / aspect)
	var point := frame.position + at * frame.size
	image.position = point - centre * image.size
	_place_number(value, point, drawn_width, number_size)

## Centres `value` on `point`, in a box `width` wide.
func _place_number(value: Label, point: Vector2, width: float, number_size: int) -> void:
	value.add_theme_font_size_override("font_size", number_size)
	value.add_theme_constant_override("outline_size", maxi(2, number_size / 4))
	value.size = Vector2(width, number_size * 1.6)
	value.position = point - value.size * 0.5

func _place(control: Control, region: Rect2, frame: Rect2) -> void:
	var placed := _region(region, frame)
	control.position = placed.position
	control.size = placed.size

## `region`, given as fractions of the frame, in the card's coordinates.
static func _region(region: Rect2, frame: Rect2) -> Rect2:
	return Rect2(frame.position + region.position * frame.size, region.size * frame.size)

## The largest font size from `largest` down to `smallest` at which `text`
## fits `width` by `height`; `smallest` when none does.
static func _fit_size(text: String, width: float, height: float, largest: int, smallest: int) -> int:
	if text == "":
		return largest
	for font_size in range(largest, smallest - 1, -1):
		if _fits(text, width, height, font_size):
			return font_size
	return smallest

static func _fits(text: String, width: float, height: float, font_size: int) -> bool:
	if text == "":
		return true
	var font := ThemeDB.fallback_font
	# Measured in the regular face; the bold keywords run wider, so leave room.
	var usable := width * 0.9
	if height == INF:
		return font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x <= usable
	var measured := font.get_multiline_string_size(
		text, HORIZONTAL_ALIGNMENT_CENTER, usable, font_size
	)
	return measured.x <= usable and measured.y <= height

## Splits runs of text into the words the rules are broken at; see `_words`.
static func _split_words(spans: Array) -> Array:
	var words: Array = []
	var pieces: Array = []
	var spaced := false
	for span: Dictionary in spans:
		var run := ""
		for character in str(span["text"]):
			if character != " " and character != "\n":
				run += character
				continue
			if run != "":
				pieces.append({"text": run, "bold": span["bold"], "italic": span["italic"]})
				run = ""
			if not pieces.is_empty():
				words.append({"pieces": pieces, "space": spaced})
				pieces = []
			spaced = character == " "
			if character == "\n":
				words.append({"break": true})
		if run != "":
			pieces.append({"text": run, "bold": span["bold"], "italic": span["italic"]})
	if not pieces.is_empty():
		words.append({"pieces": pieces, "space": spaced})
	return words

## The rules broken into lines at `font_size`, centred down `box`: each line
## as wide as the box, or as the lowest step of `narrow` it reaches down into.
## Returns the lines, the size, where the first line's top falls, and whether
## every line fitted.
##
## Where each line falls depends on how many there are, so the count is
## guessed and the break redone until the two agree.
func _break_rules(box: Rect2, narrow: Array[Rect2], font_size: int) -> Dictionary:
	var line_height := _text.get_theme_font("normal_font").get_height(font_size) \
		+ _text.get_theme_constant("line_separation")
	var count := 1
	var tried := {}
	var result := {}
	while true:
		var top := box.position.y + maxf(0.0, (box.size.y - count * line_height) * 0.5)
		result = _fill_lines(top, line_height, box, narrow, font_size)
		var lines: Array = result["lines"]
		tried[count] = true
		if lines.size() == count or tried.has(lines.size()):
			# Settled, or flipping between two counts: the lines as laid out
			# for this count are drawn where they were measured.
			result["top"] = top
			result["fits"] = result["fits"] and box.end.y - top >= lines.size() * line_height - 0.5
			break
		count = lines.size()
	result["size"] = font_size
	return result

## Fills lines greedily from `top`, a line `line_height` tall at a time.
func _fill_lines(top: float, line_height: float, box: Rect2, narrow: Array[Rect2], font_size: int) -> Dictionary:
	var lines: Array = [[]]
	var used := 0.0
	var fits := true
	var space := _text.get_theme_font("normal_font").get_string_size(" ", HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	for word: Dictionary in _words:
		if word.has("break"):
			lines.append([])
			used = 0.0
			continue
		var width := 0.0
		for piece: Dictionary in word["pieces"]:
			width += _rules_font(piece).get_string_size(
				piece["text"], HORIZONTAL_ALIGNMENT_LEFT, -1, font_size
			).x
		var line: Array = lines.back()
		var limit := _line_width(top + (lines.size() - 1) * line_height, line_height, box, narrow)
		var spaced := used + (space if word["space"] else 0.0) + width
		if line.is_empty() or spaced <= limit:
			line.append(word)
			used = width if line.size() == 1 else spaced
		else:
			lines.append([word])
			used = width
			limit = _line_width(top + (lines.size() - 1) * line_height, line_height, box, narrow)
		if used > limit:
			fits = false
	return {"lines": lines, "fits": fits}

## How wide a line whose top is at `line_top` may run: the box's width, or
## that of the lowest step of `narrow` its letters reach down into — the foot
## of a line is mostly space below them — less a sliver for the label's own
## rounding.
static func _line_width(line_top: float, line_height: float, box: Rect2, narrow: Array[Rect2]) -> float:
	var width := box.size.x
	for step in narrow:
		if line_top + line_height * 0.8 > step.position.y:
			width = step.size.x
	return width * 0.98

func _rules_font(piece: Dictionary) -> Font:
	if piece["bold"] and piece["italic"]:
		return _text.get_theme_font("bold_italics_font")
	if piece["bold"]:
		return _text.get_theme_font("bold_font")
	if piece["italic"]:
		return _text.get_theme_font("italics_font")
	return _text.get_theme_font("normal_font")

## Broken lines as BBCode, each piece in its own emphasis. A literal `[` is
## escaped so card text can never be read as a tag.
static func _lines_bbcode(lines: Array) -> String:
	var out: Array[String] = []
	for line: Array in lines:
		var text := ""
		for index in line.size():
			var word: Dictionary = line[index]
			if index > 0 and word["space"]:
				text += " "
			for piece: Dictionary in word["pieces"]:
				var part := str(piece["text"]).replace("[", "[lb]")
				if piece["italic"]:
					part = "[i]%s[/i]" % part
				if piece["bold"]:
					part = "[b]%s[/b]" % part
				text += part
		out.append(text)
	return "\n".join(out)

func _image(path: String) -> TextureRect:
	var rect := TextureRect.new()
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.texture = _texture(path)
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	return rect

func _number() -> Label:
	var label := Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_color_override("font_outline_color", Color(0.05, 0.03, 0.02))
	add_child(label)
	return label

func _tint_number(label: Label, color: Color) -> void:
	label.add_theme_color_override("font_color", color)

## A missing image draws nothing rather than failing the card: the numbers and
## text still say everything the badges would.
static func _texture(path: String) -> Texture2D:
	if _textures.has(path):
		return _textures[path]
	var found: Texture2D = null
	if ResourceLoader.exists(path):
		var resource := load(path)
		if resource is Texture2D:
			found = resource
	_textures[path] = found
	return found

## Stats drifting from the printed card are what a player scans the board for,
## so they are coloured the way the reveal colours them: buffed green, hurt or
## shrunk red.
static func attack_color(attack: int, base_attack: int) -> Color:
	if attack > base_attack:
		return COLOR_BUFF
	if attack < base_attack:
		return COLOR_HURT
	return Color.WHITE

static func health_color(health: int, max_health: int, base_health: int) -> Color:
	if health < max_health:
		return COLOR_HURT
	if max_health > base_health:
		return COLOR_BUFF
	return Color.WHITE

## A Weapon worn down from its printed Durability reads like a hurt creature.
static func durability_color(durability: int, base_durability: int) -> Color:
	if durability < base_durability:
		return COLOR_HURT
	if durability > base_durability:
		return COLOR_BUFF
	return Color.WHITE

## JSON numbers arrive as floats.
static func _int(value: Variant) -> int:
	match typeof(value):
		TYPE_FLOAT, TYPE_INT:
			return int(round(float(value)))
	return 0

## Draws a texture into an ellipse filling the control — or into `outline`,
## when one is given — cropped to cover it the way art banners are, rather
## than squashed to fit.
class ArtOval extends Control:
	const SEGMENTS := 64

	var texture: Texture2D:
		set(value):
			texture = value
			queue_redraw()
	## The window's corners as fractions of the control, in order around it;
	## empty for an ellipse.
	var outline: Array = []:
		set(value):
			outline = value
			queue_redraw()
	## The part of the texture drawn, as fractions of it.
	var region := CardArt.FULL:
		set(value):
			region = value
			queue_redraw()

	func _notification(what: int) -> void:
		if what == NOTIFICATION_RESIZED:
			queue_redraw()

	func _draw() -> void:
		if texture == null or size.x <= 0.0 or size.y <= 0.0 or not region.has_area():
			return
		var shown := CardArt.cover(texture.get_size() * region.size, size.x / size.y)
		var uv_origin := region.position + shown.position * region.size
		var uv_size := shown.size * region.size
		var units: Array = outline
		if units.is_empty():
			units = []
			for index in SEGMENTS:
				var angle := TAU * index / SEGMENTS
				units.append(Vector2(cos(angle), sin(angle)) * 0.5 + Vector2(0.5, 0.5))
		var points := PackedVector2Array()
		var uvs := PackedVector2Array()
		for unit: Vector2 in units:
			points.append(unit * size)
			uvs.append(uv_origin + unit * uv_size)
		draw_colored_polygon(points, Color.WHITE, uvs, texture)
