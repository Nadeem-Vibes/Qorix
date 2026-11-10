-- Note Taker: a prompt dialog plus a workspace-relative file write.
--
-- files.* and workspace.* need a trusted workspace and explicit consent. The
-- host re-checks both at call time; the manifest only declares intent.

local mount_id = nil

local function folder()
	return editor.settings.get("folder", "notes")
end

local function save_note()
	if not editor.workspace.has_workspace() then
		editor.ui.notify("Open a folder before saving a note.", "warning")
		return
	end

	local dialog_id, dialog_error = editor.dialogs.prompt({
		title = "Save a note",
		message = "The note is written under " .. folder() .. "/quick_note.txt.",
		default = "",
		placeholder = "What did you learn?",
	}, function(result)
		if result == nil or not result.confirmed then
			return
		end
		local text = tostring(result.value or "")
		if text == "" then
			editor.ui.notify("The note was empty; nothing was written.", "warning")
			return
		end

		local target = folder() .. "/quick_note.txt"
		local written, write_error = editor.files.write(target, text)
		if written == nil then
			editor.ui.notify("Could not write the note: " .. tostring(write_error and write_error.code), "error")
			editor.log.error("note write failed: " .. tostring(write_error and write_error.code))
			return
		end
		editor.ui.notify("Saved " .. target, "info")
	end)

	if dialog_id == nil then
		editor.log.error("could not open the note prompt: " .. tostring(dialog_error and dialog_error.code))
	end
end

local function spec()
	local status = editor.workspace.has_workspace()
		and ("Workspace: " .. editor.workspace.name())
		or "Open a folder to save notes."
	return {
		type = "panel",
		id = "dock",
		title = "Note Taker",
		children = {
			{ type = "label", id = "status", text = status },
			{ type = "button", id = "save", text = "Save note…" },
			{ type = "label", id = "hint", text = "Writes to " .. folder() .. "/quick_note.txt", color = "#8a8fa3" },
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
	editor.log.error("could not mount the note dock: " .. tostring(mount_error and mount_error.code))
else
	editor.ui.on("save", "click", save_note)
end

editor.events.on("workspace.opened", render)
editor.events.on("workspace.closed", render)

local registered, register_error = editor.commands.register({
	id = "griddycode.note_taker.save",
	label = "Note Taker: Save a Note…",
	category = "Mods",
	handler = save_note,
})
if not registered then
	editor.log.error("could not register the save command: " .. tostring(register_error and register_error.code))
end

function deactivate()
	if mount_id ~= nil then
		editor.ui.unmount(mount_id)
		mount_id = nil
	end
end
