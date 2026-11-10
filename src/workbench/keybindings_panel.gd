extends PanelContainer

## Keyboard shortcut editor (HUD).
##
## Every row comes from CommandRegistry and every shortcut comes from
## KeybindingService, so this page can never drift from the menus, the palette
## or the toolbar. Clicking a shortcut captures the next key combination,
## Delete/Backspace unbinds it, and Enter accepts a detected conflict.

const KeyChordScript = preload("res://src/platform/key_chord.gd")

const PANEL_WIDTH := 780.0
const PANEL_HEIGHT := 520.0
const PANEL_TOP := 68.0
const CATEGORY_WIDTH := 104.0
const SHORTCUT_WIDTH := 180.0

const CATEGORY_ORDER := [
	"File", "Edit", "View", "Workspace", "Terminal", "Run",
	"Preferences", "Help", "Other",
]

var editor: FileManager

var filter_edit: LineEdit
var status: Label
var scroll: ScrollContainer
var rows_box: VBoxContainer
var reset_all_button: Button

var _rows: Dictionary = {}
var _capturing_id: String = ""
var _capture_button: Button = null
var _pending_conflict: Dictionary = {}


func _ready() -> void:
	editor = _find_editor()

	theme = LuaSingleton.editor_theme
	visible = false
	modulate.a = 0.0

	set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	offset_left = -PANEL_WIDTH * 0.5
	offset_right = PANEL_WIDTH * 0.5
	offset_top = PANEL_TOP
	offset_bottom = PANEL_TOP + PANEL_HEIGHT

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	add_child(box)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	box.add_child(header)

	var title := Label.new()
	title.text = "Keyboard Shortcuts"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)

	reset_all_button = Button.new()
	reset_all_button.text = "Reset all"
	reset_all_button.tooltip_text = "Restore every shortcut to its default."
	reset_all_button.pressed.connect(_reset_all)
	header.add_child(reset_all_button)

	var close_button := Button.new()
	close_button.text = "✕"
	close_button.tooltip_text = "Close (Esc)"
	close_button.pressed.connect(close_self)
	header.add_child(close_button)

	filter_edit = LineEdit.new()
	filter_edit.placeholder_text = "Filter commands..."
	filter_edit.clear_button_enabled = true
	filter_edit.text_changed.connect(func(_text: String) -> void: _rebuild())
	box.add_child(filter_edit)

	status = Label.new()
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.custom_minimum_size = Vector2(0, 20)
	box.add_child(status)

	scroll = ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)

	rows_box = VBoxContainer.new()
	rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows_box.add_theme_constant_override("separation", 2)
	scroll.add_child(rows_box)

	LuaSingleton.on_theme_load.connect(_on_theme_load)
	LuaSingleton.on_settings_change.connect(restyle)

	if editor != null and editor.keybindings != null:
		editor.keybindings.changed.connect(_on_bindings_changed)

	restyle()
	_show_conflicts()


func _find_editor() -> FileManager:
	var node := get_parent()
	while node != null and !(node is FileManager):
		node = node.get_parent()
	return node


# ── OPEN / CLOSE ────────────────────────────────────────────────────────────

func on_open() -> void:
	_cancel_capture(false)
	if editor != null and editor.builtin_commands != null:
		# Themes and recent workspaces may have changed since the last open.
		editor.builtin_commands.refresh_dynamic()
	_rebuild()
	_show_conflicts()
	filter_edit.grab_focus()


func on_close() -> void:
	_cancel_capture(false)
	_pending_conflict.clear()


func close_self() -> void:
	if editor != null and editor.overlays != null:
		editor.overlays.close(self)


# ── ROWS ────────────────────────────────────────────────────────────────────

func _rebuild() -> void:
	if rows_box == null or editor == null or editor.commands == null:
		return

	_cancel_capture(false)
	_rows.clear()
	for child in rows_box.get_children():
		rows_box.remove_child(child)
		child.queue_free()

	var query := filter_edit.text.strip_edges().to_lower()
	var commands: Array = []
	for command in editor.commands.all():
		if bool(command.get("hidden", false)):
			continue
		if !_matches(command, query):
			continue
		commands.append(command)

	commands.sort_custom(_sort_commands)

	for command in commands:
		rows_box.add_child(_make_row(command))

	if commands.is_empty():
		var empty := Label.new()
		empty.text = "No matching commands."
		empty.add_theme_color_override("font_color", LuaSingleton.gui.font_color.darkened(0.25))
		rows_box.add_child(empty)

	reset_all_button.disabled = editor.keybindings.overrides().is_empty()


