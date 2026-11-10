# Language server support (LSP)

Language server support turns Qorix into a language-aware editor. It speaks the Language
Server Protocol over a real server process, so errors, completion, hover,
navigation, formatting, rename and code actions come from the same tools other
editors use.

The design goal is deliberately narrow: **Qorix is the client, not the
installer.** It finds a server on `PATH`, starts it for the project that needs
it, and shows friendly install instructions when the server is missing. It
never downloads a server, blocks startup while looking for one, or installs
anything without the user asking.

---

## 1. What works

| Profile | Display name | Languages | Default command |
| --- | --- | --- | --- |
| `python` | Python | Python | `pyright-langserver --stdio` |
| `typescript` | TypeScript / JavaScript | JS, JSX, TS, TSX | `typescript-language-server --stdio` |
| `rust` | Rust | Rust | `rust-analyzer` |
| `cpp` | C / C++ | C, C++ | `clangd` |
| `go` | Go | Go | `gopls` |

The built-in profiles live in `src/features/lsp/lsp_config.gd`. They cover these
extensions:

- Python: `.py`, `.pyw`, `.pyi`
- JavaScript: `.js`, `.mjs`, `.cjs`, `.jsx`
- TypeScript: `.ts`, `.mts`, `.cts`, `.tsx`
- Rust: `.rs`
- C/C++: `.c`, `.h`, `.cpp`, `.cc`, `.cxx`, `.hpp`, `.hh`, `.hxx`
- Go: `.go`

A detected language override (for example, a Python program saved as
`notes.txt`) is honoured by the LSP layer as well, as long as the language maps
to a configured profile.

### Server discovery

The manager resolves the profile's `command` through `RuntimeCatalog`, which
searches `PATH` using `PATHEXT` on Windows. Absolute paths are accepted as-is.
A `.cmd` or `.bat` shim is launched through `cmd.exe /c` with `call`, which
covers npm-installed servers on Windows.

If the command is not found:

- no process is started,
- the Servers tab gets an install card with the command and a documentation
  link,
- the Log tab records `Command not found: …`,
- the editor shows one notice per language/executable per workspace session.

The card is shown once, not on every keystroke. **Language → Language Servers
and Installs** or the panel's **Servers** tab can reopen it at any time.

### Quick start with Pyright

Pyright is the recommended Python server because it is a single npm install and
works on Windows, macOS and Linux.

```bash
npm install -g pyright
```

If `pyright-langserver` is not on `PATH`, add npm's global bin folder (on
Windows this is usually `%APPDATA%\npm`). Qorix reads `PATH` at launch, so
restart it after installing or changing `PATH`.

Then open a folder containing a Python file and wait for the first diagnostics.

---

## 2. Configuration

### 2.1 Layers

Profiles are applied from lowest to highest priority:

1. Built-in profiles (`src/features/lsp/lsp_config.gd`).
2. `user://lsp.json` — a global user override.
3. `<workspace>/.griddycode.json` — the top-level `"lsp"` key.
4. `<workspace>/.griddycode/lsp.json` — the recommended project file.

The Godot user folder is:

| OS | Folder |
| --- | --- |
| Windows | `%APPDATA%\Godot\app_userdata\Qorix` |
| Linux | `~/.local/share/godot/app_userdata/Qorix` |
| macOS | `~/Library/Application Support/Godot/app_userdata/Qorix` |

A malformed file is reported in the Log tab; it does not prevent the editor
from starting or discard the built-in profiles.

> **Trust warning:** a project config can name any executable and arguments.
> Opening a project and a matching source file starts that command. Only open
> projects you trust, or remove the `"lsp"` block from a project you do not
> trust. This is the same trust model as a workspace task or debug config.

### 2.2 Shape

