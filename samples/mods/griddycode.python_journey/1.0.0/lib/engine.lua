local M = {}
function M.build_phases(lesson, use_run, strict)
  local typing = lesson.exercise.typing or {}
  local freeform = lesson.exercise.freeform or {}
  return {
    { kind = "typing", mode = strict and "strict" or "guided", target = typing.target, marks = typing.marks, hints = typing.hints },
    { kind = "freeform", prompt = freeform.prompt, validation = use_run and freeform.run or freeform.text },
  }
end
function M.step(state) if not state then return "typing" end if state.state == "completed" then return "done" end if state.state == "validating" then return "checking" end if state.phase_kind == "freeform" then return "freeform" end return "typing" end
function M.can_check(state) return state and state.phase_kind == "freeform" and (state.state == "active" or state.state == "failed") end
function M.is_pending(state) return state and state.state == "validating" end
function M.is_done(state) return state and state.state == "completed" end
function M.hint_for(lesson, phase)
  local list = (((lesson or {}).exercise or {}).typing or {}).hints or {}
  if phase == "freeform" then list = (((lesson or {}).exercise or {}).freeform or {}).hints or list end
  for _, hint in ipairs(list) do if type(hint) == "table" and tostring(hint.text or "") ~= "" then return hint.text end end
  return "Keep going."
end
return M
