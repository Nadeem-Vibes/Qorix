extends Node

## Async Git facade for Phase 6.
##
## Every git process runs on one worker thread. The UI thread only receives
## parsed snapshots through signals, so `git status` on a huge repository can
## take as long as it needs without freezing typing or the camera.
##
## Credentials are never read, written or cached here. Git's own credential
## helper handles authentication exactly as it does in a terminal.

signal repo_changed(root: String)
signal snapshot_changed(snapshot: Dictionary)
signal head_changed
signal operation_started(action: String)
signal operation_finished(action: String, result: Dictionary)
signal baseline_ready(path: String, result: Dictionary)
signal diff_ready(path: String, result: Dictionary)

const StatusParser = preload("res://src/features/git/git_status_parser.gd")
const DiffParser = preload("res://src/features/git/git_diff.gd")
const RuntimeCatalog = preload("res://src/features/run/runtime_catalog.gd")
const Paths = preload("res://src/base/path_utils.gd")

const MAX_BASELINE_CHARS := 4 * 1024 * 1024
const LOG_COUNT := 50
const DIFF_CONTEXT := 3

var repo_root: String = ""
var workspace_path: String = ""
var git_path: String = ""
var last_snapshot: Dictionary = {}

var _catalog = null
var _thread: Thread = null
var _mutex := Mutex.new()
var _semaphore := Semaphore.new()
var _queue: Array = []
var _running: bool = true
var _thread_started: bool = false

var _generation: int = 0
var _baseline_epoch: int = 0
var _last_head: String = ""
var _pending_status: bool = false
var _status_dirty: bool = false
var _pending_baselines: Dictionary = {}
var _baseline_cache: Dictionary = {}
var _pending_diff: Dictionary = {}
var _pending_actions: int = 0


func _ready() -> void:
	# Git must never block on an interactive credential prompt from a GUI app:
	# there is no terminal to answer it, so the worker thread would hang
	# forever (and _exit_tree blocks on it). Credential helpers still work;
	# the prompt itself converts to an immediate error.
	if OS.get_environment("GIT_TERMINAL_PROMPT").is_empty():
		OS.set_environment("GIT_TERMINAL_PROMPT", "0")
	_catalog = RuntimeCatalog.new()
	git_path = _catalog.find_executable("git")
	_thread = Thread.new()
	var error := _thread.start(_worker_loop)
	_thread_started = error == OK
	if !_thread_started:
		push_warning("[git] could not start the worker thread (error %d)" % error)


func _exit_tree() -> void:
	_mutex.lock()
	_running = false
	_mutex.unlock()
	_semaphore.post()
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()
	_thread_started = false


# ── PUBLIC STATE ────────────────────────────────────────────────────────────

func has_git() -> bool:
	return !git_path.is_empty()


func has_repo() -> bool:
	return !repo_root.is_empty()


func is_busy() -> bool:
	return _pending_actions > 0


func repo_name() -> String:
	if repo_root.is_empty():
		return ""
	return repo_root.get_file() if !repo_root.get_file().is_empty() else repo_root


func set_workspace(path: String) -> void:
	workspace_path = Paths.normalize(path)
	var root := find_repo_root(workspace_path)
	if root == repo_root:
		return

	repo_root = root
	_generation += 1
	_baseline_epoch += 1
	_baseline_cache.clear()
	_pending_baselines.clear()
	_pending_diff.clear()
	_pending_status = false
	_status_dirty = false
	_last_head = ""
	last_snapshot = {}
	repo_changed.emit(repo_root)

	if repo_root.is_empty():
		snapshot_changed.emit(_empty_snapshot("No Git repository found."))
		return
	refresh(true)


func refresh(force: bool = false) -> void:
	if repo_root.is_empty() or git_path.is_empty():
		if repo_root.is_empty():
			snapshot_changed.emit(_empty_snapshot("No Git repository found."))
		else:
			snapshot_changed.emit(_empty_snapshot("Git was not found on PATH."))
		return
	if _pending_status:
		# A forced refresh usually follows an action. Do not drop it just
		# because the periodic poll is still running: queue one more pass after
		# that snapshot lands, otherwise the panel can sit on pre-action data.
		if force:
			_status_dirty = true
		return

	_pending_status = true
	var commands := [
		_command(["-c", "core.quotepath=false", "status", "--porcelain=v2", "--branch"]),
		_command(["branch", "--format=%(refname:short)%1f%(HEAD)%1f%(upstream:short)%1f%(committerdate:unix)"], true),
		_command(["log", "-n", str(LOG_COUNT), "--pretty=format:%H%x1f%h%x1f%an%x1f%ae%x1f%at%x1f%ar%x1f%D%x1f%s%x1e"], true),
		_command(["remote"], true),
	]
	_enqueue({
		"kind": "snapshot",
		"generation": _generation,
		"cwd": repo_root,
		"commands": commands,
	})


