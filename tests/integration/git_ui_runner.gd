extends SceneTree

## Headless end-to-end UI driver for the Phase 6 Git integration.
##
##   godot --headless --path . --script res://tests/integration/git_ui_runner.gd
##
## Unlike tests/integration/git_integration_runner.gd, which talks to GitService directly,
## this runner boots the real editor scene and drives the Source Control dock,
## the editor gutter, the diff dialog and the Save point path against a real
## temporary repository:
##
##   initialize repository -> commit -> edit -> gutter -> diff -> stage ->
##   unstage -> commit -> history -> discard -> save point -> branch switch
##
## The repository lives in the OS temp folder and is removed at the end. Run
## with APPDATA pointed at a throwaway folder: the editor writes its session
## and settings under user://.
##
## Add --shots="C:/path/to/shots" when running with a real window to save PNGs
## of the Source Control dock and diff viewer.

const INITIAL_ALPHA := "alpha\nbeta\ngamma\ndelta\n"
const INITIAL_BETA := "beta file\n"

var checks: int = 0
var failures: Array[String] = []

var editor = null
var workspace_path: String = ""
var shots_dir: String = ""

var _root: String = ""
var _snapshot: Dictionary = {}
var _last_action: String = ""
var _last_result: Dictionary = {}
var _main_branch: String = ""


func _initialize() -> void:
	_run()


func _run() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--shots="):
			shots_dir = arg.trim_prefix("--shots=").replace("\\", "/").trim_suffix("/")

	_root = _make_temp_dir()
	workspace_path = _root
	print("Git UI workspace: " + workspace_path)

	if !shots_dir.is_empty():
		if DirAccess.make_dir_recursive_absolute(shots_dir) != OK:
			print("WARN  could not create screenshot folder: " + shots_dir)
			shots_dir = ""

	await process_frame
	editor = await _boot_editor()
	if editor == null:
		print("FAIL  editor scene did not boot")
		_finish_without_editor()
		return

	_stop_timers()
	if editor.overlays.is_open(editor.file_dialog):
		editor.overlays.close(editor.file_dialog)
		await _wait_frames(20)

	editor.git_service.operation_finished.connect(_on_operation_finished)
	editor.git_service.snapshot_changed.connect(_on_snapshot_changed)

	_check(editor.git_service.has_git(), "git executable is available")
	if !editor.git_service.has_git():
		await _finish()
		return

	var setup_ok: bool = await _test_repository_setup()
	if setup_ok:
		await _test_gutter_and_diff()
		await _test_stage_commit_history()
		await _test_discard()
		await _test_save_point()
		await _test_branch_picker_and_history()

	await _finish()


func _boot_editor():
	var packed: PackedScene = load("res://src/main/editor.tscn")
	if packed == null:
		return null
	var instance = packed.instantiate()
	root.add_child(instance)
	current_scene = instance
	await _wait_frames(8)
	return instance


func _stop_timers() -> void:
	if editor.session_timer != null:
		editor.session_timer.stop()
	if editor.external_timer != null:
		editor.external_timer.stop()
	if editor.git_refresh_timer != null:
		editor.git_refresh_timer.stop()
	if editor.language_detect_timer != null:
		editor.language_detect_timer.stop()
	var autosave = editor.get_node_or_null("AutoSaveTimer")
	if autosave != null:
		autosave.stop()


# ── 1. EMPTY FOLDER -> INIT -> FIRST COMMIT ────────────────────────────────

