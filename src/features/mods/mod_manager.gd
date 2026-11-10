extends Node

## ModManager: discovery, activation, lifecycle and failure isolation.
##
## This is the only object the composition root constructs. It owns the registry,
## consent records, per-mod services and Lua hosts, and it is the Callable target
## the event bus uses to deliver into a mod.
##
## Startup order is fixed: scan, resolve dependencies, check consent, then
## activate in topological order. Activation is synchronous per mod but the whole
## pass is budgeted; if it exceeds 500 ms the remaining mods finish one per frame
## with a visible notice, so a large mod set cannot freeze the first frame.

const Manifest = preload("res://src/features/mods/mod_manifest.gd")
const Resolver = preload("res://src/features/mods/mod_resolver.gd")
const Registry = preload("res://src/features/mods/mod_registry.gd")
const Permissions = preload("res://src/features/mods/mod_permissions.gd")
const Storage = preload("res://src/features/mods/mod_storage.gd")
const Progress = preload("res://src/features/mods/mod_progress.gd")
const Settings = preload("res://src/features/mods/mod_settings.gd")
const Diagnostics = preload("res://src/features/mods/mod_diagnostics.gd")
const SafeMode = preload("res://src/features/mods/mod_safe_mode.gd")
const Host = preload("res://src/features/mods/mod_host.gd")
const DevWatcher = preload("res://src/features/mods/mod_dev_watcher.gd")
const Documents = preload("res://src/features/mods/mod_documents.gd")
const Files = preload("res://src/features/mods/mod_files.gd")
const Workspace = preload("res://src/features/mods/mod_workspace.gd")
const Clipboard = preload("res://src/features/mods/mod_clipboard.gd")
const Api = preload("res://src/features/mods/api/api_v1.gd")
const EventBus = preload("res://src/features/mods/events/event_bus.gd")
const Result = preload("res://src/features/mods/mod_result.gd")
const Json = preload("res://src/features/mods/mod_json.gd")
const Paths = preload("res://src/base/path_utils.gd")
const Version = preload("res://src/base/version_utils.gd")
const Package = preload("res://src/features/mods/mod_package.gd")
const Publishers = preload("res://src/features/mods/mod_publishers.gd")
const Installer = preload("res://src/features/mods/mod_installer.gd")
const Hardening = preload("res://src/features/mods/mod_hardening.gd")

signal notice(message: String, severity: String)
signal mod_state_changed(id: String, state: Dictionary)
signal failure_reported(id: String, failure: Dictionary)
signal failure_cleared(id: String)

const API_VERSION := 1
const STARTUP_BUDGET_USEC := 500000
const MAX_PENDING_COMMANDS := 64
const MAX_CODE_BYTES := 2 * 1024 * 1024
const MAX_ASSET_TEXT_BYTES := 4 * 1024 * 1024
const MAX_PACKAGE_BYTES := 64 * 1024 * 1024

var mods_root: String = "user://mods"
var data_root: String = "user://mod_data"
var dev_root: String = "user://mods_dev"
var registry_path: String = Registry.DEFAULT_PATH
var permissions_path: String = Permissions.DEFAULT_PATH
var session_path: String = SafeMode.DEFAULT_PATH
var sandbox_path: String = Host.DEFAULT_SANDBOX
var publishers_path: String = Publishers.DEFAULT_PATH
var staging_root: String = "user://mod_staging"
var editor_version: String = "1.4.0"
var api_version: int = API_VERSION
var developer_mode: bool = false
var preview_build: bool = false
var safe_mode: bool = false
var allow_unsigned_imports: bool = false
var started: bool = false

var diagnostics
var permissions
var registry
var event_bus
var safe_guard
var dev_watcher
var publishers
var installer
var hardening

var command_registry = null
var keybinding_service = null
var trust_service = null
var workspace_root: Callable = Callable()

## Phase 2 host services. The manager owns the per-mod lifecycle; these bridges
## are shared and receive the calling mod's id on every call.
var editor = null
var ui = null
var run_service = null
var documents_service = null
var files_service = null
var workspace_service = null
var clipboard_service = null

## Phase 3 host services. The composition root constructs them because they
## need the scene (overlay, hint layer, shell layers); the manager owns their
## teardown order and hands them to the API facade.
var shell_service = null
var guide_service = null
var exercise_service = null
var validation_service = null

var _hosts: Dictionary = {}
var _apis: Dictionary = {}
var _storage: Dictionary = {}
var _progress: Dictionary = {}
var _settings: Dictionary = {}
var _installed: Dictionary = {}
var _states: Dictionary = {}
var _registrations: Dictionary = {}
var _pending_activation: Array = []
var _pending_commands: Array = []
var _scan_errors: Array = []
var _startup_usec: int = 0
var _startup_duration_usec: int = 0
var _start_finished: bool = false
var _startup_deferred: bool = false
var _startup_was_deferred: bool = false
var _session_disabled: bool = false
var _safe_reason: String = ""
var _notices_shown: int = 0


func _init() -> void:
	diagnostics = Diagnostics.new()
	permissions = Permissions.new()
	registry = Registry.new()
	event_bus = EventBus.new()
	safe_guard = SafeMode.new()
	dev_watcher = DevWatcher.new()
	publishers = Publishers.new()
	installer = Installer.new()
	hardening = Hardening.new()


func setup(context: Dictionary = {}) -> Dictionary:
	if context.has("mods_root"):
		mods_root = str(context["mods_root"])
	if context.has("data_root"):
		data_root = str(context["data_root"])
	if context.has("dev_root"):
		dev_root = str(context["dev_root"])
	if context.has("registry_path"):
		registry_path = str(context["registry_path"])
	if context.has("permissions_path"):
		permissions_path = str(context["permissions_path"])
	if context.has("session_path"):
		session_path = str(context["session_path"])
	if context.has("sandbox_path"):
		sandbox_path = str(context["sandbox_path"])
	if context.has("publishers_path"):
		publishers_path = str(context["publishers_path"])
	if context.has("staging_root"):
		staging_root = str(context["staging_root"])
	if context.has("editor_version"):
		editor_version = str(context["editor_version"])
	if context.has("developer_mode"):
		developer_mode = bool(context["developer_mode"])
	if context.has("preview_build"):
		preview_build = bool(context["preview_build"])
	if context.has("allow_unsigned"):
		allow_unsigned_imports = bool(context["allow_unsigned"])
	if context.has("watch_poll_ms") or context.has("watch_debounce_ms"):
		dev_watcher.configure({
			"poll_ms": int(context.get("watch_poll_ms", DevWatcher.DEFAULT_POLL_MS)),
			"debounce_ms": int(context.get("watch_debounce_ms", DevWatcher.DEFAULT_DEBOUNCE_MS)),
		})
	if context.has("command_registry"):
		command_registry = context["command_registry"]
	if context.has("keybinding_service"):
		keybinding_service = context["keybinding_service"]
	if context.has("trust_service"):
		trust_service = context["trust_service"]
	if context.has("workspace_root") and context["workspace_root"] is Callable:
		workspace_root = context["workspace_root"]
	if context.has("editor"):
		editor = context["editor"]
	if context.has("ui"):
		ui = context["ui"]
	if context.has("run_service"):
		run_service = context["run_service"]
	if context.has("shell"):
		shell_service = context["shell"]
	if context.has("guide"):
		guide_service = context["guide"]
	if context.has("exercise"):
		exercise_service = context["exercise"]
	if context.has("validator"):
		validation_service = context["validator"]

	documents_service = Documents.new(editor)
	files_service = Files.new(editor)
	workspace_service = Workspace.new(editor)
	clipboard_service = Clipboard.new()

	registry.path = registry_path
	permissions.path = permissions_path
	safe_guard.path = session_path
	publishers.path = publishers_path
	hardening.session_path = session_path

	registry.load_registry()
	permissions.load_records()
	publishers.load_store()
	installer.setup({
		"mods_root": mods_root,
		"data_root": data_root,
		"staging_root": staging_root,
		"registry": registry,
		"permissions": permissions,
		"publishers": publishers,
		"allow_unsigned": allow_unsigned_imports,
	})
	event_bus.set_dispatch(Callable(self, "_dispatch_event"))

	return Result.ok()