func invalidate_baselines() -> void:
	_baseline_epoch += 1
	_baseline_cache.clear()
	_pending_baselines.clear()


## Asks for the HEAD version of one file. The result also tells us whether the
## path is tracked, untracked, or ignored, which keeps the gutter honest.
func request_baseline(path: String) -> void:
	var normalized := Paths.normalize(path)
	var rel := relative_to(repo_root, normalized)
	if repo_root.is_empty() or rel.is_empty():
		baseline_ready.emit(path, {"ok": false, "known": false, "tracked": false, "text": "", "error": "Not in a Git repository."})
		return

	if _baseline_cache.has(rel):
		var cached: Dictionary = _baseline_cache[rel].duplicate(true)
		cached["cached"] = true
		baseline_ready.emit(path, cached)
		return
	if _pending_baselines.has(rel):
		return

	_pending_baselines[rel] = true
	var commands := [
		_command(["show", "HEAD:" + rel], true),
		_command(["ls-files", "--cached", "--error-unmatch", "--", rel], true),
		_command(["ls-files", "--others", "--exclude-standard", "--error-unmatch", "--", rel], true),
	]
	_enqueue({
		"kind": "baseline",
		"generation": _generation,
		"epoch": _baseline_epoch,
		"cwd": repo_root,
		"path": path,
		"rel": rel,
		"commands": commands,
	})


## Runs `git diff` for a file that is not open. Open files use the in-memory
## buffer so unsaved edits are included.
func request_diff(path: String) -> void:
	var normalized := Paths.normalize(path)
	var rel := relative_to(repo_root, normalized)
	if repo_root.is_empty() or rel.is_empty():
		diff_ready.emit(path, {"ok": false, "files": [], "error": "Not in a Git repository."})
		return
	if _pending_diff.has(rel):
		return
	_pending_diff[rel] = true

	var commands: Array = []
	if _has_head():
		commands.append(_command(["diff", "--no-color", "--no-ext-diff", "--unified=%d" % DIFF_CONTEXT, "HEAD", "--", rel], true))
	else:
		commands.append(_command(["diff", "--no-color", "--no-ext-diff", "--unified=%d" % DIFF_CONTEXT, "--cached", "--", rel], true))
		commands.append(_command(["diff", "--no-color", "--no-ext-diff", "--unified=%d" % DIFF_CONTEXT, "--", rel], true))

	_enqueue({
		"kind": "diff",
		"generation": _generation,
		"cwd": repo_root,
		"path": path,
		"rel": rel,
		"commands": commands,
	})


# ── ACTIONS ─────────────────────────────────────────────────────────────────

func stage(paths: Array) -> void:
	var rels := _relative_paths(paths)
	if rels.is_empty():
		_finish_locally("stage", false, "No files selected.")
		return
	_run_action("stage", [_command(["add", "-A", "--"] + rels)])


func unstage(paths: Array) -> void:
	var rels := _relative_paths(paths)
	if rels.is_empty():
		_finish_locally("unstage", false, "No files selected.")
		return
	if _has_head():
		_run_action("unstage", [_command(["restore", "--staged", "--"] + rels)])
	else:
		_run_action("unstage", [_command(["rm", "--cached", "--"] + rels)])


func stage_all() -> void:
	_run_action("stage_all", [_command(["add", "-A"])])


func unstage_all() -> void:
	if _has_head():
		_run_action("unstage_all", [_command(["restore", "--staged", "--", "."])])
	else:
		_run_action("unstage_all", [_command(["rm", "-r", "--cached", "--", "."])])


func discard(paths: Array) -> void:
	var rels := _relative_paths(paths)
	if rels.is_empty():
		_finish_locally("discard", false, "No files selected.")
		return
	var untracked: Array = []
	var added: Array = []
	var tracked: Array = []
	for rel in rels:
		var entry := _entry_for_path(rel)
		if bool(entry.get("untracked", false)):
			untracked.append(rel)
		elif str(entry.get("index_status", "")) == "A":
			added.append(rel)
		else:
			tracked.append(rel)

	# `git restore` cannot remove a file Git has never seen, so untracked files
	# go through `clean`, and a staged-but-never-committed file is removed from
	# both the index and the worktree.
	var commands: Array = []
	if !untracked.is_empty():
		commands.append(_command(["clean", "-f", "--"] + untracked))
	if !added.is_empty():
		commands.append(_command(["rm", "-f", "--"] + added))
	if !tracked.is_empty():
		if _has_head():
			commands.append(_command(["restore", "--staged", "--worktree", "--"] + tracked))
		else:
			commands.append(_command(["rm", "-f", "--"] + tracked))
	_run_action("discard", commands)


