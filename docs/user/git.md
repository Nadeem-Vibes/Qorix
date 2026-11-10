# Git and save points

Source control in Qorix starts with one button:
**Save Point** saves your work, stages everything and records a timestamped
commit. The full **Source Control** dock exposes the usual Git flow — changes,
stage/unstage, discard, commit, branches, pull and push — without leaving the
editor.

Everything runs through the system Git installation. Qorix does not bundle
a Git implementation, does not read credential files and never stores passwords:
authentication is delegated to Git's own credential helper, exactly as it is in
a terminal.

---

## 1. What works

| Feature | Where |
| --- | --- |
| File status (staged / unstaged / untracked) | Source Control dock, Changes tab |
| Stage, unstage, discard one file or all files | Change rows and section headers |
| Commit with a message | Commit box, `git.commit` command |
| One-click timestamped commit | **Save point** button/toolbar, `git.save_point` |
| Commit history (last 50) | Source Control dock, History tab |
| Branch list and branch switch | Branch picker |
| Pull (fast-forward only) | `↓` button, `git.pull` command |
| Push (upstream, or set upstream to the first remote) | `↑` button, `git.push` command |
| Initialize a repository | No-repository page, `Initialize Repository` |
| Added/modified/deleted line markers | Editor gutter |
| Side-by-side and unified diffs | Diff dialog, opened from a gutter mark or a change row |
| Automatic refresh while the dock is open | Every 5 seconds (`git_auto_refresh`) |

Git must be on `PATH` (or otherwise resolvable by the runtime catalog). If it is
missing, the dock explains how to install it instead of failing silently.

---

## 2. The beginner path: Save point

**Save point** is a normal commit with a generated message:

```text
Save point: 2026-10-27 18:53:01
```

Pressing it:

1. Saves every open document that has unsaved edits. If a modified tab is
   untitled (or has no path), the save point stops and asks you to save that tab
   first, because there is no file for Git to commit.
2. Runs `git add -A`, so new, modified and deleted files are included.
3. Runs `git commit -m "Save point: <date and time>"`.
4. Refreshes status and history, and reports the result in the notice area.
5. If the working tree is already clean, reports “Nothing to save” instead of
   creating an empty commit.

This is intentionally the whole beginner workflow. There are no questions about
staging areas, branches or remote configuration. Advanced users can open the
full dock with **Source Control** in the command palette (or `Ctrl+Shift+G`).

---

## 3. The Source Control dock

Open it with `Ctrl+Shift+G`, the toolbar, or **Source Control → Toggle Source
Control**. It shares the left slot with the file tree and search dock. The dock
remembers whether it was open, and which tab was selected, across sessions.

### 3.1 Changes tab

Changes are split into **Staged Changes** and **Changes**, with true totals even
when the list is shortened for performance. Each row shows:

- a status code (`M` modified, `A` added, `D` deleted, `R` renamed, `?`
  untracked, `U` conflicted),
- the repository-relative path,
- a stage (`+`) or unstage (`−`) button,
- a discard (`⟲`) button for unstaged rows,
- clicking the code or the path opens the diff.

**Stage all** and **Unstage all** live in the section headers. Discard asks for
confirmation first. The discard command matches the file's state:

| File state | Git command used |
| --- | --- |
| Untracked | `git clean -f -- <path>` (the file is deleted) |
| Staged as new | `git rm -f -- <path>` |
| Tracked | `git restore --staged --worktree -- <path>` |
| No commits yet, tracked | `git rm -f -- <path>` |

Discarding cannot be undone from Qorix.

### 3.2 Commit box

Write a message and press `Enter` or **Commit**. The box uses the ordinary
`git commit -m` command and reports Git's own message (including “nothing staged
to commit” and hook failures). **Save point** is available on this tab too.

### 3.3 Branch picker and sync

The picker lists local branches, marks the current one, and switches with
`git switch <branch>` when another branch is chosen. Detached HEAD and a
repository with no commits yet are shown as non-switchable states. The
`↑n`/`↓n` indicator comes from the branch's upstream (`# branch.ab` in Git's
porcelain status).

- **Pull** runs `git pull --ff-only`; it refuses to create merge commits.
- **Push** runs `git push` when an upstream exists. Otherwise it runs
  `git push --set-upstream <remote> <branch>`, preferring `origin` and falling
  back to the first configured remote.
