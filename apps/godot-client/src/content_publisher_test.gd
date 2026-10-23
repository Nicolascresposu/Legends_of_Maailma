extends SceneTree

const Publisher := preload("res://src/content_publisher.gd")
const Files := preload("res://src/expansion_files.gd")
var failures: Array[String] = []

class FakeAccounts extends AccountClient:
	var calls: Array = []
	func admin(method: int, path: String, body: Variant = null, tag: String = "") -> void:
		calls.append({"method": method, "path": path, "body": body, "tag": tag})
	func reply(payload: Dictionary, ok: bool = true) -> void:
		var call: Dictionary = calls.pop_front()
		admin_response.emit(call["tag"], ok, payload)

func _init() -> void:
	await process_frame
	var accounts := FakeAccounts.new()
	accounts.user = {"id": "admin", "isAdmin": true}
	accounts.token = "test-only"
	accounts.http_base = "http://127.0.0.1:3000"
	get_root().add_child(accounts)
	var document: Dictionary = Files.load_folder(Files.default_root().path_join("core"))["data"]
	var publisher := Publisher.new()
	publisher.setup(accounts, func() -> Dictionary: return document.duplicate(true))
	get_root().add_child(publisher)
	await process_frame
	publisher.opened()
	_check("reads authenticated server publishing status", accounts.calls[0]["path"] == "/content")
	var status := {"enabled": true, "currentVersion": "old", "history": [{"version": "old", "createdAt": "2026-10-23T00:00:00Z", "action": "baseline", "actorId": null}], "expansions": [{"id": "CORE", "name": "Core"}]}
	accounts.reply(status)
	_check("enables preview on a publishing server", not publisher._preview_button.disabled)
	document["cards"][0]["name"] = "Changed Wolf"
	publisher.preview_draft()
	_check("uploads the draft for validation without publishing", accounts.calls[0]["path"] == "/content/preview" and accounts.calls[0]["body"]["document"]["cards"][0]["name"] == "Changed Wolf")
	var review := {"baseVersion": "old", "candidateVersion": "new", "changes": [{"kind": "cards", "id": "wolf", "change": "changed", "before": {"name": "Wolf"}, "after": {"name": "Changed Wolf"}}]}
	accounts.reply(review)
	_check("shows the server and exact before/after changes for review", publisher._review.visible and publisher._review_text.text.contains(accounts.http_base) and publisher._review_text.text.contains("Changed Wolf"))
	_check("review does not activate content", accounts.calls.is_empty())
	await _screenshot(publisher._review, "publish-review")
	publisher._review.hide()
	publisher._review.confirmed.emit()
	_check("publishes only the reviewed document and versions", accounts.calls[0]["path"] == "/content/publish" and accounts.calls[0]["body"]["baseVersion"] == "old" and accounts.calls[0]["body"]["candidateVersion"] == "new")
	var published := [""]
	publisher.published.connect(func(version: String) -> void: published[0] = version)
	var active := status.duplicate(true)
	active["currentVersion"] = "new"
	accounts.reply(active)
	_check("refreshes the active version and notifies the client", published[0] == "new" and publisher._server_label.text.contains("new"))
	publisher.preview_draft()
	document["cards"][0]["name"] = "Changed while validating"
	accounts.reply(review)
	_check("rejects a preview when the draft changed in flight", not publisher._review.visible and accounts.calls.is_empty())
	publisher.preview_draft()
	accounts.reply(review)
	publisher._review.hide()
	accounts.http_base = "http://127.0.0.1:3999"
	publisher._review.confirmed.emit()
	_check("does not publish a preview to a different server", accounts.calls.is_empty())
	accounts.http_base = "http://127.0.0.1:3000"
	publisher.preview_draft()
	accounts.user["id"] = "other-admin"
	accounts.reply(review)
	_check("ignores responses belonging to a previous account", not publisher._review.visible)
	accounts.user["id"] = "admin"
	publisher.refresh_history()
	accounts.reply(status)
	_check("shows version history", publisher._history.visible and publisher._history_list.item_count == 1)
	await _screenshot(publisher._history, "server-versions")
	publisher._preview_rollback()
	_check("requests a rollback preview", accounts.calls[0]["path"] == "/content/versions/old/preview")
	accounts.reply(review)
	_check("rollback also requires a change review", publisher._review.visible and accounts.calls.is_empty())
	publisher._review.hide()
	publisher._review.confirmed.emit()
	_check("sends a version-checked rollback", accounts.calls[0]["path"] == "/content/rollback" and accounts.calls[0]["body"]["version"] == "old")
	accounts.reply(status)
	publisher.refresh_history()
	accounts.reply(status)
	var received := [{}]
	publisher.server_draft_received.connect(func(value: Dictionary) -> void: received[0] = value)
	publisher._open_server_draft()
	accounts.reply({"document": document})
	_check("opens server content as an editable draft", received[0] == document)
	publisher.opened()
	var disabled := status.duplicate(true)
	disabled["enabled"] = false
	accounts.reply(disabled)
	_check("explains when publishing is disabled", publisher._preview_button.disabled and publisher._server_label.text.contains("disabled"))
	var client := MatchClient.new()
	get_root().add_child(client)
	var pinned := [[]]
	client.match_cards_received.connect(func(cards: Array) -> void: pinned[0] = cards)
	client._dispatch({"type": "MATCH_CONTENT", "version": "old-match", "cards": document["cards"]})
	_check("receives pinned match definitions separately from the current catalogue", client.match_content_version == "old-match" and pinned[0] == document["cards"])
	_check("main scene compiles with separate catalogue and match libraries", load("res://src/main.gd").can_instantiate())
	client.queue_free()
	publisher.queue_free()
	accounts.queue_free()
	await process_frame
	for failure in failures:
		print("FAIL: " + failure)
	print("RESULT: %s (%d failures)" % ["PASS" if failures.is_empty() else "FAIL", failures.size()])
	quit(0 if failures.is_empty() else 1)

func _check(label: String, condition: bool) -> void:
	print("  [%s] %s" % ["ok" if condition else "XX", label])
	if not condition:
		failures.append(label)

func _screenshot(window: Window, filename: String) -> void:
	var directory := ""
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--screenshot-dir="):
			directory = argument.trim_prefix("--screenshot-dir=")
	if directory == "":
		return
	for index in range(5):
		await process_frame
	window.get_texture().get_image().save_png(directory.path_join(filename + ".png"))
