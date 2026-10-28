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
##
## A card's art can be framed: `<card_id>.crop.json` beside the image holds the
## part of it the card shows, so the image itself is kept whole and can be
## reframed later.

const ART_DIR := "res://art/cards/"
## Tried in order, so PNG art wins over a placeholder in another format.
const EXTENSIONS: Array[String] = ["png", "webp", "jpg", "jpeg", "svg"]
## Replaces an art file's extension to name its framing.
const CROP_SUFFIX := ".crop.json"
## The whole image, as a crop.
const FULL := Rect2(0.0, 0.0, 1.0, 1.0)

## Height of the art banner within a card tile, in pixels.
const HAND_ART_HEIGHT := 46.0
const BOARD_ART_HEIGHT := 38.0

## Where art is looked up and linked to; tests point it at a scratch folder.
static var art_dir := ART_DIR
## Cached lookups, including misses, so a missing file is probed only once.
static var _cache: Dictionary = {}
## The same, before framing.
static var _sources: Dictionary = {}
## Every art file by card id, read from the folders once: the id the server
## sends does not say which expansion folder to look in.
static var _index: Dictionary = {}
static var _indexed := false

## The texture for a card, framed, or null when the card has no art.
static func texture_for(card_id: String) -> Texture2D:
	if card_id == "":
		return null
	if not _cache.has(card_id):
		_cache[card_id] = crop(source_texture_for(card_id), crop_for(card_id))
	return _cache[card_id]

## A card's whole image, before framing, or null when the card has no art.
static func source_texture_for(card_id: String) -> Texture2D:
	if card_id == "":
		return null
	if _sources.has(card_id):
		return _sources[card_id]
	var found: Texture2D = null
	var path := path_for(card_id)
	if path != "":
		found = _load(path)
	# A miss is cached as null: the file will not appear mid-session, and
	# probing five paths per card per repaint would be wasteful.
	_sources[card_id] = found
	return found

## The part of a card's image it shows, as fractions of the image; FULL when
## it is not framed.
static func crop_for(card_id: String) -> Rect2:
	var path := path_for(card_id)
	if path == "" or not FileAccess.file_exists(_crop_path(path)):
		return FULL
	path = _crop_path(path)
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary or not parsed.get("crop") is Array or parsed["crop"].size() != 4:
		return FULL
	var values: Array = parsed["crop"]
	var region := Rect2(float(values[0]), float(values[1]), float(values[2]), float(values[3])).intersection(FULL)
	return region if region.has_area() else FULL

## Frames a card's art to `region`; FULL drops its framing.
static func set_crop(card_id: String, region: Rect2) -> void:
	var path := path_for(card_id)
	if path == "":
		return
	_write_crop(_absolute(path), region)
	_cache.erase(card_id)

## `texture` cut down to `region`, given as fractions of it.
static func crop(texture: Texture2D, region: Rect2) -> Texture2D:
	if texture == null or region.is_equal_approx(FULL):
		return texture
	var image := texture.get_image()
	if image == null or image.is_empty():
		return texture
	if image.is_compressed():
		image.decompress()
	image.clear_mipmaps()
	var size := Vector2(image.get_size())
	var pixels := Rect2i(Rect2(region.position * size, region.size * size)).intersection(Rect2i(Vector2i.ZERO, image.get_size()))
	if pixels.size.x < 1 or pixels.size.y < 1:
		return texture
	var cropped := image.get_region(pixels)
	cropped.generate_mipmaps()
	return ImageTexture.create_from_image(cropped)

## The largest part of an image `size` big that fills a window of `aspect`
## (width over height) without stretching: all of one side, centred. This is
## what a window shows of art that is not framed.
static func cover(size: Vector2, aspect: float) -> Rect2:
	var fraction := Vector2.ONE
	var image_aspect := size.x / size.y
	if image_aspect > aspect:
		fraction.x = aspect / image_aspect
	else:
		fraction.y = image_aspect / aspect
	return Rect2((Vector2.ONE - fraction) * 0.5, fraction)

static func has_art(card_id: String) -> bool:
	return texture_for(card_id) != null

## The art file a card uses, or "" when it has none.
static func path_for(card_id: String) -> String:
	var paths := _paths(card_id)
	return paths[0] if not paths.is_empty() else ""

## Where a card's art is shown relative to the art folder, e.g. `core/chicken.png`.
static func relative(path: String) -> String:
	return path.trim_prefix(art_dir.trim_suffix("/") + "/")

## Forgets cached lookups, so newly added art appears without a restart.
static func clear_cache() -> void:
	_cache.clear()
	_sources.clear()
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
## expansion, framed to `region`, and replacing any art it had. Returns an
## error message, or "" on success.
static func link(card_id: String, source: String, folder: String, region := FULL) -> String:
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
	# After the removals: art in another format beside it shares its framing's name.
	_write_crop(to, region)
	_index[card_id] = [target]
	_sources[card_id] = texture
	_cache[card_id] = crop(texture, region)
	return ""

## Deletes a card's art, so it renders without a picture.
static func unlink(card_id: String) -> void:
	for path in _paths(card_id):
		_remove(_absolute(path))
	_index.erase(card_id)
	_sources[card_id] = null
	_cache[card_id] = null

## Moves a card's art to the id it was renamed to, in the `folder` of its
## expansion. Returns an error message, or "" on success.
static func rename(from_id: String, to_id: String, folder: String) -> String:
	var path := path_for(from_id)
	if path == "":
		return ""
	var error := link(to_id, path, folder, crop_for(from_id))
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

static func _crop_path(path: String) -> String:
	return path.get_basename() + CROP_SUFFIX

## Saves the framing of the art file at `absolute`; FULL removes it.
static func _write_crop(absolute: String, region: Rect2) -> void:
	var path := _crop_path(absolute)
	if region.is_equal_approx(FULL):
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
		return
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify({"crop": [region.position.x, region.position.y, region.size.x, region.size.y]}, "", true, true))

static func _remove(absolute: String) -> void:
	for path in [absolute, absolute + ".import", _crop_path(absolute)]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
