extends "res://tests/support/test_case.gd"

## DAP framing and schema helpers. The byte-level Content-Length rules are
## shared with LSP and already covered by test_lsp_protocol; these checks pin
## the DAP-specific envelope: seq/type, request_seq, success and no jsonrpc.

const Protocol = preload("res://src/features/debug/dap_protocol.gd")


func _roundtrip(message: Dictionary) -> Dictionary:
	var parser = Protocol.new()
	var parsed: Dictionary = parser.feed(Protocol.encode(message))
	var messages: Array = parsed.get("messages", [])
	assert_eq(messages.size(), 1, "one frame should decode")
	return messages[0] if !messages.is_empty() else {}


func test_a_request_round_trips_with_dap_fields() -> void:
	var original: Dictionary = Protocol.request(7, "initialize", {"clientID": "griddycode"})
	var decoded := _roundtrip(original)

	assert_eq(decoded.get("seq"), 7)
	assert_eq(decoded.get("type"), "request")
	assert_eq(decoded.get("command"), "initialize")
	assert_eq(decoded.get("arguments").get("clientID"), "griddycode")
	assert_false(decoded.has("jsonrpc"), "DAP messages must not carry a jsonrpc field")


func test_a_request_without_arguments_sends_an_empty_object() -> void:
	var decoded := _roundtrip(Protocol.request(1, "configurationDone"))
	assert_eq(decoded.get("arguments"), {})


func test_a_response_points_at_its_request() -> void:
	var decoded := _roundtrip(Protocol.response(8, 7, "initialize", true, {"supportsConfigurationDoneRequest": true}))
	assert_eq(decoded.get("type"), "response")
	assert_eq(decoded.get("request_seq"), 7)
	assert_eq(decoded.get("success"), true)
	assert_eq(decoded.get("body").get("supportsConfigurationDoneRequest"), true)
	assert_false(decoded.has("message"), "an empty response message is omitted")


func test_a_failed_response_keeps_the_message() -> void:
	var decoded := _roundtrip(Protocol.response(2, 1, "launch", false, null, "program does not exist"))
	assert_eq(decoded.get("success"), false)
	assert_eq(decoded.get("message"), "program does not exist")
	assert_false(decoded.has("body"))


func test_an_event_round_trips() -> void:
	var decoded := _roundtrip(Protocol.event(4, "stopped", {"reason": "breakpoint", "threadId": 1}))
	assert_eq(decoded.get("type"), "event")
	assert_eq(decoded.get("event"), "stopped")
	assert_eq(decoded.get("body").get("threadId"), 1)


func test_message_kind_detection_is_strict() -> void:
	assert_true(Protocol.is_request({"seq": 1, "type": "request", "command": "pause"}))
	assert_false(Protocol.is_request({"type": "request"}))
	assert_true(Protocol.is_response({"type": "response", "request_seq": 1}))
	assert_false(Protocol.is_response({"type": "event", "event": "stopped"}))
	assert_true(Protocol.is_event({"type": "event", "event": "stopped"}))
	assert_false(Protocol.is_event({"type": "response", "request_seq": 1}))
	assert_false(Protocol.is_event({"type": "event"}), "an event needs a name")


func test_a_successful_response_body_is_normalized() -> void:
	var result: Dictionary = Protocol.response_result({
		"type": "response", "request_seq": 3, "command": "stackTrace",
		"success": true, "body": {"stackFrames": []},
	})
	assert_true(result.get("ok"))
	assert_eq(result.get("command"), "stackTrace")
	assert_eq(result.get("request_seq"), 3)
	assert_eq(result.get("body").get("stackFrames"), [])

	var no_body: Dictionary = Protocol.response_result({
		"type": "response", "request_seq": 4, "command": "continue", "success": true,
	})
	assert_true(no_body.get("ok"))
	assert_eq(no_body.get("body"), {}, "a missing body becomes an empty object")


func test_a_failed_response_becomes_a_readable_error() -> void:
	var result: Dictionary = Protocol.response_result({
		"type": "response", "request_seq": 5, "command": "setBreakpoints",
		"success": false, "message": "  no source  ",
	})
	assert_false(result.get("ok"))
	assert_eq(result.get("error"), "no source")
	assert_eq(result.get("command"), "setBreakpoints")

	var fallback: Dictionary = Protocol.response_result({
		"type": "response", "request_seq": 6, "command": "variables", "success": false,
	})
	assert_eq(fallback.get("error"), "The debug adapter rejected variables.")


func test_frames_split_across_chunks_are_reassembled() -> void:
	var parser = Protocol.new()
	var bytes: PackedByteArray = Protocol.encode(Protocol.event(1, "output", {"output": "hello"}))
	var first: Dictionary = parser.feed(bytes.slice(0, 11))
	assert_eq(first.get("messages").size(), 0, "a partial header must not decode")
	assert_true(parser.buffered_bytes() > 0)

	var second: Dictionary = parser.feed(bytes.slice(11, bytes.size()))
	assert_eq(second.get("messages").size(), 1)
	var message: Dictionary = second.get("messages")[0]
	assert_eq(message.get("event"), "output")
	assert_eq(message.get("body").get("output"), "hello")
	assert_eq(parser.buffered_bytes(), 0)


func test_multiple_frames_in_one_chunk_are_all_returned() -> void:
	var parser = Protocol.new()
	var chunk: PackedByteArray = Protocol.encode(Protocol.event(1, "initialized", {}))
	chunk.append_array(Protocol.encode(Protocol.event(2, "stopped", {"reason": "breakpoint"})))

	var parsed: Dictionary = parser.feed(chunk)
	var messages: Array = parsed.get("messages", [])
	assert_eq(messages.size(), 2)
	assert_eq(messages[0].get("event"), "initialized")
	assert_eq(messages[1].get("event"), "stopped")


func test_reset_drops_a_partial_frame() -> void:
	var parser = Protocol.new()
	var bytes: PackedByteArray = Protocol.encode(Protocol.event(1, "output", {"output": "x"}))
	parser.feed(bytes.slice(0, 8))
	assert_true(parser.buffered_bytes() > 0)
	parser.reset()
	assert_eq(parser.buffered_bytes(), 0)

	var parsed: Dictionary = parser.feed(Protocol.encode(Protocol.event(2, "terminated", {})))
	assert_eq(parsed.get("messages").size(), 1)


func test_framing_errors_are_reported_as_dap_errors() -> void:
	var parser = Protocol.new()
	var parsed: Dictionary = parser.feed("Content-Length: nope\r\n\r\n".to_utf8_buffer())
	var errors: Array = parsed.get("errors", [])
	assert_true(errors.size() > 0, "a bad Content-Length should be reported")
	if !errors.is_empty():
		assert_false(str(errors[0]).contains("LSP"), "framing errors should refer to DAP")
