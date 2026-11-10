-- Qorix mod sandbox bootstrap.
--
-- Trusted code. Runs once per Lua state, before any mod chunk, and mirrors the
-- execution model proven in docs/archive/mod-platform/probe-report.md:
--   * every mod entry point runs in a host-created coroutine,
--   * a count hook on that coroutine raises a private sentinel,
--   * the mod environment has no debug/coroutine/io/os/package reachable,
--   * pcall/xpcall rethrow the sentinel so a mod cannot swallow its own kill,
--   * the host reaches the state only through __griddy_* functions that the mod
--     environment cannot see.
--
-- Nothing in this file is mod-facing except the `editor` table it builds.

-- Captured before the trusted libraries are removed at the end of the file.
local sethook = debug.sethook
local co_create = coroutine.create
local co_resume = coroutine.resume
local co_status = coroutine.status
local co_running = coroutine.running
local co_yield = coroutine.yield
local raw_pcall = pcall
local raw_xpcall = xpcall
local raw_load = load
local raw_error = error
local raw_assert = assert
local raw_type = type
local raw_tostring = tostring
local raw_tonumber = tonumber
local raw_select = select
local raw_pairs = pairs
local raw_ipairs = ipairs
local raw_next = next
local raw_rawget = rawget
local raw_rawset = rawset
local raw_rawequal = rawequal
local raw_rawlen = rawlen
local raw_collectgarbage = collectgarbage
local raw_pack = table.pack
local raw_concat = table.concat
local raw_floor = math.floor
local raw_max = math.max

local config = {}
if raw_type(__griddy_config) == "table" then
	config = __griddy_config
end
local native = __griddy_native

local SENTINEL = {}
local tasks = {}
local counts = {}
local handlers = {}
local module_cache = {}
local module_loading = {}
local next_task_id = 0
local next_handler_id = 0
local current_task = nil
-- Declared before the loaders: Lua resolves names at compile time, so a later
-- `local mod_env` would make module chunks load into the real global table.
local mod_env = {}

local LIMIT = raw_tonumber(config.instruction_limit) or 250
local STEP = raw_tonumber(config.instruction_step) or 1000
local MAX_SOURCE_BYTES = raw_tonumber(config.max_source_bytes) or (2 * 1024 * 1024)

local function failure(code, message)
	return { code = code, message = message }
end

local function hook()
	local co = co_running()
	if co == nil then
		return
	end
	local count = (counts[co] or 0) + 1
	counts[co] = count
	if count >= LIMIT then
		counts[co] = 0
		raw_error(SENTINEL, 0)
	end
end

local function protected_pcall(fn, ...)
	local ok, err = raw_pcall(fn, ...)
	if not ok and err == SENTINEL then
		raw_error(SENTINEL, 0)
	end
	return ok, err
end

local function protected_xpcall(fn, handler, ...)
	local ok, err = raw_xpcall(fn, function(e)
		if e == SENTINEL then
			return SENTINEL
		end
		if handler ~= nil then
			return handler(e)
		end
		return e
	end, ...)
	if not ok and err == SENTINEL then
		raw_error(SENTINEL, 0)
	end
	return ok, err
end

-- Calls the GDScript facade. Returns value, failure, ok. The third value is
-- required because a successful call may legitimately return nil.
local function call_native(method, args)
	-- The host bridge is a Godot Callable, which the Lua addon exposes as
	-- callable userdata, not as a Lua function.
	if native == nil then
		return nil, failure("host.not_started", "The mod host is not available."), false
	end
	local call_ok, result = raw_pcall(native, method, args)
	if not call_ok then
		return nil, failure("host.fatal", "The host call failed: " .. raw_tostring(result)), false
	end
	if raw_type(result) ~= "table" then
		return nil, failure("host.fatal", "The host returned a non-table result."), false
	end
	if result.ok then
		return result.value, nil, true
	end
	local err = result.error
	if raw_type(err) ~= "table" then
		return nil, failure("mod.failed", "The host returned an invalid error."), false
	end
	return nil, { code = err.code or "mod.failed", message = err.message or "The host call failed." }, false
end

local function copy_library(source)
	local copy = {}
	for key, value in raw_pairs(source) do
		copy[key] = value
	end
	return copy
end

local safe_string = copy_library(string)
safe_string.dump = nil
local safe_table = copy_library(table)
local safe_math = copy_library(math)
local safe_utf8 = copy_library(utf8)

local function new_handler(fn)
	next_handler_id = next_handler_id + 1
	handlers[next_handler_id] = fn
	return next_handler_id
end

local function new_task(fn)
	next_task_id = next_task_id + 1
	local id = next_task_id
	local co = co_create(fn)
	counts[co] = 0
	sethook(co, hook, "", STEP)
	tasks[id] = { co = co }
	return id
end

