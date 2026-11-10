extends RefCounted

## Local, automatic "previous versions" for files edited in Qorix.
##
## Every snapshot is one JSON document with the full file content, the path it
## belongs to, a reason and a timestamp. Snapshots live in
## `user://history/<sha1(canonical path)>/`, so two spellings of the same path
## share one history and a renamed folder does not corrupt another file's list.
##
## Retention is deliberately simple and bounded: the newest 50 snapshots, no
## snapshot older than seven days, and at most 2 MB of content per file. Files
## are pruned after every write, so history can never grow without a limit.
##
## The service is pure (no UI, no editor): FileManager supplies the content and
## decides when to call snapshot()/restore(). Tests can redirect `root` and
## freeze the clock with `now_override`.

signal changed(path: String)
signal restored(path: String, snapshot: Dictionary)

const Store = preload("res://src/base/file_store.gd")
const Paths = preload("res://src/base/path_utils.gd")
const Diff = preload("res://src/features/git/git_diff.gd")

const DEFAULT_ROOT := "user://history"
const MAX_SNAPSHOTS := 50
const MAX_AGE_SECONDS := 7 * 24 * 60 * 60
const MAX_BYTES := 2 * 1024 * 1024

const REASON_LABELS := {
	"save": "Before a save",
	"before_save": "Before a save",
	"autosave": "Automatic backup",
	"before_run": "Before running",
	"before_close": "Before closing",
	"before_restore": "Before restoring",
	"manual": "Manual snapshot",
}

## Redirectable for tests.
var root: String = DEFAULT_ROOT

## Unix seconds. 0 means "read the system clock"; tests set a fixed value.
var now_override: int = 0


func directory_for(path: String) -> String:
	var canonical := Paths.canonical(path)
	if canonical.is_empty():
		return ""
	return root.path_join(canonical.sha1_text())


## Stores one snapshot. Identical consecutive content is skipped, so the 60 s
## timer cannot fill the list with copies of the same buffer.
## Returns {ok, error, file, snapshot, deduped, pruned}.
func snapshot(path: String, content: String, reason: String = "save") -> Dictionary:
	var normalized := Paths.normalize(path)
	if normalized.is_empty():
		return _failure("No file path was provided.")

	var directory := directory_for(normalized)
	if directory.is_empty():
		return _failure("Could not identify this file.")

	if !_ensure_directory(directory):
		return _failure("Could not create the history folder: " + directory)

	var latest := _latest_payload(normalized)
	if !latest.is_empty() and str(latest.get("content", "")) == content:
		return {
			"ok": true,
			"error": "",
			"file": str(latest.get("_file", "")),
			"snapshot": _metadata(latest),
			"deduped": true,
			"pruned": 0,
		}

	var stamp := _now_msec()
	var counter := 1
	var file_name := ""
	while true:
		file_name = "snap-%013d-%03d.json" % [stamp, counter]
		if !FileAccess.file_exists(directory.path_join(file_name)):
			break
		counter += 1

	var payload := {
		"version": 1,
		"path": normalized,
		"reason": _clean_reason(reason),
		"timestamp": _now(),
		"created_msec": stamp,
		"bytes": content.to_utf8_buffer().size(),
		"content": content,
	}
	var result: Dictionary = Store.save_json(directory.path_join(file_name), payload)
	if !result.get("ok", false):
		return _failure("Could not write the snapshot: " + str(result.get("error", "")))

	var pruned := prune(normalized)
	var stored := payload.duplicate(true)
	stored["_file"] = file_name
	changed.emit(normalized)
	return {
		"ok": true,
		"error": "",
		"file": file_name,
		"snapshot": _metadata(stored),
		"deduped": false,
		"pruned": pruned,
	}


## Newest first. Metadata only by default; set include_content for callers
## that need the buffer (the dialog loads one snapshot at a time instead).
func snapshots(path: String, limit: int = MAX_SNAPSHOTS, include_content: bool = false) -> Array:
	var out: Array = []
	var directory := directory_for(path)
	if directory.is_empty():
		return out

	for file_name in _snapshot_files(directory):
		if out.size() >= limit:
			break
		var payload := _read_payload(directory, file_name)
		if payload.is_empty():
			continue
		payload["_file"] = file_name
		var entry := _metadata(payload)
		if include_content:
			entry["content"] = str(payload.get("content", ""))
		out.append(entry)
	return out


func count(path: String) -> int:
	return snapshots(path, MAX_SNAPSHOTS).size()


func latest(path: String) -> Dictionary:
	var list := snapshots(path, 1, true)
	return list[0] if !list.is_empty() else {}


