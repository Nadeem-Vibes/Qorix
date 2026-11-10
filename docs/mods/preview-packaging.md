# Preview packaging

Qorix ships an **opt-in developer preview**, not a public release. The preview
is clearly labeled in the app, in the download notes and in the docs, and it is
built with a custom export feature so a normal release cannot accidentally
inherit preview behavior.

## Opt-in switches

| Switch | Where | Effect |
| --- | --- | --- |
| `mod_preview` | Export preset `custom_features` | Enables `OS.has_feature("mod_preview")`, which sets `ModManager.preview_build` |
| `--mod-preview` | Runtime command line | Same label/notice for a local build without a custom feature |
| `--mod-dev` | Runtime command line | Developer mode and hot reload; debug builds enable this automatically |

`preview_build` does **not** enable distribution, signatures or a mod feed. It
adds the in-app notice and the Mods-page label. Developer mode and preview mode
are independent.

## Presets

`export_presets.cfg` contains:

| Preset | Platform | Feature | Output |
| --- | --- | --- | --- |
| `Windows Developer Preview` | Windows Desktop | `mod_preview` | `Builds/Preview/Windows/Qorix-Preview.exe` |
| `Linux/X11 Developer Preview` | Linux/X11 | `mod_preview` | `Builds/Preview/Linux/Qorix-Preview.x86_64` |

Both use the same GL Compatibility renderer and embedded PCK as the normal
presets, and include `*.lua`, `*.json` and `*.csv`. Linux is preview-only and
best effort for this cycle; Windows is the reference platform.

## Local build

The script is test-gated: it runs the full headless suite first and refuses to
export on exit code non-zero.

```powershell
powershell -ExecutionPolicy Bypass -File tools/mod-package/build_mod_preview.ps1 -Platform Windows
powershell -ExecutionPolicy Bypass -File tools/mod-package/build_mod_preview.ps1 -Platform Linux
```

Direct Godot invocation is equivalent:

```bash
godot --headless --path . --export-release "Windows Developer Preview" "Builds/Preview/Windows/Qorix-Preview.exe"
godot --headless --path . --export-release "Linux/X11 Developer Preview" "Builds/Preview/Linux/Qorix-Preview.x86_64"
```

Linux export needs the Godot 4.7.2 export templates installed. A missing
template is a build error, not a silently smaller artifact.

`Start-Process -Wait` is used deliberately on Windows: the GUI-subsystem Godot
executable is not awaited by `&`, and passing the preset name through an
`-ArgumentList` array would split it at the space. The script removes any stale
artifact before exporting, requires the `[ DONE ] savepack` marker and a
non-empty file, and only then accepts the known Godot 4.7.2 Windows shutdown
crash described below.

## Verified exports

Packaging was exercised on the Windows reference host with Godot 4.7.2 on
2026-11-06. The export presets themselves were not edited for the test.

| Artifact | Command | Result |
| --- | --- | --- |
| Windows preview PCK | `--export-pack "Windows Developer Preview" <temp>.pck` | 40,489,124 bytes; `GDPC` magic; `[ DONE ] savepack` |
| Windows preview executable | `--export-release "Windows Developer Preview" <temp>.exe` | 149,667,504 bytes; boots with `--headless --quit-after 5`, exit 0 |
| Linux preview PCK | `--export-pack "Linux/X11 Developer Preview" <temp>.pck` | 40,489,124 bytes; `GDPC` magic; `[ DONE ] savepack` |
| Linux preview executable | `--export-release "Linux/X11 Developer Preview" <temp>.x86_64` | 114,008,544 bytes; cross-export from Windows, not run here |

The Windows artifacts were also compared with the normal `Windows Desktop`
preset: its PCK export completes with the same post-savepack shutdown crash, so
the crash is a Godot 4.7.2 toolchain issue, not a preview-preset regression. A
PCK booted with `--main-pack` and the exported preview executable both started
and exited cleanly headless (only the pre-existing shader and leak warnings).
The preview executables contain the `mod_preview` feature string; a normal
`Windows Desktop` PCK does not, which matches the opt-in design. This is
packaging evidence, not the window checklist: it does not prove the on-screen
preview label, sample docks, hot reload or the five-lesson course.

## Labeling checklist

Before publishing a preview artifact:

- [ ] The About/version string matches the preview release notes.
- [ ] The startup notice says **Modding Developer Preview** and names the frozen
      API 1.0.
- [ ] View → Mods… shows **Developer Preview · API 1.0**.
- [ ] The download page/file name contains **Preview** or **Developer Preview**;
      never label it "1.0" or "stable".
- [ ] The release notes link `known-issues.md` and `feedback.md`.
- [ ] Windows is named as the reference platform and Linux as preview-only.
- [ ] No text claims signatures, authenticity, a public mod registry or
      automatic updates. SHA-256 is published as integrity only.
- [ ] The full headless suite passed on the exact commit being exported.

## Release notes template

```markdown
## Qorix Developer Preview — mod platform (API 1.0.0)

Opt-in preview for mod authors and testers. Not a public release.

- Frozen API 1.0 (100 methods, 15 catalogued permissions)
- Developer mode and hot reload for user://mods_dev copies
- Three clean-install samples, the Platform Tour lesson/self-check + Preview Lab
- Developer, API, manifest, migration and known-issue docs

Reference platform: Windows. Linux: preview-only, best effort.
Unsigned packages need explicit opt-in; there is no public registry or auto-update yet.
Report issues with the Mod Preview form; security privately via advisory.

SHA-256: <fill in the artifact hash>
```

## CI and artifacts

The release workflow still builds the normal Windows installer from a test-green
tree. The preview presets are deliberately not part of the normal tag workflow:
produce them from an explicit local or manual CI run so a stable release cannot
silently include preview flags.

If the preview is attached to GitHub Releases, attach it as a **pre-release**,
include the SHA-256 next to the file and keep the normal release assets separate.
The installer wraps the same export; do not claim that the preview installer is
signed unless package signing is actually configured.

## Failure policy

- Red headless suite → do not build or publish.
- Missing export templates → fix the runner; do not upload a partial artifact.
- An open critical/high security issue → delay the preview, record it in
  [`known-issues.md`](known-issues.md) and follow the
  [Developer Preview gate record](../archive/mod-platform/developer-preview.md).
- A docs change that adds or removes an API method without updating the golden
  fixture → treat as a red tree, not a docs-only change.

## What is deliberately absent

Archive validation before extraction, publisher signatures, rollback UI, a
remote registry, auto-update and telemetry remain future work. The preview can
be shared as a manually extracted folder, with the limitations in
[`known-issues.md`](known-issues.md) stated plainly.
