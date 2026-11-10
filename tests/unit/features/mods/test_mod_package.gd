extends TestCase

## Phase 6 package format: central-directory validation, archive limits,
## canonical digest, Ed25519 signatures and CRC-checked extraction.
##
## Malicious archives are built by hand because ZIPPacker refuses traversal
## names; the builder below writes stored entries with explicit headers so each
## rejection is tested against the bytes an attacker would actually ship.

const Package = preload("res://src/features/mods/mod_package.gd")
const Ed25519 = preload("res://src/features/mods/ed25519.gd")

const ROOT := "user://griddy_mod_tests/package"
const PUBLISHER := "griddycode.testpublisher"
const SEED_HEX := "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"

const SIG_LOCAL := 0x04034B50
const SIG_CENTRAL := 0x02014B50
const SIG_EOCD := 0x06054B50


func before_each() -> void:
	_clean(ROOT)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ROOT))


func after_each() -> void:
	_clean(ROOT)


# ── VALID PACKAGE AND EXTRACTION ────────────────────────────────────────────

func test_valid_package_validates_and_extracts() -> void:
	var path := _write_zip("valid.gcm", _entries(_package_files()))
	var report := Package.validate_archive(path)

	assert_true(report.get("ok", false), "the package validates: " + str(report.get("errors", [])))
	assert_eq(str(report.get("digest", "")).length(), 64, "digest is SHA-256 hex")
	assert_eq(int((report.get("counts", {}) as Dictionary).get("files", 0)), 3, "file count")
	assert_false(bool((report.get("signature", {}) as Dictionary).get("present", true)), "no signature yet")
	assert_eq(str((report.get("manifest", {}) as Dictionary).get("id", "")), "griddycode.testpkg", "manifest parsed")

	var destination := ROOT + "/extracted"
	var extracted := Package.extract(path, report.get("entries", []), destination)
	check(extracted.get("ok", false), "extraction succeeds: " + str(extracted))
	assert_eq(FileAccess.get_file_as_string(destination + "/main.lua"), "return \"hello\"\n", "entry contents")
	assert_eq(FileAccess.get_file_as_string(destination + "/lib/util.lua"), "return 42\n", "asset contents")
	assert_eq(FileAccess.get_file_as_string(destination + "/manifest.json"), _manifest_text(), "manifest contents")


func test_extract_refuses_nonempty_destination() -> void:
	var path := _write_zip("valid.gcm", _entries(_package_files()))
	var report := Package.validate_archive(path)
	var destination := ROOT + "/busy"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(destination))
	FileAccess.open(destination + "/keep.txt", FileAccess.WRITE).store_string("keep")

	var extracted := Package.extract(path, report.get("entries", []), destination)
	assert_eq(str(extracted.get("error", {}).get("code", "")), "package.unreadable", "non-empty destination refused")
	assert_eq(FileAccess.get_file_as_string(destination + "/keep.txt"), "keep", "existing file untouched")


func test_extract_rejects_lying_crc() -> void:
	var entries := _entries(_package_files())
	entries[0]["crc"] = 0
	var path := _write_zip("bad_crc.gcm", entries)
	var report := Package.validate_archive(path)
	assert_false(report.get("ok", false), "validator catches the CRC before extraction")
	var messages: Array = report.get("errors", [])
	check(_has_code(messages, "package.invalid"), "lying CRC reports package.invalid")
	check(_has_message(messages, "wrong size") or _has_message(messages, "CRC"), "size or CRC error reported")


func test_pack_roundtrip_and_read_folder() -> void:
	var files := _package_files()
	var path := ROOT + "/packed.gcm"
	var packed := Package.pack(files, path)
	check(packed.get("ok", false), "pack writes a package: " + str(packed))

	var report := Package.validate_archive(path)
	assert_true(report.get("ok", false), "packed package validates: " + str(report.get("errors", [])))

	var destination := ROOT + "/from_pack"
	check(Package.extract(path, report.get("entries", []), destination).get("ok", false), "packed package extracts")
	var reread := Package.read_folder_files(destination)
	check(reread.get("ok", false), "extracted folder reads back")
	assert_eq(Package.canonical_digest(_entries_from_files(reread.get("files", {}))), report.get("digest", ""), "digest survives the round trip")

	var rejected := Package.pack({"manifest.json": _manifest_text().to_utf8_buffer(), "tool.exe": PackedByteArray()}, ROOT + "/bad.gcm")
	assert_false(rejected.get("ok", false), "pack refuses blocked extensions")


