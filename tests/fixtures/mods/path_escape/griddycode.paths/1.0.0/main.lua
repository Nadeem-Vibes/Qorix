-- Both reads must fail with a structured code before touching the filesystem.

local value, relative_error = editor.assets.read_text("../../secret.txt")
editor.log.info("relative escape: " .. tostring(value) .. " " .. tostring(relative_error and relative_error.code))

local absolute, absolute_error = editor.assets.read_text("/etc/passwd")
editor.log.info("absolute escape: " .. tostring(absolute) .. " " .. tostring(absolute_error and absolute_error.code))
