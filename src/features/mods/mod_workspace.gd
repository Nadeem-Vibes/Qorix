extends RefCounted

## Workspace API bridge (Phase 2).
##
## Reads are cheap and go through the existing WorkspaceService index. A mod
## cannot choose the workspace root: switching roots is host-owned because a
## mod-supplied confirmation flag is not a user decision. The editor's own
## folder picker (and the host trust prompt) remain the only path that changes
## the root.

const Result = preload("res://src/features/mods/mod_result.gd")

const MAX_LIST := 200

var editor = null


func _init(editor_ref = null) -> void:
	editor = editor_ref


func root() -> Dictionary:
	return Result.ok(str(_workspace().get("root", "")))


func name() -> Dictionary:
	return Result.ok(str(_workspace().get("name", "")))


func has_workspace() -> Dictionary:
	return Result.ok(bool(_workspace().get("has", false)))


func list(payload: Dictionary) -> Dictionary:
	var service = _workspace_service()
	if service == null:
		return Result.ok([])

	var filter := str(payload.get("filter", ""))
	if service.has_method("quick_open_items"):
		return Result.ok(service.quick_open_items(filter, MAX_LIST))

	var out: Array = []
	for entry in service.entries:
		if out.size() >= MAX_LIST:
			break
		if !filter.is_empty() and !str(entry.rel).to_lower().contains(filter.to_lower()):
			continue
		out.append({"label": str(entry.rel), "path": str(entry.path), "rel": str(entry.rel)})
	return Result.ok(out)


func _workspace_service():
	if editor == null:
		return null
	return editor.get("workspace")


func _workspace() -> Dictionary:
	var service = _workspace_service()
	if service == null:
		return {"root": "", "name": "", "has": false}
	var has := bool(service.has_workspace()) if service.has_method("has_workspace") else false
	var root_path := str(service.root) if has else ""
	var display := str(service.workspace_name()) if has and service.has_method("workspace_name") else ""
	return {"root": root_path, "name": display, "has": has}
