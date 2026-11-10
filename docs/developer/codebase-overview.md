# Qorix Codebase Overview

> Snapshot: commit `66808e4` plus the workspace-trust, dynamic-height and P2
> fixes, and the first-run Beginner Mode and error-card feedback additions.
> At the Mod Platform 1.0 gate, verified with **Godot 4.7.2** installed:
> the headless suite prints **7,376 checks across 84 suites** and exits 0.
> That printed count is the source of truth; update this document when the
> runner's total changes.
>
> The suite is the CI gate (`ci.yml` on push/PR, and the `test` job that
> `release.yml` requires before building an installer). The LSP e2e runner is
> separate and still needs Python and a real language server.

---

## 1. What Qorix is

Qorix ("Qorix") is a desktop code editor built with **Godot
4.7** and GDScript. It is not a conventional Control-only UI: the code area is
drawn in **2D world space**, and a `Camera2D` pans and zooms over it. Screen
HUD elements live on `CanvasLayer`s.

- Engine: Godot 4.7, Forward Plus, 1920×1080 design viewport, `canvas_items`
  stretch, `keep_height`.
- Main scene: `src/main/editor.tscn` (root `Editor`, script `file_manager.gd`).
- GDScript: ~25,400 lines across `src/` (20.5k non-empty).
- Lua content: 16 language plugins, 18 themes.
- Discord Rich Presence via `addons/discord-sdk-gd`.
- Fork maintained by Mohamed Nadeem (`README`, About panel); original project
  by Face. Version constant is `v1.4.0` in `src/main/autoloads/lua_singleton.gd`.

### Runtime autoloads

| Autoload | Script | Role |
|---|---|---|
| `Icons` | `src/main/autoloads/icons.gd` | Extension → Nerd Font glyph/color table |
| `LuaSingleton` | `src/main/autoloads/lua_singleton.gd` | Lua host, theme state, settings facade, fonts, shaders, Discord |
| `Fs` | `src/main/autoloads/fs.gd` | Thin wrapper over `src/base/file_store.gd` |
| `Music` | `src/main/autoloads/music.gd` | Background WAV playback and beat pulse |
| `CommentsData` | `src/main/autoloads/comments_data.gd` | Contributor names for the comments overlay |
| `DiscordSDKLoader` | `addons/discord-sdk-gd/...` | Discord SDK callbacks |

---

## 2. Runtime topology

```
Editor (Node2D, file_manager.gd)
├─ ExternalBackground / Background        world-space dimmers
├─ EditorHost (Control, height follows title)  one EditorView per document
│    └─ ViewN (src/editor/editor_view.tscn → CodeEdit subclass)
├─ CursorEffect (ColorRect + shader)      world-space caret trail
├─ FileDialog (custom RichTextLabel picker)
├─ Settings (video + SettingsList)
├─ ThemePicker (OptionButton)
├─ Info (About/help RichTextLabels)
├─ Comments (comments.tscn)
├─ Misc/Cam (Camera2D, camera.gd)
├─ ShaderLayer / BloomLayer               full-screen effects
├─ AudioStreamPlayer / AudioTimer
└─ CanvasLayer                            legacy notice layer
     ├─ HUD (created at runtime)
     │   ├─ TopBar, Minimap, Tabs, Find
     │   ├─ FileTree, SearchPanel, Palette, Keybindings
     │   ├─ Terminal, RunOutput, Language (LSP), LSP cards/picker
     └─ runtime Notice instances
```

World-space things (code, camera, cursor trail, world overlays) use world
pixels. HUD/panel things use CanvasLayer pixels. Mixing the two coordinate
systems is the most common source of positioning bugs.

---

## 3. Startup and shutdown

### Startup (`FileManager._ready`, `file_manager.gd:170`)

1. Disable automatic quit so the custom confirmation can run.
2. Fit the window to the usable desktop (Windows taskbar safety).
3. Create services: `DocumentManager`, `OverlayController`,
   `InputController`, `WorkspaceService`, `SearchService`, `SessionService`
   (`_setup_editor_services`, line 286). Start a session lock.
4. Build the command registry, register ~55 built-ins, create the
   `KeybindingService` and load overrides (`_setup_commands`, line 351).
5. Build the HUD (`_setup_hud`, line 1373): LSP manager first, then top bar,
   minimap, tabs, find, left docks, palette, keybindings, legacy `RunManager`,
   `RunService`, terminal, run output, LSP panel/cards.
6. Prepare overlays (`_setup_overlays`, line 1491) and native dialogs
   (`_setup_dialogs`, line 1505).
