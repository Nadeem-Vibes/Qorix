local build = require("build")
local mount_id = nil
local function render(count)
  local spec = { type = "vbox", id = "root", children = {
    { type = "label", id = "status", text = "Preview activations: " .. tostring(count) },
    { type = "label", id = "build", text = build.label() },
  } }
  if mount_id == nil then mount_id = editor.ui.mount("right", spec) else editor.ui.update(mount_id, spec) end
end
local count = editor.storage.get("activations", 0) + 1
editor.storage.set("activations", count)
editor.settings.get("mode", "lab")
render(count)
function deactivate() if mount_id ~= nil then editor.ui.unmount(mount_id); mount_id = nil end end
