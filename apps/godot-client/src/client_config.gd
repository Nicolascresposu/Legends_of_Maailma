extends RefCounted
class_name ClientConfig

## Where the client should look for the server.
##
## Resolved once at startup from, in order of precedence:
##
##   1. `--server=<address>` on the command line
##   2. the `MAAILMA_SERVER` environment variable
##   3. `user://client.cfg`, written when the address is changed in the UI
##   4. `http://127.0.0.1:3000`
##
## A command line or environment value is treated as an override for that run
## and is not written to disk, so `--server=...` never changes the saved
## default. Changing the address in the UI does save it.

const PATH := "user://client.cfg"
const SECTION := "server"
const DEFAULT_BASE := "http://127.0.0.1:3000"
const ARGUMENT_PREFIX := "--server="
const ENVIRONMENT_VARIABLE := "MAAILMA_SERVER"

## Set once at startup so every consumer agrees on the address.
static var _resolved := ""
## True when the address came from an override rather than saved state.
static var _from_override := false

## The base URL to use, resolving it on first call.
static func http_base() -> String:
	if _resolved == "":
		_resolve()
	return _resolved

## Where the address came from, for a one-line note at startup.
static func source() -> String:
	if _resolved == "":
		_resolve()
	if _from_override:
		return "override"
	return "saved" if _saved_base() != "" else "default"

static func _resolve() -> void:
	var argument := _argument_base()
	if argument != "":
		_resolved = argument
		_from_override = true
		return
	var environment := normalize(OS.get_environment(ENVIRONMENT_VARIABLE))
	if environment != "":
		_resolved = environment
		_from_override = true
		return
	var saved := _saved_base()
	_resolved = saved if saved != "" else DEFAULT_BASE
	_from_override = false

## Stores an address chosen in the UI, so the next run uses it too.
static func save(base: String) -> void:
	var clean := normalize(base)
	if clean == "":
		return
	_resolved = clean
	# A saved address is the new default, so it is no longer an override.
	_from_override = false
	var config := ConfigFile.new()
	config.set_value(SECTION, "httpBase", clean)
	var error := config.save(PATH)
	if error != OK:
		push_warning("Could not save the server address: %d" % error)

static func clear() -> void:
	if FileAccess.file_exists(PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))
	_resolved = ""
	_from_override = false

## Accepts what a person would actually type and returns a usable base URL,
## or "" when there is nothing usable in it.
##
## `localhost:4000`, `127.0.0.1:4000` and `http://127.0.0.1:4000/` all resolve
## to the same address; a trailing slash or path is dropped.
static func normalize(raw: String) -> String:
	var value := raw.strip_edges()
	if value == "":
		return ""
	if not (value.begins_with("http://") or value.begins_with("https://")):
		value = "http://" + value
	# Trim any path, query or fragment: the base is scheme, host and port.
	var scheme_end := value.find("://") + 3
	var rest := value.substr(scheme_end)
	for separator in ["/", "?", "#"]:
		var at := rest.find(separator)
		if at != -1:
			rest = rest.substr(0, at)
	if rest == "":
		return ""
	return value.substr(0, scheme_end) + rest

## The websocket base for a given http base, so callers derive both the same way.
static func websocket_base(base: String) -> String:
	if base.begins_with("https://"):
		return "wss://" + base.substr(8)
	if base.begins_with("http://"):
		return "ws://" + base.substr(7)
	return "ws://" + base

static func _argument_base() -> String:
	# Both `--server=x` and `--server x`, before or after Godot's own `--`.
	var arguments := OS.get_cmdline_args() + OS.get_cmdline_user_args()
	for index in range(arguments.size()):
		var argument := str(arguments[index])
		if argument.begins_with(ARGUMENT_PREFIX):
			return normalize(argument.substr(ARGUMENT_PREFIX.length()))
		if argument == "--server" and index + 1 < arguments.size():
			return normalize(str(arguments[index + 1]))
	return ""

static func _saved_base() -> String:
	var config := ConfigFile.new()
	if config.load(PATH) != OK:
		return ""
	return normalize(str(config.get_value(SECTION, "httpBase", "")))
