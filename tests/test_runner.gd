extends SceneTree

## Minimal headless test runner (no third-party addon required):
##
##   godot --headless --path . --script res://tests/test_runner.gd
##
## Exit code 0 = all checks passed, 1 = at least one failure.

const SUITES := [
	# Base.
	preload("res://tests/unit/base/test_path_utils.gd"),
	preload("res://tests/unit/base/test_fs.gd"),
	preload("res://tests/unit/base/test_fuzzy_match.gd"),
	preload("res://tests/unit/base/test_version_utils.gd"),
	# Platform.
	preload("res://tests/unit/platform/test_ignore_rules.gd"),
	preload("res://tests/unit/platform/test_settings_service.gd"),
	preload("res://tests/unit/platform/test_workspace_service.gd"),
	preload("res://tests/unit/platform/test_workspace_trust.gd"),
	preload("res://tests/unit/platform/test_search_text.gd"),
	preload("res://tests/unit/platform/test_search_service.gd"),
	preload("res://tests/unit/platform/test_background_workers.gd"),
	preload("res://tests/unit/platform/test_accessibility.gd"),
	preload("res://tests/unit/platform/test_completion_scan.gd"),
	preload("res://tests/unit/platform/test_localization.gd"),
	preload("res://tests/unit/platform/test_session_service.gd"),
	preload("res://tests/unit/platform/test_key_chord.gd"),
	preload("res://tests/unit/platform/test_command_registry.gd"),
	preload("res://tests/unit/platform/test_keybinding_service.gd"),
	preload("res://tests/unit/platform/test_language_service.gd"),
	preload("res://tests/unit/platform/test_language_plugins.gd"),
	# Editor.
	preload("res://tests/unit/editor/test_editor_document.gd"),
	preload("res://tests/unit/editor/test_document_manager.gd"),
	preload("res://tests/unit/editor/test_scroll_settings.gd"),
	preload("res://tests/unit/editor/test_cursor_effect.gd"),
	# Workbench.
	preload("res://tests/unit/workbench/test_icon_fonts.gd"),
	# Run.
	preload("res://tests/unit/features/run/test_run_manager.gd"),
	preload("res://tests/unit/features/run/test_run_config.gd"),
	preload("res://tests/unit/features/run/test_run_service.gd"),
	preload("res://tests/unit/features/run/test_run_capture.gd"),
	preload("res://tests/unit/features/run/test_runtime_catalog.gd"),
	preload("res://tests/unit/features/run/test_error_explainer.gd"),
	preload("res://tests/unit/features/run/test_guesslang_service.gd"),
	preload("res://tests/unit/features/run/test_output_links.gd"),
	preload("res://tests/unit/features/run/test_error_feedback.gd"),
	# Language servers.
	preload("res://tests/unit/features/lsp/test_lsp_protocol.gd"),
	preload("res://tests/unit/features/lsp/test_lsp_text.gd"),
	preload("res://tests/unit/features/lsp/test_lsp_config.gd"),
	preload("res://tests/unit/features/lsp/test_lsp_client.gd"),
	preload("res://tests/unit/features/lsp/test_lsp_manager.gd"),
	# Git.
	preload("res://tests/unit/features/git/test_git_status.gd"),
	preload("res://tests/unit/features/git/test_git_diff.gd"),
	# Debugger.
	preload("res://tests/unit/features/debug/test_dap_protocol.gd"),
	preload("res://tests/unit/features/debug/test_dap_config.gd"),
	preload("res://tests/unit/features/debug/test_dap_manager.gd"),
	# Mod platform.
	preload("res://tests/unit/features/mods/test_semver_range.gd"),
	preload("res://tests/unit/features/mods/test_mod_manifest.gd"),
	preload("res://tests/unit/features/mods/test_mod_resolver.gd"),
	preload("res://tests/unit/features/mods/test_mod_permissions.gd"),
	preload("res://tests/unit/features/mods/test_event_bus.gd"),
	preload("res://tests/unit/features/mods/test_mod_storage.gd"),
	preload("res://tests/unit/features/mods/test_mod_settings.gd"),
	preload("res://tests/unit/features/mods/test_mod_host.gd"),
	preload("res://tests/unit/features/mods/test_mod_manager.gd"),
	preload("res://tests/unit/features/mods/test_mod_api_golden.gd"),
	preload("res://tests/unit/features/mods/test_mod_api_permissions.gd"),
	preload("res://tests/unit/features/mods/test_mod_files.gd"),
	preload("res://tests/unit/features/mods/test_mod_documents.gd"),
	preload("res://tests/unit/features/mods/test_mod_partial_ui.gd"),
	preload("res://tests/unit/features/mods/test_mod_api_samples.gd"),
	preload("res://tests/unit/features/mods/test_mod_api_shell_learning.gd"),
	preload("res://tests/unit/features/mods/test_platform_tour_samples.gd"),
	preload("res://tests/unit/features/mods/test_python_journey_samples.gd"),
	preload("res://tests/unit/features/mods/test_python_journey_runtime.gd"),
	preload("res://tests/unit/features/mods/test_mod_dev_watcher.gd"),
	preload("res://tests/unit/features/mods/test_mod_api_contract.gd"),
	preload("res://tests/unit/features/mods/test_mod_dev_mode.gd"),
	preload("res://tests/unit/features/mods/test_mod_preview_samples.gd"),
	preload("res://tests/unit/features/mods/test_platform_tour_runtime.gd"),
	preload("res://tests/unit/features/mods/test_mod_ed25519.gd"),
	preload("res://tests/unit/features/mods/test_mod_package.gd"),
	preload("res://tests/unit/features/mods/test_mod_installer.gd"),
	preload("res://tests/unit/features/mods/test_mod_import.gd"),
	preload("res://tests/unit/features/mods/test_mod_import_ui.gd"),
	preload("res://tests/unit/features/mods/test_mod_hardening.gd"),
	preload("res://tests/unit/features/mods/test_cpp_journey.gd"),
	preload("res://tests/unit/features/mods/test_shell_snapshot.gd"),
	preload("res://tests/unit/features/mods/test_shell_service.gd"),
	# Learning.
	preload("res://tests/unit/features/learning/test_guide_matcher.gd"),
	preload("res://tests/unit/features/learning/test_guide_filter.gd"),
	preload("res://tests/unit/features/learning/test_guide_service.gd"),
	preload("res://tests/unit/features/learning/test_guide_layout.gd"),
	preload("res://tests/unit/features/learning/test_exercise_validation.gd"),
	preload("res://tests/unit/features/learning/test_exercise_service.gd"),
	preload("res://tests/unit/features/learning/test_onboarding_service.gd"),
	preload("res://tests/unit/features/learning/test_template_service.gd"),
	preload("res://tests/unit/features/learning/test_welcome_service.gd"),
	preload("res://tests/unit/features/learning/test_history_service.gd"),
	preload("res://tests/unit/features/learning/test_course_service.gd"),
]