-- ── PUBLIC API ──────────────────────────────────────────────────────────────

local editor = {}
editor.api_version = config.api_version or 1
editor.mod = config.mod or {}

editor.permissions = {
	has = function(name)
		if raw_type(name) ~= "string" then
			return false
		end
		local value, _, ok = call_native("permissions.has", { permission = name })
		return ok and value == true
	end,
}

local function log_at(level, message)
	local text = "(unprintable value)"
	if raw_type(message) == "string" then
		text = message
	else
		local rendered_ok, rendered = raw_pcall(raw_tostring, message)
		if rendered_ok then
			text = rendered
		end
	end
	call_native("log", { level = level, message = text })
end

editor.log = {
	info = function(message) log_at("info", message) end,
	warn = function(message) log_at("warn", message) end,
	error = function(message) log_at("error", message) end,
}

local subscriptions = {}

editor.events = {
	on = function(name, fn, opts)
		if raw_type(name) ~= "string" then
			return nil, failure("event.invalid", "Event names must be strings.")
		end
		if raw_type(fn) ~= "function" then
			return nil, failure("event.invalid", "The event handler must be a function.")
		end
		local priority = 0
		if raw_type(opts) == "table" and raw_type(opts.priority) == "number" then
			priority = opts.priority
		end
		local handle = new_handler(fn)
		local subscription, err, ok = call_native("events.subscribe", {
			name = name,
			handle = handle,
			priority = priority,
		})
		if not ok then
			handlers[handle] = nil
			return nil, err
		end
		subscriptions[subscription] = handle
		return subscription
	end,

	off = function(subscription)
		if raw_type(subscription) ~= "number" then
			return nil, failure("api.bad_args", "events.off needs the subscription id returned by on().")
		end
		local _, err, ok = call_native("events.unsubscribe", { handle = subscription })
		if not ok then
			return nil, err
		end
		local handle = subscriptions[subscription]
		if handle ~= nil then
			handlers[handle] = nil
		end
		subscriptions[subscription] = nil
		return true
	end,

	emit = function(name, payload)
		if raw_type(name) ~= "string" then
			return nil, failure("event.invalid", "Event names must be strings.")
		end
		if payload ~= nil and raw_type(payload) ~= "table" then
			return nil, failure("event.invalid", "Event payloads must be a table.")
		end
		local _, err, ok = call_native("events.emit", { name = name, payload = payload })
		if not ok then
			return nil, err
		end
		return true
	end,
}

editor.async = function(fn)
	if raw_type(fn) ~= "function" then
		return nil, failure("api.bad_args", "editor.async needs a function.")
	end
	local id = new_task(fn)
	local _, err, ok = call_native("tasks.schedule", { id = id })
	if not ok then
		tasks[id] = nil
		return nil, err
	end
	return id
end

editor.wait = function(milliseconds)
	if current_task == nil then
		raw_error("editor.wait can only be called inside a task", 2)
	end
	local delay = raw_tonumber(milliseconds) or 0
	if delay < 0 then
		delay = 0
	end
	return co_yield({ __griddy_wait = delay })
end

local function schedule_timer(milliseconds, fn, repeating)
	if raw_type(fn) ~= "function" then
		return nil, failure("timer.invalid", "A timer needs a function.")
	end
	local delay = raw_tonumber(milliseconds)
	if delay == nil or delay <= 0 then
		return nil, failure("timer.invalid", "A timer needs a positive delay in milliseconds.")
	end
	local handle = new_handler(fn)
	local timer, err, ok = call_native("timer.schedule", {
		handle = handle,
		ms = delay,
		["repeat"] = repeating,
	})
	if not ok then
		handlers[handle] = nil
		return nil, err
	end
	return timer
end

editor.after = function(milliseconds, fn)
	return schedule_timer(milliseconds, fn, false)
end

editor.every = function(milliseconds, fn)
	return schedule_timer(milliseconds, fn, true)
end

editor.cancel = function(handle)
	if raw_type(handle) ~= "number" then
		return nil, failure("api.bad_args", "editor.cancel needs a task or timer id.")
	end
	local _, err, ok = call_native("cancel", { handle = handle })
	if not ok then
		return nil, err
	end
	return true
end

local commands = {}

