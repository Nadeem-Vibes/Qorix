extends RefCounted

## Registers every built-in editor command in one place.
##
## The palette, the generated menus and the toolbar all read the same entries,
## so a new command only has to be added here (or registered by a plugin) and
## every surface picks it up.

const TOGGLE_SETTINGS := [
	{"key": "vhs", "label": "Toggle: VHS & CRT shader"},
	{"key": "sunlight", "label": "Toggle: Sunlight shader"},
	{"key": "glow", "label": "Toggle: glow / bloom"},
	{"key": "music", "label": "Toggle: music"},
	{"key": "minimap", "label": "Toggle: minimap"},
	{"key": "code_completion", "label": "Toggle: code completion"},
]

var editor: FileManager = null
var registry = null

var _dynamic_ids: Array[String] = []


func register_all(command_registry) -> void:
	registry = command_registry
	registry.begin_batch()
	_register_base()
	_refresh_dynamic()
	registry.end_batch()


## Re-registers commands whose list can change while the editor runs: recent
## workspaces. One batched changed signal at the end.
func refresh_dynamic() -> void:
	if registry == null:
		return
	registry.begin_batch()
	_refresh_dynamic()
	registry.end_batch()


# ── BASE COMMANDS ───────────────────────────────────────────────────────────

func _register_base() -> void:
	_add("file.new", "New File", "File", "Ctrl+N", "global", _new_file, {
		"icon": "󰈔", "show_in_toolbar": true, "toolbar_order": 1,
		"beginner_label": "New file",
	})
	_add("file.open", "Open File...", "File", "Ctrl+O", "global", _open_file, {
		"icon": "󰉋", "show_in_toolbar": true, "toolbar_order": 2, "defer_execute": true,
		"beginner_label": "Open a file",
	})
	_add("file.open_folder", "Open Folder...", "File", "Ctrl+Shift+O", "global", _open_folder, {
		"beginner_label": "Open a folder",
	})
	_add("file.save", "Save", "File", "Ctrl+S", "global", _save, {
		"icon": "󰆓", "show_in_toolbar": true, "toolbar_order": 3,
		"beginner_label": "Save point",
		"enabled": func() -> bool: return editor.documents != null and editor.documents.count() > 0,
	})
	_add("file.save_as", "Save As...", "File", "Ctrl+Shift+S", "global", _save_as, {
		"beginner_label": "Save as a new file",
		"enabled": func() -> bool: return editor.documents != null and editor.documents.count() > 0,
	})
	_add("file.quick_open", "Quick Open File...", "File", "Ctrl+P", "global", _quick_open, {
		"defer_execute": true, "beginner_label": "Find a file",
	})
	_add("file.new_from_template", "New from Template...", "File", "", "global", _new_from_template, {
		"beginner_label": "Start from a template",
	})
	_add("file.history", "Previous Versions...", "File", "", "global", _history, {
		"beginner_label": "History",
		"enabled": func() -> bool:
			var document = editor.documents.active_document() if editor.documents != null else null
			return document != null and !str(document.path).is_empty(),
	})

	_add("tab.close", "Close Tab", "File", "Ctrl+W", "editor", _close_tab, {
		"beginner_label": "Close this file",
		"enabled": func() -> bool: return editor.documents != null and editor.documents.count() > 0,
	})
	_add("tab.reopen", "Reopen Closed Tab", "File", "Ctrl+Shift+T", "editor", _reopen_tab)

	_add("edit.find", "Find in File", "Edit", "Ctrl+F", "editor", _find, {
		"icon": "󰍉", "show_in_toolbar": true, "toolbar_order": 5,
		"beginner_label": "Find in this file",
		"enabled": func() -> bool: return editor.active_view != null,
	})
	_add("edit.replace", "Find and Replace", "Edit", "Ctrl+H", "editor", _replace, {
		"enabled": func() -> bool: return editor.active_view != null,
	})
	_add("edit.undo", "Undo", "Edit", "", "editor", _undo)
	_add("edit.redo", "Redo", "Edit", "", "editor", _redo)

	_add("language.detect", "Detect Language in Current File", "Edit", "", "global", _detect_language, {
		"beginner_hidden": true,
		"enabled": func() -> bool: return editor.documents != null and editor.documents.active_document() != null,
	})
	_add("language.clear", "Clear Detected Language", "Edit", "", "global", _clear_language, {
		"beginner_hidden": true,
		"enabled": func() -> bool:
			var document = editor.documents.active_document() if editor.documents != null else null
			return document != null and document.has_language_override(),
	})

	_add("view.command_palette", "Command Palette...", "View", "Ctrl+Shift+P", "global", _command_palette, {
		"defer_execute": true,
	})
	_add("view.file_tree", "Toggle File Explorer", "View", "Ctrl+Shift+E", "global", _toggle_file_tree, {
		"beginner_label": "Show file list",
		"checked": func() -> bool: return editor.file_tree != null and editor.file_tree.visible,
	})
	_add("view.search", "Search Across Files", "View", "Ctrl+Shift+F", "global", _toggle_search, {
		"beginner_label": "Search all files",
		"checked": func() -> bool: return editor.search_panel != null and editor.search_panel.visible,
	})
	_add("view.terminal", "Toggle Terminal", "Terminal", "Ctrl+`", "global", _toggle_terminal, {
		"icon": "󰆍", "show_in_toolbar": true, "toolbar_order": 8, "beginner_hidden": true,
		"checked": func() -> bool: return editor.terminal != null and editor.terminal.visible,
	})
	_add("view.comments", "Open Comments", "View", "Ctrl+L", "global", _comments, {
		"defer_execute": true, "beginner_hidden": true,
	})
	_add("view.zoom_in", "Zoom In", "View", "Ctrl+=", "global", _zoom_in)
	_add("view.zoom_out", "Zoom Out", "View", "Ctrl+-", "global", _zoom_out)
	_add("view.escape", "Close Panel / Open File Picker", "View", "Escape", "editor", _escape, {
		"hidden": true, "show_in_menu": false,
	})
	_add("view.escape_dialog", "Close Panel", "View", "Escape", "dialog", _escape_dialog, {
		"hidden": true, "show_in_menu": false,
	})

	_add("terminal.new", "New Terminal Tab", "Terminal", "Ctrl+Shift+`", "global", _new_terminal, {
		"beginner_hidden": true,
	})
	_add("terminal.clear", "Clear Terminal", "Terminal", "", "terminal", _clear_terminal, {
		"beginner_hidden": true,
		"enabled": func() -> bool: return editor.terminal != null and editor.terminal.visible,
	})
	_add("terminal.kill", "Kill Terminal Shell", "Terminal", "", "terminal", _kill_terminal, {
		"beginner_hidden": true,
		"enabled": func() -> bool: return editor.terminal != null and editor.terminal.visible,
	})
	_add("terminal.open_here", "Open Terminal in File's Folder", "Terminal", "", "global", _terminal_here, {
		"beginner_hidden": true,
	})

	_add("run.run", "Run Current File", "Run", "F5", "global", _run, {
		"icon": "󰐊", "show_in_toolbar": true, "toolbar_order": 6,
		"beginner_label": "Run my code",
		"enabled": func() -> bool: return editor.documents != null and editor.documents.count() > 0,
	})
	_add("run.run_alt", "Run Current File (alternate shortcut)", "Run", "Ctrl+Alt+N", "global", _run, {
		"hidden": true, "show_in_menu": false,
	})
	_add("run.run_terminal", "Run Current File in Terminal", "Run", "F6", "global", _run_in_terminal, {
		"beginner_label": "Run with keyboard input",
		"enabled": func() -> bool: return editor.documents != null and editor.documents.count() > 0,
	})
	_add("run.toggle_output", "Toggle Run Output", "Run", "Ctrl+Shift+U", "global", _toggle_run_output, {
		"beginner_label": "Show the output",
		"checked": func() -> bool: return editor.output_panel != null and editor.output_panel.visible,
	})
	_add("run.config", "Edit Run Configuration", "Run", "", "global", _run_config, {
		"beginner_hidden": true,
	})
	_add("run.preview", "Preview in Browser", "Run", "", "global", _preview, {
		"beginner_label": "Preview in browser",
		"icon": "󰖟", "show_in_toolbar": true, "toolbar_order": 11,
		"enabled": func() -> bool:
			var document = editor.documents.active_document() if editor.documents != null else null
			return document != null and !str(document.path).is_empty(),
	})
	_add("run.stop", "Stop Code Run", "Run", "Shift+F5", "global", _stop, {
		"icon": "󰓛", "show_in_toolbar": true, "toolbar_order": 7,
		"enabled": func() -> bool: return editor.run_service != null and editor.run_service.running,
	})
	_add("run.stop_alt", "Stop Code Run (alternate shortcut)", "Run", "Ctrl+Alt+M", "global", _stop, {
		"hidden": true, "show_in_menu": false,
	})

	# ── debugger (DAP) ──────────────────────────────────────────────────────
	_add("debug.start", "Start / Continue Debugging", "Debug", "Ctrl+F5", "global", _debug_start, {
		"icon": "󰃤", "show_in_toolbar": true, "toolbar_order": 10,
		"enabled": func() -> bool: return editor.documents != null and editor.documents.count() > 0,
	})
	_add("debug.toggle_breakpoint", "Toggle Breakpoint", "Debug", "F9", "editor", _debug_toggle_breakpoint, {
		"enabled": func() -> bool: return editor.active_view != null,
	})
	_add("debug.step_over", "Step Over", "Debug", "F10", "editor", _debug_step_over, {
		"enabled": func() -> bool: return editor.dap_manager != null and editor.dap_manager.is_stopped(),
	})
	_add("debug.step_into", "Step Into", "Debug", "F11", "editor", _debug_step_into, {
		"enabled": func() -> bool: return editor.dap_manager != null and editor.dap_manager.is_stopped(),
	})
	_add("debug.step_out", "Step Out", "Debug", "Shift+F11", "editor", _debug_step_out, {
		"enabled": func() -> bool: return editor.dap_manager != null and editor.dap_manager.is_stopped(),
	})
	_add("debug.stop", "Stop Debugging", "Debug", "Ctrl+Shift+F5", "global", _debug_stop, {
		"enabled": func() -> bool: return editor.dap_manager != null and editor.dap_manager.is_active(),
	})
	_add("debug.panel", "Toggle Debugger Panel", "Debug", "Ctrl+Shift+D", "global", _debug_panel, {
		"checked": func() -> bool: return editor.debug_panel != null and editor.debug_panel.visible,
	})
	_add("debug.evaluate", "Evaluate in Debug Console", "Debug", "", "global", _debug_evaluate_console, {
		"enabled": func() -> bool: return editor.dap_manager != null and editor.dap_manager.is_stopped(),
	})
	_add("debug.clear_breakpoints", "Remove All Breakpoints", "Debug", "", "global", _debug_clear_breakpoints, {
		"enabled": func() -> bool: return editor.dap_manager != null and editor.dap_manager.breakpoint_count() > 0,
	})

	# ── language support (LSP) ──────────────────────────────────────────────
	_add("lsp.problems", "Toggle Problems Panel", "Language", "Ctrl+Shift+M", "global", _lsp_problems, {
		"checked": func() -> bool: return editor.lsp_panel != null and editor.lsp_panel.visible,
	})
	_add("lsp.definition", "Go to Definition", "Language", "F12", "editor", _lsp_definition, {
		"enabled": func() -> bool: return editor.active_view != null,
	})
	_add("lsp.references", "Find References", "Language", "Shift+F12", "editor", _lsp_references, {
		"enabled": func() -> bool: return editor.active_view != null,
	})
	_add("lsp.rename", "Rename Symbol", "Language", "F2", "editor", _lsp_rename, {
		"enabled": func() -> bool: return editor.active_view != null,
	})
	_add("lsp.code_actions", "Show Code Actions", "Language", "Ctrl+.", "editor", _lsp_code_actions, {
		"enabled": func() -> bool: return editor.active_view != null,
	})
	_add("lsp.format", "Format Document", "Language", "Shift+Alt+F", "editor", _lsp_format, {
		"enabled": func() -> bool: return editor.active_view != null,
	})
	_add("lsp.hover", "Show Hover Information", "Language", "Ctrl+Shift+H", "editor", _lsp_hover, {
		"enabled": func() -> bool: return editor.active_view != null,
	})
	_add("lsp.signature", "Show Signature Help", "Language", "Ctrl+Shift+Space", "editor", _lsp_signature, {
		"enabled": func() -> bool: return editor.active_view != null,
	})
	_add("lsp.servers", "Language Servers and Installs", "Language", "", "global", _lsp_servers)
	_add("lsp.restart_servers", "Restart Language Servers", "Language", "", "global", _lsp_restart)

	# ── source control (Git) ────────────────────────────────────────────────
	_add("git.source_control", "Toggle Source Control", "Source Control", "Ctrl+Shift+G", "global", _git_panel, {
		"checked": func() -> bool: return editor.source_control_panel != null and editor.source_control_panel.visible,
	})
	_add("git.save_point", "Save Point", "Source Control", "", "global", _git_save_point, {
		"icon": "", "show_in_toolbar": true, "toolbar_order": 4,
		"enabled": func() -> bool: return editor.git_service != null and editor.git_service.has_repo(),
	})
	_add("git.refresh", "Refresh Source Control", "Source Control", "", "global", _git_refresh, {
		"enabled": func() -> bool: return editor.git_service != null and editor.git_service.has_repo(),
	})
	_add("git.commit", "Commit...", "Source Control", "", "global", _git_commit, {
		"enabled": func() -> bool: return editor.git_service != null and editor.git_service.has_repo(),
	})
	_add("git.pull", "Pull", "Source Control", "", "global", _git_pull, {
		"enabled": func() -> bool: return editor.git_service != null and editor.git_service.has_repo(),
	})
	_add("git.push", "Push", "Source Control", "", "global", _git_push, {
		"enabled": func() -> bool: return editor.git_service != null and editor.git_service.has_repo(),
	})
	_add("git.history", "View Git History", "Source Control", "", "global", _git_history, {
		"enabled": func() -> bool: return editor.git_service != null and editor.git_service.has_repo(),
	})

	_add("view.settings", "Open Settings", "Preferences", "Ctrl+,", "global", _settings, {
		"icon": "󰒓", "show_in_toolbar": true, "toolbar_order": 9, "defer_execute": true,
		"beginner_label": "Settings",
	})
	_add("view.keybindings", "Keyboard Shortcuts...", "Preferences", "Ctrl+Alt+K", "global", _keybindings, {
		"icon": "󰌌", "defer_execute": true, "beginner_hidden": true,
	})
	_add("view.theme", "Change Theme...", "Preferences", "Ctrl+T", "global", _theme, {
		"defer_execute": true, "beginner_hidden": true,
	})
	_add("view.info", "About Qorix", "Help", "Ctrl+I", "global", _info, {
		"defer_execute": true,
	})
	_add("beginner.toggle", "Beginner Mode", "Preferences", "", "global", _toggle_beginner_mode, {
		"beginner_label": "Beginner mode",
		"checked": func() -> bool: return editor.beginner_mode_enabled(),
	})
	_add("help.welcome", "Welcome Screen", "Help", "", "global", _welcome, {
		"beginner_label": "Start here",
	})
	_add("help.tutorial", "Start Tutorial", "Help", "", "global", _tutorial, {
		"beginner_label": "Show tutorial",
	})
	_add("help.explain", "Explain This", "Help", "", "global", _explain, {
		"beginner_label": "Explain this",
		"enabled": func() -> bool: return editor.active_view != null,
	})
	_add("help.journey", "Python Journey", "Help", "Ctrl+Alt+J", "global", _course_open, {
		"beginner_label": "Learn Python",
	})
	_add("help.journey_check", "Python Journey: Check My Code", "Help", "", "global", _course_check, {
		"beginner_label": "Check my code",
		"enabled": func() -> bool: return editor.course_lesson != "",
	})

	_add("settings.toggle.cursor_effect", "Cycle: cursor trail", "Preferences", "", "global", _cycle_cursor_trail, {
		"beginner_hidden": true,
	})

	for setting in TOGGLE_SETTINGS:
		var key := str(setting.get("key", ""))
		var label := str(setting.get("label", key))
		_add("settings.toggle." + key, label, "Preferences", "", "global",
			_toggle_setting.bind(key),
			{"checked": _setting_bool.bind(key), "beginner_hidden": true}
		)


