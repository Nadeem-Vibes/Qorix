local Course = require("course")
local Engine = require("engine")
local I18n = require("i18n")
local Layout = require("layout")
local Progress = require("progress")
local LESSONS = editor.content.load("index") or {}
local mounted = nil
local shell_active = false
local strict_mode = false
local show_hints = editor.settings.get("show_hints", true)
local font_size = editor.settings.get("font_size", 16)
strict_mode = editor.settings.get("strict_mode", false)
local current_lesson = nil
local current_exercise = nil
local freeform_ready = false

local function t(key, vars) return I18n.t(key, vars) end

local function lesson_by_id(id)
  for _, path in ipairs(LESSONS) do local lesson = editor.content.load(path); if lesson and lesson.id == id then return lesson end end
  return nil
end
local function first_lesson() return lesson_by_id("01_hello") or editor.content.load(LESSONS[1]) end
local function using_run_validation()
  if not editor.workspace.has_workspace() then return false, t("course.run.no_workspace") end
  if not editor.permissions.has("run") then return false, t("course.run.no_permission") end
  if not current_lesson then return false, t("course.run.no_file") end
  if not editor.files.exists(current_lesson.file) then return false, t("course.run.no_file") end
  return true, ""
end
local function snapshot(reason)
  return { lessons = LESSONS, lesson = current_lesson, done_count = 0, total = #LESSONS, partial_reason = reason, font_size = font_size, can_hint = show_hints }
end
local function bind_handlers()
  editor.ui.on("start", "click", function()
    if not current_lesson then current_lesson = first_lesson() end
    local use_run = using_run_validation()
    local phases = Engine.build_phases(current_lesson, use_run, strict_mode)
    current_exercise = editor.exercise.start({ kind = "hybrid", phases = phases })
  end)
  editor.ui.on("check", "click", function()
    local state = editor.exercise.state(current_exercise and current_exercise.exercise or 0)
    if state and state.state == "active" and state.phase_kind == "typing" and freeform_ready then
      state = { exercise = state.exercise, state = state.state, phase_kind = "freeform" }
    end
    if not Engine.can_check(state) then editor.ui.notify("Please finish typing first.", "info"); return end
    editor.exercise.submit(state.exercise)
  end)
  editor.ui.on("retry", "click", function() local state = editor.exercise.state(current_exercise and current_exercise.exercise or 0); if state and state.exercise then editor.exercise.retry(state.exercise, {}) end end)
  editor.ui.on("hint", "click", function() if current_exercise and current_exercise.exercise then editor.exercise.hint(current_exercise.exercise, Engine.hint_for(current_lesson, "freeform")) end end)
  editor.ui.on("help", "click", function() editor.ui.dialog({ title = t("course.help.title"), body = t("course.help.body") }) end)
  editor.ui.on("next_lesson", "click", function() end)
  editor.ui.on("previous", "click", function() end)
  editor.ui.on("leave", "click", function() if shell_active then editor.ui.shell.exit("leave"); shell_active = false end end)
  editor.ui.on("lesson_01_hello", "click", function() current_lesson = lesson_by_id("01_hello") or current_lesson; if current_lesson then local opened, err = editor.docs.open(Course.file_path(current_lesson)); if opened == nil then editor.docs.set_text(1, "") ; editor.files.write(Course.file_path(current_lesson), "") end end end)
end

function open_course()
  editor.ui.dialog({ title = t("onboarding.title"), body = t("onboarding.body"), buttons = { id = "start", label = "Start" } })
  editor.ui.on(1, "click", function(_)
    current_lesson = first_lesson()
    if not editor.permissions.has("ui.shell") then
      mounted = editor.ui.mount("center", Layout.partial(snapshot(t("partial.reason.permission"))))
      bind_handlers(); return
    end
    local takeover, err = editor.ui.shell.takeover({ layout = Layout.full(snapshot("")) })
    if takeover == nil then
      mounted = editor.ui.mount("center", Layout.partial(snapshot(t("partial.reason.failed", { code = tostring(err and err.code or "unknown") }))))
      bind_handlers(); return
    end
    shell_active = true
    mounted = editor.ui.mount("center", Layout.full(snapshot("")))
    bind_handlers()
    local doc_id = editor.docs.create({ title = t("app.title"), text = "" })
    editor.docs.reveal(doc_id)
  end)
end

editor.events.on("exercise.phase_changed", function(event) if event and event.kind == "freeform" then freeform_ready = true; Progress.mark_typed("01_hello") end end)
editor.events.on("exercise.completed", function(_) Progress.mark_done("01_hello") end)
editor.events.on("exercise.failed", function(_) editor.ui.notify("Check failed, revise and retry.", "warn") end)

editor.commands.register({ id = "griddycode.python_journey.open", label = "Open", handler = function() open_course() end })
editor.commands.register({ id = "griddycode.python_journey.next", label = "Next", handler = function() end })
editor.commands.register({ id = "griddycode.python_journey.previous", label = "Previous", handler = function() end })
editor.commands.register({ id = "griddycode.python_journey.hint", label = "Hint", handler = function() end })
editor.commands.register({ id = "griddycode.python_journey.help", label = "Help", handler = function() end })
editor.commands.register({ id = "griddycode.python_journey.leave", label = "Leave", handler = function() if shell_active then editor.ui.shell.exit("leave") end end })
editor.keys.bind("griddycode.python_journey.open", "Ctrl+Alt+J")
editor.keys.bind("griddycode.python_journey.next", "Ctrl+Alt+N")
editor.keys.bind("griddycode.python_journey.previous", "Ctrl+Alt+P")
editor.keys.bind("griddycode.python_journey.hint", "Ctrl+Alt+H")

function deactivate() if shell_active then editor.ui.shell.exit("deactivate"); shell_active = false end; if mounted ~= nil then editor.ui.unmount(mounted); mounted = nil end end