func _matches(command: Dictionary, query: String) -> bool:
	if query.is_empty():
		return true
	var id := str(command.get("id", ""))
	var label := str(command.get("label", ""))
	var category := str(command.get("category", ""))
	var shortcut := str(command.get("shortcut", ""))
	return (
		label.to_lower().contains(query)
		or category.to_lower().contains(query)
		or id.to_lower().contains(query)
		or shortcut.to_lower().contains(query)
	)


func _sort_commands(a: Dictionary, b: Dictionary) -> bool:
	var category_a := str(a.get("category", "Other"))
	var category_b := str(b.get("category", "Other"))
	var rank_a := CATEGORY_ORDER.find(category_a)
	var rank_b := CATEGORY_ORDER.find(category_b)
	if rank_a == -1:
		rank_a = CATEGORY_ORDER.size()
	if rank_b == -1:
		rank_b = CATEGORY_ORDER.size()
	if rank_a != rank_b:
		return rank_a < rank_b
	if category_a != category_b:
		return category_a.naturalnocasecmp_to(category_b) < 0
	return str(a.get("label", "")).naturalnocasecmp_to(str(b.get("label", ""))) < 0


func _make_row(command: Dictionary) -> Control:
	var command_id := str(command.get("id", ""))

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var category := Label.new()
	category.text = TranslationServer.translate(str(command.get("category", "Other")))
	category.custom_minimum_size = Vector2(CATEGORY_WIDTH, 0)
	category.add_theme_font_size_override("font_size", 12)
	category.add_theme_color_override("font_color", LuaSingleton.keywords.get("comments", LuaSingleton.gui.font_color))
	row.add_child(category)

	var label := Label.new()
	label.text = str(command.get("label", command_id))
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.clip_text = true
	label.tooltip_text = command_id
	label.add_theme_color_override("font_color", LuaSingleton.gui.font_color)
	row.add_child(label)

	var shortcut := Button.new()
	shortcut.custom_minimum_size = Vector2(SHORTCUT_WIDTH, 0)
	shortcut.text = _binding_text(command_id)
	shortcut.tooltip_text = _binding_tooltip(command_id)
	shortcut.pressed.connect(_start_capture.bind(command_id, shortcut))
	row.add_child(shortcut)

	var reset := Button.new()
	reset.text = "↺"
	reset.custom_minimum_size = Vector2(30, 0)
	reset.tooltip_text = "Reset to the default shortcut."
	reset.disabled = !editor.keybindings.has_override(command_id)
	reset.pressed.connect(_reset_one.bind(command_id))
	row.add_child(reset)

	_rows[command_id] = {"button": shortcut, "reset": reset}
	return row


func _binding_text(command_id: String) -> String:
	var text: String = str(editor.keybindings.binding_for(command_id))
	return text if !text.is_empty() else "Unbound"


func _binding_tooltip(command_id: String) -> String:
	var default_text: String = str(editor.keybindings.default_for(command_id))
	if default_text.is_empty():
		return "Click, then press a shortcut. Delete unbinds it."
	return "Click, then press a shortcut. Default: " + default_text


# ── CAPTURE ─────────────────────────────────────────────────────────────────

func _start_capture(command_id: String, button: Button) -> void:
	_cancel_capture(false)
	_pending_conflict.clear()

	_capturing_id = command_id
	_capture_button = button
	button.text = "Press keys..."

	var command: Dictionary = editor.commands.get_command(command_id)
	_set_status(
		"Press a shortcut for %s. Esc cancels, Delete unbinds." % str(command.get("label", command_id)),
		"capture"
	)


func _cancel_capture(show_default_status: bool = true) -> void:
	if !_capturing_id.is_empty() and is_instance_valid(_capture_button):
		_capture_button.text = _binding_text(_capturing_id)

	_capturing_id = ""
	_capture_button = null
	_pending_conflict.clear()

	if show_default_status:
		_show_conflicts()


func _input(event: InputEvent) -> void:
	if !visible or _capturing_id.is_empty():
		return
	if !(event is InputEventKey):
		return

	var key_event: InputEventKey = event
	if !key_event.pressed or key_event.echo:
		return

	# Capture owns the keyboard while it is active: the terminal and the code
	# editor must not also see the combination being recorded.
	get_viewport().set_input_as_handled()

	var code := int(key_event.physical_keycode)
	if code == 0:
		code = int(key_event.keycode)

	if KeyChordScript.is_modifier_key(code):
		_set_status("Modifiers: %s — now press a key." % _modifier_text(key_event), "capture")
		return

	if code == KEY_ESCAPE:
		_cancel_capture()
		return

	if code == KEY_DELETE or code == KEY_BACKSPACE:
		_assign("")
		return

	if code == KEY_ENTER and !_pending_conflict.is_empty():
		_assign(str(_pending_conflict.get("text", "")), true)
		return

	var chord := KeyChordScript.from_event(key_event)
	if !chord.get("ok", false):
		_set_status(str(chord.get("error", "That key cannot be used.")), "error")
		return

	_assign(str(chord.get("text", "")))


