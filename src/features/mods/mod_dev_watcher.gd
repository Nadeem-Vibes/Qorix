extends RefCounted

## Developer-mode file watcher for hot reload.
##
## Only mods loaded from `dev_root` are watched. The installed `mods_root` stays
## untouched: the plan enables hot reload for development copies, never for
## packages a user installed from a release.
##
## Watched files are `main.lua` plus every `.lua` file under `lib/` (recursive).
## A signature is the file set plus each file's mtime and size. A change starts a
## debounce timer; when the newest signature is stable for `debounce_ms`,
## `tick()` returns the mod id and ModManager performs deactivate → activate.
## Storage and progress are flushed and reloaded, so they survive; session UI
## state does not.

const DEFAULT_POLL_MS := 400
const DEFAULT_DEBOUNCE_MS := 250

var poll_ms: int = DEFAULT_POLL_MS
var debounce_ms: int = DEFAULT_DEBOUNCE_MS

## Optional override for tests and deterministic hosts:
## `Callable(id: String, root: String) -> Dictionary` returning relative path ->
## stamp. When invalid, the watcher stats the real files.
var signature_source: Callable = Callable()

var _watched: Dictionary = {}
var _since_poll_ms: float = 0.0


func configure(options: Dictionary = {}) -> void:
	if options.has("poll_ms"):
		poll_ms = maxi(1, int(options["poll_ms"]))
	if options.has("debounce_ms"):
		debounce_ms = maxi(0, int(options["debounce_ms"]))
	if options.has("signature_source") and options["signature_source"] is Callable:
		signature_source = options["signature_source"]


func watch(id: String, root: String) -> Dictionary:
	var key := str(id)
	var normalized_root := str(root)
	var entry: Dictionary = _watched.get(key, {})
	entry["root"] = normalized_root
	entry["signature"] = _signature(key, normalized_root)
	entry["files"] = watched_files(normalized_root)
	entry["dirty"] = false
	entry["pending_ms"] = 0.0
	entry["last_reload_at"] = int(entry.get("last_reload_at", 0))
	_watched[key] = entry
	return {
		"id": key,
		"root": normalized_root,
		"files": (entry["files"] as Array).size(),
	}


func unwatch(id: String) -> void:
	_watched.erase(str(id))


func clear() -> void:
	_watched.clear()
	_since_poll_ms = 0.0


func watched_ids() -> Array:
	var ids: Array = _watched.keys()
	ids.sort()
	return ids


func info() -> Dictionary:
	var out: Dictionary = {}
	for id in watched_ids():
		var entry: Dictionary = _watched[id]
		out[str(id)] = {
			"root": str(entry.get("root", "")),
			"files": (entry.get("files", []) as Array).duplicate(),
			"dirty": bool(entry.get("dirty", false)),
			"pending_ms": float(entry.get("pending_ms", 0.0)),
			"last_reload_at": int(entry.get("last_reload_at", 0)),
		}
	return out


## Advances the watcher. Returns the ids whose change has been stable for the
## debounce window. Multiple ids are returned in sorted order.
func tick(delta_ms: float) -> Array:
	if _watched.is_empty():
		return []

	_since_poll_ms += maxf(0.0, delta_ms)
	if _since_poll_ms < float(poll_ms):
		return []

	var step_ms := _since_poll_ms
	_since_poll_ms = 0.0
	var due: Array = []

	for id in watched_ids():
		var entry: Dictionary = _watched[id]
		var root := str(entry.get("root", ""))
		var current := _signature(str(id), root)
		entry["files"] = watched_files(root)

		if current != entry.get("signature", {}):
			# A save is usually several writes. Restart the quiet window and
			# wait for the next stable poll before asking for a reload.
			entry["signature"] = current
			entry["dirty"] = true
			entry["pending_ms"] = 0.0
		elif bool(entry.get("dirty", false)):
			entry["pending_ms"] = float(entry.get("pending_ms", 0.0)) + step_ms
			if float(entry["pending_ms"]) >= float(debounce_ms):
				entry["dirty"] = false
				entry["pending_ms"] = 0.0
				entry["last_reload_at"] = Time.get_ticks_msec()
				due.append(str(id))

	return due


## The files the watcher is responsible for. Public so tests and diagnostics can
## assert the exact set without touching the private signature.
func watched_files(root: String) -> Array:
	var files: Array = []
	var main_path := str(root).path_join("main.lua")
	if FileAccess.file_exists(main_path):
		files.append("main.lua")
	_collect_lua(str(root).path_join("lib"), "lib", files)
	files.sort()
	return files


func _collect_lua(directory: String, relative: String, out: Array) -> void:
	var dir := DirAccess.open(directory)
	if dir == null:
		return

	var names: Array = dir.get_files()
	names.sort()
	for name in names:
		var file_name := str(name)
		if file_name.get_extension().to_lower() != "lua":
			continue
		out.append(relative.path_join(file_name))

	var folders: Array = dir.get_directories()
	folders.sort()
	for folder in folders:
		var folder_name := str(folder)
		_collect_lua(
			directory.path_join(folder_name),
			relative.path_join(folder_name),
			out,
		)


func _signature(id: String, root: String) -> Dictionary:
	if signature_source.is_valid():
		var provided: Variant = signature_source.call(id, root)
		if provided is Dictionary:
			return (provided as Dictionary).duplicate(true)

	var out: Dictionary = {}
	for relative in watched_files(root):
		# Seconds-resolution mtimes can collide when a rapid save follows
		# activation, so the size is part of the stamp. A same-second,
		# same-size rewrite is still not detectable by polling; that is the
		# documented limit of mtime-based hot reload.
		var path := str(root).path_join(str(relative))
		var size := -1
		var file := FileAccess.open(path, FileAccess.READ)
		if file != null:
			size = int(file.get_length())
			file = null
		out[str(relative)] = "%d:%d" % [int(FileAccess.get_modified_time(path)), size]
	return out
