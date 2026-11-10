extends RefCounted

## Pure text/edit rules shared by the LSP client, the editor view and the tests.
##
## The Language Server Protocol counts positions in UTF-16 code units and names
## files with file:// URIs. Godot strings count Unicode code points and the
## editor works with native paths. Every conversion in one direction lives here
## so a surrogate pair or a Windows drive letter can never be translated one
## way in the client and another way in the UI.

const MAX_DIAGNOSTIC_LINES := 400


# ── URIs ────────────────────────────────────────────────────────────────────

## Converts an absolute native path into a file:// URI.
static func path_to_uri(path: String) -> String:
	if path.is_empty():
		return ""
	if path.begins_with("file://"):
		return path

	var normalized := path.replace("\\", "/")
	if normalized.begins_with("res://") or normalized.begins_with("user://"):
		normalized = ProjectSettings.globalize_path(normalized).replace("\\", "/")

	if normalized.begins_with("//"):
		# UNC share: file://server/share, not file:////server/share.
		return "file:" + _percent_encode(normalized)

	if normalized.length() >= 2 and normalized[1] == ":":
		normalized = "/" + normalized
	elif !normalized.begins_with("/"):
		normalized = "/" + normalized

	return "file://" + _percent_encode(normalized)


## Converts a file:// URI back into a native path with forward slashes.
static func uri_to_path(uri: String) -> String:
	var text := uri.strip_edges()
	if text.is_empty():
		return ""
	if text.begins_with("file://"):
		text = text.substr(7)
	elif text.begins_with("file:"):
		text = text.substr(5)

	# A URI may carry a query or fragment; neither belongs in a path.
	var cut := text.find("?")
	var hash_cut := text.find("#")
	if cut >= 0:
		text = text.substr(0, cut)
	if hash_cut >= 0 and (cut < 0 or hash_cut < cut):
		text = text.substr(0, hash_cut)

	text = _percent_decode(text)
	if text.begins_with("/") and text.length() >= 3 and text[2] == ":" \
		and _is_ascii_letter(text[1]):
		text = text.substr(1)
	elif !text.begins_with("/") and !(text.length() >= 2 and text[1] == ":"):
		# file://server/share has an authority component.
		text = "//" + text

	return text.replace("\\", "/")


static func _is_ascii_letter(character: String) -> bool:
	if character.length() != 1:
		return false
	var code := character.unicode_at(0)
	return (code >= 65 and code <= 90) or (code >= 97 and code <= 122)


static func _percent_encode(text: String) -> String:
	var out := ""
	for i in range(text.length()):
		var character := text[i]
		if _uri_safe(character):
			out += character
			continue
		var bytes := character.to_utf8_buffer()
		for byte in bytes:
			out += "%%%02X" % int(byte)
	return out


static func _uri_safe(character: String) -> bool:
	if character.length() != 1:
		return false
	var code := character.unicode_at(0)
	if code >= 65 and code <= 90:
		return true
	if code >= 97 and code <= 122:
		return true
	if code >= 48 and code <= 57:
		return true
	return character in ["-", "_", ".", "~", "/", ":"]


static func _percent_decode(text: String) -> String:
	var bytes := PackedByteArray()
	var i := 0
	while i < text.length():
		var character := text[i]
		if character == "%" and i + 2 < text.length():
			var hex := text.substr(i + 1, 2)
			if hex.is_valid_hex_number():
				bytes.append(hex.hex_to_int())
				i += 3
				continue
		var encoded := character.to_utf8_buffer()
		bytes.append_array(encoded)
		i += 1
	return bytes.get_string_from_utf8()


# ── UTF-16 POSITIONS ───────────────────────────────────────────────────────

static func utf16_length(text: String) -> int:
	var units := 0
	for i in range(text.length()):
		units += 2 if text.unicode_at(i) > 0xFFFF else 1
	return units


## Converts a UTF-16 code-unit column into a Godot code-point column.
static func utf16_to_column(line: String, utf16_column: int) -> int:
	if utf16_column <= 0:
		return 0
	var units := 0
	for i in range(line.length()):
		if units >= utf16_column:
			return i
		var width := 2 if line.unicode_at(i) > 0xFFFF else 1
		if units + width > utf16_column:
			return i
		units += width
	return line.length()


