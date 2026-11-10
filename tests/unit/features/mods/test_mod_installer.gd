extends TestCase

## Phase 6 installer lifecycle: publisher trust and pinning, unsigned opt-in,
## version policy, permission-growth review, rollback byte verification and
## uninstall data retention. Every package here is built by the shared fixture
## so the suite exercises the same validation path as a real import.

const Installer = preload("res://src/features/mods/mod_installer.gd")
const Registry = preload("res://src/features/mods/mod_registry.gd")
const Permissions = preload("res://src/features/mods/mod_permissions.gd")
const Publishers = preload("res://src/features/mods/mod_publishers.gd")
const Result = preload("res://src/features/mods/mod_result.gd")
const Fixture = preload("res://tests/support/mod_package_fixture.gd")

const ROOT := "user://griddy_mod_tests/installer"
const MOD_ID := "griddycode.installer"
const PUBLISHER := "griddycode.testpublisher"
const PUBLISHERS_PATH := ROOT + "/mod_publishers.json"

# RFC 8032 test-vector seeds: the first is also the fixture default.
const SEED_A := "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"
const SEED_B := "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb"

var _package_seq: int = 0


func before_each() -> void:
	_clean(ROOT)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ROOT + "/packages"))


func after_each() -> void:
	_clean(ROOT)


# ── SIGNED IMPORT AND PUBLISHER TRUST ───────────────────────────────────────

func test_inspect_is_side_effect_free_and_trust_gates_install() -> void:
	var made := _package(MOD_ID, "1.0.0", [], PUBLISHER)
	check(made.get("ok", false), "signed fixture builds: " + str(made.get("error", [])))
	if !made.get("ok", false):
		return
	var path := str(made["path"])

	var installer = _installer()
	var inspected: Dictionary = installer.inspect(path)
	check(inspected.get("ok", false), "inspect succeeds: " + str(inspected))
	var review: Dictionary = _value(inspected)
	check(!bool(review.get("can_install", true)), "a new publisher is blocked")
	check(_has_code(_array(review, "blockers"), "publisher.trust_required"), "trust blocker named")
	var publisher: Dictionary = _dict(review, "publisher")
	assert_eq(str(publisher.get("status", "")), "new", "publisher state is new")
	assert_true(bool(publisher.get("requires_trust", false)), "publisher needs trust")
	assert_eq(str(publisher.get("publisher_id", "")), PUBLISHER, "publisher id shown")
	assert_eq(str(publisher.get("fingerprint", "")).length(), 64, "fingerprint is SHA-256 sized")
	check(!_exists(ROOT + "/mods/" + MOD_ID), "inspect extracted nothing")
	check(!FileAccess.file_exists(PUBLISHERS_PATH), "inspect did not pin the key")
	check(!FileAccess.file_exists(ROOT + "/mod_registry.json"), "inspect did not write the registry")

	var approved: Dictionary = installer.inspect(path, {"trust_publisher": true})
	var approved_review: Dictionary = _value(approved)
	assert_true(bool(approved_review.get("can_install", false)), "explicit approval makes it installable")
	check(!FileAccess.file_exists(PUBLISHERS_PATH), "inspect approval is not persisted")

	var refused: Dictionary = installer.install(path)
	assert_eq(Result.code_of(refused), "publisher.trust_required", "install requires trust")
	check(!_exists(ROOT + "/mods/" + MOD_ID), "refused install extracted nothing")

	var installed: Dictionary = installer.install(path, {"trust_publisher": true})
	check(installed.get("ok", false), "trusted install succeeds: " + str(installed))
	var details: Dictionary = _value(installed)
	assert_eq(str(details.get("version", "")), "1.0.0", "installed version")
	check(_exists(ROOT + "/mods/" + MOD_ID + "/1.0.0"), "version folder written")
	assert_eq(_entry_count(ROOT + "/staging"), 0, "staging is empty after install")

	var entry: Dictionary = installer.registry.entry(MOD_ID)
	assert_eq(str(entry.get("version", "")), "1.0.0", "registry records the active version")
	assert_eq(str(entry.get("hash", "")), str(details.get("hash", "")), "registry records the digest")
	var signature: Dictionary = _dict(entry, "signature")
	assert_true(bool(signature.get("present", false)), "signature metadata stored")
	assert_true(bool(signature.get("ok", false)), "signature marked valid")
	assert_eq(str(signature.get("publisher_id", "")), PUBLISHER, "registry records the publisher")

	var stored: Dictionary = installer.publishers.get_publisher(PUBLISHER)
	assert_eq(str(stored.get("fingerprint", "")), str(signature.get("fingerprint", "")), "publisher key pinned")

	var reloaded = Publishers.new(PUBLISHERS_PATH)
	reloaded.load_store()
	check(reloaded.is_trusted(signature), "trust survives a store reload")