func _process(delta: float) -> void:
	tick(delta)


func _exit_tree() -> void:
	if started:
		stop()


# ── STARTUP ─────────────────────────────────────────────────────────────────

func start() -> Dictionary:
	if started:
		return Result.ok(status_report())

	_startup_usec = Time.get_ticks_usec()
	_startup_duration_usec = 0
	_start_finished = false
	_startup_deferred = false
	_startup_was_deferred = false
	started = true

	if preview_build:
		_notice("Modding Developer Preview: API 1.0 is frozen. Mods run only with your explicit consent.", "info")

	var evaluation: Dictionary = safe_guard.evaluate(OS.get_cmdline_args(), safe_mode)
	safe_mode = bool(evaluation.get("safe_mode", false))
	_safe_reason = str(evaluation.get("reason", ""))
	if !_safe_reason.is_empty():
		_notice(_safe_reason, "warning")

	var to_disable: Array = evaluation.get("disable", [])
	for id in to_disable:
		registry.set_enabled(str(id), false, "safe_mode")
		_notice("Disabled '%s' after an unclean-exit streak." % str(id), "warning")

	scan_installed()

	if safe_mode:
		safe_guard.begin([])
		_notice("Safe mode: mods are disabled for this session.", "info")
		_start_finished = true
		return Result.ok(status_report())

	if developer_mode:
		scan_developer()

	var plan := _build_plan()
	for warning in plan.get("warnings", []):
		_notice(str(warning.get("message", "")), "warning")
	for error in plan.get("errors", []):
		_notice(str(error.get("message", "")), "error")

	var order: Array = plan.get("order", [])
	_pending_activation = order.duplicate()
	safe_guard.begin(order)

	while !_pending_activation.is_empty():
		if _elapsed_usec() > STARTUP_BUDGET_USEC:
			_startup_deferred = true
			_startup_was_deferred = true
			_startup_duration_usec = _elapsed_usec()
			_notice("Finishing mod activation in the background…", "info")
			break
		activate(str(_pending_activation.pop_front()))

	if !_startup_deferred:
		_finish_start()

	return Result.ok(status_report())


func tick(delta: float) -> void:
	if !started:
		return

	var elapsed_ms := maxf(0.0, delta) * 1000.0
	# Session clocks: idle hints, exercise duration and validation timeouts.
	# They run before the event bus flushes the events those ticks produce.
	if validation_service != null and validation_service.has_method("tick"):
		validation_service.tick(elapsed_ms)
	if guide_service != null and guide_service.has_method("tick"):
		guide_service.tick(maxf(0.0, delta))
	if exercise_service != null and exercise_service.has_method("tick"):
		exercise_service.tick(maxf(0.0, delta))
	event_bus.tick(elapsed_ms)

	for id in _hosts.keys():
		var host = _hosts.get(id)
		if host != null:
			host.tick(elapsed_ms)

	_poll_dev_watcher(elapsed_ms)
	_drain_pending_commands()

	if !_pending_activation.is_empty() and !safe_mode and !_session_disabled:
		activate(str(_pending_activation.pop_front()))
		if _pending_activation.is_empty():
			_finish_start()


func stop() -> void:
	if !started:
		return

	event_bus.publish("app.quitting", {})
	event_bus.tick(0.0)

	for id in _hosts.keys().duplicate():
		deactivate(str(id), "The editor is closing.")

	dev_watcher.clear()
	_pending_activation.clear()
	_pending_commands.clear()
	started = false
	safe_guard.mark_clean()


func _finish_start() -> void:
	if _start_finished:
		return
	_start_finished = true
	_startup_deferred = false
	if _startup_duration_usec == 0:
		_startup_duration_usec = _elapsed_usec()

	event_bus.publish("app.ready", {
		"api_version": api_version,
		"api_semver": Api.API_SEMVER,
		"preview": preview_build,
		"developer_mode": developer_mode,
	})

	var active: Array = []
	for id in _states.keys():
		if str((_states[id] as Dictionary).get("status", "")) == "active":
			active.append(str(id))

	safe_guard.update_mods(active)
	event_bus.publish("app.mods_ready", {"count": active.size()})


# ── DISCOVERY ───────────────────────────────────────────────────────────────

## Reads `<mods_root>/<id>/<version>/manifest.json`. The registry decides which
## installed version is active: updates and rollbacks write that version, and the
## scan honors it instead of always picking the highest folder. Without a record
## the highest valid version per id wins; invalid manifests are reported and
## skipped, never fatal.
func scan_installed() -> Dictionary:
	_installed.clear()
	_scan_errors.clear()

	var directory := DirAccess.open(mods_root)
	if directory == null:
		return Result.ok([])

	var ids: Array = directory.get_directories()
	ids.sort()

	for raw_id in ids:
		var id := str(raw_id)
		if !Manifest.is_valid_id(id):
			_record_scan_error("'%s' is not a valid mod id; the folder was ignored." % id)
			continue

		var version_dir := DirAccess.open(mods_root.path_join(id))
		if version_dir == null:
			continue

		var versions: Array = version_dir.get_directories()
		versions.sort()

		var candidates: Array = []
		for raw_version in versions:
			var version_folder := str(raw_version)
			var root := mods_root.path_join(id).path_join(version_folder)
			var manifest_path := root.path_join("manifest.json")
			if !FileAccess.file_exists(manifest_path):
				_record_scan_error("%s/%s has no manifest.json." % [id, version_folder])
				continue

			var read := Manifest.read_manifest(manifest_path, {"root": root})
			if !read.get("ok", false):
				for error in read.get("errors", []):
					_record_scan_error("%s/%s: %s (%s)" % [
						id,
						version_folder,
						str(error.get("message", "")),
						str(error.get("field", "")),
					])
				continue

			var manifest: Dictionary = read["manifest"]
			if str(manifest.get("id", "")) != id:
				_record_scan_error("%s/%s declares id '%s'; the folder name wins." % [
					id,
					version_folder,
					str(manifest.get("id", "")),
				])
				continue

			candidates.append({
				"root": root,
				"manifest": manifest,
				"manifest_path": manifest_path,
				"manifest_mtime": int(FileAccess.get_modified_time(manifest_path)),
			})

		if candidates.is_empty():
			continue

		var existing: Dictionary = registry.entry(id)
		var chosen: Dictionary = _choose_candidate(candidates, existing)
		var manifest: Dictionary = chosen["manifest"]
		var root := str(chosen["root"])
		var manifest_path := str(chosen["manifest_path"])
		var mtime := int(chosen.get("manifest_mtime", 0))
		var version := str(manifest.get("version", ""))

		var newest := _package_mtime(root)
		var hash := str(existing.get("hash", ""))
		var signature: Dictionary = existing.get("signature", {}) if existing.get("signature") is Dictionary else {}
		var signature_path := root.path_join(Package.SIGNATURE_FILE)
		var signature_present := FileAccess.file_exists(signature_path)
		var signature_stale := signature_present != bool(signature.get("present", false))
		# Hashing is gated by the newest file timestamp, not just the manifest.
		# Otherwise editing main.lua without touching manifest.json would leave
		# a consent record bound to the old bytes the user reviewed. A version or
		# signature change also forces a fresh digest.
		if hash.is_empty() or int(existing.get("package_mtime", 0)) != newest \
				or str(existing.get("version", "")) != version or signature_stale:
			var package := Package.digest_folder(root)
			if !bool(package.get("ok", false)):
				for problem in package.get("errors", []):
					_record_scan_error("%s/%s: %s" % [id, version, str(problem.get("message", ""))])
				continue
			hash = str(package.get("hash", ""))
			newest = int(package.get("mtime", 0))
			signature = _read_installed_signature(root, hash)

		var now := int(Time.get_unix_time_from_system())
		if existing.is_empty():
			registry.record(id, {
				"version": version,
				"hash": hash,
				"path": root,
				"manifest_mtime": mtime,
				"package_mtime": newest,
				"signature": signature,
				"enabled": true,
				"installed_at": now,
			})
		elif str(existing.get("version", "")) != version or str(existing.get("hash", "")) != hash:
			var previous: Dictionary = existing.get("previous", {}) if existing.get("previous") is Dictionary else {}
			if str(existing.get("version", "")) != version:
				previous = _snapshot_entry(existing)
			registry.record(id, {
				"version": version,
				"hash": hash,
				"path": root,
				"manifest_mtime": mtime,
				"package_mtime": newest,
				"signature": signature,
				"previous": previous,
				"previous_version": str(previous.get("version", "")),
				"updated_at": now,
			})
		elif _signature_stamp(signature) != _signature_stamp(existing.get("signature", {})):
			registry.record(id, {"signature": signature})

		_installed[id] = {
			"id": id,
			"root": root,
			"manifest_path": manifest_path,
			"manifest": manifest,
			"hash": hash,
			"signature": signature,
			"signed": bool(signature.get("present", false)) and bool(signature.get("ok", false)),
			"allow_unsigned": bool(existing.get("allow_unsigned", false)),
			"dev": false,
		}

		if !_states.has(id):
			_mark_state(id, "inactive", "")

	for error in _scan_errors:
		notice.emit(str(error.get("message", "")), "error")

	return Result.ok(_installed.values())


