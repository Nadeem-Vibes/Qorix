local I18n = require("i18n")
local M = {}
local function t(key, vars) return I18n.t(key, vars) end
function M.full(state)
  local lesson_title = state.lesson and state.lesson.title or ""
  return {
    type = "vbox", id = "root", spacing = 6, children = {
      { type = "hbox", id = "title_row", children = { { type = "label", id = "course_title", text = t("app.title") } } },
      { type = "label", id = "progress", text = t("course.progress", { done = state.done_count or 0, total = state.total or 0 }), a11y = t("a11y.progress", { done = state.done_count or 0, total = state.total or 0 }) },
      { type = "panel", id = "lesson_header", children = { { type = "hbox", id = "lesson_top", children = { { type = "label", id = "lesson_title", text = lesson_title } } } } },
      { type = "vbox", id = "workspace", children = {
        { type = "label", id = "coach", text = state.lesson and state.lesson.coach or "" },
        { type = "editor", id = "code" },
        { type = "hbox", id = "controls", children = {
          { type = "button", id = "start", text = t("course.button.start"), tooltip = "start" },
          { type = "button", id = "check", text = t("course.button.check"), tooltip = "check" },
          { type = "button", id = "retry", text = t("course.button.retry"), tooltip = "retry" },
          { type = "button", id = "hint", text = t("course.button.hint"), tooltip = "hint" },
          { type = "button", id = "help", text = t("course.button.help"), tooltip = "help" },
          { type = "button", id = "lesson_01_hello", text = "1", tooltip = t("a11y.lesson_button", { number = 1, title = "Hello", status = "open" }) },
        } },
      } },
    },
  }
end
function M.partial(state)
  local partial_reason = state.partial_reason or t("partial.reason.permission")
  return {
    type = "vbox", id = "partial_root", children = {
      { type = "heading", id = "partial_title", text = t("partial.title") },
      { type = "label", id = "partial_why", text = t("partial.why") },
      { type = "label", id = "partial_reason", text = partial_reason },
      { type = "label", id = "partial_progress", text = t("course.progress", { done = state.done_count or 0, total = state.total or 0 }) },
    },
  }
end
return M
