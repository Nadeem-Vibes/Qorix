-- Platform Tour: a guided lesson plus self-check for the Developer Preview.
--
-- The lesson is one hybrid exercise: type a manifest id, then add a permissions
-- line. The dock also runs an eight-point self-check over the core API and shows
-- the build label, so the same sample doubles as a hot reload drill.
--
-- Install this under user://mods/griddycode.platform_tour/1.0.0/ and grant
-- documents.read + documents.write. For hot reload, copy it to
-- user://mods_dev/ and start the editor with --mod-dev.

local build = require("build")
if type(build) ~= "table" then
	build = { label = "tour-1" }
end
local Tour = require("tour")

local lesson, lesson_error = Tour.load()
if lesson == nil then
	editor.log.error("Platform Tour: could not load the lesson: " .. Tour.code(lesson_error))
end

local activations = (editor.storage.get("activations", 0) or 0) + 1
editor.storage.set("activations", activations)

local mount_id = nil
local mount_error = nil
local exercise_id = 0
local doc_id = 0
local completions = tonumber(editor.storage.get("completions", 0)) or 0
local status_text = "Ready. Start the lesson or run the self-check."
local hint_text = lesson and lesson.coach or "The lesson failed to load; check the mod log."
local stored_selfcheck = editor.storage.get("selfcheck", "")
local selfcheck_text = type(stored_selfcheck) == "string" and stored_selfcheck or ""

local function join(items, separator)
	local out = ""
	for index, item in ipairs(items) do
		if index > 1 then
			out = out .. separator
		end
		out = out .. item
	end
	return out
end

local function spec()
	local lesson_line = "Lesson unavailable. Check the mod log."
	if lesson ~= nil then
		lesson_line = lesson.title .. " — " .. lesson.summary
	end
	return {
		type = "panel",
		id = "dock",
		title = "Platform Tour",
		children = {
			{ type = "heading", id = "heading", text = "Developer Preview", font_size = 16 },
			{ type = "label", id = "lesson", text = lesson_line },
			{ type = "label", id = "status", text = status_text },
			{
				type = "label",
				id = "build",
				text = "API 1.0  ·  build " .. tostring(build.label)
					.. "  ·  activations: " .. tostring(activations),
			},
			{ type = "label", id = "progress", text = "Lessons completed: " .. tostring(completions) },
			{
				type = "hbox",
				spacing = 6,
				children = {
					{ type = "button", id = "start", text = "Start lesson" },
					{ type = "button", id = "check", text = "Check answer" },
				},
			},
			{
				type = "hbox",
				spacing = 6,
				children = {
					{ type = "button", id = "retry", text = "Retry" },
					{ type = "button", id = "selfcheck", text = "Self-check" },
				},
			},
			{
				type = "hbox",
				spacing = 6,
				children = {
					{ type = "button", id = "strict", text = "Strict typing" },
					{ type = "button", id = "reset", text = "Reset" },
				},
			},
			{ type = "label", id = "selfcheck_result", text = selfcheck_text },
			{ type = "label", id = "hint", text = hint_text, color = "#8a8fa3" },
		},
	}
end

local function refresh()
	if mount_id == nil then
		return
	end
	editor.ui.update(mount_id, spec())
end

local function stop_exercise()
	if exercise_id ~= 0 then
		Tour.stop(exercise_id)
		exercise_id = 0
	end
end

local function start_lesson()
	if lesson == nil then
		editor.ui.notify("Platform Tour: the lesson did not load; check the log.", "error")
		return
	end
	stop_exercise()

	if doc_id ~= 0 and editor.docs.set_text(doc_id, "") == nil then
		doc_id = 0
	end
	if doc_id == 0 then
		local created, create_error = editor.docs.create({ text = "", language = "lua" })
		if created == nil then
			editor.ui.notify(
				"Platform Tour: could not create the lesson document: " .. Tour.code(create_error),
				"error"
			)
			return
		end
		doc_id = created
	end

	editor.docs.reveal(doc_id)
	local strict = editor.settings.get("strict_typing", false) == true
	local started, start_error = Tour.start(lesson, doc_id, strict)
	if started == nil then
		editor.ui.notify(
			"Platform Tour: could not start the lesson: " .. Tour.code(start_error),
			"error"
		)
		return
	end

	exercise_id = tonumber(started.exercise or 0) or 0
	status_text = "Typing phase: enter the manifest id."
	hint_text = "Type the line exactly. Ghost text shows the next character."
	refresh()
	editor.ui.notify("Platform Tour: lesson started. Edit the new document.", "info")
end