## Converts a Godot code-point column into a UTF-16 code-unit column.
static func column_to_utf16(line: String, column: int) -> int:
	var end := clampi(column, 0, line.length())
	var units := 0
	for i in range(end):
		units += 2 if line.unicode_at(i) > 0xFFFF else 1
	return units


static func line_starts(text: String) -> PackedInt32Array:
	var starts := PackedInt32Array([0])
	for i in range(text.length()):
		if text[i] == "\n":
			starts.append(i + 1)
	return starts


static func line_at(text: String, line: int) -> String:
	var lines := text.split("\n")
	if line < 0 or line >= lines.size():
		return ""
	return str(lines[line])


## Converts an LSP position into an editor caret position and a code-point
## index. Out-of-range positions clamp to the end of the document, exactly as
## the protocol requires for edits appended after the final newline.
static func position_to_caret(text: String, line: int, utf16_character: int) -> Dictionary:
	var starts := line_starts(text)
	var safe_line := clampi(line, 0, starts.size() - 1)
	if line >= starts.size():
		return {"line": starts.size() - 1, "column": 0, "index": text.length()}

	var start: int = starts[safe_line]
	var end: int = text.length()
	if safe_line + 1 < starts.size():
		end = starts[safe_line + 1] - 1
	if end < start:
		end = start
	var line_text := text.substr(start, end - start)
	var column := utf16_to_column(line_text, utf16_character)
	return {"line": safe_line, "column": column, "index": start + column}


static func position_to_index(text: String, line: int, utf16_character: int) -> int:
	return int(position_to_caret(text, line, utf16_character).get("index", text.length()))


static func caret_to_position(text: String, line: int, column: int) -> Dictionary:
	var starts := line_starts(text)
	var safe_line := clampi(line, 0, starts.size() - 1)
	var start: int = starts[safe_line]
	var line_text := line_at(text, safe_line)
	return {
		"line": safe_line,
		"character": column_to_utf16(line_text, column),
	}


# ── TEXT EDITS ──────────────────────────────────────────────────────────────

## Applies LSP TextEdit[] to a plain string. Returns
## {ok, text, applied, error}. Overlapping edits are rejected rather than
## applied in an arbitrary order, which is how a rename could corrupt a file.
static func apply_text_edits(text: String, edits: Array) -> Dictionary:
	var prepared: Array = []
	var order := 0

	for raw in edits:
		if !(raw is Dictionary):
			continue
		var edit: Dictionary = raw
		var range: Variant = edit.get("range", {})
		if !(range is Dictionary):
			return {"ok": false, "text": text, "applied": 0, "error": "An edit has no range."}

		var start: Variant = range.get("start", {})
		var end: Variant = range.get("end", {})
		if !(start is Dictionary) or !(end is Dictionary):
			return {"ok": false, "text": text, "applied": 0, "error": "An edit range is incomplete."}

		var start_index := position_to_index(text, int(start.get("line", 0)), int(start.get("character", 0)))
		var end_index := position_to_index(text, int(end.get("line", 0)), int(end.get("character", 0)))
		if end_index < start_index:
			var swap := start_index
			start_index = end_index
			end_index = swap

		prepared.append({
			"start": start_index,
			"end": end_index,
			"new_text": str(edit.get("newText", "")),
			"order": order,
		})
		order += 1

	if prepared.is_empty():
		return {"ok": true, "text": text, "applied": 0, "error": ""}

	prepared.sort_custom(func(a, b) -> bool:
		if int(a.start) != int(b.start):
			return int(a.start) > int(b.start)
		if int(a.end) != int(b.end):
			return int(a.end) > int(b.end)
		return int(a.order) > int(b.order)
	)

	var last_start := text.length() + 1
	for edit in prepared:
		var start := int(edit.start)
		var end := int(edit.end)
		if end > last_start:
			return {
				"ok": false,
				"text": text,
				"applied": 0,
				"error": "The language server returned overlapping edits.",
			}
		last_start = start

	var result := text
	for edit in prepared:
		result = result.substr(0, int(edit.start)) + str(edit.new_text) + result.substr(int(edit.end))

	return {"ok": true, "text": result, "applied": prepared.size(), "error": ""}


