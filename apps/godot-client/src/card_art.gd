extends RefCounted
class_name CardArt

## Looks up card art by convention: `res://art/cards/<card_id>.png`.
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

## Cached lookups, including misses, so a missing file is probed only once.
static var _cache: Dictionary = {}

## The texture for a card, or null when the card has no art.
static func texture_for(card_id: String) -> Texture2D:
	if card_id == "":
		return null
	if _cache.has(card_id):
		return _cache[card_id]
	var found: Texture2D = null
	for extension in EXTENSIONS:
		var path := ART_DIR + card_id + "." + extension
		if ResourceLoader.exists(path):
			var resource := load(path)
			if resource is Texture2D:
				found = resource
				break
	# A miss is cached as null: the file will not appear mid-session, and
	# probing five paths per card per repaint would be wasteful.
	_cache[card_id] = found
	return found

static func has_art(card_id: String) -> bool:
	return texture_for(card_id) != null

## Forgets cached lookups, so newly added art appears without a restart.
static func clear_cache() -> void:
	_cache.clear()

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
