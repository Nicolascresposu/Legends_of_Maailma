extends Control
class_name HandView

## The player's hand, laid out and animated the way Hearthstone's is.
##
## Cards fan along a shallow arc and overlap once there are too many to sit
## side by side. Resting the pointer on one straightens and lifts it, nudges its
## neighbours aside, and shows it large enough to read. A picked-up card leaves
## the fan and follows the pointer until it is played, which fades it out where
## it was let go, or put back, which flies it home.
##
## Like the rest of the client this is presentation only. `main.gd` builds the
## small card panels, decides what a press or a drop means, and tells this what
## happened; this only places and animates. Hit-testing uses where cards rest in
## the fan rather than where they are drawn, so a card lifting under the
## pointer never moves itself out from beneath it.

const CARD_SIZE := Vector2(104, 138)
const HEIGHT := 164.0
## Largest distance between neighbouring cards' centres. A hand too wide for the
## view at this spacing closes up, and the cards overlap.
const MAX_SPACING := 110.0
const MIN_SPACING := 18.0
const SIDE_PAD := 8.0
## The whole fan turns through at most FAN_ARC radians (about 18°), and one card
## from the next through at most FAN_STEP (about 4°).
const FAN_ARC := 0.32
const FAN_STEP := 0.07
## How far the outermost cards sit below the middle one.
const ARC_DROP := 16.0

## A hovered card straightens and rises, and its neighbours make room for it.
const HOVER_LIFT := 18.0
const SPREAD := 34.0
## The large card shown on hover, and how far it grows from when it appears.
const ZOOM_WIDTH := 220.0
const ZOOM_RING := 5
const ZOOM_START := 0.55
const NOTES_WIDTH := 210.0
const NOTES_GAP := 10.0
const VIEW_MARGIN := 8.0

## A held card leans into the direction it is moved, and settles when it stops.
const TILT_PER_PIXEL := 0.012
const MAX_TILT := 0.35
## A card waiting on its target sits above the hand, a little larger.
const PARK_SCALE := 1.15
## A played card fades where it was let go. If the server has not taken it out
## of the hand by SPENT_TIMEOUT, the play was refused and it comes back.
const SPENT_SCALE := 0.6
const SPENT_TIMEOUT := 3.0

## How quickly cards close on where they are going, per second. Higher is
## snappier; a held card tracks the pointer closely.
const FOLLOW := 16.0
const FOLLOW_HELD := 30.0
const FOLLOW_ZOOM := 24.0
const SETTLE_TILT := 8.0

const Z_HOVER := 1
const Z_GLOW := 49
const Z_HELD := 50
const Z_ZOOM := 55

const COLOR_BACKDROP := Color(0.09, 0.10, 0.13, 0.97)
const COLOR_BORDER := Color(0.85, 0.74, 0.44)
const COLOR_DIM := Color(0.66, 0.69, 0.76)
const COLOR_NOTE := Color(1.0, 0.62, 0.55)
const COLOR_GLOW := Color(0.45, 0.85, 0.55)

## One card in the hand: the panel `main.gd` built for it, what it shows, and
## where it currently is, which eases toward where it is going each frame.
class Entry:
	var id := ""
	var panel: Control
	## definition_id, unaffordable, ring (a Color) and note (why it cannot be
	## played, or "").
	var info: Dictionary = {}
	var center := Vector2.ZERO
	var turn := 0.0
	var scale := 1.0
	var alpha := 0.0
	var base_modulate := Color.WHITE
	## Seconds since it was played, or -1 while it is in the hand.
	var spent_for := -1.0
	var seen := true

var library: CardLibrary

var _entries: Dictionary = {}
## Card ids in hand order, left to right.
var _order: Array[String] = []
var _hovered := ""
var _held := ""
## Where the held card is going, in this control's space.
var _held_at := Vector2.ZERO
var _held_tilt := 0.0
var _parked := false
var _ready_glow := false

