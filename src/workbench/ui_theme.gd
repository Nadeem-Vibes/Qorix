class_name UiTheme
extends RefCounted

## Small theme-derived helpers shared by generated HUD controls.

static func panel_style(top_border: bool = false, bottom_border: bool = false) -> StyleBoxFlat:
	var panel := StyleBoxFlat.new()
	panel.bg_color = LuaSingleton.gui.background_color
	panel.set_content_margin_all(6)
	panel.content_margin_left = 8
	panel.content_margin_right = 8
	panel.corner_radius_top_left = 4
	panel.corner_radius_top_right = 4
	if top_border:
		panel.border_width_top = 1
	if bottom_border:
		panel.border_width_bottom = 1
	panel.border_color = LuaSingleton.gui.current_line_color
	return panel


static func apply_button(button: Button, compact: bool = false) -> void:
	if button == null:
		return
	button.add_theme_color_override("font_color", LuaSingleton.gui.font_color)
	button.add_theme_color_override("font_hover_color", LuaSingleton.gui.selection_color)
	button.add_theme_color_override("font_pressed_color", LuaSingleton.gui.selection_color)
	button.add_theme_color_override("font_focus_color", LuaSingleton.gui.font_color)
	button.add_theme_font_size_override("font_size", 12 if compact else 13)