## Converts TextEdit[] into caret-space edits for TextEdit.insert_text() /
## remove_text(). Positions are resolved against the supplied original text.
static func edits_for_view(text: String, edits: Array) -> Array:
	var out: Array = []
	for raw in edits:
		if !(raw is Dictionary):
			continue
		var edit: Dictionary = raw
		var range: Variant = edit.get("range", {})
		if !(range is Dictionary):
			continue
		var start: Variant = range.get("start", {})
		var end: Variant = range.get("end", {})
		if !(start is Dictionary) or !(end is Dictionary):
			continue
		var from := position_to_caret(text, int(start.get("line", 0)), int(start.get("character", 0)))
		var to := position_to_caret(text, int(end.get("line", 0)), int(end.get("character", 0)))
		out.append({
			"from_line": int(from.line),
			"from_column": int(from.column),
			"to_line": int(to.line),
			"to_column": int(to.column),
			"new_text": str(edit.get("newText", "")),
		})
	return out


## Normalizes `changes` and `documentChanges` into one uri -> edits map.
## Resource operations (create/rename/delete) are reported but not applied;
## no LSP feature in Qorix creates files.
static func normalize_workspace_edit(edit: Variant) -> Dictionary:
	var files: Dictionary = {}
	var operations: Array = []
	var errors: Array[String] = []

	if !(edit is Dictionary):
		return {"ok": false, "files": files, "operations": operations, "errors": ["The workspace edit is not an object."]}

	var source: Dictionary = edit
	var changes: Variant = source.get("changes", {})
	if changes is Dictionary:
		for raw_uri in changes.keys():
			var uri := str(raw_uri)
			var edits: Variant = changes[raw_uri]
			if edits is Array:
				files[uri] = _merge_edits(files.get(uri, []), edits)

	var document_changes: Variant = source.get("documentChanges", [])
	if document_changes is Array:
		for item in document_changes:
			if !(item is Dictionary):
				continue
			var change: Dictionary = item
			if change.has("textDocument") and change.get("edits") is Array:
				var document: Variant = change.get("textDocument", {})
				var uri := str(document.get("uri", "")) if document is Dictionary else ""
				if !uri.is_empty():
					files[uri] = _merge_edits(files.get(uri, []), change["edits"])
			elif change.has("kind"):
				operations.append(change.duplicate(true))

	return {"ok": errors.is_empty(), "files": files, "operations": operations, "errors": errors}


static func _merge_edits(existing: Variant, extra: Array) -> Array:
	var out: Array = []
	if existing is Array:
		out.append_array(existing)
	out.append_array(extra)
	return out


## Applies a WorkspaceEdit to a uri -> text map. Returns
## {ok, texts, errors, applied_uris}.
static func apply_to_texts(workspace_edit: Variant, texts: Dictionary) -> Dictionary:
	var normalized := normalize_workspace_edit(workspace_edit)
	if !bool(normalized.get("ok", false)):
		return {
			"ok": false,
			"texts": texts,
			"errors": normalized.get("errors", []),
			"applied_uris": [],
		}

	var out: Dictionary = texts.duplicate(true)
	var errors: Array = []
	var applied: Array = []
	var files: Dictionary = normalized.get("files", {})

	for raw_uri in files.keys():
		var uri := str(raw_uri)
		if !out.has(uri):
			errors.append("No text is available for " + uri)
			continue
		var result := apply_text_edits(str(out[uri]), files[raw_uri])
		if !bool(result.get("ok", false)):
			errors.append("%s: %s" % [uri, str(result.get("error", "edit failed"))])
			continue
		out[uri] = result["text"]
		applied.append(uri)

	return {
		"ok": errors.is_empty(),
		"texts": out,
		"errors": errors,
		"applied_uris": applied,
	}


# ── MARKDOWN / HOVER ───────────────────────────────────────────────────────