7. Detect CLI file argument (`_cli_file_from_args`, line 258); seed Lua
   plugins/themes into `user://`; load legacy `data.save`; list themes; apply
   the saved theme and settings.
8. Restore the session unless launched with a CLI file
   (`_restore_session`, line 1071).
9. Start the autosave and external-change timers.
10. If no document is open, show the welcome file picker.

### Shutdown (`_on_close_requested` → `_finish_quit`, lines 2044/2089)

- Save a crash-recovery snapshot before prompting.
- Save every modified file; untitled/failed saves produce a confirmation.
- Write the final session, legacy `data.save` (current file/dir/theme) and
  settings.
- Shut down terminal sessions, `RunService`, and all LSP clients.
- Quit.

`NOTIFICATION_APPLICATION_FOCUS_OUT` autosaves the active file unless an
external change is pending. `FOCUS_IN` checks external changes again.

---

## 4. Directory map

| Path | Contents |
|---|---|
| `src/main/` | Composition root, main scene and runtime autoloads (`icons`, `lua_singleton`, `fs`, `music`, `comments_data`). |
| `src/base/` | Pure helpers with no scene dependencies: path/version utilities, fuzzy matching and the atomic file store. |
| `src/platform/` | Editor-agnostic services: settings, workspace, session, commands, keybindings, languages, search, accessibility and trust. |
| `src/editor/` | Document model, view host, `CodeEdit` subclass, input routing, overlays, minimap, cursor trail, comments overlay, scroll/cursor math and editor scenes. |
| `src/workbench/` | Shell UI: tabs, file tree, dialogs, palette, search, find/replace, settings, theme chooser, terminal, notices and update. |
| `src/features/run/` | Run configuration, capture protocol, runtime catalog, GuessLang detector, error explainer, error-card feedback (`error_feedback.gd`), output links/panel. |
| `src/features/lsp/` | Full LSP client/manager/config/text/UI (11 scripts, ~6.3k lines). |
| `src/features/git/` | Git service, status/diff parsers, source-control panel and diff dialog. |
| `src/features/debug/` | DAP client/protocol/config/manager and the debugger dock. |
| `src/features/learning/` | Beginner mode (auto-enabled on a fresh install), welcome/onboarding, guide and exercise engines, built-in Python Journey (`courses/`). |
| `resources/courses/` | `python_journey.json` — the built-in five-lesson Python course catalog (data only). |
| `src/features/mods/` | Mod core, frozen API facade, event bus, Lua sandbox, shell and mod UI. |
| `resources/lua/plugins/` | 16 language modules (`py`, `js`, `c`, `cpp`, `cs`, `css`, `go`, `html`, `java`, `json`, `lua`, `txt`, `bf`, `bs`, `bsx`, `yap`). |
| `resources/lua/themes/` | 18 theme scripts (Catppuccin, Tokyo Night, Rose Pine, GitHub, Nord, Monokai, One Dark, Kanagawa, violet). |
| `resources/shaders/` | Bloom, sunlight, VHS/CRT, cursor trail, rounded corners, circle mask, greenscreen. |
| `tests/unit/` | Unit suites grouped by domain: `base`, `platform`, `editor`, `workbench` and `features/`. |
| `tests/integration/` | Acceptance, LSP, debugger, Git and Git UI end-to-end runners. |
| `tests/support/` | Shared test base class and fixtures. |
| `tools/` | `mod-package/` (package CLI), `probes/lua-runtime/` (feasibility probes) and `installer/`. |
| `docs/` | `user/`, `developer/`, `mods/` and archived gate records under `docs/archive/`. |
| `addons/discord-sdk-gd/` | GDExtension Discord SDK. |
| `resources/fonts/`, `resources/icons/`, `resources/music/`, `resources/videos/`, `resources/shaders/` | Bundled fonts, file-tree/comment icons, background music, videos and screen shaders. |
| `resources/lua/`, `resources/glossary/`, `resources/localization/`, `resources/templates/`, `resources/themes/` | Language/theme seeds, beginner glossary, translation CSV, starter templates and the shared `theme.tres`. |
| `resources/third_party/` | Cursor shaders and their attribution notices. |

---

## 5. Editor core

### 5.1 Document model

`src/editor/document.gd` (`EditorDocument`, `RefCounted`):

- Identity: `path`, `display_name`, `untitled`, `modified`, `encoding`,
  `line_endings`, `disk_mtime`, and optional language override
  (`language_override`, `language_highlight`, `language_source`).
- Text lives either in `_pending_text` (before a view exists) or in the
  `CodeEdit`. `text()` resolves both; `set_text()` updates metadata and the
  view.
