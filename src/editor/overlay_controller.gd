class_name OverlayController
extends Node

## Replaces the old `_show` / `active_overlay` booleans in settings.gd with a
## small stack. Only one world-space overlay is open at a time (same rule as
## before), but every open/close now goes through one place.

const ANIMATION_TIME := 0.2
const DEFAULT_FACTOR := 18.0 * 7.5
const UI_MOTION = preload("res://src/platform/ui_motion.gd")

var editor = null
var camera = null
var background = null

var _stack: Array = []
var _animating: bool = false
var _active_factor: float = 0.0
var _background_applied: bool = false
## Reduced-motion mode turns every fade/slide into an instant cut. The
## overlay still serialises open/close through _animating, only the duration
## changes.
var reduced_motion: bool = false


func is_open(panel) -> bool:
	return _stack.has(panel)


func has_open_panel() -> bool:
	return !_stack.is_empty()


func is_animating() -> bool:
	return _animating


func prepare(panels: Array) -> void:
	for panel in panels:
		if panel == null:
			continue
		panel.modulate.a = 0.0
		panel.hide()


func toggle(panel, apply_background: bool = true, factor: float = DEFAULT_FACTOR) -> void:
	if panel == null:
		return

	if is_open(panel):
		close(panel)
	else:
		open(panel, apply_background, factor)


func open(panel, apply_background: bool = true, factor: float = DEFAULT_FACTOR) -> void:
	if panel == null or _animating:
		return
	if !_stack.is_empty():
		return

	_animating = true
	_stack.append(panel)
	_active_factor = factor
	_background_applied = apply_background

	var future_pos: Vector2 = panel.position + Vector2(factor, 0.0)

	panel.show()
	panel.modulate.a = 0.0

	# The About page is authored with huge fonts that outgrew the viewport when
	# the shortcut list got longer: at native camera scale only a cut-off
	# middle slice was visible. Fit it to the window so the whole page shows.
	if panel.name == "Info":
		_fit_info_page(panel)

	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(panel, "modulate:a", 1.0, _animation_time())

	if !is_zero_approx(factor):
		tw.tween_property(panel, "position", future_pos, _animation_time())
	else:
		tw.tween_interval(_animation_time())

	tw.chain().tween_callback(func() -> void:
		_animating = false
	)

	if apply_background:
		_fade_background(1.0)

	if panel is FileDialogType:
		panel.active = true
		if editor != null and !editor.current_file:
			editor.warn("[color=yellow]WARNING[/color]: You are currently in an empty file. No autosave will be performed.")

	if camera != null and !_is_hud_panel(panel):
		camera.focus_on(future_pos + _focus_offset(panel), panel.zoom if ("zoom" in panel) else Vector2(1, 1))

	if editor != null:
		editor.editor_host.release_active_focus()

	if !apply_background:
		panel.grab_focus()

	_on_panel_open(panel)


func close(panel) -> void:
	if panel == null or _animating:
		return
	if !is_open(panel):
		return

	_animating = true
	_stack.erase(panel)

	var future_pos: Vector2 = panel.position - Vector2(_active_factor, 0.0)

	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(panel, "modulate:a", 0.0, _animation_time())

	if !is_zero_approx(_active_factor):
		tw.tween_property(panel, "position", future_pos, _animation_time())
	else:
		tw.tween_interval(_animation_time())

	tw.chain().tween_callback(func() -> void:
		panel.hide()
		_animating = false
	)

	if _background_applied:
		_fade_background(0.0)

	if panel is FileDialogType:
		panel.active = false

	if camera != null:
		camera.focus_die()

	if editor != null:
		if !(panel is FileDialogType):
			editor.editor_host.grab_active_focus()

	_on_panel_close(panel)


func close_all() -> void:
	# Overlays never stack, so closing the top one closes the only one.
	if _stack.is_empty() or _animating:
		return
	close(_stack.back())


func _on_panel_open(panel) -> void:
	if panel.name == "Settings":
		# The cat only decodes/plays while its panel is visible; autoplay from
		# launch wasted that work behind a hidden node.
		var video: Node = panel.get_node_or_null("VideoStreamPlayer")
		if video is VideoStreamPlayer and !(video as VideoStreamPlayer).is_playing():
			(video as VideoStreamPlayer).play()

		var settings_list = panel.get_node_or_null("SettingsList")
		if settings_list != null and settings_list.has_method("refresh_values"):
			settings_list.refresh_values()
		if settings_list != null and settings_list.has_method("focus_first"):
			settings_list.focus_first()

	if panel.has_method("on_open"):
		panel.on_open()


func _on_panel_close(panel) -> void:
	if panel.name == "Settings":
		var video: Node = panel.get_node_or_null("VideoStreamPlayer")
		if video is VideoStreamPlayer:
			(video as VideoStreamPlayer).stop()

	if panel.has_method("on_close"):
		panel.on_close()


func _fade_background(opacity: float) -> void:
	if background == null:
		return

	if opacity > 0.0:
		background.show()

	var tw := create_tween()
	tw.tween_property(background, "modulate:a", opacity, _animation_time())
	if opacity <= 0.0:
		tw.tween_callback(background.hide)


func _is_hud_panel(panel) -> bool:
	return panel is Control and panel.get_parent() is CanvasLayer


func _animation_time() -> float:
	return UI_MOTION.duration(ANIMATION_TIME)


## Offset from a world-space panel's origin to the point the camera should
## center on. These panels park their content off the node origin (the scenes
## are authored with huge font sizes scaled down, and the origin only anchors
## the slide animation), so focusing the origin itself leaves the page pushed
## to the lower-right of the viewport.
func _focus_offset(panel) -> Vector2:
	if panel.name == "Settings":
		var settings_list = panel.get_node_or_null("SettingsList")
		if settings_list is Control and settings_list.size != Vector2.ZERO:
			return settings_list.position + settings_list.size * 0.5
		return Vector2.ZERO

	if panel.name == "Info":
		var rect := _text_content_rect(panel)
		if rect.has_area():
			return rect.get_center() * panel.scale

	return Vector2.ZERO


## Scales the About page so its rendered content fits the camera's view with a
## little breathing room. Local label metrics are unaffected, so re-running
## this on every open is idempotent and adapts to text edits.
func _fit_info_page(panel) -> void:
	var rect := _text_content_rect(panel)
	if !rect.has_area() or camera == null:
		return

	var view: Vector2 = camera.get_viewport_rect().size
	if view.x <= 0.0 or view.y <= 0.0:
		return

	var fit := minf(view.x / rect.size.x, view.y / rect.size.y) * 0.95
	panel.scale = Vector2.ONE * clampf(fit, 0.05, 4.0)


## Bounding box of a panel's visible content in the panel's local space.
## RichTextLabel's reported line metrics do not match what it draws for these
## oversized scaled-down controls (verified against screenshots), but the
## label control rects bound the rendered text exactly, and they are static —
## no layout timing to race with.
func _text_content_rect(panel) -> Rect2:
	var rect := Rect2()
	var found := false
	for child in panel.get_children():
		if child is not Control or not child.visible:
			continue

		var child_rect := Rect2(child.position, child.size * child.scale)
		rect = child_rect if !found else rect.merge(child_rect)
		found = true

	return rect
