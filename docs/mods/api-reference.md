# API 1.0 — frozen reference

Status: **frozen Developer Preview contract** (`API_SEMVER = "1.0.0"`,
`API_STATUS = "frozen"`). The machine-readable surface is
`tests/fixtures/mods/api_v1_surface.json`: 100 native methods, sorted, SHA-256
`e27c1c0d341956d77751814df97a98bbea1724c462547c0f22f61effb0ff2467`.

From 1.0 onward only **additive** changes are allowed inside major version 1. A
breaking change requires API 2 and an adapter; see
[`migration-notes.md`](migration-notes.md).

Every Lua wrapper returns either a value or `nil, error`, where `error` is
`{code, message, details?}`. Calls never throw into mod code. The native method
name is the security boundary: it appears in `src/features/mods/api/api_v1.gd` with one
permission annotation, and a method missing from that table cannot be called by
any wrapper.

```lua
local text, err = editor.files.read("notes/today.md")
if text == nil then
  editor.log.error("read failed: " .. tostring(err and err.code))
end
```

## Core

| Native method | Lua wrapper | Purpose |
| --- | --- | --- |
| `assets.read_text` | `editor.assets.read_text(path)` | Read a UTF-8 asset from the mod's `assets/` folder. |
| `cancel` | `editor.cancel(handle)` | Cancel a task or timer handle. |
| `commands.execute` | `editor.commands.execute(id, args?)` | Run a command registered for this mod. |
| `commands.register` | `editor.commands.register(spec)` | Register a command; ids are namespaced to the mod. |
| `commands.unregister` | `editor.commands.unregister(id)` | Remove one of this mod's commands. |
| `content.read` | `editor.content.load(path)` | Load a Lua module from `content/`. |
| `dialogs.confirm` | `editor.dialogs.confirm(spec, fn?)` | Show a confirm dialog and call back with the result. |
| `dialogs.prompt` | `editor.dialogs.prompt(spec, fn?)` | Show a one-field prompt; the value is `result.value`. |
| `events.emit` | `editor.events.emit(name, payload)` | Emit a mod-namespaced event. |
| `events.subscribe` | `editor.events.on(name, fn, {priority})` | Subscribe to a host event. |
| `events.unsubscribe` | `editor.events.off(subscription)` | Remove a subscription. |
| `exercise.hint` | `editor.exercise.hint(id?, text)` | Post a hint into the caller's exercise. |
| `guide.hint` | `editor.guide.hint(text, session?)` | Show a hint in the caller's guide session. |
| `keys.bind` | `editor.keys.bind(chord, command_id)` | Bind a shortcut to one of this mod's commands. |
| `keys.unbind` | `editor.keys.unbind(command_id)` | Remove that binding. |
| `log` | `editor.log.info/warn/error(text)` | Write to the per-mod diagnostic log. |
| `module.read` | `require(path)` | Load `lib/<path>.lua`; the only module loader. |
| `permissions.has` | `editor.permissions.has(name)` | Display-only consent check. Native checks remain authoritative. |
| `progress.all` | `editor.progress.all()` | Read every progress key for this mod. |
| `progress.get` | `editor.progress.get(key, default?)` | Read one progress value. |
| `progress.increment` | `editor.progress.increment(key, amount?)` | Add to a numeric progress value. |
| `progress.reset` | `editor.progress.reset(key)` | Delete one progress key. |
| `progress.set` | `editor.progress.set(key, value)` | Write a JSON progress value. |
| `settings.declare` | `editor.settings.declare(schema)` | Declare runtime settings in addition to the manifest. |
| `settings.get` | `editor.settings.get(key, default?)` | Read a declared setting. |
| `settings.set` | `editor.settings.set(key, value)` | Write a declared setting. |
| `storage.clear` | `editor.storage.clear()` | Delete every KV entry for this mod. |
| `storage.delete` | `editor.storage.delete(key)` | Delete one KV entry. |
| `storage.get` | `editor.storage.get(key, default?)` | Read a KV entry. |
| `storage.keys` | `editor.storage.keys()` | List KV keys. |
| `storage.set` | `editor.storage.set(key, value)` | Write a JSON KV entry. |
| `tasks.schedule` | `editor.async(fn)`, `editor.wait(ms)` | Run a Lua task on the host scheduler. |
| `timer.schedule` | `editor.after(ms, fn)`, `editor.every(ms, fn)` | One-shot or repeating timer. |
| `ui.close_dialog` | `editor.ui.close_dialog(id)` | Close a mod dialog. |
| `ui.dialog` | `editor.ui.dialog(spec)` | Open a declarative dialog. |
| `ui.focus` | `editor.ui.focus(id)` | Focus a mounted widget or dialog. |
| `ui.mount` | `editor.ui.mount(slot, spec)` | Mount a widget tree in `right` or `center`. |
| `ui.notify` | `editor.ui.notify(text, severity?, options?)` | Show a notification. |
| `ui.on` | `editor.ui.on(id, event, fn)` | Subscribe to a widget event. Use the child's local id (or `<mod_id>.<local_id>`); a mount id is not a child prefix. |
| `ui.set_visible` | `editor.ui.set_visible(id, visible)` | Show or hide a mounted widget. |
| `ui.theme.token` | `editor.ui.theme.token(name)` | Read a theme colour token. |
| `ui.unmount` | `editor.ui.unmount(id)` | Remove a mount and its handlers. |
| `ui.update` | `editor.ui.update(id, spec)` | Diff a new widget tree into an existing mount. |

