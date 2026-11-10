extends "res://tests/support/test_case.gd"

const Scan = preload("res://src/platform/completion_scan.gd")


func _lines(count: int, filler: String = "") -> Array:
	var out: Array = []
	for i in range(count):
		out.append("line %d%s" % [i, filler])
	return out


func test_short_text_is_returned_untouched() -> void:
	var text := "func main():\n\tpass"
	var result: Dictionary = Scan.window(text, 1, 1)

	assert_eq(result.get("text"), text)
	assert_eq(result.get("truncated"), false)
	assert_eq(result.get("line"), 1)
	assert_eq(result.get("column"), 1)


func test_a_large_file_is_cut_around_the_caret() -> void:
	var text := "\n".join(_lines(7000))
	var result: Dictionary = Scan.window(text, 5500, 3, 50000, 1000)

	assert_eq(result.get("truncated"), true)
	var window_lines: PackedStringArray = str(result.get("text")).split("\n")
	assert_true(window_lines.size() <= 1000)
	# 200 lines of context above the caret are kept by default.
	assert_eq(int(result.get("line")), 200)
	assert_eq(str(window_lines[int(result.get("line"))]), "line 5500")
	assert_eq(int(result.get("column")), 3)


func test_the_character_cap_still_keeps_the_caret_line() -> void:
	var lines: Array = []
	for i in range(400):
		lines.append("x".repeat(500) + " %d" % i)
	var text := "\n".join(lines)
	var result: Dictionary = Scan.window(text, 300, 10, 5000, 4000)

	assert_eq(result.get("truncated"), true)
	assert_true(str(result.get("text")).length() <= 5000)

	var window_lines: PackedStringArray = str(result.get("text")).split("\n")
	var local_line := int(result.get("line"))
	assert_true(local_line >= 0)
	assert_true(local_line < window_lines.size())
	assert_true(str(window_lines[local_line]).ends_with(" 300"), "the caret line must survive the cut")
