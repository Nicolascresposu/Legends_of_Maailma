extends RefCounted
class_name SessionStore

## Remembers the accounts signed in on this machine, for quick sign-in.
##
## Each account is kept with the session token it last signed in with, so
## choosing it again needs no password while that session lives. Passwords are
## never stored. Signing out ends the session but keeps the account listed, so
## only its password is needed next time; forgetting it removes it entirely.
##
## Tokens are written to Godot's per-user data directory, which is the
## ordinary place for a desktop game's local state. They are stored in plain
## text: anything running as this user could read them, but the same is true of
## most game launchers, and encrypting them with a key shipped inside the
## client would be obfuscation rather than protection.

const PATH := "user://accounts.cfg"
## Where a single session was kept before accounts were remembered.
const LEGACY_PATH := "user://session.cfg"
const SETTINGS := "settings"
const ACCOUNT_PREFIX := "account."
## Sessions nearing expiry are treated as expired, so a restore does not
## succeed only to fail moments later mid-request.
const EXPIRY_MARGIN_SECONDS := 60

## One remembered account, as last confirmed by its server.
class Account extends RefCounted:
	var key := ""
	var id := ""
	var email := ""
	var display_name := ""
	var server := ""
	var token := ""
	var expires_at_unix := 0
	## Higher is more recent. A counter rather than a time: two sign-ins in
	## the same second must still have an order.
	var recency := 0

	## Whether choosing this account can skip the password.
	func has_session(now_unix: int) -> bool:
		if token == "":
			return false
		# An absent expiry is treated as usable: only the server truly knows,
		# and /me will reject it if it is stale.
		if expires_at_unix <= 0:
			return true
		return expires_at_unix - EXPIRY_MARGIN_SECONDS > now_unix

## The key an account is stored under: the same person on two servers is two
## accounts.
static func key_for(server: String, user_id: String) -> String:
	return ("%s|%s" % [server, user_id]).md5_text()

## Records a successful sign-in, adding the account or refreshing it, and makes
## it the most recently used. An empty `expires_at_iso` keeps the known expiry,
## as a restore learns who the token belongs to but not when it ends.
static func remember(user: Dictionary, token: String, server: String, expires_at_iso: String) -> String:
	var config := _load()
	var key := key_for(server, str(user.get("id", "")))
	var section := ACCOUNT_PREFIX + key
	var expires := _to_unix(expires_at_iso)
	if expires == 0 and str(config.get_value(section, "token", "")) == token:
		expires = int(config.get_value(section, "expiresAt", 0))
	config.set_value(section, "id", str(user.get("id", "")))
	config.set_value(section, "email", str(user.get("email", "")))
	config.set_value(section, "displayName", str(user.get("displayName", "")))
	config.set_value(section, "server", server)
	config.set_value(section, "token", token)
	config.set_value(section, "expiresAt", expires)
	var recency := int(config.get_value(SETTINGS, "recency", 0)) + 1
	config.set_value(SETTINGS, "recency", recency)
	config.set_value(section, "recency", recency)
	_save(config)
	return key

## Every remembered account, most recently used first. A session that has
## expired is dropped now rather than left to fail later; the account stays.
static func accounts() -> Array[Account]:
	var config := _load()
	var now := int(Time.get_unix_time_from_system())
	var list: Array[Account] = []
	var expired := false
	for section in config.get_sections():
		if not section.begins_with(ACCOUNT_PREFIX):
			continue
		var account := Account.new()
		account.key = section.trim_prefix(ACCOUNT_PREFIX)
		account.id = str(config.get_value(section, "id", ""))
		account.email = str(config.get_value(section, "email", ""))
		account.display_name = str(config.get_value(section, "displayName", ""))
		account.server = str(config.get_value(section, "server", ""))
		account.token = str(config.get_value(section, "token", ""))
		account.expires_at_unix = int(config.get_value(section, "expiresAt", 0))
		account.recency = int(config.get_value(section, "recency", 0))
		if account.token != "" and not account.has_session(now):
			account.token = ""
			config.set_value(section, "token", "")
			expired = true
		list.append(account)
	if expired:
		_save(config)
	list.sort_custom(func(a: Account, b: Account) -> bool: return a.recency > b.recency)
	return list

static func find(key: String) -> Account:
	for account in accounts():
		if account.key == key:
			return account
	return null

## The account to sign back in to at startup: the most recent one, if its
## session still lives. An older account's session is not resumed in its place,
## as that would sign in someone other than whoever used the game last.
static func resumable() -> Account:
	var list := accounts()
	if list.is_empty() or list[0].token == "":
		return null
	return list[0]

## Ends an account's session on this machine, keeping the account listed.
static func end_session(key: String) -> void:
	var config := _load()
	var section := ACCOUNT_PREFIX + key
	if not config.has_section(section):
		return
	config.set_value(section, "token", "")
	config.set_value(section, "expiresAt", 0)
	_save(config)

## Removes an account entirely.
static func forget(key: String) -> void:
	var config := _load()
	var section := ACCOUNT_PREFIX + key
	if not config.has_section(section):
		return
	config.erase_section(section)
	_save(config)

## Whether a launch signs straight back in to the last account. On unless
## turned off, which is how the client behaved before it was a choice.
static func auto_sign_in() -> bool:
	return bool(_load().get_value(SETTINGS, "autoSignIn", true))

static func set_auto_sign_in(enabled: bool) -> void:
	var config := _load()
	config.set_value(SETTINGS, "autoSignIn", enabled)
	_save(config)

## Forgets every account and setting.
static func clear() -> void:
	for path in [PATH, LEGACY_PATH]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

static func _load() -> ConfigFile:
	# The single saved session cannot be carried over: it records no account
	# id to key it by. Removing it means one more sign-in, and no token left
	# behind on disk that nothing will ever use or clear.
	if FileAccess.file_exists(LEGACY_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(LEGACY_PATH))
	var config := ConfigFile.new()
	config.load(PATH)
	return config

static func _save(config: ConfigFile) -> void:
	var error := config.save(PATH)
	if error != OK:
		# Failing to remember is not worth interrupting play over.
		push_warning("Could not save accounts: %d" % error)

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
