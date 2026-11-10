extends SceneTree

## End-to-end LSP acceptance run against the real editor scene and a fake
## server. It covers the full vertical slice: process launch, initialize,
## document sync, diagnostics, completion, hover, definition, references,
## formatting, rename preview/apply, code actions, signature help, crash
## restart and the missing-server install card.
##
##   godot --headless --path . --script res://tests/integration/lsp_e2e_runner.gd -- \
##       --workspace="C:/temp/qorix-lsp-e2e" --keep
##
## Pass `--python=<absolute path>` when the `python` on PATH is a launcher that
## cannot run under the sandboxed APPDATA used for testing.
##
## Exit code 0 = all checks passed (or the run was skipped because Python is
## unavailable), 1 = at least one failure.

const LspText = preload("res://src/features/lsp/lsp_text.gd")
const RuntimeCatalog = preload("res://src/features/run/runtime_catalog.gd")

var checks: int = 0
var failures: int = 0
var editor = null
var workspace_path: String = ""
var transcript_path: String = ""
var fake_server_path: String = ""
var created_workspace: bool = false
var keep_workspace: bool = false
var skipped: bool = false
var python_path: String = ""


func _initialize() -> void:
	_run()


func _run() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--workspace="):
			workspace_path = argument.trim_prefix("--workspace=")
		elif argument.begins_with("--transcript="):
			transcript_path = argument.trim_prefix("--transcript=")
		elif argument.begins_with("--python="):
			python_path = argument.trim_prefix("--python=")
		elif argument == "--keep":
			keep_workspace = true

	if !_prepare_workspace():
		_finish(0 if skipped else 1)
		return

	await process_frame
	editor = await _boot_editor()
	if editor == null:
		print("FAIL  the editor scene did not boot")
		failures += 1
		await _finish(1)
		return

	await _stop_background_work()
	# Trust the fixture before opening it (mirrors the user's one-click
	# "Trust folder"): project-level LSP config naming the fake server is
	# only honoured for trusted folders, and this one is fully runner-owned.
	if editor.has_method("is_workspace_trusted") and !editor.is_workspace_trusted(workspace_path):
		var trust_result: Dictionary = editor.trust_service.trust(workspace_path)
		if !bool(trust_result.get("ok", false)):
			print("FAIL  could not trust the test workspace")
			failures += 1
	editor.set_workspace(workspace_path, false)
	await _wait_frames(5)
	editor.open_file(workspace_path.path_join("main.py"))
	await _wait_frames(4)
	editor.lsp_manager.sync_open_documents()
	editor.lsp_manager.ensure_active_client()

	await _test_server_startup()
	await _test_diagnostics()
	await _test_completion()
	await _test_hover_and_navigation()
	await _test_formatting_and_signature()
	await _test_rename()
	await _test_code_actions()
	await _test_crash_restart()
	await _test_missing_server()
	await _test_shutdown()

	await _finish(0 if failures == 0 else 1)


# ── SETUP ───────────────────────────────────────────────────────────────────

