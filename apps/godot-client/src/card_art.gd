extends RefCounted
class_name CardArt

## Looks up card art by convention: `res://art/cards/<expansion>/<card_id>.png`,
## where `<expansion>` is the expansion's content folder. Art directly in
## `res://art/cards/` is found too, which is where it lived first.
##
## Art is a client asset, so nothing about it reaches the shared model or the
## engine — the card id the server already sends is the whole lookup key. A
## card with no art file simply renders as text, which is what the client did
## before art existed.

const ART_DIR := "res://art/cards/"
## Tried in order, so PNG art wins over a placeholder in another format.
const EXTENSIONS: Array[String] = ["png", "webp", "jpg", "jpeg", "svg"]

## Height of the art banner within a card tile, in pixels.
const HAND_ART_HEIGHT := 46.0
const BOARD_ART_HEIGHT := 38.0

## Where art is looked up and linked to; tests point it at a scratch folder.
static var art_dir := ART_DIR
## Cached lookups, including misses, so a missing file is probed only once.
static var _cache: Dictionary = {}
## Every art file by card id, read from the folders once: the id the server
## sends does not say which expansion folder to look in.
static var _index: Dictionary = {}
static var _indexed := false

## The texture for a card, or null when the card has no art.
static func texture_for(card_id: String) -> Texture2D:
	if card_id == "":
		return null
	if _cache.has(card_id):
		return _cache[card_id]
	var found: Texture2D = null
	var path := path_for(card_id)
	if path != "":
		found = _load(path)
	# A miss is cached as null: the file will not appear mid-session, and
	# probing five paths per card per repaint would be wasteful.
	_cache[card_id] = found
	return found

static func has_art(card_id: String) -> bool:
	return texture_for(card_id) != null

## The art file a card uses, or "" when it has none.
static func path_for(card_id: String) -> String:
	var paths := _paths(card_id)
	return paths[0] if not paths.is_empty() else ""

## Where a card's art is shown relative to the art folder, e.g. `core/wolf.png`.
static func relative(path: String) -> String:
	return path.trim_prefix(art_dir.trim_suffix("/") + "/")

## Forgets cached lookups, so newly added art appears without a restart.
static func clear_cache() -> void:
	_cache.clear()
	_index.clear()
	_indexed = false

## A texture read straight from an image file, or null when it is not one.
##
## Art the creator has just linked has not been imported by the editor yet,
## so it cannot go through `load`.
static func load_image(path: String) -> Texture2D:
	if not EXTENSIONS.has(path.get_extension().to_lower()):
		return null
	var image := Image.load_from_file(ProjectSettings.globalize_path(path))
	if image == null or image.is_empty():
		return null
	# Cards draw their art far below its authored size, with mipmaps.
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)

## Makes the image at `source` a card's art, copied into the `folder` of its
## expansion and replacing any art it had. Returns an error message, or "" on
## success.
static func link(card_id: String, source: String, folder: String) -> String:
	var extension := source.get_extension().to_lower()
	var texture := load_image(source)
	if texture == null:
		return "%s is not a PNG, WebP, JPEG or SVG image" % source.get_file()
	var target := art_dir.path_join(folder).path_join(card_id + "." + extension)
	var from := _absolute(source)
	var to := _absolute(target)
	if from.nocasecmp_to(to) != 0:
		DirAccess.make_dir_recursive_absolute(to.get_base_dir())
		var error := DirAccess.copy_absolute(from, to)
		if error != OK:
			return "Could not copy art to %s: %s" % [to, error_string(error)]
		# The editor's import of the old image would otherwise keep showing it.
		_remove(to + ".import")
	# Art elsewhere — another format, another folder — would win the lookup
	# over the new image, or be left behind stale.
	for path in _paths(card_id):
		if _absolute(path).nocasecmp_to(to) != 0:
			_remove(_absolute(path))
	_index[card_id] = [target]
	_cache[card_id] = texture
	return ""

## Deletes a card's art, so it renders without a picture.
static func unlink(card_id: String) -> void:
	for path in _paths(card_id):
		_remove(_absolute(path))
	_index.erase(card_id)
	_cache[card_id] = null

## Moves a card's art to the id it was renamed to, in the `folder` of its
## expansion. Returns an error message, or "" on success.
static func rename(from_id: String, to_id: String, folder: String) -> String:
	var path := path_for(from_id)
	if path == "":
		return ""
	var error := link(to_id, path, folder)
	if error == "":
		unlink(from_id)
	return error

## A banner showing a card's art, or null when the card has none.
##
## The rect crops rather than distorts: card art is authored wider than it is
## tall, and squashing it to fit reads worse than losing the edges.
static func make_banner(card_id: String, height: float) -> TextureRect:
	var texture := texture_for(card_id)
	if texture == null:
		return null
	var rect := TextureRect.new()
	rect.texture = texture
	rect.custom_minimum_size.y = height
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	rect.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# The banner is decoration: it must never swallow a click meant for the
	# card beneath it, which is what starts a drag.
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.clip_contents = true
	return rect

## A card's art files, best first: by format, and an expansion folder's over
## the art folder's own.
static func _paths(card_id: String) -> Array:
	if card_id == "":
		return []
	if not _indexed:
		_build_index()
	return _index.get(card_id, [])

static func _build_index() -> void:
	_index.clear()
	_indexed = true
	var folders: Array[String] = []
	for folder in DirAccess.get_directories_at(art_dir):
		folders.append(art_dir.path_join(folder))
	folders.append(art_dir)
	for folder in folders:
		# An exported build lists imported art by its `.import` file alone.
		var names: Dictionary = {}
		for file in DirAccess.get_files_at(folder):
			names[file.trim_suffix(".import").trim_suffix(".remap")] = true
		for file: String in names:
			if EXTENSIONS.has(file.get_extension().to_lower()):
				var paths: Array = _index.get_or_add(file.get_basename(), [])
				paths.append(folder.path_join(file))
	for paths: Array in _index.values():
		paths.sort_custom(func(a: String, b: String) -> bool: return _rank(a) < _rank(b))

static func _rank(path: String) -> int:
	var loose := path.get_base_dir() == art_dir.trim_suffix("/")
	return (EXTENSIONS.size() if loose else 0) + EXTENSIONS.find(path.get_extension().to_lower())

static func _absolute(path: String) -> String:
	return ProjectSettings.globalize_path(path).simplify_path()

## Imported art loads as the editor prepared it. A file with no import beside
## it — one just linked, before the editor has seen it — is read directly.
static func _load(path: String) -> Texture2D:
	var raw := FileAccess.file_exists(path) and not FileAccess.file_exists(path + ".import")
	if not raw and ResourceLoader.exists(path):
		var resource := load(path)
		if resource is Texture2D:
			return resource
	return load_image(path)

static func _remove(absolute: String) -> void:
	if FileAccess.file_exists(absolute):
		DirAccess.remove_absolute(absolute)
	if FileAccess.file_exists(absolute + ".import"):
		DirAccess.remove_absolute(absolute + ".import")
