extends "res://tests/support/test_case.gd"

const GuessLang = preload("res://src/features/run/guesslang_service.gd")

const PYTHON_SAMPLE := "import os\nfrom pathlib import Path\n\ndef load_names(folder):\n    path = Path(folder)\n    names = []\n    for entry in path.iterdir():\n        if entry.suffix == \".txt\":\n            names.append(entry.stem)\n    return sorted(names)\n\nif __name__ == \"__main__\":\n    print(load_names(os.getcwd()))\n"

const JAVASCRIPT_SAMPLE := "const fs = require(\"fs\");\n\nfunction readSettings(filename) {\n  const text = fs.readFileSync(filename, \"utf8\");\n  return JSON.parse(text);\n}\n\nconst settings = readSettings(\"settings.json\");\nconsole.log(`loaded ${Object.keys(settings).length} settings`);\nmodule.exports = { readSettings };\n"

const HTML_SAMPLE := "<!DOCTYPE html>\n<html lang=\"en\">\n<head><title>Status</title></head>\n<body><main class=\"page\"><h1>Ready</h1></main></body>\n</html>\n"

const PROSE_SAMPLE := "Dear team, the release meeting has moved to Friday afternoon. Please review the checklist before then and send comments. Thanks for your patience.\n"

const SHORT_PYTHON_SAMPLE := "import json\nfrom pathlib import Path\n\ndef load_config(path):\n    data = json.loads(Path(path).read_text(encoding=\"utf-8\"))\n    return data\n\nprint(load_config(\"config.json\"))\n"

const WEAK_PYTHON_SAMPLE := "def greet(name):\n    print(name)\n"

const SHEBANG_SCRIPT := "#!/usr/bin/env python\nprint(\"shebang picked Python\")\n"

var service
var load_summary: Dictionary = {}


func before_each() -> void:
	service = GuessLang.new()
	load_summary = service.load_profiles()


func after_each() -> void:
	service = null


func test_profiles_load_without_errors() -> void:
	assert_true(load_summary.get("ok", false))
	assert_eq(load_summary.get("errors", []).size(), 0)
	assert_eq(service.profile_count(), 35)
	assert_true(service.available())


func test_a_missing_profile_file_is_reported() -> void:
	var broken = GuessLang.new("user://missing_language_profiles.json")
	var summary: Dictionary = broken.load_profiles()

	assert_false(summary.get("ok", true))
	assert_true(summary.get("errors", []).size() > 0)
	assert_false(broken.available())


func test_python_is_detected_from_a_plain_text_file() -> void:
	var result: Dictionary = service.detect(PYTHON_SAMPLE, "notes.txt")

	assert_true(result.get("ok", false))
	assert_eq(result.get("language"), "python")
	assert_eq(result.get("display"), "Python")
	assert_eq(result.get("highlight"), "py")
	assert_eq(result.get("run_language"), "python")
	assert_true(result.get("auto", false))
	assert_true(float(result.get("confidence", 0.0)) >= 0.62)
	assert_true(result.get("evidence", []).size() > 0)
	assert_eq(result.get("method"), "ngram+markers")


func test_javascript_is_detected_from_a_plain_text_file() -> void:
	var result: Dictionary = service.detect(JAVASCRIPT_SAMPLE, "notes.txt")

	assert_true(result.get("ok", false))
	assert_eq(result.get("language"), "javascript")
	assert_eq(result.get("highlight"), "js")
	assert_true(result.get("auto", false))


func test_html_is_detected_from_a_plain_text_file() -> void:
	var result: Dictionary = service.detect(HTML_SAMPLE, "notes.txt")

	assert_true(result.get("ok", false))
	assert_eq(result.get("language"), "html")
	assert_eq(result.get("highlight"), "html")
	assert_true(result.get("auto", false))


func test_prose_is_not_auto_detected() -> void:
	var result: Dictionary = service.detect(PROSE_SAMPLE, "notes.txt")

	assert_true(result.get("ok", false))
	assert_false(result.get("auto", true))


func test_a_short_real_script_is_auto_detected() -> void:
	var result: Dictionary = service.detect(SHORT_PYTHON_SAMPLE, "notes.txt")

	assert_true(result.get("ok", false))
	assert_eq(result.get("language"), "python")
	assert_true(result.get("auto", false))
	assert_true(float(result.get("confidence", 0.0)) >= service.auto_confidence())


