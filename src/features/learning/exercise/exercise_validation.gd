extends RefCounted

## Shared validation runner for guide and exercise sessions.
##
## Text checks are synchronous. Run-based checks start one RunService run and
## resolve from its `run_finished` signal, so no Lua call ever blocks on a
## process. The runner is engine-agnostic: the host injects the run bridge, the
## stop bridge and the clock, which keeps the whole matrix testable headlessly.

const Result = preload("res://src/features/mods/mod_result.gd")

const TEXT_TYPES := ["exact_text", "contains", "regex"]
const RUN_TYPES := ["stdout_contains", "stdout_regex", "exit_code"]
const DEFAULT_TIMEOUT_MS := 10000
const MAX_TIMEOUT_MS := 120000
const MAX_TESTS := 32

## Callable(path: String, options: Dictionary) -> void
var _start_run: Callable = Callable()
## Callable() -> void
var _stop_run: Callable = Callable()

var _clock_ms: float = 0.0
var _next_token: int = 0
## token -> {spec, context, done, deadline_ms, pending, results, token}
var _jobs: Dictionary = {}
var _active_token: int = 0


func set_run_bridge(start_callable: Callable, stop_callable: Callable = Callable()) -> void:
	_start_run = start_callable
	_stop_run = stop_callable


## Returns {status: "passed"|"failed"|"pending", token, results, message}.
## `done` is called exactly once with the final result.
func start(spec: Variant, context: Dictionary, done: Callable) -> Dictionary:
	var normalized := normalize_spec(spec)
	if !bool(normalized.get("ok", false)):
		return _finish_immediate(normalized, done)

	var run_required := needs_run(normalized)
	var custom := is_custom(normalized)
	if (run_required or custom) and _active_token != 0 and _jobs.has(_active_token):
		return Result.error(
			"state.invalid",
			"A validation is already in progress; wait for it to finish.",
		)

	_next_token += 1
	var token := _next_token
	var job := {
		"token": token,
		"spec": normalized,
		"context": context.duplicate(true),
		"done": done,
		"deadline_ms": _clock_ms + maxi(1, int(normalized.get("timeout_ms", DEFAULT_TIMEOUT_MS))),
		"pending": false,
		"awaiting_run": false,
		"results": [],
	}

	if custom and !run_required:
		# The mod answers with a token; no process is started and no other check
		# can run until it resolves or times out.
		job["pending"] = true
		_jobs[token] = job
		_active_token = token
		return {
			"status": "pending",
			"token": token,
			"requires": "custom",
			"results": [],
			"message": "Waiting for the mod's custom validation.",
		}

	if !run_required:
		var result := _evaluate(job, str(context.get("text", "")), "", 0)
		job["done"] = Callable()
		_jobs.erase(token)
		_call_done(done, result)
		return result

	_jobs[token] = job
	_active_token = token
	var path := str(context.get("path", ""))
	if path.is_empty() or !_start_run.is_valid():
		var blocked := _job_result(job, false, [
			{"name": "run", "type": "run", "passed": false, "message": "RunService cannot start a validation run."},
		], "run.blocked", "RunService cannot start a validation run.")
		_finish(token, blocked)
		return blocked

	job["pending"] = true
	job["awaiting_run"] = true
	_start_run.call(path, {
		"mode": "capture",
		"source": "mod_validation",
		"timeout_ms": int(normalized.get("timeout_ms", DEFAULT_TIMEOUT_MS)),
	})
	return {
		"status": "pending",
		"token": token,
		"results": [],
		"message": "Waiting for the validation run.",
	}


## Resolves a custom validation job or a run that finished twice.
func resolve(token: int, passed: bool, details: Dictionary = {}) -> Dictionary:
	var key := int(token)
	if !_jobs.has(key):
		return Result.error("exercise.unknown", "There is no pending validation with that token.")
	var job: Dictionary = _jobs[key]
	var results: Array = details.get("results", [])
	var result := _job_result(
		job,
		bool(passed),
		results,
		str(details.get("code", "")),
		str(details.get("message", "")),
	)
	_finish(key, result)
	return result


func cancel(token: int) -> void:
	var key := int(token)
	if !_jobs.has(key):
		return
	var job: Dictionary = _jobs[key]
	_jobs.erase(key)
	if _active_token == key:
		_active_token = 0
	if bool(job.get("awaiting_run", false)) and _stop_run.is_valid():
		_stop_run.call()
	job["done"] = Callable()


