extends RefCounted

## Guide matcher: compilation, prefix reconciliation and ghost slices.
##
## Pure GDScript with no scene access, so the whole learning contract is
## testable headlessly. The one engine dependency is TextServer's grapheme
## segmentation, shared with the document API through `mod_text_columns.gd`:
## the matcher can never address a column the editor would refuse.
##
## Everything is expressed in Unicode codepoint columns (what CodeEdit uses)
## while progression happens on grapheme clusters. A buffer that stops in the
## middle of a cluster (an IME composition, a combining mark typed on its own)
## is still on track; the next step accepts the rest of that cluster.

const Result = preload("res://src/features/mods/mod_result.gd")
const Columns = preload("res://src/features/mods/mod_text_columns.gd")

const MAX_TARGET_BYTES := 64 * 1024
const MAX_MARKS := 64
const MAX_HINTS := 64
const MIN_DISPLAY_CHARS := 1
const MAX_DISPLAY_CHARS := 256
const DEFAULT_DISPLAY_CHARS := 64
const MAX_DISPLAY_LINES := 8

const MODES := ["strict", "coach"]
const PROGRESSIONS := ["character", "word", "line", "none"]
const SCOPES := ["next_char", "line", "segment", "block"]
const HINT_TRIGGERS := [
	"start", "mark", "mistake", "idle", "segment_done", "complete", "diverged",
]


static func compile(spec: Dictionary) -> Dictionary:
	var raw := "" if spec.get("target") == null else str(spec.get("target", ""))
	if raw.strip_edges().is_empty():
		return Result.error("guide.invalid_spec", "A guide session needs a non-empty target.")

	var target := normalize(raw)
	if target.to_utf8_buffer().size() > MAX_TARGET_BYTES:
		return Result.error(
			"guide.invalid_spec",
			"A step target is limited to %d bytes." % MAX_TARGET_BYTES,
		)
	if _has_rtl(target):
		return Result.error(
			"guide.unsupported",
			"Right-to-left targets are not supported in API 1.",
		)

	var starts: Array = []
	var clusters: Array = []
	var boundaries := Columns.boundaries(target)
	for index in range(boundaries.size() - 1):
		var start := int(boundaries[index])
		var end := int(boundaries[index + 1])
		if end <= start:
			continue
		var position := Columns.position_of(target, start)
		starts.append(start)
		clusters.append({
			"start": start,
			"end": end,
			"text": target.substr(start, end - start),
			"line": int(position.get("line", 0)),
			"col": int(position.get("col", 0)),
		})

	var display := _display(spec.get("display", {}))
	var scored := _marks(target, spec.get("marks", []), starts)
	if !bool(scored.get("ok", false)):
		return scored

	var hints := _hints(spec.get("hints", []), scored.get("marks", {}))
	if !bool(hints.get("ok", false)):
		return hints

	var mode := str(spec.get("mode", "strict")).to_lower()
	if !MODES.has(mode):
		return Result.error("guide.invalid_spec", "'%s' is not a guide mode." % mode)

	var progression := str(spec.get("progression", "character")).to_lower()
	if !PROGRESSIONS.has(progression):
		return Result.error(
			"guide.invalid_spec",
			"'%s' is not a progression." % progression,
		)

	var normalize_value := str(spec.get("normalize", "none")).to_lower()
	if normalize_value != "" and normalize_value != "none":
		return Result.error(
			"guide.unsupported",
			"Only normalize = \"none\" is supported in API 1.",
		)

	return {
		"ok": true,
		"target": target,
		"clusters": clusters,
		"cluster_starts": starts,
		"cluster_count": clusters.size(),
		"marks": scored["marks"],
		"mark_order": scored["order"],
		"hints": hints["hints"],
		"display": display,
		"mode": mode,
		"progression": progression,
		"line_count": Columns.line_count(target),
	}


