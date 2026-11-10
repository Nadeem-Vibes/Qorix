extends SceneTree

## Headless acceptance driver for the Phase 2 workspace/dock/session work.
##
##   godot --headless --path . --script res://tests/integration/acceptance_runner.gd -- \
##       --workspace "C:/path/to/test/workspace"
##
## Add --shots="C:/path/to/shots" when running with a real window to save PNGs
## of the explorer, quick open, search results, replace preview and compare view.
##
## It boots the real editor scene (not just the services), drives the shortcuts
## through InputMap, operates the explorer/search panels, triggers an external
## disk change, and finally restarts the scene to verify session restore.
## Run it with APPDATA pointed at a throwaway folder: the editor writes its real
## session/settings files under user://.

var checks: int = 0
var failures: int = 0
var editor = null
var workspace_path: String = ""
var shots_dir: String = ""


func _initialize() -> void:
	_run()


func _run() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--workspace="):
			workspace_path = arg.trim_prefix("--workspace=")
		elif arg.begins_with("--shots="):
			shots_dir = arg.trim_prefix("--shots=")
	if workspace_path.is_empty():
		print("FAIL  no --workspace=... argument")
		quit(1)
		return
	# The editor stores normalized forward-slash paths; accept either spelling.
	workspace_path = workspace_path.replace("\\", "/").trim_suffix("/")
	if !shots_dir.is_empty():
		var dir_err := DirAccess.make_dir_recursive_absolute(shots_dir)
		if dir_err != OK:
			print("WARN  could not create screenshot folder: " + shots_dir)
			shots_dir = ""

	await process_frame
	editor = await _boot_editor()
	if editor == null:
		print("FAIL  editor scene did not boot")
		quit(1)
		return

	# Keep the test deterministic: no background autosave or external polling.
	if editor.session_timer != null:
		editor.session_timer.stop()
	if editor.external_timer != null:
		editor.external_timer.stop()
	var autosave = editor.get_node_or_null("AutoSaveTimer")
	if autosave != null:
		autosave.stop()
	_pin_classic_ui(editor)

	# The welcome file picker covers the editor on a first run.
	if editor.overlays.is_open(editor.file_dialog):
		editor.overlays.close(editor.file_dialog)
		await _wait_frames(20)

	# A fresh profile boots with no tabs. Create one so editor-scoped commands
	# (find, replace, tab close) have an active view to act on.
	if editor.documents.count() == 0:
		editor.new_tab()
		await _wait_frames(4)

	await _test_shortcuts()
	await _test_workspace_and_tree()
	await _test_quick_open()
	await _test_search_and_replace()
	await _test_external_change()
	await _test_file_operations()
	await _test_session_restart()

	print("")
	print("Acceptance: %d checks, %d failure(s)." % [checks, failures])
	if failures > 0:
		if editor != null and is_instance_valid(editor):
			editor.session.finish_session(editor._snapshot_session())
		quit(1)
		return

	# Clean shutdown also verifies final session save + lock release.
	if editor != null and is_instance_valid(editor):
		editor._finish_quit()
	else:
		quit(0)


## A throwaway APPDATA is a fresh install, which now boots in Beginner
## Mode: the simplified UI hides the Debug/Language/Source Control commands
## the palette assertions count. Pin the classic UI for the run. The startup
## flag means docks are left alone, exactly as on a real first launch.
func _pin_classic_ui(ed) -> void:
	if ed != null and ed.has_method("apply_beginner_mode") and ed.beginner_mode_enabled():
		ed.apply_beginner_mode(false, true)


func _boot_editor():
	var packed: PackedScene = load("res://src/main/editor.tscn")
	if packed == null:
		return null
	var instance = packed.instantiate()
	root.add_child(instance)
	current_scene = instance
	await _wait_frames(8)
	return instance


func _shutdown_editor() -> void:
	if editor == null or !is_instance_valid(editor):
		return
	editor._save_session(true)
	editor.queue_free()
	editor = null
	await _wait_frames(4)


