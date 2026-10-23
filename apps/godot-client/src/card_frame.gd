extends Control
class_name CardFrame

## A card drawn as a printed card: its type's frame from `art/assets/`, the
## card's art in the frame's window, its name on the ribbon, its cost on the
## gem, its stats — a Creature's Attack and Health, a Weapon's Attack and
## Durability, an Artifact's Durability — and its text in the box.
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
const COST_CENTRE := Vector2(0.5, 0.485)
const ATTACK_CENTRE := Vector2(0.49, 0.566)
const HEALTH_CENTRE := Vector2(0.487, 0.609)
const DURABILITY_CENTRE := Vector2(0.5, 0.47)

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
## Kept clear of the Attack and Health badges on the box's lower corners.
const TEXT_BOX := Rect2(0.25, 0.685, 0.5, 0.2)
## Where each badge's number sits, as fractions of the frame. Attack and
## Health stand on the text box's lower corners, inside the frame, so its thin
## bottom border and corner studs still show.
const COST_AT := Vector2(0.17, 0.07)
const ATTACK_AT := Vector2(0.2, 0.86)
const HEALTH_AT := Vector2(0.8, 0.86)

## Regions of the Spell (Action) frame: a framed art panel, the name on the
## scroll beneath it, and the text box below that.
const SPELL_BODY := Rect2(0.034, 0.003, 0.933, 0.981)
const SPELL_ART := Rect2(0.226, 0.098, 0.548, 0.437)
const SPELL_ART_OUTLINE := [
	Vector2(0.03, 0.0), Vector2(0.97, 0.0), Vector2(1.0, 0.025), Vector2(1.0, 0.975),
	Vector2(0.97, 1.0), Vector2(0.03, 1.0), Vector2(0.0, 0.975), Vector2(0.0, 0.025),
]
const SPELL_NAME_BAND := Rect2(0.17, 0.556, 0.66, 0.07)
const SPELL_TEXT_BOX := Rect2(0.2, 0.692, 0.6, 0.175)
const SPELL_COST_AT := Vector2(0.115, 0.085)

## Regions of the Weapon frame: a shield-shaped art window, the name plate,
## the text box, and the two roundels its Attack and Durability sit in.
const WEAPON_BODY := Rect2(0.01, 0.004, 0.98, 0.985)
const WEAPON_ART := Rect2(0.256, 0.126, 0.488, 0.413)
const WEAPON_ART_OUTLINE := [
	Vector2(0.0, 0.11), Vector2(0.09, 0.0), Vector2(0.91, 0.0), Vector2(1.0, 0.11),
	Vector2(1.0, 0.79), Vector2(0.5, 1.0), Vector2(0.0, 0.79),
]
const WEAPON_NAME_BAND := Rect2(0.24, 0.566, 0.52, 0.062)
## Kept clear of the roundels, which overlap the box's lower corners.
const WEAPON_TEXT_BOX := Rect2(0.25, 0.672, 0.5, 0.15)
const WEAPON_COST_AT := Vector2(0.115, 0.085)
const WEAPON_ATTACK_AT := Vector2(0.142, 0.862)
const WEAPON_DURABILITY_AT := Vector2(0.858, 0.862)

## Regions of the Artifact frame: an octagonal art window, the name plate, and
## the text box, with Durability on its shield badge at the box's lower right.
const ARTIFACT_BODY := Rect2(0.019, 0.001, 0.963, 0.968)
const ARTIFACT_ART := Rect2(0.165, 0.093, 0.667, 0.443)
const ARTIFACT_ART_OUTLINE := [
	Vector2(0.22, 0.0), Vector2(0.78, 0.0), Vector2(1.0, 0.26), Vector2(1.0, 0.74),
	Vector2(0.78, 1.0), Vector2(0.22, 1.0), Vector2(0.0, 0.74), Vector2(0.0, 0.26),
]
const ARTIFACT_NAME_BAND := Rect2(0.2, 0.562, 0.6, 0.058)
## Kept clear of the Durability badge.
const ARTIFACT_TEXT_BOX := Rect2(0.2, 0.67, 0.6, 0.2)
const ARTIFACT_COST_AT := Vector2(0.115, 0.085)
const ARTIFACT_DURABILITY_AT := Vector2(0.86, 0.885)

