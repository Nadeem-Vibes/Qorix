extends RefCounted

## Mod package format: a ZIP container with a root manifest.json,
## Lua code and assets, and an optional signature.json.
##
## Everything is validated before a single byte is extracted:
##
##   * path traversal, absolute paths, drive letters, ADS and Windows device
##     names are rejected;
##   * duplicate names (case-insensitive, because the install target is often a
##     case-insensitive filesystem), file/directory collisions and overlapping
##     local headers are rejected;
##   * symlinks, devices and other non-regular entries are rejected;
##   * encrypted and ZIP64 archives are rejected;
##   * entry count, per-entry size, total size and compression ratio are capped;
##   * executable and native-library extensions are rejected;
##   * manifest.json has to exist at the archive root and pass the Phase 1
##     schema, including entry/icon existence;
##   * signature.json, when present, must be a valid Ed25519 signature over the
##     canonical package digest before extraction is allowed.
##
## The canonical digest is SHA-256 over sorted relative paths, a NUL separator,
## the 8-byte big-endian file length and the file bytes. signature.json is not
## part of the digest: the signature covers the digest, publisher id and public
## key, so it cannot sign itself.

const Result = preload("res://src/features/mods/mod_result.gd")
const Manifest = preload("res://src/features/mods/mod_manifest.gd")
const Ed25519 = preload("res://src/features/mods/ed25519.gd")

const MANIFEST_FILE := "manifest.json"
const SIGNATURE_FILE := "signature.json"
const PACKAGE_EXTENSIONS := ["gcm", "zip"]

const MAX_PACKAGE_BYTES := 64 * 1024 * 1024
const MAX_ENTRIES := 4096
const MAX_TOTAL_UNCOMPRESSED := 64 * 1024 * 1024
const MAX_ENTRY_UNCOMPRESSED := 16 * 1024 * 1024
const MAX_SIGNATURE_BYTES := 64 * 1024
const MAX_COMPRESSION_RATIO := 100
const RATIO_MIN_BYTES := 256 * 1024
const MAX_DIRECTORY_BYTES := 4096
const MAX_PATH_LENGTH := 240

const SIG_LOCAL := 0x04034B50
const SIG_CENTRAL := 0x02014B50
const SIG_EOCD := 0x06054B50
const SIG_ZIP64_EOCD := 0x06064B50
const SIG_ZIP64_LOCATOR := 0x07064B50

const BLOCKED_EXTENSIONS := [
	"exe", "dll", "so", "dylib", "bat", "cmd", "com", "msi", "scr", "pif",
	"ps1", "psm1", "sh", "bash", "zsh", "fish", "jar", "vbs", "vbe", "js",
	"jse", "wsf", "wsh", "hta", "reg", "lnk", "url", "cpl", "sys", "drv",
	"ocx", "xll", "ko", "wasm", "luac",
]

const RESERVED_NAMES := [
	"con", "prn", "aux", "nul",
	"com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8", "com9",
	"lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9",
]

const SIGNATURE_FIELDS := [
	"schema", "algorithm", "publisher_id", "public_key", "signature",
	"package_hash", "key_id", "signed_at", "display_name",
]

static var _crc_table: PackedInt64Array = PackedInt64Array()


# ── ARCHIVE VALIDATION ──────────────────────────────────────────────────────

