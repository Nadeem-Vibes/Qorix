class_name WorkspaceService
extends Node

## Owns the opened folder and its file index.
##
## Indexing is deliberately chunked across frames instead of running in a
## worker thread: Godot's file APIs and the conversions we need (String,
## PackedStringArray) are not all thread-safe, and a time-budgeted scan keeps
## the editor responsive without introducing cross-thread lifetimes. A full
## build is only the first pass; saves, creates, renames and deletes update
## the index in place afterwards.

signal root_changed(root: String)
signal index_started(root: String)
signal index_progress(files_found: int, dirs_scanned: int)
signal index_finished(files_indexed: int, was_truncated: bool)

const Paths = preload("res://src/base/path_utils.gd")
const Entry = preload("res://src/platform/file_entry.gd")
const Store = preload("res://src/base/file_store.gd")
const Fuzzy = preload("res://src/base/fuzzy_match.gd")
const IndexWorkerScript = preload("res://src/platform/index_worker.gd")
const IgnoreRulesScript = preload("res://src/platform/ignore_rules.gd")

const RECENTS_PATH := "user://workspaces.json"
const MAX_RECENTS := 12
const MAX_ENTRIES := 100000
const MAX_DEPTH := 32
const CHUNK_USEC := 6000
const PROGRESS_INTERVAL_MSEC := 120

## Folders that are almost never worth indexing: dependencies, caches and
## build output. They stay hidden from the file tree as well, so quick open
## and the tree can never disagree about what the workspace contains.
const SKIP_DIRS := [
	".git", ".hg", ".svn",
	"node_modules", "bower_components",
	"__pycache__", ".mypy_cache", ".pytest_cache", ".ruff_cache", ".tox",
	".venv", "venv", "env",
	".godot", ".import", ".cache",
	"build", "dist", "out", "target", "coverage",
	"vendor",
]

var root: String = ""
var entries: Array = []
var recent_workspaces: Array = []
var building: bool = false
var truncated: bool = false

## The runtime turns this on. The suites keep the deterministic frame-sliced
## scan so a test can call pump() and know exactly when the build finished.
var threaded_indexing: bool = false

## Path used by the headless suites so they never touch the real recents file.
var recents_path: String = RECENTS_PATH

var _by_canonical: Dictionary = {}
var _jobs: Array = []
var _dirs_scanned: int = 0
var _last_progress_msec: int = 0
var _skip_lookup: Dictionary = {}
var _max_entries: int = MAX_ENTRIES
var _worker = null
var _ignore_cache: Dictionary = {}


func _init() -> void:
	for name in SKIP_DIRS:
		_skip_lookup[name] = true


func _ready() -> void:
	set_process(false)
	load_recents()


func _process(_delta: float) -> void:
	if !building:
		return
	if _worker != null:
		_drain_worker()
	else:
		pump(CHUNK_USEC)


# ── WORKSPACE LIFECYCLE ─────────────────────────────────────────────────────

## Opens a folder and starts indexing it. Returns {ok, error, root}.
## Drive/filesystem roots are refused: indexing C:/ would scan the whole disk.
func open_folder(path: String, remember: bool = true) -> Dictionary:
	var normalized := Paths.normalize(path)
	if normalized.is_empty():
		return _failure("No folder path was provided.")
	if _is_filesystem_root(normalized):
		return _failure("Choose a project folder, not a whole drive.")

	var global_path := ProjectSettings.globalize_path(normalized)
	if !DirAccess.dir_exists_absolute(global_path):
		return _failure("\"%s\" is not a folder." % normalized)

	root = normalized
	_ignore_cache.clear()
	if remember:
		_remember(normalized)
	root_changed.emit(root)
	_begin_build()
	return {"ok": true, "error": "", "root": root}


func close_workspace() -> void:
	root = ""
	entries.clear()
	_by_canonical.clear()
	_ignore_cache.clear()
	_jobs.clear()
	_stop_worker()
	building = false
	truncated = false
	set_process(false)
	root_changed.emit("")
	index_finished.emit(0, false)


func has_workspace() -> bool:
	return !root.is_empty()


func index_size() -> int:
	return entries.size()


