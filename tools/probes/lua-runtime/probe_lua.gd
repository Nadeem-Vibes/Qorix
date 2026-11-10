extends RefCounted

## Host wrapper around the shipped LuaAPI for the Phase 0 sandbox probes.
##
## The production ModHost does not exist yet. This wrapper exists so E2-E6 can
## run the exact bootstrap and addon binaries the editor ships, without adding
## surface to the editor.

const BOOTSTRAP_PATH := "res://tools/probes/lua-runtime/lua/bootstrap.lua"

var lua: LuaAPI = null
var memory_limit: int = 24 * 1024 * 1024
var bootstrap_error: String = ""
var native_probe: Variant = null

var _load_mod: Variant = null
var _resume: Variant = null
var _set_budget: Variant = null
var _task_count: Variant = null
var _status: Variant = null
var _drain_log: Variant = null
var _collect: Variant = null


func _init(limit_bytes: int = 24 * 1024 * 1024) -> void:
	memory_limit = limit_bytes
	lua = LuaAPI.new()
	lua.set_memory_limit(memory_limit)
	lua.bind_libraries(["base", "table", "string", "math", "utf8", "coroutine", "debug"])

	if native_probe != null:
		lua.push_variant("__probe_native", native_probe)

	var source := FileAccess.get_file_as_string(BOOTSTRAP_PATH)
	if source.is_empty():
		bootstrap_error = "bootstrap source is empty or unreadable: " + BOOTSTRAP_PATH
		return

	var err: Variant = lua.do_string(source)
	if err is LuaError:
		bootstrap_error = "bootstrap failed (%d): %s" % [err.type, err.message]
		return

	_load_mod = lua.pull_variant("__griddy_load_mod")
	_resume = lua.pull_variant("__griddy_resume")
	_set_budget = lua.pull_variant("__griddy_set_budget")
	_task_count = lua.pull_variant("__griddy_task_count")
	_status = lua.pull_variant("__griddy_status")
	_drain_log = lua.pull_variant("__griddy_drain_log")
	_collect = lua.pull_variant("__griddy_collect")


func is_ready() -> bool:
	return bootstrap_error.is_empty() and _load_mod is Callable and (_load_mod as Callable).is_valid() and _resume is Callable and (_resume as Callable).is_valid()


func set_native_probe(callback: Callable) -> bool:
	if lua == null:
		return false

	native_probe = callback
	lua.push_variant("__probe_native", callback)
	return true


## Sets the hook budget. `limit` is the number of hook firings, `step` the
## instructions between firings; effective instructions = limit * step.
func set_budget(limit: int, step: int = 1000) -> Dictionary:
	if !is_ready():
		return {}
	var result: Variant = _set_budget.call(limit, step)
	return result if result is Dictionary else {}


func load_chunk(source: String, name: String = "@probe") -> Dictionary:
	if !is_ready():
		return {"ok": false, "err": bootstrap_error}
	var result: Variant = _load_mod.call(source, name)
	return result if result is Dictionary else {"ok": false, "err": str(result)}


## Runs a chunk to completion and reports whether it was killed by the budget.
func run(source: String, name: String = "@probe") -> Dictionary:
	var task := load_chunk(source, name)
	if !bool(task.get("ok", false)):
		return {"ok": false, "err": str(task.get("err", "load failed")), "elapsed_ms": 0.0}

	var task_id: Variant = task.get("task")
	var started := Time.get_ticks_usec()
	var result: Variant = _resume.call(task_id)
	var elapsed_ms := (Time.get_ticks_usec() - started) / 1000.0

	if !(result is Dictionary):
		return {"ok": false, "err": str(result), "elapsed_ms": elapsed_ms}

	var out: Dictionary = (result as Dictionary).duplicate(true)
	out["elapsed_ms"] = elapsed_ms
	out["task_id"] = task_id
	return out


## Loads a chunk and returns its task id without running it.
func load_task(source: String, name: String = "@probe") -> Dictionary:
	return load_chunk(source, name)


func resume_task(task_id: Variant) -> Dictionary:
	if !is_ready():
		return {"ok": false, "err": bootstrap_error}

	var started := Time.get_ticks_usec()
	var result: Variant = _resume.call(task_id)
	var elapsed_ms := (Time.get_ticks_usec() - started) / 1000.0

	if !(result is Dictionary):
		return {"ok": false, "err": str(result), "elapsed_ms": elapsed_ms}

	var out: Dictionary = (result as Dictionary).duplicate(true)
	out["elapsed_ms"] = elapsed_ms
	return out


func task_count() -> int:
	if !is_ready():
		return -1
	var value: Variant = _task_count.call()
	if value is int or value is float:
		return int(value)
	return -1


func task_status(task_id: Variant) -> String:
	if !is_ready():
		return "missing"
	return str(_status.call(task_id))


func pull(name: String) -> Variant:
	if lua == null:
		return null
	return lua.pull_variant(name)


func collect_garbage() -> float:
	if !is_ready() or _collect == null or !(_collect is Callable):
		return -1.0
	return float(_collect.call())


func drain_log() -> Array:
	if !is_ready():
		return []
	var result: Variant = _drain_log.call()
	if result is Dictionary:
		var lines: Array = []
		for index in range(1, int(result.get("n", 0)) + 1):
			lines.append(str(result.get(index, "")))
		return lines
	return []


func memory_usage() -> int:
	if lua == null:
		return -1
	return int(lua.get_memory_usage())


func teardown() -> void:
	_load_mod = null
	_resume = null
	_set_budget = null
	_task_count = null
	_status = null
	_drain_log = null
	_collect = null
	lua = null
