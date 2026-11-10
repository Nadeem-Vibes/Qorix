# Lua runtime probe harness

Executable feasibility probes for the Qorix modding platform. These are
probe artifacts, not product code; the harness changes nothing in the editor.

## Run

```bash
godot --headless --path . --script res://tools/probes/lua-runtime/run_probe.gd
godot --headless --path . --script res://tools/probes/lua-runtime/run_probe.gd -- --only=E3,E4
```

Exit codes:

- `0` — no selected probe failed. Partial results are printed and written, but
  do not fail the run.
- `1` — at least one probe status is `fail`.
- `2` — bad probe selection.

Results are written to `tools/probes/lua-runtime/out/probe-results.json` (ignored by
git). The run prints one line per check and one `NOTE` line per documented
limitation.

The harness runs inside the main project because that is the only way to load
the exact bundled LuaAPI binaries. It does not load `src/main/editor.tscn` and does
not modify the editor. The bootstrap in `lua/bootstrap.lua` mirrors section 5.3
of the architecture plan and is loaded from disk on each probe state.

## Probes

| ID | File | What it covers | Current status |
| --- | --- | --- | --- |
| E2 | `probes/e2_runtime.gd` | Addon hashes, class load, Lua version, memory API | partial: editor build only |
| E3 | `probes/e3_abort_matrix.gd` | Loop abort matrix at 100/1k/10k/1M instructions, state reuse, deep-recursion fallback | **fail**: 1M non-tail recursion leaves the state unusable |
| E4 | `probes/e4_escape_hatches.gd` | Sanitized env, pcall/xpcall, nested coroutine, binary load, memory pressure, long C call, native callback | partial: native callbacks block synchronously |
| E5 | `probes/e5_lifecycle.gd` | 100 create/drop, 100 failed activations, 1,000 aborts, memory/object recovery | pass |
| E6 | `probes/e6_marshalling.gd` | GDScript/Lua values, pulled functions, re-entrancy | partial: stale callback ids and hooking of pulled functions unverified |
| E8 | `probes/e8_unicode.gd` | Grapheme segmentation, codepoint boundaries, split-cluster detection | partial: pixel alignment needs a window |

E1, E7, E9, E10, E11, E12 and E13 are not implemented here; they need an
exported build, a real window, a UI spike, or human users. See
`docs/archive/mod-platform/probe-report.md`.

## Add a probe

1. Add `probes/eN_name.gd` extending `RefCounted` with `func run(ctx: Dictionary) -> Dictionary`.
2. Return `probe`, `title`, `status`, `checks`, `metrics`, optional `limitations` and `notes`.
3. Register it in `run_probe.gd` under `PROBES`.
4. Use `probe_util.gd` for `check()`, `status()`, `first_value()` and hashing.

A probe must report a failing check rather than throw: the runner keeps going so
one experiment cannot hide the rest.
