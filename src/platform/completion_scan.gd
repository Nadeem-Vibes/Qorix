class_name CompletionScan
extends RefCounted

## Builds the text window handed to a Lua language plugin for completion.
##
## The Lua plugins walk the whole buffer twice per request, so a 10,000 line
## file used to freeze the editor for a noticeable beat even with debouncing.
## The scan is now capped in both lines and characters, and the caret is
## re-based into the window so the plugin still sees the right position.

const DEFAULT_MAX_CHARS := 120000
const DEFAULT_MAX_LINES := 4000
## Lines kept above the caret. Completion usually needs local context, not the
## exports at the top of the file.
const CONTEXT_LINES := 200


## Returns {text, line, column, truncated, start_line, end_line}. When the text
## already fits, the input is returned untouched (no split, no allocation).
static func window(
	text: String,
	caret_line: int,
	caret_column: int,
	max_chars: int = DEFAULT_MAX_CHARS,
	max_lines: int = DEFAULT_MAX_LINES
) -> Dictionary:
	var limit_chars := maxi(1000, max_chars)
	var limit_lines := maxi(2, max_lines)
	var newline_count := text.count("\n")
	var line_count := newline_count + 1

	if text.length() <= limit_chars and line_count <= limit_lines:
		return {
			"text": text,
			"line": caret_line,
			"column": caret_column,
			"truncated": false,
			"start_line": 0,
			"end_line": line_count,
		}

	var lines := text.split("\n")
	var line := clampi(caret_line, 0, maxi(0, lines.size() - 1))

	# Start a little above the caret, then keep at most `limit_lines` lines in
	# total. The caret stays inside the window because the start never passes
	# it.
	var start := maxi(0, line - CONTEXT_LINES)
	var end := mini(lines.size(), start + limit_lines)
	if end - start < limit_lines:
		start = maxi(0, end - limit_lines)

	var selected = lines.slice(start, end)
	var joined: String = "\n".join(selected)

	if joined.length() > limit_chars:
		var caret_offset := _offset_in_window(selected, line - start, caret_column)
		var from := clampi(
			caret_offset - limit_chars / 2,
			0,
			maxi(0, joined.length() - limit_chars)
		)
		var prefix := joined.substr(0, from)
		var removed_lines := prefix.count("\n")
		var trimmed := joined.substr(from, limit_chars)

		start += removed_lines
		if removed_lines == 0:
			caret_column = maxi(0, caret_column - from)

		selected = trimmed.split("\n")
		joined = trimmed

	# `line` stays absolute while `start` advances past the trimmed prefix, so
	# `line - start` is the caret's row inside the trimmed window. Subtracting
	# the removed lines from both used to shift completion upwards on big files.
	return {
		"text": joined,
		"line": clampi(line - start, 0, maxi(0, selected.size() - 1)),
		"column": maxi(0, caret_column),
		"truncated": true,
		"start_line": start,
		"end_line": start + selected.size(),
	}


static func _offset_in_window(lines, local_line: int, column: int) -> int:
	var offset := 0
	for i in range(mini(local_line, lines.size())):
		offset += str(lines[i]).length() + 1
	return offset + maxi(0, column)
