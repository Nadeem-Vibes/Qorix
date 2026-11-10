extends PanelContainer

const UI_MOTION = preload("res://src/platform/ui_motion.gd")

## Left-dock file explorer.
##
## The tree is intentionally lazy: a directory is only listed when it is
## actually expanded, and a full workspace never has to be turned into TreeItems
## up front. Godot's Tree has no `item_expanded` signal, so expanded-but-unloaded
## folders are noticed by a small polling pass (0.12s) instead of eager loads.
##
## This panel is a dock, not an overlay: it stays open while the code is edited,
## the camera shifts its focus point by half the dock width, and the terminal
## dock shortens the tree's bottom edge the same way it shortens the minimap.

const PANEL_WIDTH := 320.0
const TOP_OFFSET := 62.0
const POLL_INTERVAL := 0.12

const FOLDER_GLYPH := ""
const FOLDER_OPEN_GLYPH := "󰕌"
const REFRESH_GLYPH := "󰑓"
const CLOSE_GLYPH := "✕"

const MENU_NEW_FILE := 0
const MENU_NEW_FOLDER := 1
const MENU_RENAME := 2
const MENU_DELETE := 3
const MENU_REVEAL := 4
const MENU_COPY_PATH := 5
const MENU_OPEN_TERMINAL := 6

var editor: FileManager

var header_label: Label
var open_button: Button
var refresh_button: Button
var close_button: Button
var index_progress: ProgressBar
var tree: Tree
var menu: PopupMenu

var name_dialog: ConfirmationDialog
var name_label: Label
var name_edit: LineEdit
var delete_dialog: ConfirmationDialog

var _root: TreeItem
var _dir_items: Dictionary = {}      # rel -> TreeItem (directories only)
var _loaded_dirs: Dictionary = {}    # rel -> true once children were listed
var _expanded_dirs: Dictionary = {}  # rel -> true (survives refreshes)
var _context_rel: String = ""
var _context_path: String = ""
var _context_is_dir: bool = false
var _name_mode: String = ""          # "new_file" / "new_folder" / "rename"
var _name_target_rel: String = ""
var _poll_accum: float = 0.0
var _tween: Tween
var _animating: bool = false


var _base_position := Vector2.ZERO


func _ready() -> void:
	editor = _find_editor()
	if editor != null:
		editor.file_tree = self

	theme = LuaSingleton.editor_theme
	visible = false
	modulate.a = 0.0

	set_anchors_and_offsets_preset(Control.PRESET_LEFT_WIDE)
	offset_top = TOP_OFFSET
	offset_right = PANEL_WIDTH
	offset_bottom = 0.0
	_base_position = position

	var box = VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	add_child(box)

	var header = HBoxContainer.new()
	header.add_theme_constant_override("separation", 4)
	box.add_child(header)

	header_label = Label.new()
	header_label.text = "Explorer"
	header_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_label.clip_text = true
	header.add_child(header_label)

	open_button = Button.new()
	open_button.text = FOLDER_GLYPH
	open_button.tooltip_text = "Open folder (Ctrl+Shift+O)"
	open_button.focus_mode = Control.FOCUS_NONE
	open_button.pressed.connect(func() -> void: editor.open_folder_dialog())
	header.add_child(open_button)

	refresh_button = Button.new()
	refresh_button.text = REFRESH_GLYPH
	refresh_button.tooltip_text = "Refresh file tree"
	refresh_button.focus_mode = Control.FOCUS_NONE
	refresh_button.pressed.connect(refresh_all)
	header.add_child(refresh_button)

	close_button = Button.new()
	close_button.text = CLOSE_GLYPH
	close_button.tooltip_text = "Close explorer (Ctrl+Shift+E)"
	close_button.focus_mode = Control.FOCUS_NONE
	close_button.pressed.connect(close)
	header.add_child(close_button)

	index_progress = ProgressBar.new()
	index_progress.custom_minimum_size = Vector2(70, 4)
	index_progress.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	index_progress.show_percentage = false
	index_progress.visible = false
	header.add_child(index_progress)

	tree = Tree.new()
	tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tree.hide_root = true
	tree.columns = 2
	tree.column_titles_visible = false
	tree.select_mode = Tree.SELECT_ROW
	tree.allow_rmb_select = true
	tree.allow_reselect = true
	tree.focus_mode = Control.FOCUS_ALL
	tree.set_column_expand(0, false)
	tree.set_column_custom_minimum_width(0, 42)
	tree.set_column_expand(1, true)
	tree.set_column_clip_content(1, true)
	tree.item_activated.connect(_on_item_activated)
	tree.item_mouse_selected.connect(_on_item_mouse_selected)
	box.add_child(tree)

	menu = PopupMenu.new()
	menu.add_item("New File...", MENU_NEW_FILE)
	menu.add_item("New Folder...", MENU_NEW_FOLDER)
	menu.add_separator()
	menu.add_item("Rename...", MENU_RENAME)
	menu.add_item("Delete", MENU_DELETE)
	menu.add_separator()
	menu.add_item("Reveal in File Manager", MENU_REVEAL)
	menu.add_item("Copy Path", MENU_COPY_PATH)
	menu.add_item("Open in Terminal", MENU_OPEN_TERMINAL)
	menu.id_pressed.connect(_on_menu_id)
	add_child(menu)

	_build_dialogs()

	LuaSingleton.on_theme_load.connect(restyle)
	LuaSingleton.on_settings_change.connect(restyle)
	restyle()

	if editor != null:
		editor.workspace.root_changed.connect(_on_workspace_root_changed)
		editor.workspace.index_started.connect(_on_index_started)
		editor.workspace.index_progress.connect(_on_index_progress)
		editor.workspace.index_finished.connect(_on_index_finished)

	refresh_all()


