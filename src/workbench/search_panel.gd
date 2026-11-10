extends PanelContainer

const UI_MOTION = preload("res://src/platform/ui_motion.gd")

## Left-dock global search.
##
## The scan itself lives in SearchService (time-sliced, cancellable, backend
## agnostic). This panel only debounces typing, renders grouped results, jumps
## to a match and drives Replace All through a preview-first flow.
##
## Shares the left dock with the file explorer: opening one takes the slot from
## the other, so the camera inset never has to account for two widths.

const PANEL_WIDTH := 320.0
const TOP_OFFSET := 62.0
const SEARCH_DEBOUNCE := 0.28

const CLOSE_GLYPH := "✕"
const REPLACE_GLYPH := "󰛔"
const CASE_ON_GLYPH := "Aa"

var editor: FileManager

var header_label: Label
var replace_toggle: Button
var close_button: Button
var query_edit: LineEdit
var case_button: Button
var replace_row: HBoxContainer
var replace_edit: LineEdit
var replace_apply_button: Button
var status_label: Label
var tree: Tree

var replace_dialog: ConfirmationDialog
var replace_summary: TextEdit

var _root: TreeItem
var _results: Array = []
var _last_stats: Dictionary = {}
var _debounce_left: float = 0.0
var _pending_search: bool = false
var _tween: Tween
var _base_position := Vector2.ZERO

var _preview_files: Array = []
var _preview_query: String = ""
var _preview_replacement: String = ""
var _preview_case: bool = false


func _ready() -> void:
	editor = _find_editor()
	if editor != null:
		editor.search_panel = self

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
	header_label.text = "Search"
	header_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(header_label)

	replace_toggle = Button.new()
	replace_toggle.text = REPLACE_GLYPH
	replace_toggle.tooltip_text = "Show replace"
	replace_toggle.toggle_mode = true
	replace_toggle.focus_mode = Control.FOCUS_NONE
	replace_toggle.toggled.connect(_on_replace_toggled)
	header.add_child(replace_toggle)

	close_button = Button.new()
	close_button.text = CLOSE_GLYPH
	close_button.tooltip_text = "Close search (Ctrl+Shift+F)"
	close_button.focus_mode = Control.FOCUS_NONE
	close_button.pressed.connect(close)
	header.add_child(close_button)

	var query_row = HBoxContainer.new()
	query_row.add_theme_constant_override("separation", 4)
	box.add_child(query_row)

	query_edit = LineEdit.new()
	query_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	query_edit.placeholder_text = "Search in folder..."
	query_edit.text_changed.connect(_on_query_changed)
	query_edit.text_submitted.connect(func(_text: String) -> void: _start_search())
	query_row.add_child(query_edit)

	case_button = Button.new()
	case_button.text = CASE_ON_GLYPH
	case_button.tooltip_text = "Match case"
	case_button.toggle_mode = true
	case_button.focus_mode = Control.FOCUS_NONE
	case_button.toggled.connect(func(_on: bool) -> void: _schedule_search(0.0))
	query_row.add_child(case_button)

	replace_row = HBoxContainer.new()
	replace_row.add_theme_constant_override("separation", 4)
	replace_row.visible = false
	box.add_child(replace_row)

	replace_edit = LineEdit.new()
	replace_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	replace_edit.placeholder_text = "Replace with..."
	replace_edit.text_submitted.connect(func(_text: String) -> void: preview_replace())
	replace_row.add_child(replace_edit)

	replace_apply_button = Button.new()
	replace_apply_button.text = "All"
	replace_apply_button.tooltip_text = "Preview and replace all matches"
	replace_apply_button.focus_mode = Control.FOCUS_NONE
	replace_apply_button.pressed.connect(preview_replace)
	replace_row.add_child(replace_apply_button)

	status_label = Label.new()
	status_label.text = ""
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.add_theme_font_size_override("font_size", 12)
	box.add_child(status_label)

	tree = Tree.new()
	tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tree.hide_root = true
	tree.columns = 1
	tree.column_titles_visible = false
	tree.select_mode = Tree.SELECT_ROW
	tree.allow_rmb_select = false
	tree.focus_mode = Control.FOCUS_ALL
	tree.set_column_expand(0, true)
	tree.set_column_clip_content(0, true)
	tree.item_activated.connect(_on_item_activated)
	tree.item_mouse_selected.connect(_on_item_mouse_selected)
	box.add_child(tree)

	_build_replace_dialog()

	LuaSingleton.on_theme_load.connect(restyle)
	LuaSingleton.on_settings_change.connect(restyle)
	restyle()

	if editor != null:
		var service = editor.search_service
		service.search_started.connect(_on_search_started)
		service.search_progress.connect(_on_search_progress)
		service.search_finished.connect(_on_search_finished)
		service.search_cancelled.connect(_on_search_cancelled)
		service.search_failed.connect(_on_search_failed)
		editor.workspace.index_finished.connect(_on_index_finished)

	_clear_results()