## Converts the Markdown a language server sends into BBCode for a
## RichTextLabel. Code fences, inline code, links, headings and emphasis are
## supported; everything else is escaped so a document cannot inject tags.
static func markdown_to_bbcode(markdown: String, max_lines: int = 120) -> String:
	var text := str(markdown).replace("\r\n", "\n").replace("\r", "\n")
	var lines := text.split("\n")
	var shown := lines.size()
	if max_lines > 0 and lines.size() > max_lines:
		lines = lines.slice(0, max_lines)
		shown = lines.size()

	var out: Array[String] = []
	var in_code := false

	for raw_line in lines:
		var line := str(raw_line)
		if line.strip_edges().begins_with("```"):
			if in_code:
				out.append("[/code]")
				in_code = false
			else:
				if !out.is_empty() and out[out.size() - 1] != "":
					out.append("")
				out.append("[code]")
				in_code = true
			continue

		if in_code:
			out.append(_escape_bbcode(line))
			continue

		var stripped := line.strip_edges()
		if stripped == "---" or stripped == "***" or stripped == "___":
			out.append("[color=#7f8c98]────────────────────────[/color]")
			continue

		var heading := line.lstrip("#")
		if heading != line and line.begins_with("#"):
			out.append("[b]" + _inline_markdown(heading.strip_edges()) + "[/b]")
			continue

		if line.strip_edges().begins_with(">"):
			out.append("│ " + _inline_markdown(line.strip_edges().substr(1).strip_edges()))
			continue

		out.append(_inline_markdown(line))

	if in_code:
		out.append("[/code]")
	if max_lines > 0 and shown < text.split("\n").size():
		out.append("[color=#7f8c98]…[/color]")

	return "\n".join(out)


static func _inline_markdown(line: String) -> String:
	var working := line
	var tokens: Array[String] = []

	# Markdown links and images first: their [ ] delimiters must not be escaped
	# as BBCode before they are recognised.
	var link := RegEx.new()
	link.compile("!?\\[([^\\]]*)\\]\\(([^)]+)\\)")
	working = _replace_with_tokens(working, link, tokens, func(found: RegExMatch) -> String:
		var label := _escape_bbcode(found.get_string(1))
		var url := _escape_bbcode(found.get_string(2).strip_edges())
		return "[url=%s]%s[/url]" % [url, label if !label.is_empty() else url]
	)

	# Inline code spans. Protect their contents from emphasis rules below.
	var code := RegEx.new()
	code.compile("`([^`]+)`")
	working = _replace_with_tokens(working, code, tokens, func(found: RegExMatch) -> String:
		return "[code]" + _escape_bbcode(found.get_string(1)) + "[/code]"
	)

	working = _escape_bbcode(working)

	var bullet := RegEx.new()
	bullet.compile("^(\\s*)[-*+]\\s+")
	working = bullet.sub(working, "$1• ", true)

	var bold := RegEx.new()
	bold.compile("\\*\\*([^*]+)\\*\\*")
	working = bold.sub(working, "[b]$1[/b]", true)

	var italic := RegEx.new()
	italic.compile("(?<!\\*)\\*([^*]+)\\*(?!\\*)")
	working = italic.sub(working, "[i]$1[/i]", true)

	for i in range(tokens.size()):
		working = working.replace(_token(i), tokens[i])
	return working


static func _replace_with_tokens(line: String, regex: RegEx, tokens: Array[String], builder: Callable) -> String:
	var out := ""
	var cursor := 0
	while true:
		var found := regex.search(line, cursor)
		if found == null:
			break
		out += line.substr(cursor, found.get_start() - cursor)
		var index := tokens.size()
		tokens.append(str(builder.call(found)))
		out += _token(index)
		cursor = found.get_end()
	out += line.substr(cursor)
	return out


static func _token(index: int) -> String:
	return char(0xE000) + str(index) + char(0xE001)


static func _escape_bbcode(text: String) -> String:
	return text.replace("[", "[lb]")


## Markdown without formatting, suitable for one-line tooltips.
static func markdown_to_plain(markdown: String) -> String:
	var text := str(markdown).replace("\r\n", "\n")
	var fenced := RegEx.new()
	fenced.compile("(?s)```.*?```")
	text = fenced.sub(text, " ", true)
	text = text.replace("`", "")
	var link := RegEx.new()
	link.compile("!?\\[([^\\]]*)\\]\\(([^)]+)\\)")
	text = link.sub(text, "$1", true)
	text = text.replace("**", "").replace("__", "").replace("*", "").replace("_", "")
	text = text.replace("#", "").replace("> ", "")
	text = text.replace("\n", " ")
	while text.contains("  "):
		text = text.replace("  ", " ")
	return text.strip_edges()


