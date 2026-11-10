extends "res://tests/support/test_case.gd"

## Opening a folder must not be enough to make Qorix start a process
## named by that folder. These checks cover the store and the two loaders that
## consume its verdict.

const TrustScript = preload("res://src/platform/trust_service.gd")
const LspConfig = preload("res://src/features/lsp/lsp_config.gd")
const DapConfig = preload("res://src/features/debug/dap_config.gd")

const TEST_DIR := "user://tests_trust"
const ROOT := "user://tests_trust/project"


func before_each() -> void:
	_remove_dir(TEST_DIR)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ROOT))
	_write(ROOT.path_join(".griddycode.json"), JSON.stringify({
		"lsp": {"python": {"command": "evil-lsp", "args": ["--steal"]}},
		"debug": {"python": {"command": "evil-dap"}},
	}))


func after_each() -> void:
	_remove_dir(TEST_DIR)


func _trust():
	var store = TrustScript.new()
	store.path = TEST_DIR.path_join("trusted.json")
	store.load()
	return store


func test_trust_is_exact_to_the_folder() -> void:
	var store = _trust()
	assert_false(store.is_trusted(ROOT))
	assert_true(store.trust(ROOT).get("ok", false))
	assert_true(store.is_trusted(ROOT))
	# A child folder is a different workspace and must ask on its own.
	assert_false(store.is_trusted(ROOT.path_join("sub")))
	assert_false(store.is_trusted(""))


func test_trust_survives_a_reload_and_can_be_revoked() -> void:
	var first = _trust()
	first.trust(ROOT)

	var second = _trust()
	assert_true(second.is_trusted(ROOT))

	assert_true(second.revoke(ROOT).get("ok", false))
	assert_false(second.is_trusted(ROOT))
	assert_false(_trust().is_trusted(ROOT))


func test_untrusted_workspace_cannot_override_lsp_command() -> void:
	var config = LspConfig.new("windows", "", ".EXE", func(_path: String) -> bool: return true)
	config.load_for_project(ROOT, "")
	assert_eq(str(config.profile_for_language("python").get("command", "")), "evil-lsp")

	var restricted = LspConfig.new("windows", "", ".EXE", func(_path: String) -> bool: return true)
	restricted.workspace_trust = func(_root: String) -> bool: return false
	var loaded: Dictionary = restricted.load_for_project(ROOT, "")
	assert_true(bool(loaded.get("restricted", false)))
	assert_eq(str(restricted.profile_for_language("python").get("command", "")), "pyright-langserver")


func test_untrusted_workspace_cannot_override_dap_command() -> void:
	var config = DapConfig.new("windows", "", ".EXE", func(_path: String) -> bool: return true)
	config.load_for_project(ROOT, "")
	assert_eq(str(config.adapter("python").get("command", "")), "evil-dap")

	var restricted = DapConfig.new("windows", "", ".EXE", func(_path: String) -> bool: return true)
	restricted.workspace_trust = func(_root: String) -> bool: return false
	var loaded: Dictionary = restricted.load_for_project(ROOT, "")
	assert_true(bool(loaded.get("restricted", false)))
	assert_eq(str(restricted.adapter("python").get("command", "")), "python")


func _write(path: String, content: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	assert_ne(file, null, "could not write %s" % path)
	if file != null:
		file.store_string(content)
		file.close()


func _remove_dir(path: String) -> void:
	var absolute := ProjectSettings.globalize_path(path)
	if !DirAccess.dir_exists_absolute(absolute):
		return
	var dir := DirAccess.open(absolute)
	if dir == null:
		return
	for name in dir.get_files():
		DirAccess.remove_absolute(absolute.path_join(name))
	for name in dir.get_directories():
		_remove_dir(path.path_join(name))
	DirAccess.remove_absolute(absolute)
