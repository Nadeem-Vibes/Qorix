extends RefCounted

## Native API facade for API 1.
##
## Every mod call lands here. The Lua SDK is developer experience; this is the
## security boundary: the method table names the permission each call needs, the
## guard checks the consent record, and the service behind it validates its own
## arguments. A method that is missing from the table cannot be called at all.
##
## Phase 1 implements core, commands, events, storage, progress, settings and the
## three loaders. Phase 2 adds documents, files, workspace, run, clipboard,
## dialogs and partial UI. Phase 3 adds shell takeover, the guide session and the
## exercise engine. Phase 5 freezes this surface as API 1.0: additive changes
## stay in major 1; breaking changes require API 2 and an adapter.

const Result = preload("res://src/features/mods/mod_result.gd")
const Json = preload("res://src/features/mods/mod_json.gd")
const Permissions = preload("res://src/features/mods/mod_permissions.gd")
const Paths = preload("res://src/base/path_utils.gd")
const Validation = preload("res://src/features/learning/exercise/exercise_validation.gd")

const API_VERSION := 1
const API_SEMVER := "1.0.0"
const API_STATUS := "frozen"
const API_FROZEN := true

const METHODS := {
	"permissions.has": "core",
	"log": "core",
	"events.subscribe": "core",
	"events.unsubscribe": "core",
	"events.emit": "core",
	"tasks.schedule": "core",
	"timer.schedule": "core",
	"cancel": "core",
	"commands.register": "core",
	"commands.unregister": "core",
	"commands.execute": "core",
	"keys.bind": "core",
	"keys.unbind": "core",
	"storage.get": "core",
	"storage.set": "core",
	"storage.delete": "core",
	"storage.keys": "core",
	"storage.clear": "core",
	"progress.get": "core",
	"progress.set": "core",
	"progress.increment": "core",
	"progress.reset": "core",
	"progress.all": "core",
	"settings.declare": "core",
	"settings.get": "core",
	"settings.set": "core",
	"module.read": "core",
	"content.read": "core",
	"assets.read_text": "core",
	"docs.active": "documents.read",
	"docs.list": "documents.read",
	"docs.open": "documents.write",
	"docs.create": "documents.write",
	"docs.text": "documents.read",
	"docs.set_text": "documents.write",
	"docs.insert": "documents.write",
	"docs.replace": "documents.write",
	"docs.cursor": "documents.read",
	"docs.set_cursor": "documents.write",
	"docs.selection": "documents.read",
	"docs.set_selection": "documents.write",
	"docs.save": "documents.write",
	"docs.close": "documents.write",
	"docs.is_dirty": "documents.read",
	"docs.path": "documents.read",
	"docs.language": "documents.read",
	"docs.reveal": "documents.read",
	"files.read": "files.read",
	"files.write": "files.write",
	"files.exists": "files.read",
	"files.list": "files.read",
	"files.mkdir": "files.write",
	"files.delete": "files.write",
	"workspace.root": "workspace.read",
	"workspace.name": "workspace.read",
	"workspace.has_workspace": "workspace.read",
	"workspace.list": "workspace.read",
	"run.active": "run",
	"run.file": "run",
	"run.stop": "run",
	"run.is_running": "run",
	"clipboard.write": "clipboard.write",
	"clipboard.read": "clipboard.read",
	"dialogs.confirm": "core",
	"dialogs.prompt": "core",
	"ui.mount": "core",
	"ui.update": "core",
	"ui.unmount": "core",
	"ui.set_visible": "core",
	"ui.on": "core",
	"ui.notify": "core",
	"ui.dialog": "core",
	"ui.close_dialog": "core",
	"ui.focus": "core",
	"ui.theme.token": "core",
	"ui.layout.set_visible": "ui.layout",
	"ui.shell.takeover": "ui.shell",
	"ui.shell.exit": "ui.shell",
	"ui.shell.set_editor_visible": "ui.shell",
	"ui.shell.set_content_insets": "ui.shell",
	"guide.start": "documents.read",
	"guide.state": "documents.read",
	"guide.pause": "documents.read",
	"guide.resume": "documents.read",
	"guide.reset": "documents.write",
	"guide.stop": "documents.read",
	"guide.hint": "core",
	"guide.set_target": "documents.read",
	"guide.set_validation": "documents.read",
	"guide.resolve_validation": "documents.read",
	"guide.set_mode": "documents.read",
	"guide.set_progression": "documents.read",
	"guide.set_display": "documents.read",
	"exercise.start": "documents.read",
	"exercise.state": "documents.read",
	"exercise.submit": "documents.read",
	"exercise.retry": "documents.write",
	"exercise.stop": "documents.read",
	"exercise.hint": "core",
	"exercise.advance": "documents.write",
}

