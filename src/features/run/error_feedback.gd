extends RefCounted

## Local, private record of "Was this helpful?" votes on the friendly error
## cards shown by the Run panel.
##
## Votes are stored only on this computer, in `user://error_feedback.json`, so
## the design team can learn which explanations confuse people without ever
## sending keystrokes or source code off the device. Nothing is uploaded by
## this class.
##
## The document is one small JSON object (FileStore requires a dictionary):
## an append-only `entries` list capped at MAX_ENTRIES, oldest first.
## Identical consecutive votes for the same card are collapsed so a
## double-click cannot fill the file.

const Store = preload("res://src/base/file_store.gd")

const DEFAULT_PATH := "user://error_feedback.json"
const MAX_ENTRIES := 200
const VALID_RATINGS := ["up", "down"]

var state_path: String = DEFAULT_PATH

## Unix seconds. 0 means read the system clock; tests freeze it.
var now_override: int = 0


func record(rule_id: String, rating: String, language: String = "") -> Dictionary:
	var id := rule_id.strip_edges()
	if id.is_empty():
		return _failure("An error card needs an id before it can be rated.")
	if !VALID_RATINGS.has(rating):
		return _failure("Rating must be \"up\" or \"down\".")

	var entries := _load_entries()

	var entry := {
		"id": id,
		"rating": rating,
		"language": language.strip_edges().to_lower(),
		"time": _now_seconds(),
	}

	var last: Variant = entries.back() if !entries.is_empty() else null
	if last is Dictionary and str(last.get("id", "")) == id and str(last.get("rating", "")) == rating:
		# Collapse accidental double taps; refresh the timestamp instead.
		entries.pop_back()

	entries.append(entry)
	while entries.size() > MAX_ENTRIES:
		entries.pop_front()

	var saved: Dictionary = Store.save_json(state_path, {"version": 1, "entries": entries})
	if !bool(saved.get("ok", false)):
		return _failure(str(saved.get("error", "Feedback could not be saved.")))

	return {"ok": true, "error": "", "count": entries.size()}


## How many votes have been recorded, and the split per card. Used by the
## headless suite; nothing in the UI requires it.
func summary() -> Dictionary:
	var entries := _load_entries()
	var up := 0
	var down := 0
	var by_card := {}
	for raw in entries:
		if !(raw is Dictionary):
			continue
		var id := str(raw.get("id", ""))
		var rating := str(raw.get("rating", ""))
		if rating == "up":
			up += 1
		elif rating == "down":
			down += 1
		else:
			continue
		if !id.is_empty():
			var bucket: Dictionary = by_card.get(id, {"up": 0, "down": 0})
			bucket[rating] = int(bucket.get(rating, 0)) + 1
			by_card[id] = bucket

	return {"ok": true, "total": up + down, "up": up, "down": down, "by_card": by_card}


func clear() -> Dictionary:
	return Store.save_json(state_path, {"version": 1, "entries": []})


func _load_entries() -> Array:
	var result: Dictionary = Store.load_json(state_path)
	if !bool(result.get("ok", false)):
		return []
	var data: Variant = result.get("data", {})
	if !(data is Dictionary):
		return []
	var entries: Variant = data.get("entries", [])
	if !(entries is Array):
		return []
	return (entries as Array).duplicate(true)


func _now_seconds() -> int:
	if now_override != 0:
		return now_override
	return int(Time.get_unix_time_from_system())


func _failure(message: String) -> Dictionary:
	return {"ok": false, "error": message, "count": 0}