func _find_editor() -> FileManager:
	var node = get_parent()
	while node != null and !(node is FileManager):
		node = node.get_parent()
	return node


func _build_dialogs() -> void:
	name_dialog = ConfirmationDialog.new()
	name_dialog.title = "Name"
	name_dialog.ok_button_text = "OK"
	name_dialog.get_label().hide()
	name_dialog.min_size = Vector2i(460, 170)

	var name_box = VBoxContainer.new()
	name_box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	name_box.offset_left = 14
	name_box.offset_top = 14
	name_box.offset_right = -14
	name_box.offset_bottom = -52
	name_dialog.add_child(name_box)

	name_label = Label.new()
	name_label.text = "Name"
	name_box.add_child(name_label)

	name_edit = LineEdit.new()
	name_edit.custom_minimum_size = Vector2(0, 30)
	name_box.add_child(name_edit)

	name_dialog.register_text_enter(name_edit)
	name_dialog.confirmed.connect(_on_name_confirmed)
	add_child(name_dialog)

	delete_dialog = ConfirmationDialog.new()
	delete_dialog.title = "Delete"
	delete_dialog.ok_button_text = "Delete"
	delete_dialog.confirmed.connect(_on_delete_confirmed)
	add_child(delete_dialog)


# ── DOCK LIFECYCLE ──────────────────────────────────────────────────────────

func is_open() -> bool:
	return visible


func toggle() -> void:
	if visible:
		close()
	else:
		open()


func open() -> void:
	if visible:
		return

	if editor != null:
		editor.open_left_dock(self)
	refresh_all()

	visible = true
	modulate.a = 0.0
	position = _base_position + Vector2(10, 0)
	_animating = true
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
	_tween.set_parallel(true)
	_tween.tween_property(self, "modulate:a", 1.0, UI_MOTION.duration())
	_tween.tween_property(self, "position", _base_position, UI_MOTION.duration()).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_tween.chain().tween_callback(func() -> void: _animating = false)

	if editor != null:
		editor.update_left_inset()


func close() -> void:
	if !visible or _animating:
		return

	_animating = true
	modulate.a = 1.0
	position = _base_position
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
	_tween.set_parallel(true)
	_tween.tween_property(self, "modulate:a", 0.0, UI_MOTION.duration())
	_tween.tween_property(self, "position", _base_position + Vector2(10, 0), UI_MOTION.duration()).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	_tween.chain().tween_callback(func() -> void:
		visible = false
		_animating = false
		position = _base_position
		if editor != null:
			editor.update_left_inset()
	)


