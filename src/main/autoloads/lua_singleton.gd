extends Node

const NOTO_COLOR_EMOJI_REGULAR: FontFile = preload("res://resources/fonts/NotoColorEmoji-Regular.ttf")
const NERD_SYMBOLS: FontFile = preload("res://resources/fonts/SymbolsNerdFontMono-Regular.ttf")
const ACCESSIBILITY = preload("res://src/platform/a11y.gd")
const LOCALIZATION_SCRIPT = preload("res://src/platform/localization_service.gd")

var themes: Array = ["One Dark Pro Darker"];
var theme: String = "One Dark Pro Darker"; # default

# TODO: change me each version
var version: String = "v1.4.0";

var gui: Dictionary = {
	"background_color":            str_to_clr("#23272e"),
	"current_line_color":          str_to_clr("#23272e"),
	"selection_color":             str_to_clr("#23272e"),
	"font_color":                  str_to_clr("#23272e"),
	"word_highlighted_color":      str_to_clr("#23272e"),
	"completion_background_color": str_to_clr("#23272e"),
	"completion_selected_color":   str_to_clr("#23272e"),
	"caret_color":                 str_to_clr("#23272e")
}

# #### SETTINGS ####
# The schema and persistence live in src/platform/settings_service.gd. This
# singleton keeps the historical `settings` / get_setting() / change_setting()
# API as a compatibility wrapper, because the UI and Lua themes use it.
var settings_service: SettingsService = null

# Per-extension Lua state + highlighter cache. Keeping it in the singleton
# means every tab of the same language shares one parse instead of rebuilding
# the interpreter on each tab switch.
const LANGUAGE_SERVICE_SCRIPT = preload("res://src/platform/language_service.gd")
var language_service = null

var editor_theme: Theme = load("res://resources/themes/theme.tres");
var fonts = load_available_fonts()

# Only the selected system font is ever instantiated. Keeping a reference here
# means switching fonts releases the previous one instead of accumulating them.
var _active_system_font: SystemFont = null
var _active_system_font_name: String = ""

## Installed at startup; the saved interface language is applied once the
## settings file has been read.
var localization_service = null

## The font that was active before the dyslexia option was turned on, so the
## option is reversible without asking the user to pick their font again.
var _dyslexia_previous_font: String = ""

## Theme palette captured before the high-contrast override, so turning the
## option off restores the exact colours of the active theme.
var _pre_contrast_gui: Dictionary = {}
var _pre_contrast_keywords: Dictionary = {}


func load_available_fonts() -> Array:
	var built_ins = load_built_in_fonts()
	var system = load_system_fonts()
	built_ins.append_array(system)
	return built_ins


func load_built_in_fonts() -> Array:
	return Array(editor_theme.get_font_list("MyType")).map(load_built_in_font)


func load_built_in_font(_name: String) -> Dictionary:
	var font = editor_theme.get_font(_name, "MyType");

	# `value` is the stable ID persisted in settings.json: the font's display
	# name, not the theme's internal slot name ("font") and never a list index.
	return { "display": font.get_font_name(), "value": font.get_font_name(), "name": _name, "system": false }


## Describes a system font by name only. The SystemFont itself is created in
## resolve_font() when the font is actually selected, so startup never loads
## every installed font just to fill the dropdown.
func load_system_font(font_name: String) -> Dictionary:
	return { "display": font_name, "value": font_name, "name": font_name, "system": true }


func load_system_fonts() -> Array:
	return Array(OS.get_system_fonts()).map(load_system_font)


## Resolves a fonts[] entry to a Font, lazily creating (and caching) the
## SystemFont for the selected entry.
func resolve_font(entry: Dictionary) -> Font:
	if !entry.get("system", false):
		_active_system_font = null
		_active_system_font_name = ""

		return editor_theme.get_font(entry.name, "MyType")

	if _active_system_font != null and _active_system_font_name == entry.name:
		return _active_system_font

	var font: SystemFont = SystemFont.new()
	font.multichannel_signed_distance_field = true
	font.font_names = [entry.name]

	_active_system_font = font
	_active_system_font_name = entry.name

	return font


