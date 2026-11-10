# Info:
# "Caret" refers to the "cursor" of where text is being inserted/deleted in the CodeEdit node.
# Zoom model: the camera sits on the caret and magnifies it; the zoom level is
# picked so the longest line of the file *could* span one screenful of width.
# CodeEdit's font size is 16px, so on-screen char height is 16 * zoom px:
# zoom 10 = the deep "griddy" mode, zoom 1 = native editor scale (which reads
# like ants for this aesthetic). The code half of the camera therefore never
# zooms out below code_min_zoom (scaled by the zoom_intensity settings
# slider), so even 1000+ line files stay readable.
class_name Camera
extends Camera2D

# The glide maths lives in a dependency-free module so the headless tests can
# check it without booting the editor scene.
const Scroll = preload("res://src/editor/scroll_math.gd")

@export var transition_speed: float = 1.0

## How quickly the zoom approaches its target. One exponential-smoothing pass
## per frame replaces the tween that used to be created and killed 60 times a
## second.
const ZOOM_RESPONSE := 7.0

# The document currently on screen. Every tab owns its own EditorView, so the
# camera follows whichever view EditorHost made active.
var _view = null

var max_zoom = Vector2(10.0, 10.0);
var min_zoom = Vector2(1.0, 1.0);

# "Smooth Scrolling": glide towards the caret instead of jumping to it. The
# camera IS the scroll in this editor — the CodeEdit never scrolls internally
# (it grows to fit its content), so the caret glide is the only scrolling the
# user ever sees.
var smooth_scrolling: bool = Scroll.DEFAULT_SMOOTH_SCROLLING

# "Scrolling Speed": how fast the view travels through the file while it
# glides, in the CodeEdit's own pixels per second. Every glide also takes a
# minimum amount of time, so a one-line correction still reads as a movement.
var scroll_speed: float = Scroll.DEFAULT_SCROLL_SPEED

# State of the glide towards the caret.
var _gliding: bool = false
var _glide_from: Vector2 = Vector2.ZERO
var _glide_target: Vector2 = Vector2.ZERO
var _glide_elapsed: float = 0.0
var _glide_duration: float = 0.0

# Floor for zooming out over the CODE. The old linear formula clamped at
# min_zoom (1.0 = 16px chars on screen) as soon as the longest line reached
# ~63 chars, and real files always have such lines => big files were
# permanently in "ant mode". 3.0 keeps chars at ~48px tall no matter how much
# code there is. (Dialogs/overlays still clamp against min_zoom so their
# native scale is untouched.)
@export_range(1.0, 10.0) var code_min_zoom: float = 3.0

# How hard the camera zooms onto the code — wired to the "Zoom: Intensity"
# settings slider (LuaSingleton). 1.0 = the fitted behavior, > 1 zooms in
# more, < 1 backs off. It scales both the fit and the readability floor
# below, otherwise the slider would be a no-op on big files that always sit
# on that floor.
var zoom_intensity: float = 1.0

# Screen pixels covered by the left dock (file explorer / search). The camera
# nudges the code by half of it so the visible code area is centred in the
# space that remains, and the zoom fit uses the reduced width.
var left_inset: float = 0.0

## Shell framing insets in screen pixels: (left, top, right, bottom). While a
## shell owns the screen these replace `left_inset`; the reserved editor
## rectangle is centred and the width fit uses only the safe area. The renderer
## is still not clipped — panels overlay the world, which is the documented
## HUD-framing limitation.
var content_insets: Vector4 = Vector4.ZERO
var content_insets_active: bool = false

## Minimum number of code lines a shell keeps inside the safe rectangle. Without
## it, deep zoom inside a narrow framed column could leave one line filling the
## whole column. Applied as a zoom ceiling only while a shell is active.
const SAFE_MIN_LINES := 3.0

# Ignore mouse movement? \/
var busy = false;
var boundaries_exceeded = null;

var shake_strength: float = 15.0;

var d := 0.0;
var radius := 4.0
var speed := 2.0

# get_longest_line() splits the whole text; on big files that is too costly to
# run every frame, so the length is recomputed on this interval instead. The
# 1s zoom tween easily masks this staleness.
const RECOMPUTE_INTERVAL = 0.25
var longest_refresh := 0.0
var cached_chars := -1