local function check_work()
	if exercise_id == 0 then
		editor.ui.notify("Platform Tour: start the lesson first.", "warning")
		return
	end

	local state = Tour.state(exercise_id)
	local status = type(state) == "table" and tostring(state.state or "") or ""
	local phase_kind = type(state) == "table" and tostring(state.phase_kind or "") or ""

	if status == "validating" then
		editor.ui.notify("Platform Tour: checking the answer now.", "info")
		return
	end
	if status == "completed" then
		editor.ui.notify("Platform Tour: this lesson is already complete.", "info")
		return
	end
	if status == "passed" then
		editor.ui.notify("Platform Tour: that step is complete; continue with the next step.", "info")
		return
	end
	if status == "stopped" then
		editor.ui.notify("Platform Tour: the lesson is stopped. Press Retry to try again.", "warning")
		return
	end
	if not Tour.can_check(state) then
		if phase_kind == "typing" and status == "failed" then
			editor.ui.notify("Platform Tour: the typing step did not pass. Press Retry.", "warning")
		elseif phase_kind == "typing" then
			status_text = "Typing phase: finish the manifest id; the lesson advances automatically."
			hint_text = "Ghost text shows the next character. Check answer applies to the permissions step."
			refresh()
			editor.ui.notify(
				"Platform Tour: finish typing the manifest id first. The lesson advances automatically.",
				"info"
			)
		else
			editor.ui.notify("Platform Tour: the lesson is not ready to check yet.", "info")
		end
		return
	end

	local submitted, submit_error = Tour.submit(exercise_id)
	if submitted == nil then
		editor.ui.notify(
			"Platform Tour: could not check the answer: " .. Tour.code(submit_error),
			"error"
		)
		return
	end
	status_text = "Checking the permissions line…"
	refresh()
end

local function retry_lesson()
	if exercise_id == 0 then
		start_lesson()
		return
	end
	local retried, retry_error = Tour.retry(exercise_id)
	if retried == nil then
		editor.ui.notify(
			"Platform Tour: could not retry the lesson: " .. Tour.code(retry_error),
			"error"
		)
		return
	end
	status_text = "Retry: type the manifest id, then add the permission line."
	hint_text = lesson and lesson.coach or ""
	refresh()
end

local function toggle_strict()
	local current = editor.settings.get("strict_typing", false) == true
	local saved = editor.settings.set("strict_typing", not current)
	if saved == nil then
		editor.ui.notify("Platform Tour: could not change the setting.", "error")
		return
	end
	status_text = "Strict typing is " .. (not current and "on" or "off") .. ". Start a lesson to apply it."
	refresh()
end

local function reset_progress()
	stop_exercise()
	completions = 0
	editor.storage.set("completions", 0)
	editor.storage.delete("selfcheck")
	editor.progress.reset("platform_tour")
	selfcheck_text = ""
	status_text = "Progress reset. Start the lesson when ready."
	hint_text = lesson and lesson.coach or ""
	if doc_id ~= 0 and editor.docs.set_text(doc_id, "") == nil then
		doc_id = 0
	end
	refresh()
	editor.ui.notify("Platform Tour: progress reset.", "info")
end

