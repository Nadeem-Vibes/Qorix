extends "res://tests/support/test_case.gd"

const RuntimeCatalog = preload("res://src/features/run/runtime_catalog.gd")

var existing: Dictionary = {}


func before_each() -> void:
	existing.clear()


func after_each() -> void:
	existing.clear()


func _exists(path: String) -> bool:
	return existing.has(path)


func _windows(path_env: String = "C:/tools", pathext: String = ".EXE;.CMD"):
	return RuntimeCatalog.new("windows", path_env, pathext, Callable(self, "_exists"))


func _posix(path_env: String = "/usr/local/bin:/usr/bin"):
	return RuntimeCatalog.new("posix", path_env, "", Callable(self, "_exists"))


func test_command_segments_split_shell_statements() -> void:
	var segments := RuntimeCatalog.command_segments("gcc main.c && ./main || echo failed; node app.js")

	assert_eq(segments.size(), 4)
	assert_eq(RuntimeCatalog.first_word(segments[0]), "gcc")
	assert_eq(RuntimeCatalog.first_word(segments[1]), "./main")
	assert_eq(RuntimeCatalog.first_word(segments[2]), "echo")
	assert_eq(RuntimeCatalog.first_word(segments[3]), "node")


func test_command_segments_keep_quoted_separators_together() -> void:
	var segments := RuntimeCatalog.command_segments("python -c \"print('a && b')\" && node app.js")

	assert_eq(segments.size(), 2)
	assert_eq(RuntimeCatalog.first_word(segments[1]), "node")


func test_command_segments_do_not_split_redirections() -> void:
	var segments := RuntimeCatalog.command_segments("gcc main.c 2>&1 | tee build.log")

	assert_eq(segments.size(), 2)
	assert_eq(RuntimeCatalog.first_word(segments[0]), "gcc")
	assert_eq(RuntimeCatalog.first_word(segments[1]), "tee")


func test_first_word_removes_quotes_and_batch_prefixes() -> void:
	assert_eq(RuntimeCatalog.first_word("\"C:/Program Files/Python/python.exe\" main.py"), "C:/Program Files/Python/python.exe")
	assert_eq(RuntimeCatalog.first_word("@echo off"), "echo")
	assert_eq(RuntimeCatalog.first_word("# a comment"), "")
	assert_eq(RuntimeCatalog.first_word("   "), "")


func test_first_word_stops_at_redirection() -> void:
	assert_eq(RuntimeCatalog.first_word("python main.py > out.txt"), "python")


func test_explicit_runtimes_win_over_command_inference() -> void:
	var catalog = _posix()
	var names: Array = catalog.runtime_names({"runtimes": ["go"]}, "gcc main.c && ./main")

	assert_eq(names, ["go"])


func test_a_single_declared_runtime_string_is_accepted() -> void:
	var catalog = _posix()
	var names: Array = catalog.runtime_names({"runtimes": "node"}, "python main.py")

	assert_eq(names, ["node"])


func test_runtime_inference_skips_builtins_and_build_outputs() -> void:
	var catalog = _posix()
	var names: Array = catalog.runtime_names({}, "cd build && gcc main.c -o main && ./main")

	assert_eq(names, ["gcc"])


func test_runtime_inference_skips_a_later_absolute_build_output() -> void:
	var catalog = _posix()
	var names: Array = catalog.runtime_names({}, "go build -o /tmp/app && /tmp/app --serve")

	assert_eq(names, ["go"])


func test_runtime_inference_skips_a_first_word_that_already_exists() -> void:
	existing["/opt/toolchain/clang"] = true
	var catalog = _posix()
	var names: Array = catalog.runtime_names({}, "/opt/toolchain/clang main.c")

	assert_eq(names, [])


func test_windows_find_executable_uses_pathext() -> void:
	existing["C:/tools/python.EXE"] = true
	var catalog = _windows()

	assert_eq(catalog.find_executable("python"), "C:/tools/python.EXE")


func test_windows_find_executable_tries_lowercase_pathext() -> void:
	existing["C:/tools/tool.cmd"] = true
	var catalog = _windows("C:/tools", ".CMD")

	assert_eq(catalog.find_executable("tool"), "C:/tools/tool.cmd")


