# Debugger (DAP)

Qorix includes a real debugger. The editor speaks the Debug Adapter
Protocol (DAP) over TCP to a debug adapter process, and the first supported
adapter is Python's `debugpy`.

The design goal is the same as language-server support: **Qorix is the
client, not the installer.** It finds an adapter on `PATH`, starts it for the
file being debugged, and shows install instructions when it is missing. The
transport and the bottom dock are adapter-neutral, so adding Node, LLDB, GDB or
Go later means adding a profile, not another debugger UI.

---

## 1. What works

| Feature | Behaviour |
| --- | --- |
| Breakpoints | Click the debug gutter or press `F9`. Several breakpoints per file, kept per path, shown as `●`. |
| Start / continue | `Ctrl+F5` starts the active saved Python file; while paused, the same command continues. |
| Stop | `Ctrl+Shift+F5`, the toolbar Stop button, or the adapter terminating. |
| Stepping | Step Over (`F10`), Step Into (`F11`), Step Out (`Shift+F11`). |
| Call stack | Up to 40 frames; selecting a frame switches files and refreshes variables. |
| Variables | Scopes and values with types; nested values expand on demand, one level is prefetched. |
| Watch | Up to 20 expressions, re-evaluated on every pause and frame change. |
| Debug Console | Program/adapter output plus a REPL prompt that evaluates in the paused frame. |
| Paused-file navigation | A breakpoint in a file that is not open switches to it and puts the caret on the stopped line. |
| Session state | Breakpoints, watches, dock visibility/tab and the verbose-log value survive a restart. |
| Missing adapter | A card with the install command and a documentation link; nothing is installed or downloaded automatically. |

### Supported adapters

| Profile | Display | Languages | Status |
| --- | --- | --- | --- |
| `python` | Python (debugpy) | Python | **Implemented** |
| `node` | Node.js (planned) | JavaScript, TypeScript, JSX, TSX | Scaffolded, `implemented: false` |
| `lldb` | C / C++ / Rust (LLDB, planned) | C, C++, Rust | Scaffolded, `implemented: false` |
| `gdb` | C / C++ (GDB, planned) | C, C++ | Scaffolded, `implemented: false` |
| `go` | Go (Delve, planned) | Go | Scaffolded, `implemented: false` |

The planned profiles still appear in the adapter list and show their planned
notice when a matching file is debugged. They are not dead entries: a project
can point one at a working command today with `"implemented": true` and a
`launch` object.

### Quick start with debugpy

Install the package into the interpreter Qorix will use (the first
`python`, `python3` or `py` found on `PATH`, unless the config names an
absolute path):

```bash
python -m pip install debugpy
python -c "import debugpy; print(debugpy.__version__)"
```

Then:

1. Open a `.py` file and press `F9` on the line where the program should pause.
2. Press `Ctrl+F5`.
3. Inspect Variables, add a Watch, or type an expression in the Debug Console.
4. Use `F10`, `F11`, `Shift+F11` and `Ctrl+F5` while paused.

`debugpy` 1.8.22 is the version used by the end-to-end suite.

### Adapter discovery

`DapConfig` resolves the profile's `command` through `RuntimeCatalog`, which
searches `PATH` using `PATHEXT` on Windows. An absolute path is accepted as-is.
A `.cmd` or `.bat` shim is launched through `cmd.exe /c` with `call`.

Profiles also list `commands` (`python`, `python3`, `py` for Python). The first
one that resolves is used, so the built-in Python profile works with either a
`python` or a `py` launcher on Windows.

If nothing resolves:

- no process is started,
- the Debugger dock opens,
- an install card shows the title, hint, copyable command(s) and a docs link,
- the Debug Console records the failure.

The session state is never changed by a failed start; breakpoints and watches
are kept for the next attempt.

---

## 2. Configuration

### 2.1 Layers

Profiles are applied from lowest to highest priority:

1. Built-in profiles (`src/features/debug/dap_config.gd`).
2. `user://debug.json` — a global user override.
3. `<workspace>/.griddycode.json` — the top-level `"debug"` key.
4. `<workspace>/.griddycode/debug.json` — the recommended project file.

A later layer merges into the built-in entry: scalar fields replace, `launch`
is merged key by key, and array fields (`args`, `extensions`, `languages`,
`commands`) are replaced as a whole.

The Godot user folder is:

| OS | Folder |
| --- | --- |
| Windows | `%APPDATA%\Godot\app_userdata\Qorix` |
| Linux | `~/.local/share/godot/app_userdata/Qorix` |
| macOS | `~/Library/Application Support/Godot/app_userdata/Qorix` |

A malformed file is reported in the Debug Console when the workspace is loaded.
It does not stop the editor from starting and does not discard the built-ins.

