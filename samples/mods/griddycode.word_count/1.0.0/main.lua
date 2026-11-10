local mount_id = editor.ui.mount("left", {type="vbox", id="root", children={{type="label", id="status", text="Word Count"}}})
local function refresh()
  local active = editor.docs.active and editor.docs.active() or nil
  local text = active and (editor.docs.text(active) or "") or ""
  editor.ui.update(mount_id, {type="vbox", id="root", children={{type="label", id="status", text="Words: " .. tostring(#text)}}})
end
if editor.events and editor.events.on then editor.events.on("docs.changed", refresh) end
editor.commands.register({id="griddycode.word_count.report", label="Word Count: Report", handler=refresh})
function deactivate() if mount_id then editor.ui.unmount(mount_id) end end