Core is granted on install. Storage, progress and settings are namespaced by mod
id; quotas are described in [`developer-guide.md`](developer-guide.md).

## Documents — read

| Native method | Lua wrapper | Permission |
| --- | --- | --- |
| `docs.active` | `editor.docs.active()` | `documents.read` |
| `docs.list` | `editor.docs.list()` | `documents.read` |
| `docs.text` | `editor.docs.text(doc)` | `documents.read` |
| `docs.cursor` | `editor.docs.cursor(doc)` | `documents.read` |
| `docs.selection` | `editor.docs.selection(doc)` | `documents.read` |
| `docs.is_dirty` | `editor.docs.is_dirty(doc)` | `documents.read` |
| `docs.path` | `editor.docs.path(doc)` | `documents.read` |
| `docs.language` | `editor.docs.language(doc)` | `documents.read` |
| `docs.reveal` | `editor.docs.reveal(doc)` | `documents.read` |
| `guide.start` | `editor.guide.start(spec)` | `documents.read` |
| `guide.state` | `editor.guide.state(session?)` | `documents.read` |
| `guide.pause` | `editor.guide.pause(session?)` | `documents.read` |
| `guide.resume` | `editor.guide.resume(session?)` | `documents.read` |
| `guide.stop` | `editor.guide.stop(reason?)` | `documents.read` |
| `guide.set_target` | `editor.guide.set_target(target, session?)` | `documents.read` |
| `guide.set_validation` | `editor.guide.set_validation(spec, session?)` | `documents.read` |
| `guide.resolve_validation` | `editor.guide.resolve_validation(token, passed, details?)` | `documents.read` |
| `guide.set_mode` | `editor.guide.set_mode("strict"\|"coach", session?)` | `documents.read` |
| `guide.set_progression` | `editor.guide.set_progression(progression, session?)` | `documents.read` |
| `guide.set_display` | `editor.guide.set_display(display, session?)` | `documents.read` |
| `exercise.start` | `editor.exercise.start(spec)` | `documents.read` (+ `run` when a validation runs) |
| `exercise.state` | `editor.exercise.state(id?)` | `documents.read` |
| `exercise.stop` | `editor.exercise.stop(id?, reason?)` | `documents.read` |
| `exercise.submit` | `editor.exercise.submit(id?)` | `documents.read` (+ `run` when the exercise phase runs) |

Document ids are stable positive integers. Columns are Unicode codepoint
columns. An edit that would split a grapheme cluster fails with
`doc.column_splits_grapheme` and `details.columns = [previous, next]`.

