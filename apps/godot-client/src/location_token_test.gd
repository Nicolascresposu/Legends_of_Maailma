extends SceneTree

## Checks a Location in play drawn as its art arch, and how the client offers
## and narrates Locations, without a server.
##
##   godot --headless --path apps/godot-client --script src/location_token_test.gd
## Run it windowed with `-- --screenshot-dir=<dir>` to save what it drew.

const CAMP := {
	"id": "war_camp", "name": "War Camp", "type": "LOCATION", "cost": 3,
	"durability": 2, "duration": 3, "tags": [], "effects": [],
	"description": "Give adjacent friendly Creatures +1/+1.",
}
const SPRING := {
	"id": "healing_spring", "name": "Healing Spring", "type": "LOCATION", "cost": 3,
	"duration": 3, "tags": [], "effects": [],
	"description": "At the start of your turn, restore 2 Health to your Hero.",
}
const TOWER := {
	"id": "border_watchtower", "name": "Border Watchtower", "type": "LOCATION", "cost": 2,
	"durability": 3, "tags": [], "effects": [],
	"description": "Deal 1 damage to an enemy character.",
}

## A board slot, as the match view draws one.
const SLOT := Vector2(104, 138)

var failures: Array[String] = []

func _init() -> void:
	await process_frame
	print("== location token test ==")
	var library := CardLibrary.new()
	library.ingest([CAMP, SPRING, TOWER])

	var row := HBoxContainer.new()
	row.position = Vector2(16, 16)
	row.add_theme_constant_override("separation", 12)
	get_root().add_child(row)

	var fresh := LocationToken.make(library, {"definition_id": "war_camp"}, SLOT)
	fresh.ring_color = Color(0.45, 0.85, 0.55)
	row.add_child(fresh)
	var worn := LocationToken.make(library, {
		"definition_id": "war_camp", "durability": 1, "duration": 1, "closed": true, "marks": "closed",
	}, SLOT)
	row.add_child(worn)
	var spring := LocationToken.make(library, {"definition_id": "healing_spring", "duration": 2}, SLOT)
	row.add_child(spring)
	var tower := LocationToken.make(library, {"definition_id": "border_watchtower", "durability": 0}, SLOT)
	row.add_child(tower)
	await process_frame
	await process_frame

	_check("the token is the slot's size", fresh.size == SLOT)
	_check("the art is cut to the Location frame's arch",
		fresh._art.outline == CardFrame.LOCATION_ART_OUTLINE)
	_check("a Location with both measures shows the hourglass and the shield",
		fresh._hourglass.visible and fresh._durability.visible
		and fresh._duration_value.text == "3" and fresh._durability_value.text == "2")
	_check("the hourglass is on the left and the shield on the right",
		fresh._hourglass.get_rect().get_center().x < SLOT.x * 0.5
		and fresh._durability.get_rect().get_center().x > SLOT.x * 0.5)
	_check("both badges sit at the arch's foot",
		fresh._hourglass.get_rect().get_center().y > SLOT.y * 0.7
		and fresh._durability.get_rect().get_center().y > SLOT.y * 0.7)
	_check("printed measures are not coloured",
		fresh._duration_value.get_theme_color("font_color") == Color.WHITE
		and fresh._durability_value.get_theme_color("font_color") == Color.WHITE)
	_check("an open Location is drawn in full colour", not fresh.closed and fresh._art.modulate == Color.WHITE)
	_check("an open Location carries no marker", not fresh._marks.visible)

	_check("live measures are shown", worn._duration_value.text == "1" and worn._durability_value.text == "1")
	_check("worn-down measures are coloured as hurt",
		worn._duration_value.get_theme_color("font_color") == CardFrame.COLOR_HURT
		and worn._durability_value.get_theme_color("font_color") == CardFrame.COLOR_HURT)
	_check("a closed Location is drawn dark",
		worn.closed and worn._art.modulate == LocationToken.COLOR_CLOSED)
	_check("a closed Location says so", worn._marks.visible and worn._marks.text == "closed")

	_check("a Location with only a duration shows only the hourglass",
		spring._hourglass.visible and spring._duration_value.visible
		and not spring._durability.visible and not spring._durability_value.visible)
	_check("a Location with only Durability shows only the shield",
		tower._durability.visible and not tower._hourglass.visible and not tower._duration_value.visible)
	_check("a Location with no Durability left shows the cracked shield",
		tower._durability.texture == CardFrame._texture(CardFrame.DURABILITY_ZERO_PATH))
	_check("the token takes no pointer input", _ignores_mouse(fresh))
	_check("the arch outline follows the token's arch",
		fresh.arch_points().size() == CardFrame.LOCATION_ART_OUTLINE.size())

	# What the server offers is what a Location on the board can do.
	var legal := [
		{"type": "ACTIVATE_LOCATION", "actorId": "a", "locationId": "location_7", "targetId": "b:hero"},
		{"type": "ACTIVATE_LOCATION", "actorId": "a", "locationId": "location_8"},
		{"type": "END_TURN", "actorId": "a"},
	]
	var aimed := Targeting.actions_for_entity(legal, "location_7")
	_check("a Location's activations belong to it", aimed.size() == 1)
	_check("an aimed activation lights its target",
		Targeting.entity_targets(aimed).has("b:hero"))
	_check("an untargeted activation is used with a click",
		Targeting.untargeted_action(Targeting.actions_for_entity(legal, "location_8")) != null)

	var state := {
		"sides": {
			"a": {
				"hero": {"definitionId": "healer"},
				"creatures": {},
				"locations": {
					"location_7": {
						"instanceId": "location_7", "definitionId": "border_watchtower",
						"position": {"row": "FRONT", "column": 1},
					},
				},
			},
			"b": {"hero": {"definitionId": "striker"}, "creatures": {}, "locations": {}},
		},
	}
	_check("an activation is listed under its own group",
		ActionFormatter.group_of(legal[0]) == "Use a Location"
		and ActionFormatter.GROUP_ORDER.has("Use a Location"))
	_check("an activation names the Location and its target",
		ActionFormatter.label_for(legal[0], state, "a", library) == "Border Watchtower at Front 1 → The Striker (b)")
	for event in [
		{"type": "LOCATION_PLACED", "cardDefinitionId": "war_camp", "position": {"row": "BACK", "column": 0}},
		{"type": "LOCATION_ACTIVATED", "cardDefinitionId": "border_watchtower", "targetId": "b:hero"},
		{"type": "LOCATION_DURABILITY_CHANGED", "cardDefinitionId": "border_watchtower", "amount": -1},
		{"type": "LOCATION_DURATION_CHANGED", "cardDefinitionId": "healing_spring", "amount": -1},
		{"type": "LOCATION_REMOVED", "cardDefinitionId": "healing_spring", "reason": "EXPIRED"},
	]:
		var line := ActionFormatter.event_line(event, state, library)
		_check("the log narrates %s" % event["type"],
			line != "" and not line.contains("_") and line != str(event["type"]).capitalize())
	_check("the log says why a Location left",
		ActionFormatter.event_line({"type": "LOCATION_REMOVED", "cardDefinitionId": "border_watchtower", "reason": "SPENT"}, state, library)
		== "Border Watchtower crumbles.")

	_check("a Location explains its measures, hourglass first",
		library.location_lines("war_camp").size() == 2
		and library.location_lines("war_camp")[0].begins_with("Duration")
		and library.location_lines("war_camp")[1].begins_with("Durability"))
	_check("a Location explains only the measures it has",
		library.location_lines("healing_spring").size() == 1
		and library.location_lines("border_watchtower").size() == 1)
	_check("the tooltip gives a Location's measures",
		library.tooltip("war_camp").contains("Location — 3 turns · 2 Durability"))

	var shots := _arg("--screenshot-dir=")
	if shots != "" and DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		var path := shots.path_join("location_tokens.png")
		get_root().get_texture().get_image().save_png(path)
		print("  saved ", path)

	print("%d failure(s)" % failures.size())
	for failure in failures:
		print("  FAIL: ", failure)
	print("RESULT: ", "PASS" if failures.is_empty() else "FAIL")
	quit(0 if failures.is_empty() else 1)

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