## Commands whose entire category is too advanced for Beginner Mode. The flag
## is still written onto every command (the registry, menus and palette all read
## it), but it is applied in one place so a new debug/LSP/git command cannot be
## forgotten.
const BEGINNER_HIDDEN_CATEGORIES := ["Debug", "Language", "Source Control"]


func _add(id: String, label: String, category: String, shortcut: String, scope: String, handler: Callable, extra: Dictionary = {}) -> void:
	var data := extra.duplicate(true)
	data["label"] = label
	data["category"] = category
	data["shortcut"] = shortcut
	data["scope"] = scope
	data["handler"] = handler
	if BEGINNER_HIDDEN_CATEGORIES.has(category) and !data.has("beginner_hidden"):
		data["beginner_hidden"] = true
	registry.register(id, data)


# ── DYNAMIC COMMANDS ────────────────────────────────────────────────────────

func _refresh_dynamic() -> void:
	for id in _dynamic_ids:
		registry.unregister(id)
	_dynamic_ids.clear()

	_register_recent_workspaces()


func _register_recent_workspaces() -> void:
	if editor == null or editor.workspace == null:
		return

	var recents: Array = editor.workspace.recent_workspaces
	var limit := mini(recents.size(), 8)
	for i in range(limit):
		var path := str(recents[i])
		if path.is_empty():
			continue
		var id := "workspace.recent.%d" % i
		registry.register(id, {
			"label": "Open Recent Folder: " + path,
			"category": "Workspace",
			"scope": "global",
			"handler": _open_recent.bind(path),
			"show_in_toolbar": false,
		})
		_dynamic_ids.append(id)