editor.commands = {
	register = function(spec)
		if raw_type(spec) ~= "table" then
			return nil, failure("command.invalid", "editor.commands.register needs a table.")
		end
		if raw_type(spec.id) ~= "string" then
			return nil, failure("command.invalid", "A command needs a string id.")
		end
		if spec.handler ~= nil and raw_type(spec.handler) ~= "function" then
			return nil, failure("command.invalid", "A command handler must be a function.")
		end

		local handle = nil
		if spec.handler ~= nil then
			handle = new_handler(spec.handler)
		end

		local registered, err, ok = call_native("commands.register", {
			id = spec.id,
			label = spec.label,
			category = spec.category,
			hidden = spec.hidden == true,
			handler = handle,
		})
		if not ok then
			if handle ~= nil then
				handlers[handle] = nil
			end
			return nil, err
		end
		commands[spec.id] = handle
		return registered
	end,

	unregister = function(command_id)
		if raw_type(command_id) ~= "string" then
			return nil, failure("api.bad_args", "editor.commands.unregister needs a command id.")
		end
		local _, err, ok = call_native("commands.unregister", { id = command_id })
		if not ok then
			return nil, err
		end
		local handle = commands[command_id]
		if handle ~= nil then
			handlers[handle] = nil
		end
		commands[command_id] = nil
		return true
	end,

	execute = function(command_id, args)
		if raw_type(command_id) ~= "string" then
			return nil, failure("api.bad_args", "editor.commands.execute needs a command id.")
		end
		if args ~= nil and raw_type(args) ~= "table" then
			return nil, failure("api.bad_args", "Command arguments must be an array.")
		end
		local _, err, ok = call_native("commands.execute", { id = command_id, args = args or {} })
		if not ok then
			return nil, err
		end
		return true
	end,
}

editor.keys = {
	bind = function(command_id, chord)
		if raw_type(command_id) ~= "string" or raw_type(chord) ~= "string" then
			return nil, failure("api.bad_args", "editor.keys.bind needs a command id and a chord string.")
		end
		local _, err, ok = call_native("keys.bind", { command = command_id, chord = chord })
		if not ok then
			return nil, err
		end
		return true
	end,

	unbind = function(command_id)
		if raw_type(command_id) ~= "string" then
			return nil, failure("api.bad_args", "editor.keys.unbind needs a command id.")
		end
		local _, err, ok = call_native("keys.unbind", { command = command_id })
		if not ok then
			return nil, err
		end
		return true
	end,
}

editor.storage = {
	get = function(key, fallback)
		if raw_type(key) ~= "string" then
			return nil, failure("storage.invalid_key", "Storage keys must be strings.")
		end
		local value, err, ok = call_native("storage.get", { key = key })
		if not ok then
			return nil, err
		end
		if value == nil then
			return fallback
		end
		return value
	end,

	set = function(key, value)
		if raw_type(key) ~= "string" then
			return nil, failure("storage.invalid_key", "Storage keys must be strings.")
		end
		local _, err, ok = call_native("storage.set", { key = key, value = value })
		if not ok then
			return nil, err
		end
		return true
	end,

	delete = function(key)
		if raw_type(key) ~= "string" then
			return nil, failure("storage.invalid_key", "Storage keys must be strings.")
		end
		local _, err, ok = call_native("storage.delete", { key = key })
		if not ok then
			return nil, err
		end
		return true
	end,

	keys = function()
		local value, err, ok = call_native("storage.keys", {})
		if not ok then
			return nil, err
		end
		return value or {}
	end,

	clear = function()
		local _, err, ok = call_native("storage.clear", {})
		if not ok then
			return nil, err
		end
		return true
	end,
}

editor.progress = {
	get = function(key, fallback)
		local value, err, ok = call_native("progress.get", { key = key })
		if not ok then
			return nil, err
		end
		if value == nil then
			return fallback
		end
		return value
	end,

	set = function(key, value)
		local _, err, ok = call_native("progress.set", { key = key, value = value })
		if not ok then
			return nil, err
		end
		return true
	end,

	increment = function(key, amount)
		local value, err, ok = call_native("progress.increment", { key = key, amount = amount })
		if not ok then
			return nil, err
		end
		return value
	end,

	reset = function(key)
		local _, err, ok = call_native("progress.reset", { key = key })
		if not ok then
			return nil, err
		end
		return true
	end,

	all = function()
		local value, err, ok = call_native("progress.all", {})
		if not ok then
			return nil, err
		end
		return value or {}
	end,
}

editor.settings = {
	declare = function(schema)
		if raw_type(schema) ~= "table" then
			return nil, failure("settings.invalid", "editor.settings.declare needs an array of declarations.")
		end
		local _, err, ok = call_native("settings.declare", { schema = schema })
		if not ok then
			return nil, err
		end
		return true
	end,

	get = function(key, fallback)
		local value, err, ok = call_native("settings.get", { key = key })
		if not ok then
			return nil, err
		end
		if value == nil then
			return fallback
		end
		return value
	end,

	set = function(key, value)
		local _, err, ok = call_native("settings.set", { key = key, value = value })
		if not ok then
			return nil, err
		end
		return true
	end,
}

-- ── LOADERS ─────────────────────────────────────────────────────────────────