# ── CANONICAL DIGEST ────────────────────────────────────────────────────────

func test_digest_is_order_independent_and_excludes_signature() -> void:
	var files := _package_files()
	var first := _entries_from_files(files)
	var second := first.duplicate()
	second.reverse()

	assert_eq(Package.canonical_digest(first), Package.canonical_digest(second), "entry order does not change the digest")

	var with_signature := first.duplicate()
	with_signature.append({"path": "signature.json", "bytes": "{\"schema\":1}".to_utf8_buffer()})
	assert_eq(Package.canonical_digest(first), Package.canonical_digest(with_signature), "signature.json is excluded")

	with_signature = first.duplicate()
	with_signature.append({"path": "extra.lua", "bytes": "return 1\n".to_utf8_buffer()})
	assert_ne(Package.canonical_digest(first), Package.canonical_digest(with_signature), "a new file changes the digest")

	var changed := first.duplicate()
	changed[0] = {"path": "main.lua", "bytes": "return \"changed\"\n".to_utf8_buffer()}
	assert_ne(Package.canonical_digest(first), Package.canonical_digest(changed), "changed bytes change the digest")


func test_folder_digest_matches_package_digest() -> void:
	var files := _package_files()
	var folder := ROOT + "/folder"
	for name in files.keys():
		var target := folder.path_join(str(name))
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(target.get_base_dir()))
		FileAccess.open(target, FileAccess.WRITE).store_buffer(files[name])

	var report := Package.validate_folder(folder)
	assert_true(report.get("ok", false), "folder validates: " + str(report.get("errors", [])))
	var path := _write_zip("valid.gcm", _entries(files))
	assert_eq(report.get("digest", ""), Package.validate_archive(path).get("digest", ""), "folder and package digest agree")


# ── PATH TRAVERSAL AND ARCHIVE STRUCTURE ────────────────────────────────────

func test_rejects_unsafe_paths() -> void:
	var cases := [
		"../escape.lua",
		"/absolute.lua",
		"C:/drive.lua",
		"C:drive.lua",
		"a\\b.lua",
		"a//b.lua",
		"./a.lua",
		"a/./b.lua",
		"a/../b.lua",
		"con.txt",
		"aux/readme.txt",
		"trail./file.lua",
		"trail /file.lua",
		"a:b.lua",
		"a|b.lua",
	]
	for name in cases:
		var files := _package_files()
		files[str(name)] = "return 0\n".to_utf8_buffer()
		var path := _write_zip("unsafe_%d.gcm" % cases.find(name), _entries(files))
		var report := Package.validate_archive(path)
		assert_false(report.get("ok", false), "'%s' is rejected" % name)
		check(_has_code(report.get("errors", []), "package.invalid"), "'%s' reports package.invalid" % name)


func test_rejects_duplicate_names_and_file_directory_collisions() -> void:
	var duplicate := _entries(_package_files())
	duplicate.append({"name": "MAIN.lua", "data": "return 1\n".to_utf8_buffer()})
	var report := Package.validate_archive(_write_zip("duplicate.gcm", duplicate))
	assert_false(report.get("ok", false), "case-insensitive duplicate rejected")
	check(_has_message(report.get("errors", []), "more than once"), "duplicate named")

	var collision := _entries(_package_files())
	collision.append({"name": "assets", "data": "not a directory".to_utf8_buffer()})
	collision.append({"name": "assets/icon.png", "data": PackedByteArray([0x89, 0x50])})
	report = Package.validate_archive(_write_zip("collision.gcm", collision))
	assert_false(report.get("ok", false), "file used as a directory rejected")
	check(_has_message(report.get("errors", []), "used as a directory"), "collision named")


