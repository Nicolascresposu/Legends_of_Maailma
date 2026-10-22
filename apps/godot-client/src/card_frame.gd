extends Control
class_name CardFrame

## A Creature drawn as a printed card: the frame from `art/assets/`, the card's
## art in the oval window, its name on the ribbon, its cost on the gem, Attack
## and Health on their badges, and its text in the box.
##
## Every part is placed as a fraction of the frame, so the same card draws at
## any size — a board slot, a hand card, or the large hover reveal. Nothing in
## it takes pointer input: the panel it sits in is what starts a drag.

const FRAME_PATH := "res://art/assets/card_default.png"
const COST_PATH := "res://art/assets/taika_cost_gem.png"
const ATTACK_PATH := "res://art/assets/damage.png"
const HEALTH_PATH := "res://art/assets/health.png"

## The frame image's width over its height. A card is always drawn at this
## shape; `make` sizes it from a width.
const ASPECT := 805.0 / 1086.0

## Regions of the frame, as fractions of its width and height.
const ART_OVAL := Rect2(0.150, 0.141, 0.696, 0.523)
## The name starts clear of the cost gem, which overlaps the ribbon's left end.
const NAME_BAND := Rect2(0.215, 0.060, 0.63, 0.066)
const TEXT_BOX := Rect2(0.235, 0.705, 0.53, 0.172)

## Where each badge's number sits, as fractions of the card, and how wide the
## badge is drawn, as a fraction of the card's width.
const COST_AT := Vector2(0.115, 0.085)
const ATTACK_AT := Vector2(0.105, 0.885)
const HEALTH_AT := Vector2(0.895, 0.885)
const COST_WIDTH := 0.27
const ATTACK_WIDTH := 0.27
const HEALTH_WIDTH := 0.23
## Where the number sits within each badge image, as fractions of the image:
## the centre of the gem, of the sword's roundel, and of the heart's face.
const COST_CENTRE := Vector2(0.5, 0.485)
const ATTACK_CENTRE := Vector2(0.49, 0.566)
const HEALTH_CENTRE := Vector2(0.487, 0.609)

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

var _frame: TextureRect
var _art: ArtOval
var _name: Label
var _text: RichTextLabel
var _cost: TextureRect
var _attack: TextureRect
var _health: TextureRect
var _cost_value: Label
var _attack_value: Label
var _health_value: Label

## The text the box shows, kept plain as well so it can be measured.
var _text_bbcode := ""
var _text_plain := ""

## Loaded textures, so a board of cards loads each image once.
static var _textures: Dictionary = {}

## Whether a card is drawn with the frame. Only Creatures are, for now: the
## frame's badges are Attack and Health.
static func supports(library: CardLibrary, definition_id: String) -> bool:
	return library.card_type(definition_id) == "CREATURE"

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
	# The numbers go on last so no badge is drawn over another's number.
	_cost_value = _number()
	_attack_value = _number()
	_health_value = _number()

## Shows a card. `card` carries the same presentation fields as the hover
## reveal: definition_id, and where the card is in play, attack, health,
## max_health and marks. A card with none of the live fields shows its printed
## stats. `unaffordable` colours the cost, for a hand card the player cannot
## pay for yet.
func show_card(library: CardLibrary, card: Dictionary) -> void:
	var definition_id := str(card.get("definition_id", ""))
	_name.text = library.card_name(definition_id)
	_art.texture = CardArt.texture_for(definition_id)

	_cost_value.text = str(library.cost(definition_id))
	_tint_number(_cost_value, COLOR_SHORT if bool(card.get("unaffordable", false)) else Color.WHITE)

	var base_attack := library.base_attack(definition_id)
	var base_health := library.base_health(definition_id)
	var attack := _int(card.get("attack", base_attack))
	var health := _int(card.get("health", base_health))
	var max_health := _int(card.get("max_health", maxi(health, base_health)))
	_attack_value.text = str(attack)
	_health_value.text = str(health)
	# Stats drifting from the printed card are what a player scans the board
	# for, so they are coloured the way the reveal colours them.
	var attack_color := Color.WHITE
	if attack > base_attack:
		attack_color = COLOR_BUFF
	elif attack < base_attack:
		attack_color = COLOR_HURT
	_tint_number(_attack_value, attack_color)
	var health_color := Color.WHITE
	if health < max_health:
		health_color = COLOR_HURT
	elif max_health > base_health:
		health_color = COLOR_BUFF
	_tint_number(_health_value, health_color)

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

