extends RefCounted

## E6 — Native callback marshalling.
##
## Checks GDScript -> Lua values, Lua -> GDScript function values, and a
## re-entrant Lua -> native -> Lua call. Callback ids and stale-callback
## teardown are not implemented in this probe; they belong to ModHost.

const Util = preload("res://tools/probes/lua-runtime/probe_util.gd")
const HostScript = preload("res://tools/probes/lua-runtime/probe_lua.gd")
const NativeScript = preload("res://tools/probes/lua-runtime/probe_native.gd")


func run(_ctx: Dictionary) -> Dictionary:
	var checks: Array = []
	var limitations: Array = []
	var host = HostScript.new()
	if !host.is_ready():
		return {
			"probe": "E6",
			"title": "Native callback marshalling",
			"status": "fail",
			"checks": [Util.check("bootstrap", false, host.bootstrap_error)],
			"limitations": [],
		}

	host.set_budget(1000, 1000)
	var native = NativeScript.new()

	host.set_native_probe(Callable(native, "echo_type"))
	var types_result: Dictionary = host.run("""
return editor.test.call_native("hello"),
       editor.test.call_native(42),
       editor.test.call_native(true),
       editor.test.call_native({1, 2, 3})""", "E6:types")
	var types := _values(types_result)
	var types_ok: bool = bool(types_result.get("ok", false)) and types.size() >= 4
	if types_ok:
		types_ok = str(types[1]) == "String" and str(types[2]) == "float" and str(types[3]) == "bool"
	checks.append(Util.check(
		"gd_to_lua_types",
		types_ok,
		"Lua saw: %s" % str(types),
	))

	host.set_native_probe(Callable(native, "echo"))
	var echo_result: Dictionary = host.run("""
local a = editor.test.call_native("round-trip")
local b = editor.test.call_native(3.5)
local c = editor.test.call_native(true)
return a, b, c, a == "round-trip" and b == 3.5 and c == true""", "E6:echo")
	var echo_values := _values(echo_result)
	var echo_ok: bool = bool(echo_result.get("ok", false)) and echo_values.size() >= 4 and echo_values[3] == true
	checks.append(Util.check(
		"lua_native_roundtrip",
		echo_ok,
		"values=%s" % str(echo_values),
	))

	var define_result: Dictionary = host.run(
		"return function(a, b) return a + b end",
		"E6:define",
	)
	var add_callable: Variant = Util.first_value(define_result)
	var add_ok := bool(define_result.get("ok", false)) and add_callable is Callable and (add_callable as Callable).is_valid()
	var add_value: Variant = null
	if add_ok:
		add_value = (add_callable as Callable).call(2, 3)
	checks.append(Util.check(
		"lua_function_to_gd",
		add_ok and int(add_value) == 5,
		"pulled Lua function callable=%s result=%s" % [str(add_callable), str(add_value)],
	))
	limitations.append(
		"A function pulled directly from the state runs on the main Lua thread with no hook. The product API must never hand raw Lua functions to native callers; use integer callback ids and host-created tasks."
	)

	# Re-entrancy: Lua -> GDScript -> the same Lua function.
	var reentrant = NativeScript.new()
	reentrant.saved = add_callable if add_callable is Callable else Callable()
	host.set_native_probe(Callable(reentrant, "invoke"))
	var reentrant_result: Dictionary = host.run(
		"return editor.test.call_native({a = 6, b = 7})",
		"E6:reentrant",
	)
	var reentrant_value: Variant = Util.first_value(reentrant_result)
	checks.append(Util.check(
		"reentrant_call",
		bool(reentrant_result.get("ok", false)) and int(reentrant_value) == 13,
		"re-entrant result=%s err=%s" % [str(reentrant_value), str(reentrant_result.get("err", ""))],
	))

	# The state must still accept a normal chunk after the re-entrant call.
	var after: Dictionary = host.run("return 'alive'", "E6:after")
	checks.append(Util.check(
		"state_usable_after_callback",
		bool(after.get("ok", false)) and str(Util.first_value(after)) == "alive",
		"post-callback value=%s" % str(Util.first_value(after)),
	))

	limitations.append(
		"Stale callback ids after teardown and queued-callback invalidation are not implemented in this probe; they are requirements for ModHost and remain unverified."
	)
	host.teardown()

	return {
		"probe": "E6",
		"title": "Native callback marshalling",
		"status": Util.status(checks, limitations),
		"checks": checks,
		"limitations": limitations,
		"metrics": {
			"lua_add_result": add_value,
			"reentrant_result": reentrant_value,
			"native_calls": native.calls + reentrant.calls,
		},
		"notes": [
			"Lua tables arrive in GDScript as Dictionary/Array; Lua numbers arrive as floats.",
			"Re-entrancy works for a simple arithmetic function but proves nothing about bounded dispatch; ModHost still owns that boundary.",
		],
	}


func _values(result: Dictionary) -> Array:
	var values: Variant = result.get("values", [])
	return values if values is Array else []
