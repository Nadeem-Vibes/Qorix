extends PanelContainer

const UI_MOTION = preload("res://src/platform/ui_motion.gd")

## Phase 6 left dock: Source Control.
##
## The panel is a presentation layer over GitService. It never runs git itself
## and never keeps its own copy of the repository state: snapshots arrive from
## the worker thread, are rendered here, and every action goes back through the
## service.
##
## The beginner path is one button: **Save point** stages everything and
## commits with a timestamp. The commit box, branch picker and per-file actions
## are the advanced path, but they share the same service calls.

const PANEL_WIDTH := 320.0
const TOP_OFFSET := 62.0

## The parser can hold 3000 entries. Building 3000 rows with four controls each
## would make the dock stutter on every refresh, so the UI stops earlier. The
## counts and the "N more" note keep the true total visible.
const MAX_VISIBLE_ROWS := 400

const REFRESH_GLYPH := "󰑓"
const CLOSE_GLYPH := "✕"
const STAGE_GLYPH := "+"
const UNSTAGE_GLYPH := "−"
const DISCARD_GLYPH := "⟲"
const PULL_GLYPH := "↓"
const PUSH_GLYPH := "↑"
const SAVE_GLYPH := "󰆓"

var editor: FileManager

var header_label: Label
var refresh_button: Button
var close_button: Button

var body: VBoxContainer
var no_repo_page: VBoxContainer
var no_repo_label: Label
var init_button: Button
var open_folder_button: Button

var branch_row: HBoxContainer
var branch_picker: OptionButton
var sync_label: Label
var pull_button: Button
var push_button: Button

var save_point_button: Button
var save_hint: Label

var tabs: TabContainer
var changes_page: VBoxContainer
var history_page: VBoxContainer

var commit_row: HBoxContainer
var commit_edit: LineEdit
var commit_button: Button

var changes_scroll: ScrollContainer
var changes_list: VBoxContainer
var history_scroll: ScrollContainer
var history_list: VBoxContainer

var status_label: Label
var discard_dialog: ConfirmationDialog

var _snapshot: Dictionary = {}
var _syncing_branch: bool = false
var _busy: bool = false
var _last_repo_root: String = ""
var _discard_path: String = ""
var _branch_switchable: bool = true
var _can_pull: bool = false
var _can_push: bool = false

var _staged_signature: String = ""
var _unstaged_signature: String = ""
var _history_signature: String = ""
var _branch_signature: String = ""
var _changes_rows: int = 0

var _tween: Tween
var _animating: bool = false
var _bottom_docks: Array[Control] = []
var _base_position := Vector2.ZERO


func _ready() -> void:
	editor = _find_editor()
	if editor != null:
		editor.source_control_panel = self

	theme = LuaSingleton.editor_theme
	visible = false
	modulate.a = 0.0

	set_anchors_and_offsets_preset(Control.PRESET_LEFT_WIDE)
	offset_top = TOP_OFFSET
	offset_right = PANEL_WIDTH
	offset_bottom = 0.0
	_base_position = position

	_build()
	_build_discard_dialog()

	LuaSingleton.on_theme_load.connect(restyle)
	LuaSingleton.on_settings_change.connect(restyle)
	restyle()

	if editor != null and editor.git_service != null:
		var service = editor.git_service
		service.repo_changed.connect(_on_repo_changed)
		service.snapshot_changed.connect(_on_snapshot)
		service.operation_started.connect(_on_operation_started)
		service.operation_finished.connect(_on_operation_finished)
		if !service.last_snapshot.is_empty():
			_on_snapshot(service.last_snapshot)
		_last_repo_root = service.repo_root
		_update_repo_page()
	else:
		_update_repo_page()


func _find_editor() -> FileManager:
	var node = get_parent()
	while node != null and !(node is FileManager):
		node = node.get_parent()
	return node