## Used when the search dock takes this panel's place: no animation, the other
## panel fades in over the same rect.
func hide_now() -> void:
	visible = false
	modulate.a = 0.0
	position = _base_position
	_animating = false
	if _tween != null and _tween.is_valid():
		_tween.kill()
	if editor != null:
		editor.update_left_inset()


## The terminal drawer covers the full window width; shorten the tree so its
## last rows stay visible above it.
func attach_terminal(terminal: Control) -> void:
	attach_bottom_dock(terminal)


func attach_bottom_dock(dock: Control) -> void:
	if dock == null:
		return
	dock.visibility_changed.connect(_apply_terminal_inset)
	_apply_terminal_inset()


func _apply_terminal_inset() -> void:
	var top := 0.0
	if editor != null and editor.has_method("bottom_dock_top"):
		top = float(editor.bottom_dock_top())
	offset_bottom = minf(0.0, top)


func _process(delta: float) -> void:
	if !visible:
		return

	_poll_accum += delta
	if _poll_accum < POLL_INTERVAL:
		return
	_poll_accum = 0.0
	_sync_expanded_dirs()


# ── TREE BUILDING ───────────────────────────────────────────────────────────

func refresh_all() -> void:
	if tree == null:
		return

	tree.clear()
	_dir_items.clear()
	_loaded_dirs.clear()
	_root = tree.create_item()

	if editor == null or !editor.workspace.has_workspace():
		header_label.text = "Explorer"
		var placeholder := tree.create_item(_root)
		placeholder.set_text(0, FOLDER_GLYPH)
		placeholder.set_text(1, "Open a folder...")
		placeholder.set_metadata(0, {"action": "open_folder"})
		placeholder.set_custom_color(0, _folder_color())
		placeholder.set_custom_color(1, LuaSingleton.keywords.comments)
		return

	header_label.text = editor.workspace.workspace_name()
	header_label.tooltip_text = editor.workspace.root
	_populate(_root, "", 0)


## Fills `parent` with the children of `rel_dir`. Directories previously
## expanded stay expanded (and load their children) after a refresh.
func _populate(parent: TreeItem, rel_dir: String, depth: int) -> void:
	var children: Array = editor.workspace.list_children(rel_dir)
	_loaded_dirs[rel_dir] = true

	for child in children:
		var rel: String = str(child.get("rel", ""))
		var is_dir := bool(child.get("is_dir", false))
		var name := str(child.get("name", ""))
		var path := str(child.get("path", ""))

		var item := tree.create_item(parent)
		item.set_metadata(0, {
			"path": path,
			"rel": rel,
			"is_dir": is_dir,
		})
		item.set_text(1, name)
		item.set_tooltip_text(1, rel)

		if is_dir:
			item.set_text(0, FOLDER_GLYPH)
			item.set_custom_color(0, _folder_color())
			_dir_items[rel] = item
		else:
			var data: Dictionary = Icons.get_icon_data(str(child.get("ext", "")))
			item.set_text(0, str(data.get("icon", "󰈔")))
			item.set_custom_color(0, Color.from_string(str(data.get("color", "#ffffff")), Color.WHITE))

		if depth >= 64:
			continue

		if is_dir and _expanded_dirs.has(rel):
			item.set_collapsed(false)
			_populate(item, rel, depth + 1)
		else:
			item.set_collapsed(true)


## Notices directories the user just expanded (Tree has no expansion signal).
func _sync_expanded_dirs() -> void:
	for rel in _dir_items.keys():
		var item = _dir_items[rel]
		if !is_instance_valid(item):
			_dir_items.erase(rel)
			continue

		if item.is_collapsed():
			_expanded_dirs.erase(rel)
			continue

		_expanded_dirs[rel] = true
		if !_loaded_dirs.has(rel):
			_load_children(rel, item)
			_loaded_dirs[rel] = true


func _load_children(rel: String, item: TreeItem) -> void:
	for child in item.get_children():
		child.free()
	_populate(item, rel, _depth_for_rel(rel))


