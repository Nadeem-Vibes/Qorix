extends RefCounted

## Pure diff helpers for Phase 6.
##
## Two representations are used:
##
## * `parse_unified()` reads `git diff --no-color --unified=N` output. It is
##   used for files that are not open (and for the unified diff fallback).
## * `line_diff()` compares two in-memory buffers. The editor gutter and the
##   side-by-side viewer use it so unsaved edits are visible before a save.
##
## `line_diff()` trims the common prefix/suffix first and caps the LCS table.
## A large rewrite therefore degrades to a coarse "all changed" row set instead
## of allocating a table proportional to the whole file and blocking the UI.

## 250,000 cells is a few milliseconds in GDScript and covers ordinary edits.
## Larger middles fall back to a paired row-by-row comparison.
const MAX_LCS_CELLS := 250000


static func parse_unified(text: String) -> Dictionary:
	var result := {
		"ok": true,
		"files": [],
		"additions": 0,
		"deletions": 0,
		"raw": text,
		"error": "",
	}

	var current_file: Dictionary = {}
	var current_hunk: Dictionary = {}
	var old_line := 0
	var new_line := 0

	for raw_line in text.split("\n"):
		var line := raw_line.trim_suffix("\r")

		if line.begins_with("diff --git "):
			_flush_hunk(current_file, current_hunk)
			current_hunk = {}
			_flush_file(result, current_file)
			current_file = {
				"old_path": "",
				"new_path": "",
				"hunks": [],
				"additions": 0,
				"deletions": 0,
			}
			var paths := _paths_from_diff_header(line)
			current_file["old_path"] = paths[0]
			current_file["new_path"] = paths[1]
			continue

		# --- / +++ are hunk-content lines once a hunk is open (a deleted Lua or
		# Haskell comment starts with "--"). Only honor them as file headers
		# outside hunks.
		if line.begins_with("--- ") and current_hunk.is_empty():
			if current_file.is_empty():
				current_file = {
					"old_path": "", "new_path": "", "hunks": [],
					"additions": 0, "deletions": 0,
				}
			current_file["old_path"] = _strip_diff_path(line.substr(4))
			continue

		if line.begins_with("+++ ") and current_hunk.is_empty():
			if current_file.is_empty():
				current_file = {
					"old_path": "", "new_path": "", "hunks": [],
					"additions": 0, "deletions": 0,
				}
			current_file["new_path"] = _strip_diff_path(line.substr(4))
			continue

		if line.begins_with("@@"):
			if current_file.is_empty():
				current_file = {
					"old_path": "", "new_path": "", "hunks": [],
					"additions": 0, "deletions": 0,
				}
			_flush_hunk(current_file, current_hunk)
			var header := _parse_hunk_header(line)
			current_hunk = {
				"old_start": int(header.get("old_start", 0)),
				"old_count": int(header.get("old_count", 0)),
				"new_start": int(header.get("new_start", 0)),
				"new_count": int(header.get("new_count", 0)),
				"header": line,
				"lines": [],
			}
			old_line = int(current_hunk["old_start"])
			new_line = int(current_hunk["new_start"])
			continue

		if current_hunk.is_empty():
			continue

		if line.begins_with("\\"):
			(current_hunk["lines"] as Array).append({
				"kind": "note",
				"text": line,
				"old_line": 0,
				"new_line": 0,
			})
			continue

		if line.begins_with("+"):
			(current_hunk["lines"] as Array).append({
				"kind": "add",
				"text": line.substr(1),
				"old_line": 0,
				"new_line": new_line,
			})
			current_file["additions"] = int(current_file.get("additions", 0)) + 1
			result["additions"] = int(result["additions"]) + 1
			new_line += 1
			continue

		if line.begins_with("-"):
			(current_hunk["lines"] as Array).append({
				"kind": "delete",
				"text": line.substr(1),
				"old_line": old_line,
				"new_line": 0,
			})
			current_file["deletions"] = int(current_file.get("deletions", 0)) + 1
			result["deletions"] = int(result["deletions"]) + 1
			old_line += 1
			continue

		if line.begins_with(" "):
			(current_hunk["lines"] as Array).append({
				"kind": "context",
				"text": line.substr(1),
				"old_line": old_line,
				"new_line": new_line,
			})
			old_line += 1
			new_line += 1
			continue

	_flush_hunk(current_file, current_hunk)
	_flush_file(result, current_file)
	return result


