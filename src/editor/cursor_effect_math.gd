class_name CursorEffectMath
extends RefCounted

## The maths behind the cursor trail.
##
## The trail itself is drawn by a shader (resources/shaders/cursor_trail.gdshader); this
## module owns the parts that decide *where* the trail is: the shape of the
## caret, the rectangle the shader has to cover, and whether a movement is big
## enough to be worth animating.
##
## It is pure on purpose: the headless test runner can check it without
## booting the editor scene, and the driver (src/editor/cursor_effect.gd)
## stays free of geometry maths.

## The effects, matching the `effect` uniform of the shader.
const EFFECT_OFF := 0
const EFFECT_WARP := 1
const EFFECT_SWEEP := 2
const EFFECT_TAIL := 3

## The caret shapes, matching CodeEdit's caret_type.
const CARET_LINE := 0
const CARET_BLOCK := 1
const CARET_UNDERLINE := 2

## A trail thinner than this is invisible once the camera zooms in, so a line
## caret is widened to it.
const MIN_TRAIL_WIDTH := 2.0
## Fallback width of a line caret, in pixels.
const DEFAULT_CARET_WIDTH := 1.0
## Fallback height of an underline caret, in pixels.
const DEFAULT_UNDERLINE_HEIGHT := 2.0
## Default length of the animation, in seconds.
const DEFAULT_DURATION := 0.2
## Default strength of the trail, in percent.
const DEFAULT_OPACITY := 55
## A movement shorter than this fraction of the caret's height is not worth
## animating. It is a fraction of the height so the same number works at
## every zoom level.
const DEFAULT_MOVE_THRESHOLD := 0.05
## The soft edge of the trail, as a fraction of the caret's height.
const EDGE_RATIO := 0.06
## The soft edge is never thinner than this, in pixels.
const MIN_EDGE := 0.75


## The rectangle the caret occupies, given the cell it sits in.
##
## `caret_width` and `underline_height` are the theme's own measurements; the
## fallbacks are used when the theme does not carry them.
static func caret_shape(cell: Rect2, caret_type: int, caret_width: float, underline_height: float) -> Rect2:
	if cell.size.x <= 0.0 or cell.size.y <= 0.0:
		return Rect2()

	match caret_type:
		CARET_BLOCK:
			# The block caret covers the character under it.
			return Rect2(cell.position, cell.size)
		CARET_UNDERLINE:
			var bar: float = maxf(1.0, underline_height)
			return Rect2(cell.position.x, cell.position.y + cell.size.y - bar, cell.size.x, bar)
		_:
			# The line caret is a thin bar on the left edge of the cell. It is
			# widened to the minimum trail width, so the trail is a streak and
			# not a hairline.
			var bar_width: float = maxf(MIN_TRAIL_WIDTH, caret_width)
			return Rect2(cell.position.x, cell.position.y, bar_width, cell.size.y)


## The centre of a rectangle.
static func center(rect: Rect2) -> Vector2:
	return rect.position + rect.size * 0.5


## How far the caret travelled between two shapes, in pixels.
static func travel(previous: Rect2, current: Rect2) -> float:
	return center(previous).distance_to(center(current))


## Whether a movement is big enough to animate. `threshold` is a fraction of
## the caret's height.
static func should_animate(previous: Rect2, current: Rect2, threshold: float) -> bool:
	if previous.size.y <= 0.0 or current.size.y <= 0.0:
		return false

	var limit: float = maxf(current.size.y, previous.size.y) * maxf(0.0, threshold)
	return travel(previous, current) > limit


## The rectangle the shader has to cover for a trail between two carets.
##
## The trail never reaches outside the two carets, so their union plus a
## margin for the soft edge is enough.
static func trail_bounds(previous: Rect2, current: Rect2, padding: float) -> Rect2:
	var bounds := Rect2()
	var has_bounds := false

	if previous.size.x > 0.0 and previous.size.y > 0.0:
		bounds = previous
		has_bounds = true

	if current.size.x > 0.0 and current.size.y > 0.0:
		bounds = bounds.merge(current) if has_bounds else current
		has_bounds = true

	if !has_bounds:
		return Rect2()

	return bounds.grow(maxf(0.0, padding))


## The width of the soft edge of the trail, in pixels.
##
## It is a fraction of the caret's height so the trail keeps the same soft
## look whatever the font size is.
static func edge_size(caret_height: float) -> float:
	return maxf(MIN_EDGE, absf(caret_height) * EDGE_RATIO)
