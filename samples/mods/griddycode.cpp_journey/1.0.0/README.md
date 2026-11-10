# C++ Learning Journey

A five-lesson C++ course for Qorix. It is a real mod, not a mock: it takes
over the shell through the public API, runs a typing phase with `editor.guide`,
then a freeform phase compiled and executed through `RunService`. When a trusted
workspace or a C++ compiler is unavailable, the freeform phase falls back to
text checks and says so in the coach panel.

It is the C++ counterpart to the Python reference course. Both use the same
frozen API 1.0 contract; install either one, or both (their commands and
shortcuts do not collide).

## Lessons

| # | Lesson | Course file | Skill |
| --- | --- | --- | --- |
| 1 | Hello, C++ | `cpp_journey/01_hello.cpp` | includes, `main`, `std::cout` |
| 2 | Variables | `cpp_journey/02_variables.cpp` | `std::string`, `int`, assignment |
| 3 | Types | `cpp_journey/03_types.cpp` | `int`, `double`, `char`, `bool`, `std::string` |
| 4 | Conditionals | `cpp_journey/04_conditionals.cpp` | `if`, `else`, braces |
| 5 | Loops | `cpp_journey/05_loops.cpp` | `for`, counter, squares |

Every lesson has two phases:

1. **Typing** — type the target program. Ghost text shows what comes next,
   mistakes are blocked in strict mode and hints appear by mark.
2. **Freeform** — edit the saved file. With a trusted workspace and `g++` or
   `clang++` on `PATH`, the host compiles and runs it and checks stdout and the
   exit code. Otherwise the lesson uses its text checks.

## Install

Copy the version folder into the editor data directory:

```powershell
$data = Join-Path $env:APPDATA "Godot\app_userdata\Qorix"
$destination = Join-Path $data "mods\griddycode.cpp_journey\1.0.0"
New-Item -ItemType Directory -Force -Path $destination | Out-Null
Copy-Item -Recurse -Force "samples\mods\griddycode.cpp_journey\1.0.0\*" $destination
```

Restart Qorix, open **View → Mods…**, read the consent card and grant the
seven permissions. The course needs a trusted workspace folder to write lesson
files; run checks additionally need a C++ toolchain. `g++` and `clang++` are
both supported by the C++ run configuration.

## Use

- **C++ Journey: Open Course** — command palette, or `Ctrl+Alt+C`.
- **Next lesson** — `Ctrl+Alt+Shift+N`.
- **Previous lesson** — `Ctrl+Alt+Shift+B`.
- **Show a hint** — `Ctrl+Alt+Shift+H`.
- **Leave course** — command palette or the Leave course button.

The host bar always offers a panic exit (`Ctrl+Alt+Shift+Esc`). Progress is
stored per lesson, so closing the editor and reopening resumes at the last
lesson. Settings under **Mods** control strict typing, automatic hints and text
size.

## Validation behaviour

| Situation | What happens |
| --- | --- |
| Trusted workspace, `run` granted, compiler on PATH | The saved `.cpp` file is compiled and run; stdout and exit code are checked |
| Trusted workspace but `run` denied | The coach names `course.run.no_permission`; text checks are used |
| No workspace or untrusted workspace | Text checks are used; the coach says why |
| Compiler missing | The run fails through `RunService` with its normal stage/error explanation; the lesson remains retryable |

The compile command is the editor's normal C++ profile: `g++ $file -o $fileNoExt && $fileNoExt`.
`clang++` is used through the same profile when `g++` is unavailable.

## Structure

```text
1.0.0/
  manifest.json
  main.lua                 commands, events, shell/partial flow
  lib/course.lua           load/validate content, navigation
  lib/engine.lua           hybrid phase specs and state helpers
  lib/i18n.lua             locale loading and interpolation
  lib/layout.lua           full-shell and partial-panel layouts
  lib/progress.lua         progress keys and maps
  content/index.lua        ordered lesson paths
  content/lessons/*.lua    five data-only lessons
  content/locales/en.lua   runtime strings
  locales/en.json          translator template
```

Adding a lesson: add `content/lessons/06_name.lua` and one line in
`content/index.lua`. The shell layout is lesson-independent, so nothing else
needs to change.

## Tests

The sample is covered by `tests/unit/features/mods/test_cpp_journey.gd`:

```bash
godot --headless --path . --script res://tests/test_runner.gd
```

The suite validates the manifest, compiles every Lua file, checks the five
lessons and their C++ targets, validates both layouts against the widget
catalog, checks locale parity and used keys, drives `main.lua` against a Lua
sandbox stub, and compiles and runs each freeform example with `g++` when a
compiler is available.
