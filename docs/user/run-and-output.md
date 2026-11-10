# Run configurations, captured output and friendly errors

This document describes the Run pipeline. It is meant for
users who want to configure a project and for contributors who need to change
the capture protocol, the error rules, or the Run panel.

The design goal is simple: **a beginner should be able to press Run, see what
happened, and understand the first error without knowing how a terminal works.**
Interactive programs still belong in the real terminal.

---

## 1. Two execution modes

Every run goes through one of two paths. The profile chooses; `F6` can force
the terminal path.

| Mode | Used for | Where output goes | Input |
| --- | --- | --- | --- |
| `capture` (default) | scripts, compilers, tests, one-shot programs | Run panel | NUL / `/dev/null` |
| `terminal` | REPLs, servers, prompts, programs that need keyboard input | visible terminal tab | the keyboard |

The built-in Python profile also sets `"auto_terminal": true`. When the buffer
contains a detectable keyboard read (`input(...)`, `sys.stdin`, `fileinput`),
`RunService` chooses the terminal path automatically. Non-interactive Python
scripts keep the captured Run panel. A project can set
`"auto_terminal": false` on its Python profile to opt out.

### Captured mode

`F5` uses captured mode by default. The command runs inside a private PTY, the
PTY's bytes feed `RunCapture`, and the cleaned text is shown in the Run panel.
The panel can show:

- the command and working directory,
- streaming output while the process runs,
- the final exit code and duration,
- short diagnosis cards with an explanation and a fix,
- install cards when a runtime is missing,
- clickable `file:line` links that jump to the reported source line.

