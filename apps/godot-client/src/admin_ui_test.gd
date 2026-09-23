extends SceneTree

## Drives the admin UI against a live server: the toggle, the admin panel, a
## debug match, and editing that match from the match view.
##
## Needs an admin account. By default it signs in as the seeded admin; pass
## another with `--admin-email=` and `--admin-password=`:
##   godot --path apps/godot-client --script src/admin_ui_test.gd
##   godot --path apps/godot-client --script src/admin_ui_test.gd -- --admin-email=a@b.test --admin-password=...
##
## It changes the admin's own Fragment balance to check the panel, and puts it
## back afterwards.

var main: Control
var failures: Array[String] = []

func _init() -> void:
	await process_frame
	SessionStore.clear()
	var email := _arg("admin-email", "alice@maailma.dev")
	var password := _arg("admin-password", "maailma-dev-password")
	print("== admin UI test (%s) ==" % email)
	main = (load("res://main.tscn") as PackedScene).instantiate()
	get_root().add_child(main)
	await process_frame
	await process_frame

	main.accounts.login(email, password)
	for i in range(240):
		await process_frame
		if main.accounts.is_signed_in():
			break
	_check("signed in as an admin", main.accounts.is_admin())
	if not main.accounts.is_admin():
		_finish()
		return
	var me := str(main.accounts.user.get("id", ""))

	# --- The toggle switches between the admin UI and the player's UI. ---
	_set_admin_ui(true)
	_check("an admin is offered the toggle", main.admin_toggle.visible)
	_check("with the admin UI on, the collection offers the panel",
		main.collection_screen._admin_button.visible)
	_set_admin_ui(false)
	_check("with it off, the panel is not offered", not main.collection_screen._admin_button.visible)
	main._show_admin_view()
	_check("and cannot be opened", not main.admin_screen.visible)
	_set_admin_ui(true)

	# --- The panel reads and changes an account. ---
	main._show_admin_view()
	_check("the panel opens", main.admin_screen.visible)
	var screen: Control = main.admin_screen
	await _until(func() -> bool: return not screen._registry.is_empty())
	_check("the registry loaded", not screen._registry.is_empty())
	screen._select_user(me)
	await _until(func() -> bool: return not screen._overview.is_empty())
	_check("the admin's own account is shown", screen._overview_label.text.contains(me))
	await _screenshot("admin_panel")
	var original := int((screen._overview.get("user", {}) as Dictionary).get("fragments", 0))
	screen._fragments_input.value = 4321
	screen._user_call(HTTPClient.METHOD_PUT, "/fragments", {"balance": 4321}, "Balance set.")
	await _until(func() -> bool:
		return int((screen._overview.get("user", {}) as Dictionary).get("fragments", 0)) == 4321)
	_check("setting Fragments shows the new balance",
		int((screen._overview.get("user", {}) as Dictionary).get("fragments", 0)) == 4321)
	screen._user_call(HTTPClient.METHOD_PUT, "/fragments", {"balance": original}, "Balance set.")

	# --- A debug match for the admin opens in the match view. ---
	_pick(screen._scenario_picker, "BANDIT_AMBUSH")
	_pick(screen._debug_hero_picker, "healer")
	screen._start_debug_match()
	await _until(func() -> bool:
		return main.game_root.visible and not main.state.is_empty())
	_check("the debug match opens in the match view", main.game_root.visible and not main.state.is_empty())
	await _until(func() -> bool: return main.admin_bar.visible)
	_check("the match view shows the admin bar", main.admin_bar.visible)

	# --- Editing the match from the match view. ---
	var tools: Node = main.admin_match_tools
	await _until(func() -> bool: return tools._card_picker.item_count > 0)
	var hand_before := _hand_size(me)
	_pick(tools._card_picker, "darek_voln")
	tools._player_picker.select(tools._player_ids.find(me))
	tools._add_card()
	await _until(func() -> bool: return _hand_size(me) == hand_before + 1)
	_check("a card added from the bar reaches the hand", _hand_size(me) == hand_before + 1)
	var hand: Array = (main.state.get("sides", {}) as Dictionary).get(me, {}).get("hand", [])
	_check("it is the card chosen",
		not hand.is_empty() and str((hand[-1] as Dictionary).get("definitionId", "")) == "darek_voln")

	var hero := "%s:hero" % me
	tools._entity_picker.select(tools._entity_ids.find(hero))
	tools._health_input.text = "57"
	tools._set_stats()
	await _until(func() -> bool: return _hero_health(me) == 57)
	_check("a Hero's Health set from the bar is shown on the board", _hero_health(me) == 57)
	await _screenshot("admin_match_bar")
	_check("the log says an admin did it", "\n".join(main.log_lines).contains("[Admin]"))

	# --- Off again: the player's UI, nothing more. ---
	_set_admin_ui(false)
	_check("with the admin UI off, the match view has no admin bar", not main.admin_bar.visible)
	_set_admin_ui(true)
	_finish()

## With `--screenshot-dir=`, saves what the window shows, for a look by eye.
func _screenshot(name: String) -> void:
	var directory := _arg("screenshot-dir", "")
	if directory == "":
		return
	for i in range(10):
		await process_frame
	get_root().get_texture().get_image().save_png("%s/%s.png" % [directory, name])

func _set_admin_ui(enabled: bool) -> void:
	main.admin_toggle.button_pressed = enabled
	main._on_admin_toggled(enabled)

func _hand_size(player: String) -> int:
	var side: Dictionary = (main.state.get("sides", {}) as Dictionary).get(player, {})
	return (side.get("hand", []) as Array).size()

func _hero_health(player: String) -> int:
	var side: Dictionary = (main.state.get("sides", {}) as Dictionary).get(player, {})
	return int((side.get("hero", {}) as Dictionary).get("currentHealth", -1))

func _pick(picker: OptionButton, id: String) -> void:
	for index in range(picker.item_count):
		if str(picker.get_item_metadata(index)) == id:
			picker.select(index)
			return
	print("  [--] %s not in picker" % id)

func _until(condition: Callable, frames: int = 400) -> void:
	for i in range(frames):
		if condition.call():
			return
		await process_frame

func _arg(key: String, fallback: String) -> String:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--%s=" % key):
			return argument.substr(key.length() + 3)
	return fallback

func _check(label: String, condition: bool) -> void:
	print("  [%s] %s" % ["ok" if condition else "XX", label])
	if not condition:
		failures.append(label)

func _finish() -> void:
	print("\n%d failure(s)" % failures.size())
	for f in failures:
		print("  FAIL: ", f)
	print("RESULT: ", "PASS" if failures.is_empty() else "FAIL")
	quit(0 if failures.is_empty() else 1)