func cancel_all() -> void:
	for token in _jobs.keys():
		cancel(int(token))


func pending_token() -> int:
	return _active_token


## Called by the host when RunService finishes. Returns true when this runner
## owned the run.
func notify_run_finished(output: String, exit_code: int) -> bool:
	var token := _active_token
	if token == 0 or !_jobs.has(token):
		return false
	var job: Dictionary = _jobs[token]
	if !bool(job.get("pending", false)) or !bool(job.get("awaiting_run", false)):
		return false

	var text := ""
	var context: Variant = job.get("context", {})
	if context is Dictionary:
		text = str((context as Dictionary).get("text", ""))
	var result := _evaluate(job, text, output, int(exit_code))
	_finish(token, result)
	return true


func tick(delta_ms: float) -> void:
	_clock_ms += maxf(0.0, float(delta_ms))
	var expired: Array = []
	for token in _jobs.keys():
		var job: Dictionary = _jobs[token]
		if bool(job.get("pending", false)) and float(job.get("deadline_ms", 0.0)) <= _clock_ms:
			expired.append(int(token))
	for token in expired:
		var job: Dictionary = _jobs[token]
		var needs_stop := bool(job.get("awaiting_run", false))
		var result := _job_result(job, false, [], "run.timeout", "The validation run exceeded its timeout.")
		_finish(token, result)
		if needs_stop and _stop_run.is_valid():
			_stop_run.call()


func has_pending() -> bool:
	return _active_token != 0 and _jobs.has(_active_token)


# ── SPECS ───────────────────────────────────────────────────────────────────

static func normalize_spec(spec: Variant) -> Dictionary:
	if spec == null:
		return {"ok": true, "tests": [], "timeout_ms": DEFAULT_TIMEOUT_MS, "stop_on_fail": false}
	if !(spec is Dictionary):
		return Result.error("exercise.invalid_spec", "Validation must be an object.")
	var raw: Dictionary = spec
	var timeout := clampi(int(raw.get("timeout_ms", DEFAULT_TIMEOUT_MS)), 1, MAX_TIMEOUT_MS)

	var tests: Array = []
	if raw.get("tests") is Array:
		tests = (raw["tests"] as Array).duplicate(true)
	elif raw.has("type"):
		tests = [raw.duplicate(true)]
	if tests.size() > MAX_TESTS:
		return Result.error(
			"exercise.invalid_spec",
			"A validation may declare at most %d checks." % MAX_TESTS,
		)

	for index in range(tests.size()):
		var test: Variant = tests[index]
		if !(test is Dictionary):
			return Result.error("exercise.invalid_spec", "Every check must be an object.")
		var kind := str((test as Dictionary).get("type", ""))
		if !TEXT_TYPES.has(kind) and !RUN_TYPES.has(kind) and kind != "custom":
			return Result.error("exercise.invalid_spec", "'%s' is not a validation type." % kind)
		if kind == "custom":
			continue
		if !(test as Dictionary).has("value"):
			return Result.error("exercise.invalid_spec", "A validation check needs a value.")
		tests[index] = (test as Dictionary).duplicate(true)

	return {
		"ok": true,
		"tests": tests,
		"timeout_ms": timeout,
		"stop_on_fail": bool(raw.get("stop_on_fail", false)),
	}


static func needs_run(spec: Variant) -> bool:
	var normalized := normalize_spec(spec) if !(spec is Dictionary) or !(spec as Dictionary).has("ok") else (spec as Dictionary)
	if !bool(normalized.get("ok", false)):
		return false
	for test in normalized.get("tests", []):
		var test_type := str((test as Dictionary).get("type", ""))
		if RUN_TYPES.has(test_type):
			return true
	return false


static func is_custom(spec: Variant) -> bool:
	var normalized := normalize_spec(spec) if !(spec is Dictionary) or !(spec as Dictionary).has("ok") else (spec as Dictionary)
	if !bool(normalized.get("ok", false)):
		return false
	for test in normalized.get("tests", []):
		if str((test as Dictionary).get("type", "")) == "custom":
			return true
	return false


# ── EVALUATION ──────────────────────────────────────────────────────────────

