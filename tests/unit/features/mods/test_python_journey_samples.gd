extends "res://tests/support/test_case.gd"

## Phase 4 sample: five lessons, hybrid phases, progress, hints, localization,
## accessibility copy and the partial-UI fallback. The suite executes the
## data-only Lua files through LuaAPI and compiles every runtime module, so a
## content typo or a Lua syntax error fails CI without a window.

const Manifest = preload("res://src/features/mods/mod_manifest.gd")
const Permissions = preload("res://src/features/mods/mod_permissions.gd")
const Catalog = preload("res://src/features/mods/ui/mod_widget_catalog.gd")

const ID := "griddycode.python_journey"
const ROOT := "res://samples/mods/griddycode.python_journey/1.0.0"
const EXPECTED_LESSONS := [
	"lessons/01_hello.lua",
	"lessons/02_variables.lua",
	"lessons/03_types.lua",
	"lessons/04_conditionals.lua",
	"lessons/05_loops.lua",
]
const EXPECTED_PERMISSIONS := [
	"ui.shell",
	"documents.read",
	"documents.write",
	"files.read",
	"files.write",
	"workspace.read",
	"run",
]
const SETTINGS := {
	"strict_mode": "bool",
	"show_hints": "bool",
	"font_size": "int",
}


func _source(relative: String) -> String:
	return FileAccess.get_file_as_string(ROOT.path_join(relative))


func _compile_error(path: String) -> String:
	var source := FileAccess.get_file_as_string(path)
	if source.is_empty():
		return "the file is missing or empty"
	var lua = LuaAPI.new()
	lua.bind_libraries(["base", "table", "string"])
	lua.push_variant("__src", source)
	lua.push_variant("__name", path)
	var err: Variant = lua.do_string(
		"local chunk, message = load(__src, '@' .. __name); if chunk == nil then error(message) end"
	)
	if err is LuaError:
		return str(err.message)
	return ""


## Runs a data-only chunk and returns its table. Lesson files and the locale
## table never touch `editor`, so they are safe to execute in a bare Lua state.
func _data(path: String) -> Dictionary:
	var source := FileAccess.get_file_as_string(path)
	if source.is_empty():
		return {"ok": false, "error": "the file is missing or empty"}
	var lua = LuaAPI.new()
	lua.bind_libraries(["base", "table", "string"])
	lua.push_variant("__src", source)
	lua.push_variant("__name", path)
	var err: Variant = lua.do_string(
		"local chunk, message = load(__src, '@' .. __name); if chunk == nil then error(message) end; __value = chunk()"
	)
	if err is LuaError:
		return {"ok": false, "error": str(err.message)}
	var value: Variant = lua.pull_variant("__value")
	if value == null:
		return {"ok": false, "error": "the chunk returned nil"}
	return {"ok": true, "value": value}


func _lesson(path: String) -> Dictionary:
	var result := _data(ROOT.path_join("content").path_join(path))
	if !result.get("ok", false):
		return {}
	var value: Variant = result.get("value")
	if value is Dictionary:
		return value
	return {}


func _all_lua_files() -> Array[String]:
	var out: Array[String] = [ROOT.path_join("main.lua")]
	for folder in ["lib", "content", "content/lessons", "content/locales"]:
		var dir := DirAccess.open(ROOT.path_join(folder))
		if dir == null:
			continue
		for name in dir.get_files():
			if str(name).ends_with(".lua"):
				out.append(ROOT.path_join(folder).path_join(str(name)))
	return out


