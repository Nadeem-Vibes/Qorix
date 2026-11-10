extends RefCounted

## Reads `res://resources/templates/manifest.json` and copies a starter project into a
## folder the person chooses. The service never overwrites an existing file:
## a single-file template gets a suffixed name, and a multi-file template gets
## its own uniquely named subfolder so its relative links keep working.

const MANIFEST_PATH := "res://resources/templates/manifest.json"
const TEMPLATE_ROOT := "res://resources/templates"
const Store = preload("res://src/base/file_store.gd")
const Paths = preload("res://src/base/path_utils.gd")

var manifest_path: String = MANIFEST_PATH

var _templates: Array = []
var _by_id: Dictionary = {}
var _loaded: bool = false
var _error: String = ""


func load_templates(force: bool = false) -> Dictionary:
	if _loaded and !force:
		return {"ok": _error.is_empty(), "templates": _templates.duplicate(true), "error": _error}

	_templates.clear()
	_by_id.clear()
	_error = ""

	var text := ""
	if FileAccess.file_exists(manifest_path):
		text = FileAccess.get_file_as_string(manifest_path)
	if text.strip_edges().is_empty():
		_error = "The template manifest is missing or empty."
		_loaded = true
		return {"ok": false, "templates": [], "error": _error}

	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		_error = "The template manifest is not a JSON object."
		_loaded = true
		return {"ok": false, "templates": [], "error": _error}

	var raw: Variant = (parsed as Dictionary).get("templates", [])
	if !(raw is Array):
		_error = "The template manifest has no templates array."
		_loaded = true
		return {"ok": false, "templates": [], "error": _error}

	for item in raw:
		if !(item is Dictionary):
			continue
		var entry := _normalize_entry(item)
		if entry.is_empty():
			continue
		_templates.append(entry)
		_by_id[entry["id"]] = entry

	_loaded = true
	return {"ok": _error.is_empty(), "templates": _templates.duplicate(true), "error": _error}


func templates() -> Array:
	load_templates()
	return _templates.duplicate(true)


func get_template(template_id: String) -> Dictionary:
	load_templates()
	var entry: Variant = _by_id.get(str(template_id))
	return (entry as Dictionary).duplicate(true) if entry is Dictionary else {}


func error() -> String:
	load_templates()
	return _error


## Creates the template inside `target_dir`.
## Returns {ok, error, folder, primary, paths, template}.
func create(template_id: String, target_dir: String, preferred_name: String = "") -> Dictionary:
	var entry := get_template(template_id)
	if entry.is_empty():
		return _failure("Unknown template: " + str(template_id))

	var folder := Paths.normalize(target_dir)
	if folder.is_empty():
		return _failure("Choose a folder first.")

	var made := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder))
	if made != OK and !DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(folder)):
		return _failure("Could not create the folder: " + folder)

	var files: Array = entry.get("files", [])
	if files.is_empty():
		return _create_empty(entry, folder, preferred_name)

	# Read everything before writing anything, so a missing starter file does
	# not leave a half-copied template behind.
	var sources: Dictionary = {}
	for relative in files:
		var rel := Paths.normalize(str(relative)).trim_prefix("/")
		if rel.is_empty() or rel.contains(".."):
			return _failure("The template contains an unsafe file path: " + str(relative))
		var source_path := TEMPLATE_ROOT.path_join(str(entry.get("folder", ""))).path_join(rel)
		if !FileAccess.file_exists(source_path):
			return _failure("The template file is missing: " + source_path)
		sources[rel] = FileAccess.get_file_as_string(source_path)

	var write_root := folder
	if files.size() > 1:
		write_root = _unique_folder(folder, str(entry.get("id", "project")))
		var made_root := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(write_root))
		if made_root != OK:
			return _failure("Could not create the template folder: " + write_root)

	var created: Array[String] = []
	for relative in sources.keys():
		var rel := str(relative)
		var target := write_root.path_join(rel)
		# A single-file template must not replace an existing file. Multi-file
		# templates already got a brand-new subfolder above.
		if files.size() == 1 and FileAccess.file_exists(target):
			target = _unique_file(target.get_base_dir(), target.get_file())
		var parent := target.get_base_dir()
		if !parent.is_empty():
			DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(parent))
		var result: Dictionary = Store.save(target, str(sources[rel]))
		if !result.get("ok", false):
			return _failure("Could not write %s: %s" % [target, str(result.get("error", ""))])
		created.append(target)

	var primary_rel := Paths.normalize(str(entry.get("primary", ""))).trim_prefix("/")
	var primary := write_root.path_join(primary_rel) if !primary_rel.is_empty() else (created[0] if !created.is_empty() else "")
	# The single file may have been renamed to avoid overwriting; the returned
	# path has to be the file that actually exists.
	if files.size() == 1 and !created.is_empty():
		primary = created[0]
	return {
		"ok": true,
		"error": "",
		"folder": write_root,
		"primary": primary,
		"paths": created,
		"template": entry,
	}


