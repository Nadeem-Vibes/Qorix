extends SceneTree

## End-to-end check for the Git layer. Unlike the unit suites this drives a
## real repository through GitService, so it verifies the worker thread, the
## parser and the git CLI together:
##
##   godot --headless --path . --script res://tests/integration/git_integration_runner.gd
##
## The repository lives in the OS temp folder and is removed at the end. No
## global git configuration is touched: identity and signing are set locally
## inside the temporary repository.

const GIT_SERVICE = preload("res://src/features/git/git_service.gd")

var service: Node

var _root: String = ""
var _checks: int = 0
var _failures: Array[String] = []

var _last_action: String = ""
var _last_result: Dictionary = {}
var _baseline_result: Dictionary = {}
var _diff_result: Dictionary = {}
var _snapshot: Dictionary = {}


func _initialize() -> void:
	_run()


func _run() -> void:
	_root = _make_temp_dir()
	print("Git integration repository: " + _root)

	service = GIT_SERVICE.new()
	root.add_child(service)
	service.operation_finished.connect(_on_operation_finished)
	service.snapshot_changed.connect(_on_snapshot_changed)
	service.baseline_ready.connect(_on_baseline_ready)
	service.diff_ready.connect(_on_diff_ready)
	await create_timer(0.1).timeout

	_check(service.has_git(), "git executable is available")
	if !service.has_git():
		await _finish()
		return
	service.set_workspace(_root)
	await create_timer(0.05).timeout
	_check(!service.has_repo(), "an empty folder is not a repository")

	service.init_repository()
	_check(await _wait_action("init"), "git init finishes")
	_check(bool(_last_result.get("ok", false)), "git init succeeds")
	_check(service.has_repo(), "git init registers the repository")

	_git(["config", "user.name", "Qorix Test"])
	_git(["config", "user.email", "griddycode-test@example.invalid"])
	_git(["config", "commit.gpgsign", "false"])
	_git(["config", "core.autocrlf", "false"])

	_write("notes.txt", "alpha\nbeta\n")
	service.refresh(true)
	_check(await _wait_snapshot(func(snapshot: Dictionary) -> bool:
		return !_entry_in(snapshot, "notes.txt").is_empty()
	, "status lists the new file"), "status lists the new file")
	_check(bool(_entry_in(_snapshot, "notes.txt").get("untracked", false)), "new file is untracked")
	_check(int(_snapshot.get("unstaged_count", 0)) >= 1, "untracked files count as changes")

	_baseline_result = {}
	service.request_baseline(_abs("notes.txt"))
	_check(await _wait_until(func() -> bool: return !_baseline_result.is_empty(), "untracked baseline"), "untracked baseline arrives")
	_check(bool(_baseline_result.get("known", false)), "untracked file has a known baseline")
	_check(!bool(_baseline_result.get("tracked", false)), "untracked file is not tracked")
	_check(str(_baseline_result.get("text", "")).is_empty(), "untracked baseline text is empty")

	service.stage_all()
	_check(await _wait_action("stage_all"), "stage all finishes")
	_check(bool(_last_result.get("ok", false)), "stage all succeeds")
	_check(await _wait_snapshot(func(snapshot: Dictionary) -> bool:
		return int(snapshot.get("staged_count", 0)) >= 1
	, "staged snapshot"), "snapshot moves the file to staged")
	_check(str(_entry_in(_snapshot, "notes.txt").get("index_status", "")) == "A", "staged file is marked added")

	service.commit("Initial commit")
	_check(await _wait_action("commit"), "commit finishes")
	_check(bool(_last_result.get("ok", false)), "commit succeeds")
	_check(await _wait_snapshot(func(snapshot: Dictionary) -> bool:
		return !str(snapshot.get("head", "")).is_empty() and str(snapshot.get("head", "")) != "(initial)"
	, "first HEAD snapshot"), "snapshot reports the first HEAD")
	var main_branch := str(_snapshot.get("branch", ""))
	_check(!main_branch.is_empty(), "current branch is reported")
	_check(int(_snapshot.get("unstaged_count", 0)) == 0, "working tree is clean after commit")
	_check(_commits(_snapshot).size() >= 1, "history contains the first commit")

	_baseline_result = {}
	service.request_baseline(_abs("notes.txt"))
	_check(await _wait_until(func() -> bool: return !_baseline_result.is_empty(), "tracked baseline"), "tracked baseline arrives")
	_check(bool(_baseline_result.get("tracked", false)), "committed file is tracked")
	_check(str(_baseline_result.get("text", "")) == "alpha\nbeta\n", "baseline text is the HEAD copy")

	_baseline_result = {}
	service.request_baseline(_abs("notes.txt"))
	_check(await _wait_until(func() -> bool: return bool(_baseline_result.get("cached", false)), "cached baseline"), "baseline is cached")

	_write("notes.txt", "alpha\nbeta\ngamma\n")
	_diff_result = {}
	service.request_diff(_abs("notes.txt"))
	_check(await _wait_until(func() -> bool: return !_diff_result.is_empty(), "diff"), "diff arrives")
	_check(int(_diff_result.get("additions", 0)) == 1, "diff counts the added line")
	_check(int(_diff_result.get("deletions", 0)) == 0, "diff has no deleted lines")
	var diff_files: Array = _diff_result.get("files", [])
	_check(diff_files.size() == 1, "diff contains one file")
	if diff_files.size() == 1:
		_check(str((diff_files[0] as Dictionary).get("new_path", "")) == "notes.txt", "diff path is repository-relative")

	service.save_point()
	_check(await _wait_action("save_point"), "save point finishes")
	_check(bool(_last_result.get("ok", false)), "save point succeeds")
	_check(await _wait_snapshot(func(snapshot: Dictionary) -> bool:
		var commits := _commits(snapshot)
		return !commits.is_empty() and str((commits[0] as Dictionary).get("subject", "")).begins_with("Save point: ")
	, "save point history"), "save point commit uses the timestamped subject")
	_check(int(_snapshot.get("unstaged_count", 0)) == 0, "save point leaves a clean tree")

	_write("notes.txt", "alpha\nbeta\ngamma\ndelta\n")
	service.stage_all()
	_check(await _wait_action("stage_all"), "second stage all finishes")
	service.unstage_all()
	_check(await _wait_action("unstage_all"), "unstage all finishes")
	_check(bool(_last_result.get("ok", false)), "unstage all succeeds")
	var staged_list := _git(["diff", "--cached", "--name-only"])
	_check(str(staged_list.get("output", "")).strip_edges().is_empty(), "unstage all empties the index")

	service.discard([_abs("notes.txt")])
	_check(await _wait_action("discard"), "discard finishes")
	_check(bool(_last_result.get("ok", false)), "discard succeeds")
	_check(_read("notes.txt") == "alpha\nbeta\ngamma\n", "discard restores the tracked file")

	_write("scratch.txt", "temporary\n")
	service.refresh(true)
	_check(await _wait_snapshot(func(snapshot: Dictionary) -> bool:
		return bool(_entry_in(snapshot, "scratch.txt").get("untracked", false))
	, "scratch status"), "scratch file is listed as untracked")
	service.discard([_abs("scratch.txt")])
	_check(await _wait_action("discard"), "untracked discard finishes")
	_check(!FileAccess.file_exists(_abs("scratch.txt")), "discard deletes an untracked file")

	var branch := _git(["branch", "feature"])
	_check(int(branch.get("code", -1)) == 0, "feature branch is created")
	service.refresh(true)
	_check(await _wait_snapshot(func(snapshot: Dictionary) -> bool:
		for item in snapshot.get("branches", []):
			if item is Dictionary and str(item.get("name", "")) == "feature":
				return true
		return false
	, "branches after creation"), "branch list contains the new branch")

	service.switch_branch("feature")
	_check(await _wait_action("switch_branch"), "branch switch finishes")
	_check(bool(_last_result.get("ok", false)), "branch switch succeeds")
	_check(await _wait_snapshot(func(snapshot: Dictionary) -> bool:
		return str(snapshot.get("branch", "")) == "feature"
	, "feature branch snapshot"), "snapshot reports the switched branch")

	service.switch_branch(main_branch)
	_check(await _wait_action("switch_branch"), "branch switch back finishes")
	_check(await _wait_snapshot(func(snapshot: Dictionary) -> bool:
		return str(snapshot.get("branch", "")) == main_branch
	, "original branch snapshot"), "snapshot reports the original branch")

	_check(_commits(_snapshot).size() >= 2, "history keeps both commits")

	await _finish()


