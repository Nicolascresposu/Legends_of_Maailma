extends Control
class_name CollectionCard

## One card on a collection page, drawn as the printed card with a count of
## the copies owned beneath it.
##
## How it looks says what can be done with it: a card whose copies are all in
## the deck is darkened, an unowned card that can be crafted now is tinted
## blue and glows, and one that cannot is grey and faded. The tile decides
## nothing itself — the screen tells it which look to wear and acts on clicks.

## Left or right mouse button, pressed on the card.
signal clicked(button_index: int)

enum Look { NORMAL, SPENT, CRAFTABLE, LOCKED }

const GLOW_COLOR := Color(0.38, 0.72, 1.0)
## Glow rings, widest and faintest first, as (width, opacity).
const GLOW_RINGS := [Vector2(14, 0.14), Vector2(9, 0.24), Vector2(5, 0.42), Vector2(2.5, 0.9)]
## Pulses per second, and how far the glow fades at the bottom of a pulse.
const GLOW_RATE := 0.7
const GLOW_LOW := 0.55
const COUNT_HEIGHT := 22.0

## Shared by every tile, so a page compiles the shader once.
static var _shader: Shader

var card_id := ""
var look := Look.NORMAL
var frame: CardFrame
var _glow: Control
var _count: Label
var _pulse := 0.0

static func make(library: CardLibrary, definition_id: String, copies: int, card_look: Look) -> CollectionCard:
	var tile := CollectionCard.new()
	tile.card_id = definition_id
	tile.frame = CardFrame.make(library, {"definition_id": definition_id}, 160.0, true)
	tile.add_child(tile.frame)
	tile._count.text = "×%d" % copies if copies > 1 else ""
	tile.set_look(card_look)
	return tile

func _init() -> void:
	# Passed on, so the mouse wheel still reaches the page beneath to turn it.
	mouse_filter = Control.MOUSE_FILTER_PASS
	_glow = Control.new()
	_glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_glow.draw.connect(_draw_glow)
	add_child(_glow)
	_count = Label.new()
	_count.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_count.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_count.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_count.add_theme_font_size_override("font_size", 15)
	_count.add_theme_color_override("font_color", Color(0.93, 0.86, 0.62))
	_count.add_theme_color_override("font_outline_color", Color(0.05, 0.03, 0.02))
	_count.add_theme_constant_override("outline_size", 4)
	add_child(_count)

func set_look(value: Look) -> void:
	look = value
	frame.modulate = Color.WHITE
	frame.material = null
	match look:
		Look.SPENT:
			frame.modulate = Color(0.45, 0.45, 0.48)
		Look.CRAFTABLE:
			frame.material = _tint(Vector3(0.62, 0.86, 1.4), 0.7)
		Look.LOCKED:
			frame.material = _tint(Vector3(0.85, 0.85, 0.85), 1.0)
			frame.modulate = Color(1, 1, 1, 0.5)
	# A frame draws its parts as children, so they take its material only if
	# told to.
	for part in frame.find_children("*", "CanvasItem", true, false):
		(part as CanvasItem).use_parent_material = true
	set_process(look == Look.CRAFTABLE)
	_glow.queue_redraw()

## Fits the card into `card_size`, with the count in a band below it.
func place(at: Vector2, card_size: Vector2) -> void:
	position = at
	size = card_size + Vector2(0, COUNT_HEIGHT)
	frame.position = Vector2.ZERO
	# The frame was made at a width of its own, which it would otherwise keep
	# as its least size.
	frame.custom_minimum_size = card_size
	frame.size = card_size
	_glow.position = Vector2.ZERO
	_glow.size = card_size
	_count.position = Vector2(0, card_size.y)
	_count.size = Vector2(card_size.x, COUNT_HEIGHT)
	_glow.queue_redraw()

func _gui_input(event: InputEvent) -> void:
	var press := event as InputEventMouseButton
	if press == null or not press.pressed:
		return
	if press.button_index == MOUSE_BUTTON_LEFT or press.button_index == MOUSE_BUTTON_RIGHT:
		accept_event()
		clicked.emit(press.button_index)

func _process(delta: float) -> void:
	_pulse = fmod(_pulse + delta * GLOW_RATE, 1.0)
	_glow.queue_redraw()

## Rings of blue round the card's outline, drawn behind it so only the part
## outside its edge shows, breathing in and out.
func _draw_glow() -> void:
	if look != Look.CRAFTABLE or frame == null:
		return
	var strength := lerpf(GLOW_LOW, 1.0, 0.5 + 0.5 * cos(_pulse * TAU))
	for ring: Vector2 in GLOW_RINGS:
		var color := GLOW_COLOR
		color.a = ring.y * strength
		frame.draw_outline(_glow, Vector2.ZERO, color, ring.x)

## A material that greys a card toward its brightness, by `desaturate`, then
## multiplies it by `tint`.
static func _tint(tint: Vector3, desaturate: float) -> ShaderMaterial:
	if _shader == null:
		_shader = Shader.new()
		_shader.code = """
shader_type canvas_item;
uniform vec3 tint = vec3(1.0);
uniform float desaturate = 1.0;
void fragment() {
	float luma = dot(COLOR.rgb, vec3(0.299, 0.587, 0.114));
	COLOR.rgb = mix(COLOR.rgb, vec3(luma), desaturate) * tint;
}
"""
	var material := ShaderMaterial.new()
	material.shader = _shader
	material.set_shader_parameter("tint", tint)
	material.set_shader_parameter("desaturate", desaturate)
	return material
