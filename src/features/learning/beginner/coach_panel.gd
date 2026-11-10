extends PanelContainer

## Small floating coach card for the four-step tutorial.
##
## It mirrors OnboardingService's state; all actions are delegated to
## FileManager so the card never needs to know how a file is created or run.

const WIDTH := 380.0
const UI_MOTION = preload("res://src/platform/ui_motion.gd")

static func _t(text: String) -> String:
	return TranslationServer.translate(text)

var editor: FileManager = null

var _step_label: Label
var _title_label: Label
var _hint_label: Label
var _action_button: Button
var _skip_button: Button
var _show_tween: Tween = null


func _ready() -> void:
	editor = _find_editor()
	theme = LuaSingleton.editor_theme
	visible = false
	z_index = 32
	mouse_filter = Control.MOUSE_FILTER_STOP

	set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	offset_left = -(WIDTH + 20.0)
	offset_right = -20.0
	offset_top = 86.0
	# A fixed content-sized height: a zero-height PanelContainer draws no
	# backdrop at all, and containers don't clip, so the labels ended up
	# floating unreadable over the code.
	offset_bottom = 86.0 + 236.0

	resized.connect(func() -> void: pivot_offset = size * 0.5)

	_build()
	LuaSingleton.on_theme_load.connect(restyle)
	LuaSingleton.on_settings_change.connect(restyle)
	restyle()


func _find_editor() -> FileManager:
	var node = get_parent()
	while node != null and !(node is FileManager):
		node = node.get_parent()
	return node


func _build() -> void:
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 8)
	add_child(body)

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)
	body.add_child(top)

	_step_label = Label.new()
	_step_label.add_theme_font_size_override("font_size", 11)
	_step_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(_step_label)

	_skip_button = Button.new()
	_skip_button.text = _t("Skip")
	_skip_button.tooltip_text = _t("Stop the tutorial. You can replay it from Help > Start Tutorial.")
	_skip_button.focus_mode = Control.FOCUS_NONE
	_skip_button.pressed.connect(_on_skip)
	top.add_child(_skip_button)

	_title_label = Label.new()
	_title_label.add_theme_font_size_override("font_size", 18)
	_title_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(_title_label)

	_hint_label = Label.new()
	_hint_label.add_theme_font_size_override("font_size", 13)
	_hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(_hint_label)

	_action_button = Button.new()
	_action_button.custom_minimum_size = Vector2(0, 34)
	_action_button.pressed.connect(_on_action)
	body.add_child(_action_button)


func show_state(state: Dictionary) -> void:
	if !bool(state.get("active", false)) or int(state.get("step", 0)) >= int(state.get("step_count", 4)):
		visible = false
		return

	var was_hidden := !visible
	var step := int(state.get("step", 0))
	var total := int(state.get("step_count", 4))
	var info: Dictionary = state.get("step_info", {})

	_step_label.text = _t("STEP %d OF %d") % [step + 1, total]
	_title_label.text = str(info.get("title", "Tutorial"))
	_hint_label.text = str(info.get("hint", ""))
	_action_button.text = str(info.get("action", _t("Continue")))
	_skip_button.visible = !bool(state.get("completed", false))
	visible = true
	if was_hidden and UI_MOTION.allowed():
		# Pop the coach in so a first-time user notices it without being
		# startled: a soft fade and a small scale-up, never a bounce.
		if _show_tween != null and _show_tween.is_valid():
			_show_tween.kill()
		modulate.a = 0.0
		scale = Vector2(0.94, 0.94)
		_show_tween = create_tween()
		_show_tween.set_parallel(true)
		_show_tween.tween_property(self, "modulate:a", 1.0, 0.22).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		_show_tween.tween_property(self, "scale", Vector2.ONE, 0.26).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	elif !UI_MOTION.allowed():
		modulate.a = 1.0
		scale = Vector2.ONE


func hide_now() -> void:
	visible = false


func _on_action() -> void:
	if editor != null:
		editor.onboarding_action()


func _on_skip() -> void:
	if editor != null:
		editor.skip_onboarding()


func restyle() -> void:
	if LuaSingleton.gui == null:
		return
	var panel := StyleBoxFlat.new()
	panel.bg_color = LuaSingleton.gui.background_color.lightened(0.05)
	panel.border_color = LuaSingleton.gui.selection_color
	panel.border_width_left = 2
	panel.border_width_top = 1
	panel.border_width_right = 1
	panel.border_width_bottom = 1
	panel.corner_radius_top_left = 6
	panel.corner_radius_top_right = 6
	panel.corner_radius_bottom_left = 6
	panel.corner_radius_bottom_right = 6
	panel.content_margin_left = 16
	panel.content_margin_right = 16
	panel.content_margin_top = 12
	panel.content_margin_bottom = 14
	add_theme_stylebox_override("panel", panel)

	if _step_label != null:
		_step_label.add_theme_color_override("font_color", LuaSingleton.gui.selection_color)
	if _title_label != null:
		_title_label.add_theme_color_override("font_color", LuaSingleton.gui.font_color)
	if _hint_label != null:
		_hint_label.add_theme_color_override("font_color", LuaSingleton.gui.font_color.darkened(0.15))
	if _action_button != null:
		_action_button.add_theme_color_override("font_color", LuaSingleton.gui.selection_color)