- `capture_state()` / `restore_state()` persist caret, scroll, and one
  selection. Multi-caret state is not persisted.
- Line endings are detected (`CRLF` → `CR` → `LF`); encoding only distinguishes
  UTF-8 with/without BOM. Saves always go through `FileStore` as UTF-8.
- No stable ID: `DocumentManager` uses object identity; path lookups use
  `PathUtils.same_file()`.

`src/editor/document_manager.gd`:

- Owns `documents`, `active_index`, creates one `EditorView` per document.
- Opening an existing path returns the existing document; duplicate tabs are
  prevented by canonical path.
- Removing the active tab activates a neighbour; hidden views are kept alive
  for undo/fold/caret history and freed only on close.
- Signals: `documents_changed`, `active_document_changed`,
  `document_dirty_changed`.

### 5.2 Views and editor host

`src/editor/editor_host.gd`:

- Instantiates `src/editor/editor_view.tscn` per document, names them `ViewN`,
  anchors them full-rect, and fans settings/theme changes out to every view.
- `activate()` shows one view and hides the rest; `destroy_view()` frees on
  close. `grab_active_focus()` / `release_active_focus()` centralize focus.

`src/editor/editor_view.gd` (`extends CodeEdit`):

- Binds a document, applies language/settings/theme.
- Debounced completion (0.35 s) merges Lua plugin results with asynchronous
  LSP completion; dedup key is `label + "\n" + insert_text`.
- Owns a dedicated 14 px `"lsp"` gutter: severity glyph, 10% line tint, and a
  `✦` lightbulb when no diagnostic claims the line.
- Emits `content_changed`, `caret_moved`, `hover_requested`,
  `definition_requested`, gutter-click signals.
- `file_modified` duplicates `EditorDocument.modified`; keep them in sync.

### 5.3 Input, overlays, camera, minimap, cursor

- `InputController` (`src/editor/input_controller.gd`) routes
  `_input` for terminal-focused chords, then `_unhandled_input` through
  `KeybindingService.handle(event, scope)` and `CommandRegistry.execute()`.
  Scope priority: overlay → dialog; focused terminal → terminal; focused
  editor → editor; other text controls → dialog; fallback editor.
- `OverlayController` (`src/editor/overlay_controller.gd`) allows **one
  overlay at a time**, fades over 0.2 s, optionally dims the background, and
  moves the camera only for world-space panels. `open()` is a no-op while
  animating or occupied; callers must await close before opening another.
- `Camera` (`src/editor/camera.gd`) follows `get_caret_draw_pos()`, fits the
  longest line into the viewport, and glides using `ScrollMath`. It recreates
  its zoom tween each frame and uses a manual position glide.
- `Minimap` (`src/editor/minimap.gd`) is a screen-space strip; it tokenizes
  with the active highlighter, throttles rebuilds, and maps click positions to
  document lines.
- `CursorEffect` (`src/editor/cursor_effect.gd`) draws a world-space quad
  over the caret and drives `cursor_trail.gdshader` (warp/sweep/tail). It
  corrects the cell rectangle to the authoritative caret draw position.

### 5.4 The world grows with the document

The scene no longer caps the code area at 44,630 px. `EditorHost.refresh_height()`
computes `height_for_content(lines, line_height)` from the active view and
resizes `offset_bottom`, preserving any inset a bottom dock currently applies.
A 10,000-line file at a 22 px line height needs ~220,480 px, so the `CodeEdit`
never scrolls internally and `get_caret_draw_pos()` stays an unscrolled world
coordinate. Bottom docks read `EditorHost.base_bottom()` when they open or
close instead of caching the height from `_ready`. The world dimmer
(`ExternalBackground`) is grown with the host in the same pass.

The height policy is pure (`height_for_content`) so it can be checked without
a window; the runtime wiring is covered by the acceptance/LSP runners.

---

## 6. Feature subsystems

### 6.1 Files, tabs, saving, external changes, session

- `FileManager.open_file()` normalizes the path, reuses an existing tab,
  checks existence, loads through `Fs._load`, and notes new files in the
  workspace index.
- `save_current()` writes in place; untitled buffers go to the native Save As
  dialog. Save As refuses to target a path already open in another tab.
- Closing a modified untitled tab prompts Save / Don't save / Cancel. Modified
  saved files save on close (and stay open if the write fails). The last 20
  closed tabs are kept for `Ctrl+Shift+T`; the entry includes text, caret, and
  language override.
- External changes are detected via mtime polling every 1.5 s and on focus.
  The prompt offers Reload, Keep mine, or a read-only side-by-side Compare.
  Autosave never overwrites a file that changed on disk.
