extends "res://tests/support/test_case.gd"

const SearchText = preload("res://src/platform/search_text.gd")


func test_find_columns_is_case_insensitive_by_default() -> void:
	assert_eq(SearchText.find_columns("Hello hello HELLO", "hello"), [0, 6, 12])
	assert_eq(SearchText.find_columns("Hello hello", "hello", true), [6])


func test_find_columns_returns_no_matches_for_empty_query() -> void:
	assert_eq(SearchText.find_columns("anything", ""), [])


func test_replace_all_is_literal_and_reports_the_count() -> void:
	var result: Dictionary = SearchText.replace_all("Foo foo food", "foo", "bar")
	assert_eq(result.get("count"), 3)
	assert_eq(result.get("text"), "bar bar bard")


func test_replace_all_can_match_case() -> void:
	var result: Dictionary = SearchText.replace_all("Foo foo", "foo", "bar", true)
	assert_eq(result.get("count"), 1)
	assert_eq(result.get("text"), "Foo bar")


func test_replace_all_with_an_empty_query_is_a_no_op() -> void:
	var result: Dictionary = SearchText.replace_all("abc", "", "x")
	assert_eq(result.get("count"), 0)
	assert_eq(result.get("text"), "abc")


func test_preview_short_lines_are_trimmed() -> void:
	assert_eq(SearchText.preview_of("    if ready:", 4, 2), "if ready:")
	assert_eq(SearchText.preview_of("\treturn value", 1, 6), "return value")


func test_preview_clips_long_lines_around_the_match() -> void:
	var line := "start " + "x".repeat(300) + " needle " + "y".repeat(300)
	var preview: String = SearchText.preview_of(line, 308, 6, 80)

	assert_true(preview.length() <= 82, "preview should be clipped")
	assert_true(preview.contains("needle"))
	assert_true(preview.begins_with("…") or preview.ends_with("…"))


func test_binary_probe_detects_nul_bytes() -> void:
	assert_true(SearchText.is_binary(PackedByteArray([97, 98, 99, 0, 100])))
	assert_false(SearchText.is_binary("plain source code\n".to_utf8_buffer()))
	assert_false(SearchText.is_binary("normal text with a lone glyph é".to_utf8_buffer()))