## id -> {id, name, version}
var mod: Dictionary = {}

## docs, files, workspace, run_service, clipboard, ui, permissions, storage,
## progress, settings, events, diagnostics, commands, host, trust,
## workspace_root, developer_mode.
var services: Dictionary = {}

var mod_id: String = ""


func _init(mod_info: Dictionary, api_services: Dictionary) -> void:
	mod = mod_info.duplicate(true)
	mod_id = str(mod.get("id", ""))
	services = api_services


## The golden API surface: every method and its permission annotation.
func surface() -> Array:
	var out: Array = []
	for name in METHODS.keys():
		out.append({"name": str(name), "permission": str(METHODS[name])})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a["name"]) < str(b["name"]))
	return out


## Machine-readable version contract for the Developer Preview. Not part of the
## mod-facing method table: a mod cannot call this through `editor`.
func contract() -> Dictionary:
	return {
		"major": API_VERSION,
		"semver": API_SEMVER,
		"status": API_STATUS,
		"frozen": API_FROZEN,
		"methods": METHODS.size(),
	}


## Dispatches one call. Always returns a Result envelope; never throws into Lua.
func invoke(method: String, args: Variant = null) -> Dictionary:
	var name := str(method)
	if !METHODS.has(name):
		return Result.error("api.unknown_method", "'%s' is not part of API %d." % [name, API_VERSION])

	var guard := _guard(str(METHODS[name]))
	if !guard.is_empty():
		return guard

	var payload: Dictionary = {}
	if args != null:
		if args is Dictionary:
			payload = args
		elif args is Array and (args as Array).is_empty():
			payload = {}
		else:
			return Result.error("api.bad_args", "%s expects an object argument." % name)

	var missing := _missing_service(name)
	if !missing.is_empty():
		return Result.error("state.invalid", "%s is not available in this context." % missing)

	match name:
		"permissions.has":
			return Result.ok(bool(services["permissions"].has(mod_id, str(payload.get("permission", "")))))

		"log":
			return _log(payload)

		"events.subscribe":
			return services["events"].subscribe(mod_id, str(payload.get("name", "")), int(payload.get("handle", 0)), int(payload.get("priority", 0)))
		"events.unsubscribe":
			return services["events"].unsubscribe(int(payload.get("handle", 0)))
		"events.emit":
			return services["events"].publish(str(payload.get("name", "")), payload.get("payload"), mod_id)

		"tasks.schedule":
			return services["host"].schedule_task(int(payload.get("id", 0)))
		"timer.schedule":
			return services["host"].add_timer(int(payload.get("handle", 0)), float(payload.get("ms", 0.0)), bool(payload.get("repeat", false)))
		"cancel":
			return services["host"].cancel_handle(int(payload.get("handle", 0)))

		"commands.register":
			return _manager().register_command(mod_id, payload)
		"commands.unregister":
			return _manager().unregister_command(mod_id, str(payload.get("id", "")))
		"commands.execute":
			return _manager().execute_command(mod_id, str(payload.get("id", "")), payload.get("args"))

		"keys.bind":
			return _manager().bind_mod_key(mod_id, str(payload.get("command", "")), str(payload.get("chord", "")))
		"keys.unbind":
			return _manager().unbind_mod_key(mod_id, str(payload.get("command", "")))

		"storage.get":
			return services["storage"].get_value(str(payload.get("key", "")), payload.get("default"))
		"storage.set":
			return services["storage"].set_value(str(payload.get("key", "")), payload.get("value"))
		"storage.delete":
			return services["storage"].delete(str(payload.get("key", "")))
		"storage.keys":
			return services["storage"].keys()
		"storage.clear":
			return services["storage"].clear()

		"progress.get":
			return services["progress"].get_value(str(payload.get("key", "")), payload.get("default"))
		"progress.set":
			return services["progress"].set_value(str(payload.get("key", "")), payload.get("value"))
		"progress.increment":
			return services["progress"].increment(str(payload.get("key", "")), payload.get("amount", 1))
		"progress.reset":
			return services["progress"].reset(str(payload.get("key", "")))
		"progress.all":
			return services["progress"].all()

		"settings.declare":
			return services["settings"].declare(Json.as_array(payload.get("schema")), "runtime")
		"settings.get":
			return services["settings"].get_value(str(payload.get("key", "")), payload.get("default"))
		"settings.set":
			return services["settings"].set_value(str(payload.get("key", "")), payload.get("value"))

		"module.read":
			return _manager().read_mod_file(mod_id, "module", str(payload.get("path", "")))
		"content.read":
			return _manager().read_mod_file(mod_id, "content", str(payload.get("path", "")))
		"assets.read_text":
			return _manager().read_mod_file(mod_id, "assets", str(payload.get("path", "")))

		"docs.active":
			return _docs().active()
		"docs.list":
			return _docs().list()
		"docs.open":
			var open_guard := _guard("files.read")
			if !open_guard.is_empty():
				return open_guard
			return _docs().open(payload)
		"docs.create":
			return _docs().create(payload)
		"docs.text":
			return _docs().text(payload)
		"docs.set_text":
			return _docs().set_text(payload)
		"docs.insert":
			return _docs().insert(payload)
		"docs.replace":
			return _docs().replace(payload)
		"docs.cursor":
			return _docs().cursor(payload)
		"docs.set_cursor":
			return _docs().set_cursor(payload)
		"docs.selection":
			return _docs().selection(payload)
		"docs.set_selection":
			return _docs().set_selection(payload)
		"docs.save":
			return _docs().save(payload)
		"docs.close":
			return _docs().close(payload)
		"docs.is_dirty":
			return _docs().is_dirty(payload)
		"docs.path":
			return _docs().path(payload)
		"docs.language":
			return _docs().language(payload)
		"docs.reveal":
			return _docs().reveal(payload)

		"files.read":
			return _files().read(payload)
		"files.write":
			return _files().write(payload)
		"files.exists":
			return _files().exists(payload)
		"files.list":
			return _files().list(payload)
		"files.mkdir":
			return _files().mkdir(payload)
		"files.delete":
			return _files().delete(payload)

		"workspace.root":
			return _workspace().root()
		"workspace.name":
			return _workspace().name()
		"workspace.has_workspace":
			return _workspace().has_workspace()
		"workspace.list":
			return _workspace().list(payload)

		"run.active":
			return _run(payload, "")
		"run.file":
			return _run(payload, str(payload.get("path", "")))
		"run.stop":
			return _run_stop()
		"run.is_running":
			return _run_is_running()

		"clipboard.write":
			return _clipboard().write(payload)
		"clipboard.read":
			return _clipboard().read(payload)

		"dialogs.confirm":
			return _dialog(mod_id, payload, false)
		"dialogs.prompt":
			return _dialog(mod_id, payload, true)

		"ui.mount":
			return _ui().mount(mod_id, str(payload.get("slot", "right")), _object(payload.get("spec")))
		"ui.update":
			return _ui().update(mod_id, str(payload.get("id", "")), _object(payload.get("spec")))
		"ui.unmount":
			return _ui().unmount(mod_id, str(payload.get("id", "")))
		"ui.set_visible":
			return _ui().set_widget_visible(mod_id, str(payload.get("id", "")), bool(payload.get("visible", true)))
		"ui.on":
			return _ui().on(mod_id, str(payload.get("id", "")), str(payload.get("event", "")), int(payload.get("handle", 0)))
		"ui.notify":
			return _ui().notify(str(payload.get("text", "")), str(payload.get("severity", "info")))
		"ui.dialog":
			return _ui().dialog(mod_id, _object(payload.get("spec")))
		"ui.close_dialog":
			return _ui().close_dialog(mod_id, str(payload.get("id", "")))
		"ui.focus":
			return _ui().focus(mod_id, str(payload.get("id", "")))
		"ui.theme.token":
			return _ui().theme_token(str(payload.get("name", "")))
		"ui.layout.set_visible":
			return _ui().set_core_panel_visible(mod_id, str(payload.get("panel", "")), bool(payload.get("visible", true)))

		"ui.shell.takeover":
			return _shell().takeover(mod_id, _object(payload.get("spec")))
		"ui.shell.exit":
			return _shell().exit(mod_id, str(payload.get("reason", "")))
		"ui.shell.set_editor_visible":
			return _shell().set_editor_visible(mod_id, bool(payload.get("visible", true)))
		"ui.shell.set_content_insets":
			return _shell().set_content_insets(mod_id, _object(payload.get("insets")))

		"guide.start":
			var guide_start_guard := _run_guard_for_spec(payload)
			if !guide_start_guard.is_empty():
				return guide_start_guard
			return _guide().start(mod_id, payload)
		"guide.state":
			return _guide().state_snapshot(mod_id, int(payload.get("session", 0)))
		"guide.pause":
			return _guide().pause(mod_id, int(payload.get("session", 0)))
		"guide.resume":
			return _guide().resume(mod_id, int(payload.get("session", 0)))
		"guide.reset":
			return _guide().reset(mod_id, payload)
		"guide.stop":
			return _guide().stop(mod_id, str(payload.get("reason", "")))
		"guide.hint":
			return _guide().hint(mod_id, str(payload.get("text", "")), int(payload.get("session", 0)))
		"guide.set_target":
			return _guide().set_target(mod_id, str(payload.get("target", "")), int(payload.get("session", 0)))
		"guide.set_validation":
			var guide_spec: Variant = _validation_payload(payload)
			var guide_guard := _run_guard_for(guide_spec)
			if !guide_guard.is_empty():
				return guide_guard
			return _guide().set_validation(mod_id, guide_spec, int(payload.get("session", 0)))
		"guide.resolve_validation":
			# Custom tokens come from the shared runner, so answer whichever
			# learning session the calling mod currently owns.
			var resolution := {
				"results": payload.get("results", []),
				"code": str(payload.get("code", "")),
				"message": str(payload.get("message", "")),
			}
			var resolve_token := int(payload.get("token", 0))
			var resolve_passed := bool(payload.get("passed", false))
			if _exercise() != null and _exercise().is_live():
				return _exercise().resolve_validation(mod_id, resolve_token, resolve_passed, resolution)
			return _guide().resolve_validation(mod_id, resolve_token, resolve_passed, resolution)
		"guide.set_mode":
			return _guide().set_mode(mod_id, str(payload.get("mode", "strict")), int(payload.get("session", 0)))
		"guide.set_progression":
			return _guide().set_progression(mod_id, str(payload.get("progression", "character")), int(payload.get("session", 0)))
		"guide.set_display":
			return _guide().set_display(mod_id, _object(payload.get("display")), int(payload.get("session", 0)))

		"exercise.start":
			var start_guard := _run_guard_for_spec(payload)
			if !start_guard.is_empty():
				return start_guard
			return _exercise().start(mod_id, payload)
		"exercise.state":
			return _exercise().state_snapshot(mod_id, int(payload.get("id", 0)))
		"exercise.submit":
			var submit_guard := _run_guard_for(_exercise().requires_run_spec())
			if !submit_guard.is_empty():
				return submit_guard
			return _exercise().submit(mod_id, int(payload.get("id", 0)))
		"exercise.retry":
			return _exercise().retry(mod_id, {
				"id": int(payload.get("id", 0)),
				"restore": str(payload.get("restore", "checkpoint")),
			})
		"exercise.stop":
			return _exercise().stop(mod_id, str(payload.get("reason", "")))
		"exercise.hint":
			return _exercise().hint(mod_id, str(payload.get("text", "")), int(payload.get("id", 0)))
		"exercise.advance":
			return _exercise().advance(mod_id, int(payload.get("id", 0)))

	return Result.error("api.unknown_method", "'%s' is not part of API %d." % [name, API_VERSION])


