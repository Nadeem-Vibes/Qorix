extends RefCounted

## Shared fixture builder for Phase 6 tests: a valid manifest, package files and
## a hand-written ZIP container so tests can also build malicious archives.

const Package = preload("res://src/features/mods/mod_package.gd")
const Ed25519 = preload("res://src/features/mods/ed25519.gd")

const SIG_LOCAL := 0x04034B50
const SIG_CENTRAL := 0x02014B50
const SIG_EOCD := 0x06054B50

const DEFAULT_SEED := "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"


static func manifest(id: String, version: String, permissions: Array = [], extra: Dictionary = {}) -> Dictionary:
	var out := {
		"schema": 1,
		"id": id,
		"name": "Test " + id,
		"version": version,
		"api": 1,
		"min_editor": "1.0.0",
		"entry": "main.lua",
		"author": "Test Author",
		"description": "A package used by the Phase 6 tests.",
		"license": "MIT",
		"permissions": permissions,
	}
	for key in extra.keys():
		out[str(key)] = extra[key]
	return out


static func files(manifest_data: Dictionary, extra_files: Dictionary = {}) -> Dictionary:
	var out := {
		"manifest.json": JSON.stringify(manifest_data).to_utf8_buffer(),
		"main.lua": "return \"hello\"\n".to_utf8_buffer(),
		"lib/util.lua": "return 42\n".to_utf8_buffer(),
	}
	for key in extra_files.keys():
		out[str(key)] = extra_files[key]
	return out


static func write_zip(root: String, name: String, file_map: Dictionary) -> String:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(root))
	var path := root.path_join(name)
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_buffer(build_zip(entries(file_map)))
	file.close()
	return path


static func write_signed_zip(
	root: String,
	name: String,
	file_map: Dictionary,
	publisher: String,
	seed_hex: String = DEFAULT_SEED,
	extra_signature: Dictionary = {}
) -> Dictionary:
	var unsigned_path := write_zip(root, name + ".unsigned.gcm", file_map)
	var report := Package.validate_archive(unsigned_path)
	if !bool(report.get("ok", false)):
		return {"ok": false, "error": report.get("errors", []), "path": ""}
	var seed := Ed25519.hex_to_bytes(seed_hex)
	var signature := signature_for(report, publisher, seed)
	for key in extra_signature.keys():
		signature[str(key)] = extra_signature[key]
	var signed_files := file_map.duplicate()
	signed_files["signature.json"] = JSON.stringify(signature).to_utf8_buffer()
	var path := write_zip(root, name, signed_files)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(unsigned_path))
	return {"ok": true, "path": path, "signature": signature}


static func signature_for(report: Dictionary, publisher: String, seed: PackedByteArray) -> Dictionary:
	var public_key := Ed25519.public_key_from_seed(seed)
	var public_hex := Ed25519.bytes_to_hex(public_key)
	var digest := str(report.get("digest", ""))
	return {
		"schema": 1,
		"algorithm": "ed25519",
		"publisher_id": publisher,
		"public_key": public_hex,
		"signature": Ed25519.bytes_to_hex(Ed25519.sign(Ed25519.package_message(digest, publisher, public_hex), seed)),
		"package_hash": digest,
		"key_id": Ed25519.fingerprint(public_key),
		"signed_at": 1700000000,
		"display_name": publisher,
	}


static func entries(file_map: Dictionary) -> Array:
	var names: Array = file_map.keys()
	names.sort()
	var out: Array = []
	for name in names:
		out.append({"name": str(name), "data": file_map[name]})
	return out


static func build_zip(entry_list: Array) -> PackedByteArray:
	var output := PackedByteArray()
	var central := PackedByteArray()

	for entry in entry_list:
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

		output.append_array(u32(SIG_LOCAL))
		output.append_array(u16(20))
		output.append_array(u16(flags))
		output.append_array(u16(method))
		output.append_array(u16(0))
		output.append_array(u16(0))
		output.append_array(u32(crc))
		output.append_array(u32(compressed_size))
		output.append_array(u32(uncompressed_size))
		output.append_array(u16(name.size()))
		output.append_array(u16(local_extra.size()))
		output.append_array(name)
		output.append_array(local_extra)
		output.append_array(compressed)

		central.append_array(u32(SIG_CENTRAL))
		central.append_array(u16(0x031E))
		central.append_array(u16(20))
		central.append_array(u16(flags))
		central.append_array(u16(method))
		central.append_array(u16(0))
		central.append_array(u16(0))
		central.append_array(u32(crc))
		central.append_array(u32(compressed_size))
		central.append_array(u32(uncompressed_size))
		central.append_array(u16(name.size()))
		central.append_array(u16(central_extra.size()))
		central.append_array(u16(0))
		central.append_array(u16(0))
		central.append_array(u16(0))
		central.append_array(u32(external_attrs))
		central.append_array(u32(offset))
		central.append_array(name)
		central.append_array(central_extra)

	var cd_offset := output.size()
	output.append_array(central)
	output.append_array(u32(SIG_EOCD))
	output.append_array(u16(0))
	output.append_array(u16(0))
	output.append_array(u16(entry_list.size()))
	output.append_array(u16(entry_list.size()))
	output.append_array(u32(central.size()))
	output.append_array(u32(cd_offset))
	output.append_array(u16(0))
	return output


static func u16(value: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, value & 0xFFFF)
	return out


static func u32(value: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(4)
	out.encode_u32(0, value & 0xFFFFFFFF)
	return out
