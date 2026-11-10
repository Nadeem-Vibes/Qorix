extends SceneTree

## Phase 0 probe runner.
##
##   godot --headless --path . --script res://tools/probes/lua-runtime/run_probe.gd
##   godot --headless --path . --script res://tools/probes/lua-runtime/run_probe.gd -- --only=E3,E4
##
## Exit code 0 = no selected probe failed (partial results are reported but do
## not fail the run), 1 = a probe failed, 2 = bad arguments. Results are written
## to tools/probes/lua-runtime/out/probe-results.json.

const OUT_DIR := "res://tools/probes/lua-runtime/out"
const PROBES := {
	"E2": preload("res://tools/probes/lua-runtime/probes/e2_runtime.gd"),
	"E3": preload("res://tools/probes/lua-runtime/probes/e3_abort_matrix.gd"),
	"E4": preload("res://tools/probes/lua-runtime/probes/e4_escape_hatches.gd"),
	"E5": preload("res://tools/probes/lua-runtime/probes/e5_lifecycle.gd"),
	"E6": preload("res://tools/probes/lua-runtime/probes/e6_marshalling.gd"),
	"E8": preload("res://tools/probes/lua-runtime/probes/e8_unicode.gd"),
}


func _initialize() -> void:
	var selected := _selected_probes()
	if selected.is_empty():
		printerr("No probes selected. Known: " + ", ".join(PROBES.keys()))
		quit(2)
		return

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var report := {
		"schema": 1,
		"generated_at": Time.get_datetime_string_from_system(true),
		"godot": Engine.get_version_info(),
		"os": OS.get_name(),
		"os_version": OS.get_version(),
		"processor": OS.get_processor_name(),
		"executable": OS.get_executable_path(),
		"probes": [],
	}
	var failed := false
	var partial := 0

	for probe_id in selected:
		var script: GDScript = PROBES[probe_id]
		if !script.can_instantiate():
			printerr("Probe %s cannot be instantiated" % probe_id)
			failed = true
			continue

		var probe = script.new()
		print("RUN  %s" % probe_id)
		var started := Time.get_ticks_msec()
		var result: Dictionary = probe.run({
			"out_dir": ProjectSettings.globalize_path(OUT_DIR),
			"report": report,
		})
		var elapsed := Time.get_ticks_msec() - started
		result["duration_ms"] = elapsed
		report["probes"].append(result)

		var status := str(result.get("status", "fail"))
		print("%s  %s  %dms" % [status.to_upper(), probe_id, elapsed])
		for check in result.get("checks", []):
			var mark := "ok  " if bool(check.get("ok", false)) else "FAIL"
			print("  %s %s" % [mark, check.get("detail", check.get("name", ""))])
		for limitation in result.get("limitations", []):
			print("  NOTE " + str(limitation))

		if status == "fail":
			failed = true
		elif status == "partial":
			partial += 1

	var json_path := OUT_DIR + "/probe-results.json"
	var file := FileAccess.open(json_path, FileAccess.WRITE)
	if file == null:
		printerr("Could not write " + json_path)
		quit(1)
		return
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	print("\nWrote " + ProjectSettings.globalize_path(json_path))
	print("Summary: %d selected, %d partial" % [selected.size(), partial])

	quit(1 if failed else 0)


func _selected_probes() -> Array:
	var only := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--only="):
			only = arg.substr("--only=".length())

	if only.is_empty():
		return PROBES.keys()

	var out: Array = []
	for id in only.split(",", false):
		var key := id.strip_edges().to_upper()
		if PROBES.has(key):
			out.append(key)
	return out