func test_trusted_publisher_and_key_change_retrust() -> void:
	var first := _package(MOD_ID, "1.0.0", [], PUBLISHER, SEED_A)
	check(first.get("ok", false), "first signed fixture builds")
	if !first.get("ok", false):
		return

	var installer = _installer()
	check(installer.install(str(first["path"]), {"trust_publisher": true}).get("ok", false), "baseline installs")
	var baseline: Dictionary = installer.publishers.get_publisher(PUBLISHER)
	var baseline_fingerprint := str(baseline.get("fingerprint", ""))
	assert_eq(baseline_fingerprint.length(), 64, "baseline key pinned")

	var second := _package(MOD_ID, "1.1.0", [], PUBLISHER, SEED_A)
	check(second.get("ok", false), "same-key fixture builds")
	var trusted: Dictionary = installer.inspect(str(second["path"]))
	var trusted_review: Dictionary = _value(trusted)
	assert_eq(str(_dict(trusted_review, "publisher").get("status", "")), "trusted", "same key is trusted")
	assert_true(bool(trusted_review.get("can_install", false)), "trusted update needs no prompt")

	var changed := _package(MOD_ID, "1.2.0", [], PUBLISHER, SEED_B)
	check(changed.get("ok", false), "new-key fixture builds")
	var changed_inspect: Dictionary = installer.inspect(str(changed["path"]))
	var changed_review: Dictionary = _value(changed_inspect)
	assert_eq(str(_dict(changed_review, "publisher").get("status", "")), "key_changed", "new key is flagged")
	check(_has_code(_array(changed_review, "blockers"), "publisher.key_changed"), "key change blocker named")

	var refused: Dictionary = installer.install(str(changed["path"]), {"trust_publisher": true})
	assert_eq(Result.code_of(refused), "publisher.key_changed", "replace_key is required")
	check(!_exists(ROOT + "/mods/" + MOD_ID + "/1.2.0"), "key change refused before extraction")
	assert_eq(
		str(installer.publishers.get_publisher(PUBLISHER).get("fingerprint", "")),
		baseline_fingerprint,
		"refused key change left the pin untouched"
	)

	var replaced: Dictionary = installer.install(str(changed["path"]), {
		"trust_publisher": true,
		"replace_key": true,
	})
	check(replaced.get("ok", false), "re-trusted install succeeds: " + str(replaced))
	var updated: Dictionary = installer.publishers.get_publisher(PUBLISHER)
	assert_ne(str(updated.get("fingerprint", "")), baseline_fingerprint, "signing key replaced")
	assert_eq(str(updated.get("previous_fingerprint", "")), baseline_fingerprint, "old key recorded")
	check(int(updated.get("key_changed_at", 0)) > 0, "key change timestamp recorded")
	assert_eq(
		str(_dict(installer.registry.entry(MOD_ID), "signature").get("fingerprint", "")),
		str(updated.get("fingerprint", "")),
		"registry records the new key"
	)


func test_invalid_signature_is_never_installable() -> void:
	var made := _package(MOD_ID, "1.0.0", [], PUBLISHER, SEED_A)
	check(made.get("ok", false), "baseline signed fixture builds")
	if !made.get("ok", false):
		return

	# Keep the original signature but change the code it covers.
	var signature: Dictionary = _dict(made, "signature")
	var tampered := Fixture.files(Fixture.manifest(MOD_ID, "1.0.0", []))
	tampered["main.lua"] = "return \"tampered\"\n".to_utf8_buffer()
	tampered["signature.json"] = JSON.stringify(signature).to_utf8_buffer()
	var path := Fixture.write_zip(ROOT + "/packages", "tampered.gcm", tampered)

	var installer = _installer()
	var inspected: Dictionary = installer.inspect(path, {"trust_publisher": true, "replace_key": true})
	assert_false(bool(inspected.get("ok", true)), "invalid signature fails validation")
	assert_eq(Result.code_of(inspected), "package.invalid", "inspect rejects the package")
	var failure: Dictionary = _dict(inspected, "error")
	var details: Dictionary = _dict(failure, "details")
	check(_has_code(_array(details, "errors"), "signature.invalid"), "signature error named")

	var refused: Dictionary = installer.install(path, {"trust_publisher": true, "replace_key": true})
	assert_false(bool(refused.get("ok", true)), "install refuses the tampered package")
	check(!_exists(ROOT + "/mods/" + MOD_ID), "nothing was extracted")
	check(!FileAccess.file_exists(PUBLISHERS_PATH), "invalid signature never pins a publisher")
	check(!FileAccess.file_exists(ROOT + "/mod_registry.json"), "invalid signature never writes the registry")