# ── HANDLERS ────────────────────────────────────────────────────────────────

func _new_file() -> void:
	editor.new_tab()

func _open_file() -> void:
	if editor.overlays != null:
		editor.overlays.toggle(editor.file_dialog)

func _open_folder() -> void:
	editor.open_folder_dialog()

func _save() -> void:
	editor.save_current()

func _save_as() -> void:
	editor.save_as()

func _quick_open() -> void:
	editor.toggle_palette_files()

func _command_palette() -> void:
	editor.toggle_palette_commands()

func _close_tab() -> void:
	editor.close_tab(-1)

func _reopen_tab() -> void:
	editor.reopen_last_closed_tab()

func _find() -> void:
	editor.toggle_find()

func _replace() -> void:
	editor.toggle_replace()

func _undo() -> void:
	var view = editor.active_view
	if view != null:
		view.undo()

func _redo() -> void:
	var view = editor.active_view
	if view != null:
		view.redo()

func _toggle_file_tree() -> void:
	editor.toggle_file_tree()

func _toggle_search() -> void:
	editor.toggle_global_search()

func _toggle_terminal() -> void:
	if editor.terminal != null:
		editor.terminal.toggle()

func _new_terminal() -> void:
	if editor.terminal != null:
		editor.terminal.new_terminal()