func _build() -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	add_child(box)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 4)
	box.add_child(header)

	header_label = Label.new()
	header_label.text = "Source Control"
	header_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_label.clip_text = true
	header.add_child(header_label)

	refresh_button = Button.new()
	refresh_button.text = REFRESH_GLYPH
	refresh_button.tooltip_text = "Refresh source control (Ctrl+Shift+G)"
	refresh_button.focus_mode = Control.FOCUS_NONE
	refresh_button.pressed.connect(_on_refresh_pressed)
	header.add_child(refresh_button)

	close_button = Button.new()
	close_button.text = CLOSE_GLYPH
	close_button.tooltip_text = "Close Source Control"
	close_button.focus_mode = Control.FOCUS_NONE
	close_button.pressed.connect(close)
	header.add_child(close_button)

	no_repo_page = VBoxContainer.new()
	no_repo_page.add_theme_constant_override("separation", 10)
	no_repo_page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(no_repo_page)

	no_repo_label = Label.new()
	no_repo_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	no_repo_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	no_repo_page.add_child(no_repo_label)

	init_button = Button.new()
	init_button.text = "Initialize Repository"
	init_button.tooltip_text = "Create a new Git repository in this folder"
	init_button.custom_minimum_size = Vector2(0, 32)
	init_button.pressed.connect(_on_init_pressed)
	no_repo_page.add_child(init_button)

	open_folder_button = Button.new()
	open_folder_button.text = "Open Folder..."
	open_folder_button.pressed.connect(_on_open_folder_pressed)
	no_repo_page.add_child(open_folder_button)

	body = VBoxContainer.new()
	body.add_theme_constant_override("separation", 6)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(body)

	branch_row = HBoxContainer.new()
	branch_row.add_theme_constant_override("separation", 4)
	body.add_child(branch_row)

	branch_picker = OptionButton.new()
	branch_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	branch_picker.tooltip_text = "Current branch — choose another to switch"
	branch_picker.focus_mode = Control.FOCUS_ALL
	branch_picker.item_selected.connect(_on_branch_selected)
	branch_row.add_child(branch_picker)

	sync_label = Label.new()
	sync_label.add_theme_color_override("font_color", LuaSingleton.keywords.comments)
	branch_row.add_child(sync_label)

	pull_button = Button.new()
	pull_button.text = PULL_GLYPH
	pull_button.tooltip_text = "Pull (fast-forward only)"
	pull_button.focus_mode = Control.FOCUS_NONE
	pull_button.pressed.connect(_on_pull_pressed)
	branch_row.add_child(pull_button)

	push_button = Button.new()
	push_button.text = PUSH_GLYPH
	push_button.tooltip_text = "Push"
	push_button.focus_mode = Control.FOCUS_NONE
	push_button.pressed.connect(_on_push_pressed)
	branch_row.add_child(push_button)

	save_point_button = Button.new()
	save_point_button.text = SAVE_GLYPH + "  Save point"
	save_point_button.tooltip_text = "Save every open file, stage everything and commit with a timestamp"
	save_point_button.custom_minimum_size = Vector2(0, 34)
	save_point_button.focus_mode = Control.FOCUS_NONE
	save_point_button.pressed.connect(_on_save_point_pressed)
	body.add_child(save_point_button)

	save_hint = Label.new()
	save_hint.text = "Saves your files, then records everything as one commit."
	save_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	save_hint.add_theme_color_override("font_color", LuaSingleton.keywords.comments)
	save_hint.add_theme_font_size_override("font_size", 11)
	save_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.add_child(save_hint)

	tabs = TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(tabs)

	changes_page = VBoxContainer.new()
	changes_page.name = "Changes"
	changes_page.add_theme_constant_override("separation", 5)
	tabs.add_child(changes_page)

	commit_row = HBoxContainer.new()
	commit_row.add_theme_constant_override("separation", 4)
	changes_page.add_child(commit_row)

	commit_edit = LineEdit.new()
	commit_edit.placeholder_text = "Commit message"
	commit_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	commit_edit.tooltip_text = "Write a commit message, then press Enter"
	commit_edit.text_submitted.connect(_on_commit_submitted)
	commit_row.add_child(commit_edit)

	commit_button = Button.new()
	commit_button.text = "Commit"
	commit_button.focus_mode = Control.FOCUS_NONE
	commit_button.pressed.connect(_on_commit_pressed)
	commit_row.add_child(commit_button)

	changes_scroll = ScrollContainer.new()
	changes_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	changes_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	changes_page.add_child(changes_scroll)

	changes_list = VBoxContainer.new()
	changes_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	changes_list.add_theme_constant_override("separation", 1)
	changes_scroll.add_child(changes_list)

	history_page = VBoxContainer.new()
	history_page.name = "History"
	tabs.add_child(history_page)

	history_scroll = ScrollContainer.new()
	history_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	history_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	history_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	history_page.add_child(history_scroll)

	history_list = VBoxContainer.new()
	history_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	history_list.add_theme_constant_override("separation", 1)
	history_scroll.add_child(history_list)

	status_label = Label.new()
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.add_theme_font_size_override("font_size", 11)
	status_label.visible = false
	box.add_child(status_label)


