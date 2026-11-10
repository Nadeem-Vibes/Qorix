# Developer guide — Qorix mod platform (Developer Preview)

This guide takes you from an empty folder to a running, reloadable mod against
the frozen API 1.0. It assumes the opt-in Developer Preview build (or a local
debug build). Distribution, signatures and the public mod feed are **not** part
of the preview; see [`known-issues.md`](known-issues.md).

## 1. What you need

- Qorix `1.4.0` or newer.
- A Windows or Linux desktop build. Linux is supported on a best-effort basis
  during the preview; Windows is the reference platform.
- A text editor. Qorix itself is fine.
- For the five-lesson Python course only: Python and a trusted workspace
  folder. The Platform Tour needs only document consent.

A debug build enables developer mode automatically. A release build enables it
when launched with `--mod-dev`:

```text
Qorix.exe --mod-dev
```

The Mods page (View → Mods…, or `mods.manage` in the command palette) shows the
preview label and whether developer mode and hot reload are on.

## 2. Where files live

```text
user://mods/<id>/<version>/        installed mods; never watched
user://mods_dev/<id>/<version>/    developer copies; watched for hot reload
user://mod_data/<id>/              storage, progress and settings per mod
```

On Windows `user://` is
`%APPDATA%\Godot\app_userdata\Qorix\`. On Linux it is
`~/.local/share/godot/app_userdata/Qorix/`.

Keep the version folder (`1.0.0`) even while developing: discovery selects the
highest valid version per id, and the folder name must match the manifest id.

## 3. Hello, mod

Create `user://mods_dev/example.hello/1.0.0/manifest.json`:

```json
{
  "schema": 1,
  "id": "example.hello",
  "name": "Hello",
  "version": "1.0.0",
  "api": 1,
  "min_editor": "1.4.0",
  "entry": "main.lua",
  "author": "You",
  "description": "A first developer-preview mod.",
  "license": "MIT",
  "permissions": ["core"]
}
```

Create `main.lua` next to it:

```lua
local mount_id = nil

local function greet()
  editor.ui.notify("Hello from a mod", "info")
  editor.log.info("greet ran")
end

mount_id, mount_error = editor.ui.mount("right", {
  type = "panel",
  id = "dock",
  title = "Hello",
  children = {
    { type = "label", id = "line", text = "Developer Preview" },
    { type = "button", id = "greet", text = "Greet" },
  },
})

if mount_id == nil then
  editor.log.error("mount failed: " .. tostring(mount_error and mount_error.code))
else
  -- Child ids are local: <mod_id>.<local_id>, not <mount_id>.<local_id>.
  editor.ui.on("greet", "click", greet)
end

function deactivate()
  if mount_id ~= nil then
    editor.ui.unmount(mount_id)
    mount_id = nil
  end
end
```

Start with `--mod-dev`. The mod is already active when the editor appears. If
consent is missing, open View → Mods…, review the requested capabilities and
grant consent. `deactivate()` is required for clean teardown: the host calls it
before a reload, a disable or a quit. Unmount widgets and release handles there;
the host also cleans registrations, but an explicit `deactivate` makes intent
clear and avoids leaked callbacks during a reload.

## 4. Hot reload

Developer mode watches exactly:

```text
main.lua
lib/**/*.lua
```

Recursive `lib` modules are included. On save the watcher waits for a short
quiet window, then deactivates and reactivates the mod. Storage, progress and
settings are flushed and reloaded, so a counter survives:

```lua
local count = (editor.storage.get("activations", 0) or 0) + 1
editor.storage.set("activations", count)
```

Session state is not preserved: local Lua values, widget mounts and command
registrations are rebuilt from the new source. A manifest change is **not**
hot-reloaded; restart or press **Reload** on the Mods page. Installed mods under
`user://mods` are never watched, even in developer mode. This is deliberate:
hot reload is a development tool, not a feature of released packages.

The complete runnable example is
`samples/mods/griddycode.preview_lab/1.0.0/` in the repository.

The guided tour at `samples/mods/griddycode.platform_tour/1.0.0/` is the
end-to-end check for this guide: it declares only `documents.read` and
`documents.write`, runs a hybrid manifest lesson, probes eight core surfaces
from its own dock and carries the same build-label/activation-counter drill for
hot reload. Its README is the shortest manual test script for the preview.

## 5. Commands, settings and events

Register commands as soon as the mod activates:

```lua
local id, err = editor.commands.register({
  id = "example.hello.greet",
  label = "Hello: Greet",
  category = "Mods",
  handler = greet,
})
if id == nil then
  editor.log.error("register failed: " .. tostring(err and err.code))
end
```

Command ids are `<mod_id>.<local>`. A mod cannot execute a host command or
another mod's command. Settings declared in the manifest are available through
`editor.settings.get`; `editor.settings.set` writes them to the mod's data
folder. Subscribe to host events with `editor.events.on("document.changed", fn)`
and remember that events are coalesced and delivered on the next tick.

## 6. Permissions and trust

Declare only what you use. `core` covers partial UI, commands, events, storage,
progress, settings, timers and module loading. Everything else needs explicit
consent. Some calls need a trusted workspace as well:

| Call family | Permission | Workspace trust |
| --- | --- | --- |
| `editor.docs.*` reads | `documents.read` | no |
| `editor.docs.*` writes | `documents.write` | no (`docs.open` also checks `files.read`) |
| `editor.files.*` | `files.read` / `files.write` | yes |
| `editor.workspace.*` | `workspace.read` | no |
| `editor.run.*` | `run` | yes |
| `editor.guide.*` / `editor.exercise.*` | `documents.read` / `documents.write` | only for run-backed validation |
| `editor.ui.shell.*` | `ui.shell` | no |

`editor.permissions.has(name)` is a display helper. Do not use it as a security
decision; the native call checks consent again and can refuse even if the helper
returned true. A consent record is bound to the package hash. Editing files
under `user://mods` can invalidate an existing record, which is another reason
to develop under `user://mods_dev`.

## 7. Common failures

| Symptom | Cause | Fix |
| --- | --- | --- |
| Mod missing from the Mods page | Wrong folder depth, id mismatch, invalid manifest | Folder must be `mods_dev/<id>/<version>/manifest.json`; read the error on the Mods page or the log |
| `manifest.version_range` | `api` is not 1, or `min_editor`/`max_editor` excludes this build | Update the manifest or the editor |
| `permission.consent_required` | Sensitive permission not consented | Review and grant consent in View → Mods… |
| `trust.required` | File/run/terminal call without a trusted workspace | Open the folder as a workspace and mark it trusted |
| `module.not_found` | `require` path does not resolve under `lib/` | Use `require("name")`; `.lua` is added automatically |
| Mod stops after an edit | Lua syntax error or failed activation | Open the failure card → **Open log** |
| Hot reload does nothing | Mod is installed under `mods`, not `mods_dev`, or developer mode is off | Move the folder and start with `--mod-dev` |

Runtime failures are isolated: a failing mod is deactivated, the failure card
offers **Open log**, **Disable** and (in developer mode) **Reload**, and the
rest of the editor keeps running. Safe mode (`--safe-mode` or `--no-mods`)
starts without mods for one session. The crash-loop guard disables a mod set
after two short sessions in a row, so a bad mod cannot lock you out.

## 8. Testing a mod

- Run the headless suite before shipping changes:
  `godot --headless --path . --script res://tests/test_runner.gd`.
- Keep `main.lua` and every `lib` module free of side effects at load time when
  possible; activation is the only guaranteed point.
- Exercise both the grant and deny paths in the Mods page. A blocked mod must
  still be visible, explain what it needs, and unblock after consent.
- Test in a throwaway `APPDATA` (Windows) or `XDG_DATA_HOME` (Linux) for a
  genuinely clean install. `samples/mods/README.md` lists the copy commands.
- Run the Platform Tour as a smoke test: confirm it is blocked before consent,
  grant both document permissions, finish the manifest lesson (the typing phase
  advances by itself; **Check answer** only validates the permissions phase) and
  run the self-check. A desktop build should report **8/8 passed**.
- Quote exact error codes in bug reports; they are stable API 1.0 names.

## 9. Packaging a developer copy

There is no public distribution flow in the preview. To share a build with a
tester, zip the version folder so the archive contains `<id>/<version>/...`, and
have them extract it under `user://mods/`. They must review and grant the same
permissions. Do not overwrite `user://mod_data` when replacing a version unless
you intend to reset storage, progress and settings.

The preview build itself is opt-in: see
[`preview-packaging.md`](preview-packaging.md). It is labeled as a preview in
the app and the Mods page, and it still validates archives before extraction.

## 10. Getting help

Read [`known-issues.md`](known-issues.md) for current limitations, then use the
feedback channel in [`feedback.md`](feedback.md). Include the Qorix
version, OS, mod id/version, exact error code, the relevant log lines and the
smallest `main.lua` that reproduces the problem.
