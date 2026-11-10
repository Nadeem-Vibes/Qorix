extends RefCounted

## E4 — Escape hatches.
##
## Attacks the sanitized environment and the protected error boundary:
## swallowed sentinel, transforming xpcall handler, nested coroutine, binary
## load, memory pressure, a long C call, and a native callback that sleeps.

const Util = preload("res://tools/probes/lua-runtime/probe_util.gd")
const HostScript = preload("res://tools/probes/lua-runtime/probe_lua.gd")
const NativeScript = preload("res://tools/probes/lua-runtime/probe_native.gd")


func run(_ctx: Dictionary) -> Dictionary:
	var checks: Array = []
	var limitations: Array = []
	var host = HostScript.new()
	if !host.is_ready():
		return {
			"probe": "E4",
			"title": "Escape hatches",
			"status": "fail",
			"checks": [Util.check("bootstrap", false, host.bootstrap_error)],
			"limitations": [],
		}

	host.set_budget(1000, 1000)

	var env_result: Dictionary = host.run("""
return {
	debug_nil = debug == nil,
	coroutine_nil = coroutine == nil,
	io_nil = io == nil,
	os_nil = os == nil,
	package_nil = package == nil,
	dofile_nil = dofile == nil,
	loadfile_nil = loadfile == nil,
	collectgarbage_nil = collectgarbage == nil,
	string_dump_nil = string.dump == nil,
	editor_present = editor ~= nil,
	host_functions_hidden = _G.__griddy_load_mod == nil and _G.__griddy_resume == nil,
}""", "E4:env")
	var env: Variant = Util.first_value(env_result)
	var env_ok := env is Dictionary
	var missing: Array = []
	if env_ok:
		for key in [
			"debug_nil", "coroutine_nil", "io_nil", "os_nil", "package_nil", "dofile_nil",
			"loadfile_nil", "collectgarbage_nil", "string_dump_nil", "editor_present",
			"host_functions_hidden",
		]:
			if !bool((env as Dictionary).get(key, false)):
				missing.append(key)
	else:
		missing.append("chunk did not return a table")
	checks.append(Util.check(
		"sanitized_environment",
		missing.is_empty(),
		"missing/false: %s" % ", ".join(missing),
		{"environment": env if env is Dictionary else {}},
	))

	var pcall_result: Dictionary = host.run("pcall(function() while true do end end)", "E4:pcall")
	checks.append(Util.check(
		"pcall_rethrows_sentinel",
		bool(pcall_result.get("timeout", false)) and bool(pcall_result.get("dead", false)),
		"timeout=%s dead=%s err=%s" % [
			str(pcall_result.get("timeout", false)), str(pcall_result.get("dead", false)),
			str(pcall_result.get("err", "")),
		],
		{"elapsed_ms": float(pcall_result.get("elapsed_ms", 0.0))},
	))

	var xpcall_result: Dictionary = host.run(
		"xpcall(function() while true do end end, function(e) return 'transformed' end)",
		"E4:xpcall",
	)
	checks.append(Util.check(
		"xpcall_rethrows_sentinel",
		bool(xpcall_result.get("timeout", false)) and bool(xpcall_result.get("dead", false)),
		"timeout=%s dead=%s err=%s" % [
			str(xpcall_result.get("timeout", false)), str(xpcall_result.get("dead", false)),
			str(xpcall_result.get("err", "")),
		],
	))

	var nested_result: Dictionary = host.run("""
local ok, err = pcall(function()
	local co = coroutine.create(function() while true do end end)
	coroutine.resume(co)
end)
return ok, tostring(err)""", "E4:nested_coroutine")
	var nested_values := _values(nested_result)
	var nested_blocked: bool = bool(nested_result.get("ok", false)) and nested_values.size() >= 3 and nested_values[1] == false
	checks.append(Util.check(
		"nested_coroutine_blocked",
		nested_blocked and !bool(nested_result.get("timeout", false)),
		"chunk_ok=%s values=%s timeout=%s elapsed=%.3fms" % [
			str(nested_result.get("ok", false)), str(nested_values), str(nested_result.get("timeout", false)),
			float(nested_result.get("elapsed_ms", 0.0)),
		],
	))

	var binary_result: Dictionary = host.run("""
local fn, err = load("\\27Lua", "bin", "b")
return fn == nil, tostring(err)""", "E4:binary_load")
	var binary_values := _values(binary_result)
	var binary_rejected: bool = bool(binary_result.get("ok", false)) and binary_values.size() >= 3 and binary_values[1] == true and str(binary_values[2]).contains("binary")
	checks.append(Util.check(
		"binary_load_rejected",
		binary_rejected,
		"values=%s" % str(binary_values),
	))

	var memory_result: Dictionary = host.run("""
local ok, err = pcall(function()
	local s = string.rep("x", 64 * 1024 * 1024)
	return #s
end)
return ok, tostring(err)""", "E4:memory_pressure")
	var memory_values := _values(memory_result)
	var memory_bounded: bool = bool(memory_result.get("ok", false)) and memory_values.size() >= 3 and memory_values[1] == false and float(memory_result.get("elapsed_ms", 999999.0)) < 500.0
	checks.append(Util.check(
		"memory_pressure_bounded",
		memory_bounded,
		"values=%s elapsed=%.3fms" % [str(memory_values), float(memory_result.get("elapsed_ms", 0.0))],
	))

	var gsub_result: Dictionary = host.run("""
local s = string.rep("a", 1024 * 1024) .. "b"
local ok, err = pcall(function() return string.gsub(s, "a*b", "") end)
return ok, tostring(err)""", "E4:c_call")
	checks.append(Util.check(
		"long_c_call_bounded",
		bool(gsub_result.get("ok", false)) and float(gsub_result.get("elapsed_ms", 999999.0)) < 500.0,
		"elapsed=%.3fms values=%s" % [float(gsub_result.get("elapsed_ms", 0.0)), str(_values(gsub_result))],
		{"elapsed_ms": float(gsub_result.get("elapsed_ms", 0.0))},
	))

	var native = NativeScript.new()
	host.set_native_probe(Callable(native, "sleep_ms"))
	var native_result: Dictionary = host.run("return editor.test.call_native(120)", "E4:native_sleep")
	var native_elapsed := float(native_result.get("elapsed_ms", 0.0))
	var native_blocked := native_elapsed >= 100.0 and int(Util.first_value(native_result)) == 120
	checks.append(Util.check(
		"native_callback_blocking_measured",
		native_blocked,
		"native sleep(120ms) blocked dispatch for %.3fms" % native_elapsed,
		{"elapsed_ms": native_elapsed},
	))
	limitations.append(
		"Native callbacks are synchronous on the host thread: a 120 ms GDScript callback blocked the call path for ~120 ms. " +
		"The API must call only bounded host callables; this is a documented residual limitation, not a hard sandbox guarantee."
	)

	host.teardown()

	return {
		"probe": "E4",
		"title": "Escape hatches",
		"status": Util.status(checks, limitations),
		"checks": checks,
		"limitations": limitations,
		"metrics": {
			"pcall_elapsed_ms": float(pcall_result.get("elapsed_ms", 0.0)),
			"xpcall_elapsed_ms": float(xpcall_result.get("elapsed_ms", 0.0)),
			"gsub_elapsed_ms": float(gsub_result.get("elapsed_ms", 0.0)),
			"native_sleep_elapsed_ms": native_elapsed,
		},
		"notes": [
			"The nested coroutine is blocked because the library is absent; it is a load/name error, not an unhooked thread.",
			"The 64 MB string allocation is rejected under the 24 MB state limit.",
			"Long C calls are bounded by input size and memory, not by the instruction hook.",
		],
	}


func _values(result: Dictionary) -> Array:
	var values: Variant = result.get("values", [])
	return values if values is Array else []
