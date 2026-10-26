extends Control

## A Hero in play, drawn the way Hearthstone draws one: its art under a gilt
## pointed arch, its name on a cloth banner across the arch's foot, and its
## Health on a badge at the banner's right end.
##
## The ring round the frame carries the colour that says the Hero is ready,
## selected or a target, as a creature's oval does. Every part is placed as a
## fraction of the portrait, and nothing in it takes pointer input: the panel
## it sits in is what is dragged from and dropped on.

## The gilt frame's bounds, as fractions of the portrait. Its arch rises from
## straight sides to a point; below the banner it tapers to a point as well.
const FRAME := Rect2(0.08, 0.02, 0.84, 0.80)
const FRAME_TIP := 0.87
## How sharp the arch is: the radius of each side's curve as a fraction of the
## arch's span. A half is a round arch; one is an equilateral Gothic arch.
const ARCH_POINT := 0.56
## Width of the gilt band round the art, as a fraction of the portrait's width.
const BAND := 0.07
const RING_WIDTH := 4.0
## The banner across the arch's foot, as fractions of the portrait, and how
## far its middle bows upward, as a fraction of its height.
const BANNER := Rect2(0.03, 0.645, 0.94, 0.15)
const BANNER_BOW := 0.12
## The Health badge at the banner's right end, and how wide it is drawn, as a
## fraction of the portrait's width.
const HEALTH_AT := Vector2(0.86, 0.80)
const HEALTH_WIDTH := 0.36

const COLOR_GILT_LIGHT := Color(0.95, 0.82, 0.50)
const COLOR_GILT_DARK := Color(0.58, 0.42, 0.18)
const COLOR_OUTLINE := Color(0.10, 0.07, 0.03)
const COLOR_HOLLOW := Color(0.12, 0.13, 0.17)
const COLOR_INITIAL := Color(0.85, 0.74, 0.44, 0.28)
const COLOR_CLOTH := Color(0.38, 0.45, 0.68)
const COLOR_CLOTH_SHADE := Color(0.25, 0.30, 0.48)
const COLOR_CLOTH_FOLD := Color(0.19, 0.22, 0.36)

## The ring's colour; transparent draws no ring.
var ring_color := Color(0, 0, 0, 0):
	set(value):
		ring_color = value
		queue_redraw()

var _art: CardFrame.ArtOval
var _front: Painter
var _name: Label
var _health: TextureRect
var _health_value: Label
var _initial := ""

## A portrait `portrait_size` big; see `show_hero` for the fields.
static func make(definition_id: String, hero_name: String, health: int, max_health: int,
		portrait_size: Vector2) -> Control:
	var portrait: Control = load("res://src/hero_portrait.gd").new()
	portrait.custom_minimum_size = portrait_size
	portrait.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	portrait.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	portrait.show_hero(definition_id, hero_name, health, max_health)
	return portrait

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS

	_art = CardFrame.ArtOval.new()
	_art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_art)
	# Over the art: the gilt edge round it and the banner across its foot.
	_front = Painter.new()
	_front.painter = _draw_front
	add_child(_front)

	_name = Label.new()
	_name.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_name.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_name.clip_text = true
	_name.add_theme_color_override("font_color", Color(1.0, 0.98, 0.92))
	_name.add_theme_color_override("font_outline_color", Color(0.05, 0.04, 0.08))
	add_child(_name)

	_health = TextureRect.new()
	_health.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_health.texture = CardFrame._texture(CardFrame.HEALTH_PATH)
	_health.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_health.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	add_child(_health)
	_health_value = Label.new()
	_health_value.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_health_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_health_value.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_health_value.add_theme_color_override("font_outline_color", Color(0.05, 0.03, 0.02))
	add_child(_health_value)

## Shows a Hero: its art, if `definition_id` has any, its name and its Health.
## Damage shows red, as it does on a creature.
func show_hero(definition_id: String, hero_name: String, health: int, max_health: int) -> void:
	_art.texture = CardArt.texture_for(definition_id)
	_name.text = hero_name
	_initial = hero_name.trim_prefix("The ").left(1).to_upper()
	_health_value.text = str(health)
	_health_value.add_theme_color_override(
		"font_color", CardFrame.health_color(health, max_health, max_health)
	)
	_layout()

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_layout()

