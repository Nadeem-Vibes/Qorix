extends Node

# Port of vscode-code-runner (formulahendry/code-runner, MIT): a file goes in,
# the shell command that runs it comes out. Like code-runner's runInTerminal
# mode, nothing here spawns or owns processes — the resolved command is typed
# into the live terminal shell, so stdin, colors and REPLs keep working.
# Stop = a real Ctrl+C (ETX) to the foreground process, not a kill.

# Untyped on purpose: the tests drive this with a tiny stub instead of the
# full FileManager scene, so only current_dir/current_file/active_view/warn()
# are used.
var editor

# most recent resolved command (future: rerun last)
var last_command: String = ""

# one keypress can arrive from both the _process poll and the _gui_input poll
# in the same frame (in settings.gd) — the toggles survive that via their
# own guards, so run() needs an equivalent one-press floor, or a second
# identical command gets typed into the shell while it is still echoing
var _last_run_msec: int = 0

# Port of a trimmed code-runner executorMap, keyed by file extension.
# "cd $dir &&" compile chains run inside cmd.exe on Windows — `&&` is native
# there, so code-runner's PowerShell `&&` rewrite is not needed.
const EXECUTORS := {
	"py": "python -u",
	"js": "node",
	"mjs": "node",
	"lua": "lua",
	"rb": "ruby",
	"php": "php",
	"go": "go run",
	"pl": "perl",
	"r": "Rscript",
	"sh": "bash",
	"bat": "",
	"cmd": "",
	"ps1": "powershell -ExecutionPolicy ByPass -File",
	"dart": "dart run",
	"zig": "zig run",
	"nim": "nim compile --verbosity:0 --hints:off --run",
	"hs": "runghc",
	"gleam": "gleam run -m $fileNameWithoutExt",
	"exs": "elixir",
	"rust": "cd $dir && rustc $fileName && $dir$fileNameWithoutExt",
	"c": "cd $dir && gcc $fileName -o $fileNameWithoutExt && $dir$fileNameWithoutExt",
	"cpp": "cd $dir && g++ $fileName -o $fileNameWithoutExt && $dir$fileNameWithoutExt",
	"cc": "cd $dir && g++ $fileName -o $fileNameWithoutExt && $dir$fileNameWithoutExt",
	"cxx": "cd $dir && g++ $fileName -o $fileNameWithoutExt && $dir$fileNameWithoutExt",
	"java": "cd $dir && javac $fileName && java $fileNameWithoutExt",
}

func run(file_path: String = "") -> void:
	var now := Time.get_ticks_msec()
	if now - _last_run_msec < 300:
		return
	_last_run_msec = now

	if file_path.is_empty():
		file_path = editor.current_file
	if file_path.is_empty():
		editor.warn("[color=yellow]WARNING[/color]: Nothing to run — no file is open.")
		return

	# code-runner's saveFileBeforeRun: run what's on screen, not stale disk state
	if _setting_bool("save_before_run", true) and file_path == editor.current_file:
		editor.save_current()

	var executor = _resolve_executor(file_path)
	if executor == null:
		editor.warn("[color=yellow]WARNING[/color]: No executor for .%s files — add one to RunManager.EXECUTORS." % file_path.get_extension())
		return

	last_command = _final_command(file_path, executor)
	if editor.terminal == null:
		push_warning("[run] terminal panel missing")
		return

	# open() is fire-and-forget on purpose: it settles the terminal grid, and
	# run_command() queues anything typed before the shell is up (same pattern
	# the palette's "Open terminal in file's folder" uses)
	editor.terminal.open()
	editor.terminal.run_command(last_command)

func stop() -> void:
	# code-runner tree-kills its spawned child; with a real PTY the equivalent
	# of a human pressing Ctrl+C is writing ETX (03) to the shell — interrupts
	# the foreground process while the shell itself stays alive.
	if editor.terminal == null: return
	# Ctrl+C goes to whichever terminal tab is selected
	var session = editor.terminal.get_active_session()
	if session != null and session.running:
		session.write(PackedByteArray([3]))