## Normalizes the result of textDocument/hover into
## {ok, bbcode, plain, range}.
static func normalize_hover(result: Variant) -> Dictionary:
	if result == null:
		return {"ok": false, "bbcode": "", "plain": "", "range": {}}
	if result is String:
		var bbcode := markdown_to_bbcode(result, 80)
		return {"ok": !bbcode.strip_edges().is_empty(), "bbcode": bbcode, "plain": markdown_to_plain(result), "range": {}}

	if !(result is Dictionary):
		return {"ok": false, "bbcode": "", "plain": "", "range": {}}

	var hover: Dictionary = result
	var range: Dictionary = hover.get("range", {}) if hover.get("range", {}) is Dictionary else {}
	var contents: Variant = hover.get("contents", hover)
	var parts: Array[String] = []
	var plain_parts: Array[String] = []

	if contents is Array:
		for item in contents:
			var converted := _hover_part(item)
			if !str(converted.bbcode).is_empty():
				parts.append(str(converted.bbcode))
				plain_parts.append(str(converted.plain))
	elif contents is Dictionary or contents is String:
		var converted := _hover_part(contents)
		if !str(converted.bbcode).is_empty():
			parts.append(str(converted.bbcode))
			plain_parts.append(str(converted.plain))

	var bbcode := "\n\n".join(parts)
	return {
		"ok": !bbcode.strip_edges().is_empty(),
		"bbcode": bbcode,
		"plain": "\n".join(plain_parts),
		"range": range,
	}


static func _hover_part(part: Variant) -> Dictionary:
	if part is String:
		return {
			"bbcode": markdown_to_bbcode(part, 80),
			"plain": markdown_to_plain(part),
		}
	if part is Dictionary:
		var item: Dictionary = part
		if item.has("kind") and item.has("value"):
			var value := str(item.get("value", ""))
			if str(item.get("kind", "")) == "plaintext":
				return {"bbcode": _escape_bbcode(value), "plain": value}
			return {"bbcode": markdown_to_bbcode(value, 80), "plain": markdown_to_plain(value)}
		if item.has("language") and item.has("value"):
			var value := str(item.get("value", ""))
			return {
				"bbcode": "[code]" + _escape_bbcode(value) + "[/code]",
				"plain": value,
			}
	return {"bbcode": "", "plain": ""}


# ── DIAGNOSTICS ─────────────────────────────────────────────────────────────

static func normalize_publish_diagnostics(params: Variant) -> Dictionary:
	if !(params is Dictionary):
		return {"uri": "", "diagnostics": [], "version": null}
	var data: Dictionary = params
	var raw: Variant = data.get("diagnostics", [])
	var out: Array = []
	if raw is Array:
		for item in raw:
			if item is Dictionary:
				out.append(normalize_diagnostic(item))
	if out.size() > MAX_DIAGNOSTIC_LINES:
		out = out.slice(0, MAX_DIAGNOSTIC_LINES)
	return {
		"uri": str(data.get("uri", "")),
		"diagnostics": out,
		"version": data.get("version"),
	}


static func normalize_diagnostic(raw: Dictionary) -> Dictionary:
	var severity := int(raw.get("severity", 3))
	var code: Variant = raw.get("code", "")
	if code is Dictionary:
		code = code.get("value", "")

	var range: Variant = raw.get("range", {})
	var tags: Variant = raw.get("tags", [])
	return {
		"range": range.duplicate(true) if range is Dictionary or range is Array else {},
		"severity": severity,
		"severity_name": severity_name(severity),
		"message": str(raw.get("message", "")),
		"source": str(raw.get("source", "")),
		"code": str(code),
		"tags": tags.duplicate(true) if tags is Array else [],
		"related_information": raw.get("relatedInformation", []),
		"data": raw.get("data"),
		"raw": raw.duplicate(true),
	}


static func severity_name(severity: int) -> String:
	match severity:
		1: return "error"
		2: return "warning"
		3: return "information"
		4: return "hint"
	return "information"


static func severity_rank(severity: int) -> int:
	match severity:
		1: return 0
		2: return 1
		3: return 2
		4: return 3
	return 4


static func severity_symbol(severity: int) -> String:
	match severity:
		1: return "●"
		2: return "▲"
		3: return "■"
		4: return "○"
	return "■"


static func severity_color_key(severity: int) -> String:
	match severity:
		1: return "error"
		2: return "variable"
		3: return "function"
		4: return "comments"
	return "comments"


static func diagnostic_line(diagnostic: Dictionary) -> int:
	var range: Variant = diagnostic.get("range", {})
	if range is Dictionary:
		var start: Variant = range.get("start", {})
		if start is Dictionary:
			return int(start.get("line", 0))
	return 0


static func diagnostic_column(diagnostic: Dictionary) -> int:
	var range: Variant = diagnostic.get("range", {})
	if range is Dictionary:
		var start: Variant = range.get("start", {})
		if start is Dictionary:
			return int(start.get("character", 0))
	return 0


