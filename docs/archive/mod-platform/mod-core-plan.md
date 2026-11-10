# Phase 1 plan — Mod core

Status: **implemented** (see `mod-core.md`). The Gate A decision was
recorded as the 250k instruction budget plus fatal-state recreation (F1), and the
phase was built against the draft below. The E3 packaged platform matrix and the
manual failure-card check remain open; everything else in Gate B passes
headlessly on Godot 4.7.2 (2,429 checks across 53 suites). The scope follows
section 16.3 of Revision 2: registry, manifest, resolver, host, sandbox, tasks,
permissions, storage, events, commands, diagnostics and safe mode. Shell, guide,
exercise and the full widget catalog are out of scope.

## Inputs from Phase 0

| Input | Current state | Needed before Phase 1 |
| --- | --- | --- |
| E3 abort policy | 1M budget unsafe for non-tail recursion; 500k is borderline; 250k measured at 11.6 ms | Approve 250k, or fatal-state recreation, or both |
| E3 platform matrix | Windows editor build only | Packaged Windows debug/release and Linux release |
| E2 addon pin | Hashes recorded; `Lua 5.4` reported | Resolve the 5.4.5 discrepancy and pin the exact build |
| E4 native callbacks | Synchronous; 120 ms callback blocked 120 ms | Accept the limitation and restrict host callables |
| E4/E5 lifecycle | Teardown clean; no leak in 100 states | Re-run with fatal-state recreation |
| E6 callback ids | Raw pulled functions are unhooked; stale ids untested | ModHost must use integer callback ids |
| E7/E8/E9 | Shell/Unicode/input gates not complete | Not required for Phase 1, but required before Phase 3 shell work |
| Contracts | Drafted in `contracts.md` | Gate A sign-off; golden API file |

F1 is the only Phase 0 finding that blocks the Phase 1 sandbox design. E7/E8/E9
block Phase 3, not Phase 1.

## Work packages

### W1 — Registry and manifest validation (4 days)

- Scan `user://mods/<id>/<version>/`.
- Validate `manifest.json` against the schema: id shape, Semver version, API
  range, editor range via `VersionUtils`, entry path, permissions, settings,
  asset limits, unknown fields.
- Persist `user://mod_registry.json` atomically through `FileStore`.
- Enable/disable flags, installed version/hash, previous version retained.
- Duplicate id/version handling; invalid entries produce a startup notice, not a
  crash.

Acceptance: fixture mods `minimal` and `bad_manifest` install/reject with
field-level errors; registry survives a kill between temp write and swap.

### W2 — Dependency resolver and SemverRange (3 days)

- Add `SemverRange` around `VersionUtils`: `^`, `~`, `>=`, `<=`, `<`, `>`, `*`,
  `||`.
- Build the local graph, topological sort, cycle and missing-dependency errors.
- One active version per mod; optional dependencies activate if installed.

Acceptance: unit tests cover every operator, cycles, missing nodes, optional
nodes and deterministic ordering.

### W3 — ModHost, sandbox and tasks (8 days)

- One `LuaAPI` state per mod; bind `base, table, string, math, utf8, coroutine,
  debug` only during bootstrap.
- Port `Tools/phase0_probe/lua/bootstrap.lua` into the production host with:
  sanitized `_ENV`, protected `pcall`/`xpcall`, no raw coroutine, binary-load
  rejection, memory limit, task table.
- Host-created coroutine per task; count hook; sentinel error; task result
  `{ok, err, timeout, dead}`.
- Budgets: instruction budget per resume, 25 ms hard wall-clock watchdog,
  per-state memory limit, total mod memory cap.
- **Fatal VM error path:** a non-sentinel error that leaves the state unusable
  (stack overflow/`[Wrapped:0]`) marks the mod failed, drops the task table,
  releases the LuaAPI object and recreates the state on demand.
- Teardown order from section 5.9.

Acceptance: `infinite_while`, `pcall_loop`, `nested_coroutine`, `memory_hog` and
`crash_activate` fixtures behave as specified; a state is reusable after every
sentinel abort; a stack-overflow state is destroyed, not reused.

### W4 — PermissionService and consent (4 days)

- Parse manifest permissions; reject unknown names.
- Store consent records with id, version, hash and permission set.
- Intersect `files.*`, `run` and `terminal.write` with `TrustService`.
- Re-consent on permission growth; denial leaves the editor usable.
- Display-only `editor.permissions.has`; native checks remain authoritative.

Acceptance: `run_abuser` and `path_escape` fixtures receive structured errors;
denying `ui.shell` produces the partial-UI fallback in the sample.

### W5 — ModStorage, settings and progress (4 days)