func _test_shortcuts() -> void:
	await _press_keys(KEY_E, true, true)
	_check(editor.file_tree.visible, "Ctrl+Shift+E opens the file explorer")
	await _press_keys(KEY_F, true, true)
	_check(editor.search_panel.visible, "Ctrl+Shift+F opens global search")
	_check(!editor.file_tree.visible, "search takes the shared left dock from the explorer")
	editor.search_panel.hide_now()
	await _press_keys(KEY_E, true, true)
	_check(editor.file_tree.visible, "file explorer can reopen after search")
	await _press_keys(KEY_P, true)
	_check(editor.palette.visible, "Ctrl+P opens the quick-open palette")
	# OverlayController fades panels over 0.2s and ignores close() while it is
	# still animating; wait for the open tween before closing the panel.
	await _close_overlay(editor.palette)

	await _test_command_registry_surface()
	await _test_scope_routing()
	await _test_rebinding()
	await _test_keybindings_editor()
	await _test_deferred_palette_command()


## The palette, menus and toolbar all read the same registry. Adding a command
## must not require editing a second list anywhere.
func _test_command_registry_surface() -> void:
	_check(editor.commands.all().size() >= 40, "the registry exposes the built-in commands")
	_check(editor.commands.has("file.save"), "file.save is registered")
	_check(editor.commands.has("view.keybindings"), "view.keybindings is registered")

	await _press_keys(KEY_P, true, true)
	_check(editor.palette.visible, "Ctrl+Shift+P opens the command palette")
	_check(editor.palette.mode == "commands", "the palette is in command mode")
	var save_item := _palette_item_for("file.save")
	_check(!save_item.is_empty(), "the palette lists registry commands")
	_check(str(save_item.get("display", "")).contains("Ctrl+S"), "the palette shows the effective shortcut")
	await _close_overlay(editor.palette)

	var fired := [0]
	editor.commands.register("acceptance.demo", {
		"label": "Acceptance Demo",
		"category": "Help",
		"scope": "global",
		"shortcut": "Ctrl+Alt+R",
		"handler": func() -> void: fired[0] += 1,
	})
	await _wait_frames(2)
	_check(editor.commands.has("acceptance.demo"), "one register() call adds a command")
	_check(!_palette_item_for("acceptance.demo").is_empty(), "the new command appears in the palette")
	_check(_menu_has_item("Help", "Acceptance Demo"), "the new command appears in the generated menu")
	_check(
		editor.keybindings.handle(_key_event(KEY_R, true, false, true), "editor") == "acceptance.demo",
		"the new command's shortcut is routed"
	)
	editor.commands.execute("acceptance.demo")
	_check(fired[0] == 1, "the registered handler runs")
	editor.commands.unregister("acceptance.demo")
	await _wait_frames(2)


func _test_scope_routing() -> void:
	var ctrl_f := _key_event(KEY_F, true)
	_check(editor.keybindings.handle(ctrl_f, "editor") == "edit.find", "Ctrl+F routes to editor find")
	_check(editor.keybindings.handle(ctrl_f, "terminal") == "", "Ctrl+F is not an editor command in the terminal scope")
	_check(
		editor.keybindings.handle(_key_event(KEY_S, true), "terminal") == "file.save",
		"global commands still work in the terminal scope"
	)

	# Simulate a focused terminal without requiring the xterm extension: a
	# focusable probe inside the panel is enough for the scope check.
	var was_visible: bool = editor.terminal.visible
	editor.terminal.visible = true
	var probe := Control.new()
	probe.focus_mode = Control.FOCUS_ALL
	editor.terminal.add_child(probe)
	probe.grab_focus()
	await _wait_frames(2)
	_check(editor.terminal.is_terminal_focused(), "terminal focus is detected")
	_check(editor.input_controller._scope() == "terminal", "terminal focus selects the terminal scope")

	await _push_key(KEY_F, true)
	_check(!editor.find_panel.visible, "Ctrl+F in the terminal does not open editor find")
	probe.queue_free()
	editor.terminal.visible = was_visible
	editor.editor_host.grab_active_focus()
	await _wait_frames(1)


