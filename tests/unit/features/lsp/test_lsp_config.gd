extends "res://tests/support/test_case.gd"

const LspConfig = preload("res://src/features/lsp/lsp_config.gd")

const TEST_DIR := "user://tests_lsp_config"


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
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)


func _root() -> String:
	return ProjectSettings.globalize_path(TEST_DIR)


func _config(found: Array = []) -> LspConfig:
	return LspConfig.new(
		"windows",
		"C:/bin;C:/other",
		".EXE",
		func(path: String) -> bool: return found.has(path) or FileAccess.file_exists(path)
	)


# ── LANGUAGE LOOKUP ────────────────────────────────────────────────────────

func test_builtin_profiles_cover_the_required_languages() -> void:
	var config = _config()

	for language in ["python", "typescript", "javascript", "rust", "c", "cpp", "go"]:
		check(config.has_language(language), "missing profile for " + language)
	assert_eq(config.profile_for_language("python").get("command"), "pyright-langserver")
	assert_eq(config.profile_for_language("javascript").get("id"), "typescript")
	assert_eq(config.profile_for_language("typescriptreact").get("id"), "typescript")
	assert_eq(config.profile_for_language("cpp").get("id"), "cpp")


func test_extensions_map_to_languages() -> void:
	var config = _config()

	assert_eq(config.language_for_extension(".py"), "python")
	assert_eq(config.language_for_extension("tsx"), "typescriptreact")
	assert_eq(config.language_for_extension("h"), "c")
	assert_eq(config.language_for_extension("rs"), "rust")
	assert_eq(config.language_for_extension("txt"), "")
	assert_eq(config.language_for_extension(""), "")


func test_language_for_document_prefers_a_known_override() -> void:
	var config = _config()

	assert_eq(config.language_for_document("C:/work/notes.txt", "python"), "python")
	assert_eq(config.language_for_document("C:/work/main.py"), "python")
	# An override the profiles cannot serve falls back to the extension.
	assert_eq(config.language_for_document("C:/work/main.ts", "brainfuck"), "typescript")


func test_completion_language_id_matches_the_document() -> void:
	var config = _config()

	assert_eq(config.profile_for_language("typescriptreact", "C:/a.tsx").get("language_id"), "typescriptreact")
	assert_eq(config.profile_for_language("javascriptreact", "C:/a.jsx").get("language_id"), "javascriptreact")
	assert_eq(config.profile_for_language("cpp", "C:/a.hpp").get("language_id"), "cpp")


func test_unknown_language_has_no_profile() -> void:
	var config = _config()

	assert_eq(config.profile_for_language("haskell"), {})
	assert_false(config.has_language("haskell"))


# ── CONFIG LAYERING ────────────────────────────────────────────────────────

func test_a_custom_command_overrides_a_builtin() -> void:
	var config = _config()
	config.apply_config({"lsp": {"python": {"command": "my-pyright", "args": ["--stdio", "--verbose"]}}}, "test.json")
	var profile := config.profile_for_language("python")

	assert_eq(profile.get("command"), "my-pyright")
	assert_eq(profile.get("args"), ["--stdio", "--verbose"])
	assert_eq(profile.get("custom"), true)


func test_a_profile_can_be_disabled() -> void:
	var config = _config()
	config.apply_config({"lsp": {"rust": {"enabled": false}}}, "test.json")

	assert_eq(config.profile_for_language("rust"), {})


func test_a_bare_profile_map_is_accepted() -> void:
	var config = _config()
	config.apply_config({
		"deno": {
			"command": "deno",
			"args": ["lsp"],
			"extensions": ["ts"],
			"display": "Deno",
		},
	}, "test.json")
	var profile := config.profile_for_language("deno")

	assert_eq(profile.get("command"), "deno")
	assert_eq(profile.get("display"), "Deno")
	assert_eq(profile.get("custom"), true)
	assert_eq(profile.get("extensions"), ["ts"])
	assert_eq(config.language_for_extension("ts"), "typescript")


func test_a_string_profile_is_a_command_shorthand() -> void:
	var config = _config()
	config.apply_config({"lsp": {"zig": "zls"}}, "test.json")

	assert_eq(config.profile_for_language("zig").get("command"), "zls")


func test_language_aliases_are_normalized() -> void:
	var config = _config()
	config.apply_config({"lsp": {"mylang": {
		"command": "myls",
		"language_ids": {"mylang": "my-lang"},
	}}}, "test.json")

	assert_eq(config.profile_for_language("mylang").get("language_id"), "my-lang")
	assert_eq(LspConfig.normalize_language("PY"), "python")
	assert_eq(LspConfig.normalize_language(".tsx"), "typescriptreact")


func test_invalid_config_is_reported_not_fatal() -> void:
	var config = _config()
	var result: Dictionary = config.apply_config([], "broken.json")

	assert_false(result.get("ok"))
	assert_true(config.config_errors.size() > 0)


func test_layered_project_files_later_files_win() -> void:
	var root := _root()
	_write(root.path_join("user_lsp.json"), "{\"lsp\":{\"python\":{\"command\":\"global\"}}}")
	_write(root.path_join(".griddycode.json"), "{\"lsp\":{\"python\":{\"command\":\"project\"}}}")
	_write(root.path_join(".griddycode").path_join("lsp.json"), "{\"lsp\":{\"python\":{\"command\":\"nested\"}}}")

	var config = _config()
	var loaded: Dictionary = config.load_for_project(root, root.path_join("user_lsp.json"))
	var profile := config.profile_for_language("python")

	assert_true(loaded.get("ok"))
	assert_eq(profile.get("command"), "nested")
	assert_eq(loaded.get("sources", []).size(), 3)


