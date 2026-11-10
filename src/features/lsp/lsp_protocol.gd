extends RefCounted

## JSON-RPC 2.0 framing for the Language Server Protocol.
##
## A language server speaks a byte stream, not messages: every payload is
## preceded by `Content-Length: <bytes>` and a blank line. This class owns the
## incremental parser so the client never has to guess where a message starts.
##
## It is deliberately pure (RefCounted, no nodes, no process) so the rules can
## be tested headlessly:
##   - headers may arrive split across reads,
##   - several messages may arrive in one read,
##   - the body length is UTF-8 bytes, not characters,
##   - malformed headers report an error instead of desynchronising silently.

const MAX_BODY_BYTES := 32 * 1024 * 1024


## Encodes one JSON-RPC message with a Content-Length header.
static func encode(message: Dictionary) -> PackedByteArray:
	var body := JSON.stringify(message).to_utf8_buffer()
	var header := ("Content-Length: %d\r\n\r\n" % body.size()).to_utf8_buffer()
	return header + body


## A request that expects exactly one response.
static func request(id: Variant, method: String, params: Variant = null) -> Dictionary:
	var message := {"jsonrpc": "2.0", "id": id, "method": method}
	if params != null:
		message["params"] = params
	return message


## A one-way message. Notifications never receive a response.
static func notification_message(method: String, params: Variant = null) -> Dictionary:
	var message := {"jsonrpc": "2.0", "method": method}
	if params != null:
		message["params"] = params
	return message


## A successful response to a server-initiated request.
static func response(id: Variant, result: Variant = null) -> Dictionary:
	return {"jsonrpc": "2.0", "id": id, "result": result}


## An error response to a server-initiated request.
static func error_response(id: Variant, code: int, message: String, data: Variant = null) -> Dictionary:
	var error := {"code": code, "message": message}
	if data != null:
		error["data"] = data
	return {"jsonrpc": "2.0", "id": id, "error": error}


static func is_request(message: Dictionary) -> bool:
	return message.has("id") and message.has("method")


static func is_response(message: Dictionary) -> bool:
	return message.has("id") and !message.has("method") and (message.has("result") or message.has("error"))


static func is_notification(message: Dictionary) -> bool:
	return !message.has("id") and message.has("method")


## Result of one parsed response: {ok, result, error}.
static func response_result(message: Dictionary) -> Dictionary:
	if message.has("error"):
		var error: Variant = message.get("error")
		var text := "Language server error"
		var code := 0
		if error is Dictionary:
			text = str(error.get("message", text))
			code = int(error.get("code", 0))
		return {"ok": false, "result": null, "error": text, "code": code}
	return {"ok": true, "result": message.get("result"), "error": "", "code": 0}


## Incremental framing buffer. Call feed() with each pipe chunk and handle every
## returned message before the next feed().
var _buffer := PackedByteArray()


func reset() -> void:
	_buffer = PackedByteArray()


func buffered_bytes() -> int:
	return _buffer.size()


## Appends a chunk and returns every complete frame currently available.
## Returns {messages: Array[Dictionary], errors: Array[String]}.
func feed(chunk: PackedByteArray) -> Dictionary:
	if !chunk.is_empty():
		_buffer.append_array(chunk)

	var messages: Array = []
	var errors: Array[String] = []

	while true:
		var separator := _find_header_end()
		if separator < 0:
			break

		var header := _buffer.slice(0, separator).get_string_from_utf8()
		var length := _content_length(header)
		if length < 0:
			errors.append("Malformed LSP header: " + header.replace("\r\n", " | "))
			_buffer = _buffer.slice(separator + _separator_size(separator))
			continue
		if length > MAX_BODY_BYTES:
			errors.append("LSP message is too large (%d bytes)." % length)
			_buffer = _buffer.slice(separator + _separator_size(separator))
			continue

		var body_start := separator + _separator_size(separator)
		if _buffer.size() < body_start + length:
			# The headers are complete but the body is still arriving.
			break

		var body := _buffer.slice(body_start, body_start + length).get_string_from_utf8()
		_buffer = _buffer.slice(body_start + length)

		var parsed: Variant = JSON.parse_string(body)
		if typeof(parsed) != TYPE_DICTIONARY:
			errors.append("LSP body is not a JSON object.")
			continue
		messages.append(parsed)

	return {"messages": messages, "errors": errors}


## Index of the first byte of the blank line that ends the header block.
func _find_header_end() -> int:
	var limit := _buffer.size()
	for i in range(limit - 3):
		if _buffer[i] == 13 and _buffer[i + 1] == 10 and _buffer[i + 2] == 13 and _buffer[i + 3] == 10:
			return i
	for i in range(limit - 1):
		if _buffer[i] == 10 and _buffer[i + 1] == 10:
			return i
	return -1


func _separator_size(separator: int) -> int:
	if separator + 3 < _buffer.size() \
		and _buffer[separator] == 13 and _buffer[separator + 1] == 10 \
		and _buffer[separator + 2] == 13 and _buffer[separator + 3] == 10:
		return 4
	return 2


## Reads a Content-Length header case-insensitively. -1 means missing/invalid.
static func _content_length(header: String) -> int:
	for raw_line in header.split("\n"):
		var line := raw_line.strip_edges()
		if line.is_empty():
			continue
		var colon := line.find(":")
		if colon < 0:
			continue
		var name := line.substr(0, colon).strip_edges().to_lower()
		if name != "content-length":
			continue
		var value := line.substr(colon + 1).strip_edges()
		if !value.is_valid_int():
			return -1
		var length := int(value)
		return length if length >= 0 else -1
	return -1
