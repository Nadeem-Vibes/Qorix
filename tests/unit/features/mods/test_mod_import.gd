extends TestCase

## Phase 6 manager integration: the Mods page talks to ModManager, so this suite
## covers the whole import path against real user:// roots — review, publisher
## trust, consent growth, update, rollback and uninstall — including whether the
## imported Lua mod actually activates.

const ManagerScript = preload("res://src/features/mods/mod_manager.gd")
const RegistryScript = preload("res://src/platform/command_registry.gd")
const KeybindingScript = preload("res://src/platform/keybinding_service.gd")
const TrustScript = preload("res://src/platform/trust_service.gd")
const Result = preload("res://src/features/mods/mod_result.gd")
const Fixture = preload("res://tests/support/mod_package_fixture.gd")

const ROOT := "user://griddy_mod_tests/import"
const MOD_ID := "griddycode.imported"
const PUBLISHER := "griddycode.importpublisher"
const SEED := "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"

var _package_seq: int = 0


func before_each() -> void:
	_clean(ROOT)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ROOT + "/packages"))


func after_each() -> void:
	_clean(ROOT)


# ── SIGNED END-TO-END IMPORT ────────────────────────────────────────────────

func test_signed_import_trust_activation_and_restart() -> void:
	var made := _package(MOD_ID, "1.0.0", [], PUBLISHER)
	check(made.get("ok", false), "signed fixture builds: " + str(made.get("error", [])))
	if !made.get("ok", false):
		return
	var path := str(made["path"])

	var manager = _make()
	manager.start()

	var inspected: Dictionary = manager.inspect_package(path)
	check(inspected.get("ok", false), "review succeeds")
	var review: Dictionary = _value(inspected)
	assert_eq(str(_dict(review, "publisher").get("status", "")), "new", "first package is an unknown publisher")
	assert_false(bool(review.get("can_install", true)), "review blocks the install")
	assert_eq(manager.installed().size(), 0, "review installed nothing")

	var refused: Dictionary = manager.import_package(path)
	assert_eq(Result.code_of(refused), "publisher.trust_required", "import requires trust")
	assert_eq(manager.installed().size(), 0, "refused import installed nothing")

	var imported: Dictionary = manager.import_package(path, {"trust_publisher": true})
	check(imported.get("ok", false), "trusted import succeeds: " + str(imported))
	var outcome: Dictionary = _value(imported)
	assert_true(bool(outcome.get("activated", false)), "imported mod activated")
	assert_eq(str(_state(manager, MOD_ID).get("status", "")), "active", "state is active")

	var installed := _installed_entry(manager, MOD_ID)
	check(!installed.is_empty(), "manager lists the installed mod")
	assert_eq(str(installed.get("version", "")), "1.0.0", "installed version")
	assert_eq(str(installed.get("publisher_id", "")), PUBLISHER, "publisher shown")
	assert_eq(str(installed.get("signature_status", "")), "valid", "signature shown as valid")
	var signature: Dictionary = _dict(installed, "signature")
	assert_true(bool(signature.get("ok", false)), "signature metadata is valid")
	assert_eq(str(installed.get("previous_version", "")), "", "no previous version on first install")

	var registry_entry: Dictionary = manager.registry.entry(MOD_ID)
	assert_eq(str(registry_entry.get("version", "")), "1.0.0", "registry records the import")
	assert_true(bool(_dict(registry_entry, "signature").get("present", false)), "registry stores the signature")

	assert_eq(manager.pending_consents().size(), 0, "no consent needed for core-only")
	assert_eq(manager.trusted_publishers().size(), 1, "publisher pinned")
	var report: Dictionary = manager.status_report()
	assert_eq(_array(report, "publishers").size(), 1, "status report lists the publisher")
	assert_false(bool(report.get("allow_unsigned", true)), "unsigned imports are off by default")
	manager.stop()

	# A restart must re-read the active version and the pinned publisher.
	var restarted = _make()
	restarted.start()
	assert_eq(str(_state(restarted, MOD_ID).get("status", "")), "active", "trusted import reactivates after restart")
	var reloaded := _installed_entry(restarted, MOD_ID)
	assert_eq(str(reloaded.get("publisher_id", "")), PUBLISHER, "publisher survives restart")
	assert_eq(str(reloaded.get("signature_status", "")), "valid", "signature still validates after restart")
	restarted.stop()


