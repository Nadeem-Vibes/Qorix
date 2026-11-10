# Building a course mod — mod-author guide

This guide walks through the shape of the reference course so you can
build your own tutorial mod without copying its bugs. It assumes the mod
lifecycle and the shell, guide and exercise APIs. Read
[`../archive/mod-platform/api-reference-phase3.md`](../archive/mod-platform/api-reference-phase3.md) for the exact method
table and [`partial-ui-guide.md`](partial-ui-guide.md) for the
manifest, files and partial-UI basics.

The worked example is
[`samples/mods/griddycode.python_journey/1.0.0/`](../../samples/mods/griddycode.python_journey/1.0.0/).

## 1. Pick a small, static shape

A course mod has three jobs:

1. **Content** — lessons as data, not code.
2. **Orchestration** — open a lesson, start an exercise, react to host events,
   persist progress.
3. **Presentation** — a full shell when `ui.shell` is available, a partial panel
   otherwise.

Keep those apart. In the reference mod `content/` and `content/lessons/` are
data-only, `lib/` is pure logic plus layout builders, and `main.lua` is the only
file with side effects. Data files never touch `editor.*`, so they can be
executed and validated in a bare Lua state.

```text
my_course/
  manifest.json
  main.lua
  lib/
    course.lua      load and validate lesson data; navigation
    engine.lua      build the exercise phases and map state to steps
    progress.lua    editor.progress keys
    i18n.lua        locale loading and interpolation
    layout.lua      pure layout specs (no handlers)
  content/
    index.lua       ordered lesson paths
    lessons/*.lua   lesson data
    locales/en.lua  runtime strings
  locales/en.json   translator template
```

## 2. Manifest

```json
{
  "schema": 1,
  "id": "example.my_course",
  "name": "My Course",
  "version": "1.0.0",
  "api": 1,
  "min_editor": "1.4.0",
  "entry": "main.lua",
  "author": "You",
  "description": "One line for the Mods page.",
  "license": "MIT",
  "permissions": [
    "ui.shell",
    "documents.read",
    "documents.write",
    "files.read",
    "files.write",
    "workspace.read",
    "run"
  ],
  "settings": [
    { "key": "strict_mode", "type": "bool", "default": true, "label": "Strict typing" },
    { "key": "show_hints", "type": "bool", "default": true, "label": "Show hints" },
    { "key": "font_size", "type": "int", "default": 16, "min": 12, "max": 32, "label": "Text size" }
  ]
}
```

Rules of thumb:

- **Ask for the least you need.** `ui.shell` is optional if your course can run
  in a panel. `run` is optional if text checks are enough.
- `documents.read`/`documents.write` cover the guide and exercise APIs and the
  document edits. `files.read`/`files.write` require a trusted workspace; the
  API intersects them with trust, so you still need to handle
  `trust.required`.
- `workspace.read` is for `workspace.has_workspace()` and friends. Do not try
  to change the workspace root; API 1 has no `workspace.open_folder`.
- Declare every setting you read with `editor.settings.get`. The Mods page
  writes through the same store.
- `min_editor` must be `1.4.0` or newer for the current API surface.

## 3. Content model

`content/index.lua` returns an ordered list of paths under `content/`:

```lua
return {
  "lessons/01_hello.lua",
  "lessons/02_variables.lua",
  "lessons/03_types.lua",
  "lessons/04_conditionals.lua",
  "lessons/05_loops.lua",
}
```

Each lesson is a table. Keep it serializable:

```lua
return {
  id = "01_hello",              -- also used in progress keys and widget ids
  number = 1,
  title = "Hello",
  summary = "One sentence for the course list.",
  coach = "The one idea this lesson teaches.",
  file = "python_journey/01_hello.py",
  starter = "",                 -- text written to a new lesson file

  exercise = {
    title = "Say hello",
    prompt = "Type the line, then add a second print.",
    typing = {
      target = 'print("Hello, Qorix!")\n',
      progression = "character",        -- character | word | line | none
      mode = "strict",                  -- strict | coach
      display = { scope = "line", chars = 64 },
      marks = {
        { id = "call", text = "print" },
        { id = "message", text = '"Hello, Qorix!"' },
      },
      hints = {
        { on = "start", text = "Type the line exactly." },
        { on = "mark", mark = "call", text = "print is a function." },
        { on = "mistake", mistake = 2, text = "Check the quotes." },
        { on = "complete", text = "Now add one more line." },
      },
    },
    freeform = {
      prompt = 'Add: print("Hello, Python!")',
      example = 'print("Hello, Qorix!")\nprint("Hello, Python!")\n',
      hint = "Keep the first line; add another print.",
      run = {
        timeout_ms = 15000,
        tests = {
          { name = "first line", type = "stdout_contains", value = "Hello, Qorix!" },
          { name = "second line", type = "stdout_contains", value = "Hello, Python!" },
          { name = "clean exit", type = "exit_code", value = 0 },
        },
      },
      text = {
        tests = {
          { name = "first line", type = "contains", value = 'print("Hello, Qorix!")' },
          { name = "second line", type = "regex", value = "print\\(['\"]Hello, Python!['\"]\\)" },
        },
      },
    },
  },
}
```

Notes:

- `target` should end with `\n` so multi-line content keeps a clean shape, but
  that final newline is optional: typing the last visible character completes
  the step. Internal newlines and indentation are still inserted by Enter/Tab.
  Use spaces, never tabs, for Python indentation.
- `id` should match `^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$` because it is used in
  `editor.progress` keys.
- Keep `file` unique per lesson and inside a course folder in the workspace.
- `run` and `text` are alternative validation specs for the same edit. Always
  provide `text` so the course still works without a trusted workspace.
- Supported text checks: `exact_text`, `contains`, `regex`, `tests`.
  Supported run checks: `stdout_contains`, `stdout_regex`, `exit_code`,
  `tests`. A run spec can also use `timeout_ms` (default 10 s; the sample uses
  15 s).

## 4. Opening a lesson

Resolve the workspace first, then create or reuse the file, then open the
document:

```lua
local path = "python_journey/" .. lesson.id .. ".py"
local has_workspace, err = editor.workspace.has_workspace()
if has_workspace then
  local exists = editor.files.exists(path)
  if not exists then
    editor.files.write(path, lesson.starter or "") -- creates parent folders
  end
  local doc, open_err = editor.docs.open(path)
  if doc then
    return doc, true                             -- run-backed validation is possible
  end
end

-- No workspace/trust/open: an untitled lesson document still works.
local doc = editor.docs.create({ text = lesson.starter or "" })
return doc, false
```

`files.write` and `files.exists` require workspace trust. `docs.open`
additionally needs `files.read`. If `docs.create` is given a `path` that already
exists, it returns `doc.exists` — use `docs.open` for existing files rather than
overwriting the learner's work.

Keep the reason the run is unavailable and show it in the panel:

```lua
local reason = "course.run.no_workspace" -- or no_trust, no_permission, no_file
```

Map host codes (`workspace.required`, `trust.required`, `permission.denied`) to
localized reason keys. Never show a bare error object to the learner.

## 5. Hybrid exercises

Build one `hybrid` exercise per lesson. The typing phase starts a guide session;
`auto_advance = true` moves to the freeform phase after the typing target
passes.

```lua
local started, err = editor.exercise.start({
  kind = "hybrid",
  doc = doc_id,
  title = lesson.exercise.title,
  prompt = lesson.exercise.prompt,
  phases = {
    {
      id = "typing",
      kind = "typing",
      title = "Type it",
      target = lesson.exercise.typing.target,
      progression = "character",
      mode = strict and "strict" or "coach",
      display = { scope = "line", chars = 64 },
      marks = lesson.exercise.typing.marks,
      hints = lesson.exercise.typing.hints,
    },
    {
      id = "freeform",
      kind = "freeform",
      title = "Your turn",
      prompt = lesson.exercise.freeform.prompt,
      validation = use_run and lesson.exercise.freeform.run
                          or lesson.exercise.freeform.text,
    },
  },
  auto_advance = true,
})
```

State handling:

- `editor.exercise.state(id).state` is `active`, `validating`, `completed`,
  `failed` or `stopped`; `phase_kind` says which phase is active.
