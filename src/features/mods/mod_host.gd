extends RefCounted

## One Lua state per mod: bootstrap, sandbox, tasks, budgets and teardown.
##
## The state is created from src/features/mods/sdk/sandbox.lua, which captures the trusted
## libraries, builds the mod environment and exposes only `__griddy_*` functions
## to GDScript. Mods run in host-created coroutines with a count hook; a private
## sentinel kills a runaway task without corrupting the VM.
##
## Budget policy (Phase 0 finding F1): the instruction budget is 250 hook firings
## x 1,000 instructions = 250,000 instructions per resume. A soft wall-clock
## overrun lowers the budget; a hard overrun is logged but cannot abort a C call
## that is already inside the VM, so it degrades instead of destroying a state
## that may simply have written a slow file.

const Result = preload("res://src/features/mods/mod_result.gd")

const DEFAULT_SANDBOX := "res://src/features/mods/sdk/sandbox.lua"
const DEFAULT_MEMORY_LIMIT := 24 * 1024 * 1024
const DEFAULT_INSTRUCTION_LIMIT := 250
const DEFAULT_INSTRUCTION_STEP := 1000
const MIN_INSTRUCTION_LIMIT := 25
const SOFT_BUDGET_USEC := 8000
const HARD_BUDGET_USEC := 25000
const MAX_SOURCE_BYTES := 2 * 1024 * 1024
const MAX_TIMERS := 256
const MAX_PENDING_TASKS := 64
const MAX_SCHEDULED_PER_TICK := 8
const MAX_TIMERS_PER_TICK := 32

## {id, name, version}
var mod: Dictionary = {}

## ApiV1 facade, assigned before start().
var api = null
var diagnostics = null

var lua: LuaAPI = null
var sandbox_path := DEFAULT_SANDBOX
var memory_limit := DEFAULT_MEMORY_LIMIT
var instruction_limit := DEFAULT_INSTRUCTION_LIMIT
var instruction_step := DEFAULT_INSTRUCTION_STEP

var started := false
var state_error: String = ""
var last_error: String = ""

var _load_mod: Variant = null
var _resume: Variant = null
var _invoke: Variant = null
var _call_global: Variant = null
var _cancel_task: Variant = null
var _set_budget: Variant = null
var _task_count: Variant = null
var _handler_count: Variant = null
var _collect: Variant = null
var _shutdown: Variant = null

var _budget_limit: int = DEFAULT_INSTRUCTION_LIMIT
var _waiting: Dictionary = {}
var _timers: Dictionary = {}
var _scheduled: Array = []
var _now_ms: float = 0.0
var _running: bool = false
var _tasks_run: int = 0
var _budget_exceeded: int = 0
var _hard_overruns: int = 0
var _memory_errors: Array = []


func _init(mod_info: Dictionary, api_facade = null, diagnostics_service = null) -> void:
	mod = mod_info.duplicate(true)
	api = api_facade
	diagnostics = diagnostics_service


func mod_id() -> String:
	return str(mod.get("id", ""))


func start() -> Dictionary:
	if started:
		return Result.ok()

	state_error = ""
	last_error = ""

	if !FileAccess.file_exists(sandbox_path):
		last_error = "The sandbox bootstrap is missing: " + sandbox_path
		return Result.error("host.not_started", last_error)

	var source := FileAccess.get_file_as_string(sandbox_path)
	if source.is_empty():
		last_error = "The sandbox bootstrap is empty: " + sandbox_path
		return Result.error("host.not_started", last_error)

	lua = LuaAPI.new()
	lua.set_memory_limit(memory_limit)
	lua.bind_libraries(["base", "table", "string", "math", "utf8", "coroutine", "debug"])
	lua.push_variant("__griddy_config", {
		"api_version": 1,
		"mod": {
			"id": str(mod.get("id", "")),
			"name": str(mod.get("name", "")),
			"version": str(mod.get("version", "")),
		},
		"instruction_limit": instruction_limit,
		"instruction_step": instruction_step,
		"max_source_bytes": MAX_SOURCE_BYTES,
	})
	lua.push_variant("__griddy_native", Callable(self, "_native"))

	var error: Variant = lua.do_string(source)
	if error is LuaError:
		last_error = "The sandbox bootstrap failed (%d): %s" % [error.type, error.message]
		_release()
		return Result.error("host.not_started", last_error)

	_load_mod = lua.pull_variant("__griddy_load_mod")
	_resume = lua.pull_variant("__griddy_resume")
	_invoke = lua.pull_variant("__griddy_invoke")
	_call_global = lua.pull_variant("__griddy_call_global")
	_cancel_task = lua.pull_variant("__griddy_cancel")
	_set_budget = lua.pull_variant("__griddy_set_budget")
	_task_count = lua.pull_variant("__griddy_task_count")
	_handler_count = lua.pull_variant("__griddy_handler_count")
	_collect = lua.pull_variant("__griddy_collect")
	_shutdown = lua.pull_variant("__griddy_shutdown")

	if !_is_callable(_load_mod) or !_is_callable(_resume):
		last_error = "The sandbox bootstrap did not expose the host boundary."
		_release()
		return Result.error("host.not_started", last_error)

	started = true
	_budget_limit = instruction_limit
	_apply_budget()
	return Result.ok()


