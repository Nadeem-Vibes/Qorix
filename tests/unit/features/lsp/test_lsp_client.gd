extends "res://tests/support/test_case.gd"

## Exercises the JSON-RPC state machine without starting a process. The client
## reads framed bytes through _handle_stdout(), exactly like the frame pump
## does, so these tests cover the same dispatch path a real server uses.

const Protocol = preload("res://src/features/lsp/lsp_protocol.gd")
const Client = preload("res://src/features/lsp/lsp_client.gd")


func _client(settings: Variant = null) -> Node:
	var client = Client.new()
	client.configure({
		"id": "fake",
		"display": "Fake Server",
		"command": "fake-server",
		"args": [],
		"settings": settings,
	}, "C:/fake-project", "C:/fake-project")
	client.running = true
	return client


func _sent(client) -> Array:
	var parser = Protocol.new()
	var messages: Array = []
	for frame in client._write_queue:
		var parsed: Dictionary = parser.feed(frame)
		messages.append_array(parsed.get("messages", []))
	return messages


func _inject(client, message: Dictionary) -> void:
	client._handle_stdout(Protocol.encode(message))


func _last(client) -> Dictionary:
	var messages := _sent(client)
	return messages[messages.size() - 1] if !messages.is_empty() else {}


# ── INITIALIZE ──────────────────────────────────────────────────────────────

func test_initialize_is_sent_and_capabilities_are_stored() -> void:
	var client = _client()
	var capabilities: Array = []
	client.initialized.connect(func(_sender, caps: Dictionary) -> void:
		capabilities.append(caps)
	)

	client._begin_initialize()
	var first := _last(client)
	assert_eq(first.get("method"), "initialize")
	assert_eq(first.get("params", {}).get("processId"), OS.get_process_id())
	assert_eq(first.get("params", {}).get("rootUri"), "file:///C:/fake-project")
	assert_eq(client._init_id, first.get("id"))

	_inject(client, {
		"jsonrpc": "2.0",
		"id": client._init_id,
		"result": {"capabilities": {"hoverProvider": true, "completionProvider": {"triggerCharacters": ["."]}}},
	})

	assert_true(client.server_ready)
	assert_true(client.is_ready())
	assert_true(client.supports("hoverProvider"))
	assert_true(client.supports("completionProvider"))
	assert_false(client.supports("definitionProvider"))
	assert_eq(capabilities.size(), 1)
	assert_eq(capabilities[0].get("hoverProvider"), true)

	var methods: Array = []
	for message in _sent(client):
		methods.append(str(message.get("method", "")))
	assert_true(methods.has("initialized"))
	assert_true(methods.has("workspace/didChangeConfiguration"))

	client.free()


func test_initialize_error_reports_failure_and_stops() -> void:
	var client = _client()
	var failures: Array = []
	var exits: Array = []
	client.failed.connect(func(_sender, message: String) -> void: failures.append(message))
	client.exited.connect(func(_sender, unexpected: bool, _code: int) -> void: exits.append(unexpected))

	client._begin_initialize()
	_inject(client, {
		"jsonrpc": "2.0",
		"id": client._init_id,
		"error": {"code": -32603, "message": "No Python here"},
	})

	assert_false(client.running)
	assert_false(client.server_ready)
	assert_eq(failures.size(), 1)
	assert_true(str(failures[0]).contains("No Python here"))
	assert_eq(exits.size(), 1)
	assert_false(exits[0])

	client.free()


func test_server_settings_are_sent_after_initialize() -> void:
	var client = _client({"python": {"analysis": true}})
	client._begin_initialize()
	_inject(client, {"jsonrpc": "2.0", "id": client._init_id, "result": {"capabilities": {}}})

	var configuration := {}
	for message in _sent(client):
		if str(message.get("method", "")) == "workspace/didChangeConfiguration":
			configuration = message.get("params", {})
	assert_eq(configuration.get("settings", {}).get("python", {}).get("analysis"), true)

	client.free()


# ── REQUESTS / RESPONSES ────────────────────────────────────────────────────

func test_request_response_calls_the_callback_with_the_result() -> void:
	var client = _client()
	var replies: Array = []
	var id: int = client.send_request("textDocument/hover", {"textDocument": {"uri": "file:///a.py"}},
		func(result: Dictionary) -> void: replies.append(result))

	_inject(client, {"jsonrpc": "2.0", "id": id, "result": {"contents": "hello"}})

	assert_eq(replies.size(), 1)
	assert_true(replies[0].get("ok"))
	assert_eq(replies[0].get("result", {}).get("contents"), "hello")
	assert_true(client._pending.is_empty())
	client.free()


func test_error_responses_are_reported_to_the_callback() -> void:
	var client = _client()
	var replies: Array = []
	var id: int = client.send_request("textDocument/definition", {},
		func(result: Dictionary) -> void: replies.append(result))

	_inject(client, {
		"jsonrpc": "2.0",
		"id": id,
		"error": {"code": -32601, "message": "Not supported"},
	})

	assert_eq(replies.size(), 1)
	assert_false(replies[0].get("ok"))
	assert_eq(replies[0].get("code"), -32601)
	assert_eq(replies[0].get("error"), "Not supported")
	client.free()