## Attaches the fallbacks every UI font needs: the bundled Nerd Font for the
## private-use icon glyphs (file picker, settings rows) and Noto for emoji.
## Godot's automatic system fallback does not resolve those icon glyphs on
## Windows, so an OS-installed Nerd Font alone is not enough.
func apply_icon_fallbacks(font: Font) -> void:
	if font == null: return

	font.set_fallbacks([NERD_SYMBOLS, NOTO_COLOR_EMOJI_REGULAR])


## Covers fonts that never go through the "editor_font" setting: the built-in
## theme font and the engine default used on a fresh profile (no save file).
## The theme's Fira Code font gets the same fallbacks here.
func setup_font_fallbacks() -> void:
	var theme_font := editor_theme.get_font("font", "MyType")
	apply_icon_fallbacks(theme_font)

	# Tree rows (file explorer, search results) do not use MyType. Without an
	# explicit Tree font they fall back to the engine's default font, which has
	# no Nerd Font glyphs, so every file/folder icon renders as a box.
	if theme_font != null:
		editor_theme.set_font("font", "Tree", theme_font)

	var default_font := ThemeDB.fallback_font
	if default_font != null:
		var wrapped := FontVariation.new()
		wrapped.base_font = default_font
		wrapped.set_fallbacks([NERD_SYMBOLS, NOTO_COLOR_EMOJI_REGULAR])
		ThemeDB.fallback_font = wrapped


var settings: Array:
	get:
		return settings_service.compat_entries() if settings_service != null else []

var keywords: Dictionary = {
	"reserved":   str_to_clr("c678cc"),
	"annotation": str_to_clr("a2b429"),
	"string":     str_to_clr("98c379"),
	"binary":     str_to_clr("d19a66"),
	"symbol":     str_to_clr("839fb6"),
	"variable":   str_to_clr("e5c07b"),
	"operator":   str_to_clr("56b6c2"),
	"comments":   str_to_clr("7f848e"),
	"error":      str_to_clr("d31820"),
	"function":   str_to_clr("437ed9"),
	"member":     str_to_clr("e06c75")
}

## Pristine palette. A theme file only sets the keys it names; without these
## snapshots the keys a theme omits kept the previous theme's colours.
var _base_gui: Dictionary = gui.duplicate(true)
var _base_keywords: Dictionary = keywords.duplicate(true)

## Comments registered by the active language file. Kept as a compatibility
## alias for the comments overlay; the real per-language data lives in
## LanguageService.
var comments: Array = []

## Rich Presence is opt-in: presence broadcasts what you are editing.
var discord_sdk: bool = false;

const SUNLIGHT = preload("res://resources/shaders/sunlight.gdshader")
const VHS_AND_CRT = preload("res://resources/shaders/vhs_and_crt.gdshader")

# Autoload _ready runs before the main scene exists, so these can't stay
# @onready — they're resolved lazily through _nodes() on first use.
var editor: FileManager
var world_environment: WorldEnvironment
var shader_layer: ColorRect
var bloom_layer: ColorRect
var camera: Camera

## Resolves (once) the editor scene's nodes. Every entry point touching the
## scene calls this first; returns false while the scene isn't ready yet.
func _nodes() -> bool:
	if editor == null:
		var root_node = get_tree().root.get_node_or_null("Editor")
		if root_node == null:
			return false

		editor = root_node
		world_environment = root_node.get_node_or_null("WorldEnvironment")
		shader_layer = root_node.get_node_or_null("ShaderLayer")
		bloom_layer = root_node.get_node_or_null("BloomLayer")
		camera = root_node.get_node_or_null("Misc/Cam")

	return true





signal done_parsing;
signal on_theme_load;
signal on_settings_change;

