class_name LanguageService
extends Node

## Caches per-extension language state: the Lua interpreter used for
## completion and the keyword/region registrations.
##
## Switching between tabs of the same language does not recreate the Lua state
## or re-run the .lua language file. The CodeHighlighter itself is built per
## view: Godot binds a highlighter to one TextEdit, and sharing it between tabs
## makes it read the last tab's lines and paint colors at the wrong columns.

## Extensions the editor can highlight through a sibling plugin. TypeScript is
## highlighted by the JavaScript plugin, C headers by C, SCSS by CSS, and so
## on. Without this mapping a real .ts/.h/.scss file asks for a plugin that was
## never shipped, gets an empty highlighter and renders as plain white text.
const EXTENSION_ALIASES := {
	"pyw": "py", "pyi": "py",
	"mjs": "js", "cjs": "js", "jsx": "js",
	"ts": "js", "tsx": "js", "mts": "js", "cts": "js",
	"h": "c",
	"cc": "cpp", "cxx": "cpp", "c++": "cpp",
	"hpp": "cpp", "hh": "cpp", "hxx": "cpp",
	"csx": "cs",
	"htm": "html", "xhtml": "html",
	"scss": "css", "less": "css",
	"jsonc": "json", "geojson": "json",
	"text": "txt", "log": "txt", "md": "txt", "markdown": "txt",
}

var _cache: Dictionary = {}
var _active_extension: String = ""
var _warned_extensions: Dictionary = {}


## Every cached state points at its LuaAPI and the LuaAPI holds callables
## bound to that state. That is a reference cycle a RefCounted pair cannot
## break on its own, so the cache is unwound explicitly.
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		for key in _cache.keys():
			var state: Variant = _cache[key]
			if state is Dictionary:
				(state as Dictionary)["lua"] = null
		_cache.clear()


## Resolved at runtime instead of using the autoload's global name, so this
## service also compiles in the headless test runner (which loads scripts
## before autoload globals are registered).
func _lua():
	var loop = Engine.get_main_loop()
	if loop == null:
		return null
	return loop.root.get_node_or_null("LuaSingleton")


## The actual .lua file to execute. The user copy wins so local edits keep
## working, but the bundled plugin is a safety net when seeding failed or the
## user deleted their copy.
func _plugin_path(key: String) -> String:
	if key.is_empty():
		return ""
	var user_path := "user://langs/" + key + ".lua"
	if FileAccess.file_exists(user_path):
		return user_path
	var bundled_path := "res://resources/lua/plugins/" + key + ".lua"
	if FileAccess.file_exists(bundled_path):
		return bundled_path
	return ""


## Returns the plugin extension that can actually be loaded for `extension`,
## or "" when there is neither a direct plugin nor an alias with one.
func _plugin_extension(extension: String) -> String:
	var key := extension.strip_edges().to_lower().trim_prefix(".")
	if key.is_empty():
		return ""
	if !_plugin_path(key).is_empty():
		return key
	var alias := str(EXTENSION_ALIASES.get(key, ""))
	if !alias.is_empty() and !_plugin_path(alias).is_empty():
		return alias
	return ""


## Whether Qorix ships (or the user installed) a working language file for
## this extension. Used by auto-detection to decide if the extension already
## answers the question, so a real .py file is never re-guessed from its
## contents. Aliases count: a .ts file is already answered by js.lua.
func has_language(extension: String) -> bool:
	var key := _plugin_extension(extension)
	if key.is_empty():
		return false
	if _cache.has(key):
		return !bool(_cache[key].get("error", false))
	return true


## The extension a highlighter/completion state should really use. Unknown
## extensions fall back to plain text so a missing plugin can never produce an
## empty highlighter (which looks like the syntax colors vanished).
func resolve_extension(extension: String) -> String:
	var key := _plugin_extension(extension)
	if !key.is_empty():
		return key

	var original := extension.strip_edges().to_lower().trim_prefix(".")
	if !original.is_empty() and original != "txt" and !_warned_extensions.has(original):
		_warned_extensions[original] = true
		_warn_unsupported(original, {})
	return "txt"


func get_extension(extension: String) -> Dictionary:
	var key := resolve_extension(extension)
	if _cache.has(key):
		return _cache[key]

	var state := _build_extension(key)
	if bool(state.get("error", false)) and key != "txt":
		# A plugin can exist but fail to load. Returning its half-built state
		# would leave the CodeEdit with a keyword-less highlighter, so use the
		# plain-text plugin instead and keep the error flag for callers that
		# skip completion on broken languages.
		var fallback := _build_extension("txt")
		fallback["error"] = true
		_cache[key] = fallback
		return fallback

	_cache[key] = state
	return state


