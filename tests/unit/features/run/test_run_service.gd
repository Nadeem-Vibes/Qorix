extends TestCase

## Covers the small, pure decision that keeps interactive Python programs out
## of the captured runner. The RunService Node itself needs a PTY, so this
## suite exercises the helpers without creating a scene.

const RunServiceScript = preload("res://src/features/run/run_service.gd")
const RunConfigScript = preload("res://src/features/run/run_config.gd")


func test_python_input_is_detected_as_interactive() -> void:
	var profile := {"language": "python", "auto_terminal": true}
	assert_true(
		RunServiceScript.script_reads_stdin(profile, "name = input('Your name: ')"),
		"input() should route to the terminal"
	)
	assert_true(
		RunServiceScript.script_reads_stdin(profile, "age = input ('Age: ')"),
		"whitespace before the call parenthesis is valid Python"
	)


func test_python_stdin_readers_are_detected() -> void:
	var profile := {"language": "python", "auto_terminal": true}
	assert_true(
		RunServiceScript.script_reads_stdin(profile, "line = sys.stdin.readline()"),
		"sys.stdin should route to the terminal"
	)
	assert_true(
		RunServiceScript.script_reads_stdin(profile, "for line in fileinput.input():\n\tprint(line)"),
		"fileinput reads the keyboard stream"
	)


func test_non_interactive_python_stays_captured() -> void:
	var profile := {"language": "python", "auto_terminal": true}
	assert_false(
		RunServiceScript.script_reads_stdin(profile, "print('hello')\nfor i in range(3):\n\tprint(i)"),
		"a plain print script should stay in the Run panel"
	)
	assert_false(
		RunServiceScript.script_reads_stdin(profile, ""),
		"an empty buffer cannot read stdin"
	)


func test_auto_terminal_requires_profile_opt_in() -> void:
	var profile := {"language": "python"}
	assert_false(
		RunServiceScript.script_reads_stdin(profile, "input('Name: ')"),
		"a profile without auto_terminal keeps its configured runtime"
	)


func test_unknown_language_is_not_guessed() -> void:
	var profile := {"language": "javascript", "auto_terminal": true}
	assert_false(
		RunServiceScript.script_reads_stdin(profile, "const rl = require('node:readline')"),
		"languages without a pattern table are left to the explicit mode"
	)


func test_builtin_python_opts_into_auto_terminal() -> void:
	var config = RunConfigScript.new()
	var python: Dictionary = config.profile_for("main.py")
	assert_true(bool(python.get("auto_terminal", false)), "built-in Python should auto-route stdin readers")
	assert_eq(str(python.get("mode", "")), "capture", "auto-terminal is an addition, not a mode change")

	var javascript: Dictionary = config.profile_for("main.js")
	assert_false(bool(javascript.get("auto_terminal", false)), "other built-ins stay captured")


func test_python_shebang_opts_into_auto_terminal() -> void:
	var config = RunConfigScript.new()
	config.file_text = "#!/usr/bin/env python3\nname = input('Name: ')"
	var profile: Dictionary = config.shebang_profile()
	assert_eq(str(profile.get("language", "")), "python", "the shebang should identify Python")
	assert_true(bool(profile.get("auto_terminal", false)), "a Python shebang should auto-route stdin readers")


func test_project_can_disable_auto_terminal() -> void:
	var config = RunConfigScript.new()
	config.apply_config({
		"run": {
			"python": {
				"command": "python -u $file",
				"auto_terminal": false,
			},
		},
	}, "test")
	var python: Dictionary = config.profile_for("main.py")
	assert_false(bool(python.get("auto_terminal", true)), "an explicit project value should win")
