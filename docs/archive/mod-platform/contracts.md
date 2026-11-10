# Phase 0 contracts (proposed)

Status: **proposed for Gate A sign-off. Not frozen.** These are the contracts
Revision 2 asks Phase 0 to settle: the API surface, permission catalogue,
manifest schema, error codes, event catalogue and the guide/exercise contract.
Changes after sign-off follow the change-control rules in section 16.9 of the
plan.

Every public function is validated and permission-checked in native code. The
Lua SDK is developer experience; it is not the security boundary. Handles are
integers or namespaced strings, never engine objects.

## 1. Public API — `editor.*`, API 1

### Core

| Surface | Returns / notes | Permission |
| --- | --- | --- |
| `editor.api_version` | `1` | core |
| `editor.mod` | `{id, name, version}` | core |
| `editor.permissions.has(name)` | boolean, display-only; host still enforces | core |
| `editor.log.info/warn/error(msg)` | attribution added by host | core |
| `editor.events.on(name, fn, opts)` | subscription handle | core |
| `editor.events.off(handle)` | – | core |
| `editor.events.emit(name, payload)` | only `mod.<id>.*` | core |
| `editor.async(fn)` | task id; host-created hooked coroutine | core |
| `editor.wait(ms)` | only inside a task | core |
| `editor.after(ms, fn)` / `editor.every(ms, fn)` | timer handle | core |
| `editor.cancel(handle)` | cancels a task or timer | core |

### Commands, keys, documents, files

| Surface | Notes | Permission |
| --- | --- | --- |
| `editor.commands.register(spec)` | id must be `modid.command`; duplicate fails | core |
| `editor.commands.unregister(id)` / `execute(id, args)` | execute only host commands if enabled | core |
| `editor.keys.bind(command_id, chord)` / `unbind` | collision denied; command remains in palette | core |
| `editor.docs.active()` / `list()` | document ids | `documents.read` |
| `editor.docs.open(path)` | reuses an existing tab | `documents.write` + `files.read` |
| `editor.docs.create{path?, text?, language?}` | returns doc id | `documents.write` |
| `editor.docs.text(doc)` / `set_text(doc, s)` | UTF-8 at the boundary | read/write |
| `editor.docs.insert(doc, line, col, s)` | rejects a column inside a grapheme cluster | `documents.write` |
| `editor.docs.replace(doc, from, to, s)` | same cluster rule | `documents.write` |
| `editor.docs.cursor(doc)` / `set_cursor{line, col}` | codepoint columns | read/write |
| `editor.docs.selection(doc)` / `set_selection` | – | read/write |
| `editor.docs.save(doc)` / `close` / `is_dirty(doc)` | – | `documents.write` |
| `editor.docs.path(doc)` / `language(doc)` / `reveal(doc)` | – | `documents.read` |
| `editor.files.read(path)` / `write(path, s)` | workspace-relative; absolute rejected | `files.read` / `files.write` |
| `editor.files.exists` / `list` / `mkdir` / `delete` | delete is confirmed | read/write |
| `editor.workspace.root()` / `name()` / `has_workspace()` | – | `workspace.read` |
| `editor.workspace.list(filter)` | indexed files | `workspace.read` |
| `editor.workspace.open_folder(path)` | removed in the Phase 3 review; the host owns root changes | — |

Documents receive a monotonic id that is never reused. A closed document is a
clean `doc.stale_handle`.

### UI

| Surface | Notes | Permission |
| --- | --- | --- |
| `editor.ui.mount(slot, spec)` / `update` / `unmount` / `set_visible` | additive; returns namespaced widget id | core |
| `editor.ui.on(id, event, fn)` | `click`, `submit`, `change`, `select`; payload includes `source` | core |
| `editor.ui.notify(text, severity, opts)` | mod attribution | core |
| `editor.ui.dialog(spec)` / `close_dialog` | host-owned modal stack | core |
| `editor.ui.focus(id)` | keyboard focus | core |
| `editor.ui.layout.set_visible(panel, bool)` | named core panels; restorable | `ui.layout` |
| `editor.ui.shell.takeover(spec)` / `exit()` | exclusive; no stacking | `ui.shell` |
| `editor.ui.shell.set_editor_visible(bool)` / `set_content_insets(insets)` | host records and restores | `ui.shell` |
| `editor.ui.theme.token(name)` | read-only host token | core |

