# API 1 — Phase 3 reference

This adds the shell, guide and exercise surfaces to
`docs/mod-platform/phase2/api-reference.md`. Each native method is permission
checked in `src/features/mods/api/api_v1.gd`; the Lua names are wrappers in
`src/features/mods/sdk/sandbox.lua`. The machine-readable contract is
`tests/fixtures/mods/api_v1_surface.json` (100 entries, sorted).

Every wrapper returns either a value or `nil, error`, where `error` is
`{code, message, details?}`. Calls never throw into mod code.

`<mod_id>` is the id from the manifest; widget ids are `<mod_id>.<local_id>`.

## Shell

| Lua | Native | Permission |
| --- | --- | --- |
| `editor.ui.shell.takeover(spec)` | `ui.shell.takeover` | `ui.shell` |
| `editor.ui.shell.exit(reason?)` | `ui.shell.exit` | `ui.shell` |
| `editor.ui.shell.set_editor_visible(visible)` | `ui.shell.set_editor_visible` | `ui.shell` |
| `editor.ui.shell.set_content_insets(insets?)` | `ui.shell.set_content_insets` | `ui.shell` |

`takeover` spec:

```lua
{
  layout = { type = "hbox", children = { ... } }, -- required; a container
  editor_visible = true,                          -- optional, default true
  insets = { left = 0, top = 0, right = 0, bottom = 0 }, -- optional override
}
```

The layout is validated with the widget catalog before anything changes. It may
reserve at most one `editor` widget; two are refused with `shell.editor_slot`
because API 1 has one code viewport. The `editor` widget is a placeholder
rectangle: the host moves the real editor under the camera so it lands inside
that rectangle (advisory insets, no scissor).

The core HUD is snapshotted and hidden, never freed. Host chrome (34 px, mod
name, Exit mod, panic hint) is a child of the same shell layer, added before the
content and reserved at the top; it cannot be hidden by the layout. Only one
shell exists at a time; a second owner gets `shell.busy`.

`exit` restores the snapshot, the camera insets and the editor's previous world
visibility, then removes the layer. `set_content_insets({})` drops a custom
override and returns to the reserved-rectangle insets. Insets must be numbers;
negative values clamp to zero.

State shape (returned by every shell method):

```lua
{ owner, active, editor_visible, custom_insets, insets = {left, top, right, bottom},
  panels, hidden, reason, duration_ms }
```

Shell widgets use the Phase 2 widget catalog plus `heading`, `code_block`,
`grid`, `badge`, `tabs`, `canvas` and `editor`; `width`, `height` and `grow` are
honoured. A shell layout is static for the life of the takeover:
`editor.ui.update` targets partial mounts, so change a shell by exiting and
taking over again. Widget events (`editor.ui.on(local_id, "click", fn)`) work the
same as partial mounts.

Host panic is `Ctrl+Alt+Shift+Esc`. The first press exits the shell; a second
press within two seconds disables all mods for the session. The host handles it
before any mod input filter.

```lua
local taken, err = editor.ui.shell.takeover({
  layout = {
    type = "hbox",
    children = {
      { type = "panel", id = "side", width = 260, title = "Lesson",
        children = {
          { type = "label", id = "body", text = "Type below." },
          { type = "button", id = "close", text = "Leave course" },
        } },
      { type = "panel", id = "main", grow = 1,
        children = { { type = "editor", id = "code", grow = 1 } } },
    },
  },
})
if not taken then
  editor.log.error("shell takeover failed: " .. tostring(err and err.code))
  return
end
editor.ui.on("close", "click", function()
  editor.ui.shell.exit("closed by the user")
end)
```

## Guide

