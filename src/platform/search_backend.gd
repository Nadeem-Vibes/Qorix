class_name SearchBackend
extends RefCounted

## Contract for a global-search implementation.
##
## The service drives the backend in small `advance()` slices, so a text scan
## and a future ripgrep process can share the same UI: begin with a file list,
## get pumped until done, then read `results`. A backend only has to override
## `_scan_file()` for a simple synchronous implementation; ripgrep would
## override `begin()`/`advance()` to stream a child process instead.

const Paths = preload("res://src/base/path_utils.gd")

var query: String = ""
var options: Dictionary = {}
var files: Array = []
var results: Array = []
var files_scanned: int = 0
var truncated: bool = false
var done: bool = false
var cancelled: bool = false
var error: String = ""
var errors: Array = []

var _cursor: int = 0
var _started_msec: int = 0


## Returns false when the request cannot run at all (empty query, no files).
func begin(p_files: Array, p_query: String, p_options: Dictionary = {}) -> bool:
	cancel()

	query = p_query
	options = p_options.duplicate(true)
	files = p_files
	results = []
	files_scanned = 0
	truncated = false
	done = false
	cancelled = false
	error = ""
	errors = []
	_cursor = 0
	_started_msec = Time.get_ticks_msec()

	if query.strip_edges().is_empty():
		done = true
		return false
	if files.is_empty():
		done = true
		return true

	return true


## Scans for at most `budget_usec`. Returns true when the search is finished.
## Called repeatedly by one owner only: SearchService drives it on the main
## thread, SearchWorker drives its own copy on a worker thread.
func advance(budget_usec: int = 6000) -> bool:
	if done:
		return true
	if cancelled:
		done = true
		return true

	var deadline := Time.get_ticks_usec() + maxi(budget_usec, 250)
	var max_results := maxi(1, int(options.get("max_results", 1000)))

	while _cursor < files.size():
		if results.size() >= max_results:
			truncated = true
			break

		var file = files[_cursor]
		_cursor += 1
		files_scanned += 1

		var path := path_of(file)
		var rel := rel_of(file, path)
		if path.is_empty():
			continue

		var found := _scan_file(path, rel)
		if !found.get("ok", false):
			var message := str(found.get("error", "Could not read the file."))
			if message.is_empty():
				message = "Could not read " + path
			errors.append(message)
			if error.is_empty():
				error = message
		else:
			var matches: Array = found.get("matches", [])
			for row in matches:
				if results.size() >= max_results:
					truncated = true
					break
				if !(row is Dictionary):
					continue
				row["path"] = path
				row["rel"] = rel
				results.append(row)

		if (files_scanned & 7) == 0 and Time.get_ticks_usec() >= deadline:
			break

	if _cursor >= files.size() or truncated:
		done = true

	return done


func cancel() -> void:
	cancelled = true
	done = true


func summary() -> Dictionary:
	return {
		"query": query,
		"files_scanned": files_scanned,
		"files_total": files.size(),
		"matches": results.size(),
		"truncated": truncated,
		"done": done,
		"cancelled": cancelled,
		"error": error,
		"errors": errors.duplicate(),
		"elapsed_msec": Time.get_ticks_msec() - _started_msec,
	}


## Override in a backend. Returns {ok, matches, error}; each match carries
## line (0-based), column, length and preview. The base fills in path/rel.
func _scan_file(_path: String, _rel: String) -> Dictionary:
	return {"ok": true, "matches": [], "error": ""}


# ── SHARED HELPERS ──────────────────────────────────────────────────────────

static func path_of(file) -> String:
	if typeof(file) == TYPE_STRING or typeof(file) == TYPE_STRING_NAME:
		return str(file)
	if file == null:
		return ""
	var value = file.get("path")
	return str(value) if value != null else ""


static func rel_of(file, path: String, p_options: Dictionary = {}) -> String:
	if typeof(file) != TYPE_STRING and typeof(file) != TYPE_STRING_NAME and file != null:
		var value = file.get("rel")
		if value != null:
			return str(value)

	var base := str(p_options.get("root", ""))
	if !base.is_empty() and Paths.is_subpath(base, path):
		var normalized := Paths.normalize(path)
		var normalized_base := Paths.normalize(base).trim_suffix("/")
		return normalized.substr(normalized_base.length() + 1)

	return path
