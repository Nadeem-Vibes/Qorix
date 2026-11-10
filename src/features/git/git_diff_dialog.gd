extends AcceptDialog

## Phase 6 diff viewer.
##
## Open files are compared in memory against their HEAD baseline, so unsaved
## edits are part of the diff. Files that are not open use the parsed
## `git diff` output and are always shown in unified mode.
##
## The side-by-side view pads missing lines instead of drawing separate row
## widgets: for a few thousand changed lines that is far cheaper, and CodeEdit
## still gives selection, search and per-line background tinting for free.

const Diff = preload("res://src/features/git/git_diff.gd")

var editor: FileManager

var _document = null
var _path: String = ""
var _parsed: Dictionary = {}
var _mode: String = "side"
var _loading: bool = false

var header_label: Label
var stats_label: Label
var mode_button: Button
var side_box: HBoxContainer
var old_label: Label
var new_label: Label
var old_edit: CodeEdit
var new_edit: CodeEdit
var unified_edit: CodeEdit


func _ready() -> void:
	editor = _find_editor()
	title = "Changes"
	ok_button_text = "Close"
	min_size = Vector2i(1180, 720)
	exclusive = false

	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.offset_left = 12
	root.offset_top = 10
	root.offset_right = -12
	root.offset_bottom = -54
	root.add_theme_constant_override("separation", 6)
	add_child(root)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 10)
	root.add_child(header)

	header_label = Label.new()
	header_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_label.clip_text = true
	header_label.text = "Changes"
	header.add_child(header_label)

	stats_label = Label.new()
	stats_label.add_theme_color_override("font_color", LuaSingleton.keywords.comments)
	header.add_child(stats_label)

	mode_button = Button.new()
	mode_button.focus_mode = Control.FOCUS_NONE
	mode_button.text = "Unified"
	mode_button.tooltip_text = "Switch between side-by-side and unified diff"
	mode_button.pressed.connect(_on_mode_pressed)
	header.add_child(mode_button)

	side_box = HBoxContainer.new()
	side_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	side_box.add_theme_constant_override("separation", 8)
	root.add_child(side_box)

	var old_column := VBoxContainer.new()
	old_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	old_column.add_theme_constant_override("separation", 3)
	side_box.add_child(old_column)

	old_label = Label.new()
	old_label.text = "HEAD (old)"
	old_column.add_child(old_label)

	old_edit = _make_edit()
	old_column.add_child(old_edit)

	var new_column := VBoxContainer.new()
	new_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	new_column.add_theme_constant_override("separation", 3)
	side_box.add_child(new_column)

	new_label = Label.new()
	new_label.text = "Editor buffer (new)"
	new_column.add_child(new_label)

	new_edit = _make_edit()
	new_column.add_child(new_edit)

	unified_edit = _make_edit()
	unified_edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	unified_edit.visible = false
	root.add_child(unified_edit)

	LuaSingleton.on_theme_load.connect(restyle)
	restyle()


func _find_editor() -> FileManager:
	var node = get_parent()
	while node != null and !(node is FileManager):
		node = node.get_parent()
	return node


func _make_edit() -> CodeEdit:
	var edit := CodeEdit.new()
	edit.editable = false
	edit.context_menu_enabled = true
	edit.gutters_draw_line_numbers = false
	edit.highlight_current_line = false
	edit.caret_blink = false
	edit.wrap_mode = TextEdit.LINE_WRAPPING_NONE
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	edit.add_theme_font_size_override("font_size", 14)
	return edit


# ── PUBLIC ENTRY POINTS ─────────────────────────────────────────────────────

## Opens the diff for an open document. The document answers immediately when
## its baseline is cached; otherwise the dialog shows a short loading state
## and FileManager calls `baseline_arrived()` when the worker answers.
func open_document(document) -> void:
	_document = document
	_parsed = {}
	_loading = false
	_path = str(document.path) if document != null else ""
	title = "Changes: " + (document.title() if document != null else "")
	header_label.text = _relative_display(_path)
	header_label.tooltip_text = _path
	_style_for_document(document)
	if document == null:
		show_message("This document is not available.")
		_popup()
		return
	if document.git_baseline_known:
		_mode = "side"
		_render_document()
	else:
		show_loading("Reading the HEAD version of this file…", _path)
		# show_loading() clears the previous document, so re-attach after it:
		# baseline_arrived() needs the document to render the side-by-side view.
		_document = document
		_mode = "side"
	_popup()


