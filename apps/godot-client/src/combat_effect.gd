extends Control
class_name CombatEffect

## Presentation only: copies of the two tokens survive the state update at
## impact, even when combat removes their creatures from the battlefield.
signal impacted
signal finished

const WINDUP := 0.14
const LUNGE := 0.085
const HIT_PAUSE := 0.045
const RETURN := 0.24
const DUST_LIFE := 0.38
const IMPACT_AT := WINDUP + LUNGE
const DURATION := IMPACT_AT + DUST_LIFE

class Fighter:
	var id := ""
	var token: CreatureToken
	var home := Vector2.ZERO
	var size := Vector2.ZERO
	var dead := false

class Dust:
	var velocity := Vector2.ZERO
	var radius := 0.0
	var life := 0.0
	var tint := Color.WHITE

var _attacker: Fighter
var _defender: Fighter
var _direction := Vector2.UP
var _contact := Vector2.ZERO
var _hit_point := Vector2.ZERO
var _age := 0.0
var _hit := false
var _weight := 0.0
var _dust: Array[Dust] = []
var _shake_target: Control
var _rest_position := Vector2.ZERO

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	set_process(false)

## "Bigger" means higher current combat stats, since board tokens share a
## fixed size. Small creatures have no screen shake; the biggest cap at 6px.
static func weight_for(card: Dictionary) -> float:
	var attack := float(card.get("attack", 0))
	var health := float(card.get("max_health", card.get("health", 0)))
	return clampf((maxf(attack, (attack + health) * 0.5) - 3.0) / 7.0, 0.0, 1.0)

func play(library: CardLibrary, source_id: String, source_card: Dictionary,
		source_rect: Rect2, target_id: String, target_card: Dictionary,
		target_rect: Rect2, shake_target: Control = null) -> void:
	if is_busy() or not source_rect.has_area() or not target_rect.has_area():
		return
	_attacker = _fighter(library, source_id, source_card, source_rect)
	_defender = _fighter(library, target_id, target_card, target_rect)
	_direction = (_defender.home - _attacker.home).normalized()
	if _direction.is_zero_approx():
		_direction = Vector2.UP
	var reach := _attacker.size + _defender.size
	var contact_distance := (absf(_direction.x) * reach.x + absf(_direction.y) * reach.y) * 0.28
	_contact = _defender.home - _direction * contact_distance
	_hit_point = _defender.home - _direction * _defender.size * 0.24
	_weight = weight_for(source_card)
	_shake_target = shake_target
	if is_instance_valid(_shake_target):
		_rest_position = _shake_target.position
	_age = 0.0
	_hit = false
	_dust.clear()
	_make_dust()
	# Stops board clicks and scrolling while the copied tokens are in flight.
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_process(true)
	_pose()
	queue_redraw()

func is_busy() -> bool:
	return _attacker != null

func has_impacted() -> bool:
	return is_busy() and _hit

func owns(entity_id: String) -> bool:
	return is_busy() and (entity_id == _attacker.id or entity_id == _defender.id)

## Read the authoritative result at the hit, including simultaneous deaths.
func resolve(library: CardLibrary, state: Dictionary) -> void:
	if not has_impacted():
		return
	for fighter: Fighter in [_attacker, _defender]:
		var creature := _creature(state, fighter.id)
		fighter.dead = creature.is_empty()
		if not fighter.dead:
			fighter.token.show_card(library, {
				"definition_id": creature.get("definitionId", ""),
				"attack": creature.get("currentAttack", 0),
				"health": creature.get("currentHealth", 0),
				"max_health": creature.get("maxHealth", 0),
				"statuses": creature.get("statuses", []),
			})
	_pose()

func cancel() -> void:
	if not is_busy():
		return
	_restore_shake()
	_attacker.token.queue_free()
	_defender.token.queue_free()
	_attacker = null
	_defender = null
	_dust.clear()
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(false)
	queue_redraw()
	finished.emit()

func _exit_tree() -> void:
	_restore_shake()

func _restore_shake() -> void:
	if is_instance_valid(_shake_target):
		_shake_target.position = _rest_position
	_shake_target = null

func _process(delta: float) -> void:
	if not is_busy():
		return
	_age += delta
	if not _hit and _age >= IMPACT_AT:
		_hit = true
		impacted.emit()
	_pose()
	queue_redraw()
	if _age >= DURATION:
		cancel()

func _fighter(library: CardLibrary, id: String, card: Dictionary, rect: Rect2) -> Fighter:
	var fighter := Fighter.new()
	fighter.id = id
	var local_rect := get_global_transform().affine_inverse() * rect
	fighter.home = local_rect.get_center()
	fighter.size = local_rect.size
	fighter.token = CreatureToken.make(library, card, fighter.size)
	fighter.token.size = fighter.size
	fighter.token.pivot_offset = fighter.size * 0.5
	add_child(fighter.token)
	return fighter