## Validates a package without extracting anything.
##
## Returns:
##   {ok, errors: [{code, message, field}], entries, digest, manifest,
##    manifest_result, signature, counts: {files, directories}, sizes: {...}}
static func validate_archive(path: String) -> Dictionary:
	var errors: Array = []
	var out: Dictionary = {
		"ok": false,
		"errors": errors,
		"entries": [],
		"digest": "",
		"manifest": {},
		"manifest_result": {},
		"signature": {"present": false, "status": "unsigned"},
		"counts": {"files": 0, "directories": 0},
		"sizes": {"compressed": 0, "uncompressed": 0},
	}

	var extension := path.get_extension().to_lower()
	if !PACKAGE_EXTENSIONS.has(extension):
		_error(errors, "package.invalid", "Mod packages use the .gcm or .zip extension.")
		return out
	if path.is_empty() or !FileAccess.file_exists(path):
		_error(errors, "package.unreadable", "The package does not exist: " + path)
		return out

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_error(errors, "package.unreadable", "The package could not be opened (error %d)." % FileAccess.get_open_error())
		return out
	var size := file.get_length()
	if size <= 0:
		file.close()
		_error(errors, "package.unreadable", "The package is empty.")
		return out
	if size > MAX_PACKAGE_BYTES:
		file.close()
		_error(errors, "package.too_large", "The package is larger than %d bytes." % MAX_PACKAGE_BYTES)
		return out
	var data := file.get_buffer(size)
	file.close()

	var parsed := _parse_central_directory(data)
	for problem in parsed.get("errors", []):
		errors.append(problem)
	var entries: Array = parsed.get("entries", [])
	out["entries"] = entries
	out["counts"] = parsed.get("counts", out["counts"])
	out["sizes"] = parsed.get("sizes", out["sizes"])
	if !parsed.get("ok", false) || !errors.is_empty():
		return out

	# Decompress into memory once. Caps were enforced on the declared sizes;
	# the real size and CRC are checked again here so a lying header cannot
	# smuggle a larger file past validation.
	var files := _read_archive_files(path, entries)
	for problem in files.get("errors", []):
		errors.append(problem)
	if !files.get("ok", false):
		return out

	var file_list: Array = files["files"]
	var manifest_entry := _find_file(file_list, MANIFEST_FILE)
	if manifest_entry.is_empty():
		_error(errors, "manifest.unreadable", "The package has no manifest.json at its root.")
		return out
	if (manifest_entry["bytes"] as PackedByteArray).size() > Manifest.MAX_MANIFEST_BYTES:
		_error(errors, "manifest.unreadable", "manifest.json is larger than %d bytes." % Manifest.MAX_MANIFEST_BYTES)
		return out

	var json := JSON.new()
	if json.parse((manifest_entry["bytes"] as PackedByteArray).get_string_from_utf8()) != OK:
		_error(
			errors,
			"manifest.unreadable",
			"manifest.json is not valid JSON: %s (line %d)." % [json.get_error_message(), json.get_error_line()],
		)
		return out

	var manifest_result := Manifest.validate(json.data, {"path": MANIFEST_FILE})
	out["manifest_result"] = manifest_result
	if !manifest_result.get("ok", false):
		for problem in manifest_result.get("errors", []):
			_error(
				errors,
				str(problem.get("code", "manifest.invalid")),
				str(problem.get("message", "The manifest is invalid.")),
				str(problem.get("field", "")),
			)
		# Keep the parsed manifest for the review UI, but do not continue: the
		# entry and icon checks would be meaningless.
		out["manifest"] = manifest_result.get("manifest", {})
		return out

	var manifest: Dictionary = manifest_result["manifest"]
	out["manifest"] = manifest

	var entry_path := str(manifest.get("entry", ""))
	if !_has_file(file_list, entry_path):
		_error(errors, "manifest.invalid", "The entry file '%s' is not in the package." % entry_path)
	var assets: Dictionary = manifest.get("assets", {})
	if assets.has("icon") and !_has_file(file_list, str(assets["icon"])):
		_error(errors, "manifest.invalid", "The declared icon '%s' is not in the package." % str(assets["icon"]))

	var digest := canonical_digest(file_list)
	out["digest"] = digest

	var signature := _check_archive_signature(file_list, digest)
	out["signature"] = signature
	if bool(signature.get("present", false)) and !bool(signature.get("ok", false)):
		_error(
			errors,
			"signature.invalid",
			str(signature.get("error", "The package signature is invalid.")),
			SIGNATURE_FILE,
		)

	out["ok"] = errors.is_empty()
	return out


## Validates an already-extracted mod folder (legacy folder install, rollback
## candidate or dev copy). The same path, extension, size and signature rules
## apply, but there is no central directory to parse.
static func validate_folder(root: String) -> Dictionary:
	var errors: Array = []
	var out: Dictionary = {
		"ok": false,
		"errors": errors,
		"files": [],
		"digest": "",
		"manifest": {},
		"manifest_result": {},
		"signature": {"present": false, "status": "unsigned"},
		"mtime": 0,
		"sizes": {"uncompressed": 0},
	}
	if root.is_empty() or !DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(root)):
		_error(errors, "package.unreadable", "The mod folder does not exist: " + root)
		return out

	var collected := _collect_folder(root)
	for problem in collected.get("errors", []):
		errors.append(problem)
	var files: Array = collected.get("files", [])
	out["files"] = _public_files(files)
	out["mtime"] = int(collected.get("mtime", 0))
	out["sizes"] = {"uncompressed": int(collected.get("total", 0))}
	if !collected.get("ok", false) || !errors.is_empty():
		return out

	var manifest_entry := _find_file(files, MANIFEST_FILE)
	if manifest_entry.is_empty():
		_error(errors, "manifest.unreadable", "The folder has no manifest.json.")
		return out
	if (manifest_entry["bytes"] as PackedByteArray).size() > Manifest.MAX_MANIFEST_BYTES:
		_error(errors, "manifest.unreadable", "manifest.json is larger than %d bytes." % Manifest.MAX_MANIFEST_BYTES)
		return out

	var json := JSON.new()
	if json.parse((manifest_entry["bytes"] as PackedByteArray).get_string_from_utf8()) != OK:
		_error(errors, "manifest.unreadable", "manifest.json is not valid JSON: %s." % json.get_error_message())
		return out

	var manifest_result := Manifest.validate(json.data, {"root": root, "path": root.path_join(MANIFEST_FILE)})
	out["manifest_result"] = manifest_result
	if !manifest_result.get("ok", false):
		for problem in manifest_result.get("errors", []):
			_error(errors, str(problem.get("code", "manifest.invalid")), str(problem.get("message", "The manifest is invalid.")), str(problem.get("field", "")))
		out["manifest"] = manifest_result.get("manifest", {})
		return out

	var manifest: Dictionary = manifest_result["manifest"]
	out["manifest"] = manifest
	if !_has_file(files, str(manifest.get("entry", ""))):
		_error(errors, "manifest.invalid", "The entry file '%s' is not in the folder." % str(manifest.get("entry", "")))
	var assets: Dictionary = manifest.get("assets", {})
	if assets.has("icon") and !_has_file(files, str(assets["icon"])):
		_error(errors, "manifest.invalid", "The declared icon '%s' is not in the folder." % str(assets["icon"]))

	var digest := canonical_digest(files)
	out["digest"] = digest

	var signature_entry := _find_file(files, SIGNATURE_FILE)
	if signature_entry.is_empty():
		out["signature"] = {"present": false, "status": "unsigned"}
	else:
		var signature := check_signature_bytes(signature_entry["bytes"], digest)
		out["signature"] = signature
		if !bool(signature.get("ok", false)):
			_error(errors, "signature.invalid", str(signature.get("error", "The package signature is invalid.")), SIGNATURE_FILE)

	out["ok"] = errors.is_empty()
	return out


