local mount_id = editor.ui.mount("left", {type="vbox", id="root", children={{type="label", id="status", text="Note Taker"}}})
local function save_note()
  local ok, value = editor.dialogs.prompt({ title = "Save note", value = "note" })
  local name = value or "note.txt"
  if editor.workspace.has_workspace() then editor.files.write(name, "Saved from Note Taker") end
  editor.ui.notify("Saved " .. tostring(name), "info")
end
editor.ui.on("save", "click", save_note)
editor.commands.register({id="griddycode.note_taker.save", label="Note Taker: Save", handler=save_note})
function deactivate() if mount_id then editor.ui.unmount(mount_id) end end
