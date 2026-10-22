extends SceneTree

## Verifies remembered accounts: a session survives a restart, a remembered
## account signs in again without its password, and signing out, switching,
## forgetting and turning off automatic sign-in each do what they say.
##
## Runs several scenes in sequence within one process, each built fresh as a
## relaunch would build it. Requires a running server.
##
##   godot --headless --path apps/godot-client --script src/session_test.gd

const PASSWORD := "a-sufficiently-long-password"

var failures: Array[String] = []

func _init() -> void:
	await process_frame
	print("== remembered accounts test ==")

	# Start from a known state: nothing remembered.
	SessionStore.clear()
	_check("nothing remembered initially", SessionStore.accounts().is_empty())
	_check("automatic sign-in is on by default", SessionStore.auto_sign_in())

	# --- The store, before any request is made. ---
	var now := int(Time.get_unix_time_from_system())
	var server := "http://127.0.0.1:3000"
	SessionStore.remember({"id": "old", "email": "old@example.test", "displayName": "Old"},
		"stale", server, _iso(now - 3600))
	_check("an expired session is not resumed", SessionStore.resumable() == null)
	var old := SessionStore.find(SessionStore.key_for(server, "old"))
	_check("an expired session's account is kept", old != null and old.email == "old@example.test")
	_check("an expired session's token is dropped", old != null and old.token == "")

	SessionStore.remember({"id": "soon", "email": "soon@example.test", "displayName": "Soon"},
		"almost", server, _iso(now + 30))
	_check("a session inside the expiry margin is not resumed", SessionStore.resumable() == null)

	SessionStore.remember({"id": "fresh", "email": "fresh@example.test", "displayName": "Fresh"},
		"fresh", server, _iso(now + 86400))
	var fresh := SessionStore.resumable()
	_check("a session with time left is resumed", fresh != null and fresh.token == "fresh")
	_check("the most recent account is listed first",
		SessionStore.accounts()[0].id == "fresh")
	SessionStore.remember({"id": "fresh", "email": "fresh@example.test", "displayName": "Renamed"},
		"fresh", server, "")
	fresh = SessionStore.resumable()
	_check("a refresh keeps the known expiry", fresh != null and fresh.expires_at_unix > now)
	_check("a refresh updates the name", fresh != null and fresh.display_name == "Renamed")
	_check("the same id is one account", SessionStore.accounts().size() == 3)
	SessionStore.end_session(fresh.key)
	_check("an ended session is not resumed", SessionStore.resumable() == null)
	SessionStore.forget(fresh.key)
	_check("a forgotten account is gone", SessionStore.find(fresh.key) == null)
	SessionStore.clear()

	# --- First run: register. ---
	var first := await _launch()
	var screen: CollectionScreen = first.collection_screen
	_check("sign-in form shown when nothing is remembered", screen._auth_form.visible)
	_check("no saved accounts shown when there are none", not screen._saved_box.visible)

	var tag := "sess%d" % (Time.get_ticks_msec() % 100000)
	var email := "%s@example.test" % tag
	screen._email_input.text = email
	screen._name_input.text = tag
	screen._password_input.text = PASSWORD
	screen._do_register()
	if not await _until(func() -> bool: return first.accounts.is_signed_in()):
		_check("registered and signed in", false)
		print("  status: ", screen._auth_status.text)
		_finish()
		return
	var user_id := str(first.accounts.user.get("id", ""))

	var saved := SessionStore.resumable()
	_check("the account is remembered", saved != null and saved.id == user_id)
	_check("its token matches the live one", saved != null and saved.token == first.accounts.token)
	_check("it records the server", saved != null and saved.server != "")
	_check("it records the email", saved != null and saved.email == email)
	_check("it records an expiry", saved != null and saved.expires_at_unix > 0)

	# --- Second run: signs straight back in. ---
	first.queue_free()
	var second := await _launch()
	await _until(func() -> bool: return second.accounts.is_signed_in())
	_check("restored without signing in again", second.accounts.is_signed_in())
	_check("restored the same account", str(second.accounts.user.get("id", "")) == user_id)
	var second_screen: CollectionScreen = second.collection_screen
	_check("collection shown rather than the sign-in form", second_screen._main_box.visible)
	_check("sign-in form hidden after a restore", not second_screen._auth_form.visible)

	# --- Switching keeps the session, so picking the account needs no password. ---
	second.accounts.switch_account()
	_check("switching shows the sign-in form", second_screen._auth_form.visible)
	_check("switching is not signed in", not second.accounts.is_signed_in())
	_check("switching keeps the session", SessionStore.resumable() != null)
	_check("the account is offered", second_screen._saved_box.visible)
	second_screen._quick_sign_in(SessionStore.resumable())
	await _until(func() -> bool: return second.accounts.is_signed_in())
	_check("picking the account signs in without a password", second.accounts.is_signed_in())

	# --- Signing out ends the session but keeps the account. ---
	second.accounts.sign_out()
	await _frames(120)
	_check("sign-out clears the live token", not second.accounts.is_signed_in())
	_check("sign-out leaves no session to resume", SessionStore.resumable() == null)
	var kept := SessionStore.find(SessionStore.key_for(second.accounts.http_base, user_id))
	_check("sign-out keeps the account", kept != null and kept.token == "")
	second_screen._quick_sign_in(kept)
	_check("picking it then asks for the password", not second.accounts.is_restoring())
	_check("with the email filled in", second_screen._email_input.text == email)
	second_screen._password_input.text = PASSWORD
	second_screen._do_login()
	await _until(func() -> bool: return second.accounts.is_signed_in())
	_check("the password signs in again", second.accounts.is_signed_in())

	# --- Automatic sign-in turned off: a launch waits to be told who. ---
	second_screen._auto_sign_in.button_pressed = false
	_check("turning it off is remembered", not SessionStore.auto_sign_in())
	second.queue_free()
	var third := await _launch()
	await _frames(60)
	_check("without automatic sign-in, a launch stays signed out", not third.accounts.is_signed_in())
	_check("and shows the form", third.collection_screen._auth_form.visible)
	_check("and offers the account", third.collection_screen._saved_box.visible)
	_check("whose session still lives", SessionStore.resumable() != null)
	third.collection_screen._auto_sign_in.button_pressed = true

	# --- A rejected token must not strand the player. ---
	var live := SessionStore.resumable()
	SessionStore.remember(third.accounts.user if third.accounts.is_signed_in() else
		{"id": user_id, "email": email, "displayName": tag}, "not-a-real-token", live.server, "")
	third.queue_free()
	var fourth := await _launch()
	await _until(func() -> bool:
		return fourth.collection_screen._auth_form.visible and not fourth.accounts.is_restoring())
	_check("a rejected token falls back to the sign-in form", fourth.collection_screen._auth_form.visible)
	_check("a rejected token is discarded", SessionStore.resumable() == null)
	_check("the account is kept for its password", SessionStore.accounts().size() == 1)
	_check("its email is filled in", fourth.collection_screen._email_input.text == email)
	print("  message shown: ", fourth.collection_screen._auth_status.text)

	# --- Forgetting removes it. ---
	fourth.accounts.forget_account(SessionStore.accounts()[0])
	_check("a forgotten account is gone", SessionStore.accounts().is_empty())

	SessionStore.clear()
	_finish()

func _launch() -> Control:
	await process_frame
	var scene: Control = (load("res://main.tscn") as PackedScene).instantiate()
	get_root().add_child(scene)
	await process_frame
	await process_frame
	return scene

## Waits up to five seconds or so for `condition`, returning whether it held.
func _until(condition: Callable) -> bool:
	for i in range(300):
		if condition.call():
			return true
		await process_frame
	return condition.call()

func _frames(count: int) -> void:
	for i in range(count):
		await process_frame

func _iso(unix: int) -> String:
	return Time.get_datetime_string_from_unix_time(unix) + "Z"

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