func _initialize() -> void:
	var total_checks := 0
	var total_failures := 0
	var failed_suites: Array[String] = []

	for suite_script in SUITES:
		# A suite that fails to compile would otherwise crash the loop and leave
		# the process running forever. Report it as a failed suite instead.
		if suite_script == null or !(suite_script is GDScript) or !(suite_script as GDScript).can_instantiate():
			var broken_name := str(suite_script.resource_path.get_file()) if suite_script != null else "<missing>"
			print("FAIL  %-28s could not be instantiated" % broken_name)
			failed_suites.append(broken_name)
			total_failures += 1
			continue

		var suite: TestCase = suite_script.new()
		var methods: Array[String] = []

		for method in suite.get_method_list():
			var method_name := str(method.get("name", ""))
			if method_name.begins_with("test_"):
				methods.append(method_name)

		methods.sort()

		for method_name in methods:
			suite.begin(method_name)
			suite.before_each()
			suite.call(method_name)
			suite.after_each()

		# A suite that failed to instantiate or ran no assertions must never
		# masquerade as a pass.
		if suite.checks == 0:
			suite.failures.append("no checks were executed")

		total_checks += suite.checks
		total_failures += suite.failures.size()

		var suite_name := str(suite_script.resource_path.get_file())
		if suite.failures.is_empty():
			print("PASS  %-28s %d checks" % [suite_name, suite.checks])
		else:
			failed_suites.append(suite_name)
			print("FAIL  %-28s %d/%d checks failed" % [suite_name, suite.failures.size(), suite.checks])
			for failure in suite.failures:
				print("      - " + failure)

	print("")
	if total_failures == 0:
		print("All tests passed: %d checks across %d suites." % [total_checks, SUITES.size()])
		quit(0)
	else:
		print("%d of %d checks failed in: %s" % [
			total_failures,
			total_checks,
			", ".join(failed_suites),
		])
		quit(1)