func test_unsigned_import_needs_the_manager_opt_in() -> void:
	var made := _package(MOD_ID, "1.0.0")
	var path := str(made["path"])
	var manager = _make()
	manager.start()

	var inspected: Dictionary = manager.inspect_package(path)
	var review: Dictionary = _value(inspected)
	check(_has_code(_array(review, "blockers"), "signature.required"), "manager review blocks unsigned")
	var refused: Dictionary = manager.import_package(path)
	assert_eq(Result.code_of(refused), "signature.required", "manager refuses unsigned without opt-in")
	assert_eq(manager.installed().size(), 0, "nothing was installed")

	var imported: Dictionary = manager.import_package(path, {"allow_unsigned": true})
	check(imported.get("ok", false), "explicit opt-in imports the package: " + str(imported))
	var installed := _installed_entry(manager, MOD_ID)
	assert_true(bool(installed.get("allow_unsigned", false)), "installed entry records the opt-in")
	assert_eq(str(installed.get("signature_status", "")), "unsigned", "no signature is claimed")
	manager.stop()


# ── CONSENT GROWTH ──────────────────────────────────────────────────────────

func test_permission_growth_blocks_then_consent_activates() -> void:
	var manager = _make(true)
	manager.start()

	var path_100 := str(_package(MOD_ID, "1.0.0", ["documents.read"])["path"])
	var imported: Dictionary = manager.import_package(path_100, {"allow_unsigned": true})
	check(imported.get("ok", false), "first import installs: " + str(imported))
	var outcome: Dictionary = _value(imported)
	assert_false(bool(outcome.get("activated", true)), "sensitive mod waits for consent")
	assert_eq(str(_dict(outcome, "activation_error").get("code", "")), "permission.consent_required", "consent error")
	assert_eq(str(_state(manager, MOD_ID).get("status", "")), "blocked", "state is blocked")
	check(_array(_state(manager, MOD_ID), "missing_permissions").has("documents.read"), "missing permission named")
	assert_eq(manager.pending_consents().size(), 1, "consent is queued")

	var granted: Dictionary = manager.grant_consent(MOD_ID)
	check(granted.get("ok", false), "grant activates the mod")
	assert_eq(str(_state(manager, MOD_ID).get("status", "")), "active", "mod is active after consent")
	assert_true(manager.permissions.active_permissions(MOD_ID).has("documents.read"), "permission is live")

	var path_110 := str(_package(MOD_ID, "1.1.0", ["documents.read", "files.read"])["path"])
	var reviewed: Dictionary = manager.inspect_package(path_110, {"allow_unsigned": true})
	var growth: Dictionary = _dict(_value(reviewed), "permission_growth")
	assert_eq(_array(growth, "added"), ["files.read"], "growth review names the new permission")
	assert_false(bool(_value(reviewed).get("can_activate", true)), "growth cannot activate without consent")

	var grown_import: Dictionary = manager.import_package(path_110, {"allow_unsigned": true})
	check(grown_import.get("ok", false), "update installs: " + str(grown_import))
	var grown: Dictionary = _value(grown_import)
	assert_false(bool(grown.get("activated", true)), "update waits for re-consent")
	assert_eq(str(_state(manager, MOD_ID).get("status", "")), "blocked", "updated mod is blocked")
	check(_array(_state(manager, MOD_ID), "missing_permissions").has("files.read"), "new permission is missing")
	assert_eq(str(_installed_entry(manager, MOD_ID).get("version", "")), "1.1.0", "new version is on disk")

	check(manager.grant_consent(MOD_ID).get("ok", false), "re-consent activates the update")
	assert_true(manager.permissions.active_permissions(MOD_ID).has("files.read"), "grown permission is live")
	assert_eq(manager.pending_consents().size(), 0, "no consent left pending")

	var path_120 := str(_package(MOD_ID, "1.2.0", ["documents.read", "files.read"])["path"])
	var same_import: Dictionary = manager.import_package(path_120, {"allow_unsigned": true})
	check(same_import.get("ok", false), "later update installs: " + str(same_import))
	assert_true(bool(_value(same_import).get("activated", false)), "unchanged permissions activate without a prompt")
	assert_eq(str(_installed_entry(manager, MOD_ID).get("version", "")), "1.2.0", "1.2.0 is active")
	manager.stop()