- Buttons are disabled when there is no remote, no branch, or a command is
  already running.

### 3.4 History tab

The History tab shows the last 50 commits: subject, short hash, author, relative
time, and any branch/tag decorations. It is a read-only overview; per-file
history and blame are future work.

### 3.5 Repositories and initialization

Qorix walks up from the workspace (or the open file's folder) looking for a
`.git` directory with a `HEAD`, or a `.git` file whose `gitdir:` target has a
`HEAD`. This accepts linked worktrees and submodules while rejecting an empty or
half-deleted `.git` folder.

If no repository is found, the dock offers:

- **Initialize Repository** when a folder is open and Git is available,
- **Open Folder…** when no workspace is open.

`git init` is run in the workspace folder. Initialization does not add files or
create a commit; the first Save point does that.

---

## 4. Editor integration: changed-line gutter

A dedicated 10 px gutter shows the working tree relative to `HEAD`:

| Glyph | Meaning |
| --- | --- |
| `+` | Added line |
| `▎` | Modified line |
| `−` | Deleted line, attached to the next surviving line |

The comparison uses the **in-memory buffer**, not the file on disk, so unsaved
edits show their markers immediately. Clicking a marker opens the diff dialog
for that file.

The gutter is deliberately bounded:

- recomputation is debounced by 0.25 seconds while typing;
- buffers larger than 2 MB are skipped (the diff dialog still works on demand);
- tracked baselines larger than 4 MB, or containing NUL bytes, are treated as
  unavailable instead of being loaded into the editor;
- turning off **Changed-line markers** in Settings hides the gutter without
  discarding the cached HEAD text.

The HEAD copy is cached per file. The cache is invalidated when `HEAD` moves
(commit, pull, branch switch), when the repository changes, or when a file is
renamed or saved as a new path.

---

## 5. Diff dialog

There are two sources for a diff:

- **Open document:** compares the cached `HEAD` text with the live buffer, so
  unsaved edits are included. This view defaults to **side by side** and can be
  switched to **unified** with the header button.
- **File not open:** runs `git diff HEAD -- <path>` (or `--cached` plus the
  working-tree diff before the first commit) and shows the parsed unified diff.
  Untracked files show a short “not tracked yet” explanation because `git diff`
  has no HEAD copy to compare.

The viewer reports additions, deletions and modified lines. Rows are tinted
instead of creating a widget per line, and missing lines are padded, which keeps
multi-thousand-line diffs responsive. The diff is against `HEAD`, not against
the index: staged and unstaged edits for an open file appear together.

---

## 6. Architecture

```text
FileManager (main thread, composition root)
  ├── GitService (Node)
  │     ├── worker Thread  ── OS.execute("git", ["-C", repo, …])
  │     ├── GitStatusParser  (status, branches, log, remotes)
  │     └── GitDiff          (unified parse, bounded in-memory line diff)
  ├── SourceControlPanel (HUD left dock)
  └── GitDiffDialog (AcceptDialog)
```

### 6.1 GitService

`src/features/git/git_service.gd` is an async facade. The UI thread never runs a Git
process:

1. A request is appended to a mutex-protected queue and the worker semaphore is
   posted.
2. The worker runs the process set in order. `OS.execute` has no working-directory
   argument, so every command is wrapped with `git -C <repo_root>`.
3. Results are delivered back to the main thread with `call_deferred`.
4. Requests carry a repository **generation**; responses from a previous
   repository are dropped. Baseline requests also carry an **epoch**, so a commit
   that lands mid-request cannot paint stale marks.

Signals consumed by the editor:

| Signal | Meaning |
| --- | --- |
| `repo_changed(root)` | The workspace now points at a different repository (or none) |
| `snapshot_changed(snapshot)` | Fresh status, branches, log and remotes |
| `head_changed` | `HEAD` moved; cached baselines must be dropped |
| `operation_started(action)` / `operation_finished(action, result)` | Busy state and user feedback |
| `baseline_ready(path, result)` | HEAD text and tracked/untracked state for one file |
| `diff_ready(path, parsed)` | Parsed unified diff for a file that is not open |

Commands used by the service:

```text
git -C <repo> -c core.quotepath=false status --porcelain=v2 --branch
git -C <repo> branch --format=%(refname:short)%1f%(HEAD)%1f%(upstream:short)%1f%(committerdate:unix)
git -C <repo> log -n 50 --pretty=format:%H%x1f%h%x1f%an%x1f%ae%x1f%at%x1f%ar%x1f%D%x1f%s%x1e
git -C <repo> remote
git -C <repo> show HEAD:<path>
git -C <repo> ls-files --cached --error-unmatch -- <path>
git -C <repo> ls-files --others --exclude-standard --error-unmatch -- <path>
git -C <repo> diff --no-color --no-ext-diff --unified=3 HEAD -- <path>
git -C <repo> add -A [-- <paths>]
git -C <repo> restore --staged [--worktree] -- <paths>
git -C <repo> rm -f -- <paths>
git -C <repo> clean -f -- <paths>
git -C <repo> commit -m <message>
git -C <repo> switch <branch>
git -C <repo> pull --ff-only
git -C <repo> push [--set-upstream <remote> <branch>]
git -C <repo> init
```

`%1f` is the ref-filter escape used by `git branch --format`; `%x1f`/`%x1e` are
the pretty-format escapes used by `git log`. Using the wrong family makes Git
emit a literal `%x1f` instead of a separator, so they are intentionally
different.

### 6.2 Parsers

`src/features/git/git_status_parser.gd` parses porcelain v2 headers and entries,
branches, the log format and remotes. It also decodes Git's C-style quoted paths,
including octal UTF-8 sequences. The lists stop at 3,000 entries while the
counts keep counting; the dock draws at most 400 rows and adds a “N more” note.
This is what keeps a repository with tens of thousands of untracked files from
freezing the UI.

`src/features/git/git_diff.gd` parses unified diff output and implements the
in-memory line diff used by the gutter and the side-by-side view. The line diff
trims the common prefix and suffix, caps the LCS table at 250,000 cells, and
falls back to a bounded row-by-row comparison for a large rewrite.

### 6.3 Refresh policy

- The dock polls every 5 seconds **only while it is visible** and while Git is
  not busy. A forced refresh that arrives during a poll is queued once, not
  dropped.
- Typing schedules a gutter repaint on a 0.25-second one-shot timer.
- The panel rebuilds a list only when its data signature changes, so a periodic
  snapshot does not reset scroll position or close the branch dropdown.
- The branch picker is rebuilt only when the branch set or current branch
  changes.

---

## 7. Commands and settings

### 7.1 Commands

| Command | Default binding | Action |
| --- | --- | --- |
| `git.source_control` | `Ctrl+Shift+G` | Toggle the Source Control dock |
| `git.save_point` | — | Save open edits, stage all, commit with a timestamp |
| `git.refresh` | — | Force a status refresh |
| `git.commit` | — | Focus the commit box (or commit a supplied message) |
| `git.pull` | — | Fast-forward pull |
| `git.push` | — | Push, setting an upstream when needed |
| `git.history` | — | Open the dock on the History tab |

The toolbar also exposes **Save Point** next to Save. All Git commands are
disabled when the workspace is not inside a repository; Save Point is also
available from the palette when a repository exists.

### 7.2 Settings

| Key | Default | Effect |
| --- | --- | --- |
| `git_gutter` | `true` | Show changed-line markers in the editor gutter |
| `git_auto_refresh` | `true` | Poll status every 5 seconds while the dock is open |

Both live under **Settings → Source Control** and take effect immediately.

---

## 8. Safety and credentials

- No credential is read, written, logged or cached by Qorix. Git's own
  credential helper (Credential Manager, `osxkeychain`, `libsecret`, …) handles
  authentication.
- Commands are executed directly, without a shell, so paths and commit messages
  are passed as individual arguments and are not re-parsed by `cmd.exe` or
  `/bin/sh`.
- Discard is the only destructive action and always asks for confirmation first.
  Untracked files are deleted from disk.
- Pull is `--ff-only`; Qorix will not silently create a merge commit.
- A Save point refuses to proceed when a modified tab is untitled, so unsaved
  work cannot be left out of the commit.

---

## 9. Known limitations

- Diffs are against `HEAD`; there is no separate “staged vs unstaged” diff
  toggle.
- No per-hunk staging, conflict-resolution editor, rebase, cherry-pick, tag UI
  or remote management.
- Pull is fast-forward only. A diverged branch must be resolved in a terminal.
- History is a flat list of the last 50 commits; per-file history and blame are
  not implemented yet.
- Status lists are truncated at 3,000 entries (counts remain accurate) and the
  dock draws at most 400 rows.
- Files larger than 2 MB do not get gutter marks, and HEAD copies larger than
  4 MB are not loaded as baselines.
- Push/pull authentication is whatever the system Git credential helper
  provides. If Git needs interactive input, Qorix does not host a terminal
  prompt for it; use the terminal dock for that operation.
- Git must be installed separately.

---

## 10. Tests

### Unit suites

```bash
godot --headless --path . --script res://tests/test_runner.gd
```

`tests/unit/features/git/test_git_status.gd` covers status, branch, log and path parsing,
row caps, quoted UTF-8 paths, repository-root detection (including an empty
`.git`) and worktree `.git` files. `tests/unit/features/git/test_git_diff.gd` covers unified
diff parsing and the bounded line diff used by the gutter and side-by-side view.

### Git integration runner

```bash
godot --headless --path . --script res://tests/integration/git_integration_runner.gd
```

The runner creates a temporary repository, configures a local test identity, and
drives the real CLI through `GitService`: init, untracked status, baseline
request and cache, staging, the first commit, log, diff parsing, Save point,
unstage, discard of tracked and untracked files, branch creation and switching.
It removes the repository afterwards and ends with:

```text
GIT INTEGRATION PASSED: 53 checks.
```

No global Git configuration is modified; `user.name`, `user.email`,
`commit.gpgsign` and `core.autocrlf` are set inside the temporary repository.

### Git UI runner

```bash
godot --headless --path . --script res://tests/integration/git_ui_runner.gd
```

This end-to-end runner boots the real `src/main/editor.tscn` instead of calling
`GitService` directly. It creates a temporary repository and drives the visible
workflow: the empty-folder **Initialize Repository** page, the first commit
through the panel, opening a document and waiting for its baseline, typing to
produce modified/deleted/added gutter marks, a gutter click into the
side-by-side diff, the Unified toggle, stage/unstage/stage all, the commit box,
History, discard confirmation, the beginner Save point, and switching branches
through the picker. It removes the repository when it finishes and ends with:

```text
Git UI: 110 checks, 0 failure(s).
GIT UI PASSED
```

Run it with a throwaway `APPDATA`, because booting the editor writes session and
settings files under `user://`:

```powershell
$appdata = "$env:TEMP\qorix_git_ui_appdata"
if (Test-Path $appdata) { Remove-Item -Recurse -Force $appdata }
$env:APPDATA = $appdata
godot --headless --path . --script res://tests/integration/git_ui_runner.gd
```

Add `-- --shots="C:/path/to/shots"` when running with a real window to save PNGs
of the Source Control dock and the diff viewer.

### Manual pass

The Git section of
[docs/developer/manual-test-checklist.md](../developer/manual-test-checklist.md#14-source-control-git)
covers the visible workflow: gutter markers, diff layouts, staging, commit,
history, branch switching, Save point, pull/push controls and large-repository
responsiveness.

---

## 11. Troubleshooting

| Symptom | Likely cause / fix |
| --- | --- |
| “Git was not found on PATH” | Install Git and restart Qorix so it sees the updated `PATH`. |
| “This folder is not a Git repository yet” | Use **Initialize Repository**, or open the folder that contains `.git`. |
| Branch picker shows “(no commits yet)” | The repository is initialized but has no commits. Make a Save point first. |
| Push is disabled | No remote is configured. Add one in a terminal (`git remote add origin …`). |
| Push asks for credentials | The system Git credential helper has no credential for the remote. Configure it in a terminal; Qorix does not store passwords. |
| Pull reports “not possible to fast-forward” | The local and remote branches diverged. Resolve in the terminal (`git pull --rebase`, merge, or reset), then refresh. |
| Gutter has no marks | No repository, no HEAD baseline (new file, binary, >2 MB), or `git_gutter` is off. |
| Dock shows “N more changes are not shown” | The repository has more than 3,000 changed entries or 400 visible rows; use Git in the terminal for the full list. |
| Commit fails with a hook message | Git hooks run normally. Fix the hook output or commit from the terminal. |
