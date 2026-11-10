extends RefCounted

## Remembers whether Beginner Mode is on and what the text looked like before
## it was enabled.
##
## Beginner Mode is intentionally reversible: enabling raises the editor font
## size (and camera zoom, if it is below the comfortable floor) and records the
## previous values; disabling writes them back. The record lives in
## `user://beginner_mode.json` rather than in the generic settings file so a
## settings reset can never leave the editor stuck at 20 px.

const Store = preload("res://src/base/file_store.gd")

const DEFAULT_PATH := "user://beginner_mode.json"
const MIN_FONT_SIZE := 20
const MIN_ZOOM := 1.15
const MAX_FONT_SIZE := 48
const MIN_ZOOM_LIMIT := 0.1
const MAX_ZOOM_LIMIT := 3.0

var state_path: String = DEFAULT_PATH

var _state: Dictionary = _default_state()
var _loaded: bool = false


func load_state() -> Dictionary:
	if _loaded:
		return _state.duplicate(true)

	var result: Dictionary = Store.load_json(state_path)
	if bool(result.get("ok", false)):
		var data: Dictionary = result.get("data", {})
		_state["enabled"] = bool(data.get("enabled", false))
		_state["previous_font_size"] = clampi(int(data.get("previous_font_size", 0)), 0, MAX_FONT_SIZE)
		_state["previous_zoom"] = clampf(float(data.get("previous_zoom", 0.0)), 0.0, MAX_ZOOM_LIMIT)
		_state["active_font_size"] = clampi(int(data.get("active_font_size", 0)), 0, MAX_FONT_SIZE)
		_state["active_zoom"] = clampf(float(data.get("active_zoom", 0.0)), 0.0, MAX_ZOOM_LIMIT)
	_loaded = true
	return _state.duplicate(true)


func save_state() -> Dictionary:
	return Store.save_json(state_path, _state)


func is_enabled() -> bool:
	load_state()
	return bool(_state.get("enabled", false))


## Turns the mode on. Repeating the call is harmless and keeps the originally
## remembered values instead of recording the enlarged ones as "previous".
## Returns the sizes FileManager should apply now.
func enable(current_font_size: int, current_zoom: float) -> Dictionary:
	load_state()
	if bool(_state.get("enabled", false)) and int(_state.get("active_font_size", 0)) > 0:
		return _result(true, int(_state.get("active_font_size", MIN_FONT_SIZE)), float(_state.get("active_zoom", MIN_ZOOM)), false)

	var font := clampi(current_font_size, 8, MAX_FONT_SIZE)
	var zoom := clampf(current_zoom, MIN_ZOOM_LIMIT, MAX_ZOOM_LIMIT)

	_state["enabled"] = true
	_state["previous_font_size"] = font
	_state["previous_zoom"] = zoom if zoom > 0.0 else 1.0
	_state["active_font_size"] = maxi(font, MIN_FONT_SIZE)
	_state["active_zoom"] = maxf(zoom, MIN_ZOOM)
	save_state()
	return _result(true, int(_state["active_font_size"]), float(_state["active_zoom"]), true)


## Turns the mode off and returns the sizes to restore. Disabling twice is a
## no-op, so startup and the settings checkbox can both call it safely.
func disable() -> Dictionary:
	load_state()
	if !bool(_state.get("enabled", false)):
		return _result(false, 0, 0.0, false)

	var previous_font := int(_state.get("previous_font_size", 0))
	var previous_zoom := float(_state.get("previous_zoom", 0.0))

	_state["enabled"] = false
	_state["previous_font_size"] = 0
	_state["previous_zoom"] = 0.0
	_state["active_font_size"] = 0
	_state["active_zoom"] = 0.0
	save_state()
	return _result(false, previous_font, previous_zoom, true)


func sync(should_be_enabled: bool, current_font_size: int, current_zoom: float) -> Dictionary:
	load_state()
	if should_be_enabled:
		return enable(current_font_size, current_zoom)
	return disable()


## Confirmation copy used before a destructive action. Beginner mode gets a
## consequence-first sentence instead of a terse warning.
func confirm_message(action: String, detail: String = "") -> String:
	var text := action
	if !detail.is_empty():
		text += "\n\n" + detail
	if !is_enabled():
		return text
	return text + "\n\nYou can undo most changes from History. This one is worth a pause."


func reset() -> void:
	_state = _default_state()
	_loaded = true
	save_state()


func _result(enabled: bool, font_size: int, zoom: float, changed: bool) -> Dictionary:
	return {
		"ok": true,
		"enabled": enabled,
		"font_size": font_size,
		"zoom": zoom,
		"changed": changed,
	}


static func _default_state() -> Dictionary:
	return {
		"version": 1,
		"enabled": false,
		"previous_font_size": 0,
		"previous_zoom": 0.0,
		"active_font_size": 0,
		"active_zoom": 0.0,
	}