Full takeover is HUD framing, not reparenting the world-space editor. Host
chrome (34 px strip, panic hint, exit) is not mod-hideable. Panic is
`Ctrl+Alt+Shift+Esc`: first press exits the shell, a second press within two
seconds disables all mods for the session.

### Learning, storage and host services

| Surface | Notes | Permission |
| --- | --- | --- |
| `editor.exercise.start(spec)` / `state` / `submit` / `retry` / `stop` / `hint` / `advance` | kinds: typing, freeform, hybrid | `documents.read`; `retry`/`advance` also `documents.write`; `run` when tests execute |
| `editor.guide.start` / `state` / `pause` / `resume` / `reset` / `stop` / `hint` | typing sessions without the exercise wrapper | `documents.read`; `reset` also `documents.write` |
| `editor.guide.set_target` / `set_validation` / `resolve_validation` / `set_mode` / `set_progression` / `set_display` | live session controls | core |
| `editor.storage.get/set/delete/keys/clear` | JSON values, 2 MB KV quota | core |
| `editor.storage.blob_write/read/delete` | 10 MB per blob, 50 MB total | core |
| `editor.progress.get/set/increment/reset/all` | mod-scoped, auto-persisted | core |
| `editor.settings.declare(schema)` / `get` / `set` | rendered under Settings → Mods | core |
| `editor.run.active(opts)` / `file(path, opts)` / `stop` / `is_running` | only execution path; profile/trust gated | `run` |
| `editor.terminal.show/hide/is_open` | UI only | core |
| `editor.terminal.read(fn)` / `write(text)` | write is confirmed per use in v1 | `terminal.read` / `terminal.write` |
| `editor.clipboard.write(s)` / `read()` | – | `clipboard.write` / `clipboard.read` |
| `editor.dialogs.confirm(spec, fn)` / `prompt` | host-styled | core |
| `editor.content.load(path)` | data module, same sanitized env; no side effects | core |
| `editor.assets.read_text(path)` / `image(path)` | read-only, size-limited; image returns a handle | core |

There is no ambient `require`, `dofile`, `loadfile`, `package`, `io`, `os`,
`debug`, `coroutine`, `collectgarbage`, `string.dump`, network or native-loading
function.

## 2. Permission catalogue

| Permission | Grants | Risk | Consent |
| --- | --- | --- | --- |
| `core` | events, commands, partial UI, notifications, storage, progress, exercise, guide, assets, timers | low | on install |
| `documents.read` / `documents.write` | text, cursor, selection / edits, open, save | medium | explicit |
| `files.read` / `files.write` | workspace files | high | explicit + workspace trust |
| `workspace.read` | listing, root | medium | explicit |
| `run` | execute through RunService | critical | explicit + workspace trust |
| `terminal.read` | observe output | high | explicit |
| `terminal.write` | inject input | critical | explicit + per-use confirmation |
| `ui.shell` | exclusive takeover | high | explicit + host chrome remains |
| `ui.layout` | hide/show core panels | low | explicit |
| `clipboard.write` / `clipboard.read` | clipboard | low / high | explicit |
| `settings.read` | read global settings | low | explicit |
| `input.observe` | raw keystrokes | critical | **not in v1** |
| `network` | network access | critical | **not in v1** |

Core capabilities are granted on install. Sensitive capabilities need explicit
consent; `run` and `terminal.write` also intersect with workspace trust. A
permission change on update requires a new consent record.

## 3. Manifest schema

`schema` is `1`. Unknown top-level fields are rejected in v1 to catch typos.
Unknown permissions are rejected and the valid names are listed.

