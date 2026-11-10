# Phase 3 — Shell and learning engine

Status: **complete; automated gates pass, window checks outstanding.** Scope is §16.3 of the architecture plan:
exclusive shell takeover with host chrome and exact restore, the guide input
pipeline (matcher, filter, ghost overlay, hint layer), and the exercise engine
(typing, freeform and hybrid) with validation through RunService. The full
five-lesson reference course is Phase 4, documented in
[`reference-course.md`](reference-course.md); distribution remains Phase 6.

## Gate D (exit criteria)

| Gate D item | Automated evidence | Window evidence |
| --- | --- | --- |
| Shell survives 50 takeover/restore cycles with exact snapshot equality | `test_shell_snapshot.gd`: 50 cycles, deep capture equality, anchors/offsets/z-order restored; `test_shell_service.gd` repeats it through `takeover`/`exit` | Not run here |
| Panic exits within 100 ms | `test_shell_service.gd` measures `panic()` and asserts < 100 ms headlessly | Not run here |
| Lesson 1 completable with the keyboard only | `test_guide_filter.gd`, `test_guide_service.gd` cover the key decisions; the reference sample ships lesson 1 | Not run here (needs a window and a real keyboard/IME) |
| Freeform exercise validates through RunService | `test_exercise_service.gd` drives the run bridge and `run_finished`; `test_mod_phase3_api.gd` covers the `run` + trust gate | Not run here (needs a trusted workspace and a Python runtime) |
| E7–E9 in the integrated build | Matcher tests cover graphemes, half-typed clusters and RTL refusal | Not run here (input path, live IME, Unicode rendering) |
| Reference mod dependency on shell takeover satisfied | `test_mod_phase3_samples.gd` validates the manifest and that `main.lua` uses `ui.shell.*`; the golden surface advertises it | — |

The window column is deliberately explicit: this phase was verified headlessly.
The authoritative end-to-end run is the Phase 6 release checklist on a desktop
build.

The mod-facing contract for the new namespaces is
[`api-reference.md`](../../mods/api-reference.md); the reference mod is
`samples/mods/griddycode.python_journey/1.0.0`.

## Plan

### 1. Ownership and layering

Phase 3 keeps the Phase 1/2 boundaries. Nothing new crosses from Lua into the
editor except the `editor.*` facade:

```
src/features/mods/shell/     ShellService · ModShell · ShellChrome · ShellSnapshot
src/features/learning/guide/     GuideService · GuideMatcher · GuideFilter · GuideOverlay · GuideHintLayer
src/features/learning/exercise/  ExerciseService · ExerciseValidation
src/features/mods/api/       api_v1.gd adds ui.shell.*, guide.* and exercise.* dispatch
src/features/mods/sdk/       sandbox.lua adds the three Lua namespaces
```

- `ShellService` is host-owned and exclusive. It snapshots the core HUD, hides
  the panels it is allowed to hide, applies camera insets, and restores the
  snapshot exactly. Host chrome is outside mod control.
- `GuideService` owns one guided session at a time. It reconciles text, feeds
  the overlay, and publishes the `guide.*` catalogue.
- `ExerciseService` owns exercise state. A typing exercise delegates matching,
  ghosting and filtering to `GuideService`; a freeform exercise is a session
  over the document with a submit; a hybrid exercise is a phase list.
- `ExerciseValidation` is shared by both services. Text checks are synchronous;
  run-based checks start a RunService run and resolve from `run_finished`.

### 2. Matching and filtering (pure)

`GuideMatcher` compiles a target once and exposes:

- grapheme clusters (shared with `mod_text_columns.gd`, so a mod cannot create a
  state the document API refuses),
- prefix reconciliation with a fast path from the previous prefix,
- mark resolution (`{id, text}` found sequentially and never overlapping),
- ghost slices for the four display scopes,
- progression chunks for character/word/line/none,
- expected indentation for Enter and Tab.

`GuideFilter` is a pure decision function. It receives a semantic key event
(`text`, `backspace`, `enter`, `tab`, `other`) and a session context, and returns
`pass`, `swallow` or `insert`. Correct characters pass through natively, so
undo, key repeat, IME commit and rendering keep working. Only mismatches and
structural keys are intercepted.

The default is `progression = "character"` with `display.scope = "line"`.
Mode (`strict`/`coach`), progression and display are independent.

### 3. Input path

