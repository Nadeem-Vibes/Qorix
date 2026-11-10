class_name SessionService
extends RefCounted

## Persists the editor session and the unsaved buffers that go with it.
##
## session.json holds only metadata (tabs, carets, terminal cwd, panels).
## Modified and untitled buffers are written to separate backup files under
## user://session_backups/, so a crash can never leave a half-written document
## inside the session JSON. A lock file exists for exactly as long as the
## editor is running: finding it at startup means the previous exit was not
## clean, and the last periodic session save is offered back as recovery.

const Paths = preload("res://src/base/path_utils.gd")
const Store = preload("res://src/base/file_store.gd")

const VERSION := 1
const DEFAULT_SESSION_PATH := "user://session.json"
const DEFAULT_BACKUP_DIR := "user://session_backups"
const DEFAULT_LOCK_PATH := "user://session.lock"
const BACKUP_PREFIX := "buffer_"

var session_path: String = DEFAULT_SESSION_PATH
var backup_dir: String = DEFAULT_BACKUP_DIR
var lock_path: String = DEFAULT_LOCK_PATH

## True when begin_session() found a lock from a previous process.
var unclean: bool = false
var begun: bool = false

var last_error: String = ""


# ── LIFECYCLE ───────────────────────────────────────────────────────────────

## Must be called once at startup, before loading the session. It detects the
## stale lock, then immediately writes our own so the next crash is detectable.
func begin_session() -> Dictionary:
	unclean = !lock_path.is_empty() and FileAccess.file_exists(lock_path)
	begun = true

	var error := ""
	if !lock_path.is_empty():
		var result := Store.save_json(lock_path, {
			"pid": OS.get_process_id(),
			"started": Time.get_unix_time_from_system(),
			"version": VERSION,
		})
		error = str(result.get("error", ""))

	last_error = error
	return {"ok": error.is_empty(), "recovered": unclean, "error": error}


## Reads the last saved session and pulls any buffer backups into memory.
## Returns {ok, recovered, data, error}.
func load_session() -> Dictionary:
	if session_path.is_empty() or !FileAccess.file_exists(session_path):
		return {"ok": false, "recovered": unclean, "data": {}, "error": "No saved session."}

	var loaded := Store.load_json(session_path)
	if !loaded.get("ok", false):
		var message := str(loaded.get("error", "Could not read the session."))
		last_error = message
		return {"ok": false, "recovered": unclean, "data": {}, "error": message}

	var data := _sanitize(loaded.get("data", {}))
	_inline_backups(data)

	return {"ok": true, "recovered": unclean, "data": data, "error": ""}


## Writes the session plus one backup per unsaved/untitled buffer.
## The snapshot is not modified: `text` fields are copied out into backups.
func save_session(snapshot: Dictionary) -> Dictionary:
	var result := {
		"ok": true,
		"error": "",
		"path": session_path,
		"backups_written": 0,
	}

	var data := _sanitize(snapshot)
	var documents: Array = data.get("documents", [])
	var referenced: Dictionary = {}
	var errors: Array = []

	if _ensure_directory(backup_dir):
		for index in range(documents.size()):
			var document: Dictionary = documents[index]
			if !document.has("text"):
				document["backup"] = ""
				continue

			var text := str(document.get("text", ""))
			document.erase("text")

			var filename := "%s%03d_%s.bak" % [
				BACKUP_PREFIX,
				index,
				_identity_hash(str(document.get("path", "")), str(document.get("title", ""))),
			]
			var saved := Store.save(backup_dir.path_join(filename), text)
			if saved.get("ok", false):
				document["backup"] = filename
				referenced[filename] = true
				result["backups_written"] = int(result["backups_written"]) + 1
			else:
				document["backup"] = ""
				errors.append("%s — %s" % [filename, str(saved.get("error", "Unknown error."))])
	else:
		errors.append("Could not create the session backup folder.")
		for document in documents:
			document.erase("text")
			document["backup"] = ""

	var saved_session := Store.save_json(session_path, data)
	if !saved_session.get("ok", false):
		errors.append(str(saved_session.get("error", "Could not save the session.")))

	if errors.is_empty():
		_cleanup_backups(referenced)

	result["ok"] = errors.is_empty()
	result["error"] = "\n".join(errors)
	last_error = str(result["error"])
	return result


## Clean quit: save one last time, then release the lock.
func finish_session(snapshot: Dictionary) -> Dictionary:
	var result := save_session(snapshot)
	if !lock_path.is_empty() and FileAccess.file_exists(lock_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(lock_path))
	begun = false
	unclean = false
	return result


func clear_session() -> void:
	if !session_path.is_empty() and FileAccess.file_exists(session_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(session_path))
	if !lock_path.is_empty() and FileAccess.file_exists(lock_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(lock_path))
	_cleanup_backups({})
	begun = false
	unclean = false


