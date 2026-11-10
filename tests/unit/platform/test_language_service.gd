extends "res://tests/support/test_case.gd"

## Extensions without their own Lua plugin must borrow a sibling plugin or
## fall back to plain text. Returning an empty highlighter made supported
## files (.ts, .h, .scss) look like their syntax colors had disappeared.


func _service():
	return LanguageService.new()


func test_extension_aliases_use_a_shipped_plugin() -> void:
	var service = _service()

	assert_eq(service.resolve_extension("ts"), "js")
	assert_eq(service.resolve_extension("tsx"), "js")
	assert_eq(service.resolve_extension("h"), "c")
	assert_eq(service.resolve_extension("hpp"), "cpp")
	assert_eq(service.resolve_extension("scss"), "css")
	assert_eq(service.resolve_extension("jsonc"), "json")
	assert_eq(service.resolve_extension("pyi"), "py")
	assert_eq(service.resolve_extension("txt"), "txt")
	service.free()


func test_unknown_extension_falls_back_to_plain_text() -> void:
	var service = _service()

	assert_eq(service.resolve_extension("rs"), "txt")
	assert_false(service.has_language("rs"))
	assert_true(service.has_language("ts"))
	service.free()


func test_each_view_gets_its_own_highlighter() -> void:
	var service = _service()

	# A CodeHighlighter binds to one TextEdit. Sharing the instance between
	# two tabs makes it read the last tab's lines, which paints colors at the
	# wrong columns (the "random colors" bug).
	var first: CodeHighlighter = service.get_highlighter("py")
	var second: CodeHighlighter = service.get_highlighter("py")

	assert_ne(first, null)
	assert_ne(second, null)
	assert_ne(first, second)
	assert_eq(first.get_keyword_color("import"), second.get_keyword_color("import"))
	service.free()
