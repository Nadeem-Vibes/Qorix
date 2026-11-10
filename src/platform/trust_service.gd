class_name TrustService
extends RefCounted

## Per-workspace consent.
##
## Opening a folder is not consent to run programs named inside it: an LSP or
## debug config can name any executable and arguments, and both are read from
## the workspace. Until the user trusts a folder, project-level config files are
## ignored. Global (user://) configs are still honoured because they were
## written by the user, not by the repository.
##
## Trust is per folder, never inherited from a parent, so cloning a repository
## cannot silently borrow trust from an unrelated folder above it. The list
## lives in user://trusted_workspaces.json.

const Paths = preload("res://src/base/path_utils.gd")
const Store = preload("res://src/base/file_store.gd")

const VERSION := 1
const DEFAULT_PATH := "user://trusted_workspaces.json"

var path: String = DEFAULT_PATH
var last_error: String = ""

## canonical path -> display path, in the order they were trusted.
var _roots: Dictionary = {}


func load() -> Dictionary:
	_roots.clear()
	last_error = ""

	if path.is_empty() or !FileAccess.file_exists(path):
		return {"ok": true, "error": ""}

	var loaded := Store.load_json(path)
	if !loaded.get("ok", false):
		last_error = str(loaded.get("error", "Could not read the trusted folders list."))
		return {"ok": false, "error": last_error}

	var data: Variant = loaded.get("data", {})
	var raw_roots: Variant = data.get("roots", []) if data is Dictionary else []
	if raw_roots is Array:
		for item in raw_roots:
			var root := ""
			if item is Dictionary:
				root = str(item.get("path", ""))
			elif item is String:
				root = str(item)
			var key := Paths.canonical(root)
			if !key.is_empty():
				_roots[key] = Paths.normalize(root)

	return {"ok": true, "error": ""}


func save() -> Dictionary:
	var roots: Array = []
	for key in _roots.keys():
		roots.append({
			"path": str(_roots[key]),
			"trusted_at": int(Time.get_unix_time_from_system()),
		})

	var saved := Store.save_json(path, {"version": VERSION, "roots": roots})
	last_error = str(saved.get("error", ""))
	return saved


## Exact-folder trust. An empty or unresolvable path is never trusted, which is
## what makes "no workspace open" fail closed.
func is_trusted(root: String) -> bool:
	var key := Paths.canonical(root)
	return !key.is_empty() and _roots.has(key)


func trust(root: String) -> Dictionary:
	var key := Paths.canonical(root)
	if key.is_empty():
		return {"ok": false, "error": "There is no folder to trust."}
	if _roots.has(key):
		return {"ok": true, "error": ""}

	_roots[key] = Paths.normalize(root)
	var saved := save()
	if !saved.get("ok", false):
		_roots.erase(key)
		return {"ok": false, "error": str(saved.get("error", ""))}
	return {"ok": true, "error": ""}


func revoke(root: String) -> Dictionary:
	var key := Paths.canonical(root)
	if key.is_empty() or !_roots.has(key):
		return {"ok": true, "error": ""}

	var previous: String = _roots[key]
	_roots.erase(key)
	var saved := save()
	if !saved.get("ok", false):
		_roots[key] = previous
		return {"ok": false, "error": str(saved.get("error", ""))}
	return {"ok": true, "error": ""}


func trusted_roots() -> Array:
	var out: Array = []
	for key in _roots.keys():
		out.append(str(_roots[key]))
	return out