func _build_discard_dialog() -> void:
	discard_dialog = ConfirmationDialog.new()
	discard_dialog.title = "Discard changes"
	discard_dialog.ok_button_text = "Discard"
	discard_dialog.cancel_button_text = "Cancel"
	discard_dialog.confirmed.connect(_on_discard_confirmed)
	add_child(discard_dialog)


# ── DOCK LIFECYCLE ──────────────────────────────────────────────────────────

func is_open() -> bool:
	return visible


func toggle() -> void:
	if visible:
		close()
	else:
		open()


func open(tab: int = -1) -> void:
	if tab >= 0 and tabs != null:
		tabs.current_tab = clampi(tab, 0, tabs.get_tab_count() - 1)
	if visible:
		if tab >= 0:
			refresh()
		return

	if editor != null:
		editor.open_left_dock(self)
	_update_repo_page()
	refresh()

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


func hide_now() -> void:
	visible = false
	modulate.a = 0.0
	position = _base_position
	_animating = false
	if _tween != null and _tween.is_valid():
		_tween.kill()
	if editor != null:
		editor.update_left_inset()


func attach_bottom_dock(dock: Control) -> void:
	if dock == null:
		return
	_bottom_docks.append(dock)
	dock.visibility_changed.connect(_apply_bottom_inset)
	_apply_bottom_inset()


func _apply_bottom_inset() -> void:
	var top := 0.0
	if editor != null and editor.has_method("bottom_dock_top"):
		top = float(editor.bottom_dock_top())
	offset_bottom = minf(0.0, top)


func capture_session() -> Dictionary:
	return {
		"visible": visible,
		"tab": tabs.current_tab if tabs != null else 0,
	}


func restore_session(data: Dictionary) -> void:
	if tabs != null:
		tabs.current_tab = clampi(int(data.get("tab", 0)), 0, maxi(0, tabs.get_tab_count() - 1))
	if bool(data.get("visible", false)):
		open()


# ── SERVICE EVENTS ──────────────────────────────────────────────────────────

func refresh() -> void:
	if editor == null or editor.git_service == null:
		_update_repo_page()
		return
	editor.git_service.refresh(true)


## Opened by the "Commit..." command: bring the message box forward.
func focus_commit() -> void:
	if tabs != null:
		tabs.current_tab = 0
	if commit_edit != null:
		commit_edit.grab_focus()
		commit_edit.select_all()


func _on_repo_changed(root: String) -> void:
	if root != _last_repo_root:
		_last_repo_root = root
		commit_edit.text = ""
		_snapshot = {}
		_staged_signature = ""
		_unstaged_signature = ""
		_history_signature = ""
		_branch_signature = ""
		_clear_children(changes_list)
		_clear_children(history_list)
		branch_picker.clear()
		sync_label.text = ""
		branch_picker.add_item("(loading…)")
		_branch_switchable = false
		_can_pull = false
		_can_push = false
	_update_repo_page()


