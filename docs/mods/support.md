# Mod platform support — 1.0

This is the user-facing support policy for the Qorix mod platform in 1.0.
It covers installation, permissions, updates, recovery and what to include in a
bug report.

## Supported platforms

Windows 10/11 x86_64 is the supported platform. Linux and macOS are preview:
the editor runs, but the desktop mod matrix has not been signed off. Android,
iOS and Web are not 1.0 targets.

A mod that works on Windows may fail elsewhere because of path handling, native
toolchains or platform fonts. If you report a platform issue, include the
platform name and the exact build label from **View → Mods…**.

## Install and remove

Copy a package folder to `<editor data>/mods/<id>/<version>/`, or use **Mods… →
Import package…** for a `.gcm`/`.zip`. The folder name must match the manifest
`id`, and the version folder must be `MAJOR.MINOR.PATCH`.

The data directory is `%APPDATA%\Godot\app_userdata\Qorix\` on
Windows and `~/.local/share/godot/app_userdata/Qorix/` on Linux.
The Mods page is the source of truth for installed, blocked and failed mods.

Uninstall removes every installed version and revokes consent. Mod data under
`user://mod_data/<id>` is kept unless you explicitly delete it, so reinstalling
can resume where you left off.

## Permissions and consent

A mod declares permissions in its manifest. Sensitive permissions are blocked
until you grant them on the Mods page. Granting is all-or-nothing; denying
leaves the mod installed but blocked. An update that adds permissions asks
again. A changed publisher key is never trusted silently: review and replace
the pinned key only when you know the publisher rotated it.

The sandbox is capability-based, not a separate operating-system user. A mod
with `files.write` and a trusted workspace can write files you can write. Read
the consent card before granting.

## Recovery

- **Panic exit** — `Ctrl+Alt+Shift+Esc` exits the active mod shell immediately
  and restores the editor layout.
- **Safe mode** — start with `--safe-mode` or `--no-mods` to load no mods for one
  session. The registry is untouched, so the next normal launch tries again.
- **Crash loop** — two short sessions that end without a clean exit disable the
  previous mod set. The Mods page explains which set was disabled and why.
- **Reload** — fixes a content edit; it does not bypass consent.
- **Rollback** — after an update, the installed card can restore the previous
  version. The previous folder remains on disk until it is replaced.

If the editor will not start, move `user://mods` aside and start normally. Do
not delete `user://mod_data` unless you want to lose mod state.

## Legacy languages and themes

Lua files in `user://langs` and `user://themes` predate mods and still load
through the original editor services. They are not managed mods: they have no
permissions, consent, sandbox, update or uninstall action. The Mods page lists
them so the difference is visible. Keep backups before editing them.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Mod missing after copy | Folder shape `<id>/<version>/manifest.json`; id and version valid; scan error on the Mods page |
| Mod blocked | Required permissions are not granted, or consent was denied |
| Command missing | Mod is active, not blocked or failed; command palette category **Mods** |
| UI slot full | Each side slot has a small mount budget; close another mod panel |
| Shell refuses to open | Another mod owns the shell, or the layout is invalid |
| Lesson can't write files | Open and trust a workspace folder; grant file and workspace permissions |
| Lesson can't compile C++ | `g++` or `clang++` must be on `PATH`; otherwise the course uses text checks |
| Settings reset | Settings are keyed by mod id and version range; check the Mods page |
| Update asks for consent again | The package grew permissions or the publisher key changed |

## Reporting a problem

Include:

1. Editor version and build label (including preview/developer channel).
2. Platform and whether it is headless.
3. Mod id, version, publisher fingerprint and signature state.
4. The Mods page status and the mod's log lines.
5. What you expected and what happened; keep the smallest project or lesson
   that reproduces it.
6. For accessibility issues: input method, screen reader, focus order and the
   control that failed.

Never send a publisher private key, a session token or an unredacted mod data
folder. Diagnostic exports should contain mod ids, versions, hashes and error
codes, not file contents.

## Compatibility promise

API 1.0 is frozen. A 1.x editor keeps the documented API methods, permission
names, error codes and widget catalog. New capabilities would require API 2 and
an explicit migration. A mod may still break if it depends on an undocumented
engine detail; report that as a bug rather than relying on it.

## Known limitations

- One editor viewport per shell.
- No network or raw input permission in API 1.
- Accessibility audit is mechanical; screen-reader and IME passes are manual.
- Linux and macOS are preview platforms for this release.
- Legacy language/theme content is inventoried but not migrated.
- Mods run in-process with capability checks; the platform is not an OS sandbox.