- `editor.exercise.submit(id)` returns `{status = "pending"}` for run checks;
  wait for `exercise.completed` / `exercise.failed`, do not spin.
- **Retry** should call `editor.exercise.retry(id, { restore = "checkpoint" })`.
- On lesson switch, stop the current exercise before opening the next document.
- The host allows one guide/exercise session at a time. Handle `state.invalid`
  with a readable message rather than assuming ownership.

Run-backed validation needs `run` and workspace trust. The API checks both
before the service starts a run; a blocked run arrives as `run.blocked`.

## 6. Progress and onboarding

Use one key per lesson plus small bookkeeping keys:

```lua
local PREFIX = "lessons."
local LAST_KEY = "course.last"
local ONBOARDING_KEY = "onboarding.seen"

editor.progress.set(PREFIX .. id .. ".typed", true)
editor.progress.set(PREFIX .. id .. ".done", true)
editor.progress.set(LAST_KEY, id)
editor.progress.set(ONBOARDING_KEY, true)
```

Keys must match `^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`. Progress values are
booleans/strings; keep them JSON-shaped. On open, resume at `course.last`, else
the first lesson whose `done` is false, else the first lesson. (`editor.progress`
is `core`.)

The onboarding dialog is a normal `editor.ui.dialog` with `buttons` and an
`editor.ui.on(dialog_id, "click", fn)` handler. Record `onboarding.seen` when
the learner chooses either button so the dialog does not nag. If a dialog
cannot open, start the course anyway and show a notification — do not block on
optional UI.

## 7. Shell and partial UI

Take over only when the capability is available, and always have a panel path.
Consent is all-or-nothing per version: a mod that declares `ui.shell` and is
granted consent is expected to have it, so the realistic triggers are a host
without the capability, a failed takeover (`shell.busy`) or a full slot.

```lua
if editor.permissions.has("ui.shell") then
  local taken, err = editor.ui.shell.takeover({ layout = Layout.full(state) })
  if taken then
    view_mode = "shell"
  else
    enter_partial("The full-screen layout was unavailable: " .. err.code)
  end
else
  -- Defensive: a host build that does not offer ui.shell.
  enter_partial("ui.shell is unavailable; using the side panel.")
end
```

- Shell layouts are **static** in API 1. `editor.ui.update` only targets partial
  mounts. For a lesson switch, either exit and take over again (the sample) or
  keep the layout lesson-independent and update labels through a new takeover.
- The `editor` reserved rectangle must be a direct child of layout containers
  (`vbox`/`hbox`/`grid`), **never inside a `panel`**: a panel's background is
  opaque and covers the real CodeEdit behind the shell, and its mouse filter
  swallows the clicks the code view needs. Give the surrounding content its own
  panel above the `editor` widget (see the `lesson_header` panel in both
  journey samples) and let the rectangle itself stay bare. Layout containers
  and the slot pass mouse events through to the code view; the host returns
  keyboard focus to the code view when the shell opens and after shell widget
  actions, so typing works without clicking into the code first.
- A partial mount loses its widget handlers after `editor.ui.update`; call your
  `bind_actions()` again after every update and after every rebuild.
- Bind ids that exist in both layouts (`start`, `check`, `hint`, `retry`,
  `next_lesson`, `previous`, `help`, `leave`, `lesson_<id>`). The sample binds
  both `next` and `next_lesson` for that reason.
- Explain the fallback in the first panel label. “Side panel” alone is not
  enough; name the permission or host code.
- Shell takeover is exclusive. If another mod owns the screen, `shell.busy`
  comes back — show it and offer the panel, do not retry in a loop.
- On `deactivate()`, stop the exercise, exit the shell, unmount the partial
  panel and clear local state.

## 8. Localization

`assets.read_text` is confined to `<mod>/assets/`, so keep runtime locale files
under `content/` and load them with `editor.content.load`:

```lua
local strings = editor.content.load("locales/en")
```

`content/locales/en.lua` returns a table of strings. `locales/en.json` is the
translator template with exactly the same keys. Provide a tiny `t()`:

```lua
function M.t(key, vars)
  local text = strings[key] or key
  if type(vars) == "table" then
    text = text:gsub("{(%w+)}", function(name)
      return tostring(vars[name] or "{" .. name .. "}")
    end)
  end
  return text
end
```