## Rescan the installed root and apply the new set to the running session. The
## Mods page Refresh uses this so a newly copied folder enters the normal
## discovery path (including a consent block) without restarting the editor.
## Active mods stay active; this is not a reload of changed package bytes.
func refresh_discovery() -> Dictionary:
	if !started:
		return scan_installed()
	if safe_mode or _session_disabled:
		return Result.ok(status_report())

	scan_installed()
	var plan := _build_plan()
	for warning in plan.get("warnings", []):
		_notice(str((warning as Dictionary).get("message", "")), "warning")
	for error in plan.get("errors", []):
		_notice(str((error as Dictionary).get("message", "")), "error")

	for raw_id in plan.get("order", []):
		var key := str(raw_id)
		if str(state(key).get("status", "")) == "inactive":
			activate(key)

	return Result.ok(status_report())


## Developer mode adds a second, non-installed root: `user://mods_dev/<id>/<version>`.
## These entries use the same manifest and consent checks as installed mods, but
## they are not written to the registry and only they are watched for hot reload.
## An installed copy with the same id is replaced in memory for this session; the
## dev folder is the one a mod author is editing.
func scan_developer() -> Dictionary:
	if !developer_mode or dev_root.is_empty():
		return Result.ok([])

	var directory := DirAccess.open(dev_root)
	if directory == null:
		return Result.ok([])

	var ids: Array = directory.get_directories()
	ids.sort()

	for raw_id in ids:
		var id := str(raw_id)
		if !Manifest.is_valid_id(id):
			_notice("'%s' in %s is not a valid mod id; the dev folder was ignored." % [id, dev_root], "warning")
			continue

		var version_dir := DirAccess.open(dev_root.path_join(id))
		if version_dir == null:
			continue

		var versions: Array = version_dir.get_directories()
		versions.sort()
		var best: Dictionary = {}
		for raw_version in versions:
			var version_folder := str(raw_version)
			var root := dev_root.path_join(id).path_join(version_folder)
			var manifest_path := root.path_join("manifest.json")
			if !FileAccess.file_exists(manifest_path):
				_notice("Dev mod %s/%s has no manifest.json." % [id, version_folder], "warning")
				continue

			var read := Manifest.read_manifest(manifest_path, {"root": root})
			if !read.get("ok", false):
				for error in read.get("errors", []):
					_notice("Dev mod %s/%s: %s (%s)" % [
						id,
						version_folder,
						str(error.get("message", "")),
						str(error.get("field", "")),
					], "error")
				continue

			var manifest: Dictionary = read["manifest"]
			if str(manifest.get("id", "")) != id:
				_notice("Dev mod %s/%s declares id '%s'; the folder name wins." % [
					id,
					version_folder,
					str(manifest.get("id", "")),
				], "warning")
				continue

			if best.is_empty() or Version.is_higher_version(
				str(manifest.get("version", "")),
				str((best.get("manifest", {}) as Dictionary).get("version", "")),
			):
				best = {
					"root": root,
					"manifest": manifest,
					"manifest_path": manifest_path,
				}

		if best.is_empty():
			continue

		var root := str(best["root"])
		var manifest: Dictionary = best["manifest"]
		var package := _package_info(root)
		var hash := str(package.get("hash", ""))
		var signature := _read_installed_signature(root, hash)

		if _installed.has(id) and !bool((_installed[id] as Dictionary).get("dev", false)):
			_notice("Using the development copy of '%s' from %s for this session." % [id, dev_root], "info")

		_installed[id] = {
			"id": id,
			"root": root,
			"manifest_path": str(best["manifest_path"]),
			"manifest": manifest,
			"hash": hash,
			"signature": signature,
			"signed": bool(signature.get("present", false)) and bool(signature.get("ok", false)),
			"allow_unsigned": true,
			"dev": true,
		}
		_mark_state(id, "inactive", "")
		dev_watcher.watch(id, root)

	return Result.ok(_installed.values())


