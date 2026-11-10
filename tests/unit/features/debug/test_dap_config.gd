extends "res://tests/support/test_case.gd"

## Adapter profiles and launch resolution. No process is started: executable
## lookup is injected so the tests pin PATH/PATHEXT behavior and the Python
## launch object without depending on the machine's installed runtimes.

const DapConfig = preload("res://src/features/debug/dap_config.gd")

const TEST_DIR := "user://tests_dap_config"
const GLOBAL_CONFIG := "user://tests_dap_config/debug.json"
const WORKSPACE_DIR := "user://tests_dap_config/workspace"


func _exists(path: String) -> bool:
	var normalized := path.replace("\\", "/").to_lower()
	return normalized in [
		"c:/fake/bin/python.exe",
		"c:/fake/bin/lldb-dap.exe",
		"c:/custom/python.exe",
		"c:/fake/bin/ruby.exe",
	]


func _config() -> RefCounted:
	return DapConfig.new("windows", "C:/fake/bin", ".EXE;.CMD", Callable(self, "_exists"))


func before_each() -> void:
	_remove_dir(TEST_DIR)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(WORKSPACE_DIR))


func after_each() -> void:
	_remove_dir(TEST_DIR)


func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)


func test_python_files_resolve_to_the_python_adapter() -> void:
	var config = _config()
	assert_eq(config.adapter_id_for_path("C:/project/main.py"), "python")
	assert_eq(config.adapter_id_for_path("C:/project/tool.pyw"), "python")
	assert_eq(config.adapter_id_for_path("C:/project/notes.txt"), "", "unknown extensions have no adapter")

	var profile: Dictionary = config.adapter_for_path("C:/project/main.py")
	assert_eq(profile.get("id"), "python")
	assert_eq(profile.get("display"), "Python (debugpy)")
	assert_eq(profile.get("implemented"), true)


func test_a_detected_language_beats_the_extension() -> void:
	var config = _config()
	assert_eq(config.adapter_id_for_path("C:/project/script.txt", "python"), "python")
	assert_eq(config.adapter_id_for_path("C:/project/script.txt", "PY"), "python")
	assert_eq(config.adapter_id_for_path("C:/project/script.txt", "not-a-language"), "", "a bogus override falls back to the extension")


func test_planned_adapters_are_scaffolded_but_refuse_to_run() -> void:
	var config = _config()
	var node: Dictionary = config.adapter_for_path("C:/project/app.js")
	assert_eq(node.get("id"), "node")
	assert_eq(node.get("implemented"), false)

	var result: Dictionary = config.resolve(node, "C:/project/app.js", "C:/project", 5000)
	assert_eq(result.get("ok"), false)
	assert_true(str(result.get("error", "")).contains("not implemented"))
	assert_false(result.get("install", {}).is_empty(), "the planned adapter still carries install help")


func test_resolving_python_builds_the_adapter_and_launch_objects() -> void:
	var config = _config()
	var profile: Dictionary = config.adapter_for_path("C:/project/main.py")
	var result: Dictionary = config.resolve(profile, "C:/project/main.py", "C:/project", 5123)

	assert_eq(result.get("ok"), true, "the injected python.exe should resolve")
	assert_eq(result.get("adapter_id"), "python")
	assert_eq(str(result.get("command_path", "")).to_lower(), "c:/fake/bin/python.exe",
		"the PATHEXT casing is preserved, so compare case-insensitively")
	assert_eq(result.get("args"), [
		"-m", "debugpy.adapter", "--host", "127.0.0.1", "--port", "5123",
	])
	assert_eq(result.get("cwd"), "C:/project")

	var launch: Dictionary = result.get("launch", {})
	assert_eq(launch.get("type"), "python")
	assert_eq(launch.get("request"), "launch")
	assert_eq(launch.get("program"), "C:/project/main.py")
	assert_eq(launch.get("cwd"), "C:/project")
	assert_eq(launch.get("console"), "internalConsole")
	assert_eq(launch.get("justMyCode"), true)


func test_a_missing_interpreter_reports_the_command() -> void:
	var config = DapConfig.new("windows", "C:/nowhere", ".EXE", Callable(self, "_exists"))
	var profile: Dictionary = config.adapter_for_path("C:/project/main.py")
	var result: Dictionary = config.resolve(profile, "C:/project/main.py", "C:/project", 5000)

	assert_eq(result.get("ok"), false)
	assert_true(str(result.get("error", "")).contains("not found on PATH"))
	assert_false(result.get("install", {}).is_empty(), "missing debugpy should keep its install card")


func test_placeholder_substitution_is_recursive() -> void:
	var tokens := {
		"$port": "5100",
		"$file": "C:/p/main.py",
		"$dir": "C:/p",
		"$workspace": "C:/p",
		"$python": "C:/fake/bin/python.exe",
	}
	assert_eq(DapConfig.substitute("-m debugpy --port $port", tokens), "-m debugpy --port 5100")

	var config = _config()
	config.apply_config({
		"python": {
			"launch": {
				"env": {"PYTHONPATH": "$workspace"},
				"args": ["--file=$file", 3, true],
			},
		},
	})
	var profile: Dictionary = config.adapter_for_path("C:/p/main.py")
	var result: Dictionary = config.resolve(profile, "C:/p/main.py", "C:/p", 5100)
	var launch: Dictionary = result.get("launch", {})
	assert_eq(launch.get("env").get("PYTHONPATH"), "C:/p")
	assert_eq(launch.get("args"), ["--file=C:/p/main.py", 3, true])


