class_name TerminalSession
extends Node

# One live shell attached to a pseudoterminal (godot-xterm PTY node).
# The terminal panel owns rendering; this node owns the process: shell
# selection, working directory, fork/kill, and clean signal re-emission.
#
# The PTY class comes from the godot-xterm GDExtension, so it is resolved
# dynamically: if the extension isn't loaded (e.g. the editor hasn't been
# restarted since the addon was added) this node degrades to a no-op instead
# of failing to compile and taking the whole HUD down with it.

signal data_received(data: PackedByteArray)
signal exited(exit_code: int, signal_code: int)
signal started(shell: String, cwd: String)

## How long Windows' console teardown must rest after a shell dies before a
## respawned PTY gets a working stdin. Forking earlier can yield a silent
## shell that reads EOF and exits ~instantly (verified: 750 ms still breaks,
## 2000 ms is reliable).
const RESPAWN_SETTLE_MS := 2000

var pty  # PTY (gdextension) — untyped so the script compiles without the addon
var shell: String = ""
var cwd: String = ""
var running: bool = false
var last_exit_code: int = 0
var last_signal: int = 0
var died_msec: int = 0  # Time.get_ticks_msec() of the most recent shell death

func start(p_cols: int, p_rows: int, p_cwd: String) -> bool:
	if running:
		return true

	# "Terminal Shell" is a user setting, never a project file: a repository
	# must not be able to choose the program this starts.
	var configured := _configured_shell()
	if !configured.is_empty():
		return await _begin(configured, PackedStringArray(), p_cwd, p_cols, p_rows)

	if OS.get_name() == "Windows":
		return await _begin("cmd.exe", PackedStringArray(), p_cwd, p_cols, p_rows)
	var preferred := OS.get_environment("SHELL") if OS.has_environment("SHELL") else "/bin/sh"
	return await _begin(preferred, PackedStringArray(), p_cwd, p_cols, p_rows)


## Resolves the panel's setting through the autoload by name so this script
## still compiles in headless callers that have no LuaSingleton.
func _configured_shell() -> String:
	var lua = get_node_or_null("/root/LuaSingleton")
	if lua == null or !lua.has_method("get_setting"):
		return ""
	var found: Array = lua.get_setting("terminal_shell")
	if found.size() < 2 or int(found[1]) == -1:
		return ""
	var entry: Variant = found[0]
	if entry is Dictionary:
		return str((entry as Dictionary).get("value", "")).strip_edges()
	return ""


## Starts one non-interactive command in a PTY. RunService uses this for the
## captured Run panel: the shell that wraps the command exits when the program
## does, so PTY.exited carries the program's real exit status and there is no
## prompt/echo noise to strip. The visible terminal's start() path is untouched.
func start_command(executable: String, args: PackedStringArray, p_cwd: String, p_cols: int = 200, p_rows: int = 50) -> bool:
	if running:
		return true
	return await _begin(executable, args, p_cwd, p_cols, p_rows)


func _begin(executable: String, args: PackedStringArray, p_cwd: String, p_cols: int, p_rows: int) -> bool:
	# A PTY node can only ever fork once: its reader thread and uv pipes stay
	# bound to the previous process, so a second fork on the same node fails
	# with "EBUSY: resource busy or locked" + "Thread already started". Every
	# start therefore gets a brand-new PTY — the same lifecycle godot-xterm's
	# own editor terminal uses (one PTY instance per terminal, never reused).
	# free() (not queue_free) so the old PTY is fully torn down — thread joined,
	# ConPTY closed — BEFORE the new one forks, never in the same frame.
	var respawn := pty != null
	if respawn:
		pty.free()
		pty = null

	if !ClassDB.class_exists("PTY"):
		push_warning("[terminal] godot-xterm PTY class not loaded — restart the editor once.")
		return false

	pty = ClassDB.instantiate("PTY")
	pty.name = "PTY"
	pty.use_threads = true
	add_child(pty)

	pty.data_received.connect(_on_data_received)
	# tag the sender so a stale exit notice from a replaced PTY can be ignored
	pty.exited.connect(_on_exited.bind(pty))

	shell = executable
	if OS.get_name() == "Windows":
		# ConPTY's CreateProcess wants backslashes in the working directory;
		# the editor tracks paths with forward slashes ("C:/").
		cwd = (p_cwd if !p_cwd.is_empty() else "C:\\").replace("/", "\\")
	else:
		cwd = p_cwd if !p_cwd.is_empty() else "/"

	# respawning right after a shell died races the console teardown; wait out
	# only the remaining time — reopening long after a death forks instantly
	if respawn and died_msec > 0:
		var settle: int = died_msec + RESPAWN_SETTLE_MS - Time.get_ticks_msec()
		if settle > 0:
			await get_tree().create_timer(settle / 1000.0).timeout
			if !is_inside_tree():
				return false

	# PTY.fork(file, args, cwd, cols, rows): a real shell in a real terminal —
	# prompts, echo and colors come from the shell itself, nothing is faked.
	var err: int = pty.fork(shell, args, cwd, maxi(p_cols, 1), maxi(p_rows, 1))
	running = err == 0

	if running:
		started.emit(shell, cwd)
	else:
		push_warning("Terminal: failed to fork \"%s\" in \"%s\" (error %d)" % [shell, cwd, err])

	return running

func write(data: Variant) -> void:
	if running and pty != null:
		pty.write(data)

func resizev(size: Vector2i) -> void:
	if running and pty != null:
		pty.resizev(size)

func kill() -> void:
	# 15 = SIGTERM; literal so this script never needs the addon at parse time
	if running and pty != null:
		pty.kill(15)
	running = false
	died_msec = Time.get_ticks_msec()

func _on_data_received(data: PackedByteArray) -> void:
	data_received.emit(data)

func _on_exited(exit_code: int, signal_code: int, from_pty) -> void:
	if from_pty != pty:
		return  # stale exit notification from a replaced PTY
	running = false
	last_exit_code = exit_code
	last_signal = signal_code
	died_msec = Time.get_ticks_msec()
	exited.emit(exit_code, signal_code)
