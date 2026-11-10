extends RefCounted

## Small persisted list of recently opened files for the welcome screen.
## Missing files are hidden (and pruned on the next remember) so a stale
## history cannot send the person to a path that no longer exists.

const Store = preload("res://src/base/file_store.gd")
const Paths = preload("res://src/base/path_utils.gd")

const MAX_RECENT_FILES := 10
const DEFAULT_PATH := "user://welcome.json"

var state_path: String = DEFAULT_PATH

var _state: Dictionary = {
	"version": 1,
	"recent_files": [],
	"welcome_seen": false,
}
var _loaded: bool = false


func load_state() -> Dictionary:
	if _loaded:
		return _state.duplicate(true)

	var result: Dictionary = Store.load_json(state_path)
	if bool(result.get("ok", false)):
		var data: Dictionary = result.get("data", {})
		var recent: Variant = data.get("recent_files", [])
		if recent is Array:
			_state["recent_files"] = _clean_list(recent)
		_state["welcome_seen"] = bool(data.get("welcome_seen", false))
	_loaded = true
	return _state.duplicate(true)


func save_state() -> Dictionary:
	return Store.save_json(state_path, _state)


func remember_file(path: String) -> bool:
	var normalized := Paths.normalize(path)
	if normalized.is_empty():
		return false
	load_state()

	var recent: Array = _clean_list(_state.get("recent_files", []))
	var kept: Array = []
	for entry in recent:
		if !Paths.same_file(str(entry), normalized):
			kept.append(str(entry))
	kept.push_front(normalized)
	while kept.size() > MAX_RECENT_FILES:
		kept.pop_back()
	_state["recent_files"] = kept
	save_state()
	return true


## Most recent first. Missing files are removed from the returned list; the
## persisted list is pruned the next time remember_file() runs.
func recent_files(limit: int = 6) -> Array:
	load_state()
	var out: Array = []
	for entry in _state.get("recent_files", []):
		var path := str(entry)
		if path.is_empty() or !FileAccess.file_exists(path):
			continue
		out.append(path)
		if out.size() >= limit:
			break
	return out


func mark_welcome_seen() -> void:
	load_state()
	if bool(_state.get("welcome_seen", false)):
		return
	_state["welcome_seen"] = true
	save_state()


func welcome_seen() -> bool:
	load_state()
	return bool(_state.get("welcome_seen", false))


func clear() -> void:
	_state = {
		"version": 1,
		"recent_files": [],
		"welcome_seen": false,
	}
	_loaded = true
	save_state()


func _clean_list(raw: Array) -> Array:
	var out: Array = []
	for entry in raw:
		var path := Paths.normalize(str(entry))
		if path.is_empty():
			continue
		var duplicate := false
		for existing in out:
			if Paths.same_file(str(existing), path):
				duplicate = true
				break
		if !duplicate:
			out.append(path)
	return out
