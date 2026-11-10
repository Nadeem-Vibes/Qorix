-- Exercise orchestration for the Platform Tour.
--
-- The lesson itself is content/lessons/01_manifest.lua. This module only builds
-- the hybrid exercise (typing, then a freeform permission edit) and hides the
-- result-envelope plumbing from main.lua.

local M = {}

local function code_of(err)
	if type(err) == "table" then
		return tostring(err.code or err.message or "unknown")
	end
	return tostring(err or "unknown")
end

function M.load()
	local lesson, load_error = editor.content.load("lessons/01_manifest")
	if type(lesson) ~= "table" then
		return nil, load_error
	end
	if type(lesson.id) ~= "string" or type(lesson.typing) ~= "table" then
		return nil, { code = "lesson.invalid", message = "The lesson is missing id or typing." }
	end
	if type(lesson.typing.target) ~= "string" or lesson.typing.target == "" then
		return nil, { code = "lesson.invalid", message = "The lesson has no typing target." }
	end
	if type(lesson.freeform) ~= "table" or type(lesson.freeform.prompt) ~= "string" then
		return nil, { code = "lesson.invalid", message = "The lesson has no freeform phase." }
	end
	return lesson
end

function M.start(lesson, doc, strict)
	local typing = lesson.typing or {}
	local freeform = lesson.freeform or {}
	local validation = freeform.validation or { tests = {} }

	return editor.exercise.start({
		kind = "hybrid",
		doc = doc,
		title = lesson.title,
		prompt = freeform.prompt or "",
		auto_advance = true,
		phases = {
			{
				id = "typing",
				kind = "typing",
				title = "Manifest id",
				target = typing.target,
				mode = strict and "strict" or "coach",
				progression = "character",
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
		},
	})
end

function M.state(id)
	return editor.exercise.state(id)
end

-- Check answer is only meaningful in the freeform phase. During typing the
-- host advances automatically; submitting there delegates to a guide session
-- with no validation and returns state.invalid. A failed freeform validation
-- stays checkable: the learner edits the document and checks again.
function M.can_check(state)
	if type(state) ~= "table" then
		return false
	end
	local status = tostring(state.state or "")
	return (status == "active" or status == "failed")
		and tostring(state.phase_kind or "") == "freeform"
end

function M.submit(id)
	return editor.exercise.submit(id)
end

function M.retry(id)
	return editor.exercise.retry(id, { restore = "checkpoint" })
end

function M.stop(id)
	return editor.exercise.stop(id)
end

function M.code(err)
	return code_of(err)
end

return M