> **Trust warning:** a project config can name any executable and arguments.
> Debugging a matching file starts that command. Only debug projects you trust,
> or remove the `"debug"` block from a project you do not trust. This is the
> same trust model as a workspace task or language server profile.

### 2.2 Shape

```json
{
  "debug": {
    "python": {
      "command": "C:/Python312/python.exe",
      "args": ["-m", "debugpy.adapter", "--host", "127.0.0.1", "--port", "$port"],
      "launch": {
        "type": "python",
        "request": "launch",
        "program": "$file",
        "cwd": "$dir",
        "console": "internalConsole",
        "justMyCode": true,
        "stopOnEntry": false
      }
    }
  }
}
```

`debug.json` uses the same object without the outer `"debug"` key:

```json
{
  "python": {
    "command": "python"
  }
}
```

A profile can also be a command string. The built-in arguments and launch
object are retained:

```json
{ "debug": { "python": "C:/Python312/python.exe" } }
```

### 2.3 Fields

| Field | Meaning |
| --- | --- |
| `command` | Executable name on `PATH`, or an absolute path. |
| `args` | Arguments used to start the adapter. `$port` is replaced with the chosen TCP port. |
| `launch` | The DAP `launch` arguments object. Placeholders are substituted. |
| `extensions` | Extensions served by this profile, without the dot. |
| `languages` | Language ids that map to this profile (for example `python`). |
| `commands` | Alternative executable names tried in order when `command` is missing. |
| `display` | Name shown in install cards and the status line. |
| `implemented` | `false` keeps the profile visible but refuses to start it. |
| `enabled` | `false` refuses to start a session for matching files with a “disabled in the debug config” message; the profile stays listed. |
| `install` | Card content: `title`, `hint`, `commands` (array or string), `url`, `url_label`. |

### 2.4 Placeholders

| Token | Replaced with |
| --- | --- |
| `$port` | The TCP port chosen for this session (42,000–59,999). |
| `$file` | Absolute path of the file being debugged. |
| `$dir` | Folder containing that file. |
| `$workspace` | Workspace root, or the file's folder when no workspace is open. |
| `$python` | The resolved adapter command path. |

Placeholders are substituted recursively in `args` and in every string,
array and object inside `launch`.

### 2.5 Custom adapter example

A custom profile is any key that is not one of the built-ins. It is treated as
implemented unless it says otherwise, and the defaults fill in `request`,
`program` and `cwd` when `launch` omits them.

```json
{
  "debug": {
    "ruby": {
      "display": "Ruby (rdbg)",
      "command": "rdbg",
      "args": ["--open", "--host", "127.0.0.1", "--port", "$port"],
      "extensions": ["rb"],
      "languages": ["ruby"],
      "launch": {
        "type": "rdbg",
        "request": "launch",
        "script": "$file",
        "cwd": "$dir"
      },
      "install": {
        "title": "Install the Ruby debugger",
        "hint": "Install the debug gem, then put rdbg on PATH.",
        "commands": ["gem install debug"],
        "url": "https://github.com/ruby/debug"
      }
    }
  }
}
```

The adapter must listen on the host/port passed in `$port`; Qorix connects
to `127.0.0.1` at that port after starting the process.

---

## 3. Process and protocol

### 3.1 TCP transport

`src/features/debug/dap_client.gd` owns one adapter process and one TCP socket. The
adapter is started with `OS.execute_with_pipe(path, args, false)` and then
connects back to the editor:

- Windows launcher: `cmd.exe /d /s /c "cd /d "<cwd>" && "<command>" "<arg>"…"`.
  `.cmd`/`.bat` shims are invoked with `call`. The whole command is one quoted
  string because Godot passes arguments through without adding quotes.
- POSIX launcher: `/bin/sh -c 'cd <cwd> && exec <command> <args>'`.
- The client retries `connect_to_host("127.0.0.1", port)` every 100 ms for 10 s.
- The socket is explicitly polled every frame. Godot's `StreamPeerTCP` does not
  advance its handshake on its own; without `poll()` the status stays
  `CONNECTING` until the timeout. `set_no_delay(true)` is applied only after the
  socket is connected.
- Reads are bounded to 8 chunks per frame; writes are queued.
- A 4 MB outbound queue cap drops messages with a log line instead of growing
  without bound.

The adapter session is never started on the UI thread's critical path. A slow
or wedged adapter cannot freeze typing.

### 3.2 Framing and requests

`src/features/debug/dap_protocol.gd` delegates byte framing to the LSP parser, so
`Content-Length` is counted in UTF-8 bytes, split headers/bodies and several
messages per read all work identically. The schema helpers are DAP-only:

- every message has `seq` and `type` (`request`, `response` or `event`),
- responses point at their request with `request_seq` and carry `success`,
- `request` / `response` / `event` builders and `is_*` predicates,
- `response_result()` normalises a failure to `{ok: false, body: {}, error, …}`,
- bodies larger than 32 MB are rejected by the parser.

