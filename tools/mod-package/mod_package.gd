extends SceneTree

## Mod package tool.
##
##   godot --headless --path . --script res://tools/mod-package/mod_package.gd -- keygen ...
##
## Commands:
##   keygen  --publisher <id> --out <dir> [--display-name <name>] [--force]
##   pack    --dir <folder> --out <package.gcm>
##   sign    --package <input.gcm> --key <publisher.private.json> --out <signed.gcm>
##   digest  --package <package.gcm>
##   verify  --package <package.gcm> [--require-signature]
##
## The tool uses the same validator and signature code as the editor, so a
## package it creates follows the imported-package rules exactly. It never
## touches user://mods or the publisher trust store.

const Package = preload("res://src/features/mods/mod_package.gd")
const Ed25519 = preload("res://src/features/mods/ed25519.gd")

const KEY_SCHEMA := 1
const TOOL_TEMP := "user://mod_package_tool"


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty() or str(args[0]) == "--help" or str(args[0]) == "help":
		_usage()
		quit(0)
		return

	var command := str(args[0])
	var rest: Array = args.slice(1)
	var parsed := _parse(rest)
	var options: Dictionary = parsed.get("options", {})
	if bool(options.get("help", false)):
		_usage()
		quit(0)
		return

	match command:
		"keygen":
			quit(_keygen(options))
		"pack":
			quit(_pack(options))
		"sign":
			quit(_sign(options))
		"digest":
			quit(_digest(options))
		"verify":
			quit(_verify(options))
		_:
			printerr("Unknown command: " + command)
			_usage()
			quit(2)


func _usage() -> void:
	print("""Qorix package tool

  keygen  --publisher <id> --out <dir> [--display-name <name>] [--force]
          Creates <id>.private.json and <id>.public.json. Keep the private
          file secret: anyone with it can sign packages as this publisher.

  pack    --dir <folder> --out <package.gcm>
          Validates a mod folder and writes an unsigned package.

  sign    --package <input.gcm> --key <id.private.json> --out <signed.gcm>
          Signs a validated package. The input is not modified.

  digest  --package <package.gcm>
          Prints the canonical SHA-256 digest.

  verify  --package <package.gcm> [--require-signature]
          Validates the archive and verifies signature.json.

PowerShell wrapper: tools/mod-package/mod_package.ps1 <command> [options]
""")


# ── COMMANDS ────────────────────────────────────────────────────────────────

func _keygen(options: Dictionary) -> int:
	var publisher := str(options.get("publisher", "")).strip_edges()
	var out_dir := str(options.get("out", "")).strip_edges()
	var display_name := str(options.get("display-name", "")).strip_edges()
	if publisher.is_empty() or out_dir.is_empty():
		printerr("keygen needs --publisher and --out.")
		return 2
	if !Package.is_valid_publisher_id(publisher):
		printerr("'%s' is not a valid publisher id (2-64 characters: a-z, 0-9, dot, underscore, dash)." % publisher)
		return 2

	_ensure_dir(out_dir)
	var private_path := out_dir.path_join(publisher + ".private.json")
	var public_path := out_dir.path_join(publisher + ".public.json")
	if !bool(options.get("force", false)) and (FileAccess.file_exists(private_path) or FileAccess.file_exists(public_path)):
		printerr("A key file already exists in %s. Pass --force to replace it." % out_dir)
		return 1

	var seed := Ed25519.generate_seed()
	var public_key := Ed25519.public_key_from_seed(seed)
	var public_hex := Ed25519.bytes_to_hex(public_key)
	var fingerprint := Ed25519.fingerprint(public_key)
	var shown_name := display_name if !display_name.is_empty() else publisher

	var private_data := {
		"schema": KEY_SCHEMA,
		"publisher_id": publisher,
		"display_name": shown_name,
		"public_key": public_hex,
		"fingerprint": fingerprint,
		"seed": Ed25519.bytes_to_hex(seed),
	}
	var public_data := {
		"schema": KEY_SCHEMA,
		"publisher_id": publisher,
		"display_name": shown_name,
		"public_key": public_hex,
		"fingerprint": fingerprint,
	}
	var wrote_private := _write_json(private_path, private_data)
	if !wrote_private.get("ok", false):
		printerr(str(wrote_private.get("error", "Could not write the private key.")))
		return 1
	var wrote_public := _write_json(public_path, public_data)
	if !wrote_public.get("ok", false):
		printerr(str(wrote_public.get("error", "Could not write the public key.")))
		return 1

	print("Created %s" % private_path)
	print("Keep this file private. Anyone with it can sign packages as this publisher.")
	print("Public key:   %s" % public_hex)
	print("Fingerprint:  %s" % fingerprint)
	print("Public file:  %s" % public_path)
	return 0


