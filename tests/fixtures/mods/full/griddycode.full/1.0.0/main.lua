-- Full fixture: every Phase 1 loader plus settings, keys and progress.

local helper = require("lib.helper")
local lesson = editor.content.load("lesson")
local note = editor.assets.read_text("note.txt")

editor.settings.declare({
	{ key = "accent", type = "string", default = "blue", label = "Accent" },
})

local registered = editor.commands.register({
	id = "griddycode.full.greet",
	label = "Full: Greet",
	handler = function()
		editor.log.info(helper.greet("world") .. " / " .. lesson.title .. " / " .. note)
	end,
})

if registered then
	local bound, bind_error = editor.keys.bind("griddycode.full.greet", "Ctrl+Alt+G")
	if not bound then
		editor.log.warn("keybinding refused: " .. tostring(bind_error and bind_error.code))
	end
end

editor.progress.set("lessons", 1)
editor.storage.set("ready", true)
editor.log.info("full activated: intensity=" .. tostring(editor.settings.get("intensity", -1)))
