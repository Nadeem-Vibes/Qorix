class_name ScrollMath
extends RefCounted

## The maths behind the "Scrolling & Minimap" settings.
##
## It lives in its own file because it is pure: the camera (which glides
## towards the caret) and the minimap (which maps lines onto a screen-space
## strip) both need it, and neither needs the other. Keeping it dependency
## free also means the headless test runner can check it without booting the
## editor scene.

## Shortest a glide may take, in seconds. Even a one-line correction has to
## be a visible movement — that is what makes it read as a glide and not as
## a jump.
const MIN_TIME := 0.25
## Longest a glide may take, in seconds. A jump to the far end of a huge
## file must not crawl.
const MAX_TIME := 2.5
## Height of one line in the minimap strip, in pixels.
##
## A short file must NOT be stretched to fill the strip: five lines blown up
## to a fifth of the screen each is five solid blocks, not an overview. Every
## other editor's minimap keeps the rows thin and leaves the rest of the
## strip empty.
const ROW_HEIGHT := 3.0
## Fallback used when the settings store has no value yet.
const DEFAULT_SCROLL_SPEED := 700.0
## Fallback used when the settings store has no value yet.
const DEFAULT_SMOOTH_SCROLLING := true


## Seconds the glide towards the caret takes for a given distance.
##
## The distance is in the file's own pixels (the CodeEdit's), not screen
## pixels: the zoom magnifies the file, but the travel through it is the
## same either way.
##
## The time is a base plus the distance at the configured speed, so a short
## move still takes a moment (MIN_TIME) while a long one scales with the
## distance — clamped so a jump to the far end of a huge file stays quick.
static func glide_duration(distance: float, speed: float) -> float:
	if speed <= 0.0:
		return MIN_TIME
	return clampf(MIN_TIME + distance / speed, MIN_TIME, MAX_TIME)


## The eased progress of a glide, from 0 to 1.
##
## It starts at full speed and slows into the target, so the view settles
## instead of stopping dead. A glide that started slowly would stall every
## time the caret moved, because the glide restarts from wherever the view
## currently is.
static func glide_progress(t: float) -> float:
	var clamped := clampf(t, 0.0, 1.0)
	return 1.0 - (1.0 - clamped) * (1.0 - clamped)


## Height of one line in the minimap strip.
##
## Thin rows, capped at ROW_HEIGHT, so a short file stays a few thin lines at
## the top of the strip. A file with more lines than the strip has pixels
## gets a fractional row and is drawn one pixel row at a time.
static func strip_row_height(line_count: int, strip_height: float) -> float:
	if line_count <= 0 || strip_height <= 0.0:
		return 0.0
	return minf(ROW_HEIGHT, strip_height / float(line_count))


## Maps a line number to its y position inside the minimap strip.
static func line_to_strip_y(line: float, line_count: int, strip_height: float) -> float:
	return line * strip_row_height(line_count, strip_height)


## Maps a y position inside the minimap strip back to a line number.
static func strip_y_to_line(y: float, line_count: int, strip_height: float) -> int:
	var row_h := strip_row_height(line_count, strip_height)
	if row_h <= 0.0:
		return 0
	var line := int(floor(y / row_h))
	return clampi(line, 0, line_count - 1)
