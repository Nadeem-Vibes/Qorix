extends TestCase

## Developer-mode watcher: only main.lua + lib/**/*.lua, debounced, and driven
## by an injectable signature so mtime granularity cannot make the suite flaky.

const Watcher = preload("res://src/features/mods/mod_dev_watcher.gd")

const ROOT := "user://griddy_phase5/watcher"

var _signatures: Dictionary = {}


func before_each() -> void:
	_clean(ROOT)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ROOT))
	_signatures.clear()


func after_each() -> void:
	_clean(ROOT)


func _signature_source(id: String, _root: String) -> Dictionary:
	return _signatures.get(id, {})


func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()


func test_only_main_and_lib_lua_files_are_watched() -> void:
	var root := ROOT + "/collect"
	_write(root + "/main.lua", "return true")
	_write(root + "/lib/a.lua", "return {}")
	_write(root + "/lib/nested/b.lua", "return {}")
	_write(root + "/lib/notes.txt", "not watched")
	_write(root + "/assets/c.lua", "not watched")
	_write(root + "/content/d.lua", "not watched")

	var watcher = Watcher.new()
	var files: Array = watcher.watched_files(root)
	assert_eq(files, ["lib/a.lua", "lib/nested/b.lua", "main.lua"], "main.lua and lib/*.lua only")
	assert_eq(watcher.watched_ids(), [], "nothing is watched before watch()")


func test_change_is_debounced_before_the_reload_is_reported() -> void:
	var watcher = Watcher.new()
	watcher.configure({
		"poll_ms": 100,
		"debounce_ms": 100,
		"signature_source": Callable(self, "_signature_source"),
	})
	_signatures["griddycode.dev"] = {"main.lua": 1, "lib/build.lua": 1}
	var info: Dictionary = watcher.watch("griddycode.dev", ROOT + "/fake")
	assert_eq(int(info.get("files", 0)), 0, "provider does not require real files")
	assert_eq(watcher.tick(50.0), [], "not polled yet")

	_signatures["griddycode.dev"] = {"main.lua": 2, "lib/build.lua": 1}
	assert_eq(watcher.tick(100.0), [], "change is detected but not yet quiet")
	assert_eq(watcher.tick(100.0), ["griddycode.dev"], "reload after one stable debounce window")
	assert_eq(watcher.tick(100.0), [], "reported once")


func test_a_second_save_restarts_the_debounce_window() -> void:
	var watcher = Watcher.new()
	watcher.configure({
		"poll_ms": 100,
		"debounce_ms": 100,
		"signature_source": Callable(self, "_signature_source"),
	})
	_signatures["griddycode.dev"] = {"main.lua": 1}
	watcher.watch("griddycode.dev", ROOT + "/fake")

	_signatures["griddycode.dev"] = {"main.lua": 2}
	assert_eq(watcher.tick(100.0), [], "first change detected")
	_signatures["griddycode.dev"] = {"main.lua": 3}
	assert_eq(watcher.tick(100.0), [], "second change resets the quiet window")
	assert_eq(watcher.tick(100.0), ["griddycode.dev"], "stable after the second save")


func test_unwatch_stops_reporting_and_clear_removes_everything() -> void:
	var watcher = Watcher.new()
	watcher.configure({
		"poll_ms": 100,
		"debounce_ms": 0,
		"signature_source": Callable(self, "_signature_source"),
	})
	_signatures["a.dev"] = {"main.lua": 1}
	_signatures["b.dev"] = {"main.lua": 1}
	watcher.watch("a.dev", ROOT + "/a")
	watcher.watch("b.dev", ROOT + "/b")
	assert_eq(watcher.watched_ids(), ["a.dev", "b.dev"], "both watched")

	watcher.unwatch("a.dev")
	assert_eq(watcher.watched_ids(), ["b.dev"], "unwatch removes one id")
	_signatures["b.dev"] = {"main.lua": 2}
	assert_eq(watcher.tick(100.0), [], "detected")
	assert_eq(watcher.tick(100.0), ["b.dev"], "zero debounce reports on the next stable poll")

	watcher.clear()
	assert_eq(watcher.watched_ids(), [], "clear removes every id")
	assert_eq(watcher.tick(1000.0), [], "nothing left to report")


func _clean(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir != null:
		for name in dir.get_files():
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path.path_join(str(name))))
		for name in dir.get_directories():
			_clean(path.path_join(str(name)))
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path.path_join(str(name))))
	var absolute := ProjectSettings.globalize_path(path)
	if DirAccess.dir_exists_absolute(absolute):
		DirAccess.remove_absolute(absolute)
