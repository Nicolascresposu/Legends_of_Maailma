extends Control
class_name CardPlayEffect

## The moment a card leaves the hand for good, drawn the way Hearthstone draws a
## minion landing. The card crumbles away from its edges in a quick burst of
## shards; a Creature's art oval is left behind and drops into the slot it was
## played to, lands with a bump and a puff of dust, and becomes its token.
##
## Pure presentation, like the arrow and the reveal: it takes no input and
## knows nothing of the rules. `main.gd` hands it a fresh copy of the played
## card, the card as it was drawn when let go, and where the oval is going; and
## hides that slot's token until the oval is down.
##
## The copy is drawn into a small offscreen viewport, so the shards carry the
## card's real pixels, name and badges included, wherever they fly.

## The oval reached its slot. The token there can be shown.
signal landed(slot_key: String)

## The card is cut into a jittered grid of triangles, each split on a random
## diagonal, so it breaks into irregular shards rather than tiles.
const SHARD_COLS := 6
const SHARD_ROWS := 8
const JITTER := 0.3
## Shards go from the edges in: the outermost at once, the innermost this much
## later, so the card crumbles towards its art.
const STAGGER := 0.08
const SHARD_LIFE_MIN := 0.18
const SHARD_LIFE_MAX := 0.32
const SHARD_SPEED_MIN := 90.0
const SHARD_SPEED_MAX := 240.0
const SHARD_SPIN := 7.0
## Shards shrink to this share of their size as they go.
const SHARD_SHRINK := 0.45
const GRAVITY := 520.0
## Shards flare warm as they burn away.
const FLARE := Color(1.0, 0.80, 0.52)
## Slivers smaller than this, in square pixels, are not worth a shard.
const MIN_SHARD_AREA := 4.0

## The oval waits a beat for the card to start crumbling, then drops.
const HOLD := 0.05
const FALL := 0.30
## How high the oval rises before it drops, as extra size (nearer the eye) and
## as pixels up the screen. It rises over the first RISE share of the fall.
const LIFT := 0.22
const LIFT_PIXELS := 26.0
const RISE := 0.3
## The bump on landing: a squash that springs back over BUMP seconds.
const BUMP := 0.16
const SQUASH := 0.10
## The ring of dust thrown up on landing.
const DUST_TIME := 0.32
const DUST_GROW := 0.40
const DUST_WIDTH := 3.0
const COLOR_DUST := Color(0.86, 0.80, 0.68, 0.65)
const COLOR_SHADOW := Color(0, 0, 0, 0.45)
## The oval fades into the token beneath it once that is showing.
const FADE := 0.12
## Longest a landed oval waits for the server to put the creature in its slot;
## the hand gives a played card back after the same time.
const WAIT_MAX := HandView.SPENT_TIMEOUT

## One piece of a card, in card space, with how it flies.
class Shard:
	var points := PackedVector2Array()
	var uvs := PackedVector2Array()
	var centroid := Vector2.ZERO
	var velocity := Vector2.ZERO
	var spin := 0.0
	var delay := 0.0
	var life := 0.0

## One played card breaking up.
class Burst:
	var viewport: SubViewport
	## Card space to global, as the card was drawn when let go.
	var to_global := Transform2D.IDENTITY
	var card_size := Vector2.ZERO
	var shards: Array[Shard] = []
	var age := 0.0
	## The surviving oval, in card space; no area when nothing survives.
	var oval := Rect2()
	## Where the oval lands, as a global rect.
	var landing := Rect2()
	var slot_key := ""
	var landed := false
	## When the oval started to fade, by `age`; -1 while it has not.
	var fade_from := -1.0
	var released := false

var _bursts: Array[Burst] = []

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR

## Breaks up `card`, a fresh copy of the played card that this now owns, where
## `held` (the card as the hand drew it) is. Given a `landing` rect (global),
## a Creature's oval survives and drops onto it, and `landed` is emitted with
## `slot_key` when it is down.
func play(card: Control, held: Control, landing := Rect2(), slot_key := "") -> void:
	var burst := Burst.new()
	burst.card_size = held.size
	burst.to_global = held.get_global_transform()
	burst.slot_key = slot_key

	burst.viewport = SubViewport.new()
	burst.viewport.transparent_bg = true
	burst.viewport.disable_3d = true
	burst.viewport.gui_disable_input = true
	burst.viewport.size = Vector2i(ceili(held.size.x), ceili(held.size.y))
	burst.viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	card.position = Vector2.ZERO
	card.size = held.size
	burst.viewport.add_child(card)
	add_child(burst.viewport)

	var frame := _frame_in(card)
	if frame != null and landing.has_area():
		# The frame sits centred in the card's panel, inside its ring.
		var at := (held.size - frame.custom_minimum_size) * 0.5
		var art := frame.art_rect()
		burst.oval = Rect2(at + art.position, art.size)
		burst.landing = landing
	burst.shards = _cut(burst)
	_bursts.append(burst)
	queue_redraw()

## Whether an oval is still on its way to `slot_key`.
func is_flying(slot_key: String) -> bool:
	for burst in _bursts:
		if burst.slot_key == slot_key and burst.oval.has_area() and not burst.landed:
			return true
	return false

## Whether an oval has landed on `slot_key` and is waiting for its token.
func is_waiting(slot_key: String) -> bool:
	for burst in _bursts:
		if burst.slot_key == slot_key and burst.landed and not burst.released:
			return true
	return false

## The token at `slot_key` is showing: its oval fades into it.
func release(slot_key: String) -> void:
	for burst in _bursts:
		if burst.slot_key == slot_key:
			burst.released = true

## A play was refused: every oval still out fades where it is.
func cancel_all() -> void:
	for burst in _bursts:
		burst.released = true
		if burst.fade_from < 0.0:
			burst.fade_from = burst.age

func is_busy() -> bool:
	return not _bursts.is_empty()

func _process(delta: float) -> void:
	if _bursts.is_empty():
		return
	for burst: Burst in _bursts.duplicate():
		burst.age += delta
		var fall_age := burst.age - HOLD
		if burst.oval.has_area() and not burst.landed and fall_age >= FALL:
			burst.landed = true
			landed.emit(burst.slot_key)
		# Fade once released and the bump has settled, or once it has waited
		# for its token too long.
		if burst.fade_from < 0.0 and burst.landed:
			var settled := fall_age >= FALL + BUMP
			var waited := fall_age >= FALL + WAIT_MAX
			if (burst.released and settled) or waited:
				burst.fade_from = burst.age
		if _finished(burst):
			_bursts.erase(burst)
			burst.viewport.queue_free()
	queue_redraw()

func _finished(burst: Burst) -> bool:
	for shard in burst.shards:
		if burst.age < shard.delay + shard.life:
			return false
	if not burst.oval.has_area():
		return true
	var dust_done := burst.age - HOLD >= FALL + DUST_TIME
	return dust_done and burst.fade_from >= 0.0 and burst.age >= burst.fade_from + FADE

func _draw() -> void:
	var to_local := get_global_transform().affine_inverse()
	for burst in _bursts:
		var texture := burst.viewport.get_texture()
		if burst.oval.has_area():
			_draw_landing(burst, to_local)
		for shard in burst.shards:
			_draw_shard(burst, shard, texture, to_local)
		if burst.oval.has_area():
			_draw_oval(burst, texture, to_local)

func _draw_shard(burst: Burst, shard: Shard, texture: Texture2D, to_local: Transform2D) -> void:
	var age := burst.age - shard.delay
	if age > shard.life:
		return
	var points := PackedVector2Array()
	var centre := burst.to_global * shard.centroid
	if age <= 0.0:
		# Not gone yet: still part of the card, exactly where it was.
		for point in shard.points:
			points.append(to_local * (burst.to_global * point))
		draw_colored_polygon(points, Color.WHITE, shard.uvs, texture)
		return
	var progress := age / shard.life
	var travel := burst.to_global.basis_xform(shard.velocity) * age + Vector2(0, 0.5 * GRAVITY * age * age)
	var shrink := lerpf(1.0, SHARD_SHRINK, progress)
	var turn := shard.spin * age
	for point in shard.points:
		var offset := (burst.to_global * point - centre).rotated(turn) * shrink
		points.append(to_local * (centre + offset + travel))
	var color := Color.WHITE.lerp(FLARE, minf(progress * 2.0, 1.0))
	color.a = 1.0 - progress
	draw_colored_polygon(points, color, shard.uvs, texture)

