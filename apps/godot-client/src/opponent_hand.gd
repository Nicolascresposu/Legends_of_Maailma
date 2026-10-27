extends Control

## The opponent's hand, as Hearthstone shows it: their cards face down along
## the top of the screen, fanned the other way up from the player's own and
## hanging off the top edge, so only their lower part is in view.
##
## It shows a count and nothing else — the cards are hidden — so it is drawn
## rather than built from controls, and takes no part in dragging or targeting.
## Resting the pointer on the cards shows how many are in the hand and the
## deck, at once, as the cards in play reveal themselves.

const BACK_PATH := "res://art/assets/cardback_default.png"
## The cards are a little smaller than the player's: they are further away.
const CARD_SIZE := Vector2(72, 108)
## The strip this takes from the screen; the cards stand taller than it and
## run up through the margin and off the top of the view.
const HEIGHT := 48.0
## Where the middle card's lower edge sits above the foot of the strip.
const FOOT := 3.0
## Spacing, fan and arc. The fan is turned further than the player's, so with
## only their lower half in view the cards still read one by one.
const MAX_SPACING := 58.0
const MIN_SPACING := 12.0
const FAN_ARC := 0.5
const FAN_STEP := 0.11
const ARC_DROP := 12.0
## A dark edge round each card, so where one overlaps the next reads as two
## cards rather than one run of pattern.
const EDGE := 2.5
const COLOR_EDGE := Color(0.04, 0.03, 0.03, 0.85)
## The counts shown over the cards while the pointer rests on them.
const COUNTS_FONT_SIZE := 14
const COUNTS_PAD := Vector2(10, 4)
const COLOR_COUNTS_BACK := Color(0.09, 0.10, 0.13, 0.92)
const COLOR_COUNTS_BORDER := Color(0.85, 0.74, 0.44)
const COLOR_COUNTS_TEXT := Color(0.92, 0.93, 0.96)

var count := 0
var deck := 0
var _texture: Texture2D
var _hovered := false

func _init() -> void:
	custom_minimum_size.y = HEIGHT
	mouse_filter = Control.MOUSE_FILTER_PASS
	# Beneath everything else, so the admin bar, when it is shown above, covers
	# the cards rather than the cards covering it.
	z_index = -1
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	if ResourceLoader.exists(BACK_PATH):
		_texture = load(BACK_PATH)

func set_counts(cards: int, deck_cards: int) -> void:
	if cards == count and deck_cards == deck:
		return
	count = cards
	deck = deck_cards
	if count == 0:
		_hovered = false
	queue_redraw()

func counts_text() -> String:
	return "Hand %d · Deck %d" % [count, deck]

func is_showing_counts() -> bool:
	return _hovered

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_set_hovered(over_cards((event as InputEventMouseMotion).position))

func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT:
		_set_hovered(false)

func _set_hovered(hovered: bool) -> void:
	if hovered != _hovered:
		_hovered = hovered
		queue_redraw()

## Whether `at`, in this control's space, is over the fan rather than the
## empty strip either side of it.
func over_cards(at: Vector2) -> bool:
	if count == 0:
		return false
	var first: Vector2 = rest_of(0)[0]
	var last: Vector2 = rest_of(count - 1)[0]
	return at.x >= first.x - CARD_SIZE.x * 0.5 and at.x <= last.x + CARD_SIZE.x * 0.5

func _draw() -> void:
	if _texture == null:
		return
	for index in count:
		var rest := rest_of(index)
		# Turned end over end, so the backs face the player as the opponent
		# holds them, and leaning the opposite way to the player's own.
		draw_set_transform(rest[0], PI + rest[1])
		draw_rect(Rect2(-CARD_SIZE * 0.5, CARD_SIZE).grow(EDGE), COLOR_EDGE)
		draw_texture_rect(_texture, Rect2(-CARD_SIZE * 0.5, CARD_SIZE), false)
	draw_set_transform(Vector2.ZERO)
	if _hovered:
		_draw_counts()

func _draw_counts() -> void:
	var font := get_theme_default_font()
	var text := counts_text()
	var text_size := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, COUNTS_FONT_SIZE)
	var box := Rect2(Vector2.ZERO, text_size + COUNTS_PAD * 2.0)
	box.position = Vector2(size.x * 0.5, size.y * 0.5) - box.size * 0.5
	var style := StyleBoxFlat.new()
	style.bg_color = COLOR_COUNTS_BACK
	style.border_color = COLOR_COUNTS_BORDER
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	draw_style_box(style, box)
	var baseline := box.position + Vector2(COUNTS_PAD.x, COUNTS_PAD.y + font.get_ascent(COUNTS_FONT_SIZE))
	draw_string(font, baseline, text, HORIZONTAL_ALIGNMENT_LEFT, -1, COUNTS_FONT_SIZE, COLOR_COUNTS_TEXT)

## [centre, lean] of the card at `index`: the player's fan mirrored top to
## bottom, its outer cards rising toward the edge rather than dropping.
func rest_of(index: int) -> Array:
	var spacing := MAX_SPACING
	if count > 1:
		var room := size.x - CARD_SIZE.x
		spacing = clampf(room / (count - 1), MIN_SPACING, MAX_SPACING)
	var from_middle := index - (count - 1) * 0.5
	var step := FAN_STEP
	if count > 1:
		step = minf(FAN_STEP, FAN_ARC / (count - 1))
	var reach := maxf((count - 1) * 0.5, 1.0)
	var rise := ARC_DROP * pow(from_middle / reach, 2.0)
	var center := Vector2(size.x * 0.5 + from_middle * spacing,
		HEIGHT - FOOT - rise - CARD_SIZE.y * 0.5)
	return [center, -from_middle * step]
