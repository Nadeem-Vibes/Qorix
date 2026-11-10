local M = {}
local PREFIX = "cpp_journey/"
local EXT = ".cpp"
function M.find(items, id) for _, item in ipairs(items or {}) do if item.id == id then return item end end return nil end
function M.position(items, id) for i, item in ipairs(items or {}) do if item.id == id then return i end end return 0 end
function M.next(items, id) local p = M.position(items, id); if p > 0 and p < #items then return items[p + 1] end return nil end
function M.previous(items, id) local p = M.position(items, id); if p > 1 then return items[p - 1] end return nil end
function M.first_incomplete(items, done) for _, item in ipairs(items or {}) do if not done(item.id) then return item end end return nil end
function M.file_path(lesson) return PREFIX .. tostring((lesson and lesson.id) or "") .. EXT end
return M
