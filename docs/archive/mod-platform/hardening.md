# Phase 7 — Hardening and Public 1.0

Status: **implemented; automated evidence is produced by the headless suite,
human Gate H evidence is still outstanding.**

Phase 7 is the release phase from §16.3 of the architecture plan. It adds no mod
capability and does not change the frozen API 1.0 surface. It makes the public
1.0 claim testable:

- a platform support matrix instead of an undocumented "it runs here";
- startup and memory budgets with per-mod host counters;
- a mechanical accessibility audit of every widget the host mounts for mods;
- crash-loop, safe-mode, panic and exact-restore drills;
- an honest inventory of legacy language/theme content that predates mods;
- support, release and migration documents;
- one service, `src/features/mods/mod_hardening.gd`, that reports the same evidence
  to the Mods page, the release gate and the tests.

## Gate H evidence

| Gate H item | Automated evidence | Human evidence |
| --- | --- | --- |
| Supported platform matrix | `Hardening.PLATFORM_MATRIX` and `test_mod_phase7_hardening.gd`; Windows is the reference platform, Linux/macOS are preview, Android/iOS/Web are unsupported | Desktop pass on each supported or preview platform |
| Startup and dispatch budget | Activation time against the 500 ms budget; deferred activation and instruction-budget overruns are reported as warnings | Perceptible-lag review on a low-end desktop |
| Memory budget | Aggregate Lua memory against the 96 MB budget, plus per-host limits and budget counters | Long-session memory profile with the reference course open |
| Mod failure isolation | Failed, blocked and disabled mods surface in the audit; any failed mod fails the gate | Recover from a deliberately failing mod without restarting the editor |
| Package and signature health | Scan errors and recorded failures fail or warn the gate | Phase 6 external review |
| Accessibility | Every mounted interactive widget is keyboard-focusable and has text or a tooltip label; `ModUiRegistry.accessibility_audit()` reports issues by widget id | Screen-reader, IME and keyboard-only pass on Windows and macOS |
| Panic and exact restore | The headless drill runs 50 takeover/inset/panic cycles and compares the shell snapshot after every exit | Desktop panic drill from the host bar |
| Crash loop and safe mode | Two short unclean sessions disable the previous mod set; `--safe-mode` / `--no-mods` start clean for one launch | Manual recovery walkthrough after killing the process |
| Legacy content migration | Legacy `.lua` files under `user://langs` and `user://themes` are inventoried and labelled as unmanaged; nothing is moved or deleted | Visual check that legacy languages and themes still load |
| Support and release docs | `support.md`, `release-notes.md` and this gate record must exist or the audit fails | Support owner sign-off |
| Human release review | Passes only when the runtime supplies recorded review evidence | Five-user consent study, screen-reader pass, IME pass and platform matrix |

The audit returns per-check `pass`, `warn`, `fail` or `manual`. `release_ready`
is true only when there are no failures, no warnings and no outstanding manual
checks. That is deliberately strict: an audit can be green while the release
gate is still open for people.

## Platform policy for 1.0

| Platform | Status | Meaning |
| --- | --- | --- |
| Windows 10/11 x86_64 | Supported | Reference platform; the automated and desktop gates run here |
| Linux x86_64 | Preview | Packages install and run, but the desktop matrix is not signed off |
| macOS | Preview | No signed build or desktop accessibility pass yet |
| Android, iOS, Web | Unsupported | Not 1.0 targets; the editor remains a desktop application |

The Mods page names the running platform and channel, so a preview build never
presents itself as the public channel.

## Accessibility scope

`ModUiRegistry.accessibility_audit()` checks the mechanics the host owns:

- interactive catalog widgets use `FOCUS_ALL`;
- each has non-empty text or a tooltip label;
- focus order follows the declarative scene-tree order;
- unmounted or queued-free nodes are not counted.

It cannot judge screen-reader announcements, IME composition, colour contrast in
a user theme, or whether a label makes sense. Those remain human checks.

## Legacy content

Before the mod platform, users installed language plugins in `user://langs` and
themes in `user://themes`. Those loaders are still authoritative. Phase 7 adds a
read-only inventory, not a migration: the Mods page lists the files and states
plainly that they have no permissions, consent, sandbox or uninstall action.
Moving them into packages would be a breaking change and is not part of 1.0.

## Verification

```bash
godot --headless --path . --script res://tests/test_runner.gd
```

The Phase 7 suites are registered at the end of `tests/test_runner.gd`:

| Suite | Focus |
| --- | --- |
| `test_mod_phase7_hardening.gd` | Platform matrix, channels, legacy inventory, audit pass/fail/manual paths, accessibility audit, 50-cycle panic/restore drill, crash-loop drill, support docs |
| `test_mod_phase7_cpp_journey.gd` | C++ course manifest, Lua compilation, lesson schema, C++ targets, locale parity, layout validation, runtime flow, real `g++` compile and run |

The C++ compile test runs only when `g++` is on `PATH`; it reports the skip
instead of pretending a compile happened. On the verification machine `g++`
16.2.0 was available, so all five freeform examples compiled and ran. The shell
drill is headless and cannot prove the desktop panic button is reachable with a
screen reader.

Last full run (Godot 4.7.2, Windows): **7056 checks across 82 suites, exit 0**.
The Phase 7 suites contribute **161 checks** in `test_mod_phase7_hardening.gd`
and **1328 checks** in `test_mod_phase7_cpp_journey.gd`.

## Still open before public release

1. Record the human release review in the audit (`release_review.ok` with a
   detail). Without it the gate stays `manual`.
2. Run the desktop keyboard, screen-reader and IME pass on Windows, then repeat
   the matrix on Linux and macOS or keep the preview labels.
3. Complete the five-user consent study from Phase 6.
4. Complete the external security review from Phase 6.
5. Produce a signed build for every supported platform; Phase 7 does not add
   code signing or an installer.

See [`support.md`](../../mods/support.md) for the user-facing support policy and
[`release-notes.md`](../../mods/release-notes.md) for the 1.0.0 notes.