func _test_rebinding() -> void:
	var original: String = editor.keybindings.binding_for("file.save")
	var result: Dictionary = editor.keybindings.set_binding("file.save", "Ctrl+Alt+U")
	_check(result.get("ok", false), "rebinding file.save succeeds")
	_check(
		str(editor.commands.get_command("file.save").get("shortcut", "")) == "Ctrl+Alt+U",
		"the registry shortcut updates"
	)
	var button = editor.top_bar.toolbar_buttons.get("file.save")
	_check(button != null and button.tooltip_text.contains("Ctrl+Alt+U"), "the toolbar tooltip updates")
	var palette_item := _palette_item_for("file.save")
	_check(str(palette_item.get("display", "")).contains("Ctrl+Alt+U"), "the palette shortcut updates")
	_check(FileAccess.file_exists(editor.keybindings.path), "the override is persisted")
	_check(
		editor.keybindings.handle(_key_event(KEY_U, true, false, true), "editor") == "file.save",
		"the new chord is routed"
	)

	editor.keybindings.reset_binding("file.save")
	_check(editor.keybindings.binding_for("file.save") == original, "reset restores the default")
	var reset_button = editor.top_bar.toolbar_buttons.get("file.save")
	_check(reset_button != null and reset_button.tooltip_text.contains(original), "the tooltip returns to the default")


func _test_keybindings_editor() -> void:
	await _wait_overlays()
	editor.open_keybindings()
	var opened: bool = await _wait_until(func() -> bool: return editor.keybindings_panel.visible, 120)
	_check(opened, "the keyboard shortcuts panel opens")
	_check(editor.keybindings_panel._rows.size() > 20, "the panel lists the registry commands")

	var row: Dictionary = editor.keybindings_panel._rows.get("file.save", {})
	_check(!row.is_empty(), "file.save has a shortcut row")
	if !row.is_empty():
		var button: Button = row["button"]
		editor.keybindings_panel._start_capture("file.save", button)
		await _push_key(KEY_Y, true, false, true)
		await _wait_frames(3)
		_check(editor.keybindings.binding_for("file.save") == "Ctrl+Alt+Y", "capturing a chord rebinds the command")
		editor.keybindings.reset_binding("file.save")

	await _close_overlay(editor.keybindings_panel)


func _test_deferred_palette_command() -> void:
	await _wait_overlays()
	await _press_keys(KEY_P, true, true)
	_check(editor.palette.visible, "the command palette opens for the deferred-command test")
	await _wait_overlays()
	editor.palette.prompt.text = "Open Settings"
	editor.palette.refilter()
	_check(!editor.palette.filtered.is_empty(), "the palette finds Open Settings")
	editor.palette.confirm()
	var opened: bool = await _wait_until(func() -> bool: return editor.settings_panel.visible, 120)
	_check(opened, "a deferred palette command opens its overlay after the fade")
	await _close_overlay(editor.settings_panel)


func _test_workspace_and_tree() -> void:
	_check(editor.set_workspace(workspace_path), "workspace opens")
	# The workspace-trust dialog is modal: it swallows every key event until a
	# user answers it, which silently breaks every later key-driven check. A
	# real user answers the dialog before working; do the same here. Emitting
	# `confirmed` directly does not hide the dialog the way the OK button
	# does, so hide it explicitly.
	if editor.trust_dialog != null and editor.trust_dialog.visible:
		editor.trust_dialog.confirmed.emit()
		editor.trust_dialog.hide()
	var finished: bool = await _wait_until(func() -> bool:
		return !editor.workspace.building
	, 1200)
	_check(finished, "workspace index finishes")
	_check(editor.workspace.index_size() == 5, "index contains the five visible files")
	_check(editor.workspace.file_for_path(workspace_path.path_join(".git/ignored.txt")) == null, ".git is skipped")
	_check(editor.workspace.file_for_path(workspace_path.path_join("node_modules/ignored.js")) == null, "node_modules is skipped")
	_check(editor.workspace.file_for_path(workspace_path.path_join("build/ignored.txt")) == null, "build is skipped")
	_check(editor.file_tree.visible, "opening a workspace reveals the explorer")

	editor.file_tree._expand_dir("sub")
	editor.file_tree.refresh_all()
	await _wait_frames(3)
	var sub_item = editor.file_tree._dir_items.get("sub")
	_check(sub_item != null and sub_item.get_child_count() >= 2, "expanding sub/ loads its lazy children")
	_check(editor.camera.left_inset > 0.0, "camera shifts for the open left dock")
	await _capture("01_file_tree")
	await _test_mouse_folder_expansion(sub_item)


