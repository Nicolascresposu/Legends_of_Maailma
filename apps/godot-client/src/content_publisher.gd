extends VBoxContainer

## Authenticated server publication is separate from local Save and Export.
signal published(version: String)
signal issues(errors: Array)
const Validator := preload("res://src/content_validator.gd")
var accounts: AccountClient
var draft_provider: Callable
var _requests: Dictionary = {}
var _serial := 0
var _server_label: Label
var _preview_button: Button
var _history_button: Button
var _status: Dictionary = {}
var _review: ConfirmationDialog
var _review_text: TextEdit
var _review_request: Dictionary = {}
var _history: AcceptDialog
var _history_list: ItemList
var _server_expansions: OptionButton
var _notice: Label

func setup(client: AccountClient, provider: Callable) -> void:
	accounts = client
	draft_provider = provider
	if not accounts.admin_response.is_connected(_on_response):
		accounts.admin_response.connect(_on_response)

func _ready() -> void:
	var row := HBoxContainer.new()
	add_child(row)
	_server_label = Label.new()
	_server_label.text = "Server publishing · Open through the admin panel to connect."
	_server_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_server_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	row.add_child(_server_label)
	_preview_button = _button(row, "Preview publish…", preview_draft)
	_preview_button.disabled = true
	_history_button = _button(row, "Server versions…", refresh_history)
	_history_button.disabled = true
	_notice = Label.new()
	_notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_notice.visible = false
	add_child(_notice)
	_review = ConfirmationDialog.new()
	_review.title = "Review server content"
	_review.ok_button_text = "Publish version"
	_review.confirmed.connect(_confirm_review)
	add_child(_review)
	_review_text = TextEdit.new()
	_review_text.editable = false
	_review_text.add_theme_color_override("font_readonly_color", Color("e8edf2"))
	_review_text.custom_minimum_size = Vector2(720, 380)
	_review_text.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_review.add_child(_review_text)
	_history = AcceptDialog.new()
	_history.title = "Server versions and expansions"
	add_child(_history)
	var body := VBoxContainer.new()
	body.custom_minimum_size = Vector2(740, 400)
	_history.add_child(body)
	var open_row := HBoxContainer.new()
	body.add_child(open_row)
	_server_expansions = OptionButton.new()
	_server_expansions.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	open_row.add_child(_server_expansions)
	_button(open_row, "Open server draft", _open_server_draft)
	_history_list = ItemList.new()
	_history_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(_history_list)
	_button(body, "Preview rollback to selected version…", _preview_rollback)

func opened() -> void:
	if accounts == null or not accounts.is_admin():
		return
	_history_button.disabled = false
	_request("status", HTTPClient.METHOD_GET, "")

func _request(operation: String, method: int, path: String, body: Variant = null, context: Dictionary = {}) -> void:
	if accounts == null or not accounts.is_admin():
		_say("Sign in as an admin to publish server content.", true)
		return
	_serial += 1
	var tag := "creator-publish:%d" % _serial
	_requests[tag] = {"operation": operation, "server": accounts.http_base, "user": str(accounts.user.get("id", "")), "context": context}
	accounts.admin(method, "/content" + path, body, tag)

func preview_draft() -> void:
	if not draft_provider.is_valid():
		return
	var document: Dictionary = draft_provider.call()
	var errors := Validator.validate_shape(document)
	if not errors.is_empty():
		issues.emit(errors)
		return
	_say("Validating draft against " + accounts.http_base + "…")
	_request("preview", HTTPClient.METHOD_POST, "/preview", {"document": document}, {"document": document, "stamp": JSON.stringify(document), "kind": "publish"})

func refresh_history() -> void:
	_request("history", HTTPClient.METHOD_GET, "")

func _on_response(tag: String, ok: bool, payload: Dictionary) -> void:
	if not _requests.has(tag):
		return
	var request: Dictionary = _requests[tag]
	_requests.erase(tag)
	if accounts.http_base != request["server"] or str(accounts.user.get("id", "")) != request["user"]:
		_say("The signed-in server or account changed. Refresh the server versions.", true)
		return
	if not ok:
		var message := str(payload.get("message", "Server request failed."))
		_say(message, true)
		if payload.get("code", "") == "INVALID_CONTENT":
			issues.emit(Array(message.split("\n", false)))
		return
	match str(request["operation"]):
		"status", "history":
			_update_status(payload)
			if request["operation"] == "history":
				_show_history()
		"preview":
			var context: Dictionary = request["context"]
			if context["kind"] == "publish" and JSON.stringify(draft_provider.call()) != context["stamp"]:
				_say("The draft changed while validating. Preview it again.", true)
				return
			_open_review(payload, request)
		"publish", "rollback":
			_update_status(payload)
			_history.hide()
			_say("Server is using version %s. Start a new match to test it." % str(payload["currentVersion"]).left(12))
			published.emit(str(payload["currentVersion"]))
		"open":
			server_draft_received.emit(payload.get("document", {}))