func test_cancelling_a_request_notifies_the_server_and_fails_the_callback() -> void:
	var client = _client()
	var replies: Array = []
	var id: int = client.send_request("textDocument/completion", {},
		func(result: Dictionary) -> void: replies.append(result))

	client.cancel_request(id)

	assert_true(client._pending.is_empty())
	assert_eq(replies.size(), 1)
	assert_eq(replies[0].get("code"), -32800)

	var cancel := _last(client)
	assert_eq(cancel.get("method"), "$/cancelRequest")
	assert_eq(cancel.get("params", {}).get("id"), id)
	client.free()


func test_a_request_past_its_deadline_times_out_once() -> void:
	var client = _client()
	var replies: Array = []
	var id: int = client.send_request("textDocument/hover", {},
		func(result: Dictionary) -> void: replies.append(result))
	client._pending[id]["deadline"] = 0

	client._expire_requests()
	client._expire_requests()

	assert_true(client._pending.is_empty())
	assert_eq(replies.size(), 1)
	assert_false(replies[0].get("ok"))
	assert_true(str(replies[0].get("error")).contains("did not answer"))
	assert_true(client.log_text().contains("did not answer"))
	client.free()


# ── NOTIFICATIONS / SERVER REQUESTS ────────────────────────────────────────

func test_publish_diagnostics_is_forwarded_as_a_signal() -> void:
	var client = _client()
	var received: Array = []
	client.publish_diagnostics.connect(func(_sender, params: Variant) -> void: received.append(params))

	var params := {
		"uri": "file:///a.py",
		"diagnostics": [{"range": {"start": {"line": 1, "character": 2}}, "message": "bad"}],
	}
	_inject(client, {"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics", "params": params})

	assert_eq(received.size(), 1)
	assert_eq(received[0].get("uri"), "file:///a.py")
	client.free()


func test_stderr_is_captured_and_logged() -> void:
	var client = _client()
	var chunks: Array = []
	client.stderr_received.connect(func(_sender, text: String) -> void: chunks.append(text))

	client._handle_stderr("server warning\nmore\n".to_utf8_buffer())

	assert_eq(chunks.size(), 1)
	assert_true(client.stderr_text().contains("server warning"))
	assert_true(client.log_text().contains("[stderr] server warning"))
	client.free()


func test_workspace_configuration_request_is_answered_from_settings() -> void:
	var client = _client({"python": {"analysis": true}})
	_inject(client, {
		"jsonrpc": "2.0",
		"id": "config-1",
		"method": "workspace/configuration",
		"params": {"items": [{"section": "python"}, {"section": "missing"}]},
	})

	var response := _last(client)
	assert_eq(response.get("id"), "config-1")
	var values: Array = response.get("result", [])
	assert_eq(values.size(), 2)
	assert_eq(values[0].get("analysis"), true)
	assert_eq(values[1], {})
	client.free()


func test_apply_edit_request_is_forwarded_with_its_id() -> void:
	var client = _client()
	var requests: Array = []
	client.apply_edit_requested.connect(func(_sender, id: Variant, edit: Variant) -> void:
		requests.append({"id": id, "edit": edit})
	)

	_inject(client, {
		"jsonrpc": "2.0",
		"id": 44,
		"method": "workspace/applyEdit",
		"params": {"edit": {"changes": {"file:///a.py": []}}},
	})

	assert_eq(requests.size(), 1)
	assert_eq(requests[0].get("id"), 44)
	assert_true(requests[0].get("edit", {}).has("changes"))
	client.free()


func test_an_unknown_server_request_gets_a_method_not_found_error() -> void:
	var client = _client()

	_inject(client, {"jsonrpc": "2.0", "id": 9, "method": "fake/unknown", "params": {}})

	var response := _last(client)
	assert_eq(response.get("id"), 9)
	assert_eq(response.get("error", {}).get("code"), -32601)
	assert_true(str(response.get("error", {}).get("message")).contains("fake/unknown"))
	client.free()


func test_malformed_frames_are_logged_without_crashing() -> void:
	var client = _client()

	client._handle_stdout("Content-Length: nope\r\n\r\n".to_utf8_buffer())

	assert_true(client.log_text().contains("Malformed LSP header"))
	assert_true(client.running)
	client.free()


# ── SHUTDOWN ────────────────────────────────────────────────────────────────

func test_shutdown_asks_the_server_then_exits_normally() -> void:
	var client = _client()
	var exits: Array = []
	client.exited.connect(func(_sender, unexpected: bool, _code: int) -> void: exits.append(unexpected))
	client.server_ready = true

	client.stop()
	var shutdown := _last(client)
	assert_eq(shutdown.get("method"), "shutdown")
	assert_true(client._shutdown_requested)

	_inject(client, {"jsonrpc": "2.0", "id": shutdown.get("id"), "result": null})
	var exit_notice := _last(client)
	assert_eq(exit_notice.get("method"), "exit")

	client.force_stop()
	assert_false(client.running)
	assert_eq(exits.size(), 1)
	assert_false(exits[0])
	client.free()
