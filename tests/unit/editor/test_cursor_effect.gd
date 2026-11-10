extends "res://tests/support/test_case.gd"

## The cursor trail draws itself with a shader, but the decisions that decide
## *where* it goes are plain maths: the shape of the caret, the rectangle the
## shader has to cover, and whether a movement is worth animating.
##
## Those live in src/editor/cursor_effect_math.gd on purpose: they are free
## of autoload dependencies, so they can be checked without booting the
## editor. The settings the trail reads are checked here too, so a schema
## change cannot silently break the effect.

const Cursor = preload("res://src/editor/cursor_effect_math.gd")

const CELL := Rect2(100.0, 200.0, 9.0, 18.0)


# ── CARET SHAPE ───────────────────────────────────────────────────────────────

func test_the_block_caret_covers_the_cell() -> void:
	var shape := Cursor.caret_shape(CELL, Cursor.CARET_BLOCK, 1.0, 2.0)
	assert_eq(shape, CELL)


func test_the_line_caret_is_a_bar_on_the_left_edge() -> void:
	var shape := Cursor.caret_shape(CELL, Cursor.CARET_LINE, 1.0, 2.0)
	assert_eq(shape.position.x, CELL.position.x)
	assert_eq(shape.size.y, CELL.size.y)
	assert_true(shape.size.x >= Cursor.MIN_TRAIL_WIDTH)
	assert_true(shape.size.x < CELL.size.x)


func test_the_line_caret_keeps_a_wider_theme_caret() -> void:
	# A theme that draws a fat caret gets a fat trail.
	var shape := Cursor.caret_shape(CELL, Cursor.CARET_LINE, 6.0, 2.0)
	assert_eq(shape.size.x, 6.0)


func test_the_underline_caret_sits_at_the_bottom_of_the_cell() -> void:
	var shape := Cursor.caret_shape(CELL, Cursor.CARET_UNDERLINE, 1.0, 3.0)
	assert_eq(shape.position.x, CELL.position.x)
	assert_eq(shape.size.x, CELL.size.x)
	assert_eq(shape.size.y, 3.0)
	assert_eq(shape.position.y + shape.size.y, CELL.position.y + CELL.size.y)


func test_an_empty_cell_has_no_caret() -> void:
	assert_eq(Cursor.caret_shape(Rect2(), Cursor.CARET_BLOCK, 1.0, 2.0), Rect2())


# ── MOVEMENT ──────────────────────────────────────────────────────────────────

func test_travel_measures_the_distance_between_the_centres() -> void:
	var a := Rect2(0.0, 0.0, 10.0, 20.0)
	var b := Rect2(30.0, 0.0, 10.0, 20.0)
	assert_eq(Cursor.travel(a, b), 30.0)


func test_a_move_below_the_threshold_is_not_animated() -> void:
	var a := Rect2(0.0, 0.0, 10.0, 20.0)
	var b := Rect2(0.5, 0.0, 10.0, 20.0)
	# 20px tall caret, threshold 5% => a move under 1px is ignored.
	assert_false(Cursor.should_animate(a, b, Cursor.DEFAULT_MOVE_THRESHOLD))


func test_a_real_move_is_animated() -> void:
	var a := Rect2(0.0, 0.0, 10.0, 20.0)
	var b := Rect2(40.0, 0.0, 10.0, 20.0)
	assert_true(Cursor.should_animate(a, b, Cursor.DEFAULT_MOVE_THRESHOLD))


func test_a_caret_without_a_cell_is_never_animated() -> void:
	var a := Rect2()
	var b := Rect2(0.0, 0.0, 10.0, 20.0)
	assert_false(Cursor.should_animate(a, b, Cursor.DEFAULT_MOVE_THRESHOLD))
	assert_false(Cursor.should_animate(b, a, Cursor.DEFAULT_MOVE_THRESHOLD))


# ── BOUNDS ────────────────────────────────────────────────────────────────────

func test_the_bounds_cover_both_carets() -> void:
	var a := Rect2(0.0, 0.0, 10.0, 20.0)
	var b := Rect2(50.0, 40.0, 10.0, 20.0)
	var bounds := Cursor.trail_bounds(a, b, 0.0)
	assert_eq(bounds.position, Vector2(0.0, 0.0))
	assert_eq(bounds.size, Vector2(60.0, 60.0))


func test_the_bounds_grow_by_the_padding() -> void:
	var a := Rect2(0.0, 0.0, 10.0, 20.0)
	var bounds := Cursor.trail_bounds(a, a, 4.0)
	assert_eq(bounds.position, Vector2(-4.0, -4.0))
	assert_eq(bounds.size, Vector2(18.0, 28.0))


func test_the_bounds_of_an_empty_caret_are_empty() -> void:
	assert_eq(Cursor.trail_bounds(Rect2(), Rect2(), 4.0), Rect2())


# ── SOFT EDGE ────────────────────────────────────────────────────────────────

func test_the_edge_scales_with_the_caret() -> void:
	assert_true(Cursor.edge_size(40.0) > Cursor.edge_size(20.0))


func test_the_edge_is_never_thinner_than_the_floor() -> void:
	assert_eq(Cursor.edge_size(1.0), Cursor.MIN_EDGE)


# ── SETTINGS ─────────────────────────────────────────────────────────────────

func test_the_trail_settings_have_their_defaults() -> void:
	var service := SettingsService.new()
	assert_eq(service.get_value("cursor_effect"), Cursor.EFFECT_WARP)
	assert_eq(service.get_value("cursor_effect_duration"), Cursor.DEFAULT_DURATION)
	assert_eq(service.get_value("cursor_effect_opacity"), Cursor.DEFAULT_OPACITY)
	service.free()


func test_the_effect_setting_offers_the_three_effects() -> void:
	var service := SettingsService.new()
	var entry: Dictionary = service.compat_entry("cursor_effect")
	assert_false(entry.is_empty())
	var values: Array = []
	for option in entry.get("options", []):
		var choice: Dictionary = option
		values.append(choice.get("value"))
	assert_true(values.has(Cursor.EFFECT_OFF))
	assert_true(values.has(Cursor.EFFECT_WARP))
	assert_true(values.has(Cursor.EFFECT_SWEEP))
	assert_true(values.has(Cursor.EFFECT_TAIL))
	service.free()