| Lua | Native | Permission |
| --- | --- | --- |
| `editor.guide.start(spec)` | `guide.start` | `documents.read` |
| `editor.guide.state(session?)` | `guide.state` | `documents.read` |
| `editor.guide.pause(session?)` | `guide.pause` | `documents.read` |
| `editor.guide.resume(session?)` | `guide.resume` | `documents.read` |
| `editor.guide.reset({restore?})` | `guide.reset` | `documents.write` |
| `editor.guide.stop(reason?)` | `guide.stop` | `documents.read` |
| `editor.guide.hint(text, session?)` | `guide.hint` | `core` |
| `editor.guide.set_target(target, session?)` | `guide.set_target` | `documents.read` |
| `editor.guide.set_validation(spec, session?)` | `guide.set_validation` | `documents.read` |
| `editor.guide.resolve_validation(token, passed, details?)` | `guide.resolve_validation` | `documents.read` |
| `editor.guide.set_mode("strict"\|"coach", session?)` | `guide.set_mode` | `documents.read` |
| `editor.guide.set_progression(progression, session?)` | `guide.set_progression` | `documents.read` |
| `editor.guide.set_display(display, session?)` | `guide.set_display` | `documents.read` |

Start spec:

```lua
{
  doc = 12,                 -- document id; omit for the active document
  target = "print(1)\n",    -- required, non-empty, <= 64 KiB, no RTL
  title = "First line",     -- optional
  mode = "strict",          -- "strict" blocks mistakes, "coach" only reports
  progression = "character",-- "character"|"word"|"line"|"none"
  display = { scope = "line", chars = 64, alpha = 0.32 }, -- scope also next_char|segment|block
  marks = { { id = "call", text = "print" } },
  hints = {
    { on = "start", text = "Type it." },
    { on = "mark", mark = "call", text = "print is a function." },
    { on = "mistake", mistake = 2, text = "Check the quotes." },
  },
  validation = { type = "exact_text", value = "print(1)" }, -- optional
  notify_every = 8,         -- progress events every N codepoints
}
```

Mark text is found sequentially and must not overlap an earlier mark; duplicate
ids are refused. Hint triggers are `start`, `mark`, `mistake`, `idle`,
`segment_done`, `complete` and `diverged`.

While a session is active the guide reconciles the document against the target
on every content change and filters input before the GUI: the expected character
passes natively (so undo, repeat and IME keep working), a wrong character is
swallowed in strict mode, and Enter/Tab insert the target's newline and
indentation. A newline at the very end of a target is optional for completion:
typing the last visible character finishes the step, and Enter still works.
Filtering pauses when the caret is not at the expected position, a
selection exists, or the session is paused/diverged. The guide also turns off
wrap, auto-indent, auto-brace and completion for the session and restores them
on every terminal state.

A session is exclusive per host: a second owner gets `state.invalid`. States are
`active`, `paused`, `diverged`, `validating`, `completed`, `failed`, `stopped`.
`reset` defaults to restoring the text captured at start (`restore = "start"`),
or use `"checkpoint"`/`"keep"`.

`guide.start`, `guide.resume`, `guide.reset`, `exercise.start`, `exercise.retry`
and `exercise.advance` return keyboard focus to the active document. A session
started from a mod dock button is immediately typeable; a session belonging to a
background document never pulls focus away from the active tab.

Events: `guide.started`, `guide.progress`, `guide.segment`, `guide.mistake`,
`guide.diverged`, `guide.validated`, `guide.completed`, `guide.stopped`.
`guide.diverged` publishes the position and the expected text but never the
actual typed text; that is delivered only to the owning mod's session sink.

Guide and exercise methods read document content, so they need `documents.read`;
`guide.reset`, `exercise.retry` and `exercise.advance` can restore or replace
text and need `documents.write` as well.

`set_validation` with a run-backed check needs `run` and workspace trust, exactly
like `exercise.start`.

## Exercise

| Lua | Native | Permission |
| --- | --- | --- |
| `editor.exercise.start(spec)` | `exercise.start` | `documents.read` (+ `run` when validation runs) |
| `editor.exercise.state(id?)` | `exercise.state` | `documents.read` |
| `editor.exercise.submit(id?)` | `exercise.submit` | `documents.read` (+ `run` when the phase runs) |
| `editor.exercise.retry(id?, {restore?})` | `exercise.retry` | `documents.write` |
| `editor.exercise.stop(id?, reason?)` | `exercise.stop` | `documents.read` |
| `editor.exercise.hint(id?, text)` | `exercise.hint` | `core` |
| `editor.exercise.advance(id?)` | `exercise.advance` | `documents.write` |

