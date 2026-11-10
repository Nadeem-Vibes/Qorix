extends TestCase

## Semver ranges: caret/tilde ceilings, comparison groups, OR and failures.

const Semver = preload("res://src/features/mods/semver_range.gd")


func test_versions() -> void:
	check(Semver.is_version("1.2.3"), "plain semver")
	check(Semver.is_version("0.0.1"), "patch zero")
	check(Semver.is_version("1.2.3-beta.1"), "pre-release suffix")
	check(!Semver.is_version("1.2"), "partial is not a version")
	check(!Semver.is_version("v1.2.3"), "leading v is not a version")
	check(!Semver.is_version(""), "empty string")
	check(!Semver.is_version("1.2.3.4"), "four parts")


func test_parse() -> void:
	check(Semver.is_range("*"), "wildcard")
	check(Semver.is_range(""), "empty means any")
	check(Semver.is_range("^1.2.0"), "caret")
	check(Semver.is_range(">=1.0.0 <2.0.0"), "space-separated AND")
	check(Semver.is_range(">=1.0.0, <2.0.0"), "comma-separated AND")
	check(Semver.is_range("1.0.0 || 2.0.0"), "OR groups")
	check(!Semver.is_range(">=x"), "bad version")
	check(!Semver.is_range("^"), "missing version")
	check(!Semver.is_range(">=1.0.0 ||"), "empty OR group")


func test_caret() -> void:
	check(Semver.satisfies("1.2.3", "^1.2.0"), "at the floor")
	check(Semver.satisfies("1.9.9", "^1.2.0"), "same major")
	check(!Semver.satisfies("2.0.0", "^1.2.0"), "next major")
	check(!Semver.satisfies("1.1.9", "^1.2.0"), "below the floor")
	check(Semver.satisfies("0.2.5", "^0.2.3"), "zero major, same minor")
	check(!Semver.satisfies("0.3.0", "^0.2.3"), "zero major, next minor")
	check(Semver.satisfies("0.0.3", "^0.0.3"), "zero major and minor")
	check(!Semver.satisfies("0.0.4", "^0.0.3"), "zero major and minor ceiling")


func test_tilde() -> void:
	check(Semver.satisfies("1.2.9", "~1.2.3"), "same minor")
	check(!Semver.satisfies("1.3.0", "~1.2.3"), "next minor")
	check(Semver.satisfies("1.2.0", "~1.2"), "partial tilde")
	check(Semver.satisfies("1.9.9", "~1"), "major-only tilde")
	check(!Semver.satisfies("2.0.0", "~1"), "major-only tilde ceiling")


func test_comparisons_and_exact() -> void:
	check(Semver.satisfies("1.5.0", ">=1.0.0 <2.0.0"), "inside the window")
	check(!Semver.satisfies("2.0.0", ">=1.0.0 <2.0.0"), "exclusive ceiling")
	check(Semver.satisfies("1.2.3", "1.2.3"), "exact")
	check(Semver.satisfies("1.2.9", "=1.2"), "partial exact means the line")
	check(!Semver.satisfies("1.3.0", "=1.2"), "partial exact ceiling")
	check(Semver.satisfies("1.0.0", "1.0.0 || 2.0.0"), "first OR branch")
	check(Semver.satisfies("2.0.0", "1.0.0 || 2.0.0"), "second OR branch")
	check(Semver.satisfies("9.9.9", "*"), "wildcard")
	check(!Semver.satisfies("9.9.9", "nonsense"), "invalid range rejects")
	check(!Semver.satisfies("nonsense", "*"), "invalid version rejects")


func test_deterministic_parse() -> void:
	var first := Semver.parse(">=1.0.0 <2.0.0 || ^3.1.0")
	var second := Semver.parse(">=1.0.0 <2.0.0 || ^3.1.0")
	check(first.get("ok", false), "first parse")
	assert_eq(JSON.stringify(first.get("groups")), JSON.stringify(second.get("groups")), "same groups")
