# Sample mods

These are runnable documentation for the frozen API 1.0. They are not installed
automatically. Copy a version folder under the editor's data directory, restart
or press **Reload** on the Mods page, then review and grant the requested
permissions.

On Windows the data directory is
`%APPDATA%\Godot\app_userdata\Qorix\`. On Linux it is
`~/.local/share/godot/app_userdata/Qorix/`.

## Clean-install samples (Gate F)

| Sample | What it teaches | Permissions |
| --- | --- | --- |
| `griddycode.hello_dock` | Partial UI dock, a command, a setting, a notification and a storage-backed counter | `core` |
| `griddycode.word_count` | Host events, document reads and an in-place widget update | `documents.read` |
| `griddycode.note_taker` | Prompt dialog, workspace-relative file write and trust | `files.read`, `files.write`, `workspace.read` |

Copy the three clean-install samples at once (PowerShell):

```powershell
$data = Join-Path $env:APPDATA "Godot\app_userdata\Qorix"
foreach ($id in "griddycode.hello_dock", "griddycode.word_count", "griddycode.note_taker") {
    $destination = Join-Path $data "mods\$id\1.0.0"
    New-Item -ItemType Directory -Force -Path $destination | Out-Null
    Copy-Item -Recurse -Force "samples\mods\$id\1.0.0\*" $destination
}
```

Restart Qorix. **Hello Dock** activates immediately. **Word Count** asks
for `documents.read`; **Note Taker** asks for its three file/workspace
permissions. Open **View → Mods…**, read the consent card, grant the
permissions and confirm the dock or command appears. Denying consent leaves the
mod installed but blocked; that is the intended least-privilege path.

**Note Taker** also needs an open, trusted workspace folder; it refuses to write
without one. **Word Count** works with no workspace once `documents.read` is
granted.

## Guided lesson: Platform Tour

`griddycode.platform_tour` is the quickest way to test the whole platform from
the user side. It asks only for `documents.read` and `documents.write`, then:

- creates an untitled Lua document and runs a hybrid lesson: type a manifest
  `id`, then add a `permissions` line and check it;
- runs an eight-point self-check over storage, progress, settings, commands,
  events, documents, permissions and the UI;
- reports a build label and activation counter, so the same sample doubles as
  the hot reload drill.

Follow its [README](griddycode.platform_tour/1.0.0/README.md). It is blocked
until both document permissions are granted, which is the intended consent
path. The self-check should report **8/8 passed** in a desktop build.

## Developer-mode sample: Preview Lab

`griddycode.preview_lab` is the hot-reload test bed. It uses only
`core`, stores an activation counter and loads `lib/build.lua` through
`require`. Follow its
[README](griddycode.preview_lab/1.0.0/README.md) after copying it to
`user://mods_dev/griddycode.preview_lab/1.0.0/` and starting with `--mod-dev`.

Key check: edit `lib/build.lua`, save, and watch the build label change while
the activation counter increments. Storage survives the deactivate/activate
cycle; Lua locals and widgets do not.

## Reference course

`griddycode.python_journey` is the five-lesson reference mod. It needs
`ui.shell`, `documents.read`, `documents.write`, `run`, `core` and a trusted
workspace with Python available. Its
[README](griddycode.python_journey/1.0.0/README.md) covers the course and the
manual test checklist.

## Teaching course: C++ Journey

`griddycode.cpp_journey` is a five-lesson C++ course built on the same hybrid
learning engine: includes and `main`, variables, types, conditionals and loops.
It needs `ui.shell`, document/file/workspace permissions and `run`; freeform
work is compiled with the editor's C++ profile (`g++` or `clang++`). Without a
trusted workspace or compiler it falls back to text checks and explains why.
Its [README](griddycode.cpp_journey/1.0.0/README.md) has the install steps,
lesson table, shortcuts and validation matrix. The Python course remains the
reference mod; install both if you want to compare them.

## Folder shape

```text
<id>/<version>/
  manifest.json
  main.lua
  lib/        optional require() modules
  content/    optional editor.content.load() modules
  assets/     optional text/image assets
```

The folder name must match the manifest `id`, and the version folder must be a
valid `MAJOR.MINOR.PATCH`. Discovery selects the highest valid version per id.
Do not put a sample directly under `mods/` without the id/version layers.

## Testing a sample after editing

- Hot reload applies only to a copy under `mods_dev` in developer mode.
- For an installed sample, edit the file, restart, or press **Reload** on the
  Mods page. The package hash changes, so a sensitive mod may ask for consent
  again.
- Run the headless gate before sharing a changed sample:
  `godot --headless --path . --script res://tests/test_runner.gd`.
- Use a throwaway data directory when testing a clean install; `user://mod_data`
  keeps counters and settings between runs.

See [`../../docs/mods/developer-guide.md`](../../docs/mods/developer-guide.md)
for the full walkthrough and
[`../../docs/mods/known-issues.md`](../../docs/mods/known-issues.md)
for preview limitations.