# ── METHODS ─────────────────────────────────────────────────────────────────

func _log(payload: Dictionary) -> Dictionary:
	var level := str(payload.get("level", "info"))
	var message := str(payload.get("message", ""))
	if message.length() > 8192:
		message = message.substr(0, 8192)
	services["diagnostics"].log(mod_id, level, message)
	return Result.ok(true)


# ── PHASE 2 SERVICES ────────────────────────────────────────────────────────

func _dialog(mod_id_value: String, payload: Dictionary, prompt: bool) -> Dictionary:
	var spec := _object(payload.get("spec"))
	if spec.is_empty():
		spec = {}
		spec["title"] = str(payload.get("title", "Mod"))
		spec["message"] = str(payload.get("message", ""))

	if prompt:
		var value := str(payload.get("default", ""))
		spec["body"] = {
			"type": "vbox",
			"children": [
				{
					"type": "input",
					"id": "value",
					"text": value,
					"placeholder": str(payload.get("placeholder", "")),
				},
			],
		}
		if !spec.has("confirm"):
			spec["confirm"] = "OK"
		if !spec.has("cancel"):
			spec["cancel"] = "Cancel"

	var opened: Dictionary = _ui().dialog(mod_id_value, spec)
	if !opened.get("ok", false):
		return opened

	var dialog_id := str(opened.get("value", ""))
	var handle := int(payload.get("handle", 0))
	if handle > 0:
		var subscribed: Dictionary = _ui().on(mod_id_value, dialog_id, "click", handle)
		if !subscribed.get("ok", false):
			_ui().close_dialog(mod_id_value, dialog_id)
			return subscribed
	return opened


