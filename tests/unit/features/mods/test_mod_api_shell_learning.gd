extends "res://tests/support/test_case.gd"

## Phase 3 API boundary: the new method/permission pairs, fail-closed missing
## services, the run gate for run-backed validation and the added result codes.

const Api = preload("res://src/features/mods/api/api_v1.gd")
const Permissions = preload("res://src/features/mods/mod_permissions.gd")
const Result = preload("res://src/features/mods/mod_result.gd")

const MOD := "griddycode.phase3"


class TrustStub:
	var trusted: bool = false

	func is_trusted(_root: String) -> bool:
		return trusted


func _api(services: Dictionary = {}):
	return Api.new({"id": MOD, "name": "Phase 3", "version": "1.0.0"}, services)


func _root() -> String:
	return "C:/workspace"


func test_phase3_methods_have_the_expected_permission() -> void:
	var expected := {
		"ui.shell.takeover": "ui.shell",
		"ui.shell.exit": "ui.shell",
		"ui.shell.set_editor_visible": "ui.shell",
		"ui.shell.set_content_insets": "ui.shell",
		"guide.start": "documents.read",
		"guide.set_validation": "documents.read",
		"guide.resolve_validation": "documents.read",
		"guide.set_display": "documents.read",
		"guide.reset": "documents.write",
		"exercise.start": "documents.read",
		"exercise.submit": "documents.read",
		"exercise.retry": "documents.write",
		"exercise.advance": "documents.write",
	}
	var surface := {}
	for entry in _api().surface():
		surface[str(entry["name"])] = str(entry["permission"])
	for name in expected.keys():
		assert_eq(surface.get(name, ""), expected[name], "permission for " + name)
	assert_eq(surface.size(), 100, "API 1 now advertises 100 methods")


func test_missing_services_fail_closed() -> void:
	var permissions = Permissions.new()
	permissions.set_active(MOD, ["core", "ui.shell", "run", "documents.read", "documents.write"])
	var api = _api({"permissions": permissions})
	assert_eq(Result.code_of(api.invoke("ui.shell.takeover", {"spec": {}})), "state.invalid")
	assert_eq(Result.code_of(api.invoke("guide.start", {"target": "a"})), "state.invalid")
	assert_eq(Result.code_of(api.invoke("exercise.start", {"kind": "freeform"})), "state.invalid")
	assert_eq(Result.code_of(api.invoke("exercise.advance", {})), "state.invalid")


func test_shell_permission_is_enforced() -> void:
	var permissions = Permissions.new()
	permissions.set_active(MOD, ["core"])
	var api = _api({"permissions": permissions, "shell": _ShellStub.new(), "ui": _UiStub.new()})
	var denied: Dictionary = api.invoke("ui.shell.takeover", {"spec": {}})
	assert_eq(Result.code_of(denied), "permission.denied", "ui.shell is consent-gated")

	permissions.set_active(MOD, ["core", "ui.shell"])
	check(bool(api.invoke("ui.shell.takeover", {"spec": {}}).get("ok", false)), "granted shell takeover reaches the service")


func test_run_backed_exercise_needs_run_permission_and_trust() -> void:
	var permissions = Permissions.new()
	permissions.set_active(MOD, ["core"])
	var trust := TrustStub.new()
	var exercise := _ExerciseStub.new()
	var api = _api({
		"permissions": permissions,
		"exercise": exercise,
		"trust": trust,
		"workspace_root": Callable(self, "_root"),
	})

	var spec := {
		"kind": "freeform",
		"prompt": "Print hi.",
		"validation": {"type": "stdout_contains", "value": "hi"},
	}
	assert_eq(Result.code_of(api.invoke("exercise.start", spec)), "permission.denied", "documents.read is required")
	assert_eq(exercise.started, 0, "the service was never reached")

	permissions.set_active(MOD, ["core", "documents.read"])
	assert_eq(Result.code_of(api.invoke("exercise.start", spec)), "permission.denied", "run is required")
	assert_eq(exercise.started, 0, "the service was never reached")

	permissions.set_active(MOD, ["core", "documents.read", "run"])
	assert_eq(Result.code_of(api.invoke("exercise.start", spec)), "trust.required", "run also needs trust")
	assert_eq(exercise.started, 0, "the service was never reached")

	trust.trusted = true
	check(bool(api.invoke("exercise.start", spec).get("ok", false)), "granted and trusted reaches the service")
	assert_eq(exercise.started, 1, "the service ran once")

	var text_only := {"kind": "freeform", "prompt": "Print hi.", "validation": {"type": "contains", "value": "hi"}}
	check(bool(api.invoke("exercise.start", text_only).get("ok", false)), "a text check needs only documents.read")


func test_guide_run_validation_is_gated() -> void:
	var permissions = Permissions.new()
	permissions.set_active(MOD, ["core"])
	var api = _api({"permissions": permissions, "guide": _GuideStub.new()})
	var spec := {"type": "stdout_regex", "value": "^ok$"}
	assert_eq(Result.code_of(api.invoke("guide.set_validation", {"validation": spec})), "permission.denied")

	permissions.set_active(MOD, ["core", "documents.read"])
	assert_eq(Result.code_of(api.invoke("guide.set_validation", {"validation": spec})), "permission.denied", "run is required")

	var start_spec := {"doc": 1, "target": "ok", "validation": spec}
	assert_eq(Result.code_of(api.invoke("guide.start", start_spec)), "permission.denied", "start is gated too")

	var text_spec := {"type": "contains", "value": "ok"}
	check(bool(api.invoke("guide.set_validation", {"validation": text_spec}).get("ok", false)), "text validation needs only documents.read")
	check(bool(api.invoke("guide.start", {"doc": 1, "target": "ok", "validation": text_spec}).get("ok", false)), "a text-only guide needs only documents.read")


func test_phase3_result_codes_are_known() -> void:
	for code in [
		"guide.invalid_spec", "guide.unsupported", "exercise.invalid_spec",
		"exercise.unknown", "exercise.invalid_state", "shell.invalid_spec",
		"shell.insets_invalid", "shell.editor_slot",
	]:
		check(Result.known(code), "phase 3 code present: " + code)


func test_unknown_phase3_method_is_rejected() -> void:
	assert_eq(Result.code_of(_api().invoke("guide.explode", {})), "api.unknown_method")


class _ShellStub:
	func takeover(_mod_id: String, _spec: Dictionary) -> Dictionary:
		return {"ok": true, "value": {"active": true}}


class _UiStub:
	pass


class _GuideStub:
	func start(_mod_id: String, spec: Dictionary, _sink: Callable = Callable()) -> Dictionary:
		return {"ok": true, "value": {"session": 1, "target": str(spec.get("target", ""))}}

	func set_validation(_mod_id: String, spec: Variant, _session: int = 0) -> Dictionary:
		return {"ok": true, "value": {"configured": spec != null}}


class _ExerciseStub:
	var started: int = 0

	func start(_mod_id: String, _spec: Dictionary) -> Dictionary:
		started += 1
		return {"ok": true, "value": {"state": "active"}}

	func requires_run_spec() -> Variant:
		return null
