-- `coroutine` is absent from the mod environment, so this fails at the lookup
-- instead of starting an unhooked thread.

local ok, err = pcall(function()
	local co = coroutine.create(function()
		while true do end
	end)
	coroutine.resume(co)
end)

editor.log.info("nested coroutine: " .. tostring(ok) .. " " .. tostring(err))
