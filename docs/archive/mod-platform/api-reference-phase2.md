# API 1 — Phase 2 reference

This is the mod-facing surface in `src/features/mods/api/api_v1.gd`. Each native method is
permission-checked; the Lua names are wrappers in `src/features/mods/sdk/sandbox.lua`.
The machine-readable contract is
`tests/fixtures/mods/api_v1_surface.json` (77 entries, sorted).

Every wrapper returns either a value or `nil, error`, where `error` is
`{code, message, details?}`. Calls never throw into mod code.

## Core

| Lua | Native | Permission |
| --- | --- | --- |
| `editor.permissions.has(name)` | `permissions.has` | core |
| `editor.log.info/warn/error(text)` | `log` | core |
| `editor.events.on(name, fn, {priority})` | `events.subscribe` | core |
| `editor.events.off(subscription)` | `events.unsubscribe` | core |
| `editor.events.emit(name, payload)` | `events.emit` | core |
| `editor.async(fn)`, `editor.wait(ms)` | `tasks.schedule` | core |
| `editor.after(ms, fn)`, `editor.every(ms, fn)` | `timer.schedule` | core |
| `editor.cancel(handle)` | `cancel` | core |
| `editor.commands.register/unregister/execute` | `commands.*` | core |
| `editor.keys.bind/unbind` | `keys.*` | core |
| `editor.storage.get/set/delete/keys/clear` | `storage.*` | core |
| `editor.progress.get/set/increment/reset/all` | `progress.*` | core |
| `editor.settings.declare/get/set` | `settings.*` | core |
| `require(path)`, `editor.content.load(path)` | `module.read`, `content.read` | core |
| `editor.assets.read_text(path)` | `assets.read_text` | core |

## Documents

| Lua | Permission |
| --- | --- |
| `editor.docs.active()` | documents.read |
| `editor.docs.list()` | documents.read |
| `editor.docs.open(path)` | documents.write, files.read |
| `editor.docs.create({path?, text?, language?})` | documents.write |
| `editor.docs.text(doc)` | documents.read |
| `editor.docs.set_text(doc, text)` | documents.write |
| `editor.docs.insert(doc, line, column, text)` | documents.write |
| `editor.docs.replace(doc, from, to, text)` | documents.write |
| `editor.docs.cursor(doc)` | documents.read |
| `editor.docs.set_cursor(doc, {line, col})` | documents.write |
| `editor.docs.selection(doc)` | documents.read |
| `editor.docs.set_selection(doc, from, to)` | documents.write |
| `editor.docs.save(doc)` | documents.write |
| `editor.docs.close(doc, {force?})` | documents.write |
| `editor.docs.is_dirty(doc)` | documents.read |
| `editor.docs.path(doc)` | documents.read |
| `editor.docs.language(doc)` | documents.read |
| `editor.docs.reveal(doc)` | documents.read |

Document ids are stable positive integers. Columns are Unicode codepoint columns.
An edit whose column falls inside a grapheme cluster fails with
`doc.column_splits_grapheme` and `details.columns = [previous, next]`. `close`
on a dirty document returns `doc.dirty` unless `force=true`. Untitled documents
return `doc.unsaved` from `save`; use the host's Save As UI.

```lua
local id = editor.docs.active()
local text = editor.docs.text(id)
editor.docs.insert(id, 0, 0, "-- header\n")
editor.docs.save(id)
```

## Files and workspace

| Lua | Permission |
| --- | --- |
| `editor.files.read(path)` | files.read |
| `editor.files.write(path, text)` | files.write |
| `editor.files.exists(path)` | files.read |
| `editor.files.list(path, {recursive?})` | files.read |
| `editor.files.mkdir(path)` | files.write |
| `editor.files.delete(path, {confirmed=true})` | files.write |
| `editor.workspace.root()` | workspace.read |
| `editor.workspace.name()` | workspace.read |
| `editor.workspace.has_workspace()` | workspace.read |
| `editor.workspace.list(filter?)` | workspace.read |

Paths are workspace-relative. Absolute paths, drive letters and `..` are
rejected before a file is opened. `files.*` additionally require workspace trust
and a real open folder; the editor's cwd fallback is not a mod workspace.
Writes are atomic through `FileStore` and capped at 8 MiB. `delete` only removes
empty folders.