func _run(payload: Dictionary, path: String) -> Dictionary:
	var runner = services.get("run_service")
	if runner == null:
		return Result.error("state.invalid", "RunService is not available.")

	var target := str(path)
	var options: Dictionary = {}
	var raw_options: Variant = payload.get("options", {})
	if raw_options is Dictionary:
		options = (raw_options as Dictionary).duplicate(true)

	if !target.is_empty():
		var resolved: Dictionary = _files().resolve(target)
		if !resolved.get("ok", false):
			return resolved
		target = str(resolved["value"])
		if !FileAccess.file_exists(target):
			return Result.error("module.not_found", "The file does not exist: " + str(path))

	if runner.has_method("run"):
		runner.call_deferred("run", target, options)
		return Result.ok({"started": true, "path": target, "stopping_previous": bool(runner.get("running"))})
	return Result.error("state.invalid", "RunService cannot start a run.")


func _run_stop() -> Dictionary:
	var runner = services.get("run_service")
	if runner == null:
		return Result.error("state.invalid", "RunService is not available.")
	if runner.has_method("stop"):
		runner.call_deferred("stop")
	return Result.ok(true)


func _run_is_running() -> Dictionary:
	var runner = services.get("run_service")
	if runner == null:
		return Result.ok(false)
	return Result.ok(bool(runner.get("running")))