func _assign(text: String, force: bool = false) -> void:
	if _capturing_id.is_empty():
		return

	var command_id := _capturing_id
	var result: Dictionary = editor.keybindings.set_binding(command_id, text, force)
	if !result.get("ok", false):
		var conflicts: Array = result.get("conflicts", [])
		if !conflicts.is_empty() and !force:
			_pending_conflict = {"id": command_id, "text": text, "conflicts": conflicts}
			_set_status(
				str(result.get("error", "Shortcut conflict.")) + " Press Enter to use it anyway, Esc to cancel.",
				"error"
			)
			return
		_set_status(str(result.get("error", "Could not save the shortcut.")), "error")
		return

	_capturing_id = ""
	_capture_button = null
	_pending_conflict.clear()
	_rebuild()
	_set_status("Shortcut updated.", "info")
	filter_edit.grab_focus()


func _modifier_text(event: InputEventKey) -> String:
	var parts: Array[String] = []
	if event.ctrl_pressed:
		parts.append("Ctrl")
	if event.alt_pressed:
		parts.append("Alt")
	if event.shift_pressed:
		parts.append("Shift")
	if event.meta_pressed:
		parts.append("Meta")
	return "+".join(parts) if !parts.is_empty() else "none"


# ── RESET ───────────────────────────────────────────────────────────────────

func _reset_one(command_id: String) -> void:
	_cancel_capture(false)
	var result: Dictionary = editor.keybindings.reset_binding(command_id)
	if result.get("ok", false):
		_set_status("Shortcut reset to its default.", "info")
	else:
		_set_status(str(result.get("error", "Could not reset the shortcut.")), "error")


func _reset_all() -> void:
	_cancel_capture(false)
	editor.keybindings.reset_all()
	_rebuild()
	_set_status("Every shortcut was reset to its default.", "info")


# ── STATUS / THEME ──────────────────────────────────────────────────────────

func _show_conflicts() -> void:
	if editor == null or editor.keybindings == null:
		return

	var conflicts: Array = editor.keybindings.conflicts()
	if conflicts.is_empty():
		_set_status("Click a shortcut to rebind it. Only global, editor and terminal shortcuts can be bound.", "info")
		return

	var parts: Array[String] = []
	for conflict in conflicts:
		var ids: Array = conflict.get("commands", [])
		var labels: Array[String] = []
		for id in ids:
			var command: Dictionary = editor.commands.get_command(str(id))
			labels.append(str(command.get("label", id)))
		parts.append("%s → %s" % [str(conflict.get("chord", "")), ", ".join(labels)])

	_set_status("Conflicts: " + " | ".join(parts), "error")


func _set_status(text: String, kind: String) -> void:
	if status == null:
		return

	status.text = text
	var color: Color = LuaSingleton.keywords.get("comments", LuaSingleton.gui.font_color)
	if kind == "error":
		color = Color(1.0, 0.46, 0.46)
	elif kind == "capture":
		color = LuaSingleton.gui.selection_color
	status.add_theme_color_override("font_color", color)


func _on_bindings_changed() -> void:
	if _capturing_id.is_empty() and visible:
		_rebuild()
		_show_conflicts()


func _on_theme_load() -> void:
	restyle()
	if visible:
		_rebuild()
		_show_conflicts()


func restyle() -> void:
	theme = LuaSingleton.editor_theme

	var panel := StyleBoxFlat.new()
	panel.bg_color = LuaSingleton.gui.background_color
	panel.set_content_margin_all(10)
	panel.content_margin_left = 14
	panel.content_margin_right = 14
	panel.corner_radius_top_left = 4
	panel.corner_radius_top_right = 4
	panel.corner_radius_bottom_left = 4
	panel.corner_radius_bottom_right = 4
	panel.border_width_bottom = 1
	panel.border_color = LuaSingleton.gui.current_line_color
	add_theme_stylebox_override("panel", panel)

	if scroll != null:
		scroll.add_theme_stylebox_override("panel", StyleBoxEmpty.new())

	if status != null and _capturing_id.is_empty():
		_show_conflicts()