func commit(message: String) -> void:
	var text := message.strip_edges()
	if text.is_empty():
		_finish_locally("commit", false, "Write a commit message first.")
		return
	_run_action("commit", [_command(["commit", "-m", text])])


## The beginner path: one click, everything staged, timestamped message.
func save_point() -> void:
	var stamp := Time.get_datetime_string_from_system(false, true)
	_run_action("save_point", [
		_command(["add", "-A"]),
		_command(["commit", "-m", "Save point: " + stamp]),
	])


func pull() -> void:
	_run_action("pull", [_command(["pull", "--ff-only"])])


func push() -> void:
	# No HEAD check here: a commit action may still be waiting for its snapshot.
	# Git's own error message is clearer than a race-dependent refusal.
	var upstream := str(last_snapshot.get("upstream", ""))
	if !upstream.is_empty():
		_run_action("push", [_command(["push"])])
		return

	var branch := str(last_snapshot.get("branch", ""))
	var remotes: Array = last_snapshot.get("remotes", [])
	if branch.is_empty() or remotes.is_empty():
		_finish_locally("push", false, "This branch has no upstream and no remote is configured.")
		return
	var remote := "origin" if remotes.has("origin") else str(remotes[0])
	_run_action("push", [_command(["push", "--set-upstream", remote, branch])])


func switch_branch(branch: String) -> void:
	var name := branch.strip_edges()
	if name.is_empty():
		_finish_locally("switch_branch", false, "Choose a branch first.")
		return
	_run_action("switch_branch", [_command(["switch", name])])


func init_repository() -> void:
	if workspace_path.is_empty():
		_finish_locally("init", false, "Open a folder before initializing a repository.")
		return
	if git_path.is_empty():
		_finish_locally("init", false, "Git was not found on PATH.")
		return
	_run_action("init", [_command(["init"])], workspace_path)


# ── WORKER PLUMBING ─────────────────────────────────────────────────────────

func _worker_loop() -> void:
	while true:
		_semaphore.wait()
		_mutex.lock()
		if !_running:
			_mutex.unlock()
			return
		var request: Dictionary = {}
		if !_queue.is_empty():
			request = _queue.pop_front()
		_mutex.unlock()
		if request.is_empty():
			continue

		var results: Array = []
		var cwd := str(request.get("cwd", ""))
		for command in request.get("commands", []):
			if !(command is Dictionary):
				continue
			var args: Array = command.get("args", [])
			if !cwd.is_empty():
				# OS.execute does not take a working directory; -C is git's
				# own way to run against the repository root without a shell.
				args = ["-C", cwd] + args
			var output: Array = []
			var code := OS.execute(git_path, args, output, true)
			var text := ""
			if !output.is_empty():
				text = str(output[0])
			results.append({
				"code": code,
				"output": text,
				"args": args,
				"allow_failure": bool(command.get("allow_failure", false)),
			})
			if code != 0 and !bool(command.get("allow_failure", false)):
				break

		call_deferred("_deliver", request, results)


func _enqueue(request: Dictionary) -> void:
	if !_thread_started:
		call_deferred("_deliver", request, [])
		return
	_mutex.lock()
	_queue.append(request)
	_mutex.unlock()
	_semaphore.post()


func _deliver(request: Dictionary, results: Array) -> void:
	if !is_inside_tree():
		return

	var generation := int(request.get("generation", _generation))
	var kind := str(request.get("kind", ""))
	if generation != _generation:
		if kind == "snapshot":
			_pending_status = false
		elif kind == "baseline":
			_pending_baselines.erase(str(request.get("rel", "")))
		elif kind == "diff":
			_pending_diff.erase(str(request.get("rel", "")))
		elif kind == "action":
			_pending_actions = maxi(0, _pending_actions - 1)
			operation_finished.emit(str(request.get("action", "")), {
				"ok": false,
				"action": str(request.get("action", "")),
				"output": "",
				"message": "The repository changed before this command finished.",
			})
		return

	match kind:
		"snapshot":
			_deliver_snapshot(results)
		"baseline":
			_deliver_baseline(request, results)
		"diff":
			_deliver_diff(request, results)
		"action":
			_deliver_action(request, results)