The workspace root is host-owned. There is no `workspace.open_folder` in API 1:
a mod-supplied `confirmed` flag is not a user decision, and switching roots would
also move the trust boundary. Ask the user to use the editor's own
`File > Open Folder` command instead.

`docs.create({path = ...})` never reopens an existing file. It returns
`doc.exists`; open it with `docs.open` (which is a `documents.write` action and
does not expose its text without `documents.read`).

```lua
local ok = editor.dialogs.confirm({title = "Delete note?", message = "This cannot be undone."},
  function(result)
    if result.confirmed then
      editor.files.delete("notes/old.txt", {confirmed = true})
    end
  end)
```

## Run, clipboard

| Lua | Permission |
| --- | --- |
| `editor.run.active(options?)` | run |
| `editor.run.file(path, options?)` | run |
| `editor.run.stop()` | run |
| `editor.run.is_running()` | run |
| `editor.clipboard.write(text)` | clipboard.write |
| `editor.clipboard.read()` | clipboard.read |

`run` is intersected with workspace trust. Starting and stopping are deferred to
the next frame because `RunService` waits for a PTY; the return value means the
request was accepted. Clipboard values are capped at 1 MiB.

## Dialogs and partial UI

| Lua | Permission |
| --- | --- |
| `editor.dialogs.confirm(spec, fn?)` | core |
| `editor.dialogs.prompt(spec, fn?)` | core |
| `editor.ui.mount(slot, spec)` | core |
| `editor.ui.update(id, spec)` | core |
| `editor.ui.unmount(id)` | core |
| `editor.ui.set_visible(id, visible)` | core |
| `editor.ui.on(id, event, fn)` | core |
| `editor.ui.notify(text, severity?, options?)` | core |
| `editor.ui.dialog(spec)` | core |
| `editor.ui.close_dialog(id)` | core |
| `editor.ui.focus(id)` | core |
| `editor.ui.theme.token(name)` | core |
| `editor.ui.layout.set_visible(panel, visible)` | ui.layout |

Slots are `right` and `center`, four mounts each. Widget ids are
`<mod_id>.<local_id>`; omit `id` and the host assigns one. `update` requires the
same root `type` and reconciles children in place. Handlers registered with
`ui.on` survive an in-place update; handlers for children that are removed are
dropped. Events are `click`, `submit`, `change`, `select`; a button emits from
its own id (`<mod_id>.<local_id>`), so register on `"button_id"` (or the full
`<mod_id>.<local_id>`). `mount_id` is the panel's id and is not a prefix for its
children.

Theme tokens: `background`, `foreground`, `selection`, `current_line`, `caret`,
`accent`, `error`, `warning`, `success`. Values are `#rrggbb`.

Layout panels: `terminal`, `output`, `problems`/`language`, `debugger`,
`minimap`, `file_tree`, `search`, `source_control`. Hiding a panel restores it
when the mod is disabled or reloaded.

Dialog callbacks receive `{button, confirmed, source, event, values, value?}`.
`prompt` adds an input with field id `value`, so `result.value` is the typed text.
The dialog closes after the callback returns.

```lua
local mount_id = editor.ui.mount("right", {
  type = "panel", id = "dock", title = "Counter",
  children = {
    {type = "label", id = "count", text = "0"},
    {type = "button", id = "bump", text = "+1"},
  },
})

local count = 0
editor.ui.on("bump", "click", function()
  count = count + 1
  editor.ui.update(mount_id, {
    type = "panel", title = "Counter",
    children = {
      {type = "label", id = "count", text = tostring(count)},
      {type = "button", id = "bump", text = "+1"},
    },
  })
  editor.ui.notify("Count: " .. tostring(count), "info")
end)
```

## Error codes added in Phase 2

`doc.not_found`, `doc.open_failed`, `doc.invalid_position`, `doc.too_large`,
`doc.unsaved`, `doc.save_failed`, `doc.dirty`, `workspace.required`,
`workspace.open_failed`, `module.unreadable`, `module.too_large`,
`module.unwritable`, `module.not_empty`, `ui.confirmation_required`,
`clipboard.too_large`.

Existing codes such as `doc.stale_handle`, `doc.column_splits_grapheme`,
`path.invalid`, `path.outside_workspace`, `ui.slot_full`, `ui.widget_invalid`,
`permission.denied` and `trust.required` keep their Phase 0 meaning.