func workspace_name() -> String:
	if root.is_empty():
		return ""
	return root.trim_suffix("/").get_file() if root.trim_suffix("/") != "" else root


func is_inside_workspace(path: String) -> bool:
	if root.is_empty() or path.is_empty():
		return false
	return Paths.is_subpath(root, path)


## Path relative to the workspace root ("" for the root itself).
func relative_path(path: String) -> String:
	if root.is_empty() or path.is_empty():
		return ""

	var normalized := Paths.normalize(path)
	var normalized_root := Paths.normalize(root).trim_suffix("/")

	# Compare identities (Windows folds case) but slice the display spelling,
	# so "C:/Proj" and "c:/proj/file.gd" still yield "file.gd".
	if Paths.canonical(normalized_root) == Paths.canonical(normalized):
		return ""
	if !Paths.canonical(normalized).begins_with(Paths.canonical(normalized_root) + "/"):
		return ""

	return normalized.substr(normalized_root.length() + 1)


func file_for_path(path: String):
	if path.is_empty():
		return null
	return _by_canonical.get(Paths.canonical(path))


# ── INDEX BUILD ─────────────────────────────────────────────────────────────

func _begin_build() -> void:
	entries.clear()
	_by_canonical.clear()
	_jobs.clear()
	_dirs_scanned = 0
	truncated = false
	_last_progress_msec = 0

	if root.is_empty():
		building = false
		set_process(false)
		index_finished.emit(0, false)
		return

	if threaded_indexing:
		_stop_worker()
		var worker = IndexWorkerScript.new()
		if worker.start(root, SKIP_DIRS, _max_entries, MAX_DEPTH):
			_worker = worker
			building = true
			index_started.emit(root)
			set_process(true)
			return

	building = true
	_jobs.append(_make_job(root, "", 0))
	index_started.emit(root)
	set_process(true)


## Advances the scan for at most `budget_usec` microseconds. Public so tests
## can finish a build deterministically without waiting on frames.
func pump(budget_usec: int = CHUNK_USEC) -> void:
	if !building:
		return

	if _worker != null:
		_drain_worker()
		return

	var deadline := Time.get_ticks_usec() + maxi(budget_usec, 250)

	while !_jobs.is_empty():
		var job: Dictionary = _jobs.pop_front()

		if !job.get("listed", false):
			var listed := _list_directory(str(job.get("abs", "")))
			if listed.is_empty():
				_dirs_scanned += 1
				continue
			job["items"] = listed
			job["listed"] = true

		var items: Array = job.get("items", [])
		var index: int = int(job.get("index", 0))
		var abs_dir: String = str(job.get("abs", ""))
		var rel_dir: String = str(job.get("rel", ""))
		var depth: int = int(job.get("depth", 0))

		while index < items.size():
			var item: Dictionary = items[index]
			index += 1

			var name := str(item.get("name", ""))
			var is_dir := bool(item.get("dir", false))

			if is_dir:
				if _should_skip_dir(name) or depth + 1 > MAX_DEPTH:
					continue

				var child_abs := abs_dir.path_join(name)
				var child_rel := name if rel_dir.is_empty() else rel_dir.path_join(name)
				_jobs.append(_make_job(child_abs, child_rel, depth + 1))
				continue

			if entries.size() >= _max_entries:
				truncated = true
				_jobs.clear()
				_finish_build()
				return

			var file_abs := abs_dir.path_join(name)
			var file_rel := name if rel_dir.is_empty() else rel_dir.path_join(name)
			_upsert(_entry_for(file_abs, file_rel))

			# Checking the clock is cheap compared to opening a file; doing it
			# per item keeps a single huge directory from blocking a frame.
			if (index & 31) == 0 and Time.get_ticks_usec() >= deadline:
				job["index"] = index
				_jobs.push_front(job)
				_emit_progress()
				return

		_dirs_scanned += 1

		if Time.get_ticks_usec() >= deadline:
			_emit_progress()
			return

	_finish_build()


func _finish_build() -> void:
	building = false
	_jobs.clear()
	set_process(false)
	_sort_entries()
	index_finished.emit(entries.size(), truncated)