var _zoom: PanelContainer
var _zoom_scale := ZOOM_START
var _notes: PanelContainer
var _glow: Panel
var _glow_frame: CardFrame
var _glow_style: StyleBoxFlat
var _glow_empty := StyleBoxEmpty.new()
var _empty: Label

func setup(card_library: CardLibrary) -> void:
	library = card_library

func _init() -> void:
	custom_minimum_size.y = HEIGHT
	mouse_filter = Control.MOUSE_FILTER_PASS
	mouse_exited.connect(clear_hover)

	_empty = Label.new()
	_empty.text = "(no cards in hand)"
	_empty.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_empty.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_empty.add_theme_color_override("font_color", COLOR_DIM)
	add_child(_empty)

	# Drawn behind a held card when letting go would play it.
	_glow = Panel.new()
	_glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_glow.z_index = Z_GLOW
	_glow.visible = false
	var glow_style := StyleBoxFlat.new()
	_glow_style = glow_style
	glow_style.draw_center = false
	glow_style.border_color = COLOR_GLOW
	glow_style.set_border_width_all(3)
	glow_style.set_corner_radius_all(9)
	glow_style.shadow_color = Color(COLOR_GLOW, 0.6)
	glow_style.shadow_size = 14
	_glow.add_theme_stylebox_override("panel", glow_style)
	_glow.draw.connect(_draw_held_outline)
	add_child(_glow)

	_zoom = PanelContainer.new()
	_zoom.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_zoom.z_index = Z_ZOOM
	_zoom.visible = false
	add_child(_zoom)

	_notes = PanelContainer.new()
	_notes.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_notes.z_index = Z_ZOOM
	_notes.visible = false
	var notes_style := StyleBoxFlat.new()
	notes_style.bg_color = COLOR_BACKDROP
	notes_style.border_color = COLOR_BORDER
	notes_style.set_border_width_all(2)
	notes_style.set_corner_radius_all(8)
	notes_style.set_content_margin_all(10)
	notes_style.shadow_color = Color(0, 0, 0, 0.45)
	notes_style.shadow_size = 8
	_notes.add_theme_stylebox_override("panel", notes_style)
	add_child(_notes)

# --- Contents ---------------------------------------------------------------

## Starts a refresh of the hand: every card not put back by `end_update` leaves.
func begin_update() -> void:
	for id in _entries:
		(_entries[id] as Entry).seen = false
	_order.clear()

## Puts a card in the hand, in order. A card already there keeps where it is
## and eases to its new place; a new one comes in from the deck, off the right.
## `panel` replaces the card's previous panel, and is owned by this from now on.
func put_card(id: String, panel: Control, info: Dictionary) -> void:
	var entry: Entry = _entries.get(id, null)
	if entry == null:
		entry = Entry.new()
		entry.id = id
		entry.center = Vector2(size.x + CARD_SIZE.x, _height() * 0.5)
		_entries[id] = entry
	elif entry.panel != null and is_instance_valid(entry.panel):
		remove_child(entry.panel)
		entry.panel.queue_free()
	entry.panel = panel
	entry.info = info
	entry.seen = true
	entry.base_modulate = panel.modulate
	# The hand does its own hit-testing, against where cards rest.
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(panel)
	_order.append(id)
	_apply(entry)

## Finishes a refresh: cards that left the hand go, and the rest draw in order.
func end_update() -> void:
	for id in _entries.keys():
		var entry: Entry = _entries[id]
		if entry.seen:
			continue
		if entry.panel != null and is_instance_valid(entry.panel):
			remove_child(entry.panel)
			entry.panel.queue_free()
		_entries.erase(id)
	if not _entries.has(_held):
		_held = ""
		_parked = false
	# Later cards draw over earlier ones, as they overlap in a fan.
	for index in _order.size():
		move_child((_entries[_order[index]] as Entry).panel, index)
	_empty.visible = _order.is_empty()
	# The hovered card may have become affordable, or left the hand.
	var hovered := _hovered
	_hovered = ""
	hover(hovered if _entries.has(hovered) else "")