## Regions of the Location frame: a pointed-arch art window, the name plate,
## and the text box. Locations are not in the game yet; the frame is ready for
## when the server sends one.
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
const LOCATION_TEXT_BOX := Rect2(0.14, 0.69, 0.72, 0.19)
const LOCATION_COST_AT := Vector2(0.115, 0.085)

## Each framed card type's frame and where its parts go on it. The body is
## the card's visible extent within its image, which the ring hugs; the
## outline is the art window's shape, an empty one drawing it as an ellipse.
const LAYOUTS := {
	"CREATURE": {
		"frame": FRAME_PATH, "body": BODY, "art": ART_OVAL, "outline": ART_OVAL_OUTLINE,
		"name": NAME_BAND, "text": TEXT_BOX, "cost": COST_AT,
	},
	"ACTION": {
		"frame": SPELL_FRAME_PATH, "body": SPELL_BODY, "art": SPELL_ART, "outline": SPELL_ART_OUTLINE,
		"name": SPELL_NAME_BAND, "text": SPELL_TEXT_BOX, "cost": SPELL_COST_AT,
	},
	"WEAPON": {
		"frame": WEAPON_FRAME_PATH, "body": WEAPON_BODY, "art": WEAPON_ART, "outline": WEAPON_ART_OUTLINE,
		"name": WEAPON_NAME_BAND, "text": WEAPON_TEXT_BOX, "cost": WEAPON_COST_AT,
	},
	"ARTIFACT": {
		"frame": ARTIFACT_FRAME_PATH, "body": ARTIFACT_BODY, "art": ARTIFACT_ART, "outline": ARTIFACT_ART_OUTLINE,
		"name": ARTIFACT_NAME_BAND, "text": ARTIFACT_TEXT_BOX, "cost": ARTIFACT_COST_AT,
	},
	"LOCATION": {
		"frame": LOCATION_FRAME_PATH, "body": LOCATION_BODY, "art": LOCATION_ART, "outline": LOCATION_ART_OUTLINE,
		"name": LOCATION_NAME_BAND, "text": LOCATION_TEXT_BOX, "cost": LOCATION_COST_AT,
	},
}

const INK := Color(0.22, 0.14, 0.07)
const COLOR_BUFF := Color(0.52, 0.95, 0.60)
const COLOR_HURT := Color(1.0, 0.45, 0.42)
const COLOR_SHORT := Color(1.0, 0.45, 0.42)

## Text never shrinks below these sizes to fit; past that it is cut off, and a
## detailed card reports it through `rules_fit` so the caller can show it
## elsewhere.
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
var ring_width := 4.0
## A drop shadow under the ring, for a card lifted above the others.
var ring_shadow := 0

## The card type whose frame is showing; a key of `LAYOUTS`.
var _kind := "CREATURE"
var _frame: TextureRect
var _art: ArtOval
var _name: Label
var _text: RichTextLabel
var _cost: TextureRect
var _attack: TextureRect
var _health: TextureRect
var _durability: TextureRect
var _cost_value: Label
var _attack_value: Label
var _health_value: Label
var _durability_value: Label

## The text the box shows, kept plain as well so it can be measured.
var _text_bbcode := ""
var _text_plain := ""

## Loaded textures, so a board of cards loads each image once.
static var _textures: Dictionary = {}

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
	_text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_text.add_theme_color_override("default_color", INK)
	add_child(_text)

	_cost = _image(COST_PATH)
	add_child(_cost)
	_attack = _image(ATTACK_PATH)
	add_child(_attack)
	_health = _image(HEALTH_PATH)
	add_child(_health)
	_durability = _image(DURABILITY_PATH)
	add_child(_durability)
	# The numbers go on last so no badge is drawn over another's number.
	_cost_value = _number()
	_attack_value = _number()
	_health_value = _number()
	_durability_value = _number()