func test_manifest_declares_the_phase4_surface() -> void:
	var result: Dictionary = Manifest.read_manifest(
		ROOT.path_join("manifest.json"),
		{"root": ROOT},
	)
	check(result.get("ok", false), "manifest validates: %s" % str(result.get("errors", [])))
	if !result.get("ok", false):
		return

	var manifest: Dictionary = result.get("manifest", {})
	assert_eq(str(manifest.get("id", "")), ID, "manifest id")
	assert_eq(int(manifest.get("api", 0)), 1, "API version")
	assert_eq(str(manifest.get("version", "")), "1.0.0", "sample version")
	assert_eq(str(manifest.get("min_editor", "")), "1.4.0", "minimum editor version")
	check(
		FileAccess.file_exists(ROOT.path_join(str(manifest.get("entry", "")))),
		"entry exists",
	)

	var declared: Array = manifest.get("permissions", [])
	for permission in EXPECTED_PERMISSIONS:
		check(declared.has(permission), "declares %s" % permission)
	for permission in declared:
		var name := str(permission)
		check(Permissions.CATALOGUE.has(name), "permission is catalogued: %s" % name)
		if Permissions.CATALOGUE.has(name):
			check(
				bool((Permissions.CATALOGUE[name] as Dictionary).get("available", false)),
				"permission is available in v1: %s" % name,
			)
	check(!declared.has("network"), "does not ask for network access")
	check(!declared.has("input.observe"), "does not ask for raw input")

	var definitions: Dictionary = {}
	for raw in manifest.get("settings", []):
		if raw is Dictionary:
			definitions[str((raw as Dictionary).get("key", ""))] = raw
	assert_eq(definitions.size(), SETTINGS.size(), "declared settings")
	for key in SETTINGS:
		check(definitions.has(key), "declares the %s setting" % key)
		if !definitions.has(key):
			continue
		var definition: Dictionary = definitions[key]
		assert_eq(str(definition.get("type", "")), SETTINGS[key], "%s type" % key)
		if key == "font_size":
			assert_eq(int(definition.get("min", 0)), 12, "font_size minimum")
			assert_eq(int(definition.get("max", 0)), 32, "font_size maximum")


func test_every_sample_lua_file_compiles() -> void:
	var files := _all_lua_files()
	assert_true(files.size() >= 13, "expected the main, lib, content and locale files")
	for path in files:
		assert_eq(_compile_error(path), "", "%s compiles" % path.get_file())


func test_course_index_lists_five_ordered_lessons() -> void:
	var index := _data(ROOT.path_join("content/index.lua"))
	check(index.get("ok", false), "course index loads")
	if !index.get("ok", false):
		return
	var paths: Variant = index.get("value")
	assert_true(paths is Array, "course index returns an array")
	if !(paths is Array):
		return
	assert_eq((paths as Array).size(), EXPECTED_LESSONS.size(), "lesson count")
	for position in range(EXPECTED_LESSONS.size()):
		if position < (paths as Array).size():
			assert_eq(str((paths as Array)[position]), EXPECTED_LESSONS[position], "lesson %d order" % position)
		check(
			FileAccess.file_exists(ROOT.path_join("content").path_join(EXPECTED_LESSONS[position])),
			"%s exists" % EXPECTED_LESSONS[position],
		)


func test_each_lesson_is_a_two_phase_exercise() -> void:
	var ids: Dictionary = {}
	var files: Dictionary = {}
	var numbers: Dictionary = {}
	for path in EXPECTED_LESSONS:
		var lesson := _lesson(path)
		check(!lesson.is_empty(), "%s returns a lesson table" % path)
		if lesson.is_empty():
			continue

		var id := str(lesson.get("id", ""))
		check(!id.is_empty(), "%s has an id" % path)
		check(!ids.has(id), "%s id is unique" % path)
		ids[id] = true

		var number := int(lesson.get("number", 0))
		check(number >= 1 and number <= EXPECTED_LESSONS.size(), "%s has a lesson number" % path)
		check(!numbers.has(number), "%s lesson number is unique" % path)
		numbers[number] = true

		var title := str(lesson.get("title", ""))
		var summary := str(lesson.get("summary", ""))
		var coach := str(lesson.get("coach", ""))
		check(!title.is_empty(), "%s has a title" % path)
		check(!summary.is_empty(), "%s has a summary" % path)
		check(!coach.is_empty(), "%s has coach copy" % path)

		var file_path := str(lesson.get("file", ""))
		check(file_path.begins_with("python_journey/"), "%s uses the course folder" % path)
		check(file_path.ends_with(".py"), "%s lesson file is Python" % path)
		check(!files.has(file_path), "%s lesson file is unique" % path)
		files[file_path] = true
		check(file_path == "python_journey/%s.py" % id, "%s file matches its id" % path)

		var exercise: Variant = lesson.get("exercise")
		check(exercise is Dictionary, "%s has an exercise" % path)
		if !(exercise is Dictionary):
			continue
		var exercise_data: Dictionary = exercise

		var typing: Variant = exercise_data.get("typing")
		check(typing is Dictionary, "%s has a typing phase" % path)
		if typing is Dictionary:
			_check_typing(path, typing)

		var freeform: Variant = exercise_data.get("freeform")
		check(freeform is Dictionary, "%s has a freeform phase" % path)
		if freeform is Dictionary:
			_check_freeform(path, freeform)