- `SessionService` (`src/platform/session_service.gd`) stores metadata in
  `user://session.json`, dirty/untitled text in `user://session_backups/`, and
  a pid/start lock in `user://session.lock`. A stale lock marks the previous
  run as a crash and triggers "Session recovered".
- The snapshot preserves the Problems dock (`lsp`) and Source Control dock
  (`git`) at both the top level and inside `panels`; the earlier sanitizer
  dropped both keys, so that state never restored.

### 6.2 Workspace, quick open, search

- `WorkspaceService` (`src/platform/workspace_service.gd`) opens one folder,
  rejects filesystem roots, and indexes it in 6 ms chunks (max 100k entries,
  depth 32). `src/platform/ignore_rules.gd` applies `.gitignore` files (comments,
  negation, directory-only rules, anchoring and `**`) from the root down
  through nested folders; the built-in skip list stays as a baseline for
  dependency/cache folders that are not always gitignored. The index feeds the
  tree, quick open, and search.
- `quick_open_items()` scores exact relative path/name first, then fuzzy name,
  then fuzzy relative path. Recents live in `user://workspaces.json` (max 12;
  8 exposed as commands).
- `SearchService` + `TextSearchBackend` scan the workspace in 6 ms slices,
  skip binary extensions, files > 2 MiB, and files whose first 4 KiB contain a
  NUL. Literal matching only (case-sensitive optional); max 1000 results, 200
  per file. Replace previews/apply are literal and refuse paths outside the
  workspace.
- `FindReplace` is an independent in-file scanner capped at 10,000 matches;
  it highlights through `CodeEdit.set_search_text` and replaces bottom-up.
- `FuzzyMatch` returns lower-is-better scores (`-1` no match, `-1000` exact).

### 6.3 Commands, keybindings, UI shell

- `CommandRegistry` stores label/category/shortcut/scope/handler/enabled/
  checked/icon/visibility flags. `execute()` deliberately ignores scope;
  keyboard routing filters by scope first. Batch registration coalesces the
  `changed` signal.
- `BuiltinCommands` registers ~55 fixed commands plus dynamic recent-workspace
  commands. Categories drive the menu order: File, Edit, View,
  Workspace, Terminal, Run, Preferences, Help, Other. Themes are switched only
  through the Ctrl+T picker (`ThemeChooser`), never through a menu.
- `KeybindingService` persists only overrides to `user://keybindings.json`
  (`{"version":1,"bindings":{id:"Ctrl+Shift+P"}}`); empty string unbinds.
  It builds `cmd_*` InputMap actions, matches exact modifiers, ignores key
  echo, and reports conflicts (global overlaps every scope). `KeyChord` is the
  pure parser/formatter/matcher.
- `TopBar` hosts generated menus and a 28 px toolbar. `MenuBuilder` groups by
  category and shows accelerators; `ToolbarBuilder` filters `show_in_toolbar`
  and sorts by `toolbar_order`.
- Tabs are a pure view over `DocumentManager`: `TabBar`, dirty `*` prefix,
  no drag reorder, no file icons. Tabs sync on document/dirty changes.
- The file tree is a 320 px left dock with lazy directory loading, 0.12 s
  polling for newly expanded folders, Nerd Font icons, and a context menu
  (new file/folder, rename, delete, reveal, copy path, open terminal).
- The palette has files and commands modes. With a workspace, files come from
  the index; without one, a bounded disk sweep (3000 files). Command execution
  is deferred 0.3 s to avoid re-entrant overlay changes.
- The custom world-space file dialog (`file_dialog.gd`) is keyboard-driven,
  has no bookmarks/filters, caps fuzzy search at 1000 entries, and only shows
  drive shortcuts at a drive root.

### 6.4 Settings, themes, effects, audio

- `SettingsService` (`src/platform/settings_service.gd`) is schema-driven:
  **80 settings in 15 categories**, persisted to `user://settings.json` as
  `{"settings_version":2,"values":{...}}`. Values are stored by stable key;
  `editor_font` stores the display name. Invalid values are coerced/clamped;
  saves are debounced 0.5 s. Legacy `data.save` settings are imported once.
- `LuaSingleton` keeps the historical `settings` / `get_setting()` /
  `change_setting()` facade used by the UI and themes.
- Themes are Lua files in `user://themes/`, seeded from `res://resources/lua/themes`
  only when missing. `setup_theme()` binds `base`, `table`, `string`, exposes
  `set_keywords`, `set_gui`, `disable_glow`, executes the file, then emits
  `on_theme_load`.