func test_rejects_symlinks_encryption_and_zip64() -> void:
	var symlink := _entries(_package_files())
	symlink.append({"name": "link.lua", "data": "target\n".to_utf8_buffer(), "external_attrs": 0xA1FF0000})
	var report := Package.validate_archive(_write_zip("symlink.gcm", symlink))
	assert_false(report.get("ok", false), "symlink rejected")
	check(_has_message(report.get("errors", []), "symbolic link"), "symlink named")

	var encrypted := _entries(_package_files())
	encrypted.append({"name": "secret.lua", "data": "x\n".to_utf8_buffer(), "flags": 0x0001})
	report = Package.validate_archive(_write_zip("encrypted.gcm", encrypted))
	assert_false(report.get("ok", false), "encrypted entry rejected")
	check(_has_message(report.get("errors", []), "Encrypted"), "encryption named")

	var zip64 := _entries(_package_files())
	zip64.append({"name": "zip64.lua", "data": "x\n".to_utf8_buffer(), "central_extra": _extra(0x0001, PackedByteArray())})
	report = Package.validate_archive(_write_zip("zip64.gcm", zip64))
	assert_false(report.get("ok", false), "ZIP64 extra field rejected")
	check(_has_code(report.get("errors", []), "package.zip64"), "zip64 code")


func test_rejects_blocked_extensions_and_oversized_entries() -> void:
	var blocked := _package_files()
	blocked["tool.exe"] = PackedByteArray([0x4D, 0x5A])
	var report := Package.validate_archive(_write_zip("blocked.gcm", _entries(blocked)))
	assert_false(report.get("ok", false), "executable rejected")
	check(_has_code(report.get("errors", []), "package.blocked_file"), "blocked file code")

	var oversized := _entries(_package_files())
	oversized.append({
		"name": "big.bin",
		"method": 8,
		"compressed": PackedByteArray([0]),
		"compressed_size": 1,
		"uncompressed_size": Package.MAX_ENTRY_UNCOMPRESSED + 1,
	})
	report = Package.validate_archive(_write_zip("oversized.gcm", oversized))
	assert_false(report.get("ok", false), "oversized entry rejected")
	check(_has_code(report.get("errors", []), "package.too_large"), "size code")

	var ratio := _entries(_package_files())
	ratio.append({
		"name": "bomb.bin",
		"method": 8,
		"compressed": PackedByteArray([0]),
		"compressed_size": 1,
		"uncompressed_size": 300 * 1024,
	})
	report = Package.validate_archive(_write_zip("ratio.gcm", ratio))
	assert_false(report.get("ok", false), "compression bomb rejected")
	check(_has_code(report.get("errors", []), "package.compression_ratio"), "ratio code")


func test_rejects_too_many_entries_and_total_size() -> void:
	var many := _build_zip(_entries(_package_files()))
	var eocd := _find_eocd(many)
	many.encode_u16(eocd + 8, 4097)
	many.encode_u16(eocd + 10, 4097)
	var many_path := ROOT + "/many_entries.gcm"
	_write_bytes(many_path, many)
	var report := Package.validate_archive(many_path)
	assert_false(report.get("ok", false), "entry-count cap enforced")
	check(_has_code(report.get("errors", []), "package.too_large"), "entry-count code")

	var total := _entries(_package_files())
	for index in range(5):
		total.append({
			"name": "part_%d.bin" % index,
			"method": 8,
			"compressed": _zeros(1024 * 1024),
			"compressed_size": 1024 * 1024,
			"uncompressed_size": 15 * 1024 * 1024,
		})
	report = Package.validate_archive(_write_zip("total.gcm", total))
	assert_false(report.get("ok", false), "total-size cap enforced")
	check(_has_code(report.get("errors", []), "package.too_large"), "total-size code")


func test_rejects_missing_and_invalid_manifest() -> void:
	var no_manifest := {"main.lua": "return 0\n".to_utf8_buffer()}
	var report := Package.validate_archive(_write_zip("no_manifest.gcm", _entries(no_manifest)))
	assert_false(report.get("ok", false), "missing manifest rejected")
	check(_has_code(report.get("errors", []), "manifest.unreadable"), "missing manifest code")

	var broken := {"manifest.json": "{not json".to_utf8_buffer(), "main.lua": "return 0\n".to_utf8_buffer()}
	report = Package.validate_archive(_write_zip("broken.gcm", _entries(broken)))
	assert_false(report.get("ok", false), "invalid JSON rejected")
	check(_has_code(report.get("errors", []), "manifest.unreadable"), "invalid JSON code")

	var manifest := _manifest()
	manifest["permissions"] = ["filesystem.everything"]
	var bad_permission := {
		"manifest.json": JSON.stringify(manifest).to_utf8_buffer(),
		"main.lua": "return 0\n".to_utf8_buffer(),
	}
	report = Package.validate_archive(_write_zip("permission.gcm", _entries(bad_permission)))
	assert_false(report.get("ok", false), "unknown permission rejected")
	check(_has_code(report.get("errors", []), "manifest.unknown_permission"), "permission code")

	var missing_entry := _package_files()
	missing_entry.erase("main.lua")
	report = Package.validate_archive(_write_zip("missing_entry.gcm", _entries(missing_entry)))
	assert_false(report.get("ok", false), "declared entry must exist")
	check(_has_message(report.get("errors", []), "entry file"), "missing entry named")


