extends Control

## Shows its content whole: scaled down, never up, until it fits both ways,
## and centred in what is left. The battlefield fits the screen this way
## instead of scrolling, so both Heroes are always in view.

var content: Control

func _init() -> void:
	clip_contents = true
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
		factor = minf(1.0, minf(size.x / needed.x, size.y / needed.y))
	content.scale = Vector2(factor, factor)
	# Full width at its own scale, so rows centred in it stay centred here.
	content.size = Vector2(size.x / factor, needed.y)
	content.position = Vector2(0.0, maxf(0.0, (size.y - needed.y * factor) / 2.0))