func activate(extension: String) -> Dictionary:
	var state := get_extension(extension)
	_active_extension = str(state.get("extension", "txt"))
	return state


func active_extension() -> String:
	return _active_extension


## Builds a highlighter bound to one view. The parsed keywords and regions are
## cached, but the CodeHighlighter is not: two CodeEdits must never share one,
## or the highlighter reads whichever view bound it last and colors the other
## tab's text at the wrong columns.
func get_highlighter(extension: String) -> CodeHighlighter:
	var state := get_extension(extension)

	var lua = _lua()
	var palette: Dictionary = lua.keywords if lua != null else {}

	var highlighter := CodeHighlighter.new()
	highlighter.number_color = palette.get("binary", Color.WHITE)
	highlighter.symbol_color = palette.get("symbol", Color.WHITE)
	highlighter.function_color = palette.get("function", Color.WHITE)
	highlighter.member_variable_color = palette.get("member", Color.WHITE)

	var keywords: Dictionary = state.get("keywords", {})
	for keyword in keywords.keys():
		var color_name: String = str(keywords[keyword])
		if palette.has(color_name):
			highlighter.add_keyword_color(str(keyword), palette[color_name])

	var regions: Array = state.get("regions", [])
	for entry in regions:
		if entry.size() < 3:
			continue
		if highlighter.has_color_region(str(entry[0])):
			continue
		var color_name: String = str(entry[2])
		if !palette.has(color_name):
			continue
		highlighter.add_color_region(
			str(entry[0]),
			str(entry[1]),
			palette[color_name],
			bool(entry[3]) if entry.size() > 3 else false
		)

	return highlighter


func _build_extension(extension: String) -> Dictionary:
	var state := {
		"extension": extension,
		"keywords": {},
		"regions": [],
		"comments": [],
		"lua": null,
		"error": false,
		"warned": false,
	}

	var lua = LuaAPI.new()
	lua.bind_libraries(["base", "table", "string"])

	# bind() appends the state dictionary after the arguments supplied by Lua,
	# so registrations land in this language's own bucket instead of globals.
	lua.push_variant("highlight", _collect_keyword.bind(state))
	lua.push_variant("highlight_region", func(start, end, color, line_only = false):
		_collect_region(start, end, color, line_only, state)
	)
	lua.push_variant("add_comment", _collect_comment.bind(state))
	lua.push_variant("splitstr", _splitstr)
	lua.push_variant("trim", _trim)

	state["lua"] = lua

	var path := _plugin_path(extension)
	if path.is_empty():
		state["error"] = true
		_warn_unsupported(extension, state)
		return state

	var err = lua.do_file(path)
	if err is LuaError:
		state["error"] = true
		print("ERROR %d: %s" % [err.type, err.message])
		_warn_unsupported(extension, state)
		return state

	return state


func _collect_keyword(keyword: String, color: String, state: Dictionary) -> void:
	var lua = _lua()
	if lua == null or !lua.keywords.has(color):
		print("ERROR: provided color property (\"%s\") at \"%s\" is invalid." % [color, keyword])
		return

	state["keywords"][keyword] = color


func _collect_region(start: String, end: String, color: String, line_only: bool, state: Dictionary) -> void:
	var lua = _lua()
	if lua == null or !lua.keywords.has(color):
		print("ERROR: provided color (\"%s\") at color region (start: \"%s\", end: \"%s\") is invalid." % [color, start, end])
		return

	state["regions"].append([start, end, color, line_only])


func _collect_comment(comment: String, state: Dictionary) -> void:
	state["comments"].append(comment)


func _splitstr(input: String, separator: String):
	return input.split(separator)


func _trim(input: String):
	return input.strip_edges()


func _warn_unsupported(extension: String, state: Dictionary) -> void:
	if bool(state.get("warned", false)):
		return
	state["warned"] = true

	var lua = _lua()
	if lua == null or !lua.is_inside_tree():
		return
	lua._nodes()
	if lua.editor != null:
		lua.editor.warn("[color=yellow]WARNING[/color]: No syntax highlighter is available for .%s. Showing plain text; highlighting, autocomplete and comments for this file won’t work properly." % extension)