Requests have monotonically increasing sequence numbers and a callback. The
default deadline is 12 s; `initialize` uses 15 s, `launch` 20 s and `disconnect`
3 s. An expired request resolves its callback with `ok: false` instead of
leaking it.

### 3.3 Session flow

For Python the sequence is:

```text
start process → TCP connect → initialize
  → launch (program, cwd, justMyCode, stopOnEntry)
  → initialized event
  → setBreakpoints for every file that has breakpoints
  → configurationDone
  → stopped / output / terminated events
  → stackTrace → scopes → variables
```

`continue`, `next`, `stepIn`, `stepOut` and `disconnect` carry the adapter's
thread id. A `stopped` event stores the reason (`breakpoint`, `step`, `pause`,
`exception`, `entry`, …) and the thread id, then requests the top 40 frames.

When the adapter sends `terminated`, the session ends and the dock reports
`Debug session ended.` If the process exits without `terminated`, the exit
event's code is logged and the session is closed.

`Stop Debugging` sends `disconnect` with `terminateDebuggee: true`, waits up to
900 ms for the process to close, then kills the process tree
(`taskkill /F /T /PID` on Windows). Closing the editor calls the same path.

### 3.4 Reverse requests and unsupported DAP features

The adapter may send requests to the editor. Qorix declines them with a
console explanation:

- `runInTerminal` — the debugger uses the internal console, which cannot
  provide keyboard input. Run without debugging (`F6`) for interactive
  programs.
- `startDebugging` — child debug sessions are not supported in this build.
- anything else — the editor does not implement the request.

Qorix advertises variable types and variable paging, but not
`runInTerminal`, memory references, progress reporting or invalidated events.

### 3.5 Adapter output and failures

`output` events are appended to the Debug Console; category `stderr` is shown
as an error colour and `stdout` as normal output. Adapter lifecycle lines and
protocol errors are prefixed by their kind in the console. Adapter stderr is
drained when the platform exposes the pipe, and the tail is included in
connection-failure messages.

A start failure (missing command, missing package, refusal, connection timeout)
leaves breakpoints and watches intact. A connection timeout names the adapter,
host and port so it is clear whether the process started but never listened.

---

## 4. Features

### 4.1 Breakpoints

Breakpoints live in `DapManager.breakpoints`, keyed by normalized path. On
Windows the key is case-folded so `C:\Src\main.py` and `c:/src/main.py` are the
same file.

