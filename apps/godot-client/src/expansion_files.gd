extends RefCounted

## Local authoring only. No HTTP requests, database changes, or live publishing.
const Validator := preload("res://src/content_validator.gd")
const FILES := ["expansion", "cards", "packs"]
## Files a folder may leave out; a missing one holds nothing.
const OPTIONAL := ["starterDecks", "scenarios"]

static func default_root() -> String:
	return ProjectSettings.globalize_path("res://").path_join("../../packages/card-definitions/content").simplify_path()

static func load_folder(directory: String) -> Dictionary:
	var data: Dictionary = {}
	var errors: Array[String] = []
	for key in FILES + OPTIONAL:
		var path := directory.path_join(key + ".json")
		if key in OPTIONAL and not FileAccess.file_exists(path):
			data[key] = []
			continue
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null:
			errors.append("%s: %s" % [path, error_string(FileAccess.get_open_error())])
			continue
		var json := JSON.new()
		var result := json.parse(file.get_as_text())
		if result != OK:
			errors.append("%s line %d: %s" % [path, json.get_error_line(), json.get_error_message()])
		else:
			data[key] = json.data
	if errors.is_empty():
		errors.assign(Validator.validate_shape(data))
	return {"ok": errors.is_empty(), "data": data, "errors": errors, "stamp": fingerprint(directory)}

static func catalog(root: String, excluding: String = "") -> Dictionary:
	var directory := DirAccess.open(root)
	if directory == null:
		return {"ok": false, "entries": [], "errors": ["Cannot open content folder: " + root]}
	var names := directory.get_directories()
	names.sort()
	var entries: Array = []
	var errors: Array[String] = []
	for folder in names:
		if folder.begins_with("."):
			continue
		var path := root.path_join(folder).simplify_path()
		if same_path(path, excluding):
			continue
		var result := load_folder(path)
		if result["ok"]:
			entries.append({"folder": folder, "path": path, "data": result["data"], "stamp": result["stamp"]})
		else:
			errors.append_array(result["errors"])
	return {"ok": errors.is_empty(), "entries": entries, "errors": errors}

static func validate(data: Dictionary, root: String = "", excluding: String = "") -> Array[String]:
	var siblings: Array = []
	var errors: Array[String] = []
	if root != "":
		var result := catalog(root, excluding)
		siblings = result["entries"]
		errors.append_array(result["errors"])
	errors.append_array(Validator.validate(data, siblings))
	return errors

static func same_path(a: String, b: String) -> bool:
	if a == "" or b == "":
		return false
	var left := ProjectSettings.globalize_path(a).simplify_path().trim_suffix("/")
	var right := ProjectSettings.globalize_path(b).simplify_path().trim_suffix("/")
	return left.nocasecmp_to(right) == 0 if OS.get_name() == "Windows" else left == right

static func safe_folder(name: String) -> bool:
	var pattern := RegEx.new()
	pattern.compile("^[a-zA-Z0-9][a-zA-Z0-9_-]*$")
	return pattern.search(name) != null

static func suggested_folder(id: String) -> String:
	var pattern := RegEx.new()
	pattern.compile("[^a-z0-9_-]+")
	return pattern.sub(id.to_lower().replace("_", "-"), "-", true).trim_prefix("-")

static func fingerprint(directory: String) -> String:
	var combined := ""
	for key in FILES + OPTIONAL:
		var path := directory.path_join(key + ".json")
		combined += key + ":" + (FileAccess.get_sha256(path) if FileAccess.file_exists(path) else "missing") + "\n"
	return combined.sha256_text()

static func has_content(directory: String) -> bool:
	for key in FILES:
		if FileAccess.file_exists(directory.path_join(key + ".json")):
			return true
	return false

## `context`, when given, is the other expansions to validate against in place
## of the ones on disk: a save that also rewrites them validates what they
## will be, not what they were.
static func save(root: String, folder: String, data: Dictionary, expected_stamp: String = "", overwrite: bool = false, context: Variant = null) -> Dictionary:
	if not safe_folder(folder):
		return _failure(["Folder name must use letters, numbers, hyphens or underscores; no paths."])
	var path := root.path_join(folder).simplify_path()
	# Resolve the final target before any writes; it must be an immediate child.
	if not same_path(path.get_base_dir(), root):
		return _failure(["Expansion folder must be inside the selected content folder."])
	var errors := Validator.validate(data, context) if context is Array else validate(data, root, path)
	if not errors.is_empty():
		return _failure(errors)
	return write_folder(path, data, expected_stamp, overwrite)

