extends RefCounted

## Framing and schema helpers for the Debug Adapter Protocol.
##
## DAP uses the same `Content-Length` framing as LSP but a different message
## schema: every message carries a `seq` and `type` (request, response or
## event), responses point at their request with `request_seq`, and there is no
## `jsonrpc` field. Framing is delegated to LspProtocol so the byte-level rules
## are tested once; the schema helpers below are DAP-only.

const LspProtocol = preload("res://src/features/lsp/lsp_protocol.gd")

const MAX_BODY_BYTES := 32 * 1024 * 1024


## Encodes one DAP message with a Content-Length header.
static func encode(message: Dictionary) -> PackedByteArray:
	return LspProtocol.encode(message)


static func request(seq: int, command: String, arguments: Variant = null) -> Dictionary:
	var message := {"seq": seq, "type": "request", "command": command}
	message["arguments"] = arguments if arguments != null else {}
	return message


static func response(seq: int, request_seq: int, command: String, success: bool = true,
		body: Variant = null, message: String = "") -> Dictionary:
	var out := {
		"seq": seq,
		"type": "response",
		"request_seq": request_seq,
		"success": success,
		"command": command,
	}
	if body != null:
		out["body"] = body
	if !message.is_empty():
		out["message"] = message
	return out


static func event(seq: int, event_name: String, body: Variant = null) -> Dictionary:
	var out := {"seq": seq, "type": "event", "event": event_name}
	if body != null:
		out["body"] = body
	return out


static func is_request(message: Dictionary) -> bool:
	return str(message.get("type", "")) == "request" and message.has("command") and message.has("seq")


static func is_response(message: Dictionary) -> bool:
	return str(message.get("type", "")) == "response" and message.has("request_seq")


static func is_event(message: Dictionary) -> bool:
	return str(message.get("type", "")) == "event" and message.has("event")


## Result of one response: {ok, body, error, command, request_seq, message}.
## DAP encodes failures with `success: false` plus a human-readable `message`.
static func response_result(message: Dictionary) -> Dictionary:
	var command := str(message.get("command", ""))
	var request_seq := int(message.get("request_seq", -1))
	if !bool(message.get("success", false)):
		var text := str(message.get("message", "")).strip_edges()
		if text.is_empty():
			text = "The debug adapter rejected %s." % command
		return {
			"ok": false,
			"body": {},
			"error": text,
			"command": command,
			"request_seq": request_seq,
			"message": message,
		}
	var body: Variant = message.get("body")
	return {
		"ok": true,
		"body": body if body is Dictionary else {},
		"error": "",
		"command": command,
		"request_seq": request_seq,
		"message": message,
	}


## Incremental framing buffer. Call feed() with each TCP chunk and handle every
## returned message before the next call.
var _parser = LspProtocol.new()


func reset() -> void:
	_parser.reset()


func buffered_bytes() -> int:
	return _parser.buffered_bytes()


## Appends a chunk and returns {messages: Array[Dictionary], errors: Array[String]}.
func feed(chunk: PackedByteArray) -> Dictionary:
	var parsed: Dictionary = _parser.feed(chunk)
	var errors: Array[String] = []
	for error in parsed.get("errors", []):
		errors.append(str(error).replace("LSP", "DAP"))
	return {
		"messages": parsed.get("messages", []),
		"errors": errors,
	}
