-- Progress helpers on top of editor.progress.
--
-- One record per lesson plus the last opened lesson and the onboarding flag.
-- Values are plain JSON: booleans and strings only, so a corrupted record is
-- easy to inspect.

local M = {}

local PREFIX = "lessons."
local LAST_KEY = "course.last"
local ONBOARDING_KEY = "onboarding.seen"

local function lesson_key(id, part)
	return PREFIX .. id .. "." .. part
end

function M.typed(id)
	return editor.progress.get(lesson_key(id, "typed"), false) == true
end

function M.done(id)
	return editor.progress.get(lesson_key(id, "done"), false) == true
end

function M.mark_typed(id)
	return editor.progress.set(lesson_key(id, "typed"), true)
end

function M.mark_done(id)
	return editor.progress.set(lesson_key(id, "done"), true)
end

function M.count_done(lessons)
	local count = 0
	for _, entry in ipairs(lessons) do
		if M.done(entry.id) then
			count = count + 1
		end
	end
	return count
end

function M.completed_map(lessons)
	local out = {}
	for _, entry in ipairs(lessons) do
		out[entry.id] = M.done(entry.id)
	end
	return out
end

function M.typed_map(lessons)
	local out = {}
	for _, entry in ipairs(lessons) do
		out[entry.id] = M.typed(entry.id)
	end
	return out
end

function M.last_id()
	local value = editor.progress.get(LAST_KEY, "")
	if type(value) == "string" then
		return value
	end
	return ""
end

function M.set_last(id)
	return editor.progress.set(LAST_KEY, id)
end

function M.onboarding_seen()
	return editor.progress.get(ONBOARDING_KEY, false) == true
end

function M.mark_onboarding()
	return editor.progress.set(ONBOARDING_KEY, true)
end

function M.reset(lessons)
	for _, entry in ipairs(lessons) do
		editor.progress.reset(lesson_key(entry.id, "typed"))
		editor.progress.reset(lesson_key(entry.id, "done"))
	end
	editor.progress.reset(LAST_KEY)
end

return M