## Set once a theme load has been attempted (success or failure). Panels that
## are built before the first load await the on_theme_load signal instead; this
## flag lets late-created or failure-path panels skip the wait entirely.
var theme_load_attempted := false;



func _ready() -> void:
	settings_service = SettingsService.new()
	settings_service.name = "SettingsService"
	add_child(settings_service)

	# The font dropdown is theme-owned data, so it is pushed into the generic
	# schema here instead of making SettingsService depend on the theme.
	settings_service.set_options("editor_font", fonts)
	settings_service.set_default("editor_font", default_font_id())

	# Translations are installed before the settings are read so the saved
	# locale is applied to the very first panel that is built.
	localization_service = LOCALIZATION_SCRIPT.new()
	localization_service.name = "LocalizationService"
	add_child(localization_service)
	localization_service.install()
	settings_service.set_options("ui_language", localization_service.language_options())
	settings_service.set_default("ui_language", "en")

	settings_service.load_settings()
	localization_service.set_locale(str(settings_service.get_value("ui_language", "en")))
	settings_service.changed.connect(_on_setting_changed)

	language_service = LANGUAGE_SERVICE_SCRIPT.new()
	language_service.name = "LanguageService"
	add_child(language_service)

	setup_font_fallbacks()

	# glow & shader brightness depend on the theme: re-evaluate on every load.
	# (the engine glow itself is switched off inside apply_glow once nodes
	# exist — it's replaced by our bloom shader)
	on_theme_load.connect(func() -> void:
		if !_nodes(): return

		_refresh_effects()

		if shader_layer.material.shader == VHS_AND_CRT:
			tune_vhs_brightness()
	)


## Applies a changed value but does NOT rebuild the settings list on every
## slider tick. Callers that alter a control (shader checkboxes, palette
## toggles) emit on_settings_change themselves when the UI needs a refresh.
func _on_setting_changed(property: String, value: Variant) -> void:
	handle_internal_setting_change(property, value)


## Recomputes the glow/bloom pass. While a fullscreen shader (sunlight, VHS &
## CRT) is active the bloom pass is suspended entirely — the shader's amplified
## output would just bloom into a white haze on top of itself.
func _refresh_effects() -> void:
	if !_nodes(): return

	if shader_layer.material != null and shader_layer.material.shader != null:
		apply_glow(false)
	else:
		apply_glow()




func get_setting(property: String) -> Array:
	if settings_service == null:
		return [{}, -1]

	var entry := settings_service.compat_entry(property)
	if entry.is_empty():
		return [{}, -1]

	return [entry, settings_service.index_of(property)]


## Ordered category descriptors used to group the Ctrl+, panel.
func settings_categories() -> Array:
	if settings_service == null:
		return []
	return settings_service.categories()

func change_setting(property: String, value: Variant) -> void:
	if settings_service == null:
		return

	# SettingsService emits `changed`, which applies the value through
	# handle_internal_setting_change().
	settings_service.set_setting(property, value)


## One Ctrl+= / Ctrl+- step on the Zoom: Intensity setting. Fixed multiplicative
## steps (~x1.15 per press), snapped to the slider's 0.01 grid so a zoom-out
## right after a zoom-in lands back on exactly the value you came from. The old
## sync multiplied the intensity by the font-size ratio instead: the camera's
## fit formula divides by the char width, which grows by the same ratio, so the
## two effects cancelled out in the fit regime (screen never moved while the
## slider value drifted), and it dead-ended whenever either value clamped.
const ZOOM_STEP := 1.15

func change_zoom_intensity_by(direction: int) -> void:
	var current := float(get_setting("zoom_intensity")[0].get("value", 1.0))

	var next := current * ZOOM_STEP if direction > 0 else current / ZOOM_STEP
	next = clampf(snappedf(next, 0.01), 0.1, 3.0)

	if next == current:
		return

	change_setting("zoom_intensity", next)