# ── SIGNALS ─────────────────────────────────────────────────────────────────

func _on_operation_finished(action: String, result: Dictionary) -> void:
	_last_action = action
	_last_result = result


func _on_snapshot_changed(snapshot: Dictionary) -> void:
	_snapshot = snapshot


func _on_baseline_ready(_path: String, result: Dictionary) -> void:
	_baseline_result = result


func _on_diff_ready(_path: String, result: Dictionary) -> void:
	_diff_result = result


# ── HELPERS ─────────────────────────────────────────────────────────────────

func _wait_action(action: String) -> bool:
	_last_action = ""
	_last_result = {}
	return await _wait_until(func() -> bool: return _last_action == action, "action " + action)


func _wait_snapshot(predicate: Callable, label: String) -> bool:
	var ok := await _wait_until(func() -> bool:
		return bool(_snapshot.get("ok", false)) and bool(predicate.call(_snapshot))
	, label)
	if !ok:
		var subjects: Array[String] = []
		for commit in _commits(_snapshot):
			subjects.append(str((commit as Dictionary).get("subject", "")))
		print("  snapshot state: branch=%s head=%s staged=%d unstaged=%d commits=%s" % [
			str(_snapshot.get("branch", "")),
			str(_snapshot.get("head", "")),
			int(_snapshot.get("staged_count", 0)),
			int(_snapshot.get("unstaged_count", 0)),
			str(subjects),
		])
		print("  git log: " + str(_git(["log", "-3", "--pretty=format:%s"]).get("output", "")))
	return ok


