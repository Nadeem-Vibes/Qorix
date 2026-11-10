extends "res://tests/support/test_case.gd"

## C++ Learning Journey: the second real course. The suite executes the
## data-only Lua lessons, compiles every runtime module, drives main.lua against
## a sandbox stub, validates the declarative layouts and, when g++ is on PATH,
## compiles and runs every freeform example and checks its declared assertions.

const Manifest = preload("res://src/features/mods/mod_manifest.gd")
const Permissions = preload("res://src/features/mods/mod_permissions.gd")
const Catalog = preload("res://src/features/mods/ui/mod_widget_catalog.gd")

const ID := "griddycode.cpp_journey"
const ROOT := "res://samples/mods/griddycode.cpp_journey/1.0.0"
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
const REQUIRED_CPP := {
	"01_hello": ["#include <iostream>", "int main()", "std::cout", "return 0;"],
	"02_variables": ["std::string", "int age", "std::cout"],
	"03_types": ["int count", "double price", "char grade", "bool ready", "std::string label"],
	"04_conditionals": ["if (score >= 60)", "pass"],
	"05_loops": ["for (int i = 1; i <= 5; ++i)", "std::cout << i"],
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


func _balanced(text: String) -> bool:
	var opens := text.count("{")
	var closes := text.count("}")
	return opens > 0 and opens == closes


func _text_checks(source: String, tests: Array) -> Array:
	var failures: Array = []
	for raw in tests:
		if !(raw is Dictionary):
			failures.append("a test is not an object")
			continue
		var test: Dictionary = raw
		var name := str(test.get("name", ""))
		var kind := str(test.get("type", ""))
		var value := str(test.get("value", ""))
		var passed := false
		match kind:
			"contains":
				passed = source.contains(value)
			"exact_text":
				passed = source == value
			"regex":
				var regex := RegEx.new()
				passed = regex.compile(value) == OK and regex.search(source) != null
		if !passed:
			failures.append("%s (%s)" % [name, kind])
	return failures


func _check_typing(path: String, lesson_id: String, typing: Dictionary) -> void:
	var target := str(typing.get("target", ""))
	check(!target.is_empty(), "%s typing target is non-empty" % path)
	check(target.ends_with("\n"), "%s typing target ends with a newline" % path)
	check(!target.contains("\t"), "%s typing target uses spaces" % path)
	check(target.contains("#include <iostream>"), "%s includes iostream" % path)
	check(target.contains("int main()"), "%s defines main" % path)
	check(target.contains("return 0;"), "%s returns from main" % path)
	check(_balanced(target), "%s has balanced braces" % path)
	check(target.contains("std::"), "%s uses the std namespace explicitly" % path)
	check(!target.contains("print("), "%s is not Python" % path)
	check(!target.contains("def "), "%s has no Python function" % path)
	for line in target.split("\n"):
		if line.begins_with(" "):
			var spaces := line.length() - line.strip_edges(true, false).length()
			check(spaces % 4 == 0, "%s indents C++ by four spaces" % path)
	for token in REQUIRED_CPP.get(lesson_id, []):
		check(target.contains(str(token)), "%s teaches %s" % [path, token])

	var marks: Variant = typing.get("marks")
	check(marks is Array and !(marks as Array).is_empty(), "%s typing marks exist" % path)
	var mark_ids: Dictionary = {}
	if marks is Array:
		for raw in marks:
			check(raw is Dictionary, "%s mark is an object" % path)
			if !(raw is Dictionary):
				continue
			var mark: Dictionary = raw
			var mark_id := str(mark.get("id", ""))
			var mark_text := str(mark.get("text", ""))
			check(!mark_id.is_empty(), "%s mark has an id" % path)
			check(!mark_ids.has(mark_id), "%s mark ids are unique" % path)
			mark_ids[mark_id] = true
			check(!mark_text.is_empty(), "%s mark has text" % path)
			check(target.contains(mark_text), "%s mark text appears in the target" % path)

	var hints: Variant = typing.get("hints")
	check(hints is Array and !(hints as Array).is_empty(), "%s typing hints exist" % path)
	var has_complete := false
	if hints is Array:
		for raw in hints:
			check(raw is Dictionary, "%s hint is an object" % path)
			if !(raw is Dictionary):
				continue
			var hint: Dictionary = raw
			var trigger := str(hint.get("on", ""))
			check(trigger in ["start", "mark", "mistake", "complete"], "%s hint trigger %s" % [path, trigger])
			check(!str(hint.get("text", "")).is_empty(), "%s hint has text" % path)
			if trigger == "mark":
				check(mark_ids.has(str(hint.get("mark", ""))), "%s hint names a real mark" % path)
			if trigger == "complete":
				has_complete = true
	check(has_complete, "%s has a completion hint" % path)


func _check_freeform(path: String, freeform: Dictionary) -> void:
	var example := str(freeform.get("example", ""))
	check(!str(freeform.get("prompt", "")).is_empty(), "%s freeform prompt exists" % path)
	check(!str(freeform.get("hint", "")).is_empty(), "%s freeform hint exists" % path)
	check(!example.is_empty(), "%s freeform example exists" % path)
	check(!example.contains("\t"), "%s example uses spaces" % path)
	check(example.contains("#include <iostream>"), "%s example includes iostream" % path)
	check(example.contains("int main()"), "%s example defines main" % path)
	check(example.contains("return 0;"), "%s example returns from main" % path)
	check(_balanced(example), "%s example has balanced braces" % path)
	check(!example.contains("print("), "%s example is not Python" % path)
	check(!example.contains("def "), "%s example has no Python function" % path)

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
			var failures := _text_checks(example, tests)
			check(failures.is_empty(), "%s example passes its text fallback: %s" % [path, str(failures)])


func test_manifest_declares_the_cpp_course_surface() -> void:
	var result: Dictionary = Manifest.read_manifest(
		ROOT.path_join("manifest.json"),
		{"root": ROOT},
	)
	check(result.get("ok", false), "manifest validates: %s" % str(result.get("errors", [])))
	if !result.get("ok", false):
		return

	var manifest: Dictionary = result.get("manifest", {})
	assert_eq(str(manifest.get("id", "")), ID, "manifest id")
	assert_eq(str(manifest.get("name", "")), "C++ Learning Journey", "manifest name")
	assert_eq(int(manifest.get("api", 0)), 1, "API version")
	assert_eq(str(manifest.get("version", "")), "1.0.0", "sample version")
	assert_eq(str(manifest.get("min_editor", "")), "1.4.0", "minimum editor version")
	assert_eq(str(manifest.get("license", "")), "MIT", "license")
	check(str(manifest.get("description", "")).contains("C++"), "description names C++")
	check(FileAccess.file_exists(ROOT.path_join(str(manifest.get("entry", "")))), "entry exists")

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


func test_every_cpp_course_lua_file_compiles() -> void:
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


func test_each_lesson_is_a_valid_cpp_exercise() -> void:
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

		check(!str(lesson.get("title", "")).is_empty(), "%s has a title" % path)
		check(!str(lesson.get("summary", "")).is_empty(), "%s has a summary" % path)
		check(!str(lesson.get("coach", "")).is_empty(), "%s has coach copy" % path)

		var file_path := str(lesson.get("file", ""))
		check(file_path.begins_with("cpp_journey/"), "%s uses the course folder" % path)
		check(file_path.ends_with(".cpp"), "%s lesson file is C++" % path)
		check(!files.has(file_path), "%s lesson file is unique" % path)
		files[file_path] = true
		check(file_path == "cpp_journey/%s.cpp" % id, "%s file matches its id" % path)

		var exercise: Variant = lesson.get("exercise")
		check(exercise is Dictionary, "%s has an exercise" % path)
		if !(exercise is Dictionary):
			continue
		var exercise_data: Dictionary = exercise

		var typing: Variant = exercise_data.get("typing")
		check(typing is Dictionary, "%s has a typing phase" % path)
		if typing is Dictionary:
			_check_typing(path, id, typing)

		var freeform: Variant = exercise_data.get("freeform")
		check(freeform is Dictionary, "%s has a freeform phase" % path)
		if freeform is Dictionary:
			_check_freeform(path, freeform)


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
		__step_typing = __engine.step({ state = "active", phase_kind = "typing" })
		__step_freeform = __engine.step({ state = "active", phase_kind = "freeform" })
		__step_pending = __engine.step({ state = "validating", phase_kind = "freeform" })
		__step_done = __engine.step({ state = "completed" })
		__step_failed = __engine.step({ state = "failed", phase_kind = "freeform" })
		__check_freeform = __engine.can_check({ state = "active", phase_kind = "freeform" })
		__check_typing = __engine.can_check({ state = "active", phase_kind = "typing" })
		__check_pending = __engine.can_check({ state = "validating", phase_kind = "freeform" })
		__is_pending = __engine.is_pending({ state = "validating" })
		__is_done = __engine.is_done({ state = "completed" })
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


func test_course_navigation_helpers_use_cpp_paths() -> void:
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
	assert_eq(str(lua.pull_variant("__fallback_file")), "cpp_journey/99_custom.cpp", "default lesson file path")


func test_locale_tables_match_and_are_cpp_specific() -> void:
	var lua_result := _data(ROOT.path_join("content/locales/en.lua"))
	check(lua_result.get("ok", false), "runtime locale loads")
	if !lua_result.get("ok", false):
		return
	var lua_locale: Variant = lua_result.get("value")
	check(lua_locale is Dictionary, "runtime locale returns a table")
	if !(lua_locale is Dictionary):
		return

	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(ROOT.path_join("locales/en.json")))
	check(parsed is Dictionary, "translation template parses")
	if !(parsed is Dictionary):
		return
	var json_locale: Dictionary = parsed
	var lua_keys: Array = (lua_locale as Dictionary).keys()
	lua_keys.sort()
	var json_keys: Array = json_locale.keys()
	json_keys.sort()
	assert_eq(lua_keys.size(), json_keys.size(), "the two locale files list the same number of keys")
	check(lua_keys.size() >= 80, "the locale covers the full course chrome")
	for key in lua_keys:
		check(json_locale.has(key), "translation template has %s" % key)
		check(typeof((lua_locale as Dictionary)[key]) == TYPE_STRING, "runtime %s is a string" % key)
		check(typeof(json_locale.get(key)) == TYPE_STRING, "template %s is a string" % key)
	for key in json_keys:
		check((lua_locale as Dictionary).has(key), "runtime locale has %s" % key)

	assert_eq(str((lua_locale as Dictionary).get("app.title", "")), "C++ Learning Journey", "app title")
	for key in ["course.help.title", "partial.title", "onboarding.title", "notice.no_course"]:
		var text := str((lua_locale as Dictionary).get(key, ""))
		check(text.contains("C++"), "%s is C++-specific" % key)
		check(!text.to_lower().contains("python"), "%s does not mention Python" % key)
	var help := str((lua_locale as Dictionary).get("course.help.body", ""))
	check(help.contains("g++") or help.contains("clang++"), "help names a C++ compiler")
	check(help.contains("Ctrl+Alt+Shift+Esc"), "help explains the panic exit")
	check(help.contains("Tab") and help.contains("Enter"), "help explains keyboard use")
	check(str((lua_locale as Dictionary).get("onboarding.bullet.files", "")).contains("cpp_journey/"), "onboarding names the C++ folder")
	for key in json_locale:
		check(!str(json_locale[key]).to_lower().contains("python"), "template %s does not mention Python" % key)


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