func test_unsigned_import_requires_explicit_opt_in() -> void:
	var made := _package(MOD_ID, "1.0.0")
	var path := str(made["path"])
	var installer = _installer()

	var inspected: Dictionary = installer.inspect(path)
	check(inspected.get("ok", false), "unsigned archive is structurally valid")
	var review: Dictionary = _value(inspected)
	assert_true(bool(review.get("unsigned", false)), "review marks the package unsigned")
	check(_has_code(_array(review, "blockers"), "signature.required"), "unsigned is blocked by default")
	assert_false(bool(review.get("can_install", true)), "cannot install without opt-in")

	var refused: Dictionary = installer.install(path)
	assert_eq(Result.code_of(refused), "signature.required", "install honors the default policy")
	check(!_exists(ROOT + "/mods/" + MOD_ID), "unsigned refusal extracted nothing")

	var allowed: Dictionary = installer.inspect(path, {"allow_unsigned": true})
	var allowed_review: Dictionary = _value(allowed)
	check(_has_code(_array(allowed_review, "warnings"), "signature.unsigned"), "opt-in warns about origin")
	assert_true(bool(allowed_review.get("can_install", false)), "opt-in is installable")

	var installed: Dictionary = installer.install(path, {"allow_unsigned": true})
	check(installed.get("ok", false), "unsigned install with opt-in: " + str(installed))
	var entry: Dictionary = installer.registry.entry(MOD_ID)
	assert_true(bool(entry.get("allow_unsigned", false)), "registry records the opt-in")
	assert_false(bool(_dict(entry, "signature").get("present", true)), "no signature stored")


# ── VERSION POLICY ──────────────────────────────────────────────────────────

func test_update_replace_and_downgrade_policy() -> void:
	var installer = _installer(true)
	var path_100 := str(_package(MOD_ID, "1.0.0")["path"])
	var first: Dictionary = installer.install(path_100)
	check(first.get("ok", false), "1.0.0 installs: " + str(first))
	var hash_100 := str(_value(first).get("hash", ""))

	var path_090 := str(_package(MOD_ID, "0.9.0")["path"])
	var older_inspect: Dictionary = installer.inspect(path_090)
	var older: Dictionary = _value(older_inspect)
	assert_eq(str(_dict(older, "update").get("kind", "")), "downgrade", "older version detected")
	check(_has_code(_array(older, "blockers"), "update.downgrade"), "downgrade blocked by default")
	assert_false(bool(older.get("can_install", true)), "cannot install a downgrade")
	var refused_older: Dictionary = installer.install(path_090)
	assert_eq(Result.code_of(refused_older), "update.downgrade", "install refuses the downgrade")

	var path_110 := str(_package(MOD_ID, "1.1.0")["path"])
	var newer_inspect: Dictionary = installer.inspect(path_110)
	var newer: Dictionary = _value(newer_inspect)
	var update: Dictionary = _dict(newer, "update")
	assert_eq(str(update.get("kind", "")), "update", "newer version detected")
	assert_eq(str(update.get("current_version", "")), "1.0.0", "current version reported")
	assert_true(bool(newer.get("can_install", false)), "update is installable")

	var second: Dictionary = installer.install(path_110)
	check(second.get("ok", false), "1.1.0 installs: " + str(second))
	check(_exists(ROOT + "/mods/" + MOD_ID + "/1.0.0"), "old version folder kept for rollback")
	check(_exists(ROOT + "/mods/" + MOD_ID + "/1.1.0"), "new version folder written")
	var entry: Dictionary = installer.registry.entry(MOD_ID)
	assert_eq(str(entry.get("version", "")), "1.1.0", "registry active version advanced")
	var previous: Dictionary = _dict(entry, "previous")
	assert_eq(str(previous.get("version", "")), "1.0.0", "previous snapshot recorded")
	assert_eq(str(previous.get("hash", "")), hash_100, "previous snapshot keeps the old digest")

	# Reinstalling the exact same bytes is a reinstall, not an update.
	var same_inspect: Dictionary = installer.inspect(path_110)
	var same: Dictionary = _value(same_inspect)
	assert_eq(str(_dict(same, "update").get("kind", "")), "reinstall", "identical version is a reinstall")
	check(_has_code(_array(same, "blockers"), "update.exists"), "existing target needs explicit replace")
	var refused_same: Dictionary = installer.install(path_110)
	assert_eq(Result.code_of(refused_same), "update.exists", "reinstall is refused without replace")

	# Same version, different bytes: replace keeps the previous update target.
	var replacement_path := str(_package(MOD_ID, "1.1.0", [], "", SEED_A, {
		"description": "A replaced build used by the installer tests.",
	})["path"])
	var replacement_inspect: Dictionary = installer.inspect(replacement_path)
	var replacement: Dictionary = _value(replacement_inspect)
	assert_eq(str(_dict(replacement, "update").get("kind", "")), "replace", "changed same-version is a replace")
	var replaced: Dictionary = installer.install(replacement_path, {"replace": true})
	check(replaced.get("ok", false), "replace installs: " + str(replaced))
	entry = installer.registry.entry(MOD_ID)
	assert_eq(str(entry.get("version", "")), "1.1.0", "active version stays 1.1.0")
	assert_eq(str(_dict(entry, "previous").get("version", "")), "1.0.0", "replace keeps the rollback target")
	assert_ne(str(entry.get("hash", "")), hash_100, "replacement changed the active digest")

	# allow_downgrade is explicit and applies to a fresh id.
	var downgrade_id := "griddycode.downgrade"
	var high_path := str(_package(downgrade_id, "2.0.0")["path"])
	check(installer.install(high_path).get("ok", false), "downgrade fixture installs 2.0.0")
	var low_path := str(_package(downgrade_id, "1.0.0")["path"])
	var downgraded: Dictionary = installer.install(low_path, {"allow_downgrade": true})
	check(downgraded.get("ok", false), "allow_downgrade permits the older version: " + str(downgraded))
	assert_eq(str(installer.registry.entry(downgrade_id).get("version", "")), "1.0.0", "older version became active")


