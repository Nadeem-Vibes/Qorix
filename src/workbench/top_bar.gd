extends PanelContainer

## The generated top bar: a real MenuBar plus a toolbar, both built from
## CommandRegistry. It sits above the tab strip so the menus never cover code.

const HEIGHT := 28.0
const MenuBuilder = preload("res://src/workbench/menu_builder.gd")
const ToolbarBuilder = preload("res://src/workbench/toolbar_builder.gd")
const UiTheme = preload("res://src/workbench/ui_theme.gd")

var editor: FileManager
var menu_bar: MenuBar
var toolbar: HBoxContainer
var toolbar_buttons: Dictionary = {}

var _refresh_queued: bool = false


func _ready() -> void:
	editor = _find_editor()

	theme = LuaSingleton.editor_theme
	set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	offset_top = 0.0
	offset_bottom = HEIGHT
	custom_minimum_size = Vector2(0, HEIGHT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	add_child(box)

	menu_bar = MenuBar.new()
	menu_bar.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	menu_bar.focus_mode = Control.FOCUS_NONE
	menu_bar.theme = LuaSingleton.editor_theme
	box.add_child(menu_bar)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(spacer)

	toolbar = HBoxContainer.new()
	toolbar.add_theme_constant_override("separation", 2)
	toolbar.size_flags_horizontal = Control.SIZE_SHRINK_END
	box.add_child(toolbar)

	LuaSingleton.on_theme_load.connect(_on_theme_load)
	LuaSingleton.on_settings_change.connect(_queue_refresh)

	if editor != null and editor.commands != null:
		editor.commands.changed.connect(refresh)

	restyle()
	refresh()


func _find_editor() -> FileManager:
	var node = get_parent()
	while node != null and !(node is FileManager):
		node = node.get_parent()
	return node


## Rebuilds menus and toolbar from the registry. Called immediately on a
## rebinding so shortcut labels and toolbar tooltips cannot go stale.
func refresh() -> void:
	if editor == null or editor.commands == null:
		return
	if !is_inside_tree():
		return

	MenuBuilder.build(menu_bar, editor.commands, _execute)
	ToolbarBuilder.build(toolbar, editor.commands, _execute, toolbar_buttons)
	restyle_buttons()


func _queue_refresh() -> void:
	if _refresh_queued:
		return
	_refresh_queued = true
	call_deferred("_deferred_refresh")


func _deferred_refresh() -> void:
	_refresh_queued = false
	refresh()


func _execute(command_id: String) -> void:
	if editor != null and editor.commands != null:
		editor.commands.execute(command_id)


func _on_theme_load() -> void:
	restyle()
	_queue_refresh()


func restyle() -> void:
	if menu_bar == null:
		return

	theme = LuaSingleton.editor_theme
	menu_bar.theme = LuaSingleton.editor_theme

	var panel := UiTheme.panel_style(false, true)
	panel.bg_color = LuaSingleton.gui.background_color.darkened(0.06)
	panel.content_margin_top = 2
	panel.content_margin_bottom = 2
	add_theme_stylebox_override("panel", panel)

	menu_bar.add_theme_color_override("font_color", LuaSingleton.gui.font_color)
	menu_bar.add_theme_color_override("font_hover_color", LuaSingleton.gui.selection_color)
	menu_bar.add_theme_color_override("font_pressed_color", LuaSingleton.gui.selection_color)
	menu_bar.add_theme_font_size_override("font_size", 13)

	restyle_buttons()


func restyle_buttons() -> void:
	for button in toolbar_buttons.values():
		if !is_instance_valid(button):
			continue
		UiTheme.apply_button(button)
		button.add_theme_font_size_override("font_size", 15)
