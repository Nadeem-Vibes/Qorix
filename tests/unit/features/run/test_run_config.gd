extends "res://tests/support/test_case.gd"

const RunConfig = preload("res://src/features/run/run_config.gd")

const TEST_DIR := "user://tests_run_config"


func before_each() -> void:
	_remove_dir(TEST_DIR)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TEST_DIR))


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


func _write(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)


func _root() -> String:
	return ProjectSettings.globalize_path(TEST_DIR)


func _posix_config():
	var config = RunConfig.new()
	config.platform = "posix"
	return config


func test_builtin_profile_matches_extension() -> void:
	var config = _posix_config()
	var profile := config.profile_for("/work/main.py")

	assert_eq(profile.get("id"), "python")
	assert_eq(profile.get("language"), "python")
	assert_eq(profile.get("display"), "Python")
	assert_eq(profile.get("runtimes"), ["python"])


func test_language_override_beats_a_plain_text_extension() -> void:
	var config = _posix_config()
	var profile := config.profile_for("/work/notes.txt", "python")

	assert_eq(profile.get("id"), "python")


func test_custom_config_overrides_a_builtin_command() -> void:
	var config = _posix_config()
	config.apply_config({"run": {"python": {"command": "py -3 $file"}}}, "test.json")
	var profile := config.profile_for("/work/main.py")

	assert_eq(profile.get("id"), "python")
	assert_eq(profile.get("custom"), true)
	assert_eq(profile.get("command"), "py -3 $file")


func test_bare_profile_map_is_accepted() -> void:
	var config = _posix_config()
	config.apply_config({"deno": {"command": "deno run $file", "extensions": ["ts"]}}, "test.json")
	var profile := config.profile_for("/work/app.ts")

	assert_eq(profile.get("id"), "deno")
	assert_eq(profile.get("custom"), true)


func test_interactive_profile_is_normalized_to_terminal_mode() -> void:
	var config = _posix_config()
	config.apply_config({"run": {"server": {
		"command": "python -u $file", "interactive": true,
	}}}, "test.json")

	assert_eq(config.profile_for("/work/x.py", "server").get("mode"), "terminal")


func test_shebang_is_used_when_enabled() -> void:
	var config = _posix_config()
	config.load_for_project("", "/work/script.txt", "#!/usr/bin/env node\nconsole.log('hi')\n", true)
	var profile := config.profile_for("/work/script.txt")

	assert_eq(profile.get("id"), "shebang")
	assert_eq(profile.get("command"), "node $file")
	assert_eq(profile.get("language"), "javascript")


func test_shebang_can_be_disabled() -> void:
	var config = _posix_config()
	config.load_for_project("", "/work/script.txt", "#!/usr/bin/env node\nconsole.log('hi')\n", false)

	assert_eq(config.profile_for("/work/script.txt"), {})


func test_placeholders_are_shell_quoted() -> void:
	var config = _posix_config()
	var command: String = config.resolve_command({
		"command": "python -u $file --name $fileNameWithoutExt --cwd $workspace",
	}, "/work/my file.py", "/work")

	assert_eq(command, "python -u '/work/my file.py' --name 'my file' --cwd '/work'")


func test_placeholder_inside_quotes_is_not_double_quoted() -> void:
	var config = _posix_config()
	var command: String = config.resolve_command({
		"command": "python \"$file\"",
	}, "/work/my file.py", "/work")

	assert_eq(command, "python \"/work/my file.py\"")


func test_placeholder_inside_single_quotes_keeps_its_quoting() -> void:
	var config = _posix_config()
	var command: String = config.resolve_command({
		"command": "python '$file'",
	}, "/work/my file.py", "/work")

	assert_eq(command, "python '/work/my file.py'")


func test_missing_placeholder_appends_the_quoted_file() -> void:
	var config = _posix_config()
	var command: String = config.resolve_command({"command": "node"}, "/work/app.js", "/work")

	assert_eq(command, "node '/work/app.js'")


func test_append_file_can_be_disabled() -> void:
	var config = _posix_config()
	var command: String = config.resolve_command({
		"command": "node", "append_file": false,
	}, "/work/app.js", "/work")

	assert_eq(command, "node")


func test_resolve_existing_cwd_falls_back_to_the_file_folder() -> void:
	var config = _posix_config()
	var folder := _root().path_join("project")
	DirAccess.make_dir_recursive_absolute(folder)
	var path := folder.path_join("main.py")
	_write(path, "print('hi')\n")

	var cwd: String = config.resolve_existing_cwd({
		"cwd": folder.path_join("does-not-exist"),
	}, path, folder)

	assert_eq(cwd, folder)


func test_invalid_config_json_is_reported_without_crashing() -> void:
	var root := _root()
	_write(root.path_join(".griddycode.json"), "{ not json")
	var config = _posix_config()
	var loaded: Dictionary = config.load_for_project(root, root.path_join("main.py"))

	assert_false(loaded.get("ok"))
	assert_true(loaded.get("errors", []).size() > 0)


func test_layered_config_later_files_win() -> void:
	var root := _root()
	_write(root.path_join("user_run.json"), "{\"run\":{\"python\":{\"command\":\"python $file\"}}}")
	_write(root.path_join(".griddycode.json"), "{\"run\":{\"python\":{\"command\":\"python3 -u $file\"}}}")
	var config = _posix_config()
	config.load_for_project(root, root.path_join("main.py"), "", true, root.path_join("user_run.json"))
	var profile := config.profile_for(root.path_join("main.py"))

	assert_eq(profile.get("command"), "python3 -u $file")


func test_default_config_text_is_valid_and_documented() -> void:
	var text := RunConfig.default_config_text()
	var parsed: Variant = JSON.parse_string(text)

	assert_true(parsed is Dictionary)
	assert_true((parsed as Dictionary).has("run"))
	assert_true((parsed as Dictionary)["run"].has("python"))
	assert_true((parsed as Dictionary)["run"].has("node"))