func _check_typing(path: String, typing: Dictionary) -> void:
	var target := str(typing.get("target", ""))
	check(!target.is_empty(), "%s typing target is non-empty" % path)
	check(target.ends_with("\n"), "%s typing target ends with a newline" % path)
	check(!target.contains("\t"), "%s typing target uses spaces" % path)
	for line in target.split("\n"):
		if line.begins_with(" "):
			var spaces := line.length() - line.strip_edges(true, false).length()
			check(spaces % 4 == 0, "%s indents Python by four spaces" % path)

	var marks: Variant = typing.get("marks")
	check(marks is Array and !(marks as Array).is_empty(), "%s typing marks exist" % path)
	if marks is Array:
		for mark in marks:
			check(mark is Dictionary, "%s mark is an object" % path)
			if mark is Dictionary:
				check(!str((mark as Dictionary).get("id", "")).is_empty(), "%s mark has an id" % path)
				check(!str((mark as Dictionary).get("text", "")).is_empty(), "%s mark has text" % path)

	var hints: Variant = typing.get("hints")
	check(hints is Array and !(hints as Array).is_empty(), "%s typing hints exist" % path)
	if hints is Array:
		for hint in hints:
			check(hint is Dictionary, "%s hint is an object" % path)
			if hint is Dictionary:
				var data: Dictionary = hint
				check(!str(data.get("on", "")).is_empty(), "%s hint has a trigger" % path)
				check(!str(data.get("text", "")).is_empty(), "%s hint has text" % path)


func _check_freeform(path: String, freeform: Dictionary) -> void:
	check(!str(freeform.get("prompt", "")).is_empty(), "%s freeform prompt exists" % path)
	check(!str(freeform.get("example", "")).is_empty(), "%s freeform example exists" % path)
	check(!str(freeform.get("hint", "")).is_empty(), "%s freeform hint exists" % path)
	check(!str(freeform.get("example", "")).contains("\t"), "%s example uses spaces" % path)

	var run: Variant = freeform.get("run")
	check(run is Dictionary, "%s has run validation" % path)
	if run is Dictionary:
		var tests: Variant = (run as Dictionary).get("tests")
		check(tests is Array and !(tests as Array).is_empty(), "%s run tests exist" % path)
		var has_stdout := false
		var has_exit := false
		if tests is Array:
			for test in tests:
				check(test is Dictionary, "%s run test is an object" % path)
				if !(test is Dictionary):
					continue
				var kind := str((test as Dictionary).get("type", ""))
				check(
					kind in ["stdout_contains", "stdout_regex", "exit_code"],
					"%s run test type %s" % [path, kind],
				)
				has_stdout = has_stdout or kind.begins_with("stdout_")
				has_exit = has_exit or kind == "exit_code"
		check(has_stdout, "%s run validation checks program output" % path)
		check(has_exit, "%s run validation checks the exit code" % path)

	var text: Variant = freeform.get("text")
	check(text is Dictionary, "%s has text fallback validation" % path)
	if text is Dictionary:
		var tests: Variant = (text as Dictionary).get("tests")
		check(tests is Array and !(tests as Array).is_empty(), "%s text tests exist" % path)
		if tests is Array:
			for test in tests:
				check(test is Dictionary, "%s text test is an object" % path)
				if test is Dictionary:
					var kind := str((test as Dictionary).get("type", ""))
					check(
						kind in ["exact_text", "contains", "regex"],
						"%s text test type %s" % [path, kind],
					)


func test_every_module_returns_a_table() -> void:
	for module in ["course", "engine", "i18n", "layout", "progress"]:
		var lua = LuaAPI.new()
		lua.bind_libraries(["base", "table", "string"])
		lua.push_variant("__src", _source("lib/%s.lua" % module))
		var err: Variant = lua.do_string("""
			__i18n = { t = function(key) return key end }
			function require(path) return __i18n end
			local chunk = assert(load(__src, '@module.lua'))
			__ok = type(chunk()) == "table"
		""")
		check(!(err is LuaError), "%s loads: %s" % [module, str(err.message) if err is LuaError else ""])
		check(bool(lua.pull_variant("__ok")), "%s returns its table" % module)