func toggle_shader(shader: Shader, value: bool) -> void:
	if !_nodes(): return

	if value and (_setting_bool("reduced_motion", false) or _setting_bool("high_contrast", false)):
		# The setting stays on; the effect simply stays off while the
		# accessibility mode forbids it. Turning the mode off restores it.
		shader_layer.hide()
		return

	if value:
		# shaders are full-screen overlays, so they can't stack: enabling one
		# turns the other off.
		var other = "vhs" if shader == SUNLIGHT else "sunlight";
		var other_setting = get_setting(other);

		if other_setting[1] != -1 and settings[other_setting[1]]["value"]:
			set_setting_value(other, false)
			on_settings_change.emit() # refresh the checkboxes in the settings menu

		shader_layer.show()
		shader_layer.material.shader = shader

		if shader == VHS_AND_CRT:
			tune_vhs_brightness()

		# full-screen shaders replace the atmosphere — suspend the bloom pass
		# so its halo doesn't stack onto the shader's amplified output.
		_refresh_effects()
	else:
		shader_layer.material.shader = null
		shader_layer.hide()

		_refresh_effects()


## Approximate perceptual brightness of the theme background (0 black → 1 white).
func background_luminance() -> float:
	var c: Color = gui["background_color"];
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b


## Writes a value into the settings store WITHOUT applying it.
func set_setting_value(property: String, value: Variant) -> void:
	if settings_service == null:
		return

	settings_service.set_value(property, value)


## Stable ID persisted for the selected editor font (display name).
func default_font_id() -> String:
	if fonts.is_empty():
		return ""

	return str(fonts[0].get("display", fonts[0].get("value", "")))


## Finds a fonts[] entry by the stable ID (display name), accepting older
## saved shapes ("font" slot name, or a system font's family name).
func find_font(font_id: String) -> Dictionary:
	for entry in fonts:
		if str(entry.get("display", "")) == font_id:
			return entry
		if str(entry.get("value", "")) == font_id:
			return entry
		if str(entry.get("name", "")) == font_id:
			return entry

	return {}


## Applies every persisted value once the editor scene exists. Called from
## FileManager._ready after the legacy save (if any) has been imported.
func apply_all_settings() -> void:
	if settings_service == null:
		return

	for entry in settings_service.compat_entries():
		handle_internal_setting_change(str(entry.get("property", "")), entry.get("value"))

	on_settings_change.emit()


## Imports the settings block of an old user://data.save. No-op after
## settings.json has been loaded/persisted.
func apply_legacy_settings(entries: Variant) -> Dictionary:
	if settings_service == null:
		return {"ok": false, "imported": 0, "skipped": true, "error": "Settings service unavailable."}

	return settings_service.import_legacy(entries)


func get_settings_for_save() -> Dictionary:
	if settings_service == null:
		return {}

	return settings_service.values()


func save_settings() -> Dictionary:
	if settings_service == null:
		return {"ok": false, "error": "Settings service unavailable.", "path": ""}

	return settings_service.save()


## Applies the "glow" setting. This now drives the dedicated bloom shader
## (resources/shaders/bloom.gdshader, BloomLayer) instead of Godot's environment glow:
## the built-in glow applies to every pixel above an HDR threshold of 0.0,
## which washes light themes into white. The bloom threshold sits ~0.15 above
## the theme background instead — low enough that pastel / mid-bright text
## colors bloom into a full neon halo — while light themes still get nothing.
func apply_glow(value: Variant = null) -> void:
	if !_nodes(): return

	var enabled = bool(value) if value != null else bool(get_setting("glow")[0].get("value", true))

	# Accessibility switch: bloom destroys high contrast, and reduced-motion
	# mode keeps the screen completely static.
	enabled = enabled and !_setting_bool("high_contrast", false) and !_setting_bool("reduced_motion", false)

	# The WorldEnvironment was removed when the project moved to the
	# Compatibility renderer; glow is a canvas shader now.
	if world_environment != null and world_environment.environment != null:
		world_environment.environment.glow_enabled = false

	if bloom_layer == null or bloom_layer.material == null: return

	var intensity = float(get_setting("glow_intensity")[0].get("value", 2.0))
	bloom_layer.visible = enabled and intensity > 0.0

	if bloom_layer.visible:
		var threshold = clampf(background_luminance() + 0.15, 0.32, 1.3)
		bloom_layer.material.set_shader_parameter("threshold", threshold)
		bloom_layer.material.set_shader_parameter("intensity", intensity)