## Opens a unified diff for a file that is not open (or when only git's own
## output is available).
func open_parsed(path: String, parsed: Dictionary) -> void:
	_document = null
	_path = path
	_parsed = parsed
	_loading = false
	title = "Changes: " + path.get_file()
	header_label.text = _relative_display(path)
	header_label.tooltip_text = path
	_style_for_document(null)

	var rows := Diff.unified_lines(parsed)
	if rows.is_empty():
		show_message("No changes against HEAD." if bool(parsed.get("ok", true)) else str(parsed.get("error", "Git diff failed.")))
		_popup()
		return

	var texts: Array[String] = []
	for row in rows:
		texts.append(str(row.get("text", "")))
	unified_edit.text = "\n".join(texts)
	for i in range(rows.size()):
		var kind := str(rows[i].get("kind", "context"))
		if kind == "file" or kind == "hunk":
			unified_edit.set_line_background_color(i, _tint(LuaSingleton.keywords.function, 0.10))
		elif kind == "add":
			unified_edit.set_line_background_color(i, _added_tint())
		elif kind == "delete":
			unified_edit.set_line_background_color(i, _deleted_tint())
	stats_label.text = "+%d  −%d" % [int(parsed.get("additions", 0)), int(parsed.get("deletions", 0))]
	mode_button.visible = false
	_show_mode("unified")
	_popup()


func show_loading(message: String, path: String) -> void:
	_loading = true
	_document = null
	_parsed = {}
	_path = path
	title = "Changes: " + path.get_file()
	header_label.text = _relative_display(path)
	header_label.tooltip_text = path
	stats_label.text = ""
	mode_button.visible = false
	unified_edit.text = message
	old_edit.text = ""
	new_edit.text = ""
	_show_mode("unified")


func show_message(message: String) -> void:
	_loading = false
	# Drop any document/parsed state so a late signal for the previous diff
	# cannot overwrite this message.
	_document = null
	_parsed = {}
	header_label.text = _path.get_file() if !_path.is_empty() else "Changes"
	stats_label.text = ""
	mode_button.visible = false
	unified_edit.text = message
	old_edit.text = ""
	new_edit.text = ""
	_show_mode("unified")


func is_for_path(path: String) -> bool:
	return !_path.is_empty() and path == _path


## Called by FileManager after a baseline request finishes. Returns true when
## the dialog consumed the answer.
func baseline_arrived(path: String, _result: Dictionary) -> bool:
	if !visible or !is_for_path(path):
		return false
	if _document == null:
		return false
	_loading = false
	if _document.git_baseline_known:
		_mode = "side"
		_render_document()
	else:
		show_message("The HEAD version of this file is unavailable.")
	return true


func diff_arrived(path: String, parsed: Dictionary) -> bool:
	if !visible or !is_for_path(path) or _document != null:
		return false
	open_parsed(path, parsed)
	return true


# ── RENDERING ───────────────────────────────────────────────────────────────

func _render_document() -> void:
	if _document == null:
		return
	_loading = false
	_document.git_baseline_known = true
	var result := Diff.line_diff(str(_document.git_baseline_text), str(_document.text()))
	var rows: Array = result.get("rows", [])
	var added := int(result.get("added", 0))
	var modified := int(result.get("modified", 0))
	var deleted := int(result.get("deleted", 0))
	stats_label.text = "+%d  −%d  ~%d" % [added, deleted, modified]

	if rows.is_empty():
		show_message("No changes against HEAD.")
		return

	var old_lines: Array[String] = []
	var new_lines: Array[String] = []
	var unified_lines: Array[String] = []
	for row in rows:
		var kind := str(row.get("kind", "context"))
		var old_line := int(row.get("old_line", 0))
		var new_line := int(row.get("new_line", 0))
		var left := str(row.get("left", ""))
		var right := str(row.get("right", ""))
		old_lines.append(_number_prefix(old_line) + left)
		new_lines.append(_number_prefix(new_line) + right)

		match kind:
			"add":
				unified_lines.append("+" + right)
			"delete":
				unified_lines.append("-" + left)
			"modify":
				unified_lines.append("-" + left)
				unified_lines.append("+" + right)
			_:
				unified_lines.append(" " + right)

	old_edit.text = "\n".join(old_lines)
	new_edit.text = "\n".join(new_lines)
	unified_edit.text = "\n".join(unified_lines)

	for i in range(rows.size()):
		var kind := str(rows[i].get("kind", "context"))
		match kind:
			"add":
				new_edit.set_line_background_color(i, _added_tint())
			"delete":
				old_edit.set_line_background_color(i, _deleted_tint())
			"modify":
				old_edit.set_line_background_color(i, _modified_tint())
				new_edit.set_line_background_color(i, _modified_tint())

	mode_button.visible = true
	_show_mode(_mode)


