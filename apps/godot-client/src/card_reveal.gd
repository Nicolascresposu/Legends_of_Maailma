extends Control
class_name CardReveal

## The Hearthstone-style hover reveal: resting the pointer on a card in play
## blows it up beside the board so its art and rules text are readable.
##
## The reveal is pure presentation. It reads the card library for the printed
## card and the board entity for the stats that have drifted from it, and it
## never takes pointer input — the small panel underneath stays draggable
## while the large one is showing.

## The panel is a fixed width and hugs its content vertically: a vanilla
## creature is a short card and should not be padded out to the height of one
## with three lines of rules text.
const PANEL_WIDTH := 264.0
## Gap between the hovered panel and the reveal, and from the screen edge.
const GAP := 14.0
const MARGIN := 10.0
## The connection bar and status lines own the top of the window; the reveal
## stays below them rather than covering controls the player is using.
const TOP_MARGIN := 108.0
## Pointer dwell before the reveal appears. Long enough that sweeping the
## pointer across the board does not flash a card at every slot it crosses.
const DELAY := 0.35

const COLOR_BACKDROP := Color(0.09, 0.10, 0.13, 0.97)
const COLOR_BORDER := Color(0.85, 0.74, 0.44)
const COLOR_DIM := Color(0.66, 0.69, 0.76)
const COLOR_BUFF := Color(0.52, 0.88, 0.60)
const COLOR_HURT := Color(0.92, 0.52, 0.52)

var library: CardLibrary

var _panel: PanelContainer
var _art: TextureRect
var _art_slot: Control
var _title: Label
var _type_line: Label
var _stats: Label
var _keywords: Label
var _rules: RichTextLabel
var _flavour: RichTextLabel
var _marks: Label

## What is currently revealed, so a repaint of the same card is a no-op and a
## re-render of the board does not make the reveal flicker.
var _shown_key := ""
## The card waiting out `DELAY`, and how much of it has elapsed.
var _pending_key := ""
var _pending_card: Dictionary = {}
var _pending_anchor := Rect2()
var _elapsed := 0.0
## Whether a re-place is already waiting on the deferred queue.
var _place_queued := false

func _init() -> void:
	# An overlay: it must never intercept a press meant for the card beneath it.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	visible = false

func setup(card_library: CardLibrary) -> void:
	library = card_library

func _ready() -> void:
	set_process(true)
	_build()

func _build() -> void:
	_panel = PanelContainer.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.custom_minimum_size.x = PANEL_WIDTH
	# Shrink to the content's height rather than filling the overlay.
	_panel.size = Vector2(PANEL_WIDTH, 0.0)
	var style := StyleBoxFlat.new()
	style.bg_color = COLOR_BACKDROP
	style.border_color = COLOR_BORDER
	style.set_border_width_all(2)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(12)
	style.shadow_color = Color(0, 0, 0, 0.45)
	style.shadow_size = 10
	_panel.add_theme_stylebox_override("panel", style)
	_panel.minimum_size_changed.connect(_queue_place)
	add_child(_panel)

	var column := VBoxContainer.new()
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override("separation", 6)
	_panel.add_child(column)

	_title = Label.new()
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_title.add_theme_font_size_override("font_size", 19)
	column.add_child(_title)

	_type_line = Label.new()
	_type_line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_type_line.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_type_line.add_theme_font_size_override("font_size", 12)
	_type_line.add_theme_color_override("font_color", COLOR_DIM)
	column.add_child(_type_line)

	# The art keeps its slot in the column so a card without art does not make
	# everything below it jump up relative to a card that has some.
	_art_slot = Control.new()
	_art_slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_art_slot.custom_minimum_size.y = 132
	column.add_child(_art_slot)

	_art = TextureRect.new()
	_art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_art.clip_contents = true
	_art_slot.add_child(_art)

	_stats = Label.new()
	_stats.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stats.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_stats.add_theme_font_size_override("font_size", 17)
	column.add_child(_stats)

	# The printed description comes before the glossary: it is the card as a
	# player would read it, and the glossary below explains its bold words.
	_rules = RichTextLabel.new()
	_rules.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rules.bbcode_enabled = true
	_rules.fit_content = true
	_rules.scroll_active = false
	_rules.add_theme_font_size_override("normal_font_size", 13)
	_rules.add_theme_font_size_override("bold_font_size", 13)
	_rules.add_theme_font_size_override("italics_font_size", 13)
	_rules.add_theme_font_size_override("bold_italics_font_size", 13)
	column.add_child(_rules)

	_keywords = Label.new()
	_keywords.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Left-aligned: these are sentences, and centring wrapped prose is unreadable.
	_keywords.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_keywords.add_theme_font_size_override("font_size", 12)
	_keywords.add_theme_color_override("font_color", COLOR_BORDER)
	column.add_child(_keywords)

	# Flavour sits last and dimmed: it is read after the rules, if at all.
	_flavour = RichTextLabel.new()
	_flavour.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_flavour.bbcode_enabled = true
	_flavour.fit_content = true
	_flavour.scroll_active = false
	for font_size in ["normal_font_size", "bold_font_size", "italics_font_size", "bold_italics_font_size"]:
		_flavour.add_theme_font_size_override(font_size, 12)
	_flavour.add_theme_color_override("default_color", COLOR_DIM)
	column.add_child(_flavour)

	# What the creature cannot do right now ("acted", "sick").
	_marks = Label.new()
	_marks.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_marks.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_marks.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_marks.add_theme_font_size_override("font_size", 11)
	_marks.add_theme_color_override("font_color", COLOR_DIM)
	column.add_child(_marks)