```json
{
  "lsp": {
    "python": {
      "command": "pyright-langserver",
      "args": ["--stdio"],
      "root_markers": ["pyproject.toml", "pyrightconfig.json", ".git"],
      "settings": {
        "python": {
          "analysis": { "typeCheckingMode": "basic" }
        }
      }
    },
    "cpp": {
      "command": "C:/tools/llvm/bin/clangd.exe",
      "args": ["--log=error"],
      "root_markers": ["compile_commands.json", "CMakeLists.txt", ".git"]
    }
  }
}
```

A profile can also be a command string:

```json
{ "lsp": { "python": "C:/tools/pyright-langserver.cmd" } }
```

When a string is used, the built-in `args` and `root_markers` are retained.

### 2.3 Fields

| Field | Meaning |
| --- | --- |
| `command` | Required. Executable name on `PATH`, or an absolute path. |
| `args` | Array of arguments sent to the server. |
| `root_markers` | Files/folders that identify the project root. The nearest ancestor wins, stopping at the workspace root. |
| `extensions` | Extensions served by a custom profile (for example `["mine"]`). |
| `language_ids` | Map from Qorix language ids to the ids sent in `didOpen` (for example `{"javascript": "javascriptreact"}`). |
| `languages` | Array shorthand for `language_ids`. |
| `language_id` | A single id used for every language in the profile. |
| `display` | Name shown in the Servers tab. |
| `enabled` | Set to `false` to hide a built-in profile. |
| `settings` | Object sent with `workspace/didChangeConfiguration` and returned for `workspace/configuration`. |
| `initialization_options` | Object sent as `initializationOptions` during `initialize`. |
| `install` | Install card: `title`, `hint`, `commands` (array or string), `url`, `url_label`. |

### 2.4 Root selection

For each open file, `root_for()` walks up from the file looking for the first
folder that contains any `root_markers`. It stops at the workspace root. If no
marker is found, the workspace root is used when the file is inside it;
otherwise the file's own folder is used.

One server is kept per **profile + root**. Two unrelated projects opened in the
same workspace can therefore run two `clangd` processes without sharing state.

### 2.5 Custom language example

```json
{
  "lsp": {
    "mylang": {
      "display": "My Language",
      "command": "my-language-server",
      "args": ["--stdio"],
      "extensions": ["mine"],
      "language_ids": { "mylang": "mylang" },
      "root_markers": [".mylangroot"],
      "install": {
        "title": "Install My Language support",
        "hint": "Install the My Language server and put its launcher on PATH.",
        "commands": ["npm install -g my-language-server"],
        "url": "https://example.test/my-language-server"
      }
    }
  }
}
```

The language id must also be understood by the highlighter for syntax colours,
but the LSP features work from the extension and the profile even when the
highlighter falls back to plain text.

---

## 3. Process and protocol

### 3.1 Non-blocking transport

`src/features/lsp/lsp_client.gd` owns one process and its JSON-RPC state. It uses
`OS.execute_with_pipe(path, args, false)` and pumps both pipes from `_process`:

- writes are queued and flushed in small batches,
- stdout/stderr are drained in bounded chunks per frame,
- the UI thread never waits for a server,
- a slow or wedged server cannot freeze the editor.

On Windows the launcher is:

```text
cmd.exe /d /s /c "cd /d "<root>" && "<server>" "<arg>" …"
```

The whole command is one quoted string because Godot's `execute_with_pipe`
passes arguments through without adding quotes. This is what makes paths with
spaces work. `.cmd`/`.bat` shims are invoked with `call`, and `taskkill /F /T`
reaches the `node` process behind an npm shim.

On POSIX the launcher is:

```sh
/bin/sh -c 'cd <root> && exec <server> <args>'
```

### 3.2 Framing and requests

`src/features/lsp/lsp_protocol.gd` is a pure incremental parser:

- `Content-Length` is counted in UTF-8 bytes,
- headers and bodies may be split across reads,
- several messages may arrive in one read,
- malformed headers are reported instead of silently desynchronising.