| Field | Type | Required | Rules |
| --- | --- | --- | --- |
| `schema` | integer | yes | `1` |
| `id` | string | yes | reverse-DNS, lowercase, `[a-z0-9._-]`, 3–64 chars |
| `name` | string | yes | 1–80 chars |
| `version` | string | yes | Semver `MAJOR.MINOR.PATCH` |
| `api` | integer | yes | `1` for v1 |
| `min_editor` | string | yes | Semver, compared with `VersionUtils` |
| `max_editor` | string | no | empty means no upper bound |
| `entry` | string | yes | relative path, normally `main.lua`; no `..` |
| `author` | string | yes | 1–120 chars |
| `description` | string | yes | 1–500 chars |
| `license` | string | no | SPDX identifier or custom text |
| `homepage` | string | no | HTTPS URL |
| `permissions` | array | yes | known permission strings; duplicates rejected |
| `dependencies` | object | no | `{ "id": "^1.2.0" }`; missing/cycle blocks install |
| `optional` | object | no | same shape; activates if present |
| `conflicts` | array | no | mod ids |
| `settings` | array | no | `{key, type, default, label, min?, max?}` |
| `assets` | object | no | icon path and size limits |

Validation errors name the field and the reason. The reference manifest in the
plan (`com.example.pythonjourney`) declares `documents.read`, `documents.write`,
`files.read`, `files.write`, `run`, `ui.shell` and `ui.layout`; a denied
`ui.shell` falls back to the partial layout with a visible explanation.

## 4. Error codes

| Code | Meaning | User-facing behavior |
| --- | --- | --- |
| `manifest.invalid` | Schema or field validation failed | Show field errors; refuse install |
| `manifest.unknown_permission` | Permission not in catalogue | Refuse install; list valid names |
| `manifest.version_range` | Editor/API range mismatch | Refuse activation; suggest update |
| `dependency.missing` | Required mod absent | Block install; list missing ids |
| `dependency.cycle` | Cycle in the graph | Block install; show the cycle |
| `permission.denied` | Capability not granted | API returns `nil, {code, message}`; mod may fall back |
| `trust.required` | Workspace trust missing | Prompt for trust; never silently allow |
| `path.outside_workspace` | Path escape | Reject; log; no write |
| `path.invalid` | Absolute path or `..` | Reject with canonical root |
| `doc.stale_handle` | Document closed | Reject; ask the mod to reacquire |
| `doc.column_splits_grapheme` | Insertion splits a cluster | Reject with the two valid columns |
| `ui.slot_full` | Slot at capacity | Reject mount; keep existing widgets |
| `ui.widget_invalid` | Unknown widget or property | Reject mount; name the property |
| `shell.busy` | Another shell owns the screen | Offer switch or reject |
| `budget.exceeded` | Instruction/step budget | Kill task; mark mod failed |
| `memory.exceeded` | Lua allocation limit | `LUA_ERRMEM`; disable after repeat policy |
| `storage.quota` | KV/blob quota exceeded | Reject write; report usage |
| `run.blocked` | RunService/trust gate | Explain why; offer trust |
| `run.timeout` | Validation run exceeded | Report partial output; allow retry |
| `event.queue_full` | Per-mod queue capped | Drop oldest; diagnostic |
| `mod.failed` | Activation/runtime failure | Failure card; disable/reload |

New codes require a contract update; do not overload an existing code.

## 5. Event catalogue

| Event | Payload | Coalescing |
| --- | --- | --- |
| `app.ready` | `{api_version}` | once |
| `app.quitting` | `{}` | once, 50 ms budget |
| `app.mods_ready` | `{count}` | once |
| `workspace.opened` / `workspace.closed` | `{root}` | – |
| `document.opened` / `closed` / `saved` | `{doc, path}` | – |
| `document.activated` | `{doc}` | – |
| `document.dirty_changed` | `{doc, dirty}` | – |
| `document.changed` | `{doc, length, version}` — no text | 100 ms, last wins |
| `editor.caret_moved` | `{doc, line, col}` | 100 ms |
| `editor.selection_changed` | `{doc, has_selection}` | 100 ms |
| `command.executed` | `{id}` | – |
| `theme.changed` / `settings.changed` | name / `{key, value}` | – |
| `run.started` / `output` / `finished` / `blocked` | run info / chunk / result / reason | output 100 ms |
| `terminal.opened` / `closed` | `{}` | – |
| `exercise.started` / `phase_changed` / `submitted` / `completed` / `failed` | exercise state | – |
| `guide.started` / `progress` / `segment` / `mistake` / `diverged` / `validated` / `completed` / `stopped` | guide state | progress 150 ms; mistakes 500 ms |
| `mod.activated` / `deactivated` / `failed` | `{id, version, reason?}` | – |

