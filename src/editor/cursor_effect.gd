class_name CursorEffect
extends ColorRect

## The cursor trail: a smear that follows the text cursor.
##
## The effect lives in the world, right above the code, so it scales with the
## camera exactly like the caret it belongs to. The trail itself is a shader
## (resources/shaders/cursor_trail.gdshader); this node only feeds it the two caret
## rectangles and the time since the caret moved.
##
## The live caret is never painted over: the shader keeps a hole for it, so
## the cursor stays crisp while the smear passes behind it.
##
## The maths that decide where the trail goes lives in
## src/editor/cursor_effect_math.gd, where the headless tests can reach it.

const SHADER = preload("res://resources/shaders/cursor_trail.gdshader")
const MATH = preload("res://src/editor/cursor_effect_math.gd")

const SETTING_EFFECT := "cursor_effect"
const SETTING_DURATION := "cursor_effect_duration"
const SETTING_OPACITY := "cursor_effect_opacity"

## The longest a trail may be, as a fraction of the visible world height.
const MAX_TRAIL_LENGTH_RATIO := 0.2

var editor = null

var _material: ShaderMaterial
var _view = null
var _current: Rect2 = Rect2()
var _previous: Rect2 = Rect2()
var _elapsed: float = 0.0
var _duration: float = MATH.DEFAULT_DURATION
var _effect: int = MATH.EFFECT_WARP
var _opacity: float = float(MATH.DEFAULT_OPACITY) / 100.0
var _running: bool = false
# Where the caret was the last time it was measured. Measuring a cell costs
# a walk over the line, so it only happens when the caret really moved.
var _caret_line: int = -1
var _caret_column: int = -1
var _font_size: int = -1
var _resync: bool = false
var _motion_disabled: bool = false
var _pulse_elapsed: float = 1.0
var _pulse_duration: float = 0.22


func _ready() -> void:
	editor = _find_editor()

	# The trail is decoration: it must never eat a click meant for the code.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false

	_material = ShaderMaterial.new()
	_material.shader = SHADER
	material = _material

	_apply_settings()
	_update_material()

	LuaSingleton.on_theme_load.connect(_on_theme_load)


func _process(delta: float) -> void:
	if _motion_disabled || _effect == MATH.EFFECT_OFF:
		_stop()
		return

	var view := _active_view()
	if view == null || !is_instance_valid(view):
		_stop()
		return

	if view != _view:
		_set_view(view)

	# A new font size moves the caret without moving it: the old rectangle
	# belongs to a world that no longer exists, so it is dropped.
	var font_size: int = view.get_theme_font_size("font_size")
	if font_size != _font_size:
		_font_size = font_size
		_resync = true

	var line: int = view.get_caret_line()
	var column: int = view.get_caret_column()
	if _resync || line != _caret_line || column != _caret_column:
		_caret_line = line
		_caret_column = column
		if _resync:
			_resync = false
			_current = Rect2()
		_move_caret(view)

	if !_running:
		_update_pulse(delta)
		return

	_elapsed += delta
	if _elapsed >= _duration:
		_stop()
		return

	_update_quad()
	_update_pulse(delta)


## The caret moved: the trail starts where it was and ends where it is.
func _move_caret(view: CodeEdit) -> void:
	var caret := _caret_rect(view)
	if caret.size.x <= 0.0 || caret.size.y <= 0.0:
		return

	# The first sighting only learns where the caret is: there is no trail to
	# draw from a position the editor never was in.
	if _current.size.x <= 0.0:
		_current = caret
		_previous = caret
		_running = false
		_elapsed = 0.0
		return

	_previous = _current
	_current = caret
	_elapsed = 0.0
	_running = MATH.should_animate(_previous, _current, MATH.DEFAULT_MOVE_THRESHOLD)
	_material.set_shader_parameter("trail_color", _trail_color_for_view(view))
	_material.set_shader_parameter("glow_strength", 0.85)


