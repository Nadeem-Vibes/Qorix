extends "res://tests/support/test_case.gd"

const OutputLinks = preload("res://src/features/run/output_links.gd")
const Paths = preload("res://src/base/path_utils.gd")

const TEST_DIR := "user://tests_output_links"

var file_path := ""
var root := ""


func before_each() -> void:
	_remove_dir(TEST_DIR)
	DirAccess.make_dir_recursive_absolute(_root())
	root = _root()
	file_path = root.path_join("main.py")
	var file := FileAccess.open(file_path, FileAccess.WRITE)
	file.store_string("import sys\nprint(\"[1]\")\n")


func after_each() -> void:
	_remove_dir(TEST_DIR)


func _remove_dir(path: String) -> void:
	var global := ProjectSettings.globalize_path(path)
	var dir := DirAccess.open(global)
	if dir == null:
		return
	for file in dir.get_files():
		DirAccess.remove_absolute(global.path_join(file))
	for folder in dir.get_directories():
		_remove_dir(path.path_join(folder))
	DirAccess.remove_absolute(global)


func _root() -> String:
	return ProjectSettings.globalize_path(TEST_DIR).replace("\\", "/")


func _decode_meta(linkified: String) -> Dictionary:
	var start := linkified.find("griddy:")
	if start < 0:
		return {}
	var end := linkified.find("]", start)
	if end < 0:
		return {}
	var encoded := linkified.substr(start + 7, end - start - 7)
	var payload: Variant = JSON.parse_string(Marshalls.base64_to_utf8(encoded))
	return payload if payload is Dictionary else {}


func test_the_pattern_compiles() -> void:
	var regex := OutputLinks.compile()

	assert_eq(regex.get_pattern(), OutputLinks.FILE_LINE_PATTERN)


func test_python_file_headers_are_parsed() -> void:
	var output := "Traceback (most recent call last):\n  File \"%s\", line 2, in <module>\nSyntaxError: bad\n" % file_path
	var links := OutputLinks.find_links(output, OutputLinks.compile())

	assert_eq(links.size(), 1)
	var link: Dictionary = links[0]
	assert_eq(link.get("path"), file_path)
	assert_eq(link.get("line"), 2)
	assert_eq(link.get("column"), 0)
	var raw := str(link.get("raw", ""))
	assert_true(raw.contains("File \""))
	assert_true(raw.contains("line 2"))
	assert_eq(output.substr(int(link.get("start", 0)), int(link.get("end", 0)) - int(link.get("start", 0))), raw)


func test_generic_path_line_column_is_parsed() -> void:
	var links := OutputLinks.find_links("src/main.py:12:4: error: expected ';'", OutputLinks.compile())

	assert_eq(links.size(), 1)
	var link: Dictionary = links[0]
	assert_eq(link.get("path"), "src/main.py")
	assert_eq(link.get("line"), 12)
	assert_eq(link.get("column"), 4)


func test_a_generic_path_without_a_column_is_parsed() -> void:
	var links := OutputLinks.find_links("C:/build/app.c:9: warning: unused", OutputLinks.compile())

	assert_eq(links.size(), 1)
	assert_eq(links[0].get("path"), "C:/build/app.c")
	assert_eq(links[0].get("line"), 9)
	assert_eq(links[0].get("column"), 0)


func test_an_existing_python_file_becomes_a_clickable_link() -> void:
	var output := "Traceback (most recent call last):\n  File \"%s\", line 2, in <module>\n    print(\"[1]\")\nSyntaxError: invalid syntax\n" % file_path
	var linkified: String = OutputLinks.linkify(output)

	assert_true(linkified.contains("[url=griddy:"))
	assert_true(linkified.contains("[lb]1]"), "BBCode brackets in output must be escaped")
	assert_false(linkified.contains("print(\"[1]\")"), "raw brackets must not survive")

	var payload := _decode_meta(linkified)
	assert_eq(payload.get("kind"), "open")
	assert_eq(payload.get("path"), file_path)
	assert_eq(payload.get("line"), 2)
	assert_eq(payload.get("column"), 0)


