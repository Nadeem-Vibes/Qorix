extends Control

## Retained display list for the `canvas` widget.
##
## A canvas is a list of ops rebuilt only when the props change; it is not
## per-frame Lua drawing and it cannot create engine objects. Supported ops:
## line, rect, text, image (image is reserved for the Phase 4 asset handle and is
## ignored for now). Coordinates are canvas-local pixels.

const MAX_OPS := 512
const MAX_TEXT := 512

var ops: Array = []


func set_ops(value: Variant) -> void:
	if !(value is Array):
		ops = []
		queue_redraw()
		return

	var next: Array = []
	for item in value:
		if next.size() >= MAX_OPS:
			break
		if item is Dictionary:
			next.append((item as Dictionary).duplicate(true))
	ops = next
	queue_redraw()


func _draw() -> void:
	var font := get_theme_default_font()
	var font_size := get_theme_default_font_size()

	for item in ops:
		var op: Dictionary = item
		var kind := str(op.get("op", ""))
		var color := Color.from_string(str(op.get("color", "#cdd6f4")), Color.WHITE)
		match kind:
			"line":
				draw_line(
					Vector2(float(op.get("x1", 0)), float(op.get("y1", 0))),
					Vector2(float(op.get("x2", 0)), float(op.get("y2", 0))),
					color,
					float(op.get("width", 1.0)),
				)
			"rect":
				var rect := Rect2(
					Vector2(float(op.get("x", 0)), float(op.get("y", 0))),
					Vector2(float(op.get("w", 0)), float(op.get("h", 0))),
				)
				if bool(op.get("filled", false)):
					draw_rect(rect, color, true)
				else:
					draw_rect(rect, color, false, float(op.get("width", 1.0)))
			"text":
				if font == null:
					continue
				var text := str(op.get("text", ""))
				if text.length() > MAX_TEXT:
					text = text.substr(0, MAX_TEXT)
				var origin := Vector2(float(op.get("x", 0)), float(op.get("y", 0)))
				draw_string(
					font,
					origin,
					text,
					HORIZONTAL_ALIGNMENT_LEFT,
					-1,
					clampi(int(op.get("size", font_size)), 1, 512),
					color,
				)