Requests carry monotonically increasing integer ids. Every request has a
deadline (12 s by default, 25 s for `initialize`) and a callback. A cancelled
request removes the callback, sends `$/cancelRequest`, and resolves with code
`-32800`. At most 8 MB of outbound frames are queued; beyond that, messages are
dropped with a log line rather than growing without bound.

### 3.3 Initialize and shutdown

The client sends `initialize` with:

- the process id, client name/version and locale,
- `rootUri` and a `workspaceFolders` entry,
- capabilities for full-text sync, completion, hover, definition, references,
  formatting, rename, code actions, signature help, diagnostics and
  `workspace/applyEdit`,
- `initializationOptions` and `settings` when the profile defines them.

After the response it sends `initialized` and
`workspace/didChangeConfiguration`, then marks the client ready and opens every
document that belongs to it.

Shutdown is a handshake: `shutdown` → `exit` → wait 400 ms → kill the process
tree. If the server does not answer the shutdown request within 3 s, or the
connection is already broken, the process is killed directly. Closing the
editor stops every client; switching workspaces does the same before loading
the new config.

### 3.4 Document synchronization

The client uses **full-text sync** (`TextDocumentSyncKind.Full`). Every
`didChange` sends the whole buffer. This costs a little more bandwidth than
incremental ranges, but it makes undo, reload, external changes and
multi-edit operations agree with the server without maintaining a mirror.

- `didOpen` carries the current text and version.
- `didChange` is debounced for 120 ms and carries a new version.
- `didSave` sends the saved text.
- `didClose` is sent when a tab closes or changes language/profile.
- Background tabs are opened as soon as their server becomes ready.
- Untitled buffers are not sent to a server (they have no URI/path).

### 3.5 Crash recovery

If a server exits without a shutdown request:

1. its diagnostics are cleared,
2. the Log tab records `Exited unexpectedly (code …)`,
3. the client is restarted after 1 s, 2 s, then 3 s for the next crashes,
4. after more than three crashes in one minute, automatic restarts stop and the
   log asks the user to run **Language → Restart Language Servers**.

`Language → Restart Language Servers` also clears the crash history, reloads
the config, re-syncs open documents and starts the active file's server again.
Stderr is captured separately and shown in the Log tab, which is usually the
fastest way to see why a server refuses to start.

---

## 4. Features

### 4.1 Diagnostics and the Problems list

Servers publish diagnostics with `textDocument/publishDiagnostics`. The manager
normalizes severity, range, message, source, code and related information, then
paints the worst diagnostic per line:

- a coloured `●` in the LSP gutter,
- a 10%-opacity background tint on the line,
- a list row in **Problems** with file, line, message and severity colour.

While the user types, stale gutter marks are cleared immediately because line
numbers move. New diagnostics usually arrive within a few hundred
milliseconds. Clicking a gutter mark shows the full message for that line in
the hover card. Double-clicking (or pressing Enter on) a Problems row opens the
file and moves the caret to the reported position.

The Problems tab has a filter box (file, path, message, source) and a detail
pane. `Clear` clears diagnostics without stopping the servers. **Open Problems
when new errors appear** is off by default; when enabled, the panel only opens
when the total problem count grows, so a periodic republish does not fight a
user who just closed it.

### 4.2 Completion

Completion is merged with Qorix's existing Lua-based completion instead of
replacing it. The local pass opens the popup; the server result arrives
asynchronously and is appended to the same popup.

- Duplicate label/insert-text pairs are skipped.
- Snippets are converted to plain insert text (`greet(${1:name})` becomes
  `greet(name)`).
- Results are ignored when the caret moved while the server was thinking.
- `Completion from the language server` turns the server half off; local
  completion keeps working.
- Triggers come from normal typing and the editor's completion request, not
  from a hard-coded character list.

### 4.3 Hover