func _wait_until(predicate: Callable, label: String, timeout: float = 20.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(predicate.call()):
			return true
		await create_timer(0.02).timeout
	_fail(label + " (timed out)")
	return false


func _entry_in(snapshot: Dictionary, rel: String) -> Dictionary:
	for entry in snapshot.get("files", []):
		if entry is Dictionary and str(entry.get("path", "")) == rel:
			return entry
	return {}


func _commits(snapshot: Dictionary) -> Array:
	var commits: Array = snapshot.get("commits", [])
	return commits


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if !condition:
		_fail(label)


func _fail(label: String) -> void:
	_failures.append(label)


func _finish() -> void:
	service.queue_free()
	await create_timer(0.1).timeout
	_remove_dir(_root)

	print("")
	if _failures.is_empty():
		print("GIT INTEGRATION PASSED: %d checks." % _checks)
		quit(0)
	else:
		for failure in _failures:
			print("  - " + failure)
		print("GIT INTEGRATION FAILED: %d of %d checks." % [_failures.size(), _checks])
		quit(1)


# ── TEMP REPO / FILES ───────────────────────────────────────────────────────

func _make_temp_dir() -> String:
	var base := OS.get_temp_dir().path_join("qorix-git-%d-%d" % [
		int(Time.get_unix_time_from_system()),
		Time.get_ticks_usec(),
	])
	DirAccess.make_dir_recursive_absolute(base)
	return base


func _abs(name: String) -> String:
	return _root.path_join(name)


func _write(name: String, text: String) -> void:
	var file := FileAccess.open(_abs(name), FileAccess.WRITE)
	if file == null:
		_fail("could not write " + name)
		return
	file.store_string(text)
	file.close()


func _read(name: String) -> String:
	if !FileAccess.file_exists(_abs(name)):
		return ""
	return FileAccess.get_file_as_string(_abs(name))


func _git(args: Array) -> Dictionary:
	var output: Array = []
	var code := OS.execute(service.git_path, ["-C", _root] + args, output, true)
	var text := str(output[0]) if !output.is_empty() else ""
	return {"code": code, "output": text}


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