## VHS & CRT multiplies the screen by `brightness` (default 6) to offset how dark
## the effect is; on bright backgrounds that's a one-way trip to white-screen
## city, so scale it down: never amplify past 0.9 luminance, cap at 6.
func tune_vhs_brightness() -> void:
	if !_nodes(): return

	var bg = maxf(background_luminance(), 0.01);
	shader_layer.material.set_shader_parameter("brightness", minf(6.0, 0.9 / bg))



func handle_internal_setting_change(property: String, value: Variant) -> void:
	# values are always stored; applying them just needs the scene to exist
	if !_nodes(): return

	# oh my god he's about to do it
	var p = property;

	# Every editor property is applied to every open view. New views read the
	# persisted value themselves in EditorView.apply_settings().
	if p in [
		"caret_type", "caret_blink", "caret_interval", "draw_line_numbers",
		"code_completion", "indentation_size", "indentation_automatic",
		"indentation_use_spaces", "auto_brace_completion",
		"auto_brace_highlight_matching", "git_gutter",
	]:
		if editor.editor_host != null:
			editor.editor_host.apply_setting(p, value)
	# The cursor trail has its own node: it is drawn over the code, not by
	# the views themselves.
	if p in ["cursor_effect", "cursor_effect_duration", "cursor_effect_opacity"]:
		if editor.cursor_effect != null:
			editor.cursor_effect.apply_setting(p, value)
	if p == "editor_font":
		# The persisted value is the font's stable display name. Unknown names
		# (font uninstalled/renamed) fall back to the first available font.
		var entry := find_font(str(value))
		if entry.is_empty() and !fonts.is_empty():
			entry = fonts[0]
		if entry.is_empty(): return

		var font := resolve_font(entry)
		if font == null: return

		apply_icon_fallbacks(font)

		editor_theme.set_font("normal_font", "RichTextLabel", font)
		editor_theme.set_font("font", "Label", font)
		editor_theme.set_font("font", "CodeEdit", font)
		editor_theme.set_font("font", "Button", font)
		editor_theme.set_font("font", "Tree", font)
	if p == "editor_font_size":
		editor_theme.set_font_size("font_size", "CodeEdit", int(value))
	if p == "editor_font_size" or p == "editor_line_height":
		_apply_line_height()

	# SHADERS
	if p == "glow":
		apply_glow(value)
	if p == "glow_intensity":
		apply_glow()
	if p == "sunlight":
		toggle_shader(SUNLIGHT, value)
	if p == "vhs":
		toggle_shader(VHS_AND_CRT, value)
	# MUSIC
	if p == "music":
		Music.set_enabled(value)
	if p == "music_volume":
		Music.set_volume(value)
	if p == "music_move_intensity":
		Music.music_move_intensity = value
	# CAMERA
	if p == "zoom_intensity":
		if camera: camera.zoom_intensity = value
	# The camera IS the scroll in this editor: the CodeEdit grows to fit its
	# content and never scrolls internally, so these two drive the view.
	if p == "smooth_scrolling":
		if camera: camera.smooth_scrolling = bool(value)
	if p == "scroll_speed":
		if camera: camera.scroll_speed = float(value)
	# MINIMAP (screen-space strip, not the CodeEdit's built-in one)
	if p == "minimap":
		if editor.minimap != null:
			editor.minimap.set_enabled(bool(value))
	if p == "minimap_width":
		if editor.minimap != null:
			editor.minimap.set_strip_width(int(value))
	if p == "large_file_mode" or p == "large_file_threshold":
		if editor != null and editor.has_method("apply_large_file_settings"):
			editor.apply_large_file_settings()
	if p == "background_indexing":
		if editor != null and editor.has_method("apply_background_indexing"):
			editor.apply_background_indexing(bool(value))
	if p == "high_contrast":
		apply_high_contrast(bool(value))
	if p == "reduced_motion" or p == "static_camera":
		apply_motion_settings()
	if p == "focus_indicators":
		_apply_focus_indicators()
	if p == "dyslexia_font":
		apply_dyslexia_font(bool(value))
	if p == "ui_language":
		_apply_language(str(value))
	if p == "git_auto_refresh":
		if editor != null and editor.has_method("apply_git_setting"):
			editor.apply_git_setting(p, value)
	if p == "discord_sdk":
		discord_sdk = value;
	if p == "beginner_mode" and editor != null and editor.has_method("apply_beginner_mode"):
		editor.apply_beginner_mode(bool(value))
	if (p == "history_interval" or p == "history_enabled") and editor != null and editor.has_method("apply_history_setting"):
		editor.apply_history_setting()