func _on_snapshot(snapshot: Dictionary) -> void:
	_snapshot = snapshot
	_update_repo_page()
	if editor == null or editor.git_service == null or !editor.git_service.has_repo():
		return

	_update_branch_row()
	_render_changes()
	_render_history()


func _on_operation_started(action: String) -> void:
	_busy = true
	_show_status(_action_verb(action) + "…", false)
	_update_controls()


func _on_operation_finished(action: String, result: Dictionary) -> void:
	_busy = false
	var ok := bool(result.get("ok", false))
	var message := str(result.get("message", ""))
	if message.is_empty():
		message = "Done." if ok else "Git command failed."
	if action == "commit" and ok:
		commit_edit.text = ""
	_show_status(message, ok)
	_update_controls()


func _update_controls() -> void:
	var busy := _busy
	if editor != null and editor.git_service != null:
		busy = busy or editor.git_service.is_busy()
	refresh_button.disabled = busy
	save_point_button.disabled = busy
	commit_button.disabled = busy
	branch_picker.disabled = busy or !_branch_switchable
	pull_button.disabled = busy or !_can_pull
	push_button.disabled = busy or !_can_push
	init_button.disabled = busy


func _update_repo_page() -> void:
	var service: Node = editor.git_service if editor != null else null
	var has_repo: bool = service != null and service.has_repo()
	var has_git: bool = service != null and service.has_git()
	body.visible = has_repo
	no_repo_page.visible = !has_repo

	if has_repo:
		header_label.text = "Source Control — " + service.repo_name()
		header_label.tooltip_text = service.repo_root
		refresh_button.tooltip_text = "Refresh source control (Ctrl+Shift+G)"
		_update_controls()
		return

	header_label.text = "Source Control"
	header_label.tooltip_text = ""
	init_button.visible = has_git and service != null and !service.workspace_path.is_empty()
	open_folder_button.visible = service == null or service.workspace_path.is_empty()
	refresh_button.tooltip_text = "Check for a Git repository"

	if !has_git:
		no_repo_label.text = "Git was not found on PATH.\n\nInstall Git, then restart Qorix. The system Git credential helper is used for authentication; Qorix never stores passwords."
	elif service == null or service.workspace_path.is_empty():
		no_repo_label.text = "Open a folder to use Source Control.\n\nSave points record the whole folder as one commit."
	else:
		no_repo_label.text = "This folder is not a Git repository yet.\n\nInitialize one to start making save points. Nothing leaves your computer."
	_update_controls()


# ── CHANGES ─────────────────────────────────────────────────────────────────

func _render_changes() -> void:
	var staged: Array = _snapshot.get("staged", [])
	var unstaged: Array = _snapshot.get("unstaged", [])
	var staged_sig := _entries_signature(staged)
	var unstaged_sig := _entries_signature(unstaged)
	if staged_sig == _staged_signature and unstaged_sig == _unstaged_signature:
		return
	_staged_signature = staged_sig
	_unstaged_signature = unstaged_sig

	var scroll := changes_scroll.scroll_vertical
	_clear_children(changes_list)
	_changes_rows = 0

	var staged_count := int(_snapshot.get("staged_count", staged.size()))
	var unstaged_count := int(_snapshot.get("unstaged_count", unstaged.size()))

	_add_section_header(
		"Staged Changes (%d)" % staged_count,
		"Unstage all",
		_on_unstage_all_pressed,
		staged_count > 0
	)
	if staged.is_empty():
		_add_note("Nothing staged. Use + to stage a file, or Save point for everything.")
	for entry in staged:
		if _changes_rows >= MAX_VISIBLE_ROWS:
			break
		_add_change_row(entry, true)
		_changes_rows += 1

	_add_section_header(
		"Changes (%d)" % unstaged_count,
		"Stage all",
		_on_stage_all_pressed,
		unstaged_count > 0
	)
	if unstaged.is_empty():
		_add_note("No unstaged changes.")
	for entry in unstaged:
		if _changes_rows >= MAX_VISIBLE_ROWS:
			break
		_add_change_row(entry, false)
		_changes_rows += 1

	var hidden := staged_count + unstaged_count - _changes_rows
	if hidden > 0:
		_add_note("… %d more change(s) are not shown. Use git in the terminal for the full list." % hidden)
	if bool(_snapshot.get("truncated", false)):
		_add_note("The repository contains more changes than Source Control lists at once.")

	_set_changes_scroll(scroll)