func has_session() -> bool:
	return !session_path.is_empty() and FileAccess.file_exists(session_path)


func read_backup(filename: String) -> String:
	if filename.is_empty():
		return ""
	var safe_name := filename.get_file()
	if !safe_name.begins_with(BACKUP_PREFIX) or !safe_name.ends_with(".bak"):
		return ""
	return Store.load_text(backup_dir.path_join(safe_name))


# ── SNAPSHOT SANITIZING ─────────────────────────────────────────────────────

## Keeps the on-disk format small, typed and safe to feed back into the editor.
## Unknown keys are dropped; path strings are normalized; counters are clamped.
func _sanitize(snapshot: Dictionary) -> Dictionary:
	var source: Dictionary = snapshot.duplicate(true)

	var data := {
		"version": VERSION,
		"workspace_root": Paths.normalize(str(source.get("workspace_root", ""))),
		"active_index": maxi(0, int(source.get("active_index", 0))),
		"documents": [],
		"terminal": _sanitize_terminal(source.get("terminal", {})),
		"output": _sanitize_output(source.get("output", {})),
		"debug": _sanitize_debug(source.get("debug", {})),
		"lsp": _sanitize_lsp(source.get("lsp", {})),
		"git": _sanitize_git(source.get("git", {})),
		"panels": _sanitize_panels(source.get("panels", {})),
	}

	var documents: Variant = source.get("documents", [])
	if documents is Array:
		for raw in documents:
			if !(raw is Dictionary):
				continue
			var document := _sanitize_document(raw)
			if document.is_empty():
				continue
			data["documents"].append(document)

	var active := int(data["active_index"])
	var document_list: Array = data["documents"]
	if active >= document_list.size():
		data["active_index"] = maxi(0, document_list.size() - 1)

	return data


func _sanitize_document(raw: Dictionary) -> Dictionary:
	var path := Paths.normalize(str(raw.get("path", "")))
	var title := str(raw.get("title", "")).strip_edges()
	var untitled := bool(raw.get("untitled", path.is_empty()))

	if path.is_empty() and !untitled:
		return {}
	if title.length() > 300:
		title = title.substr(0, 300)

	var document := {
		"path": path,
		"title": title,
		"untitled": untitled,
		"modified": bool(raw.get("modified", false)),
		"caret_line": maxi(0, int(raw.get("caret_line", 0))),
		"caret_column": maxi(0, int(raw.get("caret_column", 0))),
		"scroll_vertical": maxi(0, int(raw.get("scroll_vertical", 0))),
		"scroll_horizontal": maxi(0, int(raw.get("scroll_horizontal", 0))),
		"has_selection": bool(raw.get("has_selection", false)),
		"selection_from_line": maxi(0, int(raw.get("selection_from_line", 0))),
		"selection_from_column": maxi(0, int(raw.get("selection_from_column", 0))),
		"selection_to_line": maxi(0, int(raw.get("selection_to_line", 0))),
		"selection_to_column": maxi(0, int(raw.get("selection_to_column", 0))),
		"encoding": str(raw.get("encoding", "UTF-8")),
		"line_endings": str(raw.get("line_endings", "LF")),
		"language": _sanitize_language(raw.get("language", "")),
		"language_highlight": _sanitize_language(raw.get("language_highlight", "")),
		"language_source": _sanitize_language_source(raw.get("language_source", "")),
		"backup": "",
	}

	if raw.has("text"):
		document["text"] = str(raw.get("text", ""))
	elif !str(raw.get("backup", "")).is_empty():
		var backup := str(raw.get("backup", "")).get_file()
		if backup.begins_with(BACKUP_PREFIX) and backup.ends_with(".bak"):
			document["backup"] = backup

	return document


func _sanitize_terminal(raw: Variant) -> Dictionary:
	var source: Dictionary = {}
	if raw is Dictionary:
		source = raw
	var entries: Array = []
	var raw_entries: Variant = source.get("entries", [])
	if raw_entries is Array:
		for item in raw_entries:
			if !(item is Dictionary):
				continue
			var cwd := Paths.normalize(str(item.get("start_cwd", item.get("cwd", ""))))
			entries.append({
				"title": str(item.get("title", "")).substr(0, 200),
				"start_cwd": cwd,
				"cwd": cwd,
			})

	return {
		"open": bool(source.get("open", false)),
		"active_index": maxi(0, int(source.get("active_index", 0))),
		"entries": entries,
	}


func _sanitize_panels(raw: Variant) -> Dictionary:
	var source: Dictionary = {}
	if raw is Dictionary:
		source = raw
	return {
		"file_tree": bool(source.get("file_tree", false)),
		"search": bool(source.get("search", false)),
		"git": bool(source.get("git", false)),
		"terminal": bool(source.get("terminal", false)),
		"output": bool(source.get("output", false)),
		"debug": bool(source.get("debug", false)),
		"lsp": bool(source.get("lsp", false)),
	}