func _test_repository_setup() -> bool:
	var panel = editor.source_control_panel
	_check(editor.set_workspace(workspace_path), "empty folder opens as a workspace")
	_check(await _wait_until(func() -> bool: return !editor.workspace.building), "workspace index finishes")
	_check(!editor.git_service.has_repo(), "an empty folder is not a Git repository yet")

	editor.open_source_control(0)
	_check(await _wait_until(func() -> bool: return panel.visible), "Source Control dock opens")
	_check(await _wait_until(func() -> bool: return panel.no_repo_page.visible), "the no-repository page is shown")
	_check(panel.init_button.visible, "Initialize Repository is offered")
	_check(!panel.open_folder_button.visible, "Open Folder is hidden while a workspace is already open")
	if !panel.init_button.visible:
		return false

	panel._on_init_pressed()
	var init_done: bool = await _wait_action("init")
	_check(init_done, "git init finishes through the panel")
	_check(bool(_last_result.get("ok", false)), "git init succeeds")
	if !init_done:
		return false
	_check(await _wait_until(func() -> bool: return editor.git_service.has_repo()), "the new repository is registered")
	_check(await _wait_until(func() -> bool: return panel.body.visible), "the repository page replaces the empty state")
	_check(await _wait_until(func() -> bool: return !panel.no_repo_page.visible), "the no-repository page is hidden")
	_check(editor.source_control_panel.visible, "the dock stays open after initialization")

	# Identity and line endings are local to this throwaway repository. The
	# test never reads or touches the user's global Git configuration.
	var configs := [
		["user.name", "Qorix UI Test"],
		["user.email", "griddycode-ui@example.invalid"],
		["commit.gpgsign", "false"],
		["core.autocrlf", "false"],
	]
	for pair in configs:
		var result := _git(["config", pair[0], pair[1]])
		_check(int(result.get("code", -1)) == 0, "test repo config %s" % str(pair[0]))

	_check(_write("alpha.txt", INITIAL_ALPHA), "alpha.txt is created")
	_check(_write("beta.txt", INITIAL_BETA), "beta.txt is created")
	editor.git_service.refresh(true)

	var changes: bool = await _wait_snapshot(func(snapshot: Dictionary) -> bool:
		return int(snapshot.get("unstaged_count", 0)) >= 2 \
			and !_entry_in(snapshot, "alpha.txt").is_empty() \
			and !_entry_in(snapshot, "beta.txt").is_empty()
	, "initial untracked files")
	_check(changes, "status lists both new files")
	if !changes:
		return false
	_check(await _wait_until(func() -> bool:
		return _contains_label(panel.changes_list, "Changes (2)")
	), "the panel renders both new files")

	panel._on_stage_all_pressed()
	var staged: bool = await _wait_action("stage_all")
	_check(staged, "Stage all finishes through the panel")
	_check(bool(_last_result.get("ok", false)), "Stage all succeeds")
	var staged_snapshot: bool = await _wait_snapshot(func(snapshot: Dictionary) -> bool:
		return int(snapshot.get("staged_count", 0)) >= 2 and int(snapshot.get("unstaged_count", 0)) == 0
	, "initial files staged")
	_check(staged_snapshot, "both files move to the staged list")
	if !staged_snapshot:
		return false
	_check(await _wait_until(func() -> bool:
		return _contains_label(panel.changes_list, "Staged Changes (2)")
	), "the panel renders the staged section")

	panel.commit_edit.text = "Initial commit"
	panel._submit_commit()
	var committed: bool = await _wait_action("commit")
	_check(committed, "the commit box commits the staged files")
	_check(bool(_last_result.get("ok", false)), "the initial commit succeeds")
	if !committed:
		return false

	var clean: bool = await _wait_snapshot(func(snapshot: Dictionary) -> bool:
		var commits := _commits(snapshot)
		return int(snapshot.get("staged_count", 0)) == 0 \
			and int(snapshot.get("unstaged_count", 0)) == 0 \
			and !commits.is_empty() \
			and str((commits[0] as Dictionary).get("subject", "")) == "Initial commit"
	, "initial commit snapshot")
	_check(clean, "the initial commit leaves a clean tree and one history entry")
	if !clean:
		return false

	_main_branch = str(_snapshot.get("branch", ""))
	_check(!_main_branch.is_empty(), "the repository reports its current branch")
	_check(panel.commit_edit.text.is_empty(), "the commit box clears after success")
	_check(await _wait_until(func() -> bool:
		return _contains_label(panel.history_list, "Initial commit")
	), "the History tab receives the first commit")
	_check(_branch_index(panel, _main_branch) >= 0, "the branch picker lists the current branch")
	_check(panel.pull_button.disabled, "Pull is disabled without a remote")
	_check(panel.push_button.disabled, "Push is disabled without a remote")
	_check(panel.save_point_button.visible, "Save point is visible for beginners")
	await _capture("01_source_control")
	return true