func clear_cards() -> void:
	begin_update()
	end_update()

func card_ids() -> Array[String]:
	return _order.duplicate()

func info_for(id: String) -> Dictionary:
	var entry: Entry = _entries.get(id, null)
	return entry.info if entry != null else {}

## The panel drawn for a card, or null when it is not in the hand.
func panel_for(id: String) -> Control:
	var entry: Entry = _entries.get(id, null)
	return entry.panel if entry != null else null

# --- Hit-testing ------------------------------------------------------------

## The card under a global point, by where cards rest in the fan, or "". Where
## cards overlap, the one drawn on top wins.
func card_at(at: Vector2) -> String:
	if not get_global_rect().has_point(at):
		return ""
	var fan := _fan()
	var local := at - global_position
	for index in range(fan.size() - 1, -1, -1):
		var rest := _rest(index, fan.size())
		var offset: Vector2 = (local - (rest[0] as Vector2)).rotated(-float(rest[1]))
		if absf(offset.x) <= CARD_SIZE.x * 0.5 and absf(offset.y) <= CARD_SIZE.y * 0.5:
			return fan[index]
	return ""

## Where a card rests in the fan, as an unrotated global rect.
func rest_rect(id: String) -> Rect2:
	var fan := _fan()
	var index := fan.find(id)
	if index < 0:
		return Rect2()
	var center: Vector2 = _rest(index, fan.size())[0]
	return Rect2(global_position + center - CARD_SIZE * 0.5, CARD_SIZE)

# --- Hover ------------------------------------------------------------------

## Shows `id` large, or nothing for "". Safe to call every pointer move.
func hover(id: String) -> void:
	if _held != "":
		id = ""
	if id == _hovered:
		return
	_hovered = id
	_build_zoom()

func clear_hover() -> void:
	hover("")

func hovered_id() -> String:
	return _hovered

func is_zoomed() -> bool:
	return _zoom.visible

# --- Holding ----------------------------------------------------------------

## Takes a card out of the fan to follow the pointer, from global point `at`.
func pick_up(id: String, at: Vector2) -> void:
	if not _entries.has(id):
		return
	clear_hover()
	_held = id
	_held_at = at - global_position
	_held_tilt = 0.0
	_parked = false
	_ready_glow = false

func move_held(at: Vector2) -> void:
	if _held == "":
		return
	var local := at - global_position
	_held_tilt = clampf(_held_tilt + (local.x - _held_at.x) * TILT_PER_PIXEL, -MAX_TILT, MAX_TILT)
	_held_at = local
	_parked = false

## Sends the held card above the hand, where the targeting arrow starts.
func park_held() -> void:
	if _held != "":
		_parked = true

func is_parked() -> bool:
	return _parked

## Where a parked card sits, as a global point.
func park_point() -> Vector2:
	return global_position + _park_center()

## Lights the held card up, to say letting go here would play it.
func set_held_ready(lit: bool) -> void:
	_ready_glow = lit

func held_id() -> String:
	return _held

## The held card was played: it fades where it is, and the fan closes up.
## Without `fade` it is gone at once, for an effect that takes over drawing it.
func spend_held(fade := true) -> void:
	var entry: Entry = _entries.get(_held, null)
	if entry != null:
		entry.spent_for = 0.0
		if not fade:
			entry.alpha = 0.0
			_apply(entry)
	_held = ""
	_parked = false

## The held card goes back to its place in the hand.
func return_held() -> void:
	_held = ""
	_parked = false

## Brings back every played card still in the hand, after the server refused
## a play, rather than waiting out SPENT_TIMEOUT.
func restore_spent() -> void:
	for id in _entries:
		(_entries[id] as Entry).spent_for = -1.0

func is_spent(id: String) -> bool:
	var entry: Entry = _entries.get(id, null)
	return entry != null and entry.spent_for >= 0.0