func _add_section_header(title: String, action_label: String, action: Callable, enabled: bool) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	changes_list.add_child(row)

	var label := Label.new()
	label.text = title
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.clip_text = true
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", LuaSingleton.keywords.comments)
	row.add_child(label)

	var button := Button.new()
	button.text = action_label
	button.flat = true
	button.focus_mode = Control.FOCUS_NONE
	button.add_theme_font_size_override("font_size", 11)
	button.disabled = !enabled || _busy
	button.pressed.connect(action)
	row.add_child(button)


func _add_change_row(entry: Dictionary, staged: bool) -> void:
	var rel := str(entry.get("path", ""))
	if rel.is_empty():
		return
	var abs := _absolute_path(rel)
	var code := _entry_code(entry, staged)
	var label := str(entry.get("status_label", "Changed"))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	changes_list.add_child(row)

	var diff_button := Button.new()
	diff_button.text = code
	diff_button.flat = true
	diff_button.focus_mode = Control.FOCUS_NONE
	diff_button.custom_minimum_size = Vector2(22, 0)
	diff_button.tooltip_text = label + " — show changes"
	diff_button.add_theme_color_override("font_color", _status_color(code))
	diff_button.pressed.connect(_on_diff_pressed.bind(abs))
	row.add_child(diff_button)

	var file_button := Button.new()
	file_button.text = rel
	file_button.flat = true
	file_button.focus_mode = Control.FOCUS_NONE
	file_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	file_button.clip_text = true
	file_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	file_button.tooltip_text = rel
	file_button.pressed.connect(_on_open_pressed.bind(abs))
	row.add_child(file_button)

	if staged:
		var unstage := _row_button(UNSTAGE_GLYPH, "Unstage")
		unstage.pressed.connect(_on_unstage_pressed.bind(abs))
		row.add_child(unstage)
	else:
		var stage := _row_button(STAGE_GLYPH, "Stage")
		stage.pressed.connect(_on_stage_pressed.bind(abs))
		row.add_child(stage)

		var discard := _row_button(DISCARD_GLYPH, "Discard changes")
		discard.pressed.connect(_on_discard_pressed.bind(abs, rel))
		row.add_child(discard)


func _row_button(text: String, tooltip: String) -> Button:
	var button := Button.new()
	button.text = text
	button.flat = true
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = Vector2(22, 0)
	button.tooltip_text = tooltip
	return button


func _add_note(text: String) -> void:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", 11)
	label.add_theme_color_override("font_color", LuaSingleton.keywords.comments)
	changes_list.add_child(label)


func _entries_signature(entries: Array) -> String:
	var parts: Array[String] = []
	for entry in entries:
		if !(entry is Dictionary):
			continue
		parts.append("%s:%s:%s" % [
			str(entry.get("path", "")),
			str(entry.get("index_status", "")),
			str(entry.get("worktree_status", "")),
		])
	return "\n".join(parts)


func _entry_code(entry: Dictionary, staged: bool) -> String:
	if bool(entry.get("untracked", false)):
		return "?"
	if bool(entry.get("conflicted", false)):
		return "U"
	var code := str(entry.get("index_status", ".")) if staged else str(entry.get("worktree_status", "."))
	if code.is_empty() or code == ".":
		code = str(entry.get("status", "M"))
	return code


func _status_color(code: String) -> Color:
	var key := "variable"
	match code:
		"A", "?":
			key = "string"
		"D", "U":
			key = "error"
		"R", "C":
			key = "function"
	var value: Variant = LuaSingleton.keywords.get(key)
	return value if value is Color else LuaSingleton.gui.font_color