func _clear_terminal() -> void:
	if editor.terminal != null:
		editor.terminal.clear_active()

func _kill_terminal() -> void:
	if editor.terminal != null:
		editor.terminal.kill_session()

func _terminal_here() -> void:
	if editor.terminal == null:
		return
	var command = ("cd /d \"%s\"" % editor.current_dir) if OS.get_name() == "Windows" \
		else ("cd \"%s\"" % editor.current_dir)
	editor.terminal.open()
	editor.terminal.run_command(command)

func _detect_language() -> void:
	if editor != null and editor.has_method("detect_language"):
		editor.detect_language()


func _clear_language() -> void:
	if editor != null and editor.has_method("clear_language_override"):
		editor.clear_language_override()


func _run() -> void:
	if editor.has_method("prepare_run_snapshot"):
		editor.prepare_run_snapshot()
	if editor.run_service != null:
		editor.run_service.run()

func _run_in_terminal() -> void:
	if editor.has_method("prepare_run_snapshot"):
		editor.prepare_run_snapshot()
	if editor.run_service != null:
		editor.run_service.run("", {"force_terminal": true})

func _stop() -> void:
	if editor.run_service != null:
		editor.run_service.stop()

func _toggle_run_output() -> void:
	if editor.output_panel != null:
		editor.output_panel.toggle()