# --- Layout -----------------------------------------------------------------

func _process(delta: float) -> void:
	_held_tilt = lerpf(_held_tilt, 0.0, _ease(SETTLE_TILT, delta))
	var fan := _fan()
	var hovered_index := fan.find(_hovered)
	for id in _order:
		var entry: Entry = _entries[id]
		var weight := _ease(FOLLOW, delta)
		var center := entry.center
		var turn := 0.0
		var grow := 1.0
		var alpha := 1.0
		entry.panel.z_index = 0
		if id == _held:
			weight = _ease(FOLLOW_HELD, delta)
			entry.panel.z_index = Z_HELD
			if _parked:
				center = _park_center()
				grow = PARK_SCALE
			else:
				center = _held_at
				turn = _held_tilt
		elif entry.spent_for >= 0.0:
			entry.spent_for += delta
			entry.panel.z_index = Z_HELD
			grow = SPENT_SCALE
			alpha = 0.0
			if entry.spent_for > SPENT_TIMEOUT:
				entry.spent_for = -1.0
		else:
			var index := fan.find(id)
			var rest := _rest(index, fan.size())
			center = rest[0]
			turn = rest[1]
			if hovered_index >= 0:
				if index == hovered_index:
					center.y -= HOVER_LIFT
					turn = 0.0
					entry.panel.z_index = Z_HOVER
				else:
					var away := index - hovered_index
					center.x += signf(away) * SPREAD / absf(away)
		entry.center = entry.center.lerp(center, weight)
		entry.turn = lerp_angle(entry.turn, turn, weight)
		entry.scale = lerpf(entry.scale, grow, weight)
		entry.alpha = lerpf(entry.alpha, alpha, weight)
		_apply(entry)
	_place_glow()
	_place_zoom(delta, fan, hovered_index)

## Cards taking part in the fan: everything not held and not just played.
func _fan() -> Array[String]:
	var fan: Array[String] = []
	for id in _order:
		if id != _held and (_entries[id] as Entry).spent_for < 0.0:
			fan.append(id)
	return fan

## [centre, rotation] of the card at `index` of `count` resting in the fan.
func _rest(index: int, count: int) -> Array:
	var spacing := MAX_SPACING
	if count > 1:
		var room := size.x - SIDE_PAD * 2.0 - CARD_SIZE.x
		spacing = clampf(room / (count - 1), MIN_SPACING, MAX_SPACING)
	var from_middle := index - (count - 1) * 0.5
	var step := FAN_STEP
	if count > 1:
		step = minf(FAN_STEP, FAN_ARC / (count - 1))
	# The outermost cards drop the most, whatever the hand's size, so a small
	# hand curves as much as a full one.
	var reach := maxf((count - 1) * 0.5, 1.0)
	var drop := ARC_DROP * pow(from_middle / reach, 2.0)
	var center := Vector2(size.x * 0.5 + from_middle * spacing, _height() * 0.5 + 4.0 + drop)
	return [center, from_middle * step]

func _park_center() -> Vector2:
	return Vector2(size.x * 0.5, -CARD_SIZE.y * 0.5)

func _height() -> float:
	return size.y if size.y > 0.0 else HEIGHT

func _apply(entry: Entry) -> void:
	var panel := entry.panel
	panel.size = panel.get_combined_minimum_size()
	panel.pivot_offset = panel.size * 0.5
	panel.position = entry.center - panel.size * 0.5
	panel.rotation = entry.turn
	panel.scale = Vector2.ONE * entry.scale
	panel.modulate = entry.base_modulate * Color(1, 1, 1, entry.alpha)