# ── 2. GUTTER + DIFF VIEWER ────────────────────────────────────────────────

func _test_gutter_and_diff() -> bool:
	var alpha_abs := _abs("alpha.txt")
	editor.open_file(alpha_abs)
	var document = editor.documents.find_by_path(alpha_abs)
	_check(document != null, "alpha.txt opens in an editor tab")
	if document == null:
		return false

	var baseline: bool = await _wait_until(func() -> bool: return document.git_baseline_known)
	_check(baseline, "the HEAD baseline arrives for the open document")
	if !baseline:
		return false
	_check(str(document.git_baseline_text) == INITIAL_ALPHA, "the baseline is the committed HEAD copy")

	# Produce one modified line, one deleted line and one added line. The
	# insertion/removal calls go through CodeEdit, so the editor's own
	# content_changed signal schedules the gutter, exactly like typing.
	var view = document.view
	view.set_caret_line(1)
	view.set_caret_column(0)
	view.insert_text_at_caret("BETA ")
	view.remove_text(2, 0, 3, 0)
	view.set_caret_line(3)
	view.set_caret_column(0)
	view.insert_text_at_caret("epsilon\n")
	# CodeEdit delivers text_changed after the edit settles, so let the
	# document manager process the dirty state before asserting on it.
	_check(await _wait_until(func() -> bool: return document.modified, 2.0), "typing marks the buffer dirty")

	var painted: bool = await _wait_until(func() -> bool: return view.git_gutter_line_count() >= 3, 5.0)
	_check(painted, "the gutter paints the changed lines after the debounce")
	_check(view.git_mark_at(1) == "modified", "the edited line gets a modified mark")
	_check(view.git_mark_at(2) == "deleted", "the removed line anchors a deleted mark")
	_check(view.git_mark_at(3) == "added", "the new line gets an added mark")
	if !painted:
		print("  gutter marks: painted=%d at1=%s at2=%s at3=%s" % [
			view.git_gutter_line_count(), view.git_mark_at(1), view.git_mark_at(2), view.git_mark_at(3),
		])

	# A gutter click goes through EditorView's real signal path.
	view._on_gutter_clicked(1, view._git_gutter)
	var dialog = editor.git_diff_dialog
	var shown: bool = await _wait_until(func() -> bool: return dialog.visible)
	_check(shown, "clicking a gutter mark opens the diff dialog")
	if !shown:
		return false
	var rendered: bool = await _wait_until(func() -> bool:
		return !dialog._loading and !dialog.new_edit.text.is_empty()
	)
	_check(rendered, "the side-by-side diff renders without staying on the loading page")
	_check(str(dialog.title).contains("alpha.txt"), "the diff title names the file")
	_check(dialog._mode == "side", "open documents start in side-by-side mode")
	_check(dialog.side_box.visible, "the side-by-side panes are visible")
	_check(dialog.old_edit.text.contains("gamma"), "the old pane shows the HEAD line")
	_check(dialog.new_edit.text.contains("BETA beta"), "the new pane shows the modified line")
	_check(dialog.new_edit.text.contains("epsilon"), "the new pane shows the added line")
	_check(dialog.stats_label.text.contains("+1") and dialog.stats_label.text.contains("~1"), "the stats count additions and modifications")
	await _capture("02_git_diff")

	dialog._on_mode_pressed()
	_check(dialog._mode == "unified", "the Unified button switches modes")
	_check(dialog.unified_edit.visible and !dialog.side_box.visible, "the unified pane replaces the side-by-side panes")
	_check(dialog.unified_edit.text.contains("-gamma"), "the unified view shows the deleted line")
	_check(dialog.unified_edit.text.contains("+epsilon"), "the unified view shows the added line")
	_check(dialog.unified_edit.text.contains("+BETA beta"), "the unified view shows the modified line")
	_check(dialog.mode_button.text == "Side by side", "the mode button offers the way back")

	dialog._on_mode_pressed()
	_check(dialog._mode == "side" and dialog.side_box.visible, "the dialog returns to side-by-side mode")
	dialog.hide()
	await _wait_frames(2)
	return true


# ── 3. STAGE / UNSTAGE / COMMIT / HISTORY ──────────────────────────────────