func test_a_missing_file_stays_plain_text() -> void:
	var missing := root.path_join("ghost.py")
	var output := "  File \"%s\", line 3\nSyntaxError: nope\n" % missing
	var linkified: String = OutputLinks.linkify(output)

	assert_false(linkified.contains("[url=griddy:"))
	assert_true(linkified.contains("ghost.py"))


func test_a_relative_path_uses_the_run_cwd() -> void:
	var output := "  File \"main.py\", line 1\nSyntaxError: nope\n"
	var linkified: String = OutputLinks.linkify(output, null, root)
	var payload := _decode_meta(linkified)

	assert_eq(payload.get("path"), Paths.normalize(file_path))
	assert_eq(payload.get("line"), 1)


func test_a_relative_path_falls_back_to_the_workspace() -> void:
	var linkified: String = OutputLinks.linkify("main.py:1: bad", null, "", root)
	var payload := _decode_meta(linkified)

	assert_eq(payload.get("path"), Paths.normalize(file_path))


func test_a_relative_path_falls_back_to_the_source_folder() -> void:
	var source := root.path_join("source.gd")
	var linkified: String = OutputLinks.linkify("main.py:1: bad", null, "", "", source)
	var payload := _decode_meta(linkified)

	assert_eq(payload.get("path"), Paths.normalize(file_path))


func test_an_unresolvable_relative_path_is_returned_as_written() -> void:
	assert_eq(OutputLinks.resolve_path("missing.py", root), "missing.py")


func test_an_absolute_existing_path_is_normalized() -> void:
	var backslashes := file_path.replace("/", "\\")

	assert_eq(OutputLinks.resolve_path(backslashes), file_path)


func test_linkable_requires_an_existing_file_and_a_positive_line() -> void:
	assert_true(OutputLinks.linkable(file_path, 1))
	assert_false(OutputLinks.linkable(file_path, 0))
	assert_false(OutputLinks.linkable(root.path_join("ghost.py"), 1))
	assert_false(OutputLinks.linkable("", 1))


func test_bbcode_brackets_are_escaped() -> void:
	assert_eq(OutputLinks.escape("[b]bold[/b]"), "[lb]b]bold[lb]/b]")


func test_meta_payload_round_trips() -> void:
	var payload := {"kind": "open", "path": "C:/work/main.py", "line": 3, "column": 2}
	var meta: String = OutputLinks.meta(payload)

	assert_true(meta.begins_with("griddy:"))
	var decoded: Variant = JSON.parse_string(Marshalls.base64_to_utf8(meta.substr(7)))
	assert_true(decoded is Dictionary)
	if !(decoded is Dictionary):
		return
	assert_eq(decoded.get("kind"), "open")
	assert_eq(decoded.get("path"), "C:/work/main.py")
	assert_eq(int(decoded.get("line", 0)), 3)
	assert_eq(int(decoded.get("column", 0)), 2)


func test_linkified_output_keeps_the_text_around_the_link() -> void:
	var output := "before\n  File \"%s\", line 2\n    print(\"x\")\nafter\n" % file_path
	var linkified: String = OutputLinks.linkify(output)

	assert_true(linkified.begins_with("before\n"))
	assert_true(linkified.ends_with("    print(\"x\")\nafter\n"))


func test_two_existing_errors_become_two_links() -> void:
	var output := "main.py:1:1: first\nmain.py:2:1: second\n"
	var linkified: String = OutputLinks.linkify(output, null, root)

	var first := linkified.find("[url=griddy:")
	var second := linkified.find("[url=griddy:", first + 1)
	assert_true(first >= 0)
	assert_true(second > first)
	assert_eq(linkified.count("[url=griddy:"), 2)
	assert_eq(linkified.count("[/url]"), 2)
