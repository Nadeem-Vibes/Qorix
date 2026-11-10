extends TestCase

## ModManager integration: discovery, activation order, commands, events,
## storage, consent, failures, safe mode and the crash-loop guard.

const ManagerScript = preload("res://src/features/mods/mod_manager.gd")
const RegistryScript = preload("res://src/platform/command_registry.gd")
const KeybindingScript = preload("res://src/platform/keybinding_service.gd")
const TrustScript = preload("res://src/platform/trust_service.gd")
const Store = preload("res://src/base/file_store.gd")
const Result = preload("res://src/features/mods/mod_result.gd")

const ROOT := "user://griddy_mod_tests/manager"


func before_each() -> void:
	_clean(ROOT)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ROOT))


func after_each() -> void:
	_clean(ROOT)


func _make(fixture: String):
	var command_registry = RegistryScript.new()
	var keybindings = KeybindingScript.new()
	keybindings.setup(command_registry)

	var manager = ManagerScript.new()
	manager.setup({
		"mods_root": "res://tests/fixtures/mods/" + fixture,
		"data_root": ROOT + "/data",
		"registry_path": ROOT + "/mod_registry.json",
		"permissions_path": ROOT + "/mod_permissions.json",
		"session_path": ROOT + "/mod_session.json",
		"command_registry": command_registry,
		"keybinding_service": keybindings,
		"trust_service": TrustScript.new(),
		"editor_version": "1.4.0",
		"developer_mode": true,
	})
	return manager


func _status(manager, id: String) -> String:
	return str(manager.state(id).get("status", ""))


func _kv(manager, id: String) -> Dictionary:
	var path: String = ROOT + "/data/" + id + "/kv.json"
	if !FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


func test_minimal_activation_and_command() -> void:
	var manager = _make("minimal")
	var report: Dictionary = manager.start()
	check(report.get("ok", false), "start reports ok")
	assert_eq(_status(manager, "griddycode.minimal"), "active")
	check(manager.command_registry.has("griddycode.minimal.hello"), "command registered")

	manager.tick(0.016)
	var log_text: String = manager.diagnostics.text("griddycode.minimal")
	check(log_text.contains("minimal activated"), "activation logged")
	check(log_text.contains("mods ready: 1"), "app.mods_ready delivered")

	manager.command_registry.execute("griddycode.minimal.hello")
	manager.tick(0.016)
	check(manager.diagnostics.text("griddycode.minimal").contains("hello from minimal (1)"), "command handler ran")

	var kv := _kv(manager, "griddycode.minimal")
	check(int(kv.get("hello_count", 0)) == 1, "storage persisted")

	manager.deactivate("griddycode.minimal", "test")
	check(!manager.command_registry.has("griddycode.minimal.hello"), "command unregistered")
	assert_eq(_status(manager, "griddycode.minimal"), "inactive")

	manager.stop()
	var marker: Variant = JSON.parse_string(FileAccess.get_file_as_string(ROOT + "/mod_session.json"))
	check(marker is Dictionary and bool((marker as Dictionary).get("clean", false)), "clean exit marker")


func test_mods_cannot_execute_host_or_foreign_commands() -> void:
	var manager = _make("minimal")
	manager.start()
	var host_ran := [false]
	manager.command_registry.register("file.save", {
		"handler": func(_args: Variant = null) -> void:
			host_ran[0] = true
	})

	var denied: Dictionary = manager.execute_command("griddycode.minimal", "file.save")
	assert_eq(Result.code_of(denied), "permission.denied", "host commands are not callable")
	check(manager._pending_commands.is_empty(), "nothing was queued")

	# Even a forged queue entry is re-checked at drain time, so a host command can
	# never slip through between queue and tick.
	manager._pending_commands.append({
		"id": "file.save",
		"mod_id": "griddycode.minimal",
		"args": [],
	})
	manager._drain_pending_commands()
	check(!host_ran[0], "host command was not executed")

	var own: Dictionary = manager.execute_command("griddycode.minimal", "griddycode.minimal.hello")
	check(bool(own.get("ok", false)), "a mod may execute its own command")
	manager._drain_pending_commands()
	check(manager.diagnostics.text("griddycode.minimal").contains("hello from minimal (1)"), "own command ran")
	manager.stop()


func test_full_fixture_loaders_settings_and_keys() -> void:
	var manager = _make("full")
	manager.start()
	assert_eq(_status(manager, "griddycode.full"), "active")

	check(manager.keybinding_service.runtime_bindings().has("griddycode.full.greet"), "runtime binding recorded")
	check(!manager.keybinding_service.binding_for("griddycode.full.greet").is_empty(), "binding is effective")

	manager.command_registry.execute("griddycode.full.greet")
	manager.tick(0.016)

	var log_text: String = manager.diagnostics.text("griddycode.full")
	check(log_text.contains("full activated: intensity=3"), "manifest setting read")
	check(log_text.contains("hello, world"), "require() loaded the library")
	check(log_text.contains("Lesson one"), "content.load returned a table")
	check(log_text.contains("fixture asset"), "assets.read_text returned text")
	check(!log_text.contains("keybinding refused"), "keybinding accepted")
	check(log_text.contains("hello, world"), "command executed")

	manager.deactivate("griddycode.full", "test")
	check(!manager.keybinding_service.runtime_bindings().has("griddycode.full.greet"), "binding removed on teardown")


func test_dependency_order() -> void:
	var manager = _make("dependency")
	var order: Array = []
	manager.mod_state_changed.connect(func(id: String, state: Dictionary) -> void:
		if str(state.get("status", "")) == "active":
			order.append(id)
	)

	manager.start()
	assert_eq(order, ["griddycode.base", "griddycode.dependent"])
	assert_eq(_status(manager, "griddycode.base"), "active")
	assert_eq(_status(manager, "griddycode.dependent"), "active")


