extends Control
class_name CreatureToken

## A Creature in play, drawn the way Hearthstone draws a minion on the board:
## its art in a large oval, with Attack and Health on badges at the oval's foot.
## The whole card — name, cost and rules — is one hover away, in the reveal.
##
## Two things the player acts on stay on the token: its keywords (a Guard has
## to be attacked first) and why it cannot act ("sick", "acted").
##
## The ring round the oval carries the colour that says the creature is ready,
## selected or a target; on a card in the hand that is the panel round it. Like
## the card frame, every part is placed as a fraction of the token, and nothing
## in it takes pointer input: the slot panel it sits in is what starts a drag.

## The art oval, as fractions of the token. It fills nearly all of it, leaving
## room at the foot for the badges to overhang.
const OVAL := Rect2(0.05, 0.035, 0.90, 0.84)
## Width of the coloured ring outside the oval, and of the gilt edge on it.
const RING_WIDTH := 4.0
const EDGE_WIDTH := 2.0
## Guard appears a beat after contact, then snaps out and settles.
const GUARD_DELAY := 0.07
const GUARD_EXPAND := 0.13
const GUARD_SETTLE := 0.15
const GUARD_ENTRANCE := GUARD_DELAY + GUARD_EXPAND + GUARD_SETTLE
## Where each badge's number sits, as fractions of the token, and how wide the
## badge is drawn, as a fraction of its width. The badge images are the
## frame's, so they keep the frame's proportions to each other.
const ATTACK_AT := Vector2(0.16, 0.85)
const HEALTH_AT := Vector2(0.84, 0.85)
const ATTACK_WIDTH := 0.48
const HEALTH_WIDTH := 0.41
## Last Breath sits between the stat badges at the foot of the oval.
const LAST_BREATH_PATH := "res://art/assets/last_breath.png"
const LAST_BREATH_AT := Vector2(0.5, 0.85)
const LAST_BREATH_WIDTH := 0.30
## The keyword chip sits over the top of the oval, the marker above the badges.
const KEYWORDS_AT := 0.13
const MARKS_AT := 0.70

const COLOR_EDGE := Color(0.85, 0.74, 0.44)
const COLOR_HOLLOW := Color(0.12, 0.13, 0.17)
const COLOR_CHIP := Color(0.06, 0.05, 0.04, 0.78)
const COLOR_MARKS := Color(0.80, 0.82, 0.88)
## A creature that cannot act has its art dimmed, so a ready one stands out.
const COLOR_RESTING := Color(0.62, 0.62, 0.66)

## The ring's colour; transparent draws no ring.
var ring_color := Color(0, 0, 0, 0):
	set(value):
		ring_color = value
		if _guard != null:
			_guard.ring_color = value
		queue_redraw()

var _art: CardFrame.ArtOval
var _guard: GuardShield
var _rim: Rim
var _ward: WardShield
var _last_breath: TextureRect
var _attack: TextureRect
var _health: TextureRect
var _attack_value: Label
var _health_value: Label
var _keywords: Label
var _marks: Label

## A token `size` big showing `card`; see `show_card` for its fields.
static func make(library: CardLibrary, card: Dictionary, token_size: Vector2) -> CreatureToken:
	var token := CreatureToken.new()
	token.custom_minimum_size = token_size
	token.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	token.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	token.show_card(library, card)
	return token

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS

	# Guard is a steel shield behind the oval; Ward is a golden bubble over it.
	_guard = GuardShield.new()
	_guard.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_guard.visible = false
	add_child(_guard)
	_art = CardFrame.ArtOval.new()
	_art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_art)
	_rim = Rim.new()
	_rim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_rim)
	# Above the portrait and rim, below the keyword chips and stat badges.
	_ward = WardShield.new()
	_ward.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ward.visible = false
	add_child(_ward)

	_keywords = _chip(COLOR_EDGE)
	_marks = _chip(COLOR_MARKS)

	_last_breath = _image(LAST_BREATH_PATH)
	_last_breath.visible = false
	_attack = _image(CardFrame.ATTACK_PATH)
	_health = _image(CardFrame.HEALTH_PATH)
	_attack_value = _number()
	_health_value = _number()

## Shows a creature. `card` carries the hover reveal's fields: definition_id,
## and where it is in play, attack, health, max_health, statuses and marks.
func show_card(library: CardLibrary, card: Dictionary) -> void:
	var definition_id := str(card.get("definition_id", ""))
	_art.texture = CardArt.texture_for(definition_id)
	_guard.visible = library.keywords(definition_id).has("GUARD")
	_last_breath.visible = library.keywords(definition_id).has("LAST_BREATH")
	# Printed Ward survives on the card after it is spent; only the live
	# status tells us whether the next damage is still protected.
	_ward.visible = false
	for status in card.get("statuses", []):
		if status is Dictionary and str(status.get("kind", "")) == "WARD":
			_ward.visible = true
			break

	var base_attack := library.base_attack(definition_id)
	var base_health := library.base_health(definition_id)
	var attack := CardFrame._int(card.get("attack", base_attack))
	var health := CardFrame._int(card.get("health", base_health))
	var max_health := CardFrame._int(card.get("max_health", maxi(health, base_health)))
	_attack_value.text = str(attack)
	_health_value.text = str(health)
	_attack_value.add_theme_color_override("font_color", CardFrame.attack_color(attack, base_attack))
	_health_value.add_theme_color_override(
		"font_color", CardFrame.health_color(health, max_health, base_health)
	)

	var names: Array[String] = []
	for keyword in library.keywords(definition_id):
		names.append(str(keyword).capitalize())
	_keywords.text = " · ".join(names)
	_keywords.visible = not names.is_empty()

	var marks := str(card.get("marks", ""))
	_marks.text = marks
	_marks.visible = marks != ""
	_art.modulate = COLOR_RESTING if marks != "" else Color.WHITE
	_layout()

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_layout()

