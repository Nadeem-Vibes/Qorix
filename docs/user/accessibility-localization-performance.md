# Accessibility, localization and performance

This work makes Qorix comfortable with reduced motion, real text metrics,
high contrast, an alternative font, keyboard-only navigation, and a translated
interface. It also removes the per-frame work that made very large files and
workspace-wide search compete with typing.

The implementation was verified by code review and new headless suites. The
Godot executable was not available on the machine that produced this change, so
the suites and the Compatibility renderer still need to be run once on a machine
with Godot 4.7 installed (commands at the end of this document).

---

## 1. Accessibility

### New settings

| Key | Type / default | What it does |
|---|---|---|
| `editor_line_height` | float `1.25` (1.0–2.5) | Real line-height multiplier (Editor category). Converted to CodeEdit's extra-pixel `line_spacing` with `Accessibility.line_spacing_px()`. |
| `reduced_motion` | bool `false` | Master calm mode: no camera wobble, no glide, no music pulse, no cursor trail, no overlay fades, no full-screen shaders, paused background video. |
| `static_camera` | bool `false` | Stops the wobble and the smooth scroll without changing the rest of the UI. |
| `high_contrast` | bool `false` | Black background plus WCAG AAA foreground/syntax colours. Glow and shaders are suspended. |
| `dyslexia_font` | bool `false` | Uses the first installed OpenDyslexic / Atkinson Hyperlegible / Lexend (or Comic Sans MS / Verdana) and raises line height to at least 1.4. Never downloads a font. |
| `focus_indicators` | bool `true` | Bright 2 px focus ring on buttons, check buttons, dropdowns, sliders, line edits, lists and tabs. |
| `ui_animations` | bool `true` | Enables short fades/slides for docks, overlays and bottom panels. Reduced Motion and Static Camera override it. |
| `state_feedback` | bool `true` | Enables brief non-blocking feedback when switching tabs and changing editor state. |

Line height stays in **Editor** next to the font size; the other five live in
the new **Accessibility** category of `Ctrl+,`.

### Where it is applied

- `src/platform/a11y.gd` — pure helpers: WCAG contrast math, line-height
  conversion, large-file decision, dyslexia font lookup, focus-ring style.
  The headless suite checks the numbers.
- `src/main/autoloads/lua_singleton.gd` — applies the palette, line height, focus rings,
  motion switches, fonts, shaders and video pause. `HIGH_CONTRAST_GUI` /
  `HIGH_CONTRAST_KEYWORDS` are captured from the active theme first and restored
  exactly when the option is turned off (`_pre_contrast_gui`).
- `src/editor/camera.gd` — `set_motion_mode()`. In static/reduced mode the wobble
  is `Vector2.ZERO`, zoom snaps to its target, and `focus_on()` cuts instead of
  panning.
- `src/main/autoloads/music.gd` — `set_pulse_enabled()` keeps the music playing without the
  beat-driven camera pulse.
- `src/editor/cursor_effect.gd` — `set_motion_disabled()`.
- `src/editor/overlay_controller.gd` — fades/slides collapse to 1 ms and the
  settings panel focuses its first row on open.
- `src/platform/ui_motion.gd` — centralizes the animation policy so every
  transition respects the two UI settings and accessibility overrides.
- `src/platform/focus_nav.gd` — gives generated HUD controls a Tab stop and
  finds the first focusable control in a panel. `FileManager._setup_hud()` and
  `SettingsList.setup_settings()` call it.

### Reduced-motion behaviour

`reduced_motion` implies static camera. While it is on:

- camera offset is zero and every move is instantaneous,
- the smooth-scroll setting is ignored,
- the music keeps playing but never pulses the camera,
- the cursor trail is disabled,
- the Settings overlay and file dialogs cut open/closed,
- Sunlight/VHS and bloom are suspended (their setting values are kept),
- the jumping-cat background video is paused.

Turning it off restores the configured shader and glow state.

---

## 2. Localization

### Catalog

`resources/localization/strings.csv` is a Godot-format CSV:

```
keys,en,de,es
"Save","Save","Speichern","Guardar"
```

- `resources/localization/strings.csv` is a Godot-format CSV with **240+
  rows** across `keys,en,de,es`. The beginner-facing surface (welcome screen,
  Python Journey dock and notices, coach card chrome, error-card vote
  buttons) is translated; the five lessons ship as German and Spanish
  catalogs (`resources/courses/python_journey.{de,es}.json`), the forty
  error-rule explanations carry localized `title_de/es`, `message_de/es`,
  `explain_de/es` and `fix_de/es` fields chosen at diagnosis time, and the
  onboarding tutorial copy (`OnboardingService.STEPS`) ships with `de`/`es`
  variants picked by the current UI language. English-only beginner strings:
  none known.
- Column 1 is `keys`. Keys are the **English source strings**, so call sites can
  use `tr("Save")` and the same row works for every locale.
- Three languages ship: English, German and Spanish.
- `*.csv` was added to both export presets, so the catalog is inside exported
  builds.

### Runtime loader