Resting the pointer on a symbol schedules `textDocument/hover` after 180 ms.
The result is converted from Markdown to BBCode and shown in a floating card
positioned next to the caret. The card:

- stays in screen space while the camera moves,
- flips above the line when there is no room below,
- stops above the open bottom dock,
- closes on Esc, a click outside it, a caret move, or a tab switch.

The explicit **Language → Show Hover Information** command (`Ctrl+Shift+H`)
works even when automatic hover is disabled. Hover failures are silent during
normal pointing and become a warning when invoked explicitly.

### 4.4 Definition and references

- **Go to Definition** (`F12`) sends `textDocument/definition`. A single
  location jumps directly; multiple locations open the location picker.
- **Find References** (`Shift+F12`) sends `textDocument/references` with
  `includeDeclaration: true` and opens a picker titled `References (n)`.

Both accept `Location`, `LocationLink` and arrays of either. Opening a result
uses the existing search-result path, so the file opens in a tab and the caret
lands on the reported UTF-16 column converted to a TextEdit code-point column.

### 4.5 Formatting

**Format Document** (`Shift+Alt+F`) sends `textDocument/formatting` with the
editor's indentation size and spaces/tabs setting, then applies the returned
`TextEdit[]` as one complex undo step.

- A single undo restores the whole formatting change.
- The buffer is left dirty; formatting never saves silently.
- A server that does not advertise `documentFormattingProvider` produces a
  clear warning instead of a request.
- Range formatting is not implemented.

### 4.6 Rename

**Rename Symbol** (`F2`) opens a small dialog with the current word and
location. The manager remembers the document, path, line and column from the
moment the dialog opened, so switching tabs while typing a new name cannot
rename the wrong symbol.

The server returns a `WorkspaceEdit`:

- a single-file edit is applied immediately,
- a multi-file edit opens the **Preview Changes** dialog with the file count,
  edit count, changed line numbers, and flags for unsaved or missing files,
- **Apply Changes** updates open buffers in memory and writes unopened files to
  disk,
- **Cancel** leaves everything untouched.

Open buffers with unsaved changes are updated in memory only; their disk files
are not overwritten. If a write fails, the edit is kept in the buffer and the
buffer is left dirty so the change is not lost.

### 4.7 Code actions and the lightbulb

After diagnostics arrive (or the caret moves), the manager asks for
`textDocument/codeAction` with the diagnostics overlapping the current line.
The result is cached per line:

- a `✦` appears in the action gutter when actions exist,
- clicking the gutter opens the picker for that line,
- **Show Code Actions** (`Ctrl+.`) opens it on demand,
- the picker shows the action title, kind and preferred marker.

Applying an action can take four paths:

1. a complete `WorkspaceEdit` is applied (single file) or previewed (multiple
   files),
2. a `Command` is sent through `workspace/executeCommand`; if its result is a
   `WorkspaceEdit`, it is applied or previewed,
3. an action with `data` but no edit is completed with `codeAction/resolve`,
   then applied,
4. a server-initiated `workspace/applyEdit` is applied immediately and
   acknowledged with `{ "applied": true }`.

Resource operations (`create`, `rename`, `delete` file operations inside a
`WorkspaceEdit`) are detected and listed in the preview but are not applied.
The dialog says so instead of pretending the refactor was complete.

### 4.8 Signature help

Signature help opens while the caret is inside a call's argument list. A small
context scanner checks parentheses and commas first, so typing a plain `(` in a
comment does not pop the card.

- Auto trigger debounce: 280 ms.
- `Ctrl+Shift+Space` triggers immediately at the caret.
- The active signature and active parameter are highlighted in the card.
- Multiple overloads show `n of m overloads`.
- The card sits above the call line when possible and below it when there is no
  room, never under the bottom dock.

---

## 5. The Language panel

The panel is `src/features/lsp/lsp_panel.gd`, a third bottom dock that shares the
strip with the terminal and the Run output. Opening one hides the other two;
closing it never stops a server. The panel has three tabs:

### Problems

A jumpable list of every diagnostic for open documents, with a filter and a
detail pane. The header counts errors, warnings and the total.

### Servers

One row per configured profile:

| Symbol | Meaning |
| --- | --- |
| `●` | server running and initialized |
| `◐` | process started, initialize not finished |
| `○` | command found, server not started yet |
| `✕` | command not found |

The detail pane shows languages, command, arguments, root markers, roots, and
the install card when needed. Install cards include the executable being
looked for, copyable install commands, and a documentation button. The card is
plain UI: nothing is downloaded or run automatically.

### Log

A readable transcript of server lifecycle, stderr, protocol errors and config
problems. The panel keeps the last 600 lines; each client keeps the last 400
lines and the last 16 KB of stderr. **Clear log** clears only the display.

The panel remembers whether it was open and which tab was selected in the
session. Diagnostics themselves are not persisted; they reappear when a server
analyzes the reopened files.

---

## 6. Commands and shortcuts

All commands are in the **Language** menu and the command palette.

| Command | Default shortcut | Scope |
| --- | --- | --- |
| Toggle Problems Panel | `Ctrl+Shift+M` | global |
| Go to Definition | `F12` | editor |
| Find References | `Shift+F12` | editor |
| Rename Symbol | `F2` | editor |
| Show Code Actions | `Ctrl+.` | editor |
| Format Document | `Shift+Alt+F` | editor |
| Show Hover Information | `Ctrl+Shift+H` | editor |
| Show Signature Help | `Ctrl+Shift+Space` | editor |
| Language Servers and Installs | — | global |
| Restart Language Servers | — | global |

`Ctrl+.` is also accepted while the caret is in a text field in the editor, as
long as the editor scope has focus. The picker takes focus and closes with
`Esc`.

---

## 7. Settings

The **Language Support** category in `Ctrl+,` contains:

| Setting | Default | Effect |
| --- | --- | --- |
| Language Servers | on | Master switch. Off stops every server and hides the panel features. |
| Diagnostics: errors and warnings | on | Gutter marks and Problems rows. Turning it off clears existing marks but keeps servers running. |
| Completion from the language server | on | Merge server suggestions into the local completion popup. |
| Hover documentation | on | Automatic hover on pointer rest. The explicit command still works when off. |
| Signature help while typing | on | Automatic signature cards inside calls. Manual trigger still works when off. |
| Code action lightbulb | on | The `✦` gutter and cached actions. `Ctrl+.` still works when off. |
| Open Problems when new errors appear | off | Open the Problems tab only when the total problem count grows. |

Changing the master switch starts or stops servers immediately. Other
feature toggles are read at request time; no restart is required.

---

## 8. Session restore

The session snapshot includes the Language panel's `open` and `tab` state
under the `lsp` key. On restore:

1. the panel reopens on the same tab,
2. documents are reopened as usual,
3. each server starts lazily for the active file and then opens every matching
   background document,
4. diagnostics are recomputed by the server.

Servers are not kept alive across an editor restart. A crash or forced kill
leaves no orphan process: the manager kills the process tree on exit, and a
server started by a previous process cannot attach to the new editor.

---

## 9. File map