```
InputController._input (before GUI)
  ├─ Ctrl+Alt+Shift+Esc → host panic (never reaches a mod)
  └─ active guide session? → GuideService.filter(event)
        pass    → let CodeEdit insert natively
        swallow → mark the event handled, count the mistake
        insert  → mark the event handled, insert the expected chunk
```

Filtering in `_input` is deliberate: `CodeEdit` receives text in
`_gui_input`, which runs after `_input`, so a swallowed key can never reach the
widget. When the guide is paused, diverged, or the caret is not at the expected
position, every key passes.

### 4. Ghost rendering and hints

`GuideOverlay` is a world-space `Node2D` under `EditorHost`, so it inherits the
camera pan and zoom. It draws one `draw_string` per ghost cluster, the next
cluster box, and a short-lived mistake flash. It repaints on text change, caret
move, camera change and resize. The ghost is capped at 64 characters and 8
lines.

`GuideLayout` resolves ghost geometry. `TextEdit.get_rect_at_line_column`
describes the cell that *ends* at a caret column, and ghost clusters usually
start past the end of the real line, where the editor returns an invalid rect.
The layout module anchors the first cluster at the caret (line start plus the
measured typed prefix), advances the remaining clusters with the editor theme
font's metrics, and uses the stylebox top margin for the first line of an empty
document. The ghost baseline adds the same leading the editor applies inside a
line, so ghost glyphs, the next-cluster box, the caret and the hint bubble all
share the editor's coordinates. The overlay and the hint anchor both use it.

`GuideHintLayer` is a screen-space `Control` in the HUD. It projects the anchor
through `CanvasItem.get_global_transform_with_canvas()`, clamps the bubble to
the viewport, and auto-dismisses. Hints fire on start, mark entry, the Nth
mistake, idle, segment completion, divergence and completion.

Known limits (documented, not fixed in v1): ZWJ emoji may split into multiple
clusters, RTL targets are refused with `guide.unsupported`, folds are not
disabled (guidance forces no-wrap, no auto-indent, no auto-brace and no
completion), and the ghost of a partially typed cluster starts at the typed
prefix.

### 5. Shell framing

`ShellService.takeover(mod_id, spec)`:

1. Rejects a second owner with `shell.busy`.
2. Validates the layout with the widget catalog and rejects more than one
   `editor` widget (`shell.editor_slot`) — v1 has one code viewport.
3. Captures `ShellSnapshot` for every core panel: visibility, anchors, offsets,
   position, size, z-order and parent. Position and size are recorded for
diagnostics; restore writes anchors and offsets (the authoritative pair) and
only falls back to position/size for older entries.
4. Adds `ModShell` above the core HUD (layer 100); host chrome is its first
   child and the layout starts below the 34 px strip.
5. Builds the layout, reserves the `editor` rectangle, hides the core panels and
   applies camera insets: `left`, `top`, `right`, `bottom`.
6. `exit()` restores the snapshot, the insets and the world visibility.

Host chrome is a 34 px strip with the mod name, **Exit mod** and the panic hint.
It cannot be hidden or restyled. Panic is handled in the root input path: the
first press exits the shell, a second press within two seconds disables all mods
for the session.

### 6. Exercise model

| Kind | Engine | Ghost/filter | Validation |
| --- | --- | --- | --- |
| `typing` | GuideService | yes | text and/or run |
| `freeform` | ExerciseService | no | tests, stdout, exit code, custom |
| `hybrid` | phase list | per phase | per phase |

Session states: `idle → starting → active ⇄ paused`, plus `diverged`,
`validating`, `passed`, `failed`, `completed`, `stopped`. `completed` is
terminal; `failed` is recoverable with `retry`. Checkpoints are text snapshots at
phase and segment boundaries, capped at 20 and kept for the session only.
Progress semantics stay in the mod (`editor.progress`); the host reports stats
(duration, attempts, mistakes, hints).

### 7. Validation

`ExerciseValidation` supports `exact_text`, `contains`, `regex`,
`stdout_contains`, `stdout_regex`, `exit_code`, `tests` and `custom`.

- Trailing-newline tolerance for `exact_text`; normalized line endings.
- `tests` is an ordered list with partial results and `stop_on_fail`.
- Run-based checks share one run and resolve on `run_finished`; a run past
  `timeout_ms` fails with `run.timeout` and the run is stopped.
- `custom` emits a validation request with a token and a snapshot; the mod
  answers through `guide.resolve_validation`, which the host routes to the
  active guide or exercise session owned by the caller.

Run-based validation is gated twice: the API requires `run`, and `run` is
intersected with workspace trust exactly as in Phase 2.