static func _flush_hunk(file: Dictionary, hunk: Dictionary) -> void:
	if file.is_empty() or hunk.is_empty():
		return
	(file["hunks"] as Array).append(hunk)


static func _flush_file(result: Dictionary, file: Dictionary) -> void:
	if file.is_empty():
		return
	if (file["hunks"] as Array).is_empty() and str(file.get("old_path", "")).is_empty() and str(file.get("new_path", "")).is_empty():
		return
	(result["files"] as Array).append(file)


static func _paths_from_diff_header(line: String) -> Array:
	var body := line.substr(11)
	# The separator between a/old and b/new is the LAST " b/": paths may
	# themselves contain " b/" anywhere earlier.
	var marker := body.rfind(" b/")
	if marker == -1:
		return [_strip_diff_path(body), ""]
	return [_strip_diff_path(body.substr(0, marker)), _strip_diff_path(body.substr(marker + 1))]


static func _strip_diff_path(value: String) -> String:
	var path := value.strip_edges()
	# Git appends a tab + timestamp in some external diff variants.
	var tab := path.find("\t")
	if tab != -1:
		path = path.substr(0, tab)
	if path == "/dev/null":
		return ""
	if path.begins_with("a/") or path.begins_with("b/"):
		path = path.substr(2)
	if path.begins_with("\"") and path.ends_with("\"") and path.length() >= 2:
		path = path.substr(1, path.length() - 2)
	return path


static func _parse_hunk_header(line: String) -> Dictionary:
	# @@ -12,3 +12,4 @@ optional section heading
	var body_start := 2
	var body_end := line.find(" @@", body_start)
	if body_end == -1:
		body_end = line.length()
	var body := line.substr(body_start, body_end - body_start).strip_edges()
	var result := {
		"old_start": 0, "old_count": 0,
		"new_start": 0, "new_count": 0,
	}
	for part in body.split(" ", false):
		if part.begins_with("-"):
			var old_range := _parse_range(part.substr(1))
			result["old_start"] = old_range[0]
			result["old_count"] = old_range[1]
		elif part.begins_with("+"):
			var new_range := _parse_range(part.substr(1))
			result["new_start"] = new_range[0]
			result["new_count"] = new_range[1]
	return result


static func _parse_range(value: String) -> Array:
	var parts := value.split(",", true)
	var start := int(parts[0]) if !parts.is_empty() and str(parts[0]).is_valid_int() else 0
	var count := 1
	if parts.size() > 1 and str(parts[1]).is_valid_int():
		count = int(parts[1])
	return [start, count]


## Compares two buffers. Returns side-by-side rows plus the gutter marks for
## the right-hand (current) buffer.
##
## Each row: {kind, left, right, old_line, new_line}
##   kind = context | add | delete | modify | gap
## Marks: {line_index: "added" | "modified" | "deleted"} (0-based).
static func line_diff(old_text: String, new_text: String) -> Dictionary:
	var old_lines := old_text.split("\n")
	var new_lines := new_text.split("\n")

	var prefix := 0
	var shortest := mini(old_lines.size(), new_lines.size())
	while prefix < shortest and old_lines[prefix] == new_lines[prefix]:
		prefix += 1

	var suffix := 0
	var old_remaining := old_lines.size() - prefix
	var new_remaining := new_lines.size() - prefix
	var suffix_limit := mini(old_remaining, new_remaining)
	while suffix < suffix_limit and old_lines[old_lines.size() - 1 - suffix] == new_lines[new_lines.size() - 1 - suffix]:
		suffix += 1

	var rows: Array = []
	for i in range(prefix):
		rows.append(_context_row(str(old_lines[i]), i + 1, i + 1))

	var old_mid := old_lines.slice(prefix, old_lines.size() - suffix)
	var new_mid := new_lines.slice(prefix, new_lines.size() - suffix)
	_append_middle(rows, old_mid, new_mid, prefix)

	var new_suffix_start := new_lines.size() - suffix
	for i in range(suffix):
		var old_line := old_lines.size() - suffix + i
		var new_line := new_suffix_start + i
		rows.append(_context_row(str(new_lines[new_line]), old_line + 1, new_line + 1))

	var marks := _marks_from_rows(rows, new_lines.size())
	return {
		"ok": true,
		"rows": rows,
		"marks": marks,
		"added": int(marks.get("_added", 0)),
		"modified": int(marks.get("_modified", 0)),
		"deleted": int(marks.get("_deleted", 0)),
		"old_lines": old_lines.size(),
		"new_lines": new_lines.size(),
	}


