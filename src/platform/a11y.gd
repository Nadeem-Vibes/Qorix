class_name Accessibility
extends RefCounted

## Pure accessibility helpers: contrast maths, line-height conversion, the
## large-file decision and the focus-ring style. Nothing here touches a scene,
## so the headless suites can check the numbers without booting the editor.

## A file is "large" once it crosses either limit. The line threshold is the
## one the user controls; the character limit catches minified bundles that
## have few lines but megabytes of text.
const DEFAULT_LARGE_FILE_LINES := 5000
const MIN_LARGE_FILE_LINES := 500
const MAX_LARGE_FILE_LINES := 100000
const LARGE_FILE_CHARS := 750000

## Multiplier bounds for the real line-height setting. 1.0 is the theme's own
## spacing (no extra pixels), 2.5 is the most a comfortable layout needs.
const MIN_LINE_HEIGHT := 1.0
const MAX_LINE_HEIGHT := 2.5
const DEFAULT_LINE_HEIGHT := 1.25

## High-contrast palette. Every foreground is at least 7:1 against #000000
## (WCAG AAA for normal text); the accent is deliberately yellow instead of a
## pastel so it survives the bloom-free, low-saturation case.
const HIGH_CONTRAST_GUI := {
	"background_color": Color("#000000"),
	"current_line_color": Color("#1a1a1a"),
	"selection_color": Color("#ffe600"),
	"font_color": Color("#ffffff"),
	"word_highlighted_color": Color("#2e2e2e"),
	"completion_background_color": Color("#000000"),
	"completion_selected_color": Color("#333300"),
	"caret_color": Color("#00ffff"),
}

const HIGH_CONTRAST_KEYWORDS := {
	"reserved": Color("#ff8cff"),
	"annotation": Color("#b6ff8c"),
	"string": Color("#6dff9a"),
	"binary": Color("#ffb86b"),
	"symbol": Color("#ffffff"),
	"variable": Color("#ffe066"),
	"operator": Color("#7ff9ff"),
	"comments": Color("#c8c8c8"),
	"error": Color("#ff6b6b"),
	"function": Color("#8fd3ff"),
	"member": Color("#ffb3c1"),
}

## Fonts that are designed for readers with dyslexia. They are only offered
## when the operating system reports them; Qorix never downloads fonts.
const DYSLEXIA_FONTS := [
	"OpenDyslexic",
	"Atkinson Hyperlegible",
	"Lexend",
	"Comic Sans MS",
	"Verdana",
]


## WCAG relative luminance (0 black .. 1 white).
static func relative_luminance(color: Color) -> float:
	var r := _linear_channel(color.r)
	var g := _linear_channel(color.g)
	var b := _linear_channel(color.b)
	return 0.2126 * r + 0.7152 * g + 0.0722 * b


static func _linear_channel(value: float) -> float:
	var channel := clampf(value, 0.0, 1.0)
	if channel <= 0.04045:
		return channel / 12.92
	return pow((channel + 0.055) / 1.055, 2.4)


## WCAG contrast ratio, 1.0 (identical) .. 21.0 (black on white).
static func contrast_ratio(a: Color, b: Color) -> float:
	var first := relative_luminance(a)
	var second := relative_luminance(b)
	var lighter := maxf(first, second)
	var darker := minf(first, second)
	return (lighter + 0.05) / (darker + 0.05)


## CodeEdit's `line_spacing` is the number of *extra* pixels between lines on
## top of the font's own height. The setting is a real line-height multiplier,
## so the extra pixels are what remains after one font height.
static func line_spacing_px(font_size: int, line_height: float) -> int:
	var multiplier := clampf(line_height, MIN_LINE_HEIGHT, MAX_LINE_HEIGHT)
	var extra := float(maxi(font_size, 1)) * (multiplier - 1.0)
	return maxi(0, roundi(extra))


## Smallest line-height the accessibility settings allow, after clamping.
static func clamped_line_height(value: float) -> float:
	return clampf(value, MIN_LINE_HEIGHT, MAX_LINE_HEIGHT)


## A file needs large-file mode when it is longer than the configured number of
## lines, or when its text is simply too big to index in a frame.
static func is_large_file(
	line_count: int,
	char_count: int,
	threshold_lines: int = DEFAULT_LARGE_FILE_LINES,
	char_threshold: int = LARGE_FILE_CHARS
) -> bool:
	if line_count > maxi(MIN_LARGE_FILE_LINES, threshold_lines):
		return true
	if line_count > 1 and char_count > maxi(0, char_threshold):
		return true
	return false


## Motion is restricted when either accessibility switch is on. Reduced motion
## is the master switch: static camera is a subset of it.
static func motion_restricted(reduced_motion: bool, static_camera: bool) -> bool:
	return reduced_motion or static_camera


## The first installed font from `names`, matched case-insensitively on the
## display/value/name of a fonts[] entry. Returns {} when none is installed.
static func pick_font(fonts: Array, names: Array = DYSLEXIA_FONTS) -> Dictionary:
	for wanted in names:
		var needle := str(wanted).to_lower()
		for entry in fonts:
			if !(entry is Dictionary):
				continue
			var data: Dictionary = entry
			for field in ["display", "value", "name"]:
				if str(data.get(field, "")).to_lower() == needle:
					return data
	for wanted in names:
		var needle := str(wanted).to_lower()
		for entry in fonts:
			if !(entry is Dictionary):
				continue
			var data: Dictionary = entry
			for field in ["display", "value", "name"]:
				if str(data.get(field, "")).to_lower().contains(needle):
					return data
	return {}


## A visible keyboard focus ring. Transparent inside, bright border, so it
## works on every theme without changing the control's own colours.
static func focus_stylebox(color: Color, width: int = 2) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0)
	style.border_color = color
	style.border_width_left = width
	style.border_width_top = width
	style.border_width_right = width
	style.border_width_bottom = width
	style.corner_radius_top_left = 2
	style.corner_radius_top_right = 2
	style.corner_radius_bottom_left = 2
	style.corner_radius_bottom_right = 2
	style.content_margin_left = 2
	style.content_margin_right = 2
	return style