## Negative age holds the shield back until the landing signal arrives.
## An explicit age lets a rebuilt board resume rather than restart the pop.
func guard_entrance(age: float) -> void:
	_guard.entrance(age)

func _draw() -> void:
	var token := _token_size()
	var oval := Rect2(OVAL.position * token, OVAL.size * token)
	if ring_color.a > 0.0:
		draw_colored_polygon(_ellipse(oval.grow(RING_WIDTH)), ring_color)
	# Behind the art, so a creature with none still reads as an oval.
	draw_colored_polygon(_ellipse(oval), COLOR_HOLLOW)

func _layout() -> void:
	var token := _token_size()
	if token.x <= 0.0:
		return
	var oval := Rect2(OVAL.position * token, OVAL.size * token)
	_guard.position = oval.position
	_guard.size = oval.size
	_guard.pivot_offset = oval.size * 0.5
	_art.position = oval.position
	_art.size = oval.size
	_rim.position = oval.position
	_rim.size = oval.size
	_ward.position = oval.position
	_ward.size = oval.size

	var chip_size := clampi(int(token.x * 0.095), 8, 14)
	_place_chip(_keywords, KEYWORDS_AT, oval, token, chip_size)
	_place_chip(_marks, MARKS_AT, oval, token, chip_size)
	_last_breath.size = Vector2.ONE * token.x * LAST_BREATH_WIDTH
	_last_breath.position = LAST_BREATH_AT * token - _last_breath.size * 0.5

	var number_size := clampi(int(token.x * 0.22), 10, 40)
	_badge(_attack, _attack_value, ATTACK_AT, ATTACK_WIDTH, CardFrame.ATTACK_CENTRE, token, number_size)
	_badge(_health, _health_value, HEALTH_AT, HEALTH_WIDTH, CardFrame.HEALTH_CENTRE, token, number_size)
	queue_redraw()

func _token_size() -> Vector2:
	return size if size.x > 0.0 else custom_minimum_size

