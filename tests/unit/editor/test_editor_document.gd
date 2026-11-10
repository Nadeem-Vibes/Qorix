extends "res://tests/support/test_case.gd"

const Document = preload("res://src/editor/document.gd")


func test_pending_text_is_returned_before_a_view_exists() -> void:
	var document = Document.new()
	document.set_pending_text("hello")

	assert_eq(document.text(), "hello")


func test_untitled_document_uses_a_safe_title_and_extension() -> void:
	var document = Document.new()

	assert_eq(document.extension(), "txt")
	assert_eq(document.title(), "Untitled")


func test_title_prefers_the_display_name() -> void:
	var document = Document.new()
	document.path = "C:/work/example.py"
	document.display_name = "example.py"

	assert_eq(document.title(), "example.py")


func test_title_falls_back_to_the_path() -> void:
	var document = Document.new()
	document.path = "C:/work/example.py"

	assert_eq(document.title(), "example.py")


func test_extension_is_read_from_the_path() -> void:
	var document = Document.new()
	document.path = "C:/work/example.gd"

	assert_eq(document.extension(), "gd")


func test_line_endings_are_detected() -> void:
	var document = Document.new()

	document.set_pending_text("one\ntwo")
	assert_eq(document.line_endings, "LF")

	document.set_pending_text("one\r\ntwo")
	assert_eq(document.line_endings, "CRLF")

	document.set_pending_text("one\rtwo")
	assert_eq(document.line_endings, "CR")


func test_utf8_bom_is_detected() -> void:
	var document = Document.new()

	document.set_pending_text("plain")
	assert_eq(document.encoding, "UTF-8")

	document.set_pending_text("\ufeffwith a bom")
	assert_eq(document.encoding, "UTF-8 BOM")


func test_mark_dirty_and_clean_toggle_the_flag() -> void:
	var document = Document.new()

	assert_false(document.modified)

	document.mark_dirty()
	assert_true(document.modified)

	document.mark_clean()
	assert_false(document.modified)
