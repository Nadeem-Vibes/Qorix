extends RefCounted

## Hardening and public-release evidence.
##
## This service does not add capabilities. It reports what the host can prove
## about the install it is running in: the supported-platform matrix, startup
## and memory budgets, per-mod failure and budget counters, safe-mode state, the
## accessibility audit of mounted mod UI, and the legacy language/theme content
## that predates the mod platform.
##
## Two Gate H items cannot be measured inside the process — a real screen-reader
## pass and a desktop restore/panic drill. They are reported as `manual` instead
## of being silently counted as passes. A release is only `ready` when no check
## fails and no manual evidence is outstanding.

const SafeMode = preload("res://src/features/mods/mod_safe_mode.gd")

const PHASE := 7
const RELEASE := "Qorix Mod Platform 1.0"
const STARTUP_BUDGET_USEC := 500000
const TOTAL_MEMORY_BUDGET := 96 * 1024 * 1024
const SUPPORT_DOC := "res://docs/mods/support.md"
const NOTES_DOC := "res://docs/mods/release-notes.md"
const README_DOC := "res://docs/archive/mod-platform/hardening.md"

## Platform policy for 1.0. Windows is the reference platform, Linux and macOS
## are preview-only for this cycle, and the remaining exports are unsupported.
const PLATFORM_MATRIX := {
	"Windows": {
		"status": "supported",
		"label": "Windows 10/11 x86_64",
		"note": "Reference platform. Desktop and headless gates run here.",
	},
	"Linux": {
		"status": "preview",
		"label": "Linux x86_64",
		"note": "Preview-only this cycle; the desktop matrix pass is pending.",
	},
	"macOS": {
		"status": "preview",
		"label": "macOS",
		"note": "Preview-only; there is no signed build or desktop pass yet.",
	},
	"Android": {
		"status": "unsupported",
		"label": "Android",
		"note": "Not a 1.0 target.",
	},
	"iOS": {
		"status": "unsupported",
		"label": "iOS",
		"note": "Not a 1.0 target.",
	},
	"Web": {
		"status": "unsupported",
		"label": "Web",
		"note": "Not a 1.0 target.",
	},
}

## User-installed content from before the mod platform. These folders are still
## loaded by the editor's existing language and theme services; the inventory is
## read-only and exists so the Mods page can label the content honestly instead
## of pretending it is a managed mod.
const LEGACY_ROOTS := [
	{"kind": "language", "label": "Language plugin", "root": "user://langs", "source": "user"},
	{"kind": "theme", "label": "Theme", "root": "user://themes", "source": "user"},
]

var session_path: String = SafeMode.DEFAULT_PATH
var startup_budget_usec: int = STARTUP_BUDGET_USEC
var memory_budget_bytes: int = TOTAL_MEMORY_BUDGET
var legacy_roots: Array = LEGACY_ROOTS.duplicate(true)


## Returns the running platform and its 1.0 support status.
func platform() -> Dictionary:
	var name := str(OS.get_name())
	var entry: Dictionary = PLATFORM_MATRIX.get(name, {
		"status": "unsupported",
		"label": name,
		"note": "This platform is not part of the 1.0 support matrix.",
	})
	var version: Dictionary = Engine.get_version_info()
	return {
		"name": name,
		"status": str(entry.get("status", "unsupported")),
		"label": str(entry.get("label", name)),
		"note": str(entry.get("note", "")),
		"godot": str(version.get("string", "")),
		"headless": str(DisplayServer.get_name()).to_lower() == "headless",
	}


## Build channel shown by the Mods page. A preview build never claims to be the
## public channel, even when the binary is otherwise release-shaped.
func channel(preview_build: bool = false, developer_mode: bool = false) -> Dictionary:
	if preview_build:
		return {
			"id": "preview",
			"label": "Developer Preview",
			"note": "Opt-in preview build. API 1.0 is frozen; distribution security is implemented.",
		}
	if developer_mode:
		return {
			"id": "developer",
			"label": "Developer build",
			"note": "Debug or --mod-dev build with hot reload and user://mods_dev scanning.",
		}
	return {
		"id": "public",
		"label": "Public 1.0",
		"note": "Stable channel. Mods require explicit consent and run in the capability sandbox.",
	}