func test_layout_specs_validate_with_cpp_copy() -> void:
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
			coach = "A type fixes what a variable can store.",
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
			step = "freeform", status = "Freeform", hint = "Use std::boolalpha.",
			prompt = "Print the types.", target = "std::cout << count",
			use_run = true, run_note = "Compile check: the saved file runs.",
			font_size = 18,
			can_start = true, can_check = true, can_retry = true,
			can_hint = true, can_next_lesson = true,
			nav_previous = true, nav_next = true,
			has_exercise = true, partial_reason = "Side panel fallback.",
		}

		__full = Layout.full(state)
		__partial = Layout.partial(state)
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
		if row_title is Label:
			check((row_title as Label).autowrap_mode == TextServer.AUTOWRAP_OFF, "the course title keeps its text width")
			check((row_title as Label).get_combined_minimum_size().x > 100.0, "the course title is wider than one letter")
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
	if partial is Dictionary:
		var result: Dictionary = Catalog.validate(partial)
		check(result.get("ok", false), "the partial layout satisfies the widget catalog: %s" % str(result.get("error", "")))
	check(elapsed_ms < 1000.0, "a full layout builds quickly (%.1f ms)" % elapsed_ms)
	check(_source("lib/layout.lua").contains("a11y.lesson_button"), "lesson buttons expose accessible labels")
	check(_source("lib/layout.lua").contains("a11y.progress"), "progress exposes an accessible label")