## Applies one batch of worker results on the main thread, where the entries
## array and the canonical path dictionary are owned.
func _drain_worker() -> void:
	if _worker == null:
		return

	var batch: Dictionary = _worker.drain()
	for data in batch.get("entries", []):
		if !(data is Dictionary):
			continue
		var item: Dictionary = data
		_upsert(Entry.new(
			str(item.get("path", "")),
			str(item.get("rel", "")),
			str(item.get("name", "")),
			str(item.get("ext", "")),
			int(item.get("size", 0)),
			int(item.get("mtime", 0))
		))

	_dirs_scanned = maxi(_dirs_scanned, int(batch.get("dirs", 0)))

	if !bool(batch.get("finished", false)):
		if Time.get_ticks_msec() - _last_progress_msec >= PROGRESS_INTERVAL_MSEC:
			_emit_progress()
		return

	truncated = bool(batch.get("truncated", false))
	_stop_worker()
	_finish_build()


func _stop_worker() -> void:
	if _worker == null:
		return
	_worker.cancel()
	_worker.wait()
	_worker = null


func _exit_tree() -> void:
	_stop_worker()


func _list_directory(abs_path: String) -> Array:
	var dir := DirAccess.open(abs_path)
	if dir == null:
		return []

	var out: Array = []
	for name in dir.get_directories():
		out.append({"name": name, "dir": true})
	for name in dir.get_files():
		out.append({"name": name, "dir": false})
	return out


func _make_job(abs_path: String, rel: String, depth: int) -> Dictionary:
	return {
		"abs": abs_path,
		"rel": rel,
		"depth": depth,
		"items": [],
		"index": 0,
		"listed": false,
	}


func _emit_progress() -> void:
	var now := Time.get_ticks_msec()
	if now - _last_progress_msec < PROGRESS_INTERVAL_MSEC:
		return
	_last_progress_msec = now
	index_progress.emit(entries.size(), _dirs_scanned)


func _entry_for(path: String, rel: String):
	var ext := Paths.extension(path)
	return Entry.new(
		path,
		rel,
		path.get_file(),
		ext,
		_file_size(path),
		_mtime(path)
	)


func _upsert(entry) -> void:
	var key := Paths.canonical(entry.path)
	var previous = _by_canonical.get(key)
	if previous != null:
		entries.erase(previous)
	_by_canonical[key] = entry
	entries.append(entry)


func _sort_entries() -> void:
	entries.sort_custom(func(a, b) -> bool:
		return a.rel.naturalnocasecmp_to(b.rel) < 0
	)


func _should_skip_dir(name: String) -> bool:
	return _skip_lookup.has(name)


## Rules that apply inside `rel_dir`: every .gitignore from the root down to
## (and including) that folder. Cached because the file tree asks on every
## expand; the cache is dropped when the workspace or a path changes.
func _ignore_for(rel_dir: String):
	var key := rel_dir.strip_edges().trim_suffix("/")
	if _ignore_cache.has(key):
		return _ignore_cache[key]
	if root.is_empty():
		return null

	var rules = IgnoreRulesScript.new()
	var bases: Array = [""]
	var current := ""
	if !key.is_empty():
		for part in key.split("/", false):
			current = part if current.is_empty() else current.path_join(part)
			bases.append(current)

	for base in bases:
		var folder := root if str(base).is_empty() else root.path_join(str(base))
		var path := folder.path_join(".gitignore")
		if FileAccess.file_exists(path):
			rules.add_file(str(base), FileAccess.get_file_as_string(path))

	_ignore_cache[key] = rules
	return rules


## Adds or updates one file, or removes it when it no longer exists.
func note_changed(path: String) -> bool:
	var normalized := Paths.normalize(path)
	if !is_inside_workspace(normalized):
		return false

	if FileAccess.file_exists(normalized):
		_upsert(_entry_for(normalized, relative_path(normalized)))
		return true

	return note_deleted(normalized)


## Drops a file, or every indexed file below a directory.
func note_deleted(path: String) -> bool:
	var canonical := Paths.canonical(path)
	if canonical.is_empty():
		return false

	var prefix := canonical.trim_suffix("/") + "/"
	var removed := false

	for key in _by_canonical.keys():
		if key == canonical or str(key).begins_with(prefix):
			var entry = _by_canonical[key]
			_by_canonical.erase(key)
			entries.erase(entry)
			removed = true

	return removed


