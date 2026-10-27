extends Control
class_name LocationToken

## A Location in play: its art in the pointed arch of its card's frame, with
## its duration on an hourglass at the arch's foot on the left and its
## Durability on a shield on the right — whichever of the two it has. The
## whole card is one hover away, in the reveal.
##
## A Location that has been used is closed until its owner's next turn, and
## is drawn dark until then, as Hearthstone draws a Location on cooldown.
##
## Like the creature token, every part is placed as a fraction of the token,
## the ring round the arch carries the colour that says the Location is ready,
## selected or a target, and nothing in it takes pointer input.

## The arch, as fractions of the token. It leaves room at the foot for the
## badges to overhang, as the creature token's oval does.
const ARCH := Rect2(0.06, 0.035, 0.88, 0.80)
## The arch's outline within that rect: the art window of the Location frame.
const OUTLINE := CardFrame.LOCATION_ART_OUTLINE
const RING_WIDTH := 4.0
const EDGE_WIDTH := 2.0
## Where each badge's number sits, as fractions of the token, and how wide its
## image is drawn, as a fraction of the token's width.
const DURATION_AT := Vector2(0.18, 0.83)
const DURABILITY_AT := Vector2(0.82, 0.83)
const BADGE_WIDTH := 0.42
const MARKS_AT := 0.45

const COLOR_EDGE := CreatureToken.COLOR_EDGE
const COLOR_HOLLOW := CreatureToken.COLOR_HOLLOW
const COLOR_CHIP := CreatureToken.COLOR_CHIP
const COLOR_MARKS := CreatureToken.COLOR_MARKS
## A closed Location is drawn dark, so an open one stands out.
const COLOR_CLOSED := Color(0.30, 0.30, 0.36)

## The ring's colour; transparent draws no ring.
var ring_color := Color(0, 0, 0, 0):
	set(value):
		ring_color = value
		queue_redraw()

## Whether the Location is closed, as last shown.
var closed := false

var _art: CardFrame.ArtOval
var _rim: Rim
var _hourglass: TextureRect
var _durability: TextureRect
var _duration_value: Label
var _durability_value: Label
var _marks: Label

## A token `size` big showing `card`; see `show_card` for its fields.
static func make(library: CardLibrary, card: Dictionary, token_size: Vector2) -> LocationToken:
	var token := LocationToken.new()
	token.custom_minimum_size = token_size
	token.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	token.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	token.show_card(library, card)
	return token

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS

	_art = CardFrame.ArtOval.new()
	_art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_art.outline = OUTLINE
	add_child(_art)
	_rim = Rim.new()
	_rim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_rim)

	_marks = Label.new()
	_marks.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_marks.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_marks.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_marks.add_theme_color_override("font_color", COLOR_MARKS)
	var style := StyleBoxFlat.new()
	style.bg_color = COLOR_CHIP
	style.set_corner_radius_all(6)
	_marks.add_theme_stylebox_override("normal", style)
	_marks.visible = false
	add_child(_marks)

	_hourglass = _image(CardFrame.HOURGLASS_PATH)
	_durability = _image(CardFrame.DURABILITY_PATH)
	_duration_value = _number()
	_durability_value = _number()

## Shows a Location. `card` carries the hover reveal's fields: definition_id,
## and where it is in play, durability, duration, closed and marks.
func show_card(library: CardLibrary, card: Dictionary) -> void:
	var definition_id := str(card.get("definition_id", ""))
	_art.texture = CardArt.texture_for(definition_id)

	var timed := library.has_duration(definition_id)
	_hourglass.visible = timed
	_duration_value.visible = timed
	if timed:
		var base_duration := library.base_duration(definition_id)
		var duration := CardFrame._int(card.get("duration", base_duration))
		_duration_value.text = str(duration)
		_duration_value.add_theme_color_override(
			"font_color", CardFrame.durability_color(duration, base_duration)
		)

	var shielded := library.has_durability(definition_id)
	_durability.visible = shielded
	_durability_value.visible = shielded
	if shielded:
		var base_durability := library.base_durability(definition_id)
		var durability := CardFrame._int(card.get("durability", base_durability))
		_durability_value.text = str(durability)
		_durability_value.add_theme_color_override(
			"font_color", CardFrame.durability_color(durability, base_durability)
		)
		_durability.texture = CardFrame._texture(
			CardFrame.DURABILITY_ZERO_PATH if durability <= 0 else CardFrame.DURABILITY_PATH
		)

	closed = bool(card.get("closed", false))
	_art.modulate = COLOR_CLOSED if closed else Color.WHITE
	_rim.modulate = COLOR_CLOSED if closed else Color.WHITE
	var marks := str(card.get("marks", ""))
	_marks.text = marks
	_marks.visible = marks != ""
	_layout()

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_layout()

