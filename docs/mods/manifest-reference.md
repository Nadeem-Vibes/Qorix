# Manifest reference — schema 1

Every mod is a folder:

```text
user://mods/<id>/<version>/
  manifest.json     required
  main.lua          required unless "entry" names another file
  lib/              optional Lua modules loaded with require()
  content/          optional Lua content loaded with editor.content.load()
  assets/           optional text and image assets
```

`user://` is `%APPDATA%\Godot\app_userdata\Qorix\` on Windows,
`~/.local/share/godot/app_userdata/Qorix/` on Linux and
`~/Library/Application Support/Qorix/` on macOS. Developer copies
can instead live under `user://mods_dev/<id>/<version>/`.

`manifest.json` is at most 256 KiB. Validation reports every problem at once
instead of stopping at the first. Unknown top-level fields are rejected so a
typo such as `permission` cannot silently drop a capability request.

## Fields

| Field | Type | Required | Rules |
| --- | --- | --- | --- |
| `schema` | integer | yes | Must be `1`. |
| `id` | string | yes | Reverse-DNS id: 3–64 characters, lowercase letters, digits, `.`, `_` or `-`, at least two segments. Must equal the folder name. |
| `name` | string | yes | 1–80 characters, shown in the Mods page and host chrome. |
| `version` | string | yes | `MAJOR.MINOR.PATCH`, for example `1.0.0`. The highest valid version folder wins. |
| `api` | integer | yes | Must be `1` in the Developer Preview. |
| `min_editor` | string | yes | Minimum Qorix version, for example `1.4.0`. |
| `max_editor` | string | no | Optional maximum editor version; must not be lower than `min_editor`. |
| `entry` | string | yes | Relative `.lua` path inside the mod folder, normally `main.lua`. Maximum 2 MiB. |
| `author` | string | yes | 1–120 characters. |
| `description` | string | yes | 1–500 characters. |
| `license` | string | no | Up to 200 characters. A missing license produces a warning, not an error. |
| `homepage` | string | no | Must start with `https://`, maximum 300 characters. |
| `permissions` | array | yes | Permission names from the catalogue below. `core` is added automatically. Duplicates are rejected. |
| `dependencies` | object | no | Map of mod id to version range. All must be installed and active. |
| `optional` | object | no | Map of mod id to version range. Loaded before the mod when present, but never blocks it. |
| `conflicts` | array | no | Mod ids that cannot be active together. Self-conflicts and duplicates are rejected. |
| `settings` | array | no | Declarations shown in the Mods page; see below. |
| `assets` | object | no | `icon` may name a relative `png`, `jpg`, `webp` or `svg` file. |

Version ranges use the same syntax as `SemverRange`: an exact version, a
caret/tilde range, or comparisons such as `>=1.2.0 <2.0.0`.

```json
{
  "schema": 1,
  "id": "example.counter",
  "name": "Counter",
  "version": "1.0.0",
  "api": 1,
  "min_editor": "1.4.0",
  "entry": "main.lua",
  "author": "Example",
  "description": "A minimal counter with a declared setting.",
  "license": "MIT",
  "permissions": ["core"],
  "dependencies": {"example.base": ">=1.0.0 <2.0.0"},
  "settings": [
    {"key": "step", "type": "int", "default": 1, "label": "Step", "min": 1, "max": 100}
  ]
}
```

## Settings

| Setting field | Type | Required | Rules |
| --- | --- | --- | --- |
| `key` | string | yes | Lowercase letters, digits and `_`, at most 64 characters, unique per manifest. |
| `type` | string | yes | One of `bool`, `int`, `float`, `string`. |
| `default` | matching type | yes | Must match `type`; numeric bounds and options are checked. |
| `label` | string | no | 1–120 characters, defaults to `key`. |
| `min` | number | no | Inclusive lower bound for `int` or `float`. |
| `max` | number | no | Inclusive upper bound for `int` or `float`. |
| `options` | array | no | Objects with `display` and `value`; values are string, number or boolean. |

Values are stored per mod under `user://mod_data/<id>/settings.json`. A mod can
declare additional runtime settings with `editor.settings.declare(schema)`; a
duplicate key with a different definition fails with `settings.conflict`.

## Permissions

The catalogue is `src/features/mods/mod_permissions.gd`. `core` is always present and
needs no prompt. Every other available permission needs explicit consent; the
`+ trust` entries also need a trusted workspace at call time.

| Permission | Risk | Consent | Available | Grants |
| --- | --- | --- | --- | --- |
| `core` | low | install | yes | events, commands, partial UI, storage, progress, assets, timers |
| `documents.read` | medium | explicit | yes | document text, cursor, selection, guide and exercise reads |
| `documents.write` | medium | explicit | yes | edits, open, save, close, guide reset, exercise retry/advance |
| `files.read` | high | explicit + trust | yes | workspace files |
| `files.write` | high | explicit + trust | yes | workspace files |
| `workspace.read` | medium | explicit | yes | workspace listing and root |
| `run` | critical | explicit + trust | yes | execute through RunService |
| `terminal.read` | high | explicit | yes | observe terminal output |
| `terminal.write` | critical | explicit + trust | yes | inject terminal input |
| `ui.shell` | high | explicit | yes | exclusive shell takeover with host chrome |
| `ui.layout` | low | explicit | yes | hide/show core panels |
| `clipboard.write` | low | explicit | yes | clipboard writes |
| `clipboard.read` | high | explicit | yes | clipboard reads |
| `settings.read` | low | explicit | yes | read global editor settings |
| `input.observe` | critical | not in v1 | **no** | raw keystrokes — reserved |
| `network` | critical | not in v1 | **no** | network access — reserved |

A manifest that declares a reserved permission is rejected with
`manifest.unknown_permission`; it cannot be installed "for later". Sensitive
consent is bound to the package hash and version. If a later version adds a
permission, the user is asked again.

## Dependencies, optional modules and conflicts

`dependencies` and `optional` are objects keyed by mod id. A dependency that is
missing, has the wrong version, or is itself blocked blocks the dependent mod
with `dependency.missing` or `dependency.version`; the rest of the mod set still
loads. A cycle blocks every mod in the cycle with `dependency.cycle`. Conflicts
are symmetric in effect: if both sides are installed, neither is activated.

`optional` entries are ordered before the mod when present. They are not
required to satisfy activation and a missing optional mod is not an error.

## Assets

`assets.icon` is decorative. The API can read text assets with
`editor.assets.read_text(path)` (4 MiB cap); only `.lua` files can be loaded as
modules or content. Paths are relative, use `/`, and cannot escape the mod
folder.

## Validation and compatibility

`Manifest.read_manifest(path, {"root": folder})` validates the file and returns
`{ok, manifest, errors, warnings}`. Installation keeps the package even when
`min_editor`/`max_editor` do not match the running editor; activation is blocked
with `manifest.version_range` until the user updates either side. Change the
manifest during hot reload? **No** — developer hot reload watches `main.lua` and
`lib/**/*.lua`. Restart or use **Reload** on the Mods page to re-read a
manifest.

## Related documents

- [`api-reference.md`](api-reference.md) — the frozen native surfaces.
- [`developer-guide.md`](developer-guide.md) — a walkthrough from folder to
  running mod.
- [`../archive/mod-platform/api-reference-phase2.md`](../archive/mod-platform/api-reference-phase2.md) — partial UI widget
  catalog and document/file semantics.
- [`samples/mods/README.md`](../../samples/mods/README.md) - runnable
  manifests.