# ── PERMISSION GROWTH ───────────────────────────────────────────────────────

func test_permission_growth_requires_reconsent() -> void:
	var installer = _installer(true)
	var path_100 := str(_package(MOD_ID, "1.0.0", ["documents.read"])["path"])
	var first_inspect: Dictionary = installer.inspect(path_100)
	var first: Dictionary = _value(first_inspect)
	var first_growth: Dictionary = _dict(first, "permission_growth")
	assert_true(bool(first_growth.get("first_consent", false)), "first consent flagged")
	assert_true(bool(first_growth.get("requires_consent", false)), "sensitive permission needs consent")
	assert_eq(_array(first_growth, "added"), ["documents.read"], "added permission named")
	assert_false(bool(first.get("can_activate", true)), "activation waits for consent")
	check(_has_code(_array(first, "warnings"), "consent.required"), "first-consent warning")

	var granted_first: Dictionary = installer.permissions.grant(
		MOD_ID,
		"1.0.0",
		str(first.get("hash", "")),
		["core", "documents.read"]
	)
	check(granted_first.get("ok", false), "first consent recorded")
	check(installer.install(path_100).get("ok", false), "1.0.0 installs after consent")

	var path_110 := str(_package(MOD_ID, "1.1.0", ["documents.read", "files.read"])["path"])
	var growth_inspect: Dictionary = installer.inspect(path_110)
	var grown: Dictionary = _value(growth_inspect)
	var growth: Dictionary = _dict(grown, "permission_growth")
	assert_true(bool(growth.get("growing", false)), "permission growth flagged")
	assert_eq(_array(growth, "added"), ["files.read"], "new permission named")
	assert_true(bool(growth.get("requires_consent", false)), "growth requires fresh consent")
	assert_false(bool(grown.get("can_activate", true)), "activation waits for re-consent")
	check(_has_code(_array(grown, "warnings"), "permission.growth"), "growth warning")
	var details: Array = _array(growth, "details")
	check(!details.is_empty(), "permission details shown")
	if !details.is_empty():
		assert_eq(str((details[0] as Dictionary).get("risk", "")), "high", "added permission risk shown")

	var consented_inspect: Dictionary = installer.inspect(path_110, {"consent": true})
	assert_true(bool(_value(consented_inspect).get("can_activate", false)), "consent option unblocks activation")
	var granted_growth: Dictionary = installer.permissions.grant(
		MOD_ID,
		"1.1.0",
		str(grown.get("hash", "")),
		["core", "documents.read", "files.read"]
	)
	check(granted_growth.get("ok", false), "grown consent recorded")

	var path_120 := str(_package(MOD_ID, "1.2.0", ["documents.read"])["path"])
	var shrunk_inspect: Dictionary = installer.inspect(path_120)
	var shrunk: Dictionary = _value(shrunk_inspect)
	var shrunk_growth: Dictionary = _dict(shrunk, "permission_growth")
	var removed: Array = _array(shrunk_growth, "removed")
	check(removed.has("files.read"), "removed permission reported")
	assert_false(bool(shrunk_growth.get("requires_consent", true)), "shrinking needs no consent")
	assert_true(bool(shrunk.get("can_activate", false)), "shrunk package can activate")

	var clean_path := str(_package("griddycode.clean", "1.0.0")["path"])
	var clean_inspect: Dictionary = installer.inspect(clean_path)
	var clean: Dictionary = _value(clean_inspect)
	assert_false(bool(_dict(clean, "permission_growth").get("requires_consent", true)), "core-only needs no consent")
	assert_true(bool(clean.get("can_activate", false)), "core-only package can activate")


