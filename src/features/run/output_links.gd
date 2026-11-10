extends RefCounted

## Pure helpers for the Run panel's clickable output.
##
## The panel itself needs a theme and a tree, which makes it awkward to cover
## in the headless suite. Everything that decides "is this text a file:line
## link, and where does it point?" lives here instead, so a compiler diagnostic
## can be tested without building the UI.
##
## The pattern has two alternatives:
##   * Python tracebacks: `File "path", line N[, in ...]`
##   * Everything else: `path.ext:N[:C]`, optionally with a drive or ./ prefix
## Groups 2/3 are the Python path/line; groups 5/6/7 are the generic
## path/line/column. Paths printed by compilers are 1-based.

const Paths = preload("res://src/base/path_utils.gd")

const FILE_LINE_PATTERN := "(?m)(File \"([^\"]+)\", line (\\d+)(?:, in [^\\n]*)?)|(((?:[A-Za-z]:[\\\\/]|/|\\.{1,2}[\\\\/])?[^\\s:()\\[\\]{}\"'<>]+\\.[A-Za-z0-9_+-]{1,12}):(\\d+)(?::(\\d+))?)"


static func compile(pattern: String = FILE_LINE_PATTERN) -> RegEx:
	var regex := RegEx.new()
	regex.compile(pattern)
	return regex


## Finds every candidate in output order. Each entry is:
## {start, end, raw, path, line, column}
static func find_links(output: String, regex: RegEx = null) -> Array:
	var matcher: RegEx = regex if regex != null else compile()
	var out: Array = []

	for result in matcher.search_all(output):
		var path := ""
		var line := 0
		var column := 0
		if !result.get_string(2).is_empty():
			path = result.get_string(2)
			line = int(result.get_string(3))
		else:
			path = result.get_string(5)
			line = int(result.get_string(6))
			column = int(result.get_string(7)) if !result.get_string(7).is_empty() else 0

		out.append({
			"start": result.get_start(0),
			"end": result.get_end(0),
			"raw": result.get_string(0),
			"path": path,
			"line": line,
			"column": column,
		})

	return out


## Resolves a path printed by a compiler. Relative paths are tried against the
## run cwd, then the workspace, then the source file's folder. If none exists,
## the spelling is kept so the line can still be shown.
static func resolve_path(value: String, cwd: String = "", workspace: String = "", source_file: String = "") -> String:
	var text := Paths.normalize(value.strip_edges())
	if text.is_empty():
		return ""
	if text.is_absolute_path():
		return text

	var bases: Array[String] = [cwd, workspace, source_file.get_base_dir()]
	for base in bases:
		var normalized := Paths.normalize(base)
		if normalized.is_empty():
			continue
		var candidate := Paths.normalize(normalized.path_join(text))
		if FileAccess.file_exists(candidate):
			return candidate
	return text


static func linkable(path: String, line: int) -> bool:
	return !path.is_empty() and line > 0 and FileAccess.file_exists(path)


## Renders output as BBCode with a real link for every diagnostic path that
## exists. Non-link text is still escaped, so a log line like `[ERROR]` cannot
## be swallowed by RichTextLabel.
static func linkify(
	output: String,
	regex: RegEx = null,
	cwd: String = "",
	workspace: String = "",
	source_file: String = ""
) -> String:
	var matches := find_links(output, regex)
	if matches.is_empty():
		return escape(output)

	var out := ""
	var cursor := 0
	for entry in matches:
		var start := int(entry.get("start", 0))
		var end := int(entry.get("end", 0))
		if start < cursor:
			continue
		out += escape(output.substr(cursor, start - cursor))

		var raw := str(entry.get("raw", ""))
		var line := int(entry.get("line", 0))
		var column := int(entry.get("column", 0))
		var resolved := resolve_path(str(entry.get("path", "")), cwd, workspace, source_file)
		if !linkable(resolved, line):
			out += escape(raw)
		else:
			var payload := {
				"kind": "open", "path": resolved, "line": line, "column": column,
			}
			out += "[url=%s][u]%s[/u][/url]" % [meta(payload), escape(raw)]
		cursor = end

	out += escape(output.substr(cursor))
	return out


## RichTextLabel would otherwise treat compiler output such as [1] as a tag.
## "[lb]" is Godot's literal left bracket.
static func escape(text: String) -> String:
	return text.replace("[", "[lb]")


## Metadata payload for a RichTextLabel [url] tag. Documented here because the
## panel and the tests must agree on the encoding.
static func meta(payload: Dictionary) -> String:
	return "griddy:" + Marshalls.utf8_to_base64(JSON.stringify(payload))