## Where the oval is at this moment: centre, size and turn, all global.
func _oval_pose(burst: Burst) -> Dictionary:
	var start_centre := burst.to_global * burst.oval.get_center()
	var start_size := burst.oval.size * burst.to_global.get_scale()
	var start_turn := burst.to_global.get_rotation()
	var fall_age := burst.age - HOLD
	var progress := clampf(fall_age / FALL, 0.0, 1.0)
	var across := smoothstep(0.0, 1.0, progress)
	# Up over the first RISE of the fall, then down again, gathering speed.
	var height := 0.0
	if progress < RISE:
		height = smoothstep(0.0, RISE, progress)
	else:
		height = 1.0 - pow((progress - RISE) / (1.0 - RISE), 2.0)
	var oval_size := start_size.lerp(burst.landing.size, across) * (1.0 + LIFT * height)
	var centre := start_centre.lerp(burst.landing.get_center(), across) - Vector2(0, LIFT_PIXELS * height)
	if fall_age > FALL:
		# Landed: squashed flat by the bump, springing back.
		var bump := clampf((fall_age - FALL) / BUMP, 0.0, 1.0)
		var squash := SQUASH * sin(PI * bump) * (1.0 - bump)
		oval_size = burst.landing.size * Vector2(1.0 + squash, 1.0 - squash)
		centre = burst.landing.get_center() + Vector2(0, burst.landing.size.y * squash * 0.5)
	return {
		"centre": centre,
		"size": oval_size,
		"turn": lerp_angle(start_turn, 0.0, across),
		"height": height if fall_age <= FALL else 0.0,
		"across": across,
	}

## The shadow growing under the falling oval, and the dust once it lands.
func _draw_landing(burst: Burst, to_local: Transform2D) -> void:
	var pose := _oval_pose(burst)
	var fall_age := burst.age - HOLD
	var alpha := _oval_alpha(burst)
	if fall_age > 0.0 and alpha > 0.0:
		var shadow := COLOR_SHADOW
		shadow.a *= float(pose["across"]) * alpha
		var spread := 1.0 + 0.25 * float(pose["height"])
		var area := Rect2(Vector2.ZERO, burst.landing.size * spread)
		area.position = burst.landing.get_center() + Vector2(0, 4) - area.size * 0.5
		draw_colored_polygon(_to_local(CreatureToken._ellipse(area, 48), to_local), shadow)
	var dust_age := fall_age - FALL
	if dust_age > 0.0 and dust_age < DUST_TIME:
		var spread := dust_age / DUST_TIME
		var ring := Rect2(Vector2.ZERO, burst.landing.size * (1.0 + DUST_GROW * spread))
		ring.position = burst.landing.get_center() - ring.size * 0.5
		var dust := COLOR_DUST
		dust.a *= 1.0 - spread
		var points := _to_local(CreatureToken._ellipse(ring, 48), to_local)
		points.append(points[0])
		draw_polyline(points, dust, DUST_WIDTH * (1.0 - spread * 0.5), true)

func _draw_oval(burst: Burst, texture: Texture2D, to_local: Transform2D) -> void:
	var alpha := _oval_alpha(burst)
	if alpha <= 0.0:
		return
	var pose := _oval_pose(burst)
	var centre: Vector2 = pose["centre"]
	var oval_size: Vector2 = pose["size"]
	var turn: float = pose["turn"]
	var unit := CreatureToken._ellipse(Rect2(-0.5, -0.5, 1.0, 1.0))
	var points := PackedVector2Array()
	var uvs := PackedVector2Array()
	var texture_size := Vector2(burst.viewport.size)
	for point in unit:
		points.append(to_local * (centre + (point * oval_size).rotated(turn)))
		uvs.append((burst.oval.get_center() + point * burst.oval.size) / texture_size)
	draw_colored_polygon(points, Color(1, 1, 1, alpha), uvs, texture)
	# The gilt edge the token has, so the oval reads as the token arriving.
	points.append(points[0])
	draw_polyline(points, Color(CreatureToken.COLOR_EDGE, alpha), CreatureToken.EDGE_WIDTH, true)

