extends RefCounted

## Guide input filter: a pure decision function.
##
## Input is a semantic key event, not an InputEvent, so the whole filter is
## testable headlessly and the platform mapping stays in one place
## (`input_controller.gd`). The filter never edits text by itself: it answers
## pass, swallow or insert, and the host performs the insertion.
##
## Correct characters pass through natively. That keeps undo, key repeat, IME
## commit behaviour and rendering inside CodeEdit, and it is why only
## mismatches and structural keys are intercepted.

const Matcher = preload("res://src/features/learning/guide/guide_matcher.gd")
const Columns = preload("res://src/features/mods/mod_text_columns.gd")

const PASS := "pass"
const SWALLOW := "swallow"
const INSERT := "insert"


## `context`:
##   compiled        — GuideMatcher.compile() result
##   prefix_cp       — reconciled codepoint prefix
##   caret_line/col  — current caret in codepoint columns
##   has_selection   — true when the view has a selection
##   paused, active  — session flags
##
## `event`:
##   kind — "text" | "backspace" | "enter" | "tab" | "escape" | "other"
##   text — printable text for "text"
##   ctrl/alt/meta/ime — modifier flags
static func decide(context: Dictionary, event: Dictionary) -> Dictionary:
	var compiled: Dictionary = context.get("compiled", {})
	var target := str(compiled.get("target", ""))
	var prefix := int(context.get("prefix_cp", 0))

	if !bool(context.get("active", false)) or bool(context.get("paused", false)):
		return _pass("inactive")
	if bool(context.get("has_selection", false)):
		return _pass("selection")
	if bool(event.get("ctrl", false)) or bool(event.get("alt", false)) or bool(event.get("meta", false)):
		return _pass("shortcut")
	if bool(event.get("ime", false)):
		return _pass("ime")

	var kind := str(event.get("kind", "other"))
	if kind == "other" or kind == "escape":
		return _pass("unhandled")

	var position := Columns.position_of(target, clampi(prefix, 0, target.length()))
	if int(position.get("line", 0)) != int(context.get("caret_line", 0)) \
		or int(position.get("col", 0)) != int(context.get("caret_col", 0)):
		return _pass("caret_elsewhere")

	if prefix >= target.length():
		return _pass("target_complete")

	if kind == "backspace":
		return _pass("native_backspace")

	if kind == "enter":
		if target[prefix] == "\n":
			var indent := Matcher.indent_after(compiled, prefix)
			return _insert("\n" + indent, "expected_newline")
		return _mistake("enter", target.substr(prefix, 1))

	if kind == "tab":
		if int(context.get("caret_col", 0)) == 0:
			var indent := Matcher.line_indent(compiled, prefix)
			var remainder := target.substr(prefix)
			if !indent.is_empty() and remainder.begins_with(indent):
				return _insert(indent, "expected_indent")
		return _mistake("tab", target.substr(prefix, 1))

	if kind != "text":
		return _pass("unhandled")

	var text := str(event.get("text", ""))
	if text.is_empty():
		return _pass("empty")

	var progression := str(compiled.get("progression", "character"))
	var mode := str(compiled.get("mode", "strict"))
	if progression == "none":
		return _pass("no_progression")

	var chunk := Matcher.chunk(compiled, prefix, progression)
	var matches := !chunk.is_empty() and chunk.begins_with(text)

	if mode == "coach":
		# Coach mode never blocks input; it still reports the mismatch so the
		# hint layer can react.
		return {
			"action": PASS,
			"text": text,
			"mistake": !matches,
			"reason": "coach",
			"expected": chunk,
			"position": position,
		}

	if matches:
		return _pass("expected")

	return _mistake("text", chunk)


static func _pass(reason: String) -> Dictionary:
	return {"action": PASS, "text": "", "mistake": false, "reason": reason}


static func _insert(text: String, reason: String) -> Dictionary:
	return {"action": INSERT, "text": text, "mistake": false, "reason": reason}


static func _mistake(reason: String, expected: String) -> Dictionary:
	return {
		"action": SWALLOW,
		"text": "",
		"mistake": true,
		"reason": reason,
		"expected": expected,
	}
