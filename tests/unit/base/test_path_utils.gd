extends "res://tests/support/test_case.gd"


func test_backslashes_become_forward_slashes() -> void:
	assert_eq(PathUtils.normalize("C:\\foo\\bar.txt"), "C:/foo/bar.txt")


func test_duplicate_separators_are_collapsed() -> void:
	assert_eq(PathUtils.normalize("C://foo//bar///baz.txt"), "C:/foo/bar/baz.txt")


func test_trailing_slash_is_removed_but_roots_stay() -> void:
	assert_eq(PathUtils.normalize("C:/foo/bar/"), "C:/foo/bar")
	assert_eq(PathUtils.normalize("C:/"), "C:/")
	assert_eq(PathUtils.normalize("/"), "/")


func test_dot_segments_are_resolved() -> void:
	assert_eq(PathUtils.normalize("C:/foo/./bar/../baz"), "C:/foo/baz")
	assert_eq(PathUtils.normalize("/tmp/../etc/./x"), "/etc/x")


func test_resource_scheme_survives_normalization() -> void:
	assert_eq(PathUtils.normalize("user://langs//py.lua"), "user://langs/py.lua")
	assert_eq(PathUtils.normalize("res://src/base/../main/editor.tscn"), "res://src/main/editor.tscn")


func test_same_file_ignores_separator_spelling() -> void:
	assert_true(PathUtils.same_file("C:\\foo\\Bar.txt", "C:/foo/Bar.txt"))


func test_same_file_case_follows_the_platform() -> void:
	var upper := PathUtils.same_file("C:/foo/Bar.txt", "C:/foo/bar.txt")
	if OS.get_name() == "Windows":
		assert_true(upper, "Windows paths are case-insensitive")
	else:
		assert_false(upper, "POSIX paths are case-sensitive")


func test_same_file_rejects_empty_paths() -> void:
	assert_false(PathUtils.same_file("", ""))


func test_is_subpath_is_segment_aware() -> void:
	assert_true(PathUtils.is_subpath("/tmp/foo", "/tmp/foo/bar"))
	assert_true(PathUtils.is_subpath("/tmp/foo", "/tmp/foo"))
	assert_false(PathUtils.is_subpath("/tmp/foo", "/tmp/foo2"))
	assert_false(PathUtils.is_subpath("/tmp/foo", "/tmp/foobar/baz"))


func test_root_is_a_parent_of_absolute_paths() -> void:
	assert_true(PathUtils.is_subpath("/", "/tmp/anything"))


func test_extension() -> void:
	assert_eq(PathUtils.extension("archive.tar.gz"), "gz")
	assert_eq(PathUtils.extension("C:\\dir\\main.py"), "py")
	assert_eq(PathUtils.extension("README"), "")
	assert_eq(PathUtils.extension(".gitignore"), "")
	assert_eq(PathUtils.extension("trailing."), "")
