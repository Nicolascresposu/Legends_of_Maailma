extends Control

## Shows its content whole: scaled until it fits both ways, up to MAX_SCALE,
## and centred in what is left. The battlefield fits the screen this way
## instead of scrolling, so both Heroes are always in view, and grows to use
## a large window rather than sitting small in the middle of it.

## Past this the art is stretched further than it was drawn for.
const MAX_SCALE := 1.4

var content: Control

func _init() -> void:
	clip_contents = true
	# The board's clicks and hovers are hit-tested by the match view above it,
	# so they must pass through; a bare Control would stop them here.
	mouse_filter = Control.MOUSE_FILTER_PASS
	resized.connect(fit)

func set_content(control: Control) -> void:
	content = control
	add_child(control)
	control.minimum_size_changed.connect(fit)
	fit()

## Lays the content out at once. Its minimum size is current as soon as its
## children change, so this needs no frame to pass before rects are read.
func fit() -> void:
	if content == null or size.x <= 0.0 or size.y <= 0.0:
		return
	var needed := content.get_combined_minimum_size()
	var factor := 1.0
	if needed.x > 0.0 and needed.y > 0.0:
		factor = minf(MAX_SCALE, minf(size.x / needed.x, size.y / needed.y))
	content.scale = Vector2(factor, factor)
	# Full width at its own scale, so rows centred in it stay centred here.
	content.size = Vector2(size.x / factor, needed.y)
	content.position = Vector2(0.0, maxf(0.0, (size.y - needed.y * factor) / 2.0))