## Deferred first population for a directory the user just expanded. The item
## can disappear (refresh, workspace switch) before this runs, so validate it.
func _load_children_deferred(rel: String, item: TreeItem) -> void:
	if !is_instance_valid(item) or item.is_collapsed():
		return
	if _loaded_dirs.has(rel):
		return
	_load_children(rel, item)
	_loaded_dirs[rel] = true


func _depth_for_rel(rel: String) -> int:
	return rel.split("/", false).size()


func _on_workspace_root_changed(_root_path: String) -> void:
	_expanded_dirs.clear()
	refresh_all()


func _on_index_started(root_path: String) -> void:
	if editor != null and editor.workspace.has_workspace():
		header_label.text = "Indexing %s..." % root_path.get_file()
	if index_progress != null:
		index_progress.value = 0.0
		index_progress.visible = true
		_fade_tree(0.55)


func _on_index_progress(files_found: int, _dirs_scanned: int) -> void:
	if editor != null and editor.workspace.building:
		header_label.text = "Indexing... %d files" % files_found
	if index_progress != null:
		index_progress.value = minf(float(files_found), 1000.0) / 10.0


func _on_index_finished(_files: int, _truncated: bool) -> void:
	# The tree lists directories directly, so a finished index only matters for
	# the header/placeholder state. Keep expanded directories intact.
	refresh_all()
	if index_progress != null:
		index_progress.value = 100.0
		index_progress.visible = false
	_fade_tree(1.0)


func _fade_tree(target: float) -> void:
	if !visible or !UI_MOTION.allowed():
		modulate.a = target
		return
	var tween := create_tween()
	tween.tween_property(self, "modulate:a", target, UI_MOTION.duration(0.18))


# ── ACTIVATION / CONTEXT MENU ───────────────────────────────────────────────

func _metadata(item: TreeItem) -> Dictionary:
	if item == null:
		return {}
	var value = item.get_metadata(0)
	return value if value is Dictionary else {}


func _on_item_activated() -> void:
	var item := tree.get_selected()
	var meta := _metadata(item)
	if meta.is_empty():
		return

	if str(meta.get("action", "")) == "open_folder":
		editor.open_folder_dialog()
		return

	var path := str(meta.get("path", ""))
	var rel := str(meta.get("rel", ""))

	if bool(meta.get("is_dir", false)):
		var open := !item.is_collapsed()
		item.set_collapsed(open)
		if !open:
			_expanded_dirs[rel] = true
			if !_loaded_dirs.has(rel):
				# Tree::create_item() is forbidden while the Tree is emitting
				# item_mouse_selected/item_activated. Defer the first population
				# until the input event has finished.
				call_deferred("_load_children_deferred", rel, item)
		else:
			_expanded_dirs.erase(rel)
		return

	editor.open_file(path)


func _on_item_mouse_selected(_position: Vector2, button: int) -> void:
	var item := tree.get_selected()
	var meta := _metadata(item)
	if meta.is_empty():
		return

	if str(meta.get("action", "")) == "open_folder":
		return

	if button == MOUSE_BUTTON_LEFT:
		if bool(meta.get("is_dir", false)):
			_on_item_activated()
		return

	if button != MOUSE_BUTTON_RIGHT:
		return

	_context_rel = str(meta.get("rel", ""))
	_context_path = str(meta.get("path", ""))
	_context_is_dir = bool(meta.get("is_dir", false))
	_show_context_menu()


func _show_context_menu() -> void:
	if _context_path.is_empty():
		return

	menu.set_item_disabled(menu.get_item_index(MENU_OPEN_TERMINAL), editor.terminal == null)
	menu.position = Vector2i(get_viewport().get_mouse_position())
	menu.reset_size()
	menu.popup()


func _on_menu_id(id: int) -> void:
	match id:
		MENU_NEW_FILE:
			_ask_name("new_file", _context_rel, _context_is_dir, "untitled.txt")
		MENU_NEW_FOLDER:
			_ask_name("new_folder", _context_rel, _context_is_dir, "new_folder")
		MENU_RENAME:
			_ask_name("rename", _context_rel, _context_is_dir, _context_path.get_file())
		MENU_DELETE:
			_ask_delete()
		MENU_REVEAL:
			_reveal()
		MENU_COPY_PATH:
			_copy_path()
		MENU_OPEN_TERMINAL:
			_open_terminal_here()