static func _append_middle(rows: Array, old_mid: PackedStringArray, new_mid: PackedStringArray, prefix: int) -> void:
	if old_mid.is_empty() and new_mid.is_empty():
		return

	if old_mid.is_empty():
		for j in range(new_mid.size()):
			rows.append(_add_row(str(new_mid[j]), prefix + j + 1))
		return

	if new_mid.is_empty():
		for i in range(old_mid.size()):
			rows.append(_delete_row(str(old_mid[i]), prefix + i + 1))
		return

	var cells := old_mid.size() * new_mid.size()
	if cells > MAX_LCS_CELLS:
		_append_coarse_block(rows, old_mid, new_mid, prefix)
		return

	var matches := _lcs_matches(old_mid, new_mid)
	var old_cursor := 0
	var new_cursor := 0
	for match in matches:
		var match_old := int(match[0])
		var match_new := int(match[1])
		_append_changed_block(rows, old_mid, new_mid, old_cursor, match_old, new_cursor, match_new, prefix)
		rows.append(_context_row(str(new_mid[match_new]), prefix + match_old + 1, prefix + match_new + 1))
		old_cursor = match_old + 1
		new_cursor = match_new + 1
	_append_changed_block(rows, old_mid, new_mid, old_cursor, old_mid.size(), new_cursor, new_mid.size(), prefix)


static func _append_coarse_block(rows: Array, old_mid: PackedStringArray, new_mid: PackedStringArray, prefix: int) -> void:
	# Deliberately bounded fallback: pair rows until one side runs out, then
	# show the rest as pure additions/deletions.
	var paired := mini(old_mid.size(), new_mid.size())
	for i in range(paired):
		rows.append(_modify_row(str(old_mid[i]), str(new_mid[i]), prefix + i + 1, prefix + i + 1))
	for i in range(paired, old_mid.size()):
		rows.append(_delete_row(str(old_mid[i]), prefix + i + 1))
	for j in range(paired, new_mid.size()):
		rows.append(_add_row(str(new_mid[j]), prefix + j + 1))


static func _append_changed_block(rows: Array, old_mid: PackedStringArray, new_mid: PackedStringArray, old_start: int, old_end: int, new_start: int, new_end: int, prefix: int) -> void:
	var paired := mini(old_end - old_start, new_end - new_start)
	for i in range(paired):
		rows.append(_modify_row(
			str(old_mid[old_start + i]),
			str(new_mid[new_start + i]),
			prefix + old_start + i + 1,
			prefix + new_start + i + 1
		))
	for i in range(paired, old_end - old_start):
		rows.append(_delete_row(str(old_mid[old_start + i]), prefix + old_start + i + 1))
	for j in range(paired, new_end - new_start):
		rows.append(_add_row(str(new_mid[new_start + j]), prefix + new_start + j + 1))