static func diagnostic_label(diagnostic: Dictionary) -> String:
	var message := str(diagnostic.get("message", "Problem")).replace("\n", " ").strip_edges()
	var source := str(diagnostic.get("source", "")).strip_edges()
	var code := str(diagnostic.get("code", "")).strip_edges()
	var suffix := ""
	if !source.is_empty():
		suffix += "  (" + source
		if !code.is_empty():
			suffix += " " + code
		suffix += ")"
	elif !code.is_empty():
		suffix += "  (" + code + ")"
	return message + suffix


# ── COMPLETION ──────────────────────────────────────────────────────────────

## Normalizes CompletionList / CompletionItem[] into a stable item shape.
static func normalize_completion(result: Variant) -> Dictionary:
	var raw_items: Array = []
	var incomplete := false
	if result is Array:
		raw_items = result
	elif result is Dictionary:
		var data: Dictionary = result
		if data.get("items") is Array:
			raw_items = data["items"]
		incomplete = bool(data.get("isIncomplete", false))
	elif result == null:
		return {"items": [], "is_incomplete": false}

	var items: Array = []
	for raw in raw_items:
		if !(raw is Dictionary):
			continue
		items.append(normalize_completion_item(raw))
	return {"items": items, "is_incomplete": incomplete}


static func normalize_completion_item(raw: Dictionary) -> Dictionary:
	var format := int(raw.get("insertTextFormat", 1))
	var insert_text := str(raw.get("insertText", ""))
	var text_edit: Variant = raw.get("textEdit")
	if insert_text.is_empty() and text_edit is Dictionary:
		insert_text = str((text_edit as Dictionary).get("newText", ""))
	if insert_text.is_empty():
		insert_text = str(raw.get("label", ""))
	if format == 2:
		insert_text = snippet_to_text(insert_text)

	var documentation: Dictionary = _documentation_part(raw.get("documentation"))
	var label := str(raw.get("label", ""))
	var label_details: Variant = raw.get("labelDetails")
	var detail := str(raw.get("detail", ""))
	if label_details is Dictionary:
		var extra := str((label_details as Dictionary).get("detail", ""))
		var description := str((label_details as Dictionary).get("description", ""))
		if !extra.is_empty():
			detail = extra if detail.is_empty() else detail + " " + extra
		if !description.is_empty():
			detail = description if detail.is_empty() else detail + " — " + description

	var kind := int(raw.get("kind", 1))
	return {
		"label": label,
		"label_details": label_details if label_details is Dictionary else {},
		"detail": detail,
		"documentation": documentation.get("markdown", ""),
		"documentation_bbcode": documentation.get("bbcode", ""),
		"documentation_plain": documentation.get("plain", ""),
		"kind": kind,
		"kind_name": completion_kind_name(kind),
		"category": completion_category(kind),
		"insert_text": insert_text,
		"sort_text": str(raw.get("sortText", label)),
		"filter_text": str(raw.get("filterText", label)),
		"deprecated": bool(raw.get("deprecated", false)) or raw.get("tags", []).has(1),
		"preselect": bool(raw.get("preselect", false)),
		"text_edit": text_edit.duplicate(true) if text_edit is Dictionary else {},
		"additional_text_edits": raw.get("additionalTextEdits", []).duplicate(true) if raw.get("additionalTextEdits", []) is Array else [],
		"commit_characters": raw.get("commitCharacters", []),
	}


static func _documentation_part(documentation: Variant) -> Dictionary:
	if documentation is String:
		return {
			"markdown": documentation,
			"bbcode": markdown_to_bbcode(documentation, 30),
			"plain": markdown_to_plain(documentation),
		}
	if documentation is Dictionary:
		var data: Dictionary = documentation
		var value := str(data.get("value", ""))
		if str(data.get("kind", "")) == "plaintext":
			return {"markdown": value, "bbcode": _escape_bbcode(value), "plain": value}
		return {
			"markdown": value,
			"bbcode": markdown_to_bbcode(value, 30),
			"plain": markdown_to_plain(value),
		}
	return {"markdown": "", "bbcode": "", "plain": ""}