### 8. New API surface (24 methods)

| Namespace | Methods | Permission |
| --- | --- | --- |
| `ui.shell` | `takeover`, `exit`, `set_editor_visible`, `set_content_insets` | `ui.shell` |
| `guide` | `start`, `state`, `pause`, `resume`, `reset`, `stop`, `hint`, `set_target`, `set_validation`, `resolve_validation`, `set_mode`, `set_progression`, `set_display` | `documents.read`; `reset` needs `documents.write`; `hint` is `core` |
| `exercise` | `start`, `state`, `submit`, `retry`, `stop`, `hint`, `advance` | `documents.read`; `retry`/`advance` need `documents.write`; `hint` is `core` |

`exercise.start`, `exercise.submit`, `guide.start` and `guide.set_validation`
also need `run` when the session's validation/tests execute a program; the
guard runs before the service sees the call. Guide/exercise methods read the
document, which is why they are not `core`.

### 9. New result codes

`guide.invalid_spec`, `guide.unsupported`, `exercise.invalid_spec`,
`exercise.unknown`, `exercise.invalid_state`, `shell.invalid_spec`,
`shell.insets_invalid`, `shell.editor_slot`.

Codes keep their contract meaning; a conflict (a second shell owner, a guide
already running) is `shell.busy` / `state.invalid`, not a new code.

### 10. Widgets added for the shell

`editor` (reserved rectangle), `heading`, `code_block`, `grid`, `badge`, `tabs`
and `canvas` (retained display list of line/rect/text ops). `width`, `height`
and `grow` are now honoured. `icon_button`, `tree` and `image` need the asset
handle work planned for Phase 4 and are not advertised in this phase.

### 11. Verification

```bash
godot --headless --path . --script res://tests/test_runner.gd
```

| Suite | Covers |
| --- | --- |
| `test_guide_matcher` | compile, marks, graphemes, prefix fast path, ghost scopes, chunks, Unicode and RTL refusal |
| `test_guide_layout` | ghost anchors, editor theme font and baseline, empty-document origin, prefix measurement |
| `test_guide_filter` | progression modes, strict/coach, Enter/Tab/Backspace, caret and selection pass-through |
| `test_guide_service` | lifecycle, progress/mistake/divergence events, hints, validation pass/fail, teardown |
| `test_exercise_validation` | text checks, run checks, partial results, custom tokens, timeouts |
| `test_exercise_service` | typing/freeform/hybrid, run-backed submit, retry checkpoints, stats |
| `test_shell_snapshot` | 50 capture/hide/restore cycles, exact equality, inset maths |
| `test_shell_service` | takeover/exclusivity, editor slot, insets, panic timing, exact restore |
| `test_mod_phase3_api` | permission annotations, missing services, run gating, golden (100 entries) |
| `test_mod_phase3_samples` | reference sample manifest, lesson content and demonstrated surfaces |

At Phase 3 completion: **3600 checks across 67 suites**, exit 0, including the
Phase 1/2 suites and the 100-method golden. A 120-frame headless boot of the
editor also starts the mod services with no script or null-instance errors. The
Phase 4 suites extend this baseline; see
[`reference-course.md`](reference-course.md#verification).

### 12. Risks and explicit deviations

- **Camera insets are advisory.** The code stays a world under the camera; the
  panels overlay it and the camera centres the caret in the safe rectangle. There
  is no scissor.
- **One code viewport.** Two `editor` widgets in one shell are rejected.
- **Folds and proportional fonts.** Guidance disables wrap, auto-indent,
  auto-brace and completion; folds are host state and are not cleared, so ghost
  alignment under an active fold is not guaranteed.
- **`icon_button`, `tree`, `image`** are deferred with the asset-handle API.
- **Run validation is single-flight.** Starting a validation run stops any run
  the user started, exactly like pressing Run. The docs say so.
- **Guide/exercise sessions are exclusive per host.** A second owner gets
  `state.invalid` with a message naming the current owner.
- **Shell layouts are static.** `editor.ui.update` targets partial mounts only,
  so a shell cannot diff its tree in place; exit and take over again instead.
  The reference sample keeps the layout lesson-independent for that reason.
- **Validation spec is an object.** `{type, value}` or `{tests = {...}}`; a bare
  list is refused with `exercise.invalid_spec`.
- **Records.** An active shell is marked in safe mode (`mark_shell`) so a crash
  loop reports "shell" as the last known state; the marker is cleared on exit
  and on panic.