func _build_plan() -> Dictionary:
	var manifests: Dictionary = {}

	for id in _installed.keys():
		var record: Dictionary = _installed[id]
		var manifest: Dictionary = record["manifest"]
		var is_dev := bool(record.get("dev", false))

		# A dev copy is not an installed package, so an old registry entry for
		# the same id (for example a disabled installed copy) must not silently
		# disable the one the author is editing.
		if !is_dev and !registry.is_enabled(id):
			_mark_state(str(id), "disabled", str(registry.entry(id).get("disabled_reason", "Disabled.")))
			continue

		var compatibility := Manifest.check_compatibility(manifest, api_version, editor_version)
		if !compatibility.get("ok", false):
			_mark_state(str(id), "unsupported", Result.message_of(compatibility))
			notice.emit("'%s' was not activated: %s" % [str(manifest.get("name", id)), Result.message_of(compatibility)], "warning")
			continue

		# A signed package whose bytes changed after install no longer verifies.
		# Refuse to run it; the UI asks for a clean reinstall.
		var signature: Dictionary = record.get("signature", {}) if record.get("signature") is Dictionary else {}
		if bool(signature.get("present", false)) and !bool(signature.get("ok", false)):
			_mark_state(str(id), "blocked", "The installed package signature is invalid. Reinstall it from a signed package.")
			notice.emit("'%s' was not activated: its signature is invalid." % str(manifest.get("name", id)), "error")
			continue

		manifests[str(id)] = manifest

	var resolved: Dictionary = Resolver.resolve(manifests)
	if bool(resolved.get("ok", false)):
		return resolved

	# A dependency problem blocks the implicated mods, not the whole set. Remove
	# them, then remove anything that required a removed mod, until stable.
	var blocked: Dictionary = {}
	for error in resolved.get("errors", []):
		var ids: Variant = (error as Dictionary).get("ids", [])
		if ids is Array:
			for id in ids:
				blocked[str(id)] = true

	var remaining: Array = []
	for id in resolved.get("order", []):
		if blocked.has(str(id)):
			_block_dependency(str(id), "Dependency problem; see the mod log.")
		else:
			remaining.append(str(id))

	var changed := true
	while changed:
		changed = false
		var keep: Array = []
		for id in remaining:
			var manifest: Dictionary = manifests[str(id)] if manifests.has(str(id)) else {}
			var missing_dependency := false
			var dependencies: Variant = manifest.get("dependencies", {})
			if dependencies is Dictionary:
				for dep in (dependencies as Dictionary).keys():
					if !remaining.has(str(dep)):
						missing_dependency = true
						break
			if missing_dependency:
				blocked[str(id)] = true
				_block_dependency(str(id), "A required dependency is unavailable.")
				changed = true
			else:
				keep.append(str(id))
		remaining = keep

	resolved["order"] = remaining
	return resolved


# ── ACTIVATION ──────────────────────────────────────────────────────────────

func activate(id: String) -> Dictionary:
	var key := str(id)
	if _session_disabled:
		return Result.error("state.invalid", "All mods are disabled for this session.")

	if _states.has(key) and str((_states[key] as Dictionary).get("status", "")) == "active":
		return Result.ok(_states[key])

	if _hosts.has(key):
		deactivate(key, "Reactivating.")

	var record: Variant = _installed.get(key)
	if !(record is Dictionary):
		return Result.error("dependency.missing", "'%s' is not installed." % key)

	var installed: Dictionary = record
	var manifest: Dictionary = installed["manifest"]

	var compatibility := Manifest.check_compatibility(manifest, api_version, editor_version)
	if !compatibility.get("ok", false):
		_mark_state(key, "unsupported", Result.message_of(compatibility))
		return compatibility

	var consent: Dictionary = permissions.consent_status(
		key,
		str(manifest.get("version", "")),
		str(installed.get("hash", "")),
		manifest.get("permissions", []),
	)

	if !bool(consent.get("granted", false)):
		var missing: Array = consent.get("missing", [])
		_mark_state(key, "blocked", "Needs consent for: " + ", ".join(missing), missing)
		notice.emit(
			"'%s' needs permission consent: %s" % [str(manifest.get("name", key)), ", ".join(missing)],
			"warning",
		)
		return Result.consent_required(missing)

	if bool(consent.get("refresh", false)):
		permissions.grant(key, str(manifest.get("version", "")), str(installed.get("hash", "")), manifest.get("permissions", []))

	permissions.set_active(key, manifest.get("permissions", []))

	var storage = Storage.new(key, data_root)
	storage.load_state()
	var progress = Progress.new(key, data_root)
	progress.load_state()
	var settings = Settings.new(key, data_root)
	settings.load_state()
	settings.declare(manifest.get("settings", []), "manifest")

	_storage[key] = storage
	_progress[key] = progress
	_settings[key] = settings
	_registrations[key] = {"commands": [], "bindings": []}

	var mod_info := {
		"id": key,
		"name": str(manifest.get("name", key)),
		"version": str(manifest.get("version", "")),
	}
	var host = Host.new(mod_info, null, diagnostics)
	host.sandbox_path = sandbox_path
	host.instruction_limit = Host.DEFAULT_INSTRUCTION_LIMIT
	host.instruction_step = Host.DEFAULT_INSTRUCTION_STEP

	var api = Api.new(mod_info, {
		"permissions": permissions,
		"storage": storage,
		"progress": progress,
		"settings": settings,
		"events": event_bus,
		"diagnostics": diagnostics,
		"commands": self,
		"host": host,
		"trust": trust_service,
		"workspace_root": workspace_root,
		"developer_mode": developer_mode,
		"docs": documents_service,
		"files": files_service,
		"workspace": workspace_service,
		"run_service": run_service,
		"clipboard": clipboard_service,
		"ui": ui,
		"shell": shell_service,
		"guide": guide_service,
		"exercise": exercise_service,
	})

	host.api = api
	_apis[key] = api
	_hosts[key] = host

	var host_start := host.start()
	if !host_start.get("ok", false):
		_fail(key, Result.code_of(host_start), Result.message_of(host_start))
		return host_start

	var entry_path := str(installed["root"]).path_join(str(manifest.get("entry", "main.lua")))
	var source := FileAccess.get_file_as_string(entry_path)
	if source.is_empty():
		var message := "The entry file is missing or empty: " + entry_path
		_fail(key, "module.not_found", message)
		return Result.error("module.not_found", message)

	var activation := host.activate(source, str(manifest.get("entry", "main.lua")))
	if !activation.get("ok", false):
		_fail(key, Result.code_of(activation), Result.message_of(activation))
		return activation

	_mark_state(key, "active", "")
	if bool(installed.get("dev", false)):
		dev_watcher.watch(key, str(installed["root"]))
	diagnostics.mark_healthy(key)
	event_bus.publish("mod.activated", {"id": key, "version": str(manifest.get("version", ""))})

	return Result.ok(_states.get(key, {}))


func deactivate(id: String, reason: String = "") -> Dictionary:
	var key := str(id)
	if !_hosts.has(key) and !_states.has(key):
		return Result.ok()

	_teardown(key, true)
	dev_watcher.unwatch(key)
	_mark_state(key, "inactive", reason)
	event_bus.publish("mod.deactivated", {"id": key})

	return Result.ok()


func reload_mod(id: String) -> Dictionary:
	var key := str(id)
	if _states.has(key) and str((_states[key] as Dictionary).get("status", "")) == "active":
		deactivate(key, "Reloading.")

	var result := activate(key)
	if result.get("ok", false):
		diagnostics.mark_healthy(key)
		failure_cleared.emit(key)
	return result


## Developer mode only. A file change in a dev package deactivates and reactivates
## the mod after a short quiet window. Installed packages are never watched.
func _poll_dev_watcher(elapsed_ms: float) -> void:
	if !developer_mode or safe_mode or _session_disabled:
		return

	for id in dev_watcher.tick(elapsed_ms):
		var key := str(id)
		var status := str(state(key).get("status", ""))
		if status != "active" and status != "failed":
			continue

		diagnostics.log(key, "info", "Hot reload triggered by a file change.")
		var result := reload_mod(key)
		if result.get("ok", false):
			_notice("Reloaded '%s' after a file change." % _display_name(key), "info")


## Riskier than deactivate(): the registry stays enabled, but nothing activates
## again until the next launch. Used by the panic path and safe mode UI.
func disable_all_for_session(reason: String = "All mods were disabled for this session.") -> void:
	_session_disabled = true
	for id in _hosts.keys().duplicate():
		deactivate(str(id), reason)
	_pending_activation.clear()
	_notice(reason, "warning")


# ── PHASE 3 BRIDGES ─────────────────────────────────────────────────────────

func display_name(id: String) -> String:
	return _display_name(str(id))


func filter_guide_input(event: Dictionary) -> Dictionary:
	if guide_service == null or !guide_service.has_method("filter"):
		return {"action": "pass"}
	return guide_service.filter(event)