func _test_stage_commit_history() -> bool:
	var panel = editor.source_control_panel
	var alpha_abs := _abs("alpha.txt")
	var document = editor.documents.find_by_path(alpha_abs)
	if document == null:
		_check(false, "alpha.txt is still open for the staging test")
		return false

	editor.commands.execute("file.save")
	var saved: bool = await _wait_until(func() -> bool: return !document.modified, 10.0)
	_check(saved, "Ctrl+S equivalent writes the edited buffer")
	_check(_read("alpha.txt").contains("epsilon"), "the saved file contains the new line")
	if !saved:
		return false

	var changed: bool = await _wait_snapshot(func(snapshot: Dictionary) -> bool:
		var entry := _entry_in(snapshot, "alpha.txt")
		return str(entry.get("worktree_status", "")) == "M" \
			and int(snapshot.get("staged_count", 0)) == 0
	, "saved alpha change")
	_check(changed, "the panel receives the unstaged change")
	if !changed:
		return false
	_check(panel._changes_rows >= 1, "the Changes list renders the file")
	_check(await _wait_until(func() -> bool:
		return _contains_label(panel.changes_list, "Changes (1)")
	), "the Changes section shows the correct count")
	await _capture("03_changes")

	panel._on_stage_pressed(alpha_abs)
	var staged: bool = await _wait_action("stage")
	_check(staged, "the row's Stage action finishes")
	_check(bool(_last_result.get("ok", false)), "staging one file succeeds")
	var staged_snapshot: bool = await _wait_snapshot(func(snapshot: Dictionary) -> bool:
		var entry := _entry_in(snapshot, "alpha.txt")
		return int(snapshot.get("staged_count", 0)) == 1 \
			and int(snapshot.get("unstaged_count", 0)) == 0 \
			and str(entry.get("index_status", "")) == "M"
	, "single file staged")
	_check(staged_snapshot, "the file moves to the staged section")
	if !staged_snapshot:
		return false

	panel._on_unstage_pressed(alpha_abs)
	var unstaged: bool = await _wait_action("unstage")
	_check(unstaged, "the row's Unstage action finishes")
	_check(bool(_last_result.get("ok", false)), "unstaging one file succeeds")
	var unstaged_snapshot: bool = await _wait_snapshot(func(snapshot: Dictionary) -> bool:
		return int(snapshot.get("staged_count", 0)) == 0 and int(snapshot.get("unstaged_count", 0)) >= 1
	, "single file unstaged")
	_check(unstaged_snapshot, "the file returns to the Changes section")
	if !unstaged_snapshot:
		return false

	panel._on_stage_all_pressed()
	var stage_all: bool = await _wait_action("stage_all")
	_check(stage_all, "Stage all finishes for the history test")
	_check(bool(_last_result.get("ok", false)), "Stage all succeeds")
	var all_staged: bool = await _wait_snapshot(func(snapshot: Dictionary) -> bool:
		return int(snapshot.get("staged_count", 0)) >= 1 and int(snapshot.get("unstaged_count", 0)) == 0
	, "all changes staged")
	_check(all_staged, "the commit box now has staged content")
	if !all_staged:
		return false

	panel.commit_edit.text = "UI commit"
	panel._submit_commit()
	var committed: bool = await _wait_action("commit")
	_check(committed, "the commit box finishes the second commit")
	_check(bool(_last_result.get("ok", false)), "the second commit succeeds")
	var clean: bool = await _wait_snapshot(func(snapshot: Dictionary) -> bool:
		var commits := _commits(snapshot)
		return int(snapshot.get("staged_count", 0)) == 0 \
			and int(snapshot.get("unstaged_count", 0)) == 0 \
			and !commits.is_empty() \
			and str((commits[0] as Dictionary).get("subject", "")) == "UI commit"
	, "UI commit history")
	_check(clean, "the second commit is the newest history entry")
	if !clean:
		return false
	_check(panel.commit_edit.text.is_empty(), "the commit box clears after the second commit")
	_check(panel.tabs.get_tab_title(1) == "History", "the history tab is present")
	panel.tabs.current_tab = 1
	_check(await _wait_until(func() -> bool:
		return _contains_label(panel.history_list, "UI commit") \
			and _contains_label(panel.history_list, "Initial commit")
	), "History lists both commits")
	_check(panel.history_list.get_child_count() >= 4, "History renders one block per commit")
	await _capture("04_history")
	panel.tabs.current_tab = 0
	return true