## A user rename/move: drop the old subtree and index the new one.
func note_renamed(old_path: String, new_path: String) -> void:
	note_deleted(old_path)
	note_created(new_path)


## A newly created file/folder (including a renamed-in path). Files are cheap;
## a folder is walked once, synchronously, because this only happens after an
## explicit user action and is usually a small subtree.
func note_created(path: String) -> void:
	var normalized := Paths.normalize(path)
	if !is_inside_workspace(normalized):
		return

	if FileAccess.file_exists(normalized):
		var rel := relative_path(normalized)
		var rules = _ignore_for(rel.get_base_dir())
		if rules == null or !rules.matches(rel, false):
			_upsert(_entry_for(normalized, rel))
		return

	if !DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(normalized)):
		return

	var stack: Array = [[normalized, relative_path(normalized), 0]]
	var added := 0

	while !stack.is_empty() and added < _max_entries:
		var job: Array = stack.pop_back()
		var dir_path: String = job[0]
		var rel_dir: String = job[1]
		var depth: int = job[2]
		var dir := DirAccess.open(dir_path)
		if dir == null:
			continue

		for name in dir.get_directories():
			if !_should_skip_dir(name) and depth + 1 <= MAX_DEPTH:
				var child_rel := name if rel_dir.is_empty() else rel_dir.path_join(name)
				stack.append([dir_path.path_join(name), child_rel, depth + 1])
		for name in dir.get_files():
			if added >= _max_entries:
				break
			var file_abs := dir_path.path_join(name)
			var file_rel := name if rel_dir.is_empty() else rel_dir.path_join(name)
			_upsert(_entry_for(file_abs, file_rel))
			added += 1


# ── FILE TREE / QUICK OPEN ──────────────────────────────────────────────────

## Lazy file-tree children. Directories come first, then natural sort.
## Returns [{name, rel, path, is_dir, ext}].
func list_children(rel_dir: String) -> Array:
	if root.is_empty():
		return []

	var safe_rel := Paths.normalize(rel_dir)
	if safe_rel.begins_with(".."):
		return []

	var abs_dir := root if safe_rel.is_empty() else root.path_join(safe_rel)
	if !Paths.is_subpath(root, abs_dir):
		return []

	var dir := DirAccess.open(abs_dir)
	if dir == null:
		return []

	var rules = _ignore_for(safe_rel)
	var out: Array = []
	for name in dir.get_directories():
		if _should_skip_dir(name):
			continue
		var rel := name if safe_rel.is_empty() else safe_rel.path_join(name)
		if rules != null and rules.matches(rel, true):
			continue
		out.append({
			"name": name,
			"rel": rel,
			"path": abs_dir.path_join(name),
			"is_dir": true,
			"ext": "",
		})

	for name in dir.get_files():
		var rel := name if safe_rel.is_empty() else safe_rel.path_join(name)
		if rules != null and rules.matches(rel, false):
			continue
		out.append({
			"name": name,
			"rel": rel,
			"path": abs_dir.path_join(name),
			"is_dir": false,
			"ext": Paths.extension(name),
		})

	out.sort_custom(func(a, b) -> bool:
		if bool(a.is_dir) != bool(b.is_dir):
			return bool(a.is_dir)
		return str(a.name).naturalnocasecmp_to(str(b.name)) < 0
	)
	return out