| Path | Responsibility |
| --- | --- |
| `src/features/lsp/lsp_protocol.gd` | JSON-RPC framing, parsing, request/response/notification helpers. |
| `src/features/lsp/lsp_text.gd` | UTF-16 positions, edit application, payload normalization, Markdown/BBCode helpers. |
| `src/features/lsp/lsp_config.gd` | Built-in profiles, layered config, language/root/command resolution, install data. |
| `src/features/lsp/lsp_client.gd` | One process, non-blocking pipes, initialize/shutdown, requests, crash detection. |
| `src/features/lsp/lsp_manager.gd` | Document sync, clients/restarts, diagnostics, features, workspace edits. |
| `src/features/lsp/lsp_panel.gd` | Problems/Servers/Log dock and install cards. |
| `src/features/lsp/lsp_hover_panel.gd` | Floating hover/diagnostic card. |
| `src/features/lsp/lsp_signature_panel.gd` | Floating signature-help card. |
| `src/features/lsp/lsp_picker.gd` | Shared location/code-action picker. |
| `src/features/lsp/lsp_rename_dialog.gd` | Rename name entry. |
| `src/features/lsp/workspace_edit_preview.gd` | Multi-file edit review dialog. |
| `src/editor/editor_view.gd` | LSP gutters, diagnostic painting, lightbulb, completion merge, native symbol signals. |
| `src/main/file_manager.gd` | Manager/HUD creation, document lifecycle hooks, dock coexistence, session capture. |
| `src/platform/builtin_commands.gd` | Language commands and shortcuts. |
| `src/platform/settings_service.gd` | Language Support settings. |

---

## 10. Tests

The headless unit suite covers the pure protocol, text, config, client and
manager logic:

```bash
godot --headless --path . --script res://tests/test_runner.gd
```

Language-server suites:

- `tests/unit/features/lsp/test_lsp_protocol.gd` — framing, split reads, multiple
  messages, malformed headers, UTF-8 byte lengths.
- `tests/unit/features/lsp/test_lsp_text.gd` — UTF-16 conversion, edit application,
  completion/hover/diagnostic/location/code-action normalization.
- `tests/unit/features/lsp/test_lsp_config.gd` — layered config, profiles, language/root
  lookup, PATH resolution, install help.
- `tests/unit/features/lsp/test_lsp_client.gd` — request tracking, timeouts, cancellation,
  initialize/shutdown ordering, crash/exit handling.
- `tests/unit/features/lsp/test_lsp_manager.gd` — document sync, diagnostics, restart
  limits, server rows, install state, workspace edits.

At the time of writing the suite is **1413 checks across 32 suites** and exits
with code 0.

### End-to-end run

`tests/integration/lsp_e2e_runner.gd` boots the real editor scene, starts the deterministic
fake server in `tests/fixtures/fake_lsp_server.py`, and drives the full vertical
slice: launch, initialize, diagnostics, completion merge, hover,
definition/references, formatting, signature help, rename preview/apply, code
actions (including resolve), server-initiated `workspace/applyEdit`, crash
restart, the missing-server install card, session capture and shutdown.

```powershell
$env:APPDATA = "$env:TEMP\griddy_lsp_appdata"
godot --headless --path . --script res://tests/integration/lsp_e2e_runner.gd -- `
  --python="C:/path/to/python.exe"
```

The runner creates a throwaway workspace when `--workspace` is omitted. Pass
`--workspace=<path> --keep` to inspect the fixture and
`lsp-transcript.jsonl` afterwards. Do not redirect `LOCALAPPDATA`: on Windows
the Python install manager uses it to locate the interpreter. `--python` is
optional; it is useful when `python` on `PATH` is a launcher that cannot run
under the sandboxed `APPDATA`. The runner skips (exit code 0) when Python or
the fixture is unavailable. A passing run ends with:

```text
All LSP end-to-end checks passed: 59 checks.
```

The fake server writes every protocol message to `lsp-transcript.jsonl` in the
workspace. When a check fails, the runner prints the LSP log and the tail of
that transcript, which is usually enough to see whether the editor or the
server stopped talking.

### Live server smoke

A headless smoke run against Pyright 1.1.414 on Windows also passed: server
startup, diagnostics, completion, hover, definition, references, a two-file
rename, and shutdown. That run exposed a real-world URI difference — Pyright
lowercases the Windows drive letter (`file:///c%3A/...`), while
`path_to_uri()` emits `file:///C%3A/...`. Diagnostics are now resolved by path
when the exact URI is unknown, and `test_lsp_manager.gd` covers the fallback.