# ── CANONICAL DIGEST ────────────────────────────────────────────────────────

## Hashes sorted relative paths, a NUL separator, the 8-byte big-endian length
## and the contents. `files` is an Array of {path, bytes}; signature.json is
## excluded wherever it appears because it signs the digest itself.
static func canonical_digest(files: Array) -> String:
	var sorted := files.duplicate()
	sorted.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.get("path", "")) < str(b.get("path", ""))
	)

	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	for item in sorted:
		var path := str((item as Dictionary).get("path", ""))
		if path == SIGNATURE_FILE:
			continue
		var bytes: PackedByteArray = (item as Dictionary).get("bytes", PackedByteArray())
		var length := bytes.size()
		var length_bytes := PackedByteArray()
		length_bytes.resize(8)
		for index in range(8):
			length_bytes[7 - index] = (length >> (index * 8)) & 0xFF
		context.update(path.to_utf8_buffer())
		context.update(PackedByteArray([0]))
		context.update(length_bytes)
		context.update(bytes)
	return context.finish().hex_encode().to_lower()


## Cheap digest for an installed folder when the caller already knows it is
## safe. returns {ok, hash, mtime}; validation belongs in validate_folder().
static func digest_folder(root: String) -> Dictionary:
	var collected := _collect_folder(root)
	if !collected.get("ok", false):
		return {"ok": false, "hash": "", "mtime": 0, "errors": collected.get("errors", [])}
	return {
		"ok": true,
		"hash": canonical_digest(collected["files"]),
		"mtime": int(collected.get("mtime", 0)),
		"errors": [],
	}


# ── SIGNATURES ──────────────────────────────────────────────────────────────

## Validates signature.json bytes and verifies them against `digest`.
## Returns {present, ok, status, publisher_id, public_key, fingerprint,
##          package_hash, signed_at, display_name, error}.
static func check_signature_bytes(bytes: PackedByteArray, digest: String) -> Dictionary:
	var out: Dictionary = {
		"present": true,
		"ok": false,
		"status": "invalid",
		"publisher_id": "",
		"public_key": "",
		"fingerprint": "",
		"package_hash": "",
		"signed_at": 0,
		"display_name": "",
		"error": "",
	}
	if bytes.size() > MAX_SIGNATURE_BYTES:
		out["error"] = "signature.json is larger than %d bytes." % MAX_SIGNATURE_BYTES
		return out

	var json := JSON.new()
	if json.parse(bytes.get_string_from_utf8()) != OK:
		out["error"] = "signature.json is not valid JSON: %s." % json.get_error_message()
		return out
	var data: Variant = json.data
	if !(data is Dictionary):
		out["error"] = "signature.json must be a JSON object."
		return out

	var source: Dictionary = data
	for key in source.keys():
		if !SIGNATURE_FIELDS.has(str(key)):
			out["error"] = "signature.json has an unknown field '%s'." % str(key)
			return out

	if int(source.get("schema", 0)) != 1:
		out["error"] = "signature.json uses an unsupported schema."
		return out
	if str(source.get("algorithm", "")) != "ed25519":
		out["error"] = "signature.json must use the ed25519 algorithm."
		return out

	var publisher_id := str(source.get("publisher_id", ""))
	if !is_valid_publisher_id(publisher_id):
		out["error"] = "'%s' is not a valid publisher id." % publisher_id
		return out
	var public_key := str(source.get("public_key", "")).to_lower()
	if public_key.length() != 64:
		out["error"] = "public_key must be 32 bytes of hex."
		return out
	var signature_hex := str(source.get("signature", "")).to_lower()
	if signature_hex.length() != 128:
		out["error"] = "signature must be 64 bytes of hex."
		return out
	var package_hash := str(source.get("package_hash", "")).to_lower()
	if package_hash.length() != 64:
		out["error"] = "package_hash must be 32 bytes of hex."
		return out

	var public_key_bytes := Ed25519.hex_to_bytes(public_key)
	var signature_bytes := Ed25519.hex_to_bytes(signature_hex)
	if public_key_bytes.size() != 32:
		out["error"] = "public_key is not valid hex."
		return out
	if signature_bytes.size() != 64:
		out["error"] = "signature is not valid hex."
		return out

	var fingerprint := Ed25519.fingerprint(public_key_bytes)
	out["publisher_id"] = publisher_id
	out["public_key"] = public_key
	out["fingerprint"] = fingerprint
	out["package_hash"] = package_hash
	out["signed_at"] = int(source.get("signed_at", 0))
	out["display_name"] = str(source.get("display_name", ""))
	if source.has("key_id"):
		if str(source.get("key_id", "")).to_lower() != fingerprint:
			out["error"] = "key_id does not match the public key fingerprint."
			return out

	if package_hash != digest.to_lower():
		out["error"] = "The signature covers a different package digest."
		return out

	var message := Ed25519.package_message(digest, publisher_id, public_key)
	if !Ed25519.verify(signature_bytes, message, public_key_bytes):
		out["error"] = "The Ed25519 signature does not verify."
		return out

	out["ok"] = true
	out["status"] = "valid"
	return out