- Runtime colors live in `LuaSingleton.gui` and `.keywords`. Theme scripts
  only set the keys they name, so `setup_theme()` starts each load from the
  captured pristine palettes; keys omitted by a theme can no longer inherit
  the previous theme's colours.
- Glow is replaced by a custom bloom shader (`resources/shaders/bloom.gdshader`), with
  threshold based on background luminance. Full-screen Sunlight/VHS shaders
  suspend bloom. `tune_vhs_brightness()` scales brightness by background
  luminance to avoid whiteouts.
- Fonts: bundled Fira Code + system fonts; `SystemFont` is created lazily.
  Nerd Font/Noto Color Emoji fallbacks are attached to editor, tree, and
  button fonts.
- Music is a single WAV player with volume and a camera pulse driven by a
  spectrum analyzer. Disabled by default.
- The theme chooser previews on hover and commits on selection; the active
  theme is persisted in `user://data.save`, not `settings.json`.

### 6.5 Lua language plugins

- `LanguageService` maps extensions through aliases (`pyw/pyi→py`,
  `mjs/cjs/jsx/ts/tsx→js`, `h→c`, `cc/cxx→cpp`, `htm→html`, ...), prefers
  `user://langs/<key>.lua`, then `res://resources/lua/plugins/<key>.lua`, and falls back
  to `txt` with a warning.
- Plugin state is cached per extension; each view gets its own
  `CodeHighlighter` (sharing one would leak column widths). A plugin load
  error still yields a working `txt` highlighter plus `error=true`.
- API: `highlight(keyword, color)`, `highlight_region(start, end, color,
  line_only)`, `add_comment(text)`, `detect_functions(content, line, column)`,
  `detect_variables(...)`. `resources/lua/definitions.lua` has LuaLS annotations.
- Completion is debounced 0.35 s; the plugin's functions/variables are merged
  with LSP results.
- No hot reload: plugin edits require switching to a different extension or
  restarting. Built-ins are seeded only if missing, so upstream fixes do not
  overwrite user copies (one targeted `css.lua` repair exists).

### 6.6 Run and output

- `RunConfig` has 22 built-in profiles, layered config
  (`user://run.json` → `<workspace>/.griddycode.json` →
  `<workspace>/.griddycode/run.json`), shebang support, placeholders
  (`$file`, `$dir`, `$workspace`, ...), and shell quoting.
- `RunService` chooses capture vs terminal mode. Capture uses a private PTY
  wrapped by marker lines; `RunCapture` strips ANSI/OSC, handles CR/backspace,
  UTF-8 boundaries, and truncates at 1M chars. Terminal mode types the command
  into a terminal tab and does not observe its exit code.
- `RuntimeCatalog` resolves executables from PATH/PATHEXT, aliases runtime
  names, preflights profiles, and produces install cards.
- `GuessLangService` is an offline character-trigram TF-IDF detector with
  syntax markers and an extension hint; 35 profiles. Auto-apply needs
  confidence ≥ 0.45 and a margin ≥ 0.06 (docs say 62%; code wins).
- `ErrorExplainer` loads 40 rules from `src/features/run/error_rules/*.json`,
  prioritizes language → generic → other, resolves file/line/column, and
  renders title/explanation/fix cards. Fallbacks cover success, stopped,
  and unknown exit codes.
- `OutputLinks` recognizes `path:line[:column]` and Python traceback headers,
  resolves relative paths against cwd/workspace/source folder, and encodes
  click metadata as base64 JSON in BBCode links.
- **Known issues:** marker exit code wins over PTY exit code (docs claim the
  opposite); `RunService.run()` returns `{}` immediately on the capture path;
  terminal runs skip runtime preflight; Stop is unreachable in terminal mode;
  clearing the output panel suppresses subsequent live output; the generated
  default config template defines a `py` profile with `mode:"terminal"`,
  which shadows the built-in Python profile if saved unchanged; `$dirSlash` is
  documented but unsupported.

### 6.7 Terminal

- `TerminalPanel` is a 300 px bottom dock with tab bar, Clear/Kill/Close, and
  a shell/cwd label. Tabs are lazily started (`_ensure_started` waits for a
  stable grid, then forks). `TerminalSession` wraps a PTY, writes/resizes,
  forwards signals, and ignores stale exit events from replaced PTYs.
- Shell integration is absent: no OSC 133, no per-command exit codes, no live
  cwd. The label is startup metadata and becomes stale after `cd`.
- Session capture stores open state, active tab, titles, and start folders;
  scrollback is not persisted.
- The bottom strip is shared by terminal, Run output, and LSP panel; opening
  one hides the others. Closing the Run panel does not stop a captured run.
