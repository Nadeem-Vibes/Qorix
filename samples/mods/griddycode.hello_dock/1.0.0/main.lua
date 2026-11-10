local mount_id = editor.ui.mount("left", {type="vbox", id="root", children={{type="label", id="status", text="Hello Dock"}}})
editor.ui.update(mount_id, {type="vbox", id="root", children={{type="label", id="status", text="Hello Dock ready"}}})
editor.ui.on("reset", "click", function() editor.storage.set("dock_reset", true); editor.ui.notify("Hello Dock reset", "info") end)
editor.commands.register({id="griddycode.hello_dock.reset", label="Hello Dock: Reset", handler=function() editor.ui.notify("Hello Dock reset", "info") end})
function deactivate() if mount_id then editor.ui.unmount(mount_id) end end