`src/platform/localization_service.gd` parses the CSV at runtime instead of
relying on Godot's import step. That keeps a fresh checkout and headless runs
working without generated `.translation` files.

- `install()` builds one `Translation` per language column and registers them
  with `TranslationServer`.
- `user://localization/strings.csv` (same format) overrides individual rows
  without re-exporting the project.
- A missing key falls back to the source string, so a partially translated UI
  is safe.

### Language picker

`ui_language` is a `string` setting under **Language & Region**. Its options are
filled from the CSV header at startup (`LocalizationService.language_options()`).
Changing it calls `TranslationServer.set_locale()` and rebuilds the top bar,
tabs and settings list (`FileManager.refresh_localized_ui()`).

Translated surfaces:

- every command label (menus, toolbar tooltips, command palette, keybinding
  rows, beginner labels),
- menu titles (grouping still uses the stable English category ids),
- keybinding category labels,
- settings display names, descriptions, category headings and dropdown values
  that are part of the catalog,
- the welcome screen (all text, the five Python Journey lesson buttons and
  the tutorial/beginner-mode toggles),
- the Python Journey dock and its notices,
- the tutorial coach card chrome (STEP counter, Skip),
- the tutorial STEPS copy itself (titles, hints, button labels),
- the Run panel's error-card vote buttons and the feedback/winget toasts,
- the five Python Journey lessons (German and Spanish catalogs),
- the forty error-rule explanations (de/es fields).

English-only beginner strings: none known.

---

## 3. Performance

### Worker threads

- `src/platform/index_worker.gd` walks a workspace folder on a `Thread`,
  respects the existing skip list / depth / entry cap, and posts plain
  dictionaries in batches.
- `src/platform/search_worker.gd` runs `TextSearchBackend` on a `Thread` and
  publishes results in batches.
- `WorkspaceService` and `SearchService` drain those batches once per frame with
  a `Mutex`-guarded handoff. No Godot objects are created on the worker thread;
  `FileEntry` objects and index dictionaries stay on the main thread.
- `background_indexing` (default on) chooses this path. When off, or in
  `--headless` runs, the original deterministic frame-sliced pumps are used.
- Cancelling a search joins its worker so no thread is left behind; both
  services also stop their worker on `_exit_tree()`.

### Completion

- `src/platform/completion_scan.gd` caps the text handed to a Lua plugin at
  **4,000 lines / 120,000 characters**, keeping 200 lines of context above the
  caret and re-basing `line`/`column`.
- `EditorView` increments a generation counter on every request and every text
  change; a language-server reply from an older generation is discarded instead
  of landing at the wrong position.
- `cancel_completion()` clears the pending debounce and the popup when the
  document is replaced, a tab becomes large-file mode, or completion is turned
  off.
- Per-extension Lua state and keyword/region tables are still cached in
  `LanguageService` (one parse per extension, one `CodeHighlighter` per view).

### Camera and text metrics

- The per-frame `create_tween()` in `camera.gd` is gone. Zoom uses one
  exponential-smoothing lerp per frame (`ZOOM_RESPONSE`), and `focus_on()`
  still uses a single tween for overlay moves.
- `EditorView` caches the longest-line length. It is recomputed at most twice a
  second after a text change, and large files are sampled (200 measurements)
  instead of walking every line. The camera asks for the cached number and no
  longer splits the buffer every 250 ms.

### Renderer and WorldEnvironment

- `project.godot` now targets **GL Compatibility**
  (`renderer/rendering_method` and `.mobile`).
- The `WorldEnvironment` node and its `Environment` sub-resource were removed
  from `src/main/editor.tscn`. Glow was already a canvas bloom shader, and nothing
  else used the environment. `LuaSingleton.apply_glow()` keeps a null guard so
  it remains safe if a scene ever adds the node back.
- Compatibility support for the screen-texture bloom/VHS shaders must be
  confirmed visually on the target GPU (see the checklist below).

### Large-file mode

- `large_file_mode` (default on) and `large_file_threshold` (default **5,000
  lines**) decide when a document is large. A 750,000-character cap catches
  minified bundles with few lines.
- Above the threshold the view:
  - uses no `CodeHighlighter` (plain text),
  - skips completion entirely,
  - skips LSP diagnostic painting,
  - reports its state through `large_file_mode_changed`.
- `FileManager` suppresses the minimap for that document only and shows a
  one-time notice. Leaving the tab restores the Minimap setting.
- Opening a large file prints
  `INFO: large file <name> opened in <ms> ms` to the Godot output, which is the
  measurement used for the 300 ms acceptance target.

---

## 4. How to test

### Automated suites

Run from the repository root with Godot 4.7 on `PATH`:

```bash
godot --headless --path . --script res://tests/test_runner.gd
godot --headless --path . --script res://tests/integration/git_integration_runner.gd
godot --headless --path . --script res://tests/integration/git_ui_runner.gd
godot --headless --path . --script res://tests/integration/acceptance_runner.gd -- --workspace="C:/path/to/test/workspace"
```

New suites:

- `tests/unit/platform/test_accessibility.gd` — WCAG contrast, line-height conversion,
  large-file decision, dyslexia font selection, focus ring, schema/defaults.