- `RunService` uses the active terminal tab for stop, so switching tabs before
  stopping can interrupt the wrong shell.

### 6.8 LSP

- 11 scripts under `src/features/lsp/`; `LspManager` is the orchestrator.
- Built-in profiles: Python (`pyright-langserver --stdio`), TypeScript/JS
  (`typescript-language-server --stdio`), Rust (`rust-analyzer`), C/C++
  (`clangd`), Go (`gopls`). Config layers: built-ins → `user://lsp.json` →
  `<workspace>/.griddycode.json` → `<workspace>/.griddycode/lsp.json`.
- One client per `profile|root`; documents are keyed by profile/root and
  synchronized with full-text `didChange` (120 ms debounce). Saving sends
  `didSave`; close/language/root changes send `didClose`.
- Transport: `OS.execute_with_pipe`, `Content-Length` framing, 12 s request
  timeout (25 s initialize), 8 MiB write queue, 8 reads/frame of 64 KiB,
  graceful shutdown then kill.
- Features: diagnostics, hover, completion, signature help, definition,
  references, formatting, rename, code actions (including resolve),
  workspace edits with preview, lightbulb gutter, Problems/Servers/Log dock.
- UTF-16 column conversion, URI encoding, edit sorting/overlap rejection, and
  Markdown→BBCode conversion are centralized in `lsp_text.gd`.
- **Known issues:** `workspace/applyEdit` replies `{applied:true}` even when
  per-file writes fail; oversize-frame recovery can desynchronize the parser;
  forced kills lose exit codes; diagnostics versions are ignored; completion
  ignores `text_edit`/`additionalTextEdits`; no watched files, semantic tokens,
  inlay hints, code lens, or auto-install.
- Keyboard: `Ctrl+Shift+M` problems, `F12` definition, `Shift+F12` references,
  `F2` rename, `Ctrl+.` actions, `Shift+Alt+F` format, `Ctrl+Shift+H` hover,
  `Ctrl+Shift+Space` signature.

### 6.9 Comments and misc

- Comments are a playful overlay: `CommentsData` holds 21 contributor names;
  `Comments` shuffles and shows three cards with random age/likes and avatars
  from `resources/icons/comments/`. Active language comments come from the Lua plugin's
  `add_comment` calls.
- `update.gd` checks the GitHub releases API manually; it has no HTTP status,
  parse, rate-limit, or timeout handling.
- Notices are single-shot 5 s RichTextLabels; there is no queue, so rapid
  warnings overlap.
- Discord Rich Presence updates on active document/save. It is off by
  default (`discord_sdk` is opt-in) because presence broadcasts activity.
- Workspace trust: `src/platform/trust_service.gd` stores an exact-folder allow list in
  `user://trusted_workspaces.json`. Until a folder is trusted, LSP, DAP and run
  config loaders ignore `<workspace>/.griddycode.json` and
  `.griddycode/*.json`; the folder still opens for editing.

---

## 7. Persistence and configuration

| File | Owner | Contents |
|---|---|---|
| `user://settings.json` | `SettingsService` | Versioned settings values |
| `user://keybindings.json` | `KeybindingService` | Command → chord overrides |
| `user://session.json` | `SessionService` | Workspace, documents metadata, panels |
| `user://session.lock` | `SessionService` | Pid/start time; stale lock = crash |
| `user://session_backups/` | `SessionService` | Dirty/untitled buffer text |
| `user://data.save` | `FileManager` | Legacy current file/dir/theme + old settings |
| `user://workspaces.json` | `WorkspaceService` | Recent workspace roots |
| `user://run.json` | `RunConfig` | Global run profile overrides |
| `user://lsp.json` | `LspConfig` | Global LSP profile overrides |
| `user://langs/*.lua` | `LanguageService` | User language plugins |
| `user://themes/*.lua` | `LuaSingleton` | User themes |
| `<workspace>/.griddycode.json` | Run + LSP | Compact project config |
| `<workspace>/.griddycode/lsp.json` | LSP | Recommended project LSP config |
| `<workspace>/.griddycode/run.json` | Run | Recommended project run config |

The user-data folder on Windows is
`%APPDATA%\Godot\app_userdata\Qorix`.

---

## 8. Tests, builds, tooling

### Automated suites

```bash
godot --headless --path . --script res://tests/test_runner.gd
godot --headless --path . --script res://tests/integration/acceptance_runner.gd -- --workspace="C:/path/to/test/workspace"
# LSP e2e (requires Python):
godot --headless --path . --script res://tests/integration/lsp_e2e_runner.gd
```

