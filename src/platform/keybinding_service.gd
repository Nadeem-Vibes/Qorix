extends Node

## Owns the shortcut layer between raw key events and CommandRegistry.
##
## Defaults come from the commands themselves. Only user overrides are stored
## in user://keybindings.json, so adding a command with a new default shortcut
## shows up automatically after an update instead of being missing from an old
## settings file.
##
## Scopes decide which bindings may fire:
##   global   - anywhere (save, open, toggles)
##   editor   - only while the code editor owns the keyboard
##   terminal - only while the terminal owns the keyboard
##   palette  - while the command palette is open
##   dialog   - while a dialog/panel owns the keyboard
## Global shares every scope; the others only overlap themselves. That is why
## Ctrl+F can open editor find and still be free for a terminal binding.

signal changed

const FileStoreScript = preload("res://src/base/file_store.gd")
const KeyChordScript = preload("res://src/platform/key_chord.gd")

const ACTION_PREFIX := "cmd_"
const CURRENT_VERSION := 1
const DEFAULT_PATH := "user://keybindings.json"

var registry = null
var path: String = DEFAULT_PATH

var _defaults: Dictionary = {}
var _overrides: Dictionary = {}
## Session-only bindings owned by mods. Never written to keybindings.json: a
## persisted override would outlive the command when the mod is disabled.
var _runtime: Dictionary = {}
var _effective: Dictionary = {}
var _chords: Dictionary = {}
var _load_error: String = ""
var _syncing: bool = false


func setup(command_registry) -> void:
	if registry != null and registry.changed.is_connected(_on_registry_changed):
		registry.changed.disconnect(_on_registry_changed)
	registry = command_registry
	if registry != null and !registry.changed.is_connected(_on_registry_changed):
		registry.changed.connect(_on_registry_changed)


## Reads user overrides and installs the matching InputMap actions.
func load_bindings() -> Dictionary:
	_capture_defaults()
	_overrides.clear()
	_load_error = ""

	if FileAccess.file_exists(path):
		var loaded: Dictionary = FileStoreScript.load_json(path)
		if !loaded.get("ok", false):
			_load_error = str(loaded.get("error", "Could not read keybindings.json."))
			push_warning("[keybindings] " + _load_error)
		else:
			var data: Dictionary = loaded.get("data", {})
			var raw: Variant = data.get("bindings", {})
			if !(raw is Dictionary):
				_load_error = "keybindings.json has no bindings object."
				push_warning("[keybindings] " + _load_error)
				raw = {}

			for key in raw.keys():
				var command_id := str(key)
				var value := str(raw[key]).strip_edges()
				if value.is_empty():
					_overrides[command_id] = ""
					continue
				var chord: Dictionary = KeyChordScript.parse(value)
				if !chord.get("ok", false):
					_load_error = "Ignored invalid shortcut for %s: %s" % [command_id, value]
					push_warning("[keybindings] " + _load_error)
					continue
				_overrides[command_id] = str(chord.get("text", value))

	sync_registry()
	build_input_map()
	changed.emit()
	return {
		"ok": _load_error.is_empty(),
		"error": _load_error,
		"overrides": _overrides.size(),
	}


## Re-reads the command list: new commands get their defaults (or an existing
## override), removed commands disappear, and every visible shortcut label is
## updated in one registry-changed burst.
func sync_registry() -> void:
	if registry == null or _syncing:
		return

	_syncing = true
	_capture_defaults()
	registry.begin_batch()
	for command in registry.all():
		var command_id := str(command.get("id", ""))
		if command_id.is_empty():
			continue
		registry.set_shortcut(command_id, _text_for(command_id))
	registry.end_batch()
	_rebuild_chords()
	_syncing = false
	changed.emit()


## A command registered after load_bindings() (a plugin, a test, a dynamic
## recents entry) gets its default shortcut and InputMap action immediately.
## The guard keeps set_shortcut() from re-entering sync_registry().
func _on_registry_changed() -> void:
	if _syncing:
		return
	sync_registry()
	build_input_map()


func binding_for(id: String) -> String:
	var command_id := str(id)
	if _runtime.has(command_id):
		return str(_runtime[command_id])
	if _overrides.has(command_id):
		return str(_overrides[command_id])
	return str(_defaults.get(command_id, ""))


func default_for(id: String) -> String:
	return str(_defaults.get(str(id), ""))


func chord_for(id: String) -> Dictionary:
	var chord: Variant = _chords.get(str(id))
	return chord if chord is Dictionary else {}


func has_override(id: String) -> bool:
	return _overrides.has(str(id))


