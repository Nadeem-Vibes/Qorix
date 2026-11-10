extends "res://tests/support/test_case.gd"

const Protocol = preload("res://src/features/lsp/lsp_protocol.gd")


func _message(text: String) -> PackedByteArray:
	return Protocol.encode({"jsonrpc": "2.0", "method": "test", "params": {"text": text}})


func _header_end(frame: PackedByteArray) -> int:
	for i in range(frame.size() - 3):
		if frame[i] == 13 and frame[i + 1] == 10 and frame[i + 2] == 13 and frame[i + 3] == 10:
			return i + 4
	return -1


func _feed_all(chunks: Array) -> Dictionary:
	var parser = Protocol.new()
	var messages: Array = []
	var errors: Array = []
	for chunk in chunks:
		var result: Dictionary = parser.feed(chunk)
		messages.append_array(result["messages"])
		errors.append_array(result["errors"])
	return {"messages": messages, "errors": errors, "parser": parser}


func test_encode_uses_utf8_byte_length() -> void:
	var payload := "héllo 🌍"
	var frame := Protocol.encode({"jsonrpc": "2.0", "method": "x", "params": {"text": payload}})
	var separator := _header_end(frame) - 4
	var header := frame.slice(0, separator).get_string_from_utf8()
	var body_size := frame.size() - separator - 4
	var declared := int(header.substr("Content-Length: ".length()))

	assert_eq(declared, body_size)
	assert_eq(body_size, JSON.stringify({"jsonrpc": "2.0", "method": "x", "params": {"text": payload}}).to_utf8_buffer().size())
	assert_true(declared > payload.to_utf8_buffer().size())


func test_request_and_notification_shapes() -> void:
	var request := Protocol.request(7, "textDocument/hover", {"x": 1})
	var note := Protocol.notification_message("initialized", {})
	var response := Protocol.response("abc", {"ok": true})
	var error := Protocol.error_response(3, -32601, "nope")

	assert_eq(request.get("id"), 7)
	assert_eq(request.get("method"), "textDocument/hover")
	assert_true(Protocol.is_request(request))
	assert_false(Protocol.is_notification(request))
	assert_true(Protocol.is_notification(note))
	assert_false(Protocol.is_request(note))
	assert_true(Protocol.is_response(response))
	assert_true(Protocol.is_response(error))
	assert_false(Protocol.is_response(request))
	assert_eq(error.get("error", {}).get("code"), -32601)


func test_response_result_reports_errors() -> void:
	var ok := Protocol.response_result({"id": 1, "result": {"value": 2}})
	var bad := Protocol.response_result({"id": 1, "error": {"code": -32000, "message": "boom"}})

	assert_true(ok.get("ok"))
	assert_eq(ok.get("result", {}).get("value"), 2)
	assert_false(bad.get("ok"))
	assert_eq(bad.get("code"), -32000)
	assert_eq(bad.get("error"), "boom")


func test_single_frame_round_trip() -> void:
	var original := {"jsonrpc": "2.0", "id": 1, "result": {"hello": "world"}}
	var result := _feed_all([Protocol.encode(original)])

	assert_eq(result["errors"].size(), 0)
	assert_eq(result["messages"].size(), 1)
	var decoded: Dictionary = result["messages"][0]
	assert_eq(decoded.get("jsonrpc"), "2.0")
	assert_eq(int(decoded.get("id", 0)), 1)
	assert_eq(decoded.get("result"), {"hello": "world"})


func test_headers_split_across_reads() -> void:
	var frame := _message("split")
	var result := _feed_all([frame.slice(0, 5), frame.slice(5, 20), frame.slice(20)])

	assert_eq(result["errors"].size(), 0)
	assert_eq(result["messages"].size(), 1)
	assert_eq(result["messages"][0].get("params", {}).get("text"), "split")


func test_body_split_within_one_message() -> void:
	var frame := _message("body")
	var header_end := _header_end(frame)
	var result := _feed_all([frame.slice(0, header_end + 2), frame.slice(header_end + 2)])

	assert_eq(result["messages"].size(), 1)
	assert_eq(result["parser"].buffered_bytes(), 0)


func test_multiple_messages_in_one_chunk() -> void:
	var chunk := _message("one") + _message("two") + _message("three")
	var result := _feed_all([chunk])

	assert_eq(result["messages"].size(), 3)
	assert_eq(result["messages"][2].get("params", {}).get("text"), "three")
	assert_eq(result["errors"].size(), 0)


func test_lf_only_header_is_accepted() -> void:
	var body := JSON.stringify({"jsonrpc": "2.0", "method": "x"})
	var frame := ("Content-Length: %d\n\n" % body.to_utf8_buffer().size()).to_utf8_buffer() + body.to_utf8_buffer()
	var result := _feed_all([frame])

	assert_eq(result["messages"].size(), 1)
	assert_eq(result["errors"].size(), 0)


func test_malformed_header_is_reported_and_parser_recovers() -> void:
	var good := _message("after")
	var broken := "No Length Here\r\n\r\n".to_utf8_buffer()
	var result := _feed_all([broken, good])

	assert_eq(result["errors"].size(), 1)
	assert_eq(result["messages"].size(), 1)
	assert_eq(result["messages"][0].get("params", {}).get("text"), "after")


func test_non_object_body_is_reported() -> void:
	var body := "[]".to_utf8_buffer()
	var frame := ("Content-Length: %d\r\n\r\n" % body.size()).to_utf8_buffer() + body
	var result := _feed_all([frame])

	assert_eq(result["messages"].size(), 0)
	assert_eq(result["errors"].size(), 1)


func test_oversized_body_is_rejected_without_waiting() -> void:
	var parser = Protocol.new()
	var header := ("Content-Length: %d\r\n\r\n" % (Protocol.MAX_BODY_BYTES + 1)).to_utf8_buffer()
	var result: Dictionary = parser.feed(header)

	assert_eq(result["messages"].size(), 0)
	assert_eq(result["errors"].size(), 1)
	assert_eq(parser.buffered_bytes(), 0)


func test_content_length_header_is_case_insensitive() -> void:
	var body := JSON.stringify({"jsonrpc": "2.0", "method": "x"})
	var frame := ("content-length: %d\r\n\r\n" % body.to_utf8_buffer().size()).to_utf8_buffer() + body.to_utf8_buffer()
	var result := _feed_all([frame])

	assert_eq(result["messages"].size(), 1)


func test_incomplete_headers_wait_for_more_data() -> void:
	var parser = Protocol.new()
	var partial := "Content-Length: 2\r\n".to_utf8_buffer()
	var result: Dictionary = parser.feed(partial)

	assert_eq(result["messages"].size(), 0)
	assert_eq(result["errors"].size(), 0)
	assert_eq(parser.buffered_bytes(), partial.size())


func test_reset_discards_partial_data() -> void:
	var parser = Protocol.new()
	parser.feed("Content-Length: 100\r\n\r\n{\"a\"".to_utf8_buffer())
	assert_true(parser.buffered_bytes() > 0)
	parser.reset()

	assert_eq(parser.buffered_bytes(), 0)
	assert_eq(parser.feed(_message("fresh"))["messages"].size(), 1)
