extends TestCase

## Phase 6 import UI. Drives the real Mods page against a fake manager so the
## review dialog, consent gate, signature/risk rendering and lifecycle controls
## are checked without paying Ed25519 costs or touching user://mods.

const SettingsPanel = preload("res://src/features/mods/ui/mod_settings_panel.gd")

const MOD_ID := "griddycode.import_ui"
const FINGERPRINT := "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
const OLD_FINGERPRINT := "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
const HASH := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"


class FakeManager:
	var review: Dictionary = {}
	var inspect_calls: Array = []
	var import_calls: Array = []
	var rollback_calls: Array = []
	var uninstall_calls: Array = []
	var installed_records: Array = []
	var publisher_map: Dictionary = {}
	var permission_map: Dictionary = {}
	var developer_mode: bool = false
	var preview_build: bool = false

	func installed() -> Array:
		return installed_records.duplicate(true)

	func state(id: String) -> Dictionary:
		return {
			"id": id,
			"name": "Card Mod",
			"version": "2.0.0",
			"status": "active",
			"reason": "",
			"missing_permissions": [],
		}

	func pending_activations() -> int:
		return 0

	func settings_for(_id: String) -> Dictionary:
		return {"definitions": [], "values": {}}

	func set_mod_setting(_id: String, _key: String, _value: Variant) -> Dictionary:
		return {"ok": true}

	func set_enabled(_id: String, _enabled: bool, _reason: String = "") -> Dictionary:
		return {"ok": true}

	func reload_mod(_id: String) -> Dictionary:
		return {"ok": true}

	func grant_consent(_id: String, _permissions: Array = []) -> Dictionary:
		return {"ok": true}

	func publisher_state(_signature: Dictionary) -> Dictionary:
		return publisher_map.duplicate(true)

	func registry_permissions(id: String) -> Array:
		var found: Variant = permission_map.get(id)
		return (found as Array).duplicate() if found is Array else []

	func inspect_package(path: String, options: Dictionary = {}) -> Dictionary:
		inspect_calls.append({"path": path, "options": options.duplicate(true)})
		var result: Dictionary = review.duplicate(true)
		var raw_blockers: Array = result.get("blockers", []) if result.get("blockers") is Array else []
		var kept: Array = []
		for raw in raw_blockers:
			if !(raw is Dictionary):
				continue
			var code := str((raw as Dictionary).get("code", ""))
			var keep := true
			match code:
				"publisher.trust_required":
					keep = !bool(options.get("trust_publisher", false))
				"publisher.key_changed":
					keep = !(bool(options.get("trust_publisher", false)) and bool(options.get("replace_key", false)))
				"signature.required":
					keep = !bool(options.get("allow_unsigned", false))
				"update.exists":
					keep = !bool(options.get("replace", false))
				"update.downgrade":
					keep = !bool(options.get("allow_downgrade", false))
			if keep:
				kept.append(raw)
		result["blockers"] = kept
		result["can_install"] = kept.is_empty() and bool(result.get("base_can_install", true))
		return {"ok": true, "value": result}

	func import_package(path: String, options: Dictionary = {}) -> Dictionary:
		import_calls.append({"path": path, "options": options.duplicate(true)})
		return {
			"ok": true,
			"value": {
				"install": {"id": MOD_ID, "version": "1.2.0", "previous_version": ""},
				"review": review.duplicate(true),
				"activated": bool(options.get("activate", true)),
				"activation_error": {},
				"state": {},
			},
		}

	func rollback_mod(id: String, options: Dictionary = {}) -> Dictionary:
		rollback_calls.append({"id": id, "options": options.duplicate(true)})
		return {
			"ok": true,
			"value": {
				"rollback": {"version": "1.9.0"},
				"activated": true,
				"activation_error": {},
				"state": {},
			},
		}

	func uninstall_mod(id: String, options: Dictionary = {}) -> Dictionary:
		uninstall_calls.append({"id": id, "options": options.duplicate(true)})
		var remove_data := bool(options.get("remove_data", false))
		return {
			"ok": true,
			"value": {
				"removed_versions": 2,
				"data_removed": remove_data,
				"data_kept": !remove_data,
			},
		}


# ── IMPORT REVIEW ───────────────────────────────────────────────────────────