func _absolute_path(rel: String) -> String:
	if editor == null or editor.git_service == null:
		return rel
	return editor.git_service.repo_root.path_join(rel)


func _set_changes_scroll(value: int) -> void:
	call_deferred("_restore_scroll", changes_scroll, value)


func _restore_scroll(scroll: ScrollContainer, value: int) -> void:
	if scroll != null and is_instance_valid(scroll):
		scroll.scroll_vertical = value


# ── BRANCH / SYNC ───────────────────────────────────────────────────────────

func _update_branch_row() -> void:
	var branches: Array = _snapshot.get("branches", [])
	var detached := bool(_snapshot.get("detached", false))
	var initial := bool(_snapshot.get("initial", false))

	# Auto-refresh runs every few seconds. Rebuilding the OptionButton each time
	# closes an open dropdown and steals the user's selection, so only touch it
	# when the branch set or the current branch actually changed.
	var signature_parts: Array[String] = [str(detached), str(initial)]
	for branch in branches:
		if !(branch is Dictionary):
			continue
		var name := str(branch.get("name", ""))
		if name.is_empty():
			continue
		var prefix := "● " if bool(branch.get("current", false)) else "   "
		signature_parts.append(prefix + name)
	var signature := "\n".join(signature_parts)

	if signature != _branch_signature:
		_branch_signature = signature
		_syncing_branch = true
		branch_picker.clear()
		for branch in branches:
			if !(branch is Dictionary):
				continue
			var name := str(branch.get("name", ""))
			if name.is_empty():
				continue
			var index := branch_picker.item_count
			var prefix := "● " if bool(branch.get("current", false)) else "   "
			branch_picker.add_item(prefix + name)
			branch_picker.set_item_metadata(index, name)
			if bool(branch.get("current", false)):
				branch_picker.select(index)
		_syncing_branch = false

		if branch_picker.item_count == 0:
			branch_picker.add_item("(no commits yet)" if initial else "(detached)")
		elif detached:
			branch_picker.add_item("(detached)")
			branch_picker.select(branch_picker.item_count - 1)

	_branch_switchable = branch_picker.item_count > 0 and !detached and !initial

	var branch := str(_snapshot.get("branch", ""))
	var ahead := int(_snapshot.get("ahead", 0))
	var behind := int(_snapshot.get("behind", 0))
	var sync := ""
	if ahead > 0:
		sync += "↑%d" % ahead
	if behind > 0:
		sync += "↓%d" % behind
	sync_label.text = sync
	sync_label.visible = !sync.is_empty()

	var remotes: Array = _snapshot.get("remotes", [])
	_can_pull = !remotes.is_empty()
	_can_push = !remotes.is_empty() and (!branch.is_empty() or !str(_snapshot.get("upstream", "")).is_empty())
	pull_button.tooltip_text = "Pull (fast-forward only)" if _can_pull else "No remote configured"
	push_button.tooltip_text = "Push" if _can_push else "No upstream and no remote configured"
	_update_controls()


# ── HISTORY ─────────────────────────────────────────────────────────────────