## Lists user-installed legacy language/theme Lua files. Read-only: the existing
## loaders remain authoritative and this never moves or deletes anything.
func legacy_inventory() -> Dictionary:
	var entries: Array = []
	var unreadable: Array = []

	for spec in legacy_roots:
		if !(spec is Dictionary):
			continue
		var config: Dictionary = spec
		var root := str(config.get("root", ""))
		if root.is_empty():
			continue
		var directory := DirAccess.open(root)
		if directory == null:
			continue

		var kind := str(config.get("kind", "content"))
		var source := str(config.get("source", "user"))
		var files: Array = directory.get_files()
		files.sort()
		for raw_name in files:
			var file_name := str(raw_name)
			if !file_name.to_lower().ends_with(".lua"):
				continue
			var path := root.path_join(file_name)
			var size := _file_size(path)
			entries.append({
				"id": file_name.get_basename(),
				"kind": kind,
				"label": str(config.get("label", kind)),
				"source": source,
				"path": path,
				"bytes": size,
				"modified": int(FileAccess.get_modified_time(path)),
			})

	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var left := "%s|%s|%s" % [str(a.get("kind", "")), str(a.get("id", "")), str(a.get("path", ""))]
		var right := "%s|%s|%s" % [str(b.get("kind", "")), str(b.get("id", "")), str(b.get("path", ""))]
		return left < right
	)

	return {
		"ok": true,
		"entries": entries,
		"count": entries.size(),
		"roots": legacy_roots.size(),
		"unreadable": unreadable,
		"note": "Legacy language and theme Lua still runs through the original loaders. It is not a managed mod: no permissions, consent, sandbox or uninstall.",
	}


## Produces the Gate H audit. `runtime` is a plain snapshot built by ModManager
## so this class stays testable without a scene tree.
func audit(runtime: Dictionary = {}) -> Dictionary:
	var started := Time.get_ticks_usec()
	var platform_info := platform()
	var channel_info := channel(
		bool(runtime.get("preview_build", false)),
		bool(runtime.get("developer_mode", false)),
	)
	var legacy := legacy_inventory()
	var session := _session_status()
	var summary := _runtime_summary(runtime)

	var checks: Array = []
	checks.append(_check(
		"platform",
		"Supported platform",
		_platform_status(str(platform_info.get("status", "unsupported"))),
		"%s · %s" % [str(platform_info.get("label", "")), str(platform_info.get("note", ""))],
	))
	checks.append(_performance_check(summary))
	checks.append(_memory_check(summary))
	checks.append(_mod_health_check(summary))
	checks.append(_security_check(summary))
	checks.append(_accessibility_check(runtime.get("ui_audit", {}), summary))
	checks.append(_restore_panic_check(runtime.get("panic_drill", {}), summary))
	checks.append(_check(
		"migration",
		"Legacy content inventory",
		"pass",
		"%d legacy language/theme file(s) found; they remain usable and are listed separately." % int(legacy.get("count", 0)),
	))
	checks.append(_safe_mode_check(session, bool(runtime.get("safe_mode", false)), bool(runtime.get("session_disabled", false))))
	checks.append(_docs_check())
	checks.append(_release_review_check(runtime.get("release_review", {})))

	var counts := {"pass": 0, "warn": 0, "fail": 0, "manual": 0}
	var manual: Array = []
	for raw in checks:
		var item: Dictionary = raw
		var status := str(item.get("status", "manual"))
		if counts.has(status):
			counts[status] = int(counts[status]) + 1
		if status == "manual":
			manual.append(str(item.get("label", "")))

	var automated_ready := int(counts["fail"]) == 0 and int(counts["manual"]) == 0
	var release_ready := automated_ready and int(counts["warn"]) == 0

	return {
		"ok": true,
		"phase": PHASE,
		"release": RELEASE,
		"generated_at": int(Time.get_unix_time_from_system()),
		"elapsed_usec": int(Time.get_ticks_usec() - started),
		"channel": channel_info,
		"platform": platform_info,
		"legacy": legacy,
		"session": session,
		"runtime": summary,
		"checks": checks,
		"counts": counts,
		"automated_ready": automated_ready,
		"release_ready": release_ready,
		"manual_checks": manual,
	}


## Gate H in one call. `ready` is deliberately strict: warnings and outstanding
## manual evidence keep the gate open.
func release_gate(runtime: Dictionary = {}) -> Dictionary:
	var report := audit(runtime)
	var open: Array = []
	for raw in report.get("checks", []):
		var item: Dictionary = raw
		var status := str(item.get("status", "manual"))
		if status != "pass":
			open.append(item.duplicate(true))
	return {
		"gate": "H",
		"release": RELEASE,
		"ready": bool(report.get("release_ready", false)),
		"open": open,
		"report": report,
	}


