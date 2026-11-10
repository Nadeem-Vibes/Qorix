local fallback = {
  ["partial.reason.permission"] = "Enable ui.shell permission to open the immersive view.",
  ["partial.reason.failed"] = "Shell takeover failed with code: {code}.",
  ["partial.reason.slot"] = "Host did not provide a usable shell slot ({code}).",
}
local locale = nil
if editor and editor.content and editor.content.load then locale = editor.content.load("locales/en") end
if type(locale) ~= "table" then locale = fallback end
local M = {}
local function interpolate(text, vars)
  if type(vars) ~= "table" then return text end
  return (text:gsub("{([A-Za-z0-9_]+)}", function(key) local value = vars[key]; if value == nil then return "{" .. key .. "}" end; return tostring(value) end))
end
function M.has(key) return locale[key] ~= nil end
function M.t(key, vars)
  local text = locale[key] or fallback[key]
  if text == nil then return key end
  return interpolate(tostring(text), vars)
end
return M