- Namespaced KV and blobs under `user://mod_data/<id>/`.
- Quotas: 2 MB KV, 10 MB per blob, 50 MB total; atomic writes via `FileStore`.
- Malformed JSON restores defaults and keeps a backup.
- Settings declared in the manifest render under Settings → Mods; no
  `SettingsService._schema` mutation.
- Progress helpers persist on teardown.

Acceptance: `storage_abuser` is rejected at quota; malformed data recovers;
100 write/read cycles leave no temp files.

### W6 — EventBus (4 days)

- Typed events from `contracts.md`.
- Per-mod queue capped at 256; drop oldest; diagnostic.
- Coalescing windows: document.changed 100 ms, caret/selection 100 ms, guide
  progress 150 ms, mistakes 500 ms.
- Round-robin dispatch under a 2 ms/frame total budget.
- Error isolation: one mod's handler failure does not stop the others.
- Reserved event names rejected for mod emission.

Acceptance: `event_storm` (10,000 events) leaves the editor responsive; a
looping handler is killed within one budget; ordering is deterministic by
priority then registration.

### W7 — Commands, keybindings and diagnostics (4 days)

- Namespaced command ids; duplicate registration fails; unregister on teardown.
- Keybinding collision denied; command remains in the palette.
- Diagnostics ring buffer (last 500 lines) per mod with source/line/traceback.
- Failure card: error, Open log, Disable, Reload (developer mode only).
- Safe mode: `--safe-mode` / `--no-mods`, unclean-exit marker, two short unclean
  sessions disable the previous mod set.

Acceptance: `minimal` registers one command and deactivates cleanly; a failing
mod leaves other mods and the editor usable; safe mode starts with no mods.

### W8 — Fixtures and test suites (4 days, parallel)

Add `tests/suites/mods/` and `tests/fixtures/mods/`:

`minimal`, `bad_manifest`, `infinite_while`, `pcall_loop`, `nested_coroutine`,
`memory_hog`, `event_storm`, `crash_activate`, `storage_abuser`, `path_escape`,
`run_abuser`.

Unit: manifest validation, SemverRange, permission intersection, event
coalescing, queue caps, task result mapping, storage quotas, teardown ordering.

Integration: state bootstrap, activation/deactivation, command registration,
event publish/subscribe, storage persistence, safe mode.

Security: the attack suite above, plus unknown permission, permission growth,
absolute/`..` paths, stale handles and repeated memory errors.

Acceptance: every suite runs headless through `tests/test_runner.gd`; no test
touches a real workspace; CI exit code is the gate.

### W9 — Composition root and rollback (2 days)

- Add exactly one `_setup_mods()` call in `src/main/file_manager.gd` after
  `_setup_dialogs()`; do not reorder existing startup.
- Feature flag / kill switch; `--no-mods`; safe mode.
- Startup budget 500 ms total; if exceeded, continue activation deferred with a
  progress notice.
- Rollback plan: disable the mod set, restore the previous registry file, keep
  `user://mod_data` untouched; document manual recovery.

Acceptance: startup without mods is unchanged within the E1 budget; a bad mod
set cannot prevent the editor from reaching an interactive frame.

## Test plan

| Layer | Examples | Runs |
| --- | --- | --- |
| Unit | manifest fields, ranges, permission intersection, event coalescing, quota math | every commit, headless |
| Integration | bootstrap, activation, teardown, commands, events, storage | every commit, headless |
| Security | loops, pcall swallow, nested coroutine, memory hog, path escape, permission escalation, event storm | every commit, headless |
| End-to-end | fixture mods in a real window; safe mode; disable/reload | nightly, per platform |
| Manual | startup, failure card, consent text, safe mode | release gate |

CI matrix: Windows debug, Windows release, Linux release. macOS stays a manual
release-gate run.

Performance budgets: startup within the E1 baseline; mod dispatch under 2 ms per
frame; keystroke latency regression under 10%; no state leak over 100 cycles.

## Gate B checklist

- [ ] A fixture mod can install, activate, register a command, emit/receive
      events, persist data, fail safely and deactivate.
- [ ] The sandbox attack suite passes, including the E3 deep-recursion fatal
      path.
- [ ] No editor regression; startup stays within budget.
- [ ] Permission enforcement and trust intersection are covered by tests.
- [ ] Storage quotas and malformed-data recovery pass.
- [ ] Diagnostics, failure card and safe mode work.
- [ ] E3 is re-run on packaged Windows debug/release and Linux release.
- [ ] API golden file exists and matches the signed contracts.

## Schedule

Five weeks for one experienced Godot/GDScript engineer, with the fixture/test
work parallelised. The estimate assumes no renderer rewrite, no new process
model and no remote registry. Phase 0's E3 decision is the only blocking input;
E7/E8/E9 can run in parallel with Phase 1 but must pass before Phase 3.
