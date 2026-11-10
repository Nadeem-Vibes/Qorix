extends RefCounted

## Grapheme-aware column helpers for the document API.
##
## Public columns are Unicode codepoint columns, which is what CodeEdit uses.
## An edit is rejected when its column falls inside a grapheme cluster: the
## contract is that the buffer is never cut in the middle of a combining mark,
## a skin-tone modifier or a multi-codepoint grapheme that this build can
## segment. The matcher in Phase 3 uses the same boundaries, so a mod cannot
## create a state the ghost renderer cannot address.


## Boundaries after codepoint 0. TextServer returns the end of every cluster and
## omits the implicit leading zero, so [0] is added here.
static func boundaries(text: String) -> Array:
	var out: Array = [0]
	if text.is_empty():
		return out

	var server := TextServerManager.get_primary_interface()
	var breaks := server.string_get_character_breaks(text) if server != null else PackedInt32Array()
	for value in breaks:
		var index := int(value)
		if index > 0 and index < text.length() and !out.has(index):
			out.append(index)
	if !out.has(text.length()):
		out.append(text.length())
	out.sort()
	return out


static func is_boundary(text: String, column: int) -> bool:
	var col := int(column)
	if col < 0 or col > text.length():
		return false
	if col == 0 or col == text.length():
		return true
	return boundaries(text).has(col)


## Returns [previous_valid, next_valid] when `column` splits a cluster, or an
## empty array when it is already a boundary.
static func split_columns(text: String, column: int) -> Array:
	var col := int(column)
	if is_boundary(text, col) or col < 0 or col > text.length():
		return []

	var previous := 0
	var next := text.length()
	for value in boundaries(text):
		var index := int(value)
		if index < col:
			previous = index
		elif index > col:
			next = index
			break
	return [previous, next]


static func line_count(text: String) -> int:
	return maxi(1, text.split("\n").size())


static func line_at(text: String, line: int) -> String:
	var lines := text.split("\n")
	if line < 0 or line >= lines.size():
		return ""
	return lines[line]


## Codepoint offset of {line, column}, or -1 when the position is out of range.
static func offset_of(text: String, line: int, column: int) -> int:
	var lines := text.split("\n")
	if line < 0 or line >= lines.size():
		return -1
	var target := str(lines[line])
	if column < 0 or column > target.length():
		return -1

	var offset := 0
	for index in range(line):
		offset += (lines[index] as String).length() + 1
	return offset + column


## Inverse of offset_of. The offset immediately after a newline maps to
## {next line, column 0}; the end-of-line offset maps to the previous line.
static func position_of(text: String, offset: int) -> Dictionary:
	var target := clampi(int(offset), 0, text.length())
	var lines := text.split("\n")
	var consumed := 0

	for line in range(lines.size()):
		var content := str(lines[line])
		var line_end := consumed + content.length()
		if target <= line_end or line == lines.size() - 1:
			return {"line": line, "col": clampi(target - consumed, 0, content.length())}
		consumed = line_end + 1

	return {"line": 0, "col": 0}
