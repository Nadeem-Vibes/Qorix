extends TestCase

## Mod settings: declaration, coercion, bounds, conflicts and persistence.

const Settings = preload("res://src/features/mods/mod_settings.gd")
const Store = preload("res://src/base/file_store.gd")

const ROOT := "user://griddy_mod_tests/settings"
const ID := "griddycode.test"


func before_each() -> void:
	_clean(ROOT)


func after_each() -> void:
	_clean(ROOT)


func _settings():
	var settings = Settings.new(ID, ROOT + "/data")
	settings.load_state()
	settings.declare([
		{"key": "level", "type": "int", "default": 3, "min": 0, "max": 10, "label": "Level"},
		{"key": "accent", "type": "string", "default": "blue", "label": "Accent"},
		{"key": "enabled", "type": "bool", "default": true, "label": "Enabled"},
		{"key": "scale", "type": "float", "default": 1.5, "label": "Scale"},
	], "manifest")
	return settings


func test_definitions_and_defaults() -> void:
	var settings = _settings()
	assert_eq(settings.definitions().size(), 4)
	assert_eq(int(settings.get_value("level", -1)["value"]), 3)
	assert_eq(str(settings.get_value("accent", "")["value"]), "blue")
	check(bool(settings.get_value("enabled", false)["value"]), "bool default")
	check(is_equal_approx(float(settings.get_value("scale", 0.0)["value"]), 1.5), "float default")


func test_coercion_and_bounds() -> void:
	var settings = _settings()

	# Lua has one number type, so an int setting arrives as 4.0.
	check(settings.set_value("level", 4.0).get("ok", false), "float-shaped int accepted")
	assert_eq(int(settings.get_value("level", -1)["value"]), 4)

	check(settings.set_value("level", 99).get("ok", false), "out-of-range value clamps")
	assert_eq(int(settings.get_value("level", -1)["value"]), 10)

	check(settings.set_value("level", -4).get("ok", false), "lower bound clamps")
	assert_eq(int(settings.get_value("level", -1)["value"]), 0)

	check(!settings.set_value("level", 2.5).get("ok", false), "fractional int rejected")
	assert_eq(_code(settings.set_value("level", "four")), "settings.invalid")
	assert_eq(_code(settings.set_value("enabled", "yes")), "settings.invalid")


func test_unknown_keys() -> void:
	var settings = _settings()
	assert_eq(_code(settings.get_value("nope", 0)), "settings.invalid")
	assert_eq(_code(settings.set_value("nope", 0)), "settings.invalid")


func test_declaration_rules() -> void:
	var settings = _settings()

	var same = settings.declare([
		{"key": "level", "type": "int", "default": 3, "label": "Level again"},
	], "runtime")
	check(same.get("ok", false), "redeclaring the same type is idempotent")

	var different = settings.declare([
		{"key": "level", "type": "string", "default": "high", "label": "Level"},
	], "runtime")
	check(!different.get("ok", false), "different type is refused")
	assert_eq(_code(different), "settings.conflict")

	var added = settings.declare([
		{"key": "extra", "type": "bool", "default": false, "label": "Extra"},
	], "runtime")
	check(added.get("ok", false), "runtime declarations are allowed")
	check(settings.has_definition("extra"), "runtime setting stored")


func test_persistence() -> void:
	var settings = _settings()
	settings.set_value("level", 7)
	settings.set_value("accent", "green")

	var reloaded = Settings.new(ID, ROOT + "/data")
	reloaded.declare([
		{"key": "level", "type": "int", "default": 3, "min": 0, "max": 10, "label": "Level"},
		{"key": "accent", "type": "string", "default": "blue", "label": "Accent"},
	], "manifest")

	assert_eq(int(reloaded.get_value("level", -1)["value"]), 7)
	assert_eq(str(reloaded.get_value("accent", "")["value"]), "green")


func test_malformed_settings_recover() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ROOT + "/data/" + ID))
	Store.save(ROOT + "/data/" + ID + "/settings.json", "not json")

	var settings = _settings()
	check(settings.get_value("level", 3).get("ok", false), "service still usable")
	check(FileAccess.file_exists(ROOT + "/data/" + ID + "/settings.json.corrupt"), "corrupt copy kept")
	assert_eq(int(settings.get_value("level", -1)["value"]), 3)


func _code(result: Dictionary) -> String:
	var failure: Variant = result.get("error")
	if failure is Dictionary:
		return str((failure as Dictionary).get("code", ""))
	return ""


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