## Places every part for the card's current size, and fits its text.
func _layout() -> void:
	var card := size if size.x > 0.0 else custom_minimum_size
	if card.x <= 0.0:
		return
	_frame.position = Vector2.ZERO
	_frame.size = card
	_place(_art, ART_OVAL, card)

	# The name may spill past the ribbon's thin centre onto its curls; that
	# reads better than a name too small to make out.
	var band := Rect2(NAME_BAND.position * card, NAME_BAND.size * card)
	var name_size := _fit_size(
		_name.text, band.size.x, INF, clampi(int(card.y * 0.065), MIN_NAME_SIZE, 22), MIN_NAME_SIZE
	)
	_name.add_theme_font_size_override("font_size", name_size)
	# A label never draws shorter than its line, which on a small card is
	# taller than the ribbon; it is centred on the ribbon at whatever height
	# it takes.
	_name.size = Vector2(band.size.x, maxf(band.size.y, name_size * 1.5))
	_name.position = Vector2(band.position.x, band.get_center().y - _name.size.y * 0.5)

	_place(_text, TEXT_BOX, card)
	var largest := clampi(int(card.y * (0.040 if detailed else 0.06)), MIN_TEXT_SIZE, 15)
	var smallest := MIN_RULES_SIZE if detailed else MIN_TEXT_SIZE
	var text_size := _fit_size(_text_plain, _text.size.x, _text.size.y, largest, smallest)
	rules_fit = _fits(_text_plain, _text.size.x, _text.size.y, text_size)
	for font_size in ["normal_font_size", "bold_font_size", "italics_font_size", "bold_italics_font_size"]:
		_text.add_theme_font_size_override(font_size, text_size)
	_text.text = "[center]%s[/center]" % _text_bbcode if _text_bbcode != "" else ""

	var number_size := clampi(int(card.x * 0.15), 9, 34)
	_badge(_cost, _cost_value, COST_AT, COST_WIDTH, COST_CENTRE, card, number_size)
	_badge(_attack, _attack_value, ATTACK_AT, ATTACK_WIDTH, ATTACK_CENTRE, card, number_size)
	_badge(_health, _health_value, HEALTH_AT, HEALTH_WIDTH, HEALTH_CENTRE, card, number_size)

## Draws `image` `width` (a fraction of the card's width) wide, positioned so
## its `centre` lands on `at`, with `value` centred over that point.
func _badge(image: TextureRect, value: Label, at: Vector2, width: float, centre: Vector2, card: Vector2, number_size: int) -> void:
	var texture := image.texture
	var drawn_width := card.x * width
	var aspect := 1.0
	if texture != null:
		aspect = texture.get_width() / float(texture.get_height())
	image.size = Vector2(drawn_width, drawn_width / aspect)
	var point := at * card
	image.position = point - centre * image.size
	value.add_theme_font_size_override("font_size", number_size)
	value.add_theme_constant_override("outline_size", maxi(2, number_size / 4))
	value.size = Vector2(drawn_width, number_size * 1.6)
	value.position = point - value.size * 0.5

func _place(control: Control, region: Rect2, card: Vector2) -> void:
	control.position = region.position * card
	control.size = region.size * card

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

## JSON numbers arrive as floats.
static func _int(value: Variant) -> int:
	match typeof(value):
		TYPE_FLOAT, TYPE_INT:
			return int(round(float(value)))
	return 0

## Draws a texture into an ellipse filling the control, cropped to cover it the
## way art banners are, rather than squashed to fit.
class ArtOval extends Control:
	const SEGMENTS := 64

	var texture: Texture2D:
		set(value):
			texture = value
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
		var points := PackedVector2Array()
		var uvs := PackedVector2Array()
		for index in SEGMENTS:
			var angle := TAU * index / SEGMENTS
			var unit := Vector2(cos(angle), sin(angle)) * 0.5 + Vector2(0.5, 0.5)
			points.append(unit * size)
			uvs.append(uv_origin + unit * uv_size)
		draw_colored_polygon(points, Color.WHITE, uvs, texture)