func _deliver_snapshot(results: Array) -> void:
	_pending_status = false

	var status_output := _result_output(results, 0)
	var status_code := _result_code(results, 0)
	var snapshot := StatusParser.parse_status(status_output)
	if status_code != 0:
		snapshot["ok"] = false
		snapshot["error"] = _first_error_line(status_output)
	else:
		snapshot["ok"] = true
		snapshot["error"] = ""

	snapshot["branches"] = StatusParser.parse_branches(_result_output(results, 1))
	snapshot["commits"] = StatusParser.parse_log(_result_output(results, 2))
	snapshot["remotes"] = StatusParser.parse_remotes(_result_output(results, 3))
	snapshot["repo_root"] = repo_root
	snapshot["workspace_path"] = workspace_path
	snapshot["git_path"] = git_path
	snapshot["git_available"] = !git_path.is_empty()

	var head := str(snapshot.get("head", ""))
	if _last_head.is_empty():
		_last_head = head
	elif head != _last_head:
		_last_head = head
		invalidate_baselines()
		head_changed.emit()

	last_snapshot = snapshot
	snapshot_changed.emit(snapshot)

	if _status_dirty:
		_status_dirty = false
		refresh(true)


func _deliver_baseline(request: Dictionary, results: Array) -> void:
	var rel := str(request.get("rel", ""))
	var path := str(request.get("path", ""))
	_pending_baselines.erase(rel)

	if int(request.get("epoch", _baseline_epoch)) != _baseline_epoch:
		return

	var show_code := _result_code(results, 0)
	var show_output := _result_output(results, 0)
	var cached_code := _result_code(results, 1)
	var other_code := _result_code(results, 2)

	var result := {
		"ok": false,
		"known": false,
		"tracked": false,
		"untracked": false,
		"text": "",
		"too_large": false,
		"error": "",
	}

	if show_code == 0:
		if show_output.length() > MAX_BASELINE_CHARS or show_output.contains(String.chr(0)):
			result["too_large"] = true
			result["error"] = "The HEAD copy is too large or binary; gutter marks are unavailable."
		else:
			result["ok"] = true
			result["known"] = true
			result["tracked"] = true
			result["text"] = show_output
	elif cached_code == 0:
		result["ok"] = true
		result["known"] = true
		result["tracked"] = true
	elif other_code == 0:
		result["ok"] = true
		result["known"] = true
		result["untracked"] = true
	else:
		result["error"] = "This file is not tracked by Git."

	if result["known"]:
		_baseline_cache[rel] = result.duplicate(true)
	baseline_ready.emit(path, result)


func _deliver_diff(request: Dictionary, results: Array) -> void:
	var rel := str(request.get("rel", ""))
	var path := str(request.get("path", ""))
	_pending_diff.erase(rel)

	var combined := ""
	for result in results:
		combined += str((result as Dictionary).get("output", ""))

	var parsed := DiffParser.parse_unified(combined)
	parsed["path"] = path
	parsed["rel"] = rel
	diff_ready.emit(path, parsed)


func _deliver_action(request: Dictionary, results: Array) -> void:
	var action := str(request.get("action", ""))
	_pending_actions = maxi(0, _pending_actions - 1)

	var ok := true
	var output := ""
	for result in results:
		var item: Dictionary = result
		output += str(item.get("output", ""))
		if int(item.get("code", 0)) != 0:
			ok = false

	var message := _action_message(action, ok, output)
	var result_data := {
		"ok": ok,
		"action": action,
		"output": output,
		"message": message,
	}

	operation_finished.emit(action, result_data)

	if action == "init" and ok:
		set_workspace(workspace_path)
		return

	if !repo_root.is_empty():
		refresh(true)


# ── HELPERS ─────────────────────────────────────────────────────────────────

func _run_action(action: String, commands: Array, cwd_override: String = "") -> void:
	if repo_root.is_empty() and action != "init":
		_finish_locally(action, false, "Open a folder with a Git repository first.")
		return
	if git_path.is_empty():
		_finish_locally(action, false, "Git was not found on PATH.")
		return

	_pending_actions += 1
	operation_started.emit(action)
	_enqueue({
		"kind": "action",
		"action": action,
		"generation": _generation,
		"cwd": cwd_override if !cwd_override.is_empty() else repo_root,
		"commands": commands,
	})


func _finish_locally(action: String, ok: bool, message: String) -> void:
	operation_finished.emit(action, {
		"ok": ok,
		"action": action,
		"output": "",
		"message": message,
	})


