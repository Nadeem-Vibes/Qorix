-- No `run` permission is declared, so the facade must refuse with permission.denied.

local value, err = editor.run.active({})

editor.log.info("run refusal: " .. tostring(value) .. " " .. tostring(err and err.code))
