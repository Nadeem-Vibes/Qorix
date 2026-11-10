extends RefCounted

## E2 — Runtime pinning and load.
##
## The checklist asks for the same class surface and Lua version in a packaged
## Windows release and Linux release. This run records the shipped files and
## the host binary actually used; packaged-build verification stays pending
## until an exported build is run through the same probe.

const Util = preload("res://tools/probes/lua-runtime/probe_util.gd")
const EXTENSION := "res://addons/luaAPI/luaAPI.gdextension"
const BINARIES := [
	"res://addons/luaAPI/bin/libluaapi.windows.template_debug.x86_64.dll",
	"res://addons/luaAPI/bin/libluaapi.windows.template_release.x86_64.dll",
	"res://addons/luaAPI/bin/libluaapi.linux.template_debug.x86_64.so",
	"res://addons/luaAPI/bin/libluaapi.linux.template_release.x86_64.so",
]


func run(_ctx: Dictionary) -> Dictionary:
	var checks: Array = []
	var limitations: Array = []

	var class_present := ClassDB.class_exists("LuaAPI")
	checks.append(Util.check("class_present", class_present, "LuaAPI class in ClassDB: %s" % str(class_present)))

	var extension_hash := Util.sha256_file(EXTENSION)
	checks.append(Util.check("extension_hash", !extension_hash.is_empty(), "sha256(luaAPI.gdextension)=%s" % extension_hash))

	var hashes: Dictionary = {}
	for path in BINARIES:
		var hash := Util.sha256_file(path)
		hashes[path.get_file()] = {
			"sha256": hash,
			"bytes": Util.file_size(path),
		}
		checks.append(Util.check(
			"binary_" + str(path.get_file()),
			!hash.is_empty(),
			"%s sha256=%s bytes=%d" % [path.get_file(), hash, Util.file_size(path)],
		))

	var extension_list := FileAccess.get_file_as_string("res://.godot/extension_list.cfg")
	var listed := extension_list.contains("res://addons/luaAPI/luaAPI.gdextension")
	checks.append(Util.check(
		"extension_list",
		listed,
		".godot/extension_list.cfg lists the addon: %s" % str(listed),
	))

	var version := ""
	var memory_usage := -1
	var memory_limit := -1
	if class_present:
		var lua: LuaAPI = LuaAPI.new()
		lua.bind_libraries(["base", "table", "string"])
		lua.set_memory_limit(24 * 1024 * 1024)
		var pulled: Variant = lua.pull_variant("_VERSION")
		version = str(pulled)
		memory_usage = int(lua.get_memory_usage())
		memory_limit = int(lua.get_memory_limit())
		lua = null

	checks.append(Util.check("lua_version", !version.is_empty(), "Lua version string: %s" % version))
	checks.append(Util.check(
		"memory_api",
		memory_limit == 24 * 1024 * 1024 and memory_usage > 0,
		"memory_limit=%d memory_usage=%d" % [memory_limit, memory_usage],
	))

	var packaged := !OS.has_feature("editor")
	if !packaged:
		limitations.append("This run used the editor binary. The packaged Windows release and Linux release checks in E2 are still pending.")
	else:
		checks.append(Util.check("packaged_build", true, "Running from a packaged build: %s" % OS.get_executable_path()))

	return {
		"probe": "E2",
		"title": "Runtime pinning and load",
		"status": Util.status(checks, limitations),
		"checks": checks,
		"limitations": limitations,
		"metrics": {
			"engine": Engine.get_version_info(),
			"editor_build": OS.has_feature("editor"),
			"executable": OS.get_executable_path(),
			"extension_sha256": extension_hash,
			"binary_sha256": hashes,
			"lua_version": version,
			"memory_limit": memory_limit,
			"memory_usage": memory_usage,
		},
		"notes": [
			"The plan requires the same pinned addon in packaged Windows debug/release and Linux release builds; those runs are not claimed here.",
			"Record this file's sha256 values in the build manifest before freezing the addon.",
		],
	}