local function load_module(kind, path)
	if raw_type(path) ~= "string" or path == "" then
		return nil, failure("module.invalid", "The module path must be a non-empty string.")
	end

	local cache_key = kind .. ":" .. path
	if module_cache[cache_key] ~= nil then
		return module_cache[cache_key]
	end
	if module_loading[cache_key] then
		return nil, failure("module.invalid", "Cyclic load: " .. path)
	end

	module_loading[cache_key] = true
	local method = kind .. ".read"
	if kind == "assets" then
		method = "assets.read_text"
	end
	local source, read_err, read_ok = call_native(method, { path = path })
	if not read_ok then
		module_loading[cache_key] = nil
		return nil, read_err
	end

	local chunk, load_err = raw_load(source, "@" .. path, "t", mod_env)
	if not chunk then
		module_loading[cache_key] = nil
		return nil, failure("module.invalid", "Could not compile " .. path .. ": " .. raw_tostring(load_err))
	end

	local ran, value = raw_pcall(chunk, path)
	module_loading[cache_key] = nil
	if not ran then
		if value == SENTINEL then
			raw_error(SENTINEL, 0)
		end
		return nil, failure("module.invalid", "Loading " .. path .. " failed: " .. raw_tostring(value))
	end
	if raw_type(value) ~= "table" then
		return nil, failure("module.invalid", path .. " must return a table.")
	end

	module_cache[cache_key] = value
	return value
end

local function require_module(path)
	if raw_type(path) ~= "string" then
		return nil, failure("module.invalid", "require needs a module path.")
	end
	local normalized = safe_string.gsub(path, "%.", "/")
	if safe_string.sub(normalized, 1, 4) == "lib/" then
		normalized = safe_string.sub(normalized, 5)
	end
	return load_module("module", normalized)
end

editor.content = {
	load = function(path)
		return load_module("content", path)
	end,
}

editor.assets = {
	read_text = function(path)
		if raw_type(path) ~= "string" then
			return nil, failure("path.invalid", "Asset paths must be strings.")
		end
		local value, err, ok = call_native("assets.read_text", { path = path })
		if not ok then
			return nil, err
		end
		return value
	end,
}

-- ── PHASE 2: DOCUMENTS, FILES, WORKSPACE ───────────────────────────────────

local function require_number(value, label)
	if raw_type(value) ~= "number" then
		return nil, failure("api.bad_args", label .. " must be a document id.")
	end
	return value
end

editor.docs = {
	active = function()
		local value, err, ok = call_native("docs.active", {})
		if not ok then
			return nil, err
		end
		return value
	end,

	list = function()
		local value, err, ok = call_native("docs.list", {})
		if not ok then
			return nil, err
		end
		return value or {}
	end,

	open = function(path)
		if raw_type(path) ~= "string" then
			return nil, failure("api.bad_args", "docs.open needs a path string.")
		end
		local value, err, ok = call_native("docs.open", { path = path })
		if not ok then
			return nil, err
		end
		return value
	end,

	create = function(spec)
		if raw_type(spec) ~= "table" then
			return nil, failure("api.bad_args", "docs.create needs an options table.")
		end
		local value, err, ok = call_native("docs.create", spec)
		if not ok then
			return nil, err
		end
		return value
	end,

	text = function(doc)
		local id, id_err = require_number(doc, "docs.text")
		if id == nil then return nil, id_err end
		local value, err, ok = call_native("docs.text", { doc = id })
		if not ok then return nil, err end
		return value
	end,

	set_text = function(doc, text)
		local id, id_err = require_number(doc, "docs.set_text")
		if id == nil then return nil, id_err end
		local value, err, ok = call_native("docs.set_text", { doc = id, text = text })
		if not ok then return nil, err end
		return value
	end,

	insert = function(doc, line, column, text)
		local id, id_err = require_number(doc, "docs.insert")
		if id == nil then return nil, id_err end
		local value, err, ok = call_native("docs.insert", { doc = id, line = line, col = column, text = text })
		if not ok then return nil, err end
		return value
	end,

	replace = function(doc, from, to, text)
		local id, id_err = require_number(doc, "docs.replace")
		if id == nil then return nil, id_err end
		if raw_type(from) ~= "table" or raw_type(to) ~= "table" then
			return nil, failure("api.bad_args", "docs.replace needs from={line,col} and to={line,col}.")
		end
		local value, err, ok = call_native("docs.replace", { doc = id, from = from, to = to, text = text })
		if not ok then return nil, err end
		return value
	end,

	cursor = function(doc)
		local id, id_err = require_number(doc, "docs.cursor")
		if id == nil then return nil, id_err end
		local value, err, ok = call_native("docs.cursor", { doc = id })
		if not ok then return nil, err end
		return value
	end,

	set_cursor = function(doc, position)
		local id, id_err = require_number(doc, "docs.set_cursor")
		if id == nil then return nil, id_err end
		if raw_type(position) ~= "table" then
			return nil, failure("api.bad_args", "docs.set_cursor needs {line,col}.")
		end
		local value, err, ok = call_native("docs.set_cursor", { doc = id, line = position.line, col = position.col })
		if not ok then return nil, err end
		return value
	end,

	selection = function(doc)
		local id, id_err = require_number(doc, "docs.selection")
		if id == nil then return nil, id_err end
		local value, err, ok = call_native("docs.selection", { doc = id })
		if not ok then return nil, err end
		return value
	end,

	set_selection = function(doc, from, to)
		local id, id_err = require_number(doc, "docs.set_selection")
		if id == nil then return nil, id_err end
		if raw_type(from) ~= "table" or raw_type(to) ~= "table" then
			return nil, failure("api.bad_args", "docs.set_selection needs from={line,col} and to={line,col}.")
		end
		local value, err, ok = call_native("docs.set_selection", { doc = id, from = from, to = to })
		if not ok then return nil, err end
		return value
	end,

	save = function(doc)
		local id, id_err = require_number(doc, "docs.save")
		if id == nil then return nil, id_err end
		local value, err, ok = call_native("docs.save", { doc = id })
		if not ok then return nil, err end
		return value
	end,

	close = function(doc, options)
		local id, id_err = require_number(doc, "docs.close")
		if id == nil then return nil, id_err end
		local force = raw_type(options) == "table" and options.force == true
		local value, err, ok = call_native("docs.close", { doc = id, force = force })
		if not ok then return nil, err end
		return value
	end,

	is_dirty = function(doc)
		local id, id_err = require_number(doc, "docs.is_dirty")
		if id == nil then return nil, id_err end
		local value, err, ok = call_native("docs.is_dirty", { doc = id })
		if not ok then return nil, err end
		return value
	end,

	path = function(doc)
		local id, id_err = require_number(doc, "docs.path")
		if id == nil then return nil, id_err end
		local value, err, ok = call_native("docs.path", { doc = id })
		if not ok then return nil, err end
		return value
	end,

	language = function(doc)
		local id, id_err = require_number(doc, "docs.language")
		if id == nil then return nil, id_err end
		local value, err, ok = call_native("docs.language", { doc = id })
		if not ok then return nil, err end
		return value
	end,

	reveal = function(doc)
		local id, id_err = require_number(doc, "docs.reveal")
		if id == nil then return nil, id_err end
		local value, err, ok = call_native("docs.reveal", { doc = id })
		if not ok then return nil, err end
		return value
	end,
}