static func _lcs_matches(old_lines: PackedStringArray, new_lines: PackedStringArray) -> Array:
	var n := old_lines.size()
	var m := new_lines.size()
	var table: Array[PackedInt32Array] = []
	table.resize(n + 1)
	for i in range(n + 1):
		var row := PackedInt32Array()
		row.resize(m + 1)
		table[i] = row

	for i in range(n - 1, -1, -1):
		var row := table[i]
		var next := table[i + 1]
		for j in range(m - 1, -1, -1):
			if old_lines[i] == new_lines[j]:
				row[j] = next[j + 1] + 1
			else:
				row[j] = maxi(next[j], row[j + 1])

	var matches: Array = []
	var i := 0
	var j := 0
	while i < n and j < m:
		if old_lines[i] == new_lines[j]:
			matches.append([i, j])
			i += 1
			j += 1
		elif table[i + 1][j] >= table[i][j + 1]:
			i += 1
		else:
			j += 1
	return matches


static func _context_row(text: String, old_line: int, new_line: int) -> Dictionary:
	return {"kind": "context", "left": text, "right": text, "old_line": old_line, "new_line": new_line}


static func _add_row(text: String, new_line: int) -> Dictionary:
	return {"kind": "add", "left": "", "right": text, "old_line": 0, "new_line": new_line}


static func _delete_row(text: String, old_line: int) -> Dictionary:
	return {"kind": "delete", "left": text, "right": "", "old_line": old_line, "new_line": 0}


static func _modify_row(left_text: String, right_text: String, old_line: int, new_line: int) -> Dictionary:
	return {"kind": "modify", "left": left_text, "right": right_text, "old_line": old_line, "new_line": new_line}


static func _marks_from_rows(rows: Array, new_line_count: int) -> Dictionary:
	var marks: Dictionary = {}
	var added := 0
	var modified := 0
	var deleted := 0

	for i in range(rows.size()):
		var row: Dictionary = rows[i]
		var kind := str(row.get("kind", "context"))
		var new_line := int(row.get("new_line", 0))
		if kind == "add" and new_line > 0:
			marks[new_line - 1] = "added"
			added += 1
		elif kind == "modify" and new_line > 0:
			marks[new_line - 1] = "modified"
			modified += 1

	# A deletion has no line of its own in the current buffer. Attach it to the
	# next surviving line, or to the last line when the deletion is at EOF.
	for i in range(rows.size()):
		var row: Dictionary = rows[i]
		if str(row.get("kind", "")) != "delete":
			continue
		deleted += 1
		var target := _next_new_line(rows, i, new_line_count)
		if target >= 0 and !marks.has(target):
			marks[target] = "deleted"

	marks["_added"] = added
	marks["_modified"] = modified
	marks["_deleted"] = deleted
	return marks


static func _next_new_line(rows: Array, start: int, new_line_count: int) -> int:
	for i in range(start + 1, rows.size()):
		var line := int((rows[i] as Dictionary).get("new_line", 0))
		if line > 0:
			return line - 1
	if new_line_count > 0:
		return new_line_count - 1
	return -1


## Flattens a parsed diff into rows for the single-pane unified viewer.
## Row: {kind, text, old_line, new_line}
static func unified_lines(parsed: Dictionary) -> Array:
	var rows: Array = []
	for file in parsed.get("files", []):
		if !(file is Dictionary):
			continue
		var old_path := str(file.get("old_path", ""))
		var new_path := str(file.get("new_path", ""))
		var title := "--- " + (old_path if !old_path.is_empty() else "/dev/null")
		title += "   +++ " + (new_path if !new_path.is_empty() else "/dev/null")
		rows.append({"kind": "file", "text": title, "old_line": 0, "new_line": 0})
		for hunk in file.get("hunks", []):
			if !(hunk is Dictionary):
				continue
			rows.append({"kind": "hunk", "text": str(hunk.get("header", "")), "old_line": 0, "new_line": 0})
			for line in hunk.get("lines", []):
				if !(line is Dictionary):
					continue
				var kind := str(line.get("kind", "context"))
				var prefix := " "
				if kind == "add":
					prefix = "+"
				elif kind == "delete":
					prefix = "-"
				elif kind == "note":
					prefix = "\\"
				rows.append({
					"kind": kind,
					"text": prefix + str(line.get("text", "")),
					"old_line": int(line.get("old_line", 0)),
					"new_line": int(line.get("new_line", 0)),
				})
	return rows