func test_command_surface_and_shortcuts_are_cpp_specific() -> void:
	var main := _source("main.lua")
	for command in [
		"griddycode.cpp_journey.open",
		"griddycode.cpp_journey.next",
		"griddycode.cpp_journey.previous",
		"griddycode.cpp_journey.hint",
		"griddycode.cpp_journey.help",
		"griddycode.cpp_journey.leave",
	]:
		check(main.contains(command), "registers %s" % command)
	for shortcut in ["Ctrl+Alt+C", "Ctrl+Alt+Shift+N", "Ctrl+Alt+Shift+B", "Ctrl+Alt+Shift+H"]:
		check(main.contains(shortcut), "binds %s" % shortcut)
	check(!main.contains("griddycode.python_journey"), "does not reuse Python command ids")
	check(!main.contains("Ctrl+Alt+J"), "does not collide with the Python course shortcut")
	check(main.contains("function deactivate()"), "the mod can be deactivated cleanly")
	check(_source("lib/course.lua").contains("cpp_journey/"), "the course writes to the cpp_journey folder")
	check(_source("lib/course.lua").contains(".cpp"), "the course writes .cpp files")
	var readme := FileAccess.get_file_as_string(ROOT.path_join("README.md"))
	check(readme.contains("g++"), "the README documents the compiler")
	check(readme.contains("cpp_journey/01_hello.cpp"), "the README names the lesson files")
	check(readme.to_lower().contains("text checks"), "the README documents the fallback")