func test_a_broken_project_file_does_not_discard_builtins() -> void:
	var root := _root()
	_write(root.path_join(".griddycode.json"), "{ not json")

	var config = _config()
	var loaded: Dictionary = config.load_for_project(root, root.path_join("missing.json"))

	assert_false(loaded.get("ok"))
	assert_true(loaded.get("errors", []).size() > 0)
	assert_eq(config.profile_for_language("python").get("command"), "pyright-langserver")


func test_missing_config_files_are_silently_skipped() -> void:
	var config = _config()
	var loaded: Dictionary = config.load_for_project("", "user://does_not_exist_lsp.json")

	assert_true(loaded.get("ok"))
	assert_eq(loaded.get("sources", []).size(), 0)


# ── PROJECT ROOT ───────────────────────────────────────────────────────────

func test_root_marker_wins_over_the_workspace() -> void:
	var config = _config(["C:/work/app/pyproject.toml"])
	var profile := config.profile_for_language("python")
	var root := config.root_for(profile, "C:/work/app/src/deep/main.py", "C:/work")

	assert_eq(root, "C:/work/app")


func test_nearest_root_marker_wins() -> void:
	var config = _config(["C:/outer/pyproject.toml", "C:/outer/pkg/pyproject.toml"])
	var profile := config.profile_for_language("python")
	var root := config.root_for(profile, "C:/outer/pkg/src/main.py", "C:/outer")

	assert_eq(root, "C:/outer/pkg")


func test_without_markers_the_workspace_is_the_root() -> void:
	var config = _config()
	var profile := config.profile_for_language("python")
	var root := config.root_for(profile, "C:/work/src/main.py", "C:/work")

	assert_eq(root, "C:/work")


func test_a_file_outside_the_workspace_uses_its_own_folder() -> void:
	var config = _config()
	var profile := config.profile_for_language("python")
	var root := config.root_for(profile, "C:/elsewhere/main.py", "C:/work")

	assert_eq(root, "C:/elsewhere")


# ── EXECUTABLE LOOKUP ──────────────────────────────────────────────────────

func test_path_lookup_adds_windows_extensions() -> void:
	var config = _config(["C:/bin/deno.exe"])
	config.apply_config({"lsp": {"deno": {"command": "deno", "extensions": ["ts"]}}}, "test.json")

	var resolved: Dictionary = config.resolve_command(config.profile_for_language("deno"))

	assert_true(resolved.get("ok"))
	assert_eq(resolved.get("path"), "C:/bin/deno.exe")


func test_a_path_command_is_used_when_the_file_exists() -> void:
	var config = _config(["C:/tools/myls.exe"])
	config.apply_config({"lsp": {"mylang": {"command": "C:\\tools\\myls.exe"}}}, "test.json")

	var resolved: Dictionary = config.resolve_command(config.profile_for_language("mylang"))

	assert_true(resolved.get("ok"))
	assert_eq(resolved.get("path"), "C:/tools/myls.exe")


func test_a_missing_command_reports_a_friendly_error() -> void:
	var config = _config()
	var resolved: Dictionary = config.resolve_command(config.profile_for_language("python"))

	assert_false(resolved.get("ok"))
	assert_true(str(resolved.get("error")).contains("pyright-langserver"))


func test_an_injected_resolver_wins() -> void:
	var config = _config()
	config.executable_resolver = func(name: String) -> String:
		return "C:/runtime/" + name + ".exe" if name == "gopls" else ""

	var resolved: Dictionary = config.resolve_command(config.profile_for_language("go"))

	assert_true(resolved.get("ok"))
	assert_eq(resolved.get("path"), "C:/runtime/gopls.exe")


func test_server_status_includes_install_help_and_root() -> void:
	var config = _config(["C:/bin/pyright-langserver.exe"])
	var status: Dictionary = config.server_status("python", "C:/work/main.py", "C:/work")

	assert_true(status.get("ok"))
	assert_eq(status.get("root"), "C:/work")
	assert_eq(status.get("command"), "pyright-langserver")
	assert_true(status.get("install", {}).get("commands", []).size() > 0)


func test_server_entries_describe_every_profile() -> void:
	var config = _config(["C:/bin/gopls.exe"])
	var entries: Array = config.server_entries()
	var found: Dictionary = {}

	for entry in entries:
		found[entry.get("id")] = entry

	assert_eq(found.size(), 5)
	assert_true(found.has("python"))
	assert_false(found["python"].get("found"))
	assert_true(found["go"].get("found"))
	assert_eq(found["python"].get("install", {}).get("executable"), "pyright-langserver")
	assert_eq(found["python"].get("display"), "Python")


func test_install_help_accepts_a_single_command_string() -> void:
	var config = _config()
	config.apply_config({"lsp": {"mylang": {
		"command": "myls",
		"install": {"command_windows": "winget install myls"},
	}}}, "test.json")
	var help: Dictionary = config.install_help("mylang")

	assert_eq(help.get("commands"), ["winget install myls"])
	assert_eq(help.get("executable"), "myls")