## Reads one snapshot. The filename is validated so a caller cannot escape the
## per-path folder with "../".
## Returns {ok, error, snapshot, content}.
func read(path: String, file_name: String) -> Dictionary:
	var directory := directory_for(path)
	if directory.is_empty() or !_safe_file_name(file_name):
		return {"ok": false, "error": "Invalid snapshot name.", "snapshot": {}, "content": ""}

	var payload := _read_payload(directory, file_name)
	if payload.is_empty():
		return {"ok": false, "error": "That snapshot could not be read.", "snapshot": {}, "content": ""}
	return {
		"ok": true,
		"error": "",
		"snapshot": _metadata(payload),
		"content": str(payload.get("content", "")),
	}


## Writes a snapshot back to disk. The caller is responsible for saving the
## current buffer first (FileManager snapshots it as "before_restore") and for
## updating an open document after this returns.
## Returns {ok, error, content, snapshot}.
func restore(path: String, file_name: String) -> Dictionary:
	var loaded := read(path, file_name)
	if !bool(loaded.get("ok", false)):
		return {"ok": false, "error": str(loaded.get("error", "")), "content": "", "snapshot": {}}

	var target := Paths.normalize(path)
	var parent := target.get_base_dir()
	if !parent.is_empty():
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(parent))

	var result: Dictionary = Store.save(target, str(loaded.get("content", "")))
	if !result.get("ok", false):
		return {
			"ok": false,
			"error": str(result.get("error", "Could not write the file.")),
			"content": "",
			"snapshot": loaded.get("snapshot", {}),
		}

	var snapshot_info: Dictionary = loaded.get("snapshot", {})
	restored.emit(target, snapshot_info)
	changed.emit(target)
	return {
		"ok": true,
		"error": "",
		"content": str(loaded.get("content", "")),
		"snapshot": snapshot_info,
	}


## Rows for the diff dialog: snapshot content is "old", the current buffer is
## "new". Uses the same bounded line diff as the Git gutter.
func diff(path: String, file_name: String, current_text: String) -> Dictionary:
	var loaded := read(path, file_name)
	if !bool(loaded.get("ok", false)):
		return {"ok": false, "error": str(loaded.get("error", "")), "rows": [], "lines": []}

	var rows: Dictionary = Diff.line_diff(str(loaded.get("content", "")), current_text)
	var lines: Array = []
	for row in rows.get("rows", []):
		var kind := str(row.get("kind", "context"))
		if kind == "context":
			lines.append({"kind": "context", "text": "  " + str(row.get("right", ""))})
		elif kind == "add":
			lines.append({"kind": "add", "text": "+ " + str(row.get("right", ""))})
		elif kind == "delete":
			lines.append({"kind": "delete", "text": "- " + str(row.get("left", ""))})
		elif kind == "modify":
			lines.append({"kind": "delete", "text": "- " + str(row.get("left", ""))})
			lines.append({"kind": "add", "text": "+ " + str(row.get("right", ""))})
		else:
			lines.append({"kind": "gap", "text": "  …"})

	return {
		"ok": true,
		"error": "",
		"rows": rows.get("rows", []),
		"lines": lines,
		"added": int(rows.get("added", 0)),
		"modified": int(rows.get("modified", 0)),
		"deleted": int(rows.get("deleted", 0)),
		"old_lines": int(rows.get("old_lines", 0)),
		"new_lines": int(rows.get("new_lines", 0)),
		"snapshot": loaded.get("snapshot", {}),
	}


## Enforces count, age and byte limits. Returns how many files were removed.
func prune(path: String) -> int:
	var directory := directory_for(path)
	if directory.is_empty():
		return 0

	var removed := 0
	var now := _now()
	var kept := 0
	var total_bytes := 0

	for file_name in _snapshot_files(directory):
		var full := directory.path_join(file_name)
		var payload := _read_payload(directory, file_name)
		if payload.is_empty():
			DirAccess.remove_absolute(ProjectSettings.globalize_path(full))
			removed += 1
			continue

		var timestamp := int(payload.get("timestamp", 0))
		var bytes := int(payload.get("bytes", str(payload.get("content", "")).to_utf8_buffer().size()))
		var too_old := timestamp > 0 and now - timestamp > MAX_AGE_SECONDS
		var too_many := kept >= MAX_SNAPSHOTS
		# The newest snapshot always survives, even over the byte cap —
		# otherwise a file whose snapshot exceeds MAX_BYTES would have it
		# deleted by the very prune() that follows snapshot(), and its
		# history would be completely silent.
		var too_big := kept > 0 and total_bytes + bytes > MAX_BYTES

		if too_old or too_many or too_big:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(full))
			removed += 1
			continue

		kept += 1
		total_bytes += bytes

	if removed > 0:
		var dir := DirAccess.open(ProjectSettings.globalize_path(directory))
		if dir != null and dir.get_files().is_empty() and dir.get_directories().is_empty():
			DirAccess.remove_absolute(ProjectSettings.globalize_path(directory))
	return removed


