# Phase 0 probe report

Date: 3 November 2026  
Host: Windows 10.0.26300, Godot 4.7.2 stable (`ed1daf0bf`), bundled LuaAPI addon  
Harness: `Tools/phase0_probe/`  
Result artifact: `Tools/phase0_probe/out/probe-results.json`

This report records what was actually measured. Gate A is not signed. The
experiments that need a window, an exported build or human users are listed as
pending rather than inferred.

## Summary

| Experiment | Status | Short result |
| --- | --- | --- |
| E1 baseline | pending | No exported build or window measurement yet |
| E2 runtime pinning | partial | Addon loads; hashes recorded; packaged Windows/Linux pending |
| E3 abort matrix | **fail** | Sentinel works at 100/1k/10k and for normal loops at 1M; non-tail recursion at 1M overflows the C stack and corrupts the state |
| E4 escape hatches | partial | All attacks contained; native callbacks are synchronous and can block |
| E5 lifecycle | pass | No leak detected across 100 states and 1,000 aborts |
| E6 marshalling | partial | Values and re-entrancy work; raw pulled functions are unhooked |
| E7 shell framing | pending | Requires real-window spike |
| E8 Unicode | partial | Segmentation and split rejection work; pixel alignment pending |
| E9 input/IME | pending | Manual matrix |
| E10 widgets/accessibility | pending | UI spike |
| E11 event bus | pending | Not built |
| E12 vertical slice | pending | Three-user study |
| E13 packaging | pending | Archive validator and consent walkthrough |

## E2 — Runtime pinning and packaged load

Measured in the editor binary:

| Item | Value |
| --- | --- |
| `LuaAPI` in ClassDB | true |
| `_VERSION` | `Lua 5.4` |
| `luaAPI.gdextension` SHA-256 | `5c70526b56d5402b836645e7c60cf0c1a0b3b8e7d1599b48be7634f1f246f08f` |
| Windows debug x86_64 DLL | `32a709eeb2361d2ec174f732a74fa85f1bd37029350edae213ca451a381a3908` (1,829,888 bytes) |
| Windows release x86_64 DLL | `6a09efe231191156dae5b13ff452f11d9f6f05a99d435f695c077a870a514d0d` (1,945,600 bytes) |
| Linux debug x86_64 SO | `318783de379914318c85e2fadaaa52c2d6d4610d2be1733c445841b3c21875c5` (1,010,792 bytes) |
| Linux release x86_64 SO | `49a0759dc784afcdb83f84e943318ec6c4612f236ad77e4a411d85008f6e7cf8` (1,071,992 bytes) |
| `.godot/extension_list.cfg` lists addon | true |
| Memory limit / usage | 25,165,824 / 14,012 bytes |

The probe recorded `Lua 5.4`, not `Lua 5.4.5`. The architecture plan's probe
reported 5.4.5 from the shipped DLL; this discrepancy must be resolved before
the version is quoted in a manifest or support table. The class surface and
memory API load, but packaged Windows release and Linux release runs are still
required. No packaged-build pass is claimed.

## E3 — Abort matrix

### Results

| Budget | `while true` | numeric `for` to `math.huge` | infinite generic `for` | `repeat ... until false` | mutual recursion | non-tail deep recursion |
| --- | --- | --- | --- | --- | --- | --- |
| 100 instructions | 0.03 ms | 0.01 ms | 0.01 ms | 0.01 ms | 0.01 ms | 0.01 ms |
| 1,000 | 0.01 ms | 0.01 ms | 0.01 ms | 0.01 ms | 0.01 ms | 0.06 ms |
| 10,000 | 0.03 ms | 0.04 ms | 0.07 ms | 0.04 ms | 0.05 ms | 0.41 ms |
| 1,000,000 (production) | 2.24 ms | 2.83 ms | 6.46 ms | 3.36 ms | 4.77 ms | **63.02 ms, no sentinel** |

Every row except the last aborted with `budget.exceeded`, left no task behind and
accepted a normal chunk immediately afterwards.