func _portrait_size() -> Vector2:
	return size if size.x > 0.0 else custom_minimum_size

## The frame's outline in the portrait's pixels: the arch, its sides, and the
## point beneath the banner.
func _frame_outline() -> PackedVector2Array:
	var portrait := _portrait_size()
	var frame := Rect2(FRAME.position * portrait, FRAME.size * portrait)
	var points := arch(frame)
	# `arch` ends at the foot of the right side; close through the tip.
	points.append(Vector2(portrait.x * 0.5, portrait.y * FRAME_TIP))
	return points

## The art window: the frame's arch less the gilt band, down to its foot.
func _window_rect() -> Rect2:
	var portrait := _portrait_size()
	var frame := Rect2(FRAME.position * portrait, FRAME.size * portrait)
	var band := portrait.x * BAND
	return Rect2(frame.position + Vector2(band, band), frame.size - Vector2(band * 2.0, band))

## A pointed arch filling `rect`: up the left side, over the point and down the
## right side, ending at the right side's foot. Each side curves about a centre
## on the spring line, `ARCH_POINT` of the span from it.
static func arch(rect: Rect2, segments := 18) -> PackedVector2Array:
	var span := rect.size.x
	var radius := span * ARCH_POINT
	var reach := acos((radius - span * 0.5) / radius)
	var rise := radius * sin(reach)
	var spring := rect.position.y + rise
	var left := PackedVector2Array()
	left.append(Vector2(rect.position.x, rect.end.y))
	for index in segments + 1:
		var angle := PI + reach * index / segments
		left.append(Vector2(rect.position.x + radius + radius * cos(angle), spring + radius * sin(angle)))
	var points := left.duplicate()
	# The right side mirrors the left, walked the other way.
	for index in range(left.size() - 2, -1, -1):
		var point := left[index]
		points.append(Vector2(rect.position.x + rect.end.x - point.x, point.y))
	return points

func _layout() -> void:
	var portrait := _portrait_size()
	if portrait.x <= 0.0:
		return
	var window := _window_rect()
	_art.position = window.position
	_art.size = window.size
	var outline: Array = []
	for point in arch(window):
		outline.append((point - window.position) / window.size)
	_art.outline = outline
	_front.position = Vector2.ZERO
	_front.size = portrait

	var banner := Rect2(BANNER.position * portrait, BANNER.size * portrait)
	var name_size := clampi(int(portrait.x * 0.10), 7, 22)
	_name.add_theme_font_size_override("font_size", name_size)
	_name.add_theme_constant_override("outline_size", maxi(2, name_size / 4))
	# Clear of the Health badge, which overhangs the banner's right end.
	_name.position = Vector2(banner.position.x + banner.size.x * 0.08, banner.position.y)
	_name.size = Vector2(banner.size.x * 0.70, banner.size.y)

	var texture := _health.texture
	var drawn_width := portrait.x * HEALTH_WIDTH
	var aspect := 1.0
	if texture != null:
		aspect = texture.get_width() / float(texture.get_height())
	_health.size = Vector2(drawn_width, drawn_width / aspect)
	var point := HEALTH_AT * portrait
	_health.position = point - CardFrame.HEALTH_CENTRE * _health.size
	var number_size := clampi(int(portrait.x * 0.19), 10, 40)
	_health_value.add_theme_font_size_override("font_size", number_size)
	_health_value.add_theme_constant_override("outline_size", maxi(2, number_size / 4))
	_health_value.size = Vector2(drawn_width, number_size * 1.6)
	_health_value.position = point - _health_value.size * 0.5
	queue_redraw()
	_front.queue_redraw()

