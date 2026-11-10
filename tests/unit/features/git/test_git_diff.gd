extends "res://tests/support/test_case.gd"

const Diff = preload("res://src/features/git/git_diff.gd")


func test_unified_diff_is_parsed_into_hunks() -> void:
	var text := (
		"diff --git a/a.txt b/a.txt\n" +
		"index 111..222 100644\n" +
		"--- a/a.txt\n" +
		"+++ b/a.txt\n" +
		"@@ -1,3 +1,4 @@\n" +
		" line one\n" +
		"-old two\n" +
		"+new two\n" +
		"+new three\n" +
		" line three\n"
	)
	var parsed := Diff.parse_unified(text)
	assert_eq(parsed["additions"], 2)
	assert_eq(parsed["deletions"], 1)
	assert_eq((parsed["files"] as Array).size(), 1)

	var file: Dictionary = parsed["files"][0]
	assert_eq(file["old_path"], "a.txt")
	assert_eq(file["new_path"], "a.txt")
	assert_eq((file["hunks"] as Array).size(), 1)

	var hunk: Dictionary = file["hunks"][0]
	assert_eq(hunk["old_start"], 1)
	assert_eq(hunk["old_count"], 3)
	assert_eq(hunk["new_start"], 1)
	assert_eq(hunk["new_count"], 4)
	assert_eq((hunk["lines"] as Array).size(), 5)
	assert_eq(hunk["lines"][1]["kind"], "delete")
	assert_eq(hunk["lines"][2]["kind"], "add")
	assert_eq(hunk["lines"][3]["new_line"], 3)


func test_unified_diff_handles_multiple_files_and_no_newline_note() -> void:
	var text := (
		"diff --git a/one.txt b/one.txt\n" +
		"--- a/one.txt\n+++ b/one.txt\n" +
		"@@ -1 +1 @@\n-old\n+new\n" +
		"\\ No newline at end of file\n" +
		"diff --git a/two.txt b/two.txt\n" +
		"--- a/two.txt\n+++ b/two.txt\n" +
		"@@ -1,0 +1,1 @@\n+added\n"
	)
	var parsed := Diff.parse_unified(text)
	assert_eq((parsed["files"] as Array).size(), 2)
	assert_eq(parsed["additions"], 2)
	assert_eq(parsed["deletions"], 1)
	assert_eq(parsed["files"][0]["hunks"][0]["lines"][2]["kind"], "note")


func test_line_diff_finds_a_changed_line() -> void:
	var result := Diff.line_diff("one\ntwo\nthree", "one\nTWO\nthree")
	assert_eq(result["modified"], 1)
	assert_eq(result["added"], 0)
	assert_eq(result["deleted"], 0)
	assert_eq((result["rows"] as Array).size(), 3)
	assert_eq(result["rows"][1]["kind"], "modify")
	assert_eq(result["marks"][1], "modified")


func test_line_diff_marks_added_lines() -> void:
	var result := Diff.line_diff("one", "one\ntwo")
	assert_eq(result["added"], 1)
	assert_eq(result["marks"][1], "added")
	assert_eq(result["rows"][1]["new_line"], 2)


func test_line_diff_marks_deletions_on_the_next_surviving_line() -> void:
	var result := Diff.line_diff("one\ntwo\nthree", "one\nthree")
	assert_eq(result["deleted"], 1)
	assert_eq(result["marks"][1], "deleted")
	assert_eq(result["rows"][1]["kind"], "delete")


func test_line_diff_deletion_at_eof_marks_the_last_line() -> void:
	var result := Diff.line_diff("one\ntwo", "one")
	assert_eq(result["deleted"], 1)
	assert_eq(result["marks"][0], "deleted")


func test_line_diff_identical_buffers_have_no_marks() -> void:
	var result := Diff.line_diff("one\ntwo\n", "one\ntwo\n")
	assert_true((result["marks"] as Dictionary).is_empty() || int(result["marks"].get("_added", 0)) == 0)
	assert_eq(result["added"], 0)
	assert_eq(result["modified"], 0)
	assert_eq(result["deleted"], 0)
	for row in result["rows"]:
		assert_eq(row["kind"], "context")


func test_line_diff_pairs_a_replacement_block_for_side_by_side() -> void:
	var result := Diff.line_diff("one\nold a\nold b\nfour", "one\nnew a\nnew b\nfour")
	assert_eq(result["modified"], 2)
	var kinds: Array = []
	for row in result["rows"]:
		kinds.append(row["kind"])
	assert_eq(kinds, ["context", "modify", "modify", "context"])


func test_unified_rows_keep_diff_prefixes() -> void:
	var parsed := Diff.parse_unified(
		"diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new\n"
	)
	var rows := Diff.unified_lines(parsed)
	var texts: Array = []
	for row in rows:
		texts.append(row["text"])
	assert_true(texts.has("-old"))
	assert_true(texts.has("+new"))
	assert_true(texts.has("@@ -1 +1 @@"))
