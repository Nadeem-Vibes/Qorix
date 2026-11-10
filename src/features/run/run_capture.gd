extends RefCounted

## Turns a detached PTY's byte stream into the text the Run panel shows.
##
## A captured run is wrapped in an invisible shell that prints a start marker
## before the user's program. Everything before that marker is terminal
## handshake noise (ConPTY's `ESC[?9001h` startup sequences, for example).
## An optional end marker carries an exit code, but the PTY's own exit status
## is the authoritative one: Windows cmd.exe expands `%ERRORLEVEL%` too early
## in compound commands, while PTY.exited reports the real child status.
##
## The parser is deliberately pure: feed it bytes, ask it for text. No node,
## no UI, no PTY, so every cleanup rule is covered by the headless suite.

const MAX_OUTPUT_CHARS := 1_000_000
const KEEP_HEAD_CHARS := 500_000
const KEEP_TAIL_CHARS := 500_000

const ANSI_PATTERN := "\\x1B\\][^\\x07\\x1B]*(?:\\x07|\\x1B\\\\)|\\x1B\\[[0-?]*[ -/]*[@-~]|\\x1B[@-_]"
const CONTROL_PATTERN := "[\\x00-\\x07\\x0B\\x0C\\x0E-\\x1F\\x7F]"

var token: String = ""
var start_marker: String = ""
var end_marker: String = ""

var _seen_start: bool = false
var _finished: bool = false
var _truncated: bool = false

var _pre_start: String = ""
var _body: String = ""
var _pending_bytes: PackedByteArray = PackedByteArray()
var _marker_exit_code: int = -1

var _ansi: RegEx
var _controls: RegEx


func _init(p_token: String = "") -> void:
	_ansi = RegEx.new()
	_ansi.compile(ANSI_PATTERN)
	_controls = RegEx.new()
	_controls.compile(CONTROL_PATTERN)
	if !p_token.is_empty():
		set_token(p_token)


func set_token(p_token: String) -> void:
	token = p_token
	start_marker = "__GRIDDY_RUN_START_%s__" % token
	end_marker = "__GRIDDY_RUN_EXIT_%s__" % token


static func make_token() -> String:
	# Alphanumeric only: the token is pasted into both cmd.exe and POSIX shell
	# snippets, so avoiding punctuation avoids a second layer of quoting.
	return "%d%d" % [Time.get_ticks_usec(), randi() % 100000]


## Feeds raw PTY bytes. Returns true when the visible output changed.
func feed_bytes(chunk: PackedByteArray) -> bool:
	if _finished or chunk.is_empty():
		return false

	_pending_bytes.append_array(chunk)
	var complete := _complete_utf8_prefix(_pending_bytes)
	if complete <= 0:
		return false

	var slice := _pending_bytes.slice(0, complete)
	_pending_bytes = _pending_bytes.slice(complete)
	return feed_string(slice.get_string_from_utf8())


## Feeds already-decoded text (useful for tests and for callers that already
## have a String).
func feed_string(text: String) -> bool:
	if _finished or text.is_empty():
		return false

	if !_seen_start:
		_pre_start += text
		var index := _find_line_marker(_pre_start, start_marker)
		if index < 0:
			# The marker is short. Keeping a generous tail prevents a marker
			# split across chunks from being forgotten without growing forever.
			if _pre_start.length() > start_marker.length() + 8192:
				_pre_start = _pre_start.substr(_pre_start.length() - (start_marker.length() + 1024))
			return false

		_seen_start = true
		var remainder := _pre_start.substr(index + start_marker.length())
		_pre_start = ""
		remainder = _trim_leading_newline(remainder)
		return _append_body(remainder)

	return _append_body(text)


func _append_body(text: String) -> bool:
	if text.is_empty():
		return false

	var before := output()
	var index := _find_line_marker(_body + text, end_marker)
	if index >= 0:
		var combined := _body + text
		_body = combined.substr(0, index)
		var after := combined.substr(index + end_marker.length())
		_marker_exit_code = _parse_exit_code(after)
		_finished = true
		return output() != before

	_body += text
	_cap_body()
	return output() != before


## Called when the PTY exits (or when the user stops the run). The PTY's exit
## status wins because it cannot be fooled by shell expansion rules.
func finish(exit_code: int = -1) -> void:
	if _finished and _marker_exit_code >= 0:
		_flush_pending()
		return

	_flush_pending()
	_finished = true
	if exit_code >= 0:
		_marker_exit_code = exit_code


