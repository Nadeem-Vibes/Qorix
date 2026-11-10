extends RefCounted

## E5 — State lifecycle, memory and leaks.
##
## Creates and drops states with successful and failed activations, runs the
## abort path 1,000 times, and compares static memory / object counts against
## the baseline after forcing a Lua collection.

const Util = preload("res://tools/probes/lua-runtime/probe_util.gd")
const HostScript = preload("res://tools/probes/lua-runtime/probe_lua.gd")

const CREATE_CYCLES := 100
const FAILED_ACTIVATIONS := 100
const ABORT_CYCLES := 1000


func run(_ctx: Dictionary) -> Dictionary:
	var checks: Array = []
	var limitations: Array = []

	var baseline_objects := int(Performance.get_monitor(Performance.OBJECT_COUNT))
	var baseline_memory := OS.get_static_memory_usage()

	var creation_failures := 0
	for _i in CREATE_CYCLES:
		var host = HostScript.new()
		if !host.is_ready():
			creation_failures += 1
		else:
			var result: Dictionary = host.run("return 1")
			if !bool(result.get("ok", false)):
				creation_failures += 1
		host.teardown()

	var failed_activation_failures := 0
	for _i in FAILED_ACTIVATIONS:
		var host = HostScript.new()
		if !host.is_ready():
			failed_activation_failures += 1
		else:
			var loaded: Dictionary = host.load_chunk("this is not valid lua !!!", "E5:invalid")
			if bool(loaded.get("ok", true)):
				failed_activation_failures += 1
		host.teardown()

	var abort_host = HostScript.new()
	var abort_failures := 0
	var orphan_checks := 0
	var abort_started := Time.get_ticks_usec()
	if !abort_host.is_ready():
		abort_failures = ABORT_CYCLES
	else:
		abort_host.set_budget(10, 100)
		for index in ABORT_CYCLES:
			var result: Dictionary = abort_host.run("while true do end", "E5:abort")
			if !bool(result.get("timeout", false)):
				abort_failures += 1
			if index % 100 == 0 and abort_host.task_count() != 0:
				orphan_checks += 1
	var abort_elapsed := (Time.get_ticks_usec() - abort_started) / 1000.0

	if abort_host.is_ready():
		abort_host.collect_garbage()
	if abort_host.is_ready():
		abort_host.teardown()

	# A second collection after teardown; RefCounted teardown is deterministic,
	# but the monitor only settles after the frame-free work above.
	OS.delay_msec(50)
	var after_objects := int(Performance.get_monitor(Performance.OBJECT_COUNT))
	var after_memory := OS.get_static_memory_usage()
	var object_delta := after_objects - baseline_objects
	var memory_delta := after_memory - baseline_memory
	var memory_ratio := float(memory_delta) / float(baseline_memory) if baseline_memory > 0 else 0.0

	checks.append(Util.check(
		"create_drop_100",
		creation_failures == 0,
		"%d/%d state create/run/drop cycles failed" % [creation_failures, CREATE_CYCLES],
	))
	checks.append(Util.check(
		"failed_activation_100",
		failed_activation_failures == 0,
		"%d/%d failed-activation cycles were not rejected" % [failed_activation_failures, FAILED_ACTIVATIONS],
	))
	checks.append(Util.check(
		"abort_1000",
		abort_failures == 0,
		"%d/%d abort cycles failed in %.1fms total" % [abort_failures, ABORT_CYCLES, abort_elapsed],
		{"elapsed_ms": abort_elapsed},
	))
	checks.append(Util.check(
		"no_orphan_tasks",
		orphan_checks == 0,
		"orphan task checks failed %d times" % orphan_checks,
	))
	checks.append(Util.check(
		"memory_recovers_within_5pct",
		baseline_memory <= 0 or absf(memory_ratio) <= 0.05,
		"static memory %d -> %d (%+.2f%%), objects %d -> %d (%+d)" % [
			baseline_memory, after_memory, memory_ratio * 100.0, baseline_objects, after_objects, object_delta,
		],
		{
			"baseline_memory": baseline_memory,
			"after_memory": after_memory,
			"memory_ratio": memory_ratio,
			"baseline_objects": baseline_objects,
			"after_objects": after_objects,
			"object_delta": object_delta,
		},
	))

	if baseline_memory <= 0:
		limitations.append("OS.get_static_memory_usage() reported 0 in this host, so the 5% memory criterion could not be evaluated.")

	return {
		"probe": "E5",
		"title": "State lifecycle, memory and leaks",
		"status": Util.status(checks, limitations),
		"checks": checks,
		"limitations": limitations,
		"metrics": {
			"cycles": {
				"create_drop": CREATE_CYCLES,
				"failed_activation": FAILED_ACTIVATIONS,
				"aborts": ABORT_CYCLES,
			},
			"abort_total_ms": abort_elapsed,
			"baseline_memory": baseline_memory,
			"after_memory": after_memory,
			"memory_delta": memory_delta,
			"memory_ratio": memory_ratio,
			"baseline_objects": baseline_objects,
			"after_objects": after_objects,
			"object_delta": object_delta,
		},
		"notes": [
			"RSS is not portable from GDScript; this probe uses OS.get_static_memory_usage() and Performance.OBJECT_COUNT.",
			"The 1,000 abort cycles use a 1,000-instruction budget, not the production budget.",
		],
	}