# One tween at a time. The old code built a fresh create_tween() every frame
# while older ones were still alive, so several tweens wrote zoom and
# global_position each frame — together with the unclamped focus_on()/to_zoom()
# path, that is where the rare "zoomed out way too far" glitches came from.
var camera_tween: Tween

## Accessibility modes. Static mode removes the wobble and the glide; reduced
## motion also stops the music pulse and decorative effects elsewhere.
var static_mode: bool = false
var reduced_motion: bool = false

func _ready() -> void:
	_refresh_view()
	_apply_scroll_settings()


## Reads the persisted "Smooth Scrolling" / "Scrolling Speed" values. The
## settings are pushed live too (LuaSingleton.handle_internal_setting_change),
## this is what makes the camera correct on a cold start.
func _apply_scroll_settings() -> void:
	var smooth: Array = LuaSingleton.get_setting("smooth_scrolling")
	if smooth.size() >= 2 && smooth[1] != -1:
		var entry: Dictionary = smooth[0]
		smooth_scrolling = bool(entry.get("value", Scroll.DEFAULT_SMOOTH_SCROLLING))

	var speed: Array = LuaSingleton.get_setting("scroll_speed")
	if speed.size() >= 2 && speed[1] != -1:
		var entry: Dictionary = speed[0]
		scroll_speed = float(entry.get("value", Scroll.DEFAULT_SCROLL_SPEED))


## Resolves the active EditorView. The autoload caches its scene nodes
## lazily, so ask it to look once per frame until the editor scene exists.
func _active_view():
	if LuaSingleton.editor == null:
		LuaSingleton._nodes()

	if LuaSingleton.editor == null:
		return null

	return LuaSingleton.editor.active_view


## Swaps the camera target when a tab is activated and invalidates the cached
## longest-line measurement (it belongs to the previous file).
func _refresh_view():
	var view = _active_view()
	if view == _view:
		return _view

	_view = view
	cached_chars = -1
	longest_refresh = 0.0

	if _view != null and is_instance_valid(_view):
		limit_right = _view.size.x

	return _view


func get_font_metrics() -> Vector2:
	if _view == null or !is_instance_valid(_view):
		return Vector2.ZERO

	# Measure the font actually used to paint the code (the CodeEdit's resolved
	# theme font), not the viewport default — a theme with a non-default editor
	# font would otherwise misjudge every zoom fit. Fall back to the default.
	var font: Font = _view.get_theme_font("font")
	if font == null:
		font = _view.get_theme_default_font()
	if font == null:
		return Vector2.ZERO

	# ask the theme resource directly; fall back to the engine default size if
	# that yields nothing either — an unmeasured font must not return 0, it
	# would divide later computations by zero
	var font_size: int = -1
	if _view.theme != null:
		font_size = _view.theme.get_font_size("font", "CodeEdit")
	if font_size <= 0:
		font_size = _view.get_theme_default_font_size()
	# NOTE: imo this is a good approximation of the average character size for a non
	# monospaced font.
	return font.get_char_size(0x30, font_size)


# The zoom the editor should sit at: one screen of width fits the longest line.
# It is a scale, not a viewport fit — the camera follows the caret, so the
# span only defines how large the characters look.
func target_zoom() -> Vector2:
	if cached_chars <= 0:
		# no content: max out on the deep-zoom state
		return max_zoom

	var char_size: Vector2 = get_font_metrics()
	if char_size.x <= 0.0:
		# font could not be measured: park on the readability floor
		return Vector2(code_min_zoom, code_min_zoom)

	# "+1" keeps a one-character margin, same idea as the old (chars+1)/7 rule
	var effective_left := content_insets.x if content_insets_active else left_inset
	var effective_right := content_insets.z if content_insets_active else 0.0
	var usable_width: float = maxf(1.0, get_viewport_rect().size.x - effective_left - effective_right)
	var fitting: float = usable_width / ((cached_chars + 1) * char_size.x)
	fitting *= zoom_intensity

	# the floor scales along with the intensity, but never below the absolute
	# min_zoom, so tiny intensities can't push the camera past native scale
	# (ant mode!)
	var code_floor: float = maxf(min_zoom.x, code_min_zoom * zoom_intensity)

	var ceiling: Vector2 = max_zoom
	if content_insets_active:
		ceiling = _shell_zoom_ceiling(char_size)
		if ceiling.x < code_floor:
			ceiling = Vector2(code_floor, code_floor)

	return clamp(Vector2(fitting, fitting), Vector2(code_floor, code_floor), ceiling)


