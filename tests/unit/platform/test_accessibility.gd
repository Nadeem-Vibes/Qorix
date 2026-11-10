extends "res://tests/support/test_case.gd"

const A11y = preload("res://src/platform/a11y.gd")
const SettingsScript = preload("res://src/platform/settings_service.gd")

var service: Node


func before_each() -> void:
	service = SettingsScript.new()


func after_each() -> void:
	if service != null:
		service.free()
	service = null


# ── CONTRAST ────────────────────────────────────────────────────────────────

func test_black_on_white_is_the_maximum_contrast() -> void:
	assert_true(absf(A11y.contrast_ratio(Color.BLACK, Color.WHITE) - 21.0) < 0.05)


func test_identical_colours_have_no_contrast() -> void:
	assert_true(absf(A11y.contrast_ratio(Color("#808080"), Color("#808080")) - 1.0) < 0.001)


func test_high_contrast_foregrounds_meet_wcag_aaa() -> void:
	var background: Color = A11y.HIGH_CONTRAST_GUI["background_color"]
	for key in ["font_color", "selection_color", "caret_color"]:
		var ratio: float = A11y.contrast_ratio(A11y.HIGH_CONTRAST_GUI[key], background)
		assert_true(ratio >= 7.0, "%s only reaches %.2f:1" % [key, ratio])

	for key in A11y.HIGH_CONTRAST_KEYWORDS.keys():
		var ratio: float = A11y.contrast_ratio(A11y.HIGH_CONTRAST_KEYWORDS[key], background)
		assert_true(ratio >= 7.0, "keyword %s only reaches %.2f:1" % [key, ratio])


# ── LINE HEIGHT ─────────────────────────────────────────────────────────────

func test_line_height_is_converted_to_themes_extra_pixels() -> void:
	# 16 px at 1.25 is the theme's default 4 px of extra spacing.
	assert_eq(A11y.line_spacing_px(16, 1.25), 4)
	assert_eq(A11y.line_spacing_px(16, 1.0), 0)
	assert_eq(A11y.line_spacing_px(20, 2.5), 30)
	# Values outside the setting range are clamped, never used raw.
	assert_eq(A11y.line_spacing_px(16, 9.0), 24)
	assert_eq(A11y.line_spacing_px(16, 0.1), 0)
	assert_eq(A11y.clamped_line_height(9.0), A11y.MAX_LINE_HEIGHT)
	assert_eq(A11y.clamped_line_height(0.1), A11y.MIN_LINE_HEIGHT)


# ── LARGE FILES ─────────────────────────────────────────────────────────────

func test_large_file_decision_uses_lines_and_characters() -> void:
	assert_false(A11y.is_large_file(100, 1000))
	assert_false(A11y.is_large_file(5000, 1000))
	assert_true(A11y.is_large_file(5001, 1000))
	assert_true(A11y.is_large_file(10000, 1000))
	# A minified bundle has few lines but far too much text to scan.
	assert_true(A11y.is_large_file(4, A11y.LARGE_FILE_CHARS + 1))
	# The user threshold is honoured, but never below the safety floor.
	assert_true(A11y.is_large_file(900, 100, 800))
	assert_false(A11y.is_large_file(400, 100, 100))


func test_motion_is_restricted_by_either_switch() -> void:
	assert_true(A11y.motion_restricted(true, false))
	assert_true(A11y.motion_restricted(false, true))
	assert_true(A11y.motion_restricted(true, true))
	assert_false(A11y.motion_restricted(false, false))


# ── DYSLEXIA FONT AND FOCUS RING ────────────────────────────────────────────

func test_dyslexia_font_prefers_an_installed_designated_face() -> void:
	var fonts := [
		{"display": "Fira Code"},
		{"display": "OpenDyslexic"},
		{"display": "Atkinson Hyperlegible"},
	]
	assert_eq(A11y.pick_font(fonts).get("display"), "OpenDyslexic")

	fonts = [{"display": "fira code"}, {"display": "opendyslexic"}]
	assert_eq(A11y.pick_font(fonts).get("display"), "opendyslexic", "matching is case-insensitive")

	fonts = [{"display": "Lexend Deca"}]
	assert_eq(A11y.pick_font(fonts).get("display"), "Lexend Deca", "a family variant is accepted")

	fonts = [{"display": "Fira Code"}]
	assert_true(A11y.pick_font(fonts).is_empty())


func test_focus_ring_is_visible_and_coloured() -> void:
	var style := A11y.focus_stylebox(Color("#ffe600"), 3)
	assert_eq(style.border_width_top, 3)
	assert_eq(style.border_width_left, 3)
	assert_eq(style.border_color, Color("#ffe600"))
	assert_true(style.bg_color.a < 0.01, "the ring must not repaint the control background")


# ── SETTINGS SCHEMA ─────────────────────────────────────────────────────────

func test_accessibility_and_performance_settings_exist() -> void:
	for key in [
		"editor_line_height", "reduced_motion", "static_camera", "high_contrast",
		"dyslexia_font", "focus_indicators", "ui_language", "large_file_mode",
		"large_file_threshold", "background_indexing", "ui_polish",
	]:
		assert_true(service.has(key), "missing setting: " + key)


func test_accessibility_defaults_are_sane() -> void:
	assert_eq(service.get_value("editor_line_height"), 1.25)
	assert_eq(service.get_value("reduced_motion"), false)
	assert_eq(service.get_value("static_camera"), false)
	assert_eq(service.get_value("ui_polish"), true)
	assert_eq(service.get_value("high_contrast"), false)
	assert_eq(service.get_value("focus_indicators"), true)
	assert_eq(service.get_value("ui_language"), "en")
	assert_eq(service.get_value("large_file_mode"), true)
	assert_eq(service.get_value("large_file_threshold"), 5000)
	assert_eq(service.get_value("background_indexing"), true)


func test_line_height_setting_clamps_to_its_range() -> void:
	assert_true(service.set_setting("editor_line_height", 9.0))
	assert_eq(service.get_value("editor_line_height"), 2.5)
	assert_true(service.set_setting("editor_line_height", 0.1))
	assert_eq(service.get_value("editor_line_height"), 1.0)


func test_new_categories_are_present() -> void:
	var keys: Array = []
	for category in service.categories():
		keys.append(str(category.get("key", "")))
	assert_true(keys.has("accessibility"))
	assert_true(keys.has("localization"))
	assert_true(keys.has("performance"))
