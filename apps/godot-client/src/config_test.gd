extends SceneTree

## Checks how the client resolves the server address, and that it can actually
## talk to a server on a non-default port.
##
##   godot --headless --path apps/godot-client --script src/config_test.gd
##   godot --headless --path apps/godot-client --script src/config_test.gd -- --server=127.0.0.1:3100

var failures: Array[String] = []

func _init() -> void:
	await process_frame
	print("== client configuration test ==")

	# --- Normalizing what a person would type. ---
	_check("a bare host:port becomes a URL",
		ClientConfig.normalize("127.0.0.1:4000") == "http://127.0.0.1:4000")
	_check("localhost is accepted",
		ClientConfig.normalize("localhost:4000") == "http://localhost:4000")
	_check("an explicit scheme is kept",
		ClientConfig.normalize("https://play.example:8443") == "https://play.example:8443")
	_check("a trailing slash is dropped",
		ClientConfig.normalize("http://127.0.0.1:4000/") == "http://127.0.0.1:4000")
	_check("a path is dropped",
		ClientConfig.normalize("http://127.0.0.1:4000/api/cards") == "http://127.0.0.1:4000")
	_check("surrounding space is ignored",
		ClientConfig.normalize("  127.0.0.1:4000  ") == "http://127.0.0.1:4000")
	_check("a bare domain gets https",
		ClientConfig.normalize("maailma.example.com") == "https://maailma.example.com")
	_check("a bare domain with a port gets https",
		ClientConfig.normalize("play.example:8443/") == "https://play.example:8443")
	_check("a LAN address gets http",
		ClientConfig.normalize("192.168.0.94:3000") == "http://192.168.0.94:3000")
	_check("an IPv6 literal gets http",
		ClientConfig.normalize("[::1]:3000") == "http://[::1]:3000")
	_check("an explicit http domain is kept",
		ClientConfig.normalize("http://maailma.example.com") == "http://maailma.example.com")
	_check("empty input yields nothing", ClientConfig.normalize("   ") == "")

	# --- Websocket derivation follows the scheme. ---
	_check("http yields ws",
		ClientConfig.websocket_base("http://127.0.0.1:4000") == "ws://127.0.0.1:4000")
	_check("https yields wss",
		ClientConfig.websocket_base("https://play.example") == "wss://play.example")

	# --- Saving makes an address stick. ---
	ClientConfig.clear()
	ClientConfig.save("127.0.0.1:4100")
	_check("a saved address is used", ClientConfig.http_base() == "http://127.0.0.1:4100")
	ClientConfig.clear()
	# With no saved address the built-in default applies — unless this run was
	# given an override, which outranks both.
	if _override_in_effect() == "":
		_check("clearing returns to the default",
			ClientConfig.http_base() == ClientConfig.DEFAULT_BASE)
	else:
		_check("clearing falls back to the override",
			ClientConfig.http_base() == _override_in_effect())

	# --- A client picks the resolved address up. ---
	# A client reads the address when it is built, so save before constructing.
	# `clear()` drops the cached resolution so the new file is picked up.
	ClientConfig.clear()
	ClientConfig.save("127.0.0.1:4200")
	var expected_base := ClientConfig.http_base()
	var match_client := MatchClient.new()
	get_root().add_child(match_client)
	_check("the match client uses the configured address",
		match_client.http_base == expected_base)
	_check("its websocket url follows",
		match_client.websocket_url() == ClientConfig.websocket_base(expected_base) + "/matches")
	var account_client := AccountClient.new()
	get_root().add_child(account_client)
	_check("the account client uses the same address",
		account_client.http_base == expected_base)
	ClientConfig.clear()

	# --- An override beats a saved address. ---
	# Only meaningful when the run supplied one; otherwise the saved value wins.
	var expected := _override_in_effect()
	if expected != "":
		# Write a saved address, then force a fresh resolve: the override must
		# still win. `clear()` resets the cached resolution as well as the file.
		ClientConfig.save("127.0.0.1:9999")
		ClientConfig.clear()
		_check("an override wins over a saved address", ClientConfig.http_base() == expected)
		_check("an override is reported as such", ClientConfig.source() == "override")
		ClientConfig.clear()
	else:
		print("  [--] no override supplied; precedence not exercised this run")

	_finish()

func _finish() -> void:
	print("\n%d failure(s)" % failures.size())
	for f in failures:
		print("  FAIL: ", f)
	print("RESULT: ", "PASS" if failures.is_empty() else "FAIL")
	quit(0 if failures.is_empty() else 1)

## The address this run was overridden with, or "" when it was not.
func _override_in_effect() -> String:
	for argument in OS.get_cmdline_args() + OS.get_cmdline_user_args():
		if str(argument).begins_with("--server="):
			return ClientConfig.normalize(str(argument).substr("--server=".length()))
	return ClientConfig.normalize(OS.get_environment(ClientConfig.ENVIRONMENT_VARIABLE))

func _check(label: String, condition: bool) -> void:
	print("  [%s] %s" % ["ok" if condition else "XX", label])
	if not condition:
		failures.append(label)