## The arch's outline, in the token's own coordinates.
func arch_points() -> PackedVector2Array:
	return shape_points(_arch_rect())

## `OUTLINE` fitted to `rect`.
static func shape_points(rect: Rect2) -> PackedVector2Array:
	var points := PackedVector2Array()
	for unit: Vector2 in OUTLINE:
		points.append(rect.position + unit * rect.size)
	return points

func _draw() -> void:
	var points := arch_points()
	if ring_color.a > 0.0:
		for ring in Geometry2D.offset_polygon(points, RING_WIDTH, Geometry2D.JOIN_ROUND):
			draw_colored_polygon(ring, ring_color)
	# Behind the art, so a Location with none still reads as an arch.
	draw_colored_polygon(points, COLOR_HOLLOW)

func _layout() -> void:
	var token := _token_size()
	if token.x <= 0.0:
		return
	var arch := _arch_rect()
	_art.position = arch.position
	_art.size = arch.size
	_rim.position = arch.position
	_rim.size = arch.size

	var chip_size := clampi(int(token.x * 0.095), 8, 14)
	_marks.add_theme_font_size_override("font_size", chip_size)
	var width := minf(
		ThemeDB.fallback_font.get_string_size(_marks.text, HORIZONTAL_ALIGNMENT_LEFT, -1, chip_size).x + 10.0,
		arch.size.x * 0.86
	)
	_marks.size = Vector2(width, chip_size * 1.6)
	_marks.position = Vector2(token.x * 0.5 - width * 0.5, token.y * MARKS_AT - _marks.size.y * 0.5)

	var number_size := clampi(int(token.x * 0.22), 10, 40)
	_badge(_hourglass, _duration_value, DURATION_AT, CardFrame.HOURGLASS_CENTRE, token, number_size)
	_badge(_durability, _durability_value, DURABILITY_AT, CardFrame.DURABILITY_CENTRE, token, number_size)
	queue_redraw()

func _arch_rect() -> Rect2:
	var token := _token_size()
	return Rect2(ARCH.position * token, ARCH.size * token)

func _token_size() -> Vector2:
	return size if size.x > 0.0 else custom_minimum_size

## `image` drawn BADGE_WIDTH of the token wide with its `centre` on `at`, and
## `value` over it.
func _badge(image: TextureRect, value: Label, at: Vector2, centre: Vector2, token: Vector2, number_size: int) -> void:
	var texture := image.texture
	var drawn_width := token.x * BADGE_WIDTH
	var aspect := 1.0
	if texture != null:
		aspect = texture.get_width() / float(texture.get_height())
	image.size = Vector2(drawn_width, drawn_width / aspect)
	var point := at * token
	image.position = point - centre * image.size
	value.add_theme_font_size_override("font_size", number_size)
	value.add_theme_constant_override("outline_size", maxi(2, number_size / 4))
	value.size = Vector2(drawn_width, number_size * 1.6)
	value.position = point - value.size * 0.5

func _image(path: String) -> TextureRect:
	var rect := TextureRect.new()
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.texture = CardFrame._texture(path)
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	add_child(rect)
	return rect

func _number() -> Label:
	var label := Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_color_override("font_outline_color", Color(0.05, 0.03, 0.02))
	add_child(label)
	return label

## The gilt edge round the arch, drawn over the art so it never bleeds past it.
class Rim extends Control:
	func _notification(what: int) -> void:
		if what == NOTIFICATION_RESIZED:
			queue_redraw()

	func _draw() -> void:
		if size.x <= 0.0 or size.y <= 0.0:
			return
		var points := LocationToken.shape_points(Rect2(Vector2.ZERO, size))
		points.append(points[0])
		draw_polyline(points, LocationToken.COLOR_EDGE, LocationToken.EDGE_WIDTH, true)
