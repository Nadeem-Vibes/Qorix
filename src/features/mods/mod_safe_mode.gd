extends RefCounted

## Crash-loop guard and safe mode.
##
## The editor writes a session marker when mods activate and rewrites it with
## `clean = true` on a normal exit. If the process dies inside the marker's short
## window twice in a row, the mod set from that session is disabled on the next
## launch: a mod that prevents the editor from reaching a clean quit cannot do it
## a third time.
##
## `--safe-mode` and `--no-mods` start with no mods for this session only; the
## registry is untouched, so the next normal launch tries again.

const Result = preload("res://src/features/mods/mod_result.gd")
const Store = preload("res://src/base/file_store.gd")

const VERSION := 1
const DEFAULT_PATH := "user://mod_session.json"
const SHORT_SESSION_SECONDS := 60
const STREAK_LIMIT := 2
const FLAGS := ["--safe-mode", "--no-mods"]

var path: String = DEFAULT_PATH
var last_error: String = ""

var _streak: int = 0


func _init(marker_path: String = DEFAULT_PATH) -> void:
	path = marker_path


## Decides how this launch should treat mods.
## Returns {safe_mode, disable: Array, streak, reason, previous}.
func evaluate(cmdline_args: PackedStringArray, force_safe_mode: bool = false) -> Dictionary:
	var requested := force_safe_mode
	for argument in cmdline_args:
		if FLAGS.has(str(argument)):
			requested = true

	var previous := marker()
	_streak = 0

	if requested:
		return {
			"safe_mode": true,
			"disable": [],
			"streak": int(previous.get("streak", 0)),
			"reason": "Safe mode was requested on the command line.",
			"previous": previous,
		}

	var disable: Array = []
	var reason := ""

	if !bool(previous.get("clean", true)) and previous.has("started_at"):
		var started_at := int(previous.get("started_at", 0))
		var elapsed := int(Time.get_unix_time_from_system()) - started_at
		if started_at > 0 and elapsed >= 0 and elapsed < SHORT_SESSION_SECONDS:
			_streak = int(previous.get("streak", 0)) + 1
			if _streak >= STREAK_LIMIT:
				var mods: Variant = previous.get("mods", [])
				if mods is Array:
					for id in mods:
						disable.append(str(id))
				_streak = 0
				reason = "Two short sessions ended without a clean exit; the previous mod set was disabled."
				if bool(previous.get("shell", false)):
					reason += " A mod shell was active when the editor stopped."

	return {
		"safe_mode": false,
		"disable": disable,
		"streak": _streak,
		"reason": reason,
		"previous": previous,
	}


## Writes the in-progress marker. Call after the mod set has been chosen.
func begin(active_ids: Array) -> Dictionary:
	return _write({
		"version": VERSION,
		"clean": false,
		"started_at": int(Time.get_unix_time_from_system()),
		"mods": active_ids.duplicate(),
		"shell": false,
		"streak": _streak,
	})


## Records whether a shell was active. The next launch uses it to explain a
## crash-loop disable when the editor stopped inside a takeover.
func mark_shell(active: bool) -> Dictionary:
	var data := marker()
	if data.is_empty():
		return Result.ok()
	data["shell"] = bool(active)
	return _write(data)


## Updates the mod list without resetting the start time (deferred activation).
func update_mods(active_ids: Array) -> Dictionary:
	var data := marker()
	data["mods"] = active_ids.duplicate()
	return _write(data)


## Marks a clean exit. The next launch will not count this session as a crash.
func mark_clean() -> Dictionary:
	var data := marker()
	if str(data.get("started_at", "")) == "":
		data["started_at"] = int(Time.get_unix_time_from_system())
	return _write({
		"version": VERSION,
		"clean": true,
		"started_at": int(data.get("started_at", Time.get_unix_time_from_system())),
		"ended_at": int(Time.get_unix_time_from_system()),
		"mods": data.get("mods", []),
		"streak": 0,
	})


func marker() -> Dictionary:
	if path.is_empty() or !FileAccess.file_exists(path):
		return {}
	var loaded := Store.load_json(path)
	if !loaded.get("ok", false):
		last_error = str(loaded.get("error", "Could not read the mod session marker."))
		return {}
	var data: Variant = loaded.get("data", {})
	return (data as Dictionary).duplicate(true) if data is Dictionary else {}


func streak() -> int:
	return _streak


func _write(data: Dictionary) -> Dictionary:
	var saved := Store.save_json(path, data)
	last_error = str(saved.get("error", ""))
	if !saved.get("ok", false):
		return Result.error("registry.invalid", "Could not write the mod session marker: " + last_error)
	return Result.ok(data)