func test_review_surfaces_publisher_permissions_and_requires_consent() -> void:
	var fake := FakeManager.new()
	fake.review = _review()
	var panel = _panel(fake)
	panel.open_import("user://fixture.gcm")

	assert_eq(str(panel._import_review.get("name", "")), "Import UI Test", "review loaded")
	check(panel._import_dialog.title.contains("Import UI Test"), "review dialog titled for the package")
	var text := _text(panel._import_body)
	check(text.contains("Publisher id: com.example.ui"), "publisher id shown")
	check(text.contains("This publisher is not trusted yet"), "new publisher warning shown")
	check(text.contains("Key fingerprint: bbbb bbbb bbbb bbbb"), "short fingerprint shown")
	check(text.contains("documents.write"), "added permission shown")
	check(text.contains("medium"), "permission risk shown")
	check(text.contains("edits, open, save"), "permission grant shown")
	check(text.contains("Must be resolved"), "blockers shown")
	check(panel._import_dialog.get_ok_button().disabled, "install disabled before trust and consent")

	var trust = _checkbox(panel._import_body, "Trust publisher")
	check(trust != null, "trust checkbox rendered")
	if trust != null:
		(trust as CheckBox).button_pressed = true
		panel._refresh_import()
	check(panel._import_dialog.get_ok_button().disabled, "consent still gates install")

	var consent = _checkbox(panel._import_body, "I accept these permissions")
	check(consent != null, "consent checkbox rendered")
	if consent != null:
		(consent as CheckBox).button_pressed = true
		panel._refresh_import()
	check(!panel._import_dialog.get_ok_button().disabled, "install enabled after trust and consent")

	panel._on_import_confirmed()
	assert_eq(fake.import_calls.size(), 1, "import called once")
	if !fake.import_calls.is_empty():
		var options: Dictionary = (fake.import_calls[0] as Dictionary).get("options", {})
		check(bool(options.get("trust_publisher", false)), "trust option passed to install")
		check(bool(options.get("consent", false)), "consent option passed to install")
		check(bool(options.get("activate", true)), "activation defaults to on")
	check(panel._status.text.contains("Installed"), "success status shown")
	panel.free()


func test_key_change_requires_trust_and_key_replacement() -> void:
	var fake := FakeManager.new()
	var review := _review()
	review["permission_growth"] = _growth([], false)
	review["warnings"] = []
	review["publisher"] = {
		"status": "key_changed",
		"trusted": false,
		"requires_trust": true,
		"publisher_id": "com.example.ui",
		"fingerprint": FINGERPRINT,
		"public_key": "c".repeat(64),
		"display_name": "UI Publisher",
		"stored_fingerprint": OLD_FINGERPRINT,
		"reason": "The signing key changed.",
	}
	review["blockers"] = [{"code": "publisher.key_changed", "message": "Publisher changed its signing key."}]
	fake.review = review

	var panel = _panel(fake)
	panel.open_import("user://fixture.gcm")
	var text := _text(panel._import_body)
	check(text.contains("The signing key for UI Publisher changed."), "key change warning shown")
	check(text.contains("Previously pinned key: dddd dddd dddd dddd"), "old fingerprint shown")

	var trust = _checkbox(panel._import_body, "Replace the pinned key")
	check(trust != null, "replace-key checkbox rendered")
	if trust != null:
		(trust as CheckBox).button_pressed = true
		panel._refresh_import()
	check(!panel._import_dialog.get_ok_button().disabled, "install enabled after re-trust")
	if !fake.inspect_calls.is_empty():
		var options: Dictionary = (fake.inspect_calls[fake.inspect_calls.size() - 1] as Dictionary).get("options", {})
		check(bool(options.get("trust_publisher", false)), "trust flag set")
		check(bool(options.get("replace_key", false)), "replace_key set with trust")
	panel.free()


