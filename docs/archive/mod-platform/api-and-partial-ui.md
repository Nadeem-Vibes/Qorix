# Phase 2 — API and partial UI

Status: **implemented, headless suites green; Gate C's windowed/manual checks
are still pending.** This is the Phase 2 scope from §16.3 of the architecture
plan: document/file/workspace/run/clipboard/dialog APIs, the widget catalog,
slot registry, in-place diffing, modal stack, the Mods settings page, the API
golden, developer docs and three samples. Shell takeover, guide and exercise
remain out of scope.

## Phase 0 and Phase 1 audit

Before this phase started, the tree was audited against the gates in the plan:

- **Phase 0 Gate A was not signed.** The probe harness and written report exist,
  but E1/E7/E9/E10/E11/E12/E13 are still listed as pending and the Phase 1 plan
  was implemented without the gate approval the plan requires. This is a process
  deviation in the existing tree, not something Phase 2 hides.
- **Phase 1 was green headless.** The pre-Phase-2 baseline was 2,429 checks
  across 53 suites, exit 0.
- **Phase 1 consent hashing had a real bug.** The package hash was only refreshed
  when `manifest.json`'s mtime changed, so editing `main.lua` could keep a
  consent record bound to bytes the user never reviewed. `ModRegistry` now stores
  `package_mtime` (the newest file in the package), and `ModManager` hashes when
  any package file changes. Startup still only stats files unless a timestamp
  changed.
- **Phase 1 Gate B remains partially pending** for the packaged E3 matrix and the
  manual UI/platform checks. The headless lifecycle, sandbox, storage, event and
  API suites pass.

Phase 2 builds on that implementation rather than restarting it.

## What is in the tree

| Area | File | Responsibility |
| --- | --- | --- |
| Text columns | `src/features/mods/mod_text_columns.gd` | codepoint columns, grapheme boundaries, split detection |
| Documents | `src/features/mods/mod_documents.gd` | stable ids, read/edit/save/close/reveal |
| Files | `src/features/mods/mod_files.gd` | workspace-relative read/write/list/mkdir/delete, atomic writes |
| Workspace | `src/features/mods/mod_workspace.gd` | root/name/list/open_folder |
| Clipboard | `src/features/mods/mod_clipboard.gd` | bounded clipboard read/write |
| Widget catalog | `src/features/mods/ui/mod_widget_catalog.gd` | declarative controls + in-place reconciliation |
| UI registry | `src/features/mods/ui/mod_ui_registry.gd` | right/center slots, event routing, modal stack, layout overrides |
| Mods page | `src/features/mods/ui/mod_settings_panel.gd` | installed mods, consent, reload, settings |
| API facade | `src/features/mods/api/api_v1.gd` | method table, permission annotations, Phase 2 dispatch |
| Lua SDK | `src/features/mods/sdk/sandbox.lua` | `editor.docs/files/workspace/run/clipboard/dialogs/ui` |
| Composition root | `src/main/file_manager.gd` | services, host events, command, settings page |
| Golden | `tests/fixtures/mods/api_v1_surface.json` | exact method/permission contract |
| Samples | `samples/mods/` | Hello Dock, Word Count, Note Taker |
| Tests | `tests/suites/test_mod_phase2_*.gd` | API, documents, files, UI, samples |

Documents now carry a monotonic integer `id` (`EditorDocument.id`), and
`DocumentManager.find_by_id()` resolves it. A closed document's id is never
reused, so a stale handle returns `doc.stale_handle` instead of addressing a new
buffer. Mods never receive the document object or a view.

## API surface

`api_v1.gd` is the security boundary. Every method in the table has one
permission annotation; a missing method cannot be called. The complete sorted
list is the golden file and `docs/mod-platform/phase2/api-reference.md`.

| Namespace | Methods | Permission |
| --- | --- | --- |
| documents | `active, list, open, create, text, set_text, insert, replace, cursor, set_cursor, selection, set_selection, save, close, is_dirty, path, language, reveal` | `documents.read` / `documents.write` |
| files | `read, write, exists, list, mkdir, delete` | `files.read` / `files.write` |
| workspace | `root, name, has_workspace, list, open_folder` | `workspace.read` |
| run | `active, file, stop, is_running` | `run` |
| clipboard | `write, read` | `clipboard.write` / `clipboard.read` |
| dialogs | `confirm, prompt` | `core` |
| partial UI | `mount, update, unmount, set_visible, on, notify, dialog, close_dialog, focus, theme.token` | `core` |
| layout | `ui.layout.set_visible` | `ui.layout` |

The workspace root is host-owned: `workspace.open_folder` is not part of API 1,
because a mod-supplied confirmation flag is not a user decision. `files.*` and
`run` remain intersected with workspace trust, exactly as in Phase 1.
`docs.open`/`files.*` resolve only inside a real `WorkspaceService`; the
process-cwd fallback used by save dialogs is deliberately not accepted as a mod
workspace.

The Lua wrappers are thin: validate the Lua-side shape, call
`call_native(method, args)`, return `(value, error)` or `(nil, error)`. They do
not add capabilities. `run.*` is queued through `RunService.call_deferred`
because starting a run awaits a PTY; `run.is_running()` is the immediate query.
`files.delete` requires `confirmed=true`; the samples show the matching
`editor.dialogs.confirm` flow.

## Partial UI

`ModUiRegistry` is host-owned. Slots are `right` (4 mounts) and `center` (4);
widget ids are `<mod_id>.<local_id>`. `mount()` validates the whole spec before
creating a node. `update()` reconciles in place: matching children keep their
identity, changed text/values are applied with signals blocked, removed children
are freed. There is no arbitrary engine object or raw `Control` in the API.

