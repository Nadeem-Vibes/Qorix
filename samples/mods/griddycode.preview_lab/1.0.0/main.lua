-- Preview Lab: the Phase 5 developer-mode sample.
--
-- This file and lib/build.lua are watched when the mod is loaded from
-- user://mods_dev/<id>/<version> in developer mode. Saving either file
-- deactivates and reactivates the mod. The activation counter lives in storage,
-- so it survives a hot reload even though the panel is rebuilt from scratch.

local build = require("build")

local activations = (editor.storage.get("activations", 0) or 0) + 1
editor.storage.set("activations", activations)

local mount_id = nil

local function spec()
	local greeting = editor.settings.get("greeting", "Hello from a development mod")
	return {
		type = "panel",
		id = "dock",
		title = "Preview Lab",
		children = {
			{ type = "label", id = "greeting", text = greeting },
			{
				type = "label",
				id = "status",
				text = "Build " .. build.label .. "  ·  activations: " .. tostring(activations),
			},
			{ type = "button", id = "ping", text = "Ping" },
			{
				type = "label",
				id = "hint",
				text = "Edit main.lua or lib/build.lua with --mod-dev; this panel reloads.",
				color = "#8a8fa3",
			},
		},
	}
end

local function render()
	if mount_id ~= nil then
		editor.ui.update(mount_id, spec())
	end
end

local function ping()
	editor.ui.notify("Preview Lab: activation " .. tostring(activations) .. " is live.", "info")
	editor.log.info("Preview Lab ping (build " .. build.label .. ", activation " .. tostring(activations) .. ")")
end

mount_id, mount_error = editor.ui.mount("right", spec())
if mount_id == nil then
	editor.log.error("Preview Lab could not mount its dock: " .. tostring(mount_error and mount_error.code))
else
	editor.ui.on("ping", "click", ping)
end

local ping_command, ping_error = editor.commands.register({
	id = "griddycode.preview_lab.ping",
	label = "Preview Lab: Ping",
	category = "Mods",
	handler = ping,
})
if ping_command == nil then
	editor.log.error("Preview Lab could not register ping: " .. tostring(ping_error and ping_error.code))
end

local reset_command, reset_error = editor.commands.register({
	id = "griddycode.preview_lab.reset",
	label = "Preview Lab: Reset Activation Count",
	category = "Mods",
	handler = function()
		activations = 1
		editor.storage.set("activations", activations)
		render()
		editor.ui.notify("Preview Lab activation counter reset.", "info")
	end,
})
if reset_command == nil then
	editor.log.error("Preview Lab could not register reset: " .. tostring(reset_error and reset_error.code))
end

function deactivate()
	if mount_id ~= nil then
		editor.ui.unmount(mount_id)
		mount_id = nil
	end
end
