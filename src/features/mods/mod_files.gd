extends RefCounted

## Files API bridge (Phase 2).
##
## Every path is workspace-relative. Absolute paths, drive letters and '..' are
## rejected before a FileAccess is opened. Reads and writes are size-limited,
## writes are atomic through FileStore, and delete requires an explicit
## confirmation flag (the Lua SDK pairs it with editor.dialogs.confirm).

const Result = preload("res://src/features/mods/mod_result.gd")
const Paths = preload("res://src/base/path_utils.gd")
const Store = preload("res://src/base/file_store.gd")

const MAX_TEXT_BYTES := 8 * 1024 * 1024
const MAX_LIST_ENTRIES := 2000
const MAX_DEPTH := 16
const SKIP_DIRS := [".git", ".hg", ".svn", ".godot", "node_modules", "__pycache__", ".venv", "venv", "build", "dist"]

var editor = null


func _init(editor_ref = null) -> void:
	editor = editor_ref


func read(payload: Dictionary) -> Dictionary:
	var resolved := resolve(str(payload.get("path", "")))
	if !resolved.get("ok", false):
		return resolved
	var path: String = resolved["value"]

	if !FileAccess.file_exists(path):
		return Result.error("module.not_found", "The file does not exist: " + str(payload.get("path", "")))
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return Result.error("module.unreadable", "The file could not be opened.")
	var size := file.get_length()
	if size > MAX_TEXT_BYTES:
		file = null
		return Result.error("module.too_large", "The file is larger than %d bytes." % MAX_TEXT_BYTES)
	var text := file.get_as_text()
	file = null
	return Result.ok(text)


func write(payload: Dictionary) -> Dictionary:
	var resolved := resolve(str(payload.get("path", "")))
	if !resolved.get("ok", false):
		return resolved
	var path: String = resolved["value"]

	var text := str(payload.get("text", ""))
	var size := text.to_utf8_buffer().size()
	if size > MAX_TEXT_BYTES:
		return Result.error("module.too_large", "The file would be larger than %d bytes." % MAX_TEXT_BYTES)
	if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(path)):
		return Result.error("path.invalid", "The path names a folder.")

	var parent := ProjectSettings.globalize_path(path.get_base_dir())
	if !DirAccess.dir_exists_absolute(parent):
		var made := DirAccess.make_dir_recursive_absolute(parent)
		if made != OK:
			return Result.error("module.unwritable", "The parent folder could not be created.")

	var saved := Store.save(path, text)
	if !saved.get("ok", false):
		return Result.error("module.unwritable", str(saved.get("error", "The file could not be written.")))
	return Result.ok(size)


func exists(payload: Dictionary) -> Dictionary:
	var resolved := resolve(str(payload.get("path", "")), true)
	if !resolved.get("ok", false):
		return resolved
	var path: String = resolved["value"]
	return Result.ok(FileAccess.file_exists(path) or DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(path)))


func list(payload: Dictionary) -> Dictionary:
	var resolved := resolve(str(payload.get("path", "")), true)
	if !resolved.get("ok", false):
		return resolved
	var base: String = resolved["value"]
	if !DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(base)):
		return Result.error("path.invalid", "The folder does not exist.")

	var recursive := bool(payload.get("recursive", false))
	var out: Array = []
	var root := _workspace_root()
	_walk(base, root, recursive, out, 0)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.get("path", "")).naturalnocasecmp_to(str(b.get("path", ""))) < 0
	)
	return Result.ok(out)


func mkdir(payload: Dictionary) -> Dictionary:
	var resolved := resolve(str(payload.get("path", "")))
	if !resolved.get("ok", false):
		return resolved
	var path: String = resolved["value"]
	var made := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path))
	if made != OK and made != ERR_ALREADY_EXISTS:
		return Result.error("module.unwritable", "The folder could not be created (error %d)." % made)
	return Result.ok(true)