# ── ROLLBACK AND UNINSTALL ──────────────────────────────────────────────────

func test_rollback_restores_previous_and_verifies_bytes() -> void:
	var installer = _installer(true)
	var path_100 := str(_package(MOD_ID, "1.0.0")["path"])
	var path_110 := str(_package(MOD_ID, "1.1.0")["path"])
	check(installer.install(path_100).get("ok", false), "1.0.0 installs")
	check(installer.install(path_110).get("ok", false), "1.1.0 installs")

	var rolled: Dictionary = installer.rollback(MOD_ID)
	check(rolled.get("ok", false), "rollback succeeds: " + str(rolled))
	var restored: Dictionary = _value(rolled)
	assert_eq(str(restored.get("version", "")), "1.0.0", "previous version restored")
	assert_eq(str(restored.get("restored_from_version", "")), "1.1.0", "rollback reports the source")
	var entry: Dictionary = installer.registry.entry(MOD_ID)
	assert_eq(str(entry.get("version", "")), "1.0.0", "registry active version rolled back")
	assert_eq(str(_dict(entry, "previous").get("version", "")), "1.1.0", "rollback makes 1.1.0 the previous")

	var second: Dictionary = installer.rollback(MOD_ID)
	check(second.get("ok", false), "a second rollback toggles forward")
	assert_eq(str(_value(second).get("version", "")), "1.1.0", "back to 1.1.0")

	var missing: Dictionary = installer.rollback("griddycode.never")
	assert_eq(Result.code_of(missing), "dependency.missing", "unknown mod has no rollback")

	# A previous folder that changed on disk must not be restored.
	var tamper_id := "griddycode.tampered"
	check(installer.install(str(_package(tamper_id, "1.0.0")["path"])).get("ok", false), "tamper fixture 1.0.0")
	check(installer.install(str(_package(tamper_id, "1.1.0")["path"])).get("ok", false), "tamper fixture 1.1.0")
	var previous_file := ROOT + "/mods/" + tamper_id + "/1.0.0/main.lua"
	var handle := FileAccess.open(previous_file, FileAccess.WRITE)
	handle.store_string("return \"tampered\"\n")
	handle.close()
	var blocked: Dictionary = installer.rollback(tamper_id)
	assert_eq(Result.code_of(blocked), "update.rollback_blocked", "tampered bytes block rollback")
	assert_eq(str(installer.registry.entry(tamper_id).get("version", "")), "1.1.0", "active version unchanged")

	# A crafted registry record cannot point the rollback outside the mod folder.
	var outside_id := "griddycode.outside"
	var recorded: Dictionary = installer.registry.record(outside_id, {
		"version": "1.1.0",
		"hash": "",
		"path": ROOT + "/mods/" + outside_id + "/1.1.0",
		"previous": {"version": "1.0.0", "hash": "", "path": ROOT + "/escape"},
	})
	check(recorded.get("ok", false), "crafted registry record saves")
	var escaped: Dictionary = installer.rollback(outside_id)
	assert_eq(Result.code_of(escaped), "path.outside_workspace", "previous path must stay inside the mod folder")