# ── FILE OPERATIONS ─────────────────────────────────────────────────────────

func _ask_name(mode: String, rel: String, is_dir: bool, suggestion: String) -> void:
	_name_mode = mode
	_name_target_rel = rel
	if mode == "rename":
		name_label.text = "New name for \"%s\":" % rel.get_file()
		name_dialog.title = "Rename"
	elif mode == "new_folder":
		name_label.text = "Folder name in \"%s\":" % _parent_label(is_dir, rel)
		name_dialog.title = "New Folder"
	else:
		name_label.text = "File name in \"%s\":" % _parent_label(is_dir, rel)
		name_dialog.title = "New File"

	name_edit.text = suggestion
	name_dialog.popup_centered()
	name_edit.grab_focus()
	name_edit.select_all()


func _parent_label(is_dir: bool, rel: String) -> String:
	if is_dir:
		return rel if !rel.is_empty() else editor.workspace.workspace_name()
	return rel.get_base_dir() if !rel.is_empty() else editor.workspace.workspace_name()


func _parent_rel(is_dir: bool, rel: String) -> String:
	if is_dir:
		return rel
	return rel.get_base_dir()


func _on_name_confirmed() -> void:
	var value := name_edit.text.strip_edges()
	if value.is_empty():
		return
	if value.contains("/") or value.contains("\\"):
		editor.warn("[color=yellow]WARNING[/color]: Names cannot contain slashes.")
		return

	var mode := _name_mode
	_name_mode = ""

	if !editor.workspace.has_workspace():
		return

	var rel_dir := _parent_rel(_context_is_dir, _name_target_rel)
	var target_rel := value if rel_dir.is_empty() else rel_dir.path_join(value)
	var target_path: String = str(editor.workspace.root).path_join(target_rel)

	match mode:
		"new_file":
			_create_file(target_path, rel_dir)
		"new_folder":
			_create_folder(target_path, rel_dir)
		"rename":
			_rename(_context_path, target_path)


func _create_file(path: String, rel_dir: String) -> void:
	if FileAccess.file_exists(path) or DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(path)):
		editor.warn("[color=yellow]WARNING[/color]: \"%s\" already exists." % path.get_file())
		return

	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		editor.warn("[color=red]ERROR[/color]: Could not create \"%s\"." % path)
		return
	file.store_string("")
	file = null

	editor.workspace.note_created(path)
	_expand_dir(rel_dir)
	refresh_all()
	editor.open_file(path)


func _create_folder(path: String, rel_dir: String) -> void:
	if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(path)):
		editor.warn("[color=yellow]WARNING[/color]: \"%s\" already exists." % path.get_file())
		return

	if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path)) != OK:
		editor.warn("[color=red]ERROR[/color]: Could not create \"%s\"." % path)
		return

	editor.workspace.note_created(path)
	_expand_dir(rel_dir)
	refresh_all()


func _rename(old_path: String, new_path: String) -> void:
	if editor.workspace.is_inside_workspace(new_path):
		if FileAccess.file_exists(new_path) or DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(new_path)):
			editor.warn("[color=yellow]WARNING[/color]: \"%s\" already exists." % new_path.get_file())
			return

	var error := DirAccess.rename_absolute(
		ProjectSettings.globalize_path(old_path),
		ProjectSettings.globalize_path(new_path)
	)
	if error != OK:
		editor.warn("[color=red]ERROR[/color]: Could not rename \"%s\" (error %d)." % [old_path.get_file(), error])
		return

	editor.workspace.note_renamed(old_path, new_path)
	editor.note_path_renamed(old_path, new_path)
	refresh_all()


func _ask_delete() -> void:
	if _context_path.is_empty():
		return
	var suffix := " and everything inside it" if _context_is_dir else ""
	delete_dialog.dialog_text = "Delete \"%s\"%s?\n\nThis cannot be undone." % [_context_rel, suffix]
	delete_dialog.popup_centered()


func _on_delete_confirmed() -> void:
	var path := _context_path
	if path.is_empty():
		return

	var error := _delete_path(path)
	if error != OK:
		editor.warn("[color=red]ERROR[/color]: Could not delete \"%s\" (error %d)." % [path.get_file(), error])
		return

	editor.workspace.note_deleted(path)
	editor.note_path_deleted(path)
	_expanded_dirs.erase(_context_rel)
	refresh_all()


