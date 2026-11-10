extends TestCase

## Mod storage, blobs and progress: quotas, atomic writes and corruption recovery.

const Storage = preload("res://src/features/mods/mod_storage.gd")
const Progress = preload("res://src/features/mods/mod_progress.gd")
const Store = preload("res://src/base/file_store.gd")

const ROOT := "user://griddy_mod_tests/storage"
const ID := "griddycode.test"


func before_each() -> void:
	_clean(ROOT)


func after_each() -> void:
	_clean(ROOT)


func _storage():
	var storage = Storage.new(ID, ROOT + "/data")
	storage.load_state()
	return storage


func _progress():
	var progress = Progress.new(ID, ROOT + "/data")
	progress.load_state()
	return progress


func _mod_dir() -> String:
	return ROOT + "/data/" + ID


func test_kv_roundtrip_and_keys() -> void:
	var storage = _storage()
	check(storage.set_value("count", 2).get("ok", false), "set count")
	check(storage.set_value("name", "Griddy").get("ok", false), "set name")
	check(storage.set_value("nested", {"a": [1, 2, 3]}).get("ok", false), "set nested")

	var keys: Array = storage.keys()["value"]
	assert_eq(keys, ["count", "name", "nested"])

	var count = storage.get_value("count", 0)["value"]
	check(int(count) == 2, "int survives JSON")
	var nested = storage.get_value("nested", {})["value"]
	assert_eq(nested["a"], [1, 2, 3])

	check(storage.delete("name").get("ok", false), "delete key")
	check(!(storage.keys()["value"] as Array).has("name"), "deleted key is gone")


func test_persistence() -> void:
	var storage = _storage()
	storage.set_value("persisted", true)

	var reloaded = _storage()
	check(bool(reloaded.get_value("persisted", false)["value"]), "value survives a new instance")


func test_invalid_values() -> void:
	var storage = _storage()
	assert_eq(_code(storage.set_value("", 1)), "storage.invalid_key")
	assert_eq(_code(storage.set_value("bad key!", 1)), "storage.invalid_key")
	assert_eq(_code(storage.set_value("callback", Callable())), "storage.invalid_value")
	assert_eq(_code(storage.set_value("object", RefCounted.new())), "storage.invalid_value")


func test_kv_quota() -> void:
	var storage = _storage()
	storage.set_value("kept", "yes")

	var oversized := "x".repeat(Storage.KV_QUOTA + 1)
	assert_eq(_code(storage.set_value("oversized", oversized)), "storage.quota")
	assert_eq(str(storage.get_value("kept", "")["value"]), "yes")


func test_malformed_kv_recovers() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_mod_dir()))
	Store.save(_mod_dir() + "/kv.json", "{not json")

	var storage = _storage()
	check(storage.get_value("anything", "fallback").get("ok", false), "service still usable")
	check(FileAccess.file_exists(_mod_dir() + "/kv.json.corrupt"), "corrupt copy kept")
	check(!FileAccess.file_exists(_mod_dir() + "/kv.json"), "broken file removed")


func test_blobs() -> void:
	var storage = _storage()
	var written = storage.blob_write("note.txt", "hello".to_utf8_buffer())
	check(written.get("ok", false), "blob write")

	var read = storage.blob_read("note.txt")
	check(read.get("ok", false), "blob read")
	assert_eq((read["value"] as PackedByteArray).get_string_from_utf8(), "hello")

	var usage: Dictionary = storage.usage()
	assert_eq(int(usage.get("blob_bytes", 0)), 5)
	assert_eq(int(usage.get("blob_count", 0)), 1)

	assert_eq(_code(storage.blob_write("../escape", "x")), "storage.invalid_key")
	assert_eq(_code(storage.blob_read("missing.txt")), "module.not_found")

	check(storage.blob_delete("note.txt").get("ok", false), "blob delete")
	assert_eq(int(storage.usage().get("blob_bytes", -1)), 0)


func test_no_temp_files() -> void:
	var storage = _storage()
	for index in range(50):
		storage.set_value("counter", index)

	storage.flush()
	_check_no_temp_files(_mod_dir())


func test_progress() -> void:
	var progress = _progress()
	check(progress.set_value("lessons", 2).get("ok", false), "set progress")
	check(progress.increment("lessons", 3).get("ok", false), "increment progress")
	assert_eq(int(progress.get_value("lessons", 0)["value"]), 5)

	check(progress.set_value("last", "hello").get("ok", false), "second key")
	check(progress.reset("last").get("ok", false), "reset one key")
	check(!progress.all()["value"].has("last"), "key removed")

	var reloaded = _progress()
	assert_eq(int(reloaded.get_value("lessons", 0)["value"]), 5)

	reloaded.reset("")
	check((reloaded.all()["value"] as Dictionary).is_empty(), "reset all")
	assert_eq(_code(reloaded.set_value("bad key!", 1)), "storage.invalid_key")


func _code(result: Dictionary) -> String:
	var failure: Variant = result.get("error")
	if failure is Dictionary:
		return str((failure as Dictionary).get("code", ""))
	return ""


func _check_no_temp_files(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	for name in dir.get_files():
		check(!str(name).ends_with(".griddy_tmp"), "no temp file: " + str(name))
	for directory in dir.get_directories():
		_check_no_temp_files(path.path_join(str(directory)))


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