func _run_config() -> void:
	if editor.run_service != null:
		editor.run_service.open_config()


# ── DEBUG HANDLERS ──────────────────────────────────────────────────────────

func _debug_start() -> void:
	if editor.has_method("debug_start_or_continue"):
		editor.debug_start_or_continue()


func _debug_toggle_breakpoint() -> void:
	if editor.has_method("toggle_breakpoint_at_cursor"):
		editor.toggle_breakpoint_at_cursor()


func _debug_step_over() -> void:
	if editor.has_method("debug_step_over"):
		editor.debug_step_over()


func _debug_step_into() -> void:
	if editor.has_method("debug_step_into"):
		editor.debug_step_into()


func _debug_step_out() -> void:
	if editor.has_method("debug_step_out"):
		editor.debug_step_out()


func _debug_stop() -> void:
	if editor.has_method("debug_stop"):
		editor.debug_stop()


func _debug_panel() -> void:
	if editor.has_method("toggle_debug_panel"):
		editor.toggle_debug_panel()


func _debug_evaluate_console() -> void:
	if editor.has_method("focus_debug_console"):
		editor.focus_debug_console()


func _debug_clear_breakpoints() -> void:
	if editor.has_method("clear_all_breakpoints"):
		editor.clear_all_breakpoints()


# ── LSP HANDLERS ────────────────────────────────────────────────────────────

