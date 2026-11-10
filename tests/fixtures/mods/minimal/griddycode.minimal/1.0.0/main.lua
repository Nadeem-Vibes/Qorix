-- Minimal fixture: command, event subscription, storage, progress and teardown.

editor.log.info("minimal activated")

editor.events.on("app.mods_ready", function(payload)
	editor.storage.set("mods_ready", true)
	editor.log.info("mods ready: " .. tostring(payload.count))
end)

local registered, register_error = editor.commands.register({
	id = "griddycode.minimal.hello",
	label = "Minimal: Hello",
	handler = function(context)
		local count = editor.storage.get("hello_count", 0) + 1
		editor.storage.set("hello_count", count)
		editor.progress.set("last_command", "hello")
		editor.log.info("hello from minimal (" .. tostring(count) .. ")")
	end,
})

if not registered then
	editor.log.error("command registration failed: " .. tostring(register_error and register_error.code))
end

function deactivate()
	editor.log.info("minimal deactivated")
end