## Stage every file before replacing any original. Each replacement is a rename;
## old files are retained until all replacements succeed, and rolled back on error.
static func write_folder(directory: String, data: Dictionary, expected_stamp: String = "", overwrite: bool = false) -> Dictionary:
	var errors := Validator.validate_shape(data)
	if not errors.is_empty():
		return _failure(errors)
	var present := has_content(directory)
	var current := fingerprint(directory)
	if expected_stamp != "" and current != expected_stamp:
		return _failure(["Files changed outside the creator. Reopen the expansion before saving: " + directory])
	if present and expected_stamp == "" and not overwrite:
		return {"ok": false, "needs_overwrite": true, "path": directory, "stamp": current, "errors": []}
	var result := DirAccess.make_dir_recursive_absolute(directory)
	if result != OK:
		return _failure(["Cannot create folder %s: %s" % [directory, error_string(result)]])
	var token := ".creator-%s-%s" % [Time.get_ticks_usec(), randi()]
	var staged: Array = []
	for key in FILES + OPTIONAL:
		var path := directory.path_join(key + ".json")
		# An optional file is written once it holds something, and kept after.
		if key in OPTIONAL and data.get(key, []).is_empty() and not FileAccess.file_exists(path):
			continue
		var original := FileAccess.open(path, FileAccess.READ) if FileAccess.file_exists(path) else null
		if original != null:
			var parsed := JSON.new()
			var valid := parsed.parse(original.get_as_text()) == OK
			original.close()
			if valid and parsed.data == data.get(key, []):
				continue
		var record := {"path": path, "temp": path + token + ".tmp", "backup": path + token + ".backup", "backed_up": false, "replaced": false}
		staged.append(record)
		var file := FileAccess.open(record["temp"], FileAccess.WRITE)
		if file == null:
			_cleanup_temps(staged)
			return _failure(["Cannot stage %s: %s" % [path, error_string(FileAccess.get_open_error())]])
		file.store_string(_serialize(data.get(key, [])) + "\n")
		file.flush()
		var written := file.get_error()
		file.close()
		if written != OK:
			_cleanup_temps(staged)
			return _failure(["Could not write %s: %s" % [path, error_string(written)]])
	if fingerprint(directory) != current:
		_cleanup_temps(staged)
		return _failure(["Files changed while staging the save. Reopen the expansion."])
	for record: Dictionary in staged:
		if FileAccess.file_exists(record["path"]):
			result = DirAccess.rename_absolute(record["path"], record["backup"])
			if result != OK:
				return _rollback(staged, "Cannot back up %s: %s" % [record["path"], error_string(result)])
			record["backed_up"] = true
		result = DirAccess.rename_absolute(record["temp"], record["path"])
		if result != OK:
			return _rollback(staged, "Cannot replace %s: %s" % [record["path"], error_string(result)])
		record["replaced"] = true
	for record: Dictionary in staged:
		if record["backed_up"]:
			DirAccess.remove_absolute(record["backup"])
	return {"ok": true, "path": directory, "stamp": fingerprint(directory), "errors": []}

## Keep human-editable two-space JSON and compact scalar arrays, matching the
## repository's formatter. Unchanged files are never reformatted during a save.
static func _serialize(value: Variant, depth: int = 0, column: int = 0) -> String:
	var indent := "  ".repeat(depth)
	var child_indent := indent + "  "
	if value is Dictionary:
		if value.is_empty():
			return "{}"
		var lines: Array[String] = []
		for key in value:
			var prefix := child_indent + JSON.stringify(str(key)) + ": "
			lines.append(prefix + _serialize(value[key], depth + 1, prefix.length()))
		return "{\n" + ",\n".join(lines) + "\n" + indent + "}"
	if value is Array:
		if value.is_empty():
			return "[]"
		var simple := true
		var inline_parts: Array[String] = []
		for item in value:
			if item is Dictionary or item is Array:
				simple = false
				break
			inline_parts.append(_serialize(item))
		var inline_text := "[" + ", ".join(inline_parts) + "]"
		if simple and column + inline_text.length() <= 100:
			return inline_text
		var lines: Array[String] = []
		for item in value:
			lines.append(child_indent + _serialize(item, depth + 1, child_indent.length()))
		return "[\n" + ",\n".join(lines) + "\n" + indent + "]"
	if typeof(value) == TYPE_FLOAT and floor(value) == value and abs(value) <= 9007199254740991.0:
		return str(int(value))
	return JSON.stringify(value)

static func _cleanup_temps(records: Array) -> void:
	for record: Dictionary in records:
		if FileAccess.file_exists(record["temp"]):
			DirAccess.remove_absolute(record["temp"])

static func _rollback(records: Array, message: String) -> Dictionary:
	var errors: Array[String] = [message]
	for record: Dictionary in records:
		if record["replaced"]:
			DirAccess.remove_absolute(record["path"])
		if record["backed_up"]:
			var result := DirAccess.rename_absolute(record["backup"], record["path"])
			if result != OK:
				errors.append("Restore failed; original retained at " + str(record["backup"]))
	_cleanup_temps(records)
	return _failure(errors)

static func _failure(errors: Array) -> Dictionary:
	return {"ok": false, "errors": errors}
