-- Localization scaffold.
--
-- Runtime strings live in content/locales/en.lua so the sandbox can load them
-- with editor.content.load (there is no JSON reader in the sandbox). The root
-- locales/en.json file is the same table as JSON, for translators and tooling.
-- Lesson prose stays in content/lessons because it is course data.

local M = {}

-- Critical fallbacks keep the fallback explanation readable even if the locale
-- file is missing or rejected. Everything else falls back to its key.
local FALLBACK = {
	["app.title"] = "Python Learning Journey",
	["course.leave"] = "Leave course",
	["course.start"] = "Start exercise",
	["course.check"] = "Check my work",
	["course.hint"] = "Show a hint",
	["course.retry"] = "Retry step",
	["course.next"] = "Next lesson",
	["partial.title"] = "Python Journey",
	["partial.reason.permission"] = "The ui.shell permission was not granted, so the full-screen course view is off. The journey still works in the editor.",
	["partial.reason.failed"] = "The full-screen view could not start. The journey is running in this side panel instead.",
	["partial.reason.slot"] = "The side panel could not be mounted. Use the command palette commands instead.",
	["partial.why"] = "All lesson files, hints and checks still work.",
	["notice.no_content"] = "No lesson content was found next to this mod.",
	["notice.no_documents"] = "The documents permission is required to open a lesson file.",
	["notice.help_fallback"] = "Python Journey help: Tab moves focus and Enter activates a button.",
}

local strings = nil

local function load_strings()
	local values, err = editor.content.load("locales/en")
	if type(values) == "table" then
		strings = values
	else
		strings = {}
		editor.log.warn("Python Journey: the English locale did not load: " .. tostring(err and err.code or "unknown"))
	end
end

function M.t(key, vars)
	if strings == nil then
		load_strings()
	end
	local text = strings[key]
	if type(text) ~= "string" then
		text = FALLBACK[key]
	end
	if type(text) ~= "string" then
		return key
	end
	if type(vars) == "table" then
		text = string.gsub(text, "{([%w_]+)}", function(name)
			local value = vars[name]
			if value == nil then
				return "{" .. name .. "}"
			end
			return tostring(value)
		end)
	end
	return text
end

function M.has(key)
	if strings == nil then
		load_strings()
	end
	return type(strings[key]) == "string"
end

function M.reload()
	strings = nil
end

return M