func test_freeform_examples_compile_and_run_with_gpp() -> void:
	var probe: Array = []
	var available := OS.execute("g++", PackedStringArray(["--version"]), probe, true) == 0
	if !available:
		check(true, "g++ is not installed; the real compile check was skipped")
		return
	check(true, "g++ is available for the real compile check")

	var root := ProjectSettings.globalize_path("user://phase7_cpp_compile_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(root)
	var suffix := ".exe" if OS.get_name() == "Windows" else ""
	var compiled := 0
	for position in range(EXPECTED_LESSONS.size()):
		var lesson := _lesson(EXPECTED_LESSONS[position])
		if lesson.is_empty():
			check(false, "lesson %d loads" % position)
			continue
		var exercise: Dictionary = lesson.get("exercise", {})
		var freeform: Dictionary = exercise.get("freeform", {})
		var example := str(freeform.get("example", ""))
		var base := "lesson_%d" % (position + 1)
		var source_path := root.path_join(base + ".cpp")
		var exe_path := root.path_join(base + suffix)
		var file := FileAccess.open(source_path, FileAccess.WRITE)
		check(file != null, "%s is writable" % source_path.get_file())
		if file == null:
			continue
		file.store_string(example)
		file.close()

		var compile_output: Array = []
		var compile_args := PackedStringArray(["-std=c++17", "-Wall", "-Wextra", source_path, "-o", exe_path])
		var compile_code := OS.execute("g++", compile_args, compile_output, true)
		assert_eq(compile_code, 0, "%s compiles: %s" % [base, _joined(compile_output)])
		if compile_code != 0:
			continue
		compiled += 1

		var run_output: Array = []
		var run_code := OS.execute(exe_path, PackedStringArray(), run_output, true)
		var text := _joined(run_output)
		var tests: Array = (freeform.get("run", {}) as Dictionary).get("tests", [])
		for raw in tests:
			if !(raw is Dictionary):
				continue
			var test: Dictionary = raw
			var kind := str(test.get("type", ""))
			var value := str(test.get("value", ""))
			var name := str(test.get("name", ""))
			match kind:
				"stdout_contains":
					check(text.contains(value), "%s %s: stdout contains %s" % [base, name, value])
				"stdout_regex":
					var regex := RegEx.new()
					var compiled_regex := regex.compile(value) == OK
					check(compiled_regex, "%s %s: regex compiles" % [base, name])
					if compiled_regex:
						check(regex.search(text) != null, "%s %s: stdout matches %s" % [base, name, value])
				"exit_code":
					assert_eq(run_code, int(value), "%s %s: exit code" % [base, name])
	assert_eq(compiled, EXPECTED_LESSONS.size(), "every freeform example compiled")
	_remove_tree(root)


func _joined(output: Array) -> String:
	var text := ""
	for part in output:
		text += str(part)
	return text


func _remove_tree(path: String) -> void:
	if path.is_empty() or !DirAccess.dir_exists_absolute(path):
		return
	for name in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(name))
	for name in DirAccess.get_directories_at(path):
		var child := path.path_join(name)
		_remove_tree(child)
		DirAccess.remove_absolute(child)
	DirAccess.remove_absolute(path)