func test_engine_builds_a_typing_then_freeform_hybrid() -> void:
	var lesson := _lesson(EXPECTED_LESSONS[0])
	check(!lesson.is_empty(), "lesson data loads")
	if lesson.is_empty():
		return

	var lua = LuaAPI.new()
	lua.bind_libraries(["base", "table", "string"])
	lua.push_variant("__lesson", lesson)
	lua.push_variant("__engine_src", _source("lib/engine.lua"))
	var err: Variant = lua.do_string("""
		local chunk = assert(load(__engine_src, '@engine.lua'))
		__engine = chunk()
		__text_phases = __engine.build_phases(__lesson, false, true)
		__run_phases = __engine.build_phases(__lesson, true, true)
		__typing_state = { state = "active", phase_kind = "typing" }
		__freeform_state = { state = "active", phase_kind = "freeform" }
		__pending_state = { state = "validating", phase_kind = "freeform" }
		__done_state = { state = "completed" }
		__failed_state = { state = "failed", phase_kind = "freeform" }
		__step_typing = __engine.step(__typing_state)
		__step_freeform = __engine.step(__freeform_state)
		__step_pending = __engine.step(__pending_state)
		__step_done = __engine.step(__done_state)
		__step_failed = __engine.step(__failed_state)
		__check_freeform = __engine.can_check(__freeform_state)
		__check_typing = __engine.can_check(__typing_state)
		__check_pending = __engine.can_check(__pending_state)
		__is_pending = __engine.is_pending(__pending_state)
		__is_done = __engine.is_done(__done_state)
		__typing_hint = __engine.hint_for(__lesson, "typing")
		__freeform_hint = __engine.hint_for(__lesson, "freeform")
	""")
	assert_false(err is LuaError, "engine module executes: %s" % (str(err.message) if err is LuaError else ""))

	var text_phases: Variant = lua.pull_variant("__text_phases")
	var run_phases: Variant = lua.pull_variant("__run_phases")
	check(text_phases is Array, "engine returns phases")
	if text_phases is Array:
		assert_eq((text_phases as Array).size(), 2, "two phases")
		var first: Dictionary = (text_phases as Array)[0]
		var second: Dictionary = (text_phases as Array)[1]
		assert_eq(str(first.get("kind", "")), "typing", "first phase is typing")
		assert_eq(str(second.get("kind", "")), "freeform", "second phase is freeform")
		assert_eq(str(first.get("mode", "")), "strict", "strict mode reaches the typing phase")
		var validation: Dictionary = second.get("validation", {})
		var tests: Array = validation.get("tests", [])
		check(!tests.is_empty(), "text fallback validation is embedded")
		if !tests.is_empty():
			assert_eq(str((tests[0] as Dictionary).get("type", "")), "contains", "text fallback uses text checks")
	if run_phases is Array:
		var validation: Dictionary = ((run_phases as Array)[1] as Dictionary).get("validation", {})
		var tests: Array = validation.get("tests", [])
		check(!tests.is_empty(), "run validation is embedded")
		if !tests.is_empty():
			assert_eq(str((tests[0] as Dictionary).get("type", "")), "stdout_contains", "run path uses run checks")

	assert_eq(str(lua.pull_variant("__step_typing")), "typing", "typing state maps to the typing step")
	assert_eq(str(lua.pull_variant("__step_freeform")), "freeform", "freeform state maps to the freeform step")
	assert_eq(str(lua.pull_variant("__step_pending")), "checking", "validating state maps to checking")
	assert_eq(str(lua.pull_variant("__step_done")), "done", "completed state maps to done")
	assert_eq(str(lua.pull_variant("__step_failed")), "freeform", "failed freeform state keeps the freeform step")
	assert_true(bool(lua.pull_variant("__check_freeform")), "freeform can be checked")
	assert_false(bool(lua.pull_variant("__check_typing")), "typing cannot be checked")
	assert_false(bool(lua.pull_variant("__check_pending")), "a pending check cannot be submitted again")
	assert_true(bool(lua.pull_variant("__is_pending")), "pending state is detected")
	assert_true(bool(lua.pull_variant("__is_done")), "completed state is detected")
	check(!str(lua.pull_variant("__typing_hint")).is_empty(), "typing hint comes from the lesson")
	check(!str(lua.pull_variant("__freeform_hint")).is_empty(), "freeform hint comes from the lesson")