# ── GUARDS ──────────────────────────────────────────────────────────────────

func _guard(permission: String) -> Dictionary:
	if permission == "core":
		return {}

	var permissions = services.get("permissions")
	if permissions == null or !permissions.has(mod_id, permission):
		return Result.permission_denied(permission)

	if Permissions.requires_trust(permission) and !_workspace_trusted():
		return Result.trust_required(permission)

	return {}


func _workspace_trusted() -> bool:
	var trust = services.get("trust")
	var root_callable: Variant = services.get("workspace_root")
	if trust == null or !(root_callable is Callable):
		return false

	var callable: Callable = root_callable
	if !callable.is_valid():
		return false

	var root := str(callable.call())
	return !root.is_empty() and trust.is_trusted(root)


func _manager():
	return services["commands"]


func _docs():
	return services.get("docs", null)


func _files():
	return services.get("files", null)


func _workspace():
	return services.get("workspace", null)


func _clipboard():
	return services.get("clipboard", null)


func _ui():
	return services.get("ui", null)


func _shell():
	return services.get("shell", null)


func _guide():
	return services.get("guide", null)


func _exercise():
	return services.get("exercise", null)


## The validation object carried by a guide/exercise payload. Both spellings are
## accepted because the contract uses `validation` and the samples use `tests`.
func _validation_payload(payload: Dictionary) -> Variant:
	if payload.has("validation"):
		return payload["validation"]
	return payload.get("tests", null)


## Run-based validation is gated exactly like `run.*`: the permission must be
## granted and the workspace must be trusted. Text-only validation stays core.
func _run_guard_for(spec: Variant) -> Dictionary:
	if spec == null:
		return {}
	if !Validation.needs_run(spec):
		return {}
	return _guard("run")


func _run_guard_for_spec(payload: Dictionary) -> Dictionary:
	var single := _run_guard_for(_validation_payload(payload))
	if !single.is_empty():
		return single
	var phases: Variant = payload.get("phases", [])
	if phases is Array:
		for phase in phases:
			if !(phase is Dictionary):
				continue
			var phase_guard := _run_guard_for(_validation_payload(phase))
			if !phase_guard.is_empty():
				return phase_guard
	return {}


## Phase 2 methods fail closed when the composition root did not supply the
## service. That keeps a headless test or a stripped build from crashing on a
## nil call instead of returning a structured error.
func _missing_service(method: String) -> String:
	if method.begins_with("docs."):
		return "The document service" if _docs() == null else ""
	if method.begins_with("files."):
		return "The files service" if _files() == null else ""
	if method.begins_with("workspace."):
		return "The workspace service" if _workspace() == null else ""
	if method.begins_with("clipboard."):
		return "The clipboard service" if _clipboard() == null else ""
	if method.begins_with("ui.shell."):
		if _ui() == null:
			return "The UI registry"
		return "The shell service" if _shell() == null else ""
	if method.begins_with("ui.") or method.begins_with("dialogs."):
		return "The UI registry" if _ui() == null else ""
	if method.begins_with("guide."):
		return "The guide service" if _guide() == null else ""
	if method.begins_with("exercise."):
		return "The exercise service" if _exercise() == null else ""
	return ""


func _object(value: Variant) -> Dictionary:
	return (value as Dictionary).duplicate(true) if value is Dictionary else {}