static func completion_kind_name(kind: int) -> String:
	match kind:
		1: return "text"
		2: return "method"
		3: return "function"
		4: return "constructor"
		5: return "field"
		6: return "variable"
		7: return "class"
		8: return "interface"
		9: return "module"
		10: return "property"
		11: return "unit"
		12: return "value"
		13: return "enum"
		14: return "keyword"
		15: return "snippet"
		16: return "color"
		17: return "file"
		18: return "reference"
		19: return "folder"
		20: return "enum member"
		21: return "constant"
		22: return "struct"
		23: return "event"
		24: return "operator"
		25: return "type parameter"
	return "text"


static func completion_category(kind: int) -> String:
	match kind:
		2, 3, 4: return "function"
		5, 6, 10, 20: return "variable"
		7, 8, 9, 22, 25: return "class"
		13, 21, 12: return "constant"
		14, 24: return "keyword"
		15: return "snippet"
	return "plain"


## Turns an LSP snippet into text CodeEdit can insert. Placeholders become
## their default text (or nothing), choices become their first choice, and all
## snippet syntax is removed.
static func snippet_to_text(snippet: String) -> String:
	return _snippet_text(snippet, 0)


static func _snippet_text(snippet: String, depth: int) -> String:
	if depth > 8:
		return ""
	var out := ""
	var i := 0
	while i < snippet.length():
		var character := snippet[i]
		if character == "\\" and i + 1 < snippet.length():
			out += snippet[i + 1]
			i += 2
			continue
		if character != "$":
			out += character
			i += 1
			continue

		if i + 1 >= snippet.length():
			out += "$"
			break
		var next := snippet[i + 1]
		if next == "$":
			out += "$"
			i += 2
			continue
		if next.is_valid_int():
			i += 2
			while i < snippet.length() and snippet[i].is_valid_int():
				i += 1
			continue
		if next != "{":
			out += "$"
			i += 1
			continue

		var close := snippet.find("}", i + 2)
		if close < 0:
			i = snippet.length()
			break
		var inner := snippet.substr(i + 2, close - i - 2)
		out += _snippet_placeholder(inner, depth + 1)
		i = close + 1
	return out


static func _snippet_placeholder(inner: String, depth: int) -> String:
	var colon := inner.find(":")
	var pipe := inner.find("|")
	if pipe >= 0 and (colon < 0 or pipe < colon):
		var end_pipe := inner.rfind("|")
		if end_pipe > pipe:
			var choices := inner.substr(pipe + 1, end_pipe - pipe - 1).split(",")
			return str(choices[0]) if !choices.is_empty() else ""
		return ""
	if colon >= 0:
		return _snippet_text(inner.substr(colon + 1), depth)
	if inner.is_valid_int():
		return ""
	# A snippet variable such as TM_FILENAME. Leave it empty instead of
	# printing an unresolved ${...} into the user's file.
	return ""


# ── SIGNATURE HELP ─────────────────────────────────────────────────────────

static func normalize_signature_help(result: Variant) -> Dictionary:
	if !(result is Dictionary):
		return {"ok": false, "signatures": [], "active_signature": 0, "active_parameter": -1}
	var data: Dictionary = result
	var raw: Variant = data.get("signatures", [])
	if !(raw is Array) or (raw as Array).is_empty():
		return {"ok": false, "signatures": [], "active_signature": 0, "active_parameter": -1}

	var signatures: Array = []
	for item in raw:
		if !(item is Dictionary):
			continue
		var signature: Dictionary = item
		var documentation: Dictionary = _documentation_part(signature.get("documentation"))
		var parameters: Array = []
		var raw_parameters: Variant = signature.get("parameters", [])
		if raw_parameters is Array:
			for parameter in raw_parameters:
				if parameter is Dictionary:
					var param_doc: Dictionary = _documentation_part((parameter as Dictionary).get("documentation"))
					parameters.append({
						"label": (parameter as Dictionary).get("label", ""),
						"documentation": param_doc.get("plain", ""),
					})
		signatures.append({
			"label": str(signature.get("label", "")),
			"documentation": documentation.get("markdown", ""),
			"documentation_bbcode": documentation.get("bbcode", ""),
			"documentation_plain": documentation.get("plain", ""),
			"parameters": parameters,
		})

	return {
		"ok": !signatures.is_empty(),
		"signatures": signatures,
		"active_signature": clampi(int(data.get("activeSignature", 0)), 0, maxi(signatures.size() - 1, 0)),
		"active_parameter": int(data.get("activeParameter", -1)),
	}