## The rectangle the caret occupies, in world pixels.
##
## The CodeEdit lives inside the zoomed world, so its own coordinates have to
## be lifted into the world before the trail can be placed there.
func _caret_rect(view: CodeEdit) -> Rect2:
	var caret_pos: Vector2 = view.get_caret_draw_pos()
	var cell: Rect2 = view.get_rect_at_line_column(view.get_caret_line(), view.get_caret_column())
	if cell.size.y <= 0.0:
		# The editor has no cell for this position (the end of the file, for
		# instance): the caret's own position is the next best thing.
		cell = Rect2(caret_pos, Vector2(_char_width(view), float(view.get_line_height())))
	if cell.size.x <= 0.0:
		# At the end of a line the cell can come back without a width.
		cell.size.x = _char_width(view)
	if cell.size.x <= 0.0 || cell.size.y <= 0.0:
		return Rect2()

	# get_rect_at_line_column() describes the cell that ends at the caret, so
	# its x is one character behind it. The caret's own draw position is the
	# authoritative x; the cell only supplies the line's top, height and the
	# width of a block caret. Without this the trail trails the *previous*
	# column and reads as a second cursor next to the real one.
	cell.position.x = caret_pos.x

	var shape: Rect2 = MATH.caret_shape(cell, view.caret_type, _caret_width(view), _underline_height(view))
	var xform: Transform2D = view.get_global_transform()
	return Rect2(xform * shape.position, xform.basis_xform(shape.size))


## Places the quad over both carets and hands the shader what it needs.
func _update_quad() -> void:
	var edge: float = MATH.edge_size(_current.size.y)
	var bounds: Rect2 = MATH.trail_bounds(_previous, _current, edge * 2.0 + 2.0)
	if bounds.size.x <= 0.0 || bounds.size.y <= 0.0:
		return

	position = bounds.position
	size = bounds.size

	_material.set_shader_parameter("current_cursor", _local_rect(_current, bounds.position))
	_material.set_shader_parameter("previous_cursor", _local_rect(_previous, bounds.position))
	_material.set_shader_parameter("elapsed", _elapsed)
	_material.set_shader_parameter("antialias_size", edge)
	_material.set_shader_parameter("max_trail_length", _max_trail_length())

	visible = true


## The parts of the shader that only change when a setting does.
func _update_material() -> void:
	if _material == null:
		return

	_material.set_shader_parameter("effect", _effect)
	_material.set_shader_parameter("duration", _duration)
	_material.set_shader_parameter("trail_color", _trail_color())
	_material.set_shader_parameter("glow_strength", 0.0)


func _stop() -> void:
	_running = false
	if visible:
		visible = false


## Briefly emphasizes a caret jump caused by a diagnostic, search result, or
## navigation action. It is intentionally separate from the movement trail.
func pulse() -> void:
	if _motion_disabled or !UI_MOTION_ALLOWED():
		return
	_pulse_elapsed = 0.0
	_material.set_shader_parameter("glow_strength", 1.0)


func _update_pulse(delta: float) -> void:
	if _pulse_elapsed >= _pulse_duration:
		return
	_pulse_elapsed += delta
	var strength := 1.0 - clampf(_pulse_elapsed / _pulse_duration, 0.0, 1.0)
	_material.set_shader_parameter("glow_strength", strength)


## A new tab has its own caret: the trail must not reach across from the old
## one, so the history starts empty again.
func _set_view(view) -> void:
	_view = view
	_current = Rect2()
	_previous = Rect2()
	_caret_line = -1
	_caret_column = -1
	_resync = false
	_stop()


# ── SETTINGS ──────────────────────────────────────────────────────────────────

## Reduced motion removes the trail even when the trail setting is on. The
## next caret move starts a fresh history instead of crossing the old one.
func set_motion_disabled(value: bool) -> void:
	if _motion_disabled == value:
		return

	_motion_disabled = value
	_stop()
	_current = Rect2()
	_previous = Rect2()
	_resync = true


func apply_setting(property: String, value: Variant) -> void:
	match property:
		SETTING_EFFECT:
			var was_off: bool = _effect == MATH.EFFECT_OFF
			_effect = int(value)
			if !was_off && _effect == MATH.EFFECT_OFF:
				_stop()
			if was_off && _effect != MATH.EFFECT_OFF:
				# The caret is somewhere else than when the effect was off:
				# start over instead of drawing a trail across the file.
				_current = Rect2()
				_previous = Rect2()
				_resync = true
		SETTING_DURATION:
			_duration = clampf(float(value), 0.05, 1.0)
		SETTING_OPACITY:
			_opacity = clampf(float(value) / 100.0, 0.0, 1.0)

	_update_material()


