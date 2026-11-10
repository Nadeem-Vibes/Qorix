extends TestCase

## ModHost sandbox: environment, sentinel aborts, pcall/xpcall, coroutine denial,
## memory limits, task/handler/timer plumbing and teardown.

const HostScript = preload("res://src/features/mods/mod_host.gd")
const Diagnostics = preload("res://src/features/mods/mod_diagnostics.gd")
const Result = preload("res://src/features/mods/mod_result.gd")


class FakeApi:
	var logs: Array = []
	var subscriptions: Array = []
	var host = null

	func invoke(method: String, args: Variant = null) -> Dictionary:
		var payload: Dictionary = args if args is Dictionary else {}
		match method:
			"log":
				logs.append({
					"level": str(payload.get("level", "info")),
					"message": str(payload.get("message", "")),
				})
				return {"ok": true, "value": true}
			"events.subscribe":
				subscriptions.append(payload.duplicate(true))
				return {"ok": true, "value": subscriptions.size()}
			"events.unsubscribe":
				return {"ok": true, "value": true}
			"events.emit":
				return {"ok": true, "value": true}
			"tasks.schedule":
				if host != null:
					return host.schedule_task(int(payload.get("id", 0)))
				return {"ok": true, "value": int(payload.get("id", 0))}
			"timer.schedule":
				if host != null:
					return host.add_timer(
						int(payload.get("handle", 0)),
						float(payload.get("ms", 0.0)),
						bool(payload.get("repeat", false)),
					)
				return {"ok": true, "value": int(payload.get("handle", 0))}
			"cancel":
				if host != null:
					return host.cancel_handle(int(payload.get("handle", 0)))
				return {"ok": true, "value": false}
			"permissions.has":
				return {"ok": true, "value": false}
		return {"ok": true, "value": null}


func _api() -> FakeApi:
	return FakeApi.new()


func _host(api = null):
	var diagnostics = Diagnostics.new()
	var facade = api if api != null else _api()
	var host = HostScript.new(
		{"id": "griddycode.test", "name": "Test Host", "version": "1.0.0"},
		facade,
		diagnostics,
	)
	facade.host = host
	return host


func _values(result: Dictionary) -> Array:
	if !result.get("ok", false):
		return []
	var payload: Variant = result.get("value")
	if !(payload is Dictionary):
		return []
	var packed: Variant = (payload as Dictionary).get("values")
	if packed is Array:
		return packed
	if packed is Dictionary:
		var keys: Array = (packed as Dictionary).keys()
		keys.sort()
		var out: Array = []
		for key in keys:
			if typeof(key) == TYPE_INT:
				out.append((packed as Dictionary)[key])
		return out
	return []


func _log_text(api: FakeApi) -> String:
	var lines: Array = []
	for entry in api.logs:
		lines.append(str(entry.get("message", "")))
	return "\n".join(lines)


func test_bootstrap() -> void:
	var host = _host()
	var started: Dictionary = host.start()
	check(started.get("ok", false), "host starts: " + str(started.get("error", {})))
	check(host.started, "host reports started")
	check(host.memory_usage() > 0, "lua state allocated")
	host.teardown()
	check(!host.started, "teardown stops the host")


func test_sanitized_environment() -> void:
	var host = _host()
	host.start()

	var result: Dictionary = host.activate("""
return {
	debug_nil = debug == nil,
	coroutine_nil = coroutine == nil,
	io_nil = io == nil,
	os_nil = os == nil,
	package_nil = package == nil,
	dofile_nil = dofile == nil,
	loadfile_nil = loadfile == nil,
	collectgarbage_nil = collectgarbage == nil,
	dump_nil = string.dump == nil,
	editor_present = editor ~= nil,
	host_hidden = _G.__griddy_load_mod == nil and _G.__griddy_resume == nil,
	host_global_hidden = __griddy_load_mod == nil,
}
""", "env.lua")

	check(result.get("ok", false), "environment chunk runs")
	var values := _values(result)
	check(values.size() == 1, "one return value")
	var env: Variant = values[0]
	check(env is Dictionary, "the chunk returned a table")
	if env is Dictionary:
		for key in [
			"debug_nil", "coroutine_nil", "io_nil", "os_nil", "package_nil",
			"dofile_nil", "loadfile_nil", "collectgarbage_nil", "dump_nil",
			"editor_present", "host_hidden", "host_global_hidden",
		]:
			check(bool((env as Dictionary).get(key, false)), "environment: " + key)

	host.teardown()


