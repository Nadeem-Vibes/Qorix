-- Hello Dock: the smallest complete partial-UI mod.
--
-- It demonstrates the Phase 2 containers and leaves (panel/label/button),
-- widget diffing, a command, a declared setting, a notification and storage.
-- Copy this folder to user://mods/ and restart Qorix.

local clicks = editor.storage.get("clicks", 0)
local mount_id = nil

local function dock_spec()
	local label = editor.settings.get("label", "Hello from a mod")
	local show_count = editor.settings.get("show_count", true)
	local text = label
	if show_count then
		text = text .. "  ·  clicks: " .. tostring(clicks)
	end

	return {
		type = "panel",
		id = "dock",
		title = "Hello Dock",
		children = {
			{ type = "label", id = "greeting", text = text },
			{ type = "button", id = "bump", text = "Say hello" },
		},
	}
end

local function render()
	if mount_id ~= nil then
		editor.ui.update(mount_id, dock_spec())
	end
end

local function bump()
	clicks = clicks + 1
	editor.storage.set("clicks", clicks)
	render()
	editor.ui.notify("Hello from a dock (" .. tostring(clicks) .. ")", "info")
end

mount_id, mount_error = editor.ui.mount("right", dock_spec())
if mount_id == nil then
	editor.log.error("could not mount the dock: " .. tostring(mount_error and mount_error.code))
else
	-- A button emits from its own widget id, not from the panel that contains it.
	-- The local id is enough; it is resolved as <mod_id>.<local_id>.
	editor.ui.on("bump", "click", bump)
end

local registered, register_error = editor.commands.register({
	id = "griddycode.hello_dock.reset",
	label = "Hello Dock: Reset Counter",
	category = "Mods",
	handler = function()
		clicks = 0
		editor.storage.set("clicks", 0)
		render()
		editor.ui.notify("Hello Dock counter reset", "info")
	end,
})
if not registered then
	editor.log.error("could not register the reset command: " .. tostring(register_error and register_error.code))
end

function deactivate()
	if mount_id ~= nil then
		editor.ui.unmount(mount_id)
		mount_id = nil
	end
end