## Regression for Tree::create_item() being called from inside item_mouse_selected.
## The Tree blocks item creation during that signal, so the first population of a
## folder must be deferred. Headless viewports do not route mouse clicks.
func _test_mouse_folder_expansion(sub_item: TreeItem) -> void:
	if DisplayServer.get_name() == "headless":
		print("SKIP  mouse-click folder expansion (needs a real window)")
		return
	if sub_item == null or !is_instance_valid(sub_item):
		_check(false, "mouse-click folder expansion has a tree item")
		return

	var panel = editor.file_tree
	var tree: Tree = panel.tree
	panel._expanded_dirs.erase("sub")
	panel._loaded_dirs.erase("sub")
	for child in sub_item.get_children():
		child.free()
	sub_item.set_collapsed(true)
	tree.scroll_to_item(sub_item)
	await _wait_frames(3)

	var rect := tree.get_item_area_rect(sub_item, 1)
	if rect.size.y <= 0.0:
		_check(false, "mouse-click folder expansion item is visible")
		return
	var local := rect.position + Vector2(rect.size.x * 0.5, rect.size.y * 0.5)
	_push_mouse_click(tree.get_global_transform_with_canvas() * local)
	await _wait_frames(8)
	_check(tree.get_selected() == sub_item, "mouse-click selects the folder")
	_check(sub_item.get_child_count() >= 2, "mouse-click folder expansion loads its lazy children")
	_check(panel._loaded_dirs.has("sub"), "mouse-click folder expansion marks the directory loaded")


func _test_quick_open() -> void:
	var hits: Array = editor.workspace.quick_open_items("gamma", 10)
	_check(!hits.is_empty(), "quick open finds a file by name")
	_check(!hits.is_empty() and str(hits[0].get("path", "")).ends_with("sub/gamma.md"), "quick open ranks gamma.md first")

	var multi: Array = editor.workspace.quick_open_items("sub gamma", 10)
	_check(!multi.is_empty(), "space-separated quick-open tokens match")

	await _press_keys(KEY_P, true)
	await _wait_overlays()
	_check(editor.palette.visible, "quick-open palette is visible for typing")
	editor.palette.prompt.text = "beta"
	editor.palette.refilter()
	_check(!editor.palette.filtered.is_empty(), "palette filters against the workspace index")
	await _capture("02_quick_open")
	editor.palette.confirm()
	await _wait_frames(6)
	var doc = editor.documents.active_document()
	_check(doc != null and str(doc.path).ends_with("beta.gd"), "palette Enter opens the selected file")
	await _close_overlay(editor.palette)


func _test_search_and_replace() -> void:
	await _press_keys(KEY_F, true, true)
	_check(editor.search_panel.visible, "global search opens")
	editor.search_panel.query_edit.text = "needle"
	editor.search_panel._pending_search = false
	editor.search_panel._start_search()

	var done: bool = await _wait_until(func() -> bool:
		return !editor.search_service.searching and !editor.search_panel._results.is_empty()
	, 1200)
	_check(done, "global search completes with results")
	_check(editor.search_panel._results.size() >= 5, "search finds every indexed needle")
	_check(editor.search_panel.tree.get_root().get_child_count() >= 4, "results are grouped by file")
	await _capture("03_search_results")

	var file_item: TreeItem = editor.search_panel.tree.get_root().get_first_child()
	var match_item: TreeItem = file_item.get_first_child() if file_item != null else null
	_check(match_item != null, "a result row exists")
	if match_item != null:
		var meta: Dictionary = match_item.get_metadata(0)
		editor.search_panel._activate(match_item)
		await _wait_frames(4)
		var active = editor.documents.active_document()
		_check(active != null and str(active.path) == str(meta.get("path", "")), "clicking a result opens its file")
		_check(active != null and active.caret_line == int(meta.get("line", -1)), "clicking a result moves the caret to the line")

	editor.search_panel.replace_edit.text = "pin"
	editor.search_panel.preview_replace()
	_check(editor.search_panel.replace_dialog.visible, "Replace All preview opens")
	_check(editor.search_panel.replace_summary.text.contains("Replace"), "preview summarizes the replacement")
	_check(editor.search_panel.replace_summary.text.contains("6 occurrences"), "preview counts the matches")
	await _capture("04_replace_preview")
	editor.search_panel._apply_replace()
	editor.search_panel.replace_dialog.hide()
	await _wait_frames(4)
	_check(FileAccess.get_file_as_string(workspace_path.path_join("alpha.txt")).contains("pin"), "Replace All wrote alpha.txt")
	_check(!FileAccess.get_file_as_string(workspace_path.path_join("sub/gamma.md")).contains("needle"), "Replace All wrote nested files")
	var alpha_doc = editor.documents.find_by_path(workspace_path.path_join("alpha.txt"))
	_check(alpha_doc == null or str(alpha_doc.text()).contains("pin"), "clean open documents reload after replace")