func _prepare_workspace() -> bool:
	fake_server_path = ProjectSettings.globalize_path("res://tests/fixtures/fake_lsp_server.py")
	if !FileAccess.file_exists(fake_server_path):
		print("SKIP  fake LSP server fixture is missing: " + fake_server_path)
		skipped = true
		return false

	var catalog = RuntimeCatalog.new()
	var python_command := python_path.strip_edges()
	if python_command.is_empty():
		python_command = catalog.find_executable("python")
	elif !python_command.contains("/") and !python_command.contains("\\"):
		# A bare name is still resolved through the editor's own lookup so the
		# test covers command resolution rather than cmd's search rules.
		var resolved := catalog.find_executable(python_command)
		if !resolved.is_empty():
			python_command = resolved
	if python_command.is_empty():
		print("SKIP  Python is not on PATH; install Python or pass --python=<path>.")
		skipped = true
		return false
	print("INFO  python: " + python_command)

	if workspace_path.is_empty():
		workspace_path = OS.get_temp_dir().path_join(
			"qorix_lsp_e2e_%d_%d" % [OS.get_process_id(), Time.get_ticks_msec()]
		)
		created_workspace = true
	workspace_path = workspace_path.replace("\\", "/")
	DirAccess.make_dir_recursive_absolute(workspace_path)
	if transcript_path.is_empty():
		transcript_path = workspace_path.path_join("lsp-transcript.jsonl")
	transcript_path = transcript_path.replace("\\", "/")
	if FileAccess.file_exists(transcript_path):
		DirAccess.remove_absolute(transcript_path)

	_write("pyproject.toml", "[project]\nname = \"qorix-lsp-e2e\"\n")
	_write("main.py", "def greet(name):\n"
		+ "    return \"Hello \" + name\n"
		+ "\n"
		+ "\n"
		+ "def main():\n"
		+ "    print(greet(\"world\"))\n"
		+ "    missing_symbol  # TODO: remove\n")
	_write("helper.py", "from main import greet\n"
		+ "\n"
		+ "def shout():\n"
		+ "    return greet(\"!\").upper()\n")
	_write("broken.c", "int main(void) { return 0; }\n")

	var config := {
		"lsp": {
			"python": {
				"command": python_command,
				"args": [fake_server_path, "--transcript=" + transcript_path],
				"root_markers": ["pyproject.toml"],
			},
			"cpp": {
				"command": "definitely-not-installed-griddycode",
			},
		},
	}
	_write(".griddycode.json", JSON.stringify(config, "\t", false))
	print("INFO  workspace: " + workspace_path)
	print("INFO  transcript: " + transcript_path)
	return true


func _write(name: String, text: String) -> void:
	var path := workspace_path.path_join(name)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file = null


func _boot_editor():
	var packed: PackedScene = load("res://src/main/editor.tscn")
	if packed == null:
		return null
	var instance = packed.instantiate()
	root.add_child(instance)
	current_scene = instance
	await _wait_frames(10)

	# The welcome picker covers the editor on a fresh profile.
	if instance.overlays != null and instance.overlays.is_open(instance.file_dialog):
		instance.overlays.close(instance.file_dialog)
		await _wait_frames(20)
	return instance


func _stop_background_work() -> void:
	if editor.session_timer != null:
		editor.session_timer.stop()
	if editor.external_timer != null:
		editor.external_timer.stop()
	var autosave = editor.get_node_or_null("AutoSaveTimer")
	if autosave != null:
		autosave.stop()


# ── FEATURES ────────────────────────────────────────────────────────────────

func _test_server_startup() -> void:
	var manager = editor.lsp_manager
	var ready := await _wait_until(func() -> bool:
		return _ready_client(manager) != null
	, 600)
	_check(ready, "the fake Python server starts and initializes")

	if !ready:
		_dump_lsp_state()
		return

	var rows: Array = manager.server_rows()
	var python_row := {}
	for row in rows:
		if str(row.get("id", "")) == "python":
			python_row = row
	_check(!python_row.is_empty(), "the Servers list contains Python")
	_check(bool(python_row.get("found", false)), "the Server list resolves the Python command")
	_check(bool(python_row.get("ready", false)), "the Server list shows the Python server as ready")
	var logged := await _wait_until(func() -> bool:
		return manager.server_log().contains("Fake LSP is ready.")
	, 300)
	_check(logged, "window/logMessage reaches the LSP log")
	_check(manager.problem_counts().get("total") != null, "problem counts are available")


