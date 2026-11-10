extends "res://tests/support/test_case.gd"

## Guide filter: the pure key decision. Correct characters pass natively;
## structural keys insert the expected chunk; mismatches are swallowed (strict)
## or allowed (coach).

const Matcher = preload("res://src/features/learning/guide/guide_matcher.gd")
const Filter = preload("res://src/features/learning/guide/guide_filter.gd")


func _context(target: String, prefix: int = 0, caret_col: int = -1, spec: Dictionary = {}) -> Dictionary:
	var input := {"target": target, "progression": "character", "mode": "strict"}
	for key in spec.keys():
		input[key] = spec[key]
	var compiled := Matcher.compile(input)
	var position: Dictionary = Matcher.reconcile(compiled, target.substr(0, prefix), 0).get("position", {})
	return {
		"compiled": compiled,
		"prefix_cp": prefix,
		"caret_line": int(position.get("line", 0)),
		"caret_col": int(position.get("col", 0)) if caret_col < 0 else caret_col,
		"has_selection": false,
		"paused": false,
		"active": true,
	}


func _text(value: String) -> Dictionary:
	return {"kind": "text", "text": value}


func test_correct_character_passes_natively() -> void:
	var decision := Filter.decide(_context("print"), _text("p"))
	assert_eq(str(decision.get("action", "")), "pass", "expected character passes")
	assert_false(bool(decision.get("mistake", true)), "no mistake")


func test_wrong_character_is_swallowed_in_strict_mode() -> void:
	var decision := Filter.decide(_context("print"), _text("x"))
	assert_eq(str(decision.get("action", "")), "swallow", "wrong character is blocked")
	check(bool(decision.get("mistake", false)), "mistake is reported")
	assert_eq(str(decision.get("expected", "")), "p", "expected cluster is reported")


func test_coach_mode_allows_wrong_input_but_reports_it() -> void:
	var decision := Filter.decide(_context("print", 0, -1, {"mode": "coach"}), _text("x"))
	assert_eq(str(decision.get("action", "")), "pass", "coach mode never blocks")
	check(bool(decision.get("mistake", false)), "coach still reports the mismatch")


func test_word_and_line_progression_accept_chunks() -> void:
	var word := Filter.decide(_context("hello world", 0, -1, {"progression": "word"}), _text("hello"))
	assert_eq(str(word.get("action", "")), "pass", "a whole word is accepted at once")
	var partial := Filter.decide(_context("hello world", 0, -1, {"progression": "word"}), _text("h"))
	assert_eq(str(partial.get("action", "")), "pass", "a prefix of the word is accepted")

	var line := Filter.decide(_context("abc\ndef", 0, -1, {"progression": "line"}), _text("abc"))
	assert_eq(str(line.get("action", "")), "pass", "a whole line is accepted")
	var wrong_line := Filter.decide(_context("abc\ndef", 0, -1, {"progression": "line"}), _text("x"))
	assert_eq(str(wrong_line.get("action", "")), "swallow", "a wrong line start is blocked")


func test_none_progression_never_filters() -> void:
	var decision := Filter.decide(_context("abc", 0, -1, {"progression": "none"}), _text("z"))
	assert_eq(str(decision.get("action", "")), "pass", "none means free editing")


func test_shortcut_selection_and_caret_elsewhere_pass() -> void:
	var shortcut := {"kind": "text", "text": "z", "ctrl": true}
	assert_eq(str(Filter.decide(_context("abc"), shortcut).get("action", "")), "pass", "ctrl combinations pass")

	var context := _context("abc")
	context["has_selection"] = true
	assert_eq(str(Filter.decide(context, _text("z")).get("action", "")), "pass", "a selection pauses filtering")

	var moved := _context("abc", 0, 4)
	assert_eq(str(Filter.decide(moved, _text("z")).get("action", "")), "pass", "caret elsewhere pauses filtering")

	var ime := {"kind": "other", "text": "", "ime": true}
	assert_eq(str(Filter.decide(_context("abc"), ime).get("action", "")), "pass", "IME candidates pass")


func test_enter_inserts_only_an_expected_newline_and_indent() -> void:
	var context := _context("if x:\n    y", 5, -1)
	var insert := Filter.decide(context, {"kind": "enter"})
	assert_eq(str(insert.get("action", "")), "insert", "expected newline is inserted by the host")
	assert_eq(str(insert.get("text", "")), "\n    ", "the next line's indent comes with it")

	var wrong := Filter.decide(_context("abc"), {"kind": "enter"})
	assert_eq(str(wrong.get("action", "")), "swallow", "an unexpected newline is a mistake")
	check(bool(wrong.get("mistake", false)), "the mismatch is reported")


func test_tab_inserts_the_expected_indent_at_line_start() -> void:
	var decision := Filter.decide(_context("    print", 0, 0), {"kind": "tab"})
	assert_eq(str(decision.get("action", "")), "insert", "tab at a line start inserts the indent")
	assert_eq(str(decision.get("text", "")), "    ", "the indent run is the expected one")

	var elsewhere := Filter.decide(_context("    print", 2, 2), {"kind": "tab"})
	assert_eq(str(elsewhere.get("action", "")), "swallow", "tab inside the indent is a mistake")


func test_backspace_and_escape_pass() -> void:
	assert_eq(str(Filter.decide(_context("abc"), {"kind": "backspace"}).get("action", "")), "pass", "backspace is native")
	assert_eq(str(Filter.decide(_context("abc"), {"kind": "escape"}).get("action", "")), "pass", "escape is not filtered")


func test_completed_target_never_filters() -> void:
	var context := _context("abc", 3)
	assert_eq(str(Filter.decide(context, _text("z")).get("action", "")), "pass", "nothing is left to filter")


func test_partially_typed_cluster_accepts_the_rest() -> void:
	var compiled := Matcher.compile({"target": "e\u0301x"})
	var context := {
		"compiled": compiled,
		"prefix_cp": 1,
		"caret_line": 0,
		"caret_col": 1,
		"has_selection": false,
		"paused": false,
		"active": true,
	}
	var decision := Filter.decide(context, _text("\u0301"))
	assert_eq(str(decision.get("action", "")), "pass", "the combining mark completes the cluster")
