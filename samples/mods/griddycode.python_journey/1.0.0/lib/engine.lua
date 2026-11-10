-- Exercise orchestration.
--
-- Every lesson is one hybrid exercise: a typing phase owned by editor.guide,
-- then a freeform phase. The freeform validation is run-backed when the lesson
-- file is saved inside a trusted workspace, and text-only otherwise. The engine
-- never interprets progress; main.lua persists that through lib/progress.lua.

local M = {}

local function copy_table(value)
	if type(value) ~= "table" then
		return nil
	end
	local out = {}
	for key, item in pairs(value) do
		out[key] = item
	end
	return out
end

function M.build_phases(lesson, use_run, strict)
	local exercise = lesson.exercise or {}
	local typing = exercise.typing or {}
	local freeform = exercise.freeform or {}

	local mode = "coach"
	if strict then
		mode = typing.mode or "strict"
	end

	local validation = copy_table(use_run and freeform.run or freeform.text)
	if validation == nil then
		validation = { tests = {} }
	end

	return {
		{
			id = "typing",
			kind = "typing",
			title = typing.title or exercise.title or lesson.title,
			target = typing.target,
			progression = typing.progression or "character",
			mode = mode,
			display = typing.display,
			marks = typing.marks,
			hints = typing.hints,
		},
		{
			id = "freeform",
			kind = "freeform",
			title = freeform.title or "Freeform",
			prompt = freeform.prompt or "",
			validation = validation,
		},
	}
end

function M.start(lesson, doc, use_run, strict)
	local exercise = lesson.exercise or {}
	local started, err = editor.exercise.start({
		kind = "hybrid",
		doc = doc,
		title = exercise.title or lesson.title,
		prompt = exercise.prompt or "",
		phases = M.build_phases(lesson, use_run, strict),
		auto_advance = true,
	})
	if started == nil then
		return nil, err
	end
	return started
end

function M.state(id)
	return editor.exercise.state(id)
end

function M.submit(id)
	return editor.exercise.submit(id)
end

function M.retry(id)
	return editor.exercise.retry(id, { restore = "checkpoint" })
end

function M.hint(id, text)
	return editor.exercise.hint(id, text)
end

function M.advance(id)
	return editor.exercise.advance(id)
end

function M.stop(id, reason)
	return editor.exercise.stop(id, reason)
end

function M.phase_kind(state)
	if type(state) ~= "table" then
		return ""
	end
	return tostring(state.phase_kind or "")
end

function M.step(state)
	if type(state) ~= "table" then
		return "ready"
	end
	local status = tostring(state.state or "")
	if status == "completed" then
		return "done"
	end
	if status == "validating" then
		return "checking"
	end
	local kind = M.phase_kind(state)
	if kind == "typing" then
		return "typing"
	end
	if kind == "freeform" then
		return "freeform"
	end
	if status == "passed" then
		return "freeform"
	end
	if status == "failed" then
		return kind ~= "" and kind or "freeform"
	end
	if status == "stopped" or status == "idle" or status == "" then
		return "ready"
	end
	return "ready"
end

function M.can_check(state)
	if type(state) ~= "table" then
		return false
	end
	local status = tostring(state.state or "")
	if status == "validating" or status == "completed" or status == "stopped" then
		return false
	end
	return M.phase_kind(state) == "freeform"
end

function M.can_retry(state)
	if type(state) ~= "table" then
		return false
	end
	local status = tostring(state.state or "")
	if status == "completed" or status == "stopped" or status == "idle" then
		return false
	end
	return M.phase_kind(state) ~= ""
end

function M.is_pending(state)
	return type(state) == "table" and tostring(state.state or "") == "validating"
end

function M.is_done(state)
	return type(state) == "table" and tostring(state.state or "") == "completed"
end

function M.is_failed(state)
	return type(state) == "table" and tostring(state.state or "") == "failed"
end

function M.target_for(lesson, step)
	local exercise = lesson.exercise or {}
	if step == "freeform" or step == "checking" then
		return tostring((exercise.freeform or {}).example or "")
	end
	return tostring((exercise.typing or {}).target or "")
end

function M.prompt_for(lesson, step)
	local exercise = lesson.exercise or {}
	if step == "freeform" or step == "checking" then
		return tostring((exercise.freeform or {}).prompt or "")
	end
	if step == "ready" or step == "typing" then
		return tostring(exercise.prompt or "")
	end
	return ""
end

function M.hint_for(lesson, step)
	local exercise = lesson.exercise or {}
	if step == "typing" then
		local hints = (exercise.typing or {}).hints or {}
		for _, hint in ipairs(hints) do
			if hint.on == "start" and type(hint.text) == "string" then
				return hint.text
			end
		end
		return tostring(lesson.coach or "")
	end
	if step == "freeform" or step == "checking" then
		return tostring((exercise.freeform or {}).hint or lesson.coach or "")
	end
	return tostring(lesson.coach or "")
end

return M
