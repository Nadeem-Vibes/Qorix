extends Node

## One-time, safe migration of the per-user data directory.
##
## The application was renamed from GriddyCode (and its unreleased
## "Bussin GriddyCode" builds) to Qorix, which moves Godot's per-user data
## directory (user://). On the first launch after the rename this copies any
## files the legacy directories hold into the new one.
##
## Guarantees:
## - never overwrites a file that already exists in the new directory;
## - never deletes or modifies a legacy directory;
## - safe to run on every startup (a marker file limits it to one full pass);
## - copying is per-file, so an interrupted migration resumes cleanly;
## - runs before any other autoload reads or writes user://.

const MARKER_FILE := ".migration_from_griddycode"
const LEGACY_DIR_NAMES := ["Bussin GriddyCode", "GriddyCode"]

func _ready() -> void:
	_migrate_legacy_user_dir()

func _migrate_legacy_user_dir() -> void:
	# globalize_path("user://") returns a trailing slash; strip it or
	# get_base_dir() would name the new directory instead of its parent.
	var current := ProjectSettings.globalize_path("user://").trim_suffix("/")
	var base := current.get_base_dir()
	if FileAccess.file_exists(current.path_join(MARKER_FILE)):
		return
	if DirAccess.make_dir_recursive_absolute(current) != OK:
		push_warning("Qorix: could not create the user data directory at %s" % current)
		return
	var copied := 0
	var legacy_found := false
	for legacy_name in LEGACY_DIR_NAMES:
		var legacy := base.path_join(legacy_name)
		if legacy == current:
			continue
		if !DirAccess.dir_exists_absolute(legacy):
			continue
		legacy_found = true
		copied += _copy_missing_recursive(legacy, current)
	if legacy_found:
		# Only mark the pass complete when a legacy directory was actually seen;
		# otherwise stay cheap to re-check on the next launch.
		_write_marker(current, copied)
		if copied == 0:
			print("Qorix: legacy GriddyCode data directory found; the new directory is already up to date.")
	if copied > 0:
		print("Qorix: migrated %d file(s) from a legacy GriddyCode data directory." % copied)

## Copies files that are missing in `to_dir` from `from_dir`, recursively.
## Returns the number of files copied. Existing files in `to_dir` are kept.
func _copy_missing_recursive(from_dir: String, to_dir: String) -> int:
	var copied := 0
	var open_dir := DirAccess.open(from_dir)
	if open_dir == null:
		push_warning("Qorix: could not read legacy data directory %s" % from_dir)
		return 0
	open_dir.include_hidden = true
	open_dir.list_dir_begin()
	var entry := open_dir.get_next()
	while entry != "":
		if entry != "." and entry != "..":
			var from_path := from_dir.path_join(entry)
			var to_path := to_dir.path_join(entry)
			if open_dir.current_is_dir():
				if DirAccess.make_dir_recursive_absolute(to_path) == OK:
					copied += _copy_missing_recursive(from_path, to_path)
			else:
				if !FileAccess.file_exists(to_path):
					if DirAccess.copy_absolute(from_path, to_path) == OK:
						copied += 1
					else:
						push_warning("Qorix: could not migrate %s" % from_path)
		entry = open_dir.get_next()
	open_dir.list_dir_end()
	return copied

func _write_marker(current: String, copied: int) -> void:
	var file := FileAccess.open(current.path_join(MARKER_FILE), FileAccess.WRITE)
	if file == null:
		push_warning("Qorix: could not write the migration marker in %s" % current)
		return
	file.store_string("Qorix user data migration marker.\nMigrated %d file(s) from a legacy GriddyCode directory on first launch.\n" % copied)
	file.close()
