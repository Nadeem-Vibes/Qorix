extends RefCounted

## Single source of truth for every action the editor can perform.
##
## Menus, the toolbar, the command palette and the keyboard both read this
## registry. Adding a command is one register() call: no second list to edit in
## the palette, and no third list for shortcuts.
##
## Registered entry keys:
##   label             display name
##   category          menu group ("File", "Edit", "View", ...)
##   shortcut          default shortcut text, e.g. "Ctrl+Shift+P"
##   default_shortcut  filled automatically; survives user rebinding
##   scope             global / editor / terminal / palette / dialog
##   handler           Callable, receives the args passed to execute()
##   enabled           bool or Callable returning bool
##   checked           bool or Callable for menu/palette check marks
##   icon              glyph used by the toolbar
##   hidden            true keeps it out of menus and the palette
##   show_in_menu      default true
##   show_in_toolbar   default false
##   toolbar_order     lower numbers appear first in the toolbar
##   defer_execute     palette closes, waits for its fade, then runs it
##   beginner_label    plain-language label shown while Beginner Mode is on
##   beginner_hidden   true keeps the command out of Beginner Mode menus/palette

signal changed
signal executed(id: String, args: Array)

var _commands: Dictionary = {}
var _order: Array[String] = []
var _batch_depth: int = 0
var _notify_pending: bool = false
var _beginner_mode: bool = false


func register(id: String, options: Dictionary = {}) -> Dictionary:
	var command_id := str(id).strip_edges()
	if command_id.is_empty():
		push_warning("[commands] ignored a command with no id")
		return {}

	var entry: Dictionary = options.duplicate(true)
	entry["id"] = command_id
	entry["label"] = str(entry.get("label", command_id))
	entry["category"] = str(entry.get("category", "Other"))
	entry["scope"] = str(entry.get("scope", "global"))
	entry["shortcut"] = str(entry.get("shortcut", ""))
	if !entry.has("default_shortcut"):
		entry["default_shortcut"] = entry["shortcut"]
	entry["default_shortcut"] = str(entry.get("default_shortcut", entry["shortcut"]))
	entry["handler"] = entry.get("handler", Callable())
	entry["enabled"] = entry.get("enabled", true)
	entry["hidden"] = bool(entry.get("hidden", false))
	entry["show_in_menu"] = bool(entry.get("show_in_menu", true))
	entry["show_in_toolbar"] = bool(entry.get("show_in_toolbar", false))
	entry["toolbar_order"] = int(entry.get("toolbar_order", 100))
	entry["defer_execute"] = bool(entry.get("defer_execute", false))
	entry["beginner_label"] = str(entry.get("beginner_label", ""))
	entry["beginner_hidden"] = bool(entry.get("beginner_hidden", false))

	if !_commands.has(command_id):
		_order.append(command_id)
	_commands[command_id] = entry
	_notify()
	return entry.duplicate(true)


func unregister(id: String) -> bool:
	var command_id := str(id)
	if !_commands.has(command_id):
		return false
	_commands.erase(command_id)
	_order.erase(command_id)
	_notify()
	return true


func has(id: String) -> bool:
	return _commands.has(str(id))


func get_command(id: String) -> Dictionary:
	var entry: Variant = _commands.get(str(id))
	return _present(entry) if entry is Dictionary else {}


func all() -> Array:
	var out: Array = []
	for id in _order:
		if !_commands.has(id):
			continue
		var entry: Dictionary = _commands[id]
		if _beginner_mode and bool(entry.get("beginner_hidden", false)):
			continue
		out.append(_present(entry))
	return out


## Commands whose scope applies in `scope`, including global commands.
func for_scope(scope: String) -> Array:
	var out: Array = []
	for command in all():
		var command_scope := str(command.get("scope", "global"))
		if command_scope == "global" or command_scope == scope:
			out.append(command)
	return out


func categories() -> Array[String]:
	var out: Array[String] = []
	for command in all():
		var category := str(command.get("category", "Other"))
		if !out.has(category):
			out.append(category)
	return out


func set_beginner_mode(enabled: bool) -> void:
	if _beginner_mode == enabled:
		return
	_beginner_mode = enabled
	_notify()


func beginner_mode() -> bool:
	return _beginner_mode


func _present(entry: Dictionary) -> Dictionary:
	var out := entry.duplicate(true)
	# Localization happens at presentation time, not registration time, so a
	# language switch updates menus, the palette and the keybinding panel from
	# the same command entry.
	out["label"] = TranslationServer.translate(str(out.get("label", "")))
	if out.has("beginner_label"):
		out["beginner_label"] = TranslationServer.translate(str(out.get("beginner_label", "")))
	if _beginner_mode:
		var plain := str(entry.get("beginner_label", ""))
		if !plain.is_empty():
			out["label"] = TranslationServer.translate(plain)
		out["beginner_mode"] = true
	return out


func set_shortcut(id: String, shortcut: String) -> bool:
	var command_id := str(id)
	if !_commands.has(command_id):
		return false
	_commands[command_id]["shortcut"] = str(shortcut)
	_notify()
	return true


func is_enabled(id: String) -> bool:
	var entry: Variant = _commands.get(str(id))
	if !(entry is Dictionary):
		return false
	return _evaluate_bool(entry.get("enabled", true), true)


func is_checked(id: String) -> bool:
	var entry: Variant = _commands.get(str(id))
	if !(entry is Dictionary) or !entry.has("checked"):
		return false
	return _evaluate_bool(entry.get("checked"), false)


## Runs a command. Scope is intentionally NOT enforced here: the palette and
## menus may execute any visible command, while keyboard routing filters by
## scope before calling execute().
func execute(id: String, args: Array = []) -> Dictionary:
	var command_id := str(id)
	var entry: Variant = _commands.get(command_id)
	if !(entry is Dictionary):
		return {"ok": false, "error": "Unknown command: " + command_id}

	if !is_enabled(command_id):
		return {"ok": false, "error": "Command is disabled: " + command_id}

	var handler: Variant = entry.get("handler")
	if !(handler is Callable) or !(handler as Callable).is_valid():
		return {"ok": false, "error": "Command has no handler: " + command_id}

	(handler as Callable).callv(args)
	executed.emit(command_id, args)
	return {"ok": true, "error": ""}


## Coalesces a burst of registrations (theme/recents refresh) into one UI
## rebuild instead of one per command.
func begin_batch() -> void:
	_batch_depth += 1


func end_batch() -> void:
	_batch_depth = maxi(0, _batch_depth - 1)
	if _batch_depth == 0 and _notify_pending:
		_notify_pending = false
		changed.emit()


func _notify() -> void:
	if _batch_depth > 0:
		_notify_pending = true
		return
	changed.emit()


static func _evaluate_bool(value: Variant, fallback: bool) -> bool:
	if value is Callable:
		var callback: Callable = value
		if !callback.is_valid():
			return fallback
		return bool(callback.call())
	return bool(value)
