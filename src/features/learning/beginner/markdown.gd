extends RefCounted

## Offline Markdown to HTML renderer used by the live preview.
##
## Only a deliberately small, predictable subset is supported: headings,
## paragraphs, fenced code, inline code, links, images, bold/italic, lists,
## blockquotes and horizontal rules. Raw HTML is escaped, so previewing a note
## downloaded from the internet can never run its scripts.
##
## `render_document()` produces a complete page with the same calm typography
## as the preview stylesheet; `render_body()` is the fragment used by tests and
## by callers that want to wrap it themselves.

const DOCUMENT_TITLE_FALLBACK := "Preview"


static func render_document(markdown: String, title: String = DOCUMENT_TITLE_FALLBACK, extra_head: String = "", extra_body: String = "") -> String:
	var safe_title := escape_html(title)
	var head := extra_head.strip_edges()
	var body := render_body(markdown)
	var tail := extra_body.strip_edges()

	var page := "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n"
	page += "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
	page += "<title>%s</title>\n" % safe_title
	page += "<style>\n%s\n</style>\n" % _stylesheet()
	if !head.is_empty():
		page += head + "\n"
	page += "</head>\n<body>\n<main class=\"preview\">\n"
	page += body
	page += "\n</main>\n"
	if !tail.is_empty():
		page += tail + "\n"
	page += "</body>\n</html>\n"
	return page


static func render_body(markdown: String) -> String:
	var text := markdown.replace("\r\n", "\n").replace("\r", "\n")
	var lines := text.split("\n")
	var out: Array[String] = []
	var paragraph: Array[String] = []
	var list_type := ""
	var in_code := false
	var code_language := ""
	var code_lines: Array[String] = []

	for index in range(lines.size()):
		var line := str(lines[index])

		if line.begins_with("```") or line.begins_with("~~~"):
			var fence := "```" if line.begins_with("```") else "~~~"
			if in_code:
				out.append(_code_block("\n".join(code_lines), code_language))
				code_lines.clear()
				code_language = ""
				in_code = false
			else:
				_flush_paragraph(out, paragraph)
				_close_list(out, list_type)
				list_type = ""
				in_code = true
				code_language = _safe_language(line.substr(3).strip_edges())
			continue

		if in_code:
			code_lines.append(line)
			continue

		if line.strip_edges().is_empty():
			_flush_paragraph(out, paragraph)
			_close_list(out, list_type)
			list_type = ""
			continue

		var heading := _heading(line)
		if !heading.is_empty():
			_flush_paragraph(out, paragraph)
			_close_list(out, list_type)
			list_type = ""
			out.append("<h%d>%s</h%d>" % [int(heading["level"]), inline(str(heading["text"])), int(heading["level"])])
			continue

		if _is_rule(line):
			_flush_paragraph(out, paragraph)
			_close_list(out, list_type)
			list_type = ""
			out.append("<hr>")
			continue

		if line.strip_edges().begins_with(">"):
			_flush_paragraph(out, paragraph)
			_close_list(out, list_type)
			list_type = ""
			var quote_lines: Array[String] = []
			while index < lines.size():
				var candidate := str(lines[index])
				if !candidate.strip_edges().begins_with(">"):
					break
				quote_lines.append(candidate.strip_edges().trim_prefix(">").strip_edges())
				index += 1
			index -= 1
			out.append("<blockquote><p>%s</p></blockquote>" % inline(" ".join(quote_lines)))
			continue

		var item := _list_item(line)
		if !item.is_empty():
			_flush_paragraph(out, paragraph)
			var item_type := str(item.get("type", "ul"))
			if list_type.is_empty():
				list_type = item_type
				out.append("<%s>" % list_type)
			elif list_type != item_type:
				_close_list(out, list_type)
				list_type = item_type
				out.append("<%s>" % list_type)
			out.append("<li>%s</li>" % inline(str(item.get("text", ""))))
			continue

		_close_list(out, list_type)
		list_type = ""
		paragraph.append(line.strip_edges())

	if in_code:
		out.append(_code_block("\n".join(code_lines), code_language))
	_flush_paragraph(out, paragraph)
	_close_list(out, list_type)
	return "\n".join(out)


