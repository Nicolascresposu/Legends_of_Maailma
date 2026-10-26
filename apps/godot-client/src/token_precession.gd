extends Control
class_name TokenPrecession

## Project the complete 2D token as a thin surface rotating in 3D. Its normal
## traces a cone; the artwork does not spin around its own normal.
const PADDING := 20
const COLUMNS := 6
const ROWS := 8
const THICKNESS := 5.0

var basis := Basis.IDENTITY
var _source: CreatureToken
var _source_modulate := Color.WHITE
var _viewport: SubViewport
var _tilt := 0.0

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR

func setup(source: CreatureToken) -> void:
	_source = source
	_source_modulate = source.modulate
	_viewport = SubViewport.new()
	_viewport.transparent_bg = true
	_viewport.disable_3d = true
	_viewport.gui_disable_input = true
	_viewport.size = Vector2i(source.size.ceil()) + Vector2i.ONE * PADDING * 2
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var copy := source.visual_copy()
	copy.modulate = _source_modulate
	copy.position = Vector2.ONE * PADDING
	copy.size = source.size
	_viewport.add_child(copy)
	add_child(_viewport)

func pose(tilt: float, phase: float) -> void:
	_tilt = tilt
	basis = Basis(Vector3(cos(phase), sin(phase), 0.0), tilt)
	if is_instance_valid(_source):
		_source.modulate = _source_modulate
		if tilt > 0.001:
			_source.modulate.a = 0.0
	queue_redraw()

func restore() -> void:
	if is_instance_valid(_source):
		_source.modulate = _source_modulate
	# A retired viewport can exit the tree after a replacement has already
	# hidden this same token. Do not restore its visibility a second time.
	_source = null
	_tilt = 0.0
	queue_redraw()

func _exit_tree() -> void:
	restore()

func _project(point: Vector2, depth := 0.0) -> Vector2:
	# Keep the foot planted while the face leans through depth, rather than
	# letting the token tumble freely around its centre.
	var centre := _source.size * Vector2(0.5, CreatureToken.OVAL.end.y)
	var vertex := basis * Vector3(point.x - centre.x, point.y - centre.y, depth)
	var focal := maxf(_source.size.x, _source.size.y) * 3.5
	var perspective := focal / (focal + vertex.z)
	return centre + Vector2(vertex.x, vertex.y) * perspective

func _draw() -> void:
	if _tilt <= 0.001 or not is_instance_valid(_source) or not _source.is_inside_tree():
		return
	# Read the live layout every draw; board containers can settle after the
	# authoritative update replaces the source token at impact.
	draw_set_transform_matrix(get_global_transform().affine_inverse() * _source.get_global_transform())
	var shadow := Rect2(_source.size * Vector2(0.13, 0.87), _source.size * Vector2(0.74, 0.10))
	draw_colored_polygon(CreatureToken._ellipse(shadow, 40), Color(0, 0, 0, minf(_tilt * 1.4, 0.32)))
	_draw_rim()
	var texture := _viewport.get_texture()
	var area := Rect2(-Vector2.ONE * PADDING, Vector2(_viewport.size))
	var light := clampf(0.94 + basis.z.x * 0.16 - basis.z.y * 0.12, 0.76, 1.08)
	var color := Color(light, light, light)
	# A small tessellated surface preserves perspective across the portrait,
	# frame and badges rather than stretching the token as a single quad.
	for row in ROWS:
		for column in COLUMNS:
			var uvs := PackedVector2Array([
				Vector2(float(column) / COLUMNS, float(row) / ROWS),
				Vector2(float(column + 1) / COLUMNS, float(row) / ROWS),
				Vector2(float(column + 1) / COLUMNS, float(row + 1) / ROWS),
				Vector2(float(column) / COLUMNS, float(row + 1) / ROWS),
			])
			var points := PackedVector2Array()
			for uv in uvs:
				points.append(_project(area.position + uv * area.size))
			draw_colored_polygon(points, color, uvs, texture)

func _draw_rim() -> void:
	var oval := Rect2(CreatureToken.OVAL.position * _source.size, CreatureToken.OVAL.size * _source.size)
	var outline := CreatureToken._ellipse(oval, 48)
	for index in outline.size():
		var next := (index + 1) % outline.size()
		var points := PackedVector2Array([
			_project(outline[index], THICKNESS), _project(outline[next], THICKNESS),
			_project(outline[next]), _project(outline[index]),
		])
		var normal := ((outline[index] + outline[next]) * 0.5 - oval.get_center()).normalized()
		var light := clampf(0.50 + normal.dot(Vector2(-0.5, -0.8)) * 0.28, 0.25, 0.85)
		var color := Color(CreatureToken.COLOR_EDGE * light, _source_modulate.a)
		# Edge-on side faces collapse to almost a line. Explicit triangles,
		# excluding zero-area slivers, avoid polygon triangulation failures.
		_draw_rim_triangle(points[0], points[1], points[2], color)
		_draw_rim_triangle(points[0], points[2], points[3], color)

func _draw_rim_triangle(a: Vector2, b: Vector2, c: Vector2, color: Color) -> void:
	if absf((b - a).cross(c - a)) < 0.02:
		return
	draw_colored_polygon(PackedVector2Array([a, b, c]), color)