static func is_valid_publisher_id(value: String) -> bool:
	if value.length() < 2 or value.length() > 64:
		return false
	var regex := RegEx.new()
	if regex.compile("^[a-z0-9][a-z0-9._-]*$") != OK:
		return false
	return regex.search(value) != null


# ── EXTRACTION ──────────────────────────────────────────────────────────────

## Extracts a validated package into an empty staging folder. The caller must
## pass the entries from validate_archive(); this function re-checks real sizes
## and CRC32 values, so a central directory that lied during validation cannot
## write more bytes than expected.
static func extract(path: String, entries: Array, destination: String) -> Dictionary:
	if destination.is_empty():
		return Result.error("package.unreadable", "The extraction destination is empty.")
	var absolute := ProjectSettings.globalize_path(destination)
	if DirAccess.dir_exists_absolute(absolute):
		if !_directory_is_empty(absolute):
			return Result.error("package.unreadable", "The extraction destination is not empty.")
	else:
		var made := DirAccess.make_dir_recursive_absolute(absolute)
		if made != OK:
			return Result.error("package.unreadable", "Could not create the staging folder (error %d)." % made)

	var reader := ZIPReader.new()
	if reader.open(path) != OK:
		return Result.error("package.unreadable", "The package could not be opened for extraction.")

	for entry in entries:
		var item: Dictionary = entry
		if bool(item.get("directory", false)):
			continue
		var relative := str(item.get("path", ""))
		if relative.is_empty():
			return Result.error("package.invalid", "The package contains an empty file name.")
		if !reader.file_exists(relative):
			return Result.error("package.invalid", "The package entry '%s' could not be read." % relative)
		var bytes := reader.read_file(relative)
		if bytes.size() != int(item.get("size", -1)):
			return Result.error("package.invalid", "The package entry '%s' has the wrong size." % relative)
		if crc32(bytes) != int(item.get("crc32", 0)):
			return Result.error("package.invalid", "The package entry '%s' failed its CRC check." % relative)
		var target := destination.path_join(relative)
		var parent := target.get_base_dir()
		if !parent.is_empty():
			var made_parent := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(parent))
			if made_parent != OK:
				return Result.error("package.unreadable", "Could not create '%s' (error %d)." % [parent, made_parent])
		var output := FileAccess.open(target, FileAccess.WRITE)
		if output == null:
			return Result.error("package.unreadable", "Could not write '%s' (error %d)." % [relative, FileAccess.get_open_error()])
		output.store_buffer(bytes)
		output.close()

	reader.close()
	return Result.ok({"destination": destination})


# ── PACKING (used by tools/mod-package/mod_package.gd) ──────────────────────

## Writes a ZIP container from {relative path: PackedByteArray}. The caller is
## responsible for adding signature.json, but every path gets the same safety
## checks as an imported package.
static func pack(files: Dictionary, output_path: String) -> Dictionary:
	var names: Array = files.keys()
	names.sort()
	for raw_name in names:
		var name := str(raw_name).replace("\\", "/")
		var problem := _path_problem(name, false)
		if !problem.is_empty():
			return Result.error("package.invalid", problem)
		var extension := name.get_extension().to_lower()
		if BLOCKED_EXTENSIONS.has(extension):
			return Result.error("package.invalid", "'%s' has a blocked extension." % name)
		var bytes: Variant = files[raw_name]
		if !(bytes is PackedByteArray):
			return Result.error("package.invalid", "'%s' is not a PackedByteArray." % name)

	var packer := ZIPPacker.new()
	var opened := packer.open(output_path)
	if opened != OK:
		return Result.error("package.unreadable", "Could not create the package (error %d)." % opened)
	for raw_name in names:
		var name := str(raw_name).replace("\\", "/")
		var start := packer.start_file(name)
		if start != OK:
			packer.close()
			return Result.error("package.unreadable", "Could not write '%s' (error %d)." % [name, start])
		packer.write_file(files[raw_name])
		packer.close_file()
	packer.close()
	return Result.ok({"path": output_path, "files": names.size()})


## Reads a folder into {relative path: PackedByteArray} for pack(). Rejects the
## same unsafe names as an import so the tool cannot build a package the editor
## would refuse.
static func read_folder_files(root: String) -> Dictionary:
	var collected := _collect_folder(root)
	if !collected.get("ok", false):
		return {"ok": false, "error": "The folder failed validation.", "errors": collected.get("errors", [])}
	var out: Dictionary = {}
	for item in collected["files"]:
		out[str(item["path"])] = item["bytes"]
	return {"ok": true, "files": out, "mtime": int(collected.get("mtime", 0))}


# ── CENTRAL DIRECTORY PARSER ────────────────────────────────────────────────