## Shows a card. `card` carries the same presentation fields as the hover
## reveal: definition_id, and where the card is in play, attack, health,
## max_health, durability and marks. A card with none of the live fields shows
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

	_cost_value.text = str(library.cost(definition_id))
	_tint_number(_cost_value, COLOR_SHORT if bool(card.get("unaffordable", false)) else Color.WHITE)

	# A Creature's Attack and Health sit on badges; a Weapon's Attack and
	# Durability in its frame's roundels; an Artifact's Durability on its
	# shield; a Spell or Location has none.
	var is_creature := _kind == "CREATURE"
	var is_weapon := _kind == "WEAPON"
	var is_artifact := _kind == "ARTIFACT"
	_attack.visible = is_creature
	_health.visible = is_creature
	_durability.visible = is_artifact
	_attack_value.visible = is_creature or is_weapon
	_health_value.visible = is_creature
	_durability_value.visible = is_weapon or is_artifact

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
	elif is_weapon or is_artifact:
		var base_durability := library.base_durability(definition_id)
		var durability := _int(card.get("durability", base_durability))
		_durability_value.text = str(durability)
		_tint_number(_durability_value, durability_color(durability, base_durability))
		_durability.texture = _texture(DURABILITY_ZERO_PATH if durability <= 0 else DURABILITY_PATH)

	if detailed:
		_text_bbcode = library.description_bbcode(definition_id)
		_text_plain = library.description_plain(definition_id)
	else:
		# Sentences do not fit a small card, so it shows what the board always
		# showed: the keywords by name, and why a creature cannot act.
		var lines: Array[String] = []
		var names: Array[String] = []
		for keyword in library.keywords(definition_id):
			names.append(str(keyword).capitalize())
		# A Weapon's reach is not a listed keyword, but reads like one.
		if is_weapon and library.is_ranged_weapon(definition_id):
			names.append("Ranged")
		if not names.is_empty():
			lines.append(" · ".join(names))
		var marks := str(card.get("marks", ""))
		if marks != "":
			lines.append(marks)
		_text_plain = "\n".join(lines)
		var bbcode_lines: Array[String] = []
		if not names.is_empty():
			bbcode_lines.append("[b]%s[/b]" % " · ".join(names))
		if marks != "":
			bbcode_lines.append("[i]%s[/i]" % marks)
		_text_bbcode = "\n".join(bbcode_lines)
	_layout()

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_layout()

func _draw() -> void:
	if ring_color.a <= 0.0 and ring_shadow <= 0:
		return
	var body := body_rect().grow(ring_width)
	var style := StyleBoxFlat.new()
	style.bg_color = ring_color
	style.set_corner_radius_all(int(ring_width) + 2)
	style.shadow_color = Color(0, 0, 0, 0.5)
	style.shadow_size = ring_shadow
	draw_style_box(style, body)

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

	_place(_text, layout["text"], frame)
	var largest := clampi(int(frame.size.y * (0.040 if detailed else 0.06)), MIN_TEXT_SIZE, 15)
	var smallest := MIN_RULES_SIZE if detailed else MIN_TEXT_SIZE
	var text_size := _fit_size(_text_plain, _text.size.x, _text.size.y, largest, smallest)
	rules_fit = _fits(_text_plain, _text.size.x, _text.size.y, text_size)
	for font_size in ["normal_font_size", "bold_font_size", "italics_font_size", "bold_italics_font_size"]:
		_text.add_theme_font_size_override(font_size, text_size)
	_text.text = "[center]%s[/center]" % _text_bbcode if _text_bbcode != "" else ""

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

	func _notification(what: int) -> void:
		if what == NOTIFICATION_RESIZED:
			queue_redraw()

	func _draw() -> void:
		if texture == null or size.x <= 0.0 or size.y <= 0.0:
			return
		var uv_size := Vector2.ONE
		var art_aspect := texture.get_width() / float(texture.get_height())
		var oval_aspect := size.x / size.y
		if art_aspect > oval_aspect:
			uv_size.x = oval_aspect / art_aspect
		else:
			uv_size.y = art_aspect / oval_aspect
		var uv_origin := (Vector2.ONE - uv_size) * 0.5
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
