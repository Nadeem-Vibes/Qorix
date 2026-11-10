# Qorix Mod Platform 1.0.0 — release notes

Release: **Qorix Mod Platform 1.0.0**  
API: **1.0.0, frozen**  
Channel: **Public 1.0** (preview and developer builds are labelled separately)

## Highlights

- Frozen API 1.0 with 100 methods across documents, files, workspace, events,
  commands, keys, settings, permissions, UI, shell, exercise, guide, run and
  progress.
- Capability-based permissions with explicit consent, permission-growth
  re-consent and a sandboxed Lua host with memory and instruction budgets.
- Declarative partial UI and exclusive shell takeover with exact restore,
  panic exit and crash-loop protection.
- Hybrid learning exercises: guided typing, then freeform work validated by
  text checks or a real run.
- Validated `.gcm`/`.zip` packages, SHA-256 digests, Ed25519 publisher
  signatures, pinned publisher identity, update, rollback and uninstall.
- Hardening: platform matrix, startup and memory budgets, mechanical
  accessibility audit, legacy-content inventory and the Gate H release audit.

## New in 1.0.0 hardening

- The Mods page shows the running channel and platform, a **Platform health ·
  Gate H** card with pass/warn/fail/manual evidence, and a separate **Legacy
  content** list. Legacy language/theme files are never presented as mods.
- Startup activation is measured against a 500 ms budget; deferred activation
  and task instruction-budget overruns are reported.
- Active Lua memory is measured against a 96 MB aggregate budget, with
  per-host limits and overrun counters.
- `ModUiRegistry.accessibility_audit()` checks that every mounted interactive
  widget is keyboard-focusable and has a text or tooltip label, and reports
  issue widget ids.
- The release gate returns `ready: false` while any warning or manual evidence
  is outstanding. A recorded human review can close the review item; it cannot
  hide a failed automated check.
- The C++ Learning Journey sample ships as a second five-lesson course. It
  teaches includes, `main`, variables, types, conditionals and loops, and
  compiles freeform work through the existing C++ run profile. Without a
  compiler it uses text checks and says so.

## Compatibility

- No API 1.0 method, permission name, error code or widget type was removed or
  changed in the hardening pass. The API surface fixture and hash are unchanged.
- Existing mods that validate against API 1.0 continue to load. Mods using
  undocumented engine behaviour should be retested.
- The Python Learning Journey remains the reference course. The C++ course uses
  distinct ids and shortcuts, so both can be installed together.

## Upgrade from Developer Preview

1. Keep a copy of `user://mods` before upgrading.
2. Install 1.0 normally. Installed mods are scanned and validated again.
3. Review any consent request caused by permission growth or a changed
   publisher key. Do not replace a pinned key unless the publisher confirms the
   rotation.
4. Open **View → Mods…** and check the Platform health card. A preview platform
   is a warning, not a failure; a failed mod or package is a failure.
5. If the previous session crashed inside a mod shell, the crash-loop guard may
   disable the previous mod set for one launch. Use **Reload** after reviewing
   the mod, or start with `--safe-mode` to diagnose.

## Verification

```bash
godot --headless --path . --script res://tests/test_runner.gd
```

The suite covers the API contract, permissions, host and budgets, shell
snapshot/panic, partial UI, learning engine, both courses, package security,
install/rollback/uninstall, the hardening audit and a real `g++` compile/run when
a compiler is available.

The release gate is separate from the test suite. It stays open until the human
items are recorded: desktop keyboard/screen-reader/IME pass, platform matrix,
five-user consent study, external security review and support sign-off. See
[`README.md`](README.md) for the full Gate H table and [`support.md`](support.md)
for the user policy.

## Known issues

- Linux and macOS remain preview platforms for 1.0.
- The mechanical accessibility audit cannot validate screen-reader output, IME
  behaviour or contrast.
- Legacy language/theme Lua is inventoried but not migrated or sandboxed.
- A shell reserves one editor viewport; layouts with two are refused.
- `run` checks depend on a trusted workspace and a compiler on `PATH`; the C++
  course falls back to text checks, while other mods may fail their run step.
- Mods run in-process with capability checks; this is not an OS-level sandbox.

## Support

Read [`support.md`](support.md) before reporting. Include the build label,
platform, mod id/version, publisher fingerprint, signature state and the Mods
page status. Never send private keys, session tokens or unredacted file content.
