# Phase 1 — Mod core

Status: **implemented; Gate B is green for the headless suites and pending the
platform/manual items listed at the end.**

This is the code Phase 0's `mod-core-plan.md` scoped: registry, manifest,
resolver, host, sandbox, tasks, permissions, storage, events, commands,
diagnostics and safe mode. Shell takeover, the learning engine and the full
widget catalog remain out of scope, as do the document/file/workspace/run APIs
(Phase 2).

The workspace already had the Phase 0 probe harness and contracts; nothing in
Phase 0 was rewritten to make this fit.

## What is in the tree

| Area | File | Responsibility | Plan item |
| --- | --- | --- | --- |
| Result envelope | `src/features/mods/mod_result.gd` | `{ok, value}` / `{ok, error:{code,message}}`, code catalogue | contracts §4 |
| JSON guard | `src/features/mods/mod_json.gd` | JSON-only values, byte counts, Lua array normalization | W5 |
| Semver ranges | `src/features/mods/semver_range.gd` | `^`, `~`, `>=`, `<=`, `<`, `>`, `*`, `||` | W2 |
| Manifest | `src/features/mods/mod_manifest.gd` | schema 1, field-level errors, compatibility | W1 |
| Registry | `src/features/mods/mod_registry.gd` | installed versions, hashes, enabled flags | W1 |
| Resolver | `src/features/mods/mod_resolver.gd` | topological order, missing/version/cycle/conflict | W2 |
| Permissions | `src/features/mods/mod_permissions.gd` | catalogue, consent records, active set, trust map | W4 |
| Host | `src/features/mods/mod_host.gd` | one Lua state, bootstrap capture, task budgets, timers | W3 |
| Sandbox | `src/features/mods/sdk/sandbox.lua` | sanitized `_ENV`, sentinel hook, protected pcall, API closures | W3 |
| API facade | `src/features/mods/api/api_v1.gd` | native method table + permission guard + golden surface | W3/W7 |
| Events | `src/features/mods/events/event_bus.gd` | typed catalogue, coalescing, per-mod queues, 2 ms dispatch budget | W6 |
| Storage | `src/features/mods/mod_storage.gd` | namespaced KV + blobs, quotas, atomic writes | W5 |
| Progress | `src/features/mods/mod_progress.gd` | small mod-scoped progress file | W5 |
| Settings | `src/features/mods/mod_settings.gd` | declared schema, coercion, persistence | W5 |
| Diagnostics | `src/features/mods/mod_diagnostics.gd` | 500-line ring buffer, failure record | W7 |
| Safe mode | `src/features/mods/mod_safe_mode.gd` | session marker, unclean-exit streak, `--safe-mode` | W7 |
| Manager | `src/features/mods/mod_manager.gd` | discovery, consent, activation, teardown, deferral | W1–W9 |
| Failure cards | `src/features/mods/ui/mod_failure_cards.gd` | Open log / Disable / Reload | W7 |
| Composition root | `src/main/file_manager.gd` | one `_setup_mods()` after `_setup_dialogs()` | W9 |

Tests live in `tests/suites/test_mod_*.gd`, `test_semver_range.gd` and
`test_event_bus.gd`; fixture mods live in `tests/fixtures/mods/`.

## Startup and lifecycle

```
FileManager._ready()
  TrustService.load()                  (existing)
  _setup_editor_services()             (existing)
  _setup_commands()                    (existing)
  _setup_hud()                         (existing)
  _setup_overlays() / _setup_dialogs() (existing)
  _setup_mods()                        <- the only new call
    ModManager.setup()                 load registry + consent records
    ModManager.start()
      safe-mode / crash-loop evaluation
      scan user://mods/<id>/<version>/
      resolve dependencies
      consent check per mod
      activate in topological order, 500 ms budget, rest deferred one per frame
      publish app.mods_ready
```

Per-mod activation:

1. Compatibility (`api`, `min_editor`, `max_editor`).
2. Consent status for sensitive permissions (core needs no record).
3. Storage, progress and settings services under `user://mod_data/<id>/`.
4. `LuaAPI` state + `sandbox.lua` bootstrap.
5. Entry chunk compiled into the sanitized environment and run as a hooked task.
6. State → `active`; `mod.activated` published.

