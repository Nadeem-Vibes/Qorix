extends "res://tests/support/test_case.gd"

## Guide matcher: compilation, marks, grapheme-aware reconciliation, ghost
## scopes and progression chunks. Pure logic, no scene.

const Matcher = preload("res://src/features/learning/guide/guide_matcher.gd")
const Result = preload("res://src/features/mods/mod_result.gd")


func _compiled(spec: Dictionary = {}) -> Dictionary:
	var input := {
		"target": "print(\"Hello\")\n",
		"progression": "character",
		"display": {"scope": "line"},
		"marks": [
			{"id": "fn", "text": "print"},
			{"id": "msg", "text": "\"Hello\""},
		],
		"hints": [
			{"on": "start", "text": "Start here."},
			{"on": "mark", "mark": "fn", "text": "This prints."},
		],
	}
	if spec.has("target"):
		# A different target invalidates the default marks and hints.
		input.erase("marks")
		input.erase("hints")
	for key in spec.keys():
		input[key] = spec[key]
	return Matcher.compile(input)


func test_compile_target_marks_and_hints() -> void:
	var compiled := _compiled()
	check(bool(compiled.get("ok", false)), "target compiles")
	assert_eq(int(compiled.get("cluster_count", 0)), "print(\"Hello\")\n".length(), "one ASCII cluster per codepoint")
	var marks: Dictionary = compiled.get("marks", {})
	assert_eq(int(marks.get("fn", {}).get("start", -1)), 0, "first mark starts at zero")
	assert_eq(int(marks.get("msg", {}).get("start", -1)), 6, "second mark found sequentially")
	assert_eq(str(compiled.get("mode", "")), "strict", "strict is the default mode")
	assert_eq(str(compiled.get("progression", "")), "character", "character is the default progression")
	assert_eq(int(compiled.get("display", {}).get("chars", 0)), 64, "display default cap")
	assert_eq(Matcher.hints_for(compiled, "mark", "fn").size(), 1, "mark hint resolves")
	assert_eq(Matcher.hints_for(compiled, "mark", "msg").size(), 0, "unknown mark has no hint")


func test_empty_and_invalid_targets_are_rejected() -> void:
	assert_eq(Result.code_of(Matcher.compile({"target": "   "})), "guide.invalid_spec")
	assert_eq(Result.code_of(_compiled({"target": "abc", "mode": "nope"})), "guide.invalid_spec")
	assert_eq(Result.code_of(_compiled({"target": "abc", "progression": "nope"})), "guide.invalid_spec")
	assert_eq(Result.code_of(_compiled({"target": "abc", "marks": [{"id": "a", "text": "zzz"}]})), "guide.invalid_spec")


func test_marks_must_be_ordered_and_non_overlapping() -> void:
	var compiled := Matcher.compile({
		"target": "abcab",
		"marks": [
			{"id": "late", "text": "bc"},
			{"id": "early", "text": "abc"},
		],
	})
	assert_eq(Result.code_of(compiled), "guide.invalid_spec", "a mark before the cursor cannot be resolved")

	var duplicate := Matcher.compile({
		"target": "abc",
		"marks": [{"id": "same", "text": "a"}, {"id": "same", "text": "b"}],
	})
	assert_eq(Result.code_of(duplicate), "guide.invalid_spec", "duplicate mark ids are refused")


func test_rtl_targets_are_refused() -> void:
	var compiled := Matcher.compile({"target": "שלום"})
	assert_eq(Result.code_of(compiled), "guide.unsupported", "RTL is out of scope in API 1")


func test_reconcile_tracks_prefix_and_divergence() -> void:
	var compiled := _compiled()
	var empty := Matcher.reconcile(compiled, "")
	check(bool(empty.get("on_track", false)), "empty buffer is on track")
	assert_eq(int(empty.get("prefix_cp", -1)), 0)
	assert_eq(int(empty.get("prefix_clusters", -1)), 0)

	var partial := Matcher.reconcile(compiled, "pri")
	check(bool(partial.get("on_track", false)), "partial prefix is on track")
	assert_eq(int(partial.get("prefix_cp", -1)), 3)
	assert_eq(str(partial.get("expected", "")), "n", "next expected cluster")

	var wrong := Matcher.reconcile(compiled, "prX")
	assert_false(bool(wrong.get("on_track", true)), "mismatch diverges")
	assert_eq(int(wrong.get("prefix_cp", -1)), 2, "prefix stops before the wrong character")

	var complete := Matcher.reconcile(compiled, str(compiled.get("target", "")))
	check(bool(complete.get("at_end", false)), "full target is at the end")