- A click on the debug gutter toggles the clicked line.
- `F9` toggles the caret line.
- A file may hold any number of breakpoints; they are sorted by line.
- Every change sends a fresh `setBreakpoints` for that whole file, which is what
  DAP expects (the request replaces the file's list).
- `condition` is sent when non-empty; the built-in UI does not edit conditions
  yet, but session restore preserves them and the adapter receives them.
- Untitled buffers cannot own breakpoints: click/F9 shows a warning asking for a
  save first.
- The dot stays on the requested line while the adapter's `actual_line` and
  verification message are recorded on the entry. The gutter deliberately does
  not distinguish verified from pending.
- `Remove All Breakpoints` clears every file and repaints open tabs.

The editor uses a dedicated 16 px gutter appended after CodeEdit's built-in
gutters. It sits left of the Git and LSP strips and has its own click dispatch,
so a breakpoint click can never be mistaken for a diagnostic or Git action.
The paused line uses `▶` and wins over a breakpoint on the same line.

### 4.2 Variables and scopes

On every pause the manager requests `stackTrace`, then `scopes` for the selected
frame, then `variables` for each scope. The response is kept with its
`variablesReference`:

- values show the adapter's `value` and, when present, `[type]`,
- nested values get an expand arrow,
- expanding asks for the children; the manager prefetches one level (first 12
  references) so small lists and dicts are instant,
- each request asks for 200 values (`start: 0`, `count: 200`),
- expansion state resets on every new pause because reference numbers are only
  valid for that stop,
- the tree is capped at 1,200 rows per render.

Godot's `Tree` has no expansion signal, so the panel polls the visible tree
every 150 ms and requests children the moment an item is opened.

Selecting a frame in the Call Stack clears the old scope data, requests scopes
for the new frame, and navigates to its file/line.

### 4.3 Watch

The Watch tab keeps up to 20 unique expressions. A new watch is evaluated
immediately when paused; otherwise it shows `evaluating…` until the next pause.

- Each row shows the expression, value and `[type]`,
- failures show the adapter's message in the error colour,
- removing a row removes its cached result,
- `Refresh` re-evaluates every expression in the current pause,
- changing the selected frame re-evaluates every watch against that frame.

Watches are saved with the session and restored without a running adapter.

### 4.4 Call stack

The top 40 frames are shown as `function — file:line`. Clicking a frame:

- makes it the selected frame,
- updates the execution marker and opens the file if needed (unless the
  auto-open setting is off),
- requests its scopes,
- refreshes watches.

The frame list is rebuilt on every pause and when a frame is selected, so the
highlight always matches the variables on screen.

### 4.5 Debug Console

The console shows, in order:

- adapter lifecycle (`Starting …`, `Connected …`, `Paused: breakpoint`),
- program `output` events (merged into one entry between commands),
- protocol warnings and errors,
- submitted expressions (`> base + step`) and their results,
- the terminated/exit reason.

The prompt is editable only while paused. It evaluates in the selected frame
(`context: "repl"`) and requires a pause; running or idle sessions show a clear
message instead of silently doing nothing. Up/Down walk the last 60 submitted
expressions. `Clear Console` empties the view but not the session.

Console storage is capped at 600 entries / 240,000 characters so a chatty
program cannot grow memory without bound. BBCode from the program is escaped
before display, and colour comes from the active theme.

### 4.6 Stepping and the paused line

`F10` sends `next`, `F11` sends `stepIn`, `Shift+F11` sends `stepOut`. The state
moves to `running` immediately and back to `stopped` on the next stopped event;
the Call Stack and Variables views clear as soon as execution resumes. Watch
rows keep their last values while the program runs, then re-evaluate on the
next pause.

Python's adapter reports the caller's **call line** after `stepOut`, not the
line after it. From `value = add(base, step)` on line 15, Step Into enters
`add()`; Step Out returns to line 15, and one Step Over reaches line 16. The
end-to-end suite pins this behaviour.

The paused line is painted in every open view of the stopped file. The caret
jumps to the stopped line and column, and the status line reads
`Paused (breakpoint) at main.py:15`.

### 4.7 Paused-file navigation

When a frame stops in a file that is not open, the editor opens the file as a
tab and moves the caret to the stopped line. A setting,
**Open the file when a breakpoint is hit** (default on), can turn the tab switch
off. With it off:

- the execution marker still appears in any already-open view of that file,
- the status line still names the file and line,
- a closed file is not opened.

The marker is cleared on `continued`, on termination, when the session stops,
and when a new session starts.

### 4.8 The Debugger dock

The debugger is a bottom dock, 386 px tall, sharing the strip with the
terminal, Run output and Language panels. Opening one of those hides the
debugger, and opening the debugger hides the other three; they never overlap.
Closing the dock does not stop the session, so a breakpoint can be inspected
again with `Ctrl+Shift+D`.

Layout:

```text
┌ Debug  [Start] [Step Over] [Step Into] [Step Out] [Stop]   status   [Clear Console] [X] ┐
│ install card (only when an adapter is missing)                                          │
│ ┌ Variables / Watch ─────────────┐ ┌ Call Stack ───────────────────────────────────┐   │
│ │ scopes and values             │ │ function — file:line                          │   │
│ │                               │ ├ Debug Console ────────────────────────────────┤   │
│ │                               │ │ output, errors, results                       │   │
│ │                               │ │ > evaluate an expression…                     │   │
│ └───────────────────────────────┘ └───────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

Buttons disable themselves from the session state: step buttons only while
paused, Stop while active, Start while connecting/running/stopping. The status
label mirrors the manager's `status_text()`.

A missing adapter opens the dock on the Variables tab and renders a card with
a title, hint, one copy button per install command and an optional link. The
card is cleared when a session starts successfully.

---

## 5. Commands and shortcuts

All commands are in the generated **Debug** menu and can be rebound in
Settings → Keybindings. `global` means the command works anywhere unless a
focused text field consumes the key; `editor` means it only runs while a code
editor has focus.

| Command | Id | Default shortcut | Scope |
| --- | --- | --- | --- |
| Start / Continue Debugging | `debug.start` | `Ctrl+F5` | global |
| Toggle Breakpoint | `debug.toggle_breakpoint` | `F9` | editor |
| Step Over | `debug.step_over` | `F10` | editor |
| Step Into | `debug.step_into` | `F11` | editor |
| Step Out | `debug.step_out` | `Shift+F11` | editor |
| Stop Debugging | `debug.stop` | `Ctrl+Shift+F5` | global |
| Toggle Debugger Panel | `debug.panel` | `Ctrl+Shift+D` | global |
| Evaluate in Debug Console | `debug.evaluate` | — | global |
| Remove All Breakpoints | `debug.clear_breakpoints` | — | global |

Start / Continue is also a toolbar button. Evaluate and Remove All Breakpoints
are deliberately unbound; they live in the menu and command palette.

Starting debugging:

- refuses an untitled buffer (an adapter needs a file on disk),
- refuses a file that no longer exists,
- saves every modified saved buffer first; a failed save aborts the launch,
- resolves the adapter from the language override first, then the extension,
- opens the Debugger dock whether the start succeeds or fails.

---

## 6. Settings

| Setting | Key | Default | Meaning |
| --- | --- | --- | --- |
| Open the file when a breakpoint is hit | `debug_auto_open_stopped_file` | on | Switch to the stopped file and place the caret on the line. Turn off to stay in the current tab. |
| Verbose debug adapter log | `debug_verbose_log` | off | Print every DAP request, response and event, plus the launch object, to the Debug Console. |

Both are in Settings → Debugger. Changing a setting applies immediately; no
restart is needed.

Use the verbose log when an adapter refuses to start, rejects a launch, or
stops in an unexpected place. It records the exact request/response payloads
and the resolved launch object.

---

## 7. Session restore

`FileManager` captures the debugger into the normal session snapshot:

```json
{
  "panels": { "debug": true },
  "debug": {
    "open": true,
    "tab": 0,
    "watches": ["base + step"],
    "verbose_log": false,
    "breakpoints": [
      { "path": "C:/src/main.py", "line": 14, "condition": "" }
    ]
  }
}
```

- `panel.capture_session()` adds `open` and the selected tab to the manager's
  data, so the dock reopens on the tab that was visible.
- Breakpoints keep their path, zero-based line and condition.
- Watches are de-duplicated and capped at 20.
- Breakpoints are de-duplicated by path + line (case-folded on Windows) and
  capped at 500. Conditions are trimmed to 400 characters.
- The tab index is clamped to the two real tabs (Variables, Watch).
- A malformed debug block degrades to defaults; it never prevents the editor
  from starting.

An active adapter session is **not** reattached after a restart. The debuggee
is a child process of the previous run; restoring breakpoints and watches is
the useful part.

---

## 8. File map

| File | Responsibility |
| --- | --- |
| `src/features/debug/dap_protocol.gd` | Content-Length framing through the LSP parser; DAP request/response/event schema helpers. |
| `src/features/debug/dap_config.gd` | Built-in profiles, layered config, command resolution, placeholder substitution, install help. |
| `src/features/debug/dap_client.gd` | Adapter process launch, TCP connect/retry/poll, framing, request deadlines, reverse requests, shutdown. |
| `src/features/debug/dap_manager.gd` | Session state machine, breakpoints, stack/scopes/variables, watches, console, evaluate, navigation, session capture. |
| `src/features/debug/debug_panel.gd` | Bottom dock: toolbar, Variables/Watch trees, Call Stack, console prompt, install card, theme. |
| `src/editor/editor_view.gd` | Debug gutter registration, breakpoint/execution marks, gutter click signal. |
| `src/main/file_manager.gd` | Composition root: manager/panel creation, commands, gutter sync, navigation, saving, session restore, shutdown. |
| `src/platform/builtin_commands.gd` | Debug menu commands, shortcuts and handlers. |
| `src/platform/settings_service.gd` | Debugger settings category and the two settings. |
| `src/platform/session_service.gd` | Serializes and sanitizes the `debug` block. |
| `tests/unit/features/debug/test_dap_protocol.gd` | Framing/schema unit tests. |
| `tests/unit/features/debug/test_dap_config.gd` | Config layering, resolution, substitution and install help. |
| `tests/unit/features/debug/test_dap_manager.gd` | Session lifecycle, breakpoints, stack/scopes/variables, watches, console, navigation, session state. |
| `tests/unit/platform/test_session_service.gd` | Debug session round-trip and malformed-block tests. |
| `tests/integration/dap_e2e_runner.gd` | Real `debugpy` acceptance run against the real editor scene. |
| `tests/fixtures/dap_target.py` | End-to-end target with pinned line numbers. |
| `tests/fixtures/dap_helper.py` | Second file for cross-file breakpoint/navigation checks. |

---

## 9. Tests

### 9.1 Unit suites

```bash
godot --headless --path . --script res://tests/test_runner.gd
```

The runner prints one line per suite. A passing run ends with:

```text
All tests passed: 1775 checks across 37 suites.
```

The total can read 1774 or 1775 between runs because one capture test's
outcome depends on timing; `All tests passed` and the 37 suites are the stable
signals.

The debugger contributes:

| Suite | Checks | Covers |
| --- | --- | --- |
| `test_dap_protocol.gd` | 53 | Header/body splits, multiple messages, malformed input, request/response/event helpers, failure normalisation. |
| `test_dap_config.gd` | 61 | Layers, string and object profiles, aliases, resolution, `$port`/`$file`/`$dir`/`$workspace`/`$python`, custom profiles, install help, disabled/planned profiles. |
| `test_dap_manager.gd` | 122 | Start guards, missing-adapter help, breakpoint bookkeeping and events, stack/scopes/variables, watches, evaluation, stepping guards, navigation, console limits, session capture/restore. |
| `test_session_service.gd` | 57 (14 for the debug block) | Round-trip, de-duplication, clamping, malformed blocks. |

The suites are pure scripts. They do not need Python, `debugpy`, a display or a
workspace, and they never start an adapter process.

The test runner also reports an uncompilable suite as `FAIL … could not be
instantiated` instead of hanging forever.

### 9.2 End-to-end run with real debugpy

The acceptance runner boots the real editor scene, copies the Python fixtures
into a temporary workspace, and drives the whole vertical slice against a real
`debugpy` adapter:

- gutter click and `F9` breakpoints, including removal and two files,
- start and stop at the pinned breakpoint,
- Variables (locals `base` and `step`) and the Call Stack,
- a watch expression (`base + step` → `5`),
- Debug Console evaluation (`base + step + 100` → `105`),
- Step Into / Step Out / Step Over with debugpy's exact stop lines,
- a cross-file breakpoint, automatic file switch, marker and caret,
- stepping out to the caller and switching back,
- continue to termination,
- the Stop Debugging command and button state,
- session capture/restore of watches and breakpoints.

Python with `debugpy` must be available. On Windows, PowerShell:

```powershell
$env:APPDATA = "$env:TEMP\qorix_dap_appdata"
godot --headless --path . --script res://tests/integration/dap_e2e_runner.gd -- `
  --python="C:/Users/you/AppData/Local/Programs/Python/Python312/python.exe"
```

A passing run ends with:

```text
All DAP end-to-end checks passed: 73 checks.
```

and exits 0. Leak warnings at exit are unrelated to the debugger (the editor's
existing teardown reports them).

The runner creates its own workspace and removes it afterwards. To keep it for
inspection:

```powershell
godot --headless --path . --script res://tests/integration/dap_e2e_runner.gd -- `
  --workspace="C:/temp/qorix-dap-e2e" --keep `
  --python="C:/Python312/python.exe"
```

The workspace contains `dap_target.py`, `dap_helper.py` and a
`.griddycode.json` that pins `debug.python.command`.

If the fixtures are missing, Python cannot be found, or `debugpy` cannot be
imported, the runner prints `SKIP …` and exits 0. `python -m pip install
debugpy` fixes the last case.

Do not redirect `LOCALAPPDATA` on Windows (the Python install manager needs it).
A throwaway `APPDATA` is recommended because the editor writes settings and
session files under `user://`.

#### Pinned fixture lines

`tests/fixtures/dap_target.py` and `tests/fixtures/dap_helper.py` are shared
with the runner. Keep the line numbers in sync or update the constants at the
top of `dap_e2e_runner.gd`:

| Line | Code | Used by |
| --- | --- | --- |
| target 7 | `total = a + b` inside `add()` | Step Into |
| target 14 | `value = add(base, step)` | first breakpoint, Step Out result |
| target 15 | `print(f"value={value}")` | Step Over result |
| target 16 | `helper_add(step, 5)` | Step Out of the helper |
| target 17 | `for index in range(3):` | loop line |
| target 18 | `value += index` | second breakpoint (stop test) |
| helper 4 | `total = a + b` | cross-file breakpoint |

### 9.3 What the unit suites cannot prove

The unit suites use fakes and a scripted transport. The real-adapter run is the
only automated proof that:

- `debugpy` accepts Godot's TCP connection,
- the launch arguments are accepted,
- Python's line numbers match the fixture,
- `stackTrace`/`scopes`/`variables` and `evaluate` work end to end.

Run both before a release.

---

## 10. Known limitations

- **Python only.** Node, LLDB, GDB and Go profiles are scaffolded and show a
  planned notice. They can be pointed at a working adapter with
  `"implemented": true` and a `launch` object, but are not tested by the suite.
- **No interactive stdin.** The adapter uses the internal console, so programs
  that read keyboard input must run with `F6` (Run) instead of the debugger.
- **No conditional-breakpoint UI.** Conditions are part of the model, are sent
  to the adapter and survive a restart, but there is no editor to type one yet.
- **No exception/hit-count configuration.** The adapter's initial stop reasons
  are displayed, but breakpoint options are fixed.
- **Unverified breakpoints keep their dot.** The adapter's `verified` flag and
  actual line are recorded but not rendered differently.
- **One thread at a time.** The top frame of the adapter's reported thread is
  used; there is no thread picker.
- **Bounded lists.** 40 stack frames, 200 values per request, one prefetched
  level (12 references), 1,200 tree rows, 20 watches, 500 persisted
  breakpoints, 600 console entries / 240,000 characters, 300 adapter log lines.
- **Port choice is not OS-assigned.** A port in 42,000–59,999 is picked; if it
  is already in use the adapter cannot bind and the start times out with a
  clear message.
- **No session reattachment.** Restarting the editor restores breakpoints,
  watches and the dock, not a live debuggee.
- **Editor-scoped shortcuts** (`F9`–`F11`) require focus in a code editor, so a
  focused terminal or text field keeps its own key handling.

---

## 11. Manual acceptance run

Use a disposable workspace and a fresh profile. The whole run takes about five
minutes.

### 11.1 Setup

1. Confirm `debugpy` is installed for the interpreter on `PATH`:

   ```bash
   python -c "import debugpy; print(debugpy.__version__)"
   ```

2. Create `dap_demo.py`:

   ```python
   def add(a, b):
       total = a + b
       return total


   def main():
       base = 2
       step = 3
       value = add(base, step)
       print(f"value={value}")
       for index in range(3):
           value += index
       print(f"done={value}")


   if __name__ == "__main__":
       main()
   ```

   The important lines are 2 (`total = a + b`), 9 (`value = add(...)`),
   10 (`print(...)`), 11 (`for ...`) and 12 (`value += index`).

3. Open the folder in Qorix, then open `dap_demo.py`.

### 11.2 Breakpoints

- [ ] The editor has a narrow gutter left of the Git/LSP strips; clicking line
      9 paints `●` on that line and the Debug Console is untouched.
- [ ] Clicking the dot again removes it.
- [ ] Put the caret on line 9 and press `F9`: the dot appears.
- [ ] Put the caret on line 12 and press `F9`: a second dot appears; both lines
      keep their dots.
- [ ] Press `F9` on line 12 again: only that dot is removed; line 9 is intact.
- [ ] Click the gutter, then save and reopen the file: the dot is still there.
- [ ] `Ctrl+Shift+P` → **Remove All Breakpoints**: every dot disappears.
- [ ] Open an untitled buffer and press `F9`: a warning asks you to save it
      first; no dot appears.

### 11.3 Start, pause, inspect

- [ ] Put a breakpoint on line 9 and press `Ctrl+F5`. The Debugger dock opens
      on Variables, the status shows the adapter starting, then
      `Paused (breakpoint) at dap_demo.py:9`.
- [ ] The paused line shows `▶`, the caret is on line 9, and the tab is active.
- [ ] Variables lists `base = 2` and `step = 3` with their types.
- [ ] Expand a locals entry (for example a list added to the program): children
      appear without freezing the editor.
- [ ] The Call Stack shows `main — dap_demo.py:9`.
- [ ] Press `Ctrl+F5`: the program runs to the end, the dock reports
      `Debug session ended.`, the `▶` disappears and the breakpoint dot
      returns.
- [ ] Press `Ctrl+F5` again: a new session pauses on line 9.
- [ ] Press `Ctrl+Shift+F5`: the session stops, the dock shows Ready, and the
      adapter process is gone (check Task Manager for `python`).

### 11.4 Watch and console

- [ ] While paused on line 9, open the **Watch** tab, type `base + step`, press
      Enter or **Add**: the row evaluates to `5  [int]`.
- [ ] Add `base + step + 100`: it evaluates to `105`.
- [ ] Add the same expression twice: the second attempt is refused with a
      warning; no duplicate row.
- [ ] Select the row and press **Remove**: it disappears.
- [ ] Press **Refresh**: remaining rows re-evaluate and keep their values.
- [ ] Press `Ctrl+Shift+P` → **Evaluate in Debug Console**: the dock focuses the
      prompt.
- [ ] Type `base * step` and press Enter: the console echoes `> base * step`
      and prints `6  [int]`.
- [ ] Press Up: the previous expression returns to the prompt. Press Down:
      the next one returns; the prompt clears at the end.
- [ ] While the program is running (press `Ctrl+F5` and pause nowhere), the
      prompt is disabled and its placeholder says to pause first.
- [ ] Type an invalid expression (`nope`) while paused: the console shows the
      adapter's error in red; the session stays paused.
- [ ] Press **Clear Console**: entries disappear; breakpoints and watches stay.
- [ ] Turn on **Verbose debug adapter log** in Settings and start again: the
      console shows `initialize`, `launch`, `setBreakpoints` and events.
      Turn it off and confirm normal output returns.

### 11.5 Stepping and call stack

- [ ] Pause on line 9, press `F11` (Step Into): execution enters `add()` and
      pauses on line 2. The marker, caret and status follow.
- [ ] Press `Shift+F11` (Step Out): execution returns to the caller and pauses
      on line 9 (debugpy reports the call line).
- [ ] Press `F10` (Step Over): execution pauses on line 10.
- [ ] Press `F10` again: it enters the loop on line 11.
- [ ] While inside `add()`, the Call Stack has `add` on top and `main` below.
      Click `main`: the editor switches to line 9 and Variables shows `main`'s
      locals.
- [ ] Click `add` again: the editor switches back and Variables shows `a`, `b`
      and `total`.
- [ ] Start a session with no breakpoints and press `Ctrl+F5`: no step buttons
      are enabled while running.

### 11.6 Cross-file stop and auto-open

1. Add a helper file:

   ```python
   def shout(text):
       return text.upper() + "!"
   ```

2. In `dap_demo.py`, import and call it on a new line before the loop:

   ```python
   from dap_helper import shout
   ...
   shout("hello")
   ```

3. Put a breakpoint inside `shout` and one before the call.

- [ ] Start debugging; when the helper breakpoint hits, the helper file opens
      as a tab, the caret lands on the stopped line, and the marker is there.
- [ ] The Call Stack lists `shout` and `main`; clicking `main` switches back.
- [ ] Turn off **Open the file when a breakpoint is hit**, close the helper tab,
      and start again. Execution still pauses in the helper, the status names
      `dap_helper.py:<line>`, but no tab opens.
- [ ] Turn the setting back on; the next stop opens the file again.

### 11.7 Dock, shortcuts and session restore

- [ ] `Ctrl+Shift+D` opens and closes the dock. Closing it while paused leaves
      the session alive; reopening it shows the same variables and stack.
- [ ] With the terminal open, start debugging: the terminal hides and the
      debugger appears. Press ``Ctrl+` ``: the debugger hides and the terminal
      returns. The same holds for Run output and the Language panel.
- [ ] Resize the window while paused: the dock stays aligned to the bottom and
      the editor area shrinks instead of overlapping.
- [ ] Leave a breakpoint on line 9 and a watch `base + step`, then restart
      Qorix: the watch and dot are back; the dock reopens if it was open.
- [ ] Start debugging again and confirm the restored breakpoint hits.
- [ ] Rebind `debug.start` to another key in Settings → Keybindings; the new
      key starts a session and the old one no longer does.

### 11.8 Failure paths and install cards

- [ ] Remove `debugpy` from the interpreter (or point `debug.python.command` at
      an interpreter without it). Start debugging: the dock opens with the
      debugpy install card, the console names the failure, and no session is
      left running. Reinstall it before continuing.
- [ ] Point the config at `definitely-not-installed`: the card shows the
      command and a copy button; copying puts it on the clipboard.
- [ ] Open a `.js` file and start debugging: the planned Node notice appears;
      no command is started.
- [ ] Open an untitled buffer and press `Ctrl+F5`: the warning asks you to save
      it; nothing starts.
- [ ] Modify a saved file without saving, then start debugging: the file is
      written to disk first and the breakpoint lands on the new line. (Check the
      tab's `*` before starting.)
- [ ] Start debugging, then kill the adapter in Task Manager: the console
      reports the lost connection, the session returns to idle, and the editor
      stays responsive.
- [ ] Open a project with a malformed `.griddycode.json`: the console reports
      the parse error but the built-in Python profile still works.

### 11.9 Python-specific checks

- [ ] Pause inside a list/dict and expand it: children show values and types.
- [ ] Evaluate `len(items)`, a slice, and a method call while paused: results
      match Python's own output.
- [ ] Step Into a standard-library call with **justMyCode** on: execution does
      not descend into site-packages.
- [ ] A program that calls `input()` pauses/hits breakpoints but cannot read
      stdin from the debug console; run it with `F6` instead.

---

## 12. Troubleshooting

| Symptom | Check |
| --- | --- |
| `The debug adapter command "python" was not found on PATH.` | Open a new terminal, run `python --version`, and restart Qorix after fixing `PATH`. |
| `Python debugging needs debugpy` card | `python -m pip install debugpy`, using the same interpreter shown in the card/config. |
| `did not accept a connection on 127.0.0.1:<port>` | The adapter started but is not listening. Run `python -m debugpy.adapter --host 127.0.0.1 --port <port>` by hand, check a firewall prompt, and retry. |
| Start works, breakpoint never hits | Confirm the file is saved and the dot is on an executable line. Python cannot stop on a blank line, `def`, or a comment. |
| Variables empty while paused | Expand the scope; wait a moment for the adapter. Check the verbose log for a failed `variables` response. |
| Steps stop on the previous line | Python reports the call line for `stepOut`; this is expected. Use Step Over once to reach the next statement. |
| Debug dock does not open | `Ctrl+Shift+D`; check that another bottom dock is not covering it. |
| Breakpoints vanish after restart | The workspace path must be the same; breakpoints are keyed by absolute normalized path. |
| Nothing happens on `Ctrl+F5` | The command is disabled without an open document, or the editor is in a scope where a text field consumed the key. Use the Debug menu. |

For an adapter that misbehaves, enable **Verbose debug adapter log** and copy
the Debug Console. It contains the exact DAP requests, responses, launch
object, resolved command and port.
