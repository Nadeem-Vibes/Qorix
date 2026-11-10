# Phase 5 — Developer Preview

Status: **implemented; automated gates pass, window evidence pending.** This is
the Phase 5 scope from §16 of the architecture plan: freeze API 1.0, ship
developer documentation and samples, add preview packaging, developer mode with
hot reload, a known-issues list and a feedback channel. It is a developer
preview, not a public release: distribution security remains Phase 6 and the
public 1.0 gate is Phase 7, documented in [`hardening.md`](hardening.md).

## What Phase 5 adds

| Area | Implementation |
| --- | --- |
| Frozen contract | `Api.API_SEMVER = "1.0.0"`, `API_STATUS = "frozen"`, `API_FROZEN = true`, `contract()`; 100 native methods and 15 catalogue permissions pinned by the golden fixture |
| Developer mode | Debug builds or `--mod-dev`; scans `user://mods_dev` as a non-installed root |
| Hot reload | `mod_dev_watcher.gd` watches `main.lua` and recursive `lib/**/*.lua`, debounces saves, deactivates/reactivates; storage, progress and settings survive |
| Preview packaging | `mod_preview` export feature / `--mod-preview`; Windows and Linux preview export presets; an in-app preview notice and Mods-page label |
| Samples | Three clean-install samples, `griddycode.platform_tour` (guided lesson plus self-check) and `griddycode.preview_lab` (hot-reload test bed) |
| Docs | This page, the developer guide, the frozen API and manifest references, migration notes, known issues, feedback and packaging |
| Feedback | GitHub issue form `.github/ISSUE_TEMPLATE/mod-preview.yml` |

## Gate F evidence

