# Writing a partial-UI mod

This guide matches the code and the three samples under `samples/mods/`. Read
`api-reference.md` for every function and permission.

## Package layout

```
user://mods/<id>/<version>/
  manifest.json
  main.lua
  lib/...        (optional modules loaded with require)
  content/...    (optional tables loaded with editor.content.load)
  assets/...     (optional text loaded with editor.assets.read_text)
```

`manifest.json`:

```json
{
  "schema": 1,
  "id": "example.hello",
  "name": "Hello",
  "version": "1.0.0",
  "api": 1,
  "min_editor": "1.3.0",
  "entry": "main.lua",
  "author": "You",
  "description": "What this mod does.",
  "license": "MIT",
  "permissions": ["core"]
}
```

Permissions are declared, then consented. `core` needs no consent. The high-risk
capabilities (`files.*`, `run`, `terminal.write`) also require workspace trust.
Missing consent leaves the mod `blocked`; use **View → Mods…** to review and
grant it. The native guard checks the active session set, not
`editor.permissions.has()` (that call is display only).

## Lifecycle

Top-level code runs once when the mod activates. Register commands, event
handlers and partial UI there. An optional global `deactivate()` runs on disable,
reload or quit; the host also drops commands, subscriptions, runtime keybindings
and UI mounts automatically.

```lua
local mount_id = nil

mount_id = editor.ui.mount("right", {
  type = "panel", id = "dock", title = "Hello",
  children = {
    {type = "label", id = "message", text = "Hello from a mod"},
    {type = "button", id = "greet", text = "Greet"},
  },
})

editor.ui.on("greet", "click", function()
  editor.ui.notify("Hello!", "info")
end)

function deactivate()
  if mount_id then
    editor.ui.unmount(mount_id)
    mount_id = nil
  end
end
```

Long work is cooperative: use `editor.async(function() ... end)` and
`editor.wait(ms)` inside it. Do not busy-wait; the instruction budget kills the
task. `editor.after/every` return timer handles and `editor.cancel` removes them.

## Settings

Declare settings in the manifest or at runtime. They appear on the Mods page and
are available through `editor.settings.get`.

```lua
local label = editor.settings.get("label", "Hello")

local ok, err = editor.settings.declare({
  {key = "compact", type = "bool", default = false, label = "Compact mode"},
})
```

The Mods page writes through the same validated store. There is no host
`settings.changed` event yet; re-read the value on the next user action.

## Documents

Use `editor.docs.active()` or `editor.docs.list()`. A document id is stable for
the lifetime of that tab and is never reused. The Lua side never sees an engine
object.

```lua
local id = editor.docs.active()
if id ~= 0 then
  local text = editor.docs.text(id)
  local words = 0
  for _ in string.gmatch(text, "%S+") do words = words + 1 end
  editor.ui.notify("Words: " .. tostring(words), "info")
end
```

Columns are codepoint columns. An edit that would split a combining cluster is
rejected with `doc.column_splits_grapheme`; the error carries the nearest valid
columns. `set_text`, `insert`, `replace`, `set_cursor`, `set_selection`, `save`
and `close` all mark the document dirty/clean through the editor's normal path.
`close` refuses a dirty document unless `force=true`. Unsaved documents cannot be
saved by a mod (`doc.unsaved`).

Host document events are coalesced where appropriate:

```
document.opened, document.activated, document.changed (100 ms),
document.dirty_changed, document.saved, document.closed
```

## Files and workspace

Every path is workspace-relative and must stay inside the open folder. Absolute
paths, drive letters and `..` fail with `path.invalid`; there is no path that
resolves outside the root. A missing workspace returns `workspace.required`.
`files.*` need explicit consent and trust.

```lua
if not editor.workspace.has_workspace() then
  editor.ui.notify("Open a folder first.", "warning")
  return
end

local bytes, err = editor.files.write("notes/today.txt", "Learned about mods.")
if bytes == nil then
  editor.log.error("write failed: " .. tostring(err.code))
end
```

`files.delete` requires `confirmed=true`. Ask first:

```lua
editor.dialogs.confirm({
  title = "Delete note?",
  message = "This cannot be undone.",
}, function(result)
  if result.confirmed then
    editor.files.delete("notes/old.txt", {confirmed = true})
  end
end)
```

The workspace root is host-owned. A mod cannot call `workspace.open_folder`:
ask the user to open the folder themselves from the editor's File menu, then
listen for `workspace.opened`.

Writes are atomic and capped at 8 MiB. `list` is sorted, caps at 2000 entries and
skips `.git`, `node_modules`, caches and build folders. Deleting a non-empty
folder fails with `module.not_empty`.

## Partial UI

The catalog is declarative; no `Control` crosses the boundary. Containers:
`panel`, `vbox`, `hbox`, `scroll`. Leaves: `label`, `richtext`, `button`,
`checkbox`, `slider`, `spin`, `progress`, `separator`, `divider`, `spacer`,
`input`, `text`, `option`.

```lua
local spec = {
  type = "panel",
  id = "dock",
  title = "Status",
  children = {
    {type = "label", id = "status", text = "Ready"},
    {type = "hbox", children = {
      {type = "button", id = "run", text = "Run"},
      {type = "button", id = "stop", text = "Stop"},
    }},
  },
}
```

Limits: 200 widgets, 8 nesting levels, four mounts per slot, six modals, eight
handlers per event. `update` requires the same root type; children are reconciled
in place, so a label you update keeps its node and scroll position. Removed
children are freed.

Widget ids become `<mod_id>.<local_id>`. A button emits from its own local id;
`mount_id` is the root panel's id, not a prefix for its children. Pass the
child's local id (or the full `<mod_id>.<local_id>`):

```lua
local mount_id = editor.ui.mount("right", spec)
editor.ui.on("run", "click", do_run)
```

Events: `click` (button), `submit` (input, Enter), `change` (checkbox/slider/spin
or input focus loss), `select` (option). `ui.dialog` opens a modal; `close_dialog`
closes it; `ui.focus` focuses a widget; `ui.theme.token` reads the active theme.
`ui.layout.set_visible` hides a core panel, but needs the `ui.layout` permission;
the original visibility is restored when the mod deactivates.

Dialogs receive values:

```lua
editor.dialogs.prompt({
  title = "Save a note",
  message = "Where should it go?",
  default = "",
  placeholder = "Text",
}, function(result)
  if result.confirmed then
    editor.ui.notify("You typed " .. tostring(result.value), "info")
  end
end)
```

## Run and clipboard

`editor.run.active()`, `run.file(path)`, `run.stop()` are accepted requests
executed on the next frame; `run.is_running()` is immediate. A run needs `run`
consent and a trusted workspace; the request is refused by the native guard, not
silently ignored.

Clipboard reads/writes are separate permissions and capped at 1 MiB. Do not use
the clipboard as storage; use `editor.storage` for persisted data.

## Events

Host events are listed in `src/features/mods/events/event_bus.gd` and documented in the
[API reference](api-reference.md). A mod may subscribe to them and to its own
`mod.<its id>.*` namespace; it cannot emit host events or subscribe to another
mod's events.

```lua
editor.events.on("document.changed", function(payload)
  editor.log.info("changed: " .. tostring(payload.id))
end)
```

## Debugging

Run with `--mod-dev` (or use a debug build) to enable the reload button on
failure cards and on the Mods page. Every mod has a log ring buffer; **View →
Mods… → Log** shows it. Failures are isolated: an activation error marks only
that mod failed, and a runtime task that exceeds its budget kills only that task.
`--safe-mode` / `--no-mods` starts with the mod set disabled for the session.
