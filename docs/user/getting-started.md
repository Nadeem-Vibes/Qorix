# Getting started with Qorix

This guide takes you from an empty desktop to running your first program. It
assumes no prior programming experience. If you already know another editor,
skim sections 2 and 4 and you are done.

Qorix is a **desktop** application. Nothing you type ever leaves your
computer: there is no account, no cloud sync and no telemetry.

---

## 1. Install

**Windows 10/11 (x86_64)** is the supported platform. Download the installer
(or the portable ZIP) from the project's releases page and run it. Linux
x86_64 and macOS builds exist as previews.

Two things are useful but optional:

| Tool | What it unlocks | Where to get it |
| --- | --- | --- |
| Python 3 | Running `.py` files and the Python debugger | [python.org](https://www.python.org/downloads/) — tick **"Add python.exe to PATH"** in the installer |
| Git | Save points, the Source Control dock, changed-line markers | [git-scm.com](https://git-scm.com/downloads) |

Qorix does not install these for you, but on Windows the Python and
Node.js install cards offer a one-click **Install with winget** option: a
confirmation dialog shows the exact command, and the installer runs in a
visible terminal tab. If no runtime is installed at all, Qorix says so
with a friendly card and a link — you can always install it later and keep
going.

---

## 2. The first launch

A fresh installation starts in **Beginner Mode**:

- larger text, so the editor is readable from further away,
- plain-language setting names ("Easier-to-read text" instead of "Dyslexia-friendly font"),
- a simpler settings list and simpler menus (Debug, Language and Source Control categories are hidden),
- a reminder before destructive actions,
- **History** turned on: Qorix keeps automatic local snapshots of your files, so closing without saving or a bad edit is always recoverable.

Everything is reversible. Turn Beginner Mode off any of these ways:

- the **Beginner Mode** checkbox on the welcome screen,
- **Preferences → Getting Started → Beginner Mode**, or
- the command palette (`Ctrl+Shift+P`) → **Beginner Mode**.

Turning it off restores your previous text size and zoom and brings back the
full interface. Turning it on again is just as safe.

---

## 3. The two-minute tutorial

With no file open, the **Welcome** screen appears. Press **Start the tutorial**
(or use the command palette → **Start Tutorial**) and follow the four steps:

1. **Open or create a file** — the easiest is **New from Template → Python script**.
2. **Type a line of code** — click anywhere in the file and edit it.
3. **Run your code** — press the **Run** button or `F5`. Qorix saves first, then runs.
4. **See your output** — the Run panel opens at the bottom with your program's output.

The tutorial resumes where you left off if you close the app. You can replay
it at any time from the Help menu.

---

## 4. The built-in Python Journey course

Qorix ships with a complete five-lesson Python course, built into the
app. It teaches `print()`, variables, types, conditionals and loops — the
exact foundations every beginner needs.

Start it from:

- the **LEARN PYTHON** section on the welcome screen (five lessons + progress),
- **Help → Python Journey**,
- or the command palette (`Ctrl+Shift+P`) → **Python Journey** (`Ctrl+Alt+J`).

Each lesson has two steps:

1. **Type it** — the target line(s) appear as ghost text in the lesson file.
   Wrong keys are refused; hints pop up at the marks that matter.
2. **Make it yours** — edit the file freely, then press **Check my code**.
   With a workspace open and Python 3 installed, the saved program is run and
   its output is graded. Without them, your code is checked as text instead —
   and Qorix tells you which it is using.

Your progress is saved on this computer (`python_journey_progress.json` in the
user-data folder) and the course resumes where you left off. Lesson files
live in `<workspace>/python_journey/`; existing files are reused, so you keep
your edits.

The course is translated into German and Spanish (`python_journey.de.json`,
`python_journey.es.json`) and follows the UI language selected in
**Preferences → Interface Language**. Error explanations and the error cards
are translated the same way.

Completing all five lessons does the following, in order: your first typed
program runs, you read its errors, you fix them, and you know Qorix well
enough to explore everything else it can do.

---

## 5. Running a file, and understanding errors

Press `F5` to run the current file. The output panel shows:

- the command line and folder your program ran in,
- streaming output while it runs,
- the exit code,
- short, plain-language explanations of common errors, with a **Show me the fix** link,
- install cards when Python/Node/GCC/etc. is missing.

Programs that need to read the keyboard (`input()` in Python) run in the
integrated terminal instead. For other languages, press `F6` (**Run Current
File in Terminal**).

Every error explanation has **This explains it / Still confusing** links. Your
vote is stored **only on this computer** and helps make future explanations
clearer — nothing is sent anywhere.

Clickable `file:line` links in the output jump straight to the offending line.

---

## 6. Undo mistakes without thinking about it

- **History** (File → **Previous Versions…**) keeps up to 50 automatic
  snapshots per file from the last seven days: before every save, every run,
  every close and once a minute while you are editing. Local disk only.
- **Save point** (the toolbar button, or the command palette) stages and
  commits everything with a timestamped message. It is the simplest way to
  checkpoint before a risky change. It needs Git on your PATH.
- **Autosave** saves the active file in the background; files that changed on
  disk outside the editor are never overwritten — Qorix offers **Reload**,
  **Keep mine** or a side-by-side **Compare** instead.

---

## 7. Getting unstuck while reading code

Hover a keyword (Python, JavaScript, HTML, CSS, C) and, when the language
server has nothing to say, a plain-language card appears: what the word means,
in normal words, with a tiny example. Move the pointer away and it goes away.

The **Explain This** command (Help menu) explains the current word or
selection even when hover is off.

If a word has no explanation yet, Qorix says so honestly instead of
making one up.

---

## 8. The welcome screen, any time

**Help → Welcome Screen** reopens it. From there you can:

- start from a template (Python, a web page, a C program or an empty file),
- reopen a recent file or folder,
- replay the tutorial,
- toggle Beginner Mode.

---

## 9. When you are ready for the full interface

Beginner Mode is a scaffold, not a ceiling. Turn it off (see section 2) and
everything Qorix can do appears: the debugger (`Ctrl+F5`), Source Control
(`Ctrl+Shift+G`), language servers (`Ctrl+Space`-style completion, rename,
go-to-definition `F12`, all with undo), global search (`Ctrl+Shift+F`), the
command palette (`Ctrl+Shift+P`), and every Preferences setting.

A short guided walkthrough of the full interface is also available as the
Python Learning Journey sample mod in the repository, if you prefer the
mod-based version with signed distribution and per-mod updates.

---

## 10. Getting help

- **Ctrl+I** opens the interactive introduction inside the app.
- **Help → About Qorix** shows the version and keyboard cheatsheet.
- The documentation lives in the repository under `docs/user/`, one guide per
  topic (running code, the debugger, Git and save points, accessibility and
  localization).
- Report bugs privately via `SECURITY.md`, or with a public issue on the
  project's issue tracker.

---

## 11. Privacy, in one line

Qorix runs locally. Your files, your settings, your history and your
feedback votes stay on your machine. No account is required, nothing is
uploaded, and no language model ever reads your code.
