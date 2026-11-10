-- Word Count: host events + document reads + a live dock.
--
-- The mod never receives an engine object: editor.docs.active() is a stable
-- integer id and every read returns a fresh string. document.changed arrives
-- coalesced, so fast typing does not run this on every key.

local mount_id = nil
local last_document = 0

local function summarize()
	local document = editor.docs.active()
	if document == nil or document == 0 then
		return "No document is open."
	end
	last_document = document

	local text, read_error = editor.docs.text(document)
	if text == nil then
		return "Could not read document: " .. tostring(read_error and read_error.code)
	end

	local lines = 0
	for _ in string.gmatch(text, "\n") do
		lines = lines + 1
	end
	if #text > 0 and string.sub(text, -1) ~= "\n" then
		lines = lines + 1
	end

	local words = 0
	for _ in string.gmatch(text, "%S+") do
		words = words + 1
	end
	return "Words: " .. tostring(words) .. "  ·  Lines: " .. tostring(lines)
end

local function spec()
	return {
		type = "panel",
		id = "dock",
		title = "Word Count",
		children = {
			{ type = "label", id = "summary", text = summarize() },
			{ type = "button", id = "refresh", text = "Refresh" },
			{ type = "label", id = "hint", text = "Updates when the document changes.", color = "#8a8fa3" },
		},
	}
end

local function render()
	if mount_id ~= nil then
		editor.ui.update(mount_id, spec())
	end
end

mount_id, mount_error = editor.ui.mount("right", spec())
if mount_id == nil then
	editor.log.error("could not mount the word count dock: " .. tostring(mount_error and mount_error.code))
else
	editor.ui.on("refresh", "click", render)
end

editor.events.on("document.changed", render)
editor.events.on("document.activated", render)
editor.events.on("document.opened", render)
editor.events.on("document.closed", render)

local registered, register_error = editor.commands.register({
	id = "griddycode.word_count.report",
	label = "Word Count: Report",
	category = "Mods",
	handler = function()
		local summary = summarize()
		editor.ui.notify(summary, "info")
		editor.log.info(summary)
	end,
})
if not registered then
	editor.log.error("could not register the word count command: " .. tostring(register_error and register_error.code))
end

function deactivate()
	if mount_id ~= nil then
		editor.ui.unmount(mount_id)
		mount_id = nil
	end
end
