extends Node

## Autoload wrapper around the shared atomic persistence helper. Kept as the
## historical API used by the editor UI; the implementation lives in
## src/base/file_store.gd so headless tests and core services can save
## without booting the autoloads.

const Store = preload("res://src/base/file_store.gd")


## Writes content atomically (temp file + rename) and reports what happened.
## Callers MUST check `ok`; a failed save is never silent.
## Returns {ok: bool, error: String, path: String}.
func save(path: String, content: String) -> Dictionary:
	return Store.save(path, content)


func _load(path: String) -> String:
	return Store.load_text(path)
