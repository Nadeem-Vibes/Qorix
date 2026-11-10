# Phase 0 — Feasibility and contracts

Status: **Gate A not passed.** This is the current Phase 0 evidence pack for the
modding platform described in *Qorix Universal Modding Platform — Technical
Architecture Plan, Revision 2* (2 November 2026).

Phase 0 is a feasibility gate, not an implementation phase. No product code is
merged from it. The only code added here is the probe harness under
`Tools/phase0_probe/`.

## Deliverables

| Deliverable | Location | State |
| --- | --- | --- |
| Reproducible probe harness | `Tools/phase0_probe/` | E2, E3, E4, E5, E6, E8 run headless |
| Written probe report | `probe-report.md` | Draft with measured results |
| Frozen API, permissions, manifest and errors | `contracts.md` | Proposed; awaits Gate A sign-off |
| Phase 1 backlog and test plan | `mod-core-plan.md` | Draft; blocked on Gate A |

## Experiment status

| Experiment | Status | Evidence |
| --- | --- | --- |
| E1 baseline capture | pending | Needs an exported release build, a window and 20-run medians |
| E2 runtime pinning and packaged load | partial | Editor build loads; hashes recorded; packaged Windows/Linux pending |
| E3 abort matrix | **fail** | All loop forms abort at 100/1k/10k; at 1M a non-tail recursion hits Lua's C-stack overflow, takes ~63 ms and leaves the state unable to compile another chunk |
| E4 escape hatches | partial | Sanitized env, pcall/xpcall, nested coroutine, binary load, memory and C-call checks pass; native callbacks block synchronously |
| E5 state lifecycle | pass | 100 create/drop + 100 failed activations + 1,000 aborts; memory +0.02%, objects +1 |
| E6 callback marshalling | partial | Values and re-entrancy work; raw pulled functions are unhooked; stale callback ids untested |
| E7 shell framing | pending | Needs a real-window shell spike and snapshot/restore test |
| E8 ghost alignment and Unicode | partial | Segmentation and split detection pass; pixel alignment needs a window |
| E9 input filter/IME | pending | Manual window matrix |
| E10 widget catalog | pending | UI spike |
| E11 event bus isolation | pending | Not built yet |
| E12 reference vertical slice | pending | Throwaway spike and three users |
| E13 packaging and consent | pending | Archive validator and five-user consent walkthrough |

## Gate A checklist

- [x] Probe harness and reproducible scripts checked in.
- [x] E2, E3, E4, E5, E6, E8 run headless and write machine-readable results.
- [ ] E1, E7, E9, E10, E11, E12, E13 reported.
- [ ] E3 passes or has an approved fallback that preserves safety and usability.
- [ ] E4 passes or its native-callback limitation is explicitly accepted.
- [ ] E7, E8 and E9 pass.
- [ ] Windows and Linux packaged builds load the pinned addon.
- [ ] API surface, permission catalogue, manifest schema and error codes are signed off.
- [ ] Phase 1 plan, test plan and rollback plan approved.
- [x] No product code changed in Phase 0.

**Decision recorded for Phase 1:** the instruction budget is **250k** (250 hook
firings x 1,000 instructions), the safer target from F1, and a non-sentinel VM
error is fatal to the mod's Lua state: the state is dropped and recreated on the
next activation. The 1M production budget is not safe on the measured build. See
`probe-report.md` finding F1 and `mod-core.md`.

## Reproduction

```bash
godot --headless --path . --script res://Tools/phase0_probe/run_probe.gd
```

Results are written to `Tools/phase0_probe/out/probe-results.json`. The measured
run is Windows 10.0.26300, Godot 4.7.2 stable (`ed1daf0bf`), with the bundled
LuaAPI addon. Linux and packaged-build runs are still required.

## Documents

- [Probe report](probe-report.md) — measured results, findings and pending work.
- [Contracts](contracts.md) — proposed API, permissions, manifest, errors, events and learning contracts.
- [Phase 1 plan](mod-core-plan.md) — backlog, test plan and Gate B criteria.