Teardown follows §5.9 of the plan: optional `deactivate()` global (100 ms is
logged as a warning, not enforced by force), event subscriptions dropped,
commands unregistered, runtime keybindings cleared, data flushed, state released,
`mod.deactivated` published.

## Sandbox and budgets

The Phase 0 probe conclusion is implemented directly:

- Trusted libraries are bound only for bootstrap; the bootstrap captures
  `debug.sethook`, `coroutine.*`, `pcall`/`xpcall` and `load` into upvalues and
  sets `debug = nil` before any mod code runs.
- The mod environment has no `debug`, `coroutine`, `io`, `os`, `package`,
  `dofile`, `loadfile`, `collectgarbage` or `string.dump`. Its `_G` is itself.
- Every entry point runs in a host-created coroutine with a count hook that
  raises a private sentinel. `pcall`/`xpcall` rethrow the sentinel; the filter
  cannot be transformed by an `xpcall` handler.
- `editor.wait` is a plain `coroutine.yield` inside the host-owned thread. It
  does not use the addon's `LuaCoroutine`/`yield_state` path that corrupted the VM
  in Phase 0.
- Instruction budget: **250 hook firings × 1,000 instructions = 250,000
  instructions per resume** (Phase 0 F1). On exhaustion the task dies, the mod is
  marked failed when it was activation, and the state stays reusable.
- Memory: 24 MB per state. `LUA_ERRMEM` maps to `memory.exceeded`; three memory
  errors in 30 seconds is reported by `memory_error_storm()` for the disable
  policy.
- Wall clock: 8 ms soft / 25 ms hard per resume. An overrun lowers the budget and
  is logged. It deliberately does **not** destroy the state: a C function already
  inside the VM cannot be aborted, and a slow disk write is not a sandbox escape.
- Non-sentinel VM corruption (`[Wrapped…]`, C-stack overflow, error-in-error-
  handling) drops the state and reports `host.fatal`; the manager can recreate it
  on the next activation.
- Source limit: 2 MB per entry/module load; asset text 4 MB; package hash reads up
  to 64 MB.

## Permissions and consent

The catalogue is `mod_permissions.gd`. `core` is granted on install; every other
permission needs a consent record keyed by mod id, version and package hash.

- A record survives an update when the sensitive set does not grow; the manager
  refreshes the stored version/hash on activation.
- A new sensitive permission produces `permission.consent_required` and the mod
  stays `blocked` until `ModManager.grant_consent(id)`.
- `files.*`, `run` and `terminal.write` also require a trusted workspace. The
  check happens in the API guard at call time (`trust.required`).
- `editor.permissions.has()` is display only. The native guard decides.
- `input.observe` and `network` are in the catalogue as `available: false`; a
  manifest that asks for them is rejected with `manifest.unknown_permission`.

## Data layout

```
user://mods/<id>/<version>/          read-only mod package
user://mod_data/<id>/kv.json         2 MB KV quota
user://mod_data/<id>/blobs/          10 MB per blob, 50 MB total
user://mod_data/<id>/progress.json   64 KB
user://mod_data/<id>/settings.json   64 KB
user://mod_registry.json             enabled flags, hash, previous version
user://mod_permissions.json          consent records
user://mod_session.json              clean-exit / crash-loop marker
```

`kv.json`, `progress.json`, `settings.json` and blobs are written through
temp-file + swap. A malformed file is copied to `*.corrupt` and the service starts
from defaults. A mod's data is never deleted by disabling it.

## Events

`event_bus.gd` carries the contract catalogue plus each mod's own
`mod.<id>.*` namespace. Reserved events cannot be emitted by mods, and a mod
cannot subscribe to another mod's namespace. Host callers leave the source empty.

- Per-mod queue: 256; oldest dropped and counted (`dropped_count`).
- Coalescing: `document.changed`/caret/selection 100 ms, `run.output` 100 ms,
  `guide.progress` 150 ms, `guide.mistake` 500 ms; last payload wins.
- Dispatch is round-robin across mods with a 2 ms/frame budget; each delivery is a
  fresh hooked task in that mod's state, so a handler that blows its budget only
  kills its own task.