- `tests/unit/platform/test_localization.gd` — CSV quoting/CRLF, install of en/de/es,
  locale switching, unknown locale and missing-key fallback.
- `tests/unit/platform/test_completion_scan.gd` — the 4,000-line and 120k-character
  caps, caret re-basing, caret line surviving the character trim.
- `tests/unit/platform/test_background_workers.gd` — threaded search results, safe
  cancellation, threaded index batches and skip folders.

The unit runner must end with `All tests passed: N checks across M suites.` and
exit code 0.

### Manual checklist

**Accessibility**

1. Open `Ctrl+,` → Accessibility. Set **Editor Line Height** to 2.0. Confirm the
   code lines visibly spread out (not just the camera zoom), and that the caret
   and cursor trail stay on the correct line.
2. Turn on **Reduced Motion**. Confirm:
   - opening Settings/theme/file dialogs is an instant cut,
   - moving the caret does not glide or wobble,
   - enabling **Shader: VHS and CRT** shows nothing while reduced motion is on,
   - turning reduced motion off brings the shader back,
   - music still plays (if on) but the camera does not pulse.
3. Turn on **Static Camera** alone; confirm the wobble/glide stop and effects
   remain available.
4. Turn on **High Contrast**; confirm black background, white text and bright
   syntax colours; text must remain readable in every open tab. Turn it off;
   the original theme colours must return exactly (including colours that theme
   does not explicitly set).
5. Turn on **Dyslexia-friendly Font**. If no supported font is installed, a
   yellow warning must appear and the checkbox must go back off. If one is
   installed, the editor font changes, line height becomes at least 1.4, and the
   Editor Font dropdown shows the chosen family. Turn it off to restore the
   previous font.
6. With **Focus Indicators** on, press `Tab` through the settings panel and the
   toolbar: every focused control needs a visible bright ring. `Ctrl+,` must put
   focus on the first row so the panel can be used without the mouse.

**Localization**

1. Open `Ctrl+,` → Language & Region → **Interface Language** and choose
   `Deutsch`. Menus, command labels, keybinding rows and settings names should
   switch to German; the code must not change.
2. Choose `Español`, then `English`.
3. Restart the app and confirm the chosen language is still selected.
4. Add a row to `user://localization/strings.csv` for a key and reload: the
   override should win. A missing row must stay in English, never blank.

**Performance**

1. Generate a 10,000-line file. PowerShell:

   ```powershell
   $out = "$env:TEMP\griddy_10k.js"
   1..10000 | ForEach-Object { "const value$_ = $_ * 2; // line $_" } | Set-Content $out
   ```

2. Open it in Qorix. The Godot output must contain
   `INFO: large file griddy_10k.js opened in <ms> ms`; the target is **< 300**.
3. Verify the minimap is hidden for that tab, syntax colours are absent,
   completion does not open, and typing/paging stays responsive. Switch back to a
   normal file: the minimap and colours must return.
4. With a normal file, type quickly and hold a key with completion enabled:
   the completion popup must appear after the debounce and never after a pause
   of one frame.
5. Open a workspace with many files, run **Search Across Files**, and keep
   typing in the editor while results stream in. The UI should stay responsive;
   Cancel and the `X` button must stop results immediately.
6. Idle memory: run the project from the Godot editor with
   **Debugger → Monitors → Memory** visible. Leave the editor idle for two
   minutes after closing extra tabs. Record `Memory Static` and object count at
   the start and end of the idle window. (The agreed budget is not encoded in
   this repository; report the measured value with the machine specs.)
7. Renderer: open **Project Settings → Rendering**, confirm the editor runs with
   `gl_compatibility`, and check that glow, Sunlight and VHS & CRT still render.
   The `WorldEnvironment` node must be absent from the scene tree.

### Reporting a bug

Include:

- the setting(s) involved and the file/language,
- whether the crash/visual bug reproduces after a restart,
- the Godot output around `INFO: large file ...` or any `ERROR`/`SCRIPT ERROR`,
- the exact renderer (`Compatibility`/`Mobile`), OS and GPU,
- for localization, the selected language and the source string that stayed in
  the wrong language,
- for performance, the measured open time, file line count and whether the
  file was in large-file mode.

---

## 5. Known limitations

- The automated suites and the Compatibility renderer could not be executed on
  the machine that wrote this change (no Godot binary on `PATH`). They are the
  first thing to run.
- Large-file mode intentionally disables LSP diagnostic painting as well as
  highlighting/completion. The language server may still parse the document;
  the editor simply does not paint its results.
- Localization currently covers command/menu/settings chrome. Long descriptions
  and most notices remain English until rows are added to `strings.csv`.
- The camera still follows the caret in world space; the historical ~1,600-line
  camera/CodeEdit scroll boundary is not removed by this work, but large-file
  mode avoids the expensive work above that size.
- Whether Godot's `DirAccess`/`FileAccess` calls used by the worker threads are
  as safe as expected must be confirmed on Windows and Linux in the manual pass;
  the headless suites exercise the worker classes directly but not a full app
  session on every platform.