func _test_external_change() -> void:
	var alpha := workspace_path.path_join("alpha.txt")
	var beta := workspace_path.path_join("beta.gd")
	editor.open_file(alpha)
	editor.open_file(beta)
	await _wait_frames(3)

	var beta_doc = editor.documents.find_by_path(beta)
	await _wait(1.2)
	_write(beta, "BETA EXTERNAL\n")
	editor._check_external_changes()
	_check(editor.external_dialog.visible, "external mtime change raises the reload prompt")
	_check(editor._external_document == beta_doc, "the prompt points at the changed document")

	editor._show_external_compare()
	_check(editor.compare_dialog.visible, "Compare opens the side-by-side view")
	_check(editor.compare_buffer_edit.text.contains("func beta"), "compare shows the editor buffer")
	_check(editor.compare_disk_edit.text.contains("BETA EXTERNAL"), "compare shows the disk revision")
	await _capture("05_compare")
	editor.compare_dialog.hide()

	editor._reload_external_tab()
	editor.external_dialog.hide()
	_check(str(beta_doc.text()).contains("BETA EXTERNAL"), "Reload replaces the buffer with the disk version")
	_check(!beta_doc.modified, "Reload leaves the buffer clean")
	_check(editor._external_document == null, "Reload clears the pending change")

	var alpha_doc = editor.documents.find_by_path(alpha)
	await _wait(1.2)
	_write(alpha, "ALPHA EXTERNAL\n")
	editor._check_external_changes()
	_check(editor.external_dialog.visible, "a second external change prompts again")
	_check(editor._external_document == alpha_doc, "the second prompt points at alpha.txt")
	editor._keep_external_tab()
	editor.external_dialog.hide()
	_check(str(alpha_doc.text()).contains("pin"), "Keep mine retains the editor buffer")
	_check(alpha_doc.modified, "Keep mine marks the buffer dirty so it cannot be lost silently")

	# The periodic autosave must defer to the external-change prompt instead of
	# writing the buffer over the newer disk revision.
	editor.open_file(beta)
	await _wait(1.2)
	_write(beta, "BETA SECOND EXTERNAL\n")
	editor._on_auto_save_timer_timeout()
	_check(FileAccess.get_file_as_string(beta).contains("BETA SECOND EXTERNAL"), "autosave does not overwrite an external change")
	_check(editor.external_dialog.visible, "autosave routes the external change to the reload prompt")
	_check(editor._external_document == beta_doc, "the autosave prompt points at the active document")
	editor.external_dialog.hide()
	editor._external_document = null
	beta_doc.mark_clean()
	beta_doc.disk_mtime = editor._mtime(beta)


func _test_file_operations() -> void:
	var panel = editor.file_tree
	panel._context_rel = "sub"
	panel._context_path = workspace_path.path_join("sub")
	panel._context_is_dir = true

	panel._on_menu_id(0)  # MENU_NEW_FILE
	_check(panel.name_dialog.visible, "New File menu opens the name dialog")
	panel.name_edit.text = "from_menu.txt"
	panel._on_name_confirmed()
	panel.name_dialog.hide()
	await _wait_frames(3)
	var created := workspace_path.path_join("sub/from_menu.txt")
	_check(FileAccess.file_exists(created), "New File creates the file on disk")
	_check(editor.workspace.file_for_path(created) != null, "New File adds it to the index")
	_check(editor.documents.find_by_path(created) != null, "New File opens the created file")

	panel._context_rel = "sub/from_menu.txt"
	panel._context_path = created
	panel._context_is_dir = false
	panel._on_menu_id(2)  # MENU_RENAME
	panel.name_edit.text = "renamed.txt"
	panel._on_name_confirmed()
	panel.name_dialog.hide()
	await _wait_frames(3)
	var renamed := workspace_path.path_join("sub/renamed.txt")
	_check(!FileAccess.file_exists(created) and FileAccess.file_exists(renamed), "Rename moves the file on disk")
	_check(editor.workspace.file_for_path(renamed) != null, "Rename updates the index")
	_check(editor.documents.find_by_path(renamed) != null, "Rename keeps the open tab pointing at the new path")

	panel._context_rel = "sub/renamed.txt"
	panel._context_path = renamed
	panel._context_is_dir = false
	panel._on_menu_id(3)  # MENU_DELETE
	_check(panel.delete_dialog.visible, "Delete asks for confirmation")
	panel._on_delete_confirmed()
	panel.delete_dialog.hide()
	await _wait_frames(3)
	_check(!FileAccess.file_exists(renamed), "Delete removes the file")
	_check(editor.workspace.file_for_path(renamed) == null, "Delete removes it from the index")
	_check(editor.documents.find_by_path(renamed) == null, "Delete closes the unmodified tab")

	panel._context_rel = "sub"
	panel._context_path = workspace_path.path_join("sub")
	panel._context_is_dir = true
	panel._on_menu_id(1)  # MENU_NEW_FOLDER
	panel.name_edit.text = "made_by_menu"
	panel._on_name_confirmed()
	panel.name_dialog.hide()
	await _wait_frames(2)
	var folder := workspace_path.path_join("sub/made_by_menu")
	_check(DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(folder)), "New Folder creates the directory")
	panel._delete_path(folder)
	await _wait_frames(2)