func _find_editor() -> FileManager:
	var node = get_parent()
	while node != null and !(node is FileManager):
		node = node.get_parent()
	return node


func _build_replace_dialog() -> void:
	replace_dialog = ConfirmationDialog.new()
	replace_dialog.title = "Replace All"
	replace_dialog.ok_button_text = "Replace"
	replace_dialog.get_label().hide()
	replace_dialog.min_size = Vector2i(760, 460)

	replace_summary = TextEdit.new()
	replace_summary.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	replace_summary.offset_left = 12
	replace_summary.offset_top = 12
	replace_summary.offset_right = -12
	replace_summary.offset_bottom = -54
	replace_summary.editable = false
	replace_summary.context_menu_enabled = true
	replace_summary.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	replace_dialog.add_child(replace_summary)

	replace_dialog.confirmed.connect(_apply_replace)
	add_child(replace_dialog)


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
		focus_query()
		return

	if editor != null:
		editor.open_left_dock(self)

	visible = true
	modulate.a = 0.0
	position = _base_position + Vector2(6, 0)
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
	_tween.set_parallel(true)
	_tween.tween_property(self, "modulate:a", 1.0, UI_MOTION.duration(0.18))
	_tween.tween_property(self, "position", _base_position, UI_MOTION.duration(0.18))

	if editor != null:
		editor.update_left_inset()

	focus_query()
	if !query_edit.text.strip_edges().is_empty() and _results.is_empty():
		_schedule_search(0.0)


func close() -> void:
	if !visible:
		return

	_pending_search = false
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
	_tween.set_parallel(true)
	_tween.tween_property(self, "modulate:a", 0.0, UI_MOTION.duration(0.18))
	_tween.tween_property(self, "position", _base_position + Vector2(6, 0), UI_MOTION.duration(0.18))
	_tween.chain()
	_tween.tween_callback(func() -> void:
		visible = false
		position = _base_position
		if editor != null:
			editor.update_left_inset()
	)

	editor.search_service.cancel()


func hide_now() -> void:
	_pending_search = false
	visible = false
	modulate.a = 0.0
	if _tween != null and _tween.is_valid():
		_tween.kill()
	if editor != null:
		editor.search_service.cancel()
		editor.update_left_inset()


func focus_query() -> void:
	query_edit.grab_focus()
	query_edit.select_all()


## The terminal drawer covers the full window width; shorten the search dock
## the same way the file tree is shortened so its last rows stay visible.
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
	if !_pending_search:
		return

	_debounce_left -= delta
	if _debounce_left > 0.0:
		return

	_pending_search = false
	_start_search()


# ── SEARCH FLOW ─────────────────────────────────────────────────────────────

func _on_query_changed(_text: String) -> void:
	_schedule_search(SEARCH_DEBOUNCE)


func _schedule_search(delay: float) -> void:
	_pending_search = true
	_debounce_left = delay