## Asks for `card` to be revealed next to `anchor` (a screen rect).
##
## Called every frame the pointer rests on a card, so it must stay cheap: only
## a change of card does any work, and the reveal waits out `DELAY` first.
##
## `key` identifies what is hovered — a board entity id, or a card id where
## there is no instance. `card` carries the presentation fields:
##   definition_id, attack, health, max_health, durability, marks.
func request(key: String, card: Dictionary, anchor: Rect2) -> void:
	if key == "":
		hide_reveal()
		return
	if key == _shown_key:
		# Already up: keep it where it is rather than chasing a board that may
		# have re-laid out by a pixel.
		return
	if key != _pending_key:
		_pending_key = key
		_pending_card = card
		_pending_anchor = anchor
		_elapsed = 0.0
		# Switching cards while one is already up swaps immediately: the dwell
		# is there to avoid flashing cards at a pointer in transit, and a
		# pointer that has already settled has served it.
		if _shown_key != "":
			_reveal()
	else:
		_pending_card = card
		_pending_anchor = anchor

## Re-reads a card that is already revealed, after the board rebuilt beneath it.
##
## Distinct from `request`: this repaints in place with no dwell, so a creature
## taking damage under the pointer updates as it happens.
func refresh(key: String, card: Dictionary, anchor: Rect2) -> void:
	if _shown_key == "" or key != _shown_key:
		return
	_pending_card = card
	_pending_anchor = anchor
	_fill(card)
	_place(anchor)

## Takes the reveal down, cancelling anything waiting on the dwell timer.
func hide_reveal() -> void:
	_pending_key = ""
	_pending_card = {}
	_elapsed = 0.0
	if _shown_key == "":
		return
	_shown_key = ""
	visible = false

func is_revealing() -> bool:
	return _shown_key != ""

func _process(delta: float) -> void:
	if _pending_key == "" or _pending_key == _shown_key:
		return
	_elapsed += delta
	if _elapsed >= DELAY:
		_reveal()

func _reveal() -> void:
	if library == null or _pending_key == "":
		return
	_shown_key = _pending_key
	_fill(_pending_card)
	visible = true
	# Place it now so it is never drawn in the wrong spot; `_queue_place`
	# corrects it as layout settles the content's real height.
	_place(_pending_anchor)
	_queue_place()

## Re-places the panel once its content has finished laying out.
##
## The panel's height is only final after its wrapped text has been laid out
## at the panel's width, and that can take several passes: a line that was
## hidden for the previous card still has the width it was last given, often
## 1px, so it first measures as one glyph per line and only shrinks once its
## container has sorted it. Every one of those changes reaches the panel as a
## change of minimum size, so re-placing on that signal — deferred, and at
## most once per flush — tracks the height to its final value before the
## frame is drawn, however many passes it takes.
func _queue_place() -> void:
	if _place_queued or _shown_key == "":
		return
	_place_queued = true
	call_deferred("_place_again")

func _place_again() -> void:
	_place_queued = false
	if _shown_key != "":
		_place(_pending_anchor)

