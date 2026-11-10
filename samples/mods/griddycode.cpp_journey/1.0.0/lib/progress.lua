local M = {}
function M.mark_typed(id) editor.progress.set("lessons." .. id .. ".typed", true) end
function M.mark_done(id) editor.progress.set("lessons." .. id .. ".done", true) end
function M.is_done(id) return editor.progress.get("lessons." .. id .. ".done", false) == true end
return M