func overrides() -> Dictionary:
	return _overrides.duplicate()


func load_error() -> String:
	return _load_error


## Assigns a shortcut. Empty text unbinds the command. Returns
## {ok, error, conflicts:[command ids]} without changing anything on failure.
func set_binding(id: String, value: String, force: bool = false) -> Dictionary:
	var command_id := str(id)
	if registry == null or !registry.has(command_id):
		return {"ok": false, "error": "Unknown command: " + command_id, "conflicts": []}

	var text := value.strip_edges()
	var chord: Dictionary = KeyChordScript.blank()
	if !text.is_empty():
		chord = KeyChordScript.parse(text)
		if !chord.get("ok", false):
			return {"ok": false, "error": str(chord.get("error", "Invalid shortcut.")), "conflicts": []}
		text = str(chord.get("text", text))

	if !text.is_empty() and !force:
		var conflicts := _conflicting_commands(command_id, chord)
		if !conflicts.is_empty():
			return {
				"ok": false,
				"error": "Shortcut is already used by " + _command_labels(conflicts) + ".",
				"conflicts": conflicts,
			}

	_overrides[command_id] = text
	sync_registry()
	build_input_map()
	var saved := save_bindings()
	if !saved.get("ok", false):
		return {"ok": false, "error": str(saved.get("error", "Could not save shortcuts.")), "conflicts": []}

	changed.emit()
	return {"ok": true, "error": "", "conflicts": []}


## Binds a command for this session without persisting it. Used by mods through
## ModManager; collisions with any other command are refused, and the command
## keeps its default shortcut when the binding is cleared.
func set_runtime_binding(id: String, value: String, force: bool = false) -> Dictionary:
	var command_id := str(id)
	if registry == null or !registry.has(command_id):
		return {"ok": false, "error": "Unknown command: " + command_id, "conflicts": []}

	var text := value.strip_edges()
	var chord: Dictionary = KeyChordScript.blank()
	if !text.is_empty():
		chord = KeyChordScript.parse(text)
		if !chord.get("ok", false):
			return {"ok": false, "error": str(chord.get("error", "Invalid shortcut.")), "conflicts": []}
		text = str(chord.get("text", text))

	if !text.is_empty() and !force:
		var conflicts := _conflicting_commands(command_id, chord)
		if !conflicts.is_empty():
			return {
				"ok": false,
				"error": "Shortcut is already used by " + _command_labels(conflicts) + ".",
				"conflicts": conflicts,
			}

	_runtime[command_id] = text
	sync_registry()
	build_input_map()
	return {"ok": true, "error": "", "conflicts": []}


func clear_runtime_binding(id: String) -> void:
	var command_id := str(id)
	if !_runtime.has(command_id):
		return
	_runtime.erase(command_id)
	sync_registry()
	build_input_map()


func runtime_bindings() -> Dictionary:
	return _runtime.duplicate()


func reset_binding(id: String) -> Dictionary:
	var command_id := str(id)
	if registry == null or !registry.has(command_id):
		return {"ok": false, "error": "Unknown command: " + command_id}

	_overrides.erase(command_id)
	sync_registry()
	build_input_map()
	save_bindings()
	changed.emit()
	return {"ok": true, "error": ""}


func reset_all() -> Dictionary:
	_overrides.clear()
	sync_registry()
	build_input_map()
	save_bindings()
	changed.emit()
	return {"ok": true, "error": ""}


## Every command with a usable shortcut, as
## [{chord, text, commands:[ids]}], with overlapping scopes only.
func conflicts() -> Array:
	var groups: Dictionary = {}
	for command in registry.all() if registry != null else []:
		var command_id := str(command.get("id", ""))
		var text := binding_for(command_id)
		if text.is_empty() || !_chords.has(command_id):
			continue
		var chord: Dictionary = _chords[command_id]
		var group_key := _chord_key(chord)
		if !groups.has(group_key):
			groups[group_key] = []
		groups[group_key].append(command_id)

	var out: Array = []
	for key in groups.keys():
		var ids: Array = groups[key]
		if ids.size() < 2:
			continue

		var conflict_ids: Array[String] = []
		for i in range(ids.size()):
			for j in range(i + 1, ids.size()):
				var a := str(ids[i])
				var b := str(ids[j])
				if _scope_overlap(_scope_of(a), _scope_of(b)):
					if !conflict_ids.has(a):
						conflict_ids.append(a)
					if !conflict_ids.has(b):
						conflict_ids.append(b)

		if !conflict_ids.is_empty():
			out.append({
				"chord": str(KeyChordScript.format(_chords[conflict_ids[0]])),
				"commands": conflict_ids,
			})
	return out