func _runtime_summary(runtime: Dictionary) -> Dictionary:
	var states: Array = runtime.get("states", []) if runtime.get("states") is Array else []
	var installed: Array = runtime.get("installed", []) if runtime.get("installed") is Array else []
	var failures: Array = runtime.get("failures", []) if runtime.get("failures") is Array else []
	var scan_errors: Array = runtime.get("scan_errors", []) if runtime.get("scan_errors") is Array else []

	var active := 0
	var blocked := 0
	var failed := 0
	var disabled := 0
	for raw in states:
		if !(raw is Dictionary):
			continue
		match str((raw as Dictionary).get("status", "")):
			"active":
				active += 1
			"blocked":
				blocked += 1
			"failed":
				failed += 1
			"disabled":
				disabled += 1

	return {
		"started": bool(runtime.get("started", true)),
		"startup_usec": int(runtime.get("startup_usec", 0)),
		"startup_budget_usec": startup_budget_usec,
		"deferred": bool(runtime.get("deferred", false)),
		"memory_bytes": int(runtime.get("memory_bytes", 0)),
		"memory_limit_bytes": int(runtime.get("memory_limit_bytes", 0)),
		"memory_budget_bytes": memory_budget_bytes,
		"budget_exceeded": int(runtime.get("budget_exceeded", 0)),
		"hard_overruns": int(runtime.get("hard_overruns", 0)),
		"tasks": int(runtime.get("tasks", 0)),
		"installed": installed.size(),
		"states": states.size(),
		"active": active,
		"blocked": blocked,
		"failed": failed,
		"disabled": disabled,
		"failures": failures.size(),
		"scan_errors": scan_errors.size(),
		"pending_activations": int(runtime.get("pending_activations", 0)),
		"safe_mode": bool(runtime.get("safe_mode", false)),
		"session_disabled": bool(runtime.get("session_disabled", false)),
	}


func _platform_status(status: String) -> String:
	match status:
		"supported":
			return "pass"
		"preview":
			return "warn"
		_:
			return "fail"


func _performance_check(summary: Dictionary) -> Dictionary:
	if !bool(summary.get("started", false)):
		return _check("performance", "Startup and dispatch budget", "manual", "The mod platform has not started yet.")
	var elapsed := int(summary.get("startup_usec", 0))
	var budget := int(summary.get("startup_budget_usec", STARTUP_BUDGET_USEC))
	# A deferred activation already yielded to a background frame. Its duration
	# may include that wait, so report the warning before judging the budget.
	if bool(summary.get("deferred", false)):
		return _check("performance", "Startup and dispatch budget", "warn", "Activation was deferred to background frames.")
	if elapsed > budget:
		return _check(
			"performance",
			"Startup and dispatch budget",
			"fail",
			"Activation took %.1f ms; the budget is %.1f ms." % [float(elapsed) / 1000.0, float(budget) / 1000.0],
		)
	var overruns := int(summary.get("budget_exceeded", 0))
	if overruns > 0:
		return _check(
			"performance",
			"Startup and dispatch budget",
			"warn",
			"%d task(s) hit the instruction budget; the mod host lowered their budget." % overruns,
		)
	return _check(
		"performance",
		"Startup and dispatch budget",
		"pass",
		"Activation took %.1f ms of a %.1f ms budget." % [float(elapsed) / 1000.0, float(budget) / 1000.0],
	)


func _memory_check(summary: Dictionary) -> Dictionary:
	var used := int(summary.get("memory_bytes", 0))
	var limit := int(summary.get("memory_limit_bytes", 0))
	if used <= 0:
		return _check("memory", "Lua memory budget", "pass", "No active Lua state is holding memory.")
	if used > memory_budget_bytes:
		return _check(
			"memory",
			"Lua memory budget",
			"fail",
			"Active Lua states use %.1f MB; the aggregate budget is %.1f MB." % [
				_mb(used), _mb(memory_budget_bytes),
			],
		)
	var detail := "Active Lua states use %.1f MB of a %.1f MB aggregate budget." % [_mb(used), _mb(memory_budget_bytes)]
	if limit > memory_budget_bytes:
		detail += " Per-state limits total %.1f MB." % _mb(limit)
	return _check("memory", "Lua memory budget", "pass", detail)


func _mod_health_check(summary: Dictionary) -> Dictionary:
	var failed := int(summary.get("failed", 0))
	var blocked := int(summary.get("blocked", 0))
	var active := int(summary.get("active", 0))
	if failed > 0:
		return _check(
			"mod_health",
			"Mod isolation",
			"fail",
			"%d mod(s) failed. Open their log or disable them before release." % failed,
		)
	var detail := "%d active, %d blocked on consent, %d installed." % [
		active, blocked, int(summary.get("installed", 0)),
	]
	if int(summary.get("failures", 0)) > 0:
		return _check("mod_health", "Mod isolation", "warn", detail + " A recorded failure is still listed.")
	return _check("mod_health", "Mod isolation", "pass", detail)