# ── ACCESSIBILITY & LOCALIZATION ────────────────────────────────────────────

func _setting_value(key: String, fallback: Variant = null) -> Variant:
	if settings_service == null:
		return fallback
	var found := settings_service.compat_entry(key)
	if found.is_empty():
		return fallback
	return found.get("value", fallback)


func _setting_bool(key: String, fallback: bool = false) -> bool:
	return bool(_setting_value(key, fallback))


## Applies the real line-height setting. CodeEdit's `line_spacing` is the extra
## pixels between lines, so the multiplier is converted using the current font
## size instead of being written as a raw pixel value.
func _apply_line_height() -> void:
	if editor_theme == null:
		return
	var size := int(_setting_value("editor_font_size", 16))
	var height := float(_setting_value("editor_line_height", ACCESSIBILITY.DEFAULT_LINE_HEIGHT))
	editor_theme.set_constant("line_spacing", "CodeEdit", ACCESSIBILITY.line_spacing_px(size, height))


func _apply_accessibility_palette() -> void:
	if !_setting_bool("high_contrast", false):
		return
	if _pre_contrast_gui.is_empty():
		_pre_contrast_gui = gui.duplicate(true)
		_pre_contrast_keywords = keywords.duplicate(true)
	for key in ACCESSIBILITY.HIGH_CONTRAST_GUI.keys():
		gui[key] = ACCESSIBILITY.HIGH_CONTRAST_GUI[key]
	for key in ACCESSIBILITY.HIGH_CONTRAST_KEYWORDS.keys():
		keywords[key] = ACCESSIBILITY.HIGH_CONTRAST_KEYWORDS[key]


## High contrast is a palette override, not a second theme: the active theme is
## re-applied when it is turned off, so nothing from the override survives.
func apply_high_contrast(enabled: bool) -> void:
	if !_nodes():
		return

	if enabled:
		_apply_accessibility_palette()
		if shader_layer != null:
			shader_layer.hide()
		if bloom_layer != null:
			bloom_layer.visible = false
		on_theme_load.emit()
		on_settings_change.emit()
		return

	# Restore the captured theme palette. Reloading the theme file would work
	# for the keys it sets, but the theme dictionaries are intentionally not
	# cleared between loads, so unset keys could keep the contrast colours.
	for key in _pre_contrast_gui.keys():
		gui[key] = _pre_contrast_gui[key]
	for key in _pre_contrast_keywords.keys():
		keywords[key] = _pre_contrast_keywords[key]
	_pre_contrast_gui.clear()
	_pre_contrast_keywords.clear()
	_apply_line_height()
	_apply_focus_indicators()
	_restore_shader_layer()
	_refresh_effects()
	on_theme_load.emit()
	on_settings_change.emit()