func delete(payload: Dictionary) -> Dictionary:
	if !bool(payload.get("confirmed", false)):
		return Result.error(
			"ui.confirmation_required",
			"Deleting a file needs confirmation. Ask with editor.dialogs.confirm, then pass confirmed=true.",
		)

	var resolved := resolve(str(payload.get("path", "")))
	if !resolved.get("ok", false):
		return resolved
	var path: String = resolved["value"]

	var root := _workspace_root()
	if Paths.canonical(path) == Paths.canonical(root):
		return Result.error("path.invalid", "The workspace root cannot be deleted.")

	var is_dir := DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(path))
	if !is_dir and !FileAccess.file_exists(path):
		return Result.error("module.not_found", "The path does not exist.")

	if is_dir:
		var dir := DirAccess.open(path)
		if dir != null and (!dir.get_files().is_empty() or !dir.get_directories().is_empty()):
			return Result.error("module.not_empty", "The folder is not empty.")

	var error := DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	if error != OK:
		return Result.error("module.unwritable", "The path could not be deleted (error %d)." % error)
	return Result.ok(true)


## Resolves a workspace-relative path. `allow_root` is used by list/exists.
func resolve(relative: String, allow_root: bool = false) -> Dictionary:
	var root := _workspace_root()
	if root.is_empty():
		return Result.error("workspace.required", "Open a folder before using file paths.")

	var raw := str(relative).strip_edges().replace("\\", "/")
	if raw.is_empty():
		if allow_root:
			return Result.ok(Paths.normalize(root))
		return Result.error("path.invalid", "The path is empty.")
	if raw.begins_with("/") or (raw.length() >= 2 and raw[1] == ":"):
		return Result.error("path.invalid", "Absolute paths are not allowed; use a workspace-relative path.")
	if raw.contains("..") or raw.contains(":"):
		return Result.error("path.invalid", "'%s' is not a safe workspace path." % relative)

	var full := Paths.normalize(root.path_join(raw))
	if full == Paths.normalize(root):
		if allow_root:
			return Result.ok(full)
		return Result.error("path.invalid", "The workspace root is not a file.")
	if !Paths.is_subpath(root, full):
		return Result.error("path.outside_workspace", "'%s' resolves outside the workspace." % relative)
	return Result.ok(full)


func _walk(directory: String, root: String, recursive: bool, out: Array, depth: int) -> void:
	if depth > MAX_DEPTH or out.size() >= MAX_LIST_ENTRIES:
		return
	var dir := DirAccess.open(directory)
	if dir == null:
		return

	var folders: Array = dir.get_directories()
	folders.sort()
	for name in folders:
		var folder_name := str(name)
		if SKIP_DIRS.has(folder_name):
			continue
		var path := directory.path_join(folder_name)
		var relative := _relative(path, root)
		out.append({"path": relative, "name": folder_name, "is_dir": true, "size": 0})
		if recursive:
			_walk(path, root, true, out, depth + 1)
		if out.size() >= MAX_LIST_ENTRIES:
			return

	var files: Array = dir.get_files()
	files.sort()
	for name in files:
		var file_name := str(name)
		var path := directory.path_join(file_name)
		var size := 0
		var file := FileAccess.open(path, FileAccess.READ)
		if file != null:
			size = file.get_length()
			file = null
		out.append({"path": _relative(path, root), "name": file_name, "is_dir": false, "size": size})
		if out.size() >= MAX_LIST_ENTRIES:
			return


func _relative(path: String, root: String) -> String:
	var relative := Paths.normalize(path)
	var normalized_root := Paths.normalize(root).trim_suffix("/")
	if Paths.canonical(relative) == Paths.canonical(normalized_root):
		return ""
	if Paths.canonical(relative).begins_with(Paths.canonical(normalized_root) + "/"):
		return relative.substr(normalized_root.length() + 1)
	return relative


func _workspace_root() -> String:
	if editor == null:
		return ""
	# A real WorkspaceService is authoritative. `workspace_root_for_tools()`
	# falls back to the process cwd on purpose (Run/save dialogs need it), so it
	# must never turn "no folder open" into a writable workspace for a mod.
	var workspace = editor.get("workspace")
	if workspace != null:
		if workspace.has_method("has_workspace") and workspace.has_workspace():
			return str(workspace.root)
		return ""
	if editor.has_method("workspace_root_for_tools"):
		return str(editor.workspace_root_for_tools())
	return ""
