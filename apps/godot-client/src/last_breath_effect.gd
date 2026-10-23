extends Control
class_name LastBreathEffect

## Independent of combat: the skull and smoke outlive the dying token and
## remain for a full second, including deaths from spells and chained effects.
const DURATION := 1.0

class Puff:
	var offset := Vector2.ZERO
	var velocity := Vector2.ZERO
	var radius := 0.0
	var phase := 0.0
	var tint := Color.WHITE

class Burst:
	var centre := Vector2.ZERO
	var width := 0.0
	var age := 0.0
	var puffs: Array[Puff] = []

var _bursts: Array[Burst] = []
var _skull: Texture2D
var _smoke: GradientTexture2D

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_skull = CardFrame._texture(CreatureToken.LAST_BREATH_PATH)
	# Soft radial density gives each moving puff a smoky, feathered edge.
	_smoke = GradientTexture2D.new()
	_smoke.width = 64
	_smoke.height = 64
	_smoke.fill = GradientTexture2D.FILL_RADIAL
	_smoke.fill_from = Vector2(0.5, 0.5)
	_smoke.fill_to = Vector2(1.0, 0.5)
	var density := Gradient.new()
	density.offsets = PackedFloat32Array([0.0, 0.35, 0.7, 1.0])
	density.colors = PackedColorArray([Color.WHITE, Color(1, 1, 1, 0.75),
		Color(1, 1, 1, 0.25), Color(1, 1, 1, 0)])
	_smoke.gradient = density

func play(token_rect: Rect2) -> void:
	if not token_rect.has_area():
		return
	var local_rect := get_global_transform().affine_inverse() * token_rect
	var oval := Rect2(local_rect.position + CreatureToken.OVAL.position * local_rect.size,
		CreatureToken.OVAL.size * local_rect.size)
	var burst := Burst.new()
	burst.centre = oval.get_center()
	burst.width = oval.size.x
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	for index in 18:
		var puff := Puff.new()
		var direction := Vector2.from_angle(TAU * index / 18.0 + rng.randf_range(-0.15, 0.15))
		puff.offset = direction * burst.width * rng.randf_range(0.06, 0.25)
		puff.velocity = direction * burst.width * rng.randf_range(0.16, 0.40) + Vector2(0, -burst.width * 0.16)
		puff.radius = burst.width * rng.randf_range(0.24, 0.37)
		puff.phase = rng.randf_range(0.0, TAU)
		puff.tint = Color(0.38, 0.015, 0.04).lerp(Color(0.94, 0.08, 0.12), rng.randf())
		burst.puffs.append(puff)
	_bursts.append(burst)
	queue_redraw()

func cancel() -> void:
	_bursts.clear()
	queue_redraw()

func _process(delta: float) -> void:
	if _bursts.is_empty():
		return
	for burst: Burst in _bursts.duplicate():
		burst.age += delta
		if burst.age >= DURATION:
			_bursts.erase(burst)
	queue_redraw()

func _draw() -> void:
	for burst in _bursts:
		var t := clampf(burst.age / DURATION, 0.0, 1.0)
		var fade := 1.0 - smoothstep(0.78, 1.0, t)
		for puff in burst.puffs:
			var curl := Vector2(sin(puff.phase + t * 5.0), cos(puff.phase + t * 4.0)) * burst.width * 0.06 * t
			var centre := burst.centre + puff.offset + puff.velocity * t + curl
			var radius := puff.radius * (0.65 + 0.85 * sqrt(t))
			var tint := puff.tint
			tint.a = fade * (0.68 - t * 0.15)
			draw_texture_rect(_smoke, Rect2(centre - Vector2.ONE * radius, Vector2.ONE * radius * 2.0), false, tint)
		if _skull != null:
			var pop := 1.0 + 0.13 * sin(PI * clampf(t / 0.22, 0.0, 1.0))
			var width := burst.width * 0.64 * pop
			var skull_size := Vector2(width, width * _skull.get_height() / float(_skull.get_width()))
			var centre := burst.centre + Vector2(0, -burst.width * 0.08 * t)
			draw_texture_rect(_skull, Rect2(centre - skull_size * 0.5, skull_size), false, Color(1, 1, 1, fade))
