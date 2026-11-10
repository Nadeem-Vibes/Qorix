extends TestCase

## Permission catalogue, consent records and the runtime active set.

const Permissions = preload("res://src/features/mods/mod_permissions.gd")

const ROOT := "user://griddy_mod_tests/permissions"


func before_each() -> void:
	_clean(ROOT)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ROOT))


func after_each() -> void:
	_clean(ROOT)


func _service():
	var service = Permissions.new(ROOT + "/mod_permissions.json")
	service.load_records()
	return service


func _clean(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir != null:
		for name in dir.get_files():
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path.path_join(str(name))))
		for name in dir.get_directories():
			_clean(path.path_join(str(name)))
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path.path_join(str(name))))
	var absolute := ProjectSettings.globalize_path(path)
	if DirAccess.dir_exists_absolute(absolute):
		DirAccess.remove_absolute(absolute)


func test_catalogue() -> void:
	var names := Permissions.available_names()
	check(names.has("core"), "core is available")
	check(names.has("documents.read"), "documents.read is available")
	check(names.has("run"), "run is available")
	check(!names.has("network"), "network is not in v1")
	check(!names.has("input.observe"), "input.observe is not in v1")
	check(Permissions.requires_trust("run"), "run needs trust")
	check(!Permissions.requires_trust("documents.read"), "documents.read does not")
	assert_eq(Permissions.sensitive(["core", "documents.read", "run"]), ["documents.read", "run"])


func test_validate() -> void:
	var service = _service()

	var unknown: Dictionary = service.validate(["core", "made.up"])
	check(!unknown.get("ok", false), "unknown permission fails")
	assert_eq(str((unknown["errors"][0] as Dictionary).get("code")), "permission.unknown")

	var reserved: Dictionary = service.validate(["core", "network"])
	check(!reserved.get("ok", false), "reserved permission fails")

	var implicit: Dictionary = service.validate([])
	check(implicit.get("ok", false), "empty list is valid")
	check((implicit.get("permissions", []) as Array).has("core"), "core is added")


func test_consent_lifecycle() -> void:
	var service = _service()
	var permissions := ["core", "documents.read"]

	var missing: Dictionary = service.consent_status("com.example.mod", "1.0.0", "hash-a", permissions)
	check(!missing.get("granted", false), "no record blocks")
	assert_eq(missing.get("missing"), ["documents.read"])
	assert_eq(missing.get("reason"), "no_record")

	var granted: Dictionary = service.grant("com.example.mod", "1.0.0", "hash-a", permissions)
	check(granted.get("ok", false), "grant saves")

	var ok: Dictionary = service.consent_status("com.example.mod", "1.0.0", "hash-a", permissions)
	check(ok.get("granted", false), "record grants")
	check(!ok.get("refresh", false), "same identity needs no refresh")

	var updated: Dictionary = service.consent_status("com.example.mod", "1.1.0", "hash-b", permissions)
	check(updated.get("granted", false), "same permissions stay granted across an update")
	check(updated.get("refresh", false), "identity refresh is requested")

	var grown: Dictionary = service.consent_status("com.example.mod", "1.1.0", "hash-b", ["core", "documents.read", "run"])
	check(!grown.get("granted", false), "new sensitive permission needs consent")
	assert_eq(grown.get("missing"), ["run"])
	assert_eq(grown.get("reason"), "permission_growth")


func test_core_needs_no_record() -> void:
	var service = _service()
	var status: Dictionary = service.consent_status("com.example.core", "1.0.0", "hash", ["core"])
	check(status.get("granted", false), "core-only mod activates")
	check((status.get("missing", []) as Array).is_empty(), "nothing missing")


func test_active_set_and_runtime_checks() -> void:
	var service = _service()
	service.grant("com.example.mod", "1.0.0", "hash", ["core", "documents.read"])

	check(!service.has("com.example.mod", "documents.read"), "nothing is active before activation")

	service.set_active("com.example.mod", ["core", "documents.read"])
	check(service.has("com.example.mod", "documents.read"), "active permission")
	check(service.has("com.example.mod", "core"), "core is always true")
	check(!service.has("com.example.mod", "run"), "ungranted permission stays false")

	service.clear_active("com.example.mod")
	check(!service.has("com.example.mod", "documents.read"), "runtime permission is cleared")
	check(!service.record("com.example.mod").is_empty(), "consent record remains after the session")


func test_persistence_and_revoke() -> void:
	var first = _service()
	first.grant("com.example.mod", "1.0.0", "hash", ["core", "documents.read"])

	var second = _service()
	assert_eq(second.record("com.example.mod").get("version"), "1.0.0")
	check((second.record("com.example.mod").get("permissions", []) as Array).has("documents.read"), "record survives reload")

	second.revoke("com.example.mod")
	check(second.record("com.example.mod").is_empty(), "revoked")

	var third = _service()
	check(third.record("com.example.mod").is_empty(), "revocation persists")


func test_malformed_records_do_not_crash() -> void:
	FileStore.save(ROOT + "/mod_permissions.json", "not json")
	var service = _service()
	check(service.all_records().is_empty(), "malformed file resets records")
	check(!service.last_error.is_empty(), "error is reported")
