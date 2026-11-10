-- Course loader and lookup helpers.
--
-- content/index.lua is the ordered list; every lesson file is data and must
-- expose an id, a title and a two-phase exercise (typing then freeform). The
-- loader reports a bad lesson and keeps the rest, so one typo cannot hide the
-- whole course.

local M = {}

local function log_bad(path, message)
	editor.log.error("Python Journey: " .. path .. ": " .. message)
end

local function is_text(value)
	return type(value) == "string" and value ~= ""
end

local function validate(entry, path)
	if type(entry) ~= "table" then
		log_bad(path, "the file must return a table")
		return nil
	end
	if not is_text(entry.id) then
		log_bad(path, "id must be a non-empty string")
		return nil
	end
	if type(entry.number) ~= "number" then
		log_bad(entry.id, "number must be a number")
		return nil
	end
	if not is_text(entry.title) or not is_text(entry.summary) then
		log_bad(entry.id, "title and summary must be strings")
		return nil
	end
	if type(entry.exercise) ~= "table" then
		log_bad(entry.id, "exercise must be a table")
		return nil
	end

	local typing = entry.exercise.typing
	if type(typing) ~= "table" or not is_text(typing.target) then
		log_bad(entry.id, "exercise.typing.target is required")
		return nil
	end
	local freeform = entry.exercise.freeform
	if type(freeform) ~= "table" or not is_text(freeform.prompt) then
		log_bad(entry.id, "exercise.freeform.prompt is required")
		return nil
	end
	if type(freeform.run) ~= "table" and type(freeform.text) ~= "table" then
		log_bad(entry.id, "exercise.freeform needs run or text validation")
		return nil
	end

	if entry.file ~= nil and not is_text(entry.file) then
		log_bad(entry.id, "file must be a workspace-relative path")
		return nil
	end
	return entry
end

function M.load()
	local index, index_error = editor.content.load("index")
	if type(index) ~= "table" then
		return nil, index_error
	end

	local lessons = {}
	for _, path in ipairs(index) do
		if type(path) == "string" and path ~= "" then
			local entry, load_error = editor.content.load(path)
			if entry == nil then
				log_bad(path, "did not load: " .. tostring(load_error and load_error.code or "unknown"))
			else
				local checked = validate(entry, path)
				if checked ~= nil then
					table.insert(lessons, checked)
				end
			end
		end
	end
	return lessons
end

function M.find(lessons, id)
	for _, entry in ipairs(lessons) do
		if entry.id == id then
			return entry
		end
	end
	return nil
end

function M.position(lessons, id)
	for index, entry in ipairs(lessons) do
		if entry.id == id then
			return index
		end
	end
	return nil
end

function M.next(lessons, id)
	local index = M.position(lessons, id)
	if index ~= nil and index < #lessons then
		return lessons[index + 1]
	end
	return nil
end

function M.previous(lessons, id)
	local index = M.position(lessons, id)
	if index ~= nil and index > 1 then
		return lessons[index - 1]
	end
	return nil
end

function M.first_incomplete(lessons, is_done)
	for _, entry in ipairs(lessons) do
		if not is_done(entry.id) then
			return entry
		end
	end
	return lessons[1]
end

function M.file_path(lesson)
	if lesson.file ~= nil then
		return lesson.file
	end
	return "python_journey/" .. lesson.id .. ".py"
end

return M