static func inline(text: String) -> String:
	var escaped := escape_html(text)
	var with_code: Dictionary = _protect_code_spans(escaped)
	var value := str(with_code.get("text", escaped))
	var codes: Array = with_code.get("codes", [])

	# Images first: the leading ! distinguishes them from links.
	value = _regex_replace(value, "!\\[([^\\]]*)\\]\\(([^)\\s]+)(?:\\s+&quot;([^&]*)&quot;)?\\)", func(matches: Array) -> String:
		var url := _safe_url(str(matches[1]), true)
		var alt := str(matches[0])
		var title := str(matches[2]) if matches.size() > 2 else ""
		var title_attr := " title=\"%s\"" % title if !title.is_empty() else ""
		return "<img src=\"%s\" alt=\"%s\"%s>" % [url, alt, title_attr]
	)

	value = _regex_replace(value, "\\[([^\\]]+)\\]\\(([^)\\s]+)(?:\\s+&quot;([^&]*)&quot;)?\\)", func(matches: Array) -> String:
		var url := _safe_url(str(matches[1]), false)
		var label := str(matches[0])
		var title := str(matches[2]) if matches.size() > 2 else ""
		var title_attr := " title=\"%s\"" % title if !title.is_empty() else ""
		return "<a href=\"%s\"%s>%s</a>" % [url, title_attr, label]
	)

	value = _regex_replace(value, "\\*\\*([^*]+)\\*\\*", func(matches: Array) -> String:
		return "<strong>%s</strong>" % str(matches[0])
	)
	value = _regex_replace(value, "__([^_]+)__", func(matches: Array) -> String:
		return "<strong>%s</strong>" % str(matches[0])
	)
	value = _regex_replace(value, "~~([^~]+)~~", func(matches: Array) -> String:
		return "<del>%s</del>" % str(matches[0])
	)
	value = _regex_replace(value, "\\*([^*\\n]+)\\*", func(matches: Array) -> String:
		return "<em>%s</em>" % str(matches[0])
	)
	value = _regex_replace(value, "(^|\\s)_([^_\\n]+)_($|\\s|[.,!?])", func(matches: Array) -> String:
		var prefix := str(matches[0])
		var middle := str(matches[1])
		var suffix := str(matches[2]) if matches.size() > 2 else ""
		return "%s<em>%s</em>%s" % [prefix, middle, suffix]
	)

	for i in range(codes.size()):
		value = value.replace("\u0001%d\u0002" % i, "<code>%s</code>" % str(codes[i]))
	return value


static func escape_html(text: String) -> String:
	return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;")


static func _protect_code_spans(text: String) -> Dictionary:
	var regex := RegEx.new()
	if regex.compile("`([^`\\n]+)`") != OK:
		return {"text": text, "codes": []}
	var out := ""
	var codes: Array[String] = []
	var cursor := 0
	for match in regex.search_all(text):
		out += text.substr(cursor, match.get_start() - cursor)
		out += "\u0001%d\u0002" % codes.size()
		# The caller already escaped the whole line once; escaping the captured
		# span again double-encodes it ("&amp;" became "&amp;amp;").
		codes.append(match.get_string(1))
		cursor = match.get_end()
	out += text.substr(cursor)
	return {"text": out, "codes": codes}


static func _regex_replace(text: String, pattern: String, builder: Callable) -> String:
	var regex := RegEx.new()
	if regex.compile(pattern) != OK:
		return text
	var out := ""
	var cursor := 0
	for match in regex.search_all(text):
		out += text.substr(cursor, match.get_start() - cursor)
		var groups: Array[String] = []
		# Group 0 is the whole match; the first capture is group 1.
		for group in range(1, match.get_group_count() + 1):
			groups.append(str(match.get_string(group)))
		out += str(builder.call(groups))
		cursor = match.get_end()
	out += text.substr(cursor)
	return out


static func _heading(line: String) -> Dictionary:
	var stripped := line.strip_edges()
	var level := 0
	while level < stripped.length() and level < 6 and stripped[level] == "#":
		level += 1
	if level == 0 or level >= stripped.length() or stripped[level] != " ":
		return {}
	return {"level": level, "text": stripped.substr(level + 1).strip_edges()}


static func _is_rule(line: String) -> bool:
	var stripped := line.strip_edges().replace(" ", "")
	if stripped.length() < 3:
		return false
	return stripped == "-".repeat(stripped.length()) or stripped == "*".repeat(stripped.length()) or stripped == "_".repeat(stripped.length())


