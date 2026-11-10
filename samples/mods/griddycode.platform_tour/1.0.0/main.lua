local Build = require("build")
local Tour = require("tour")
local mount_id = nil
local strict_mode = false
local current = nil

local function lesson() return editor.content.load("lessons/01_manifest") end

local function render(status)
  local text = status or (strict_mode and "Strict typing is on" or "Strict typing is off")
  local spec = { type = "vbox", id = "root", children = {
    { type = "label", id = "status", text = text },
    { type = "button", id = "start", text = "Start" },
    { type = "button", id = "check", text = "Check" },
    { type = "button", id = "retry", text = "Retry" },
    { type = "button", id = "selfcheck", text = "Self-check" },
    { type = "button", id = "strict", text = "Strict" },
    { type = "button", id = "reset", text = "Reset" },
  } }
  if mount_id == nil then mount_id = editor.ui.mount("right", spec) else editor.ui.update(mount_id, spec) end
end

local function start() current = editor.exercise.start(Tour.exercise(lesson(), strict_mode)) end
local function check_answer()
  local state = editor.exercise.state(current and current.exercise or 0)
  if state.phase_kind == "typing" and state.state == "active" then editor.ui.notify("Please finish typing first.", "info"); return end
  if state.phase_kind == "freeform" and (state.state == "active" or state.state == "failed") then editor.exercise.submit(state.exercise) end
end
local function retry() local state = editor.exercise.state(current and current.exercise or 0); if state.exercise and state.exercise > 0 then editor.exercise.retry(state.exercise, {}) end end
local function run_selfcheck() editor.events.on("mod.griddycode.platform_tour.selfcheck_probe", function(_) end); editor.ui.notify(Tour.selfcheck(), "info") end
local function toggle_strict() strict_mode = not strict_mode; render(strict_mode and "Strict typing is on" or "Strict typing is off") end
local function reset() strict_mode = false; editor.progress.reset("tour.strict"); render("Strict typing is off") end

editor.ui.on("start", "click", function() start() end)
editor.ui.on("check", "click", function() check_answer() end)
editor.ui.on("retry", "click", function() retry() end)
editor.ui.on("selfcheck", "click", function() run_selfcheck() end)
editor.ui.on("strict", "click", function() toggle_strict() end)
editor.ui.on("reset", "click", function() reset() end)

editor.commands.register({ id = "griddycode.platform_tour.start", label = "Start", handler = start })
editor.commands.register({ id = "griddycode.platform_tour.selfcheck", label = "Self-check", handler = run_selfcheck })
editor.commands.register({ id = "griddycode.platform_tour.check", label = "Check", handler = check_answer })
editor.commands.register({ id = "griddycode.platform_tour.retry", label = "Retry", handler = retry })
editor.commands.register({ id = "griddycode.platform_tour.strict", label = "Strict", handler = toggle_strict })
editor.commands.register({ id = "griddycode.platform_tour.reset", label = "Reset", handler = reset })

editor.events.on("exercise.phase_changed", function(event) if event and event.kind == "freeform" then editor.progress.set("lessons.01_manifest.typed", true) end end)
editor.events.on("exercise.completed", function(_) editor.progress.set("lessons.01_manifest.done", true) end)
editor.events.on("exercise.failed", function(_) editor.ui.notify("Try again and press Retry.", "warn") end)

local count = editor.storage.get("activations", 0) + 1
editor.storage.set("activations", count)
render("Strict typing is off")

function deactivate() if mount_id ~= nil then editor.ui.unmount(mount_id); mount_id = nil end end