## Called for every unhandled key event. Returns the command id to execute, or
## "" when nothing in this scope matches. Exact modifier matching is used, so
## Ctrl+Shift+S never also triggers Ctrl+S.
func handle(event: InputEvent, scope: String) -> String:
	if registry == null or !(event is InputEventKey):
		return ""

	var key_event: InputEventKey = event
	if !key_event.pressed or key_event.echo:
		return ""

	for command in registry.for_scope(scope):
		var command_id := str(command.get("id", ""))
		var chord: Variant = _chords.get(command_id)
		if !(chord is Dictionary):
			continue
		if !KeyChordScript.matches(key_event, chord):
			continue
		if !registry.is_enabled(command_id):
			continue
		return command_id

	return ""


func action_name(id: String) -> String:
	return ACTION_PREFIX + str(id).replace(".", "_").replace(":", "_").replace("-", "_").replace(" ", "_")


## Rebuilds the cmd_* InputMap actions from the effective bindings. The editor
## matches events through handle() as well; the actions keep the shortcuts
## discoverable to the engine, tests and future UI.
func build_input_map() -> void:
	for action in InputMap.get_actions():
		var action_name_value := str(action)
		if action_name_value.begins_with(ACTION_PREFIX):
			InputMap.erase_action(action_name_value)

	if registry == null:
		return

	for command in registry.all():
		var command_id := str(command.get("id", ""))
		var chord: Variant = _chords.get(command_id)
		if !(chord is Dictionary) or !chord.get("ok", false):
			continue

		var action := action_name(command_id)
		if !InputMap.has_action(action):
			InputMap.add_action(action)

		var event := InputEventKey.new()
		event.physical_keycode = int(chord.get("keycode", 0))
		event.ctrl_pressed = bool(chord.get("ctrl", false))
		event.alt_pressed = bool(chord.get("alt", false))
		event.shift_pressed = bool(chord.get("shift", false))
		event.meta_pressed = bool(chord.get("meta", false))
		InputMap.action_add_event(action, event)


func save_bindings() -> Dictionary:
	return FileStoreScript.save_json(path, {
		"version": CURRENT_VERSION,
		"bindings": _overrides,
	})


# ── INTERNALS ───────────────────────────────────────────────────────────────

func _capture_defaults() -> void:
	if registry == null:
		return
	for command in registry.all():
		var command_id := str(command.get("id", ""))
		if command_id.is_empty() or _defaults.has(command_id):
			continue
		_defaults[command_id] = str(command.get("default_shortcut", command.get("shortcut", "")))


func _text_for(id: String) -> String:
	return binding_for(id)


func _rebuild_chords() -> void:
	_effective.clear()
	_chords.clear()
	if registry == null:
		return

	for command in registry.all():
		var command_id := str(command.get("id", ""))
		var text := _text_for(command_id)
		_effective[command_id] = text
		if text.is_empty():
			continue
		var chord: Dictionary = KeyChordScript.parse(text)
		if chord.get("ok", false):
			_chords[command_id] = chord


func _conflicting_commands(id: String, chord: Dictionary) -> Array[String]:
	var out: Array[String] = []
	if registry == null:
		return out

	var scope := _scope_of(id)
	for command in registry.all():
		var other_id := str(command.get("id", ""))
		if other_id == id:
			continue
		if !_scope_overlap(scope, _scope_of(other_id)):
			continue
		var other: Variant = _chords.get(other_id)
		if other is Dictionary and KeyChordScript.same(chord, other):
			out.append(other_id)
	return out


func _scope_of(id: String) -> String:
	if registry == null:
		return "global"
	var command: Dictionary = registry.get_command(id)
	return str(command.get("scope", "global"))


func _command_labels(ids: Array) -> String:
	var labels: Array[String] = []
	for id in ids:
		if registry == null:
			continue
		var command: Dictionary = registry.get_command(str(id))
		labels.append(str(command.get("label", id)))
	return ", ".join(labels)


func _chord_key(chord: Dictionary) -> String:
	return "%d|%s%s%s%s" % [
		int(chord.get("keycode", 0)),
		"c" if bool(chord.get("ctrl", false)) else "-",
		"a" if bool(chord.get("alt", false)) else "-",
		"s" if bool(chord.get("shift", false)) else "-",
		"m" if bool(chord.get("meta", false)) else "-",
	]


static func _scope_overlap(a: String, b: String) -> bool:
	if a == "global" or b == "global":
		return true
	return a == b
