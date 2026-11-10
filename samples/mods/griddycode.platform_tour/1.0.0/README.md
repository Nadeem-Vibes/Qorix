# Platform Tour

A guided lesson and self-check for the frozen API 1.0 Developer Preview. It is
the sample to start with after the three clean-install samples: it shows a
manifest, a consent-gated permission, a hybrid exercise and a dock that reports
whether the core services are live.

The mod declares only `documents.read` and `documents.write`. It has no file,
workspace, run or shell permissions.

## Install

1. Copy this `1.0.0` folder to:

   ```text
   user://mods/griddycode.platform_tour/1.0.0/
   ```

   On Windows `user://` is
   `%APPDATA%\Godot\app_userdata\Qorix\`; on Linux it is
   `~/.local/share/godot/app_userdata/Qorix/`.

   ```powershell
   $data = Join-Path $env:APPDATA "Godot\app_userdata\Qorix"
   $destination = Join-Path $data "mods\griddycode.platform_tour\1.0.0"
   New-Item -ItemType Directory -Force -Path $destination | Out-Null
   Copy-Item -Recurse -Force "samples\mods\griddycode.platform_tour\1.0.0\*" $destination
   ```

2. Start Qorix, open **View → Mods…**, select **Platform Tour** and read
   the consent card. Grant `documents.read` and `documents.write`.

3. The mod is blocked while consent is missing and activates as soon as both
   permissions are granted. The **Platform Tour** dock appears on the right.

## Run the lesson

1. Click **Start lesson** (or run **Platform Tour: Start Lesson** from the
   command palette).
2. The mod creates an untitled Lua document and starts a hybrid exercise.
3. Type the manifest id exactly:

   ```lua
   id = "example.hello"
   ```

   Ghost text shows the next character. With **Strict typing** off, mistakes are
   marked but do not stop the exercise; turn it on to require exact input.
   **Check answer** applies to the permissions phase; during typing it explains
   that the lesson advances automatically.
4. The exercise advances to the permissions phase. On the next line add:

   ```lua
   permissions = { "core", "documents.read" }
   ```

5. Click **Check answer**. The lesson passes when the document contains both
   `permissions` and `documents.read`.

**Retry** restores the checkpoint and starts the typing phase again. **Reset**
stops the exercise, clears the completion count and removes the stored
self-check result.

## Self-check

Click **Self-check** (or run **Platform Tour: Run Self-check**). It probes
eight surfaces with real calls:

| Check | What it proves |
| --- | --- |
| `storage` | set, get and delete survive inside the mod sandbox |
| `progress` | set, increment, get and reset agree |
| `settings` | the manifest-declared setting can be read and written |
| `commands` | a mod command can be registered and removed |
| `events` | a subscription can be created and released |
| `documents` | a scratch document can be created, read and closed |
| `permissions` | `documents.read` is actually granted |
| `ui` | the dock mounted |

A GUI run should report **8/8 passed**. The `ui` check fails if the dock service
is unavailable (for example a stripped headless composition), and the
`documents` check fails if consent was not granted. The result is stored so it
survives a reload.

## Hot reload drill

`content/*.lua` is **not** watched. The watched files are `main.lua` and
`lib/**/*.lua`, so the drill edits `lib/build.lua`:

1. Copy this folder to
   `%APPDATA%\Godot\app_userdata\Qorix\mods_dev/griddycode.platform_tour/1.0.0`.
2. Start with `--mod-dev` and grant the same two permissions.
3. Note the **Build** label and activation count in the dock.
4. Change `label = "tour-1"` to `"tour-2"` in `lib/build.lua` and save.
5. The mod reloads within about a second. The build label changes and the
   activation count increases because storage survives the reload.

Editing the lesson file under `content/` needs a restart or **Reload** on the
Mods page instead.

## Troubleshooting

- **Blocked, no dock:** grant both document permissions on the Mods page.
- **"Lesson unavailable":** the content file did not load; check the mod log
  for `Platform Tour: could not load the lesson`.
- **Self-check 7/8 with `ui` failed:** the dock could not mount in this build;
  the rest of the API still works.
- **Self-check 7/8 with `documents` failed:** `documents.write` was not granted.
- **Hot reload does nothing:** confirm the copy is under `mods_dev`, the editor
  was started with `--mod-dev`, and the edited file is `main.lua` or under
  `lib/`.

See [`../../README.md`](../../README.md) for the full sample index and
[`../../../../docs/mods/developer-guide.md`](../../../../docs/mods/developer-guide.md)
for the API walkthrough.
