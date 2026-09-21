extends RefCounted
class_name SessionStore

## Remembers a signed-in session between runs.
##
## The token is written to Godot's per-user data directory, which is the
## ordinary place for a desktop game's local state. It is stored in plain text:
## anything running as this user could read it, but the same is true of most
## game launchers, and encrypting it with a key shipped inside the client would
## be obfuscation rather than protection.
##
## The token is a bearer credential, so treat it as a password: the file is
## deleted on sign-out, and a token the server rejects is discarded rather than
## retried.

const PATH := "user://session.cfg"
const SECTION := "session"
## Sessions nearing expiry are treated as expired, so a restore does not
## succeed only to fail moments later mid-request.
const EXPIRY_MARGIN_SECONDS := 60

## What was loaded from disk, before the server has confirmed any of it.
class Saved extends RefCounted:
	var token := ""
	var display_name := ""
	var server := ""
	var expires_at_unix := 0

	func is_usable(now_unix: int) -> bool:
		if token == "":
			return false
		# An absent expiry is treated as usable: only the server truly knows,
		# and /me will reject it if it is stale.
		if expires_at_unix <= 0:
			return true
		return expires_at_unix - EXPIRY_MARGIN_SECONDS > now_unix

## Writes the session, replacing any previous one.
static func save(token: String, display_name: String, server: String, expires_at_iso: String) -> void:
	var config := ConfigFile.new()
	config.set_value(SECTION, "token", token)
	config.set_value(SECTION, "displayName", display_name)
	config.set_value(SECTION, "server", server)
	config.set_value(SECTION, "expiresAt", _to_unix(expires_at_iso))
	var error := config.save(PATH)
	if error != OK:
		# Failing to remember is not worth interrupting play over.
		push_warning("Could not save the session: %d" % error)

## Reads the saved session, or null when there is none worth trying.
static func load_saved() -> Saved:
	var config := ConfigFile.new()
	if config.load(PATH) != OK:
		return null
	var saved := Saved.new()
	saved.token = str(config.get_value(SECTION, "token", ""))
	saved.display_name = str(config.get_value(SECTION, "displayName", ""))
	saved.server = str(config.get_value(SECTION, "server", ""))
	saved.expires_at_unix = int(config.get_value(SECTION, "expiresAt", 0))
	if not saved.is_usable(int(Time.get_unix_time_from_system())):
		# An expired token is cleared now rather than left to fail later.
		clear()
		return null
	return saved

static func clear() -> void:
	if FileAccess.file_exists(PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))

static func has_saved() -> bool:
	return load_saved() != null

## Converts the server's ISO timestamp to a Unix time, or 0 when absent.
static func _to_unix(iso: String) -> int:
	if iso.strip_edges() == "":
		return 0
	# Godot parses "YYYY-MM-DDTHH:MM:SS"; the server also sends milliseconds
	# and a trailing Z, neither of which it accepts.
	var trimmed := iso.strip_edges()
	var dot := trimmed.find(".")
	if dot != -1:
		trimmed = trimmed.substr(0, dot)
	trimmed = trimmed.trim_suffix("Z")
	var parsed := Time.get_unix_time_from_datetime_string(trimmed)
	return int(parsed)