func _lsp_problems() -> void:
	if editor.lsp_panel == null:
		return
	if editor.lsp_panel.visible:
		editor.lsp_panel.close()
	else:
		editor.lsp_panel.open(0)


func _lsp_servers() -> void:
	if editor.lsp_panel != null:
		editor.lsp_panel.open(1)


func _lsp_restart() -> void:
	if editor.lsp_manager != null:
		editor.lsp_manager.restart_servers()


func _lsp_definition() -> void:
	if editor.lsp_manager != null and editor.active_view != null:
		editor.lsp_manager.request_definition(editor.active_view)


func _lsp_references() -> void:
	if editor.lsp_manager != null and editor.active_view != null:
		editor.lsp_manager.request_references(editor.active_view)


func _lsp_rename() -> void:
	if editor.lsp_manager != null and editor.active_view != null:
		editor.lsp_manager.request_rename(editor.active_view)


func _lsp_code_actions() -> void:
	if editor.lsp_manager != null and editor.active_view != null:
		editor.lsp_manager.request_code_actions(editor.active_view)


func _lsp_format() -> void:
	if editor.lsp_manager != null and editor.active_view != null:
		editor.lsp_manager.request_formatting(editor.active_view)


func _lsp_hover() -> void:
	if editor.lsp_manager != null and editor.active_view != null:
		editor.lsp_manager.hover_at_caret(editor.active_view, true)