func _create_empty(entry: Dictionary, folder: String, preferred_name: String) -> Dictionary:
	var name := preferred_name.strip_edges()
	if name.is_empty():
		name = str(entry.get("primary", "untitled.txt"))
	name = Paths.normalize(name).get_file()
	if name.is_empty():
		name = "untitled.txt"
	var target := _unique_file(folder, name)
	var result: Dictionary = Store.save(target, "")
	if !result.get("ok", false):
		return _failure("Could not write %s: %s" % [target, str(result.get("error", ""))])
	return {
		"ok": true,
		"error": "",
		"folder": folder,
		"primary": target,
		"paths": [target],
		"template": entry,
	}


func _normalize_entry(item: Dictionary) -> Dictionary:
	var id := str(item.get("id", "")).strip_edges().to_lower()
	if id.is_empty():
		return {}
	var files: Array = []
	var raw_files: Variant = item.get("files", [])
	if raw_files is Array:
		for file in raw_files:
			if str(file).strip_edges().is_empty():
				continue
			files.append(str(file).replace("\\", "/"))
	return {
		"id": id,
		"label": str(item.get("label", id.capitalize())),
		"description": str(item.get("description", "")),
		"language": str(item.get("language", "")),
		"folder": str(item.get("folder", id)).trim_prefix("/").trim_suffix("/"),
		"primary": str(item.get("primary", "")),
		"files": files,
		"icon": str(item.get("icon", "")),
	}


func _unique_folder(parent: String, base: String) -> String:
	var slug := _slug(base)
	if slug.is_empty():
		slug = "project"
	var candidate := parent.path_join(slug)
	var counter := 2
	while DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(candidate)):
		candidate = parent.path_join("%s-%d" % [slug, counter])
		counter += 1
	return candidate


func _unique_file(folder: String, name: String) -> String:
	var candidate := folder.path_join(name)
	if !FileAccess.file_exists(candidate):
		return candidate
	var extension := name.get_extension()
	var stem := name.get_basename()
	var counter := 2
	while true:
		var next_name := "%s-%d" % [stem, counter]
		if !extension.is_empty():
			next_name += "." + extension
		candidate = folder.path_join(next_name)
		if !FileAccess.file_exists(candidate):
			return candidate
		counter += 1
	return candidate


func _slug(value: String) -> String:
	var out := ""
	for character in value.to_lower():
		if "abcdefghijklmnopqrstuvwxyz0123456789".contains(character):
			out += character
		elif (character == " " or character == "-" or character == "_") and !out.ends_with("-"):
			out += "-"
	return out.trim_suffix("-")


func _failure(message: String) -> Dictionary:
	return {
		"ok": false,
		"error": message,
		"folder": "",
		"primary": "",
		"paths": [],
		"template": {},
	}