editor.files = {
	read = function(path)
		if raw_type(path) ~= "string" then return nil, failure("api.bad_args", "files.read needs a path.") end
		local value, err, ok = call_native("files.read", { path = path })
		if not ok then return nil, err end
		return value
	end,

	write = function(path, text)
		if raw_type(path) ~= "string" then return nil, failure("api.bad_args", "files.write needs a path.") end
		local value, err, ok = call_native("files.write", { path = path, text = text })
		if not ok then return nil, err end
		return value
	end,

	exists = function(path)
		if raw_type(path) ~= "string" then return nil, failure("api.bad_args", "files.exists needs a path.") end
		local value, err, ok = call_native("files.exists", { path = path })
		if not ok then return nil, err end
		return value
	end,

	list = function(path, options)
		local recursive = raw_type(options) == "table" and options.recursive == true
		local value, err, ok = call_native("files.list", { path = path or "", recursive = recursive })
		if not ok then return nil, err end
		return value or {}
	end,

	mkdir = function(path)
		if raw_type(path) ~= "string" then return nil, failure("api.bad_args", "files.mkdir needs a path.") end
		local value, err, ok = call_native("files.mkdir", { path = path })
		if not ok then return nil, err end
		return value
	end,

	delete = function(path, options)
		if raw_type(path) ~= "string" then return nil, failure("api.bad_args", "files.delete needs a path.") end
		local confirmed = raw_type(options) == "table" and options.confirmed == true
		local value, err, ok = call_native("files.delete", { path = path, confirmed = confirmed })
		if not ok then return nil, err end
		return value
	end,
}

editor.workspace = {
	root = function()
		local value, err, ok = call_native("workspace.root", {})
		if not ok then return nil, err end
		return value
	end,

	name = function()
		local value, err, ok = call_native("workspace.name", {})
		if not ok then return nil, err end
		return value
	end,

	has_workspace = function()
		local value, err, ok = call_native("workspace.has_workspace", {})
		if not ok then return nil, err end
		return value == true
	end,

	list = function(filter)
		local value, err, ok = call_native("workspace.list", { filter = filter or "" })
		if not ok then return nil, err end
		return value or {}
	end,
}