func _pack(options: Dictionary) -> int:
	var folder := str(options.get("dir", "")).strip_edges()
	var out_path := str(options.get("out", "")).strip_edges()
	if folder.is_empty() or out_path.is_empty():
		printerr("pack needs --dir and --out.")
		return 2
	if !_valid_output_extension(out_path):
		printerr("Packages must end in .gcm or .zip.")
		return 2

	var valid := Package.validate_folder(folder)
	if !bool(valid.get("ok", false)):
		_print_errors(valid.get("errors", []))
		return 1

	var read := Package.read_folder_files(folder)
	if !bool(read.get("ok", false)):
		_print_errors(read.get("errors", []))
		return 1
	var files: Dictionary = read["files"]
	if files.erase(Package.SIGNATURE_FILE):
		print("Excluded the existing signature.json; run sign after packing.")

	var packed := Package.pack(files, out_path)
	if !bool(packed.get("ok", false)):
		printerr(_message_of(packed))
		return 1
	print("Wrote %s (%d file(s))." % [out_path, int((packed.get("value", {}) as Dictionary).get("files", 0))])
	print("Digest: %s" % str(valid.get("digest", "")))
	print("This package is unsigned. Run sign before sharing it.")
	return 0


func _sign(options: Dictionary) -> int:
	var package_path := str(options.get("package", "")).strip_edges()
	var key_path := str(options.get("key", "")).strip_edges()
	var out_path := str(options.get("out", "")).strip_edges()
	if package_path.is_empty() or key_path.is_empty() or out_path.is_empty():
		printerr("sign needs --package, --key and --out.")
		return 2
	if !_valid_output_extension(out_path):
		printerr("Packages must end in .gcm or .zip.")
		return 2
	if _same_path(package_path, out_path):
		printerr("The signed package must use a different path from the input.")
		return 2

	var key := _read_json(key_path)
	if !bool(key.get("ok", false)):
		printerr(str(key.get("error", "Could not read the key file.")))
		return 1
	var key_data: Dictionary = key["data"]
	var publisher := str(key_data.get("publisher_id", ""))
	var seed := Ed25519.hex_to_bytes(str(key_data.get("seed", "")))
	if !Package.is_valid_publisher_id(publisher) or seed.size() != 32:
		printerr("The key file is not a valid Qorix publisher key.")
		return 1

	var validation := Package.validate_archive(package_path)
	if !bool(validation.get("ok", false)):
		_print_errors(validation.get("errors", []))
		return 1
	var digest := str(validation.get("digest", ""))
	if digest.length() != 64:
		printerr("The package digest could not be computed.")
		return 1

	var temp := TOOL_TEMP.path_join("sign-%d" % Time.get_ticks_usec())
	var extracted := Package.extract(package_path, validation.get("entries", []), temp)
	if !bool(extracted.get("ok", false)):
		_remove_tree(temp)
		printerr(_message_of(extracted))
		return 1
	var read := Package.read_folder_files(temp)
	if !bool(read.get("ok", false)):
		_remove_tree(temp)
		_print_errors(read.get("errors", []))
		return 1
	var files: Dictionary = read["files"]
	files.erase(Package.SIGNATURE_FILE)

	var public_hex := Ed25519.bytes_to_hex(Ed25519.public_key_from_seed(seed))
	var fingerprint := Ed25519.fingerprint(Ed25519.hex_to_bytes(public_hex))
	var signature := {
		"schema": 1,
		"algorithm": "ed25519",
		"publisher_id": publisher,
		"public_key": public_hex,
		"signature": Ed25519.bytes_to_hex(Ed25519.sign(
			Ed25519.package_message(digest, publisher, public_hex),
			seed,
		)),
		"package_hash": digest,
		"key_id": fingerprint,
		"signed_at": int(options.get("signed-at", Time.get_unix_time_from_system())),
		"display_name": str(key_data.get("display_name", publisher)),
	}
	files[Package.SIGNATURE_FILE] = JSON.stringify(signature, "  ").to_utf8_buffer()

	var packed := Package.pack(files, out_path)
	_remove_tree(temp)
	if !bool(packed.get("ok", false)):
		printerr(_message_of(packed))
		return 1

	var verified := Package.validate_archive(out_path)
	if !bool(verified.get("ok", false)):
		_print_errors(verified.get("errors", []))
		return 1
	var check: Dictionary = verified.get("signature", {}) if verified.get("signature") is Dictionary else {}
	if !bool(check.get("ok", false)):
		printerr("The signed package did not verify: " + str(check.get("error", "unknown error")))
		return 1

	print("Wrote %s" % out_path)
	print("Publisher:   %s" % publisher)
	print("Fingerprint: %s" % fingerprint)
	print("Digest:      %s" % digest)
	return 0