func _test_diagnostics() -> void:
	var manager = editor.lsp_manager
	var got := await _wait_until(func() -> bool:
		return int(manager.problem_counts().get("total", 0)) >= 2
	, 300)
	_check(got, "publishDiagnostics reaches the Problems data")

	var counts: Dictionary = manager.problem_counts()
	_check(int(counts.get("error", 0)) >= 1, "the undefined name is reported as an error")
	_check(int(counts.get("warning", 0)) >= 1, "the TODO is reported as a warning")

	var view = editor.active_view
	if view != null:
		_check(view._worst_diagnostics.has(6), "the editor paints a gutter mark on the diagnostic line")
		_check(view._last_diagnostics.size() >= 2, "the editor keeps every diagnostic for the line")
		_check(view._lsp_gutter >= 0, "the LSP gutter exists")
		_check(view.get_gutter_width(view._lsp_gutter) <= 16, "the LSP gutter stays compact")
		var gutter_count: int = view.get_gutter_count()
		view.set_action_available(true, 5)
		_check(view.get_gutter_count() == gutter_count, "the lightbulb reuses the diagnostic gutter")
		_check(view.get_line_gutter_text(5, view._lsp_gutter) == "✦", "the lightbulb paints in the shared gutter")
		view.set_action_available(false)

	editor.open_lsp_panel(0)
	await _wait(0.25)
	editor.lsp_panel.refresh()
	var panel = editor.lsp_panel
	_check(panel.visible, "the LSP panel opens on the Problems tab")
	_check(panel._current_tab == 0, "the Problems tab is selected")
	_check(panel._problem_list.item_count >= 2, "the Problems list shows both diagnostics")
	_check(str(panel._header_status.text).contains("error"), "the Problems header counts errors")


func _test_completion() -> void:
	var manager = editor.lsp_manager
	var view = editor.active_view
	if view == null:
		_check(false, "an active view exists for completion")
		return

	editor.editor_host.grab_active_focus()
	view.grab_focus()
	view.set_caret_line(5)
	view.set_caret_column(10)
	await _wait_frames(2)

	# GDScript lambdas capture variables by value. Mutate the captured Array
	# instead of reassigning it, or the local below stays empty.
	var items: Array = []
	var requested: bool = manager.request_completion(view, 5, 10, func(received: Array) -> void:
		items.append_array(received)
	)
	_check(requested, "the completion request is sent")
	var got := await _wait_until(func() -> bool: return !items.is_empty(), 300)
	_check(got, "the server returns completion items")
	_check(_has_completion(items, "greet"), "completion includes the server's greet function")
	_check(_has_completion(items, "greeting"), "completion includes a variable")

	# The Lua pass and the LSP pass share one popup. Exercise the merge with
	# the real view so duplicate labels are impossible.
	view._completion_labels.clear()
	view._merge_lsp_completion(items, 5, 10, 0)
	_check(view._completion_labels.size() > 0, "LSP items merge into the code-completion popup")
	_check(view._completion_labels.has("greet\ngreet(name)"), "snippet insert text arrives as greet(name)")


func _test_hover_and_navigation() -> void:
	var manager = editor.lsp_manager
	var view = editor.active_view
	if view == null:
		_check(false, "an active view exists for hover")
		return

	manager.request_hover(view, 5, 11, true)
	var hovered := await _wait_until(func() -> bool: return editor.lsp_hover_panel.visible, 300)
	_check(hovered, "hover opens a floating card")
	if hovered:
		_check(str(editor.lsp_hover_panel._label.text).contains("greet"), "hover renders the markdown symbol")
	manager.hide_hover()

	view.set_caret_line(5)
	view.set_caret_column(11)
	manager.request_definition(view)
	var defined := await _wait_until(func() -> bool:
		return view.get_caret_line() == 0 and view.get_caret_column() == 4
	, 300)
	_check(defined, "go-to-definition moves the caret to the declaration")

	view.set_caret_line(0)
	view.set_caret_column(4)
	manager.request_references(view)
	var references := await _wait_until(func() -> bool: return editor.lsp_picker.visible, 300)
	_check(references, "find-references opens the location picker")
	if references:
		_check(editor.lsp_picker._items.size() == 2, "the picker lists both reference locations")
		_check(str(editor.lsp_picker._title.text).contains("References (2)"), "the picker counts references")
		editor.lsp_picker.close_now()


func _test_formatting_and_signature() -> void:
	var manager = editor.lsp_manager
	var view = editor.active_view
	if view == null:
		_check(false, "an active view exists for formatting")
		return

	manager.request_formatting(view)
	var formatted := await _wait_until(func() -> bool:
		return str(view.text).contains("Hi") and !str(view.text).contains("Hello")
	, 300)
	_check(formatted, "formatting applies the server's text edits")
	_check(bool(view.document.modified), "formatting leaves the buffer dirty so it can be undone/saved")
	await _wait(0.3)

	view.set_caret_line(5)
	view.set_caret_column(10)
	manager.schedule_signature(view, true)
	var signature := await _wait_until(func() -> bool: return editor.lsp_signature_panel.visible, 300)
	_check(signature, "signature help opens inside a call")
	if signature:
		var rendered := str(editor.lsp_signature_panel._label.text)
		_check(rendered.contains("greet(") and rendered.contains("name: str"), "signature help shows the parameter")
	manager.hide_signature()