editor.run = {
	active = function(options)
		local value, err, ok = call_native("run.active", { options = options or {} })
		if not ok then return nil, err end
		return value
	end,

	file = function(path, options)
		if raw_type(path) ~= "string" then return nil, failure("api.bad_args", "run.file needs a path.") end
		local value, err, ok = call_native("run.file", { path = path, options = options or {} })
		if not ok then return nil, err end
		return value
	end,

	stop = function()
		local value, err, ok = call_native("run.stop", {})
		if not ok then return nil, err end
		return value
	end,

	is_running = function()
		local value, err, ok = call_native("run.is_running", {})
		if not ok then return nil, err end
		return value == true
	end,
}

editor.clipboard = {
	write = function(text)
		if raw_type(text) ~= "string" then return nil, failure("api.bad_args", "clipboard.write needs a string.") end
		local value, err, ok = call_native("clipboard.write", { text = text })
		if not ok then return nil, err end
		return value
	end,

	read = function()
		local value, err, ok = call_native("clipboard.read", {})
		if not ok then return nil, err end
		return value
	end,
}

-- ── PHASE 2: DIALOGS AND PARTIAL UI ────────────────────────────────────────

local function dialog_call(method, spec, fn, prompt)
	if raw_type(spec) ~= "table" then
		return nil, failure("api.bad_args", method .. " needs a specification table.")
	end
	local handle = 0
	if fn ~= nil then
		if raw_type(fn) ~= "function" then
			return nil, failure("api.bad_args", method .. " needs a callback function.")
		end
		handle = new_handler(fn)
	end
	local args = { spec = spec, handle = handle }
	if prompt then
		args.default = spec.default
		args.placeholder = spec.placeholder
	end
	local value, err, ok = call_native("dialogs." .. (prompt and "prompt" or "confirm"), args)
	if not ok then
		if handle ~= 0 then handlers[handle] = nil end
		return nil, err
	end
	return value
end

editor.dialogs = {
	confirm = function(spec, fn)
		return dialog_call("dialogs.confirm", spec, fn, false)
	end,

	prompt = function(spec, fn)
		return dialog_call("dialogs.prompt", spec, fn, true)
	end,
}

editor.ui = {
	mount = function(slot, spec)
		if raw_type(slot) ~= "string" or raw_type(spec) ~= "table" then
			return nil, failure("api.bad_args", "ui.mount needs a slot name and a widget specification.")
		end
		local value, err, ok = call_native("ui.mount", { slot = slot, spec = spec })
		if not ok then return nil, err end
		return value
	end,

	update = function(id, spec)
		if raw_type(spec) ~= "table" then
			return nil, failure("api.bad_args", "ui.update needs a widget specification.")
		end
		local value, err, ok = call_native("ui.update", { id = id, spec = spec })
		if not ok then return nil, err end
		return value
	end,

	unmount = function(id)
		local value, err, ok = call_native("ui.unmount", { id = id })
		if not ok then return nil, err end
		return value
	end,

	set_visible = function(id, visible)
		local value, err, ok = call_native("ui.set_visible", { id = id, visible = visible == true })
		if not ok then return nil, err end
		return value
	end,

	on = function(id, event, fn)
		if raw_type(fn) ~= "function" then
			return nil, failure("api.bad_args", "ui.on needs a callback function.")
		end
		local handle = new_handler(fn)
		local value, err, ok = call_native("ui.on", { id = id, event = event, handle = handle })
		if not ok then
			handlers[handle] = nil
			return nil, err
		end
		return value
	end,

	notify = function(text, severity, options)
		local value, err, ok = call_native("ui.notify", {
			text = text,
			severity = severity or "info",
			options = options or {},
		})
		if not ok then return nil, err end
		return value
	end,

	dialog = function(spec)
		if raw_type(spec) ~= "table" then
			return nil, failure("api.bad_args", "ui.dialog needs a specification table.")
		end
		local value, err, ok = call_native("ui.dialog", { spec = spec })
		if not ok then return nil, err end
		return value
	end,

	close_dialog = function(id)
		local value, err, ok = call_native("ui.close_dialog", { id = id })
		if not ok then return nil, err end
		return value
	end,

	focus = function(id)
		local value, err, ok = call_native("ui.focus", { id = id })
		if not ok then return nil, err end
		return value
	end,

	layout = {
		set_visible = function(panel, visible)
			local value, err, ok = call_native("ui.layout.set_visible", { panel = panel, visible = visible == true })
			if not ok then return nil, err end
			return value
		end,
	},

	theme = {
		token = function(name)
			local value, err, ok = call_native("ui.theme.token", { name = name })
			if not ok then return nil, err end
			return value
		end,
	},
}

-- ── PHASE 3: SHELL, GUIDE AND EXERCISE ────────────────────────────────────

-- Every wrapper validates the Lua-side shape, calls the native facade and
-- returns (value, error). They add no capabilities: the permission table in
-- api_v1.gd decides what exists and the native guard decides who may call it.

