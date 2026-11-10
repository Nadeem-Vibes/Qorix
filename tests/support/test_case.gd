class_name TestCase
extends RefCounted

## Tiny assertion base for the headless runner. Tests keep running after a
## failed assertion so one run reports every problem, not just the first.

var failures: Array[String] = []
var checks: int = 0
var current_test: String = ""


func begin(test_name: String) -> void:
	current_test = test_name


func before_each() -> void:
	pass


func after_each() -> void:
	pass


func check(condition: bool, message: String) -> void:
	checks += 1
	if !condition:
		failures.append("%s: %s" % [current_test, message])


func assert_eq(actual: Variant, expected: Variant, message: String = "") -> void:
	checks += 1
	if actual != expected:
		failures.append("%s: %s (expected %s, got %s)" % [
			current_test,
			message if !message.is_empty() else "values differ",
			str(expected),
			str(actual),
		])


func assert_ne(actual: Variant, unexpected: Variant, message: String = "") -> void:
	checks += 1
	if actual == unexpected:
		failures.append("%s: %s (expected a value other than %s)" % [
			current_test,
			message if !message.is_empty() else "values are equal",
			str(unexpected),
		])


func assert_true(value: bool, message: String = "") -> void:
	check(value, message if !message.is_empty() else "expected true")


func assert_false(value: bool, message: String = "") -> void:
	check(!value, message if !message.is_empty() else "expected false")
