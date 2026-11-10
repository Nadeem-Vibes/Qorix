-- C++ Learning Journey: five lessons, course navigation, progress, hints,
-- accessibility text and a partial-UI fallback.
--
-- The mod owns the screen when ui.shell is granted. If it is not, or if the
-- takeover fails, the same lesson flow runs from a side panel and the panel
-- says exactly why. Each lesson is one hybrid exercise: a typing phase owned by
-- editor.guide, then a freeform phase checked by editor.exercise. Freeform
-- validation runs the saved file when a trusted workspace is available and
-- falls back to text checks otherwise.
--
-- Content lives in content/lessons/*.lua; runtime strings live in
-- content/locales/en.lua (the JSON file at locales/en.json is the translator
-- template). Nothing in the shell layout is lesson-specific.

local I18n = require("i18n")
local Course = require("course")
local Progress = require("progress")
local Engine = require("engine")
local Layout = require("layout")

local lessons = {}
local current = nil
local open_lesson
local doc_id = 0
local exercise_id = 0
local last_state = nil

local view_mode = "idle" -- idle | shell | partial
local shell_open = false
local partial_mount = nil
local partial_reason = ""
local course_active = false
local onboarding_open = false

local status_text = ""
local hint_text = ""
local run_ready = false
local run_reason_key = "course.run.no_file"
local use_run = false

local function t(key, vars)
	return I18n.t(key, vars)
end

local function notify(text, level)
	editor.ui.notify(tostring(text or ""), level or "info")
end

local function code_of(err)
	return tostring(err and err.code or "unknown")
end

local function setting(key, fallback)
	local value = editor.settings.get(key, fallback)
	if value == nil then
		return fallback
	end
	return value
end

local function lesson_font_size()
	local value = tonumber(setting("font_size", 16)) or 16
	return math.max(12, math.min(32, value))
end

local function strict_mode()
	return setting("strict_mode", true) == true
end

local function hints_enabled()
	return setting("show_hints", true) == true
end

local function map_error(err)
	local code = code_of(err)
	if code == "workspace.required" then
		return "course.run.no_workspace"
	end
	if code == "trust.required" then
		return "course.run.no_trust"
	end
	if code == "permission.denied" then
		return "course.run.no_permission"
	end
	return "course.run.no_file"
end

local function run_note()
	if use_run then
		return t("course.run.ready")
	end
	return t("course.status.no_run", { reason = t(run_reason_key) }) .. " " .. t("course.run.why")
end

local function sync_exercise_state()
	if exercise_id == 0 then
		last_state = nil
		return
	end
	local snapshot = Engine.state(exercise_id)
	if type(snapshot) == "table" then
		if tonumber(snapshot.exercise or 0) == 0 then
			exercise_id = 0
			last_state = nil
		else
			last_state = snapshot
		end
	end
end

local function stop_exercise()
	if exercise_id ~= 0 then
		Engine.stop(exercise_id, "Lesson paused.")
		exercise_id = 0
	end
	last_state = nil
end

local function current_step()
	return Engine.step(last_state)
end

local function build_view_state()
	sync_exercise_state()

	local completed = Progress.completed_map(lessons)
	local typed = Progress.typed_map(lessons)
	local done_count = 0
	for _, entry in ipairs(lessons) do
		if completed[entry.id] then
			done_count = done_count + 1
		end
	end

	local step = current_step()
	local phase = Engine.phase_kind(last_state)
	local status = status_text
	if type(last_state) == "table" then
		local session = tostring(last_state.state or "")
		if session == "validating" then
			status = t("course.status.checking")
		elseif session == "completed" then
			status = t("course.status.passed")
		elseif session == "failed" then
			status = t("course.status.failed")
		elseif session == "stopped" then
			status = t("course.status.stopped")
		end
	end
	if type(status) ~= "string" or status == "" then
		if step == "done" then
			status = t("course.status.passed")
		elseif phase == "typing" then
			status = t("course.status.typing")
		elseif phase == "freeform" then
			status = t("course.status.typing_done")
		else
			status = t("course.status.ready")
		end
	end

	local previous_lesson = nil
	local next_lesson = nil
	if current ~= nil then
		previous_lesson = Course.previous(lessons, current.id)
		next_lesson = Course.next(lessons, current.id)
	end

	local can_start = current ~= nil and (
		exercise_id == 0 or step == "ready" or step == "done" or
		(type(last_state) == "table" and tostring(last_state.state or "") == "stopped")
	)

	return {
		lessons = lessons,
		lesson = current,
		completed = completed,
		typed = typed,
		done_count = done_count,
		total = #lessons,
		step = step,
		status = status,
		hint = hint_text,
		prompt = current and Engine.prompt_for(current, step) or "",
		target = current and Engine.target_for(current, step) or "",
		use_run = use_run,
		run_note = run_note(),
		font_size = lesson_font_size(),
		can_start = can_start,
		can_check = exercise_id ~= 0 and Engine.can_check(last_state),
		can_retry = exercise_id ~= 0 and Engine.can_retry(last_state),
		can_hint = current ~= nil,
		can_next_lesson = step == "done" and next_lesson ~= nil,
		nav_previous = previous_lesson ~= nil,
		nav_next = next_lesson ~= nil,
		has_exercise = exercise_id ~= 0,
		partial_reason = partial_reason,
	}
end

local function bind_actions()
	editor.ui.on("help", "click", function() show_help() end)
	editor.ui.on("leave", "click", function() leave_course() end)
	editor.ui.on("start", "click", function() start_exercise() end)
	editor.ui.on("check", "click", function() check_work() end)
	editor.ui.on("hint", "click", function() show_hint() end)
	editor.ui.on("retry", "click", function() retry_step() end)
	editor.ui.on("next_lesson", "click", function() next_lesson() end)
	editor.ui.on("previous", "click", function() previous_lesson() end)
	editor.ui.on("next", "click", function() next_lesson() end)
	for _, entry in ipairs(lessons) do
		local id = entry.id
		editor.ui.on("lesson_" .. id, "click", function() open_lesson(id) end)
	end
end

local function mount_partial()
	partial_reason = partial_reason or t("partial.reason.permission")
	local spec = Layout.partial(build_view_state())
	if partial_mount ~= nil then
		local updated = editor.ui.update(partial_mount, spec)
		if updated ~= nil then
			bind_actions()
			return true
		end
		partial_mount = nil
	end

	local id, err = editor.ui.mount("right", spec)
	if id == nil then
		id, err = editor.ui.mount("center", spec)
	end
	if id == nil then
		return nil, err
	end
	partial_mount = id
	bind_actions()
	return true
end

local function enter_partial(reason)
	if shell_open then
		editor.ui.shell.exit("Switching to the side panel.")
		shell_open = false
	end
	view_mode = "partial"
	partial_reason = reason or t("partial.reason.permission")
	local ok, err = mount_partial()
	if ok == nil then
		view_mode = "idle"
		notify(t("partial.reason.slot", { code = code_of(err) }), "error")
	end
end

local function refresh()
	if view_mode == "shell" then
		local taken, err = editor.ui.shell.takeover({ layout = Layout.full(build_view_state()) })
		if taken == nil then
			enter_partial(t("partial.reason.failed", { code = code_of(err) }))
			return
		end
		shell_open = true
		bind_actions()
	elseif view_mode == "partial" then
		local ok, err = mount_partial()
		if ok == nil then
			view_mode = "idle"
			notify(t("partial.reason.slot", { code = code_of(err) }), "error")
		end
	end
end

local function open_document(lesson)
	local path = Course.file_path(lesson)
	local reason = nil
	local has_workspace, workspace_error = editor.workspace.has_workspace()
	if has_workspace == nil then
		reason = map_error(workspace_error)
	elseif has_workspace ~= true then
		reason = "course.run.no_workspace"
	else
		local exists, exists_error = editor.files.exists(path)
		if exists == nil then
			reason = map_error(exists_error)
		else
			if not exists then
				local wrote, write_error = editor.files.write(path, lesson.starter or "")
				if wrote == nil then
					reason = map_error(write_error)
				end
			end
			if reason == nil then
				local opened, open_error = editor.docs.open(path)
				if type(opened) == "number" then
					editor.docs.reveal(opened)
					return opened, true, "course.run.ready"
				end
				reason = map_error(open_error)
			end
		end
	end

	local created, create_error = editor.docs.create({ text = lesson.starter or "" })
	if type(created) ~= "number" then
		notify(t("notice.no_documents"), "error")
		editor.log.error("C++ Journey: could not create a lesson document: " .. code_of(create_error))
		return 0, false, reason or "course.run.no_file"
	end
	editor.docs.reveal(created)
	notify(t("course.notice.text_check"), "warning")
	return created, false, reason or "course.run.no_file"
end

function open_lesson(id)
	local entry = Course.find(lessons, id)
	if entry == nil then
		notify(t("notice.no_lesson"), "warning")
		return
	end

	stop_exercise()
	current = entry
	doc_id = 0
	use_run = false
	status_text = t("course.status.ready")
	hint_text = ""

	doc_id, run_ready, run_reason_key = open_document(entry)
	if doc_id == 0 then
		return
	end

	if hints_enabled() then
		hint_text = Engine.hint_for(entry, "ready")
	end
	Progress.set_last(entry.id)
	refresh()
end

function show_help()
	local id = editor.ui.dialog({
		title = t("course.help.title"),
		buttons = {
			{ id = "close", label = t("course.help.close"), primary = true },
		},
		body = {
			type = "vbox",
			spacing = 6,
			children = {
				{ type = "label", text = t("course.help.body") },
				{ type = "label", text = t("onboarding.bullet.files") },
				{ type = "label", text = t("onboarding.bullet.fallback") },
				{ type = "label", text = t("onboarding.bullet.keyboard") },
			},
		},
	})
	if id == nil then
		notify(t("notice.help_fallback"), "info")
	end
end

function start_exercise()
	if current == nil then
		notify(t("notice.no_course"), "warning")
		return
	end
	if doc_id == 0 then
		doc_id, run_ready, run_reason_key = open_document(current)
		if doc_id == 0 then
			return
		end
	end

	stop_exercise()
	editor.docs.set_text(doc_id, current.starter or "")
	editor.docs.reveal(doc_id)
	use_run = run_ready and editor.permissions.has("run")
	if run_ready and not use_run then
		run_reason_key = "course.run.no_permission"
	end

	local started, err = Engine.start(current, doc_id, use_run, strict_mode())
	if started == nil then
		notify("Could not start the exercise: " .. code_of(err), "error")
		return
	end

	exercise_id = tonumber(started.exercise or 0) or 0
	last_state = started
	status_text = t("course.status.typing")
	hint_text = ""
	if hints_enabled() then
		hint_text = Engine.hint_for(current, "typing")
	end
	Progress.set_last(current.id)
	refresh()
end

function check_work()
	if exercise_id == 0 or current == nil then
		notify(t("course.status.no_attempt"), "warning")
		return
	end
	local snapshot = Engine.state(exercise_id)
	if type(snapshot) == "table" and tostring(snapshot.state or "") == "validating" then
		notify(t("course.notice.checking"), "info")
		return
	end
	if type(snapshot) == "table" and tostring(snapshot.state or "") == "completed" then
		notify(t("course.status.passed"), "info")
		return
	end

	local submitted, err = Engine.submit(exercise_id)
	if submitted == nil then
		notify("Could not submit the exercise: " .. code_of(err), "error")
		return
	end

	local state = Engine.state(exercise_id)
	last_state = type(state) == "table" and state or submitted
	if Engine.is_pending(last_state) or tostring(submitted.status or "") == "pending" then
		status_text = t("course.status.checking")
		notify(t("course.notice.checking"), "info")
	elseif Engine.is_done(last_state) then
		status_text = t("course.status.passed")
	elseif Engine.is_failed(last_state) then
		status_text = t("course.status.failed")
		notify(t("course.notice.failed"), "warning")
	end
	refresh()
end

function retry_step()
	if exercise_id == 0 or current == nil then
		notify(t("course.status.no_attempt"), "warning")
		return
	end
	local retried, err = Engine.retry(exercise_id)
	if retried == nil then
		notify("Could not retry the step: " .. code_of(err), "error")
		return
	end
	local state = Engine.state(exercise_id)
	last_state = type(state) == "table" and state or retried
	local step = current_step()
	status_text = step == "typing" and t("course.status.typing") or t("course.status.typing_done")
	hint_text = ""
	if hints_enabled() then
		hint_text = Engine.hint_for(current, step)
	end
	refresh()
end

function show_hint()
	if current == nil then
		notify(t("notice.no_course"), "warning")
		return
	end
	local text = Engine.hint_for(current, current_step())
	if exercise_id ~= 0 then
		Engine.hint(exercise_id, text)
	else
		notify(text, "info")
	end
	hint_text = text
	refresh()
end

function next_lesson()
	if current == nil then
		notify(t("notice.no_course"), "warning")
		return
	end
	local entry = Course.next(lessons, current.id)
	if entry == nil then
		notify(t("notice.no_next"), "info")
		return
	end
	open_lesson(entry.id)
end

function previous_lesson()
	if current == nil then
		notify(t("notice.no_course"), "warning")
		return
	end
	local entry = Course.previous(lessons, current.id)
	if entry == nil then
		notify(t("notice.no_previous"), "info")
		return
	end
	open_lesson(entry.id)
end

function leave_course()
	stop_exercise()
	if shell_open then
		editor.ui.shell.exit("Course closed.")
		shell_open = false
	end
	if partial_mount ~= nil then
		editor.ui.unmount(partial_mount)
		partial_mount = nil
	end
	view_mode = "idle"
	course_active = false
	current = nil
	doc_id = 0
	notify(t("notice.leave"), "info")
end

local function complete_onboarding(start)
	Progress.mark_onboarding()
	onboarding_open = false
	if start then
		course_active = true
		if not editor.permissions.has("ui.shell") then
			view_mode = "partial"
			partial_reason = t("partial.reason.permission")
		else
			view_mode = "shell"
		end
		local start_lesson = Course.find(lessons, Progress.last_id())
		if start_lesson == nil then
			start_lesson = Course.first_incomplete(lessons, Progress.done)
		end
		if start_lesson == nil then
			start_lesson = lessons[1]
		end
		if start_lesson ~= nil then
			open_lesson(start_lesson.id)
		end
	else
		notify(t("onboarding.later_notice"), "info")
	end
end

local function show_onboarding()
	onboarding_open = true
	local id = editor.ui.dialog({
		title = t("onboarding.title"),
		message = t("onboarding.body"),
		buttons = {
			{ id = "later", label = t("onboarding.later") },
			{ id = "start", label = t("onboarding.start"), primary = true },
		},
		body = {
			type = "vbox",
			spacing = 4,
			children = {
				{ type = "label", text = t("onboarding.bullet.files") },
				{ type = "label", text = t("onboarding.bullet.fallback") },
				{ type = "label", text = t("onboarding.bullet.keyboard") },
			},
		},
	})
	if id == nil then
		complete_onboarding(true)
		return
	end
	editor.ui.on(id, "click", function(payload)
		local button = "start"
		if type(payload) == "table" and type(payload.button) == "string" then
			button = payload.button
		end
		complete_onboarding(button == "start")
	end)
end

local function load_course()
	if #lessons > 0 then
		return true
	end
	local loaded, err = Course.load()
	if loaded == nil then
		notify(t("notice.no_content") .. " (" .. code_of(err) .. ")", "error")
		return false
	end
	lessons = loaded
	if #lessons == 0 then
		notify(t("notice.no_content"), "error")
		return false
	end
	return true
end

function open_course()
	if not load_course() then
		return
	end
	if course_active and view_mode ~= "idle" then
		refresh()
		return
	end
	if onboarding_open then
		notify(t("onboarding.later_notice"), "info")
		return
	end
	if not Progress.onboarding_seen() then
		show_onboarding()
		return
	end

	course_active = true
	if not editor.permissions.has("ui.shell") then
		view_mode = "partial"
		partial_reason = t("partial.reason.permission")
	else
		view_mode = "shell"
	end

	local start_lesson = Course.find(lessons, Progress.last_id())
	if start_lesson == nil then
		start_lesson = Course.first_incomplete(lessons, Progress.done)
	end
	if start_lesson == nil then
		start_lesson = lessons[1]
	end
	if start_lesson ~= nil then
		open_lesson(start_lesson.id)
	end
end

editor.events.on("exercise.phase_changed", function(payload)
	if type(payload) ~= "table" or current == nil then
		return
	end
	if tonumber(payload.exercise or 0) ~= exercise_id then
		return
	end
	if tonumber(payload.phase or 0) == 1 then
		Progress.mark_typed(current.id)
		sync_exercise_state()
		status_text = t("course.status.typing_done")
		hint_text = ""
		if hints_enabled() then
			hint_text = Engine.hint_for(current, "freeform")
		end
		notify(t("course.notice.typing_done"), "info")
		refresh()
	end
end)

editor.events.on("exercise.completed", function(payload)
	if type(payload) ~= "table" or current == nil then
		return
	end
	if tonumber(payload.exercise or 0) ~= exercise_id then
		return
	end
	Progress.mark_typed(current.id)
	Progress.mark_done(current.id)
	sync_exercise_state()
	status_text = t("course.status.passed")
	hint_text = ""
	notify(t("course.notice.passed"), "info")
	refresh()
end)

editor.events.on("exercise.failed", function(payload)
	if type(payload) ~= "table" or current == nil then
		return
	end
	if tonumber(payload.exercise or 0) ~= exercise_id then
		return
	end
	sync_exercise_state()
	status_text = t("course.status.failed")
	hint_text = ""
	if hints_enabled() then
		hint_text = Engine.hint_for(current, current_step())
	end
	notify(t("course.notice.failed"), "warning")
	refresh()
end)

editor.events.on("exercise.stopped", function(payload)
	if type(payload) ~= "table" or current == nil then
		return
	end
	if tonumber(payload.exercise or 0) ~= exercise_id then
		return
	end
	status_text = t("course.status.stopped")
	refresh()
end)

editor.commands.register({
	id = "griddycode.cpp_journey.open",
	label = "C++ Journey: Open Course",
	category = "Mods",
	handler = open_course,
})

editor.commands.register({
	id = "griddycode.cpp_journey.next",
	label = "C++ Journey: Next Lesson",
	category = "Mods",
	handler = next_lesson,
})

editor.commands.register({
	id = "griddycode.cpp_journey.previous",
	label = "C++ Journey: Previous Lesson",
	category = "Mods",
	handler = previous_lesson,
})

editor.commands.register({
	id = "griddycode.cpp_journey.hint",
	label = "C++ Journey: Show Hint",
	category = "Mods",
	handler = show_hint,
})

editor.commands.register({
	id = "griddycode.cpp_journey.help",
	label = "C++ Journey: Help",
	category = "Mods",
	handler = show_help,
})

editor.commands.register({
	id = "griddycode.cpp_journey.leave",
	label = "C++ Journey: Leave Course",
	category = "Mods",
	handler = leave_course,
})

local bindings = {
	{ "griddycode.cpp_journey.open", "Ctrl+Alt+C" },
	{ "griddycode.cpp_journey.next", "Ctrl+Alt+Shift+N" },
	{ "griddycode.cpp_journey.previous", "Ctrl+Alt+Shift+B" },
	{ "griddycode.cpp_journey.hint", "Ctrl+Alt+Shift+H" },
}
for _, entry in ipairs(bindings) do
	local bound, bind_error = editor.keys.bind(entry[1], entry[2])
	if bound == nil then
		editor.log.warn("C++ Journey: could not bind " .. entry[2] .. ": " .. code_of(bind_error))
	end
end

function deactivate()
	stop_exercise()
	if shell_open then
		editor.ui.shell.exit("Mod deactivated.")
		shell_open = false
	end
	if partial_mount ~= nil then
		editor.ui.unmount(partial_mount)
		partial_mount = nil
	end
	view_mode = "idle"
	course_active = false
	current = nil
end