# ── 4. DISCARD FROM THE PANEL ──────────────────────────────────────────────

func _test_discard() -> bool:
	var panel = editor.source_control_panel
	var beta_abs := _abs("beta.txt")
	_check(_write("beta.txt", "changed on disk\n"), "beta.txt is modified outside the editor")
	editor.git_service.refresh(true)

	var changed: bool = await _wait_snapshot(func(snapshot: Dictionary) -> bool:
		var entry := _entry_in(snapshot, "beta.txt")
		return str(entry.get("worktree_status", "")) == "M" and int(snapshot.get("unstaged_count", 0)) >= 1
	, "beta change")
	_check(changed, "the panel receives the second unstaged change")
	if !changed:
		return false

	panel._on_discard_pressed(beta_abs, "beta.txt")
	_check(panel.discard_dialog.visible, "the discard action asks for confirmation")
	_check(panel.discard_dialog.dialog_text.contains("beta.txt"), "the confirmation names the file")
	panel._on_discard_confirmed()
	panel.discard_dialog.hide()
	var discarded: bool = await _wait_action("discard")
	_check(discarded, "Discard finishes through the panel")
	_check(bool(_last_result.get("ok", false)), "Discard succeeds")
	var clean: bool = await _wait_snapshot(func(snapshot: Dictionary) -> bool:
		return int(snapshot.get("unstaged_count", 0)) == 0 and _entry_in(snapshot, "beta.txt").is_empty()
	, "clean after discard")
	_check(clean, "the discarded file leaves the Changes list")
	_check(_read("beta.txt") == INITIAL_BETA, "Discard restores the HEAD copy on disk")
	return true


# ── 5. BEGINNER SAVE POINT ─────────────────────────────────────────────────

func _test_save_point() -> bool:
	var panel = editor.source_control_panel
	var alpha_abs := _abs("alpha.txt")
	var document = editor.documents.find_by_path(alpha_abs)
	if document == null:
		_check(false, "alpha.txt is still open for the save point test")
		return false

	var view = document.view
	view.set_caret_line(view.get_line_count() - 1)
	view.set_caret_column(0)
	view.insert_text_at_caret("omega\n")
	_check(await _wait_until(func() -> bool: return document.modified, 2.0), "typing the final line dirties the buffer")

	editor.create_save_point()
	var saved: bool = await _wait_action("save_point")
	_check(saved, "Save point finishes through the editor")
	_check(bool(_last_result.get("ok", false)), "Save point succeeds")
	var clean: bool = await _wait_snapshot(func(snapshot: Dictionary) -> bool:
		var commits := _commits(snapshot)
		return int(snapshot.get("staged_count", 0)) == 0 \
			and int(snapshot.get("unstaged_count", 0)) == 0 \
			and !commits.is_empty() \
			and str((commits[0] as Dictionary).get("subject", "")).begins_with("Save point: ")
	, "save point commit")
	_check(clean, "Save point creates a timestamped commit and a clean tree")
	if !clean:
		return false
	_check(!document.modified, "Save point saves the open buffer before committing")
	_check(_read("alpha.txt").contains("omega"), "the committed file includes the unsaved edit")
	_check(await _wait_until(func() -> bool:
		return _contains_label(panel.history_list, "Save point: ")
	), "History shows the Save point subject")
	_check(_contains_label(panel.history_list, "UI commit"), "History keeps the earlier commit")
	return true


# ── 6. BRANCH PICKER + HISTORY TAB ─────────────────────────────────────────

