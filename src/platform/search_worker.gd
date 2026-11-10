class_name SearchWorker
extends RefCounted

## Runs a literal workspace search on a worker thread.
##
## The main thread only ever touches this object through start/drain/cancel/
## wait. Results are copied out under a mutex in batches, so a big search no
## longer has to be sliced into 6 ms pumps on the UI thread. The matching
## itself is still TextSearchBackend (and therefore covered by its tests).

const Backend = preload("res://src/platform/text_search_backend.gd")

var _thread: Thread = null
var _mutex: Mutex = Mutex.new()
var _backend = null

var _files: Array = []
var _query: String = ""
var _options: Dictionary = {}
var _pending: Array = []
var _published: int = 0
var _scanned: int = 0
var _truncated: bool = false
var _error: String = ""
var _errors: Array = []
var _finished: bool = false
var _cancelled: bool = false
var _running: bool = false
var _started_msec: int = 0


## Starts the scan. Returns false only when the thread could not be created.
func start(files: Array, query: String, options: Dictionary = {}) -> bool:
	if _running:
		cancel()
	if _thread != null:
		# A finished thread still owns an OS handle until joined. Always reap it
		# before replacing it, even when the previous scan already reported done.
		wait()

	_files = files.duplicate()
	_query = query
	_options = options.duplicate(true)
	_backend = Backend.new()

	_mutex.lock()
	_pending.clear()
	_published = 0
	_scanned = 0
	_truncated = false
	_error = ""
	_errors = []
	_finished = false
	_cancelled = false
	_started_msec = Time.get_ticks_msec()
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
	if !_backend.begin(_files, _query, _options):
		_finish()
		return

	while true:
		var done: bool = _backend.advance(100000)
		_publish()
		if done:
			break
		if _is_cancelled():
			_backend.cancel()
			break

	_finish()


## Copies every result produced since the last drain. Must run on the main
## thread; it is safe to call while the worker is still scanning.
func drain() -> Dictionary:
	_mutex.lock()
	var results: Array = _pending.duplicate()
	_pending.clear()
	var snapshot := {
		"results": results,
		"files_scanned": _scanned,
		"files_total": _files.size(),
		"matches": _published,
		"truncated": _truncated,
		"done": _finished,
		"cancelled": _cancelled,
		"error": _error,
		"errors": _errors.duplicate(),
		"elapsed_msec": Time.get_ticks_msec() - _started_msec,
		"query": _query,
	}
	_mutex.unlock()
	return snapshot


## Last known stats without consuming pending results.
func stats() -> Dictionary:
	_mutex.lock()
	var snapshot := {
		"files_scanned": _scanned,
		"files_total": _files.size(),
		"matches": _published,
		"truncated": _truncated,
		"done": _finished,
		"cancelled": _cancelled,
		"error": _error,
		"errors": _errors.duplicate(),
		"elapsed_msec": Time.get_ticks_msec() - _started_msec,
		"query": _query,
	}
	_mutex.unlock()
	return snapshot


func cancel() -> void:
	_mutex.lock()
	_cancelled = true
	_mutex.unlock()
	# Do not touch the backend from this thread: it is mid-scan on the worker.
	# The loop sees the flag and calls `_backend.cancel()` on its own thread.


## Joins the worker. Safe to call repeatedly.
func wait() -> void:
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()
	_thread = null
	_running = false


func is_running() -> bool:
	return _running


func finished() -> bool:
	_mutex.lock()
	var value := _finished
	_mutex.unlock()
	return value


func _is_cancelled() -> bool:
	_mutex.lock()
	var value := _cancelled
	_mutex.unlock()
	return value


func _publish() -> void:
	_mutex.lock()
	var all: Array = _backend.results
	if all.size() > _published:
		_pending.append_array(all.slice(_published))
		_published = all.size()
	_scanned = _backend.files_scanned
	_truncated = _backend.truncated
	_error = _backend.error
	_errors = _backend.errors.duplicate()
	_mutex.unlock()


func _finish() -> void:
	_publish()
	_mutex.lock()
	_finished = true
	_running = false
	_mutex.unlock()
