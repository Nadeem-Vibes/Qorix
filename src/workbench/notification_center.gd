class_name NotificationCenter
extends Control

const UI_MOTION = preload("res://src/platform/ui_motion.gd")
const UiTheme = preload("res://src/workbench/ui_theme.gd")

const MAX_VISIBLE := 5
const DISPLAY_SECONDS := 5.0
const WIDTH := 430.0

var _stack: VBoxContainer
var _items: Array[Control] = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	offset_left = -WIDTH - 16.0
	offset_top = 12.0
	offset_right = -16.0
	offset_bottom = 0.0

	_stack = VBoxContainer.new()
	_stack.add_theme_constant_override("separation", 6)
	_stack.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_stack)

	LuaSingleton.on_theme_load.connect(restyle)
	restyle()


func push(message: String, severity: String = "info") -> void:
	if message.strip_edges().is_empty():
		return

	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(WIDTH, 0)
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.set_meta("severity", severity)
	card.add_theme_stylebox_override("panel", _card_style(severity))

	var label := RichTextLabel.new()
	label.bbcode_enabled = true
	label.fit_content = true
	label.scroll_active = false
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.text = message
	card.add_child(label)

	_stack.add_child(card)
	_items.push_back(card)
	while _items.size() > MAX_VISIBLE:
		_remove(_items.pop_front())

	card.modulate.a = 0.0
	if UI_MOTION.allowed():
		# Fade only: the cards live in a VBoxContainer, which rewrites each
		# child's position on every layout pass and would fight a position
		# tween (the card jittered instead of sliding).
		var tween := create_tween()
		tween.tween_property(card, "modulate:a", 1.0, UI_MOTION.duration())
	else:
		card.modulate.a = 1.0

	get_tree().create_timer(DISPLAY_SECONDS).timeout.connect(func() -> void:
		if is_instance_valid(card):
			_remove(card)
	)


func restyle() -> void:
	for item in _items:
		if is_instance_valid(item) and item is PanelContainer:
			var label := item.get_child(0)
			item.add_theme_stylebox_override("panel", _card_style(str(item.get_meta("severity", "info"))))
			if label is RichTextLabel:
				label.add_theme_color_override("default_color", LuaSingleton.gui.font_color)


func _card_style(severity: String) -> StyleBoxFlat:
	var style := UiTheme.panel_style()
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	style.border_width_left = 3
	style.border_color = _severity_color(severity)
	return style


func _severity_color(severity: String) -> Color:
	match severity:
		"error":
			return Color("#f7768e")
		"warning":
			return Color("#e0af68")
		"success":
			return Color("#9ece6a")
		_:
			return LuaSingleton.gui.selection_color


func _remove(card: Control) -> void:
	if !_items.has(card):
		return
	_items.erase(card)
	if !is_instance_valid(card):
		return
	if UI_MOTION.allowed():
		var tween := create_tween()
		tween.tween_property(card, "modulate:a", 0.0, UI_MOTION.duration())
		tween.tween_callback(card.queue_free)
	else:
		card.queue_free()
