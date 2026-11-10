extends "res://tests/support/test_case.gd"

## Every bundled language plugin must execute without a Lua error. A plugin
## that loads partially still returns a state dictionary, so a runtime error
## used to surface only as "all syntax colors are gone" in the editor.

const PLUGIN_DIR := "res://resources/lua/plugins"


func _load_plugin(path: String) -> Dictionary:
	var keywords: Dictionary = {}
	var regions: Array = []
	var comments: Array = []

	var lua = LuaAPI.new()
	lua.bind_libraries(["base", "table", "string"])
	lua.push_variant("highlight", func(keyword, color):
		keywords[str(keyword)] = str(color)
	)
	lua.push_variant("highlight_region", func(start, end, color, line_only = false):
		regions.append([str(start), str(end), str(color), bool(line_only)])
	)
	lua.push_variant("add_comment", func(comment):
		comments.append(str(comment))
	)
	lua.push_variant("splitstr", func(input, separator):
		return str(input).split(str(separator))
	)
	lua.push_variant("trim", func(input):
		return str(input).strip_edges()
	)

	var err = lua.do_file(path)
	var error_message := ""
	if err is LuaError:
		error_message = str(err.message)

	return {
		"error": error_message,
		"keywords": keywords,
		"regions": regions,
		"comments": comments,
	}


func test_every_bundled_language_plugin_loads() -> void:
	var dir := DirAccess.open(PLUGIN_DIR)
	assert_ne(dir, null, "missing %s" % PLUGIN_DIR)
	if dir == null:
		return

	var files: Array = []
	for file in dir.get_files():
		if file.ends_with(".lua"):
			files.append(file)
	assert_true(files.size() >= 16, "expected all bundled plugins, found %d" % files.size())

	for file in files:
		var state := _load_plugin(PLUGIN_DIR.path_join(file))
		assert_eq(str(state.get("error", "")), "", "%s failed to load" % file)

		# txt.lua is intentionally empty: it exists so plain-text buffers do
		# not warn. Every other plugin must register at least one token.
		if file != "txt.lua":
			var keywords: Dictionary = state.get("keywords", {})
			var regions: Array = state.get("regions", [])
			assert_true(keywords.size() > 0 or regions.size() > 0, "%s registered no highlighting" % file)


func test_css_registers_keywords() -> void:
	var state := _load_plugin(PLUGIN_DIR.path_join("css.lua"))

	assert_eq(str(state.get("error", "")), "")
	var keywords: Dictionary = state.get("keywords", {})
	assert_true(keywords.has("color"), "css.lua did not register the color property")
	assert_true(keywords.size() > 100, "css.lua registered too few keywords")