func _start_search() -> void:
	if editor == null:
		return

	var query := query_edit.text.strip_edges()
	if query.is_empty():
		editor.search_service.cancel()
		_results.clear()
		_clear_results()
		status_label.text = ""
		return

	if !editor.workspace.has_workspace():
		_status("Open a folder to search its files.")
		return

	var files: Array = editor.workspace.files_for_search()
	_status("Searching...")
	editor.search_service.search(query, files, {
		"case_sensitive": case_button.button_pressed,
	})


func _on_search_started(_query: String, total: int) -> void:
	_results.clear()
	_clear_results()
	_status("Searching %d files..." % total)


func _on_search_progress(scanned: int, total: int, matches: int) -> void:
	_status("Scanning %d / %d - %d matches" % [scanned, total, matches])


func _on_search_cancelled() -> void:
	_status("Search cancelled.")


func _on_search_failed(message: String) -> void:
	_status("Search failed: " + message)


func _on_search_finished(results: Array, stats: Dictionary) -> void:
	_results = results
	_last_stats = stats
	_populate_results(results)

	var matches := int(stats.get("matches", results.size()))
	var files := _file_count(results)
	var text := "%d matches in %d files" % [matches, files]
	if bool(stats.get("truncated", false)):
		text += " (limit reached)"
	text += " - %d ms" % int(stats.get("elapsed_msec", 0))
	_status(text)


func _on_index_finished(_files: int, _truncated: bool) -> void:
	if visible and !query_edit.text.strip_edges().is_empty():
		_schedule_search(0.1)


func _status(text: String) -> void:
	status_label.text = text


# ── RESULTS ─────────────────────────────────────────────────────────────────

func _clear_results() -> void:
	if tree == null:
		return
	tree.clear()
	_root = tree.create_item()


func _populate_results(results: Array) -> void:
	_clear_results()

	if results.is_empty():
		var empty := tree.create_item(_root)
		empty.set_text(0, "No results")
		empty.set_custom_color(0, LuaSingleton.keywords.comments)
		return

	var current_path := ""
	var parent: TreeItem = null
	var count := 0

	for row in results:
		var path := str(row.get("path", ""))
		if path != current_path:
			current_path = path
			count = 0
			parent = tree.create_item(_root)
			parent.set_metadata(0, {"path": path, "is_file": true})
			parent.set_text(0, str(row.get("rel", path)))
			parent.set_tooltip_text(0, path)
			parent.set_custom_color(0, LuaSingleton.gui.font_color)
			parent.set_collapsed(false)

		if parent == null:
			continue

		count += 1
		var line := int(row.get("line", 0))
		var preview := str(row.get("preview", "")).strip_edges()
		var item := tree.create_item(parent)
		item.set_metadata(0, {
			"path": path,
			"line": line,
			"column": int(row.get("column", 0)),
			"length": int(row.get("length", 0)),
			"is_match": true,
		})
		item.set_text(0, "%d: %s" % [line + 1, preview])
		item.set_tooltip_text(0, "%s:%d" % [str(row.get("rel", path)), line + 1])
		item.set_custom_color(0, LuaSingleton.keywords.comments)


func _file_count(results: Array) -> int:
	var seen: Dictionary = {}
	for row in results:
		seen[str(row.get("path", ""))] = true
	return seen.size()


func _metadata(item: TreeItem) -> Dictionary:
	if item == null:
		return {}
	var value = item.get_metadata(0)
	return value if value is Dictionary else {}


func _on_item_activated() -> void:
	_activate(tree.get_selected())


func _on_item_mouse_selected(_position: Vector2, button: int) -> void:
	if button != MOUSE_BUTTON_LEFT:
		return
	_activate(tree.get_selected())


func _activate(item: TreeItem) -> void:
	var meta := _metadata(item)
	if meta.is_empty():
		return

	if bool(meta.get("is_file", false)):
		item.set_collapsed(!item.is_collapsed())
		return

	if bool(meta.get("is_match", false)):
		editor.open_search_result(
			str(meta.get("path", "")),
			int(meta.get("line", 0)),
			int(meta.get("column", 0))
		)


# ── REPLACE ALL ─────────────────────────────────────────────────────────────

