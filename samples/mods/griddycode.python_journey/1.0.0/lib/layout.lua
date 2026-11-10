-- Pure layout builders for the full shell and the partial fallback.
--
-- The host rebuilds shell widgets from scratch on takeover; a partial mount is
-- reconciled with ui.update. Both paths use the same state table, so a lesson
-- looks the same in either place. No handler is bound here: main.lua binds ids
-- after every build.

local I18n = require("i18n")

local M = {}

local function t(key, vars)
	return I18n.t(key, vars)
end

local function step_name(step)
	if step == "typing" then
		return t("course.step.typing")
	end
	if step == "freeform" then
		return t("course.step.freeform")
	end
	if step == "checking" then
		return t("course.step.checking")
	end
	if step == "done" then
		return t("course.step.done")
	end
	return t("course.ready")
end

local function lesson_status(state, entry)
	if state.completed[entry.id] then
		return t("course.done")
	end
	if state.lesson ~= nil and state.lesson.id == entry.id then
		return t("course.current")
	end
	if state.typed[entry.id] then
		return t("course.step.freeform")
	end
	return t("course.not_started")
end

local function lesson_label(state, entry)
	if state.completed[entry.id] then
		return "[x] " .. tostring(entry.number) .. ". " .. entry.title
	end
	if state.lesson ~= nil and state.lesson.id == entry.id then
		return "> " .. tostring(entry.number) .. ". " .. entry.title
	end
	return tostring(entry.number) .. ". " .. entry.title
end

local function lesson_button(state, entry)
	local status = lesson_status(state, entry)
	return {
		type = "button",
		id = "lesson_" .. entry.id,
		text = lesson_label(state, entry),
		tooltip = t("a11y.lesson_button", {
			number = entry.number,
			title = entry.title,
			status = status,
		}),
	}
end

local function lesson_buttons(state)
	local out = {}
	for _, entry in ipairs(state.lessons) do
		table.insert(out, lesson_button(state, entry))
	end
	return out
end

local function progress_percent(state)
	if state.total <= 0 then
		return 0
	end
	return math.floor(state.done_count * 100 / state.total)
end

local function run_badge(state)
	if state.use_run then
		return t("course.run.badge")
	end
	return t("course.text.badge")
end

local function action_button(id, text, tooltip, disabled)
	local spec = { type = "button", id = id, text = text, tooltip = tooltip }
	if disabled then
		spec.disabled = true
	end
	return spec
end

local function coach_actions(state)
	local primary = {}
	if state.can_start then
		table.insert(primary, action_button(
			"start",
			state.has_exercise and t("course.restart") or t("course.start"),
			state.has_exercise and t("course.restart.tooltip") or t("course.start.tooltip"),
			false
		))
	end
	if state.can_check then
		table.insert(primary, action_button("check", t("course.check"), t("course.check.tooltip"), false))
	end
	if state.can_hint then
		table.insert(primary, action_button("hint", t("course.hint"), t("course.hint.tooltip"), false))
	end

	local secondary = {}
	if state.can_retry then
		table.insert(secondary, action_button("retry", t("course.retry"), t("course.retry.tooltip"), false))
	end
	if state.can_next_lesson then
		table.insert(secondary, action_button("next_lesson", t("course.next"), t("course.next.tooltip"), false))
	end

	return primary, secondary
end

local function target_label(state)
	if state.step == "freeform" or state.step == "checking" then
		return t("coach.example")
	end
	return t("coach.target")
end

local function hint_text(state)
	if type(state.hint) == "string" and state.hint ~= "" then
		return state.hint
	end
	return t("coach.no_hint")
end