func test_reconcile_fast_path_matches_full_scan() -> void:
	var compiled := _compiled()
	var buffer := "print(\"Hel"
	var full := Matcher.reconcile(compiled, buffer)
	var fast := Matcher.reconcile(compiled, buffer, int(full.get("prefix_cp", 0)))
	assert_eq(fast, full, "the fast path returns the same result as a full scan")

	var wrong_fast := Matcher.reconcile(compiled, "print(\"Hex", 10)
	var wrong_full := Matcher.reconcile(compiled, "print(\"Hex")
	assert_eq(wrong_fast, wrong_full, "fast path falls back when the edit changed the prefix")


func test_half_typed_grapheme_stays_on_track() -> void:
	var compiled := Matcher.compile({"target": "e\u0301x"})
	assert_eq(int(compiled.get("cluster_count", 0)), 2, "combining mark is one cluster")
	assert_eq(int(compiled.get("target", "").length()), 3, "three codepoints")

	var base := Matcher.reconcile(compiled, "e")
	check(bool(base.get("on_track", false)), "base is a prefix")
	assert_eq(int(base.get("prefix_cp", -1)), 1, "the untyped combining mark is the next step")

	var full_cluster := Matcher.reconcile(compiled, "e\u0301")
	check(bool(full_cluster.get("on_track", false)), "the finished cluster is on track")
	assert_eq(int(full_cluster.get("prefix_cp", -1)), 2)

	var divergent := Matcher.reconcile(compiled, "ex")
	assert_false(bool(divergent.get("on_track", true)), "a wrong second codepoint diverges")


func test_ghost_scopes() -> void:
	var compiled := _compiled({"target": "ab\ncd\nef", "display": {"scope": "line", "chars": 64}})
	var line := Matcher.ghost(compiled, 0)
	assert_eq(str(line.get("next", "")), "a", "line ghost starts at the next cluster")
	assert_eq((line.get("lines", []) as Array).size(), 1, "line scope stays on the expected line")

	var next_char := Matcher.ghost(_compiled({"target": "ab\ncd\nef", "display": {"scope": "next_char"}}), 1)
	assert_eq(str(next_char.get("text", "")), "b", "next_char shows one cluster")

	var block := Matcher.ghost(_compiled({"target": "ab\ncd\nef", "display": {"scope": "block"}}), 0)
	assert_eq((block.get("lines", []) as Array).size(), 3, "block ghost spans the target")

	var capped := _compiled({"target": "abcdefghij", "display": {"scope": "block", "chars": 4}})
	var cut := Matcher.ghost(capped, 0)
	var shown := ""
	for row in cut.get("lines", []):
		shown += str((row as Dictionary).get("text", ""))
	assert_eq(shown.length(), 4, "chars cap is a hard cap")
	check(bool(cut.get("truncated", false)), "truncation is reported")


func test_progression_chunks() -> void:
	var compiled := _compiled({"target": "hello world\nnext"})
	assert_eq(Matcher.chunk(compiled, 0, "character"), "h", "character chunk is one cluster")
	assert_eq(Matcher.chunk(compiled, 0, "word"), "hello", "word chunk stops at the space")
	assert_eq(Matcher.chunk(compiled, 5, "word"), " ", "a space is accepted on its own")
	assert_eq(Matcher.chunk(compiled, 0, "line"), "hello world\n", "line chunk includes the newline")
	assert_eq(Matcher.chunk(compiled, 0, "none"), "", "none has no chunk")


func test_indentation_helpers() -> void:
	var compiled := _compiled({"target": "if x:\n    print(x)\n"})
	assert_eq(Matcher.indent_after(compiled, 5), "    ", "the next line's indent is exposed")
	assert_eq(Matcher.indent_after(compiled, 0), "", "no newline means no indent")
	assert_eq(Matcher.line_indent(compiled, 10), "    ", "current line indent")
	assert_eq(Matcher.line_start(compiled, 10), 6, "line start offset")
	assert_eq(Matcher.mark_starting_at(compiled, 0), "", "no mark at zero")