func _flush_pending() -> void:
	if _pending_bytes.is_empty():
		return
	# Incomplete UTF-8 at process end is still worth showing; append a
	# replacement character for the truncated tail instead of handing invalid
	# bytes to the engine decoder (which logs a Unicode error). Complete bytes
	# before the tail are decoded normally.
	var complete := _complete_utf8_prefix(_pending_bytes)
	var text := ""
	if complete > 0:
		text = _pending_bytes.slice(0, complete).get_string_from_utf8()
	if complete < _pending_bytes.size():
		text += String.chr(0xFFFD)
	_pending_bytes.clear()
	if _seen_start:
		_body += text
		_cap_body()
		return
	_pre_start += text
	if !_seen_start:
		var index := _find_line_marker(_pre_start, start_marker)
		if index >= 0:
			_seen_start = true
			_body += _trim_leading_newline(_pre_start.substr(index + start_marker.length()))
		_pre_start = ""


func output() -> String:
	if !_seen_start:
		return ""
	return _clean(_body)


func raw_output() -> String:
	return _body


func exit_code() -> int:
	return _marker_exit_code


func has_started() -> bool:
	return _seen_start


func is_finished() -> bool:
	return _finished


func truncated() -> bool:
	return _truncated


func clear() -> void:
	_seen_start = false
	_finished = false
	_truncated = false
	_pre_start = ""
	_body = ""
	_pending_bytes = PackedByteArray()
	_marker_exit_code = -1


# ── CLEANUP ─────────────────────────────────────────────────────────────────

func _clean(raw: String) -> String:
	if raw.is_empty():
		return ""

	var text := _ansi.sub(raw, "", true)
	text = text.replace("\r\n", "\n")
	text = _controls.sub(text, "", true)

	var lines := text.split("\n")
	var out: Array[String] = []
	for line in lines:
		out.append(_apply_line_controls(line))
	return "\n".join(out)


## Applies the two controls a terminal would interpret in place: backspace
## removes the previous character, and a bare CR returns to column 0 (so a
## progress bar shows its latest state instead of every historical frame).
func _apply_line_controls(line: String) -> String:
	# Most lines contain neither control. Returning them untouched keeps a very
	# long single-line log linear instead of rebuilding it one character at a
	# time, which used to make a 1 MB minified file hang the panel.
	var text := line
	var carriage := text.rfind("\r")
	if carriage >= 0:
		text = text.substr(carriage + 1)
	if !text.contains("\b"):
		return text

	var out: Array[String] = []
	for i in range(text.length()):
		var character := text[i]
		if character == "\b":
			if !out.is_empty():
				out.pop_back()
		else:
			out.append(character)
	return "".join(out)


func _trim_leading_newline(text: String) -> String:
	if text.begins_with("\r\n"):
		return text.substr(2)
	if text.begins_with("\n") or text.begins_with("\r"):
		return text.substr(1)
	return text


func _find_line_marker(buffer: String, marker: String) -> int:
	# A captured run uses a non-interactive shell, so the command is never
	# echoed back and the first occurrence is always the real marker. The
	# token is random, so program output cannot collide with it by accident.
	return buffer.find(marker) if !marker.is_empty() else -1


func _parse_exit_code(text: String) -> int:
	var digits := ""
	for i in range(text.length()):
		var character := text[i]
		if character == "\r" or character == "\n":
			break
		if character >= "0" and character <= "9":
			digits += character
		elif digits.is_empty():
			continue
		else:
			break
	return int(digits) if !digits.is_empty() else -1


func _cap_body() -> void:
	if _body.length() <= MAX_OUTPUT_CHARS + 200_000:
		return

	var marker := "\n… [output truncated] …\n"
	_body = _body.substr(0, KEEP_HEAD_CHARS) + marker + _body.substr(_body.length() - KEEP_TAIL_CHARS)
	_truncated = true


## Number of bytes that form complete UTF-8 sequences. A rune split across two
## PTY reads must not be decoded as two replacement characters, or every
## non-ASCII filename in a traceback would be corrupted.
static func _complete_utf8_prefix(bytes: PackedByteArray) -> int:
	var i := 0
	while i < bytes.size():
		var byte := bytes[i]
		var needed := 0
		if byte < 0x80:
			needed = 0
		elif (byte & 0xE0) == 0xC0:
			needed = 1
		elif (byte & 0xF0) == 0xE0:
			needed = 2
		elif (byte & 0xF8) == 0xF0:
			needed = 3
		else:
			# Invalid lead byte: let the decoder produce a replacement char
			# for this byte and continue with the next one.
			i += 1
			continue

		if i + needed >= bytes.size():
			break
		i += needed + 1
	return i