function M.full(state)
	local fs = state.font_size or 16
	local small = math.max(11, fs - 2)
	local code_size = math.max(11, fs - 3)
	local lesson = state.lesson
	local title = lesson and lesson.title or t("app.title")
	local summary = lesson and lesson.summary or ""
	local percent = progress_percent(state)
	local primary, secondary = coach_actions(state)

	local actions = {}
	if #primary > 0 then
		table.insert(actions, { type = "hbox", id = "coach_primary", spacing = 6, children = primary })
	end
	if #secondary > 0 then
		table.insert(actions, { type = "hbox", id = "coach_secondary", spacing = 6, children = secondary })
	end

	return {
		type = "vbox",
		id = "course_shell",
		spacing = 8,
		children = {
			{
				type = "hbox",
				id = "course_top",
				spacing = 10,
				children = {
					{ type = "label", id = "course_title", text = t("app.title"), font_size = fs + 2 },
					{
						type = "progress",
						id = "course_progress",
						value = percent,
						max = 100,
						width = 180,
						tooltip = t("a11y.progress", { done = state.done_count, total = state.total }),
					},
					{
						type = "label",
						id = "progress_text",
						text = t("course.progress", { done = state.done_count, total = state.total }),
						font_size = small,
					},
					{ type = "spacer", id = "top_push", grow = 1 },
					action_button("help", t("course.help"), t("course.help.tooltip"), false),
					action_button("leave", t("course.leave"), t("course.leave.tooltip"), false),
				},
			},
			{
				type = "hbox",
				id = "course_body",
				grow = 1,
				spacing = 10,
				children = {
					{
						type = "panel",
						id = "lesson_list",
						width = 290,
						title = t("course.lesson_list"),
						children = (function()
							local children = lesson_buttons(state)
							table.insert(children, { type = "separator", id = "nav_separator" })
							table.insert(children, {
								type = "hbox",
								id = "nav_row",
								spacing = 6,
								children = {
									action_button("previous", t("course.previous"), t("course.previous.tooltip"), not state.nav_previous),
									action_button("next", t("course.next"), t("course.next.tooltip"), not state.nav_next),
								},
							})
							table.insert(children, { type = "spacer", id = "lesson_push", grow = 1 })
							table.insert(children, { type = "badge", id = "check_mode", text = run_badge(state) })
							table.insert(children, {
								type = "label",
								id = "run_note",
								text = state.run_note or "",
								font_size = small,
							})
							return children
						end)(),
					},
					{
						-- The editor rectangle must stay outside every panel: a panel's
						-- background is opaque and would cover the real CodeEdit behind
						-- the shell. The heading gets its own panel above the code.
						type = "vbox",
						id = "workspace",
						grow = 1,
						spacing = 6,
						children = {
							{
								type = "panel",
								id = "lesson_header",
								children = {
									{ type = "heading", id = "lesson_title", text = title, font_size = fs + 4 },
									{ type = "label", id = "lesson_summary", text = summary, font_size = fs },
									{
										type = "hbox",
										id = "meta_row",
										spacing = 6,
										children = {
											{ type = "badge", id = "step_badge", text = step_name(state.step) },
											{ type = "badge", id = "mode_badge", text = run_badge(state) },
										},
									},
								},
							},
							{ type = "editor", id = "code", grow = 1 },
						},
					},
					{
						type = "panel",
						id = "coach",
						width = 340,
						title = t("coach.title"),
						children = {
							{
								type = "label",
								id = "coach_step",
								text = t("coach.step", { index = 1, total = 2, kind = step_name(state.step) }),
								font_size = small,
							},
							{ type = "label", id = "coach_prompt", text = state.prompt or "", font_size = fs },
							{ type = "separator", id = "coach_separator" },
							{ type = "label", id = "coach_target_label", text = target_label(state), font_size = small },
							{ type = "code_block", id = "coach_target", text = state.target or "", font_size = code_size },
							{ type = "label", id = "coach_status", text = state.status or "", font_size = small },
							{
								type = "label",
								id = "coach_hint",
								text = t("coach.hint") .. ": " .. hint_text(state),
								font_size = small,
							},
							{ type = "label", id = "coach_note", text = state.run_note or "", font_size = code_size },
							{ type = "spacer", id = "coach_push", grow = 1 },
							table.unpack(actions),
						},
					},
				},
			},
		},
	}
end

function M.partial(state)
	local fs = math.max(12, (state.font_size or 16) - 2)
	local lesson = state.lesson
	local title = lesson and lesson.title or t("app.title")
	local percent = progress_percent(state)
	local primary, secondary = coach_actions(state)

	local children = {
		{ type = "label", id = "partial_reason", text = state.partial_reason or "", font_size = fs },
		{ type = "label", id = "partial_why", text = t("partial.why"), font_size = fs - 1 },
		{ type = "separator", id = "partial_sep1" },
		{ type = "label", id = "partial_lesson", text = title, font_size = fs + 2 },
		{ type = "label", id = "partial_summary", text = lesson and lesson.summary or "", font_size = fs - 1 },
		{
			type = "progress",
			id = "partial_progress",
			value = percent,
			max = 100,
			tooltip = t("a11y.progress", { done = state.done_count, total = state.total }),
		},
		{
			type = "label",
			id = "partial_progress_text",
			text = t("course.progress", { done = state.done_count, total = state.total }),
			font_size = fs - 1,
		},
		{ type = "separator", id = "partial_sep2" },
	}

	for _, entry in ipairs(state.lessons) do
		table.insert(children, lesson_button(state, entry))
	end

	table.insert(children, { type = "separator", id = "partial_sep3" })
	table.insert(children, {
		type = "label",
		id = "partial_status",
		text = state.status or "",
		font_size = fs - 1,
	})
	table.insert(children, {
		type = "label",
		id = "partial_note",
		text = state.run_note or "",
		font_size = fs - 2,
	})

	for _, button in ipairs(primary) do
		table.insert(children, button)
	end
	for _, button in ipairs(secondary) do
		table.insert(children, button)
	end

	table.insert(children, action_button("help", t("course.help"), t("course.help.tooltip"), false))
	table.insert(children, action_button("leave", t("course.leave"), t("course.leave.tooltip"), false))

	return {
		type = "panel",
		id = "course_panel",
		title = t("partial.title"),
		spacing = 6,
		children = children,
	}
end

return M