### Failure detail

The non-tail recursion is:

```lua
local function f(n)
  local x = f(n + 1)
  return x + 1
end
f(1)
```

At the production budget, Lua reaches its C-stack limit before the instruction
hook fires. The addon returns an error object (`[Wrapped:0]`), the task is not
removed, and a subsequent `load` of an ordinary chunk returns the same error.
The state is no longer usable. The editor process stayed responsive, but the mod
state is lost.

At a 500,000-instruction budget the same chunk is killed by the sentinel in
**49.97 ms** and the state remains usable (`alive` returned). At 250,000 it
aborted in 11.56 ms in the isolation run. A tail-recursive loop (mutual
recursion) is caught by the hook at 1M; the failure is specific to non-tail
recursion reaching the C-stack limit.

### Recommendation

Do not freeze the 1M production budget as written. Either:

1. Lower the per-resume instruction budget to 250,000 (measured 11.6 ms on this
   host, leaving margin under 50 ms), or
2. Treat any non-sentinel VM error (including stack overflow) as fatal to the
   mod state: mark the mod failed, drop the task table, release the LuaAPI
   object and recreate the state on demand. Do not reuse a state after
   `[Wrapped:0]`.

A combined policy is safest: 250k instruction budget, 25 ms hard wall clock, and
fatal-state recreation for non-sentinel errors. This must be re-run on packaged
Windows release and Linux release before Gate A.

## E4 — Escape hatches

All containment checks passed:

| Attack | Result |
| --- | --- |
| `debug`, `coroutine`, `io`, `os`, `package`, `dofile`, `loadfile`, `collectgarbage`, `string.dump` reachable | false; absent |
| Host globals (`__griddy_load_mod`, `__griddy_resume`) visible | false |
| `pcall(function() while true do end end)` | killed by sentinel, task dead |
| `xpcall` with a transforming handler | killed by sentinel, task dead |
| Nested `coroutine.create` | blocked at the name lookup; no hang |
| Binary `load("\27Lua", ..., "b")` | rejected: `binary chunks are not allowed` |
| 64 MB `string.rep` under a 24 MB limit | rejected: `not enough memory` in 0.01 ms |
| 1 MB `string.gsub` | completed in 5.04 ms; bounded by input, not interruptible |
| Native `sleep(120)` callback | blocked the dispatch path for 120.75 ms |

The 1 MB `gsub` and the native callback are the two documented residuals. The
instruction hook cannot interrupt a C function mid-call, and a GDScript callback
runs synchronously on the host thread. The public API must only call bounded
host callables; long work belongs in a host task or a run profile.

## E5 — State lifecycle, memory and leaks

| Check | Result |
| --- | --- |
| 100 state create/run/drop cycles | 0 failures |
| 100 failed activations | 0 accepted |
| 1,000 abort cycles at 1,000 instructions | 0 failures, 13.9 ms total |
| Orphan task checks | 0 failures |
| Static memory | 94,334,021 → 94,348,545 bytes (+0.02%) |
| Object count | 1,660 → 1,661 (+1) |

This supports the one-state-per-mod teardown model, with the E3 caveat that a
state which hit a non-recoverable VM error must be destroyed rather than reused.

## E6 — Native callback marshalling

| Check | Result |
| --- | --- |
| GDScript → Lua types | String, float, bool and table observed correctly (table arrived as an Array) |
| Lua → native round-trip | string, 3.5 and true returned unchanged |
| Lua function returned to GDScript | `LuaCallable`, `2 + 3 = 5.0` |
| Lua → native → Lua re-entrancy | `6 + 7 = 13.0`, state still usable |
| Stale callback ids after teardown | not implemented; unverified |

A function pulled directly from the state runs on the main Lua thread with no
hook. That is a design constraint, not a usable API: ModHost must expose integer
callback ids and dispatch every callback as a hooked host task. Stale ids and
queued-callback invalidation remain required tests for Phase 1.