## Longest common prefix in codepoints, adjusted so a half-typed cluster is not
## a divergence. `previous_prefix_cp` is the fast path: when the old prefix still
## matches, only the edit's suffix is compared.
static func reconcile(compiled: Dictionary, buffer: String, previous_prefix_cp: int = -1) -> Dictionary:
	var target := str(compiled.get("target", ""))
	var starts: Array = compiled.get("cluster_starts", [])
	var previous := int(previous_prefix_cp)
	var start := 0
	if previous > 0 and previous <= buffer.length() and previous <= target.length():
		if buffer.substr(0, previous) == target.substr(0, previous):
			start = previous

	var limit := mini(target.length(), buffer.length())
	var index := start
	while index < limit and target.unicode_at(index) == buffer.unicode_at(index):
		index += 1

	var is_prefix := index >= buffer.length() and target.substr(0, buffer.length()) == buffer
	var prefix_cp := index
	if is_prefix:
		prefix_cp = buffer.length()
	elif !_is_cluster_start(starts, prefix_cp):
		prefix_cp = _floor_cluster(starts, prefix_cp)

	var on_track := is_prefix
	var at_end := on_track and prefix_cp >= target.length()
	var cluster_index := _floor_index(starts, prefix_cp)
	var expected := ""
	if prefix_cp < target.length():
		var end := _cluster_end(starts, cluster_index, target)
		expected = target.substr(prefix_cp, maxi(0, end - prefix_cp))

	var actual := ""
	if !on_track:
		var actual_end := mini(buffer.length(), prefix_cp + maxi(1, expected.length()))
		actual = buffer.substr(mini(prefix_cp, buffer.length()), maxi(0, actual_end - prefix_cp))

	return {
		"ok": true,
		"prefix_cp": prefix_cp,
		"prefix_clusters": maxi(0, cluster_index),
		"on_track": on_track,
		"at_end": at_end,
		"expected": expected,
		"actual": actual,
		"position": Columns.position_of(target, prefix_cp),
		"buffer_length": buffer.length(),
	}


## Ghost slice for the display scope. All coordinates are codepoint columns.
static func ghost(compiled: Dictionary, prefix_cp: int) -> Dictionary:
	var target := str(compiled.get("target", ""))
	var display: Dictionary = compiled.get("display", {})
	var scope := str(display.get("scope", "line"))
	var cap := int(display.get("chars", DEFAULT_DISPLAY_CHARS))
	var starts: Array = compiled.get("cluster_starts", [])

	var from := clampi(int(prefix_cp), 0, target.length())
	var limit := _scope_limit(compiled, from, scope)
	var index := _floor_index(starts, from)

	var lines: Array = []
	var current: Dictionary = {}
	var total := 0
	var truncated := false
	var next_cluster := ""

	while index < starts.size():
		var cluster_start := int(starts[index])
		if cluster_start >= limit:
			break
		var cluster_end := _cluster_end(starts, index, target)
		var text := target.substr(cluster_start, cluster_end - cluster_start)
		if total + text.length() > cap:
			truncated = true
			break
		if next_cluster.is_empty() and cluster_end > from:
			next_cluster = target.substr(from, cluster_end - from)

		if text == "\n":
			if !current.is_empty():
				lines.append(current)
				current = {}
			if lines.size() >= MAX_DISPLAY_LINES:
				truncated = true
				break
			index += 1
			continue

		var position := Columns.position_of(target, cluster_start)
		var line_number := int(position.get("line", 0))
		if current.is_empty():
			current = {
				"line": line_number,
				"col": int(position.get("col", 0)),
				"text": "",
				"clusters": [],
			}
		var display_text := text
		var display_col := int(position.get("col", 0))
		if cluster_start < from and cluster_end > from:
			# A half-typed cluster: keep only the remainder in the ghost.
			display_text = target.substr(from, cluster_end - from)
			display_col = int(Columns.position_of(target, from).get("col", 0))
		current["text"] = str(current.get("text", "")) + display_text
		(current["clusters"] as Array).append({
			"text": display_text,
			"line": line_number,
			"col": display_col,
		})
		total += display_text.length()
		index += 1

	if !current.is_empty():
		lines.append(current)
	if lines.size() > MAX_DISPLAY_LINES:
		lines = lines.slice(0, MAX_DISPLAY_LINES)
		truncated = true

	return {
		"ok": true,
		"from": from,
		"to": limit,
		"text": target.substr(from, maxi(0, limit - from)),
		"lines": lines,
		"next": next_cluster,
		"truncated": truncated,
	}


## The chunk the current progression accepts as one step.
static func chunk(compiled: Dictionary, prefix_cp: int, progression: String = "") -> String:
	var target := str(compiled.get("target", ""))
	var mode := progression if !progression.is_empty() else str(compiled.get("progression", "character"))
	var from := clampi(int(prefix_cp), 0, target.length())
	if from >= target.length():
		return ""
	if mode == "none":
		return ""

	var starts: Array = compiled.get("cluster_starts", [])
	var index := _floor_index(starts, from)
	match mode:
		"word":
			var end := from
			var started := false
			while end < target.length():
				var character := target[end]
				var is_space := character == " " or character == "\t" or character == "\n"
				if started and is_space:
					break
				if !started and is_space:
					# Spaces are accepted with the word, one at a time.
					return character
				started = true
				end += 1
			return target.substr(from, maxi(1, end - from))
		"line":
			var newline := target.find("\n", from)
			if newline == -1:
				return target.substr(from)
			return target.substr(from, newline - from + 1)
		_:
			var cluster_end := _cluster_end(starts, index, target)
			return target.substr(from, maxi(0, cluster_end - from))