func _apply_focus_indicators() -> void:
	if editor_theme == null:
		return

	var enabled := _setting_bool("focus_indicators", true)
	var accent: Color = gui.get("selection_color", Color("#8ab4f8"))
	if ACCESSIBILITY.contrast_ratio(accent, gui.get("background_color", Color.BLACK)) < 3.0:
		accent = Color("#ffd400")

	var style: StyleBox = ACCESSIBILITY.focus_stylebox(accent) if enabled else StyleBoxEmpty.new()
	for type in ["Button", "CheckButton", "OptionButton", "HSlider", "LineEdit", "ItemList", "LinkButton", "TabBar"]:
		editor_theme.set_stylebox("focus", type, style)


## Reduced motion and static camera both stop motion; reduced motion is the
## wider switch and also removes decorative shaders, video and the trail.
func apply_motion_settings() -> void:
	if !_nodes():
		return

	var reduced := _setting_bool("reduced_motion", false)
	var static_mode := reduced or _setting_bool("static_camera", false)

	if camera != null and camera.has_method("set_motion_mode"):
		camera.set_motion_mode(static_mode, reduced)
	Music.set_pulse_enabled(!static_mode)
	if editor.cursor_effect != null:
		editor.cursor_effect.set_motion_disabled(reduced)
	if editor.overlays != null:
		editor.overlays.reduced_motion = reduced
	_set_background_video_paused(reduced)

	if reduced:
		if shader_layer != null:
			shader_layer.hide()
		if bloom_layer != null:
			bloom_layer.visible = false
	else:
		_restore_shader_layer()

	_refresh_effects()


func _restore_shader_layer() -> void:
	if shader_layer == null or shader_layer.material == null:
		return

	# Accessibility modes win over the shader setting: never bring a
	# full-screen effect back while motion is restricted or contrast is forced.
	if _setting_bool("reduced_motion", false) or _setting_bool("high_contrast", false):
		shader_layer.hide()
		return

	if _setting_bool("vhs", false):
		shader_layer.material.shader = VHS_AND_CRT
		shader_layer.show()
		tune_vhs_brightness()
	elif _setting_bool("sunlight", false):
		shader_layer.material.shader = SUNLIGHT
		shader_layer.show()
	else:
		shader_layer.material.shader = null
		shader_layer.hide()


func _set_background_video_paused(paused: bool) -> void:
	if editor == null:
		return
	var settings_node := editor.get_node_or_null("Settings")
	if settings_node == null:
		return
	var video := settings_node.get_node_or_null("VideoStreamPlayer")
	if video is VideoStreamPlayer:
		(video as VideoStreamPlayer).paused = paused


## Picks the first installed dyslexia-friendly font. The previous font is
## remembered for this session so turning the option off restores it.
func apply_dyslexia_font(enabled: bool) -> void:
	var current := str(_setting_value("editor_font", ""))

	if !enabled:
		if !_dyslexia_previous_font.is_empty():
			var previous := _dyslexia_previous_font
			_dyslexia_previous_font = ""
			set_setting_value("editor_font", previous)
			handle_internal_setting_change("editor_font", previous)
		return

	var entry: Dictionary = ACCESSIBILITY.pick_font(fonts)
	if entry.is_empty():
		if editor != null and editor.has_method("warn"):
			editor.warn("[color=yellow]WARNING[/color]: No dyslexia-friendly font is installed. Install OpenDyslexic, Atkinson Hyperlegible or Lexend, then turn this on again.")
		# Go through change_setting so the checkbox and the saved value agree;
		# set_setting_value alone left the toggle visibly on.
		change_setting("dyslexia_font", false)
		on_settings_change.emit()
		return

	if !current.is_empty() and current != str(entry.get("display", "")):
		_dyslexia_previous_font = current
	var font_id := str(entry.get("display", entry.get("value", "")))
	set_setting_value("editor_font", font_id)
	handle_internal_setting_change("editor_font", font_id)

	# A little more air is part of the recommendation for these faces, but a
	# larger user choice is never reduced.
	if float(_setting_value("editor_line_height", 1.25)) < 1.4:
		change_setting("editor_line_height", 1.4)


