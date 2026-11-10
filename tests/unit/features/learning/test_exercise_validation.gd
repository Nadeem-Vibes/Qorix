extends "res://tests/support/test_case.gd"

## Validation runner: text checks, run-backed checks, partial test results,
## custom tokens and timeouts. The run bridge is a stub, so nothing is executed.

const Validation = preload("res://src/features/learning/exercise/exercise_validation.gd")
const Result = preload("res://src/features/mods/mod_result.gd")

var _started: Array = []
var _stopped: int = 0
var _result: Dictionary = {}
var _done_calls: int = 0


func _start_run(path: String, options: Dictionary) -> void:
	_started.append([path, options])


func _stop_run() -> void:
	_stopped += 1


func _done(result: Dictionary) -> void:
	_result = result
	_done_calls += 1


func _runner():
	_started = []
	_stopped = 0
	_result = {}
	_done_calls = 0
	var runner = Validation.new()
	runner.set_run_bridge(Callable(self, "_start_run"), Callable(self, "_stop_run"))
	return runner


func _start(runner, spec: Variant, text: String = "", path: String = "C:/workspace/a.py") -> Dictionary:
	return runner.start(spec, {"text": text, "path": path, "doc": 1}, Callable(self, "_done"))


func test_exact_text_tolerates_line_endings_and_trailing_newline() -> void:
	var runner = _runner()
	var result := _start(runner, {"type": "exact_text", "value": "print(1)\n"}, "print(1)\r\n")
	check(bool(result.get("passed", false)), "CRLF and a trailing newline are tolerated")
	assert_eq(int(_done_calls), 1, "done is called exactly once for a text check")
	assert_eq(str(_result.get("status", "")), "passed")

	var mismatch := _start(runner, {"type": "exact_text", "value": "print(1)"}, "print(2)")
	assert_false(bool(mismatch.get("passed", true)), "different text fails")


func test_contains_and_regex() -> void:
	var runner = _runner()
	check(bool(_start(runner, {"type": "contains", "value": "print"}, "x = 1\nprint(x)").get("passed", false)), "contains passes")
	assert_false(bool(_start(runner, {"type": "contains", "value": "def"}, "print(1)").get("passed", true)), "contains fails")
	check(bool(_start(runner, {"type": "regex", "value": "print\\(\\d+\\)"}, "print(42)").get("passed", false)), "regex passes")
	assert_false(bool(_start(runner, {"type": "regex", "value": "["}, "print(1)").get("passed", true)), "bad regex fails safely")


func test_tests_list_reports_partial_results_and_stop_on_fail() -> void:
	var runner = _runner()
	var result := _start(runner, {
		"tests": [
			{"name": "has_print", "type": "contains", "value": "print"},
			{"name": "has_loop", "type": "contains", "value": "for"},
		],
	}, "print(1)")
	assert_false(bool(result.get("passed", true)), "one failing check fails the set")
	var results: Array = result.get("results", [])
	assert_eq(results.size(), 2, "every check is reported")
	check(bool((results[0] as Dictionary).get("passed", false)), "first check passed")
	assert_false(bool((results[1] as Dictionary).get("passed", true)), "second check failed")


func test_run_backed_validation_is_pending_until_run_finished() -> void:
	var runner = _runner()
	var outcome := _start(runner, {"type": "stdout_contains", "value": "Hello"})
	assert_eq(str(outcome.get("status", "")), "pending", "a run check is pending immediately")
	assert_eq(_started.size(), 1, "the run bridge was asked to start")
	assert_eq(_done_calls, 0, "nothing is done before the run")

	check(bool(runner.notify_run_finished("Hello, World!\n", 0)), "the runner owned the run")
	assert_eq(_done_calls, 1, "the run resolved the job")
	check(bool(_result.get("passed", false)), "stdout matched")

	assert_false(bool(runner.notify_run_finished("stray", 0)), "a second finish is not claimed")


func test_exit_code_and_stdout_regex() -> void:
	var runner = _runner()
	_start(runner, {
		"tests": [
			{"name": "exit", "type": "exit_code", "value": 0},
			{"name": "lines", "type": "stdout_regex", "value": "^1\\n2\\n3\\n$"},
		],
	})
	runner.notify_run_finished("1\n2\n3\n", 0)
	check(bool(_result.get("passed", false)), "both run checks passed")

	var failed_runner = _runner()
	_start(failed_runner, {"type": "exit_code", "value": 0})
	failed_runner.notify_run_finished("", 2)
	assert_false(bool(_result.get("passed", true)), "a non-zero exit fails")


func test_timeout_fails_and_stops_the_run() -> void:
	var runner = _runner()
	_start(runner, {"type": "stdout_contains", "value": "x", "timeout_ms": 500})
	runner.tick(600.0)
	assert_eq(str(_result.get("code", "")), "run.timeout", "the timeout is a structured failure")
	assert_eq(_stopped, 1, "the run was stopped")
	assert_eq(_done_calls, 1, "done ran once")


func test_custom_validation_waits_for_the_mod_token() -> void:
	var runner = _runner()
	var outcome := _start(runner, {"type": "custom", "value": "teacher"})
	assert_eq(str(outcome.get("status", "")), "pending", "custom validation is pending")
	assert_eq(str(outcome.get("requires", "")), "custom", "the requirement is named")
	var token := int(outcome.get("token", 0))
	check(token > 0, "a token is issued")
	check(bool(runner.resolve(token, true, {"results": [{"name": "manual", "type": "custom", "passed": true}]}).get("passed", false)), "resolve accepts the mod's answer")
	assert_eq(_done_calls, 1, "done ran once")
	assert_eq(Result.code_of(runner.resolve(token, true)), "exercise.unknown", "a used token is unknown")


func test_invalid_spec_is_a_failure_not_a_crash() -> void:
	var runner = _runner()
	var result := _start(runner, {"type": "not_a_check", "value": 1})
	assert_false(bool(result.get("passed", true)), "unknown type fails")
	assert_eq(str(result.get("code", "")), "exercise.invalid_spec")
	var bad := _start(runner, "not a dictionary")
	assert_eq(str(bad.get("code", "")), "exercise.invalid_spec", "a non-object spec fails with a code")