func _test_branch_picker_and_history() -> bool:
	var panel = editor.source_control_panel
	var feature := "feature-ui"
	var created := _git(["branch", feature])
	_check(int(created.get("code", -1)) == 0, "the feature branch is created")
	panel.refresh()

	var listed: bool = await _wait_snapshot(func(snapshot: Dictionary) -> bool:
		for item in snapshot.get("branches", []):
			if item is Dictionary and str(item.get("name", "")) == feature:
				return true
		return false
	, "feature branch listed")
	_check(listed, "the snapshot lists the new branch")
	if !listed:
		return false
	_check(await _wait_until(func() -> bool: return _branch_index(panel, feature) >= 0), "the branch picker lists the new branch")

	var feature_index := _branch_index(panel, feature)
	if feature_index < 0:
		return false
	panel._on_branch_selected(feature_index)
	var switched: bool = await _wait_action("switch_branch")
	_check(switched, "selecting a branch in the picker switches branches")
	_check(bool(_last_result.get("ok", false)), "the feature branch switch succeeds")
	var on_feature: bool = await _wait_snapshot(func(snapshot: Dictionary) -> bool:
		return str(snapshot.get("branch", "")) == feature
	, "feature branch snapshot")
	_check(on_feature, "the snapshot reports the feature branch")
	if !on_feature:
		return false
	_check(await _wait_until(func() -> bool:
		return _branch_index(panel, feature) >= 0 \
			and str(panel.branch_picker.get_item_metadata(panel.branch_picker.selected)) == feature
	), "the picker selects the feature branch")

	var main_index := _branch_index(panel, _main_branch)
	_check(main_index >= 0, "the original branch is still in the picker")
	if main_index >= 0:
		panel._on_branch_selected(main_index)
		var back: bool = await _wait_action("switch_branch")
		_check(back, "switching back finishes")
		_check(bool(_last_result.get("ok", false)), "the switch back succeeds")
		var on_main: bool = await _wait_snapshot(func(snapshot: Dictionary) -> bool:
			return str(snapshot.get("branch", "")) == _main_branch
		, "original branch snapshot")
		_check(on_main, "the snapshot reports the original branch again")

	panel.tabs.current_tab = 1
	_check(await _wait_until(func() -> bool:
		return _contains_label(panel.history_list, "Initial commit") \
			and _contains_label(panel.history_list, "UI commit") \
			and _contains_label(panel.history_list, "Save point: ")
	), "the History tab keeps every commit")
	_check(panel.history_list.get_child_count() >= 6, "History renders all three commits")
	return true


# ── SIGNALS ────────────────────────────────────────────────────────────────

func _on_operation_finished(action: String, result: Dictionary) -> void:
	_last_action = action
	_last_result = result


func _on_snapshot_changed(snapshot: Dictionary) -> void:
	_snapshot = snapshot


# ── FINISH + CLEANUP ───────────────────────────────────────────────────────

func _finish() -> void:
	if editor != null and is_instance_valid(editor):
		while editor.documents.count() > 0:
			editor.documents.remove_document(0)
		await _wait_frames(2)
		if editor.git_service != null:
			editor.git_service.set_workspace("")
			await _wait_frames(2)
		if editor.source_control_panel != null:
			editor.source_control_panel.hide_now()

	_remove_dir(_root)

	print("")
	print("Git UI: %d checks, %d failure(s)." % [checks, failures.size()])
	if !failures.is_empty():
		for failure in failures:
			print("  - " + failure)
		print("GIT UI FAILED")
		if editor != null and is_instance_valid(editor) and editor.session != null:
			editor.session.finish_session(editor._snapshot_session())
		quit(1)
		return

	print("GIT UI PASSED")
	if editor != null and is_instance_valid(editor):
		# _finish_quit saves the session, releases the lock, shuts down the
		# terminal/LSP and calls get_tree().quit(). Exit code 0 therefore also
		# verifies the clean-shutdown path.
		editor._finish_quit()
	else:
		quit(0)


func _finish_without_editor() -> void:
	_remove_dir(_root)
	print("")
	print("Git UI: %d checks, %d failure(s)." % [checks, failures.size()])
	print("GIT UI FAILED")
	quit(1)


# ── HELPERS ────────────────────────────────────────────────────────────────

func _check(condition: bool, label: String) -> void:
	checks += 1
	if condition:
		print("PASS  " + label)
	else:
		failures.append(label)
		print("FAIL  " + label)


func _wait_action(action: String, timeout: float = 20.0) -> bool:
	_last_action = ""
	_last_result = {}
	return await _wait_until(func() -> bool: return _last_action == action, timeout)