func _pose() -> void:
	var from := _attacker.home
	var centre := from
	var lift := 1.0
	var turn := 0.0
	var pullback := from - _direction * (18.0 + _weight * 12.0)
	var tilt := -0.075 if _direction.x >= 0.0 else 0.075
	if _age < WINDUP:
		var t := smoothstep(0.0, WINDUP, _age)
		centre = from.lerp(pullback, t)
		lift = lerpf(1.0, 1.08, t)
		turn = tilt * t
	elif _age < IMPACT_AT:
		var t := clampf((_age - WINDUP) / LUNGE, 0.0, 1.0)
		centre = pullback.lerp(_contact, t * t * t)
		lift = lerpf(1.08, 1.03, t)
		turn = lerpf(tilt, -tilt * 0.4, t)
	else:
		var t := clampf((_age - IMPACT_AT - HIT_PAUSE) / RETURN, 0.0, 1.0)
		var ease := 1.0 - pow(1.0 - t, 3.0)
		centre = _contact.lerp(from, ease)
		lift = lerpf(1.03, 1.0, ease)
		turn = -tilt * 0.4 * (1.0 - ease)
	_place(_attacker, centre, Vector2.ONE * lift, turn)

	var hit_age := maxf(0.0, _age - IMPACT_AT)
	var recoil := sin(minf(hit_age / 0.065, 1.0) * PI * 0.5) * exp(-hit_age * 13.0) if _hit else 0.0
	var squash := recoil * (0.10 + _weight * 0.05)
	var target_scale := Vector2(1.0 + squash, 1.0 - squash)
	if absf(_direction.x) > absf(_direction.y):
		target_scale = Vector2(target_scale.y, target_scale.x)
	_place(_defender, _defender.home + _direction * recoil * (12.0 + _weight * 15.0),
		target_scale, recoil * -tilt)
	if _hit:
		var flash := 1.0 + 0.65 * (1.0 - clampf(hit_age / 0.09, 0.0, 1.0))
		for fighter: Fighter in [_attacker, _defender]:
			var alpha := 1.0 - clampf(hit_age / 0.19, 0.0, 1.0) if fighter.dead else 1.0
			fighter.token.modulate = Color(flash, flash, flash, alpha)
	if is_instance_valid(_shake_target):
		var fade := pow(1.0 - clampf(hit_age / 0.25, 0.0, 1.0), 2.0)
		var amplitude := 6.0 * _weight * fade if _hit else 0.0
		_shake_target.position = _rest_position + Vector2(
			cos(hit_age * 105.0), sin(hit_age * 137.0) * 0.65) * amplitude

func _place(fighter: Fighter, centre: Vector2, stretch: Vector2, turn: float) -> void:
	fighter.token.position = centre - fighter.size * 0.5
	fighter.token.scale = stretch
	fighter.token.rotation = turn

func _make_dust() -> void:
	# Local RNG keeps cosmetic variation separate from every other effect.
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	for index in 18 + int(_weight * 18.0):
		var puff := Dust.new()
		var angle := rng.randf_range(0.0, TAU)
		puff.velocity = Vector2.from_angle(angle) * rng.randf_range(75.0, 235.0) * (1.0 + _weight * 0.45)
		puff.velocity += _direction * rng.randf_range(20.0, 75.0)
		puff.radius = rng.randf_range(3.0, 8.0) * (1.0 + _weight * 0.35)
		puff.life = rng.randf_range(0.23, DUST_LIFE)
		puff.tint = Color(0.73, 0.65, 0.52).lerp(Color(0.94, 0.86, 0.69), rng.randf())
		_dust.append(puff)

func _draw() -> void:
	if not is_busy():
		return
	# A soft ground shadow makes the windup read as a lifted creature.
	var shadow := Rect2(_attacker.home - _attacker.size * Vector2(0.43, -0.30),
		_attacker.size * Vector2(0.86, 0.20))
	draw_colored_polygon(CreatureToken._ellipse(shadow, 40), Color(0, 0, 0, 0.24))
	if not _hit:
		return
	var age := _age - IMPACT_AT
	if age < 0.12:
		var flash := Color(1.0, 0.91, 0.68, (1.0 - age / 0.12) * 0.8)
		var radius := (10.0 + age * 190.0) * (1.0 + _weight * 0.5)
		draw_circle(_hit_point, radius, flash, false, 3.0, true)
	for puff in _dust:
		if age >= puff.life:
			continue
		var t := age / puff.life
		var travel := puff.velocity * age * (1.0 - t * 0.4) + Vector2(0, -24.0 * t * t)
		var tint := puff.tint
		tint.a = pow(1.0 - t, 2.0) * 0.65
		var radius := puff.radius * (0.45 + t * 1.4)
		draw_circle(_hit_point + travel, radius, tint, true, -1.0, true)

static func _creature(state: Dictionary, entity_id: String) -> Dictionary:
	for side: Dictionary in (state.get("sides", {}) as Dictionary).values():
		var creatures: Dictionary = side.get("creatures", {})
		if creatures.has(entity_id):
			return creatures[entity_id]
	return {}