func test_invalid_signature_disables_install_and_hides_trust() -> void:
	var fake := FakeManager.new()
	var review := _review()
	review["signature"] = {
		"present": true,
		"ok": false,
		"status": "invalid",
		"publisher_id": "com.example.ui",
		"fingerprint": FINGERPRINT,
		"public_key": "c".repeat(64),
		"display_name": "UI Publisher",
		"signed_at": 1700000000,
		"error": "The Ed25519 signature does not verify.",
	}
	review["publisher"] = {
		"status": "invalid", "trusted": false, "requires_trust": false,
		"publisher_id": "com.example.ui", "fingerprint": FINGERPRINT,
		"public_key": "c".repeat(64), "display_name": "UI Publisher",
		"stored_fingerprint": "", "reason": "",
	}
	review["permission_growth"] = _growth([], false)
	review["warnings"] = []
	review["blockers"] = [{"code": "signature.invalid", "message": "The signature is invalid."}]
	fake.review = review

	var panel = _panel(fake)
	panel.open_import("user://fixture.gcm")
	var text := _text(panel._import_body)
	check(text.contains("Signature invalid: The Ed25519 signature does not verify."), "signature error shown")
	check(panel._import_dialog.get_ok_button().disabled, "invalid signature cannot be installed")
	check(_checkbox(panel._import_body, "Trust publisher") == null, "no trust prompt for an invalid signature")
	check(_checkbox(panel._import_body, "Allow this unsigned package") == null, "no unsigned prompt")
	panel.free()


func test_unsigned_package_requires_explicit_opt_in() -> void:
	var fake := FakeManager.new()
	var review := _review()
	review["unsigned"] = true
	review["signature"] = {"present": false, "ok": true, "status": "unsigned"}
	review["publisher"] = {"status": "unsigned", "trusted": false, "requires_trust": false}
	review["permission_growth"] = _growth([], false)
	review["warnings"] = []
	review["blockers"] = [{"code": "signature.required", "message": "This package is unsigned."}]
	fake.review = review

	var panel = _panel(fake)
	panel.open_import("user://fixture.gcm")
	check(_text(panel._import_body).contains("This package is unsigned"), "unsigned warning shown")
	check(panel._import_dialog.get_ok_button().disabled, "unsigned package blocked by default")
	var allow = _checkbox(panel._import_body, "Allow this unsigned package")
	check(allow != null, "unsigned opt-in rendered")
	if allow != null:
		(allow as CheckBox).button_pressed = true
		panel._refresh_import()
	check(!panel._import_dialog.get_ok_button().disabled, "opt-in allows install")
	panel._on_import_confirmed()
	if !fake.import_calls.is_empty():
		var options: Dictionary = (fake.import_calls[0] as Dictionary).get("options", {})
		check(bool(options.get("allow_unsigned", false)), "unsigned option passed to install")
	panel.free()


func test_permission_growth_needs_consent_and_honors_activate_off() -> void:
	var fake := FakeManager.new()
	var review := _review()
	review["blockers"] = []
	review["warnings"] = [{"code": "permission.growth", "message": "This update adds permissions: files.write"}]
	review["publisher"] = {
		"status": "trusted", "trusted": true, "requires_trust": false,
		"publisher_id": "com.example.ui", "fingerprint": FINGERPRINT,
		"public_key": "c".repeat(64), "display_name": "UI Publisher",
		"stored_fingerprint": FINGERPRINT, "reason": "",
	}
	review["permission_growth"] = {
		"first_consent": false,
		"growing": true,
		"requires_consent": true,
		"added": ["files.write"],
		"removed": [],
		"declared": ["documents.write", "files.write"],
		"sensitive": ["documents.write", "files.write"],
		"consented": ["documents.write"],
		"details": [{
			"name": "files.write",
			"risk": "high",
			"consent": "explicit+trust",
			"grants": "workspace files",
		}],
	}
	review["update"] = {
		"kind": "update",
		"current_version": "1.0.0",
		"current_hash": "e".repeat(64),
		"incoming_version": "1.2.0",
		"incoming_hash": HASH,
		"previous_version": "1.0.0",
		"target_path": "user://mods/griddycode.import_ui/1.2.0",
		"target_exists": false,
		"can_rollback": true,
	}
	fake.review = review

	var panel = _panel(fake)
	panel.open_import("user://fixture.gcm")
	check(_text(panel._import_body).contains("This update adds 1 permission(s)"), "growth copy shown")
	check(panel._import_dialog.get_ok_button().disabled, "growth blocks install until accepted")
	var consent = _checkbox(panel._import_body, "I accept these permissions")
	check(consent != null, "growth consent checkbox rendered")
	if consent != null:
		(consent as CheckBox).button_pressed = true
		panel._refresh_import()
	check(!panel._import_dialog.get_ok_button().disabled, "install enabled after consent")

	var activate = _checkbox(panel._import_body, "Activate after installing")
	check(activate != null, "activate checkbox rendered")
	if activate != null:
		(activate as CheckBox).button_pressed = false
	panel._on_import_confirmed()
	if !fake.import_calls.is_empty():
		var options: Dictionary = (fake.import_calls[0] as Dictionary).get("options", {})
		check(bool(options.get("consent", false)), "consent recorded")
		check(!bool(options.get("activate", true)), "activation can be turned off")
	panel.free()