func _on_replace_toggled(on: bool) -> void:
	replace_row.visible = on
	if on:
		replace_edit.grab_focus()
		replace_edit.select_all()


func _result_paths() -> Array:
	var out: Array = []
	var seen: Dictionary = {}
	for row in _results:
		var path := str(row.get("path", ""))
		if path.is_empty() or seen.has(path):
			continue
		seen[path] = true
		out.append(path)
	return out


func preview_replace() -> void:
	if editor == null or editor.search_service.searching:
		return

	var query := query_edit.text.strip_edges()
	if query.is_empty():
		_status("Type something to replace first.")
		return

	var files := _result_paths()
	if files.is_empty():
		_status("No matches to replace.")
		return

	_preview_files = files
	_preview_query = query
	_preview_replacement = replace_edit.text
	_preview_case = case_button.button_pressed

	var preview: Dictionary = editor.search_service.replace_preview(
		files, query, _preview_replacement, {"case_sensitive": _preview_case}
	)
	if !preview.get("ok", false):
		_status("Replace preview failed: " + str(preview.get("error", "")))
		return

	var total := int(preview.get("total", 0))
	if total == 0:
		_status("No matches to replace.")
		return

	var lines: Array[String] = []
	lines.append("Replace %d occurrence%s of \"%s\" in %d file%s?" % [
		total,
		"" if total == 1 else "s",
		query,
		preview.get("files", []).size(),
		"" if preview.get("files", []).size() == 1 else "s",
	])
	lines.append("")
	for entry in preview.get("files", []):
		lines.append("  %s  (%d)" % [str(entry.get("rel", entry.get("path", ""))), int(entry.get("count", 0))])

	var skipped: Array = preview.get("skipped", [])
	if !skipped.is_empty():
		lines.append("")
		lines.append("%d file%s will be skipped." % [skipped.size(), "" if skipped.size() == 1 else "s"])
	var errors: Array = preview.get("errors", [])
	if !errors.is_empty():
		lines.append("")
		lines.append("Problems:")
		for error in errors:
			lines.append("  " + str(error))

	lines.append("")
	lines.append("This writes directly to disk. Open documents without unsaved changes are reloaded.")

	replace_summary.text = "\n".join(lines)
	replace_dialog.popup_centered()


func _apply_replace() -> void:
	var applied: Dictionary = editor.search_service.replace_apply(
		_preview_files, _preview_query, _preview_replacement, {"case_sensitive": _preview_case}
	)

	if !applied.get("ok", false):
		_status("Replace failed: " + str(applied.get("error", "unknown error")))
		editor.warn("[color=red]REPLACE FAILED[/color]: %s" % str(applied.get("error", "Unknown error.")))
		return

	var written: Array = applied.get("written", [])
	editor.reload_documents_after_replace(written)
	if editor.file_tree != null:
		editor.file_tree.refresh_all()

	_status("Replaced %d occurrence%s in %d file%s." % [
		int(applied.get("total", 0)),
		"" if int(applied.get("total", 0)) == 1 else "s",
		written.size(),
		"" if written.size() == 1 else "s",
	])

	_schedule_search(0.15)


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
	status_label.add_theme_color_override("font_color", LuaSingleton.keywords.comments)

	tree.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	tree.add_theme_stylebox_override("focus", StyleBoxEmpty.new())

	var selected = StyleBoxFlat.new()
	selected.bg_color = LuaSingleton.gui.selection_color
	selected.set_content_margin_all(2)
	tree.add_theme_stylebox_override("selected", selected)
	tree.add_theme_stylebox_override("selected_focus", selected)

	tree.add_theme_color_override("font_color", font)
	tree.add_theme_color_override("font_hovered_color", font)
	tree.add_theme_color_override("font_selected_color", font)
	tree.add_theme_color_override("guide_color", LuaSingleton.keywords.comments)

	if replace_summary != null:
		replace_summary.add_theme_color_override("font_color", font)
		replace_summary.add_theme_color_override("background_color", LuaSingleton.gui.background_color)