func _wait_snapshot(predicate: Callable, label: String, timeout: float = 20.0) -> bool:
	var ok: bool = await _wait_until(func() -> bool:
		return bool(_snapshot.get("ok", false)) and bool(predicate.call(_snapshot))
	, timeout)
	if !ok:
		var subjects: Array[String] = []
		for commit in _commits(_snapshot):
			subjects.append(str((commit as Dictionary).get("subject", "")))
		print("  snapshot state for '%s': branch=%s head=%s staged=%d unstaged=%d commits=%s" % [
			label,
			str(_snapshot.get("branch", "")),
			str(_snapshot.get("head", "")),
			int(_snapshot.get("staged_count", 0)),
			int(_snapshot.get("unstaged_count", 0)),
			str(subjects),
		])
	return ok


func _wait_until(predicate: Callable, timeout: float = 20.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(predicate.call()):
			return true
		await process_frame
	return false


func _wait_frames(count: int) -> void:
	for i in range(count):
		await process_frame


func _wait(seconds: float) -> void:
	await create_timer(seconds).timeout


func _capture(name: String) -> void:
	if shots_dir.is_empty():
		return
	if DisplayServer.get_name() == "headless":
		print("WARN  screenshot capture needs a real window: " + name)
		return
	await _wait(0.3)
	await _wait_frames(2)
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	var path := shots_dir.path_join(name + ".png")
	if image.save_png(path) == OK:
		print("SHOT  " + path)
	else:
		print("WARN  could not save screenshot: " + path)


func _entry_in(snapshot: Dictionary, rel: String) -> Dictionary:
	for entry in snapshot.get("files", []):
		if entry is Dictionary and str(entry.get("path", "")) == rel:
			return entry
	return {}


func _commits(snapshot: Dictionary) -> Array:
	return snapshot.get("commits", [])


func _branch_index(panel, name: String) -> int:
	if panel == null or panel.branch_picker == null:
		return -1
	for i in range(panel.branch_picker.item_count):
		if str(panel.branch_picker.get_item_metadata(i)) == name:
			return i
	return -1


func _contains_label(container: Node, needle: String) -> bool:
	if container == null:
		return false
	for child in container.get_children():
		if child is Label and str((child as Label).text).contains(needle):
			return true
		if _contains_label(child, needle):
			return true
	return false


# ── TEMP REPO / FILES ──────────────────────────────────────────────────────

func _make_temp_dir() -> String:
	var base := OS.get_temp_dir().path_join("qorix-git-ui-%d-%d" % [
		int(Time.get_unix_time_from_system()),
		Time.get_ticks_usec(),
	]).replace("\\", "/").trim_suffix("/")
	DirAccess.make_dir_recursive_absolute(base)
	return base


func _abs(name: String) -> String:
	return _root.path_join(name)


func _write(name: String, text: String) -> bool:
	var file := FileAccess.open(_abs(name), FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(text)
	file.close()
	return true


func _read(name: String) -> String:
	if !FileAccess.file_exists(_abs(name)):
		return ""
	return FileAccess.get_file_as_string(_abs(name))


func _git(args: Array) -> Dictionary:
	var output: Array = []
	var git_path := str(editor.git_service.git_path) if editor != null else ""
	if git_path.is_empty():
		return {"code": -1, "output": "git not found"}
	var code := OS.execute(git_path, ["-C", workspace_path] + args, output, true)
	return {"code": code, "output": str(output[0]) if !output.is_empty() else ""}


func _remove_dir(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	# Git marks `.git` hidden on Windows, and DirAccess skips hidden entries by
	# default. It also makes object files read-only, which blocks deletion.
	# Clear both attributes before walking the tree.
	if OS.get_name() == "Windows":
		var ignored: Array = []
		OS.execute("attrib", ["-R", path.path_join("*"), "/S", "/D"], ignored, true)
	dir.include_hidden = true
	dir.list_dir_begin()
	var name := dir.get_next()
	while !name.is_empty():
		if name != "." and name != "..":
			var child := path.path_join(name)
			if dir.current_is_dir():
				_remove_dir(child)
			else:
				DirAccess.remove_absolute(child)
		name = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(path)