# ── INSTALLED CARD AND LIFECYCLE ────────────────────────────────────────────

func test_card_shows_signature_permission_risk_rollback_and_uninstall() -> void:
	var fake := FakeManager.new()
	fake.installed_records = [_record()]
	fake.publisher_map = {
		"status": "trusted",
		"trusted": true,
		"requires_trust": false,
		"publisher_id": "com.example.ui",
		"fingerprint": FINGERPRINT,
		"public_key": "c".repeat(64),
		"display_name": "UI Publisher",
		"stored_fingerprint": FINGERPRINT,
		"reason": "",
	}
	fake.permission_map[MOD_ID] = ["files.read", "documents.write"]

	var panel = _panel(fake)
	panel.refresh()
	var text := _text(panel._list)
	check(text.contains("Verified signature · UI Publisher · key bbbb bbbb bbbb bbbb"), "signature chip shown")
	check(text.contains("Permissions: 1 high, 1 medium"), "risk summary shown")
	check(text.contains("No settings declared."), "settings empty state shown")

	var rollback = _button(panel._list, "Roll back to v1.9.0")
	check(rollback != null, "rollback button shown")
	if rollback != null:
		(rollback as Button).emit_signal("pressed")
		var dialog = _dialog(panel, "Roll back")
		check(dialog != null, "rollback confirmation opens")
		if dialog != null:
			(dialog as ConfirmationDialog).confirmed.emit()
		assert_eq(fake.rollback_calls.size(), 1, "rollback called")
		check(panel._status.text.contains("Rolled Card Mod back to v1.9.0"), "rollback status shown")
		panel.refresh()

	var uninstall = _button(panel._list, "Uninstall")
	check(uninstall != null, "uninstall button shown")
	if uninstall != null:
		(uninstall as Button).emit_signal("pressed")
		var dialog = _dialog(panel, "Uninstall")
		check(dialog != null, "uninstall confirmation opens")
		if dialog != null:
			(dialog as ConfirmationDialog).custom_action.emit(&"remove_data")
		assert_eq(fake.uninstall_calls.size(), 1, "uninstall called")
		if !fake.uninstall_calls.is_empty():
			var options: Dictionary = (fake.uninstall_calls[0] as Dictionary).get("options", {})
			check(bool(options.get("remove_data", false)), "remove_data passed")
		check(panel._status.text.contains("Mod data was deleted."), "deletion status shown")
	panel.free()


func test_uninstall_keeps_data_by_default() -> void:
	var fake := FakeManager.new()
	fake.installed_records = [_record()]
	fake.publisher_map = {
		"status": "trusted", "trusted": true, "requires_trust": false,
		"publisher_id": "com.example.ui", "fingerprint": FINGERPRINT,
		"public_key": "c".repeat(64), "display_name": "UI Publisher",
		"stored_fingerprint": FINGERPRINT, "reason": "",
	}
	fake.permission_map[MOD_ID] = []
	var panel = _panel(fake)
	panel.refresh()
	var uninstall = _button(panel._list, "Uninstall")
	if uninstall != null:
		(uninstall as Button).emit_signal("pressed")
		var dialog = _dialog(panel, "Uninstall")
		if dialog != null:
			(dialog as ConfirmationDialog).confirmed.emit()
	assert_eq(fake.uninstall_calls.size(), 1, "uninstall called")
	if !fake.uninstall_calls.is_empty():
		var options: Dictionary = (fake.uninstall_calls[0] as Dictionary).get("options", {})
		check(!bool(options.get("remove_data", true)), "remove_data defaults off")
	check(panel._status.text.contains("Mod data was kept"), "kept-data status shown")
	panel.free()


# ── FIXTURES ────────────────────────────────────────────────────────────────