func test_course_navigation_helpers() -> void:
	var items: Array = []
	for path in EXPECTED_LESSONS:
		var lesson := _lesson(path)
		if !lesson.is_empty():
			items.append({"id": str(lesson.get("id", "")), "file": str(lesson.get("file", ""))})
	assert_eq(items.size(), EXPECTED_LESSONS.size(), "navigation fixture")

	var lua = LuaAPI.new()
	lua.bind_libraries(["base", "table", "string"])
	lua.push_variant("__items", items)
	lua.push_variant("__course_src", _source("lib/course.lua"))
	var err: Variant = lua.do_string("""
		local chunk = assert(load(__course_src, '@course.lua'))
		__course = chunk()
		__found = __course.find(__items, "03_types")
		__position = __course.position(__items, "04_conditionals")
		__next = __course.next(__items, "02_variables")
		__last_next = __course.next(__items, "05_loops")
		__previous = __course.previous(__items, "02_variables")
		__first_previous = __course.previous(__items, "01_hello")
		__first_incomplete = __course.first_incomplete(__items, function(id) return id == "01_hello" end)
		__fallback_file = __course.file_path({ id = "99_custom" })
	""")
	assert_false(err is LuaError, "course module executes: %s" % (str(err.message) if err is LuaError else ""))

	var found: Variant = lua.pull_variant("__found")
	check(found is Dictionary, "find returns the lesson")
	if found is Dictionary:
		assert_eq(str((found as Dictionary).get("id", "")), "03_types", "find returns the right lesson")
	assert_eq(int(lua.pull_variant("__position")), 4, "position is one-based")
	var next: Variant = lua.pull_variant("__next")
	check(next is Dictionary, "next returns a lesson")
	if next is Dictionary:
		assert_eq(str((next as Dictionary).get("id", "")), "03_types", "next lesson")
	assert_eq(lua.pull_variant("__last_next"), null, "the last lesson has no next")
	var previous: Variant = lua.pull_variant("__previous")
	check(previous is Dictionary, "previous returns a lesson")
	if previous is Dictionary:
		assert_eq(str((previous as Dictionary).get("id", "")), "01_hello", "previous lesson")
	assert_eq(lua.pull_variant("__first_previous"), null, "the first lesson has no previous")
	var first_incomplete: Variant = lua.pull_variant("__first_incomplete")
	check(first_incomplete is Dictionary, "first_incomplete returns a lesson")
	if first_incomplete is Dictionary:
		assert_eq(str((first_incomplete as Dictionary).get("id", "")), "02_variables", "first incomplete lesson")
	assert_eq(str(lua.pull_variant("__fallback_file")), "python_journey/99_custom.py", "default lesson file path")


func test_locale_tables_have_the_same_keys() -> void:
	var lua_result := _data(ROOT.path_join("content/locales/en.lua"))
	check(lua_result.get("ok", false), "runtime locale loads")
	if !lua_result.get("ok", false):
		return
	var lua_locale: Variant = lua_result.get("value")
	check(lua_locale is Dictionary, "runtime locale returns a table")
	if !(lua_locale is Dictionary):
		return

	var json_text := FileAccess.get_file_as_string(ROOT.path_join("locales/en.json"))
	var parsed: Variant = JSON.parse_string(json_text)
	check(parsed is Dictionary, "translation template parses")
	if !(parsed is Dictionary):
		return
	var json_locale: Dictionary = parsed

	var lua_keys: Array = (lua_locale as Dictionary).keys()
	lua_keys.sort()
	var json_keys: Array = json_locale.keys()
	json_keys.sort()
	assert_eq(lua_keys.size(), json_keys.size(), "the two locale files list the same number of keys")
	for key in lua_keys:
		check(json_locale.has(key), "translation template has %s" % key)
		check(
			typeof((lua_locale as Dictionary)[key]) == TYPE_STRING,
			"runtime %s is a string" % key,
		)
		check(
			typeof(json_locale.get(key)) == TYPE_STRING,
			"template %s is a string" % key,
		)
	for key in json_keys:
		check((lua_locale as Dictionary).has(key), "runtime locale has %s" % key)
	assert_eq(str((lua_locale as Dictionary).get("app.title", "")), "Python Learning Journey", "app title")