func _number_prefix(line: int) -> String:
	return "%5s  " % (str(line) if line > 0 else "")


func _on_mode_pressed() -> void:
	_show_mode("unified" if _mode == "side" else "side")


func _show_mode(mode: String) -> void:
	_mode = mode
	var side := mode == "side" and !old_edit.text.is_empty()
	side_box.visible = side
	unified_edit.visible = !side
	mode_button.text = "Unified" if side else "Side by side"


func _popup() -> void:
	if !visible:
		popup_centered_ratio(0.8)


func _relative_display(path: String) -> String:
	if path.is_empty():
		return ""
	var relative := path
	if editor != null and editor.git_service != null and editor.git_service.has_repo():
		var rel: String = editor.git_service.relative_to(editor.git_service.repo_root, path)
		if !rel.is_empty():
			relative = rel
	return relative


# ── THEME ───────────────────────────────────────────────────────────────────

func restyle() -> void:
	if header_label == null:
		return
	var font: Color = LuaSingleton.gui.font_color
	header_label.add_theme_color_override("font_color", font)
	old_label.add_theme_color_override("font_color", LuaSingleton.keywords.comments)
	new_label.add_theme_color_override("font_color", LuaSingleton.keywords.comments)
	stats_label.add_theme_color_override("font_color", LuaSingleton.keywords.comments)
	mode_button.add_theme_color_override("font_color", font)
	mode_button.add_theme_color_override("font_hover_color", LuaSingleton.gui.selection_color)
	for edit in [old_edit, new_edit, unified_edit]:
		if edit != null:
			_style_edit(edit)
	# Background tints are theme-dependent; repaint after a theme switch. Never
	# pop the dialog open from a theme change: only refresh it while visible.
	if !visible or _path.is_empty():
		return
	if _document != null and _document.git_baseline_known:
		_render_document()
	elif !_parsed.is_empty():
		var parsed := _parsed
		open_parsed(_path, parsed)


func _style_edit(edit: CodeEdit) -> void:
	edit.theme = LuaSingleton.editor_theme
	edit.add_theme_color_override("background_color", LuaSingleton.gui.background_color)
	edit.add_theme_color_override("current_line_color", Color(0, 0, 0, 0))
	edit.add_theme_color_override("selection_color", LuaSingleton.gui.selection_color)
	edit.add_theme_color_override("font_color", LuaSingleton.gui.font_color)
	edit.add_theme_color_override("word_highlighted_color", LuaSingleton.gui.word_highlighted_color)
	edit.add_theme_color_override("caret_color", LuaSingleton.gui.caret_color)


func _style_for_document(document) -> void:
	var extension := ""
	if document != null:
		extension = document.language_extension()
	if !extension.is_empty() and LuaSingleton.language_service != null:
		var highlighter = LuaSingleton.language_service.get_highlighter(extension)
		old_edit.syntax_highlighter = highlighter
		new_edit.syntax_highlighter = highlighter
		unified_edit.syntax_highlighter = highlighter
	else:
		old_edit.syntax_highlighter = null
		new_edit.syntax_highlighter = null
		unified_edit.syntax_highlighter = null


func _added_tint() -> Color:
	return _tint(LuaSingleton.keywords.get("string", Color("#6a9955")), 0.16)


func _deleted_tint() -> Color:
	return _tint(LuaSingleton.keywords.get("error", Color("#e06c75")), 0.16)


func _modified_tint() -> Color:
	return _tint(LuaSingleton.keywords.get("variable", Color("#d7ba7d")), 0.13)


func _tint(value: Variant, alpha: float) -> Color:
	var color: Color = value if value is Color else Color("#d7ba7d")
	color.a = alpha
	return color
