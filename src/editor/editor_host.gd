class_name EditorHost
extends Control

## Owns every EditorView. Exactly one view is visible at a time; the others
## stay alive so their undo history, carets, selection, folds and scroll
## offsets survive tab switches.
##
## The host is also the world's vertical extent. It used to be a scene
## constant (44630 px), which capped the editor at roughly 1,600 lines: past
## that the CodeEdit started scrolling internally while the camera kept
## treating the caret position as an unscrolled world coordinate. The height
## is now derived from the active document, so the only scroll this editor has
## is still the camera.

signal active_view_changed(view)
signal view_created(view)
signal view_content_changed(view)
signal view_large_file_changed(view, is_large)
signal height_changed(height: float)

const VIEW_SCENE = preload("res://src/editor/editor_view.tscn")

## Below this the camera's world feels cramped; it is also the resting height
## of an empty editor. It is not a content cap.
const MIN_WORLD_HEIGHT := 1080.0

## Extra world below the last line so the caret is never pinned to the very
## edge of the world when it is on the last line.
const CONTENT_MARGIN := 480.0

var views: Array = []
var active_view = null

var _next_view_number: int = 1
# Closing the focused tab would otherwise leave focus nowhere. Remember it so
# the next activated view picks the keyboard up again.
var _restore_focus: bool = false

## Resting height, without the inset a bottom dock is currently applying.
var _base_height: float = 0.0


func _ready() -> void:
	LuaSingleton.on_theme_load.connect(_on_theme_load)
	_base_height = maxf(offset_bottom, MIN_WORLD_HEIGHT)


## Height the editor uses before a bottom dock shrinks it. Panels must read
## this instead of caching offset_bottom: the value changes as the active
## document grows or shrinks.
func base_bottom() -> float:
	return _base_height


## Pure maths so the height policy can be checked headlessly.
static func height_for_content(lines: int, line_height: float) -> float:
	var content := maxf(1.0, float(lines)) * maxf(1.0, line_height) + CONTENT_MARGIN
	return maxf(MIN_WORLD_HEIGHT, content)


## Grows or shrinks the world to fit the active document. The dock inset is
## preserved: if a bottom panel currently holds 300 px of the editor, the new
## height keeps that 300 px taken and every other pixel goes to the code.
func refresh_height() -> void:
	var view = active_view
	if view == null or !is_instance_valid(view):
		return

	var lines := 1
	if view.has_method("get_line_count"):
		lines = maxi(1, int(view.get_line_count()))
	var line_height := 1.0
	if view.has_method("get_line_height"):
		line_height = float(view.get_line_height())

	var height := height_for_content(lines, line_height)
	var previous := _base_height
	if is_equal_approx(height, previous):
		return

	var inset := offset_bottom - previous
	_base_height = height
	offset_bottom = _base_height + inset

	_grow_world_background()
	height_changed.emit(_base_height)


## The dimmer behind the whole world is a scene sibling with its own fixed
## height. Without this it would end in the middle of a long file. The two
## effect layers below it have the same problem: they stop at y ~5200, which
## is where the VHS/sunlight and the bloom cut off mid-frame on long files.
func _grow_world_background() -> void:
	var parent := get_parent()
	if parent == null:
		return
	var world_height := _base_height + MIN_WORLD_HEIGHT
	for node_name in ["ExternalBackground", "ShaderLayer", "BloomLayer"]:
		var layer := parent.get_node_or_null(node_name)
		if layer is Control:
			(layer as Control).offset_bottom = maxf(
				(layer as Control).offset_bottom,
				world_height
			)


func create_view(document):
	var view = VIEW_SCENE.instantiate()
	view.name = "View%d" % _next_view_number
	_next_view_number += 1
	view.language_extension = document.language_extension()
	view.visible = false

	add_child(view)
	view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	view.content_changed.connect(_on_view_content_changed)
	view.large_file_mode_changed.connect(_on_view_large_file_changed)

	document.view = view
	view.load_document(document, document.pending_text())
	document.clear_pending_text()

	views.append(view)
	view_created.emit(view)
	return view


func activate(view) -> void:
	if view == null or view == active_view:
		return
	if !views.has(view):
		return

	var old = active_view
	var had_focus: bool = _restore_focus or (old != null and is_instance_valid(old) and old.has_focus())
	_restore_focus = false

	view.show()
	if old != null and is_instance_valid(old):
		old.hide()

	active_view = view
	refresh_height()
	if had_focus:
		view.grab_focus()

	active_view_changed.emit(view)


func destroy_view(view) -> void:
	if view == null:
		return

	views.erase(view)
	if active_view == view:
		_restore_focus = is_instance_valid(view) and view.has_focus()
		active_view = null
		active_view_changed.emit(null)

	if is_instance_valid(view):
		view.visible = false
		view.queue_free()


func apply_setting(property: String, value: Variant) -> void:
	for view in views:
		if is_instance_valid(view):
			view.apply_setting(property, value)
	# Font size and line height change how tall every line is.
	refresh_height()


func grab_active_focus() -> void:
	if active_view != null and is_instance_valid(active_view):
		active_view.grab_focus()


func release_active_focus() -> void:
	if active_view != null and is_instance_valid(active_view):
		active_view.release_focus()


func has_active_view() -> bool:
	return active_view != null and is_instance_valid(active_view)


func _on_view_content_changed(view) -> void:
	if view == active_view:
		refresh_height()
	view_content_changed.emit(view)


func _on_view_large_file_changed(view, is_large: bool) -> void:
	view_large_file_changed.emit(view, is_large)


func active_large_file() -> bool:
	return active_view != null and is_instance_valid(active_view) and bool(active_view.get("large_file"))


func _on_theme_load() -> void:
	for view in views:
		if !is_instance_valid(view):
			continue
		view.apply_theme()
		view.apply_language()
	refresh_height()