## Centres a chip across the oval at `at` (a fraction of the token's height),
## no wider than the oval; a long keyword list is cut short with an ellipsis.
func _place_chip(chip: Label, at: float, oval: Rect2, token: Vector2, font_size: int) -> void:
	chip.add_theme_font_size_override("font_size", font_size)
	var width := minf(
		ThemeDB.fallback_font.get_string_size(chip.text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x + 10.0,
		oval.size.x * 0.86
	)
	chip.size = Vector2(width, font_size * 1.6)
	chip.position = Vector2(token.x * 0.5 - width * 0.5, token.y * at - chip.size.y * 0.5)

## As the card frame places its badges: `image` drawn `width` (a fraction of
## the token's width) wide with its `centre` on `at`, and `value` over it.
func _badge(image: TextureRect, value: Label, at: Vector2, width: float, centre: Vector2, token: Vector2, number_size: int) -> void:
	var texture := image.texture
	var drawn_width := token.x * width
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

func _chip(color: Color) -> Label:
	var chip := Label.new()
	chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	chip.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	chip.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	chip.clip_text = true
	chip.add_theme_color_override("font_color", color)
	var style := StyleBoxFlat.new()
	style.bg_color = COLOR_CHIP
	style.set_corner_radius_all(6)
	chip.add_theme_stylebox_override("normal", style)
	chip.visible = false
	add_child(chip)
	return chip

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

static func _ellipse(rect: Rect2, segments := 64) -> PackedVector2Array:
	var points := PackedVector2Array()
	for index in segments:
		var angle := TAU * index / segments
		points.append(rect.get_center() + Vector2(cos(angle), sin(angle)) * rect.size * 0.5)
	return points

## A steel escutcheon framing the portrait, with broad shoulders and a pointed
## foot. It sits behind the art so Guard and Ward can both be read at once.
class GuardShield extends Control:
	var _entrance_age := -1.0
	var ring_color := Color.TRANSPARENT:
		set(value):
			ring_color = value
			queue_redraw()

	func _init() -> void:
		set_process(false)

	func _ready() -> void:
		set_process(_entrance_age >= 0.0 and _entrance_age < CreatureToken.GUARD_ENTRANCE)

	func entrance(age: float) -> void:
		_entrance_age = age
		set_process(age >= 0.0 and age < CreatureToken.GUARD_ENTRANCE)
		_pose()

	func _process(delta: float) -> void:
		_entrance_age += delta
		_pose()
		if _entrance_age >= CreatureToken.GUARD_ENTRANCE:
			set_process(false)

	func _pose() -> void:
		if _entrance_age < CreatureToken.GUARD_DELAY:
			modulate.a = 0.0
			scale = Vector2.ONE * 0.78
			return
		var age := _entrance_age - CreatureToken.GUARD_DELAY
		modulate.a = clampf(age / 0.045, 0.0, 1.0)
		var amount := 1.0
		if age < CreatureToken.GUARD_EXPAND:
			var progress := age / CreatureToken.GUARD_EXPAND
			amount = lerpf(0.78, 1.12, 1.0 - pow(1.0 - progress, 3.0))
		else:
			var progress := clampf((age - CreatureToken.GUARD_EXPAND) / CreatureToken.GUARD_SETTLE, 0.0, 1.0)
			amount = lerpf(1.12, 1.0, smoothstep(0.0, 1.0, progress))
		scale = Vector2.ONE * amount

	func _notification(what: int) -> void:
		if what == NOTIFICATION_RESIZED:
			queue_redraw()

	func _draw() -> void:
		if size.x <= 0.0 or size.y <= 0.0:
			return
		var outline := PackedVector2Array()
		var shape := [Vector2(0.5, -0.065), Vector2(0.77, -0.025),
			Vector2(1.035, 0.14), Vector2(1.035, 0.55), Vector2(0.90, 0.83),
			Vector2(0.5, 1.07), Vector2(0.10, 0.83), Vector2(-0.035, 0.55),
			Vector2(-0.035, 0.14), Vector2(0.23, -0.025)]
		for point: Vector2 in shape:
			outline.append(point * size)
		outline.append(outline[0])
		# Selection and target colours follow the outer shield as well.
		if ring_color.a > 0.0:
			draw_polyline(outline, ring_color, 8.0, true)
		draw_colored_polygon(outline, Color(0.36, 0.43, 0.52))
		draw_polyline(outline, Color(0.08, 0.11, 0.16), 4.0, true)
		draw_polyline(outline, Color(0.78, 0.85, 0.93), 1.5, true)
		var bevel := PackedVector2Array()
		for point: Vector2 in outline:
			bevel.append(size * 0.5 + (point - size * 0.5) * 0.94)
		draw_polyline(bevel, Color(0.53, 0.63, 0.75), 2.0, true)
		for at: Vector2 in [Vector2(0.055, 0.17), Vector2(0.945, 0.17), Vector2(0.5, 1.015)]:
			var radius := maxf(1.5, size.x * 0.023)
			draw_circle(at * size, radius + 1.0, Color(0.12, 0.17, 0.23))
			draw_circle(at * size, radius, Color(0.83, 0.88, 0.94))
		# Keep an empty portrait hollow when no art texture is available.
		draw_colored_polygon(CreatureToken._ellipse(Rect2(Vector2.ZERO, size)), CreatureToken.COLOR_HOLLOW)

## The gilt edge round the art, drawn over it so the art never bleeds past it.
class Rim extends Control:
	func _notification(what: int) -> void:
		if what == NOTIFICATION_RESIZED:
			queue_redraw()

	func _draw() -> void:
		if size.x <= 0.0 or size.y <= 0.0:
			return
		var points := CreatureToken._ellipse(Rect2(Vector2.ZERO, size))
		points.append(points[0])
		draw_polyline(points, CreatureToken.COLOR_EDGE, CreatureToken.EDGE_WIDTH, true)

## A glassy golden bubble hugging the oval. Drawn procedurally so its soft
## halo and bright edge stay crisp at any battlefield scale.
class WardShield extends Control:
	func _notification(what: int) -> void:
		if what == NOTIFICATION_RESIZED:
			queue_redraw()

	func _draw() -> void:
		if size.x <= 0.0 or size.y <= 0.0:
			return
		var oval := Rect2(Vector2.ZERO, size).grow(1.5)
		var points := CreatureToken._ellipse(oval)
		points.append(points[0])
		draw_polyline(points, Color(1.0, 0.71, 0.12, 0.10), 12.0, true)
		draw_polyline(points, Color(1.0, 0.80, 0.20, 0.25), 7.0, true)
		draw_colored_polygon(CreatureToken._ellipse(oval), Color(1.0, 0.79, 0.20, 0.17))
		draw_polyline(points, Color(1.0, 0.86, 0.32, 0.95), 2.5, true)
		# A curved reflection gives the shield volume without hiding the art.
		var sheen := PackedVector2Array()
		var inner := oval.grow(-4.0)
		for index in 25:
			var angle := lerpf(PI * 1.05, PI * 1.70, index / 24.0)
			sheen.append(inner.get_center() + Vector2(cos(angle), sin(angle)) * inner.size * 0.5)
		draw_polyline(sheen, Color(1.0, 0.97, 0.70, 0.8), 2.0, true)