## Builds a one-line signature with the active parameter wrapped in bold.
static func signature_line(signature: Dictionary, active_parameter: int) -> String:
	var label := str(signature.get("label", ""))
	if active_parameter < 0:
		return _escape_bbcode(label)

	var parameters: Variant = signature.get("parameters", [])
	if !(parameters is Array) or active_parameter >= (parameters as Array).size():
		return _escape_bbcode(label)

	var parameter: Dictionary = parameters[active_parameter]
	var marker: Variant = parameter.get("label", "")
	if marker is Array and (marker as Array).size() >= 2:
		var start := utf16_to_column(label, int(marker[0]))
		var end := utf16_to_column(label, int(marker[1]))
		return _wrap_label_range(label, start, end)
	if marker is String and !str(marker).is_empty():
		var found := label.find(str(marker))
		if found >= 0:
			return _wrap_label_range(label, found, found + str(marker).length())
	return _escape_bbcode(label)


static func _wrap_label_range(label: String, start: int, end: int) -> String:
	var safe_start := clampi(start, 0, label.length())
	var safe_end := clampi(end, safe_start, label.length())
	return _escape_bbcode(label.substr(0, safe_start)) \
		+ "[b]" + _escape_bbcode(label.substr(safe_start, safe_end - safe_start)) + "[/b]" \
		+ _escape_bbcode(label.substr(safe_end))


## True when the caret is inside an unclosed function call's argument list.
## Used to avoid asking for signature help in ordinary code.
static func call_context(text: String, line: int, column: int) -> Dictionary:
	var line_text := line_at(text, line)
	var prefix := line_text.substr(0, clampi(column, 0, line_text.length()))
	var depth := 0
	for i in range(prefix.length() - 1, -1, -1):
		var character := prefix[i]
		if character == ")":
			depth += 1
		elif character == "(":
			if depth == 0:
				return {"inside": true, "open_column": i}
			depth -= 1
		elif character == ";" and depth == 0:
			break
	return {"inside": false, "open_column": -1}


# ── LOCATIONS / CODE ACTIONS ────────────────────────────────────────────────

## Normalizes Location / LocationLink / arrays of either. The manager decorates
## them with display labels.
static func normalize_locations(result: Variant) -> Array:
	var raw: Array = []
	if result is Array:
		raw = result
	elif result is Dictionary:
		raw = [result]
	else:
		return []

	var out: Array = []
	for item in raw:
		if !(item is Dictionary):
			continue
		var location: Dictionary = item
		var uri := str(location.get("uri", location.get("targetUri", "")))
		if uri.is_empty():
			continue
		var range: Variant = location.get("range", {})
		if location.has("targetSelectionRange"):
			range = location.get("targetSelectionRange")
		elif location.has("targetRange") and !(range is Dictionary):
			range = location.get("targetRange")
		if !(range is Dictionary):
			range = {}
		var start: Variant = range.get("start", {})
		if !(start is Dictionary):
			start = {}
		out.append({
			"uri": uri,
			"path": uri_to_path(uri),
			"range": range,
			"line": int(start.get("line", 0)),
			"character": int(start.get("character", 0)),
		})

	out.sort_custom(func(a, b) -> bool:
		var a_path := str(a.path)
		var b_path := str(b.path)
		if a_path != b_path:
			return a_path.naturalnocasecmp_to(b_path) < 0
		if int(a.line) != int(b.line):
			return int(a.line) < int(b.line)
		return int(a.character) < int(b.character)
	)
	return out


static func normalize_code_actions(result: Variant) -> Array:
	if !(result is Array):
		return []
	var out: Array = []
	for item in result:
		if !(item is Dictionary):
			continue
		var data: Dictionary = item
		var edit: Variant = data.get("edit")
		var command: Variant = data.get("command")
		out.append({
			"title": str(data.get("title", "Code action")),
			"kind": str(data.get("kind", "")),
			"diagnostics": data.get("diagnostics", []),
			"edit": edit.duplicate(true) if edit is Dictionary else null,
			"command": command.duplicate(true) if command is Dictionary else null,
			"data": data.get("data"),
			"is_preferred": bool(data.get("isPreferred", false)),
			"disabled": data.get("disabled", null),
			# The exact server object, sent back to codeAction/resolve when the
			# action carries data instead of a complete edit.
			"raw": data.duplicate(true),
		})
	return out