# ── SIGNATURES ──────────────────────────────────────────────────────────────

func test_signature_roundtrip_and_content_tamper() -> void:
	var seed := Ed25519.hex_to_bytes(SEED_HEX)
	var unsigned_path := _write_zip("unsigned.gcm", _entries(_package_files()))
	var unsigned_report := Package.validate_archive(unsigned_path)
	assert_true(unsigned_report.get("ok", false), "unsigned package validates before policy")

	var signature := _signature_for(unsigned_report, seed)
	var signed_files := _package_files()
	signed_files["signature.json"] = JSON.stringify(signature).to_utf8_buffer()
	var signed_path := _write_zip("signed.gcm", _entries(signed_files))
	var signed_report := Package.validate_archive(signed_path)

	assert_true(signed_report.get("ok", false), "signed package validates: " + str(signed_report.get("errors", [])))
	assert_eq(signed_report.get("digest", ""), unsigned_report.get("digest", ""), "signature is outside the digest")
	var info: Dictionary = signed_report.get("signature", {})
	assert_true(bool(info.get("present", false)), "signature reported present")
	assert_true(bool(info.get("ok", false)), "signature verifies")
	assert_eq(str(info.get("status", "")), "valid", "signature status")
	assert_eq(str(info.get("publisher_id", "")), PUBLISHER, "publisher id preserved")
	assert_eq(str(info.get("fingerprint", "")), Ed25519.fingerprint(Ed25519.public_key_from_seed(seed)), "fingerprint preserved")

	var tampered := _package_files()
	tampered["main.lua"] = "return \"tampered\"\n".to_utf8_buffer()
	tampered["signature.json"] = JSON.stringify(signature).to_utf8_buffer()
	var tampered_report := Package.validate_archive(_write_zip("tampered.gcm", _entries(tampered)))
	assert_false(tampered_report.get("ok", false), "tampered content is rejected")
	check(_has_code(tampered_report.get("errors", []), "signature.invalid"), "tampered signature code")

	# The signature covers a digest, so changing only signature.json metadata
	# (display_name) does not invalidate the package.
	signature["display_name"] = "Renamed Publisher"
	signed_files["signature.json"] = JSON.stringify(signature).to_utf8_buffer()
	var renamed_report := Package.validate_archive(_write_zip("renamed.gcm", _entries(signed_files)))
	assert_true(renamed_report.get("ok", false), "display name is not bound by the signature")


func test_signature_metadata_rejections() -> void:
	var seed := Ed25519.hex_to_bytes(SEED_HEX)
	var unsigned_report := Package.validate_archive(_write_zip("base.gcm", _entries(_package_files())))
	var signature := _signature_for(unsigned_report, seed)

	var cases: Array = []
	var unknown := signature.duplicate(true)
	unknown["extra"] = true
	cases.append({"label": "unknown field", "signature": unknown})

	var algorithm := signature.duplicate(true)
	algorithm["algorithm"] = "rsa"
	cases.append({"label": "wrong algorithm", "signature": algorithm})

	var hash := signature.duplicate(true)
	hash["package_hash"] = "0".repeat(64)
	cases.append({"label": "wrong package hash", "signature": hash})

	var key_id := signature.duplicate(true)
	key_id["key_id"] = "f".repeat(64)
	cases.append({"label": "wrong key id", "signature": key_id})

	var short_signature := signature.duplicate(true)
	short_signature["signature"] = "00"
	cases.append({"label": "short signature", "signature": short_signature})

	var publisher := signature.duplicate(true)
	publisher["publisher_id"] = "Not A Publisher"
	cases.append({"label": "invalid publisher id", "signature": publisher})

	for index in range(cases.size()):
		var files := _package_files()
		files["signature.json"] = JSON.stringify(cases[index]["signature"]).to_utf8_buffer()
		var report := Package.validate_archive(_write_zip("bad_signature_%d.gcm" % index, _entries(files)))
		assert_false(report.get("ok", false), "%s rejected" % str(cases[index]["label"]))
		check(_has_code(report.get("errors", []), "signature.invalid"), "%s reports signature.invalid" % str(cases[index]["label"]))