func _test_rename() -> void:
	var manager = editor.lsp_manager
	var view = editor.active_view
	if view == null:
		_check(false, "an active view exists for rename")
		return

	view.set_caret_line(0)
	view.set_caret_column(4)
	manager.request_rename(view)
	_check(manager._rename_dialog.visible, "rename opens the name dialog")
	manager._on_rename_submitted("welcome")

	var previewed := await _wait_until(func() -> bool: return manager._workspace_preview.visible, 300)
	_check(previewed, "a multi-file rename opens the workspace-edit preview")
	if previewed:
		_check(manager._workspace_preview._entries.size() == 2, "the preview lists both changed files")
		_check(str(manager._workspace_preview.title).contains("welcome"), "the preview names the new symbol")
	manager._apply_pending_workspace_edit()
	await _wait_frames(4)

	_check(str(view.text).contains("welcome"), "rename updates the open buffer in memory")
	var helper := workspace_path.path_join("helper.py")
	var helper_text := FileAccess.get_file_as_string(helper)
	_check(helper_text.contains("welcome"), "rename writes the unopened file to disk")


func _test_code_actions() -> void:
	var manager = editor.lsp_manager
	var view = editor.active_view
	if view == null:
		_check(false, "an active view exists for code actions")
		return

	view.set_caret_line(0)
	view.set_caret_column(4)
	manager.request_code_actions(view, 0, 4, true)
	var shown := await _wait_until(func() -> bool: return editor.lsp_picker.visible, 300)
	_check(shown, "code actions open the picker")
	if !shown:
		return
	var actions: Array = editor.lsp_picker._items.duplicate()
	_check(actions.size() >= 4, "the server's code actions are listed")
	editor.lsp_picker.close_now()

	if actions.size() >= 1:
		manager.apply_code_action(actions[0])
		var applied := await _wait_until(func() -> bool: return str(view.text).contains("# helper action"), 300)
		_check(applied, "a code action with a WorkspaceEdit applies immediately")
	if actions.size() >= 2:
		manager.apply_code_action(actions[1])
		var explained := await _wait_until(func() -> bool: return str(view.text).contains("# explained"), 300)
		_check(explained, "a command code action applies the edit returned by executeCommand")
	if actions.size() >= 3:
		manager.apply_code_action(actions[2])
		var server_edit := await _wait_until(func() -> bool: return str(view.text).contains("# applied by server"), 300)
		_check(server_edit, "workspace/applyEdit from the server reaches the buffer")
		await _wait(0.2)
		_check(_transcript_has_response(700, true), "the editor acknowledges workspace/applyEdit")
	if actions.size() >= 4:
		manager.apply_code_action(actions[3])
		var resolved := await _wait_until(func() -> bool: return str(view.text).contains("# resolved action"), 300)
		_check(resolved, "codeAction/resolve applies the completed action")


func _test_crash_restart() -> void:
	var manager = editor.lsp_manager
	var view = editor.active_view
	if view == null:
		_check(false, "an active view exists for crash recovery")
		return

	var last_line: int = view.get_line_count() - 1
	view.insert_text("\n# crash\n", last_line, 0)
	var restarted := await _wait_until(func() -> bool:
		return _ready_client(manager) != null and manager.server_log().contains("Exited unexpectedly")
	, 600)
	_check(restarted, "an unexpected server exit restarts the server")
	_check(manager.client_count() >= 1, "the restarted server is running")
	if restarted:
		var diagnostics := await _wait_until(func() -> bool:
			return int(manager.problem_counts().get("total", 0)) >= 1
		, 300)
		_check(diagnostics, "the restarted server republishes diagnostics")


