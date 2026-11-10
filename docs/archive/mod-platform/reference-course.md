# Phase 4 — Five-lesson reference course

Status: **content and headless gates complete; window evidence pending.** Scope:
the five-lesson Python course, navigation and progress, hints, hybrid
(typing + freeform) exercises, onboarding, accessibility, the localization
scaffold, a performance pass, screenshots and the user/mod-author guides.

The reference mod is
`../../samples/mods/griddycode.python_journey/1.0.0/` (API 1, minimum editor
1.4.0). Public distribution, signatures and the release feed are Phase 6 and
are not part of this phase.

## Gate E (exit criteria)

| Gate E item | Automated evidence | Window evidence |
| --- | --- | --- |
| Five lessons complete end to end | `test_mod_phase4_samples.gd` validates the ordered index, five lesson tables, both phases and the validation specs; `test_mod_phase4_runtime.gd` runs onboarding → lesson → typing → freeform → completion → next/previous → retry → commands → leave | Not run here (needs a desktop build, real keyboard and a Python runtime) |
| Keyboard-only path | Every action is a command plus a focusable button; `Ctrl+Alt+J/N/P/H` are bound; help explains `Tab`, `Enter` and the host panic; the runtime suite invokes every command and handler | Not run here (focus traversal and the real input path need a window) |
| Screen-reader path | Lesson buttons carry number/title/status tooltips, progress and fallback text are localized, and the help dialog names every shortcut; locale parity is checked | Not run here (needs the OS screen reader) |
| Performance budgets | 100 full shell layouts build in one headless run under a 2 s regression guard; both layouts pass `ModWidgetCatalog.validate` (200 widgets / depth 8); the course inherits the Phase 1 dispatch and instruction budgets | Not run here (typing latency, frame time and real lesson-switch rendering) |
| Documentation complete | This page, [user guide](../../mods/course-user-guide.md), [mod-author guide](../../mods/course-author-guide.md), the sample README and the [screenshot capture checklist](reference-course-screenshots.md) | Screenshots pending |
| No blocking bugs | **4626 checks across 69 suites, exit 0**; the Phase 4 runtime suite executes the actual `main.lua` against a sandbox stub and caught two real bugs during development (a missing module table and a forward declaration) | Not run here |
| Partial-UI fallback works with a clear explanation | The runtime suite covers two branches: a host without `ui.shell`, and a takeover refused with `shell.busy` (the realistic trigger, because consent grants the declared permissions together). Both assert the side panel mounts, no shell is created, and the first label names the reason; the layout is also validated by the catalog | Not run here (panel framing and focus) |

