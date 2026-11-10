-- The protected pcall must rethrow the sentinel, so activation still dies.

pcall(function()
	while true do end
end)
