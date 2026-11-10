class_name IndexWorker
extends RefCounted

## Walks a workspace folder on a worker thread and posts file batches back to
## the main thread. Only plain data crosses the thread boundary; WorkspaceService
## builds the FileEntry objects and updates its dictionaries itself.

const Paths = preload("res://src/base/path_utils.gd")
const IgnoreRulesScript = preload("res://src/platform/ignore_rules.gd")

const BATCH_SIZE := 256

var _thread: Thread = null
var _mutex: Mutex = Mutex.new()

var _root: String = ""
var _skip: Dictionary = {}
var _ignore = null
var _max_entries: int = 100000
var _max_depth: int = 32

var _pending: Array = []
var _files: int = 0
var _dirs: int = 0
var _truncated: bool = false
var _finished: bool = false
var _cancelled: bool = false
var _running: bool = false
var _error: String = ""


func start(root: String, skip_dirs: Array, max_entries: int, max_depth: int) -> bool:
	if _running:
		cancel()
	if _thread != null:
		# Reap a finished thread before replacing its handle.
		wait()

	_root = root
	_skip = {}
	for name in skip_dirs:
		_skip[str(name)] = true
	_ignore = IgnoreRulesScript.new()
	_max_entries = maxi(1, max_entries)
	_max_depth = maxi(1, max_depth)

	_mutex.lock()
	_pending.clear()
	_files = 0
	_dirs = 0
	_truncated = false
	_finished = false
	_cancelled = false
	_error = ""
	_mutex.unlock()

	_thread = Thread.new()
	_running = true
	var started := _thread.start(_run)
	if started != OK:
		_thread = null
		_running = false
		return false

	return true


func _run() -> void:
	var stack: Array = [[_root, "", 0]]

	while not stack.is_empty():
		if _is_cancelled():
			break

		var job: Array = stack.pop_back()
		var abs_dir: String = str(job[0])
		var rel_dir: String = str(job[1])
		var depth: int = int(job[2])

		var dir := DirAccess.open(abs_dir)
		if dir == null:
			continue

		# A .gitignore covers its own folder and everything below it, so it is
		# collected while descending instead of being pre-scanned.
		_load_ignore(abs_dir, rel_dir)

		_mutex.lock()
		_dirs += 1
		_mutex.unlock()

		for name in dir.get_directories():
			if _should_skip(name) or depth + 1 > _max_depth:
				continue
			var child_rel := name if rel_dir.is_empty() else rel_dir.path_join(name)
			# An ignored directory can be pruned unless a negation rule might
			# re-include something below it.
			if _ignore != null and !_ignore.has_negation and _ignore.matches(child_rel, true):
				continue
			stack.append([abs_dir.path_join(name), child_rel, depth + 1])

		for name in dir.get_files():
			if _file_count() >= _max_entries:
				_mutex.lock()
				_truncated = true
				_mutex.unlock()
				stack.clear()
				break

			var path := abs_dir.path_join(name)
			var rel := name if rel_dir.is_empty() else rel_dir.path_join(name)
			if _ignore != null and _ignore.matches(rel, false):
				continue
			_push({
				"path": path,
				"rel": rel,
				"name": name,
				"ext": Paths.extension(path),
				"size": _file_size(path),
				"mtime": _mtime(path),
			})

	_flush()
	_mutex.lock()
	_finished = true
	_running = false
	_mutex.unlock()


func _load_ignore(abs_dir: String, rel_dir: String) -> void:
	var ignore_path := abs_dir.path_join(".gitignore")
	if !FileAccess.file_exists(ignore_path):
		return
	var text := FileAccess.get_file_as_string(ignore_path)
	if !text.is_empty():
		_ignore.add_file(rel_dir, text)


## Returns {entries, files, dirs, finished, truncated, error} and clears the
## pending batch. Main thread only.
func drain() -> Dictionary:
	_mutex.lock()
	var entries: Array = _pending.duplicate()
	_pending.clear()
	var snapshot := {
		"entries": entries,
		"files": _files,
		"dirs": _dirs,
		"finished": _finished,
		"truncated": _truncated,
		"error": _error,
	}
	_mutex.unlock()
	return snapshot


func cancel() -> void:
	_mutex.lock()
	_cancelled = true
	_mutex.unlock()


func wait() -> void:
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()
	_thread = null
	_running = false


func is_running() -> bool:
	return _running


func _push(entry: Dictionary) -> void:
	_mutex.lock()
	_pending.append(entry)
	_files += 1
	var flush_now := _pending.size() >= BATCH_SIZE
	_mutex.unlock()

	if flush_now:
		# The batch stays in _pending; this only yields so a huge folder does
		# not build one giant array before the main thread ever sees it.
		OS.delay_usec(10)


func _flush() -> void:
	# Batches are published by drain(); there is no separate buffer to flush.
	pass


func _file_count() -> int:
	_mutex.lock()
	var count := _files
	_mutex.unlock()
	return count


func _is_cancelled() -> bool:
	_mutex.lock()
	var value := _cancelled
	_mutex.unlock()
	return value


func _should_skip(name: String) -> bool:
	return _skip.has(name)


static func _file_size(path: String) -> int:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return 0
	var size := file.get_length()
	file = null
	return size


static func _mtime(path: String) -> int:
	return FileAccess.get_modified_time(ProjectSettings.globalize_path(path))