Guide and exercise methods read document content, so they need
`documents.read`. A run-backed validation additionally needs `run` and a trusted
workspace; the guard is applied before the service is called. The full guide
and exercise specs are in
[`../archive/mod-platform/api-reference-phase3.md`](../archive/mod-platform/api-reference-phase3.md).

## Documents — write

| Native method | Lua wrapper | Permission |
| --- | --- | --- |
| `docs.open` | `editor.docs.open(path)` | `documents.write` (also checks `files.read`) |
| `docs.create` | `editor.docs.create({path?, text?, language?})` | `documents.write` |
| `docs.set_text` | `editor.docs.set_text(doc, text)` | `documents.write` |
| `docs.insert` | `editor.docs.insert(doc, line, column, text)` | `documents.write` |
| `docs.replace` | `editor.docs.replace(doc, from, to, text)` | `documents.write` |
| `docs.set_cursor` | `editor.docs.set_cursor(doc, {line, col})` | `documents.write` |
| `docs.set_selection` | `editor.docs.set_selection(doc, from, to)` | `documents.write` |
| `docs.save` | `editor.docs.save(doc)` | `documents.write` |
| `docs.close` | `editor.docs.close(doc, {force?})` | `documents.write` |
| `guide.reset` | `editor.guide.reset({restore?})` | `documents.write` |
| `exercise.retry` | `editor.exercise.retry(id?, {restore?})` | `documents.write` |
| `exercise.advance` | `editor.exercise.advance(id?)` | `documents.write` |

`docs.create` never reopens an existing path; it returns `doc.exists`. Use
`docs.open`, which is a write-class action. Closing a dirty document returns
`doc.dirty` unless `force = true`. Untitled documents return `doc.unsaved` from
`docs.save`; use the host's Save As UI.

## Files and workspace

| Native method | Lua wrapper | Permission |
| --- | --- | --- |
| `files.read` | `editor.files.read(path)` | `files.read` |
| `files.exists` | `editor.files.exists(path)` | `files.read` |
| `files.list` | `editor.files.list(path, {recursive?})` | `files.read` |
| `files.write` | `editor.files.write(path, text)` | `files.write` |
| `files.mkdir` | `editor.files.mkdir(path)` | `files.write` |
| `files.delete` | `editor.files.delete(path, {confirmed=true})` | `files.write` |
| `workspace.root` | `editor.workspace.root()` | `workspace.read` |
| `workspace.name` | `editor.workspace.name()` | `workspace.read` |
| `workspace.has_workspace` | `editor.workspace.has_workspace()` | `workspace.read` |
| `workspace.list` | `editor.workspace.list(filter?)` | `workspace.read` |

Paths are workspace-relative. Absolute paths, drive letters and `..` are
rejected before a file is opened. `files.*` and `run` additionally require a
trusted workspace; the editor's cwd fallback is not a mod workspace. Writes are
atomic through `FileStore` and capped at 8 MiB. `delete` only removes empty
folders and needs an explicit `confirmed` flag supplied by the mod after the
user confirmed the action in a dialog.

The workspace root is host-owned: API 1 has no `workspace.open_folder`. Ask the
user to use **File → Open Folder**.

## Run and clipboard

| Native method | Lua wrapper | Permission |
| --- | --- | --- |
| `run.active` | `editor.run.active(options?)` | `run` |
| `run.file` | `editor.run.file(path, options?)` | `run` |
| `run.stop` | `editor.run.stop()` | `run` |
| `run.is_running` | `editor.run.is_running()` | `run` |
| `clipboard.write` | `editor.clipboard.write(text)` | `clipboard.write` |
| `clipboard.read` | `editor.clipboard.read()` | `clipboard.read` |

Run requests are intersected with workspace trust and deferred to the next
frame because `RunService` waits for a PTY; a successful return means the
request was accepted. Clipboard values are capped at 1,048,576 characters.

## Shell and layout

