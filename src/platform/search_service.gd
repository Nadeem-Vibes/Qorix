class_name SearchService
extends Node

## Drives a SearchBackend in short slices and exposes replace-all helpers.
##
## The panel talks to this service, never to a scanner directly. Swapping in a
## ripgrep backend later means assigning a different object to `backend`; the
## UI, progress reporting and cancellation contract stay identical.

signal search_started(query: String, files_total: int)
signal search_progress(files_scanned: int, files_total: int, matches: int)
signal search_finished(results: Array, stats: Dictionary)
signal search_cancelled
signal search_failed(message: String)

const Backend = preload("res://src/platform/search_backend.gd")
const TextBackend = preload("res://src/platform/text_search_backend.gd")
const SearchWorkerScript = preload("res://src/platform/search_worker.gd")
const SearchText = preload("res://src/platform/search_text.gd")
const Paths = preload("res://src/base/path_utils.gd")
const Store = preload("res://src/base/file_store.gd")

const SLICE_USEC := 6000
const PROGRESS_INTERVAL_MSEC := 60
const DEFAULT_MAX_FILE_SIZE := 2 * 1024 * 1024

var backend = null
var workspace = null
var searching: bool = false

## Runtime enables the worker so the UI thread never slices a scan. The
## headless suites keep the synchronous path for deterministic pumping.
var threaded: bool = false

var _worker = null
var _thread_results: Array = []
var _thread_stats: Dictionary = {}

var _last_progress_msec: int = 0


func _init() -> void:
	backend = TextBackend.new()


func _ready() -> void:
	set_process(false)


func set_backend(next_backend) -> void:
	if searching:
		cancel()
	backend = next_backend


func _process(_delta: float) -> void:
	if searching:
		pump(SLICE_USEC)


## Starts a search. Returns false for an empty query. An empty file list still
## produces a finished event so the panel can settle its busy state.
func search(query: String, files: Array, options: Dictionary = {}) -> bool:
	cancel()
	# A finished worker leaves `_thread_stats` populated so results()/stats()
	# stay readable. Clear it before a synchronous search, or that search would
	# answer with the previous scan's data.
	_thread_results = []
	_thread_stats = {}

	if backend == null:
		backend = TextBackend.new()

	var opts := options.duplicate(true)
	if workspace != null and !opts.has("root"):
		opts["root"] = workspace.root

	# Empty queries never start a scan. The finished event still fires so the
	# panel can settle its busy state.
	if query.strip_edges().is_empty():
		search_finished.emit([], backend.summary())
		return false

	if threaded and !files.is_empty():
		var worker = SearchWorkerScript.new()
		if worker.start(files, query, opts):
			_worker = worker
			searching = true
			_last_progress_msec = 0
			_thread_results = []
			_thread_stats = {
				"query": query,
				"files_scanned": 0,
				"files_total": files.size(),
				"matches": 0,
				"truncated": false,
				"done": false,
				"cancelled": false,
				"error": "",
				"errors": [],
				"elapsed_msec": 0,
			}
			search_started.emit(query, files.size())
			set_process(true)
			# Publish whatever the worker already has; a tiny search can be
			# done before the first frame.
			_drain_worker()
			return true

	if !backend.begin(files, query, opts):
		if query.strip_edges().is_empty():
			var stats: Dictionary = backend.summary()
			search_finished.emit([], stats)
		return false

	searching = true
	_last_progress_msec = 0
	search_started.emit(query, files.size())
	set_process(true)

	# Give small searches an immediate answer; 2 ms is imperceptible and
	# keeps the panel from flashing a spinner for one-file projects.
	pump(2000)
	return true


## Advances the active backend. Public for the headless suites.
func pump(budget_usec: int = SLICE_USEC) -> void:
	if !searching:
		return

	if _worker != null:
		_drain_worker()
		return

	if backend == null:
		return

	var finished: bool = backend.advance(budget_usec)
	var stats: Dictionary = backend.summary()
	var now := Time.get_ticks_msec()

	if finished or now - _last_progress_msec >= PROGRESS_INTERVAL_MSEC:
		_last_progress_msec = now
		search_progress.emit(
			int(stats.get("files_scanned", 0)),
			int(stats.get("files_total", 0)),
			int(stats.get("matches", 0))
		)

	if finished:
		searching = false
		set_process(false)
		var results: Array = backend.results.duplicate()
		if !str(stats.get("error", "")).is_empty():
			search_failed.emit(str(stats.get("error", "")))
		search_finished.emit(results, stats)


func cancel() -> void:
	if !searching:
		return

	searching = false
	if _worker != null:
		_worker.cancel()
		_worker.wait()
		_worker = null
		_thread_results.clear()
		_thread_stats = {}
	elif backend != null:
		backend.cancel()
	set_process(false)
	search_cancelled.emit()


func results() -> Array:
	if _worker != null or !_thread_stats.is_empty():
		return _thread_results.duplicate(true)
	return backend.results.duplicate() if backend != null else []


func stats() -> Dictionary:
	if _worker != null:
		return _worker.stats()
	if !_thread_stats.is_empty():
		return _thread_stats.duplicate(true)
	return backend.summary() if backend != null else {}