func _test_missing_server() -> void:
	var manager = editor.lsp_manager
	editor.open_file(workspace_path.path_join("broken.c"))
	await _wait_frames(5)
	var cards: Array = manager.install_cards()
	_check(!cards.is_empty(), "a missing C/C++ server produces an install card")
	_check(editor.lsp_panel.visible, "the missing-server notice opens the LSP panel")
	await _wait(0.25)
	editor.lsp_panel.refresh()
	_check(editor.lsp_panel._current_tab == 1, "the install card opens the Servers tab")
	_check(editor.lsp_panel._install_box.get_child_count() > 0, "the install card is rendered")

	var cpp := {}
	for row in manager.server_rows():
		if str(row.get("id", "")) == "cpp":
			cpp = row
	_check(!cpp.is_empty(), "the Servers list contains C/C++")
	_check(!bool(cpp.get("found", true)), "the Servers list reports the missing C/C++ command")

	var session: Dictionary = editor.lsp_panel.capture_session()
	_check(session.has("open") and session.has("tab"), "the LSP panel captures its session state")


func _test_shutdown() -> void:
	var manager = editor.lsp_manager
	manager.shutdown()
	var stopped := await _wait_until(func() -> bool: return manager.client_count() == 0, 180)
	_check(stopped, "shutdown stops every language server")


# ── HELPERS ─────────────────────────────────────────────────────────────────

func _check(condition: bool, label: String) -> void:
	checks += 1
	if condition:
		print("PASS  " + label)
	else:
		failures += 1
		print("FAIL  " + label)


func _ready_client(manager):
	if manager == null:
		return null
	for client in manager._clients.values():
		if is_instance_valid(client) and client.is_ready():
			return client
	return null


func _has_completion(items: Array, label: String) -> bool:
	for item in items:
		if item is Dictionary and str(item.get("label", "")) == label:
			return true
	return false


func _transcript_has_response(request_id: int, applied: bool) -> bool:
	if !FileAccess.file_exists(transcript_path):
		return false
	var text := FileAccess.get_file_as_string(transcript_path)
	for line in text.split("\n"):
		if line.strip_edges().is_empty():
			continue
		var parsed: Variant = JSON.parse_string(line)
		if !(parsed is Dictionary):
			continue
		var message: Variant = parsed.get("message")
		if !(message is Dictionary):
			continue
		if int(message.get("id", -1)) != request_id:
			continue
		var result: Variant = message.get("result")
		if result is Dictionary and bool(result.get("applied", false)) == applied:
			return true
	return false


func _dump_lsp_state() -> void:
	var manager = editor.lsp_manager
	print("---- LSP state ----")
	print(manager.server_log())
	if FileAccess.file_exists(transcript_path):
		print("---- transcript tail ----")
		var lines := FileAccess.get_file_as_string(transcript_path).split("\n")
		var start := maxi(0, lines.size() - 30)
		for index in range(start, lines.size()):
			if !lines[index].strip_edges().is_empty():
				print(lines[index])


func _wait_frames(count: int) -> void:
	for i in range(count):
		await process_frame


func _wait(seconds: float) -> void:
	await create_timer(seconds).timeout


func _wait_until(predicate: Callable, max_frames: int = 600) -> bool:
	for i in range(max_frames):
		if predicate.call():
			return true
		await process_frame
	return false


func _finish(code: int) -> void:
	if editor != null and is_instance_valid(editor):
		if editor.lsp_manager != null:
			editor.lsp_manager.shutdown()
		if editor.terminal != null:
			editor.terminal.shutdown()
		editor.queue_free()
		await _wait_frames(4)
		editor = null

	if created_workspace and !keep_workspace:
		_remove_dir(workspace_path)

	print("")
	if skipped:
		print("LSP end-to-end run skipped.")
	elif failures == 0:
		print("All LSP end-to-end checks passed: %d checks." % checks)
	else:
		print("%d of %d LSP end-to-end checks failed." % [failures, checks])
	quit(code)


func _remove_dir(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	for file in dir.get_files():
		DirAccess.remove_absolute(path.path_join(file))
	for folder in dir.get_directories():
		_remove_dir(path.path_join(folder))
	DirAccess.remove_absolute(path)