The catalog supports containers (`panel`, `vbox`, `hbox`, `scroll`) and leaves
(`label`, `richtext`, `button`, `checkbox`, `slider`, `spin`, `progress`,
`separator`, `divider`, `spacer`, `input`, `text`, `option`). Limits: 200
widgets, 8 levels of nesting, 2000 entries in `files.list`, 8 handlers per widget
event, 6 open modals.

Events are `click`, `submit`, `change` and `select`; a button emits from its own
widget id, so a mod registers on the child's local id (or the full
`<mod_id>.<local_id>`), not on the panel or `<mount_id>.<button_id>`.
Dialogs are a stack inside the registry; a click is delivered before the dialog
closes, and input/checkbox/option/spin/slider values are collected into
`{values, value}` so `editor.dialogs.prompt` receives the typed text. Teardown
(`reset_mod`) unmounts widgets, closes dialogs and restores layout visibility.

The Mods page is opened by the host command **View → Mods…** (`mods.manage`). It
lists installed mods, status, missing consent, log/reload/disable and declared
settings. Writes go through `ModManager.set_mod_setting()`, the same validated
store the Lua `editor.settings.*` API uses.

## Host events

`file_manager.gd` now publishes the catalogue events the plan promised:

- `document.opened`, `document.activated`, `document.changed` (coalesced),
  `document.dirty_changed`, `document.saved`, `document.closed`
- `workspace.opened`, `workspace.closed`
- `run.started`, `run.output` (coalesced, tail-limited), `run.finished`,
  `run.blocked`
- `command.executed`, `theme.changed`
- `app.ready`, `app.mods_ready`, `mod.activated`, `mod.deactivated`, `mod.failed`

Payloads are JSON-shaped and bounded by the event bus's 16 KiB cap. A run
payload carries the tail of the output rather than a duplicated full log.

## Samples

Copy a sample folder into `user://mods/` (on Windows,
`%APPDATA%\Godot\app_userdata\Qorix\mods\`), restart, and grant consent
from **View → Mods…**:

| Sample | Demonstrates | Permissions |
| --- | --- | --- |
| `griddycode.hello_dock` | dock panel, button diffing, command, setting, notification, storage counter | `core` |
| `griddycode.word_count` | document reads, host events, live panel | `documents.read` |
| `griddycode.note_taker` | prompt dialog, workspace-relative file write | `files.read`, `files.write`, `workspace.read` |

`hello_dock` is the Gate C sample: it adds a dock panel, a command, a declared
setting, a notification and a storage-backed counter. `tests/suites/
test_mod_phase2_samples.gd` validates every manifest and entry file and checks
that the samples use the APIs they document.

## Verification

```bash
godot --headless --path . --script res://tests/test_runner.gd
```

Phase 2 suites:

| Suite | Covers |
| --- | --- |
| `test_mod_phase2_api` | method permissions, missing-service failure, trust intersection, new result codes |
| `test_mod_phase2_documents` | grapheme boundaries, offsets, ids, open/create/edit/save/close, stale handles |
| `test_mod_phase2_files` | containment, workspace requirement, recursive list, atomic write, confirmed delete |
| `test_mod_phase2_ui` | catalog validation/diffing, slots, event routing, modal value collection, layout restore, Mods page |
| `test_mod_phase2_samples` | sample manifests, entries, documented API usage |

The API golden now contains **77 methods** (42 core/UI, 18 documents, 6 files,
5 workspace, 4 run, 2 clipboard).

## Gate C status

| Gate C item | Status |
| --- | --- |
| A sample mod adds a dock panel, command, setting, notification and storage-backed counter | Implemented in `griddycode.hello_dock`; headless manifest/API checks pass. Windowed consent/UI check pending. |
| Permissions are enforced | Pass headless: document read/write split, files trust intersection, `permission.denied` cases. |
| API golden is stable | Pass: 77-entry golden compared exactly by `test_mod_api_golden`. |
| Docs examples load in CI | Sample manifests and entry files are validated by `test_mod_phase2_samples`; full Lua execution with a UI host is a manual/windowed check. |

## Known limitations and deviations

- **No shell takeover, guide or exercise.** Those are Phase 3 and the API table
  does not advertise them.
- **Partial UI is host-framed.** Right/center slots only; no world-space or
  arbitrary embedding. Modal focus and keyboard traversal have not had the
  Phase 4 accessibility audit.
- **`run.*` is deferred.** Starting/stopping a run is scheduled on the next
  frame; `run.is_running` is the synchronous state query. Run output is tailed in
  events to respect the payload cap.
- **`settings.changed` is not emitted by the host.** The Mods page writes the
  store; a mod re-reads settings on its next action. Adding a change event is
  additive and does not need an API version bump.
- **`docs.open` needs `files.read`.** This is intentional: opening a path reads
  the workspace even though the document tab is write-scoped.
- **Clipboard is headless-untested.** The service caps values at 1 MiB and
  delegates to `DisplayServer`; the headless suite does not claim clipboard
  round-trip coverage.
- **Phase 0 Gate A is still unsigned.** This phase does not retroactively make
  the gate pass; the missing experiments and gate review should be closed before
  Phase 3 shell work, per the plan's dependency rule.

## Next

Phase 3 adds shell takeover, the guide matcher and the exercise engine on top of
this facade; see `docs/mod-platform/phase3/README.md` and its
`api-reference.md`. Keep the API golden, these documents and the samples in the
same change whenever the surface moves; the plan's change-control rule requires
it.