func _oval_alpha(burst: Burst) -> float:
	if burst.fade_from < 0.0:
		return 1.0
	return clampf(1.0 - (burst.age - burst.fade_from) / FADE, 0.0, 1.0)

## Cuts the card into shards; with a surviving oval, around it.
func _cut(burst: Burst) -> Array[Shard]:
	var card_size := burst.card_size
	var cell := card_size / Vector2(SHARD_COLS, SHARD_ROWS)
	var grid: Array[PackedVector2Array] = []
	for row in SHARD_ROWS + 1:
		var line := PackedVector2Array()
		for column in SHARD_COLS + 1:
			var point := Vector2(column, row) * cell
			# The outline stays straight, so the card's edge is the edge it had.
			if row > 0 and row < SHARD_ROWS and column > 0 and column < SHARD_COLS:
				point += Vector2(randf_range(-JITTER, JITTER), randf_range(-JITTER, JITTER)) * cell
			line.append(point)
		grid.append(line)

	var oval_points := PackedVector2Array()
	if burst.oval.has_area():
		oval_points = CreatureToken._ellipse(burst.oval, 48)
	var texture_size := Vector2(burst.viewport.size)
	var shards: Array[Shard] = []
	for row in SHARD_ROWS:
		for column in SHARD_COLS:
			var a := grid[row][column]
			var b := grid[row][column + 1]
			var c := grid[row + 1][column + 1]
			var d := grid[row + 1][column]
			var halves: Array[PackedVector2Array] = []
			if randf() < 0.5:
				halves = [PackedVector2Array([a, b, c]), PackedVector2Array([a, c, d])]
			else:
				halves = [PackedVector2Array([a, b, d]), PackedVector2Array([b, c, d])]
			for half in halves:
				var pieces: Array[PackedVector2Array] = [half]
				if not oval_points.is_empty():
					pieces = Geometry2D.clip_polygons(half, oval_points)
				for piece in pieces:
					# A triangle is smaller than the oval, so cutting the oval out
					# never leaves a hole: every piece is a shard.
					if piece.size() >= 3 and absf(_area(piece)) >= MIN_SHARD_AREA:
						shards.append(_shard(piece, card_size, texture_size))
	return shards

func _shard(points: PackedVector2Array, card_size: Vector2, texture_size: Vector2) -> Shard:
	var shard := Shard.new()
	shard.points = points
	var centroid := Vector2.ZERO
	for point in points:
		centroid += point
		shard.uvs.append(point / texture_size)
	centroid /= points.size()
	shard.centroid = centroid
	var away := centroid - card_size * 0.5
	var direction := away.normalized() if away.length() > 0.5 else Vector2.UP
	# Outward, with a little upward puff, as if blown off the card.
	shard.velocity = direction * randf_range(SHARD_SPEED_MIN, SHARD_SPEED_MAX) \
		+ Vector2(randf_range(-40.0, 40.0), -60.0)
	shard.spin = randf_range(-SHARD_SPIN, SHARD_SPIN)
	var edge := ((centroid / card_size) - Vector2(0.5, 0.5)).abs()
	var outward := clampf(maxf(edge.x, edge.y) * 2.0, 0.0, 1.0)
	shard.delay = STAGGER * (1.0 - outward) + randf() * 0.02
	shard.life = randf_range(SHARD_LIFE_MIN, SHARD_LIFE_MAX)
	return shard

func _frame_in(node: Node) -> CardFrame:
	for child in node.get_children():
		if child is CardFrame:
			return child
		var found := _frame_in(child)
		if found != null:
			return found
	return null

func _to_local(points: PackedVector2Array, to_local: Transform2D) -> PackedVector2Array:
	var out := PackedVector2Array()
	for point in points:
		out.append(to_local * point)
	return out

static func _area(points: PackedVector2Array) -> float:
	var total := 0.0
	for index in points.size():
		var a := points[index]
		var b := points[(index + 1) % points.size()]
		total += a.x * b.y - b.x * a.y
	return total * 0.5