func _place_glow() -> void:
	var entry: Entry = _entries.get(_held, null)
	_glow.visible = entry != null and _ready_glow and not _parked
	if not _glow.visible:
		return
	var panel := entry.panel
	_glow.size = panel.size
	_glow.pivot_offset = panel.pivot_offset
	_glow.position = panel.position
	_glow.rotation = panel.rotation
	_glow.scale = panel.scale
	_glow_frame = null
	for child in panel.get_children():
		if child is CardFrame:
			_glow_frame = child
			break
	if _glow_frame != null:
		_glow.add_theme_stylebox_override("panel", _glow_empty)
	else:
		_glow.add_theme_stylebox_override("panel", _glow_style)
	_glow.queue_redraw()

func _draw_held_outline() -> void:
	if is_instance_valid(_glow_frame):
		_glow_frame.draw_outline(_glow, _glow_frame.position, COLOR_GLOW, 6.0)

## Stands the large card on the bottom of the hand, centred over the hovered
## card and kept inside the view, growing to full size as it appears.
func _place_zoom(delta: float, fan: Array[String], hovered_index: int) -> void:
	if not _zoom.visible or hovered_index < 0:
		return
	_zoom_scale = lerpf(_zoom_scale, 1.0, _ease(FOLLOW_ZOOM, delta))
	var zoom_size := _zoom.get_combined_minimum_size()
	_zoom.size = zoom_size
	_zoom.pivot_offset = Vector2(zoom_size.x * 0.5, zoom_size.y)
	_zoom.scale = Vector2.ONE * _zoom_scale
	var view := get_viewport_rect().size
	var rest: Vector2 = _rest(hovered_index, fan.size())[0]
	var left := global_position.x + rest.x - zoom_size.x * 0.5
	left = clampf(left, VIEW_MARGIN, maxf(VIEW_MARGIN, view.x - zoom_size.x - VIEW_MARGIN))
	var top := global_position.y + _height() - zoom_size.y
	top = maxf(top, VIEW_MARGIN)
	_zoom.position = Vector2(left, top) - global_position

	if not _notes.visible:
		return
	var notes_size := _notes.get_combined_minimum_size()
	_notes.size = notes_size
	# Beside the card, to the right by preference, as Hearthstone's keyword
	# boxes are; flipped left where the right edge is too close.
	var notes_left := left + zoom_size.x + NOTES_GAP
	if notes_left + notes_size.x > view.x - VIEW_MARGIN:
		notes_left = left - NOTES_GAP - notes_size.x
	_notes.position = Vector2(notes_left, top) - global_position
	_notes.modulate.a = clampf((_zoom_scale - ZOOM_START) / (1.0 - ZOOM_START), 0.0, 1.0)

