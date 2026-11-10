class_name SearchText
extends RefCounted

## Pure text helpers for the global search panel. No file access, no nodes —
## so the edge cases (case folding, overlapping matches, binary detection)
## can be tested headlessly.

const PREVIEW_LIMIT := 220
const BINARY_PROBE := 4096


static func find_columns(line: String, query: String, case_sensitive: bool = false) -> Array:
	var out: Array = []
	if query.is_empty():
		return out

	var hay := line if case_sensitive else line.to_lower()
	var needle := query if case_sensitive else query.to_lower()
	var step := maxi(1, needle.length())
	var at := hay.find(needle)

	while at != -1:
		out.append(at)
		at = hay.find(needle, at + step)

	return out


## Replaces every literal occurrence. Returns {text: String, count: int}.
## Replacement text is inserted verbatim (callers should keep it single-line
## when replacing inside a line-oriented preview).
static func replace_all(
	text: String,
	query: String,
	replacement: String,
	case_sensitive: bool = false
) -> Dictionary:
	if query.is_empty():
		return {"text": text, "count": 0}

	if case_sensitive:
		var count := text.count(query)
		if count == 0:
			return {"text": text, "count": 0}
		return {"text": text.replace(query, replacement), "count": count}

	var hay := text.to_lower()
	var needle := query.to_lower()
	var step := maxi(1, needle.length())
	var out := ""
	var cursor := 0
	var total := 0

	while true:
		var at := hay.find(needle, cursor)
		if at == -1:
			out += text.substr(cursor)
			break

		out += text.substr(cursor, at - cursor)
		out += replacement
		cursor = at + step
		total += 1

	return {"text": out, "count": total}


## A single-line preview clipped around the match. Leading indentation is
## dropped, which keeps the result list readable for deeply nested code.
static func preview_of(
	line: String,
	column: int,
	length: int,
	limit: int = PREVIEW_LIMIT
) -> String:
	var trimmed := line.strip_edges()
	if trimmed.length() <= limit:
		return trimmed

	var indent := line.length() - line.strip_edges(true, false).length()
	var local_column := maxi(0, column - indent)
	var span := maxi(length, 1)
	var start := clampi(local_column - limit / 3, 0, maxi(0, trimmed.length() - limit))
	var end := mini(trimmed.length(), start + limit)
	var slice := trimmed.substr(start, end - start)

	if start > 0:
		slice = "…" + slice
	if end < trimmed.length():
		slice += "…"

	return slice


## A NUL byte in the probe window is a reliable enough binary signal for a
## source-code search: text files never contain them, most binaries do.
##
## The probe is raw bytes, not a String: Godot Strings cannot store NUL (it is
## replaced with U+FFFD), so checking a String here would never match and the
## literal "\u0000" itself would trip the engine's Unicode parser at load time.
static func is_binary(probe: PackedByteArray) -> bool:
	return probe.has(0)
