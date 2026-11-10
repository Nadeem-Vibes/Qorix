extends Control

## Screen-space start screen: starter templates, recent files, recent folders
## and the tutorial entry point.
##
## It is a plain HUD control rather than a world-space overlay, so it does not
## pan or zoom with the code behind it. FileManager shows it when no document
## is open or when "Welcome Screen" is invoked.

const MAX_RECENT_FILES := 6
const MAX_RECENT_WORKSPACES := 5
const UI_MOTION = preload("res://src/platform/ui_motion.gd")

static func _t(text: String) -> String:
	return TranslationServer.translate(text)

var editor: FileManager = null

var _card: PanelContainer
var _templates_grid: GridContainer
var _learn_box: VBoxContainer
var _learn_progress: Label
var _recent_files_box: VBoxContainer
var _recent_workspaces_box: VBoxContainer
var _empty_hint: Label
var _beginner_toggle: CheckButton
var _open_tween: Tween = null


func _ready() -> void:
	editor = _find_editor()
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	z_index = 40
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
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
	var backdrop := ColorRect.new()
	backdrop.color = Color(0, 0, 0, 0.62)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(backdrop)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	_card = PanelContainer.new()
	_card.custom_minimum_size = Vector2(940, 0)
	_card.mouse_filter = Control.MOUSE_FILTER_STOP
	# Pop-in animations scale around the card's centre instead of its
	# top-left corner, so the ease-out feels anchored rather than rubbery.
	_card.resized.connect(func() -> void: _card.pivot_offset = _card.size * 0.5)
	center.add_child(_card)

	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 14)
	_card.add_child(body)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 10)
	body.add_child(header)

	var titles := VBoxContainer.new()
	titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	titles.add_theme_constant_override("separation", 2)
	header.add_child(titles)

	var title := Label.new()
	title.text = _t("Welcome to Qorix")
	title.add_theme_font_size_override("font_size", 28)
	titles.add_child(title)

	var subtitle := Label.new()
	subtitle.text = _t("Pick a starting point, or open something you worked on before.")
	subtitle.add_theme_font_size_override("font_size", 14)
	titles.add_child(subtitle)

	var close := Button.new()
	close.text = "✕"
	close.tooltip_text = _t("Close (Esc)")
	close.focus_mode = Control.FOCUS_NONE
	close.pressed.connect(close_welcome)
	header.add_child(close)

	var templates_title := Label.new()
	templates_title.text = _t("START SOMETHING NEW")
	templates_title.add_theme_font_size_override("font_size", 12)
	body.add_child(templates_title)

	_templates_grid = GridContainer.new()
	_templates_grid.columns = 2
	_templates_grid.add_theme_constant_override("h_separation", 10)
	_templates_grid.add_theme_constant_override("v_separation", 10)
	body.add_child(_templates_grid)

	var learn_title := Label.new()
	learn_title.text = _t("LEARN PYTHON")
	learn_title.add_theme_font_size_override("font_size", 12)
	body.add_child(learn_title)

	_learn_box = VBoxContainer.new()
	_learn_box.name = "LearnPython"
	_learn_box.add_theme_constant_override("separation", 4)
	body.add_child(_learn_box)

	_learn_progress = Label.new()
	_learn_progress.text = ""
	_learn_progress.add_theme_font_size_override("font_size", 11)
	body.add_child(_learn_progress)

	var recent_row := HBoxContainer.new()
	recent_row.add_theme_constant_override("separation", 28)
	body.add_child(recent_row)

	var files_column := VBoxContainer.new()
	files_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	files_column.add_theme_constant_override("separation", 6)
	recent_row.add_child(files_column)

	var files_title := Label.new()
	files_title.text = _t("RECENT FILES")
	files_title.add_theme_font_size_override("font_size", 12)
	files_column.add_child(files_title)

	_recent_files_box = VBoxContainer.new()
	_recent_files_box.add_theme_constant_override("separation", 4)
	files_column.add_child(_recent_files_box)

	var folders_column := VBoxContainer.new()
	folders_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	folders_column.add_theme_constant_override("separation", 6)
	recent_row.add_child(folders_column)

	var folders_title := Label.new()
	folders_title.text = _t("RECENT FOLDERS")
	folders_title.add_theme_font_size_override("font_size", 12)
	folders_column.add_child(folders_title)

	_recent_workspaces_box = VBoxContainer.new()
	_recent_workspaces_box.add_theme_constant_override("separation", 4)
	folders_column.add_child(_recent_workspaces_box)

	_empty_hint = Label.new()
	_empty_hint.text = _t("New to all of this? Start the four-step tutorial.")
	_empty_hint.add_theme_font_size_override("font_size", 13)
	body.add_child(_empty_hint)

	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", 8)
	body.add_child(footer)

	var open_folder := Button.new()
	open_folder.text = _t("Open a folder…")
	open_folder.tooltip_text = _t("Choose a folder to treat as a project (Ctrl+Shift+O)")
	open_folder.pressed.connect(_on_open_folder)
	footer.add_child(open_folder)

	_beginner_toggle = CheckButton.new()
	_beginner_toggle.text = "Beginner Mode"
	_beginner_toggle.tooltip_text = _t("Larger text, plain-language menus, simpler settings and safety nets. Turn this off any time to see the full interface.")
	_beginner_toggle.toggled.connect(_on_beginner_toggled)
	footer.add_child(_beginner_toggle)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(spacer)

	var tutorial := Button.new()
	tutorial.text = _t("Start the tutorial")
	tutorial.tooltip_text = _t("A four-step walkthrough: open a file, type, run it, see the output (about two minutes)")
	tutorial.pressed.connect(_on_tutorial)
	footer.add_child(tutorial)