## Indentation the next line expects, or "" when the next cluster is not a
## newline.
static func indent_after(compiled: Dictionary, prefix_cp: int) -> String:
	var target := str(compiled.get("target", ""))
	var from := clampi(int(prefix_cp), 0, target.length())
	if from >= target.length() or target[from] != "\n":
		return ""
	var run := ""
	var index := from + 1
	while index < target.length():
		var character := target[index]
		if character != " " and character != "\t":
			break
		run += character
		index += 1
	return run


## Indentation run at the start of the line that contains `prefix_cp`.
static func line_indent(compiled: Dictionary, prefix_cp: int) -> String:
	var target := str(compiled.get("target", ""))
	var position := Columns.position_of(target, clampi(int(prefix_cp), 0, target.length()))
	var line := int(position.get("line", 0))
	var lines := target.split("\n")
	if line < 0 or line >= lines.size():
		return ""
	var text := str(lines[line])
	var run := ""
	for index in range(text.length()):
		var character := text[index]
		if character != " " and character != "\t":
			break
		run += character
	return run


## Codepoint offset of the first character of the line containing `prefix_cp`.
static func line_start(compiled: Dictionary, prefix_cp: int) -> int:
	var target := str(compiled.get("target", ""))
	var position := Columns.position_of(target, clampi(int(prefix_cp), 0, target.length()))
	var line := int(position.get("line", 0))
	var lines := target.split("\n")
	var offset := 0
	for index in range(mini(line, lines.size())):
		offset += str(lines[index]).length() + 1
	return offset


## Mark that contains `prefix_cp`, or an empty Dictionary.
static func mark_at(compiled: Dictionary, prefix_cp: int) -> Dictionary:
	var marks: Dictionary = compiled.get("marks", {})
	var position := int(prefix_cp)
	for id in marks.keys():
		var mark: Dictionary = marks[id]
		if position >= int(mark.get("start", 0)) and position < int(mark.get("end", 0)):
			return mark
	return {}


## Id of the mark that starts exactly at `prefix_cp`, or "".
static func mark_starting_at(compiled: Dictionary, prefix_cp: int) -> String:
	var marks: Dictionary = compiled.get("marks", {})
	for id in marks.keys():
		if int((marks[id] as Dictionary).get("start", -1)) == int(prefix_cp):
			return str(id)
	return ""


static func hints_for(compiled: Dictionary, trigger: String, mark_id: String = "", mistakes: int = -1) -> Array:
	var out: Array = []
	for hint in compiled.get("hints", []):
		var entry: Dictionary = hint
		if str(entry.get("on", "")) != trigger:
			continue
		if trigger == "mark" and !mark_id.is_empty() and str(entry.get("mark", "")) != mark_id:
			continue
		if trigger == "mistake" and mistakes >= 0:
			# Lessons declare "this hint unlocks on the Nth mistake"; only
			# return hints whose threshold the learner has reached. A negative
			# count means the caller asked without a count: no filtering.
			var threshold := int(entry.get("mistake", 1))
			if mistakes < threshold:
				continue
		out.append(str(entry.get("text", "")))
	return out


static func normalize(text: String) -> String:
	return text.replace("\r\n", "\n").replace("\r", "\n")


## Codepoints a learner must type before a target is complete.
##
## Lesson targets end with a newline so multi-line content keeps a clean shape,
## but that final newline is invisible in the ghost: requiring it looked like a
## lesson that could never finish after the last visible character. Pressing
## Enter at the end is still accepted; it is simply not mandatory.
static func completion_length(target: String) -> int:
	var length := str(target).length()
	if length > 1 and str(target).unicode_at(length - 1) == 10:
		return length - 1
	return length


static func is_cluster_start(compiled: Dictionary, codepoint: int) -> bool:
	return _is_cluster_start(compiled.get("cluster_starts", []), int(codepoint))


static func cluster_index(compiled: Dictionary, codepoint: int) -> int:
	return _floor_index(compiled.get("cluster_starts", []), int(codepoint))


# ── INTERNALS ───────────────────────────────────────────────────────────────

static func _display(raw: Variant) -> Dictionary:
	var spec: Dictionary = raw if raw is Dictionary else {}
	var scope := str(spec.get("scope", "line")).to_lower()
	if !SCOPES.has(scope):
		scope = "line"
	return {
		"scope": scope,
		"chars": clampi(
			int(spec.get("chars", DEFAULT_DISPLAY_CHARS)),
			MIN_DISPLAY_CHARS,
			MAX_DISPLAY_CHARS,
		),
		"alpha": clampf(float(spec.get("alpha", 0.32)), 0.0, 1.0),
	}


