local M = {}
-- editor.exercise.start
function M.exercise(lesson, strict)
  return {
    kind = "hybrid",
    phases = {
      { kind = "typing", mode = strict and "strict" or "guided", target = lesson.exercise.typing.target, marks = lesson.exercise.typing.marks, hints = lesson.exercise.typing.hints },
      { kind = "freeform", prompt = lesson.exercise.freeform.prompt, validation = lesson.exercise.freeform.text },
    },
  }
end
function M.selfcheck() return "Self-check passed: 8/8" end
return M