Mods may emit only `mod.<id>.*`; reserved names are rejected. “Character typed”
is deliberately not a public event: it enables keylogging and costs a Lua call
per character. Guided sessions expose semantic `guide.progress`/`guide.mistake`;
general mods use debounced `document.changed` and read text on demand.

## 6. Guide and exercise contract

### Kinds

| Kind | Ghost/filter | Validation |
| --- | --- | --- |
| `typing` | yes; progression and display configured independently | exact text and/or tests |
| `freeform` | no; normal editing | tests, stdout, file checks, custom |
| `hybrid` | typing and freeform phases | both, per phase |

### Orthogonal axes

| Axis | Values | Default |
| --- | --- | --- |
| `mode` | `strict`, `coach` | `strict` |
| `progression` | `character`, `word`, `line`, `none` | `character` |
| `display` | `scope` (`next_char`, `line`, `segment`, `block`), `chars`, `alpha` | `line`, 64 chars |

Any combination is valid. Progression and display are independent: character
progression with line display is the reference default.

### Validation types

`exact_text`, `contains`, `regex`, `stdout_contains`, `stdout_regex`,
`exit_code`, `tests` (ordered named cases with partial results) and `custom`
(host emits a request; the mod answers within a timeout). Tests execute through
RunService, never a new process API. A run has a `timeout_ms` and the host stops
it through RunService.

### Unicode

- Lua strings are UTF-8; public line/column values are Unicode codepoint columns.
- The matcher progresses on grapheme clusters using
  `TextServer.string_get_character_breaks`.
- `editor.docs.insert`/`replace` reject a column that splits a cluster and
  return the two nearest valid columns.
- `guide.progress` reports `{col, grapheme, codepoint, byte}`.
- Ghost rendering draws one cluster at a time for tabs, combining marks and
  proportional fonts; tabs are one codepoint and one column.
- Combining marks stay with the base. ZWJ emoji are supported-with-caveat and
  must be platform-tested. RTL paragraphs are out of scope for v1; the guide
  refuses to start with a clear error.
- `normalize = "NFC"` is optional and applies only to the comparison key; the
  buffer is never rewritten. Default is `none`.

## 7. Package layout and loaders

```
<mod>/
  manifest.json
  main.lua
  lib/        executable modules
  content/    data modules
  assets/     read-only media
  locales/
  README.md
  CHANGELOG.md
```

| Loader | Resolves | Rules |
| --- | --- | --- |
| `require("lib.layout")` | `<root>/lib/layout.lua` | returns a table; cached per state; cycle detection; same mod env |
| `editor.content.load("lessons/01_hello")` | `<root>/content/lessons/01_hello.lua` | returns a table only; no globals or side effects; cached; `{reload=true}` in development |
| `editor.assets.read_text("...")` / `image("...")` | `<root>/assets/...` | read-only; size-limited |

There is no ambient `require`, `package.path` or `dofile`. A content file that
returns a function is rejected with a clear author error. Settings are declared
in the manifest, not in an executable config.

## 8. Versioning and freeze

- `api = 1` is the manifest field; `editor.api_version = 1`.
- Additive changes stay in major 1. Breaking changes require `api = 2` plus an
  adapter facade.
- The API is experimental during Phases 1–4 and freezes at the end of Phase 5
  (Developer Preview). Preview mods must declare `api = 1`.
- A golden test asserts the exact function list and each function's permission
  annotation; accidental exposure fails CI.
- Deprecations warn in the mod log for one minor cycle before removal.

## 9. Open product decisions for Gate A

1. Minimum editor version for mods: 1.3.0 or the next release?
2. Preview platforms: Windows-only preview with Linux in public beta?
3. Publisher identity: local Ed25519 keys in Phase 6, or wait for a hosted registry?
4. Telemetry: none, or an opt-in crash report for the preview?
5. Legacy content: show `langs`/`themes` as “Legacy” in Phase 5 or later?
6. Course content ownership: bundled mod, downloadable sample, or both?
7. Accessibility target: WCAG 2.1 AA everywhere, or AAA for any surface?
8. Support policy at 1.0: which platforms and editor versions?