# EXECUTOR RESOLUTION ─────────────────────────────────────────────

func _resolve_executor(file_path: String):
	# code-runner's chain, phase 1: shebang (respectShebang) wins, then the
	# extension map. A glob map and per-language pick come in a later phase.
	if _setting_bool("respect_shebang", true):
		var bang := _shebang(file_path)
		if !bang.is_empty():
			return bang
	return EXECUTORS.get(file_path.get_extension().to_lower())

func _shebang(file_path: String) -> String:
	var first := ""
	if file_path == editor.current_file:
		# first line of the live buffer — get_line() lives on CodeEdit, not String
		var view = editor.active_view
		if view != null and view.get_line_count() > 0:
			first = view.get_line(0)
	elif FileAccess.file_exists(file_path):
		var f := FileAccess.open(file_path, FileAccess.READ)
		if f != null:
			first = f.get_line()

	# `#![...]` is a Rust attribute, not a shebang (code-runner's ^#!(?!\[) rule)
	if first.begins_with("#!") and !first.begins_with("#!["):
		return first.substr(2).strip_edges()
	return ""

# PLACEHOLDER SUBSTITUTION ────────────────────────────────────────

func _final_command(file_path: String, executor: String) -> String:
	var win := OS.get_name() == "Windows"
	# the editor tracks paths with forward slashes; cmd.exe wants backslashes
	# (terminal_session applies the same rule to its cwd)
	var q = func(s: String) -> String:
		return '"%s"' % (s.replace("/", "\\") if win else s)

	# code-runner's $dir has a trailing slash: `$dir$fileNameWithoutExt` is one
	# concatenated path; `$dirWithoutTrailingSlash` strips it again
	var dir_slash: String = file_path.get_base_dir()
	if dir_slash.is_empty(): dir_slash = editor.current_dir
	dir_slash += "/"

	# code-runner's $workspaceRoot is the opened folder, which is not always
	# the folder of the current file. The test stub only has current_dir.
	var workspace_root: String = editor.current_dir
	if editor.has_method("workspace_root_for_tools"):
		var resolved := str(editor.workspace_root_for_tools())
		if !resolved.is_empty():
			workspace_root = resolved

	# substitution order matters — $fileNameWithoutExt, $fullFileName and
	# $dirWithoutTrailingSlash each contain a shorter placeholder as a prefix
	var cmd := executor
	cmd = cmd.replace("$workspaceRoot", workspace_root)
	cmd = cmd.replace("$fileNameWithoutExt", file_path.get_file().get_basename())
	cmd = cmd.replace("$fullFileName", q.call(file_path))
	cmd = cmd.replace("$fileName", file_path.get_file())
	cmd = cmd.replace("$dirWithoutTrailingSlash", q.call(dir_slash.trim_suffix("/")))
	cmd = cmd.replace("$dir", q.call(dir_slash))

	# executor had no placeholders → append the quoted file (code-runner rule).
	# An empty executor (bat/cmd run natively) must get the bare quoted file:
	# " file.bat" starting with a space breaks cmd.exe's command parsing
	if cmd == executor:
		if executor.is_empty():
			cmd = q.call(file_path)
		else:
			cmd = "%s %s" % [executor, q.call(file_path)]
	return cmd

# SETTINGS ────────────────────────────────────────────────────────

func _setting_bool(property: String, fallback: bool) -> bool:
	# Resolved dynamically rather than through the LuaSingleton identifier so
	# the headless test runner can compile this script without autoloads.
	var singleton = get_node_or_null("/root/LuaSingleton")
	if singleton == null:
		return fallback

	# same lookup shape the palette uses: [setting_dict, index], {} / -1 when absent
	var found = singleton.get_setting(property)
	return bool(found[0].get("value", fallback))