func _render_history() -> void:
	var commits: Array = _snapshot.get("commits", [])
	var parts: Array[String] = []
	for commit in commits:
		if commit is Dictionary:
			parts.append(str(commit.get("hash", "")) + ":" + str(commit.get("subject", "")))
	var signature := "\n".join(parts)
	if signature == _history_signature:
		return
	_history_signature = signature

	var scroll := history_scroll.scroll_vertical
	_clear_children(history_list)
	if commits.is_empty():
		_add_history_note("No commits yet. Save point creates the first one.")
		return

	for commit in commits:
		if !(commit is Dictionary):
			continue
		var entry := VBoxContainer.new()
		entry.add_theme_constant_override("separation", 1)
		entry.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		history_list.add_child(entry)

		var subject := Label.new()
		subject.text = str(commit.get("subject", "(no subject)"))
		subject.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		subject.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		entry.add_child(subject)

		var meta_parts: Array[String] = []
		var short := str(commit.get("short", ""))
		var author := str(commit.get("author", ""))
		var relative := str(commit.get("relative", ""))
		if !short.is_empty():
			meta_parts.append(short)
		if !author.is_empty():
			meta_parts.append(author)
		if !relative.is_empty():
			meta_parts.append(relative)
		var decorations := str(commit.get("decorations", ""))
		if !decorations.is_empty():
			meta_parts.append(decorations)
		var meta := Label.new()
		meta.text = " · ".join(meta_parts)
		meta.add_theme_font_size_override("font_size", 11)
		meta.add_theme_color_override("font_color", LuaSingleton.keywords.comments)
		meta.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		entry.add_child(meta)

		var separator := HSeparator.new()
		separator.modulate.a = 0.45
		history_list.add_child(separator)

	_set_history_scroll(scroll)


func _add_history_note(text: String) -> void:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", 11)
	label.add_theme_color_override("font_color", LuaSingleton.keywords.comments)
	history_list.add_child(label)


func _set_history_scroll(value: int) -> void:
	call_deferred("_restore_scroll", history_scroll, value)


# ── ACTIONS ─────────────────────────────────────────────────────────────────

func _on_refresh_pressed() -> void:
	refresh()


func _on_save_point_pressed() -> void:
	if editor != null:
		editor.create_save_point()


func _on_commit_pressed() -> void:
	_submit_commit()


func _on_commit_submitted(_text: String) -> void:
	_submit_commit()


func _submit_commit() -> void:
	var service = editor.git_service if editor != null else null
	if service == null:
		return
	var message := commit_edit.text.strip_edges()
	if message.is_empty():
		_show_status("Write a commit message first.", false)
		commit_edit.grab_focus()
		return
	service.commit(message)


func _on_stage_pressed(path: String) -> void:
	if _busy or editor == null or editor.git_service == null:
		return
	editor.git_service.stage([path])


func _on_unstage_pressed(path: String) -> void:
	if _busy or editor == null or editor.git_service == null:
		return
	editor.git_service.unstage([path])


func _on_stage_all_pressed() -> void:
	if _busy or editor == null or editor.git_service == null:
		return
	editor.git_service.stage_all()


func _on_unstage_all_pressed() -> void:
	if _busy or editor == null or editor.git_service == null:
		return
	editor.git_service.unstage_all()


func _on_discard_pressed(path: String, rel: String) -> void:
	if _busy:
		return
	_discard_path = path
	var suffix := ""
	if _is_untracked(path):
		suffix = "\n\nThe file is untracked, so it will be deleted from disk."
	elif _is_staged_added(path):
		suffix = "\n\nThe file is new and staged, so it will be deleted from disk."
	else:
		suffix = "\n\nThis cannot be undone."
	discard_dialog.dialog_text = "Discard all changes to \"%s\"?%s" % [rel, suffix]
	discard_dialog.popup_centered()
	discard_dialog.get_ok_button().grab_focus()


func _is_staged_added(path: String) -> bool:
	for entry in _snapshot.get("staged", []):
		if entry is Dictionary and str(entry.get("index_status", "")) == "A":
			if _absolute_path(str(entry.get("path", ""))) == path:
				return true
	return false


func _is_untracked(path: String) -> bool:
	for entry in _snapshot.get("unstaged", []):
		if entry is Dictionary and bool(entry.get("untracked", false)):
			if _absolute_path(str(entry.get("path", ""))) == path:
				return true
	return false


func _on_discard_confirmed() -> void:
	if _discard_path.is_empty() or editor == null or editor.git_service == null:
		return
	editor.git_service.discard([_discard_path])
	_discard_path = ""


func _on_branch_selected(index: int) -> void:
	if _syncing_branch or _busy or editor == null or editor.git_service == null:
		return
	var name := str(branch_picker.get_item_metadata(index))
	if name.is_empty() or name == str(_snapshot.get("branch", "")):
		return
	editor.git_service.switch_branch(name)


