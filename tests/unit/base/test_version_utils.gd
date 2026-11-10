extends "res://tests/support/test_case.gd"


func test_newer_major_is_higher() -> void:
	assert_true(VersionUtils.is_higher_version("v1.2.2", "v2.0.0"))


func test_same_version_is_not_higher() -> void:
	assert_false(VersionUtils.is_higher_version("v1.2.2", "v1.2.2"))


func test_components_compare_numerically() -> void:
	assert_true(VersionUtils.is_higher_version("v1.2.2", "v1.2.10"))
	assert_false(VersionUtils.is_higher_version("v1.10.0", "v1.9.9"))


func test_missing_components_count_as_zero() -> void:
	assert_true(VersionUtils.is_higher_version("v1.2", "v1.2.1"))
	assert_false(VersionUtils.is_higher_version("v1.2.1", "v1.2"))


func test_prerelease_suffix_is_ignored_for_ordering() -> void:
	assert_true(VersionUtils.is_higher_version("v1.2.2", "v1.2.3-beta"))
	assert_false(VersionUtils.is_higher_version("v1.2.2", "v1.2.2-beta"))


func test_compare_versions() -> void:
	assert_eq(VersionUtils.compare_versions("1.0.0", "1.0.0"), 0)
	assert_eq(VersionUtils.compare_versions("1.0.1", "1.0.0"), 1)
	assert_eq(VersionUtils.compare_versions("1.0.0", "1.0.1"), -1)