func notify_guide_text(view) -> void:
	if guide_service != null and guide_service.has_method("on_text_changed"):
		guide_service.on_text_changed(view)


func notify_guide_caret(view) -> void:
	if guide_service != null and guide_service.has_method("on_caret_moved"):
		guide_service.on_caret_moved(view)


## RunService finished one run. A validation run may own it, in which case the
## runner resolves the exercise instead of the mods seeing a stray result.
func notify_run_finished(output: String, exit_code: int) -> bool:
	if validation_service == null or !validation_service.has_method("notify_run_finished"):
		return false
	return bool(validation_service.notify_run_finished(output, int(exit_code)))


func panic_mods() -> Dictionary:
	if shell_service == null or !shell_service.has_method("panic"):
		return {"had_shell": false, "owner": ""}
	return shell_service.panic()


func mark_shell_active(active: bool) -> void:
	if safe_guard != null and safe_guard.has_method("mark_shell"):
		safe_guard.mark_shell(bool(active))


func shell_state() -> Dictionary:
	if shell_service == null or !shell_service.has_method("state"):
		return {"active": false, "owner": ""}
	return shell_service.state()


func set_enabled(id: String, enabled: bool, reason: String = "") -> Dictionary:
	var key := str(id)
	if !registry.has(key):
		return Result.error("registry.invalid", "'%s' is not installed." % key)

	var saved: Dictionary = registry.set_enabled(key, enabled, reason)
	if !saved.get("ok", false):
		return saved

	if !enabled:
		deactivate(key, reason)
		_mark_state(key, "disabled", reason)
	else:
		activate(key)

	return Result.ok()


func grant_consent(id: String, permissions_to_grant: Array = []) -> Dictionary:
	var key := str(id)
	var record: Variant = _installed.get(key)
	if !(record is Dictionary):
		return Result.error("dependency.missing", "'%s' is not installed." % key)

	var manifest: Dictionary = (record as Dictionary)["manifest"]
	var declared: Array = permissions_to_grant
	if declared.is_empty():
		declared = manifest.get("permissions", [])

	var granted: Dictionary = permissions.grant(key, str(manifest.get("version", "")), str((record as Dictionary).get("hash", "")), declared)
	if !granted.get("ok", false):
		return granted

	return activate(key)


func deny_consent(id: String) -> Dictionary:
	var key := str(id)
	permissions.revoke(key)
	permissions.clear_active(key)
	_mark_state(key, "blocked", "Permission consent was denied.", permissions.sensitive(registry_permissions(key)))
	return Result.ok()


# ── DISTRIBUTION (PHASE 6) ──────────────────────────────────────────────────

## Validates a package and returns the review the import dialog renders. No file
## is extracted. Options: allow_unsigned, trust_publisher, replace_key, replace,
## allow_downgrade, consent.
func inspect_package(package_path: String, options: Dictionary = {}) -> Dictionary:
	if installer == null:
		return Result.error("state.invalid", "The installer is not available.")
	return installer.inspect(package_path, options)


## Installs a reviewed package, rescans and optionally activates it. When the
## user accepted the permission list, the consent record is written before
## activation; otherwise activation stays blocked on the missing permissions.
func import_package(package_path: String, options: Dictionary = {}) -> Dictionary:
	if installer == null:
		return Result.error("state.invalid", "The installer is not available.")

	var inspected: Dictionary = installer.inspect(package_path, options)
	if !inspected.get("ok", false):
		return inspected
	var review: Dictionary = inspected["value"]
	var key := str(review.get("id", ""))
	var was_active := str(state(key).get("status", "")) == "active"
	if was_active:
		deactivate(key, "Updating.")

	var installed: Dictionary = installer.install(package_path, options)
	if !installed.get("ok", false):
		if was_active and _installed.has(key):
			activate(key)
		return installed

	var details: Dictionary = installed["value"]
	scan_installed()
	if !_installed.has(key):
		return Result.error("install.move_failed", "The package was installed but the mod scan could not find it.")

	var declared: Array = (review.get("manifest", {}) as Dictionary).get("permissions", [])
	var growth: Dictionary = review.get("permission_growth", {})
	if bool(growth.get("requires_consent", false)) and bool(options.get("consent", false)):
		var granted: Dictionary = permissions.grant(key, str(details.get("version", "")), str(details.get("hash", "")), declared)
		if !granted.get("ok", false):
			return granted

	var activation: Dictionary = Result.ok()
	var activated := false
	if bool(options.get("activate", true)):
		activation = activate(key)
		activated = activation.get("ok", false)
		if !activated:
			_notice("'%s' was installed but not activated: %s" % [
				str(review.get("name", key)),
				Result.message_of(activation),
			], "warning")

	return Result.ok({
		"install": details,
		"review": review,
		"activated": activated,
		"activation_error": {} if activated else activation.get("error", {}),
		"state": state(key),
	})


## Restores the previous version recorded by the last update. The manager
## deactivates first so the old Lua state cannot keep running from a path that
## is no longer the active record.
func rollback_mod(id: String, options: Dictionary = {}) -> Dictionary:
	if installer == null:
		return Result.error("state.invalid", "The installer is not available.")
	var key := str(id)
	var was_active := str(state(key).get("status", "")) == "active"
	if was_active:
		deactivate(key, "Rolling back.")

	var rolled: Dictionary = installer.rollback(key, options)
	if !rolled.get("ok", false):
		if was_active and _installed.has(key):
			activate(key)
		return rolled

	scan_installed()
	if !_installed.has(key):
		return Result.error("update.rollback_blocked", "The previous version could not be scanned.")

	var activation := activate(key)
	return Result.ok({
		"rollback": rolled["value"],
		"activated": activation.get("ok", false),
		"activation_error": {} if activation.get("ok", false) else activation.get("error", {}),
		"state": state(key),
	})


## Removes every installed version and revokes consent. Mod data is kept by
## default; pass {"remove_data": true} to delete it as well.
func uninstall_mod(id: String, options: Dictionary = {}) -> Dictionary:
	if installer == null:
		return Result.error("state.invalid", "The installer is not available.")
	var key := str(id)
	if _hosts.has(key) or _states.has(key):
		deactivate(key, "Uninstalled.")
	dev_watcher.unwatch(key)
	if diagnostics.has_method("clear"):
		diagnostics.clear(key)

	var removed: Dictionary = installer.uninstall(key, options)
	if !removed.get("ok", false):
		return removed

	_installed.erase(key)
	_states.erase(key)
	return removed


func publisher_state(signature: Dictionary) -> Dictionary:
	if publishers == null:
		return {}
	return publishers.state(signature)


func trusted_publishers() -> Array:
	if publishers == null:
		return []
	return publishers.publishers()


func trust_publisher(signature: Dictionary, options: Dictionary = {}) -> Dictionary:
	if publishers == null:
		return Result.error("state.invalid", "The publisher store is not available.")
	return publishers.trust(signature, options)


func forget_publisher(publisher_id: String) -> Dictionary:
	if publishers == null:
		return Result.error("state.invalid", "The publisher store is not available.")
	return publishers.forget(publisher_id)


# ── FAILURES ────────────────────────────────────────────────────────────────

func _fail(id: String, code: String, message: String) -> void:
	var key := str(id)
	var failure := {
		"id": key,
		"code": code if !code.is_empty() else "mod.failed",
		"message": message if !message.is_empty() else "The mod stopped.",
		"name": _display_name(key),
	}

	_teardown(key, false)
	_mark_state(key, "failed", str(failure["message"]))
	diagnostics.mark_failed(key, failure)
	failure_reported.emit(key, diagnostics.failure(key))
	event_bus.publish("mod.failed", {"id": key, "reason": str(failure["message"])})

	_notice("'%s' failed: %s" % [str(failure["name"]), str(failure["message"])], "error")


