-- 32 MB is past the 24 MB per-state limit, so this must fail with memory.exceeded
-- rather than growing the editor's RSS.

local big = string.rep("x", 32 * 1024 * 1024)
editor.log.info("allocated " .. tostring(#big))
