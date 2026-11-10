extends "res://tests/support/test_case.gd"

## Phase 7 hardening: platform policy, channels, legacy inventory, the Gate H
## audit, the mechanical accessibility audit, a 50-cycle panic/restore drill and
## the crash-loop/safe-mode drill. Everything here runs headless except the human
## checks, which the audit must report as `manual` rather than pretend to pass.

const Hardening = preload("res://src/features/mods/mod_hardening.gd")
const SafeMode = preload("res://src/features/mods/mod_safe_mode.gd")
const Shell = preload("res://src/features/mods/shell/shell_service.gd")
const Snapshot = preload("res://src/features/mods/shell/shell_snapshot.gd")
const Ui = preload("res://src/features/mods/ui/mod_ui_registry.gd")
const SettingsPanel = preload("res://src/features/mods/ui/mod_settings_panel.gd")
const ManagerScript = preload("res://src/features/mods/mod_manager.gd")
const RegistryScript = preload("res://src/platform/command_registry.gd")
const KeybindingScript = preload("res://src/platform/keybinding_service.gd")
const TrustScript = preload("res://src/platform/trust_service.gd")

const MOD := "griddycode.hardening_test"

var _panels: Dictionary = {}
var _layers: Array = []
var _insets: Array = []
var _markers: Array = []
var _world: Array = []
var _world_visible := true
var _host: Node = null


class FakePanel:
	extends Control
	pass


func _write_file(path: String, text: String) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(text)
	file.close()
	return true


func _remove_tree(path: String) -> void:
	if path.is_empty() or !DirAccess.dir_exists_absolute(path):
		return
	for name in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(name))
	for name in DirAccess.get_directories_at(path):
		var child := path.path_join(name)
		_remove_tree(child)
		DirAccess.remove_absolute(child)
	DirAccess.remove_absolute(path)