func _apply_settings() -> void:
	var effect_setting: Array = LuaSingleton.get_setting(SETTING_EFFECT)
	if effect_setting.size() >= 2 && effect_setting[1] != -1:
		var entry: Dictionary = effect_setting[0]
		_effect = int(entry.get("value", MATH.EFFECT_WARP))

	var duration_setting: Array = LuaSingleton.get_setting(SETTING_DURATION)
	if duration_setting.size() >= 2 && duration_setting[1] != -1:
		var entry: Dictionary = duration_setting[0]
		_duration = clampf(float(entry.get("value", MATH.DEFAULT_DURATION)), 0.05, 1.0)

	var opacity_setting: Array = LuaSingleton.get_setting(SETTING_OPACITY)
	if opacity_setting.size() >= 2 && opacity_setting[1] != -1:
		var entry: Dictionary = opacity_setting[0]
		_opacity = clampf(float(entry.get("value", MATH.DEFAULT_OPACITY)) / 100.0, 0.0, 1.0)


func _on_theme_load() -> void:
	_update_material()


# ── HELPERS ──────────────────────────────────────────────────────────────────

## The colour of the trail: the caret's own colour, at the configured strength.
func _trail_color() -> Color:
	var color: Color = LuaSingleton.gui.get("caret_color", Color(0.4, 0.8, 1.0))
	color.a = _opacity
	return color


func _trail_color_for_view(view: CodeEdit) -> Color:
	var color := _trail_color()
	if view.caret_type == TextEdit.CARET_TYPE_BLOCK:
		color = LuaSingleton.gui.selection_color
	color.a = _opacity
	return color


func UI_MOTION_ALLOWED() -> bool:
	var lua = _find_lua_singleton()
	if lua == null or !lua.has_method("get_setting"):
		return true
	var settings: Array = lua.get_setting("reduced_motion")
	if settings.size() > 0 and settings[0] is Dictionary and bool(settings[0].get("value", false)):
		return false
	return true


func _find_lua_singleton():
	var tree := Engine.get_main_loop() as SceneTree
	return tree.root.get_node_or_null("LuaSingleton") if tree != null and tree.root != null else null


## How long the tail of the comet may be, in world pixels. It is a fraction of
## the visible world, so the tail keeps its length on screen at every zoom.
func _max_trail_length() -> float:
	var camera = _camera()
	if camera == null:
		return 200.0

	var zoom: float = maxf(0.01, camera.zoom.y)
	return MAX_TRAIL_LENGTH_RATIO * (get_viewport_rect().size.y / zoom)


func _caret_width(view: CodeEdit) -> float:
	if view.has_theme_constant("caret_width"):
		return maxf(1.0, float(view.get_theme_constant("caret_width")))
	return MATH.DEFAULT_CARET_WIDTH


## The width of one character, in the editor's own pixels. It is the width of
## the block caret and the fallback for a cell the editor reports without one.
func _char_width(view: CodeEdit) -> float:
	var font: Font = view.get_theme_font("font")
	if font == null:
		return MATH.DEFAULT_CARET_WIDTH

	var size: int = view.get_theme_font_size("font_size")
	if size <= 0:
		size = view.get_theme_default_font_size()

	var width: float = font.get_string_size("0", HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	return maxf(MATH.DEFAULT_CARET_WIDTH, width)


func _underline_height(view: CodeEdit) -> float:
	if view.has_theme_constant("caret_underline_height"):
		return maxf(1.0, float(view.get_theme_constant("caret_underline_height")))
	return MATH.DEFAULT_UNDERLINE_HEIGHT


## A rectangle relative to the top left of the quad the shader is drawn on.
static func _local_rect(rect: Rect2, origin: Vector2) -> Vector4:
	return Vector4(
		rect.position.x - origin.x,
		rect.position.y - origin.y,
		rect.size.x,
		rect.size.y
	)


func _active_view() -> CodeEdit:
	if editor == null:
		return null
	return editor.active_view as CodeEdit


func _camera():
	if editor == null:
		return null
	return editor.camera


func _find_editor():
	var node := get_parent()
	while node != null && !(node is FileManager):
		node = node.get_parent()
	return node
