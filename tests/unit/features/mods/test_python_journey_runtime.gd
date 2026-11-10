extends "res://tests/support/test_case.gd"

## Phase 4 runtime suite: executes the reference mod against a hand-written Lua
## stub of the sandbox surface. Compilation alone cannot catch a missing module
## table or a forward declaration used before it is assigned, so this suite
## drives onboarding, a lesson, both hybrid phases, navigation, failure/retry,
## commands, deactivation and the partial-UI fallback through main.lua.

const ROOT := "res://samples/mods/griddycode.python_journey/1.0.0"


func test_main_runtime_flow_against_a_sandbox_stub() -> void:
	var lua = LuaAPI.new()
	lua.bind_libraries(["base", "table", "string", "math", "utf8", "coroutine", "debug"])
	lua.push_variant("__read", func(relative: String) -> String:
		return FileAccess.get_file_as_string(ROOT.path_join(relative))
	)
	var err: Variant = lua.do_string("""
		local modules = {}
		local function load_module(kind, path)
			local key = kind .. ":" .. path
			if modules[key] ~= nil then return modules[key] end
			local relative = kind .. "/" .. path
			if path:match("%.lua$") == nil then relative = relative .. ".lua" end
			local source = __read(relative)
			assert(source ~= "", "missing " .. key)
			local chunk = assert(load(source, "@" .. path))
			modules[key] = chunk()
			return modules[key]
		end
		function require(path) return load_module("lib", path) end

		local state = { progress = {}, exercise_state = nil, workspace = false }
		local ui_handlers = {}
		local events = {}
		local commands = {}
		local dialogs = {}
		local notifications = {}
		local command_count = 0

		local function remember(target, key, value)
			target[key] = target[key] or {}
			table.insert(target[key], value)
		end

		editor = {
			log = {
				info = function(message) end,
				warn = function(message) end,
				error = function(message) error("log.error: " .. tostring(message)) end,
			},
			content = { load = function(path) return load_module("content", path) end },
			settings = { get = function(key, fallback) return fallback end },
			permissions = { has = function(name) return true end },
			workspace = { has_workspace = function() return state.workspace end },
			files = {
				exists = function(path) return state.file_exists == true end,
				write = function(path, text) state.written = path; return true end,
			},
			docs = {
				create = function(spec) state.doc_text = spec.text or ""; return 1 end,
				open = function(path) return nil, { code = "workspace.required" } end,
				reveal = function(id) return true end,
				set_text = function(id, text) state.doc_text = text; return true end,
			},
			progress = {
				get = function(key, fallback)
					local value = state.progress[key]
					if value == nil then return fallback end
					return value
				end,
				set = function(key, value) state.progress[key] = value; return true end,
				reset = function(key) state.progress[key] = nil; return true end,
			},
			events = {
				on = function(name, fn) remember(events, name, fn); return name end,
			},
			commands = {
				register = function(spec) remember(commands, spec.id, spec); return spec.id end,
			},
			keys = { bind = function(id, chord) return true end },
			ui = {
				notify = function(text, level) table.insert(notifications, { text = text, level = level }) end,
				on = function(id, event, fn)
					ui_handlers[id] = ui_handlers[id] or {}
					ui_handlers[id][event] = fn
					return true
				end,
				mount = function(slot, spec) state.partial = spec; return "mount1" end,
				update = function(id, spec) state.partial = spec; return true end,
				unmount = function(id) state.partial = nil; return true end,
				dialog = function(spec) table.insert(dialogs, spec); return 1 end,
				focus = function(id) return true end,
				shell = {
					takeover = function(spec) state.layout = spec.layout; return { owner = "griddycode.test", active = true } end,
					exit = function(reason) state.layout = nil; return true end,
				},
			},
			exercise = {
				start = function(spec) state.exercise_spec = spec; state.exercise_state = { exercise = 1, state = "active", phase_kind = "typing" }; return state.exercise_state end,
				state = function(id) return state.exercise_state or { exercise = 0 } end,
				submit = function(id) state.exercise_state = { exercise = 1, state = "validating", phase_kind = "freeform" }; return { status = "pending" } end,
				retry = function(id) state.exercise_state = { exercise = 1, state = "active", phase_kind = "freeform" }; return state.exercise_state end,
				stop = function(id, reason) state.exercise_state = nil; return true end,
				hint = function(id, text) state.last_hint = text; return true end,
			},
		}

		local function read(relative)
			local source = __read(relative)
			assert(source ~= "", "missing " .. relative)
			return assert(load(source, "@" .. relative))
		end

		local main = read("main.lua")
		main()

		-- Open the course, then accept onboarding.
		open_course()
		assert(ui_handlers[1] ~= nil and ui_handlers[1]["click"] ~= nil, "onboarding handler")
		ui_handlers[1]["click"]({ button = "start" })
		assert(state.layout ~= nil, "shell layout created")
		assert(state.doc_text == "", "an empty starter opens an empty document")

		-- Start the hybrid exercise: typing first, freeform second.
		assert(ui_handlers["start"] ~= nil, "start handler is bound")
		ui_handlers["start"]["click"]()
		assert(state.exercise_spec ~= nil, "exercise spec created")
		assert(state.exercise_spec.kind == "hybrid", "exercise is hybrid")
		assert(#state.exercise_spec.phases == 2, "exercise has two phases")
		assert(state.exercise_spec.phases[1].kind == "typing", "first phase is typing")
		assert(state.exercise_spec.phases[2].kind == "freeform", "second phase is freeform")
		assert(#state.exercise_spec.phases[2].validation.tests > 0, "text validation is present")

		-- The typing phase completes, then a text-only submit.
		events["exercise.phase_changed"][1]({ exercise = 1, phase = 1, kind = "freeform" })
		assert(state.progress["lessons.01_hello.typed"] == true, "typing progress recorded")
		ui_handlers["check"]["click"]()
		assert(state.exercise_state.state == "validating", "check enters validating")

		-- Completion, navigation, hints and help.
		events["exercise.completed"][1]({ exercise = 1 })
		assert(state.progress["lessons.01_hello.done"] == true, "completion progress recorded")
		ui_handlers["next_lesson"]["click"]()
		assert(state.layout ~= nil, "next lesson keeps the shell")
		ui_handlers["previous"]["click"]()
		ui_handlers["hint"]["click"]()
		ui_handlers["help"]["click"]()
		assert(#dialogs > 0, "help dialog opens")

		-- Failure then retry on a fresh attempt.
		ui_handlers["start"]["click"]()
		state.exercise_state = { exercise = 1, state = "failed", phase_kind = "freeform" }
		events["exercise.failed"][1]({ exercise = 1 })
		ui_handlers["retry"]["click"]()
		assert(state.exercise_state.state == "active", "retry restarts the phase")

		-- Leave, reopen, and invoke every command once.
		ui_handlers["leave"]["click"]()
		assert(state.layout == nil, "leave exits the shell")
		open_course()
		for id, handlers in pairs(commands) do
			command_count = command_count + 1
			for _, command in ipairs(handlers) do
				if command.handler ~= nil then command.handler() end
			end
		end
		deactivate()
		assert(state.layout == nil, "deactivate exits the shell")

		-- Partial path 1: a host context without ui.shell mounts the panel.
		editor.permissions.has = function(name) return name ~= "ui.shell" end
		open_course()
		assert(state.partial ~= nil, "partial panel mounts without ui.shell")
		assert(state.layout == nil, "no shell is created without permission")
		local partial_text = ""
		if type(state.partial) == "table" and type(state.partial.children) == "table" then
			partial_text = tostring(state.partial.children[1].text or "")
		end
		assert(partial_text ~= "", "the partial panel explains the fallback")
		deactivate()

		-- Partial path 2: the realistic trigger, a takeover refused because
		-- another mod owns the shell (consent is all-or-nothing).
		editor.permissions.has = function(name) return true end
		local takeover = editor.ui.shell.takeover
		editor.ui.shell.takeover = function(spec) return nil, { code = "shell.busy" } end
		open_course()
		assert(state.partial ~= nil, "partial panel mounts when takeover fails")
		assert(state.layout == nil, "no shell is created after a failed takeover")
		local busy_text = ""
		if type(state.partial) == "table" and type(state.partial.children) == "table" then
			busy_text = tostring(state.partial.children[1].text or "")
		end
		assert(busy_text ~= "", "the takeover failure is explained")
		deactivate()
		editor.ui.shell.takeover = takeover

		-- Run-backed path: a trusted workspace opens the real lesson file, so
		-- the freeform phase embeds stdout checks instead of text checks.
		editor.permissions.has = function(name) return true end
		state.workspace = true
		state.file_exists = true
		editor.docs.open = function(path) state.opened_path = path; return 2 end
		open_course()
		assert(ui_handlers["lesson_01_hello"] ~= nil, "lesson navigation is bound")
		ui_handlers["lesson_01_hello"]["click"]()
		assert(state.opened_path == "python_journey/01_hello.py", "lesson file is opened in the workspace")
		ui_handlers["start"]["click"]()
		assert(state.exercise_spec.phases[2].validation.tests[1].type == "stdout_contains", "run validation is embedded")
		deactivate()

		__state = {
			notifications = #notifications,
			dialogs = #dialogs,
			command_count = command_count,
			partial_text = partial_text,
			busy_text = busy_text,
			progress_done = state.progress["lessons.01_hello.done"] == true,
			run_test_type = state.exercise_spec.phases[2].validation.tests[1].type,
			opened_path = state.opened_path,
		}
	""")

	check(!(err is LuaError), "main.lua runtime flow: %s" % (str(err.message) if err is LuaError else ""))
	if err is LuaError:
		return

	var state: Variant = lua.pull_variant("__state")
	check(state is Dictionary, "the runtime stub reports its state")
	if !(state is Dictionary):
		return
	var data: Dictionary = state
	check(int(data.get("notifications", 0)) >= 5, "the flow raises the expected notifications")
	check(int(data.get("dialogs", 0)) >= 2, "onboarding and help dialogs opened")
	assert_eq(int(data.get("command_count", 0)), 6, "every command is registered")
	check(str(data.get("partial_text", "")).length() > 0, "the partial panel carries its reason")
	check(str(data.get("partial_text", "")).contains("ui.shell"), "the permission fallback names ui.shell")
	check(str(data.get("busy_text", "")).length() > 0, "the takeover failure is explained")
	check(str(data.get("busy_text", "")).contains("shell.busy"), "the takeover failure names the host code")
	check(bool(data.get("progress_done", false)), "completion reached progress storage")
	assert_eq(str(data.get("run_test_type", "")), "stdout_contains", "the run-backed phase uses stdout checks")
	assert_eq(str(data.get("opened_path", "")), "python_journey/01_hello.py", "the run-backed lesson opened its file")