func test_consent_blocks_then_grants() -> void:
	var manager = _make("consent")
	manager.start()

	var blocked: Dictionary = manager.state("griddycode.sensitive")
	assert_eq(str(blocked.get("status", "")), "blocked")
	check((blocked.get("missing_permissions", []) as Array).has("documents.read"), "missing permission named")
	assert_eq(manager.pending_consents().size(), 1)

	var granted: Dictionary = manager.grant_consent("griddycode.sensitive")
	check(granted.get("ok", false), "consent activates the mod")
	assert_eq(_status(manager, "griddycode.sensitive"), "active")
	check(manager.command_registry.has("griddycode.sensitive.inspect"), "command registered after consent")


func test_activation_failure_is_isolated() -> void:
	var manager = _make("crash_activate")
	manager.start()

	assert_eq(_status(manager, "griddycode.crash"), "failed")
	check(manager.diagnostics.has_failure("griddycode.crash"), "failure recorded")
	assert_eq(str(manager.diagnostics.failure("griddycode.crash").get("code", "")), "mod.failed")
	check(manager.diagnostics.failure("griddycode.crash").get("message", "").contains("boom"), "error quoted")


func test_budget_and_memory_failures() -> void:
	var loop = _make("infinite_while")
	loop.start()
	assert_eq(_status(loop, "griddycode.infinite"), "failed")
	assert_eq(str(loop.diagnostics.failure("griddycode.infinite").get("code", "")), "budget.exceeded")

	var memory = _make("memory_hog")
	memory.start()
	assert_eq(_status(memory, "griddycode.memory"), "failed")
	assert_eq(str(memory.diagnostics.failure("griddycode.memory").get("code", "")), "memory.exceeded")


func test_nested_coroutine_fails_cleanly() -> void:
	var manager = _make("nested_coroutine")
	manager.start()
	assert_eq(_status(manager, "griddycode.nested"), "active")
	check(manager.diagnostics.text("griddycode.nested").contains("nil value"), "unhooked coroutine blocked")


func test_storage_quota_fixture() -> void:
	var manager = _make("storage_abuser")
	manager.start()
	manager.tick(0.016)
	check(manager.diagnostics.text("griddycode.storage").contains("storage.quota"), "quota error reported")


func test_path_escape_fixture() -> void:
	var manager = _make("path_escape")
	manager.start()
	var log_text: String = manager.diagnostics.text("griddycode.paths")
	check(log_text.contains("path.invalid"), "relative escape rejected")
	check(log_text.contains("absolute escape"), "absolute path attempted")
	check(log_text.contains("nil"), "no file contents returned")


func test_run_permission_denied() -> void:
	var manager = _make("run_abuser")
	manager.start()
	check(manager.diagnostics.text("griddycode.run").contains("permission.denied"), "run refused without consent")


func test_event_storm_drops_oldest() -> void:
	var manager = _make("event_storm")
	manager.start()
	check(manager.event_bus.dropped_count("griddycode.storm") > 0, "queue cap reported a drop")
	check(manager.event_bus.queue_depth("griddycode.storm") <= 256, "queue capped")


func test_safe_mode_activates_nothing() -> void:
	var manager = _make("minimal")
	manager.safe_mode = true
	manager.start()

	check(manager.safe_mode, "safe mode flag")
	check(manager.host("griddycode.minimal") == null, "no host was created")
	assert_ne(_status(manager, "griddycode.minimal"), "active")
	check(FileAccess.file_exists(ROOT + "/mod_session.json"), "session marker written")


func test_short_unclean_sessions_disable_previous_set() -> void:
	var first = _make("minimal")
	first.start()
	first.stop()

	var started_at := int(Time.get_unix_time_from_system()) - 5
	Store.save_json(ROOT + "/mod_session.json", {
		"version": 1,
		"clean": false,
		"started_at": started_at,
		"mods": ["griddycode.minimal"],
		"streak": 1,
	})

	var second = _make("minimal")
	second.start()
	check(!second.registry.is_enabled("griddycode.minimal"), "registry disabled the crashing set")
	assert_eq(_status(second, "griddycode.minimal"), "disabled")
	check(second.status_report().get("safe_reason", "").contains("clean exit"), "reason reported")


func test_reload_keeps_data() -> void:
	var manager = _make("minimal")
	manager.start()
	manager.command_registry.execute("griddycode.minimal.hello")
	check(int(_kv(manager, "griddycode.minimal").get("hello_count", 0)) == 1, "first run stored")

	manager.reload_mod("griddycode.minimal")
	assert_eq(_status(manager, "griddycode.minimal"), "active")
	manager.command_registry.execute("griddycode.minimal.hello")
	check(int(_kv(manager, "griddycode.minimal").get("hello_count", 0)) == 2, "storage survived reload")


func test_scan_reports_invalid_manifest() -> void:
	var manager = _make("bad_manifest")
	manager.start()
	check(!manager.status_report().get("scan_errors", []).is_empty(), "scan error reported")
	check(manager.host("bad.id") == null, "invalid manifest was not activated")


func test_deferred_activation_finishes_on_tick() -> void:
	var manager = _make("minimal")
	# Force the deferred path without waiting for a real 500 ms startup: queue the
	# mod manually, exactly as start() would after the budget ran out.
	manager.scan_installed()
	manager._pending_activation = ["griddycode.minimal"]
	manager._start_finished = false
	manager.started = true

	manager.tick(0.016)
	assert_eq(_status(manager, "griddycode.minimal"), "active")
	manager.stop()


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