static func _parse_central_directory(data: PackedByteArray) -> Dictionary:
	var errors: Array = []
	var entries: Array = []
	var counts := {"files": 0, "directories": 0}
	var sizes := {"compressed": 0, "uncompressed": 0}
	var out := {
		"ok": false,
		"errors": errors,
		"entries": entries,
		"counts": counts,
		"sizes": sizes,
	}

	if data.size() < 22:
		_error(errors, "package.invalid", "The file is too small to be a ZIP archive.")
		return out

	var eocd := _find_eocd(data)
	if eocd < 0:
		_error(errors, "package.invalid", "The ZIP end-of-central-directory record is missing or ambiguous.")
		return out
	if eocd >= 20 and data.decode_u32(eocd - 20) == SIG_ZIP64_LOCATOR:
		_error(errors, "package.zip64", "ZIP64 packages are not supported.")
		return out
	if eocd >= 56 and data.decode_u32(eocd - 56) == SIG_ZIP64_EOCD:
		_error(errors, "package.zip64", "ZIP64 packages are not supported.")
		return out

	var disk := data.decode_u16(eocd + 4)
	var cd_disk := data.decode_u16(eocd + 6)
	var entries_disk := data.decode_u16(eocd + 8)
	var entries_total := data.decode_u16(eocd + 10)
	var cd_size := data.decode_u32(eocd + 12)
	var cd_offset := data.decode_u32(eocd + 16)
	var comment_len := data.decode_u16(eocd + 20)

	if comment_len != data.size() - eocd - 22:
		_error(errors, "package.invalid", "The ZIP comment length does not match the file.")
		return out
	if disk != 0 or cd_disk != 0:
		_error(errors, "package.invalid", "Multi-disk ZIP archives are not supported.")
		return out
	if entries_disk != entries_total:
		_error(errors, "package.invalid", "The ZIP entry counts disagree.")
		return out
	if entries_total == 0xFFFF or cd_size == 0xFFFFFFFF or cd_offset == 0xFFFFFFFF:
		_error(errors, "package.zip64", "ZIP64 packages are not supported.")
		return out
	if entries_total == 0:
		_error(errors, "package.invalid", "The package has no entries.")
		return out
	if entries_total > MAX_ENTRIES:
		_error(errors, "package.too_large", "The package has more than %d entries." % MAX_ENTRIES)
		return out

	var cd_end := cd_offset + cd_size
	if cd_offset < 0 or cd_end != eocd:
		_error(errors, "package.invalid", "The ZIP central directory is not where the end record says it is.")
		return out
	if cd_end > data.size():
		_error(errors, "package.invalid", "The ZIP central directory runs past the end of the file.")
		return out

	var seen: Dictionary = {}
	var cursor := cd_offset
	for index in range(entries_total):
		if cursor + 46 > cd_end:
			_error(errors, "package.invalid", "Central directory entry %d is truncated." % index)
			return out
		if data.decode_u32(cursor) != SIG_CENTRAL:
			_error(errors, "package.invalid", "Central directory entry %d has a bad signature." % index)
			return out

		var version_made := data.decode_u16(cursor + 4)
		var flags := data.decode_u16(cursor + 8)
		var method := data.decode_u16(cursor + 10)
		var crc := data.decode_u32(cursor + 16)
		var compressed_size := data.decode_u32(cursor + 20)
		var uncompressed_size := data.decode_u32(cursor + 24)
		var name_len := data.decode_u16(cursor + 28)
		var extra_len := data.decode_u16(cursor + 30)
		var entry_comment_len := data.decode_u16(cursor + 32)
		var disk_start := data.decode_u16(cursor + 34)
		var external_attrs := data.decode_u32(cursor + 38)
		var local_offset := data.decode_u32(cursor + 42)
		var next := cursor + 46 + name_len + extra_len + entry_comment_len
		if next > cd_end:
			_error(errors, "package.invalid", "Central directory entry %d runs past the directory." % index)
			return out

		if compressed_size == 0xFFFFFFFF or uncompressed_size == 0xFFFFFFFF or local_offset == 0xFFFFFFFF or disk_start == 0xFFFF:
			_error(errors, "package.zip64", "ZIP64 entry sizes are not supported.")
			return out
		if disk_start != 0:
			_error(errors, "package.invalid", "Multi-disk entries are not supported.")
			return out

		var name_bytes := data.slice(cursor + 46, cursor + 46 + name_len)
		var name := name_bytes.get_string_from_utf8()
		if name.is_empty() or name.to_utf8_buffer() != name_bytes:
			_error(errors, "package.invalid", "Entry %d has an empty or non-UTF-8 name." % index)
			return out

		# Extra fields: reject ZIP64 outright; parse defensively so a malformed
		# extra field cannot hide a second name or size.
		var extra_start := cursor + 46 + name_len
		if extra_len > 0:
			var extra := data.slice(extra_start, extra_start + extra_len)
			var offset := 0
			while offset + 4 <= extra.size():
				var tag := extra.decode_u16(offset)
				var field_size := extra.decode_u16(offset + 2)
				if offset + 4 + field_size > extra.size():
					_error(errors, "package.invalid", "Entry '%s' has a malformed extra field." % name)
					return out
				if tag == 0x0001:
					_error(errors, "package.zip64", "ZIP64 extra fields are not supported.")
					return out
				offset += 4 + field_size
			if offset != extra.size():
				_error(errors, "package.invalid", "Entry '%s' has trailing extra-field bytes." % name)
				return out

		# Encrypted archives (traditional, strong or masked-header) are never
		# accepted: we would have to ask for a password and the review UI cannot
		# show what is inside first.
		if (flags & 0x0001) != 0 or (flags & 0x0040) != 0 or (flags & 0x2000) != 0:
			_error(errors, "package.invalid", "Encrypted entries are not supported.")
			return out
		if method != 0 and method != 8:
			_error(errors, "package.invalid", "Entry '%s' uses unsupported compression method %d." % [name, method])
			return out

		var is_directory := name.ends_with("/")
		var path_problem := _path_problem(name, is_directory)
		if !path_problem.is_empty():
			_error(errors, "package.invalid", path_problem)
			return out
		var key := name.to_lower()
		if seen.has(key):
			_error(errors, "package.invalid", "The package contains '%s' more than once." % name)
			return out
		seen[key] = true

		var mode := (external_attrs >> 16) & 0xFFFF
		var type := mode & 0xF000
		if type == 0xA000:
			_error(errors, "package.invalid", "Entry '%s' is a symbolic link, which packages may not contain." % name)
			return out
		if type != 0 and type != 0x8000 and type != 0x4000:
			_error(errors, "package.invalid", "Entry '%s' is not a regular file or directory." % name)
			return out
		if is_directory:
			if type != 0 and type != 0x4000:
				_error(errors, "package.invalid", "Directory entry '%s' has a file type." % name)
				return out
			# Directory entries are never extracted. Godot's own ZIPPacker emits a
			# deflated empty directory entry (2 compressed bytes, 0 uncompressed),
			# so require zero content but tolerate the encoding overhead.
			if uncompressed_size != 0:
				_error(errors, "package.invalid", "Directory entry '%s' carries data." % name)
				return out
			if compressed_size > MAX_DIRECTORY_BYTES:
				_error(errors, "package.invalid", "Directory entry '%s' carries too much data." % name)
				return out
			counts["directories"] = int(counts["directories"]) + 1
		else:
			if type == 0x4000:
				_error(errors, "package.invalid", "File entry '%s' is marked as a directory." % name)
				return out
			var extension := name.get_extension().to_lower()
			if BLOCKED_EXTENSIONS.has(extension):
				_error(errors, "package.blocked_file", "Entry '%s' has a blocked extension (.%s)." % [name, extension])
				return out
			if uncompressed_size > MAX_ENTRY_UNCOMPRESSED:
				_error(errors, "package.too_large", "Entry '%s' is larger than %d bytes." % [name, MAX_ENTRY_UNCOMPRESSED])
				return out
			if compressed_size > MAX_PACKAGE_BYTES:
				_error(errors, "package.too_large", "Entry '%s' has an impossible compressed size." % name)
				return out
			if compressed_size == 0 and uncompressed_size > 0:
				_error(errors, "package.invalid", "Entry '%s' has data but no compressed bytes." % name)
				return out
			if method == 0 and compressed_size != uncompressed_size:
				_error(errors, "package.invalid", "Stored entry '%s' has different compressed and uncompressed sizes." % name)
				return out
			if method == 8 and uncompressed_size >= RATIO_MIN_BYTES:
				if compressed_size == 0 or uncompressed_size > compressed_size * MAX_COMPRESSION_RATIO:
					_error(errors, "package.compression_ratio", "Entry '%s' is compressed more than %d:1." % [name, MAX_COMPRESSION_RATIO])
					return out
			counts["files"] = int(counts["files"]) + 1
			sizes["compressed"] = int(sizes["compressed"]) + compressed_size
			sizes["uncompressed"] = int(sizes["uncompressed"]) + uncompressed_size
			if int(sizes["uncompressed"]) > MAX_TOTAL_UNCOMPRESSED:
				_error(errors, "package.too_large", "The package expands to more than %d bytes." % MAX_TOTAL_UNCOMPRESSED)
				return out

		var local := _check_local_header(data, cd_offset, local_offset, name_bytes, flags, method, compressed_size)
		if !local.get("ok", false):
			_error(errors, "package.invalid", str(local.get("message", "Invalid local header.")))
			return out

		entries.append({
			"path": name,
			"directory": is_directory,
			"method": method,
			"flags": flags,
			"crc32": crc,
			"compressed_size": compressed_size,
			"size": uncompressed_size,
			"local_offset": local_offset,
			"data_start": int(local["data_start"]),
			"data_end": int(local["data_start"]) + compressed_size,
			"external_attrs": external_attrs,
			"version_made_by": version_made,
		})
		cursor = next

	if cursor != cd_end:
		_error(errors, "package.invalid", "The ZIP central directory has trailing data.")
		return out

	# Local headers may appear in any order, but two entries may never share or
	# overlap the same bytes.
	var ranges: Array = []
	for entry in entries:
		ranges.append({"start": int(entry["local_offset"]), "end": int(entry["data_end"]), "name": str(entry["path"])})
	ranges.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["start"]) < int(b["start"]))
	var previous_end := 0
	for range_entry in ranges:
		if int(range_entry["start"]) < previous_end:
			_error(errors, "package.invalid", "Entries '%s' and a previous entry overlap." % str(range_entry["name"]))
			return out
		previous_end = int(range_entry["end"])

	# File/directory collisions: "a" and "a/b" cannot coexist after extraction.
	var names: Dictionary = {}
	for entry in entries:
		names[str(entry["path"]).trim_suffix("/").to_lower()] = bool(entry["directory"])
	for key in names.keys():
		var parts := str(key).split("/", true)
		var prefix := ""
		for index in range(parts.size() - 1):
			prefix = str(parts[index]) if prefix.is_empty() else prefix.path_join(str(parts[index]))
			if names.has(prefix) and !bool(names[prefix]):
				_error(errors, "package.invalid", "'%s' is a file but is also used as a directory." % prefix)
				return out

	out["ok"] = errors.is_empty()
	return out


