extends "res://tests/support/test_case.gd"

## The scrolling settings drive the camera and the screen-space minimap, not
## the CodeEdit (which never scrolls internally in this editor). These checks
## pin the mapping maths and the schema those two depend on.
##
## The maths lives in src/editor/scroll_math.gd on purpose: it is free of
## autoload dependencies, so it can be checked without booting the editor.

const Scroll = preload("res://src/editor/scroll_math.gd")

const TEST_DIR := "user://tests_tmp_scroll"
const TEST_PATH := "user://tests_tmp_scroll/settings.json"

var service: SettingsService


func before_each() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TEST_DIR))
	_remove_file(TEST_PATH)
	service = SettingsService.new()
	service.path = TEST_PATH


func after_each() -> void:
	if service != null:
		service.free()
	service = null
	_remove_file(TEST_PATH)


func _remove_file(path: String) -> void:
	var global := ProjectSettings.globalize_path(path)
	if FileAccess.file_exists(global):
		DirAccess.remove_absolute(global)


func _write_json(path: String, data: Dictionary) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(data))


# ── CAMERA GLIDE ─────────────────────────────────────────────────────────────

func test_a_short_move_still_takes_a_moment() -> void:
	# Even a one-line correction has to be a visible movement.
	assert_eq(Scroll.glide_duration(0.0, 700.0), Scroll.MIN_TIME)
	assert_true(Scroll.glide_duration(34.0, 700.0) >= Scroll.MIN_TIME)
	assert_true(Scroll.glide_duration(34.0, 700.0) < Scroll.MIN_TIME + 0.1)


func test_the_glide_time_grows_with_the_distance() -> void:
	# A longer move takes proportionally longer at the configured speed.
	var short := Scroll.glide_duration(340.0, 700.0)
	var long := Scroll.glide_duration(1340.0, 700.0)
	assert_true(long > short)
	assert_true(absf((long - short) - (1340.0 - 340.0) / 700.0) < 0.0001)


func test_a_long_glide_is_capped() -> void:
	# A jump to the far end of a huge file must not crawl.
	assert_eq(Scroll.glide_duration(100000.0, 700.0), Scroll.MAX_TIME)


func test_the_glide_survives_a_zero_speed() -> void:
	assert_eq(Scroll.glide_duration(500.0, 0.0), Scroll.MIN_TIME)


func test_the_glide_progress_starts_fast_and_settles() -> void:
	# It must start at full speed, or a glide that restarts on every caret
	# move would stall.
	assert_eq(Scroll.glide_progress(0.0), 0.0)
	assert_true(Scroll.glide_progress(0.01) > 0.0)
	# ...and it must land exactly on the target.
	assert_eq(Scroll.glide_progress(1.0), 1.0)
	# The progress never goes backwards.
	var previous := 0.0
	for i in range(21):
		var progress := Scroll.glide_progress(float(i) / 20.0)
		assert_true(progress >= previous, "the progress must not go backwards")
		previous = progress


# ── MINIMAP MAPPING ──────────────────────────────────────────────────────────

func test_a_short_file_keeps_thin_rows() -> void:
	# Five lines must stay five thin rows, not five blocks a fifth of the
	# screen each.
	assert_eq(Scroll.strip_row_height(5, 1046.0), Scroll.ROW_HEIGHT)
	assert_eq(Scroll.strip_row_height(1, 1046.0), Scroll.ROW_HEIGHT)
	# A file with more lines than the strip has pixels shares them out.
	assert_eq(Scroll.strip_row_height(1046, 1046.0), 1.0)
	assert_true(Scroll.strip_row_height(5000, 1046.0) < 1.0)


func test_minimap_line_mapping_round_trips() -> void:
	var y: float = Scroll.line_to_strip_y(10.0, 100, 500.0)
	assert_eq(y, 30.0)
	assert_eq(Scroll.strip_y_to_line(y, 100, 500.0), 10)


func test_minimap_line_mapping_clamps_to_the_file() -> void:
	assert_eq(Scroll.strip_y_to_line(-10.0, 100, 500.0), 0)
	assert_eq(Scroll.strip_y_to_line(9999.0, 100, 500.0), 99)


func test_minimap_line_mapping_survives_an_empty_file() -> void:
	assert_eq(Scroll.line_to_strip_y(0.0, 0, 500.0), 0.0)
	assert_eq(Scroll.strip_y_to_line(120.0, 0, 500.0), 0)


# ── SCHEMA ───────────────────────────────────────────────────────────────────

func test_the_scrolling_settings_exist() -> void:
	assert_true(service.has("smooth_scrolling"))
	assert_true(service.has("scroll_speed"))
	assert_true(service.has("minimap"))
	assert_true(service.has("minimap_width"))


func test_smooth_scrolling_defaults_to_on() -> void:
	assert_eq(service.get_value("smooth_scrolling"), Scroll.DEFAULT_SMOOTH_SCROLLING)


func test_the_scroll_speed_default_is_shared_with_the_camera() -> void:
	assert_eq(service.get_value("scroll_speed"), int(Scroll.DEFAULT_SCROLL_SPEED))


func test_the_scroll_speed_slider_range() -> void:
	# The slider starts at 100 px/s so a very slow glide is reachable.
	var entry: Dictionary = service.compat_entry("scroll_speed")
	assert_eq(entry.get("min", 0), 100)
	assert_eq(entry.get("max", 0), 6000)

	# ...and the store clamps to it.
	assert_true(service.set_setting("scroll_speed", 50))
	assert_eq(service.get_value("scroll_speed"), 100)
	assert_true(service.set_setting("scroll_speed", 99999))
	assert_eq(service.get_value("scroll_speed"), 6000)


func test_the_codeedit_scroll_speed_key_is_gone() -> void:
	# It drove TextEdit.scroll_v_scroll_speed, which this editor never uses.
	assert_false(service.has("v_scroll_speed"))


func test_a_persisted_codeedit_scroll_speed_is_ignored() -> void:
	_write_json(TEST_PATH, {
		"settings_version": SettingsService.CURRENT_VERSION,
		"values": {"v_scroll_speed": 900},
	})

	var result: Dictionary = service.load_settings()

	assert_true(result.get("ok", false))
	assert_false(service.has("v_scroll_speed"))
	assert_eq(service.get_value("scroll_speed"), int(Scroll.DEFAULT_SCROLL_SPEED))
