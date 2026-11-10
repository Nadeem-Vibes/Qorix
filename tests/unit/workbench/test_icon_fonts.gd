extends "res://tests/support/test_case.gd"

## File-explorer rows are Nerd Font private-use glyphs. These checks catch a
## glyph that the bundled font cannot draw, and a Tree that is not using the
## font with icon fallbacks (the cause of the "icons do not load" report).

const FILE_TREE_SOURCE := "res://src/workbench/file_tree_panel.gd"
const NERD_FONT: FontFile = preload("res://resources/fonts/SymbolsNerdFontMono-Regular.ttf")


func _autoload(name: String):
	var loop = Engine.get_main_loop()
	if loop == null:
		return null
	return loop.root.get_node_or_null(name)


func _has_glyph(text: String) -> bool:
	return !text.is_empty() and NERD_FONT.has_char(text.unicode_at(0))


## Reads a `const NAME := "glyph"` value without preloading file_tree_panel.gd:
## that script depends on autoload globals, which are unavailable while the
## headless runner is compiling its suite list.
func _tree_glyph(name: String) -> String:
	var source := FileAccess.get_file_as_string(FILE_TREE_SOURCE)
	var marker := "const %s := \"" % name
	var start := source.find(marker)
	if start < 0:
		return ""
	start += marker.length()
	var end := source.find("\"", start)
	if end < 0:
		return ""
	return source.substr(start, end - start)


func test_every_icon_glyph_is_in_the_bundled_font() -> void:
	var icons = _autoload("Icons")
	assert_ne(icons, null, "Icons autoload is missing")
	if icons == null:
		return

	for entry in icons.ICONS:
		var glyph := str(entry.get("icon", ""))
		assert_true(_has_glyph(glyph), "font has no glyph for %s" % str(entry.get("extensions", [])))

	var fallback := str(icons.get_icon_data("unknown_extension").get("icon", ""))
	assert_true(_has_glyph(fallback), "font has no glyph for the generic file icon")


func test_file_tree_glyphs_are_in_the_bundled_font() -> void:
	assert_true(_has_glyph(_tree_glyph("FOLDER_GLYPH")), "font has no folder glyph")
	assert_true(_has_glyph(_tree_glyph("FOLDER_OPEN_GLYPH")), "font has no open-folder glyph")
	assert_true(_has_glyph(_tree_glyph("REFRESH_GLYPH")), "font has no refresh glyph")


func test_tree_theme_font_carries_icon_fallbacks() -> void:
	var lua = _autoload("LuaSingleton")
	assert_ne(lua, null, "LuaSingleton autoload is missing")
	if lua == null:
		return

	lua.setup_font_fallbacks()
	var font: Font = lua.editor_theme.get_font("font", "Tree")
	assert_ne(font, null, "theme has no Tree font")
	if font == null:
		return

	assert_true(font.has_char(0xF4D3), "Tree font cannot draw the folder glyph")
	assert_true(font.has_char(0xE606), "Tree font cannot draw the Python glyph")
