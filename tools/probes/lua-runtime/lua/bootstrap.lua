-- Phase 0 probe bootstrap.
--
-- Trusted code. Runs once per Lua state before any mod chunk. This mirrors the
-- execution model in section 5.3 of the architecture plan:
--   * every mod entry point runs in a host-created coroutine,
--   * a count hook on that coroutine raises a private sentinel,
--   * the mod environment has no debug/coroutine/io/os/package,
--   * pcall/xpcall are wrapped so a mod cannot swallow the sentinel.
--
-- This file is a probe artifact, not product code.

local sethook = debug.sethook
local co_create = coroutine.create
local co_resume = coroutine.resume
local co_status = coroutine.status
local co_running = coroutine.running
local raw_pcall = pcall
local raw_xpcall = xpcall
local raw_load = load
local raw_error = error
local raw_type = type
local raw_tostring = tostring
local raw_select = select
local raw_pairs = pairs
local raw_ipairs = ipairs
local raw_collectgarbage = collectgarbage

local SENTINEL = {}
local tasks = {}
local counts = {}
local next_task_id = 0
local LIMIT = 1000
local STEP = 1000
local log_lines = {}

local function log_line(level, message)
	local text = raw_tostring(message)
	if level then
		text = level .. " " .. text
	end
	log_lines[#log_lines + 1] = text
end

local function hook()
	local co = co_running()
	if co == nil then
		return
	end

	local n = (counts[co] or 0) + 1
	counts[co] = n
	if n >= LIMIT then
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
		if handler then
			return handler(e)
		end
		return e
	end, ...)
	if not ok and err == SENTINEL then
		raw_error(SENTINEL, 0)
	end
	return ok, err
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

local mod_env = {}
mod_env._G = mod_env
mod_env._VERSION = _VERSION
mod_env.string = safe_string
mod_env.table = safe_table
mod_env.math = safe_math
mod_env.utf8 = safe_utf8
mod_env.pcall = protected_pcall
mod_env.xpcall = protected_xpcall
mod_env.error = raw_error
mod_env.assert = assert
mod_env.type = raw_type
mod_env.tostring = raw_tostring
mod_env.tonumber = tonumber
mod_env.pairs = raw_pairs
mod_env.ipairs = raw_ipairs
mod_env.next = next
mod_env.select = raw_select
mod_env.rawget = rawget
mod_env.rawset = rawset
mod_env.rawequal = rawequal
mod_env.rawlen = rawlen

mod_env.print = function(...)
	local parts = {}
	for i = 1, raw_select("#", ...) do
		parts[#parts + 1] = raw_tostring(raw_select(i, ...))
	end
	log_line(nil, table.concat(parts, "\t"))
end

mod_env.load = function(chunk, name, mode, env)
	if raw_type(chunk) ~= "string" then
		return nil, "source must be a string"
	end
	if chunk:sub(1, 1) == "\27" then
		return nil, "binary chunks are not allowed"
	end
	return raw_load(chunk, name or "@mod", "t", env or mod_env)
end

local editor = {}
editor.api_version = 1
editor.mod = { id = "phase0.probe", name = "Phase 0 Probe", version = "0.0.1" }
editor.log = {
	info = function(message) log_line("INFO", message) end,
	warn = function(message) log_line("WARN", message) end,
	error = function(message) log_line("ERROR", message) end,
}
editor.test = {}
mod_env.editor = editor

-- Probe-only native boundary. The host may replace __probe_native with a
-- Callable; mod code reaches it only through editor.test.
editor.test.call_native = function(value)
	if __probe_native == nil then
		return nil, "no native callback"
	end
	return __probe_native(value)
end

editor.test.native_available = function()
	return __probe_native ~= nil
end

local function new_task(fn)
	local co = co_create(fn)
	counts[co] = 0
	sethook(co, hook, "", STEP)
	next_task_id = next_task_id + 1
	local id = next_task_id
	tasks[id] = co
	return id
end

function __griddy_load_mod(source, name)
	if raw_type(source) ~= "string" then
		return { ok = false, err = "source must be a string" }
	end

	local fn, err = raw_load(source, name or "@mod", "t", mod_env)
	if not fn then
		return { ok = false, err = raw_tostring(err) }
	end

	return { ok = true, task = new_task(fn) }
end

function __griddy_resume(id)
	local co = tasks[id]
	if not co then
		return { ok = false, err = "no task" }
	end

	counts[co] = 0
	local results = table.pack(co_resume(co))
	local dead = co_status(co) == "dead"
	if dead then
		tasks[id] = nil
	end

	if not results[1] then
		if results[2] == SENTINEL then
			return { ok = false, timeout = true, dead = true, err = "budget.exceeded" }
		end
		return { ok = false, err = raw_tostring(results[2]), dead = dead }
	end

	return { ok = true, values = results, dead = dead }
end

function __griddy_set_budget(limit, step)
	LIMIT = math.max(1, math.floor(tonumber(limit) or LIMIT))
	STEP = math.max(1, math.floor(tonumber(step) or STEP))
	return { limit = LIMIT, step = STEP, instructions = LIMIT * STEP }
end

function __griddy_task_count()
	local count = 0
	for _ in raw_pairs(tasks) do
		count = count + 1
	end
	return count
end

function __griddy_status(id)
	local co = tasks[id]
	if not co then
		return "missing"
	end
	return co_status(co)
end

function __griddy_drain_log()
	local out = log_lines
	log_lines = {}
	return out
end

function __griddy_collect()
	raw_collectgarbage("collect")
	return raw_collectgarbage("count")
end

-- No trusted debug library remains reachable after bootstrap.
debug = nil
