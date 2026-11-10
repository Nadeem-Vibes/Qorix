extends RefCounted

## E3 — Abort matrix.
##
## Runs every loop form named by the architecture plan at the three instruction
## counts from section 14.5, then at the production budget (1,000,000
## instructions). Every case must abort in under 50 ms, and the state must
## accept ordinary work immediately afterwards.

const Util = preload("res://tools/probes/lua-runtime/probe_util.gd")
const HostScript = preload("res://tools/probes/lua-runtime/probe_lua.gd")

const CASES := [
	{
		"name": "while_true",
		"source": "while true do end",
		"expect_timeout": true,
	},
	{
		"name": "numeric_for_math_huge",
		"source": "for i = 1, math.huge do end",
		"expect_timeout": true,
	},
	{
		"name": "generic_for_infinite_iterator",
		"source": "local function iterate() return function() return 1 end end\nfor _ in iterate() do end",
		"expect_timeout": true,
	},
	{
		"name": "repeat_until_false",
		"source": "repeat local x = 1 until false",
		"expect_timeout": true,
	},
	{
		"name": "mutual_recursion",
		"source": "local a, b\na = function() return b() end\nb = function() return a() end\na()",
		"expect_timeout": true,
	},
	{
		"name": "deep_recursion",
		"source": "local function f(n)\n  local x = f(n + 1)\n  return x + 1\nend\nf(1)",
		"expect_timeout": false,
	},
]

const BUDGETS := [
	{"label": "100", "limit": 10, "step": 10},
	{"label": "1000", "limit": 10, "step": 100},
	{"label": "10000", "limit": 10, "step": 1000},
	{"label": "1000000_production", "limit": 1000, "step": 1000},
]
const ABORT_LIMIT_MS := 50.0


func run(_ctx: Dictionary) -> Dictionary:
	var checks: Array = []
	var metrics: Dictionary = {
		"budgets": BUDGETS,
		"abort_limit_ms": ABORT_LIMIT_MS,
	}

	for config in BUDGETS:
		var label := str(config["label"])
		var host = HostScript.new()
		if !host.is_ready():
			checks.append(Util.check("bootstrap_" + label, false, host.bootstrap_error))
			host.teardown()
			continue

		var budget: Dictionary = host.set_budget(int(config["limit"]), int(config["step"]))
		var effective := int(budget.get("instructions", 0))

		for test_case in CASES:
			var result: Dictionary = host.run(str(test_case["source"]), "E3:" + label + ":" + str(test_case["name"]))
			var elapsed := float(result.get("elapsed_ms", 999999.0))
			var timed_out := bool(result.get("timeout", false))
			var aborted := !bool(result.get("ok", true))
			var elapsed_ok := elapsed < ABORT_LIMIT_MS
			var timeout_ok := timed_out if bool(test_case["expect_timeout"]) else true
			var ok := aborted and elapsed_ok and timeout_ok

			checks.append(Util.check(
				"abort_%s_%s" % [label, str(test_case["name"])],
				ok,
				"%s @%d instructions: aborted=%s timeout=%s elapsed=%.3fms err=%s" % [
					str(test_case["name"]), effective, str(aborted), str(timed_out), elapsed,
					str(result.get("err", "")),
				],
				{
					"effective_instructions": effective,
					"elapsed_ms": elapsed,
					"timeout": timed_out,
					"task_dead": bool(result.get("dead", false)),
				},
			))

		# The state must accept ordinary work immediately after the matrix.
		var alive: Dictionary = host.run("return 'alive'", "E3:post_abort")
		var alive_value: Variant = Util.first_value(alive)
		var alive_ok: bool = bool(alive.get("ok", false)) and str(alive_value) == "alive"
		checks.append(Util.check(
			"state_reusable_%s" % label,
			alive_ok,
			"post-abort chunk value=%s err=%s" % [str(alive_value), str(alive.get("err", ""))],
		))
		checks.append(Util.check(
			"no_orphan_tasks_%s" % label,
			host.task_count() == 0,
			"task_count=%d" % host.task_count(),
		))

		host.teardown()

	# Fallback evidence for the Gate A decision: a non-tail recursion that
	# reaches Lua's C stack overflow at the 1M budget still aborts cleanly with
	# the sentinel at 500k, and the state remains usable.
	var fallback_host = HostScript.new()
	if fallback_host.is_ready():
		fallback_host.set_budget(500, 1000)
		var deep_case: Dictionary = CASES[5]
		var deep_result: Dictionary = fallback_host.run(str(deep_case["source"]), "E3:deep_500k")
		var deep_after: Dictionary = fallback_host.run("return 'alive'", "E3:deep_500k_after")
		checks.append(Util.check(
			"deep_recursion_500k_fallback",
			bool(deep_result.get("timeout", false)) and bool(deep_after.get("ok", false)),
			"500k budget: timeout=%s elapsed=%.3fms; post-abort=%s" % [
				str(deep_result.get("timeout", false)), float(deep_result.get("elapsed_ms", 0.0)),
				str(Util.first_value(deep_after)),
			],
			{
				"effective_instructions": 500000,
				"elapsed_ms": float(deep_result.get("elapsed_ms", 0.0)),
			},
		))
		fallback_host.teardown()

	return {
		"probe": "E3",
		"title": "Abort matrix",
		"status": Util.status(checks),
		"checks": checks,
		"metrics": metrics,
		"notes": [
			"The three instruction counts from the plan are enforced with ten hook firings per run; the production row uses 1,000 firings x 1,000 instructions.",
			"Deep recursion aborts through Lua's stack-overflow error rather than the budget sentinel; it counts as an abort when it finishes under the limit and the state remains usable.",
		],
	}