static func _list_item(line: String) -> Dictionary:
	var stripped := line.strip_edges()
	if stripped.begins_with("- ") or stripped.begins_with("* ") or stripped.begins_with("+ "):
		return {"type": "ul", "text": stripped.substr(2).strip_edges()}
	var dot := stripped.find(". ")
	if dot > 0:
		var number := stripped.substr(0, dot)
		if number.is_valid_int():
			return {"type": "ol", "text": stripped.substr(dot + 2).strip_edges()}
	return {}


static func _flush_paragraph(out: Array[String], paragraph: Array[String]) -> void:
	if paragraph.is_empty():
		return
	out.append("<p>%s</p>" % inline(" ".join(paragraph)))
	paragraph.clear()


static func _close_list(out: Array[String], list_type: String) -> void:
	if list_type.is_empty():
		return
	out.append("</%s>" % list_type)


static func _code_block(code: String, language: String) -> String:
	var class_attr := " class=\"language-%s\"" % language if !language.is_empty() else ""
	return "<pre><code%s>%s</code></pre>" % [class_attr, escape_html(code)]


static func _safe_language(value: String) -> String:
	var out := ""
	for character in value.to_lower():
		if "abcdefghijklmnopqrstuvwxyz0123456789_+-".contains(character):
			out += character
	return out


static func _safe_url(url: String, image: bool) -> String:
	var value := url.strip_edges()
	var lower := value.to_lower()
	if lower.begins_with("javascript:") or lower.begins_with("vbscript:"):
		return "#"
	if lower.begins_with("data:"):
		# Inline images are the one allowed data: payload; everything else
		# (and every data: link) is dropped.
		return value if (image and lower.begins_with("data:image/")) else "#"
	if lower.begins_with("http://") or lower.begins_with("https://") or lower.begins_with("mailto:"):
		return value
	if value.begins_with("#") or value.begins_with("/") or value.begins_with("./") or value.begins_with("../"):
		return value
	# A relative file next to the document is useful; a bare "word" is not.
	if !value.is_empty() and !value.contains(":"):
		return value
	return "#"


static func _stylesheet() -> String:
	return """
:root { color-scheme: dark; }
* { box-sizing: border-box; }
html, body { margin: 0; padding: 0; background: #14171c; color: #d7dce2; }
body { font: 17px/1.65 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
main.preview { max-width: 860px; margin: 0 auto; padding: 48px 28px 96px; }
h1, h2, h3, h4, h5, h6 { color: #eef2f7; line-height: 1.25; margin: 1.6em 0 0.55em; }
h1 { font-size: 2.2em; border-bottom: 1px solid #2a3038; padding-bottom: 0.3em; }
h2 { font-size: 1.65em; }
h3 { font-size: 1.3em; }
p { margin: 0.8em 0; }
a { color: #8bd5ff; }
a:hover { color: #b7e6ff; }
code { font: 0.92em/1.5 "Cascadia Code", Consolas, "SF Mono", monospace; background: #1f242c; color: #f0c674; border-radius: 4px; padding: 0.14em 0.36em; }
pre { background: #1b2027; border: 1px solid #2a3038; border-radius: 8px; padding: 16px 18px; overflow-x: auto; }
pre code { background: none; color: #d7dce2; padding: 0; font-size: 0.9em; }
blockquote { margin: 1.2em 0; padding: 0.2em 1.1em; border-left: 3px solid #4a90d9; color: #aeb8c4; background: #181d24; }
ul, ol { padding-left: 1.6em; }
li { margin: 0.3em 0; }
hr { border: 0; border-top: 1px solid #2a3038; margin: 2em 0; }
img { max-width: 100%; border-radius: 8px; }
del { color: #8d98a6; }
"""


## Injects the live-reload script into an HTML document. Kept here so both HTML
## and Markdown previews use exactly the same polling behaviour.
static func inject_live_reload(html: String, script: String) -> String:
	if script.strip_edges().is_empty():
		return html
	var marker := html.to_lower().rfind("</body>")
	if marker >= 0:
		return html.substr(0, marker) + script + "\n" + html.substr(marker)
	return html + "\n" + script
