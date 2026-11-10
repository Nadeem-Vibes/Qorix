# Python Learning Journey — user guide

> **Note:** Qorix now ships Python Journey **built in** — five guided
> lessons on the welcome screen, from your first `print()` to your first
> loops. It needs no installation, no permissions and no mods. See
> [the getting started guide](../user/getting-started.md). This document
> describes the sample **mod** version, which remains available in the
> repository for contributors and as the reference shell course.

Python Learning Journey is a five-lesson course that runs inside Qorix. It
teaches `print`, variables, types, conditionals and loops. Each lesson is a
short typing exercise followed by a small edit you make yourself.

The course is a mod: it can own the screen, keep progress, and run your saved
Python file when the workspace is trusted. Nothing is sent anywhere.

## Install

1. Quit Qorix.
2. Copy the mod folder so the result is:

   ```text
   %APPDATA%\Godot\app_userdata\Qorix\mods\griddycode.python_journey\1.0.0\manifest.json
   ```

   On macOS/Linux use `<Godot user data>/Qorix/mods/griddycode.python_journey/1.0.0/`.
   The folder name must stay `griddycode.python_journey` and the version folder
   must match the manifest (`1.0.0`).

3. Start Qorix, open **View → Mods…**, select **Python Learning Journey**
   and grant the permissions after reviewing them.
4. Enable the mod. If the course does not open from its shortcut, use the
   command palette and run **Python Journey: Open Course**.

The mod asks for `ui.shell`, `documents.read`, `documents.write`, `files.read`,
`files.write`, `workspace.read` and `run`. These are used to take over the
screen, edit the lesson document, create `python_journey/*.py` files in your
workspace, read the workspace state and run the saved program. No network,
raw input or clipboard access is requested.

## First run

The first time you open the course, an onboarding dialog explains three things:

- the course creates or reuses Python files in a `python_journey` folder,
- the course can still run without a workspace, but checks become text-only,
- every action has a keyboard route, and `Ctrl+Alt+Shift+Esc` always exits.

Choose **Start** to open the first lesson, or **Later** to close the dialog.
The dialog appears only once; **Help** shows the same guidance later.

If you want saved files and run-backed checks, open a folder in Qorix and
trust it when prompted **before** starting a lesson. Without a workspace, the
lesson is an ordinary untitled document.

## The lesson screen

The shell shows the course title and progress at the top, the real code editor
in the middle, and a coach panel on the right.

1. **Typing phase.** The coach shows the target line and **Start** resets the
   lesson file to its starter text. Ghost text shows what to type next. In the
   default strict mode, wrong keys are blocked and counted; mark hints explain
   the important pieces. The phase advances automatically when the line matches.
2. **Freeform phase.** Read the prompt and make the requested edit yourself.
   **Check** submits it. When a trusted workspace and the `run` permission are
   available, Qorix runs the saved file and checks stdout and the exit
   code. Otherwise the submission is checked against text patterns and the
   panel says why the run is unavailable.

**Retry** restarts the current phase after a failed check. **Next lesson**
appears when the exercise is complete. You can jump to any lesson from the
lesson list at any time.

Progress is saved per lesson (`typed` and `done`). When you reopen the course it
resumes at the last lesson, or at the first incomplete lesson. There is no
in-app progress reset in version 1.

## Controls

| Action | Button | Shortcut |
| --- | --- | --- |
| Open the course | — | `Ctrl+Alt+J` |
| Next lesson | **Next lesson** | `Ctrl+Alt+N` |
| Previous lesson | **Previous** | `Ctrl+Alt+P` |
| Show a hint | **Hint** | `Ctrl+Alt+H` |
| Start / restart the lesson | **Start** | — |
| Submit the freeform phase | **Check** | — |
| Retry after a failed check | **Retry** | — |
| Help | **Help** | — |
| Leave the course | **Leave course** or the host **Exit mod** strip | `Ctrl+Alt+Shift+Esc` (host panic) |

Shortcuts are normal Qorix keybindings and can be rebound from the
keybindings settings. The commands also appear in the command palette under
**Mods**.

### Keyboard only

Use `Tab` / `Shift+Tab` to move focus and `Enter` or `Space` to activate a
button. Buttons are in reading order: lesson list, then the phase actions, then
help and leave. The code editor keeps its normal keyboard behavior. The host
panic shortcut always works, even while the guide owns typing.

### Screen readers

Lesson buttons announce the lesson number, title and status; progress announces
“N of 5 lessons complete”; the status line and the fallback explanation are
plain text. All of this copy comes from the locale table, so a translation can
cover it. A formal screen-reader pass is part of the release checklist; report
anything that is not announced clearly.

## Workspace, trust and run checks

| Situation | What happens |
| --- | --- |
| Workspace open, trusted, `run` granted, Python available | Lesson files live in `python_journey/`; **Check** runs the saved file and validates stdout and the exit code. |
| No folder open | The lesson is untitled; **Check** uses text patterns. The coach explains that run checks are unavailable without a workspace. |
| Folder open but not trusted | The same text fallback; the reason is `trust required`/not trusted. |
| `run` unavailable in this build/session | Text fallback; the reason names the missing capability. |
| No Python runtime / run fails to start | The run error is shown by Qorix; fix the interpreter and **Check** again. |

The course writes through the same file API as any other mod, so an existing
`python_journey/01_hello.py` is never overwritten. Delete or rename the file if
you want a clean starter.

## Settings

Open **View → Mods…**, select the course and edit its settings:

| Setting | Default | Meaning |
| --- | --- | --- |
| **Strict typing (block wrong keys)** | on | Off is coach mode: mistakes are counted, but keys are not blocked. |
| **Show hints automatically** | on | Show the phase hint in the coach panel. **Hint** still works when off. |
| **Lesson text size** | 16 | 12–32; the code editor keeps its own size. |

## If the course uses the side panel

`ui.shell` is optional at the host level. If the capability is missing, another
mod already owns the screen (the shell is exclusive), or the takeover fails,
the course opens in the right panel (or the center panel if the right is full).
The first line explains the reason:

- the missing `ui.shell` capability in this build,
- the host error code (for example `shell.busy`),
- or “no free panel slot”.

The panel keeps every action and the same lesson flow. Lesson changes update
the panel in place. If another mod owns the screen, leave its shell and reopen
the course to get the full-screen layout.

## Troubleshooting

**The mod is not listed.** Check the folder is
`mods/griddycode.python_journey/1.0.0/manifest.json`, restart Qorix, and
look at **View → Mods…** for a status or failure reason. A minimum editor
version below 1.4.0 or a missing permission blocks activation.

**The course will not open.** Run **Python Journey: Open Course** from the
command palette. If the shell is busy, the panel explains it; another mod’s
shell must exit first.

**Checks always use text.** Open and trust a workspace, grant `run`, and make
sure Python is installed. The coach line above the buttons tells you which gate
is missing.

**My edits disappeared.** **Start** resets the lesson document to the starter
text by design. Use **Check** to submit without resetting. With a workspace,
the file is saved before a run check.

**I want to leave immediately.** Press `Ctrl+Alt+Shift+Esc` (host panic) or the
**Exit mod** strip. A second panic press within two seconds disables all mods
for the session.

## Uninstall

Disable the mod in **View → Mods…** and remove
`mods/griddycode.python_journey/` from the user data folder. Course files in
your workspace are ordinary files and are not removed by the mod.

For the design and authoring details, see the
[course author guide](course-author-guide.md) and the
[sample README](../../samples/mods/griddycode.python_journey/1.0.0/README.md).