func test_locale_interpolation_and_missing_fallbacks() -> void:
	var locale_result := _data(ROOT.path_join("content/locales/en.lua"))
	if !locale_result.get("ok", false):
		check(false, "runtime locale loads")
		return

	var lua = LuaAPI.new()
	lua.bind_libraries(["base", "table", "string"])
	lua.push_variant("__locale", locale_result.get("value"))
	lua.push_variant("__i18n_src", _source("lib/i18n.lua"))
	var err: Variant = lua.do_string("""
		editor = {
			content = { load = function(path) return __locale end },
			log = { warn = function(message) end },
		}
		local chunk = assert(load(__i18n_src, '@i18n.lua'))
		__i18n = chunk()
		__interpolated = __i18n.t("course.progress", { done = 2, total = 5 })
		__missing = __i18n.t("missing.key")
		__has_title = __i18n.has("app.title")
		__has_missing = __i18n.has("missing.key")
	""")
	assert_false(err is LuaError, "i18n module executes: %s" % (str(err.message) if err is LuaError else ""))
	assert_eq(str(lua.pull_variant("__interpolated")), "2 of 5 lessons complete", "placeholders interpolate")
	assert_eq(str(lua.pull_variant("__missing")), "missing.key", "a missing key falls back to itself")
	assert_true(bool(lua.pull_variant("__has_title")), "has() finds a real key")
	assert_false(bool(lua.pull_variant("__has_missing")), "has() rejects a missing key")

	var fallback_lua = LuaAPI.new()
	fallback_lua.bind_libraries(["base", "table", "string"])
	fallback_lua.push_variant("__i18n_src", _source("lib/i18n.lua"))
	var fallback_err: Variant = fallback_lua.do_string("""
		editor = {
			content = { load = function(path) return nil, { code = "module.not_found" } end },
			log = { warn = function(message) end },
		}
		local chunk = assert(load(__i18n_src, '@i18n.lua'))
		__i18n = chunk()
		__fallback = __i18n.t("partial.reason.permission")
	""")
	assert_false(
		fallback_err is LuaError,
		"i18n module executes without a locale: %s" % (str(fallback_err.message) if fallback_err is LuaError else ""),
	)
	check(
		str(fallback_lua.pull_variant("__fallback")).contains("ui.shell"),
		"the fallback copy explains the missing shell permission",
	)


func test_locale_keys_used_by_the_ui_exist() -> void:
	var locale_result := _data(ROOT.path_join("content/locales/en.lua"))
	if !locale_result.get("ok", false):
		check(false, "runtime locale loads")
		return
	var locale: Dictionary = locale_result.get("value")

	var regex := RegEx.new()
	regex.compile("\\bt\\(\"([A-Za-z0-9_.]+)\"")
	for relative in ["main.lua", "lib/layout.lua"]:
		var source := _source(relative)
		for match in regex.search_all(source):
			var key := match.get_string(1)
			check(locale.has(key), "%s uses a defined key: %s" % [relative, key])

	for key in [
		"course.run.no_workspace",
		"course.run.no_trust",
		"course.run.no_permission",
		"course.run.no_file",
		"partial.reason.permission",
		"partial.reason.failed",
		"partial.reason.slot",
	]:
		check(locale.has(key), "fallback reason is translated: %s" % key)

	for pair in [
		["course.progress", ["done", "total"]],
		["coach.step", ["index", "total", "kind"]],
		["a11y.progress", ["done", "total"]],
		["a11y.lesson_button", ["number", "title", "status"]],
		["course.status.no_run", ["reason"]],
		["partial.reason.failed", ["code"]],
		["partial.reason.slot", ["code"]],
	]:
		var key := str(pair[0])
		var text := str(locale.get(key, ""))
		for token in pair[1]:
			check(text.contains("{%s}" % str(token)), "%s keeps the {%s} placeholder" % [key, str(token)])