func test_windows_find_executable_accepts_an_existing_extension() -> void:
	existing["C:/tools/node.exe"] = true
	var catalog = _windows()

	assert_eq(catalog.find_executable("node.exe"), "C:/tools/node.exe")


func test_posix_path_folders_use_a_colon_separator() -> void:
	existing["/usr/bin/python3"] = true
	var catalog = _posix("/usr/local/bin:/usr/bin")

	assert_eq(catalog.find_executable("python3"), "/usr/bin/python3")


func test_resolve_runtime_falls_back_through_its_group() -> void:
	existing["C:/tools/py.EXE"] = true
	var catalog = _windows()
	var resolved: Dictionary = catalog.resolve_runtime("python")

	assert_eq(resolved.get("group"), "python")
	assert_eq(resolved.get("resolved"), "py")
	assert_eq(resolved.get("path"), "C:/tools/py.EXE")


func test_resolve_runtime_accepts_a_missing_name_as_unresolved() -> void:
	var catalog = _windows("/empty")
	var resolved: Dictionary = catalog.resolve_runtime("java")

	assert_eq(resolved.get("resolved"), "")
	assert_eq(resolved.get("path"), "")
	assert_eq(catalog.check_profile({"runtimes": ["java"]}, "java Main.java").ok, false)


func test_check_profile_reports_a_usable_alias_replacement() -> void:
	existing["C:/tools/py.EXE"] = true
	var catalog = _windows()
	var result: Dictionary = catalog.check_profile({"runtimes": ["python"]}, "python -u $file")

	assert_true(result.ok)
	assert_eq(result.missing.size(), 0)
	assert_eq(result.replacements, {"python": "py"})


func test_missing_runtime_has_install_guidance_instead_of_a_raw_error() -> void:
	var catalog = _windows("/empty")
	var result: Dictionary = catalog.check_profile({"runtimes": ["go"]}, "go run $file")

	assert_false(result.ok)
	assert_eq(result.missing.size(), 1)
	var help: Dictionary = result.missing[0].get("install", {})
	assert_eq(help.get("group"), "go")
	assert_true(str(help.get("title", "")).contains("Go"))
	assert_true(str(help.get("url", "")).begins_with("https://go.dev"))


func test_install_help_aliases_python3_to_python() -> void:
	var catalog = _windows()
	var help: Dictionary = catalog.install_help("python3")

	assert_eq(help.get("group"), "python")
	assert_true(str(help.get("url", "")).contains("python.org"))


func test_install_help_is_platform_aware_for_c_compilers() -> void:
	var windows_help: Dictionary = _windows().install_help("g++")
	var posix_help: Dictionary = _posix().install_help("gcc")

	assert_true(str(windows_help.get("hint", "")).contains("MSYS2"))
	assert_true(str(windows_help.get("url", "")).contains("msys2.org"))
	assert_true(str(posix_help.get("hint", "")).contains("package manager"))


func test_install_help_carries_winget_commands_for_python_and_node_on_windows() -> void:
	var python_help: Dictionary = _windows().install_help("python")
	var node_help: Dictionary = _windows().install_help("node")

	assert_true(str(python_help.get("winget", "")).contains("winget install"))
	assert_true(str(python_help.get("winget", "")).contains("Python.Python.3.12"))
	assert_true(str(python_help.get("winget_label", "")).contains("Python"))
	assert_true(str(node_help.get("winget", "")).contains("winget install"))
	assert_true(str(node_help.get("winget", "")).contains("NodeJS"))


func test_install_help_omits_winget_on_posix() -> void:
	var python_help: Dictionary = _posix().install_help("python")

	assert_eq(str(python_help.get("winget", "")), "")


func test_replace_executable_only_rewrites_statement_starts() -> void:
	var command := RuntimeCatalog.replace_executable(
		"python a.py && python b.py", "python", "py"
	)

	assert_eq(command, "py a.py && py b.py")


func test_replace_executable_does_not_touch_an_argument() -> void:
	var command := RuntimeCatalog.replace_executable(
		"echo python is here", "python", "py"
	)

	assert_eq(command, "echo python is here")


func test_replace_executable_quotes_a_path_with_spaces() -> void:
	var command := RuntimeCatalog.replace_executable(
		"python main.py", "python", "C:/Program Files/Python/python.exe"
	)

	assert_eq(command, "\"C:/Program Files/Python/python.exe\" main.py")