func _lsp_signature() -> void:
	if editor.lsp_manager != null and editor.active_view != null:
		editor.lsp_manager.schedule_signature(editor.active_view, true)


# ── GIT HANDLERS ────────────────────────────────────────────────────────────

func _git_panel() -> void:
	editor.toggle_source_control()


func _git_save_point() -> void:
	editor.create_save_point()


func _git_refresh() -> void:
	if editor.source_control_panel != null:
		editor.source_control_panel.refresh()
	elif editor.git_service != null:
		editor.git_service.refresh(true)


func _git_commit() -> void:
	editor.git_commit()


func _git_pull() -> void:
	editor.git_pull()


func _git_push() -> void:
	editor.git_push()


func _git_history() -> void:
	editor.open_source_control(1)


func _comments() -> void:
	if editor.overlays != null:
		editor.overlays.toggle(editor.comments_panel, false, -(18 * 7.5))

func _zoom_in() -> void:
	LuaSingleton.change_zoom_intensity_by(1)
	_refresh_settings_rows()

func _zoom_out() -> void:
	LuaSingleton.change_zoom_intensity_by(-1)
	_refresh_settings_rows()

func _refresh_settings_rows() -> void:
	if editor.settings_panel == null or !editor.settings_panel.visible:
		return
	var settings_list = editor.settings_panel.get_node_or_null("SettingsList")
	if settings_list != null and settings_list.has_method("refresh_values"):
		settings_list.refresh_values()

func _escape() -> void:
	if editor.overlays == null or editor.overlays.is_animating():
		return
	if editor.overlays.is_open(editor.file_dialog):
		editor.overlays.close(editor.file_dialog)
	elif editor.overlays.has_open_panel():
		editor.overlays.close_all()
	else:
		editor.overlays.open(editor.file_dialog)


## Escape while a dialog/text field owns the keyboard: close the panel, but
## never pop the file picker open from inside another text field.
func _escape_dialog() -> void:
	if editor.overlays == null or editor.overlays.is_animating():
		return
	if editor.overlays.is_open(editor.file_dialog):
		editor.overlays.close(editor.file_dialog)
	elif editor.overlays.has_open_panel():
		editor.overlays.close_all()

func _settings() -> void:
	editor.open_settings()

func _keybindings() -> void:
	editor.open_keybindings()

func _theme() -> void:
	if editor.overlays != null:
		editor.overlays.toggle(editor.theme_chooser_panel, false, 18 * 28)

func _info() -> void:
	if editor.overlays != null:
		editor.overlays.toggle(editor.info_panel, true, 1500)

func _cycle_cursor_trail() -> void:
	var entry: Dictionary = LuaSingleton.get_setting("cursor_effect")[0]
	var current := int(entry.get("value", 1))
	LuaSingleton.change_setting("cursor_effect", (current + 1) % 4)
	LuaSingleton.on_settings_change.emit()

func _toggle_setting(property: String) -> void:
	var entry: Dictionary = LuaSingleton.get_setting(property)[0]
	var current := bool(entry.get("value", false))
	LuaSingleton.change_setting(property, !current)
	LuaSingleton.on_settings_change.emit()

func _setting_bool(property: String) -> bool:
	var found = LuaSingleton.get_setting(property)
	if found is Array and found.size() >= 2 and int(found[1]) != -1:
		return bool(found[0].get("value", false))
	return false


func _new_from_template() -> void:
	editor.open_welcome("templates")


func _history() -> void:
	editor.open_history()


func _preview() -> void:
	editor.open_preview()


func _welcome() -> void:
	editor.open_welcome()


func _tutorial() -> void:
	editor.start_onboarding(true)


func _explain() -> void:
	editor.explain_current_word()


func _course_open() -> void:
	editor.toggle_course_panel()


func _course_check() -> void:
	editor.course_check()


func _toggle_beginner_mode() -> void:
	editor.set_beginner_mode(!editor.beginner_mode_enabled())


func _open_recent(path: String) -> void:
	editor.set_workspace(path)
