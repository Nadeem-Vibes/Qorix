-- The 2 MB KV quota must reject this write and keep the existing values.

local payload = string.rep("x", 2 * 1024 * 1024 + 1)
local ok, err = editor.storage.set("oversized", payload)

editor.log.info("storage quota: " .. tostring(ok) .. " " .. tostring(err and err.code))