| Native method | Lua wrapper | Permission |
| --- | --- | --- |
| `ui.shell.takeover` | `editor.ui.shell.takeover(spec)` | `ui.shell` |
| `ui.shell.exit` | `editor.ui.shell.exit(reason?)` | `ui.shell` |
| `ui.shell.set_editor_visible` | `editor.ui.shell.set_editor_visible(visible)` | `ui.shell` |
| `ui.shell.set_content_insets` | `editor.ui.shell.set_content_insets(insets?)` | `ui.shell` |
| `ui.layout.set_visible` | `editor.ui.layout.set_visible(panel, visible)` | `ui.layout` |

Shell takeover is exclusive: a second owner gets `shell.busy`. The core HUD is
snapshotted and hidden, never freed; `ui.shell.exit` restores the exact
snapshot, camera insets and editor visibility. The host chrome (34 px with the
mod name, **Exit mod** and the panic hint) cannot be hidden by a layout. Panic
is `Ctrl+Alt+Shift+Esc`: the first press exits the shell, a second press within
two seconds disables all mods for the session.

Layout panels are `terminal`, `output`, `problems`/`language`, `debugger`,
`minimap`, `file_tree`, `search` and `source_control`. Hiding one restores it
when the mod is disabled or reloaded.

## Permission catalogue

`src/features/mods/mod_permissions.gd` is the catalogue. `consent` is what activation
requires; `available = false` entries are reserved and rejected by manifest
validation.

| Permission | Risk | Consent | Available | Grants |
| --- | --- | --- | --- | --- |
| `core` | low | install | yes | events, commands, partial UI, notifications, storage, progress, assets, timers |
| `documents.read` | medium | explicit | yes | text, cursor, selection |
| `documents.write` | medium | explicit | yes | edits, open, save |
| `files.read` | high | explicit + trust | yes | workspace files |
| `files.write` | high | explicit + trust | yes | workspace files |
| `workspace.read` | medium | explicit | yes | listing, root |
| `run` | critical | explicit + trust | yes | execute through RunService |
| `terminal.read` | high | explicit | yes | observe output |
| `terminal.write` | critical | explicit + trust | yes | inject input |
| `ui.shell` | high | explicit | yes | exclusive takeover, host chrome remains |
| `ui.layout` | low | explicit | yes | hide/show core panels |
| `clipboard.write` | low | explicit | yes | clipboard writes |
| `clipboard.read` | high | explicit | yes | clipboard reads |
| `settings.read` | low | explicit | yes | read global settings |
| `input.observe` | critical | not in v1 | **no** | raw keystrokes — reserved |
| `network` | critical | not in v1 | **no** | network access — reserved |

`permissions.has(name)` is a display helper only. Every native call re-checks
the active consent record. Sensitive permissions survive a version update only
when the permission set did not grow; a new permission triggers a fresh consent
prompt. `files.*`, `run` and `terminal.write` are also checked against the
workspace trust record at call time.

## Error envelope

Every failure is `{ok = false, error = {code, message, details?}}`. The codes
are listed in `src/features/mods/mod_result.gd`. API 1.0 adds no new code names
beyond the original mod-core contract; the Developer Preview freezes the existing names.

Common codes: `permission.denied`, `permission.consent_required`,
`trust.required`, `path.invalid`, `path.outside_workspace`, `state.invalid`,
`api.bad_args`, `api.unknown_method`, `storage.quota`, `event.queue_full`,
`budget.exceeded`, `memory.exceeded`, `run.blocked`, `run.timeout`,
`ui.slot_full`, `ui.widget_invalid`, `shell.busy`, `shell.invalid_spec`,
`host.fatal`, `mod.failed`.

## Verifying the contract

```bash
godot --headless --path . --script res://tests/test_runner.gd
```

`test_mod_api_golden.gd` compares the native table with the golden fixture and
`test_mod_api_contract.gd` pins the constants, the SHA-256 and docs coverage.
If a method is added, the golden file, this reference and the migration notes
change in the same commit; if a method is removed or re-annotated, that is a
breaking change and needs API 2.