local function native_call(method, args)
	local value, err, ok = call_native(method, args or {})
	if not ok then
		return nil, err
	end
	return value
end

editor.ui.shell = {
	takeover = function(spec)
		if raw_type(spec) ~= "table" then
			return nil, failure("api.bad_args", "shell.takeover needs a specification table.")
		end
		return native_call("ui.shell.takeover", { spec = spec })
	end,

	exit = function(reason)
		return native_call("ui.shell.exit", { reason = reason or "" })
	end,

	set_editor_visible = function(visible)
		return native_call("ui.shell.set_editor_visible", { visible = visible == true })
	end,

	set_content_insets = function(insets)
		if raw_type(insets) ~= "table" then
			return nil, failure("api.bad_args", "shell.set_content_insets needs an insets table.")
		end
		return native_call("ui.shell.set_content_insets", { insets = insets })
	end,
}

editor.guide = {
	start = function(spec)
		if raw_type(spec) ~= "table" then
			return nil, failure("api.bad_args", "guide.start needs a specification table.")
		end
		return native_call("guide.start", spec)
	end,

	state = function(session)
		return native_call("guide.state", { session = session or 0 })
	end,

	pause = function(session)
		return native_call("guide.pause", { session = session or 0 })
	end,

	resume = function(session)
		return native_call("guide.resume", { session = session or 0 })
	end,

	reset = function(options)
		local payload = {}
		if raw_type(options) == "table" then
			payload = options
		end
		return native_call("guide.reset", payload)
	end,

	stop = function(reason)
		return native_call("guide.stop", { reason = reason or "" })
	end,

	hint = function(text, session)
		if raw_type(text) ~= "string" then
			return nil, failure("api.bad_args", "guide.hint needs a text string.")
		end
		return native_call("guide.hint", { text = text, session = session or 0 })
	end,

	set_target = function(target, session)
		if raw_type(target) ~= "string" then
			return nil, failure("api.bad_args", "guide.set_target needs a target string.")
		end
		return native_call("guide.set_target", { target = target, session = session or 0 })
	end,

	set_validation = function(spec, session)
		if raw_type(spec) ~= "table" then
			return nil, failure("api.bad_args", "guide.set_validation needs a validation table.")
		end
		return native_call("guide.set_validation", { validation = spec, session = session or 0 })
	end,

	resolve_validation = function(token, passed, details)
		if raw_type(token) ~= "number" then
			return nil, failure("api.bad_args", "guide.resolve_validation needs a token.")
		end
		local payload = { token = token, passed = passed == true }
		if raw_type(details) == "table" then
			payload.results = details.results
			payload.code = details.code
			payload.message = details.message
		end
		return native_call("guide.resolve_validation", payload)
	end,

	set_mode = function(mode, session)
		return native_call("guide.set_mode", { mode = mode, session = session or 0 })
	end,

	set_progression = function(progression, session)
		return native_call("guide.set_progression", { progression = progression, session = session or 0 })
	end,

	set_display = function(display, session)
		if raw_type(display) ~= "table" then
			return nil, failure("api.bad_args", "guide.set_display needs a display table.")
		end
		return native_call("guide.set_display", { display = display, session = session or 0 })
	end,
}

editor.exercise = {
	start = function(spec)
		if raw_type(spec) ~= "table" then
			return nil, failure("api.bad_args", "exercise.start needs a specification table.")
		end
		return native_call("exercise.start", spec)
	end,

	state = function(id)
		return native_call("exercise.state", { id = id or 0 })
	end,

	submit = function(id)
		return native_call("exercise.submit", { id = id or 0 })
	end,

	retry = function(id, options)
		local payload = { id = id or 0, restore = "checkpoint" }
		if raw_type(options) == "table" and raw_type(options.restore) == "string" then
			payload.restore = options.restore
		end
		return native_call("exercise.retry", payload)
	end,

	stop = function(id, reason)
		return native_call("exercise.stop", { id = id or 0, reason = reason or "" })
	end,

	hint = function(id, text)
		if raw_type(text) ~= "string" then
			return nil, failure("api.bad_args", "exercise.hint needs a text string.")
		end
		return native_call("exercise.hint", { id = id or 0, text = text })
	end,

	advance = function(id)
		return native_call("exercise.advance", { id = id or 0 })
	end,
}

-- ── MOD ENVIRONMENT ─────────────────────────────────────────────────────────