func clear(path: String) -> int:
	var directory := directory_for(path)
	if directory.is_empty():
		return 0
	var removed := 0
	for file_name in _snapshot_files(directory):
		if DirAccess.remove_absolute(ProjectSettings.globalize_path(directory.path_join(file_name))) == OK:
			removed += 1
	if removed > 0:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(directory))
		changed.emit(Paths.normalize(path))
	return removed


func clear_all() -> int:
	var removed := 0
	var dir := DirAccess.open(ProjectSettings.globalize_path(root))
	if dir == null:
		return 0
	for sub in dir.get_directories():
		var sub_dir := DirAccess.open(ProjectSettings.globalize_path(root.path_join(sub)))
		if sub_dir == null:
			continue
		for file_name in sub_dir.get_files():
			if DirAccess.remove_absolute(ProjectSettings.globalize_path(root.path_join(sub).path_join(file_name))) == OK:
				removed += 1
		DirAccess.remove_absolute(ProjectSettings.globalize_path(root.path_join(sub)))
	return removed


static func reason_label(reason: String) -> String:
	return str(REASON_LABELS.get(reason, reason.capitalize()))


static func format_timestamp(timestamp: int) -> String:
	if timestamp <= 0:
		return "unknown time"
	var date := Time.get_datetime_dict_from_unix_time(timestamp)
	return "%04d-%02d-%02d %02d:%02d" % [
		int(date.get("year", 1970)),
		int(date.get("month", 1)),
		int(date.get("day", 1)),
		int(date.get("hour", 0)),
		int(date.get("minute", 0)),
	]


func _latest_payload(path: String) -> Dictionary:
	var directory := directory_for(path)
	if directory.is_empty():
		return {}
	var files := _snapshot_files(directory)
	if files.is_empty():
		return {}
	var payload := _read_payload(directory, files[0])
	if !payload.is_empty():
		payload["_file"] = files[0]
	return payload


func _metadata(payload: Dictionary) -> Dictionary:
	return {
		"file": str(payload.get("_file", "")),
		"path": str(payload.get("path", "")),
		"reason": str(payload.get("reason", "")),
		"reason_label": reason_label(str(payload.get("reason", ""))),
		"timestamp": int(payload.get("timestamp", 0)),
		"created_msec": int(payload.get("created_msec", 0)),
		"bytes": int(payload.get("bytes", 0)),
		"time_label": format_timestamp(int(payload.get("timestamp", 0))),
	}


func _read_payload(directory: String, file_name: String) -> Dictionary:
	if !_safe_file_name(file_name):
		return {}
	var result: Dictionary = Store.load_json(directory.path_join(file_name))
	if !bool(result.get("ok", false)):
		return {}
	var data: Dictionary = result.get("data", {})
	if !data.has("content"):
		return {}
	return data


func _snapshot_files(directory: String) -> Array:
	var names: Array = []
	var dir := DirAccess.open(ProjectSettings.globalize_path(directory))
	if dir == null:
		return names
	for file_name in dir.get_files():
		if str(file_name).begins_with("snap-") and str(file_name).ends_with(".json"):
			names.append(str(file_name))
	names.sort()
	names.reverse()
	return names


func _ensure_directory(directory: String) -> bool:
	var global := ProjectSettings.globalize_path(directory)
	var result := DirAccess.make_dir_recursive_absolute(global)
	return result == OK and DirAccess.dir_exists_absolute(global)


func _safe_file_name(file_name: String) -> bool:
	if file_name.is_empty():
		return false
	if file_name.get_file() != file_name:
		return false
	if file_name.contains("\\") or file_name.contains("/") or file_name.contains(".."):
		return false
	return file_name.ends_with(".json")


func _clean_reason(reason: String) -> String:
	var value := reason.strip_edges().to_lower()
	return value if !value.is_empty() else "save"


func _now() -> int:
	if now_override > 0:
		return now_override
	return int(Time.get_unix_time_from_system())


func _now_msec() -> int:
	if now_override > 0:
		return now_override * 1000
	return int(Time.get_unix_time_from_system() * 1000.0)


func _failure(message: String) -> Dictionary:
	return {
		"ok": false,
		"error": message,
		"file": "",
		"snapshot": {},
		"deduped": false,
		"pruned": 0,
	}