static func _marks(target: String, raw: Variant, starts: Array) -> Dictionary:
	if raw == null:
		return {"ok": true, "marks": {}, "order": []}
	if !(raw is Array):
		return Result.error("guide.invalid_spec", "marks must be an array.")
	if (raw as Array).size() > MAX_MARKS:
		return Result.error("guide.invalid_spec", "A step may declare at most %d marks." % MAX_MARKS)

	var marks: Dictionary = {}
	var order: Array = []
	var cursor := 0
	for item in raw:
		if !(item is Dictionary):
			return Result.error("guide.invalid_spec", "Every mark must be an object.")
		var spec: Dictionary = item
		var id := str(spec.get("id", ""))
		var text := str(spec.get("text", ""))
		if id.is_empty() or text.is_empty():
			return Result.error("guide.invalid_spec", "A mark needs a non-empty id and text.")
		if marks.has(id):
			return Result.error("guide.invalid_spec", "Duplicate mark id '%s'." % id)

		var start := target.find(text, cursor)
		if start < 0:
			return Result.error(
				"guide.invalid_spec",
				"Mark '%s' (%s) does not appear after the previous mark." % [id, text],
			)
		var end := start + text.length()
		cursor = end
		var first := _floor_index(starts, start)
		var last := _floor_index(starts, maxi(start, end - 1))
		marks[id] = {
			"id": id,
			"start": start,
			"end": end,
			"cluster_start": first,
			"cluster_end": last + 1,
			"text": text,
		}
		order.append(id)

	return {"ok": true, "marks": marks, "order": order}


static func _hints(raw: Variant, marks: Dictionary) -> Dictionary:
	if raw == null:
		return {"ok": true, "hints": []}
	if !(raw is Array):
		return Result.error("guide.invalid_spec", "hints must be an array.")
	if (raw as Array).size() > MAX_HINTS:
		return Result.error("guide.invalid_spec", "A step may declare at most %d hints." % MAX_HINTS)

	var hints: Array = []
	for item in raw:
		if !(item is Dictionary):
			return Result.error("guide.invalid_spec", "Every hint must be an object.")
		var spec: Dictionary = item
		var trigger := str(spec.get("on", "")).to_lower()
		if !HINT_TRIGGERS.has(trigger):
			return Result.error("guide.invalid_spec", "'%s' is not a hint trigger." % trigger)
		var text := str(spec.get("text", ""))
		if text.strip_edges().is_empty():
			return Result.error("guide.invalid_spec", "A hint needs text.")
		var mark := str(spec.get("mark", spec.get("id", "")))
		if trigger == "mark" and (mark.is_empty() or !marks.has(mark)):
			return Result.error(
				"guide.invalid_spec",
				"A mark hint needs a declared mark id.",
			)
		var entry := {"on": trigger, "text": text}
		if !mark.is_empty():
			entry["mark"] = mark
		if spec.has("mistake") and trigger == "mistake":
			entry["mistake"] = maxi(1, int(spec.get("mistake", 1)))
		hints.append(entry)

	return {"ok": true, "hints": hints}


static func _scope_limit(compiled: Dictionary, from: int, scope: String) -> int:
	var target := str(compiled.get("target", ""))
	match scope:
		"next_char":
			var starts: Array = compiled.get("cluster_starts", [])
			var index := _floor_index(starts, from)
			return _cluster_end(starts, index, target)
		"segment":
			var mark := mark_at(compiled, from)
			if !mark.is_empty():
				return int(mark.get("end", target.length()))
			var blank := target.find("\n\n", from)
			return target.length() if blank == -1 else blank + 1
		"block":
			return target.length()
		_:
			var newline := target.find("\n", from)
			return target.length() if newline == -1 else newline


static func _cluster_end(starts: Array, index: int, target: String) -> int:
	if index < 0:
		return 0
	if index + 1 < starts.size():
		return int(starts[index + 1])
	return target.length()


static func _floor_index(starts: Array, codepoint: int) -> int:
	var low := 0
	var high := starts.size() - 1
	var found := 0
	while low <= high:
		var middle := (low + high) / 2
		if int(starts[middle]) <= codepoint:
			found = middle
			low = middle + 1
		else:
			high = middle - 1
	return found


static func _floor_cluster(starts: Array, codepoint: int) -> int:
	return int(starts[_floor_index(starts, codepoint)])


static func _is_cluster_start(starts: Array, codepoint: int) -> bool:
	var index := _floor_index(starts, codepoint)
	return index < starts.size() and int(starts[index]) == codepoint


## RTL paragraphs are out of scope for API 1. Detect the scripts rather than
## relying on a paragraph direction API that the headless server may stub.
static func _has_rtl(text: String) -> bool:
	for index in range(text.length()):
		var code := text.unicode_at(index)
		if (code >= 0x0590 and code <= 0x08FF) \
			or (code >= 0xFB1D and code <= 0xFDFF) \
			or (code >= 0xFE70 and code <= 0xFEFE):
			return true
	return false