func _review() -> Dictionary:
	return {
		"id": MOD_ID,
		"name": "Import UI Test",
		"version": "1.2.0",
		"author": "UI Author",
		"description": "A review dialog fixture.",
		"entry": "main.lua",
		"manifest": {"permissions": ["documents.write"]},
		"entries": [],
		"counts": {"files": 3, "directories": 1},
		"sizes": {"compressed": 2048, "uncompressed": 4096},
		"hash": HASH,
		"signature": {
			"present": true,
			"ok": true,
			"status": "valid",
			"publisher_id": "com.example.ui",
			"fingerprint": FINGERPRINT,
			"public_key": "c".repeat(64),
			"display_name": "UI Publisher",
			"signed_at": 1700000000,
			"error": "",
		},
		"publisher": {
			"status": "new",
			"trusted": false,
			"requires_trust": true,
			"publisher_id": "com.example.ui",
			"fingerprint": FINGERPRINT,
			"public_key": "c".repeat(64),
			"display_name": "UI Publisher",
			"stored_fingerprint": "",
			"reason": "This is the first package from 'com.example.ui'.",
		},
		"unsigned": false,
		"allow_unsigned": false,
		"trust_publisher": false,
		"permission_growth": _growth(["documents.write"], true),
		"update": {
			"kind": "install",
			"current_version": "",
			"current_hash": "",
			"incoming_version": "1.2.0",
			"incoming_hash": HASH,
			"previous_version": "",
			"target_path": "user://mods/griddycode.import_ui/1.2.0",
			"target_exists": false,
			"can_rollback": false,
		},
		"blockers": [{"code": "publisher.trust_required", "message": "Publisher 'com.example.ui' has not been trusted yet."}],
		"warnings": [{"code": "consent.required", "message": "This mod needs consent for: documents.write"}],
		"can_install": false,
		"can_activate": false,
		"base_can_install": true,
	}


func _growth(added: Array, first: bool) -> Dictionary:
	var details: Array = []
	for name in added:
		details.append({
			"name": str(name),
			"risk": "high" if str(name) == "files.write" else "medium",
			"consent": "explicit",
			"grants": "workspace files" if str(name) == "files.write" else "edits, open, save",
		})
	return {
		"first_consent": first,
		"growing": !first and !added.is_empty(),
		"requires_consent": !added.is_empty(),
		"added": added.duplicate(),
		"removed": [],
		"declared": added.duplicate(),
		"sensitive": added.duplicate(),
		"consented": [] if first else added.duplicate(),
		"details": details,
	}


func _record() -> Dictionary:
	return {
		"id": MOD_ID,
		"name": "Card Mod",
		"version": "2.0.0",
		"root": "user://mods/griddycode.import_ui/2.0.0",
		"hash": HASH,
		"dev": false,
		"signature": {
			"present": true,
			"ok": true,
			"status": "valid",
			"publisher_id": "com.example.ui",
			"fingerprint": FINGERPRINT,
			"public_key": "c".repeat(64),
			"display_name": "UI Publisher",
			"signed_at": 1700000000,
			"error": "",
		},
		"signature_status": "valid",
		"publisher_id": "com.example.ui",
		"publisher_fingerprint": FINGERPRINT,
		"previous_version": "1.9.0",
		"allow_unsigned": false,
	}


func _panel(manager: FakeManager) -> Control:
	var panel: Control = SettingsPanel.new()
	panel.setup(manager)
	Engine.get_main_loop().root.add_child(panel)
	if panel._list == null:
		panel._ready()
	return panel


func _text(node: Node) -> String:
	var out: Array[String] = []
	_collect_text(node, out)
	return "\n".join(out)


func _collect_text(node: Node, out: Array[String]) -> void:
	if node is Label:
		out.append((node as Label).text)
	elif node is Button:
		out.append((node as Button).text)
	for child in node.get_children():
		_collect_text(child, out)


func _checkbox(node: Node, fragment: String) -> CheckBox:
	if node is CheckBox and (node as CheckBox).text.contains(fragment):
		return node as CheckBox
	for child in node.get_children():
		var found := _checkbox(child, fragment)
		if found != null:
			return found
	return null


func _button(node: Node, fragment: String) -> Button:
	if node is Button and !(node is CheckBox) and (node as Button).text.contains(fragment):
		return node as Button
	for child in node.get_children():
		var found := _button(child, fragment)
		if found != null:
			return found
	return null


func _dialog(panel: Node, title_fragment: String) -> ConfirmationDialog:
	for child in panel.get_children():
		if child is ConfirmationDialog and str((child as ConfirmationDialog).title).contains(title_fragment):
			return child as ConfirmationDialog
	return null