func _teardown(id: String, call_deactivate: bool) -> void:
	var key := str(id)
	var host = _hosts.get(key)

	if host != null and call_deactivate and host.started:
		var started_usec := Time.get_ticks_usec()
		var result: Dictionary = host.call_global("deactivate")
		var elapsed := Time.get_ticks_usec() - started_usec
		if !result.get("ok", false):
			diagnostics.log(key, "warn", "deactivate() failed: " + Result.message_of(result))
		elif elapsed > 100000:
			diagnostics.log(key, "warn", "deactivate() took %.1f ms." % (float(elapsed) / 1000.0))

	# UI first, then commands, then state (plan §12.3). A shell outlives the
	# widget registry otherwise, and a guide would keep filtering keys for a
	# state that no longer exists.
	if exercise_service != null and exercise_service.has_method("stop_for_mod"):
		exercise_service.stop_for_mod(key, "The mod stopped.")
	if guide_service != null and guide_service.has_method("stop_for_mod"):
		guide_service.stop_for_mod(key, "The mod stopped.")
	if shell_service != null and shell_service.has_method("exit_for_mod"):
		shell_service.exit_for_mod(key, "The mod stopped.")
	event_bus.unsubscribe_all(key)
	if ui != null and ui.has_method("reset_mod"):
		ui.reset_mod(key)

	var registrations: Dictionary = _registrations.get(key, {})
	for command_id in registrations.get("commands", []):
		if command_registry != null:
			command_registry.unregister(str(command_id))
	for command_id in registrations.get("bindings", []):
		if keybinding_service != null:
			keybinding_service.clear_runtime_binding(str(command_id))
	_registrations.erase(key)

	if _storage.has(key):
		_storage[key].flush()
	if _progress.has(key):
		_progress[key].flush()
	if _settings.has(key):
		_settings[key].flush()

	_storage.erase(key)
	_progress.erase(key)
	_settings.erase(key)
	_apis.erase(key)
	_hosts.erase(key)
	permissions.clear_active(key)

	if host != null:
		host.teardown()


func _dispatch_event(mod_id: String, handle: int, payload: Variant) -> Dictionary:
	var host = _hosts.get(str(mod_id))
	if host == null or !host.started:
		return Result.error("state.invalid", "The mod is not running.")
	return host.invoke(int(handle), payload if payload is Dictionary else {})


# ── COMMANDS AND KEYS ───────────────────────────────────────────────────────

func register_command(mod_id: String, spec: Dictionary) -> Dictionary:
	var key := str(mod_id)
	var command_id := str(spec.get("id", ""))
	var label := str(spec.get("label", command_id))

	if command_id.is_empty() or command_id.length() > 120:
		return Result.error("command.invalid", "Command ids are 1-120 characters.")
	if !command_id.begins_with(key + "."):
		return Result.error("command.invalid", "Command ids must start with '%s.'." % key)
	if command_registry == null:
		return Result.error("state.invalid", "The command registry is not available.")
	if command_registry.has(command_id):
		return Result.error("command.duplicate", "A command with the id '%s' already exists." % command_id)

	var handle := int(spec.get("handler", -1))
	if handle <= 0:
		return Result.error("command.invalid", "A mod command needs a handler function.")

	var owner := key
	var callable := func(_a0: Variant = null, _a1: Variant = null) -> void:
		var args: Array = []
		if _a0 != null:
			args.append(_a0)
		if _a1 != null:
			args.append(_a1)
		_run_command(owner, command_id, handle, args)

	command_registry.register(command_id, {
		"label": label,
		"category": str(spec.get("category", "Mods")),
		"hidden": bool(spec.get("hidden", false)),
		"handler": callable,
		"mod_id": owner,
		"mod_handle": handle,
		"mod_name": _display_name(owner),
	})

	if _registrations.has(key):
		(_registrations[key]["commands"] as Array).append(command_id)

	return Result.ok(command_id)


func unregister_command(mod_id: String, command_id: String) -> Dictionary:
	var key := str(mod_id)
	if command_registry == null:
		return Result.error("state.invalid", "The command registry is not available.")

	var entry: Dictionary = command_registry.get_command(command_id)
	if entry.is_empty():
		return Result.error("command.unknown", "The command '%s' is not registered." % command_id)
	if str(entry.get("mod_id", "")) != key:
		return Result.error("permission.denied", "A mod may only unregister its own commands.")

	command_registry.unregister(command_id)
	if _registrations.has(key):
		(_registrations[key]["commands"] as Array).erase(command_id)

	return Result.ok()


## Mod-initiated execution is deferred to the next host tick: running a command
## from inside a Lua call would resume a coroutine from within a coroutine.
func execute_command(mod_id: String, command_id: String, args: Variant = null) -> Dictionary:
	var key := str(mod_id)
	if command_registry == null:
		return Result.error("state.invalid", "The command registry is not available.")

	var entry: Dictionary = command_registry.get_command(command_id)
	if entry.is_empty():
		return Result.error("command.unknown", "The command '%s' is not registered." % command_id)

	var owner := str(entry.get("mod_id", ""))
	if owner.is_empty() or owner != key:
		return Result.error("permission.denied", "A mod may only execute its own commands.")

	# Keep the caller on the queued item too. Draining re-checks ownership so a
	# command that changes owner between queue and tick can never cross mods.
	_pending_commands.append({
		"id": str(command_id),
		"mod_id": key,
		"args": Json.as_array(args),
	})
	while _pending_commands.size() > MAX_PENDING_COMMANDS:
		_pending_commands.pop_front()

	return Result.ok(true)


func bind_mod_key(mod_id: String, command_id: String, chord: String) -> Dictionary:
	var key := str(mod_id)
	if keybinding_service == null:
		return Result.error("state.invalid", "The keybinding service is not available.")
	if command_registry == null:
		return Result.error("state.invalid", "The command registry is not available.")

	var entry: Dictionary = command_registry.get_command(command_id)
	if entry.is_empty():
		return Result.error("command.unknown", "The command '%s' is not registered." % command_id)
	if str(entry.get("mod_id", "")) != key:
		return Result.error("permission.denied", "A mod may only bind its own commands.")

	var bound: Dictionary = keybinding_service.set_runtime_binding(command_id, chord, false)
	if !bound.get("ok", false):
		var conflicts: Array = bound.get("conflicts", [])
		return Result.error(
			"key.collision" if !conflicts.is_empty() else "key.invalid",
			str(bound.get("error", "The shortcut could not be bound.")),
			{"conflicts": conflicts},
		)

	if _registrations.has(key):
		var bindings: Array = _registrations[key]["bindings"]
		if !bindings.has(command_id):
			bindings.append(command_id)

	return Result.ok()


func unbind_mod_key(mod_id: String, command_id: String) -> Dictionary:
	var key := str(mod_id)
	if keybinding_service == null:
		return Result.error("state.invalid", "The keybinding service is not available.")

	var entry: Dictionary = command_registry.get_command(command_id) if command_registry != null else {}
	if !entry.is_empty() and str(entry.get("mod_id", "")) != key:
		return Result.error("permission.denied", "A mod may only unbind its own commands.")

	keybinding_service.clear_runtime_binding(command_id)
	if _registrations.has(key):
		(_registrations[key]["bindings"] as Array).erase(command_id)

	return Result.ok()