static func _find_eocd(data: PackedByteArray) -> int:
	var minimum := maxi(0, data.size() - 65557)
	for offset in range(data.size() - 22, minimum - 1, -1):
		if data.decode_u32(offset) == SIG_EOCD:
			var comment_len := data.decode_u16(offset + 20)
			if offset + 22 + comment_len == data.size():
				return offset
	return -1


static func _check_local_header(
	data: PackedByteArray,
	cd_offset: int,
	local_offset: int,
	central_name: PackedByteArray,
	central_flags: int,
	central_method: int,
	compressed_size: int
) -> Dictionary:
	if local_offset < 0 or local_offset + 30 > cd_offset:
		return {"ok": false, "message": "A local header points outside the data area."}
	if data.decode_u32(local_offset) != SIG_LOCAL:
		return {"ok": false, "message": "A local header signature is invalid."}
	var flags := data.decode_u16(local_offset + 6)
	var method := data.decode_u16(local_offset + 8)
	var name_len := data.decode_u16(local_offset + 26)
	var extra_len := data.decode_u16(local_offset + 28)
	var data_start := local_offset + 30 + name_len + extra_len
	if data_start > cd_offset:
		return {"ok": false, "message": "A local header's name or extra field runs past the data area."}
	if flags != central_flags or method != central_method:
		return {"ok": false, "message": "A local header disagrees with the central directory."}
	var name := data.slice(local_offset + 30, local_offset + 30 + name_len)
	if name != central_name:
		return {"ok": false, "message": "A local header name disagrees with the central directory."}
	if data_start + compressed_size > cd_offset:
		return {"ok": false, "message": "An entry's data runs into the central directory."}
	return {"ok": true, "data_start": data_start}