func _test_session_restart() -> void:
	# Build a controlled set of tabs: one dirty saved file, one clean file and
	# one unsaved buffer, plus a saved terminal tab with a custom cwd.
	while editor.documents.count() > 0:
		editor.documents.remove_document(0)
	await _wait_frames(2)

	var alpha := workspace_path.path_join("alpha.txt")
	var beta := workspace_path.path_join("beta.gd")
	editor.open_file(alpha)
	var alpha_doc = editor.documents.active_document()
	alpha_doc.set_text("ALPHA UNSAVED\nsecond line\nthird line\n", false)
	alpha_doc.mark_dirty()
	alpha_doc.view.set_caret_line(2)
	alpha_doc.view.set_caret_column(4)
	alpha_doc.view.scroll_vertical = 1
	editor.documents.capture_active_state()

	editor.open_file(beta)
	var beta_doc = editor.documents.active_document()
	beta_doc.view.set_caret_line(0)
	beta_doc.view.set_caret_column(3)
	editor.documents.capture_active_state()

	editor.documents.new_untitled("scratch buffer", "Scratch")
	var scratch = editor.documents.active_document()
	scratch.view.set_caret_line(0)
	scratch.view.set_caret_column(7)
	editor.documents.capture_active_state()

	# Active tab = beta (index 1). The search dock is open at this point.
	editor.documents.activate_index(1)
	await _wait_frames(2)

	# The terminal starts with one default tab. Keep only the tab we control so
	# the restore assertions are unambiguous.
	while editor.terminal.entries.size() > 0:
		editor.terminal.close_terminal(0)
	await _wait_frames(2)
	var term = editor.terminal._create_terminal(workspace_path.path_join("sub"))
	term.title = "TestTerm"
	editor.search_panel.open()
	await _wait_frames(2)

	var saved: Dictionary = editor.session.save_session(editor._snapshot_session())
	_check(saved.get("ok", false), "session snapshot saves with buffer backups")

	await _shutdown_editor()
	editor = await _boot_editor()
	_pin_classic_ui(editor)
	# --script is an engine flag, not a CLI file argument, so this boot follows
	# the normal session-restore path.
	_check(editor.documents.count() == 3, "restart restores all three tabs")
	_check(editor.workspace.root != "" and editor.workspace.root == workspace_path, "restart restores the workspace root")

	var restored_alpha = editor.documents.find_by_path(alpha)
	_check(restored_alpha != null and str(restored_alpha.text()) == "ALPHA UNSAVED\nsecond line\nthird line\n", "restart restores the unsaved buffer text")
	_check(restored_alpha != null and restored_alpha.modified, "restored unsaved buffer stays dirty")
	_check(restored_alpha != null and restored_alpha.caret_line == 2, "restart restores the buffer caret line")

	var restored_beta = editor.documents.find_by_path(beta)
	_check(restored_beta != null, "restart reopens clean saved files")
	_check(editor.documents.active_document() == restored_beta, "restart restores the active tab")
	_check(restored_beta != null and restored_beta.caret_line == 0 and restored_beta.caret_column == 3, "restart restores the active caret")

	var restored_scratch = null
	for doc in editor.documents.documents:
		if doc.untitled and str(doc.title()) == "Scratch":
			restored_scratch = doc
	_check(restored_scratch != null and str(restored_scratch.text()) == "scratch buffer", "restart restores untitled buffers")
	_check(restored_scratch != null and restored_scratch.caret_column == 7, "restart restores untitled carets")

	_check(editor.search_panel.visible, "restart restores the open search dock")
	_check(editor.terminal.entries.size() == 1, "restart restores the terminal tab")
	if editor.terminal.entries.size() == 1:
		var restored_term = editor.terminal.entries[0]
		_check(str(restored_term.title) == "TestTerm", "restart restores the terminal tab title")
		_check(str(restored_term.start_cwd) == workspace_path.path_join("sub"), "restart restores the terminal cwd")


