extends Control
class_name TargetingArrow

## The Hearthstone-style targeting arrow: a curved trail of dots ending in a
## solid arrowhead. It is purely decorative — it shows where a drag is pointing
## and whether the hovered target is valid.

const DOT_SPACING := 26.0
const DOT_RADIUS := 5.0
const HEAD_LENGTH := 26.0
const HEAD_WIDTH := 22.0
const CURVE_LIFT := 0.28

const COLOR_VALID := Color(0.45, 0.85, 0.55)
const COLOR_INVALID := Color(0.78, 0.35, 0.38)
const COLOR_NEUTRAL := Color(0.92, 0.80, 0.42)

var origin := Vector2.ZERO
var tip := Vector2.ZERO
var active := false
## null = nothing hovered, true = valid target, false = invalid.
var target_valid: Variant = null

func _init() -> void:
	# The arrow is an overlay: it must never intercept clicks meant for cards.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	visible = false

func begin(from: Vector2) -> void:
	origin = from
	tip = from
	target_valid = null
	active = true
	visible = true
	queue_redraw()

func point_at(to: Vector2, valid: Variant = null) -> void:
	if not active:
		return
	tip = to
	target_valid = valid
	queue_redraw()

func finish() -> void:
	active = false
	visible = false
	target_valid = null
	queue_redraw()

func _color() -> Color:
	if typeof(target_valid) == TYPE_BOOL:
		return COLOR_VALID if bool(target_valid) else COLOR_INVALID
	return COLOR_NEUTRAL

func _draw() -> void:
	if not active:
		return
	var span := tip - origin
	if span.length() < 8.0:
		return
	var color := _color()

	# A quadratic curve bowed perpendicular to the drag gives the arc that makes
	# the arrow read as a throw rather than a straight line.
	var normal := Vector2(-span.y, span.x).normalized()
	# Bow consistently upward on screen so the curve never flips mid-drag.
	if normal.y > 0.0:
		normal = -normal
	var control := origin + span * 0.5 + normal * span.length() * CURVE_LIFT

	var points := _sample_curve(origin, control, tip, 48)
	var total := _curve_length(points)
	if total <= HEAD_LENGTH:
		_draw_head(tip, (tip - origin).normalized(), color)
		return

	# Dots stop short of the head so the two do not overlap.
	var walked := 0.0
	var next_dot := DOT_SPACING * 0.5
	var head_start := total - HEAD_LENGTH
	for i in range(points.size() - 1):
		var a: Vector2 = points[i]
		var b: Vector2 = points[i + 1]
		var segment := a.distance_to(b)
		while next_dot <= walked + segment and next_dot < head_start:
			var t := (next_dot - walked) / maxf(segment, 0.0001)
			var at := a.lerp(b, t)
			# Dots swell slightly toward the tip, as in Hearthstone.
			var scale := lerpf(0.65, 1.0, next_dot / maxf(head_start, 0.0001))
			draw_circle(at, DOT_RADIUS * scale, color)
			next_dot += DOT_SPACING
		walked += segment

	var direction := (points[points.size() - 1] - points[points.size() - 2]).normalized()
	_draw_head(tip, direction, color)

func _draw_head(at: Vector2, direction: Vector2, color: Color) -> void:
	if direction.length() < 0.001:
		direction = Vector2.UP
	var side := Vector2(-direction.y, direction.x) * (HEAD_WIDTH * 0.5)
	var base := at - direction * HEAD_LENGTH
	draw_colored_polygon(
		PackedVector2Array([at, base + side, base - side]),
		color
	)

func _sample_curve(from: Vector2, control: Vector2, to: Vector2, steps: int) -> PackedVector2Array:
	var points := PackedVector2Array()
	for i in range(steps + 1):
		var t := float(i) / float(steps)
		var inv := 1.0 - t
		points.append(from * inv * inv + control * 2.0 * inv * t + to * t * t)
	return points

func _curve_length(points: PackedVector2Array) -> float:
	var total := 0.0
	for i in range(points.size() - 1):
		total += points[i].distance_to(points[i + 1])
	return total