Start spec:

```lua
{
  kind = "freeform",       -- "typing"|"freeform"|"hybrid"
  doc = 12,                -- document id; omit for the active document
  title = "Say hello",
  prompt = "Print Hello.",
  validation = {           -- or tests = { ... }
    timeout_ms = 10000,
    stop_on_fail = false,
    tests = {
      { name = "runs", type = "exit_code", value = 0 },
      { name = "output", type = "stdout_contains", value = "Hello" },
    },
  },
  auto_advance = false,    -- hybrid: advance as soon as a phase passes
  phases = {               -- hybrid only, <= 8
    { id = "type", kind = "typing", target = "print(1)\n" },
    { id = "extend", kind = "freeform", prompt = "Add a comment.",
      validation = { type = "contains", value = "#" } },
  },
}
```

A freeform phase needs a prompt or validation. A typing phase delegates to the
guide (target, marks, hints, mode and progression are passed through). A hybrid
is an ordered phase list; `advance` refuses until the current typing phase
completes or the freeform phase passes. `retry` restores the start text,
the latest checkpoint, or keeps the text, and increments the attempt count.

States: `active`, `paused`, `diverged`, `validating`, `passed` (more phases
remain), `failed`, `completed`, `stopped`. `completed` is terminal; `failed` is
recoverable with `retry`. The host reports stats (`duration_ms`, `attempts`,
`mistakes`, `hints`) but never writes course progress; use `editor.progress`.

Events: `exercise.started`, `exercise.phase_changed`, `exercise.submitted`,
`exercise.completed`, `exercise.failed`, `exercise.stopped`.

`exercise.start` scans the spec (including every hybrid phase) for run-backed
validation and applies the `run` + trust guard before the service is called.
`exercise.submit` does the same against the current phase.

## Validation

`ExerciseValidation` is shared by both engines. A spec is one check or a
`tests` list:

| `type` | Value | Runs a program |
| --- | --- | --- |
| `exact_text` | expected text | no |
| `contains` | substring | no |
| `regex` | pattern (compiled with `RegEx`) | no |
| `stdout_contains` | substring | yes |
| `stdout_regex` | pattern over the run output | yes |
| `exit_code` | integer | yes |
| `custom` | mod-defined answer | no (waits for a token) |
| `tests` | ordered list of the above | per entry |

`exact_text` normalizes line endings and tolerates a trailing newline. Run
checks capture the output and resolve from `run_finished`; a run past
`timeout_ms` fails with `run.timeout` and is stopped. Custom checks return a
pending token on the session's `validation.token`; answer with
`guide.resolve_validation(token, passed, {results})`, which routes to the active
guide or exercise session owned by the caller. Results are reported per check; a
run-backed list shares one run. Only one validation run is in flight at a time, and starting
one stops a run the user started, exactly like pressing Run.

A validation spec must be an object (`{type = ..., value = ...}` or
`{tests = {...}}`); a bare list is `exercise.invalid_spec`.

## Result codes added in Phase 3

`guide.invalid_spec`, `guide.unsupported`, `exercise.invalid_spec`,
`exercise.unknown`, `exercise.invalid_state`, `shell.invalid_spec`,
`shell.insets_invalid`, `shell.editor_slot`.

`shell.busy`, `state.invalid`, `doc.stale_handle`, `permission.denied`,
`trust.required`, `run.timeout` and `run.blocked` keep their existing meaning.

## Sample

`samples/mods/griddycode.python_journey/1.0.0` is the reference mod: shell
takeover, a typing lesson with marks and hints, a freeform exercise validated by
a real run, and cleanup in `deactivate()`.
