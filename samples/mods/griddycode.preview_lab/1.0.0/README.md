# Preview Lab

The developer-mode sample. It is safe to load from the normal `mods`
folder, but the interesting path is the development folder:

```text
user://mods_dev/griddycode.preview_lab/1.0.0/
  manifest.json
  main.lua
  lib/build.lua
```

On Windows `user://` is `%APPDATA%\Godot\app_userdata\Qorix\`.

## Try hot reload

1. Copy this `1.0.0` folder to
   `%APPDATA%\Godot\app_userdata\Qorix\mods_dev/griddycode.preview_lab/1.0.0`.
2. Start Qorix with `--mod-dev` (a debug build already enables developer
   mode). If the mod is blocked, open **View → Mods…** and grant consent.
3. Open the **Preview Lab** dock or run **Preview Lab: Ping** from the command
   palette.
4. Edit `lib/build.lua` and change `label = "dev-1"` to `"dev-2"`. Save.
5. Within about a second the mod reloads. The panel shows the new build label,
   and the activation counter increases because storage survives the reload.
6. Edit `main.lua` (for example the hint text) and save to reload again.

The activation counter is stored under the mod's `user://mod_data` folder and is
not reset by a reload. **Preview Lab: Reset Activation Count** resets it to 1.

## What it demonstrates

- `editor.storage` data that survives deactivate → activate.
- A manifest-declared setting (`greeting`) read with `editor.settings.get`.
- A dock panel, a command, a notification and a logged event.
- `require("build")` loading a second file from `lib/`, which is watched too.

Developer mode watches only `mods_dev`, never the installed `mods` folder.
Manifest changes are picked up on restart or with **Reload** on the Mods page;
hot reload watches `main.lua` and `lib/**/*.lua` only.