local function run_selfcheck()
	local results = {}
	local function record(name, ok, detail)
		results[#results + 1] = { name = name, ok = ok == true, detail = detail or "" }
	end

	local storage_ok = editor.storage.set("selfcheck.value", "ok") ~= nil
	storage_ok = storage_ok and editor.storage.get("selfcheck.value", nil) == "ok"
	editor.storage.delete("selfcheck.value")
	record("storage", storage_ok)

	local progress_ok = editor.progress.set("selfcheck", 0) ~= nil
	progress_ok = progress_ok and editor.progress.increment("selfcheck", 1) ~= nil
	progress_ok = progress_ok and tonumber(editor.progress.get("selfcheck", -1)) == 1
	editor.progress.reset("selfcheck")
	record("progress", progress_ok)

	local original = editor.settings.get("strict_typing", false) == true
	local settings_ok = editor.settings.set("strict_typing", not original) ~= nil
	settings_ok = settings_ok and editor.settings.get("strict_typing", original) == (not original)
	editor.settings.set("strict_typing", original)
	record("settings", settings_ok)

	local probe = "griddycode.platform_tour.selfcheck_probe"
	local commands_ok = editor.commands.register({
		id = probe,
		label = "Platform Tour: Self-check probe",
		category = "Mods",
		handler = function() end,
	}) ~= nil
	if commands_ok then
		editor.commands.unregister(probe)
	end
	record("commands", commands_ok)

	local subscription = editor.events.on(
		"mod.griddycode.platform_tour.selfcheck_probe",
		function() end
	)
	local events_ok = subscription ~= nil
	if events_ok then
		editor.events.off(subscription)
	end
	record("events", events_ok)

	local scratch, scratch_error = editor.docs.create({ text = "platform tour self-check" })
	local documents_ok = scratch ~= nil
	if scratch ~= nil then
		documents_ok = editor.docs.text(scratch) == "platform tour self-check"
		editor.docs.close(scratch, { force = true })
	end
	record("documents", documents_ok, Tour.code(scratch_error))

	record("permissions", editor.permissions.has("documents.read") == true)
	record("ui", mount_id ~= nil)

	local passed = 0
	local failed = {}
	for _, entry in ipairs(results) do
		if entry.ok then
			passed = passed + 1
		else
			failed[#failed + 1] = entry.name
		end
		editor.log.info(
			"Platform Tour self-check: " .. entry.name .. " = "
				.. (entry.ok and "ok" or "FAILED")
		)
	end

	selfcheck_text = "Self-check: " .. tostring(passed) .. "/" .. tostring(#results) .. " passed"
	if #failed > 0 then
		selfcheck_text = selfcheck_text .. " · failed: " .. join(failed, ", ")
		hint_text = "A failed check usually means a permission or the UI service is unavailable."
	else
		selfcheck_text = selfcheck_text .. " · core surfaces are live."
		hint_text = "Next: the hot reload drill in README.md."
	end
	editor.storage.set("selfcheck", selfcheck_text)
	if doc_id ~= 0 then
		editor.docs.reveal(doc_id)
	end
	refresh()
	editor.ui.notify(selfcheck_text, #failed == 0 and "info" or "warning")
end

mount_id, mount_error = editor.ui.mount("right", spec())
if mount_id == nil then
	editor.log.error(
		"Platform Tour: could not mount its dock: " .. Tour.code(mount_error)
	)
else
	-- Widget events use the child's local id. mount_id is the panel id and is
	-- not a prefix for its children.
	local handlers = {
		{ id = "start", fn = start_lesson },
		{ id = "check", fn = check_work },
		{ id = "retry", fn = retry_lesson },
		{ id = "selfcheck", fn = run_selfcheck },
		{ id = "strict", fn = toggle_strict },
		{ id = "reset", fn = reset_progress },
	}
	for _, entry in ipairs(handlers) do
		local subscribed, subscribe_error = editor.ui.on(entry.id, "click", entry.fn)
		if subscribed == nil then
			editor.log.error(
				"Platform Tour: could not bind the " .. entry.id .. " button: "
					.. Tour.code(subscribe_error)
			)
		end
	end
end

local commands = {
	{
		id = "griddycode.platform_tour.start",
		label = "Platform Tour: Start Lesson",
		handler = start_lesson,
	},
	{
		id = "griddycode.platform_tour.check",
		label = "Platform Tour: Check Answer",
		handler = check_work,
	},
	{
		id = "griddycode.platform_tour.selfcheck",
		label = "Platform Tour: Run Self-check",
		handler = run_selfcheck,
	},
	{
		id = "griddycode.platform_tour.reset",
		label = "Platform Tour: Reset Progress",
		handler = reset_progress,
	},
}
for _, command in ipairs(commands) do
	local registered, register_error = editor.commands.register({
		id = command.id,
		label = command.label,
		category = "Mods",
		handler = command.handler,
	})
	if registered == nil then
		editor.log.error(
			"Platform Tour: could not register " .. command.id .. ": "
				.. Tour.code(register_error)
		)
	end
end

editor.events.on("exercise.phase_changed", function(payload)
	if type(payload) ~= "table" or tonumber(payload.exercise or 0) ~= exercise_id then
		return
	end
	status_text = "Typing done. Add the permission line, then Check answer."
	hint_text = lesson and lesson.freeform.hint or ""
	refresh()
end)

editor.events.on("exercise.completed", function(payload)
	if type(payload) ~= "table" or tonumber(payload.exercise or 0) ~= exercise_id then
		return
	end
	completions = completions + 1
	editor.storage.set("completions", completions)
	editor.progress.set("platform_tour", 1)
	exercise_id = 0
	status_text = "Lesson complete. You wrote a manifest fragment and passed a validation."
	hint_text = "Next: run the self-check, then try the hot reload drill in README.md."
	refresh()
	editor.ui.notify("Platform Tour complete. Run the self-check next.", "info")
end)

editor.events.on("exercise.failed", function(payload)
	if type(payload) ~= "table" or tonumber(payload.exercise or 0) ~= exercise_id then
		return
	end
	if tonumber(payload.phase or 0) == 0 then
		status_text = "Not yet. Type the manifest id exactly, then Retry."
		hint_text = "The id is example.hello, inside double quotes."
	else
		status_text = 'Not yet. Add permissions = { "core", "documents.read" }, then Check answer.'
		hint_text = lesson and lesson.freeform.hint or ""
	end
	refresh()
end)

editor.events.on("exercise.stopped", function(payload)
	if type(payload) ~= "table" or tonumber(payload.exercise or 0) ~= exercise_id then
		return
	end
	exercise_id = 0
	status_text = "Lesson stopped. Start again when ready."
	refresh()
end)

function deactivate()
	stop_exercise()
	if mount_id ~= nil then
		editor.ui.unmount(mount_id)
		mount_id = nil
	end
end