The window column is deliberately explicit. Phase 4 was verified headlessly,
like Phase 3. The authoritative end-to-end run is the Phase 6 release
checklist on a desktop build; see [Pending window checks](#pending-window-checks).

## What was built

### Course flow

The mod owns the screen through `editor.ui.shell.takeover` when `ui.shell` is
granted. The shell layout is intentionally lesson-independent: lesson data
changes labels and editor content, never the widget tree. A lesson switch exits
and re-takes over the shell (API 1 shells are static), while the partial panel
is diffed in place with `editor.ui.update` and its handlers are re-bound after
every update.

Each lesson is a `hybrid` exercise:

| Phase | Engine | Checks |
| --- | --- | --- |
| 1. Typing | `editor.guide` | strict/coach mode, marks, hints, progress events; advances after the target text passes |
| 2. Freeform | `editor.exercise` | text checks when no trusted workspace is available; `stdout_contains` / `stdout_regex` / `exit_code` when the saved file can run |

Run-backed validation reuses the Phase 3 RunService path. If the workspace is
missing, untrusted, or the host does not allow `run` in this session, the
freeform phase falls back to the lesson's text tests and the coach panel names
the exact reason (`course.run.no_workspace`, `course.run.no_trust`,
`course.run.no_permission`, `course.run.no_file`).

### Lessons and files

| # | Lesson | Course file | Skill |
| --- | --- | --- | --- |
| 1 | Hello, Qorix | `python_journey/01_hello.py` | `print()` and strings |
| 2 | Variables | `python_journey/02_variables.py` | names and assignment |
| 3 | Types | `python_journey/03_types.py` | numbers vs text, `type()` |
| 4 | Conditionals | `python_journey/04_conditionals.py` | `if` / `else` |
| 5 | Loops | `python_journey/05_loops.py` | `for` and `range()` |

Course files are created through `files.write` (which auto-creates the folder)
and opened through `docs.open`; an existing file is reused. Without a trusted
workspace the lesson is an untitled document and validation is text-only.

### Navigation, progress and hints

- Previous/next lesson, direct lesson buttons and commands.
- Progress keys `lessons.<id>.typed`, `lessons.<id>.done`, plus
  `course.last` and `onboarding.seen`. Progress survives restarts and the
  course resumes at the last lesson, otherwise the first incomplete lesson.
- Onboarding appears once; the help dialog is always available.
- Hints come from lesson data per phase and can be automatically shown,
  requested with **Hint**, or turned off with the `show_hints` setting.

### Accessibility

- All actions are buttons with focus; the host provides `Tab` traversal and
  `Enter`/`Space` activation.
- Lesson buttons expose number, title and status through tooltips; progress has
  a “N of 5 lessons complete” label and a tooltip.
- Status, hints and the reason a run is unavailable are visible text, not color
  alone. The partial panel repeats the current phase and progress.
- The help copy names `Tab`, `Enter` and `Ctrl+Alt+Shift+Esc`.
- The three settings (`strict_mode`, `show_hints`, `font_size`) cover key
  filtering, hint density and text size.

A real windowed screen-reader pass remains the Gate E manual check; the sample
does not use raw input or focus traps.

### Localization scaffold

- Runtime strings: `content/locales/en.lua`, loaded with
  `editor.content.load("locales/en")` (`assets.read_text` is restricted to
  `assets/`, so the locale lives under `content/`).
- Translator template: `locales/en.json` with exactly the same keys.
- `lib/i18n.lua` provides `t(key, vars)`, `{placeholder}` interpolation, a
  missing-key fallback to the key itself, and built-in English text for the
  fallback reasons if the locale cannot load.
- The Phase 4 suite checks key parity, string types, interpolation placeholders,
  and that every `t("key")` used by `main.lua` and `lib/layout.lua` exists.
- To add a language, copy both files and point `lib/i18n.lua` at the new
  runtime table; see the sample README.

### Performance pass

The course is deliberately small and static:

- Five lesson tables and one ~70-key locale are loaded once; lookups are table
  reads.
- The shell tree is rebuilt only when the screen changes (lesson switch,
  exercise state change), not per keystroke. The guide overlay is host-owned.
- No `editor.every`/timer polling, no per-frame tasks and no event storm: the
  mod listens to `exercise.*` events and updates on transitions.
- Both layout specs fit the catalog limits (200 widgets, depth 8); the headless
  suite builds 100 full layouts in a single run under a 2 s guard (the guard is
  deliberately loose to avoid CI flakiness).
- The host budgets from Phase 1 still apply: 250k instructions per resume,
  2 ms/frame event dispatch, 25 ms hard wall clock per resume.

Real typing latency, frame time and lesson-switch rendering belong to the
window checklist below.

## File map

```text
samples/mods/griddycode.python_journey/1.0.0/
  manifest.json            id, version, API/min editor, permissions, settings
  main.lua                 commands, events, shell/partial flow, state
  lib/course.lua           load/validate content; find/next/previous
  lib/engine.lua           hybrid phase specs, state helpers, hints
  lib/progress.lua         progress keys and maps
  lib/i18n.lua             locale loading, t(), interpolation
  lib/layout.lua           full shell and partial-panel layout specs
  content/index.lua        ordered lesson paths
  content/lessons/*.lua    five data-only lessons
  content/locales/en.lua   runtime strings
  locales/en.json          translator template
  README.md                install, use, settings, localization
```

The mod asks for `ui.shell`, `documents.read`, `documents.write`, `files.read`,
`files.write`, `workspace.read` and `run`; it does not ask for network, raw
input, clipboard or storage beyond progress.

## Verification

```bash
godot --headless --path . --script res://tests/test_runner.gd
```

Phase 4 suites:

| Suite | Covers |
| --- | --- |
| `test_mod_phase4_samples.gd` | manifest/permissions/settings, every Lua file compiles, module return values, five ordered lessons, typing/freeform schema, hybrid phase construction, navigation, progress/hint helpers, locale parity/interpolation/used keys, accessibility and fallback copy, catalog validation and the layout build budget |
| `test_mod_phase4_runtime.gd` | executes `main.lua` against a Lua stub: onboarding, shell takeover, hybrid start, typing→freeform transition, text submit, completion, navigation, help, failure/retry, all six commands, deactivation, both partial-fallback branches (missing capability and `shell.busy`) and a run-backed lesson open |

Last full run: **4626 checks across 69 suites, exit 0.** The runtime suite found
and fixed two issues that compilation could not: `lib/layout.lua` was missing
`local M = {}`, and `open_lesson` needed a forward declaration before the
lesson-button closures were built.

## Known deviations

- **Screenshots are pending.** There is no display in the headless test
  environment; the capture checklist and intended file names are in
  [`reference-course-screenshots.md`](reference-course-screenshots.md).
- **Window checks are pending.** Keyboard-only, screen-reader, real IME,
  frame-time and real RunService validation need a desktop build. These are the
  same class of checks left open by Phase 3.
- **Shell layouts are static.** Switching lessons re-takes over the shell
  instead of diffing it; this is an API 1 constraint and keeps the sample
  honest.
- **Text fallback is pattern-based.** Without a workspace/run, a submission can
  pass by matching text without executing. The panel says so; run-backed
  validation is preferred whenever available.
- **One course at a time.** The host allows one shell and one guide/exercise
  session; a second owner is refused by the host, not queued.

## Pending window checks

Run these on a desktop build before the Phase 6 release:

1. **Five lessons end to end** with Python available and a trusted workspace;
   complete all five, including the freeform checks and progress after restart.
2. **Keyboard only**: open the course, traverse every button with `Tab`, start,
   type, submit, retry, change lesson, open help and leave without a mouse.
3. **Screen reader**: confirm lesson names, status, progress and the fallback
   reason are announced; verify the help dialog is readable.
4. **Partial UI**: make another mod’s shell active so the takeover returns
   `shell.busy`, open the course and confirm the reason and every action. If a
   host build without `ui.shell` is available, repeat with it.
5. **Performance**: measure typing latency and lesson-switch frame time during
   the typing phase at 60 Hz; compare keystroke latency with the Phase 1
   baseline (under 10% regression).
6. **Panic/restore**: `Ctrl+Alt+Shift+Esc` from the shell and from a lesson,
   then verify the core layout is restored exactly.
7. **Screenshots**: capture the list in the screenshot checklist.