func _fill(card: Dictionary) -> void:
	var definition_id := str(card.get("definition_id", ""))
	_title.text = library.card_name(definition_id)

	var kind := library.card_type(definition_id)
	var cost := library.cost(definition_id)
	var parts: Array[String] = []
	if kind != "":
		parts.append(kind.capitalize())
	parts.append("%d Taika" % cost)
	var tag_list := library.tags(definition_id)
	if not tag_list.is_empty():
		parts.append(", ".join(tag_list))
	_type_line.text = "  ·  ".join(parts)

	var texture := CardArt.texture_for(definition_id)
	_art.texture = texture
	_art_slot.visible = texture != null

	_stats.text = _stats_text(definition_id, card)
	# Stats drifting from the printed card is the thing the reveal exists to
	# show, so colour it: buffed green, damaged or shrunk red.
	_stats.add_theme_color_override("font_color", _stats_color(definition_id, card))

	# Keywords are spelled out here rather than merely listed: a board panel
	# already shows the bare names, and what they mean is the reason to look.
	var keyword_list := library.keywords(definition_id)
	var explained: Array[String] = []
	var is_weapon := kind == "WEAPON"
	for keyword in keyword_list:
		explained.append(CardLibrary.keyword_line(str(keyword), is_weapon))
	# Ranged is a Weapon's reach rather than a listed keyword, so a Ranged
	# Weapon explains it here even though it carries no keyword list.
	if is_weapon and library.is_ranged_weapon(definition_id):
		explained.append(CardLibrary.keyword_line("RANGED", true))
	_keywords.text = "\n".join(explained)
	_keywords.visible = not explained.is_empty()

	# Descriptions are written for players, so they are shown as authored,
	# with their bold keywords intact.
	var rules := library.description_bbcode(definition_id)
	_rules.text = rules
	_rules.visible = rules.strip_edges() != ""

	var story := library.flavour_bbcode(definition_id)
	_flavour.text = story
	_flavour.visible = story != ""

	var marks := str(card.get("marks", ""))
	_marks.text = marks
	_marks.visible = marks != ""

## The stat line: live board values where there are any, printed ones otherwise.
func _stats_text(definition_id: String, card: Dictionary) -> String:
	if library.card_type(definition_id) == "WEAPON":
		# An equipped Weapon reports what it has left; one in hand, what it prints.
		var weapon_attack: Variant = card.get("attack", library.base_attack(definition_id))
		var left: Variant = card.get("durability", library.base_durability(definition_id))
		return "⚔ %s   ◈ %s" % [_num(weapon_attack), _num(left)]
	if card.has("durability"):
		return "◈ %s" % _num(card["durability"])
	if not card.has("attack") and not card.has("health"):
		if library.card_type(definition_id) != "CREATURE":
			return ""
		return "⚔ %d   ♥ %d" % [
			library.base_attack(definition_id),
			library.base_health(definition_id),
		]
	var health := _num(card.get("health", ""))
	var max_health := _num(card.get("max_health", health))
	var health_text := health if health == max_health else "%s/%s" % [health, max_health]
	return "⚔ %s   ♥ %s" % [_num(card.get("attack", "")), health_text]

func _stats_color(definition_id: String, card: Dictionary) -> Color:
	if not card.has("attack") or not card.has("health"):
		return Color.WHITE
	var attack := int(card.get("attack", 0))
	var health := int(card.get("health", 0))
	var max_health := int(card.get("max_health", health))
	if attack > library.base_attack(definition_id) or max_health > library.base_health(definition_id):
		return COLOR_BUFF
	if health < max_health or attack < library.base_attack(definition_id):
		return COLOR_HURT
	return Color.WHITE

## Places the panel beside `anchor`, kept inside the viewport.
##
## To the right of the hovered card by preference, flipping to the left when
## there is no room — the same rule Hearthstone uses, and it keeps the reveal
## off the card whose stats you are comparing it against.
func _place(anchor: Rect2) -> void:
	var view := get_viewport_rect().size
	# `size` still holds the previous card's height until the layout pass that
	# follows `_fill`, so ask the content what it needs now.
	var panel_size := Vector2(PANEL_WIDTH, maxf(_panel.get_combined_minimum_size().y, 1.0))
	_panel.size = panel_size

	var x := anchor.position.x + anchor.size.x + GAP
	if x + panel_size.x > view.x - MARGIN:
		x = anchor.position.x - GAP - panel_size.x
	x = clampf(x, MARGIN, maxf(MARGIN, view.x - panel_size.x - MARGIN))

	# Vertically centred on the card, then pushed back inside the viewport.
	var y := anchor.get_center().y - panel_size.y * 0.5
	y = clampf(y, TOP_MARGIN, maxf(TOP_MARGIN, view.y - panel_size.y - MARGIN))

	_panel.position = Vector2(x, y) - global_position

## JSON numbers arrive as floats; render whole numbers without a decimal point.
func _num(value: Variant) -> String:
	match typeof(value):
		TYPE_FLOAT:
			return str(int(round(value as float)))
		TYPE_INT:
			return str(value)
	return str(value)
