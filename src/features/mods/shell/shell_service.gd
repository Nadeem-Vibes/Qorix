extends RefCounted

## Exclusive shell takeover with exact restore.
##
## The service is host-owned: it snapshots the core HUD, adds ModShell above it,
## hides the panels it may hide, and applies camera insets from the reserved
## editor rectangle. `exit` writes the snapshot back verbatim.
##
## It never frees a core panel, never reparents the CodeEdit and never touches the
## host chrome. A second owner gets `shell.busy`; the first owner is never evicted
## silently.

const Result = preload("res://src/features/mods/mod_result.gd")
const Snapshot = preload("res://src/features/mods/shell/shell_snapshot.gd")
const ModShell = preload("res://src/features/mods/shell/mod_shell.gd")
const Catalog = preload("res://src/features/mods/ui/mod_widget_catalog.gd")

const MAX_INSET := 10000.0

var owner_id := ""
var shell = null
var snapshot: Dictionary = {}
var insets: Dictionary = Snapshot.empty_insets()
var custom_insets := false
var editor_visible := true
var started_at_ms: int = 0
var last_reason := ""

var _context: Dictionary = {}
var _previous_world_visible := true
var _world_changed := false


## context:
##   panels            Callable() -> Dictionary[String, CanvasItem]
##   add_layer         Callable(CanvasLayer)
##   remove_layer      Callable(CanvasLayer)
##   apply_insets      Callable(Dictionary)
##   set_world_visible Callable(bool) -> Variant (previous visibility)
##   ui                ModUiRegistry
##   mod_name          Callable(id) -> String
##   set_shell_marker  Callable(bool), optional (crash-loop guard)
##   viewport_size     Callable() -> Vector2, optional
func setup(context: Dictionary) -> void:
	_context = context


func is_active() -> bool:
	return owner_id != "" and shell != null


func takeover(mod_id_value: String, spec: Dictionary) -> Dictionary:
	var key := str(mod_id_value)
	if is_active() and owner_id != key:
		return Result.error(
			"shell.busy",
			"'%s' already owns the screen. Exit that shell before taking over." % owner_id,
		)

	var layout: Variant = spec.get("layout", null)
	if !(layout is Dictionary):
		return Result.error("shell.invalid_spec", "A shell needs a layout object.")
	if !Catalog.CONTAINERS.has(str((layout as Dictionary).get("type", "panel"))):
		return Result.error(
			"shell.invalid_spec",
			"The shell root must be one of: %s." % ", ".join(Catalog.CONTAINERS),
		)
	var validated := Catalog.validate(layout)
	if !bool(validated.get("ok", false)):
		return Result.error("shell.invalid_spec", str(validated.get("error", "The layout is invalid.")))

	var editors := _count_type(layout, "editor")
	if editors > 1:
		return Result.error(
			"shell.editor_slot",
			"A shell reserves at most one editor rectangle; API 1 has one code viewport.",
		)

	if is_active():
		exit(owner_id, "replaced")

	var panels := _panels()
	var viewport := _viewport_size()
	snapshot = Snapshot.capture(panels, viewport)

	var restore: Variant = _context.get("restore_editor_focus", Callable())
	var restore_focus: Callable = restore if restore is Callable else Callable()

	var instance := ModShell.new()
	instance.setup(
		layout,
		_mod_name(key),
		key,
		_context.get("ui", null),
		Callable(self, "_on_chrome_exit"),
		restore_focus,
	)
	instance.insets_changed.connect(Callable(self, "_on_insets"))
	_add_layer(instance)

	shell = instance
	owner_id = key
	started_at_ms = int(Time.get_ticks_msec())
	last_reason = ""
	custom_insets = false
	insets = Snapshot.empty_insets()

	var requested_visible := bool(spec.get("editor_visible", true))
	editor_visible = requested_visible
	_previous_world_visible = _set_world_visible(requested_visible)
	_world_changed = true

	Snapshot.hide(panels)
	_apply_insets(insets)

	if spec.get("insets") is Dictionary:
		set_content_insets(key, spec["insets"])

	_set_marker(true)
	return Result.ok(state())


func exit(mod_id_value: String, reason: String = "") -> Dictionary:
	var key := str(mod_id_value)
	if !is_active():
		return Result.ok(state())
	if owner_id != key:
		return Result.error("state.invalid", "Only the shell owner can exit it.")

	# Restore the panels the shell hid. If a core panel is permanently missing
	# the editor keeps the hidden layout with no explanation — say so.
	var restored := Snapshot.restore(snapshot, _panels())
	if !restored:
		push_warning("Mods: a shell panel was missing; the workspace layout may not be fully restored.")
	_remove_layer(shell)
	shell.teardown()
	if is_instance_valid(shell):
		shell.queue_free()
	shell = null

	if _world_changed:
		_set_world_visible(_previous_world_visible)
	_world_changed = false

	custom_insets = false
	owner_id = ""
	last_reason = reason if !reason.is_empty() else "exited"
	started_at_ms = 0
	_set_marker(false)
	snapshot = {}
	editor_visible = true
	_apply_insets(Snapshot.empty_insets())
	return Result.ok(state())