func _digest(options: Dictionary) -> int:
	var package_path := str(options.get("package", "")).strip_edges()
	if package_path.is_empty():
		printerr("digest needs --package.")
		return 2
	var validation := Package.validate_archive(package_path)
	if !bool(validation.get("ok", false)):
		_print_errors(validation.get("errors", []))
		return 1
	print(str(validation.get("digest", "")))
	return 0


func _verify(options: Dictionary) -> int:
	var package_path := str(options.get("package", "")).strip_edges()
	if package_path.is_empty():
		printerr("verify needs --package.")
		return 2
	var validation := Package.validate_archive(package_path)
	if !bool(validation.get("ok", false)):
		_print_errors(validation.get("errors", []))
		return 1

	var manifest: Dictionary = validation.get("manifest", {}) if validation.get("manifest") is Dictionary else {}
	var signature: Dictionary = validation.get("signature", {}) if validation.get("signature") is Dictionary else {}
	print("Package:     %s" % package_path)
	print("Mod:         %s v%s" % [str(manifest.get("id", "")), str(manifest.get("version", ""))])
	print("Digest:      %s" % str(validation.get("digest", "")))
	if bool(signature.get("present", false)):
		print("Signature:   %s" % ("valid" if bool(signature.get("ok", false)) else "invalid"))
		print("Publisher:   %s" % str(signature.get("publisher_id", "")))
		print("Fingerprint: %s" % str(signature.get("fingerprint", "")))
		if !bool(signature.get("ok", false)):
			print("Error:       %s" % str(signature.get("error", "")))
			return 1
	else:
		print("Signature:   unsigned")
		if bool(options.get("require-signature", false)):
			printerr("--require-signature was set but the package is unsigned.")
			return 1
	return 0


# ── ARGUMENTS AND FILES ─────────────────────────────────────────────────────

func _parse(args: Array) -> Dictionary:
	var options := {}
	var positionals: Array = []
	var index := 0
	while index < args.size():
		var arg := str(args[index])
		if arg.begins_with("--"):
			var key := arg.substr(2)
			if key == "help" or key == "force" or key == "require-signature":
				options[key] = true
				index += 1
			elif index + 1 < args.size():
				options[key] = str(args[index + 1])
				index += 2
			else:
				printerr("Option --%s needs a value." % key)
				index += 1
		else:
			positionals.append(arg)
			index += 1
	return {"options": options, "positionals": positionals}


func _read_json(path: String) -> Dictionary:
	if !FileAccess.file_exists(path):
		return {"ok": false, "error": "The file does not exist: " + path}
	var text := FileAccess.get_file_as_string(path)
	var json := JSON.new()
	if json.parse(text) != OK:
		return {"ok": false, "error": "Invalid JSON in %s: %s" % [path, json.get_error_message()]}
	if !(json.data is Dictionary):
		return {"ok": false, "error": "%s must contain a JSON object." % path}
	return {"ok": true, "data": json.data}


func _write_json(path: String, data: Dictionary) -> Dictionary:
	_ensure_dir(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return {"ok": false, "error": "Could not write " + path}
	file.store_string(JSON.stringify(data, "  ") + "\n")
	file.close()
	return {"ok": true}


func _ensure_dir(path: String) -> void:
	if path.is_empty():
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path))


func _valid_output_extension(path: String) -> bool:
	return Package.PACKAGE_EXTENSIONS.has(path.get_extension().to_lower())


func _same_path(left: String, right: String) -> bool:
	return ProjectSettings.globalize_path(left).simplify_path().to_lower() == ProjectSettings.globalize_path(right).simplify_path().to_lower()


func _print_errors(errors: Variant) -> void:
	if !(errors is Array):
		printerr("The package is invalid.")
		return
	for raw in errors:
		if raw is Dictionary:
			printerr("- %s" % str((raw as Dictionary).get("message", "")))
	if (errors as Array).is_empty():
		printerr("The package is invalid.")


func _message_of(result: Dictionary) -> String:
	var failure: Dictionary = result.get("error", {}) if result.get("error") is Dictionary else {}
	return str(failure.get("message", "The operation failed."))


func _remove_tree(path: String) -> void:
	var absolute := ProjectSettings.globalize_path(path)
	if !DirAccess.dir_exists_absolute(absolute):
		return
	var directory := DirAccess.open(path)
	if directory == null:
		DirAccess.remove_absolute(absolute)
		return
	for name in directory.get_files():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path.path_join(str(name))))
	for name in directory.get_directories():
		_remove_tree(path.path_join(str(name)))
	DirAccess.remove_absolute(absolute)