signal server_draft_received(document: Dictionary)

func _update_status(payload: Dictionary) -> void:
	_status = payload
	_preview_button.disabled = not bool(payload.get("enabled", false))
	var version := str(payload.get("currentVersion", ""))
	_server_label.text = "%s · %s%s" % [accounts.http_base, version.left(12), " · publishing disabled" if not payload.get("enabled", false) else ""]
	_server_label.tooltip_text = accounts.http_base + "\n" + version

func _open_review(payload: Dictionary, request: Dictionary) -> void:
	var changes: Array = payload.get("changes", [])
	if changes.is_empty():
		_say("The proposed content already matches the server.")
		return
	_review_request = request.duplicate(true)
	_review_request["baseVersion"] = payload["baseVersion"]
	_review_request["candidateVersion"] = payload["candidateVersion"]
	var lines: Array[String] = ["Server: " + str(request["server"]), "%s → %s" % [str(payload["baseVersion"]).left(12), str(payload["candidateVersion"]).left(12)], "", "%d definition change(s). New matches use this version; existing matches retain theirs." % changes.size(), ""]
	for change: Dictionary in changes:
		lines.append("%s · %s · %s" % [str(change["change"]).to_upper(), change["kind"], change["id"]])
		var before: Variant = change.get("before")
		var after: Variant = change.get("after")
		if before is Dictionary and after is Dictionary:
			var keys: Array = before.keys()
			for key in after:
				if not keys.has(key):
					keys.append(key)
			for key in keys:
				if JSON.stringify(before.get(key)) != JSON.stringify(after.get(key)):
					lines.append("  %s: %s → %s" % [key, JSON.stringify(before.get(key)), JSON.stringify(after.get(key))])
		else:
			lines.append("Before:\n" + JSON.stringify(before, "  ", false))
			lines.append("After:\n" + JSON.stringify(after, "  ", false))
		lines.append("")
	_review_text.text = "\n".join(lines)
	_review.ok_button_text = "Publish version" if request["context"]["kind"] == "publish" else "Roll back server"
	_review.popup_centered(Vector2i(800, 540))

func _confirm_review() -> void:
	if _review_request.is_empty():
		return
	if accounts.http_base != _review_request["server"] or str(accounts.user.get("id", "")) != _review_request["user"]:
		_say("The server or account changed. Preview again.", true)
		return
	var context: Dictionary = _review_request["context"]
	var body := {"baseVersion": _review_request["baseVersion"], "candidateVersion": _review_request["candidateVersion"]}
	if context["kind"] == "publish":
		if JSON.stringify(draft_provider.call()) != context["stamp"]:
			_say("The draft changed. Preview again before publishing.", true)
			return
		body["document"] = context["document"]
		_request("publish", HTTPClient.METHOD_POST, "/publish", body)
	else:
		body["version"] = context["version"]
		_request("rollback", HTTPClient.METHOD_POST, "/rollback", body)
	_review_request = {}

func _show_history() -> void:
	_history_list.clear()
	for entry: Dictionary in _status.get("history", []):
		var version: String = entry["version"]
		_history_list.add_item("%s · %s · %s%s" % [entry["createdAt"], entry["action"], version.left(12), " · active" if version == _status.get("currentVersion") else ""])
		_history_list.set_item_metadata(_history_list.item_count - 1, version)
		_history_list.set_item_tooltip(_history_list.item_count - 1, "Actor: " + str(entry.get("actorId", "Shipped content")) + "\n" + version)
	if _history_list.item_count > 0:
		_history_list.select(0)
	_server_expansions.clear()
	for expansion: Dictionary in _status.get("expansions", []):
		_server_expansions.add_item(str(expansion["name"]))
		_server_expansions.set_item_metadata(_server_expansions.item_count - 1, expansion["id"])
	_history.popup_centered(Vector2i(800, 500))

func _preview_rollback() -> void:
	var selected := _history_list.get_selected_items()
	if selected.is_empty():
		return
	var version := str(_history_list.get_item_metadata(selected[0]))
	_history.hide()
	_request("preview", HTTPClient.METHOD_GET, "/versions/%s/preview" % version.uri_encode(), null, {"kind": "rollback", "version": version})

func _open_server_draft() -> void:
	if _server_expansions.selected < 0:
		return
	var id := str(_server_expansions.get_item_metadata(_server_expansions.selected))
	_history.hide()
	_request("open", HTTPClient.METHOD_GET, "/expansions/" + id.uri_encode())

func _say(message: String, error: bool = false) -> void:
	_notice.visible = true
	_notice.text = message
	_notice.add_theme_color_override("font_color", Color("ef9999") if error else Color("a8d9b4"))

func _button(parent: Node, text: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.pressed.connect(action)
	parent.add_child(button)
	return button