func test_project_config_can_override_a_built_in_profile() -> void:
	var config = _config()
	var applied: Dictionary = config.apply_config({
		"python": {
			"command": "C:/custom/python.exe",
			"args": ["-m", "debugpy.adapter", "--host", "127.0.0.1", "--port", "$port"],
			"launch": {"justMyCode": false, "stopOnEntry": true},
		},
	}, "test")
	assert_eq(applied.get("ok"), true)

	var profile: Dictionary = config.adapter_for_path("C:/p/main.py")
	assert_eq(profile.get("custom"), false, "overriding a built-in keeps it built-in")
	assert_eq(profile.get("command"), "C:/custom/python.exe")
	assert_eq((profile.get("launch", {}) as Dictionary).get("justMyCode"), false)
	assert_eq((profile.get("launch", {}) as Dictionary).get("stopOnEntry"), true)
	assert_eq((profile.get("launch", {}) as Dictionary).get("console"), "internalConsole", "unmentioned launch keys survive the merge")

	var result: Dictionary = config.resolve(profile, "C:/p/main.py", "C:/p", 5001)
	assert_eq(result.get("ok"), true)
	assert_eq(result.get("command_path"), "C:/custom/python.exe")


func test_a_custom_adapter_can_be_added() -> void:
	var config = _config()
	config.apply_config({
		"ruby": {
			"display": "Ruby (debug)",
			"command": "C:/fake/bin/ruby.exe",
			"extensions": ["rb"],
			"launch": {"program": "$file"},
		},
	})
	assert_eq(config.adapter_id_for_path("C:/p/app.rb"), "ruby")
	var result: Dictionary = config.resolve(config.adapter_for_path("C:/p/app.rb"), "C:/p/app.rb", "C:/p", 5002)
	assert_eq(result.get("ok"), true)
	assert_eq(result.get("display"), "Ruby (debug)")
	assert_eq(result.get("launch").get("program"), "C:/p/app.rb")


func test_disabling_an_adapter_is_reported() -> void:
	var config = _config()
	config.apply_config({"python": {"enabled": false}})
	var result: Dictionary = config.resolve(config.adapter_for_path("C:/p/main.py"), "C:/p/main.py", "C:/p", 5000)
	assert_eq(result.get("ok"), false)
	assert_true(str(result.get("error", "")).contains("disabled"))


func test_a_bad_config_value_is_an_error_not_a_crash() -> void:
	var config = _config()
	var applied: Dictionary = config.apply_config({"python": 7}, "broken.json")
	assert_eq(applied.get("ok"), true, "one bad adapter does not discard the rest")
	assert_eq(config.config_errors.size(), 1)
	assert_true(str(config.config_errors[0].get("error", "")).contains("not an object"))

	var not_an_object: Dictionary = config.apply_config([], "list.json")
	assert_eq(not_an_object.get("ok"), false)


func test_layered_files_override_from_global_to_workspace() -> void:
	_write(GLOBAL_CONFIG, JSON.stringify({
		"debug": {
			"python": {
				"command": "C:/global/python.exe",
				"launch": {"justMyCode": false},
			},
		},
	}, "\t"))

	var workspace := ProjectSettings.globalize_path(WORKSPACE_DIR).replace("\\", "/")
	_write(workspace.path_join(".griddycode.json"), JSON.stringify({
		"debug": {
			"python": {"command": "C:/workspace/python.exe"},
		},
	}, "\t"))

	var config = DapConfig.new("windows", "C:/fake/bin", ".EXE;.CMD")
	var loaded: Dictionary = config.load_for_project(workspace, GLOBAL_CONFIG)
	assert_eq(loaded.get("ok"), true)
	assert_eq(config.loaded_sources.size(), 2, "global and workspace files are both recorded")
	assert_eq(config.adapter("python").get("command"), "C:/workspace/python.exe")
	assert_eq(config.adapter("python").get("launch").get("justMyCode"), false, "later files merge over earlier ones")


func test_adapter_rows_are_sorted_and_report_availability() -> void:
	var config = _config()
	var rows: Array = config.adapter_rows()
	assert_true(rows.size() >= 5)
	var ids: Array = []
	var sorted := true
	var previous := ""
	for row in rows:
		var display := str(row.get("display", ""))
		if !previous.is_empty() and display.naturalnocasecmp_to(previous) < 0:
			sorted = false
		previous = display
		ids.append(str(row.get("id", "")))
	assert_true(sorted, "adapter rows keep a stable alphabetical order")
	assert_true(ids.has("python"))
	assert_true(ids.has("node"))

	for row in rows:
		if str(row.get("id", "")) == "python":
			assert_eq(row.get("found"), true)
			assert_eq(row.get("implemented"), true)
		elif str(row.get("id", "")) == "node":
			assert_eq(row.get("found"), false, "a planned adapter has no command")
			assert_eq(row.get("implemented"), false)


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
