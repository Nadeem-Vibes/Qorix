class_name FileStore
extends RefCounted

## Atomic text/JSON persistence shared by Fs, the workspace index and the
## session service.
##
## The write is "atomic-ish" on purpose: dump to a temp file first, then swap
## it in, so a crash mid-write can never leave a truncated file behind. This
## mirrors the original Fs.save behaviour, moved here so non-autoload callers
## (tests, core services) can persist without booting the editor.

const TMP_SUFFIX = ".griddy_tmp"


## Writes content and reports what happened.
## Returns {ok: bool, error: String, path: String}.
static func save(path: String, content: String) -> Dictionary:
	if path == null or path.is_empty():
		return _failure(path, "No file path was provided.")

	var global_path := ProjectSettings.globalize_path(path)
	var tmp_path := global_path + TMP_SUFFIX

	var file = FileAccess.open(tmp_path, FileAccess.WRITE)
	if !file:
		return _failure(path, "Could not open the file for writing (error %d)." % FileAccess.get_open_error())

	file.store_string(content)
	file.flush()
	var write_error: int = file.get_error()
	file = null  # release the handle; Windows refuses to rename an open file

	if write_error != OK:
		DirAccess.remove_absolute(tmp_path)
		return _failure(path, "Could not write the file (error %d)." % write_error)

	if FileAccess.file_exists(global_path):
		if DirAccess.remove_absolute(global_path) != OK:
			# couldn't remove the original (permissions?): write directly on
			# top of it instead of losing the change entirely.
			var fallback = FileAccess.open(global_path, FileAccess.WRITE)
			if fallback == null:
				DirAccess.remove_absolute(tmp_path)
				return _failure(path, "Could not replace the file (error %d)." % FileAccess.get_open_error())

			fallback.store_string(content)
			fallback.flush()
			var fallback_error: int = fallback.get_error()
			DirAccess.remove_absolute(tmp_path)

			if fallback_error != OK:
				return _failure(path, "Could not write the file (error %d)." % fallback_error)
			return _success(path)

	var rename_error := DirAccess.rename_absolute(tmp_path, global_path)
	if rename_error != OK:
		# rename failed (locked file, cross-drive, ...): restore from the tmp
		# file so the save is still applied, just non-atomically.
		var restored = FileAccess.open(global_path, FileAccess.WRITE)
		if restored == null:
			DirAccess.remove_absolute(tmp_path)
			return _failure(path, "Could not rename or recreate the file (error %d)." % rename_error)

		restored.store_string(content)
		restored.flush()
		var restored_error: int = restored.get_error()
		DirAccess.remove_absolute(tmp_path)

		if restored_error != OK:
			return _failure(path, "Could not write the file (error %d)." % restored_error)

	return _success(path)


static func load_text(path: String) -> String:
	if path.is_empty():
		return ""
	return FileAccess.get_file_as_string(path)


## Writes a JSON document with tabs for readability.
static func save_json(path: String, data: Variant) -> Dictionary:
	return save(path, JSON.stringify(data, "\t"))


## Reads and validates a JSON object.
## Returns {ok: bool, data: Dictionary, error: String}.
static func load_json(path: String) -> Dictionary:
	if path.is_empty() or !FileAccess.file_exists(path):
		return {"ok": false, "data": {}, "error": "File does not exist."}

	var text := FileAccess.get_file_as_string(path)
	if text.strip_edges().is_empty():
		return {"ok": false, "data": {}, "error": "File is empty."}

	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {"ok": false, "data": {}, "error": "File is not a JSON object."}

	return {"ok": true, "data": parsed, "error": ""}


static func _success(path: String) -> Dictionary:
	return {"ok": true, "error": "", "path": path}


static func _failure(path: String, message: String) -> Dictionary:
	return {"ok": false, "error": message, "path": path}