func exit_for_mod(mod_id_value: String, reason: String = "The mod stopped.") -> void:
	if owner_id == str(mod_id_value) and is_active():
		exit(owner_id, reason)


func reset_mod(mod_id_value: String, reason: String = "The mod stopped.") -> void:
	exit_for_mod(mod_id_value, reason)


func set_editor_visible(mod_id_value: String, visible: bool) -> Dictionary:
	var check := _check_owner(mod_id_value)
	if !check.is_empty():
		return check
	editor_visible = bool(visible)
	_set_world_visible(editor_visible)
	return Result.ok(state())


func set_content_insets(mod_id_value: String, values: Dictionary) -> Dictionary:
	var check := _check_owner(mod_id_value)
	if !check.is_empty():
		return check

	if values.is_empty():
		custom_insets = false
		insets = Snapshot.empty_insets()
		_apply_insets(insets)
		return Result.ok(state())

	var clean: Dictionary = {}
	for key in ["left", "top", "right", "bottom"]:
		var raw: Variant = values.get(key, 0)
		if !(raw is int or raw is float):
			return Result.error("shell.insets_invalid", "'%s' must be a number." % key)
		clean[key] = clampf(float(raw), 0.0, MAX_INSET)

	custom_insets = true
	insets = clean
	_apply_insets(insets)
	return Result.ok(state())


func state() -> Dictionary:
	return {
		"owner": owner_id,
		"active": is_active(),
		"editor_visible": editor_visible,
		"custom_insets": custom_insets,
		"insets": insets.duplicate(true),
		"panels": (snapshot.get("panels", {}) as Dictionary).size() if snapshot is Dictionary else 0,
		"hidden": Snapshot.hidden_count(_panels()) if is_active() else 0,
		"reason": last_reason,
		"duration_ms": maxi(0, int(Time.get_ticks_msec()) - started_at_ms) if started_at_ms > 0 else 0,
	}


## Panic path: the root input handler calls this before any mod. Returns whether
## a shell was exited so the caller can implement the two-press escalation.
func panic() -> Dictionary:
	if !is_active():
		return {"had_shell": false, "owner": ""}
	var previous := owner_id
	exit(previous, "panic")
	return {"had_shell": true, "owner": previous}


func _on_chrome_exit() -> void:
	if is_active():
		exit(owner_id, "exited")


func _on_insets(next: Dictionary) -> void:
	if custom_insets:
		return
	insets = next.duplicate(true)
	_apply_insets(insets)


## Always notifies: the payload's `active` flag is what tells the camera whether
## to frame (true while a shell owns the screen) or to drop the insets (false on
## exit). A zeroed dictionary with active = true still suppresses the left dock
## inset, which is what a shell with a hidden editor wants.
func _apply_insets(values: Dictionary) -> void:
	var apply: Variant = _context.get("apply_insets", Callable())
	if !(apply is Callable) or !(apply as Callable).is_valid():
		return
	var payload := values.duplicate(true)
	payload["active"] = is_active()
	(apply as Callable).call(payload)


func _panels() -> Dictionary:
	var callable: Variant = _context.get("panels", Callable())
	if callable is Callable and (callable as Callable).is_valid():
		var value: Variant = (callable as Callable).call()
		if value is Dictionary:
			return value
	return {}


func _viewport_size() -> Vector2:
	var callable: Variant = _context.get("viewport_size", Callable())
	if callable is Callable and (callable as Callable).is_valid():
		var value: Variant = (callable as Callable).call()
		if value is Vector2:
			return value
	return Vector2.ZERO


func _add_layer(layer: CanvasLayer) -> void:
	var callable: Variant = _context.get("add_layer", Callable())
	if callable is Callable and (callable as Callable).is_valid():
		(callable as Callable).call(layer)


func _remove_layer(layer: CanvasLayer) -> void:
	var callable: Variant = _context.get("remove_layer", Callable())
	if callable is Callable and (callable as Callable).is_valid():
		(callable as Callable).call(layer)


func _set_world_visible(visible: bool) -> bool:
	var callable: Variant = _context.get("set_world_visible", Callable())
	if callable is Callable and (callable as Callable).is_valid():
		var previous: Variant = (callable as Callable).call(bool(visible))
		if previous is bool:
			return bool(previous)
	return true


func _set_marker(active: bool) -> void:
	var callable: Variant = _context.get("set_shell_marker", Callable())
	if callable is Callable and (callable as Callable).is_valid():
		(callable as Callable).call(bool(active))


func _mod_name(id: String) -> String:
	var callable: Variant = _context.get("mod_name", Callable())
	if callable is Callable and (callable as Callable).is_valid():
		var value: Variant = (callable as Callable).call(id)
		return str(value) if value != null and !str(value).is_empty() else id
	return id


func _check_owner(mod_id_value: String) -> Dictionary:
	if !is_active():
		return Result.error("state.invalid", "No shell is active.")
	if owner_id != str(mod_id_value):
		return Result.error("state.invalid", "Another mod owns the active shell.")
	return {}


func _count_type(spec: Dictionary, type: String) -> int:
	var count := 1 if str(spec.get("type", "")) == type else 0
	if spec.get("children") is Array:
		for child in spec["children"]:
			if child is Dictionary:
				count += _count_type(child, type)
	return count