# ── HELPERS ─────────────────────────────────────────────────────────────────

func _check(condition: bool, label: String) -> void:
	checks += 1
	if condition:
		print("PASS  " + label)
	else:
		failures += 1
		print("FAIL  " + label)


func _capture(name: String) -> void:
	if shots_dir.is_empty():
		return
	if DisplayServer.get_name() == "headless":
		print("WARN  screenshot capture needs a real window: " + name)
		return
	# Let any dock/modal tween settle before grabbing the framebuffer.
	await _wait(0.3)
	await _wait_frames(2)
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	var path := shots_dir.path_join(name + ".png")
	var save_err := image.save_png(path)
	if save_err == OK:
		print("SHOT  " + path)
	else:
		print("WARN  could not save screenshot: " + path + " (" + str(save_err) + ")")


func _write(path: String, content: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(content)
	file = null


func _wait_frames(count: int) -> void:
	for i in range(count):
		await process_frame


func _wait(seconds: float) -> void:
	await create_timer(seconds).timeout


## OverlayController ignores opens while a fade is running and closes only
## once the open fade finished. Tests must wait for both edges.
func _wait_overlays() -> void:
	await _wait_until(func() -> bool: return !editor.overlays.is_animating(), 120)


func _close_overlay(panel) -> void:
	await _wait_overlays()
	if panel != null and editor.overlays.is_open(panel):
		editor.overlays.close(panel)
		await _wait_overlays()


func _wait_until(predicate: Callable, max_frames: int = 600) -> bool:
	for i in range(max_frames):
		if predicate.call():
			return true
		await process_frame
	return false


func _release_focus() -> void:
	await _wait_frames(1)
	root.gui_release_focus()


func _key_event(keycode: Key, ctrl: bool = false, shift: bool = false, alt: bool = false) -> InputEventKey:
	var event := InputEventKey.new()
	event.physical_keycode = keycode
	event.ctrl_pressed = ctrl
	event.shift_pressed = shift
	event.alt_pressed = alt
	event.pressed = true
	return event


## Pushes a real key event through the viewport, exactly like the OS would.
## Used directly by the scope/capture tests so they can keep their focus owner.
func _push_key(keycode: Key, ctrl: bool = false, shift: bool = false, alt: bool = false) -> void:
	var down := _key_event(keycode, ctrl, shift, alt)
	root.push_input(down, true)
	await process_frame

	var up := _key_event(keycode, ctrl, shift, alt)
	up.pressed = false
	root.push_input(up, true)
	await process_frame


func _press_keys(keycode: Key, ctrl: bool = false, shift: bool = false, alt: bool = false) -> void:
	await _release_focus()
	await _push_key(keycode, ctrl, shift, alt)
	await _wait_frames(3)


func _palette_item_for(command_id: String) -> Dictionary:
	for item in editor.palette._build_commands():
		if str(item.get("command", "")) == command_id:
			return item
	return {}


func _menu_has_item(category: String, label: String) -> bool:
	for child in editor.top_bar.menu_bar.get_children():
		if str(child.name) != category or !(child is PopupMenu):
			continue
		var popup: PopupMenu = child
		for i in range(popup.item_count):
			if popup.get_item_text(i) == label:
				return true
	return false


func _push_mouse_click(pos: Vector2) -> void:
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.position = pos
	down.global_position = pos
	root.push_input(down, true)
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = pos
	up.global_position = pos
	root.push_input(up, true)