# ── UPDATE, ROLLBACK AND UNINSTALL ──────────────────────────────────────────

func test_update_reactivates_and_rollback_restores() -> void:
	var manager = _make(true)
	manager.start()

	var path_100 := str(_package(MOD_ID, "1.0.0")["path"])
	var path_110 := str(_package(MOD_ID, "1.1.0")["path"])
	check(manager.import_package(path_100, {"allow_unsigned": true}).get("ok", false), "1.0.0 imports")
	assert_eq(str(_state(manager, MOD_ID).get("status", "")), "active", "1.0.0 is active")

	var updated: Dictionary = manager.import_package(path_110, {"allow_unsigned": true})
	check(updated.get("ok", false), "1.1.0 updates the running mod: " + str(updated))
	assert_true(bool(_value(updated).get("activated", false)), "updated mod is reactivated")
	assert_eq(str(_state(manager, MOD_ID).get("status", "")), "active", "state stays active")
	assert_eq(str(_state(manager, MOD_ID).get("version", "")), "1.1.0", "state reports 1.1.0")
	var installed := _installed_entry(manager, MOD_ID)
	assert_eq(str(installed.get("previous_version", "")), "1.0.0", "previous version recorded")
	check(_exists(ROOT + "/mods/" + MOD_ID + "/1.0.0"), "old version folder kept")
	check(_exists(ROOT + "/mods/" + MOD_ID + "/1.1.0"), "new version folder written")

	var rolled: Dictionary = manager.rollback_mod(MOD_ID)
	check(rolled.get("ok", false), "rollback succeeds: " + str(rolled))
	assert_true(bool(_value(rolled).get("activated", false)), "rolled-back version activates")
	assert_eq(str(_state(manager, MOD_ID).get("version", "")), "1.0.0", "state reports the restored version")
	assert_eq(str(_installed_entry(manager, MOD_ID).get("version", "")), "1.0.0", "installed list follows the rollback")
	assert_eq(
		str(manager.registry.entry(MOD_ID).get("previous_version", "")),
		"1.1.0",
		"rollback makes 1.1.0 the previous version"
	)

	var downgrade := str(_package(MOD_ID, "0.9.0")["path"])
	var refused: Dictionary = manager.import_package(downgrade, {"allow_unsigned": true})
	assert_eq(Result.code_of(refused), "update.downgrade", "downgrade is refused")
	assert_eq(str(_state(manager, MOD_ID).get("version", "")), "1.0.0", "active version is unchanged")

	var fresh_id := "griddycode.fresh"
	var fresh := str(_package(fresh_id, "1.0.0")["path"])
	check(manager.import_package(fresh, {"allow_unsigned": true}).get("ok", false), "fresh mod imports")
	var no_previous: Dictionary = manager.rollback_mod(fresh_id)
	assert_eq(Result.code_of(no_previous), "update.no_previous", "fresh install has nothing to roll back to")
	assert_eq(str(_state(manager, fresh_id).get("status", "")), "active", "failed rollback leaves the mod running")
	manager.stop()