# ── ARCHIVE CONTENTS ────────────────────────────────────────────────────────

static func _read_archive_files(path: String, entries: Array) -> Dictionary:
	var errors: Array = []
	var files: Array = []
	var reader := ZIPReader.new()
	if reader.open(path) != OK:
		_error(errors, "package.unreadable", "The ZIP reader could not open the package.")
		return {"ok": false, "errors": errors, "files": files}

	for entry in entries:
		if bool(entry.get("directory", false)):
			continue
		var relative := str(entry.get("path", ""))
		if !reader.file_exists(relative):
			_error(errors, "package.invalid", "The ZIP reader cannot see '%s'." % relative)
			continue
		var bytes := reader.read_file(relative)
		if bytes.size() != int(entry.get("size", -1)):
			_error(errors, "package.invalid", "Entry '%s' decompressed to the wrong size." % relative)
			continue
		if crc32(bytes) != int(entry.get("crc32", 0)):
			_error(errors, "package.invalid", "Entry '%s' failed its CRC check." % relative)
			continue
		files.append({"path": relative, "bytes": bytes})
	reader.close()
	return {"ok": errors.is_empty(), "errors": errors, "files": files}


# ── FOLDER COLLECTION ───────────────────────────────────────────────────────

static func _collect_folder(root: String) -> Dictionary:
	var errors: Array = []
	var files: Array = []
	var state := {"mtime": 0, "total": 0, "count": 0}
	_collect_folder_dir(root, "", files, errors, state)
	return {
		"ok": errors.is_empty(),
		"errors": errors,
		"files": files,
		"mtime": int(state["mtime"]),
		"total": int(state["total"]),
	}


static func _collect_folder_dir(directory: String, relative: String, files: Array, errors: Array, state: Dictionary) -> void:
	var dir := DirAccess.open(directory)
	if dir == null:
		_error(errors, "package.unreadable", "Could not read the folder: " + directory)
		return

	var names: Array = dir.get_files()
	names.sort()
	for raw_name in names:
		var name := str(raw_name)
		if name.ends_with(".griddy_tmp"):
			continue
		var path := directory.path_join(name)
		var relative_path := name if relative.is_empty() else relative.path_join(name)
		if dir.is_link(ProjectSettings.globalize_path(path)):
			_error(errors, "package.invalid", "'%s' is a symbolic link, which mod folders may not contain." % relative_path)
			continue
		var problem := _path_problem(relative_path, false)
		if !problem.is_empty():
			_error(errors, "package.invalid", problem)
			continue
		var extension := relative_path.get_extension().to_lower()
		if BLOCKED_EXTENSIONS.has(extension):
			_error(errors, "package.blocked_file", "'%s' has a blocked extension (.%s)." % [relative_path, extension])
			continue
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null:
			_error(errors, "package.unreadable", "Could not read '%s'." % relative_path)
			continue
		var size := file.get_length()
		file.close()
		if size > MAX_ENTRY_UNCOMPRESSED:
			_error(errors, "package.too_large", "'%s' is larger than %d bytes." % [relative_path, MAX_ENTRY_UNCOMPRESSED])
			continue
		state["total"] = int(state["total"]) + size
		if int(state["total"]) > MAX_TOTAL_UNCOMPRESSED:
			_error(errors, "package.too_large", "The folder expands to more than %d bytes." % MAX_TOTAL_UNCOMPRESSED)
			continue
		state["count"] = int(state["count"]) + 1
		if int(state["count"]) > MAX_ENTRIES:
			_error(errors, "package.too_large", "The folder has more than %d files." % MAX_ENTRIES)
			continue
		state["mtime"] = maxi(int(state["mtime"]), int(FileAccess.get_modified_time(path)))
		files.append({"path": relative_path, "bytes": FileAccess.get_file_as_bytes(path)})

	var folders: Array = dir.get_directories()
	folders.sort()
	for raw_folder in folders:
		var folder := str(raw_folder)
		var path := directory.path_join(folder)
		var relative_folder := folder if relative.is_empty() else relative.path_join(folder)
		if dir.is_link(ProjectSettings.globalize_path(path)):
			_error(errors, "package.invalid", "'%s' is a symbolic link, which mod folders may not contain." % relative_folder)
			continue
		_collect_folder_dir(path, relative_folder, files, errors, state)