func _process(delta: float) -> void:
	d += delta

	# Camera wobble is decoration. Accessibility modes switch it off instead of
	# merely damping it, so the code never drifts under the caret.
	if static_mode or reduced_motion:
		offset = Vector2.ZERO
	else:
		offset = Vector2(
			sin(d * speed) * radius,
			cos(d * speed) * radius
		)

	var view = _refresh_view()
	if view == null or !is_instance_valid(view):
		return

	# A freshly created view can report size.x == 0 before its first layout;
	# re-apply the clamp every frame until it catches up instead of parking
	# limit_right at 0 for the view's whole life.
	if view.size.x > 0.0 and limit_right != view.size.x:
		limit_right = view.size.x

	longest_refresh -= delta
	if longest_refresh <= 0.0:
		cached_chars = _longest_line_length(view)
		longest_refresh = RECOMPUTE_INTERVAL

	if busy: return

	var final_zoom = target_zoom()
	var char_size: Vector2 = get_font_metrics()
	var gp = view.get_caret_draw_pos()

	gp.x -= 2*char_size.x

	# Centre the code in the safe rectangle. Moving the camera opposite to the
	# inset difference moves the world (and the caret) towards that rectangle's
	# centre. A left dock is the same maths with a zero right inset.
	if content_insets_active:
		gp.x += (content_insets.z - content_insets.x) * 0.5 / maxf(final_zoom.x, 0.001)
		gp.y += (content_insets.w - content_insets.y) * 0.5 / maxf(final_zoom.y, 0.001)
	elif left_inset > 0.0:
		gp.x -= left_inset * 0.5 / maxf(final_zoom.x, 0.001)

	# One manual smoothing pass instead of a tween created every frame. The
	# old tween was killed and rebuilt every frame, so it only ever applied the
	# first sliver of its curve.
	if static_mode or reduced_motion:
		zoom = final_zoom
	else:
		zoom = zoom.lerp(final_zoom, clampf(delta * ZOOM_RESPONSE, 0.0, 1.0))

	if smooth_scrolling and !static_mode and !reduced_motion:
		_glide_to(gp, delta)
	else:
		# No glide: the view sits exactly where the caret is, right now.
		global_position = gp
		_gliding = false


## The cached longest-line length. EditorView recomputes it only when the text
## changed, so the camera no longer splits the whole buffer every 0.25 s.
func _longest_line_length(view) -> int:
	if view.has_method("get_longest_line_length"):
		return int(view.get_longest_line_length())
	return view.get_longest_line().length()


## Applies shell framing. `values` holds left/top/right/bottom in screen pixels;
## an empty or zero dictionary still activates framing so the left dock inset is
## suppressed while a shell owns the screen.
func set_content_insets(values: Dictionary) -> void:
	content_insets = Vector4(
		maxf(0.0, float(values.get("left", 0.0))),
		maxf(0.0, float(values.get("top", 0.0))),
		maxf(0.0, float(values.get("right", 0.0))),
		maxf(0.0, float(values.get("bottom", 0.0))),
	)
	content_insets_active = true


func clear_content_insets() -> void:
	content_insets = Vector4.ZERO
	content_insets_active = false


func insets_dict() -> Dictionary:
	return {
		"left": content_insets.x,
		"top": content_insets.y,
		"right": content_insets.z,
		"bottom": content_insets.w,
		"active": content_insets_active,
	}


## Keeps at least SAFE_MIN_LINES inside the vertical safe area, so a shell's
## coach panel cannot squeeze the code into a single line at deep zoom.
func _shell_zoom_ceiling(char_size: Vector2) -> Vector2:
	var safe_height := maxf(1.0, get_viewport_rect().size.y - content_insets.y - content_insets.w)
	var line_height := maxf(1.0, char_size.y)
	var ceiling := safe_height / (line_height * SAFE_MIN_LINES)
	return Vector2(
		minf(max_zoom.x, ceiling),
		minf(max_zoom.y, ceiling),
	)