## Loads and runs the entry chunk. Activation is the chunk's top level; an
## optional global `deactivate()` is called on teardown.
func activate(source: String, name: String = "main.lua") -> Dictionary:
	if !started:
		return Result.error("host.not_started", "The mod host is not running.")
	if source.length() > MAX_SOURCE_BYTES:
		return Result.error("mod.failed", "The entry file is larger than the source limit.")

	var loaded: Variant = _call(_load_mod, [source, name])
	if !(loaded is Dictionary):
		return Result.error("host.fatal", "The host returned no load result.")

	var load_result: Dictionary = loaded
	if !bool(load_result.get("ok", false)):
		return Result.error("mod.failed", str(load_result.get("err", "Could not compile the entry file.")))

	return resume_task(int(load_result.get("task", 0)))


## Runs every chunk given to the state. Used by tests and by module loads that
## need a task of their own.
func run_source(source: String, name: String = "@chunk") -> Dictionary:
	return activate(source, name)


func resume_task(task_id: int) -> Dictionary:
	if !started:
		return Result.error("host.not_started", "The mod host is not running.")
	if _running:
		return Result.error("host.reentrant", "A task cannot resume another task.")

	_running = true
	var started_usec := Time.get_ticks_usec()
	var raw: Variant = _call(_resume, [task_id])
	var elapsed_usec := Time.get_ticks_usec() - started_usec
	_running = false
	_tasks_run += 1

	return _map_resume(task_id, raw, elapsed_usec)


## Invokes a stored handler (event, command or timer) as a fresh hooked task.
func invoke(handle: int, payload: Dictionary = {}) -> Dictionary:
	if !started:
		return Result.error("host.not_started", "The mod host is not running.")
	if int(handle) <= 0:
		return Result.error("api.bad_args", "A handler id must be positive.")

	var made: Variant = _call(_invoke, [int(handle), payload])
	if !(made is Dictionary):
		return Result.error("host.fatal", "The host returned no handler result.")

	var invocation: Dictionary = made
	if !bool(invocation.get("ok", false)):
		if bool(invocation.get("missing", false)):
			return Result.error("command.unknown", "The handler no longer exists.")
		return Result.error("mod.failed", str(invocation.get("err", "The handler failed.")))

	return resume_task(int(invocation.get("task", 0)))


## Calls a global function defined in the mod environment, if present.
func call_global(name: String) -> Dictionary:
	if !started:
		return Result.error("host.not_started", "The mod host is not running.")

	var made: Variant = _call(_call_global, [str(name)])
	if !(made is Dictionary):
		return Result.error("host.fatal", "The host returned no global-call result.")

	var invocation: Dictionary = made
	if !bool(invocation.get("ok", false)):
		return Result.error("mod.failed", str(invocation.get("err", "The global call failed.")))
	if bool(invocation.get("missing", false)):
		return Result.ok({"missing": true})

	return resume_task(int(invocation.get("task", 0)))


# ── TASKS AND TIMERS ────────────────────────────────────────────────────────

func schedule_task(task_id: int) -> Dictionary:
	if int(task_id) <= 0:
		return Result.error("api.bad_args", "A task id must be positive.")
	if _scheduled.size() >= MAX_PENDING_TASKS:
		return Result.error("budget.exceeded", "Too many scheduled tasks are pending.")
	if !_scheduled.has(int(task_id)):
		_scheduled.append(int(task_id))
	return Result.ok(int(task_id))


