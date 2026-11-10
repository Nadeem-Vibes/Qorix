extends "res://tests/support/test_case.gd"

const ErrorExplainer = preload("res://src/features/run/error_explainer.gd")

const TEST_DIR := "user://tests_error_explainer"

var explainer
var load_summary: Dictionary = {}


func before_each() -> void:
	_remove_dir(TEST_DIR)
	DirAccess.make_dir_recursive_absolute(_root())
	explainer = ErrorExplainer.new()
	load_summary = explainer.load_rules()


func after_each() -> void:
	_remove_dir(TEST_DIR)
	explainer = null


func _remove_dir(path: String) -> void:
	var global := ProjectSettings.globalize_path(path)
	var dir := DirAccess.open(global)
	if dir == null:
		return
	for file in dir.get_files():
		DirAccess.remove_absolute(global.path_join(file))
	for folder in dir.get_directories():
		_remove_dir(path.path_join(folder))
	DirAccess.remove_absolute(global)


func _root() -> String:
	return ProjectSettings.globalize_path(TEST_DIR).replace("\\", "/")


func _write(name: String, text: String) -> String:
	var path := _root().path_join(name)
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	return path


func _ids(diagnoses: Array) -> Array:
	var out: Array = []
	for diagnosis in diagnoses:
		out.append(str(diagnosis.get("id", "")))
	return out


func test_rule_files_load_without_errors() -> void:
	assert_true(load_summary.get("ok", false))
	assert_eq(load_summary.get("errors", []).size(), 0)
	assert_true(int(load_summary.get("rules", 0)) >= 30)
	assert_true(explainer.is_loaded())


func test_a_missing_rule_folder_is_reported() -> void:
	var summary: Dictionary = explainer.load_rules("user://definitely_missing_rules")

	assert_false(summary.get("ok", true))
	assert_true(summary.get("errors", []).size() > 0)


func test_python_syntax_error_has_a_file_line_and_fix() -> void:
	var path := _write("main.py", "def broken(\n    print(\"hi\")\n")
	var output := "Traceback (most recent call last):\n  File \"main.py\", line 2\n    print(\"hi\")\n         ^\nSyntaxError: invalid syntax\n"
	var diagnoses: Array = explainer.explain(output, {"language": "python", "cwd": _root()})

	assert_eq(diagnoses.size(), 1)
	var diagnosis: Dictionary = diagnoses[0]
	assert_eq(diagnosis.get("id"), "python-syntax")
	assert_eq(diagnosis.get("title"), "Python syntax error")
	assert_eq(diagnosis.get("severity"), "error")
	assert_eq(diagnosis.get("file"), path)
	assert_eq(diagnosis.get("line"), 2)
	assert_true(diagnosis.get("link", false))
	assert_true(diagnosis.get("file_exists", false))
	assert_eq(diagnosis.get("source_line"), "print(\"hi\")")
	assert_true(str(diagnosis.get("message", "")).contains("line 2"))
	assert_true(str(diagnosis.get("explain", "")).contains("line 2"))
	assert_true(str(diagnosis.get("fix", "")).contains("line 2"))


func test_javascript_alias_selects_the_node_rules() -> void:
	var path := _write("app.js", "const fs = require(\"fs\");\nconst app = {};\nconst value = ;\n")
	var output := path + ":3\nconst value = ;\n         ^^^^^\nSyntaxError: Unexpected token ';'\n"
	var diagnoses: Array = explainer.explain(output, {"language": "js"})

	assert_eq(diagnoses.size(), 1)
	var diagnosis: Dictionary = diagnoses[0]
	assert_eq(diagnosis.get("id"), "node-syntax-token")
	assert_eq(diagnosis.get("title"), "JavaScript syntax error")
	assert_eq(diagnosis.get("line"), 3)
	assert_true(str(diagnosis.get("message", "")).contains("line 3"))
	assert_true(diagnosis.get("link", false))


func test_compiler_warning_keeps_its_severity_and_column() -> void:
	var path := _write("main.c", "int main(void) {\n  int x;\n  return 0;\n}\n")
	var output := path + ":2:7: warning: unused variable 'x' [-Wunused-variable]\n"
	var diagnoses: Array = explainer.explain(output, {"language": "c"})

	assert_eq(diagnoses.size(), 1)
	var diagnosis: Dictionary = diagnoses[0]
	assert_eq(diagnosis.get("id"), "cc-diagnostic")
	assert_eq(diagnosis.get("severity"), "warning")
	assert_eq(diagnosis.get("line"), 2)
	assert_eq(diagnosis.get("column"), 7)
	assert_eq(diagnosis.get("title"), "warning on line 2")
	assert_true(str(diagnosis.get("message", "")).contains("unused variable"))


func test_module_errors_are_deduplicated() -> void:
	var output := "ModuleNotFoundError: No module named 'flask'\nModuleNotFoundError: No module named 'requests'\n"
	var diagnoses: Array = explainer.explain(output, {"language": "python"})

	assert_eq(diagnoses.size(), 1)
	assert_eq(diagnoses[0].get("id"), "python-module")
	assert_true(str(diagnoses[0].get("message", "")).contains("flask"))
	assert_true(str(diagnoses[0].get("fix", "")).contains("pip install flask"))


func test_language_rules_come_before_generic_rules() -> void:
	var output := "Permission denied\nModuleNotFoundError: No module named 'flask'\n"
	var diagnoses: Array = explainer.explain(output, {"language": "python"})

	assert_eq(_ids(diagnoses), ["python-module", "generic-permission-denied"])


