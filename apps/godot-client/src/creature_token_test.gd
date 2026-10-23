extends SceneTree

## Checks a creature in play drawn as its art oval, without a server.
##
##   godot --headless --path apps/godot-client --script src/creature_token_test.gd
## Run it windowed with `-- --screenshot-dir=<dir>` to save what it drew.

const WOLF := {
	"id": "wolf", "name": "Wolf", "type": "CREATURE", "cost": 2,
	"attack": 2, "health": 3, "tags": ["BEAST"], "keywords": ["SWIFT"],
	"description": "**Swift**",
}
const NO_ART := {
	"id": "nameless_recruit", "name": "Nameless Recruit", "type": "CREATURE", "cost": 1,
	"attack": 1, "health": 1, "tags": [], "keywords": [],
	"description": "No special abilities.",
}
const WARDEN := {
	"id": "wordy_warden", "name": "Warden", "type": "CREATURE", "cost": 4,
	"attack": 3, "health": 4, "tags": ["HUMAN"],
	"keywords": ["GUARD", "ARRIVAL", "WARD", "LIFESTEAL", "LAST_BREATH"],
	"description": "**Guard**, **Ward**, **Lifesteal**, **Last Breath**",
}
const MERCY := {
	"id": "mercy_4", "name": "Mercy-4", "type": "CREATURE", "cost": 4,
	"attack": 3, "health": 4, "tags": ["ANIMA", "CONSTRUCT"],
	"keywords": ["LAST_BREATH"], "description": "**Last Breath:** Restore 2 Health to your Hero.",
}

## A board slot, as the match view draws one.
const SLOT := Vector2(104, 138)

var failures: Array[String] = []