func refresh() -> void:
	if editor == null:
		return
	_fill_templates()
	_fill_learn_python()
	_fill_recent_files()
	_fill_recent_workspaces()
	if _empty_hint != null:
		_empty_hint.visible = editor.onboarding == null or !editor.onboarding.is_completed()
	if _beginner_toggle != null:
		# Keep the toggle in sync with the command palette, Preferences and
		# any other path that changes the setting while the screen is closed.
		_beginner_toggle.set_pressed_no_signal(editor.beginner_mode_enabled())


func open(section: String = "") -> void:
	refresh()
	visible = true
	if _open_tween != null and _open_tween.is_valid():
		_open_tween.kill()
	if UI_MOTION.allowed():
		modulate.a = 0.0
		_card.scale = Vector2(0.96, 0.96)
		_open_tween = create_tween()
		_open_tween.set_parallel(true)
		_open_tween.tween_property(self, "modulate:a", 1.0, 0.28).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		_open_tween.tween_property(_card, "scale", Vector2.ONE, 0.32).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	else:
		modulate.a = 1.0
		_card.scale = Vector2.ONE
	grab_focus()
	if section == "templates" and _templates_grid != null and _templates_grid.get_child_count() > 0:
		var first := _templates_grid.get_child(0)
		if first is Control:
			(first as Control).grab_focus()


func close_welcome() -> void:
	visible = false
	if editor != null and editor.welcome != null:
		editor.welcome.mark_welcome_seen()
	if editor != null and editor.documents != null and editor.documents.count() == 0:
		editor.warn("[color=#8bd5ff]TIP[/color]: %s" % _t("Open the welcome screen any time with the Welcome Screen command in the Help menu."))


func _fill_templates() -> void:
	if _templates_grid == null:
		return
	for child in _templates_grid.get_children():
		_templates_grid.remove_child(child)
		child.queue_free()

	var templates: Array = editor.templates.templates() if editor.templates != null else []
	if templates.is_empty():
		var message := Label.new()
		message.text = str(editor.templates.error()) if editor.templates != null else _t("Templates are unavailable.")
		_templates_grid.add_child(message)
		return

	for template in templates:
		var button := Button.new()
		button.custom_minimum_size = Vector2(0, 54)
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.text = "%s  %s" % [str(template.get("icon", "")), str(template.get("label", template.get("id", "Template")))]
		button.tooltip_text = str(template.get("description", ""))
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		var id := str(template.get("id", ""))
		button.pressed.connect(func() -> void: _choose_template(id))
		_templates_grid.add_child(button)


func _fill_learn_python() -> void:
	if _learn_box == null:
		return
	for child in _learn_box.get_children():
		_learn_box.remove_child(child)
		child.queue_free()

	var service = editor.course_service
	if service == null:
		return
	var lessons: Array = service.lessons()
	if lessons.is_empty():
		_learn_box.add_child(_muted_label(_t("The course catalog is unavailable.")))
		return

	for lesson in lessons:
		var id := str(lesson.get("id", ""))
		var number := int(lesson.get("number", 0))
		var done: bool = service.is_done(id)
		var active: bool = editor.course_lesson == id
		var button := Button.new()
		button.custom_minimum_size = Vector2(0, 32)
		button.text = "%d  %s%s" % [number, str(lesson.get("title", id)), "   ✓" if done else ""]
		button.tooltip_text = str(lesson.get("summary", ""))
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.pressed.connect(func() -> void: _start_lesson(id))
		if done:
			button.add_theme_color_override("font_color", Color("#9ece6a"))
		_learn_box.add_child(button)

	var completed: int = service.completed_count()
	var total: int = service.total_lessons()
	if _learn_progress != null:
		_learn_progress.text = _t("%d of %d lessons complete") % [completed, total]
	if completed == total and total > 0:
		_learn_progress.text = _t("All %d lessons complete! Open Help → Python Journey to replay any lesson.") % total