## Problems/Servers/Log dock. FileManager reads the top-level `lsp` object, so
## dropping it here meant the panel state never survived a restart.
func _sanitize_lsp(raw: Variant) -> Dictionary:
	var source: Dictionary = {}
	if raw is Dictionary:
		source = raw
	return {
		"open": bool(source.get("open", false)),
		"tab": clampi(int(source.get("tab", 0)), 0, 2),
	}


## Source Control dock. Same contract as the other panel snapshots.
func _sanitize_git(raw: Variant) -> Dictionary:
	var source: Dictionary = {}
	if raw is Dictionary:
		source = raw
	return {
		"visible": bool(source.get("visible", false)),
		"tab": maxi(0, int(source.get("tab", 0))),
	}


func _sanitize_output(raw: Variant) -> Dictionary:
	var source: Dictionary = {}
	if raw is Dictionary:
		source = raw
	return {
		"open": bool(source.get("open", false)),
		"explanations": bool(source.get("explanations", true)),
	}


## Breakpoints and watches are durable state: they are worth restoring even
## when no session is running. Adapter ids are deliberately not stored because
## they are meaningless to the next process.
func _sanitize_debug(raw: Variant) -> Dictionary:
	var source: Dictionary = {}
	if raw is Dictionary:
		source = raw

	var watches: Array = []
	var raw_watches: Variant = source.get("watches", [])
	if raw_watches is Array:
		for item in raw_watches:
			if typeof(item) != TYPE_STRING:
				continue
			var text := str(item).strip_edges()
			if text.is_empty() or text.length() > 400 or watches.size() >= 20 or watches.has(text):
				continue
			watches.append(text)

	var breakpoints: Array = []
	var seen_breakpoints: Dictionary = {}
	var raw_breakpoints: Variant = source.get("breakpoints", [])
	if raw_breakpoints is Array:
		for item in raw_breakpoints:
			if !(item is Dictionary):
				continue
			var path := Paths.normalize(str(item.get("path", "")))
			var line := int(item.get("line", -1))
			if path.is_empty() or line < 0 or line > 10_000_000:
				continue
			var key := path.to_lower() + ":" + str(line) if OS.get_name() == "Windows" else path + ":" + str(line)
			if seen_breakpoints.has(key):
				continue
			seen_breakpoints[key] = true
			var condition := str(item.get("condition", "")).strip_edges()
			if condition.length() > 400:
				condition = condition.substr(0, 400)
			breakpoints.append({
				"path": path,
				"line": line,
				"condition": condition,
			})
			if breakpoints.size() >= 500:
				break

	return {
		"open": bool(source.get("open", false)),
		"tab": clampi(int(source.get("tab", 0)), 0, 1),
		"watches": watches,
		"breakpoints": breakpoints,
		"verbose_log": bool(source.get("verbose_log", false)),
	}


func _inline_backups(data: Dictionary) -> void:
	var documents: Array = data.get("documents", [])
	for document in documents:
		var backup := str(document.get("backup", ""))
		if backup.is_empty():
			continue
		if !bool(document.get("modified", false)) and !bool(document.get("untitled", false)):
			document.erase("backup")
			continue

		var text := read_backup(backup)
		if text.is_empty() and !FileAccess.file_exists(backup_dir.path_join(backup.get_file())):
			document["backup_missing"] = true
			document.erase("backup")
			continue

		document["text"] = text
		document.erase("backup")


# ── HELPERS ─────────────────────────────────────────────────────────────────

func _ensure_directory(path: String) -> bool:
	if path.is_empty():
		return true
	var global_path := ProjectSettings.globalize_path(path)
	if DirAccess.dir_exists_absolute(global_path):
		return true
	return DirAccess.make_dir_recursive_absolute(global_path) == OK


func _cleanup_backups(referenced: Dictionary) -> void:
	if backup_dir.is_empty():
		return
	var dir := DirAccess.open(backup_dir)
	if dir == null:
		return

	for filename in dir.get_files():
		if !filename.begins_with(BACKUP_PREFIX) or !filename.ends_with(".bak"):
			continue
		if referenced.has(filename):
			continue
		DirAccess.remove_absolute(ProjectSettings.globalize_path(backup_dir.path_join(filename)))


static func _sanitize_language(value: Variant) -> String:
	var text := str(value).strip_edges().to_lower().trim_prefix(".")
	var out := ""
	for i in range(text.length()):
		var character := text[i]
		if "abcdefghijklmnopqrstuvwxyz0123456789_+#-".contains(character):
			out += character
	return out.substr(0, 24)


static func _sanitize_language_source(value: Variant) -> String:
	var source := str(value).strip_edges().to_lower()
	if source == "auto" or source == "manual":
		return source
	return ""


static func _identity_hash(path: String, title: String) -> String:
	var identity := path if !path.is_empty() else "untitled:" + title
	return identity.sha256_text().substr(0, 10)