func add_timer(handle: int, milliseconds: float, repeat: bool) -> Dictionary:
	if int(handle) <= 0:
		return Result.error("timer.invalid", "A timer needs a positive handler id.")
	if milliseconds <= 0.0 or milliseconds > 3600000.0:
		return Result.error("timer.invalid", "Timer delays are 1-3,600,000 ms.")
	if _timers.size() >= MAX_TIMERS:
		return Result.error("timer.invalid", "A mod may keep at most %d timers." % MAX_TIMERS)

	_timers[int(handle)] = {
		"at_ms": _now_ms + milliseconds,
		"every_ms": milliseconds,
		"repeat": bool(repeat),
	}
	return Result.ok(int(handle))


func cancel_handle(handle: int) -> Dictionary:
	var id := int(handle)
	if id <= 0:
		return Result.error("api.bad_args", "A handle id must be positive.")

	var removed := false
	if _timers.erase(id):
		removed = true
	if _waiting.erase(id):
		removed = true
	var index := _scheduled.find(id)
	if index != -1:
		_scheduled.remove_at(index)
		removed = true

	if _is_callable(_cancel_task):
		var cancelled: Variant = _cancel_task.call(id)
		if cancelled is bool and cancelled:
			removed = true

	return Result.ok(removed)


func tick(delta_ms: float) -> void:
	if !started:
		return

	_now_ms += maxf(0.0, float(delta_ms))

	var spawned := 0
	while !_scheduled.is_empty() and spawned < MAX_SCHEDULED_PER_TICK:
		spawned += 1
		resume_task(int(_scheduled.pop_front()))
		if !started:
			return

	var due_tasks: Array = []
	for task_id in _waiting.keys():
		if float(_waiting[task_id]) <= _now_ms:
			due_tasks.append(task_id)
	due_tasks.sort()
	for task_id in due_tasks:
		_waiting.erase(task_id)
		resume_task(int(task_id))
		if !started:
			return

	var firing: Array = []
	for handle in _timers.keys():
		if float((_timers[handle] as Dictionary).get("at_ms", 0.0)) <= _now_ms:
			firing.append(handle)
	firing.sort()

	var fired := 0
	for handle in firing:
		if fired >= MAX_TIMERS_PER_TICK:
			break
		fired += 1

		var timer: Dictionary = _timers[int(handle)]
		if bool(timer.get("repeat", false)):
			timer["at_ms"] = _now_ms + float(timer.get("every_ms", 1.0))
		else:
			_timers.erase(int(handle))

		invoke(int(handle), {"timer": int(handle)})
		if !started:
			return


# ── BUDGETS ─────────────────────────────────────────────────────────────────

func set_budget(limit: int, step: int = 0) -> void:
	_budget_limit = maxi(MIN_INSTRUCTION_LIMIT, int(limit))
	if int(step) > 0:
		instruction_step = maxi(1, int(step))
	_apply_budget()


func budget() -> Dictionary:
	return {
		"limit": _budget_limit,
		"step": instruction_step,
		"instructions": _budget_limit * instruction_step,
		"budget_exceeded": _budget_exceeded,
		"hard_overruns": _hard_overruns,
		"tasks_run": _tasks_run,
	}


func _apply_budget() -> void:
	if _is_callable(_set_budget):
		_set_budget.call(_budget_limit, instruction_step)


func _degrade_budget() -> void:
	var next := maxi(MIN_INSTRUCTION_LIMIT, _budget_limit / 2)
	if next == _budget_limit:
		return
	_budget_limit = next
	_apply_budget()
	_note("warning", "The instruction budget was lowered to %d instructions after a slow task." % (_budget_limit * instruction_step))


# ── RESULTS ─────────────────────────────────────────────────────────────────

