extends TestCase

const IgnoreRulesScript = preload("res://src/platform/ignore_rules.gd")


func _rules(text: String):
	var rules = IgnoreRulesScript.new()
	rules.add_file("", text)
	return rules


func test_a_plain_name_matches_at_any_depth() -> void:
	var rules = _rules("*.log\n")
	assert_true(rules.matches("app.log"))
	assert_true(rules.matches("logs/app.log"))
	assert_false(rules.matches("app.txt"))


func test_a_trailing_slash_only_ignores_directories() -> void:
	var rules = _rules("build/\n")
	assert_true(rules.matches("build", true))
	assert_true(rules.matches("build/app.js", false))
	assert_false(rules.matches("build"))


func test_anchored_rules_only_apply_at_the_root() -> void:
	var rules = _rules("/todo.md\n")
	assert_true(rules.matches("todo.md"))
	assert_false(rules.matches("docs/todo.md"))


func test_double_star_spans_directories() -> void:
	var rules = _rules("src/**/generated/\n")
	assert_true(rules.matches("src/generated", true))
	assert_true(rules.matches("src/api/generated", true))
	assert_true(rules.matches("src/api/generated/types.gd", false))
	assert_false(rules.matches("tests/api/generated", true))


func test_negation_restores_the_last_word() -> void:
	var rules = _rules("*.log\n!important.log\n")
	assert_true(rules.has_negation)
	assert_true(rules.matches("app.log"))
	assert_false(rules.matches("important.log"))


func test_nested_file_rules_are_scoped_to_their_folder() -> void:
	var rules = IgnoreRulesScript.new()
	rules.add_file("", "*.tmp\n")
	rules.add_file("vendor", "*.gd\n")
	assert_true(rules.matches("notes.tmp"))
	assert_true(rules.matches("vendor/lib.gd"))
	assert_false(rules.matches("src/lib.gd"))


func test_comments_and_blank_lines_are_ignored() -> void:
	var rules = _rules("# a comment\n\n\n")
	assert_true(rules.is_empty())
	assert_false(rules.matches("anything.gd"))
