extends Node2D

## World-space ghost renderer.
##
## Lives under EditorHost, so it inherits the camera pan and zoom. The ghost is a
## declarative slice from GuideMatcher, never stored in the document; a repaint
## is one draw_string per ghost cluster plus the next-cluster box, capped at 64
## characters and 8 lines by the matcher.
##
## Alignment note: `GuideLayout` resolves each cluster's rectangle.
## `TextEdit.get_rect_at_line_column` anchors positions that exist in the
## document; the common ghost case, a column past the end of the real line,
## is advanced with font metrics instead. Wrapped and folded lines are excluded
## during a session (the guide forces no-wrap); combining marks are drawn per
## cluster, so a proportional font or a tab cannot shift the rest of the line.

const GHOST_ALPHA_DEFAULT := 0.32
const Layout = preload("res://src/features/learning/guide/guide_layout.gd")

var view = null

var _ghost: Dictionary = {}
var _alpha := GHOST_ALPHA_DEFAULT
var _foreground := Color("#cdd6f4")
var _accent := Color("#89b4fa")
var _danger := Color("#f7768e")

var _flash_line := -1
var _flash_col := -1
var _flash_until_ms := 0

var _camera_position := Vector2.INF
var _camera_zoom := Vector2.ZERO


func _ready() -> void:
	position = Vector2.ZERO
	z_index = 20
	visible = false


func set_colors(foreground: Color, accent: Color, danger: Color) -> void:
	_foreground = foreground
	_accent = accent
	_danger = danger
	queue_redraw()


func set_session(view_ref, ghost: Dictionary, alpha: float = GHOST_ALPHA_DEFAULT) -> void:
	view = view_ref
	_ghost = ghost if ghost is Dictionary else {}
	_alpha = clampf(alpha, 0.05, 1.0)
	visible = !_ghost.is_empty() and _has_lines()
	queue_redraw()


func clear() -> void:
	view = null
	_ghost = {}
	_flash_line = -1
	_flash_col = -1
	visible = false
	queue_redraw()


func flash_mistake(line: int, col: int) -> void:
	_flash_line = int(line)
	_flash_col = int(col)
	_flash_until_ms = Time.get_ticks_msec() + 450
	queue_redraw()


func _process(_delta: float) -> void:
	var camera := get_viewport().get_camera_2d() if is_inside_tree() else null
	if camera != null:
		if camera.global_position != _camera_position or camera.zoom != _camera_zoom:
			_camera_position = camera.global_position
			_camera_zoom = camera.zoom
			queue_redraw()

	if _flash_until_ms > 0 and Time.get_ticks_msec() >= _flash_until_ms:
		_flash_until_ms = 0
		queue_redraw()


func _draw() -> void:
	if view == null or !is_instance_valid(view) or !_has_lines():
		return
	if !view.has_method("get_rect_at_line_column"):
		return

	var font: Font = Layout.view_font(view)
	if font == null:
		return
	var font_size := Layout.view_font_size(view)
	var baseline := Layout.baseline_offset(view, font, font_size)
	var ghost_color := Color(_foreground, _alpha)
	var entries := Layout.cluster_rects(view, _ghost, font, font_size)

	for entry in entries:
		var rect: Rect2 = entry.get("rect", Rect2())
		var text := str(entry.get("text", ""))
		draw_string(
			font,
			rect.position + Vector2(0.0, baseline),
			text,
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			font_size,
			ghost_color,
		)

	var next_text := str(_ghost.get("next", ""))
	if !next_text.is_empty() and next_text != "\n" and !entries.is_empty():
		var first: Rect2 = entries[0].get("rect", Rect2())
		draw_rect(first.grow(1.0), Color(_accent, 0.85), false, 2.0)

	if _flash_until_ms > 0 and _flash_line >= 0:
		var flash := Layout.position_rect(view, _flash_line, _flash_col, font, font_size)
		var remaining := clampf(float(_flash_until_ms - Time.get_ticks_msec()) / 450.0, 0.0, 1.0)
		draw_rect(flash.grow(1.0), Color(_danger, 0.35 * remaining), true)


func _has_lines() -> bool:
	var lines: Variant = _ghost.get("lines", [])
	return lines is Array and !(lines as Array).is_empty()