func _security_check(summary: Dictionary) -> Dictionary:
	var scan_errors := int(summary.get("scan_errors", 0))
	var failed := int(summary.get("failed", 0))
	if failed > 0:
		return _check("security", "Package and signature health", "fail", "A failed mod may indicate an invalid package or runtime fault.")
	if scan_errors > 0:
		return _check(
			"security",
			"Package and signature health",
			"warn",
			"%d package(s) were skipped during scan; inspect the Mods log." % scan_errors,
		)
	return _check(
		"security",
		"Package and signature health",
		"pass",
		"No invalid signature, archive or scan error was reported this session.",
	)


func _accessibility_check(raw_audit: Variant, summary: Dictionary) -> Dictionary:
	if !(raw_audit is Dictionary) or (raw_audit as Dictionary).is_empty():
		return _check(
			"accessibility",
			"Mounted mod UI accessibility",
			"manual",
			"No mounted mod UI to audit; a desktop screen-reader pass is still required.",
		)
	var report: Dictionary = raw_audit
	if int(report.get("widgets", 0)) == 0:
		return _check(
			"accessibility",
			"Mounted mod UI accessibility",
			"manual",
			"No mod widgets are mounted in this session; mount a mod UI to run the mechanical audit.",
		)
	var ok := bool(report.get("ok", false))
	return _check(
		"accessibility",
		"Mounted mod UI accessibility",
		"pass" if ok else "fail",
		str(report.get("detail", "%d interactive widget(s) audited." % int(report.get("interactive", 0)))),
	)


func _restore_panic_check(raw_drill: Variant, summary: Dictionary) -> Dictionary:
	if !(raw_drill is Dictionary) or (raw_drill as Dictionary).is_empty():
		return _check(
			"restore_panic",
			"Shell restore and panic drill",
			"manual",
			"Run the desktop 50-cycle takeover/panic drill; the headless suite exercises the same code path.",
		)
	var drill: Dictionary = raw_drill
	if !bool(drill.get("ok", false)):
		return _check(
			"restore_panic",
			"Shell restore and panic drill",
			"fail",
			str(drill.get("detail", "The restore/panic drill reported a leaked panel or failed restore.")),
		)
	return _check(
		"restore_panic",
		"Shell restore and panic drill",
		"pass",
		str(drill.get("detail", "%d restore/panic cycles completed." % int(drill.get("cycles", 0)))),
	)


func _safe_mode_check(session: Dictionary, safe_mode: bool, session_disabled: bool) -> Dictionary:
	if session_disabled:
		return _check("safe_mode", "Crash-loop and safe mode", "warn", "All mods are disabled for this session.")
	if safe_mode:
		return _check("safe_mode", "Crash-loop and safe mode", "warn", "Safe mode is active for this session; no mods are loaded.")
	var streak := int(session.get("streak", 0))
	if streak > 0:
		return _check(
			"safe_mode",
			"Crash-loop and safe mode",
			"warn",
			"%d short unclean session(s) recorded; the next short exit disables the previous mod set." % streak,
		)
	return _check("safe_mode", "Crash-loop and safe mode", "pass", "The session marker shows no crash-loop streak.")


func _release_review_check(raw_review: Variant) -> Dictionary:
	if raw_review is Dictionary and bool((raw_review as Dictionary).get("ok", false)):
		return _check(
			"release_review",
			"Human release review",
			"pass",
			str((raw_review as Dictionary).get("detail", "Human release review evidence is recorded.")),
		)
	return _check(
		"release_review",
		"Human release review",
		"manual",
		"Desktop keyboard, screen-reader, IME and the five-user consent study are human Gate G/H evidence.",
	)


func _docs_check() -> Dictionary:
	var missing: Array = []
	for path in [SUPPORT_DOC, NOTES_DOC, README_DOC]:
		if !FileAccess.file_exists(path):
			missing.append(path.get_file())
	if !missing.is_empty():
		return _check(
			"support_docs",
			"Support and release documents",
			"fail",
			"Missing: " + ", ".join(missing),
		)
	return _check(
		"support_docs",
		"Support and release documents",
		"pass",
		"Support policy, release notes and the archived hardening gate record exist.",
	)


func _session_status() -> Dictionary:
	if session_path.is_empty() or !FileAccess.file_exists(session_path):
		return {"available": false, "clean": true, "streak": 0, "shell": false}
	var guard := SafeMode.new(session_path)
	var data: Dictionary = guard.marker()
	return {
		"available": !data.is_empty(),
		"clean": bool(data.get("clean", true)),
		"streak": int(data.get("streak", 0)),
		"shell": bool(data.get("shell", false)),
		"started_at": int(data.get("started_at", 0)),
	}


func _check(id: String, label: String, status: String, detail: String) -> Dictionary:
	return {
		"id": id,
		"label": label,
		"status": status,
		"detail": detail,
	}


func _file_size(path: String) -> int:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return 0
	var length := int(file.get_length())
	file.close()
	return length


static func _mb(bytes: int) -> float:
	return float(bytes) / (1024.0 * 1024.0)