## Fuzzy search over the in-memory index. Returned best-first.
## This is the operation quick open calls on every keypress: it never touches
## disk and only lowercases the query once.
func quick_open(query: String, limit: int = 200) -> Array:
	var out: Array = []
	if entries.is_empty():
		return out

	var trimmed := query.strip_edges()
	if trimmed.is_empty():
		var count := mini(maxi(limit, 0), entries.size())
		for i in range(count):
			out.append(entries[i])
		return out

	var q := trimmed.to_lower()
	var tokens := q.split(" ", false)
	var multi := tokens.size() > 1
	var scored: Array = []

	for entry in entries:
		var score := -1.0

		if multi:
			# "src main" should find src/main.gd: every token must match, and
			# the per-token scores are averaged so longer queries do not
			# automatically outrank exact one-word matches.
			var total := 0.0
			var matched := true
			for token in tokens:
				var token_score := _match_score(entry, token)
				# -1.0 is the matcher's "no match" sentinel. Exact hits use
				# negative scores (lower is better), so they must not be
				# mistaken for misses.
				if token_score == -1.0:
					matched = false
					break
				total += token_score
			if matched:
				score = total / float(tokens.size())
		else:
			score = _match_score(entry, q)

		if score != -1.0:
			scored.append({"entry": entry, "score": score})

	scored.sort_custom(func(a, b) -> bool:
		if a.score != b.score:
			return a.score < b.score
		if a.entry.rel.length() != b.entry.rel.length():
			return a.entry.rel.length() < b.entry.rel.length()
		return a.entry.rel.naturalnocasecmp_to(b.entry.rel) < 0
	)

	var shown := mini(maxi(limit, 0), scored.size())
	for i in range(shown):
		out.append(scored[i].entry)

	return out


## Palette-shaped result rows: [{label, path, rel}].
func quick_open_items(query: String, limit: int = 200) -> Array:
	var out: Array = []
	for entry in quick_open(query, limit):
		out.append({
			"label": entry.rel,
			"path": entry.path,
			"rel": entry.rel,
		})
	return out


func _match_score(entry, q: String) -> float:
	if entry.rel_lower == q:
		return -1000.0
	if entry.name_lower == q:
		return -990.0

	# A hit in the file name beats the same hit buried in the path.
	var name_score := Fuzzy.score_lowered(entry.name_lower, q)
	if name_score != -1.0:
		return name_score

	var rel_score := Fuzzy.score_lowered(entry.rel_lower, q)
	if rel_score != -1.0:
		return rel_score + 8.0

	return -1.0


## Snapshot for the search service. Duplicated so a concurrent index rebuild
## cannot mutate the list under a running search.
func files_for_search() -> Array:
	return entries.duplicate()


# ── RECENT WORKSPACES ───────────────────────────────────────────────────────

func load_recents() -> void:
	recent_workspaces.clear()
	if recents_path.is_empty():
		return

	var result := Store.load_json(recents_path)
	if !result.get("ok", false):
		return

	var data: Dictionary = result.get("data", {})
	var list: Variant = data.get("recent", [])
	if !(list is Array):
		return

	for item in list:
		var path := Paths.normalize(str(item))
		if path.is_empty():
			continue
		if _recent_index(path) != -1:
			continue
		recent_workspaces.append(path)
		if recent_workspaces.size() >= MAX_RECENTS:
			break


func _remember(path: String) -> void:
	var normalized := Paths.normalize(path)
	if normalized.is_empty():
		return

	var existing := _recent_index(normalized)
	if existing != -1:
		recent_workspaces.remove_at(existing)
	recent_workspaces.push_front(normalized)

	while recent_workspaces.size() > MAX_RECENTS:
		recent_workspaces.pop_back()

	save_recents()


func _recent_index(path: String) -> int:
	for i in range(recent_workspaces.size()):
		if Paths.same_file(str(recent_workspaces[i]), path):
			return i
	return -1


func save_recents() -> Dictionary:
	if recents_path.is_empty():
		return {"ok": true, "error": "", "path": recents_path}

	var directory := ProjectSettings.globalize_path(recents_path).get_base_dir()
	if !directory.is_empty() and !DirAccess.dir_exists_absolute(directory):
		DirAccess.make_dir_recursive_absolute(directory)

	return Store.save_json(recents_path, {
		"version": 1,
		"recent": recent_workspaces,
	})


# ── HELPERS ─────────────────────────────────────────────────────────────────

static func _is_filesystem_root(path: String) -> bool:
	var normalized := Paths.normalize(path)
	if normalized == "/":
		return true
	if normalized.length() == 3 and normalized[1] == ":" and normalized.ends_with("/"):
		return true
	return false


static func _mtime(path: String) -> int:
	if path.is_empty():
		return 0
	return FileAccess.get_modified_time(ProjectSettings.globalize_path(path))


static func _file_size(path: String) -> int:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return 0
	var size := file.get_length()
	file = null
	return size


static func _failure(message: String) -> Dictionary:
	return {"ok": false, "error": message, "root": ""}