func _start_lesson(id: String) -> void:
	visible = false
	if editor != null and editor.has_method("course_start_lesson"):
		editor.course_start_lesson(id)


func _fill_recent_files() -> void:
	if _recent_files_box == null:
		return
	for child in _recent_files_box.get_children():
		_recent_files_box.remove_child(child)
		child.queue_free()

	var files: Array = editor.welcome.recent_files(MAX_RECENT_FILES) if editor.welcome != null else []
	if files.is_empty():
		_recent_files_box.add_child(_muted_label(_t("No recent files yet.")))
		return
	for path in files:
		var button := Button.new()
		button.text = str(path).get_file()
		button.tooltip_text = str(path)
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.clip_text = true
		button.pressed.connect(func() -> void: _open_recent_file(str(path)))
		_recent_files_box.add_child(button)


func _fill_recent_workspaces() -> void:
	if _recent_workspaces_box == null:
		return
	for child in _recent_workspaces_box.get_children():
		_recent_workspaces_box.remove_child(child)
		child.queue_free()

	var workspaces: Array = []
	if editor.workspace != null:
		for path in editor.workspace.recent_workspaces:
			if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(str(path))):
				workspaces.append(str(path))
			if workspaces.size() >= MAX_RECENT_WORKSPACES:
				break
	if workspaces.is_empty():
		_recent_workspaces_box.add_child(_muted_label(_t("No recent folders yet.")))
		return
	for path in workspaces:
		var button := Button.new()
		button.text = str(path).get_file()
		if button.text.is_empty():
			button.text = str(path)
		button.tooltip_text = str(path)
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.clip_text = true
		button.pressed.connect(func() -> void: _open_recent_folder(str(path)))
		_recent_workspaces_box.add_child(button)


func _muted_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 13)
	label.add_theme_color_override("font_color", LuaSingleton.gui.font_color.darkened(0.35))
	return label


func _choose_template(id: String) -> void:
	visible = false
	if editor != null:
		if editor.welcome != null:
			editor.welcome.mark_welcome_seen()
		editor.create_from_template(id)


func _open_recent_file(path: String) -> void:
	visible = false
	if editor != null:
		if editor.welcome != null:
			editor.welcome.mark_welcome_seen()
		editor.open_file(path)


func _open_recent_folder(path: String) -> void:
	visible = false
	if editor != null:
		if editor.welcome != null:
			editor.welcome.mark_welcome_seen()
		editor.set_workspace(path)


func _on_open_folder() -> void:
	visible = false
	if editor != null:
		if editor.welcome != null:
			editor.welcome.mark_welcome_seen()
		editor.open_folder_dialog()


func _on_tutorial() -> void:
	visible = false
	if editor != null:
		if editor.welcome != null:
			editor.welcome.mark_welcome_seen()
		editor.start_onboarding(true)


func _on_beginner_toggled(pressed: bool) -> void:
	if editor != null and editor.has_method("set_beginner_mode"):
		editor.set_beginner_mode(pressed)


func restyle() -> void:
	if _card == null or LuaSingleton.gui == null:
		return
	var panel := StyleBoxFlat.new()
	panel.bg_color = LuaSingleton.gui.background_color.lightened(0.04)
	panel.border_color = LuaSingleton.gui.selection_color
	panel.border_width_left = 1
	panel.border_width_top = 1
	panel.border_width_right = 1
	panel.border_width_bottom = 1
	panel.corner_radius_top_left = 8
	panel.corner_radius_top_right = 8
	panel.corner_radius_bottom_left = 8
	panel.corner_radius_bottom_right = 8
	panel.content_margin_left = 26
	panel.content_margin_right = 26
	panel.content_margin_top = 22
	panel.content_margin_bottom = 22
	_card.add_theme_stylebox_override("panel", panel)

	var text_color: Color = LuaSingleton.gui.font_color
	for label in _all_labels(self):
		if label.get_theme_color("font_color") == Color(0, 0, 0, 0):
			label.add_theme_color_override("font_color", text_color)
	for button in _all_buttons(self):
		button.add_theme_color_override("font_color", text_color)
		button.add_theme_color_override("font_hover_color", LuaSingleton.gui.selection_color)


func _all_labels(node: Node) -> Array:
	var out: Array = []
	for child in node.get_children():
		if child is Label:
			out.append(child)
		out.append_array(_all_labels(child))
	return out


func _all_buttons(node: Node) -> Array:
	var out: Array = []
	for child in node.get_children():
		if child is Button:
			out.append(child)
		out.append_array(_all_buttons(child))
	return out