# ── PATH RULES ──────────────────────────────────────────────────────────────

static func _path_problem(name: String, is_directory: bool) -> String:
	if name.is_empty() or name.length() > MAX_PATH_LENGTH:
		return "Entry names must be 1-%d characters." % MAX_PATH_LENGTH
	if name.contains("\\"):
		return "'%s' uses backslashes; package paths use forward slashes." % name
	if name.begins_with("/"):
		return "'%s' is an absolute path." % name
	if name.length() >= 2 and _is_ascii_letter(name.unicode_at(0)) and name.unicode_at(1) == 58:
		return "'%s' starts with a drive letter." % name

	var clean := name.trim_suffix("/") if is_directory else name
	if clean.is_empty():
		return "'%s' has an empty path." % name
	if name.ends_with("/") and !is_directory:
		return "'%s' ends with a slash but is not a directory entry." % name

	var segments := clean.split("/", true)
	if segments.is_empty():
		return "'%s' has an empty path." % name
	for segment in segments:
		var part := str(segment)
		if part.is_empty() or part == "." or part == "..":
			return "'%s' contains an empty, '.' or '..' segment." % name
		if part.ends_with(".") or part.ends_with(" "):
			return "'%s' has a segment ending in a dot or space." % part
		var lower := part.to_lower()
		var stem := lower.get_slice(".", 0)
		if RESERVED_NAMES.has(stem):
			return "'%s' uses the reserved Windows name '%s'." % [name, part]
		for index in range(part.length()):
			var code := part.unicode_at(index)
			if code < 0x20 or code == 0x7F:
				return "'%s' contains a control character." % name
			var character := char(code)
			if "<>:\"|?*".contains(character):
				return "'%s' contains the character '%s'." % [name, character]
	return ""


static func _is_ascii_letter(code: int) -> bool:
	return (code >= 65 and code <= 90) or (code >= 97 and code <= 122)


# ── SMALL HELPERS ───────────────────────────────────────────────────────────

static func crc32(bytes: PackedByteArray) -> int:
	_ensure_crc_table()
	var value := 0xFFFFFFFF
	for index in range(bytes.size()):
		value = (value >> 8) ^ int(_crc_table[(value ^ int(bytes[index])) & 0xFF])
	return (value ^ 0xFFFFFFFF) & 0xFFFFFFFF


static func _ensure_crc_table() -> void:
	if !_crc_table.is_empty():
		return
	_crc_table.resize(256)
	for index in range(256):
		var value := index
		for _bit in range(8):
			if (value & 1) != 0:
				value = (value >> 1) ^ 0xEDB88320
			else:
				value = value >> 1
		_crc_table[index] = value & 0xFFFFFFFF


static func _find_file(files: Array, path: String) -> Dictionary:
	for item in files:
		if str((item as Dictionary).get("path", "")) == path:
			return item
	return {}


static func _find_file_ci(files: Array, path: String) -> Dictionary:
	var key := path.to_lower()
	for item in files:
		if str((item as Dictionary).get("path", "")).to_lower() == key:
			return item
	return {}


static func _has_file(files: Array, path: String) -> bool:
	return !_find_file_ci(files, path).is_empty()


static func _public_files(files: Array) -> Array:
	var out: Array = []
	for item in files:
		out.append({
			"path": str((item as Dictionary).get("path", "")),
			"size": ((item as Dictionary).get("bytes", PackedByteArray()) as PackedByteArray).size(),
		})
	return out


static func _directory_is_empty(absolute: String) -> bool:
	var dir := DirAccess.open(absolute)
	if dir == null:
		return false
	return dir.get_files().is_empty() and dir.get_directories().is_empty()


static func _check_archive_signature(files: Array, digest: String) -> Dictionary:
	var entry := _find_file(files, SIGNATURE_FILE)
	if entry.is_empty():
		return {"present": false, "status": "unsigned", "ok": true}
	return check_signature_bytes(entry["bytes"], digest)


static func _error(errors: Array, code: String, message: String, field: String = "") -> void:
	var problem := {"code": code, "message": message}
	if !field.is_empty():
		problem["field"] = field
	errors.append(problem)