func _statuses(report: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	var checks: Array = report.get("checks", []) if report.get("checks") is Array else []
	for raw in checks:
		if raw is Dictionary:
			out[str((raw as Dictionary).get("id", ""))] = str((raw as Dictionary).get("status", ""))
	return out


func _healthy_runtime() -> Dictionary:
	return {
		"started": true,
		"startup_usec": 1200,
		"deferred": false,
		"preview_build": false,
		"developer_mode": false,
		"safe_mode": false,
		"session_disabled": false,
		"states": [],
		"installed": [],
		"scan_errors": [],
		"failures": [],
		"memory_bytes": 0,
		"memory_limit_bytes": 0,
		"budget_exceeded": 0,
		"hard_overruns": 0,
		"tasks": 0,
		"ui_audit": {
			"ok": true,
			"widgets": 1,
			"interactive": 1,
			"focusable": 1,
			"issues": [],
			"detail": "1 widget(s), 1 interactive, 1 focusable; 0 issue(s).",
		},
		"panic_drill": {
			"ok": true,
			"cycles": 50,
			"detail": "50 restore/panic cycles completed.",
		},
		"release_review": {
			"ok": true,
			"detail": "Desktop and consent evidence recorded by the release owner.",
		},
	}


func test_platform_matrix_is_explicit() -> void:
	var matrix: Dictionary = Hardening.PLATFORM_MATRIX
	assert_eq(matrix.size(), 6, "six platforms are classified")
	for name in ["Windows", "Linux", "macOS", "Android", "iOS", "Web"]:
		check(matrix.has(name), "the matrix classifies %s" % name)
		if matrix.has(name):
			var entry: Dictionary = matrix[name]
			check(str(entry.get("status", "")) in ["supported", "preview", "unsupported"], "%s has a status" % name)
			check(!str(entry.get("label", "")).is_empty(), "%s has a label" % name)
			check(!str(entry.get("note", "")).is_empty(), "%s has a note" % name)
	assert_eq(str(((matrix["Windows"] as Dictionary).get("status", ""))), "supported", "Windows is supported")
	assert_eq(str(((matrix["Linux"] as Dictionary).get("status", ""))), "preview", "Linux is preview")
	assert_eq(str(((matrix["macOS"] as Dictionary).get("status", ""))), "preview", "macOS is preview")
	for name in ["Android", "iOS", "Web"]:
		assert_eq(str(((matrix[name] as Dictionary).get("status", ""))), "unsupported", "%s is unsupported" % name)

	var hardening = Hardening.new()
	var current: Dictionary = hardening.platform()
	assert_eq(str(current.get("name", "")), str(OS.get_name()), "the running platform is reported")
	check(!str(current.get("status", "")).is_empty(), "the running platform has a status")
	check(!str(current.get("label", "")).is_empty(), "the running platform has a label")
	check(str(current.get("status", "")) in ["supported", "preview", "unsupported"], "the status is from the matrix")
	check(typeof(current.get("headless", null)) == TYPE_BOOL, "headless detection is a bool")
	check(!str(current.get("godot", "")).is_empty(), "the engine version is reported")


func test_channels_do_not_mislabel_builds() -> void:
	var hardening = Hardening.new()
	var public: Dictionary = hardening.channel(false, false)
	var developer: Dictionary = hardening.channel(false, true)
	var preview: Dictionary = hardening.channel(true, true)
	assert_eq(str(public.get("id", "")), "public", "a normal build is public")
	assert_eq(str(public.get("label", "")), "Public 1.0", "the public label")
	assert_eq(str(developer.get("id", "")), "developer", "developer mode is labelled")
	assert_eq(str(preview.get("id", "")), "preview", "a preview build wins over developer mode")
	assert_eq(str(preview.get("label", "")), "Developer Preview", "the preview label")
	for channel in [public, developer, preview]:
		check(!str((channel as Dictionary).get("note", "")).is_empty(), "each channel explains itself")


func test_legacy_inventory_lists_language_and_theme_files() -> void:
	var root := ProjectSettings.globalize_path("user://phase7_legacy_%d" % Time.get_ticks_usec())
	var langs := root.path_join("langs")
	var themes := root.path_join("themes")
	DirAccess.make_dir_recursive_absolute(langs)
	DirAccess.make_dir_recursive_absolute(themes)
	check(_write_file(langs.path_join("alpha.lua"), "return { name = 'Alpha' }\n"), "legacy language fixture")
	check(_write_file(langs.path_join("beta.lua"), "return { name = 'Beta' }\n"), "second legacy language fixture")
	check(_write_file(themes.path_join("night.lua"), "return { bg = '#000000' }\n"), "legacy theme fixture")
	check(_write_file(themes.path_join("notes.txt"), "not content\n"), "non-lua fixture")

	var hardening = Hardening.new()
	hardening.legacy_roots = [
		{"kind": "language", "label": "Language plugin", "root": langs, "source": "user"},
		{"kind": "theme", "label": "Theme", "root": themes, "source": "user"},
		{"kind": "language", "label": "Missing", "root": root.path_join("missing"), "source": "user"},
	]
	var inventory: Dictionary = hardening.legacy_inventory()
	assert_eq(int(inventory.get("count", -1)), 3, "three legacy Lua files are found")
	var entries: Array = inventory.get("entries", [])
	assert_eq(entries.size(), 3, "the entries array matches the count")
	assert_eq(int(inventory.get("roots", 0)), 3, "all configured roots are counted")
	for raw in entries:
		var entry: Dictionary = raw
		check(!str(entry.get("id", "")).is_empty(), "a legacy entry has an id")
		check(!str(entry.get("path", "")).is_empty(), "a legacy entry has a path")
		check(int(entry.get("bytes", 0)) > 0, "a legacy entry reports its size")
		check(str(entry.get("kind", "")) in ["language", "theme"], "a legacy entry has a kind")
	if entries.size() == 3:
		assert_eq(str((entries[0] as Dictionary).get("kind", "")), "language", "languages sort before themes")
		assert_eq(str((entries[0] as Dictionary).get("id", "")), "alpha", "entries sort by id")
		assert_eq(str((entries[2] as Dictionary).get("id", "")), "night", "the theme is listed")
	check(str(inventory.get("note", "")).to_lower().contains("not a managed mod"), "legacy content is labelled honestly")
	_remove_tree(root)


func test_audit_passes_when_automated_evidence_is_clean() -> void:
	var hardening = Hardening.new()
	hardening.session_path = ProjectSettings.globalize_path("user://phase7_no_session_%d.json" % Time.get_ticks_usec())
	var report: Dictionary = hardening.audit(_healthy_runtime())
	var statuses := _statuses(report)
	var expected_platform := "pass" if OS.get_name() == "Windows" else "warn"
	assert_eq(str(statuses.get("platform", "")), expected_platform, "the platform policy is applied")
	assert_eq(str(statuses.get("performance", "")), "pass", "startup budget")
	assert_eq(str(statuses.get("memory", "")), "pass", "memory budget")
	assert_eq(str(statuses.get("mod_health", "")), "pass", "mod health")
	assert_eq(str(statuses.get("security", "")), "pass", "package health")
	assert_eq(str(statuses.get("accessibility", "")), "pass", "accessibility")
	assert_eq(str(statuses.get("restore_panic", "")), "pass", "panic drill")
	assert_eq(str(statuses.get("migration", "")), "pass", "legacy inventory")
	assert_eq(str(statuses.get("safe_mode", "")), "pass", "safe mode")
	assert_eq(str(statuses.get("support_docs", "")), "pass", "support docs")
	assert_eq(str(statuses.get("release_review", "")), "pass", "recorded human review")
	var counts: Dictionary = report.get("counts", {})
	assert_eq(int(counts.get("fail", -1)), 0, "no failures")
	assert_eq(int(counts.get("manual", -1)), 0, "no outstanding manual checks")
	check(bool(report.get("automated_ready", false)), "automated evidence is ready")
	assert_eq(bool(report.get("release_ready", false)), expected_platform == "pass", "release readiness follows the platform warning")
	var gate: Dictionary = hardening.release_gate(_healthy_runtime())
	assert_eq(str(gate.get("gate", "")), "H", "the gate is named")
	assert_eq(bool(gate.get("ready", true)), expected_platform == "pass", "the gate mirrors the report")

	var deferred := _healthy_runtime()
	deferred["deferred"] = true
	deferred["startup_usec"] = 600000
	var deferred_report: Dictionary = hardening.audit(deferred)
	assert_eq(str(_statuses(deferred_report).get("performance", "")), "warn", "a deferred activation warns instead of failing the budget")


func test_audit_reports_failures_and_keeps_the_gate_open() -> void:
	var hardening = Hardening.new()
	hardening.session_path = ProjectSettings.globalize_path("user://phase7_no_session_%d.json" % Time.get_ticks_usec())
	var runtime := _healthy_runtime()
	runtime["startup_usec"] = 600000
	runtime["memory_bytes"] = 97 * 1024 * 1024
	runtime["states"] = [{"id": "griddycode.bad", "status": "failed"}]
	runtime["failures"] = [{"mod": "griddycode.bad", "code": "runtime.error"}]
	runtime["ui_audit"] = {
		"ok": false,
		"widgets": 1,
		"interactive": 1,
		"focusable": 0,
		"issues": [{"id": "bad.button", "problem": "not keyboard focusable"}],
		"detail": "1 widget(s), 1 interactive, 0 focusable; 1 issue(s).",
	}
	runtime["panic_drill"] = {"ok": false, "cycles": 2, "detail": "A panel leaked after panic."}
	runtime["safe_mode"] = true
	runtime.erase("release_review")
	var report: Dictionary = hardening.audit(runtime)
	var statuses := _statuses(report)
	assert_eq(str(statuses.get("performance", "")), "fail", "an over-budget startup fails")
	assert_eq(str(statuses.get("memory", "")), "fail", "an over-budget Lua state fails")
	assert_eq(str(statuses.get("mod_health", "")), "fail", "a failed mod fails health")
	assert_eq(str(statuses.get("security", "")), "fail", "a recorded failure fails package health")
	assert_eq(str(statuses.get("accessibility", "")), "fail", "an accessibility issue fails")
	assert_eq(str(statuses.get("restore_panic", "")), "fail", "a failed drill fails")
	assert_eq(str(statuses.get("safe_mode", "")), "warn", "safe mode is a warning")
	assert_eq(str(statuses.get("release_review", "")), "manual", "an unrecorded review stays manual")
	var counts: Dictionary = report.get("counts", {})
	check(int(counts.get("fail", 0)) >= 6, "the failed checks are counted")
	assert_false(bool(report.get("release_ready", true)), "a failed audit cannot be release-ready")
	var gate: Dictionary = hardening.release_gate(runtime)
	assert_false(bool(gate.get("ready", true)), "the gate stays closed")
	check((gate.get("open", []) as Array).size() >= 7, "the open items are reported")


func test_audit_reports_unmeasurable_gates_as_manual() -> void:
	var hardening = Hardening.new()
	hardening.session_path = ProjectSettings.globalize_path("user://phase7_no_session_%d.json" % Time.get_ticks_usec())
	var report: Dictionary = hardening.audit({})
	var statuses := _statuses(report)
	assert_eq(str(statuses.get("accessibility", "")), "manual", "no mounted UI means a manual accessibility pass")
	assert_eq(str(statuses.get("restore_panic", "")), "manual", "no drill means a manual restore pass")
	assert_eq(str(statuses.get("release_review", "")), "manual", "human review is always explicit")
	assert_false(bool(report.get("automated_ready", true)), "outstanding manual checks block automated readiness")
	check((report.get("manual_checks", []) as Array).size() >= 3, "the manual items are listed")


func test_accessibility_audit_accepts_and_rejects_widgets() -> void:
	var ui = Ui.new()
	Engine.get_main_loop().root.add_child(ui)
	if ui._right_column == null:
		ui._ready()
	var mounted: Dictionary = ui.mount(MOD, "right", {
		"type": "panel",
		"id": "dock",
		"title": "Accessibility",
		"children": [
			{"type": "button", "id": "run", "text": "Run"},
			{"type": "label", "id": "caption", "text": "Ready"},
		],
	})
	check(bool(mounted.get("ok", false)), "the audit fixture mounts")
	var clean: Dictionary = ui.accessibility_audit()
	check(bool(clean.get("ok", false)), "a labelled keyboard widget passes: %s" % str(clean.get("issues", [])))
	check(int(clean.get("interactive", 0)) >= 1, "the button is interactive")
	assert_eq(int(clean.get("interactive", 0)), int(clean.get("focusable", -1)), "every interactive widget is focusable")

	var node = ui._node_for(MOD, MOD + ".run")
	check(node is Button, "the button is indexed")
	if node is Button:
		var button: Button = node
		button.text = ""
		button.tooltip_text = ""
		button.focus_mode = Control.FOCUS_NONE
	var broken: Dictionary = ui.accessibility_audit()
	assert_false(bool(broken.get("ok", true)), "an unlabelled, unfocusable button fails")
	check((broken.get("issues", []) as Array).size() >= 2, "both problems are reported")
	var issues: Array = broken.get("issues", [])
	if !issues.is_empty():
		assert_eq(str((issues[0] as Dictionary).get("id", "")), MOD + ".run", "the issue names the widget")
	ui.free()


func _build_panels() -> Dictionary:
	_panels = {}
	_host = Node.new()
	for name in ["TopBar", "Tabs", "Explorer"]:
		var panel := FakePanel.new()
		panel.name = name
		panel.offset_left = 4.0
		panel.offset_top = 4.0
		panel.offset_right = 120.0
		panel.offset_bottom = 40.0
		_host.add_child(panel)
		_panels[name.to_lower()] = panel
	return _panels


func _service():
	_build_panels()
	_layers = []
	_insets = []
	_markers = []
	_world = []
	_world_visible = true
	var service = Shell.new()
	service.setup({
		"panels": Callable(self, "_panel_map"),
		"add_layer": Callable(self, "_add_layer"),
		"remove_layer": Callable(self, "_remove_layer"),
		"apply_insets": Callable(self, "_apply_insets"),
		"set_world_visible": Callable(self, "_set_world"),
		"ui": null,
		"mod_name": Callable(self, "_mod_name"),
		"set_shell_marker": Callable(self, "_marker"),
		"viewport_size": Callable(self, "_viewport"),
	})
	return service


func _panel_map() -> Dictionary:
	return _panels


func _add_layer(layer) -> void:
	_layers.append(layer)


func _remove_layer(layer) -> void:
	_layers.erase(layer)


func _apply_insets(values: Dictionary) -> void:
	_insets.append(values.duplicate(true))


func _set_world(visible: bool) -> Variant:
	var previous := _world_visible
	_world_visible = bool(visible)
	_world.append(bool(visible))
	return previous


func _marker(active: bool) -> void:
	_markers.append(bool(active))


func _mod_name(_id: String) -> String:
	return "Hardening Test"


func _viewport() -> Vector2:
	return Vector2(1280, 720)


func _layout() -> Dictionary:
	return {
		"type": "hbox",
		"children": [
			{"type": "panel", "id": "nav", "width": 280, "children": [
				{"type": "heading", "id": "title", "text": "Lessons"},
			]},
			{"type": "vbox", "id": "main", "grow": 1, "children": [
				{"type": "editor", "id": "code", "grow": 1},
			]},
			{"type": "panel", "id": "coach", "width": 320, "children": [
				{"type": "label", "id": "body", "text": "Type."},
			]},
		],
	}


func test_fifty_takeover_panic_cycles_restore_exactly() -> void:
	var service = _service()
	var original: Dictionary = Snapshot.capture(_panels, Vector2(1280, 720))
	var failures := 0
	var reasons: Array = []
	var cycles := 0
	for index in range(50):
		var taken: Dictionary = service.takeover(MOD, {"layout": _layout()})
		if !bool(taken.get("ok", false)):
			failures += 1
			reasons.append("takeover %s" % str(taken))
			break
		service.set_content_insets(MOD, {
			"left": 20 + index,
			"top": 0,
			"right": 40 + index,
			"bottom": 10,
		})
		if (_panels["topbar"] as Control).visible:
			failures += 1
			reasons.append("topbar visible after takeover at %d" % index)
		var panic: Dictionary = service.panic()
		if !bool(panic.get("had_shell", false)):
			failures += 1
			reasons.append("panic had no shell at %d" % index)
		if !(_panels["topbar"] as Control).visible:
			failures += 1
			reasons.append("topbar hidden after panic at %d" % index)
		var afterwards: Dictionary = Snapshot.capture(_panels, Vector2(1280, 720))
		if !Snapshot.equals(original, afterwards):
			failures += 1
			reasons.append("snapshot mismatch at %d" % index)
		if _layers.size() != 0:
			failures += 1
			reasons.append("layer leak at %d" % index)
		cycles += 1
	if !reasons.is_empty():
		print("PHASE7_FUZZ_REASONS ", reasons.slice(0, mini(5, reasons.size())))
	assert_eq(failures, 0, "all 50 takeover/inset/panic cycles restore exactly")
	assert_eq(cycles, 50, "all 50 cycles ran")
	assert_eq(_layers.size(), 0, "no mod layer leaks")
	assert_eq(_markers.size(), 100, "each takeover and panic updates the crash marker")
	var drill := {
		"ok": failures == 0 and cycles == 50,
		"cycles": cycles,
		"detail": "%d restore/panic cycles completed." % cycles,
	}
	var hardening = Hardening.new()
	hardening.session_path = ProjectSettings.globalize_path("user://phase7_no_session_%d.json" % Time.get_ticks_usec())
	var runtime := _healthy_runtime()
	runtime["panic_drill"] = drill
	var report: Dictionary = hardening.audit(runtime)
	assert_eq(str(_statuses(report).get("restore_panic", "")), "pass", "the drill closes the restore item")
	if _host != null and is_instance_valid(_host):
		_host.free()
	_host = null


func test_crash_loop_drill_disables_the_previous_mod_set() -> void:
	var path := ProjectSettings.globalize_path("user://phase7_session_%d.json" % Time.get_ticks_usec())
	DirAccess.remove_absolute(path)
	var guard = SafeMode.new(path)
	var clean: Dictionary = guard.evaluate(PackedStringArray())
	assert_false(bool(clean.get("safe_mode", true)), "a fresh marker is not safe mode")
	assert_eq(int(clean.get("streak", -1)), 0, "a fresh marker has no streak")

	check(bool(guard.begin(["griddycode.test"]).get("ok", false)), "the first session marker is written")
	var first: Dictionary = guard.evaluate(PackedStringArray())
	assert_eq(int(first.get("streak", 0)), 1, "one short unclean session is counted")
	check((first.get("disable", []) as Array).is_empty(), "one crash does not disable mods")

	check(bool(guard.begin(["griddycode.test"]).get("ok", false)), "the second session marker is written")
	var second: Dictionary = guard.evaluate(PackedStringArray())
	assert_eq(int(second.get("streak", -1)), 0, "the streak resets after the disable")
	assert_eq((second.get("disable", []) as Array), ["griddycode.test"], "the previous mod set is disabled")
	check(str(second.get("reason", "")).to_lower().contains("disabled"), "the reason explains the disable")

	var forced: Dictionary = guard.evaluate(PackedStringArray(["--safe-mode"]))
	assert_true(bool(forced.get("safe_mode", false)), "the command line can force safe mode")
	check(bool(guard.mark_clean().get("ok", false)), "a clean exit is recorded")
	var cleared: Dictionary = guard.evaluate(PackedStringArray())
	assert_eq(int(cleared.get("streak", -1)), 0, "a clean exit clears the streak")
	assert_true((cleared.get("disable", []) as Array).is_empty(), "a clean exit disables nothing")
	DirAccess.remove_absolute(path)


func _text_of(node: Node) -> String:
	var text := ""
	if node is Label:
		text += (node as Label).text + "\n"
	for child in node.get_children():
		text += _text_of(child)
	return text


func test_manager_exposes_the_hardening_bridge() -> void:
	var root := "user://phase7_manager_%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(root))
	var commands = RegistryScript.new()
	var keybindings = KeybindingScript.new()
	keybindings.setup(commands)
	var manager = ManagerScript.new()
	manager.setup({
		"mods_root": "res://tests/fixtures/mods/minimal",
		"data_root": root + "/data",
		"registry_path": root + "/mod_registry.json",
		"permissions_path": root + "/mod_permissions.json",
		"session_path": root + "/mod_session.json",
		"command_registry": commands,
		"keybinding_service": keybindings,
		"trust_service": TrustScript.new(),
		"editor_version": "1.4.0",
		"developer_mode": true,
	})
	var started: Dictionary = manager.start()
	check(bool(started.get("ok", false)), "the manager starts for the hardening bridge")
	var status: Dictionary = manager.status_report()
	var channel: Dictionary = status.get("channel", {})
	var platform: Dictionary = status.get("platform", {})
	assert_eq(str(channel.get("id", "")), "developer", "the developer channel is reported")
	assert_eq(str(platform.get("name", "")), str(OS.get_name()), "the platform is reported")
	OS.delay_msec(550)
	var health: Dictionary = manager.health_report()
	assert_eq(int(health.get("phase", 0)), 7, "the manager returns the Phase 7 audit")
	check((health.get("checks", []) as Array).size() >= 10, "the audit includes the Gate H checks")
	check(health.get("legacy", {}) is Dictionary, "the audit embeds the legacy inventory")
	var runtime: Dictionary = health.get("runtime", {})
	check(int(runtime.get("startup_usec", -1)) < Hardening.STARTUP_BUDGET_USEC, "the audit uses startup duration, not session uptime")
	assert_eq(str(_statuses(health).get("performance", "")), "pass", "a long session does not fail the startup budget")
	var legacy: Dictionary = manager.legacy_content()
	check(bool(legacy.get("ok", false)), "the legacy inventory is callable from the manager")
	check(legacy.has("entries"), "the legacy inventory has entries")
	var refreshed: Dictionary = manager.refresh_discovery()
	check(bool(refreshed.get("ok", false)), "the Mods page can rescan discovery in place")
	assert_eq(manager.installed().size(), 1, "the rescan keeps the installed set")
	manager.stop()
	_remove_tree(ProjectSettings.globalize_path(root))


func test_mods_page_renders_health_and_legacy_cards() -> void:
	var hardening = Hardening.new()
	hardening.session_path = ProjectSettings.globalize_path("user://phase7_no_session_%d.json" % Time.get_ticks_usec())
	var report: Dictionary = hardening.audit(_healthy_runtime())
	var panel = SettingsPanel.new()
	Engine.get_main_loop().root.add_child(panel)
	var health_card: Control = panel._health_card(report)
	check(health_card is Control, "the health card builds")
	var health_text := _text_of(health_card)
	check(health_text.contains("Platform health"), "the health card has its heading")
	check(health_text.contains("Gate H"), "the health card names the gate")
	check(health_text.contains("PASS"), "the health card shows passing checks")

	var legacy_card: Control = panel._legacy_card({
		"note": "Legacy content is loaded by the editor, not the mod manager.",
		"entries": [{"label": "Language plugin", "id": "alpha", "path": "user://langs/alpha.lua"}],
		"count": 1,
	})
	check(legacy_card is Control, "the legacy card builds")
	var legacy_text := _text_of(legacy_card)
	check(legacy_text.contains("Legacy content"), "the legacy card has its heading")
	check(legacy_text.contains("alpha"), "the legacy card lists the file")
	panel.free()


func test_support_documents_are_present_and_specific() -> void:
	var paths := [Hardening.README_DOC, Hardening.SUPPORT_DOC, Hardening.NOTES_DOC]
	for path in paths:
		check(FileAccess.file_exists(path), "%s exists" % path.get_file())
		var text := FileAccess.get_file_as_string(path)
		check(text.length() > 1000, "%s has real content" % path.get_file())
	var readme := FileAccess.get_file_as_string(Hardening.README_DOC)
	var support := FileAccess.get_file_as_string(Hardening.SUPPORT_DOC)
	var notes := FileAccess.get_file_as_string(Hardening.NOTES_DOC)
	check(readme.contains("Gate H"), "the phase record documents Gate H")
	check(readme.to_lower().contains("still open"), "the phase record lists what is still open")
	check(support.to_lower().contains("safe mode"), "the support policy documents safe mode")
	check(support.contains("Ctrl+Alt+Shift+Esc"), "the support policy documents the panic exit")
	check(support.to_lower().contains("known limitations"), "the support policy lists limitations")
	check(notes.contains("1.0.0"), "the release notes carry the version")
	check(notes.contains("API 1.0"), "the release notes state the API compatibility")