func test_settings_and_capabilities_used_are_declared() -> void:
	var manifest_result: Dictionary = Manifest.read_manifest(
		ROOT.path_join("manifest.json"),
		{"root": ROOT},
	)
	if !manifest_result.get("ok", false):
		check(false, "manifest validates")
		return
	var manifest: Dictionary = manifest_result.get("manifest", {})
	var declared: Array = manifest.get("permissions", [])
	var setting_keys: Array[String] = []
	for raw in manifest.get("settings", []):
		if raw is Dictionary:
			setting_keys.append(str((raw as Dictionary).get("key", "")))

	var source := _source("main.lua")
	for module in ["course", "engine", "i18n", "layout", "progress"]:
		source += _source("lib/%s.lua" % module)
	for pair in [
		["editor.ui.shell.takeover", "ui.shell"],
		["editor.ui.shell.exit", "ui.shell"],
		["editor.docs.open", "documents.write"],
		["editor.docs.set_text", "documents.write"],
		["editor.files.exists", "files.read"],
		["editor.files.write", "files.write"],
		["editor.workspace.has_workspace", "workspace.read"],
		["editor.exercise.start", "documents.read"],
		["editor.exercise.submit", "documents.read"],
		["editor.progress", "core"],
	]:
		var call := str(pair[0])
		var permission := str(pair[1])
		check(source.contains(call), "sample uses %s" % call)
		if permission != "core":
			check(declared.has(permission), "manifest declares %s for %s" % [permission, call])

	var setting_regex := RegEx.new()
	setting_regex.compile("\\bsetting\\(\"([a-z0-9_]+)\"")
	for match in setting_regex.search_all(_source("main.lua")):
		var key := match.get_string(1)
		check(setting_keys.has(key), "manifest declares the %s setting" % key)


func test_layout_specs_validate_and_build_within_budget() -> void:
	var locale_result := _data(ROOT.path_join("content/locales/en.lua"))
	if !locale_result.get("ok", false):
		check(false, "runtime locale loads")
		return

	var lua = LuaAPI.new()
	lua.bind_libraries(["base", "table", "string", "math"])
	lua.push_variant("__locale", locale_result.get("value"))
	lua.push_variant("__i18n_src", _source("lib/i18n.lua"))
	lua.push_variant("__layout_src", _source("lib/layout.lua"))
	var started := Time.get_ticks_usec()
	var err: Variant = lua.do_string("""
		editor = {
			content = { load = function(path) return __locale end },
			log = { warn = function(message) end },
		}
		local i18n_chunk = assert(load(__i18n_src, '@i18n.lua'))
		local I18n = i18n_chunk()
		function require(path) return I18n end
		local layout_chunk = assert(load(__layout_src, '@layout.lua'))
		local Layout = layout_chunk()

		local lesson = {
			id = "03_types", number = 3, title = "Types",
			summary = "Numbers and text are different types.",
			coach = "type() names a value.",
		}
		local lessons = {
			{ id = "01_hello", number = 1, title = "Hello" },
			{ id = "02_variables", number = 2, title = "Variables" },
			lesson,
			{ id = "04_conditionals", number = 4, title = "Conditionals" },
			{ id = "05_loops", number = 5, title = "Loops" },
		}
		local state = {
			lessons = lessons, lesson = lesson,
			completed = { ["01_hello"] = true, ["02_variables"] = true },
			typed = { ["03_types"] = true },
			done_count = 2, total = 5,
			step = "freeform", status = "Freeform", hint = "Add a type() call.",
			prompt = "Print the type.", target = "print(type(3))",
			use_run = true, run_note = "Run check: the saved file runs.",
			font_size = 18,
			can_start = true, can_check = true, can_retry = true,
			can_hint = true, can_next_lesson = true,
			nav_previous = true, nav_next = true,
			has_exercise = true, partial_reason = "Side panel fallback.",
		}

		__full = Layout.full(state)
		__partial = Layout.partial(state)
		__built = 0
		for index = 1, 100 do
			local spec = Layout.full(state)
			if type(spec) == "table" and spec.type == "vbox" then
				__built = __built + 1
			end
		end
	""")
	var elapsed_ms := float(Time.get_ticks_usec() - started) / 1000.0
	check(!(err is LuaError), "layout module executes: %s" % (str(err.message) if err is LuaError else ""))
	if err is LuaError:
		return

	var full: Variant = lua.pull_variant("__full")
	var partial: Variant = lua.pull_variant("__partial")
	check(full is Dictionary, "the full layout returns a spec")
	check(partial is Dictionary, "the partial layout returns a spec")
	if full is Dictionary:
		var result: Dictionary = Catalog.validate(full)
		check(result.get("ok", false), "the full layout satisfies the widget catalog: %s" % str(result.get("error", "")))
		var built: Control = Catalog.new().build(full, ID)
		var row_title = built.find_child("ModWidget_course_title", true, false)
		check(row_title is Label, "the course title builds in the top row")
		var workspace = built.find_child("ModWidget_workspace", true, false)
		check(workspace is VBoxContainer, "the lesson workspace column builds")
		var heading_panel = built.find_child("ModWidget_lesson_header", true, false)
		check(heading_panel is PanelContainer, "the lesson heading has its own panel")
		if heading_panel is PanelContainer:
			var frame = (heading_panel as PanelContainer).get_child(0)
			check(frame.get_node_or_null("TitleRow") == null, "the heading panel does not duplicate the lesson title")
		check(built.find_child("ModWidget_lesson_title", true, false) is Label, "the lesson heading is still present")
		var editor_slot = built.find_child("ModWidget_code", true, false)
		check(editor_slot is Control, "the reserved editor slot builds")
		if editor_slot is Control:
			check(
				(editor_slot as Control).mouse_filter == Control.MOUSE_FILTER_IGNORE,
				"the editor slot lets clicks reach the real CodeEdit",
			)
			var ancestor: Node = editor_slot.get_parent()
			var covered := false
			while ancestor != null:
				if ancestor is PanelContainer:
					covered = true
					break
				ancestor = ancestor.get_parent()
			check(!covered, "the editor slot has no opaque panel ancestor")
		built.free()
	if partial is Dictionary:
		var result: Dictionary = Catalog.validate(partial)
		check(result.get("ok", false), "the partial layout satisfies the widget catalog: %s" % str(result.get("error", "")))
	assert_eq(int(lua.pull_variant("__built")), 100, "100 full layouts build")
	# 100 builds include locale lookups and table construction. The window
	# budget is a lesson switch under 100 ms; a headless build must be far under
	# that, so 2 seconds for the batch is a generous regression guard.
	check(elapsed_ms < 2000.0, "100 full layouts stay under the headless budget (%.1f ms)" % elapsed_ms)


