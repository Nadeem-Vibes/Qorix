extends "res://tests/support/test_case.gd"

const TEST_DIR := "user://tests_tmp"
const TEST_PATH := "user://tests_tmp/settings.json"

var service: SettingsService
var services: Array[SettingsService] = []


func before_each() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TEST_DIR))
	_remove_file(TEST_PATH)
	service = _new_service()


func after_each() -> void:
	for instance in services:
		if is_instance_valid(instance):
			instance.free()
	services.clear()
	service = null
	_remove_file(TEST_PATH)


func _remove_file(path: String) -> void:
	var global := ProjectSettings.globalize_path(path)
	if FileAccess.file_exists(global):
		DirAccess.remove_absolute(global)


func _font_options() -> Array:
	return [
		{"display": "Fira Code", "value": "Fira Code", "name": "font", "system": false},
		{"display": "Consolas", "value": "Consolas", "name": "Consolas", "system": true},
	]


func _new_service() -> SettingsService:
	var instance := SettingsService.new()
	instance.path = TEST_PATH
	instance.set_options("editor_font", _font_options())
	instance.set_default("editor_font", "Fira Code")
	services.append(instance)
	return instance


func _write_json(path: String, data: Dictionary) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(data))


func test_defaults_are_available() -> void:
	assert_eq(service.get_value("editor_font_size"), 16)
	assert_eq(service.get_value("caret_blink"), true)
	assert_eq(service.get_value("editor_font"), "Fira Code")
	assert_eq(service.get_value("ui_polish"), true)


func test_set_clamps_numbers_to_schema_range() -> void:
	assert_true(service.set_setting("editor_font_size", 21))
	assert_eq(service.get_value("editor_font_size"), 21)

	assert_true(service.set_setting("editor_font_size", 999))
	assert_eq(service.get_value("editor_font_size"), 48)

	assert_true(service.set_setting("editor_font_size", -5))
	assert_eq(service.get_value("editor_font_size"), 8)


func test_set_rejects_wrong_types() -> void:
	assert_false(service.set_setting("caret_blink", "yes"))
	assert_eq(service.get_value("caret_blink"), true)


func test_change_signal_reports_the_new_value() -> void:
	var seen: Array = []
	service.changed.connect(func(key: String, value: Variant) -> void:
		seen.append([key, value])
	)

	service.set_setting("editor_font", "Consolas")

	assert_eq(seen.size(), 1)
	assert_eq(seen[0][0], "editor_font")
	assert_eq(seen[0][1], "Consolas")


func test_save_writes_versioned_stable_ids_and_reloads() -> void:
	assert_true(service.set_setting("editor_font", "Consolas"))
	assert_true(service.set_setting("editor_font_size", 22))

	var saved: Dictionary = service.save()
	assert_eq(saved.get("ok"), true)

	var parsed = JSON.parse_string(FileAccess.get_file_as_string(TEST_PATH))
	assert_eq(typeof(parsed), TYPE_DICTIONARY)
	assert_eq(parsed.get("settings_version"), SettingsService.CURRENT_VERSION)
	assert_eq(parsed.get("values").get("editor_font"), "Consolas")
	assert_eq(parsed.get("values").get("editor_font_size"), 22)

	var loaded := _new_service()
	var result: Dictionary = loaded.load_settings()

	assert_eq(result.get("ok"), true)
	assert_eq(result.get("loaded"), true)
	assert_eq(loaded.get_value("editor_font"), "Consolas")
	assert_eq(loaded.get_value("editor_font_size"), 22)


func test_legacy_font_index_is_migrated_to_its_name() -> void:
	_write_json(TEST_PATH, {
		"settings_version": 0,
		"values": {"editor_font": 1},
	})

	var result: Dictionary = service.load_settings()

	assert_eq(result.get("migrated"), true)
	assert_eq(service.get_value("editor_font"), "Consolas")
	assert_eq(service.version(), SettingsService.CURRENT_VERSION)


func test_legacy_data_save_array_can_be_imported_once() -> void:
	var entries := [
		{"property": "editor_font", "value": 1},
		{"property": "editor_font_size", "value": 20.0},
	]

	var result: Dictionary = service.import_legacy(entries)

	assert_eq(result.get("imported"), 2)
	assert_eq(service.get_value("editor_font"), "Consolas")
	assert_eq(service.get_value("editor_font_size"), 20)
	assert_true(FileAccess.file_exists(TEST_PATH), "import should persist settings.json")

	var second: Dictionary = service.import_legacy(entries)
	assert_eq(second.get("skipped"), true)


func test_reset_returns_to_the_schema_default() -> void:
	service.set_setting("editor_font_size", 30)
	assert_true(service.reset("editor_font_size"))
	assert_eq(service.get_value("editor_font_size"), 16)


func test_every_setting_has_a_known_category_and_a_description() -> void:
	var category_keys := {}
	for category in service.categories():
		category_keys[str(category.get("key", ""))] = true

	assert_false(category_keys.is_empty())

	for entry in service.compat_entries():
		var key := str(entry.get("key", ""))
		assert_true(
			category_keys.has(str(entry.get("category", ""))),
			"%s has no known category" % key
		)
		assert_false(
			str(entry.get("description", "")).strip_edges().is_empty(),
			"%s is missing its hover note" % key
		)