func test_uninstall_removes_runtime_and_keeps_data() -> void:
	var manager = _make(true)
	manager.start()

	var path_100 := str(_package(MOD_ID, "1.0.0", ["documents.read"])["path"])
	check(manager.import_package(path_100, {"allow_unsigned": true, "consent": true}).get("ok", false), "mod imports")
	assert_eq(str(_state(manager, MOD_ID).get("status", "")), "active", "mod is running")

	var data_dir := ROOT + "/data/" + MOD_ID
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(data_dir))
	var handle := FileAccess.open(data_dir + "/state.json", FileAccess.WRITE)
	handle.store_string("{\"kept\":true}")
	handle.close()

	var removed: Dictionary = manager.uninstall_mod(MOD_ID)
	check(removed.get("ok", false), "uninstall succeeds: " + str(removed))
	var summary: Dictionary = _value(removed)
	assert_true(bool(summary.get("data_kept", false)), "data kept by default")
	assert_false(bool(summary.get("data_removed", true)), "data not deleted")
	check(manager.host(MOD_ID) == null, "Lua host torn down")
	assert_true(_state(manager, MOD_ID).is_empty(), "runtime state removed")
	assert_eq(manager.installed().size(), 0, "installed list is empty")
	check(!_exists(ROOT + "/mods/" + MOD_ID), "mod folder removed")
	assert_true(manager.permissions.record(MOD_ID).is_empty(), "consent revoked")
	check(FileAccess.file_exists(data_dir + "/state.json"), "kept data file survived")

	check(manager.import_package(path_100, {"allow_unsigned": true, "consent": true}).get("ok", false), "reinstall works")
	var wiped: Dictionary = manager.uninstall_mod(MOD_ID, {"remove_data": true})
	check(wiped.get("ok", false), "uninstall with remove_data succeeds")
	assert_true(bool(_value(wiped).get("data_removed", false)), "data removal reported")
	check(!_exists(data_dir), "data folder removed")

	var escaped: Dictionary = manager.uninstall_mod("../escape")
	assert_eq(Result.code_of(escaped), "path.outside_workspace", "unsafe mod id rejected")
	manager.stop()


# ── FIXTURES AND HELPERS ────────────────────────────────────────────────────

func _make(allow_unsigned: bool = false):
	var command_registry = RegistryScript.new()
	var keybindings = KeybindingScript.new()
	keybindings.setup(command_registry)

	var manager = ManagerScript.new()
	manager.setup({
		"mods_root": ROOT + "/mods",
		"data_root": ROOT + "/data",
		"registry_path": ROOT + "/mod_registry.json",
		"permissions_path": ROOT + "/mod_permissions.json",
		"session_path": ROOT + "/mod_session.json",
		"publishers_path": ROOT + "/mod_publishers.json",
		"staging_root": ROOT + "/staging",
		"command_registry": command_registry,
		"keybinding_service": keybindings,
		"trust_service": TrustScript.new(),
		"editor_version": "1.4.0",
		"developer_mode": false,
		"allow_unsigned": allow_unsigned,
	})
	return manager


func _package(
	id: String,
	version: String,
	permissions: Array = [],
	publisher: String = "",
	seed_hex: String = SEED,
	extra_manifest: Dictionary = {}
) -> Dictionary:
	_package_seq += 1
	var manifest_data := Fixture.manifest(id, version, permissions, extra_manifest)
	var file_map := Fixture.files(manifest_data)
	var file_name := "%s-%s-%03d.gcm" % [id.get_file(), version, _package_seq]
	if publisher.is_empty():
		return {
			"ok": true,
			"path": Fixture.write_zip(ROOT + "/packages", file_name, file_map),
			"signature": {},
		}
	return Fixture.write_signed_zip(ROOT + "/packages", file_name, file_map, publisher, seed_hex)


func _state(manager, id: String) -> Dictionary:
	var found: Variant = manager.state(id)
	return found if found is Dictionary else {}


func _installed_entry(manager, id: String) -> Dictionary:
	for item in manager.installed():
		if item is Dictionary and str((item as Dictionary).get("id", "")) == id:
			return (item as Dictionary).duplicate(true)
	return {}


func _value(result: Dictionary) -> Dictionary:
	var value: Variant = result.get("value", {})
	return value if value is Dictionary else {}


func _dict(source: Dictionary, key: String) -> Dictionary:
	var value: Variant = source.get(key, {})
	return value if value is Dictionary else {}


func _array(source: Dictionary, key: String) -> Array:
	var value: Variant = source.get(key, [])
	return value if value is Array else []


func _has_code(items: Array, code: String) -> bool:
	for item in items:
		if item is Dictionary and str((item as Dictionary).get("code", "")) == code:
			return true
	return false


func _exists(path: String) -> bool:
	return DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(path))


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
