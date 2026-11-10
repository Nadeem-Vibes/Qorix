# Qorix Manual Test Checklist

Use this checklist before a release or after a large refactor. The automated
suites cover the logic; this pass covers what a person can actually see, click
and type.

- **Unit tests:** `godot --headless --path . --script res://tests/test_runner.gd`
- **Git integration:** `godot --headless --path . --script res://tests/integration/git_integration_runner.gd`
- **Git UI:** `godot --headless --path . --script res://tests/integration/git_ui_runner.gd` (use a throwaway `APPDATA`; it creates and removes its own temporary repository)
- **Debugger:** `godot --headless --path . --script res://tests/integration/dap_e2e_runner.gd -- --python="C:/path/to/python.exe"` (needs `debugpy`; use a throwaway `APPDATA`)
- **Acceptance tests:** see [Running the acceptance suite](#running-the-acceptance-suite)
- **Found a problem?** Follow [Reporting an error](#reporting-an-error).

Record the result of every line as `PASS`, `FAIL`, or `SKIP` (with a reason).
A section is only green when every non-skipped line passes.

---

## 1. Test environment

### 1.1 Build and launch

- [ ] Launch the project from the Godot editor with **F6/F5**, and from a
      terminal with `godot --path .`.
- [ ] The window opens maximized on Windows; the bottom terminal row is not
      hidden behind the taskbar.
- [ ] The top bar (menus + toolbar) is visible above the tab strip.
- [ ] No `SCRIPT ERROR` appears in the console during a clean launch.
- [ ] `Ctrl+I` opens the About panel; `Esc` closes it.

### 1.2 Fresh profile

Close Qorix, rename the user data folder, and relaunch:

| OS | Folder |
| --- | --- |
| Windows | `%APPDATA%\Godot\app_userdata\Qorix` |
| Linux | `~/.local/share/godot/app_userdata/Qorix` |

- [ ] A fresh profile starts with the welcome file picker, not a crash.
- [ ] Picking a file opens it and closes the picker.
- [ ] Closing and relaunching restores the previous session (see §11).

### 1.3 Test workspace

Create a folder with this shape (the names matter for the acceptance suite):

```text
griddy-test/
  alpha.txt          # two lines containing "needle"
  beta.gd            # func beta(): + two "needle" comments
  readme.md
  sub/
    gamma.md         # one "needle"
    delta.txt        # one "needle"
  .git/ignored.txt
  node_modules/ignored.js
  build/ignored.txt
```

- [ ] `Ctrl+Shift+O` opens the folder and the explorer shows 5 files.
- [ ] `.git`, `node_modules`, and `build` do not appear in the tree or search.

---

## 2. Tabs and per-tab editor state

- [ ] Open `alpha.txt`, `beta.gd`, and `readme.md`. Three tabs appear.
- [ ] Type in `alpha.txt`, switch to `beta.gd`, and press `Ctrl+Z`.
      Only `beta.gd` changes; `alpha.txt` keeps its edit.
- [ ] Scroll `alpha.txt` to the bottom, switch away and back.
      Its scroll position is preserved.
- [ ] Put the caret on line 3 of `beta.gd`, switch away and back.
      The caret is restored.
- [ ] Make a selection in `alpha.txt`, switch away and back.
      The selection is preserved.
- [ ] `Ctrl+W` closes the active tab. `Ctrl+Shift+T` reopens it.
- [ ] Close a dirty tab: the save/discard prompt appears.
- [ ] Close the last tab: the editor does not crash; `Ctrl+N` creates a new
      untitled buffer.
- [ ] The active tab is visually distinct and the tab title shows `*` while
      dirty.

---

## 3. Files, saving, and external changes

- [ ] `Ctrl+N` creates an untitled buffer; typing marks it dirty.
- [ ] `Ctrl+S` on an untitled buffer opens Save As.
- [ ] `Ctrl+Shift+S` saves a copy under a new name and keeps the new tab.
- [ ] Saving clears the dirty marker.
- [ ] Edit a file in another program, then focus Qorix.
      The external-change prompt appears.
- [ ] **Compare** shows the buffer and disk versions side by side.
- [ ] **Reload** replaces the buffer with the disk text and clears dirty.
- [ ] **Keep mine** keeps the buffer, marks it dirty, and does not silently
      overwrite the disk file on the next autosave.
- [ ] If autosave is enabled, it never overwrites an external change; it raises
      the prompt instead.

---

## 4. Find and replace in the current file

- [ ] `Ctrl+F` opens the find panel; the caret stays in the editor.
- [ ] Type a term: matches are highlighted and the counter is correct.
- [ ] `Enter` / `Shift+Enter` move to the next / previous match.
- [ ] `Esc` closes the find panel.
- [ ] `Ctrl+H` opens replace mode.
- [ ] Replace one and Replace All update the buffer and the undo history.
- [ ] With the terminal focused, `Ctrl+F` does **not** open the editor find
      panel (see §8.3).

---

## 5. Workspace and file explorer

- [ ] `Ctrl+Shift+E` toggles the explorer dock.
- [ ] Opening a folder indexes it without freezing the UI; the status shows
      progress on large folders.
- [ ] Folders expand lazily; collapsing and re-expanding does not duplicate
      rows.
- [ ] Clicking a file opens it; clicking a folder selects and expands it.
- [ ] Right-click a folder: New File, New Folder, Rename, Delete are available.
- [ ] New File creates the file on disk, adds it to the index, and opens it.
- [ ] Rename moves the file on disk and keeps the open tab pointing at the new
      path.
- [ ] Delete asks for confirmation, removes the file, updates the index, and
      closes a clean tab.
- [ ] Deleting a dirty file warns instead of discarding silently.
- [ ] The explorer and global search share the left dock; opening one closes
      the other.
- [ ] The camera shifts so the open left dock does not cover the code.
- [ ] Recent workspaces appear in **File → Open Recent Folder** and in the
      command palette after reopening a folder.

---

## 6. Global search and replace

- [ ] `Ctrl+Shift+F` opens global search.
- [ ] Search for `needle`: 6 results across 4 files (alpha, beta, gamma,
      delta); ignored folders are absent.
- [ ] Results are grouped by file with line numbers and previews.
- [ ] Clicking a result opens the file and moves the caret to that line.
- [ ] Replace preview summarizes the match count and shows the diff.
- [ ] Apply replace writes all files, reloads clean open documents, and leaves
      dirty documents untouched.
- [ ] Case-sensitive / whole-word / regex toggles (if present) change results
      as expected.
- [ ] Searching a folder with thousands of files keeps the UI responsive and
      can be cancelled.

---

## 7. Quick open, command palette, menus, and toolbar

### 7.1 Quick open

- [ ] `Ctrl+P` opens quick open with the workspace file list.
- [ ] Typing `gamma` ranks `sub/gamma.md` first.
- [ ] Space-separated tokens (`sub gamma`) match.
- [ ] `Enter` opens the selected file; `Esc` closes the palette.
- [ ] With no workspace open, quick open still lists files from the current
      folder.

### 7.2 Command palette

- [ ] `Ctrl+Shift+P` opens the palette in command mode.
- [ ] Every visible command appears; hidden commands do not.
- [ ] Each row shows the **effective** shortcut, not the old default.
- [ ] Disabled commands are greyed out and cannot run.
- [ ] Typing filters by label, category, and id.
- [ ] Running **Open Settings** closes the palette, waits for the fade, then
      opens Settings (no overlay is lost).
- [ ] Running **Quick Open File** switches the same palette to file mode.

### 7.3 Generated menus and toolbar

- [ ] File, Edit, View, Terminal, Run, Preferences, and Help menus are
      populated (not empty). The Themes menu does not exist; themes switch only
      through the Ctrl+T picker, which lists every theme in `user://themes/`.
- [ ] Menu items show their shortcuts and disabled items are greyed out.
- [ ] Checkable items (file tree, search, terminal, setting toggles) show the
      correct check state.
- [ ] Toolbar buttons match the registry and show `Label (Shortcut)` tooltips.
- [ ] Clicking a menu item and a toolbar button runs the same command as the
      shortcut.

---

## 8. Commands, keybindings, and scopes

### 8.1 Rebinding

- [ ] `Ctrl+Alt+K`, **Preferences → Keyboard Shortcuts**, and the Settings
      button all open the shortcut editor.
- [ ] The panel lists the registry commands grouped by category and can be
      filtered.
- [ ] Click a shortcut, press `Ctrl+Alt+U`: the row updates immediately.
- [ ] The palette row for that command shows `Ctrl+Alt+U`.
- [ ] The toolbar tooltip for that command shows `Ctrl+Alt+U`.
- [ ] The new chord works and the old chord no longer works.
- [ ] Restart Qorix: the override is still active.
- [ ] **Reset** on one row restores that command's default.
- [ ] **Reset all** restores every default and clears the overrides file.
- [ ] Assigning a chord already used in an overlapping scope shows a conflict;
      `Enter` forces it, `Esc` cancels.
- [ ] Chords in different scopes may overlap (for example `Ctrl+F` in editor
      and terminal).
- [ ] `Delete`/`Backspace` while capturing unbinds the command.
- [ ] `Esc` while capturing cancels without changing anything.

### 8.2 Persistence file

- [ ] `user://keybindings.json` exists after a rebind.
- [ ] It contains **only overrides**, not every default.
- [ ] Deleting the file and restarting restores all defaults without errors.

### 8.3 Scope routing

- [ ] Focus the code editor and press `Ctrl+F`: find opens.
- [ ] Focus the terminal and press `Ctrl+F`: find does **not** open, and the
      terminal receives the key.
- [ ] Focus the terminal and press `Ctrl+S`: the active file still saves
      (global commands work in terminal scope).
- [ ] Focus the global search box and press `Ctrl+F`: editor find does not
      steal the key.
- [ ] With a dialog open, only global/dialog commands fire.
- [ ] `Esc` closes the focused panel; from the editor with nothing open it
      opens the file picker.
- [ ] `Esc` inside a text field closes the panel without popping the file
      picker open.

### 8.4 Adding a command (developer check)

- [ ] Register one command with a single `registry.register(...)` call
      (`label`, `category`, `scope`, `shortcut`, `handler`).
- [ ] Without editing any other file, it appears in the palette, the matching
      menu, and routes its shortcut immediately.
- [ ] Unregistering it removes it from the palette/menu and stops routing.

---

## 9. Terminal and running code

### 9.1 Terminal

- [ ] `` Ctrl+` `` toggles the terminal dock.
- [ ] `` Ctrl+Shift+` `` opens a new terminal tab.
- [ ] The terminal starts in the workspace/file directory.
- [ ] Typing, arrow keys, `Tab` completion, and `Ctrl+C` reach the shell.
- [ ] Terminal tabs can be switched and closed independently.
- [ ] **Open Terminal in File's Folder** changes to the active file's folder.

### 9.2 Captured Run panel

Open a non-interactive Python, JavaScript, C, Java, or Go file and press `F5`.

- [ ] The Run panel opens at the bottom and the terminal dock hides.
- [ ] The header shows the profile, the exact command, and the working
      directory.
- [ ] Output streams while the program runs; **Stop** is enabled and **Run** is
      disabled.
- [ ] A clean program prints its output, ends with a success status, and shows
      no diagnosis cards.
- [ ] A syntax error shows a friendly title, a short explanation, the exact
      `file:line` link, and a **Show me the fix** action.
- [ ] Clicking the `file:line` link opens the file and places the caret on the
      reported line.
- [ ] **Show me the fix** opens the same location and keeps the fix text
      visible.
- [ ] **Explain: Off** hides the diagnosis cards without hiding the raw output;
      it stays off after a restart.
- [ ] **Clear** empties the panel but does not stop a running program.
- [ ] Closing the panel with **✕** keeps a captured program running;
      `Ctrl+Shift+U` reopens it.
- [ ] `Shift+F5` stops a captured run. A program that ignores Ctrl+C is killed
      after the grace period.
- [ ] Starting a second run while one is active is predictable: the first is
      stopped, or a short “still stopping” card appears. No orphan process is
      left behind.
- [ ] Very long output remains scrollable and ends with an “output was
      truncated” notice instead of freezing the editor.
- [ ] No marker such as `__GRIDDY_RUN_START_...` ever appears in the panel.
- [ ] A program that prints to stderr has that text in the panel too.
- [ ] A program that prints `file:line` in a stack trace produces a clickable
      link even when no diagnosis rule matches.

### 9.3 Terminal mode and interactive programs

- [ ] `F5` on a Python file containing `input(...)` (or `sys.stdin`) opens the
      terminal automatically and types the command; the prompt accepts keyboard
      input normally and no `EOFError` appears.
- [ ] The same auto-terminal behavior still respects `F6`, a profile with
      `"mode": "terminal"`, and a project that sets `"auto_terminal": false`.
- [ ] A profile with `"mode": "terminal"` also uses the terminal instead of the
      Run panel.
- [ ] Run a small HTTP server from a project config: it keeps running in the
      terminal, prints its URL, and stops with `Ctrl+C`.
- [ ] When detection misses a reader, `F5` shows the “waiting for input” card
      with a **Run in Terminal (F6)** action instead of hanging.
- [ ] The Run panel and terminal never cover each other; opening one closes the
      other.

### 9.4 Run configuration

- [ ] **Run → Edit Run Configuration** creates
      `.griddycode/run.json` from the template when it does not exist and opens
      it.
- [ ] A custom `command` in that file is used instead of the built-in profile.
- [ ] `cwd` set to `$workspace` runs the program from the project root; `$dir`
      runs it from the source file's folder.
- [ ] A filename containing spaces works with `$file` and with a hand-written
      `"$file"` in the command.
- [ ] A malformed config shows a **Run config warning** in the panel with the
      file name and the parse error, and does not crash.
- [ ] A missing runtime (for example, rename `python` from `PATH` or use a
      profile that needs an uninstalled compiler) shows an install card with a
      hint and a link, not a raw shell error.
- [ ] With **Run: save file first** off, the interpreter sees the last saved
      text; with it on, it sees the current buffer.
- [ ] With **Run: shebang first** on, a `#!/usr/bin/env python3` file runs
      through that interpreter even if its extension is unusual.

### 9.5 Offline language detection

- [ ] Open a realistic Python program saved as `notes.txt`. A notice reports
      the detected language and confidence, and the file highlights as Python.
- [ ] Press `F5` on that `.txt` file: it uses the Python run profile.
- [ ] **Edit → Detect Language in Current File** applies a match even for a
      short or low-confidence snippet, and the notice says it is a weak match.
- [ ] **Edit → Clear Detected Language** returns to the `.txt` language and
      stops using the Python run profile.
- [ ] A real `.py` file is never auto-detected as something else.
- [ ] Turn **Detect Language in Plain Text** off in Settings and reopen a
      `.txt` file: no detection notice appears.
- [ ] Restart the editor: a manual or automatic language override is restored
      with the session.

### 9.6 Shutdown and cleanup

- [ ] Closing the editor while a captured run is active kills the child
      process.
- [ ] Closing the editor while a terminal run is active kills the shell.
- [ ] After a run finishes, no extra `cmd.exe`, `python.exe`, or compiler
      process remains in the task manager.

---

## 10. Language servers (LSP)

The built-in suites use a fake server; this pass needs a real one. Pyright is
the reference Python server:

```bash
npm install -g pyright
pyright-langserver --version
```

Restart Qorix after installing so it re-reads `PATH`. Use the demo project
from [Language servers §12.1](../user/language-servers.md#121-setup) (`main.py` calls `greet`,
declares it, and references an undefined `missing_symbol`; `helper.py` imports
it). Open both Python files before testing references or rename: Pyright only
searches files it has analyzed. Every check below can be skipped when no server
is installed, but record the reason.

### 10.1 Servers and diagnostics

- [ ] Open `main.py`. Within a few seconds the Python row is `●` in
      **Language → Language Servers and Installs → Servers**.
- [ ] The undefined-name line shows a coloured `●` and a line tint.
- [ ] `Ctrl+Shift+M` opens **Problems** with the undefined name and the
      unused-expression warning; the header counts match the rows.
- [ ] Clicking the gutter mark shows the full message in a floating card.
- [ ] Double-clicking a Problems row opens the file and moves the caret to the
      reported line.
- [ ] The filter box hides rows that do not match; **Clear** removes the marks,
      and the next edit or save brings fresh ones.
- [ ] Open a `.rs` file without `rust-analyzer`: the **Servers** tab shows an
      install card with the executable, a copyable command, and a docs button.
      Nothing is downloaded or started automatically.
- [ ] **Copy** puts the install command on the clipboard.
- [ ] In Settings, turn **Language Servers** off: processes stop and gutter
      marks clear. Turn it back on: the active file's server restarts without
      relaunching the editor.

### 10.2 Completion, hover, signature

- [ ] Inside `main()`, type `gre` and pause: the popup contains `greet` from the
      server next to local symbols, with no duplicates.
- [ ] Accept `greet`, type `(`, and signature help appears; the active `name`
      parameter is highlighted.
- [ ] Hover `greet` in `helper.py`: the card shows the signature (and
      documentation when the symbol has a docstring).
- [ ] `Esc`, a click outside, or a caret move closes the card.
- [ ] With automatic hover off, `Ctrl+Shift+H` still shows hover information.

### 10.3 Navigation, format, rename

- [ ] Put the caret on `greet` and press `F12`: the caret jumps to
      `def greet`.
- [ ] `Shift+F12` lists the declaration and both call sites.
- [ ] Pyright does not advertise formatting, so `Shift+Alt+F` shows a clear
      warning instead of sending a request. With a formatter-capable server
      (`clangd`, `rust-analyzer`), it formats the document; the tab shows `*`,
      and one `Ctrl+Z` restores the previous text.
- [ ] `F2` on `greet`, rename to `welcome`: the preview lists `main.py` and
      `helper.py` with the changed line numbers.
- [ ] **Apply Changes** updates the open buffer and writes `helper.py` to disk.
- [ ] Cancelling a second rename changes nothing.

### 10.4 Code actions and recovery

Pyright returns no quick fix for the undefined name in the demo. Run these
checks with a server that offers actions (for example `clangd` or
`typescript-language-server`), or mark them skipped.

- [ ] On an actionable line, `Ctrl+.` lists the server's quick fixes, and the
      `✦` gutter mark on that line opens the same picker.
- [ ] Applying a quick fix changes the buffer (or opens a preview when several
      files are touched); a failing command shows a warning, not a silent no-op.
- [ ] Kill the Python server in Task Manager: **Log** shows
      `Exited unexpectedly`, and the server restarts within a few seconds.
- [ ] **Restart Language Servers** stops and starts the server; **Log** shows the
      full sequence and no orphan process is left behind.
- [ ] With the panel open on **Log**, relaunch Qorix: the panel reopens on
      **Log** and the server starts again for the restored file.

### 10.5 Docks and settings

- [ ] The Language panel, terminal, and Run output never cover each other;
      opening one closes the others.
- [ ] Resizing the window keeps the panel aligned to the bottom.
- [ ] Turning off **Language Servers** or closing the panel never freezes the
      editor; a slow server cannot block typing.

---

## 11. Session restore and crash safety

Build a session with:

1. `alpha.txt` edited but **not saved** (dirty).
2. `beta.gd` open and clean, caret at line 1, column 3.
3. An untitled buffer named `Scratch`.
4. The search dock open with results.
5. A terminal tab titled `TestTerm` with a custom working directory.

- [ ] Close Qorix normally and relaunch: all three tabs return.
- [ ] The unsaved `alpha.txt` text and dirty state return.
- [ ] Caret positions and scroll offsets return for every tab.
- [ ] The active tab is the one that was active before closing.
- [ ] The untitled buffer and its text return.
- [ ] The search dock reopens.
- [ ] The terminal tab, title, and working directory return.
- [ ] The workspace root returns.
- [ ] Force-kill Qorix (Task Manager / `kill -9`), relaunch: the crash
      recovery path restores the same session and shows the recovery notice.
- [ ] A corrupt or empty session file does not prevent launch; a warning is
      shown and a clean session starts.

---

## 12. Settings, themes, and appearance

- [ ] `Ctrl+,` opens Settings.
- [ ] Every category scrolls and every control changes its setting.
- [ ] Settings persist across restart.
- [ ] `Ctrl+T` opens the theme picker; choosing a theme updates the editor,
      menus, toolbar, panels, and terminal.
- [ ] `Ctrl+=` / `Ctrl+-` zoom the code and the settings list refreshes.
- [ ] Toggling the minimap, glow, VHS/CRT, sunlight, music, and completion
      settings takes effect immediately.
- [ ] The cursor trail cycles through its modes and follows the caret.
- [ ] Resizing the window keeps the top bar, tabs, docks, and terminal aligned.
- [ ] On a 1080p Windows desktop the terminal's last row is fully visible.

---

## 13. Comments, About, and miscellaneous

- [ ] `Ctrl+L` opens the comments panel; comments render with usernames and
      dates; `Esc` closes it.
- [ ] `Ctrl+I` opens About; the version and shortcut list are readable.
- [ ] Discord Rich Presence updates the activity when Discord is running and
      fails gracefully when it is not.
- [ ] No unexpected `WARNING`/`ERROR` lines appear during normal use.

---

## 14. Source Control (Git)

### 14.1 Setup

Use a disposable repository so nothing here touches a real project:

```powershell
$repo = "$env:TEMP\griddy_git_manual"
if (Test-Path $repo) { Remove-Item -Recurse -Force $repo }
New-Item -ItemType Directory -Path $repo | Out-Null
git -C $repo init
git -C $repo config user.name "Qorix Test"
git -C $repo config user.email "test@example.invalid"
Set-Content "$repo\first.txt" "line one`nline two`nline three" -NoNewline
git -C $repo add -A
git -C $repo commit -m "First commit"
```

Open `$repo` with `Ctrl+Shift+O`.

- [ ] `Ctrl+Shift+G` opens Source Control in the left slot; the file tree and
      search dock close.
- [ ] The branch picker shows the current branch, and History shows
      `First commit`.
- [ ] Closing the dock restores the editor width.

### 14.2 Gutter and diffs

- [ ] Add a line to `first.txt` **without saving**: the gutter shows `+` on the
      new line immediately (after a short debounce).
- [ ] Change an existing line: its marker becomes `▎`.
- [ ] Delete a line: a `−` marker appears on the next surviving line.
- [ ] Click a marker: the diff dialog opens in side by side mode, with the old
      text on the left and the unsaved buffer on the right.
- [ ] **Unified** switches layouts and the line tints remain readable.
- [ ] Closing and reopening the diff keeps the file's unsaved edits.
- [ ] Save the file: the gutter still shows the same marks (HEAD did not move).
- [ ] A file that is not open in a tab opens its diff from a change row; the
      dialog shows the parsed unified diff.
- [ ] An untracked file shows “new and not tracked yet” instead of an empty
      “No changes” message.

### 14.3 Stage, commit, history

- [ ] Stage the modified file with `+`: it moves under **Staged Changes** and
      shows `M`.
- [ ] Unstage it with `−`: it returns under **Changes**.
- [ ] Stage all, enter a message, press `Enter`: the commit succeeds and the
      changes list becomes empty.
- [ ] History shows the new commit at the top with the correct subject.
- [ ] The Sent/Failed message is readable and disappears on the next action.
- [ ] Committing with an empty message focuses the box and does not run Git.
- [ ] With nothing staged, Commit reports “Nothing staged to commit.”

### 14.4 Discard

- [ ] Edit a tracked file, click `⟲`, cancel: the file is unchanged.
- [ ] Repeat and confirm: the file returns to its committed content.
- [ ] Create a new untracked file, discard it, confirm: the file is deleted from
      disk and the row disappears.
- [ ] Discarding the last change leaves a clean tree.

### 14.5 Save point

- [ ] Edit two open files but leave one unsaved. Press the **Save Point**
      toolbar button.
- [ ] Both files are written to disk and committed.
- [ ] The newest history subject starts with `Save point: ` followed by a date
      and time.
- [ ] The working tree is clean and the gutter clears.
- [ ] Press Save Point again with no changes: a “Nothing to save” notice appears
      and no empty commit is created.
- [ ] Add an untitled modified tab and press Save Point: it refuses and tells you
      to save that tab first; no commit is created.

### 14.6 Branches

- [ ] Create a branch in a terminal (`git -C $repo branch feature`), then press
      Refresh: the picker lists `feature`.
- [ ] Choose `feature`: the branch switches without leaving the editor.
- [ ] Make and commit a change on `feature`; History updates.
- [ ] Switch back to the original branch: the change disappears from the working
      tree and the picker follows.
- [ ] Detaching HEAD in a terminal (`git -C $repo switch --detach`) makes the
      picker read `(detached)` and disables switching.
- [ ] Auto-refresh does not close the picker while it is open.

### 14.7 Remote controls (optional)

Set up a local bare remote, then check the disabled and enabled states:

```powershell
$remote = "$env:TEMP\griddy_git_remote.git"
git init --bare $remote
git -C $repo remote add origin $remote
```

- [ ] With no remote, Pull and Push are disabled and their tooltips explain why.
- [ ] After adding `origin`, Push is enabled and sets the upstream on first use.
- [ ] Push succeeds; a second Push reports “Everything up-to-date”.
- [ ] Make a commit in a second clone, push it, then Pull here: the commit
      arrives without a merge commit.
- [ ] Create a divergent local commit and Pull: Git refuses the non-fast-forward
      pull and the panel shows the error.
- [ ] Remove the remote and Refresh: the buttons disable again.

### 14.8 Repository states and settings

- [ ] Open a folder with no repository: the dock offers **Initialize
      Repository**; using it makes the first Save point possible.
- [ ] Open a folder with an empty `.git` directory: it is treated as *not* a
      repository (Git itself rejects it), and Initialize repairs it.
- [ ] Turning off **Changed-line markers** hides the gutter immediately; turning
      it on repaints existing marks without reopening tabs.
- [ ] Turning off **Refresh Source Control automatically** stops the 5-second
      poll; the Refresh button still works.
- [ ] Reopening Qorix restores the dock and its selected tab.
- [ ] In a repository with thousands of changed files, typing stays responsive
      while a status refresh runs, and the dock reports that not every row is
      shown.

---

## 15. Debugger (DAP)

The debugger needs Python with the `debugpy` package. Install it into the same
interpreter Qorix will use (the one on `PATH`, or the absolute path in the
debug config):

```bash
python -m pip install debugpy
python -c "import debugpy; print(debugpy.__version__)"
```

Create this file in a disposable workspace and open it:

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

The UI line numbers below refer to the lines shown in the editor: line 2 is
`total = a + b`, line 9 is `value = add(...)`, line 10 is `print(...)`, line 11
is the `for`, and line 12 is `value += index`. The automated suite uses
`tests/fixtures/dap_target.py`, whose line map is documented in
[Debugger §9.2](../user/debugger.md#92-end-to-end-run-with-real-debugpy).

### 15.1 Breakpoints

- [ ] The debug gutter is the narrow strip left of the Git/LSP strips. Clicking
      line 9 paints `●` and adds no tab or notice.
- [ ] Clicking the dot removes it.
- [ ] `F9` on line 9 adds it back; `F9` on line 12 adds a second dot. Both
      survive saving and reopening the file.
- [ ] `F9` on line 12 removes only that dot.
- [ ] **Debug → Remove All Breakpoints** clears every dot, including a file
      that is not open.
- [ ] `F9` in an untitled buffer warns that the buffer must be saved first.

### 15.2 Start, pause, stop

- [ ] With a breakpoint on line 9, `Ctrl+F5` opens the Debugger dock, then
      shows `Paused (breakpoint) at <file>:9`.
- [ ] The paused line shows `▶`, the caret is on it, and the tab is active.
- [ ] Variables lists `base = 2` and `step = 3`; nested values expand.
- [ ] The Call Stack shows `main — <file>:9`.
- [ ] `Ctrl+F5` runs to the end; the console reports `Debug session ended.`,
      the `▶` disappears, the `●` returns, and no `python` adapter process is
      left behind.
- [ ] `Ctrl+F5` again pauses on line 9; `Ctrl+Shift+F5` stops the session and
      the dock returns to Ready.
- [ ] Starting with an untitled buffer is refused with a warning.
- [ ] Modify a saved file without saving, then start: the file is written first
      and the breakpoint uses the new text.

### 15.3 Watch and Debug Console

- [ ] While paused, add the watch `base + step`: it shows `5` with its type.
- [ ] Add `base + step + 100`: it shows `105`. Adding either expression again
      is refused; no duplicate row appears.
- [ ] Select a watch and press **Remove**; press **Refresh** to re-evaluate the
      rest.
- [ ] **Debug → Evaluate in Debug Console** focuses the prompt. Submit
      `base * step`: the console echoes `> base * step` and prints `6`.
- [ ] Up/Down walk the last expressions; sending clears the prompt.
- [ ] Submitting `nope` shows the adapter error in red and keeps the session
      paused.
- [ ] While running, the prompt is disabled and explains that a pause is
      required.
- [ ] **Clear Console** empties the output but keeps breakpoints and watches.
- [ ] Enable **Verbose debug adapter log** in Settings → Debugger, start again,
      and confirm the requests/responses/events appear. Turn it back off.

### 15.4 Stepping and call stack

- [ ] Pause on line 9, `F11`: execution enters `add()` on line 2. The marker,
      caret and status follow.
- [ ] `Shift+F11`: execution returns to the caller and pauses on line 9
      (debugpy reports the call line; this is expected).
- [ ] `F10`: execution pauses on line 10; another `F10` reaches the loop on
      line 11.
- [ ] Inside `add()`, the stack lists `add` then `main`. Click `main`:
      the editor switches to line 9 and Variables switches to `main`'s locals.
      Click `add`: the file and variables switch back.
- [ ] Step buttons are disabled while the program is running and after the
      session ends.

### 15.5 Cross-file navigation

Add `dap_helper.py` and call it from the demo:

```python
# dap_helper.py
def shout(text):
    return text.upper() + "!"
```

```python
# near the top of the demo
from dap_helper import shout
...
shout("hello")
```

- [ ] Put a breakpoint inside `shout` and one before the call. Start debugging:
      the helper file opens as a new tab, the caret lands on the stopped line,
      and the `▶` is there.
- [ ] The Call Stack lists `shout` and `main`; clicking `main` switches back.
- [ ] Turn off **Open the file when a breakpoint is hit**, close the helper tab,
      and start again. Execution pauses in the helper and the status names the
      file, but no tab opens. Turn the setting back on.

### 15.6 Dock, settings, session restore

- [ ] `Ctrl+Shift+D` toggles the dock. Closing it while paused keeps the
      session alive; reopening shows the same state.
- [ ] Opening the terminal, Run output or Language panel hides the debugger;
      opening the debugger hides them. They never overlap.
- [ ] Resizing the window keeps the dock at the bottom; the editor shrinks.
- [ ] Leave a breakpoint and a watch, then restart Qorix: both return and
      the dock reopens if it was open. Starting a new session hits the restored
      breakpoint.
- [ ] Rebind **Start / Continue Debugging** in Settings → Keybindings; the new
      key works and the old one does not.

### 15.7 Failure paths and planned adapters

- [ ] Point `debug.python.command` at an interpreter without `debugpy`, or
      uninstall the package. Starting shows the debugpy install card with a
      copyable command; no session is left running. Reinstall afterwards.
- [ ] Point the command at `definitely-not-installed`: the card names the
      command and the copy button puts it on the clipboard.
- [ ] Open a `.js` file and start debugging: the planned Node notice appears;
      nothing is started.
- [ ] Kill the adapter in Task Manager while paused: the console reports the
      lost connection, the session returns to idle, and the editor stays
      responsive.
- [ ] Open a project with malformed JSON in `.griddycode.json`: the console
      reports the parse error; the built-in Python profile still starts.

### 15.8 Python-specific checks

- [ ] Expand a paused list/dict: children show values and types.
- [ ] Evaluate `len(items)`, a slice and a method call: results match Python.
- [ ] Step Into a standard-library call with `justMyCode` on: execution does
      not descend into site-packages.
- [ ] A program that calls `input()` cannot read stdin from the debug console;
      run it with `F6` instead.

Full details, configuration and troubleshooting are in
[Debugger (DAP)](../user/debugger.md).

---

## Running the Git UI runner

The Git UI runner boots the real editor scene and drives Source Control, the
gutter, the diff dialog, staging, commits, History, discard, Save point and the
branch picker against a temporary repository it creates itself. Use a throwaway
`APPDATA`, because the editor writes session and settings files under `user://`.

PowerShell (Windows):

```powershell
$appdata = "$env:TEMP\qorix_git_ui_appdata"
if (Test-Path $appdata) { Remove-Item -Recurse -Force $appdata }
$env:APPDATA = $appdata
godot --headless --path . --script res://tests/integration/git_ui_runner.gd
```

The run ends with `Git UI: 110 checks, 0 failure(s).` and `GIT UI PASSED`, then
shuts the editor down through its normal quit path. Add
`-- --shots="C:/path/to/shots"` with a real window to save PNGs of the dock and
diff viewer.

---

## Running the acceptance suite

The acceptance driver boots the real editor scene, drives real key events, and
mutates a disposable workspace. Always start from a fresh fixture and a
throwaway `APPDATA`.

PowerShell (Windows):

```powershell
$ws = "$env:TEMP\griddy_accept_ws"
if (Test-Path $ws) { Remove-Item -Recurse -Force $ws }
New-Item -ItemType Directory -Path $ws,"$ws\sub","$ws\.git","$ws\node_modules","$ws\build" | Out-Null
Set-Content "$ws\alpha.txt" "needle one`nneedle two`nplain line" -NoNewline
Set-Content "$ws\beta.gd" "func beta():`n`t# needle three`n`t# needle four`n`tpass" -NoNewline
Set-Content "$ws\readme.md" "# readme`nno matches here" -NoNewline
Set-Content "$ws\sub\gamma.md" "gamma needle five" -NoNewline
Set-Content "$ws\sub\delta.txt" "delta needle six" -NoNewline
Set-Content "$ws\.git\ignored.txt" "needle git" -NoNewline
Set-Content "$ws\node_modules\ignored.js" "needle node" -NoNewline
Set-Content "$ws\build\ignored.txt" "needle build" -NoNewline

$env:APPDATA = "$env:TEMP\griddy_appdata"
if (Test-Path $env:APPDATA) { Remove-Item -Recurse -Force $env:APPDATA }
New-Item -ItemType Directory -Path $env:APPDATA | Out-Null

godot --headless --path . --script res://tests/integration/acceptance_runner.gd -- `
  --workspace="$($ws -replace '\\','/')"
```

Expected last line: `Acceptance: 108 checks, 0 failure(s).`

### Language server end-to-end

This run uses the deterministic fake server in
`tests/fixtures/fake_lsp_server.py`, not a real language server, so it needs
only Python on `PATH` (or `--python=<absolute path>`). It boots the real editor
scene and drives diagnostics, completion, hover, navigation, formatting,
signature help, rename preview/apply, code actions, crash restart, install
cards, session capture, and shutdown.

```powershell
$env:APPDATA = "$env:TEMP\griddy_lsp_appdata"
godot --headless --path . --script res://tests/integration/lsp_e2e_runner.gd -- `
  --python="C:/path/to/python.exe"
```

The runner creates a temporary workspace when `--workspace` is omitted; add
`--workspace=<path> --keep` to inspect the fixture and `lsp-transcript.jsonl`.
Do not redirect `LOCALAPPDATA` on Windows: the Python install manager needs it.
A passing run ends with
`All LSP end-to-end checks passed: 59 checks.` See
[Language servers §10](../user/language-servers.md#10-tests) for details and failure output.

### Debugger end-to-end

This run uses the real `debugpy` adapter, not a fake. It boots the real editor
scene, copies `tests/fixtures/dap_target.py` and `dap_helper.py` into a
temporary workspace, and drives breakpoints, start/stop, variables, watches,
console evaluation, stepping, cross-file navigation and session state. Python
must be available and must have `debugpy` installed; the run is skipped (exit 0)
when it is not.

```powershell
$env:APPDATA = "$env:TEMP\qorix_dap_appdata"
godot --headless --path . --script res://tests/integration/dap_e2e_runner.gd -- `
  --python="C:/path/to/python.exe"
```

The runner creates and removes its own workspace. Add
`--workspace="C:/temp/qorix-dap-e2e" --keep` to inspect the fixtures.
A passing run ends with:

```text
All DAP end-to-end checks passed: 73 checks.
```

See [Debugger §9](../user/debugger.md#9-tests) for the pinned fixture lines and
what each check covers.

---

## Reporting an error

A useful report lets someone reproduce the problem without guessing. Include
all of the following that apply.

### 1. Reproduce it first

- [ ] Try the same steps a second time.
- [ ] Try once with a **fresh profile** (§1.2). Note whether the bug still
      happens.
- [ ] Note whether it happens with a **fresh workspace** (§1.3) or only with
      your project.
- [ ] If it is visual, capture a screenshot or a short screen recording.
- [ ] If it is a crash or freeze, note what you were doing in the last few
      seconds.

### 2. Collect the facts

| Item | What to include |
| --- | --- |
| Qorix version | Settings → Info, or the About panel (`Ctrl+I`) |
| Commit / branch | `git rev-parse --short HEAD` if running from source |
| OS and version | For example `Windows 11 23H2`, `Linux Mint 22` |
| Godot version | `4.7.2` (or the version in `project.godot`) |
| Display / scaling | Resolution, window mode, DPI scaling |
| Steps | Numbered, starting from launch |
| Expected | What should have happened |
| Actual | What happened instead, including exact text |
| Frequency | Always / sometimes / once |
| Severity | Crash, data loss, blocked workflow, cosmetic |

### 3. Attach logs and state

Run from a terminal so the console output is captured:

```bash
godot --path . 2>&1 | tee qorix.log
```

On Windows use the **console** executable:

```powershell
& 'C:\path\to\Godot_v4.7.2-stable_win64_console.exe' --path . 2>&1 | Tee-Object qorix.log
```

Attach or paste:

- [ ] The full console log, especially the first `SCRIPT ERROR`, `ERROR`, or
      `WARNING` and its stack trace.
- [ ] `user://keybindings.json` for shortcut/rebinding bugs.
- [ ] `user://session.json` and any session backup files for restore bugs.
- [ ] `user://settings.json` (or the settings file in use) for settings bugs.
- [ ] The workspace path shape and file count for indexing/search bugs.

User data locations:

| OS | Folder |
| --- | --- |
| Windows | `%APPDATA%\Godot\app_userdata\Qorix` |
| Linux | `~/.local/share/godot/app_userdata/Qorix` |

**Redact secrets and private paths** before posting logs or config files.
Replace project names, usernames, tokens, and customer paths with placeholders.

### 4. File the report

Open an issue using the repository's **Bug report** template and include the
facts and attachments above. A strong title names the surface and the symptom,
for example:

- `Keybindings: Ctrl+F still opens editor find while the terminal is focused`
- `Session restore: unsaved buffer is lost after a forced shutdown`
- `File tree: renaming a file leaves the old path in quick open`

If the problem is a regression, add the last version or commit where it worked.
If it only happens with a particular file, attach a **minimal** copy that
reproduces it.

---

## Quick regression pass (10 minutes)

When there is no time for the full list, do these in order:

1. Launch, open the test workspace, open `alpha.txt`.
2. `Ctrl+F`, find `needle`, `Esc`.
3. `Ctrl+P`, open `beta.gd`, edit it, `Ctrl+Z` (only beta changes).
4. `Ctrl+Shift+F`, search `needle`, open a result.
5. `Ctrl+Shift+P` → Open Settings → close with `Esc`.
6. `Ctrl+Alt+K`, rebind Save, check the palette and toolbar, reset it.
7. Focus the terminal, press `Ctrl+F` (find must not open), press `Ctrl+S`
   (save must run).
8. `F5` run in the panel, open a `file:line` diagnosis link, `Shift+F5`
   stop. `F6` on a program that reads input must use the terminal.
9. With Pyright installed, open a Python file: wait for a gutter mark,
   `Ctrl+Shift+M`, `F12` on a symbol, `F2` to preview a rename, then cancel.
   Open a `.rs` file and confirm the install card names `rust-analyzer`.
10. With `debugpy` installed, put a breakpoint on an executable Python line
    with `F9`, press `Ctrl+F5`, confirm the `▶`, Variables and `Paused
    (breakpoint)` status, press `F10`, then `Ctrl+Shift+F5`.
11. Close and relaunch; confirm tabs, dirty buffer, docks, and terminal return.
12. Check the console for new errors.