func _on_pull_pressed() -> void:
	if _busy or editor == null or editor.git_service == null:
		return
	editor.git_service.pull()


func _on_push_pressed() -> void:
	if _busy or editor == null or editor.git_service == null:
		return
	editor.git_service.push()


func _on_init_pressed() -> void:
	if _busy or editor == null or editor.git_service == null:
		return
	editor.git_service.init_repository()


func _on_open_folder_pressed() -> void:
	if editor != null:
		editor.open_folder_dialog()


func _on_open_pressed(path: String) -> void:
	if editor == null:
		return
	if FileAccess.file_exists(path):
		editor.open_file(path)
	else:
		editor.show_git_diff_for(path)


func _on_diff_pressed(path: String) -> void:
	if editor != null:
		editor.show_git_diff_for(path)


func _show_status(message: String, ok: bool) -> void:
	status_label.text = message
	status_label.visible = !message.is_empty()
	var color: Color = LuaSingleton.gui.font_color
	if !ok:
		color = LuaSingleton.keywords.get("error", Color("#e06c75"))
	status_label.add_theme_color_override("font_color", color)


func _action_verb(action: String) -> String:
	match action:
		"stage", "stage_all":
			return "Staging"
		"unstage", "unstage_all":
			return "Unstaging"
		"discard":
			return "Discarding"
		"commit":
			return "Committing"
		"save_point":
			return "Saving"
		"pull":
			return "Pulling"
		"push":
			return "Pushing"
		"switch_branch":
			return "Switching branch"
		"init":
			return "Initializing repository"
	return "Running Git"


# ── THEME ───────────────────────────────────────────────────────────────────

func restyle() -> void:
	if header_label == null:
		return
	theme = LuaSingleton.editor_theme

	var panel := StyleBoxFlat.new()
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
	var comments: Color = LuaSingleton.keywords.comments
	header_label.add_theme_color_override("font_color", font)
	no_repo_label.add_theme_color_override("font_color", font)
	save_hint.add_theme_color_override("font_color", comments)
	status_label.add_theme_color_override("font_color", font)
	sync_label.add_theme_color_override("font_color", comments)

	for button in [refresh_button, close_button, pull_button, push_button, init_button, open_folder_button, commit_button]:
		if button != null:
			button.add_theme_color_override("font_color", font)
			button.add_theme_color_override("font_hover_color", LuaSingleton.gui.selection_color)
			button.add_theme_color_override("font_pressed_color", LuaSingleton.gui.selection_color)

	save_point_button.add_theme_color_override("font_color", font)
	save_point_button.add_theme_color_override("font_hover_color", LuaSingleton.gui.selection_color)

	branch_picker.add_theme_color_override("font_color", font)
	branch_picker.add_theme_color_override("font_hover_color", font)

	commit_edit.add_theme_color_override("font_color", font)
	commit_edit.add_theme_color_override("font_placeholder_color", comments)
	commit_edit.add_theme_color_override("caret_color", LuaSingleton.gui.caret_color)

	tabs.add_theme_color_override("font_selected_color", font)
	tabs.add_theme_color_override("font_unselected_color", comments)
	tabs.add_theme_stylebox_override("panel", StyleBoxEmpty.new())

	for scroll in [changes_scroll, history_scroll]:
		if scroll != null:
			scroll.add_theme_stylebox_override("panel", StyleBoxEmpty.new())

	# Row labels keep their status color, so the change lists are rebuilt on
	# the next snapshot rather than recolored here. Drop the cached signatures
	# to force that rebuild with the new palette.
	_staged_signature = ""
	_unstaged_signature = ""
	_history_signature = ""
	if visible and editor != null and editor.git_service != null and editor.git_service.has_repo():
		_render_changes()
		_render_history()


func _clear_children(container: Node) -> void:
	for child in container.get_children():
		container.remove_child(child)
		child.queue_free()
