extends RefCounted

## Per-mod diagnostics ring buffer and failure record.
##
## Console output is not a diagnostics surface: a mod author needs the last 500
## lines with source and line, and the user needs a card that names the mod and
## offers Disable / Open log. Both read from here.

signal line_added(mod_id: String, entry: Dictionary)
signal failure_changed(mod_id: String, failure: Dictionary)

const CAPACITY := 500
const MAX_MESSAGE_LENGTH := 8192

var _lines: Dictionary = {}
var _failures: Dictionary = {}


func log(mod_id: String, level: String, message: String, context: Dictionary = {}) -> Dictionary:
	var id := str(mod_id)
	var cleaned_level := level if ["info", "warn", "error"].has(level) else "info"
	var text := str(message)
	if text.length() > MAX_MESSAGE_LENGTH:
		text = text.substr(0, MAX_MESSAGE_LENGTH) + "…"

	var entry := {
		"at": int(Time.get_unix_time_from_system()),
		"level": cleaned_level,
		"message": text,
		"source": str(context.get("source", "")),
		"line": int(context.get("line", 0)),
	}
	if context.has("traceback"):
		entry["traceback"] = str(context["traceback"])

	if !_lines.has(id):
		_lines[id] = []

	var lines: Array = _lines[id]
	lines.append(entry)
	while lines.size() > CAPACITY:
		lines.pop_front()

	line_added.emit(id, entry.duplicate(true))
	return entry


func exception(mod_id: String, message: String, traceback: String = "", source: String = "", line: int = 0) -> Dictionary:
	return self.log(mod_id, "error", message, {
		"traceback": traceback,
		"source": source,
		"line": line,
	})


func lines(mod_id: String) -> Array:
	var found: Variant = _lines.get(str(mod_id))
	return (found as Array).duplicate(true) if found is Array else []


func text(mod_id: String) -> String:
	var out: PackedStringArray = []
	for entry in lines(mod_id):
		var location := ""
		if !str(entry.get("source", "")).is_empty():
			location = " (%s:%d)" % [entry.get("source", ""), int(entry.get("line", 0))]
		out.append("[%s] %s%s  %s" % [
			_time_label(int(entry.get("at", 0))),
			str(entry.get("level", "info")).to_upper(),
			location,
			str(entry.get("message", "")),
		])
		if entry.has("traceback") and !str(entry.get("traceback", "")).is_empty():
			out.append(str(entry["traceback"]))
	return "\n".join(out)


func clear(mod_id: String) -> void:
	_lines.erase(str(mod_id))


func mark_failed(mod_id: String, failure: Dictionary) -> void:
	var id := str(mod_id)
	var record := failure.duplicate(true)
	record["at"] = int(record.get("at", Time.get_unix_time_from_system()))
	if !record.has("code"):
		record["code"] = "mod.failed"
	if !record.has("message"):
		record["message"] = "The mod stopped."
	_failures[id] = record
	self.log(id, "error", str(record.get("message", "")))
	failure_changed.emit(id, record.duplicate(true))


func mark_healthy(mod_id: String) -> void:
	var id := str(mod_id)
	if !_failures.has(id):
		return
	_failures.erase(id)
	failure_changed.emit(id, {})


func failure(mod_id: String) -> Dictionary:
	var found: Variant = _failures.get(str(mod_id))
	return (found as Dictionary).duplicate(true) if found is Dictionary else {}


func has_failure(mod_id: String) -> bool:
	return _failures.has(str(mod_id))


func failures() -> Array:
	var ids: Array = _failures.keys()
	ids.sort()
	var out: Array = []
	for id in ids:
		var entry: Dictionary = (_failures[id] as Dictionary).duplicate(true)
		entry["id"] = id
		out.append(entry)
	return out


func clear_failures() -> void:
	_failures.clear()


static func _time_label(unix_time: int) -> String:
	var time := Time.get_time_dict_from_unix_time(unix_time)
	return "%02d:%02d:%02d" % [int(time.get("hour", 0)), int(time.get("minute", 0)), int(time.get("second", 0))]