func test_windows_missing_command_is_explained() -> void:
	var output := "'frobnicate' is not recognized as an internal or external command,\noperable program or batch file.\n"
	var diagnoses: Array = explainer.explain(output, {"language": "generic"})

	assert_eq(diagnoses.size(), 1)
	assert_eq(diagnoses[0].get("id"), "generic-missing-command")
	assert_eq(diagnoses[0].get("title"), "\"frobnicate\" is not installed")
	assert_true(str(diagnoses[0].get("fix", "")).contains("Install"))


func test_posix_missing_command_is_explained() -> void:
	var output := "/usr/bin/env: 'node': No such file or directory\n"
	var diagnoses: Array = explainer.explain(output, {"language": ""})

	assert_eq(diagnoses.size(), 1)
	assert_eq(diagnoses[0].get("id"), "generic-no-such-file")


func test_a_relative_missing_file_keeps_a_useful_path_but_no_link() -> void:
	var output := "  File \"ghost.py\", line 9\nSyntaxError: nope\n"
	var diagnoses: Array = explainer.explain(output, {"language": "python", "cwd": _root()})

	assert_eq(diagnoses.size(), 1)
	assert_eq(diagnoses[0].get("file"), _root().path_join("ghost.py"))
	assert_eq(diagnoses[0].get("line"), 9)
	assert_false(diagnoses[0].get("file_exists", true))
	assert_false(diagnoses[0].get("link", true))


func test_relative_paths_prefer_the_run_cwd() -> void:
	var path := _write("main.py", "print('a')\nprint(missing)\n")
	var output := "  File \"main.py\", line 2\n    print(missing)\nNameError: name 'missing' is not defined\n"
	var diagnoses: Array = explainer.explain(output, {"language": "python", "cwd": _root()})

	assert_eq(diagnoses.size(), 1)
	assert_eq(diagnoses[0].get("id"), "python-name")
	assert_eq(diagnoses[0].get("file"), path)


func test_success_with_no_output_gets_an_informational_card() -> void:
	var diagnoses: Array = explainer.explain("", {"exit_code": 0})

	assert_eq(diagnoses.size(), 1)
	assert_eq(diagnoses[0].get("id"), "run-success")
	assert_eq(diagnoses[0].get("severity"), "info")
	assert_eq(diagnoses[0].get("link"), false)


func test_success_with_output_gets_no_fake_diagnosis() -> void:
	var diagnoses: Array = explainer.explain("hello\n", {"exit_code": 0})

	assert_eq(diagnoses.size(), 0)


func test_an_unrecognised_exit_code_uses_the_last_line() -> void:
	var diagnoses: Array = explainer.explain("starting\nsomething broke\n\n", {"exit_code": 3})

	assert_eq(diagnoses.size(), 1)
	assert_eq(diagnoses[0].get("id"), "run-exit-code")
	assert_eq(diagnoses[0].get("title"), "The program exited with code 3")
	assert_eq(diagnoses[0].get("message"), "something broke")
	assert_eq(diagnoses[0].get("severity"), "error")


func test_a_stopped_process_is_a_warning() -> void:
	var diagnoses: Array = explainer.explain("", {"exit_code": -1})

	assert_eq(diagnoses.size(), 1)
	assert_eq(diagnoses[0].get("id"), "run-stopped")
	assert_eq(diagnoses[0].get("severity"), "warning")


func test_summary_prefers_the_first_diagnosis() -> void:
	var diagnosis := {"title": "Python syntax error"}

	assert_eq(explainer.summary([diagnosis], 1), "Python syntax error")


func test_summary_falls_back_to_the_exit_code() -> void:
	assert_eq(explainer.summary([], 0), "Program finished")
	assert_eq(explainer.summary([], -1), "Program stopped")
	assert_eq(explainer.summary([], 2), "Program failed (exit code 2)")


func test_explain_loads_the_rules_on_first_use() -> void:
	var fresh = ErrorExplainer.new()
	var diagnoses: Array = fresh.explain("ZeroDivisionError: division by zero\n", {"language": "python"})

	assert_true(fresh.is_loaded())
	assert_eq(diagnoses.size(), 1)
	assert_eq(diagnoses[0].get("id"), "python-zero-division")


func test_rules_render_in_german() -> void:
	var german = ErrorExplainer.new()
	german.locale = "de"
	german.load_rules()
	var diagnoses: Array = german.explain("ZeroDivisionError: division by zero\n", {"language": "python"})

	assert_eq(diagnoses.size(), 1)
	assert_eq(str(diagnoses[0].get("title", "")), "Division durch null")
	assert_true(str(diagnoses[0].get("explain", "")).contains("Der Divisor wurde zur Laufzeit"))


func test_rules_render_in_spanish() -> void:
	var spanish = ErrorExplainer.new()
	spanish.locale = "es"
	spanish.load_rules()
	var diagnoses: Array = spanish.explain("ZeroDivisionError: division by zero\n", {"language": "python"})

	assert_eq(diagnoses.size(), 1)
	assert_eq(str(diagnoses[0].get("title", "")), "División por cero")
	assert_true(str(diagnoses[0].get("explain", "")).contains("El divisor se convirtió en 0"))


func test_fallback_cards_render_in_german_and_spanish() -> void:
	var german = ErrorExplainer.new()
	german.locale = "de"
	german.load_rules()
	var diagnoses: Array = german.explain("", {"exit_code": -1})
	assert_eq(diagnoses.size(), 1)
	assert_eq(str(diagnoses[0].get("title", "")), "Das Programm wurde gestoppt")

	var spanish = ErrorExplainer.new()
	spanish.locale = "es"
	spanish.load_rules()
	var diagnoses2: Array = spanish.explain("", {"exit_code": -1})
	assert_eq(diagnoses2.size(), 1)
	assert_eq(str(diagnoses2[0].get("title", "")), "El programa se detuvo")