The process writes into a PTY, not a pipe, because compilers and runtimes behave
differently when they believe they are attached to a terminal (colors, progress
bars, Python's `-u` behavior, and so on). The capture wrapper makes the stream
boring and parseable again.

### Terminal mode

Servers, REPLs, and programs that call `input()` or read stdin need a live
keyboard. Use **Run Current File in Terminal** (`F6`), or set
`"mode": "terminal"` on the profile:

```json
{
  "run": {
    "server": {
      "command": "python -u $file",
      "cwd": "$workspace",
      "extensions": ["py"],
      "mode": "terminal"
    }
  }
}
```

`"interactive": true` is accepted as a synonym. Terminal mode types the command
into the visible terminal tab, exactly like the old runner. The program keeps
its colors, prompts, Ctrl+C handling, and stdin.

The Run panel and the terminal share the bottom strip. Opening one closes the
other, but closing the Run panel does **not** stop a captured run.

---

## 2. Run configuration

### 2.1 Where profiles are loaded from

Layers are applied from lowest to highest priority:

1. Qorix's built-in profiles (`src/features/run/run_config.gd`).
2. `user://run.json` — a global user override.
3. `<workspace>/.griddycode.json` — a compact project config.
4. `<workspace>/.griddycode/run.json` — the recommended project config.

A custom profile always beats a built-in profile. A `#!` line can also choose an
interpreter when **Run: shebang first** is enabled (the default).

### 2.2 Shape

```json
{
  "run": {
    "python": {
      "command": "python -u $file",
      "cwd": "$workspace"
    },
    "node": {
      "command": "node $file",
      "cwd": "$dir"
    },
    "server": {
      "command": "python -u $file",
      "cwd": "$workspace",
      "extensions": ["py"],
      "mode": "terminal"
    }
  }
}
```

A profile can be a command string instead of an object:

```json
{ "run": { "python": "python -u $file" } }
```

### 2.3 Fields

| Field | Meaning |
| --- | --- |
| `command` | Shell command. Required. |
| `cwd` | Working directory. Defaults to `$dir`. |
| `extensions` | File extensions that select this profile. |
| `aliases` | Extra names such as `js`, `py`, or `node`. |
| `language` | Language id used for error rules and the panel. |
| `runtimes` | Executables checked before the run (for install cards). |
| `mode` | `capture` (default) or `terminal`. |
| `interactive` | Alias for `"mode": "terminal"`. |
| `enabled` | Set to `false` to hide a built-in profile. |
| `default` | Fallback profile when nothing matches. |
| `append_file` | When no placeholder exists, append the file path (default `true`). |

### 2.4 Placeholders

Placeholders are replaced with shell-quoted paths, so filenames with spaces
work.

| Placeholder | Value |
| --- | --- |
| `$file` | Absolute file path. |
| `$dir` | Folder containing the file. |
| `$dirSlash` | Folder with a trailing slash. |
| `$workspace` | Workspace root. |
| `$workspaceRoot` | Alias for `$workspace`. |
| `$fileName` | File name with extension. |
| `$fileNameWithoutExt` | File name without the last extension. |
| `$fileNoExt` | Absolute path without the extension. |

A hand-written quoted placeholder keeps its quotes: `python "$file"` becomes
`python "/work/my file.py"` rather than `python ""/work/my file.py""`.

### 2.5 Examples

Compile and run C++:

```json
{
  "run": {
    "cpp": {
      "command": "g++ -std=c++20 -O0 -g $file -o $fileNoExt && $fileNoExt",
      "cwd": "$dir"
    }
  }
}
```

Run a Python file from the project root:

```json
{
  "run": {
    "python": {
      "command": "python -u $file",
      "cwd": "$workspace",
      "runtimes": ["python"]
    }
  }
}
```

Run a Vite dev server in the terminal:

```json
{
  "run": {
    "web": {
      "command": "npm run dev",
      "cwd": "$workspace",
      "extensions": ["js", "ts", "html"],
      "mode": "terminal"
    }
  }
}
```

### 2.6 Open the config from the editor

**Run → Edit Run Configuration** (or the **Config** button in the Run panel)
creates `.griddycode/run.json` from a documented template when it does not
exist, then opens it in a tab.

If a config file is malformed, the run is not silently cancelled. The panel
shows a **Run config warning** with the source file and the parse error.

---

## 3. How capture works

### 3.1 Wrapper and markers

The command is wrapped in a shell snippet that prints two invisible markers
with a random token:

```text
echo __GRIDDY_RUN_START_<token>__ > CONOUT$
(<command>) > CONOUT$ 2>&1 <NUL
echo __GRIDDY_RUN_EXIT_<token>__ > CONOUT$
exit /b
```

`RunCapture` discards everything before the start marker (the ConPTY handshake),
keeps the body, removes the end marker, and records the exit status.

The PTY's `exited` signal is authoritative for the exit code. The end marker is
only a boundary signal; `%ERRORLEVEL%` expansion in a compound `cmd.exe`
command line is too easy to break, so the panel does not trust a code written
into the marker.

### 3.2 Windows, `CONOUT$`, and parent consoles

There is a Windows quirk that matters here. If Qorix was itself launched
from a terminal, `CreateProcess` can duplicate the parent's console handles into
the child even when a pseudo console is attached. The child then writes its
output to the editor's own console instead of the PTY, and the Run panel appears
empty.

The Windows wrapper therefore reopens the **attached pseudo console** explicitly
with `> CONOUT$ 2>&1`. This keeps stdout and stderr inside the capture PTY both
when Qorix is launched from Explorer and when it is launched from a shell.

The capture PTY is created at **1000 columns x 200 rows**. A very wide, tall
screen prevents ConPTY from wrapping and redrawing compiler messages, which
would otherwise interleave with the cursor-positioning sequences and corrupt
long tracebacks.

### 3.3 Cleanup

`RunCapture` is deliberately pure GDScript (no nodes, no UI):

- strips ANSI CSI/OSC sequences,
- converts CRLF to LF,
- applies backspace and bare-CR edits in place (progress bars show the latest
  state instead of every frame),
- decodes UTF-8 across chunk boundaries without splitting a rune,
- truncates at roughly 1,000,000 characters, keeping the head and tail,
- reports `truncated` so the panel can say so.

Stop sends Ctrl+C first, waits for a short grace period, then kills the PTY if
the program does not leave. Closing the editor kills any captured child.

### 3.4 Interactive programs

Captured runs have no stdin. A program that calls `input()` immediately gets
end-of-file. For Python, the built-in profile opts into `auto_terminal`, so a
detected `input(...)`, `sys.stdin`, or `fileinput` reader is sent to the visible
terminal before it can fail. If detection misses a reader, Python's `EOFError`
rule explains what happened and the diagnosis card includes a one-click
**Run in Terminal (F6)** action. Use `F6` directly for anything that needs a
prompt, a server socket, a REPL, or Ctrl+C.

---

## 4. Error rules

Explanations are rendered in the current UI language: English, German or
Spanish. Each rule carries localized `title_de`/`title_es`, `message_de`,
`explain_de` and `fix_de` (and `_es`) fields next to the English ones; the
explainer picks them at diagnosis time and falls back to English when a
translation is missing. The bundled eleven fallback cards (no-output,
stopped, unknown exit code) are translated in the same three languages.

Rules live in `src/features/run/error_rules/*.json`:

| File | Language |
| --- | --- |
| `python.json` | Python |
| `node.json` | JavaScript / Node.js |
| `c_cpp.json` | GCC and Clang diagnostics |
| `java.json` | `javac` and Java stack traces |
| `go.json` | Go compiler and panic output |
| `generic.json` | cross-language fallbacks (missing command, port in use, permissions, ...) |

The JSON shape is:

```json
{
  "language": "python",
  "rules": [
    {
      "id": "python-syntax",
      "title": "Python syntax error",
      "severity": "error",
      "pattern": "(?m)^\\s*File \"([^\"]+)\", line (\\d+)...",
      "file_group": 1,
      "line_group": 2,
      "column_group": 0,
      "message": "Python could not parse this file at line {2}: {4}",
      "explain": "Python reached line {2} and could not understand the code.",
      "fix": "Check the end of line {2} for a missing colon or bracket.",
      "dedupe_key": "python-syntax",
      "max_matches": 1
    }
  ]
}
```

- `pattern` is a Godot `RegEx` pattern.
- `{0}` is the whole match; `{1}`, `{2}`, ... are capture groups.
- `file_group`, `line_group`, and `column_group` select the capture group that
  contains the path/line/column. Leave them `0` when the rule has no location.
- `severity` may be `error`, `warning`, or `info`.
- `dedupe_key` prevents the same explanation from appearing five times.
- `max_matches` caps matches for one rule (default 1).
- `fix` is shown inline and behind **Show me the fix**.
- A diagnosis only becomes a clickable link when the file exists and the line is
  greater than zero.

Rule order matters. Language-specific rules run first, then generic rules, then
rules for other languages. The first matching rule wins for a given
`dedupe_key`. At most five diagnosis cards are shown.

The fallbacks in `generic.json` and the `run-success` / `run-exit-code` rules
make sure even unmatched output gets a useful sentence.

---

## 5. The Run panel

The panel is built by `src/features/run/output_panel.gd`. It never owns a process;
`RunService` emits signals and the panel renders `last_result`.

### Header

| Control | Action |
| --- | --- |
| **▶ Run** | Run the active file (same as `F5`). |
| **■ Stop** | Stop the run (same as `Shift+F5`). |
| **Explain: On/Off** | Show or hide diagnosis cards. |
| **Clear** | Clear the displayed output without stopping the program. |
| **Config** | Create/open `.griddycode/run.json`. |
| **✕** | Close the panel; a captured run keeps going. |

### Output

- Paths printed by the compiler become `[url=griddy:...]` links.
- Clicking a link opens the file and moves the caret to the line.
- ANSI colors are stripped, so the panel is readable on every theme.
- Long runs truncate with a visible notice instead of freezing the UI.
- The status line reports running/finished/failed/stopped and the duration.

### Diagnoses

Each card shows a severity-colored title, a plain-language message, an
explanation, and actions:

- **Show me the fix** opens the source line and puts the fix text in the panel.
- **Open `file:line`** jumps to the reported location.
- The diagnosis source line is included when the file can be read.

### Missing runtimes

`RuntimeCatalog` checks the executables named by the profile before a captured
run starts. It resolves aliases such as `python3` → `py` on Windows and searches
`PATH` with `PATHEXT`. If a runtime is missing, the panel shows an install card
with a title, a short hint, and a documentation URL. The command is not run, so
the user never sees a raw `'python' is not recognized` shell error.

On Windows, the Python and Node.js cards additionally offer **Install with
winget** when `winget` is on `PATH`. One click opens a confirmation dialog with
the exact command; agreeing types it into a new, visible terminal tab where you
can watch the installer run. Nothing installs invisibly, and administrator
approval is requested by Windows itself.

---

## 6. Commands and shortcuts

| Command | Default shortcut | Notes |
| --- | --- | --- |
| Run Current File | `F5` | Captured mode by default. |
| Run Current File (alternate) | `Ctrl+Alt+N` | Hidden alias for keyboards without F5. |
| Run Current File in Terminal | `F6` | Forces terminal mode. |
| Stop Code Run | `Shift+F5` | Captured runs get Ctrl+C, then kill. |
| Stop Code Run (alternate) | `Ctrl+Alt+M` | Hidden alias. |
| Toggle Run Output | `Ctrl+Shift+U` | Shows or hides the panel. |
| Edit Run Configuration | — | Opens/creates `.griddycode/run.json`. |

All of these are in the command palette and the **Run** menu. **Run** and
**Stop** also appear in the toolbar.

Relevant settings (`Ctrl+,`):

- **Run: save file first** (default on) — save before running.
- **Run: shebang first** (default on) — `#!` chooses the interpreter.
- **Detect Language in Plain Text** (default on) — GuessLang for `.txt` and
  unknown extensions.

---

## 7. Offline language detection

`src/features/run/guesslang_service.gd` is a native GDScript reimplementation of the
GuessLang idea. It is fully offline, deterministic, and needs no Python service
or model download.

### How it scores

For each profile in `src/features/run/language_profiles.json`:

1. **Character trigram TF-IDF cosine similarity** (`0.58` weight) against the
   profile's sample text.
2. **Weighted syntax markers** (`0.36` weight), such as `def`/`import` for
   Python, braces and `function` for JavaScript, `package`/`func` for Go, or
   `#include` for C.
3. **Extension hint** (`0.06` weight).

A plain-text fallback is penalized so it cannot win by default.

### When it applies

- Only for `.txt` files and extensions that Qorix has no language plugin
  for.
- Only when the file has at least 24 non-whitespace characters.
- Auto-apply requires **62% confidence** and at least a 6% lead over the second
  language.
- Real source files always trust their extension.
- A tiny snippet is reported as a weak match but is not applied automatically.

### Manual control

- **Edit → Detect Language in Current File** applies the best match even when
  the confidence is below the auto threshold. The notice says it is a weak
  match.
- **Edit → Clear Detected Language** removes the override and returns to the
  extension-based language.
- The override is saved in the session and survives a restart.
- Highlighting and Run both use the detected language, so a Python file saved as
  `notes.txt` can still run with `F5`.

There are 35 profiles, including Python, JavaScript, TypeScript, Java, C, C++,
C#, Go, Rust, Ruby, PHP, Lua, Shell, PowerShell, Batch, HTML, CSS, JSON, YAML,
XML, Markdown, SQL, Kotlin, Swift, Dart, R, Perl, Scala, Haskell, Elixir,
Clojure, Zig, Nim, Brainfuck, and plain text.

---

## 8. File map

| Path | Responsibility |
| --- | --- |
| `src/features/run/run_service.gd` | Lifecycle, mode selection, wrapper, PTY ownership, results. |
| `src/features/run/run_config.gd` | Layered profiles, matching, placeholders, quoting. |
| `src/features/run/run_capture.gd` | Marker protocol, ANSI/CR/backspace/UTF-8 cleanup, truncation. |
| `src/features/run/error_explainer.gd` | Rule loading, matching, diagnosis/link/source-line construction. |
| `src/features/run/error_rules/*.json` | Language-specific and generic error rules. |
| `src/features/run/runtime_catalog.gd` | PATH/PATHEXT lookup, aliases, install guidance. |
| `src/features/run/output_links.gd` | `file:line` parsing, path resolution, BBCode linkification. |
| `src/features/run/output_panel.gd` | Bottom dock, header, status, cards, actions. |
| `src/features/run/guesslang_service.gd` | Offline detector, confidence, profile lookup. |
| `src/features/run/language_profiles.json` | Samples, markers, settings, and 35 profiles. |
| `src/workbench/terminal_session.gd` | One PTY per process; reused by the terminal and capture modes. |

---

## 9. Tests

The headless suite covers the pure logic without needing a GUI:

```bash
godot --headless --path . --script res://tests/test_runner.gd
```

Run suites:

- `tests/unit/features/run/test_run_config.gd`
- `tests/unit/features/run/test_run_service.gd`
- `tests/unit/features/run/test_run_capture.gd`
- `tests/unit/features/run/test_runtime_catalog.gd`
- `tests/unit/features/run/test_error_explainer.gd`
- `tests/unit/features/run/test_guesslang_service.gd`
- `tests/unit/features/run/test_output_links.gd`

At the time of writing the full suite is **1413 checks across 32 suites** with
exit code 0.

An end-to-end check with a real PTY is run manually during development, because
it needs an installed interpreter and a real pseudo console. It runs a Python
file with a syntax error and a clean Python file, then verifies the markers, the
exit codes, the diagnosis, and the link rendering. This is what caught the
Windows `CONOUT$` and ConPTY wrapping issues described above; the headless
suites keep the pure logic covered in CI.

---

## 10. Known limitations

- Captured runs have no stdin. Python readers are auto-detected and routed to
  the terminal; other languages use terminal mode when a profile says so or
  when the user presses `F6`.
- The capture panel is not a full terminal emulator. Long lines can still wrap
  if they exceed 1000 columns; the parser strips escape codes rather than
  emulating a screen.
- The panel shows at most five diagnosis cards per run.
- Rules are best-effort. Unmatched output still gets a generic exit-code card,
  never silence.
- The language detector is a heuristic, not a model. Very short or mixed files
  can be ambiguous; manual override and clearing are always available.
- On POSIX, the capture wrapper uses `/dev/null` and `/bin/sh`; Windows uses
  `cmd.exe`, NUL, and `CONOUT$`.