func _evaluate(job: Dictionary, text: String, output: String, exit_code: int) -> Dictionary:
	var spec: Dictionary = job["spec"]
	var results: Array = []
	var passed := true
	var normalized_text := text.replace("\r\n", "\n").replace("\r", "\n")

	for test in spec.get("tests", []):
		var check: Dictionary = test
		var kind := str(check.get("type", ""))
		var name := str(check.get("name", kind))
		var value: Variant = check.get("value", "")

		match kind:
			"exact_text":
				var expected := str(value).replace("\r\n", "\n").replace("\r", "\n")
				var text_ok := _trim_final_newline(normalized_text) == _trim_final_newline(expected)
				results.append({
					"name": name, "type": kind, "passed": text_ok,
					"message": "" if text_ok else "The text does not match the expected step.",
				})
				passed = passed and text_ok
			"contains":
				var contains_ok := normalized_text.contains(str(value))
				results.append({
					"name": name, "type": kind, "passed": contains_ok,
					"message": "" if contains_ok else "The text does not contain the expected content.",
				})
				passed = passed and contains_ok
			"regex":
				var text_match := _regex_match(str(value), normalized_text)
				var regex_ok := bool(text_match.get("ok", false))
				results.append({
					"name": name, "type": kind, "passed": regex_ok,
					"message": str(text_match.get("message", "")),
				})
				passed = passed and regex_ok
			"stdout_contains":
				var output_ok := output.contains(str(value))
				results.append({
					"name": name, "type": kind, "passed": output_ok,
					"message": "" if output_ok else "The program output does not contain the expected text.",
				})
				passed = passed and output_ok
			"stdout_regex":
				var output_match := _regex_match(str(value), output)
				var stdout_ok := bool(output_match.get("ok", false))
				results.append({
					"name": name, "type": kind, "passed": stdout_ok,
					"message": str(output_match.get("message", "")),
				})
				passed = passed and stdout_ok
			"exit_code":
				var exit_ok := int(exit_code) == int(value)
				results.append({
					"name": name, "type": kind, "passed": exit_ok,
					"message": "" if exit_ok else "The program exited with %d, expected %s." % [int(exit_code), str(value)],
				})
				passed = passed and exit_ok
			"custom":
				results.append({
					"name": name, "type": kind, "passed": true,
					"message": "Custom checks are resolved by the mod.",
				})
			_:
				results.append({
					"name": name, "type": kind, "passed": false,
					"message": "Unknown validation type.",
				})
				passed = false

		if !passed and bool(spec.get("stop_on_fail", false)):
			break

	var code := "" if passed else "exercise.failed"
	var message := "" if passed else "The exercise did not pass its validation."
	return _job_result(job, passed, results, code, message, output, exit_code)


func _job_result(
	job: Dictionary,
	passed: bool,
	results: Array,
	code: String = "",
	message: String = "",
	output: String = "",
	exit_code: int = 0,
) -> Dictionary:
	return {
		"status": "passed" if passed else "failed",
		"passed": passed,
		"token": int(job.get("token", 0)),
		"results": results,
		"output": output,
		"exit_code": int(exit_code),
		"code": code,
		"message": message,
	}


func _finish(token: int, result: Dictionary) -> void:
	if !_jobs.has(token):
		return
	var job: Dictionary = _jobs[token]
	_jobs.erase(token)
	if _active_token == token:
		_active_token = 0
	_call_done(job.get("done", Callable()), result)


func _finish_immediate(failure: Dictionary, done: Callable) -> Dictionary:
	var result := {
		"status": "failed",
		"passed": false,
		"token": 0,
		"results": [],
		"output": "",
		"exit_code": 0,
		"code": str(failure.get("error", {}).get("code", "exercise.invalid_spec")),
		"message": str(failure.get("error", {}).get("message", "Invalid validation.")),
	}
	_call_done(done, result)
	return result


func _call_done(done: Variant, result: Dictionary) -> void:
	if done is Callable and (done as Callable).is_valid():
		(done as Callable).call(result)


static func _trim_final_newline(text: String) -> String:
	var out := text
	while out.ends_with("\n"):
		out = out.substr(0, out.length() - 1)
	return out


static func _regex_match(pattern: String, text: String) -> Dictionary:
	var regex := RegEx.new()
	if regex.compile(pattern) != OK:
		return {"ok": false, "message": "The validation pattern is not a valid regular expression."}
	var found := regex.search(text) != null
	return {
		"ok": found,
		"message": "" if found else "The pattern did not match.",
	}