func _map_resume(task_id: int, raw: Variant, elapsed_usec: int) -> Dictionary:
	if !(raw is Dictionary):
		state_error = "The Lua host returned no task result."
		_note("error", state_error)
		_drop_state()
		return Result.error("host.fatal", state_error)

	var result: Dictionary = raw

	if bool(result.get("waiting", false)):
		_waiting[int(task_id)] = _now_ms + maxf(0.0, float(result.get("wait_ms", 0.0)))
		return Result.ok({"waiting": true})

	if bool(result.get("timeout", false)):
		_budget_exceeded += 1
		_note("error", "The task used more than %d instructions and was stopped." % (_budget_limit * instruction_step))
		_degrade_budget()
		return Result.error(
			"budget.exceeded",
			"The task used more than %d instructions and was stopped." % (_budget_limit * instruction_step),
		)

	if !bool(result.get("ok", true)):
		var message := str(result.get("err", "Lua error"))

		if _is_memory_error(message):
			_note_memory_error(message)
			return Result.error("memory.exceeded", message)

		if _is_fatal(message):
			state_error = message
			_note("error", "Fatal Lua VM error: " + message)
			_drop_state()
			return Result.error("host.fatal", message)

		_note("error", message)
		return Result.error("mod.failed", message)

	if elapsed_usec > HARD_BUDGET_USEC:
		_hard_overruns += 1
		_note("warning", "A task blocked the host for %.1f ms." % (float(elapsed_usec) / 1000.0))
		_degrade_budget()
	elif elapsed_usec > SOFT_BUDGET_USEC:
		_degrade_budget()

	return Result.ok({
		"dead": bool(result.get("dead", false)),
		"values": result.get("values"),
	})


func _is_memory_error(message: String) -> bool:
	var lowered := message.to_lower()
	for marker in ["not enough memory", "memory allocation", "lua_errmem", "memory limit"]:
		if lowered.contains(marker):
			return true
	return false


func _is_fatal(message: String) -> bool:
	var lowered := message.to_lower()
	for marker in ["[wrapped", "stack overflow", "c stack overflow", "error in error handling", "cannot recover"]:
		if lowered.contains(marker):
			return true
	return false


func _note_memory_error(message: String) -> void:
	_memory_errors.append(int(Time.get_ticks_msec()))
	while _memory_errors.size() > 8:
		_memory_errors.pop_front()
	_note("error", "Memory limit reached: " + message)


## True when three memory errors happened inside 30 seconds; the manager uses
## this to disable a mod that keeps allocating to the cap.
func memory_error_storm() -> bool:
	var cutoff := int(Time.get_ticks_msec()) - 30000
	var recent := 0
	for at in _memory_errors:
		if int(at) >= cutoff:
			recent += 1
	return recent >= 3


# ── LIFECYCLE ───────────────────────────────────────────────────────────────

func teardown() -> void:
	if _is_callable(_shutdown) and started:
		_shutdown.call()
	_release()
	started = false


func _drop_state() -> void:
	_release()
	started = false


func _release() -> void:
	_load_mod = null
	_resume = null
	_invoke = null
	_call_global = null
	_cancel_task = null
	_set_budget = null
	_task_count = null
	_handler_count = null
	_collect = null
	_shutdown = null
	_waiting.clear()
	_timers.clear()
	_scheduled.clear()
	lua = null


# ── INTROSPECTION ───────────────────────────────────────────────────────────

func memory_usage() -> int:
	if lua == null:
		return -1
	return int(lua.get_memory_usage())


func collect_garbage() -> float:
	if !_is_callable(_collect):
		return -1.0
	return float(_collect.call())


func task_count() -> int:
	if !_is_callable(_task_count):
		return -1
	return int(_task_count.call())


func handler_count() -> int:
	if !_is_callable(_handler_count):
		return -1
	return int(_handler_count.call())


func waiting_count() -> int:
	return _waiting.size()


func timer_count() -> int:
	return _timers.size()


func status() -> Dictionary:
	return {
		"id": mod_id(),
		"started": started,
		"state_error": state_error,
		"last_error": last_error,
		"memory_usage": memory_usage(),
		"memory_limit": memory_limit,
		"tasks": task_count(),
		"waiting": waiting_count(),
		"timers": timer_count(),
		"handlers": handler_count(),
		"budget": budget(),
	}


# ── INTERNALS ───────────────────────────────────────────────────────────────

func _native(method: Variant, args: Variant) -> Dictionary:
	if api == null:
		return Result.error("host.not_started", "The API facade is not attached.")
	var result: Variant = api.invoke(str(method), args)
	if !(result is Dictionary):
		return Result.error("host.fatal", "The API facade returned an invalid result.")
	return result


func _call(function_value: Variant, args: Array) -> Variant:
	if !_is_callable(function_value):
		return null
	var callable: Callable = function_value
	return callable.callv(args)


static func _is_callable(value: Variant) -> bool:
	return value is Callable and (value as Callable).is_valid()


func _note(level: String, message: String) -> void:
	last_error = message if level == "error" else last_error
	if diagnostics != null:
		diagnostics.log(mod_id(), level, message)