func _init() -> void:
	await process_frame
	print("== creature token test ==")
	var library := CardLibrary.new()
	library.ingest([WOLF, NO_ART, WARDEN, MERCY])

	var row := HBoxContainer.new()
	row.position = Vector2(16, 16)
	row.add_theme_constant_override("separation", 12)
	get_root().add_child(row)

	var hurt := CreatureToken.make(library, {
		"definition_id": "wolf", "attack": 3, "health": 1, "max_health": 3, "marks": "sick",
	}, SLOT)
	row.add_child(hurt)
	var fresh := CreatureToken.make(library, {"definition_id": "nameless_recruit"}, SLOT)
	row.add_child(fresh)
	var guard := CreatureToken.make(library, {
		"definition_id": "wordy_warden", "statuses": [{"id": "ward", "kind": "WARD"}],
	}, SLOT)
	guard.ring_color = Color(0.45, 0.85, 0.55)
	row.add_child(guard)
	var spent := CreatureToken.make(library, {"definition_id": "wordy_warden", "statuses": []}, SLOT)
	row.add_child(spent)
	var granted := CreatureToken.make(library, {
		"definition_id": "wolf", "statuses": [{"kind": "ROOTED"}, {"kind": "WARD"}], "marks": "sick",
	}, SLOT)
	row.add_child(granted)
	var mercy := CreatureToken.make(library, {"definition_id": "mercy_4", "marks": "sick"}, SLOT)
	row.add_child(mercy)
	await process_frame
	await process_frame

	_check("a token fills its slot", hurt.size == SLOT)
	var oval := hurt._art.get_rect()
	_check("the oval takes most of the token",
		oval.size.x >= SLOT.x * 0.85 and oval.size.y >= SLOT.y * 0.8)
	var frame_oval := CardFrame.ART_OVAL.size * Vector2(96.0, roundf(96.0 / CardFrame.ASPECT))
	_check("the oval is bigger than a card's art window",
		oval.size.x > frame_oval.x * 1.3 and oval.size.y > frame_oval.y * 1.5)
	_check("a creature with art shows it", hurt._art.texture != null)
	_check("a creature without art still shows an oval", fresh._art.texture == null)
	_check("live stats are shown", hurt._attack_value.text == "3" and hurt._health_value.text == "1")
	_check("a buffed Attack is coloured as a buff",
		hurt._attack_value.get_theme_color("font_color") == CardFrame.COLOR_BUFF)
	_check("a damaged creature's Health is coloured as hurt",
		hurt._health_value.get_theme_color("font_color") == CardFrame.COLOR_HURT)
	_check("printed stats are shown where there are no live ones",
		fresh._attack_value.text == "1" and fresh._health_value.text == "1")
	_check("printed stats are not coloured",
		fresh._attack_value.get_theme_color("font_color") == Color.WHITE)
	_check("the badges load", hurt._attack.texture != null and hurt._health.texture != null)
	_check("the token shows no name, cost or rules",
		not _has_text(hurt, "Wolf") and not _has_text(hurt, "2"))
	_check("keywords stay on the token", guard._keywords.visible and guard._keywords.text.contains("Guard"))
	_check("a long keyword list stays inside the oval",
		guard._keywords.size.x <= guard._art.size.x)
	_check("no keywords, no chip", not fresh._keywords.visible)
	_check("why a creature cannot act is shown", hurt._marks.visible and hurt._marks.text == "sick")
	_check("a creature that cannot act is dimmed", hurt._art.modulate != Color.WHITE)
	_check("a ready creature is not", fresh._art.modulate == Color.WHITE)
	_check("the token takes no pointer input", _ignores_mouse(hurt))
	_check("active ward covers the oval", guard._ward.visible and guard._ward.get_rect() == guard._art.get_rect())
	_check("Guard frames the portrait", guard._guard.visible and guard._guard.get_rect() == guard._art.get_rect())
	_check("Guard and Ward show together", guard._guard.visible and guard._ward.visible)
	_check("Guard keeps the readiness and target highlight", guard._guard.ring_color == guard.ring_color)
	_check("ordinary creatures have no Guard shield", not hurt._guard.visible and not fresh._guard.visible)
	_check("spent printed ward has no shield", not spent._ward.visible)
	_check("Guard remains after Ward is spent", spent._guard.visible)
	_check("no live status means no shield", not fresh._ward.visible)
	_check("granted ward also shields a resting creature", granted._ward.visible and granted._ward.modulate == Color.WHITE)
	_check("the shield leaves selection and input available", guard.ring_color.a > 0.0 and _ignores_mouse(guard))
	guard.show_card(library, {"definition_id": "wordy_warden", "statuses": [{"kind": "ROOTED"}]})
	_check("consuming ward removes the shield on refresh", not guard._ward.visible)
	guard.show_card(library, {"definition_id": "wordy_warden", "statuses": [{"kind": "WARD"}]})
	_check("regaining ward restores the shield", guard._ward.visible)
	spent.show_card(library, {"definition_id": "wolf"})
	_check("refreshing to a non-Guard clears its frame", not spent._guard.visible)
	spent.show_card(library, {"definition_id": "wordy_warden", "marks": "sick"})
	_check("resting Guards keep their steel shield", spent._guard.visible and spent._guard.modulate == Color.WHITE)
	guard.guard_entrance(-1.0)
	_check("the shield waits while the creature falls", guard._guard.modulate.a == 0.0 and not guard._guard.is_processing())
	guard.guard_entrance(0.0)
	_check("landing leaves a short beat before the shield", guard._guard.modulate.a == 0.0)
	guard._guard._process(CreatureToken.GUARD_DELAY + CreatureToken.GUARD_EXPAND)
	_check("the shield pops beyond its resting size", guard._guard.scale.x > 1.1 and guard._guard.modulate.a == 1.0)
	guard._guard._process(CreatureToken.GUARD_SETTLE + 0.01)
	_check("the shield settles and stops animating", guard._guard.scale == Vector2.ONE and not guard._guard.is_processing())

	var shots := _arg("--screenshot-dir=")
	if shots != "" and DisplayServer.get_name() != "headless":
		# Side-by-side moments of the shield appearing after contact.
		var moments := [0.0, 0.07, 0.12, 0.20, 0.27, 0.35]
		for index in moments.size():
			var shot := CreatureToken.make(library, {"definition_id": "wordy_warden"}, SLOT)
			shot.position = Vector2(16 + index * 126, 220)
			shot.size = SLOT
			get_root().add_child(shot)
			shot.guard_entrance(moments[index])
			shot._guard.set_process(false)
			var label := Label.new()
			label.text = "%.2fs" % moments[index]
			label.position = shot.position + Vector2(30, -30)
			get_root().add_child(label)
		await RenderingServer.frame_post_draw
		var path := shots.path_join("creature_tokens.png")
		get_root().get_texture().get_image().save_png(path)
		print("  saved ", path)

	print("%d failure(s)" % failures.size())
	for failure in failures:
		print("  FAIL: ", failure)
	print("RESULT: ", "PASS" if failures.is_empty() else "FAIL")
	quit(0 if failures.is_empty() else 1)

## Whether any label in `node` reads exactly `text`.
func _has_text(node: Node, text: String) -> bool:
	for child in node.get_children():
		if child is Label and (child as Label).visible and (child as Label).text == text \
				and child != (node as CreatureToken)._attack_value \
				and child != (node as CreatureToken)._health_value:
			return true
	return false

func _ignores_mouse(node: Node) -> bool:
	if node is Control and (node as Control).mouse_filter != Control.MOUSE_FILTER_IGNORE:
		return false
	for child in node.get_children():
		if not _ignores_mouse(child):
			return false
	return true

func _arg(prefix: String) -> String:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with(prefix):
			return argument.substr(prefix.length())
	return ""

func _check(label: String, condition: bool) -> void:
	print("  [%s] %s" % ["ok" if condition else "XX", label])
	if not condition:
		failures.append(label)