func test_accessibility_and_partial_fallback_copy() -> void:
	var main := _source("main.lua")
	var layout := _source("lib/layout.lua")
	var partial := layout.substr(maxi(0, layout.find("function M.partial")))

	for needle in [
		"partial.reason.permission",
		"partial.reason.failed",
		"partial.reason.slot",
		"editor.ui.mount(\"right\"",
		"editor.ui.mount(\"center\"",
		"editor.permissions.has(\"ui.shell\")",
	]:
		check(main.contains(needle), "main.lua handles %s" % needle)

	for needle in ["partial_reason", "partial.why", "course.progress"]:
		check(partial.contains(needle), "the partial panel includes %s" % needle)

	check(layout.contains("a11y.lesson_button"), "lesson buttons expose accessible labels")
	check(layout.contains("a11y.progress"), "progress exposes an accessible label")
	check(layout.contains("tooltip ="), "controls carry tooltips")
	check(main.contains("Ctrl+Alt+J"), "the course has a keyboard shortcut")
	check(main.contains("Ctrl+Alt+N"), "next lesson has a keyboard shortcut")
	check(main.contains("Ctrl+Alt+P"), "previous lesson has a keyboard shortcut")
	check(main.contains("Ctrl+Alt+H"), "hint has a keyboard shortcut")
	check(main.contains("function deactivate()"), "the mod can be deactivated cleanly")

	var locale_result := _data(ROOT.path_join("content/locales/en.lua"))
	if locale_result.get("ok", false):
		var locale: Dictionary = locale_result.get("value")
		var help := str(locale.get("course.help.body", ""))
		check(help.contains("Tab"), "help explains keyboard focus")
		check(help.contains("Enter"), "help explains activation")
		check(help.contains("Ctrl+Alt+Shift+Esc"), "help explains the panic exit")
		check(!str(locale.get("partial.why", "")).is_empty(), "the fallback explains itself")
		check(!str(locale.get("partial.reason.permission", "")).is_empty(), "the fallback names the permission")
	else:
		check(false, "runtime locale loads")