func _run_command(mod_id: String, command_id: String, handle: int, args: Array) -> void:
	var host = _hosts.get(str(mod_id))
	if host == null or !host.started:
		return

	var result: Dictionary = host.invoke(handle, {"args": args})
	if result.get("ok", false):
		return

	var code := Result.code_of(result)
	diagnostics.log(str(mod_id), "error", "Command '%s' failed: %s" % [command_id, Result.message_of(result)])
	if code == "host.fatal":
		_fail(str(mod_id), code, Result.message_of(result))


func _drain_pending_commands() -> void:
	while !_pending_commands.is_empty():
		var item: Dictionary = _pending_commands.pop_front()
		var command_id := str(item.get("id", ""))
		var args: Array = item.get("args", [])

		if command_registry == null:
			continue

		var entry: Dictionary = command_registry.get_command(command_id)
		if entry.is_empty():
			continue

		var owner := str(entry.get("mod_id", ""))
		if owner.is_empty() or owner != str(item.get("mod_id", "")):
			continue
		_run_command(owner, command_id, int(entry.get("mod_handle", -1)), args)


# ── MOD FILES ───────────────────────────────────────────────────────────────

## Resolves a mod-relative read for `require`, `editor.content.load` and
## `editor.assets.read_text`. Prefix-checked and size-limited; an escape is a
## structured error, never a read.
func read_mod_file(mod_id: String, kind: String, relative: String) -> Dictionary:
	var key := str(mod_id)
	var record: Variant = _installed.get(key)
	if !(record is Dictionary):
		return Result.error("module.not_found", "'%s' is not installed." % key)

	var folder := "lib" if kind == "module" else kind
	var base := str((record as Dictionary)["root"]).path_join(folder)
	var path := str(relative).strip_edges().replace("\\", "/")

	if path.is_empty() or path.begins_with("/") or path.contains(":") or path.contains(".."):
		return Result.error("path.invalid", "'%s' is not a relative mod path." % relative)

	if kind != "assets":
		if path.get_extension().is_empty():
			path += ".lua"
		if path.get_extension().to_lower() != "lua":
			return Result.error("path.invalid", "Only .lua files can be loaded.")

	var full := Paths.normalize(base.path_join(path))
	if !Paths.is_subpath(base, full):
		return Result.error("path.outside_workspace", "'%s' resolves outside the mod folder." % relative)
	if !FileAccess.file_exists(full):
		return Result.error("module.not_found", "The file '%s' does not exist." % path)

	var limit := MAX_CODE_BYTES if kind != "assets" else MAX_ASSET_TEXT_BYTES
	var file := FileAccess.open(full, FileAccess.READ)
	if file == null:
		return Result.error("module.not_found", "The file '%s' could not be opened." % path)
	if file.get_length() > limit:
		file.close()
		return Result.error("module.invalid", "The file '%s' is larger than %d bytes." % [path, limit])

	var text := file.get_as_text()
	file.close()
	return Result.ok(text)


# ── HELPERS ─────────────────────────────────────────────────────────────────

func _mark_state(id: String, status: String, reason: String, missing: Array = []) -> void:
	var key := str(id)
	var manifest: Dictionary = {}
	if _installed.has(key):
		manifest = (_installed[key] as Dictionary).get("manifest", {})

	var previous: Dictionary = _states.get(key, {})
	var state := {
		"id": key,
		"name": str(manifest.get("name", previous.get("name", key))),
		"version": str(manifest.get("version", previous.get("version", ""))),
		"status": status,
		"reason": reason,
		"missing_permissions": missing.duplicate(),
	}
	_states[key] = state
	mod_state_changed.emit(key, state.duplicate(true))


func _block_dependency(id: String, reason: String) -> void:
	_mark_state(id, "blocked", reason)
	_notice("'%s' was not activated: %s" % [_display_name(id), reason], "warning")


func _notice(message: String, severity: String = "info") -> void:
	if message.strip_edges().is_empty():
		return
	notice.emit(message, severity)


func _display_name(id: String) -> String:
	if _installed.has(str(id)):
		var manifest: Dictionary = (_installed[str(id)] as Dictionary).get("manifest", {})
		var name := str(manifest.get("name", ""))
		if !name.is_empty():
			return name
	return str(id)


func registry_permissions(id: String) -> Array:
	if !_installed.has(str(id)):
		return []
	var manifest: Dictionary = (_installed[str(id)] as Dictionary).get("manifest", {})
	var permissions: Variant = manifest.get("permissions", [])
	return (permissions as Array).duplicate() if permissions is Array else []


func _elapsed_usec() -> int:
	return maxi(0, Time.get_ticks_usec() - _startup_usec)


func _record_scan_error(message: String) -> void:
	_scan_errors.append({"message": str(message)})


## Newest file timestamp in the package. This is the cheap startup check: it
## stats files but never reads them.
func _package_mtime(root: String) -> int:
	var files: Array = []
	_collect_files(root, "", files)
	var newest := 0
	for relative in files:
		newest = maxi(newest, int(FileAccess.get_modified_time(root.path_join(str(relative)))))
	return newest


## Canonical package digest for an installed folder. This is the same hash the
## signature covers, so the registry, consent records and signatures all bind to
## one identity. The timestamp is what makes rehashing cheap: startup stats
## files but only reads them when something changed.
func _package_info(root: String) -> Dictionary:
	var digest := Package.digest_folder(root)
	return {
		"hash": str(digest.get("hash", "")),
		"mtime": int(digest.get("mtime", 0)),
		"ok": bool(digest.get("ok", false)),
		"errors": digest.get("errors", []),
	}


func _read_installed_signature(root: String, hash: String) -> Dictionary:
	var path := root.path_join(Package.SIGNATURE_FILE)
	if !FileAccess.file_exists(path):
		return {"present": false, "ok": true, "status": "unsigned"}
	return Package.check_signature_bytes(FileAccess.get_file_as_bytes(path), hash)


func _choose_candidate(candidates: Array, existing: Dictionary) -> Dictionary:
	var active_version := str(existing.get("version", ""))
	if !active_version.is_empty():
		var active_path := str(existing.get("path", ""))
		var fallback: Dictionary = {}
		for candidate in candidates:
			var item: Dictionary = candidate
			if str((item.get("manifest", {}) as Dictionary).get("version", "")) != active_version:
				continue
			if Paths.same_file(str(item.get("root", "")), active_path):
				return item
			if fallback.is_empty():
				fallback = item
		if !fallback.is_empty():
			return fallback

	var best: Dictionary = candidates[0]
	for candidate in candidates:
		var item: Dictionary = candidate
		if Version.is_higher_version(
			str((best.get("manifest", {}) as Dictionary).get("version", "")),
			str((item.get("manifest", {}) as Dictionary).get("version", "")),
		):
			best = item
	return best


func _snapshot_entry(entry: Dictionary) -> Dictionary:
	var signature: Variant = entry.get("signature", {})
	return {
		"version": str(entry.get("version", "")),
		"hash": str(entry.get("hash", "")),
		"path": str(entry.get("path", "")),
		"manifest_mtime": int(entry.get("manifest_mtime", 0)),
		"package_mtime": int(entry.get("package_mtime", 0)),
		"signature": (signature as Dictionary).duplicate(true) if signature is Dictionary else {},
		"allow_unsigned": bool(entry.get("allow_unsigned", false)),
	}