## Switches the camera between its animated and static behaviours.
func set_motion_mode(static_value: bool, reduced_value: bool) -> void:
	static_mode = static_value
	reduced_motion = reduced_value
	if static_mode or reduced_motion:
		offset = Vector2.ZERO
		_gliding = false


## Moves the camera towards the target over a fixed stretch of time, slowing
## into the target so it settles instead of stopping dead.
##
## Done by hand rather than with a tween on purpose: the tween towards the
## caret used to be killed and recreated every frame, so it never got past
## the first sliver of its own easing curve and the perceived speed drifted
## with the distance instead of being what the setting says.
func _glide_to(target: Vector2, delta: float) -> void:
	# A new target (the caret moved) restarts the glide from where the view
	# is now, so the motion is never a jump.
	if !_gliding || target != _glide_target:
		_gliding = true
		_glide_from = global_position
		_glide_target = target
		_glide_elapsed = 0.0
		_glide_duration = Scroll.glide_duration(global_position.distance_to(target), scroll_speed)

	_glide_elapsed += delta
	var t := clampf(_glide_elapsed / maxf(_glide_duration, 0.001), 0.0, 1.0)
	global_position = _glide_from.lerp(_glide_target, Scroll.glide_progress(t))

	if t >= 1.0:
		_gliding = false

func focus_on(pos: Vector2, _zoom: Vector2) -> void:
	busy = true;
	# clamp: focus targets come from dialogs (to_zoom) or other nodes, and used
	# to pass straight through — a dir listing with a long name could return a
	# zoom below 1.0, zero, or even negative (mirrored view)
	var bounded_zoom: Vector2 = _zoom.clamp(min_zoom, max_zoom)

	if camera_tween: camera_tween.kill()

	# Reduced motion turns every camera move into a cut, never a pan. Reset the
	# busy flag here too: no tween is created on this path, so _process would
	# otherwise stay disabled until a close panel happened to call focus_die().
	if static_mode or reduced_motion:
		global_position = pos
		zoom = bounded_zoom
		busy = false
		return

	camera_tween = create_tween()
	camera_tween.set_parallel(true)
	camera_tween.tween_property(self, "global_position", pos, transition_speed)
	camera_tween.tween_property(self, "zoom", bounded_zoom, transition_speed)

func focus_die() -> void:
	# un-busy is the whole job: `_process` tweens back to the caret by itself.
	# The old tween here ran next to the per-frame one and they fought over
	# global_position every frame.
	busy = false

func focus_temp(intensity: float) -> void:
	if busy or static_mode or reduced_motion: return

	# Apply the pulse straight onto the current zoom; the per-frame tween then
	# eases it back to the target, giving exactly one beat-shaped punch per
	# music tick. Music is always positive so beats only zoom IN, but allow a
	# little overshoot past max_zoom so they stay visible during deep zoom.
	var headroom: float = 2.0
	zoom = Vector2(
		clampf(zoom.x + intensity, min_zoom.x, max_zoom.x + headroom),
		clampf(zoom.y + intensity, min_zoom.y, max_zoom.y + headroom)
	)

func shake_camera(_shake_strength):
	if static_mode or reduced_motion:
		return Vector2.ZERO
	return Vector2(randf_range(-_shake_strength, _shake_strength), randf_range(-_shake_strength, _shake_strength))

func to_zoom(num: float) -> Vector2:
	# zoom out faster for long entries, but continuously: adding a flat 120
	# once "num > 40" made the zoom jump from 3.6 to 2.39 between lengths 40
	# and 41. A slope picks the same +120 for length 100, and no longer goes
	# negative for very long names since the result is clamped below.
	if num > 40:
		num += (num - 40) * 2

	num /= 100 # 44 -> 0.44

	num = 4 - num;

	# a dir listing with a very long name used to land at zoom <= 0 (degenerate
	# view); clamp to the same bounds every other camera move uses
	num = clampf(num, min_zoom.x, max_zoom.x)

	return Vector2(num, num)