Pyright does not advertise document formatting and returns no quick fix for the
demo's undefined name; §12 notes where another server is needed.

---

## 11. Known limitations

- **No auto-install.** Qorix never downloads or installs a language
  server. The Servers tab explains what to install; the user runs the command.
- **Server coverage is five profiles.** Custom profiles handle other
  languages, but syntax highlighting still comes from the separate language
  plugin system.
- **Full-text sync only.** Large files are re-sent on every debounced change.
  Correctness was chosen over incremental bandwidth.
- **Diagnostics are for open documents.** A server may publish diagnostics for
  a closed file; the manager ignores URIs it did not open.
- **Code actions need a complete result or supported resolve.** Actions that
  require `codeAction/resolve` work only when the server advertises
  `resolveProvider`. Actions with neither an edit, a command, nor resolvable
  data produce a warning.
- **Workspace resource operations are not applied.** File create/rename/delete
  operations inside a `WorkspaceEdit` are listed in the preview with a warning
  but are skipped.
- **Formatting is whole-document.** Range formatting, format-on-save and
  format-on-type are not implemented.
- **Completion snippets are flattened.** `${1:name}` becomes `name`; tab stops
  are not supported by the popup.
- **Completion documentation is not displayed.** The popup shows labels,
  details and icons; hover is the place for full documentation.
- **No semantic tokens, inlay hints, code lens, call hierarchy, document
  symbols or folding ranges.** Servers that advertise them are still accepted;
  the extra notifications are ignored.
- **One workspace folder is advertised.** A server is started per project root,
  but the `workspaceFolders` request returns the open workspace root, not a
  multi-root list.
- **Crash restarts are capped.** More than three crashes in a minute stop
  automatic restarts until **Restart Language Servers** is run.
- **Logs are bounded.** The panel keeps 600 lines; a client keeps 400 lines and
  16 KB of stderr. A very chatty server can lose early context.
- **Project config is trusted.** A `.griddycode.json` or `.griddycode/lsp.json`
  can start any executable. Do not open untrusted projects with an LSP block.
- **Hover cards are not full web views.** Markdown is converted to BBCode;
  images, embedded HTML and complex tables are shown as text.
- **Signature help is a heuristic outside the protocol.** It scans the current
  line for an open call; unusual macros or multi-line strings can confuse the
  auto-trigger. The manual command always asks the server.

---

## 12. Manual acceptance run

Use this when validating language-server support with a real server. The fake-server runner
covers the protocol; this pass covers what a person sees.

### 12.1 Setup

1. Install Pyright (`npm install -g pyright`) and confirm
   `pyright-langserver --version` works in a new terminal.
2. Create a folder with:

   ```text
   lsp-demo/
     pyproject.toml
     main.py
     helper.py
   ```

   `pyproject.toml`:

   ```toml
   [project]
   name = "lsp-demo"
   ```

   `main.py`:

   ```python
   def greet(name):
       return "Hello " + name


   def main():
       print(greet("world"))
       missing_symbol  # TODO: remove
   ```

   `helper.py`:

   ```python
   from main import greet


   def shout():
       return greet("!").upper()
   ```

3. Start Qorix, open the folder, and open `main.py`. Open `helper.py`
   in a second tab, then return to `main.py`. Pyright only renames or finds
   references in files it has analyzed, so both tabs must be opened first.

Pyright covers diagnostics, completion, hover, signature help, navigation and
rename. It does **not** advertise document formatting, and it returns no quick
fix for this demo's undefined name. Formatting and code-action checks therefore
need a server that advertises those capabilities, or the fake-server E2E run in
§10.

### 12.2 Diagnostics and Problems

- [ ] Within a few seconds, line 6 shows a coloured `●` and a tint.
- [ ] `Ctrl+Shift+M` opens **Problems** with at least an undefined-name error
      and an unused-expression warning.