func _signature_stamp(signature: Variant) -> String:
	if !(signature is Dictionary):
		return ""
	var source: Dictionary = signature
	return "%s|%s|%s|%s|%s|%s|%s" % [
		str(source.get("present", false)),
		str(source.get("ok", false)),
		str(source.get("status", "")),
		str(source.get("publisher_id", "")),
		str(source.get("fingerprint", "")),
		str(source.get("public_key", "")),
		str(source.get("error", "")),
	]


func _collect_files(directory: String, relative: String, out: Array) -> void:
	var dir := DirAccess.open(directory)
	if dir == null:
		return

	var names: Array = dir.get_files()
	names.sort()
	for name in names:
		var file_name := str(name)
		if file_name.ends_with(".griddy_tmp"):
			continue
		out.append(file_name if relative.is_empty() else relative.path_join(file_name))

	var folders: Array = dir.get_directories()
	folders.sort()
	for folder in folders:
		var folder_name := str(folder)
		_collect_files(
			directory.path_join(folder_name),
			folder_name if relative.is_empty() else relative.path_join(folder_name),
			out,
		)


# ── INTROSPECTION ───────────────────────────────────────────────────────────

func state(id: String) -> Dictionary:
	var found: Variant = _states.get(str(id))
	return (found as Dictionary).duplicate(true) if found is Dictionary else {}


func states() -> Array:
	var ids: Array = _states.keys()
	ids.sort()
	var out: Array = []
	for id in ids:
		out.append((_states[id] as Dictionary).duplicate(true))
	return out


func installed() -> Array:
	var out: Array = []
	for id in _installed.keys():
		var record: Dictionary = _installed[id]
		var signature: Dictionary = record.get("signature", {}) if record.get("signature") is Dictionary else {}
		var registry_entry: Dictionary = registry.entry(str(id))
		out.append({
			"id": str(id),
			"root": str(record.get("root", "")),
			"version": str((record.get("manifest", {}) as Dictionary).get("version", "")),
			"name": str((record.get("manifest", {}) as Dictionary).get("name", "")),
			"hash": str(record.get("hash", "")),
			"dev": bool(record.get("dev", false)),
			"signature": signature.duplicate(true),
			"signature_status": str(signature.get("status", "unsigned")),
			"publisher_id": str(signature.get("publisher_id", "")),
			"publisher_fingerprint": str(signature.get("fingerprint", "")),
			"previous_version": str(registry_entry.get("previous_version", "")),
			"allow_unsigned": bool(record.get("allow_unsigned", false)),
		})
	return out


func dev_mods() -> Array:
	var out: Array = []
	for id in _installed.keys():
		var record: Dictionary = _installed[id]
		if !bool(record.get("dev", false)):
			continue
		out.append({
			"id": str(id),
			"root": str(record.get("root", "")),
			"version": str((record.get("manifest", {}) as Dictionary).get("version", "")),
			"name": str((record.get("manifest", {}) as Dictionary).get("name", "")),
		})
	return out


func publish(name: String, payload: Variant = null) -> Dictionary:
	return event_bus.publish(name, payload)


## Dispatches a widget/dialog handler into the owning mod's Lua state. The UI
## registry calls this; the host still creates a hooked task for every callback.
func invoke_handler(id: String, handle: int, payload: Variant = {}) -> Dictionary:
	var host_ref = _hosts.get(str(id))
	if host_ref == null or !host_ref.started:
		return Result.error("state.invalid", "The mod is not running.")
	return host_ref.invoke(int(handle), payload if payload is Dictionary else {})


## Snapshot used by the Mods settings page.
func settings_for(id: String) -> Dictionary:
	var settings = _settings.get(str(id))
	if settings == null:
		return {"definitions": [], "values": {}}
	return {
		"definitions": settings.definitions(),
		"values": settings.values(),
	}


func set_mod_setting(id: String, key: String, value: Variant) -> Dictionary:
	var settings = _settings.get(str(id))
	if settings == null:
		return Result.error("state.invalid", "The mod is not active.")
	return settings.set_value(key, value)


func host(id: String):
	return _hosts.get(str(id))


func api_for(id: String):
	return _apis.get(str(id))


func pending_activations() -> int:
	return _pending_activation.size()


func pending_consents() -> Array:
	var out: Array = []
	for id in _states.keys():
		var entry: Dictionary = _states[id]
		if str(entry.get("status", "")) == "blocked":
			out.append(entry.duplicate(true))
	return out


## Phase 7: user-installed legacy language/theme content. Read-only.
func legacy_content() -> Dictionary:
	return hardening.legacy_inventory()


## Phase 7: the Gate H audit for this session. The Mods page renders the checks
## and the release gate consumes the same report, so UI and tests cannot drift.
func health_report() -> Dictionary:
	if hardening == null:
		return {}

	var memory := 0
	var memory_limit := 0
	var budget_exceeded := 0
	var hard_overruns := 0
	var tasks := 0
	for id in _hosts.keys():
		var host = _hosts[id]
		if host == null or !host.has_method("status"):
			continue
		var host_status: Dictionary = host.status()
		var used := int(host_status.get("memory_usage", -1))
		if used > 0:
			memory += used
		var limit := int(host_status.get("memory_limit", 0))
		if limit > 0:
			memory_limit += limit
		var budget: Dictionary = host_status.get("budget", {}) if host_status.get("budget") is Dictionary else {}
		budget_exceeded += int(budget.get("budget_exceeded", 0))
		hard_overruns += int(budget.get("hard_overruns", 0))
		tasks += maxi(0, int(host_status.get("tasks", 0)))

	var ui_audit: Dictionary = {}
	if ui != null and ui.has_method("accessibility_audit"):
		ui_audit = ui.accessibility_audit()

	return hardening.audit({
		"started": started,
		"preview_build": preview_build,
		"developer_mode": developer_mode,
		"safe_mode": safe_mode,
		"session_disabled": _session_disabled,
		"safe_reason": _safe_reason,
		"startup_usec": (_startup_duration_usec if _start_finished else _elapsed_usec()) if started else 0,
		"deferred": _startup_was_deferred,
		"pending_activations": _pending_activation.size(),
		"states": states(),
		"installed": installed(),
		"scan_errors": _scan_errors.duplicate(true),
		"failures": diagnostics.failures(),
		"memory_bytes": memory,
		"memory_limit_bytes": memory_limit,
		"budget_exceeded": budget_exceeded,
		"hard_overruns": hard_overruns,
		"tasks": tasks,
		"ui_audit": ui_audit,
	})


func status_report() -> Dictionary:
	return {
		"ok": true,
		"started": started,
		"safe_mode": safe_mode,
		"safe_reason": _safe_reason,
		"session_disabled": _session_disabled,
		"api_version": api_version,
		"api_semver": Api.API_SEMVER,
		"api_frozen": Api.API_FROZEN,
		"preview_build": preview_build,
		"developer_mode": developer_mode,
		"channel": hardening.channel(preview_build, developer_mode) if hardening != null else {},
		"platform": hardening.platform() if hardening != null else {},
		"dev_root": dev_root,
		"dev_mods": dev_mods(),
		"dev_watched": dev_watcher.watched_ids(),
		"hot_reload": developer_mode and !safe_mode and !_session_disabled,
		"editor_version": editor_version,
		"startup_usec": (_startup_duration_usec if _start_finished else _elapsed_usec()) if started else 0,
		"deferred": _startup_was_deferred,
		"mods": states(),
		"installed": installed(),
		"scan_errors": _scan_errors.duplicate(true),
		"failures": diagnostics.failures(),
		"publishers": publishers.publishers() if publishers != null else [],
		"allow_unsigned": allow_unsigned_imports,
		"staging_root": staging_root,
	}