mod_env._G = mod_env
mod_env._VERSION = _VERSION
mod_env.string = safe_string
mod_env.table = safe_table
mod_env.math = safe_math
mod_env.utf8 = safe_utf8
mod_env.pcall = protected_pcall
mod_env.xpcall = protected_xpcall
mod_env.error = raw_error
mod_env.assert = raw_assert
mod_env.type = raw_type
mod_env.tostring = raw_tostring
mod_env.tonumber = raw_tonumber
mod_env.pairs = raw_pairs
mod_env.ipairs = raw_ipairs
mod_env.next = raw_next
mod_env.select = raw_select
mod_env.rawget = raw_rawget
mod_env.rawset = raw_rawset
mod_env.rawequal = raw_rawequal
mod_env.rawlen = raw_rawlen
mod_env.require = require_module
mod_env.editor = editor

mod_env.print = function(...)
	local parts = {}
	for index = 1, raw_select("#", ...) do
		parts[index] = raw_tostring(raw_select(index, ...))
	end
	call_native("log", { level = "info", message = raw_concat(parts, "\t") })
end

mod_env.load = function(chunk, name, mode, env)
	if raw_type(chunk) ~= "string" then
		return nil, "source must be a string"
	end
	if safe_string.sub(chunk, 1, 1) == "\27" then
		return nil, "binary chunks are not allowed"
	end
	return raw_load(chunk, name or "@mod", "t", env or mod_env)
end

-- ── HOST BOUNDARY ───────────────────────────────────────────────────────────

function __griddy_load_mod(source, name)
	if raw_type(source) ~= "string" then
		return { ok = false, err = "source must be a string" }
	end
	if safe_string.len(source) > MAX_SOURCE_BYTES then
		return { ok = false, err = "the entry file is larger than the source limit" }
	end

	local chunk, compile_err = raw_load(source, name or "@mod", "t", mod_env)
	if not chunk then
		return { ok = false, err = raw_tostring(compile_err) }
	end

	return { ok = true, task = new_task(chunk) }
end

function __griddy_resume(id)
	local task = tasks[id]
	if task == nil then
		return { ok = false, err = "task not found", dead = true }
	end

	local co = task.co
	counts[co] = 0

	local previous = current_task
	current_task = id
	local packed = raw_pack(co_resume(co))
	current_task = previous
	-- table.pack carries an `n` field, which marshals to a JSON object instead of
	-- an array. Drop the leading resume status and keep the chunk's own return
	-- values as a dense list.
	local ok = packed[1]
	local results = {}
	for index = 2, packed.n do
		results[index - 1] = packed[index]
	end

	local status = co_status(co)
	if status == "dead" then
		tasks[id] = nil
	end

	if not ok then
		if packed[2] == SENTINEL then
			return { ok = false, timeout = true, dead = true, err = "budget.exceeded" }
		end
		return { ok = false, err = raw_tostring(packed[2]), dead = status == "dead" }
	end

	if status ~= "dead" and raw_type(results[1]) == "table" and results[1].__griddy_wait ~= nil then
		return { ok = true, waiting = true, wait_ms = results[1].__griddy_wait, dead = false }
	end

	return { ok = true, values = results, dead = status == "dead" }
end

function __griddy_invoke(handle, payload)
	local fn = handlers[handle]
	if fn == nil then
		return { ok = false, err = "handler not found", missing = true }
	end
	return { ok = true, task = new_task(function() return fn(payload) end) }
end

function __griddy_call_global(name)
	local fn = mod_env[name]
	if raw_type(fn) ~= "function" then
		return { ok = true, missing = true }
	end
	return { ok = true, task = new_task(function() return fn() end) }
end

function __griddy_cancel(id)
	if tasks[id] ~= nil then
		tasks[id] = nil
		return true
	end
	return false
end

function __griddy_set_budget(limit, step)
	local next_limit = raw_tonumber(limit)
	local next_step = raw_tonumber(step)
	if next_limit ~= nil and next_limit >= 1 then
		LIMIT = raw_max(1, raw_floor(next_limit))
	end
	if next_step ~= nil and next_step >= 1 then
		STEP = raw_max(1, raw_floor(next_step))
	end
	return { limit = LIMIT, step = STEP, instructions = LIMIT * STEP }
end

function __griddy_task_count()
	local count = 0
	for _ in raw_pairs(tasks) do
		count = count + 1
	end
	return count
end

function __griddy_handler_count()
	local count = 0
	for _ in raw_pairs(handlers) do
		count = count + 1
	end
	return count
end

function __griddy_has_handler(handle)
	return handlers[handle] ~= nil
end

function __griddy_drop_handler(handle)
	handlers[handle] = nil
end

function __griddy_collect()
	raw_collectgarbage("collect")
	return raw_collectgarbage("count")
end

function __griddy_shutdown()
	tasks = {}
	counts = {}
	handlers = {}
	module_cache = {}
	module_loading = {}
	subscriptions = {}
	commands = {}
	return true
end

-- The trusted libs must not be reachable after bootstrap. Mods only ever see
-- mod_env, but clearing the real globals also keeps a pulled function from
-- finding them later.
debug = nil
__griddy_config = nil
__griddy_native = nil