func test_signature_requires_supported_schema() -> void:
	var seed := Ed25519.hex_to_bytes(SEED_HEX)
	var report := Package.validate_archive(_write_zip("base2.gcm", _entries(_package_files())))
	var signature := _signature_for(report, seed)
	signature["schema"] = 2
	var files := _package_files()
	files["signature.json"] = JSON.stringify(signature).to_utf8_buffer()
	var rejected := Package.validate_archive(_write_zip("schema.gcm", _entries(files)))
	assert_false(rejected.get("ok", false), "unsupported signature schema rejected")
	check(_has_code(rejected.get("errors", []), "signature.invalid"), "schema reports signature.invalid")


# ── FOLDER VALIDATION ───────────────────────────────────────────────────────

func test_folder_rejects_blocked_files_and_missing_manifest() -> void:
	var folder := ROOT + "/unsafe_folder"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder))
	FileAccess.open(folder + "/main.lua", FileAccess.WRITE).store_string("return 0\n")
	var report := Package.validate_folder(folder)
	assert_false(report.get("ok", false), "folder without manifest rejected")
	check(_has_code(report.get("errors", []), "manifest.unreadable"), "missing manifest code")

	FileAccess.open(folder + "/manifest.json", FileAccess.WRITE).store_string(_manifest_text())
	FileAccess.open(folder + "/tool.exe", FileAccess.WRITE).store_string("MZ")
	report = Package.validate_folder(folder)
	assert_false(report.get("ok", false), "folder with executable rejected")
	check(_has_code(report.get("errors", []), "package.blocked_file"), "blocked file code")


func test_validate_rejects_wrong_container() -> void:
	var text := ROOT + "/notes.txt"
	FileAccess.open(text, FileAccess.WRITE).store_string("not a package")
	var report := Package.validate_archive(text)
	assert_false(report.get("ok", false), "non-package extension rejected")
	check(_has_code(report.get("errors", []), "package.invalid"), "extension code")

	var empty := ROOT + "/empty.gcm"
	FileAccess.open(empty, FileAccess.WRITE).store_string("")
	report = Package.validate_archive(empty)
	assert_false(report.get("ok", false), "empty file rejected")
	check(_has_code(report.get("errors", []), "package.unreadable"), "empty file code")

	var garbage := ROOT + "/garbage.gcm"
	FileAccess.open(garbage, FileAccess.WRITE).store_buffer(PackedByteArray([1, 2, 3]))
	report = Package.validate_archive(garbage)
	assert_false(report.get("ok", false), "tiny file rejected")
	check(_has_code(report.get("errors", []), "package.invalid"), "tiny file code")


# ── FIXTURES ────────────────────────────────────────────────────────────────

func _manifest() -> Dictionary:
	return {
		"schema": 1,
		"id": "griddycode.testpkg",
		"name": "Test Package",
		"version": "1.2.3",
		"api": 1,
		"min_editor": "1.0.0",
		"entry": "main.lua",
		"author": "Test Author",
		"description": "A package used by the Phase 6 validator tests.",
		"license": "MIT",
		"permissions": [],
	}


func _manifest_text() -> String:
	return JSON.stringify(_manifest())


func _package_files() -> Dictionary:
	return {
		"manifest.json": _manifest_text().to_utf8_buffer(),
		"main.lua": "return \"hello\"\n".to_utf8_buffer(),
		"lib/util.lua": "return 42\n".to_utf8_buffer(),
	}


func _signature_for(report: Dictionary, seed: PackedByteArray) -> Dictionary:
	var public_key := Ed25519.public_key_from_seed(seed)
	var public_hex := Ed25519.bytes_to_hex(public_key)
	var digest := str(report.get("digest", ""))
	var message := Ed25519.package_message(digest, PUBLISHER, public_hex)
	return {
		"schema": 1,
		"algorithm": "ed25519",
		"publisher_id": PUBLISHER,
		"public_key": public_hex,
		"signature": Ed25519.bytes_to_hex(Ed25519.sign(message, seed)),
		"package_hash": digest,
		"key_id": Ed25519.fingerprint(public_key),
		"signed_at": 1700000000,
		"display_name": "Test Publisher",
	}