func test_infinite_loop_is_killed_and_state_reusable() -> void:
	var host = _host()
	host.start()

	var loop: Dictionary = host.activate("while true do end", "loop.lua")
	assert_eq(Result.code_of(loop), "budget.exceeded")
	check(host.started, "state survives a sentinel abort")

	var after: Dictionary = host.activate("return 'alive'", "after.lua")
	check(after.get("ok", false), "state accepts new work")
	assert_eq(_values(after)[0], "alive")

	host.teardown()


func test_pcall_cannot_swallow_the_sentinel() -> void:
	var host = _host()
	host.start()

	var result: Dictionary = host.activate("pcall(function() while true do end end)", "pcall.lua")
	assert_eq(Result.code_of(result), "budget.exceeded")
	check(host.started, "state survives a swallowed pcall attempt")
	host.teardown()


func test_xpcall_handler_cannot_transform_the_sentinel() -> void:
	var host = _host()
	host.start()

	var result: Dictionary = host.activate(
		"xpcall(function() while true do end end, function(e) return 'transformed' end)",
		"xpcall.lua",
	)
	assert_eq(Result.code_of(result), "budget.exceeded")
	host.teardown()


func test_nested_coroutine_is_not_available() -> void:
	var host = _host()
	host.start()

	var result: Dictionary = host.activate("""
local ok, err = pcall(function()
	local co = coroutine.create(function() while true do end end)
	coroutine.resume(co)
end)
return ok, tostring(err)
""", "nested.lua")

	check(result.get("ok", false), "chunk itself completes")
	var values := _values(result)
	check(values.size() >= 2, "two values returned")
	assert_eq(values[0], false)
	check(str(values[1]).contains("nil value"), "coroutine lookup failed: " + str(values[1]))

	host.teardown()


func test_binary_chunks_are_rejected() -> void:
	var host = _host()
	host.start()

	var result: Dictionary = host.activate("""
local fn, err = load("\\27Lua", "bin", "b")
return fn == nil, tostring(err)
""", "binary.lua")

	check(result.get("ok", false), "chunk completes")
	var values := _values(result)
	assert_eq(values[0], true)
	check(str(values[1]).contains("binary"), "binary load rejected")

	host.teardown()


func test_memory_limit() -> void:
	var host = _host()
	host.start()

	var result: Dictionary = host.activate("local s = string.rep('x', 32 * 1024 * 1024)", "memory.lua")
	assert_eq(Result.code_of(result), "memory.exceeded")
	host.teardown()


func test_activation_error() -> void:
	var host = _host()
	host.start()

	var result: Dictionary = host.activate("error('boom from test')", "crash.lua")
	assert_eq(Result.code_of(result), "mod.failed")
	check(Result.message_of(result).contains("boom"), "error message preserved")
	check(host.started, "a normal Lua error keeps the state")

	host.teardown()


func test_event_handler_invocation() -> void:
	var api := _api()
	var host = _host(api)
	host.start()

	var result: Dictionary = host.activate("""
editor.events.on("app.ready", function(payload)
	editor.log.info("event " .. tostring(payload.count))
end)
""", "subscribe.lua")
	check(result.get("ok", false), "subscription chunk runs")
	assert_eq(api.subscriptions.size(), 1)

	var handle := int(api.subscriptions[0].get("handle", 0))
	check(handle > 0, "handler id is an integer")

	var invocation: Dictionary = host.invoke(handle, {"count": 2})
	check(invocation.get("ok", false), "handler invoked")
	check(_log_text(api).contains("event 2"), "handler ran with the payload")

	var missing: Dictionary = host.invoke(9999, {})
	assert_eq(Result.code_of(missing), "command.unknown")

	host.teardown()


func test_timer_and_async_wait() -> void:
	var api := _api()
	var host = _host(api)
	host.start()

	host.activate("""
editor.every(10, function()
	editor.log.info("timer fired")
end)
editor.async(function()
	editor.wait(20)
	editor.log.info("waited")
end)
""", "tasks.lua")

	check(!_log_text(api).contains("waited"), "wait suspends the task")
	host.tick(5.0)
	check(!_log_text(api).contains("timer fired"), "timer not due yet")

	host.tick(20.0)
	check(_log_text(api).contains("timer fired"), "timer fired")
	check(_log_text(api).contains("waited"), "wait resumed")

	host.teardown()


func test_teardown_drops_tasks_and_handlers() -> void:
	var host = _host()
	host.start()
	host.activate("editor.events.on('app.ready', function() end)", "sub.lua")
	check(host.handler_count() > 0, "handler registered")

	host.teardown()
	check(!host.started, "stopped")
	assert_eq(host.task_count(), -1)
	assert_eq(host.memory_usage(), -1)
