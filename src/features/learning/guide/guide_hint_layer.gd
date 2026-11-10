extends Control

## Screen-space hint bubble.
##
## Hints are screen-space on purpose: they stay readable at any camera zoom,
## unlike ghost text. The host anchors one bubble at a time above (or below when
## clipped) the expected cluster, clamps it to the viewport and dismisses it
## after a configurable delay. A mod can style its own coach panel instead, but
## the host bubble is always available.

const DEFAULT_TTL := 6.0
const MAX_TEXT := 400
const MARGIN := 10.0

var _bubble: PanelContainer
var _label: Label
var _ttl := 0.0
var _anchor := Vector2.ZERO


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_bubble = PanelContainer.new()
	_bubble.name = "HintBubble"
	_bubble.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bubble.visible = false
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.09, 0.09, 0.14, 0.96)
	style.border_color = Color(0.54, 0.71, 0.98, 0.75)
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 6
	style.content_margin_bottom = 6
	_bubble.add_theme_stylebox_override("panel", style)
	add_child(_bubble)

	_label = Label.new()
	_label.name = "Text"
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.custom_minimum_size = Vector2(260, 0)
	_label.add_theme_font_size_override("font_size", 13)
	_bubble.add_child(_label)


func show_hint(text: String, anchor: Vector2, ttl: float = DEFAULT_TTL) -> void:
	var trimmed := text.strip_edges()
	if trimmed.is_empty():
		return
	if trimmed.length() > MAX_TEXT:
		trimmed = trimmed.substr(0, MAX_TEXT) + "…"
	_label.text = trimmed
	_anchor = anchor
	_ttl = maxf(1.0, float(ttl))
	_bubble.reset_size()
	_bubble.visible = true
	_place()


func hide_hint() -> void:
	_ttl = 0.0
	if _bubble != null:
		_bubble.visible = false


func is_showing() -> bool:
	return _bubble != null and _bubble.visible


func tick(delta: float) -> void:
	if _ttl <= 0.0:
		return
	_ttl -= maxf(0.0, float(delta))
	if _ttl <= 0.0:
		hide_hint()


func _place() -> void:
	var viewport := get_viewport_rect().size
	if viewport.x <= 0.0 or viewport.y <= 0.0:
		return
	var bubble_size := _bubble.size
	if bubble_size.x <= 0.0:
		bubble_size = _bubble.get_combined_minimum_size()
	var x := clampf(_anchor.x - bubble_size.x * 0.5, MARGIN, maxf(MARGIN, viewport.x - bubble_size.x - MARGIN))
	var above := _anchor.y - bubble_size.y - 14.0
	var y := above
	if above < MARGIN:
		y = minf(_anchor.y + 26.0, maxf(MARGIN, viewport.y - bubble_size.y - MARGIN))
	_bubble.position = Vector2(x, y)