- Unit runner: 84 suites, dependency-free `SceneTree`, `TestCase` assertions,
  `before_each`/`after_each`, exit code 1 on failure. A suite with zero checks
  fails.
- Suites cover core math/services, editor document state, run config/capture/
  catalog/explainer/GuessLang/output links, settings, search, session,
  workspace, keybindings, command registry, icons, and LSP protocol/text/
  config/client/manager.
- Acceptance runner drives a real editor against a fixture workspace with an
  isolated `APPDATA`; expected message is `Acceptance: 108 checks, 0 failure(s).`
- LSP e2e runner uses `tests/fixtures/fake_lsp_server.py` and expects
  `All LSP end-to-end checks passed: 59 checks.` It covers startup,
  diagnostics, completion, hover, navigation, formatting, signature, rename,
  code actions, server-initiated edits, crash restart, install cards, session,
  and shutdown.
- Manual pass: `docs/developer/manual-test-checklist.md` (15 sections + appendices).

### Builds and tooling

- Export presets: Windows Desktop (`Builds/Windows/...exe`) and Linux/X11
  (`Builds/Linux/...x86_64`), x86_64, embedded PCK, includes `*.lua,*.json`.
- `tools/mod-package/` holds the package/signing CLI and the test-gated preview
  export script.
- The Discord addon is enabled and loaded as an autoload.

---

## 9. Known issues, risks, and documentation drift

| Issue | Evidence |
|---|---|
| Camera lost the document past ~1600 lines | **Fixed:** `EditorHost` grows with `height_for_content()` |
| VHS/CRT whites out some themes; light-theme glow artifacts | README §HIGH; `tune_vhs_brightness()` mitigation |
| LSP panel state dropped on restore | **Fixed:** `_sanitize()` now keeps `lsp`/`git` and both panel flags |
| Session stores no window geometry | `session_service.gd` snapshot keys |
| Run exit code: docs say PTY wins, code prefers the marker | `run_capture.gd:8`, `run_service.gd:387` |
| `RunService.run()` documented to return final result, returns `{}` on capture | `run_service.gd:83`, `:358` |
| GuessLang threshold 0.45 vs docs 0.62 | `guesslang_service.gd`, `docs/user/run-and-output.md` |
| Default run config template shadows built-in Python with terminal mode | `run_config.gd` `DEFAULT_CONFIG_TEXT` |
| Terminal-mode Stop button unreachable; stop targets active tab | `builtin_commands.gd:135`, `output_panel.gd:338` |
| Clearing Run output suppresses live output until next run | `output_panel.gd:271` |
| `$dirSlash` documented but unsupported | `run_config.gd:581` |
| `workspace/applyEdit` reports success on partial failure | `lsp_manager.gd:1659` |
| Oversize LSP frame recovery can desync parser | `lsp_protocol.gd:113` |
| LSP ignores diagnostic versions and completion text edits | `lsp_manager.gd`, `editor_view.gd:220` |
| Hybrid auto-advance lesson completed without the freeform phase (stale "completed" from the guide double-fired after advance) | **Fixed:** `exercise_service.gd` ignores guide events for non-typing phases; regression test in `tests/unit/features/learning/test_exercise_service.gd` |
| Lesson and error-rule content shipped English-only | **Fixed:** German and Spanish lesson catalogs (`resources/courses/python_journey.{de,es}.json`) and localized `title_*`/`message_*`/`explain_*`/`fix_*` fields in every error-rule file; the explainer renders in the current UI language |
| Theme colors leaked across switches | **Fixed:** `setup_theme()` resets both palettes |
| Settings `reset_all()` did not emit or save | **Fixed:** emits `changed` per key and schedules a save |
| Settings description says Ctrl+= changes font size; it changes camera zoom | **Fixed:** `settings_service.gd` description now says Ctrl+= zooms the view |
| About panel shortcut text stale (font-size zoom, open-folder chord, undo/redo) | **Fixed:** About lists undo/redo, zoom wording and the alternate run/stop chords correctly (`src/main/editor.tscn`) |
| README says Godot 4.2; project targets 4.7 | `README.md:97`, `project.godot:19` |
| No `.gitignore` parsing; hard-coded skip list only | **Fixed:** `src/platform/ignore_rules.gd` drives the worker and file tree |
| No Lua hot reload; built-ins seeded only if missing | `lua_singleton.gd`, `file_manager.gd:395` |
| Updater has no error handling | **Fixed:** checks status/JSON and names the release repo in one place |
| Rust tool is orphaned, panics, and emits invalid JSON | **Removed:** `tools/audio-analysis/` deleted; docs and `.gitignore` updated |
| Workspace `.griddycode*.json` could name a process | **Fixed:** `TrustService` gate, wired into LSP/DAP/run configs |
| World/HUD two-coordinate system | `camera.gd`, HUD panels |