func _delete_path(path: String) -> Error:
	var global := ProjectSettings.globalize_path(path)
	if !DirAccess.dir_exists_absolute(global):
		return DirAccess.remove_absolute(global)

	var dir := DirAccess.open(global)
	if dir == null:
		return DirAccess.get_open_error()

	for name in dir.get_files():
		var error := DirAccess.remove_absolute(global.path_join(name))
		if error != OK:
			return error
	for name in dir.get_directories():
		var error := _delete_path(path.path_join(name))
		if error != OK:
			return error

	return DirAccess.remove_absolute(global)


func _reveal() -> void:
	var global := ProjectSettings.globalize_path(_context_path)
	if OS.has_method("shell_show_in_file_manager"):
		OS.shell_show_in_file_manager(global)
	else:
		OS.shell_open(global.get_base_dir())


func _copy_path() -> void:
	var path := _context_path.replace("/", "\\") if OS.get_name() == "Windows" else _context_path
	DisplayServer.clipboard_set(path)


func _open_terminal_here() -> void:
	if editor.terminal == null:
		return
	var folder := _context_path if _context_is_dir else _context_path.get_base_dir()
	if OS.get_name() == "Windows":
		var quoted := "\"%s\"" % folder.replace("/", "\\")
		editor.terminal.open()
		editor.terminal.run_command("cd /d " + quoted)
	else:
		editor.terminal.open()
		editor.terminal.run_command("cd \"%s\"" % folder)


func _expand_dir(rel: String) -> void:
	if rel.is_empty():
		return

	# Expanding the whole ancestry keeps a newly created file visible after
	# refresh_all() rebuilds the tree from the root.
	var current := ""
	for part in rel.split("/", false):
		current = part if current.is_empty() else current.path_join(part)
		_expanded_dirs[current] = true


# ── THEME ───────────────────────────────────────────────────────────────────

func restyle() -> void:
	var panel = StyleBoxFlat.new()
	panel.bg_color = LuaSingleton.gui.background_color
	panel.set_content_margin_all(6)
	panel.content_margin_left = 8
	panel.content_margin_right = 8
	panel.corner_radius_top_right = 4
	panel.corner_radius_bottom_right = 4
	panel.border_width_right = 1
	panel.border_color = LuaSingleton.gui.current_line_color
	add_theme_stylebox_override("panel", panel)

	var font: Color = LuaSingleton.gui.font_color
	header_label.add_theme_color_override("font_color", font)

	tree.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	tree.add_theme_stylebox_override("focus", StyleBoxEmpty.new())

	# The explorer rows are Nerd Font private-use glyphs. Make the Tree use the
	# editor font (with the bundled icon fallback) explicitly; inheriting the
	# engine default font renders every icon as a missing-glyph box.
	var tree_font: Font = LuaSingleton.editor_theme.get_font("font", "MyType")
	if tree_font != null:
		LuaSingleton.apply_icon_fallbacks(tree_font)
		tree.add_theme_font_override("font", tree_font)

	var selected = StyleBoxFlat.new()
	selected.bg_color = LuaSingleton.gui.selection_color
	selected.set_content_margin_all(2)
	tree.add_theme_stylebox_override("selected", selected)
	tree.add_theme_stylebox_override("selected_focus", selected)

	tree.add_theme_color_override("font_color", font)
	tree.add_theme_color_override("font_hovered_color", font)
	tree.add_theme_color_override("font_selected_color", font)
	tree.add_theme_color_override("guide_color", LuaSingleton.keywords.comments)
	tree.add_theme_color_override("relationship_line_color", LuaSingleton.keywords.comments)

	# The folder glyph color is resolved at build time; repaint existing rows
	# when the theme changes.
	for rel in _dir_items.keys():
		var item = _dir_items[rel]
		if is_instance_valid(item):
			item.set_custom_color(0, _folder_color())


func _folder_color() -> Color:
	return LuaSingleton.gui.get("completion_selected_color", LuaSingleton.gui.font_color)
