# Python Learning Journey

A five-lesson Python course for Qorix, built entirely as a mod. It is the
Reference course mod: it uses an exclusive shell takeover, the guide typing
engine, hybrid exercises, progress storage, hints, onboarding, accessibility
text, its own localization files, and a partial-UI fallback when the shell is
unavailable or busy.

API version 1 · minimum editor **1.4.0** · version **1.0.0**.

## What the course does

Each lesson is one hybrid exercise with two phases:

1. **Typing** — the target line is shown as ghost text; strict mode blocks
   wrong keys, mark hints explain the pieces, and the phase advances when the
   target matches.
2. **Freeform** — the learner edits the lesson file and submits. When a trusted
   workspace is available, the saved file is run and its stdout/exit code are
   checked. Without a workspace, trust or the `run` permission, the same
   submission is checked against text patterns and the panel says why the run
   is unavailable.

| # | Lesson | File | What it teaches |
| --- | --- | --- | --- |
| 1 | Hello, Qorix | `python_journey/01_hello.py` | `print()` and string literals |
| 2 | Variables | `python_journey/02_variables.py` | names, assignment and printing a value |
| 3 | Types | `python_journey/03_types.py` | numbers vs text and `type()` |
| 4 | Conditionals | `python_journey/04_conditionals.py` | `if` / `else` |
| 5 | Loops | `python_journey/05_loops.py` | `for` over `range()` |

Progress is stored per lesson (`typed` and `done`) with `editor.progress`, so
the next session resumes at the last lesson and the course list shows what is
complete. The onboarding dialog appears once; **Help** shows the keyboard and
escape instructions at any time.

## Install

1. Copy this folder to the user mod directory, keeping the id/version layout:

   ```text
   %APPDATA%\Godot\app_userdata\Qorix\mods\griddycode.python_journey\1.0.0\
   ```

   On other platforms use
   `<Godot user data>/Qorix/mods/griddycode.python_journey/1.0.0/`.

2. Restart Qorix and open **View → Mods…**.
3. Review the permissions and grant consent, then enable the mod.
4. Open a folder if you want run-backed validation and saved lesson files.
   Trust the workspace when Qorix asks.

The mod asks for `ui.shell`, `documents.read`, `documents.write`, `files.read`,
`files.write`, `workspace.read` and `run`. It never asks for network access,
raw input or clipboard access. Consent grants the declared set together; if the
host does not offer the shell capability, or another mod already owns the
screen, the course still works in the side panel (see
**Partial-UI fallback**).

## Use

Open the course with **Python Journey: Open Course** from the command palette,
the **Mods** menu, or `Ctrl+Alt+J`.

| Action | Control | Shortcut |
| --- | --- | --- |
| Open the course | command / menu | `Ctrl+Alt+J` |
| Next lesson | button / command | `Ctrl+Alt+N` |
| Previous lesson | button / command | `Ctrl+Alt+P` |
| Show a hint | button / command | `Ctrl+Alt+H` |
| Help | button / command | — |
| Leave the course | button / command / shell chrome | `Ctrl+Alt+Shift+Esc` (host panic) |

Lesson buttons jump directly to any of the five lessons. **Start** resets the
lesson file to its starter text and begins the typing phase; **Check** submits
the freeform phase; **Retry** restarts the current phase after a failed check;
**Next lesson** appears when the exercise is complete.

The shell reserves the real editor inside the course layout, so typing and
editing happen in the normal code viewport. The host chrome strip at the top
always shows **Exit mod**; leaving the course or panicking restores the normal
editor layout exactly.

### Keyboard and screen reader

Every action is a focusable button. Use `Tab` / `Shift+Tab` to move focus and
`Enter` or `Space` to activate a control; the lesson list is a series of buttons
in reading order. Each lesson button has a tooltip that names the lesson, its
number and its status, and progress exposes a "N of 5 lessons complete" label.
All course copy comes from the locale table, including the onboarding and help
dialogs and the fallback explanation. A screen-reader pass on a desktop build
is still a manual Gate E check; see
[the archived reference-course record](../../../../docs/archive/mod-platform/reference-course.md).

## Where files go

With a workspace open, the mod creates `python_journey/<lesson>.py` in that
folder through `files.write` and opens it through `docs.open`. Existing files
are reused, so a learner can keep their edits. The folder is created
automatically by the host. Without a workspace or trust, the lesson is an
unsaved document and the panel explains that checks are text-only.

## Settings

Declared in `manifest.json`, editable from **View → Mods…**:

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `strict_mode` | bool | `true` | Block wrong keys during the typing phase. Off means coach mode: mistakes are counted but the expected keys still pass. |
| `show_hints` | bool | `true` | Show the current phase hint in the coach panel automatically. **Hint** always works. |
| `font_size` | int | `16` | Lesson text size, clamped to 12–32. |

## Partial-UI fallback

`ui.shell` is optional at the host level. If the capability is missing, another
mod already owns the screen (the shell is exclusive), or the takeover fails,
the course mounts the same lesson flow in the right panel (falling back to the
center slot) and shows the exact reason:

- the missing `ui.shell` permission in a host without the capability,
- the host error that refused the takeover (for example `shell.busy`),
- or `ui.slot_full` when no panel slot is free.

The panel keeps lesson navigation, progress, the current phase, **Start**,
**Check**, **Hint**, **Retry**, **Help** and **Leave**. A shell layout is
static, so switching lessons refreshes a takeover; the partial panel refreshes
in place with `editor.ui.update` and re-binds its handlers after each update.

## Localization

Runtime strings are loaded with `editor.content.load("locales/en")` from
`content/locales/en.lua`. `locales/en.json` is the translator template with the
same keys and is checked by the reference-course suite. To add a language:

1. Copy `content/locales/en.lua` to `<language>.lua` and translate the values,
   keeping every key and `{placeholder}`.
2. Copy `locales/en.json` to `<language>.json` for translators.
3. Point `lib/i18n.lua` at the new file (or add language selection) and check
   the key parity test in `tests/unit/features/mods/test_python_journey_samples.gd`.

Keys missing at runtime fall back to the key string, and a missing locale table
falls back to built-in English explanations for the fallback reasons, so a
broken translation cannot block the course.

## Development

```bash
godot --headless --path . --script res://tests/test_runner.gd
```

The reference-course suite compiles every Lua file, executes the data-only lesson and
locale tables, validates the manifest and permissions, checks five ordered
lessons, both hybrid phases, navigation helpers, locale parity and
interpolation, accessibility copy and the partial-UI branches. See
`tests/unit/features/mods/test_python_journey_samples.gd`.

The course is split into small modules so content can change without touching
orchestration:

```text
main.lua                 commands, events, shell/partial flow, state
lib/course.lua           load and validate content, find/next/previous
lib/engine.lua           hybrid phase specs, state helpers, hints
lib/progress.lua         per-lesson progress keys
lib/i18n.lua             locale loading and interpolation
lib/layout.lua           full shell and partial-panel layout specs
content/index.lua        ordered lesson paths
content/lessons/*.lua    lesson data
content/locales/en.lua   runtime strings
locales/en.json          translator template
```

The reference course is also the worked example for the mod-author guide:
[`docs/mods/course-author-guide.md`](../../../../docs/mods/course-author-guide.md).