| Gate F item | Automated evidence | Window evidence |
| --- | --- | --- |
| API 1.0 frozen | `test_mod_phase5_contract.gd` pins the constants, 100-method golden fixture, SHA-256 `e27c1c0d…f2467` and docs coverage; `test_mod_api_golden.gd` compares the native table entry by entry | Not applicable |
| Three samples work from a clean install | `test_mod_phase5_samples.gd` copies the three samples into a fresh root, verifies discovery, the consent-blocked state, grants consent and asserts all three reach `active` with their commands registered. The same suite validates the Platform Tour package and its blocked → consent → active path. `test_mod_phase5_tour_runtime.gd` drives the tour's real `main.lua`: Check answer during typing explains the automatic advance instead of submitting, a freeform check submits, a failed freeform check stays checkable, and the self-check reports 8/8 inside its own event namespace | Follow `samples/mods/README.md` on a desktop build; pending |
| Docs cover every public function and permission | `test_mod_phase5_contract.gd` asserts all 100 native names in [`api-reference.md`](../../mods/api-reference.md), all 15 permission names in both references, every manifest and setting field, and the presence of all eight Phase 5 documents | This page and the docs reviewed here |
| Preview build is opt-in and labeled | `file_manager.gd` enables it only for `mod_preview` or `--mod-preview`; `mod_manager.start()` publishes the preview notice; the Mods page shows **Developer Preview · API 1.0**; status reports `preview_build`; `test_mod_phase5_dev_mode.gd` checks the label in status. Both preview presets also completed `--export-pack` and `--export-release`; the Windows executable booted headless with exit 0 (see [`preview-packaging.md`](../../mods/preview-packaging.md#verified-exports)) | Confirm the notice and Mods page in a desktop build; pending |
| Reference mod passes on Windows | Phase 4 `test_mod_phase4_runtime.gd` and `test_mod_phase4_samples.gd` remain green; the reference package is unchanged and requires editor `1.4.0`, Python and a trusted workspace | Full five-lesson pass needs a Windows desktop, real keyboard and Python; pending |
| Linux supported or listed as preview-only | Export preset `Linux/X11 Developer Preview` exists; the Linux PCK and executable cross-exported from Windows; this page and [`known-issues.md`](../../mods/known-issues.md) list Linux as preview-only, best effort | A Linux desktop pass has not been run |
| No critical security issue open | The Phase 0–3 sandbox, consent, pointer, path, event, UI and shell suites are green in the full run; the preview adds no network, process or input surface; `input.observe` and `network` remain unavailable | A formal distribution/security review is Gate G; no known critical or high issue is open at this scope |

The honest summary is the same as Phases 3 and 4: headless evidence is green,
but Gate F is not signed until the window checklist is run. See
[Pending window checks](#pending-window-checks).

## Using the preview

```text
# Developer mode + hot reload (release build)
Qorix.exe --mod-dev

# Label this run as the preview build
Qorix.exe --mod-preview

# Safe mode for one session
Qorix.exe --safe-mode
```

A debug build already enables developer mode. Put development copies at
`user://mods_dev/<id>/<version>/` and installed copies at
`user://mods/<id>/<version>/`. Only the dev root is watched. The complete
walkthrough is [`developer-guide.md`](../../mods/developer-guide.md).

## Hot reload behaviour

1. The manager scans installed mods, then (in developer mode) the dev root. A
   dev copy with the same id replaces the installed copy for this session.
2. Activation registers `main.lua` and every `.lua` file under `lib/` with the
   watcher. Installed mods are never registered.
3. A changed file starts a 250 ms quiet window. If another save arrives, the
   window restarts.
4. When quiet, the manager deactivates and reactivates the mod. Storage,
   progress and settings are flushed and reloaded. Widget mounts, commands,
   timers and Lua locals are rebuilt.
5. A manifest change is not watched. Restart or use **Reload** on the Mods page.
6. Safe mode and session-disabled panic mode never hot-reload.

Polling defaults to 400 ms; tests inject poll/debounce values and a file
signature so mtime granularity cannot make the suite flaky.

## Files

| Path | Purpose |
| --- | --- |
| `src/features/mods/mod_dev_watcher.gd` | Watch set, signature, debounce and due list |
| `src/features/mods/mod_manager.gd` | Dev scan/override, watcher lifecycle, hot reload, status report |
| `src/features/mods/api/api_v1.gd` | Frozen constants and `contract()` |
| `src/features/mods/ui/mod_settings_panel.gd` | Preview label, developer-mode note, dev badge |
| `src/main/file_manager.gd` | `--mod-dev` / `--mod-preview` / feature detection |
| `samples/mods/griddycode.preview_lab/1.0.0/` | Runbook and test bed for hot reload |
| `samples/mods/griddycode.platform_tour/1.0.0/` | Guided lesson, eight-point self-check and hot reload drill |
| `tests/suites/test_mod_dev_watcher.gd` | Watch set and debounce |
| `tests/suites/test_mod_phase5_contract.gd` | Constants, golden hash, docs coverage |
| `tests/suites/test_mod_phase5_dev_mode.gd` | Dev scan, override, reload, installed-not-watched |
| `tests/suites/test_mod_phase5_samples.gd` | Clean-install activation and sample validation |
| `tests/suites/test_mod_phase5_tour_runtime.gd` | Platform Tour `main.lua` runtime: Check answer phases and self-check namespace |
| `export_presets.cfg` | `Windows Developer Preview`, `Linux/X11 Developer Preview` |
| `Tools/build_mod_preview.ps1` | Test-gated local preview export |

## Tests

```bash
godot --headless --path . --script res://tests/test_runner.gd
```

The Phase 5 suites are registered at the end of `tests/test_runner.gd`. The full
suite must finish with exit code 0; the runner prints every failed assertion
instead of stopping at the first one.

## Pending window checks

These need a desktop build and cannot be simulated headlessly:

1. Launch a release build with `--mod-dev`, copy `griddycode.preview_lab` into
   `user://mods_dev`, confirm the dev badge, edit `main.lua` and `lib/build.lua`
   and verify the panel reloads while its activation counter increments.
2. Confirm the preview notice is visible only for `--mod-preview` or a
   `mod_preview` build.
3. Copy the three clean-install samples to `user://mods`, verify the consent
   cards, grant the requested permissions and confirm each sample's dock or
   command works.
4. Install `griddycode.platform_tour`, confirm it is blocked until both document
   permissions are granted, finish the manifest lesson. While typing, confirm
   **Check answer** explains that the lesson advances automatically; after the
   permissions phase, confirm it validates and the self-check reports 8/8. Then
   run its `lib/build.lua` hot reload drill from `user://mods_dev`.
5. Run the Phase 4 five-lesson course on Windows with Python and a trusted
   workspace; capture the screenshots in
   [`reference-course-screenshots.md`](reference-course-screenshots.md).
6. Run the Phase 3 keyboard-only, screen-reader, IME and panic checks; measure
   typing latency and lesson-switch frame time.
7. Verify Linux preview behaviour (best effort) or record the platform as
   preview-only for this cycle.

## Related phases

- [`api-and-partial-ui.md`](api-and-partial-ui.md) — API, partial UI and samples.
- [`shell-and-learning.md`](shell-and-learning.md) — shell, guide and exercise.
- [`reference-course.md`](reference-course.md) — five-lesson reference course.
- [`contracts.md`](contracts.md) — error and permission
  contracts that API 1.0 freezes.

Phase 6 (distribution security, signatures, archive validation and rollback)
is implemented with automated evidence in
[`distribution-security.md`](distribution-security.md); its external security review and
five-user consent study are still pending. Phase 7 (hardening and public 1.0)
is implemented separately; see [`hardening.md`](hardening.md).