func _apply_language(code: String) -> void:
	if localization_service == null:
		return
	if !localization_service.set_locale(code):
		return
	if editor != null and editor.has_method("refresh_localized_ui"):
		editor.refresh_localized_ui()
	else:
		on_settings_change.emit()


func setup_discord_sdk(detail: String, state: String) -> void:
	if !discord_sdk: return
	DiscordSDK.details = detail
	DiscordSDK.state = state

	DiscordSDK.refresh()

# LUA
var theme_lua: LuaAPI = LuaAPI.new()

func str_to_clr(string: String) -> Color:
	return Color.from_string(string, "#ff0000");


func _lua_set_keywords(property: String, new_color: String) -> void:
	if !(property in keywords.keys()):
		print("ERROR: provided color property (\"%s\") in theme (KEYWORD) is invalid." % [property])
		return

	keywords[property] = str_to_clr(new_color)

func _lua_disable_glow() -> void:
	if !_nodes(): return

	editor.warn("[color=yellow]WARNING[/color]: This theme disabled the \"glow\".")
	set_setting_value("glow", false)
	handle_internal_setting_change("glow", false)

func _lua_set_gui(property: String, new_color: String) -> void:
	if !(property in gui.keys()):
		print("ERROR: provided color property (\"%s\") in theme (GUI) is invalid." % [property])
		return

	gui[property] = str_to_clr(new_color)

## Compatibility entry point. LanguageService parses each extension once and
## caches the interpreter, keyword/region registrations and highlighter; this
## only switches the active language and refreshes the comments alias.
func setup_extension(extension: String) -> void:
	if language_service == null:
		return

	var state: Dictionary = language_service.activate(extension)
	comments = state.get("comments", [])

	# Some overlays (comments) wait for a language to be parsed before they
	# can populate themselves. Emitting on activation keeps that flow working
	# now that parsing is cached.
	done_parsing.emit()

func setup_theme(given_theme: String) -> void:
	# Revert the contrast override before a different theme is loaded. Without
	# this, keys the new theme does not set would be captured as contrast
	# colours when the override is re-applied.
	if !_pre_contrast_gui.is_empty():
		for key in _pre_contrast_gui.keys():
			gui[key] = _pre_contrast_gui[key]
		for key in _pre_contrast_keywords.keys():
			keywords[key] = _pre_contrast_keywords[key]
		_pre_contrast_gui.clear()
		_pre_contrast_keywords.clear()

	# Start every theme from the same palette. Themes intentionally only set
	# the keys they care about, so anything left over would leak across a
	# switch.
	gui = _base_gui.duplicate(true)
	keywords = _base_keywords.duplicate(true)

	theme_lua.bind_libraries(["base", "table", "string"])

	theme_lua.push_variant("disable_glow", _lua_disable_glow)
	theme_lua.push_variant("set_keywords", _lua_set_keywords)
	theme_lua.push_variant("set_gui", _lua_set_gui)

	var theme_err: LuaError = theme_lua.do_file("user://themes/" + given_theme + ".lua")
	if theme_err is LuaError:
		_nodes()
		if editor != null:
			editor.warn("[color=yellow]WARNING[/color]: Failed to load theme: " + theme_err.message)
		print("ERROR %d: %s" % [theme_err.type, theme_err.message])
		# Listeners must still be notified: several panels await this signal
		# before they build their content, and would hang empty forever.
		# The base palette (_base_gui/_base_keywords) is a valid fallback.
		theme_load_attempted = true
		on_theme_load.emit()
		return

	# Palette and layout overrides sit on top of whatever the theme set. They
	# run here so a theme switch can never silently drop them.
	_apply_line_height()
	# A new theme is a new palette: capture it fresh before overriding.
	if _setting_bool("high_contrast", false):
		_pre_contrast_gui.clear()
		_pre_contrast_keywords.clear()
	_apply_accessibility_palette()
	_apply_focus_indicators()

	theme_load_attempted = true
	on_theme_load.emit()