func test_main_runtime_flow_against_a_sandbox_stub() -> void:
	var lua = LuaAPI.new()
	lua.bind_libraries(["base", "table", "string", "math", "utf8", "coroutine", "debug"])
	lua.push_variant("__read", func(relative: String) -> String:
		return FileAccess.get_file_as_string(ROOT.path_join(relative))
	)
	var err: Variant = lua.do_string("""
		local modules = {}
		local function load_module(kind, path)
			local key = kind .. ":" .. path
			if modules[key] ~= nil then return modules[key] end
			local relative = kind .. "/" .. path
			if path:match("%.lua$") == nil then relative = relative .. ".lua" end
			local source = __read(relative)
			assert(source ~= "", "missing " .. key)
			local chunk = assert(load(source, "@" .. path))
			modules[key] = chunk()
			return modules[key]
		end
		function require(path) return load_module("lib", path) end

		local state = { progress = {}, exercise_state = nil, workspace = false }
		local ui_handlers = {}
		local events = {}
		local commands = {}
		local dialogs = {}
		local notifications = {}
		local command_count = 0

		local function remember(target, key, value)
			target[key] = target[key] or {}
			table.insert(target[key], value)
		end

		editor = {
			log = {
				info = function(message) end,
				warn = function(message) end,
				error = function(message) error("log.error: " .. tostring(message)) end,
			},
			content = { load = function(path) return load_module("content", path) end },
			settings = { get = function(key, fallback) return fallback end },
			permissions = { has = function(name) return true end },
			workspace = { has_workspace = function() return state.workspace end },
			files = {
				exists = function(path) return state.file_exists == true end,
				write = function(path, text) state.written = path; return true end,
			},
			docs = {
				create = function(spec) state.doc_text = spec.text or ""; return 1 end,
				open = function(path) return nil, { code = "workspace.required" } end,
				reveal = function(id) return true end,
				set_text = function(id, text) state.doc_text = text; return true end,
			},
			progress = {
				get = function(key, fallback)
					local value = state.progress[key]
					if value == nil then return fallback end
					return value
				end,
				set = function(key, value) state.progress[key] = value; return true end,
				reset = function(key) state.progress[key] = nil; return true end,
			},
			events = {
				on = function(name, fn) remember(events, name, fn); return name end,
			},
			commands = {
				register = function(spec) remember(commands, spec.id, spec); return spec.id end,
			},
			keys = { bind = function(id, chord) return true end },
			ui = {
				notify = function(text, level) table.insert(notifications, { text = text, level = level }) end,
				on = function(id, event, fn)
					ui_handlers[id] = ui_handlers[id] or {}
					ui_handlers[id][event] = fn
					return true
				end,
				mount = function(slot, spec) state.partial = spec; return "mount1" end,
				update = function(id, spec) state.partial = spec; return true end,
				unmount = function(id) state.partial = nil; return true end,
				dialog = function(spec) table.insert(dialogs, spec); return 1 end,
				focus = function(id) return true end,
				shell = {
					takeover = function(spec) state.layout = spec.layout; return { owner = "griddycode.test", active = true } end,
					exit = function(reason) state.layout = nil; return true end,
				},
			},
			exercise = {
				start = function(spec) state.exercise_spec = spec; state.exercise_state = { exercise = 1, state = "active", phase_kind = "typing" }; return state.exercise_state end,
				state = function(id) return state.exercise_state or { exercise = 0 } end,
				submit = function(id) state.exercise_state = { exercise = 1, state = "validating", phase_kind = "freeform" }; return { status = "pending" } end,
				retry = function(id) state.exercise_state = { exercise = 1, state = "active", phase_kind = "freeform" }; return state.exercise_state end,
				stop = function(id, reason) state.exercise_state = nil; return true end,
				hint = function(id, text) state.last_hint = text; return true end,
			},
		}

		local function read(relative)
			local source = __read(relative)
			assert(source ~= "", "missing " .. relative)
			return assert(load(source, "@" .. relative))
		end

		local main = read("main.lua")
		main()

		open_course()
		assert(ui_handlers[1] ~= nil and ui_handlers[1]["click"] ~= nil, "onboarding handler")
		ui_handlers[1]["click"]({ button = "start" })
		assert(state.layout ~= nil, "shell layout created")
		assert(state.doc_text == "", "an empty starter opens an empty document")

		assert(ui_handlers["start"] ~= nil, "start handler is bound")
		ui_handlers["start"]["click"]()
		assert(state.exercise_spec ~= nil, "exercise spec created")
		assert(state.exercise_spec.kind == "hybrid", "exercise is hybrid")
		assert(#state.exercise_spec.phases == 2, "exercise has two phases")
		assert(state.exercise_spec.phases[1].kind == "typing", "first phase is typing")
		assert(state.exercise_spec.phases[2].kind == "freeform", "second phase is freeform")
		assert(#state.exercise_spec.phases[2].validation.tests > 0, "text validation is present")

		events["exercise.phase_changed"][1]({ exercise = 1, phase = 1, kind = "freeform" })
		assert(state.progress["lessons.01_hello.typed"] == true, "typing progress recorded")
		ui_handlers["check"]["click"]()
		assert(state.exercise_state.state == "validating", "check enters validating")

		events["exercise.completed"][1]({ exercise = 1 })
		assert(state.progress["lessons.01_hello.done"] == true, "completion progress recorded")
		ui_handlers["next_lesson"]["click"]()
		assert(state.layout ~= nil, "next lesson keeps the shell")
		ui_handlers["previous"]["click"]()
		ui_handlers["hint"]["click"]()
		ui_handlers["help"]["click"]()
		assert(#dialogs > 0, "help dialog opens")

		ui_handlers["start"]["click"]()
		state.exercise_state = { exercise = 1, state = "failed", phase_kind = "freeform" }
		events["exercise.failed"][1]({ exercise = 1 })
		ui_handlers["retry"]["click"]()
		assert(state.exercise_state.state == "active", "retry restarts the phase")

		ui_handlers["leave"]["click"]()
		assert(state.layout == nil, "leave exits the shell")
		open_course()
		for id, handlers in pairs(commands) do
			command_count = command_count + 1
			for _, command in ipairs(handlers) do
				if command.handler ~= nil then command.handler() end
			end
		end
		deactivate()
		assert(state.layout == nil, "deactivate exits the shell")

		editor.permissions.has = function(name) return name ~= "ui.shell" end
		open_course()
		assert(state.partial ~= nil, "partial panel mounts without ui.shell")
		assert(state.layout == nil, "no shell is created without permission")
		local partial_text = ""
		if type(state.partial) == "table" and type(state.partial.children) == "table" then
			partial_text = tostring(state.partial.children[1].text or "")
		end
		assert(partial_text ~= "", "the partial panel explains the fallback")
		deactivate()

		editor.permissions.has = function(name) return true end
		local takeover = editor.ui.shell.takeover
		editor.ui.shell.takeover = function(spec) return nil, { code = "shell.busy" } end
		open_course()
		assert(state.partial ~= nil, "partial panel mounts when takeover fails")
		assert(state.layout == nil, "no shell is created after a failed takeover")
		local busy_text = ""
		if type(state.partial) == "table" and type(state.partial.children) == "table" then
			busy_text = tostring(state.partial.children[1].text or "")
		end
		assert(busy_text ~= "", "the takeover failure is explained")
		deactivate()
		editor.ui.shell.takeover = takeover

		editor.permissions.has = function(name) return true end
		state.workspace = true
		state.file_exists = true
		editor.docs.open = function(path) state.opened_path = path; return 2 end
		open_course()
		assert(ui_handlers["lesson_01_hello"] ~= nil, "lesson navigation is bound")
		ui_handlers["lesson_01_hello"]["click"]()
		assert(state.opened_path == "cpp_journey/01_hello.cpp", "lesson file is opened in the workspace")
		ui_handlers["start"]["click"]()
		assert(state.exercise_spec.phases[2].validation.tests[1].type == "stdout_contains", "run validation is embedded")
		deactivate()

		__state = {
			notifications = #notifications,
			dialogs = #dialogs,
			command_count = command_count,
			partial_text = partial_text,
			busy_text = busy_text,
			progress_done = state.progress["lessons.01_hello.done"] == true,
			run_test_type = state.exercise_spec.phases[2].validation.tests[1].type,
			opened_path = state.opened_path,
		}
	""")

	check(!(err is LuaError), "main.lua runtime flow: %s" % (str(err.message) if err is LuaError else ""))
	if err is LuaError:
		return

	var state: Variant = lua.pull_variant("__state")
	check(state is Dictionary, "the runtime stub reports its state")
	if !(state is Dictionary):
		return
	var data: Dictionary = state
	check(int(data.get("notifications", 0)) >= 5, "the flow raises the expected notifications")
	check(int(data.get("dialogs", 0)) >= 2, "onboarding and help dialogs opened")
	assert_eq(int(data.get("command_count", 0)), 6, "every command is registered")
	check(str(data.get("partial_text", "")).length() > 0, "the partial panel carries its reason")
	check(str(data.get("partial_text", "")).contains("ui.shell"), "the permission fallback names ui.shell")
	check(str(data.get("busy_text", "")).length() > 0, "the takeover failure is explained")
	check(str(data.get("busy_text", "")).contains("shell.busy"), "the takeover failure names the host code")
	check(bool(data.get("progress_done", false)), "completion reached progress storage")
	assert_eq(str(data.get("run_test_type", "")), "stdout_contains", "the run-backed phase uses stdout checks")
	assert_eq(str(data.get("opened_path", "")), "cpp_journey/01_hello.cpp", "the run-backed lesson opened its file")