func _build_zoom() -> void:
	for child in _zoom.get_children():
		_zoom.remove_child(child)
		child.queue_free()
	for child in _notes.get_children():
		_notes.remove_child(child)
		child.queue_free()
	var entry: Entry = _entries.get(_hovered, null)
	if entry == null or library == null:
		_zoom.visible = false
		_notes.visible = false
		return

	var info := entry.info
	var definition_id := str(info.get("definition_id", ""))
	var ring := StyleBoxFlat.new()
	ring.bg_color = info.get("ring", COLOR_BACKDROP)
	ring.set_corner_radius_all(8)
	ring.set_content_margin_all(ZOOM_RING)
	ring.shadow_color = Color(0, 0, 0, 0.5)
	ring.shadow_size = 12
	_zoom.add_theme_stylebox_override("panel", ring)

	var notes: Array[Control] = []
	if CardFrame.supports(library, definition_id):
		var frame := CardFrame.make(library, {
			"definition_id": definition_id,
			"unaffordable": bool(info.get("unaffordable", false)),
		}, ZOOM_WIDTH, true)
		# The frame is clear at its sides, so the card draws the ring round
		# its own body and the panel only keeps room for it.
		frame.ring_color = ring.bg_color
		frame.ring_width = ZOOM_RING
		frame.ring_shadow = ring.shadow_size
		var room := StyleBoxEmpty.new()
		room.set_content_margin_all(ZOOM_RING)
		_zoom.add_theme_stylebox_override("panel", room)
		_zoom.add_child(frame)
		# Rules too long for the card's text box are printed beside it in full.
		if not frame.rules_fit:
			notes.append(_rich(library.description_bbcode(definition_id), 13, Color.WHITE))
	else:
		_zoom.add_child(_zoom_tile(definition_id, bool(info.get("unaffordable", false))))

	var kind := library.card_type(definition_id)
	var is_weapon := kind == "WEAPON"
	var explained: Array[String] = []
	for keyword in library.keywords(definition_id):
		explained.append(CardLibrary.keyword_line(str(keyword), is_weapon))
	if is_weapon and library.is_ranged_weapon(definition_id):
		explained.append(CardLibrary.keyword_line("RANGED", true))
	if not explained.is_empty():
		notes.append(_line("\n".join(explained), 12, COLOR_BORDER))
	var note := str(info.get("note", ""))
	if note != "":
		notes.append(_line(note, 12, COLOR_NOTE))

	if not notes.is_empty():
		var column := VBoxContainer.new()
		column.mouse_filter = Control.MOUSE_FILTER_IGNORE
		column.custom_minimum_size.x = NOTES_WIDTH
		column.add_theme_constant_override("separation", 8)
		for control in notes:
			column.add_child(control)
		_notes.add_child(column)
	_notes.visible = not notes.is_empty()
	_zoom.visible = true
	_zoom_scale = ZOOM_START
	_zoom.scale = Vector2.ONE * ZOOM_START
	_place_zoom(0.0, _fan(), _fan().find(_hovered))

## A card without a frame, drawn large: its name, type and cost, art, rules
## and flavour, at the frame's size so every card in the hand zooms alike.
func _zoom_tile(definition_id: String, unaffordable: bool) -> Control:
	var tile := PanelContainer.new()
	tile.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tile.custom_minimum_size = Vector2(ZOOM_WIDTH, roundf(ZOOM_WIDTH / CardFrame.ASPECT))
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.14, 0.15, 0.19)
	style.border_color = COLOR_BORDER
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(10)
	tile.add_theme_stylebox_override("panel", style)

	var column := VBoxContainer.new()
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override("separation", 6)
	tile.add_child(column)

	var title := _line(library.card_name(definition_id), 18, Color.WHITE)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(title)

	var parts: Array[String] = []
	var kind := library.card_type(definition_id)
	if kind != "":
		parts.append(kind.capitalize())
	parts.append("%d Taika" % library.cost(definition_id))
	var type_line := _line("  ·  ".join(parts), 12, COLOR_NOTE if unaffordable else COLOR_DIM)
	type_line.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(type_line)

	var banner := CardArt.make_banner(definition_id, 110.0)
	if banner != null:
		column.add_child(banner)

	if kind == "WEAPON":
		var stats := _line("⚔ %d   ◈ %d" % [
			library.base_attack(definition_id), library.base_durability(definition_id),
		], 16, Color.WHITE)
		stats.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		column.add_child(stats)

	column.add_child(_rich(library.description_bbcode(definition_id), 13, Color.WHITE))
	var story := library.flavour_bbcode(definition_id)
	if story != "":
		column.add_child(_rich(story, 11, COLOR_DIM))
	return tile

func _line(text: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label

func _rich(bbcode: String, font_size: int, color: Color) -> RichTextLabel:
	var label := RichTextLabel.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.bbcode_enabled = true
	label.fit_content = true
	label.scroll_active = false
	label.text = bbcode
	for setting in ["normal_font_size", "bold_font_size", "italics_font_size", "bold_italics_font_size"]:
		label.add_theme_font_size_override(setting, font_size)
	label.add_theme_color_override("default_color", color)
	return label

## The share of the remaining distance to cover this frame, at `rate` per
## second, so easing looks the same at any frame rate.
static func _ease(rate: float, delta: float) -> float:
	return 1.0 - exp(-rate * delta)