- Ordering inside one event: priority ascending, then registration order.

## Commands and keybindings

- Ids must start with `<mod id>.`; duplicates and foreign ids are refused.
- Command handlers receive `{args = {...}}` in Lua.
- `editor.commands.execute` is deferred to the next tick. This is deliberate:
  executing synchronously from inside a Lua call would resume a second coroutine
  while the first is running.
- `editor.keys.bind` only accepts the mod's own commands. It writes a
  **session-only** binding into `KeybindingService` (`set_runtime_binding`), so
  nothing is persisted into `user://keybindings.json` and disabling the mod
  removes both the command and the shortcut. Collisions are refused and the
  command stays in the palette.

## Diagnostics, failure cards and safe mode

- Each mod has a 500-line ring buffer with level, source, line and traceback.
- Activation/runtime failures produce a failure record and a card with
  **Open log**, **Disable** and (developer builds) **Reload**.
- Safe mode is requested with `--safe-mode` or `--no-mods`; the registry is left
  untouched and the next normal launch tries again.
- The session marker starts `clean: false`. A clean quit rewrites it to
  `clean: true`. Two sessions shorter than 60 seconds that ended unclean disable
  the mod set recorded in the previous marker.
- `disable_all_for_session()` exists for the panic path; it does not persist a
  disable.

## Phase 1 API surface

The complete list is `tests/fixtures/mods/api_v1_surface.json`; the golden test
compares both the names and the permission annotations.

| Surface | Permission |
| --- | --- |
| `permissions.has`, `log` | core |
| `events.subscribe/unsubscribe/emit` | core |
| `tasks.schedule`, `timer.schedule`, `cancel` | core |
| `commands.register/unregister/execute` | core |
| `keys.bind/unbind` | core |
| `storage.get/set/delete/keys/clear` | core |
| `progress.get/set/increment/reset/all` | core |
| `settings.declare/get/set` | core |
| `module.read`, `content.read`, `assets.read_text` | core |
| `run.active` | `run` (Phase 2 stub: `api.unavailable` after the guard) |

The Lua surface wraps these: `editor.log.*`, `editor.events.*`, `editor.async`,
`editor.wait`, `editor.after/every`, `editor.cancel`, `editor.commands.*`,
`editor.keys.*`, `editor.storage.*`, `editor.progress.*`, `editor.settings.*`,
`editor.content.load`, `require`, `editor.assets.read_text`, `editor.run.active`.

Deliberately absent from Phase 1: documents, files, workspace, UI, terminal,
clipboard and dialogs. They are now implemented in Phase 2; see
`docs/mod-platform/phase2/` and the 77-entry golden file.

## Tests

Headless:

```bash
godot --headless --path . --script res://tests/test_runner.gd
```

Verification on 2026-11-03 (Godot 4.7.2, Windows): **all 2,429 checks across 53
suites pass, exit 0**, plus a 40-frame headless startup with no script errors.
The only startup output is the project's existing shader-compiler warning.

| Suite | Covers |
| --- | --- |
| `test_semver_range` | every operator, caret/tilde zero rules, OR/AND, invalid input |
| `test_mod_manifest` | fixture read, unknown fields, permissions, ids, entry paths, settings, compatibility |
| `test_mod_resolver` | order, determinism, missing/version/cycle/conflict, optional edges |
| `test_mod_permissions` | catalogue, consent lifecycle, growth, persistence, malformed file |
| `test_event_bus` | dispatch, coalescing, queue cap, namespaces, ordering, unsubscribe |
| `test_mod_storage` | KV/blob roundtrip, quotas, atomic writes, corruption, progress |
| `test_mod_settings` | declaration, Lua-number coercion, bounds, conflicts, persistence |
| `test_mod_host` | environment, infinite loop, pcall/xpcall, nested coroutine, binary load, memory, handlers, timers, wait, teardown |
| `test_mod_manager` | activation, command, events, storage, loaders, keys, consent, failure isolation, safe mode, crash loop, reload |
| `test_mod_api_golden` | exact method/permission surface |