func test_a_two_line_snippet_is_not_auto_detected() -> void:
	var result: Dictionary = service.detect(WEAK_PYTHON_SAMPLE, "notes.txt")

	assert_true(result.get("ok", false))
	assert_eq(result.get("language"), "python")
	assert_false(result.get("auto", true))


func test_blank_lines_do_not_look_like_brainfuck() -> void:
	var result: Dictionary = service.detect(SHORT_PYTHON_SAMPLE, "notes.txt")

	assert_true(result.get("ok", false))
	assert_ne(result.get("language"), "brainfuck")


func test_a_shebang_script_without_an_extension_is_auto_detected() -> void:
	var result: Dictionary = service.detect(SHEBANG_SCRIPT, "script_no_ext")

	assert_true(result.get("ok", false))
	assert_eq(result.get("language"), "python")
	assert_true(result.get("auto", false))
	assert_true(float(result.get("confidence", 0.0)) >= 0.9)


func test_detected_languages_offer_a_canonical_save_extension() -> void:
	assert_eq(service.preferred_extension("python"), "py")
	assert_eq(service.preferred_extension("javascript"), "js")
	assert_eq(service.preferred_extension("typescript"), "ts")
	assert_eq(service.preferred_extension("c"), "c")
	assert_eq(service.preferred_extension("no_such_language"), "")

	# A saved file's extension is also a valid lookup key.
	assert_eq(service.preferred_extension("py"), "py")
	assert_true(service.extensions_for("python").has("pyw"))


func test_too_short_input_is_rejected_with_a_message() -> void:
	var result: Dictionary = service.detect("hi", "notes.txt")

	assert_false(result.get("ok", true))
	assert_eq(result.get("error"), "too-short")
	assert_false(str(result.get("message", "")).is_empty())
	assert_false(result.get("auto", true))


func test_auto_detection_requires_a_confidence_margin() -> void:
	service.settings["auto_margin"] = 10.0
	var result: Dictionary = service.detect(PYTHON_SAMPLE, "notes.txt")

	assert_true(result.get("ok", false))
	assert_eq(result.get("language"), "python")
	assert_false(result.get("auto", true))


func test_profile_lookup_accepts_an_extension_alias() -> void:
	assert_eq(service.profile_for("py").get("id"), "python")
	assert_eq(service.profile_for(".JS").get("id"), "javascript")
	assert_eq(service.profile_for("ts").get("id"), "typescript")
	assert_eq(service.profile_for("not_a_language"), {})


func test_highlight_and_run_language_helpers() -> void:
	assert_eq(service.highlight_for("python"), "py")
	assert_eq(service.highlight_for("typescript"), "js")
	assert_eq(service.run_language_for("html"), "html")
	assert_eq(service.run_language_for("not_a_language"), "not_a_language")


func test_detect_loads_profiles_on_first_use() -> void:
	var fresh = GuessLang.new()
	var result: Dictionary = fresh.detect(PYTHON_SAMPLE, "notes.txt")

	assert_true(fresh.loaded)
	assert_eq(result.get("language"), "python")


func test_detect_without_profiles_reports_unavailable() -> void:
	var broken = GuessLang.new("user://missing_language_profiles.json")
	var result: Dictionary = broken.detect(PYTHON_SAMPLE, "notes.txt")

	assert_false(result.get("ok", true))
	assert_eq(result.get("error"), "unavailable")
	assert_false(str(result.get("message", "")).is_empty())


func test_confidence_and_alternatives_are_safe_to_render() -> void:
	var result: Dictionary = service.detect(PYTHON_SAMPLE, "notes.txt")
	var confidence := float(result.get("confidence", -1.0))

	assert_true(confidence >= 0.0 and confidence <= 0.99)
	assert_true(result.get("alternatives", []).size() <= 3)
	for entry in result.get("alternatives", []):
		assert_true(entry is Dictionary)
		assert_false(str(entry.get("language", "")).is_empty())
		assert_true(float(entry.get("confidence", -1.0)) >= 0.0)