func _drain_worker() -> void:
	if _worker == null:
		return

	var batch: Dictionary = _worker.drain()
	var fresh: Array = batch.get("results", [])
	if !fresh.is_empty():
		_thread_results.append_array(fresh)

	_thread_stats = {
		"query": str(batch.get("query", _thread_stats.get("query", ""))),
		"files_scanned": int(batch.get("files_scanned", 0)),
		"files_total": int(batch.get("files_total", 0)),
		"matches": _thread_results.size(),
		"truncated": bool(batch.get("truncated", false)),
		"done": bool(batch.get("done", false)),
		"cancelled": bool(batch.get("cancelled", false)),
		"error": str(batch.get("error", "")),
		"errors": batch.get("errors", []),
		"elapsed_msec": int(batch.get("elapsed_msec", 0)),
	}

	var done := bool(batch.get("done", false))
	var now := Time.get_ticks_msec()
	if !done and now - _last_progress_msec >= PROGRESS_INTERVAL_MSEC:
		_last_progress_msec = now
		search_progress.emit(
			int(_thread_stats["files_scanned"]),
			int(_thread_stats["files_total"]),
			_thread_results.size()
		)

	if !done:
		return

	searching = false
	set_process(false)
	var results_out: Array = _thread_results.duplicate(true)
	var stats_out: Dictionary = _thread_stats.duplicate(true)
	_worker.wait()
	_worker = null
	_thread_results = results_out
	if !str(stats_out.get("error", "")).is_empty():
		search_failed.emit(str(stats_out.get("error", "")))
	search_finished.emit(results_out, stats_out)


func _exit_tree() -> void:
	# Never leave a worker thread behind when the editor closes mid-search.
	if _worker != null:
		_worker.cancel()
		_worker.wait()
		_worker = null
	searching = false


# ── REPLACE ALL ─────────────────────────────────────────────────────────────

## Counts what Replace All would change, without writing anything.
## Returns {ok, files: [{path, rel, count}], total, skipped, errors}.
func replace_preview(
	files: Array,
	query: String,
	replacement: String,
	options: Dictionary = {}
) -> Dictionary:
	return _replace(files, query, replacement, options, false)


## Applies the replacement to the same files the preview described.
## Returns {ok, files: [{path, rel, count}], total, errors, written}.
func replace_apply(
	files: Array,
	query: String,
	replacement: String,
	options: Dictionary = {}
) -> Dictionary:
	return _replace(files, query, replacement, options, true)


func _replace(
	files: Array,
	query: String,
	replacement: String,
	options: Dictionary,
	write_changes: bool
) -> Dictionary:
	var result := {
		"ok": true,
		"files": [],
		"total": 0,
		"skipped": [],
		"errors": [],
		"written": [],
	}

	if query.is_empty():
		return result

	var case_sensitive := bool(options.get("case_sensitive", false))
	var max_size := int(options.get("max_file_size", DEFAULT_MAX_FILE_SIZE))
	var skip := _canonical_set(options.get("skip_paths", []))
	var seen: Dictionary = {}

	for file in files:
		var path: String = Backend.path_of(file)
		if path.is_empty():
			continue

		var canonical := Paths.canonical(path)
		if seen.has(canonical):
			continue
		seen[canonical] = true

		if skip.has(canonical):
			result["skipped"].append(path)
			continue

		if workspace != null and !workspace.is_inside_workspace(path):
			result["skipped"].append(path)
			continue

		var read := _read_text(path, max_size)
		if !read.get("ok", false):
			if !bool(read.get("skip", false)):
				result["errors"].append(str(read.get("error", "Could not read " + path)))
			else:
				result["skipped"].append(path)
			continue

		var text := str(read.get("text", ""))
		var replaced := SearchText.replace_all(text, query, replacement, case_sensitive)
		var count := int(replaced.get("count", 0))
		if count == 0:
			continue

		var rel: String = Backend.rel_of(file, path, options)
		result["files"].append({"path": path, "rel": rel, "count": count})
		result["total"] = int(result["total"]) + count

		if !write_changes:
			continue

		var saved := Store.save(path, str(replaced.get("text", text)))
		if !saved.get("ok", false):
			result["errors"].append("%s — %s" % [path, str(saved.get("error", "Unknown error."))])
			continue

		result["written"].append(path)
		if workspace != null:
			workspace.note_changed(path)

	var errors: Array = result["errors"]
	result["ok"] = errors.is_empty()
	return result


func _read_text(path: String, max_size: int) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"ok": false, "skip": false, "error": "Could not read " + path}

	var size := file.get_length()
	if max_size > 0 and size > max_size:
		file = null
		return {"ok": false, "skip": true, "error": ""}

	# Probe raw bytes before decoding: get_as_text() drops everything from the
	# first NUL onward, so a String probe can never detect binary content.
	var probe := file.get_buffer(mini(size, SearchText.BINARY_PROBE))
	if SearchText.is_binary(probe):
		file = null
		return {"ok": false, "skip": true, "error": ""}

	file.seek(0)
	var text := file.get_as_text()
	file = null

	return {"ok": true, "skip": false, "text": text, "error": ""}


static func _canonical_set(paths: Variant) -> Dictionary:
	var out: Dictionary = {}
	if paths is Array:
		for path in paths:
			var canonical := Paths.canonical(str(path))
			if !canonical.is_empty():
				out[canonical] = true
	return out