Fixture mods: `minimal`, `full`, `bad_manifest`, `infinite_while`, `pcall_loop`,
`nested_coroutine`, `memory_hog`, `crash_activate`, `event_storm`,
`storage_abuser`, `path_escape`, `run_abuser`, `consent`, `dependency`.

## Gate B status

| Gate B item | Status |
| --- | --- |
| Fixture mod installs, activates, registers a command, emits/receives events, persists data, fails safely, deactivates | Pass (headless) |
| Sandbox attack suite, including the deep-recursion fatal path | Pass for the sentinel attacks; the packaged Windows/Linux E3 matrix is still a Phase 0 item |
| No editor regression; startup within budget | 40-frame headless startup is clean; the 500 ms budget is enforced with deferred continuation, but the E1 profile baseline does not exist yet so the number is not compared against one |
| Permission enforcement and trust intersection covered | Pass for `run`; `files.*` land with the Phase 2 API |
| Storage quotas and malformed-data recovery | Pass |
| Diagnostics, failure card and safe mode | Logic and headless tests pass; the card needs a manual window check |
| E3 re-run on packaged Windows debug/release and Linux release | **Pending** (Phase 0 harness work) |
| API golden exists and matches | Pass |

## Decisions and deviations from the Phase 0 draft

1. **250k instruction budget accepted.** This is the safer target called for by
   F1. The fatal-state recreation path exists for VM corruption.
2. **Hard wall-clock overrun degrades instead of destroying.** A GDScript native
   call cannot be aborted mid-flight; dropping a state because a 2 MB write took
   30 ms would be worse than lowering its budget.
3. **The mod settings page arrived in Phase 2.** The store and schema existed
   in Phase 1; **View → Mods…** now edits them through the same validated store.
4. **`run.active` is present but returns `api.unavailable`.** The fixture
   `run_abuser` needs a structured refusal, and adding the method now fixes the
   contract early. It is not a working run path.
5. **Cross-mod event flow is not allowed.** A mod can subscribe to host events and
   its own `mod.<id>.*`, not another mod's events. This keeps v1 isolation
   simple; a future opt-in can be added without changing the API version.
6. **Activation deferral is one mod per frame**, not a worker thread. It keeps
   the first frame responsive without introducing a second execution context.
7. **Package hashing is mtime-gated.** Rehashing every mod on every startup would
   spend the startup budget; a changed manifest mtime triggers a new hash.

### Contract additions

New error codes, all listed in `mod_result.gd` and documented here first:

`manifest.unreadable`, `dependency.conflict`, `dependency.version`,
`permission.consent_required`, `permission.unknown`, `registry.invalid`,
`state.invalid`, `settings.invalid`, `settings.conflict`, `api.bad_args`,
`api.unknown_method`, `api.unavailable`, `event.invalid`, `event.forbidden`,
`command.invalid`, `command.duplicate`, `command.unknown`, `key.collision`,
`key.invalid`, `storage.invalid_key`, `storage.invalid_value`,
`module.not_found`, `module.invalid`, `host.not_started`, `host.fatal`,
`host.reentrant`, `timer.invalid`.

No existing contract code changed meaning.

## Known limitations

- The `debug` library is available during bootstrap only. If a future addon drops
  it, the fallback is the patched abort binary from §5.10.
- A single long C call (`string.gsub` on a pathological input) is bounded by
  memory and input size, not by the instruction hook.
- The capability boundary is not a process sandbox. A granted permission can be
  abused within its scope; `files.*`, `run` and `terminal.write` are trust-gated
  but remain high-risk.
- The crash-loop heuristic cannot distinguish “mods crashed the editor” from “the
  user killed a slow session twice”. Two clean starts restore the set.
- RTL text, ZWJ alignment and the learning engine are Phase 3 concerns; nothing in
  Phase 1 depends on them.
- `EditorView` and the camera are untouched, which is why there is no editor
  regression risk from this phase.

## Next: Phase 2 handoff

Phase 2 completed this handoff: `api_v1.gd` now carries the document, file,
workspace, run, clipboard, dialog and partial-UI methods; the golden file,
samples and developer docs were updated in the same change. Shell takeover,
guide and exercise remain Phase 3. See `docs/mod-platform/phase2/README.md`,
including the Gate A/Gate B audit notes.
