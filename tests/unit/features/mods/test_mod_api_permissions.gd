extends "res://tests/support/test_case.gd"

## Phase 2 API boundary: every new method has a permission, missing services
## fail closed, and trust gates still apply to files/run.

const Api = preload("res://src/features/mods/api/api_v1.gd")
const Permissions = preload("res://src/features/mods/mod_permissions.gd")
const Result = preload("res://src/features/mods/mod_result.gd")


class TrustStub:
	var trusted: bool = false

	func is_trusted(_root: String) -> bool:
		return trusted


func _api(services: Dictionary = {}):
	return Api.new({"id": "griddycode.phase2", "name": "Phase 2", "version": "1.0.0"}, services)


func test_phase2_methods_have_the_expected_permission() -> void:
	var expected := {
		"docs.active": "documents.read",
		"docs.set_text": "documents.write",
		"docs.save": "documents.write",
		"files.read": "files.read",
		"files.write": "files.write",
		"run.file": "run",
		"clipboard.read": "clipboard.read",
		"dialogs.prompt": "core",
		"ui.mount": "core",
		"ui.layout.set_visible": "ui.layout",
	}
	var surface := {}
	for entry in _api().surface():
		surface[str(entry["name"])] = str(entry["permission"])
	for name in expected.keys():
		assert_eq(surface.get(name, ""), expected[name], "permission for " + name)


func test_missing_services_fail_closed_instead_of_crashing() -> void:
	var api = _api({})
	var ui: Dictionary = api.invoke("ui.mount", {"slot": "right", "spec": {"type": "label"}})
	assert_eq(Result.code_of(ui), "state.invalid")
	var dialog: Dictionary = api.invoke("dialogs.confirm", {"title": "x"})
	assert_eq(Result.code_of(dialog), "state.invalid")


func test_document_permissions_are_enforced() -> void:
	var permissions = Permissions.new()
	permissions.set_active("griddycode.phase2", ["core", "documents.read"])
	var api = _api({"permissions": permissions, "docs": _DocsStub.new()})

	var readable: Dictionary = api.invoke("docs.active")
	check(readable.get("ok", false), "declared read permission is allowed")
	var denied: Dictionary = api.invoke("docs.set_text", {"doc": 1, "text": "x"})
	assert_eq(Result.code_of(denied), "permission.denied")

	permissions.set_active("griddycode.phase2", ["core", "documents.write"])
	var write_allowed: Dictionary = api.invoke("docs.set_text", {"doc": 1, "text": "x"})
	check(write_allowed.get("ok", false), "declared write permission is allowed")


func test_files_permission_is_intersected_with_workspace_trust() -> void:
	var permissions = Permissions.new()
	permissions.set_active("griddycode.phase2", ["core", "files.read"])
	var trust := TrustStub.new()
	var api = _api({
		"permissions": permissions,
		"files": _FilesStub.new(),
		"trust": trust,
		"workspace_root": Callable(self, "_root"),
	})

	var denied: Dictionary = api.invoke("files.read", {"path": "a.txt"})
	assert_eq(Result.code_of(denied), "trust.required")

	trust.trusted = true
	var allowed: Dictionary = api.invoke("files.read", {"path": "a.txt"})
	check(allowed.get("ok", false), "trusted workspace allows the read")


func test_unknown_phase2_method_is_rejected() -> void:
	var result: Dictionary = _api().invoke("docs.definitely_not_real", {})
	assert_eq(Result.code_of(result), "api.unknown_method")


func test_mods_cannot_change_the_workspace_root() -> void:
	# A mod-supplied `confirmed` flag is not a user decision. The host owns the
	# folder picker, so the method is gone from API 1 rather than trusted.
	var result: Dictionary = _api().invoke("workspace.open_folder", {
		"path": "C:/somewhere-else",
		"confirmed": true,
	})
	assert_eq(Result.code_of(result), "api.unknown_method")


func test_result_catalogue_covers_phase2_codes() -> void:
	for code in [
		"doc.not_found", "doc.open_failed", "doc.invalid_position", "doc.too_large",
		"doc.unsaved", "doc.save_failed", "doc.dirty", "workspace.required",
		"workspace.open_failed", "module.unreadable", "module.too_large",
		"module.unwritable", "module.not_empty", "ui.confirmation_required",
		"clipboard.too_large",
	]:
		check(Result.known(code), "contract code present: " + code)


func _root() -> String:
	return "C:/workspace"


class _DocsStub:
	func active() -> Dictionary:
		return {"ok": true, "value": 1}

	func set_text(_payload: Dictionary) -> Dictionary:
		return {"ok": true, "value": true}


class _FilesStub:
	func read(_payload: Dictionary) -> Dictionary:
		return {"ok": true, "value": "ok"}
