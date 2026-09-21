extends SceneTree

## Verifies that a signed-in session survives a restart.
##
## Runs two scenes in sequence within one process: the first signs in, the
## second is built fresh and must come back already signed in, as a relaunch
## would. Requires a running server.
##
##   godot --headless --path apps/godot-client --script src/session_test.gd

var failures: Array[String] = []

func _init() -> void:
	await process_frame
	print("== session persistence test ==")

	# Start from a known state: no saved session.
	SessionStore.clear()
	_check("no session saved initially", not SessionStore.has_saved())

	# --- Expiry is handled before any request is made. ---
	var now := int(Time.get_unix_time_from_system())
	SessionStore.save("stale", "Old", "http://127.0.0.1:3000",
		Time.get_datetime_string_from_unix_time(now - 3600) + "Z")
	_check("an expired session is not offered", SessionStore.load_saved() == null)
	_check("an expired session is deleted", not SessionStore.has_saved())

	SessionStore.save("almost", "Soon", "http://127.0.0.1:3000",
		Time.get_datetime_string_from_unix_time(now + 30) + "Z")
	_check("a session inside the expiry margin is not offered",
		SessionStore.load_saved() == null)

	SessionStore.save("fresh", "Fresh", "http://127.0.0.1:3000",
		Time.get_datetime_string_from_unix_time(now + 86400) + "Z")
	var fresh := SessionStore.load_saved()
	_check("a session with time left is offered", fresh != null and fresh.token == "fresh")
	SessionStore.clear()

	# --- First run: sign in. ---
	var first: Control = (load("res://main.tscn") as PackedScene).instantiate()
	get_root().add_child(first)
	await process_frame
	await process_frame

	var screen: CollectionScreen = first.collection_screen
	_check("sign-in form shown when nothing is saved", screen._auth_form.visible)

	var tag := "sess%d" % (Time.get_ticks_msec() % 100000)
	screen._email_input.text = "%s@example.test" % tag
	screen._name_input.text = tag
	screen._password_input.text = "a-sufficiently-long-password"
	screen._do_register()
	for i in range(300):
		await process_frame
		if first.accounts.is_signed_in():
			break
	_check("registered and signed in", first.accounts.is_signed_in())
	if not first.accounts.is_signed_in():
		print("  status: ", screen._auth_status.text)
		_finish()
		return
	var display_name := str(first.accounts.user.get("displayName", ""))
	var user_id := str(first.accounts.user.get("id", ""))

	# The token must have reached disk.
	_check("session written to disk", SessionStore.has_saved())
	var saved := SessionStore.load_saved()
	_check("saved token matches the live one", saved != null and saved.token == first.accounts.token)
	_check("saved session records the server", saved != null and saved.server != "")
	_check("saved session records an expiry", saved != null and saved.expires_at_unix > 0)

	# --- Second run: a fresh scene, as a relaunch would build. ---
	first.queue_free()
	await process_frame
	await process_frame

	var second: Control = (load("res://main.tscn") as PackedScene).instantiate()
	get_root().add_child(second)
	await process_frame
	await process_frame
	for i in range(300):
		await process_frame
		if second.accounts.is_signed_in():
			break

	_check("restored without signing in again", second.accounts.is_signed_in())
	_check("restored the same account",
		str(second.accounts.user.get("id", "")) == user_id)
	_check("restored display name matches",
		str(second.accounts.user.get("displayName", "")) == display_name)
	var second_screen: CollectionScreen = second.collection_screen
	_check("collection shown rather than the sign-in form", second_screen._main_box.visible)
	_check("sign-in form hidden after a restore", not second_screen._auth_form.visible)

	# --- Signing out must not leave a session behind. ---
	second.accounts.sign_out()
	for i in range(120):
		await process_frame
	_check("sign-out clears the saved session", not SessionStore.has_saved())
	_check("sign-out clears the live token", not second.accounts.is_signed_in())

	# --- A rejected token must not strand the player. ---
	SessionStore.save("not-a-real-token", "Ghost", "http://127.0.0.1:3000", "")
	var third: Control = (load("res://main.tscn") as PackedScene).instantiate()
	get_root().add_child(third)
	for i in range(300):
		await process_frame
		if third.collection_screen._auth_form.visible and not third.accounts.is_signed_in():
			break
	_check("a rejected token falls back to the sign-in form",
		third.collection_screen._auth_form.visible)
	_check("a rejected token is discarded", not SessionStore.has_saved())
	print("  message shown: ", third.collection_screen._auth_status.text)

	SessionStore.clear()
	_finish()

func _finish() -> void:
	print("\n%d failure(s)" % failures.size())
	for f in failures:
		print("  FAIL: ", f)
	print("RESULT: ", "PASS" if failures.is_empty() else "FAIL")
	quit(0 if failures.is_empty() else 1)

func _check(label: String, condition: bool) -> void:
	print("  [%s] %s" % ["ok" if condition else "XX", label])
	if not condition:
		failures.append(label)
