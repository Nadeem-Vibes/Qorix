extends "res://tests/support/test_case.gd"

## Platform Tour runtime suite: drives the sample's own main.lua against a
## sandbox stub. The important regressions are behavioural:
##   - Check answer during the typing phase must not submit (state.invalid);
##   - a failed freeform check stays checkable;
##   - the self-check subscribes inside the mod's own namespace and passes 8/8.

const ROOT := "res://samples/mods/griddycode.platform_tour/1.0.0"


func test_tour_check_answer_and_selfcheck_runtime() -> void:
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
			assert(source ~= "", "missing " .. relative)
			local chunk = assert(load(source, "@" .. path))
			modules[key] = chunk()
			return modules[key]
		end
		function require(path) return load_module("lib", path) end

		local state = {
			storage = {},
			settings = {},
			progress = {},
			notifications = {},
			subscriptions = {},
			commands = {},
			exercise = { exercise = 0 },
			submitted = 0,
			doc_id = 0,
			doc_text = "",
		}
		local ui_handlers = {}

		editor = {
			log = {
				info = function(message) end,
				warn = function(message) end,
				error = function(message) error("log.error: " .. tostring(message)) end,
			},
			content = { load = function(path) return load_module("content", path) end },
			storage = {
				get = function(key, fallback)
					local value = state.storage[key]
					if value == nil then return fallback end
					return value
				end,
				set = function(key, value) state.storage[key] = value; return true end,
				delete = function(key) state.storage[key] = nil; return true end,
			},
			settings = {
				get = function(key, fallback)
					local value = state.settings[key]
					if value == nil then return fallback end
					return value
				end,
				set = function(key, value) state.settings[key] = value; return true end,
			},
			progress = {
				get = function(key, fallback)
					local value = state.progress[key]
					if value == nil then return fallback end
					return value
				end,
				set = function(key, value) state.progress[key] = value; return true end,
				increment = function(key, amount)
					state.progress[key] = (state.progress[key] or 0) + (amount or 1)
					return state.progress[key]
				end,
				reset = function(key) state.progress[key] = nil; return true end,
			},
			permissions = { has = function(name) return true end },
			docs = {
				create = function(spec)
					state.doc_id = state.doc_id + 1
					state.doc_text = tostring(spec.text or "")
					return state.doc_id
				end,
				text = function(id) return state.doc_text end,
				set_text = function(id, text) state.doc_text = text; return true end,
				reveal = function(id) return true end,
				close = function(id, options) return true end,
			},
			commands = {
				register = function(spec)
					state.commands[spec.id] = spec
					return spec.id
				end,
				unregister = function(id) state.commands[id] = nil; return true end,
			},
			events = {
				on = function(name, fn)
					state.subscriptions[name] = fn
					return name
				end,
				off = function(handle) return true end,
			},
			ui = {
				mount = function(slot, spec) state.mount_spec = spec; return "mount1" end,
				update = function(id, spec) state.mount_spec = spec; return true end,
				unmount = function(id) return true end,
				on = function(id, event, fn)
					ui_handlers[id] = ui_handlers[id] or {}
					ui_handlers[id][event] = fn
					return true
				end,
				notify = function(text, level)
					table.insert(state.notifications, { text = text, level = level })
				end,
			},
			exercise = {
				start = function(spec)
					state.exercise_spec = spec
					state.exercise = { exercise = 1, state = "active", phase_kind = "typing" }
					return state.exercise
				end,
				state = function(id) return state.exercise end,
				submit = function(id)
					state.submitted = state.submitted + 1
					state.exercise = { exercise = 1, state = "validating", phase_kind = "freeform" }
					return { status = "pending" }
				end,
				retry = function(id, options)
					state.exercise = { exercise = 1, state = "active", phase_kind = "freeform" }
					return state.exercise
				end,
				stop = function(id, reason)
					state.exercise = { exercise = 0 }
					return true
				end,
			},
		}

		local main = assert(load(__read("main.lua"), "@main.lua"))
		main()

		assert(ui_handlers["start"] ~= nil and ui_handlers["start"]["click"] ~= nil, "Start is bound")
		assert(ui_handlers["check"] ~= nil and ui_handlers["check"]["click"] ~= nil, "Check is bound")
		assert(ui_handlers["selfcheck"] ~= nil and ui_handlers["selfcheck"]["click"] ~= nil, "Self-check is bound")

		-- Start the hybrid lesson: typing first.
		ui_handlers["start"]["click"]()
		assert(state.exercise_spec ~= nil, "the lesson starts an exercise")
		assert(state.exercise_spec.kind == "hybrid", "the lesson is hybrid")
		assert(state.exercise_spec.phases[1].kind == "typing", "typing is the first phase")
		assert(state.exercise.phase_kind == "typing", "the host is in the typing phase")

		-- Check answer must guide, not submit, while typing.
		local before = state.submitted
		ui_handlers["check"]["click"]()
		assert(state.submitted == before, "Check answer does not submit during typing")
		assert(state.exercise.state == "active", "the typing exercise stays active")
		local latest = state.notifications[#state.notifications].text
		assert(latest:find("finish typing") ~= nil, "typing check explains what to do: " .. latest)

		-- Freeform phase: Check answer submits.
		state.exercise = { exercise = 1, state = "active", phase_kind = "freeform" }
		ui_handlers["check"]["click"]()
		assert(state.submitted == before + 1, "Check answer submits in the freeform phase")
		assert(state.exercise.state == "validating", "the freeform check enters validation")

		-- A failed freeform check is still checkable after the learner edits.
		state.exercise = { exercise = 1, state = "failed", phase_kind = "freeform" }
		ui_handlers["check"]["click"]()
		assert(state.submitted == before + 2, "a failed freeform check can be retried with Check answer")

		-- The self-check must pass all eight points and use the mod namespace.
		ui_handlers["selfcheck"]["click"]()
		local selfcheck = state.notifications[#state.notifications].text
		assert(selfcheck:find("8/8") ~= nil, "the self-check passes 8/8: " .. selfcheck)
		assert(
			state.subscriptions["mod.griddycode.platform_tour.selfcheck_probe"] ~= nil,
			"the self-check subscribes inside its own namespace"
		)
		assert(
			state.subscriptions["griddycode.platform_tour.selfcheck_probe"] == nil,
			"the self-check does not use an unsubscribable bare name"
		)
	""")
	if err is LuaError:
		assert_true(false, "tour runtime failed: %s" % str(err.message))
	else:
		check(true, "the Platform Tour runtime flow passes")