func _command(args: Array, allow_failure: bool = false) -> Dictionary:
	return {"args": args, "allow_failure": allow_failure}


func _entry_for_path(rel: String) -> Dictionary:
	for entry in last_snapshot.get("files", []):
		if entry is Dictionary and str(entry.get("path", "")) == rel:
			return entry
	return {}


func _relative_paths(paths: Array) -> Array:
	var out: Array = []
	for path in paths:
		var rel := relative_to(repo_root, str(path))
		if !rel.is_empty() and !out.has(rel):
			out.append(rel)
	return out


func _has_head() -> bool:
	var head := str(last_snapshot.get("head", ""))
	return !head.is_empty() and head != "(initial)"


func _empty_snapshot(error: String) -> Dictionary:
	return {
		"ok": error.is_empty(),
		"branch": "",
		"head": "",
		"upstream": "",
		"ahead": 0,
		"behind": 0,
		"detached": false,
		"initial": false,
		"files": [],
		"staged": [],
		"unstaged": [],
		"staged_count": 0,
		"unstaged_count": 0,
		"branches": [],
		"commits": [],
		"remotes": [],
		"repo_root": repo_root,
		"git_available": !git_path.is_empty(),
		"error": error,
	}


func _result_output(results: Array, index: int) -> String:
	if index < 0 or index >= results.size():
		return ""
	return str((results[index] as Dictionary).get("output", ""))


func _result_code(results: Array, index: int) -> int:
	if index < 0 or index >= results.size():
		return -1
	return int((results[index] as Dictionary).get("code", -1))


func _action_message(action: String, ok: bool, output: String) -> String:
	var text := output.strip_edges()
	var lower := text.to_lower()

	if action == "save_point" and !ok and lower.contains("nothing to commit"):
		return "Nothing to save — the working tree is clean."
	if action == "commit" and !ok and lower.contains("nothing to commit"):
		return "Nothing staged to commit."
	if ok:
		if text.is_empty():
			return "Done."
		var first := text.split("\n", false)[0] if !text.split("\n", false).is_empty() else text
		return first.strip_edges()

	var lines := text.split("\n", false)
	for line in lines:
		var candidate := str(line).strip_edges()
		if candidate.begins_with("fatal:") or candidate.begins_with("error:") or candidate.begins_with("hint:"):
			return candidate.substr(candidate.find(":") + 1).strip_edges()
	if !lines.is_empty():
		return str(lines[0]).strip_edges()
	return "Git command failed."


func _first_error_line(output: String) -> String:
	for line in output.split("\n", false):
		var text := str(line).strip_edges()
		if !text.is_empty():
			return text
	return "Git command failed."


static func find_repo_root(start_path: String) -> String:
	var path := Paths.normalize(start_path)
	if path.is_empty():
		return ""
	if FileAccess.file_exists(path):
		path = path.get_base_dir()

	while !path.is_empty():
		if _is_repository_entry(path.path_join(".git")):
			return path
		var parent := path.get_base_dir()
		if parent == path or parent.is_empty():
			break
		path = parent
	return ""


## A `.git` entry only counts when it actually describes a repository: a
## directory with HEAD (normal clones and bare worktrees) or a `gitdir:` file
## (linked worktrees and submodules). Merely creating an empty `.git` folder
## must not make the panel run commands that Git will reject.
static func _is_repository_entry(git_entry: String) -> bool:
	if DirAccess.dir_exists_absolute(git_entry):
		return FileAccess.file_exists(git_entry.path_join("HEAD"))
	if !FileAccess.file_exists(git_entry):
		return false
	var target := _resolve_gitdir_file(git_entry)
	return !target.is_empty() and FileAccess.file_exists(target.path_join("HEAD"))


static func _resolve_gitdir_file(path: String) -> String:
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		return ""
	var line := text.split("\n", false)[0].strip_edges()
	if !line.begins_with("gitdir:"):
		return ""
	var target := line.substr(7).strip_edges()
	if target.is_empty():
		return ""
	if target.is_relative_path():
		target = path.get_base_dir().path_join(target)
	return Paths.normalize(target)


static func relative_to(root: String, path: String) -> String:
	if root.is_empty() or path.is_empty():
		return ""
	if !Paths.is_subpath(root, path):
		return ""
	var normalized_root := Paths.normalize(root)
	var normalized_path := Paths.normalize(path)
	if normalized_root == normalized_path:
		return ""
	var rel := normalized_path.substr(normalized_root.length()).trim_prefix("/")
	return rel