---

## 10. How to navigate and change it safely

1. Start at `file_manager.gd`: it is the composition root and the place where
   services, HUD panels, dialogs, and lifecycle hooks are wired.
2. Follow a feature through its signal chain. For example:
   typing → `EditorView.content_changed` → `FileManager._on_view_content_changed`
   → `LspManager.document_changed` / language detect timer.
3. Respect the coordinate split: world-space (camera, code, cursor trail,
   world overlays) vs HUD (`CanvasLayer`, screen pixels). When in doubt,
   convert with the view/camera transforms.
4. Keep hidden views alive. `EditorHost.activate()` hides, it does not free;
   only `DocumentManager.remove_document()`/`destroy_view()` should free.
5. Do not open overlays re-entrantly. `OverlayController` allows one at a time
   and ignores opens while animating; await close first (see
   `open_keybindings()`).
6. Check `ok` from `Fs.save()`/`FileStore.save()`; saves are not silent.
7. Preserve user files: Lua plugins/themes and settings are user-editable.
   Seeding is intentionally copy-if-missing.
8. Before changing run/LSP behavior, read `docs/user/run-and-output.md` and
   `docs/user/language-servers.md`; note the drift listed above where code differs.
9. Run the unit, acceptance, and LSP e2e suites (Godot + Python required), then
   do the manual pass for anything visual, focus-related, or camera-related.
10. The test runner prints the authoritative total (currently 7,376 checks
    across 84 suites) and exits 0/1. CI gates on that exit code; adding checks
    changes the printed number, so update this document rather than treating
    the old prose as an expected value.

---

## Appendix A — largest source files

| Lines | File |
|---:|---|
| 3,779 | `src/main/file_manager.gd` |
| 1,804 | `src/features/lsp/lsp_manager.gd` |
| 1,055 | `src/features/lsp/lsp_text.gd` |
| 830 | `src/features/lsp/lsp_panel.gd` |
| 683 | `src/features/lsp/lsp_client.gd` |
| 651 | `src/platform/settings_service.gd` |
| 587 | `tests/integration/acceptance_runner.gd` |
| 583 | `src/features/lsp/lsp_config.gd` |
| 580 | `src/editor/minimap.gd` |
| 575 | `src/workbench/file_tree_panel.gd` |
| 568 | `src/features/run/run_config.gd` |
| 564 | `src/main/autoloads/lua_singleton.gd` |
| 553 | `src/features/run/output_panel.gd` |
| 520 | `src/features/run/run_service.gd` |

(Counts differ slightly by tool because blank lines are counted differently;
use the file itself as the source of truth.)

## Appendix B — command groups

File: new/open/open folder/save/save as/quick open. Tab: close/reopen.
Edit: find/replace/undo/redo. Language: detect/clear. View: command palette,
file tree, search, terminal, comments, zoom, escape. Terminal: new/clear/kill/
open here. Run: run, run alt, run terminal, toggle output, config, stop, stop
alt. LSP: problems, definition, references, rename, code actions, format,
hover, signature, servers, restart. Preferences: settings, keybindings, theme,
info. Dynamic: recent workspaces and theme apply. Toggles: VHS, sunlight, glow,
music, minimap, code completion, cursor trail.

## Appendix C — default settings (41 keys)

Editor: `editor_font`, `editor_font_size`, `caret_type`, `caret_blink`,
`cursor_effect`, `cursor_effect_duration`, `cursor_effect_opacity`,
`caret_interval`, `draw_line_numbers`, `code_completion`,
`auto_detect_language`.

Indentation: `indentation_size`, `indentation_automatic`,
`indentation_use_spaces`, `auto_brace_completion`,
`auto_brace_highlight_matching`.

Running: `respect_shebang`, `save_before_run`.

Language: `lsp_enabled`, `lsp_diagnostics`, `lsp_completion`, `lsp_hover`,
`lsp_signature_help`, `lsp_lightbulb`, `lsp_auto_open_problems`.

Workspace: `restore_session`, `session_autosave`, `external_change_check`.

Scrolling: `smooth_scrolling`, `scroll_speed`, `minimap`, `minimap_width`.

Appearance: `zoom_intensity`, `glow`, `glow_intensity`, `sunlight`, `vhs`.

Audio: `music`, `music_volume`, `music_move_intensity`.

Integrations: `discord_sdk`.
