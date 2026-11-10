extends "res://tests/support/test_case.gd"

const RunManagerScript = preload("res://src/features/run/run_manager.gd")


## Only the handful of editor members _final_command()/run() touch. Using the
## real FileManager here would drag the whole scene (and autoloads) into the
## headless runner.
class EditorStub:
	extends RefCounted

	var current_dir: String = ""
	var current_file: String = ""
	var active_view = null

	func warn(_message: String) -> void:
		pass


## Adds the workspace-aware hook the real FileManager exposes.
class WorkspaceEditorStub:
	extends EditorStub

	var workspace_root: String = ""

	func workspace_root_for_tools() -> String:
		return workspace_root


var editor: EditorStub
var run_manager: Node
var windows := OS.get_name() == "Windows"


func before_each() -> void:
	windows = OS.get_name() == "Windows"
	editor = EditorStub.new()
	editor.current_dir = "C:/workspace" if windows else "/workspace"

	run_manager = RunManagerScript.new()
	run_manager.editor = editor


func after_each() -> void:
	run_manager.free()
	editor = null


func _path() -> String:
	return "C:/proj/my file.py" if windows else "/proj/my file.py"


func _quoted(path: String) -> String:
	return '"%s"' % (path.replace("/", "\\") if windows else path)


func _dir_with_slash() -> String:
	return "C:/proj/" if windows else "/proj/"


func _dir_without_slash() -> String:
	return "C:/proj" if windows else "/proj"


func test_executor_without_placeholders_gets_the_quoted_file() -> void:
	var path := _path()
	assert_eq(run_manager._final_command(path, "python -u"), "python -u " + _quoted(path))


func test_empty_executor_gets_only_the_quoted_file() -> void:
	# .bat / .cmd run natively through cmd.exe. A leading space here used to
	# break cmd.exe's parsing, so the result must start with the quote.
	var path := _path()
	assert_eq(run_manager._final_command(path, ""), _quoted(path))


func test_placeholder_substitution_order() -> void:
	var path := _path()
	var command: String = run_manager._final_command(
		path,
		"run $fileNameWithoutExt from $dirWithoutTrailingSlash with $fileName -> $fullFileName"
	)
	var expected := "run my file from %s with my file.py -> %s" % [
		_quoted(_dir_without_slash()),
		_quoted(path),
	]

	assert_eq(command, expected)


func test_dir_placeholder_keeps_trailing_slash() -> void:
	var path := _path()
	var command: String = run_manager._final_command(path, "cd $dir && echo $fileName")
	var expected := "cd %s && echo my file.py" % _quoted(_dir_with_slash())

	assert_eq(command, expected)


func test_workspace_root_placeholder() -> void:
	var path := _path()
	var command: String = run_manager._final_command(path, "cd $workspaceRoot && $fileName")
	var expected := "cd %s && my file.py" % editor.current_dir

	assert_eq(command, expected)


func test_workspace_root_uses_the_open_folder_when_available() -> void:
	var workspace_editor := WorkspaceEditorStub.new()
	workspace_editor.current_dir = editor.current_dir
	workspace_editor.workspace_root = "D:/opened_folder" if windows else "/opened_folder"
	run_manager.editor = workspace_editor

	var command: String = run_manager._final_command(_path(), "cd $workspaceRoot")
	assert_eq(command, "cd " + workspace_editor.workspace_root)