func _entries(files: Dictionary) -> Array:
	var names: Array = files.keys()
	names.sort()
	var out: Array = []
	for name in names:
		out.append({"name": str(name), "data": files[name]})
	return out


func _entries_from_files(files: Dictionary) -> Array:
	var names: Array = files.keys()
	names.sort()
	var out: Array = []
	for name in names:
		out.append({"path": str(name), "bytes": files[name]})
	return out


# ── MANUAL ZIP BUILDER ──────────────────────────────────────────────────────

func _write_zip(name: String, entries: Array) -> String:
	var path := ROOT.path_join(name)
	_write_bytes(path, _build_zip(entries))
	return path


func _write_bytes(path: String, bytes: PackedByteArray) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_buffer(bytes)
	file.close()


func _build_zip(entries: Array) -> PackedByteArray:
	var output := PackedByteArray()
	var central := PackedByteArray()

	for entry in entries:
		var name := str(entry.get("name", "")).to_utf8_buffer()
		var data: PackedByteArray = entry.get("data", PackedByteArray())
		var compressed: PackedByteArray = entry.get("compressed", data)
		var method := int(entry.get("method", 0))
		var flags := int(entry.get("flags", 0))
		var crc := int(entry.get("crc", Package.crc32(data)))
		var compressed_size := int(entry.get("compressed_size", compressed.size()))
		var uncompressed_size := int(entry.get("uncompressed_size", data.size()))
		var external_attrs := int(entry.get("external_attrs", 0))
		var local_extra: PackedByteArray = entry.get("local_extra", PackedByteArray())
		var central_extra: PackedByteArray = entry.get("central_extra", local_extra)
		var offset := output.size()

		output.append_array(_u32(SIG_LOCAL))
		output.append_array(_u16(20))
		output.append_array(_u16(flags))
		output.append_array(_u16(method))
		output.append_array(_u16(0))
		output.append_array(_u16(0))
		output.append_array(_u32(crc))
		output.append_array(_u32(compressed_size))
		output.append_array(_u32(uncompressed_size))
		output.append_array(_u16(name.size()))
		output.append_array(_u16(local_extra.size()))
		output.append_array(name)
		output.append_array(local_extra)
		output.append_array(compressed)

		central.append_array(_u32(SIG_CENTRAL))
		central.append_array(_u16(0x031E))
		central.append_array(_u16(20))
		central.append_array(_u16(flags))
		central.append_array(_u16(method))
		central.append_array(_u16(0))
		central.append_array(_u16(0))
		central.append_array(_u32(crc))
		central.append_array(_u32(compressed_size))
		central.append_array(_u32(uncompressed_size))
		central.append_array(_u16(name.size()))
		central.append_array(_u16(central_extra.size()))
		central.append_array(_u16(0))
		central.append_array(_u16(0))
		central.append_array(_u16(0))
		central.append_array(_u32(external_attrs))
		central.append_array(_u32(offset))
		central.append_array(name)
		central.append_array(central_extra)

	var cd_offset := output.size()
	output.append_array(central)
	output.append_array(_u32(SIG_EOCD))
	output.append_array(_u16(0))
	output.append_array(_u16(0))
	output.append_array(_u16(entries.size()))
	output.append_array(_u16(entries.size()))
	output.append_array(_u32(central.size()))
	output.append_array(_u32(cd_offset))
	output.append_array(_u16(0))
	return output


func _extra(tag: int, payload: PackedByteArray) -> PackedByteArray:
	var out := _u16(tag)
	out.append_array(_u16(payload.size()))
	out.append_array(payload)
	return out


func _u16(value: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, value & 0xFFFF)
	return out


func _u32(value: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(4)
	out.encode_u32(0, value & 0xFFFFFFFF)
	return out


func _find_eocd(bytes: PackedByteArray) -> int:
	for offset in range(bytes.size() - 22, -1, -1):
		if bytes.decode_u32(offset) == SIG_EOCD:
			return offset
	return -1


func _zeros(count: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(count)
	return out


func _has_code(errors: Array, code: String) -> bool:
	for problem in errors:
		if str((problem as Dictionary).get("code", "")) == code:
			return true
	return false


func _has_message(errors: Array, text: String) -> bool:
	for problem in errors:
		if str((problem as Dictionary).get("message", "")).contains(text):
			return true
	return false


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