## Behind the art: the ring, the gilt frame, and the hollow the art fills. A
## Hero with no art shows its initial in the hollow instead.
func _draw() -> void:
	var portrait := _portrait_size()
	var outline := _frame_outline()
	var closed := outline.duplicate()
	closed.append(outline[0])
	if ring_color.a > 0.0:
		draw_polyline(closed, ring_color, RING_WIDTH * 2.0, true)
	# Gilt, lit from above.
	var colors := PackedColorArray()
	for point in outline:
		colors.append(COLOR_GILT_LIGHT.lerp(COLOR_GILT_DARK, point.y / portrait.y))
	draw_polygon(outline, colors)
	draw_polyline(closed, COLOR_OUTLINE, 1.5, true)
	# A bright bevel along the middle of the band, over the arch and sides.
	var frame := Rect2(FRAME.position * portrait, FRAME.size * portrait)
	var bevel := portrait.x * BAND * 0.45
	draw_polyline(arch(frame.grow_individual(-bevel, -bevel, -bevel, 0.0)),
		COLOR_GILT_LIGHT.lightened(0.35), 1.0, true)

	var window := _window_rect()
	draw_colored_polygon(arch(window), COLOR_HOLLOW)
	if _art.texture == null and _initial != "":
		var font := ThemeDB.fallback_font
		var font_size := int(window.size.x * 0.55)
		var text_size := font.get_string_size(_initial, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
		var baseline := window.position + Vector2(
			(window.size.x - text_size.x) * 0.5,
			window.size.y * 0.42 + font.get_ascent(font_size) * 0.5)
		draw_string(font, baseline, _initial, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, COLOR_INITIAL)

## Over the art: a dark line where the art meets the gilt, then the banner,
## its folded-back ends first.
func _draw_front(canvas: Control) -> void:
	var portrait := _portrait_size()
	var window := arch(_window_rect())
	window.append(window[0])
	canvas.draw_polyline(window, COLOR_OUTLINE, 1.5, true)

	var banner := Rect2(BANNER.position * portrait, BANNER.size * portrait)
	var bow := banner.size.y * BANNER_BOW
	var tail := banner.size.x * 0.07
	var drop := banner.size.y * 0.22
	for side in [-1.0, 1.0]:
		var edge: float = banner.position.x if side < 0.0 else banner.end.x
		var inner: float = edge - side * tail
		var fold := PackedVector2Array([
			Vector2(inner, banner.position.y + drop),
			Vector2(edge + side * tail * 0.35, banner.position.y + drop),
			Vector2(edge - side * tail * 0.15, banner.position.y + drop + banner.size.y * 0.5),
			Vector2(edge + side * tail * 0.35, banner.end.y + drop),
			Vector2(inner, banner.end.y + drop),
		])
		canvas.draw_colored_polygon(fold, COLOR_CLOTH_FOLD)
		fold.append(fold[0])
		canvas.draw_polyline(fold, COLOR_OUTLINE, 1.0, true)

	var top := PackedVector2Array()
	var bottom := PackedVector2Array()
	var steps := 16
	for index in steps + 1:
		var t := float(index) / steps
		var x := banner.position.x + banner.size.x * t
		var lift := sin(PI * t) * bow
		top.append(Vector2(x, banner.position.y - lift))
		bottom.append(Vector2(x, banner.end.y - lift))
	var cloth := top.duplicate()
	var shades := PackedColorArray()
	for point in top:
		shades.append(COLOR_CLOTH)
	for index in range(bottom.size() - 1, -1, -1):
		cloth.append(bottom[index])
		shades.append(COLOR_CLOTH_SHADE)
	canvas.draw_polygon(cloth, shades)
	cloth.append(cloth[0])
	canvas.draw_polyline(cloth, COLOR_OUTLINE, 1.5, true)
	# A gilt hem along each edge.
	var inset := banner.size.y * 0.12
	var hem_top := PackedVector2Array()
	var hem_bottom := PackedVector2Array()
	for index in top.size():
		hem_top.append(top[index] + Vector2(0, inset))
		hem_bottom.append(bottom[index] - Vector2(0, inset))
	canvas.draw_polyline(hem_top, COLOR_GILT_LIGHT.darkened(0.15), 1.0, true)
	canvas.draw_polyline(hem_bottom, COLOR_GILT_DARK, 1.0, true)

## Draws whatever its `painter` draws, so the portrait can paint a layer above
## its art without a class for each layer.
class Painter extends Control:
	var painter: Callable

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		if painter.is_valid():
			painter.call(self)