- [ ] Clicking the gutter mark shows the message in a floating card.
- [ ] Double-clicking a Problems row opens the file at that line.
- [ ] The filter box hides rows that do not match.
- [ ] **Clear** removes the marks; the next edit or save brings fresh ones.

### 12.3 Completion, hover, signature

- [ ] On a new line inside `main()`, type `gre` and pause: the popup contains
      `greet` from the server alongside local symbols, with no duplicates.
- [ ] Accept `greet`, type `(`, and confirm signature help appears with
      `name: Unknown` highlighted.
- [ ] Hover over `greet` in `helper.py`: a card shows the signature (and
      documentation when the symbol has a docstring).
- [ ] `Esc` or a caret move closes the hover card.
- [ ] `Ctrl+Shift+H` shows hover information even with automatic hover off.

### 12.4 Navigation, format, rename

- [ ] Put the caret on `greet` in `main.py` and press `F12`: the caret jumps to
      the `def greet` line.
- [ ] Press `Shift+F12` on `greet`: the picker lists the declaration and both
      call sites.
- [ ] Pyright does not advertise document formatting. With a formatter-capable
      server (for example `clangd` or `rust-analyzer`), press `Shift+Alt+F`:
      the buffer is formatted, the tab shows `*`, and one `Ctrl+Z` restores the
      previous text. With Pyright, the command shows a clear warning instead of
      sending a request.
- [ ] Press `F2` on `greet`, type `welcome`, and confirm the preview lists
      `main.py` and `helper.py` with line numbers.
- [ ] **Apply Changes** updates the open buffer and writes `helper.py` on disk.
- [ ] **Cancel** on a second rename changes nothing.

### 12.5 Code actions

Pyright advertises `quickfix` and `source.organizeImports` but returns no
quick fix for the undefined name in this demo. Use a server that offers actions
(clangd and `typescript-language-server` are good choices), or skip this
section with Pyright.

- [ ] Put the caret on an actionable line and press `Ctrl+.`: the picker lists
      the server's quick fixes.
- [ ] The action gutter shows `✦` on a line with actions; clicking it opens the
      same picker.
- [ ] Applying an action with an edit changes the buffer (or opens a preview if
      it touches several files).
- [ ] Applying a command action has a visible effect; failures appear as a
      warning, not a silent no-op.

### 12.6 Servers and install cards

- [ ] **Language → Language Servers and Installs** shows Python as `●` and the
      other four profiles with `○` or `✕`.
- [ ] Open a `.rs` file without `rust-analyzer`: an install card appears on the
      **Servers** tab with the executable name, a copyable command and a
      documentation button.
- [ ] **Copy** puts the command on the clipboard.
- [ ] **Restart Language Servers** stops and restarts the Python server; the Log
      tab shows the sequence.
- [ ] Kill the Python server process in Task Manager: the Log shows
      `Exited unexpectedly`, and the server restarts within a few seconds.

### 12.7 Panel and session

- [ ] The Language panel, terminal and Run output never cover each other;
      opening one closes the others.
- [ ] Resize the window: the panel stays aligned to the bottom.
- [ ] With the panel open on **Log**, close and relaunch Qorix: the panel
      reopens on the Log tab and the server starts again for `main.py`.
- [ ] With **Language Servers** off in Settings, no server process starts and
      the gutter stays empty; turning it back on starts the active file's
      server without a restart.

### 12.8 Log and troubleshooting

If a feature does nothing, check **Language → Language Servers and Installs**:

1. **Servers**: is the command found? Is the row `●`?
2. **Log**: read the last lines for stderr, a config error, or a timeout.
3. Run the same command in a terminal from the project folder and confirm it
   speaks LSP (`Content-Length` frames) rather than exiting immediately.
4. Confirm the server supports the capability (for example, `clangd` formats
   and renames; a minimal server may only publish diagnostics).
5. After installing a server, restart Qorix so it sees the updated
   `PATH`.