func test_uninstall_keeps_data_or_removes_it() -> void:
	var installer = _installer(true)
	var path_100 := str(_package(MOD_ID, "1.0.0")["path"])
	var path_110 := str(_package(MOD_ID, "1.1.0")["path"])
	check(installer.install(path_100).get("ok", false), "1.0.0 installs")
	check(installer.install(path_110).get("ok", false), "1.1.0 installs")

	var data_dir := ROOT + "/data/" + MOD_ID
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(data_dir))
	var handle := FileAccess.open(data_dir + "/state.json", FileAccess.WRITE)
	handle.store_string("{\"kept\":true}")
	handle.close()
	check(
		installer.permissions.grant(MOD_ID, "1.1.0", "", ["core", "documents.read"]).get("ok", false),
		"consent recorded before uninstall"
	)

	var removed: Dictionary = installer.uninstall(MOD_ID)
	check(removed.get("ok", false), "uninstall succeeds: " + str(removed))
	var summary: Dictionary = _value(removed)
	assert_eq(int(summary.get("removed_versions", 0)), 2, "both installed versions removed")
	assert_true(bool(summary.get("data_kept", false)), "mod data kept by default")
	assert_false(bool(summary.get("data_removed", true)), "data was not deleted")
	check(!_exists(ROOT + "/mods/" + MOD_ID), "mod folder removed")
	check(!installer.registry.has(MOD_ID), "registry record removed")
	assert_true(installer.permissions.record(MOD_ID).is_empty(), "consent record revoked")
	check(FileAccess.file_exists(data_dir + "/state.json"), "kept data file survived")

	check(installer.install(path_100).get("ok", false), "reinstall after uninstall")
	var wiped: Dictionary = installer.uninstall(MOD_ID, {"remove_data": true})
	check(wiped.get("ok", false), "uninstall with remove_data succeeds")
	assert_true(bool(_value(wiped).get("data_removed", false)), "data removal reported")
	check(!_exists(data_dir), "data folder removed")

	var escaped: Dictionary = installer.uninstall("../escape")
	assert_eq(Result.code_of(escaped), "path.outside_workspace", "unsafe mod id rejected")


func test_package_swapped_after_review_is_refused() -> void:
	var made := _package(MOD_ID, "1.0.0", [], PUBLISHER)
	check(made.get("ok", false), "signed fixture builds")
	if !made.get("ok", false):
		return
	var path := str(made["path"])
	var installer = _installer()

	var reviewed: Dictionary = installer.inspect(path, {"trust_publisher": true})
	assert_true(bool(_value(reviewed).get("can_install", false)), "package reviews as installable")

	var signature: Dictionary = _dict(made, "signature")
	var swapped := Fixture.files(Fixture.manifest(MOD_ID, "1.0.0", []))
	swapped["main.lua"] = "return \"swapped\"\n".to_utf8_buffer()
	swapped["signature.json"] = JSON.stringify(signature).to_utf8_buffer()
	Fixture.write_zip(ROOT + "/packages", path.get_file(), swapped)

	var refused: Dictionary = installer.install(path, {"trust_publisher": true})
	assert_eq(Result.code_of(refused), "package.invalid", "the swapped bytes fail validation")
	check(!_exists(ROOT + "/mods/" + MOD_ID), "the swapped package was not extracted")
	check(!FileAccess.file_exists(PUBLISHERS_PATH), "the swapped package did not pin a publisher")


# ── FIXTURES AND HELPERS ────────────────────────────────────────────────────

func _installer(allow_unsigned: bool = false):
	var registry = Registry.new(ROOT + "/mod_registry.json")
	var permissions = Permissions.new(ROOT + "/mod_permissions.json")
	var publishers = Publishers.new(PUBLISHERS_PATH)
	var installer = Installer.new()
	installer.setup({
		"mods_root": ROOT + "/mods",
		"staging_root": ROOT + "/staging",
		"data_root": ROOT + "/data",
		"registry": registry,
		"permissions": permissions,
		"publishers": publishers,
		"allow_unsigned": allow_unsigned,
	})
	registry.load_registry()
	permissions.load_records()
	return installer


func _package(
	id: String,
	version: String,
	permissions: Array = [],
	publisher: String = "",
	seed_hex: String = SEED_A,
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


func _entry_count(path: String) -> int:
	if !_exists(path):
		return 0
	var directory := DirAccess.open(path)
	if directory == null:
		return 0
	return directory.get_files().size() + directory.get_directories().size()


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