## E8 — Ghost alignment and Unicode mapping (pure part)

TextServer returns each grapheme cluster's end codepoint, with the leading zero
implicit. The matcher must treat the boundaries as `[0] + breaks`; the probe's
first implementation assumed a leading zero was included and was corrected.

| Fixture | Clusters / codepoints | Expected |
| --- | --- | --- |
| `abc` | 3 / 3 | pass |
| `e` + U+0301 | 1 / 2 | pass |
| precomposed `é` | 1 / 1 | pass |
| `日本語` | 3 / 3 | pass |
| Devanagari `नमस्ते` | 3 / 6 | recorded, no fixed expectation |
| Hebrew `שלום` | 4 / 4 | pass |
| Arabic `مرحبا` | 5 / 5 | pass |
| `👍🏽` | 1 / 2 | pass |
| ZWJ family | 1 / 7 | this build keeps it as one cluster; the plan's split caveat did not reproduce here |
| tab | 1 / 1 | pass |
| `a\té👍🏽` | 4 / 5 | pass |

Split rejection works: for `e` + U+0301 the boundaries are `[0, 2]`, so column 1
is inside a cluster and is rejected. `get_rect_at_line_column` exists but returns
`(-1, -1)` headless, so pixel alignment at 100/150/200% zoom, tabs and
proportional fonts still needs a window and screenshots.

## Pending experiments

| Experiment | What is required before it can be reported |
| --- | --- |
| E1 | Export a release build, measure cold start, 4 KB Python file keystroke-to-paint at 100/200%, idle/peak RSS, terminal open/run, 20 runs, median table |
| E7 | Real-window shell spike: 280/320/180 panels, host chrome, camera insets, four resolutions and four DPI values, 50 takeover/restore cycles with exact snapshot equality, panic under 100 ms |
| E9 | US/dead-key/IME layouts, strict and coach modes, repeat/backspace/Enter/Tab/paste/undo/selection/drag, panic during a session |
| E10 | Full v1 widget catalog, 150-widget and 400-widget shells, 10% updates at 10 Hz, keyboard/screen-reader/high-contrast/200% runs, orphan-node check |
| E11 | Eight fixture mods at 100 events/s, one looping handler, one error storm, kill mid-dispatch, queue caps and 2 ms/frame budget |
| E12 | Throwaway shell + lesson 1 + hint + stdout validation + progress + freeform follow-up, three users who have not seen the design |
| E13 | Malicious archive suite (traversal, absolute, symlink, duplicates, oversize, permission growth, hash mismatch), five-user consent walkthrough, threat tabletop |

## Findings

- **F1 (blocking):** the 1M budget does not stop non-tail recursion before the C
  stack overflows, and the addon leaves the state unusable. Use 250k or recreate
  the state on fatal VM errors; re-run E3 on every platform build.
- **F2:** the sentinel hook is fast and reliable for the other loop forms: under
  7 ms at the 1M budget, under 0.1 ms at the plan's 100/1k/10k counts.
- **F3:** the sanitized environment and protected error boundary behave as
  designed for pcall, xpcall, nested coroutine, binary chunks and memory
  pressure.
- **F4:** teardown is clean across 100 state cycles and 1,000 aborts.
- **F5:** native callbacks can block; the API must keep them bounded and never
  hand raw Lua functions to native callers.
- **F6:** TextServer segmentation is usable for the matcher; ZWJ behaviour
  differs from the plan's probe and must be platform-tested, not assumed.
- **F7:** the addon's reported Lua version is `Lua 5.4`; resolve the 5.4.5 claim
  before freezing the build manifest.

## Reproduction

```bash
godot --headless --path . --script res://Tools/phase0_probe/run_probe.gd
godot --headless --path . --script res://Tools/phase0_probe/run_probe.gd -- --only=E3,E4
```

The harness prints one line per check and writes the full JSON artifact. A
failing check is reported rather than thrown so one experiment cannot hide the
rest.