Guidelines:

- Every user-visible string — buttons, status, hints, fallback reasons, dialog
  copy, accessible labels — comes from the table.
- Keep placeholders stable across languages; the test checks `{done}`, `{total}`
  and friends.
- Missing keys fall back to the key itself, not to a crash. If the locale file
  cannot load, keep built-in English for the fallback reasons so a translation
  error cannot strand the learner in an unexplained panel.
- Add a parity test: parse the JSON template, execute the Lua table, compare key
  sets and string types, and scan `t("...")` calls for undefined keys.

## 9. Accessibility checklist

- Every action is a `button`; the catalog gives buttons focus by default.
- Give each button a `tooltip` that says what it does, not just its label.
- Lesson buttons should announce number, title and status.
- Progress should have both a visible “N of M” label and a tooltip.
- Show state as text as well as color: current lesson, phase, checking, failed,
  run unavailable.
- Explain `Tab`, `Enter`/`Space`, and the host panic shortcut in help.
- Do not trap focus, use timers to steal focus, or rely on hover-only hints.
- Keep a readable `font_size` setting and clamp it on read.

## 10. Performance

- Load content and locale once at activation; cache lessons in a local table.
- Do not poll. Listen to `exercise.*` / `guide.*` events and rebuild only on
  transitions. Avoid `editor.every` unless you truly need animation.
- Keep layouts small and static. The catalog caps a layout at 200 widgets and
  depth 8; validate both the full and partial specs.
- A shell refresh is a full rebuild; keep it to lesson/phase transitions, not
  every keystroke. The guide overlay is host-owned.
- Respect the host budgets: 250k instructions per resume, 2 ms/frame event
  dispatch and a 25 ms wall-clock watchdog. Yield with `editor.wait(ms)` inside
  `editor.async` for long work; never busy-wait.
- Reuse one validation run per submit; do not start a run from a timer or
  event storm.

## 11. Test like the reference mod

At minimum:

1. **Compile** every `.lua` file (`load()` without executing).
2. **Execute data-only files** (index, lessons, locales) and assert their
   shape, ordering, unique ids and validation specs.
3. **Execute modules** with a stub `require`/`editor` and assert each returns a
   table. This catches a missing `local M = {}`.
4. **Validate layouts** with `ModWidgetCatalog.validate` for both the shell and
   the panel.
5. **Run the actual `main.lua`** against a Lua stub of the sandbox surface and
   drive onboarding, start, phase change, submit, completion, navigation,
   failure/retry, commands, deactivate and the partial path. Assert the
   resulting progress keys, dialogs and layout reason text.
6. **Check locale parity** between the Lua table and the JSON template, and scan
   `t()` keys used by the UI.

The reference-course suites do exactly this:

```bash
godot --headless --path . --script res://tests/test_runner.gd
```

## 12. Pitfalls that actually bit

- Missing `local M = {}` in a module returns `nil` and fails the first
  `M.function` call. Return the table and test it.
- A local function used by a closure built earlier needs a forward declaration:
  `local open_lesson` before the closures, then `function open_lesson(...)`.
  Lua resolves the name at call time, not at closure creation.
- Use `table.unpack`, not `unpack`; and never name a parameter `table` — it
  shadows the library and breaks `table.insert`.
- `editor.ui.update` forgets handlers; re-bind after every update.
- A shell layout cannot be diffed; exit and take over again.
- `docs.create({path = existing})` returns `doc.exists`; use `docs.open`.
- `files.write` and `files.exists` need workspace trust; handle
  `trust.required`.
- Run validation needs `run` and trust; always provide text fallback tests.
- `editor.content.load` appends `.lua` when the path has no extension; paths are
  relative to `content/`.

## 13. Release checklist

Before publishing, run the headless suite and then the window checks in the
[manual test checklist](../developer/manual-test-checklist.md): five lessons end
to end, keyboard-only, screen reader, partial UI, performance, panic/restore,
and screenshots. Public distribution and signatures are covered by the
[publisher guide](publisher-guide.md) and [package format](package-format.md).
