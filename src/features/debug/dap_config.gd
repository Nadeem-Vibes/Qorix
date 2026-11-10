extends RefCounted

## Built-in debug-adapter definitions plus layered per-project configuration.
##
## A profile describes how to start one adapter and how to launch a program
## through it. Nothing here starts a process or opens a socket; DapClient owns
## the transport and DapManager owns the session.
##
## Config files, lowest priority first:
##   built-in adapters
##   user://debug.json
##   <workspace>/.griddycode.json          (the "debug" key)
##   <workspace>/.griddycode/debug.json
##
## Shape:
##   {
##     "debug": {
##       "python": {
##         "command": "python",
##         "args": ["-m", "debugpy.adapter", "--host", "127.0.0.1", "--port", "$port"],
##         "launch": { "justMyCode": false }
##       }
##     }
##   }
##
## Python is the first fully supported adapter. Node.js, LLDB, GDB and Delve
## profiles are scaffolded so the menu and install cards can name them, but
## their `implemented` flag stays false until a transport adapter ships.

const Paths = preload("res://src/base/path_utils.gd")

const LANGUAGE_ALIASES := {
	"python": "python", "py": "python", "python3": "python", "pyw": "python",
	"javascript": "node", "js": "node", "node": "node", "nodejs": "node",
	"typescript": "node", "ts": "node", "jsx": "node", "tsx": "node",
	"c": "lldb", "h": "lldb", "cpp": "lldb", "c++": "lldb", "cxx": "lldb",
	"rust": "lldb", "rs": "lldb",
	"go": "go", "golang": "go",
}

const DEFAULT_ADAPTERS := {
	"python": {
		"display": "Python (debugpy)",
		"extensions": ["py", "pyw"],
		"languages": ["python"],
		"commands": ["python", "python3", "py"],
		"command": "python",
		"args": ["-m", "debugpy.adapter", "--host", "127.0.0.1", "--port", "$port"],
		"launch": {
			"type": "python",
			"request": "launch",
			"program": "$file",
			"cwd": "$dir",
			"console": "internalConsole",
			"justMyCode": true,
			"stopOnEntry": false,
		},
		"implemented": true,
		"install": {
			"title": "Python debugging needs debugpy",
			"hint": "Qorix starts Python's debug adapter from the interpreter already on PATH. Install the debugpy package once, then reopen Qorix so the adapter can start.",
			"commands": ["python -m pip install debugpy"],
			"url": "https://github.com/microsoft/debugpy",
			"url_label": "Open the debugpy installation guide",
		},
	},
	"node": {
		"display": "Node.js (planned)",
		"extensions": ["js", "mjs", "cjs", "jsx", "ts", "tsx"],
		"languages": ["javascript", "typescript"],
		"commands": [],
		"command": "",
		"args": [],
		"launch": {},
		"implemented": false,
		"install": {
			"title": "Node.js debugging is planned",
			"hint": "The DAP transport and debug UI are adapter-neutral, but Qorix does not bundle Microsoft's js-debug adapter yet. Python/debugpy is available today.",
			"commands": [],
			"url": "https://github.com/microsoft/vscode-js-debug",
			"url_label": "About the js-debug adapter",
		},
	},
	"lldb": {
		"display": "C / C++ / Rust (LLDB, planned)",
		"extensions": ["c", "h", "cpp", "cc", "cxx", "hpp", "hh", "hxx", "rs"],
		"languages": ["c", "cpp", "rust"],
		"commands": ["lldb-dap", "lldb-vscode"],
		"command": "lldb-dap",
		"args": [],
		"launch": {},
		"implemented": false,
		"install": {
			"title": "Native debugging with LLDB is planned",
			"hint": "LLDB's DAP server ships with recent LLVM releases. Qorix will offer it as a native adapter; Python/debugpy is available today.",
			"commands": [],
			"url": "https://lldb.llvm.org/use/vsdebug.html",
			"url_label": "About LLDB's DAP support",
		},
	},
	"gdb": {
		"display": "C / C++ (GDB, planned)",
		"extensions": ["c", "h", "cpp", "cc", "cxx"],
		"languages": ["c", "cpp"],
		"commands": ["gdb"],
		"command": "gdb",
		"args": [],
		"launch": {},
		"implemented": false,
		"install": {
			"title": "GDB debugging is planned",
			"hint": "GDB 14 and newer include a DAP mode. Python/debugpy is the supported adapter today.",
			"commands": [],
			"url": "https://sourceware.org/gdb/",
			"url_label": "About GDB",
		},
	},
	"go": {
		"display": "Go (Delve, planned)",
		"extensions": ["go"],
		"languages": ["go"],
		"commands": ["dlv"],
		"command": "dlv",
		"args": [],
		"launch": {},
		"implemented": false,
		"install": {
			"title": "Go debugging with Delve is planned",
			"hint": "Delve exposes a DAP server. Python/debugpy is the supported adapter today.",
			"commands": ["go install github.com/go-delve/delve/cmd/dlv@latest"],
			"url": "https://github.com/go-delve/delve",
			"url_label": "About Delve",
		},
	},
}

const EXTENSION_ADAPTERS := {
	"py": "python", "pyw": "python",
	"js": "node", "mjs": "node", "cjs": "node", "jsx": "node",
	"ts": "node", "tsx": "node",
	"c": "lldb", "h": "lldb", "cpp": "lldb", "cc": "lldb", "cxx": "lldb",
	"hpp": "lldb", "hh": "lldb", "hxx": "lldb", "rs": "lldb",
	"go": "go",
}

var platform: String = ""
var path_env: String = ""
var pathext: String = ""
var exists_override: Callable = Callable()
## Optional PATH lookup owned by the caller (DapManager passes RuntimeCatalog).
var executable_resolver: Callable = Callable()

## Optional consent gate. Called with the workspace root; when it returns
## false, the project's .griddycode.json and .griddycode/debug.json are
## ignored. A debug config names an executable, so an untrusted clone must not
## be able to start one merely by being opened.
var workspace_trust: Callable = Callable()

var adapters: Dictionary = {}
var config_errors: Array = []
var loaded_sources: Array = []


func _init(p_platform: String = "", p_path_env: Variant = null, p_pathext: String = "",
		p_exists: Callable = Callable()) -> void:
	platform = p_platform if !p_platform.is_empty() else ("windows" if OS.get_name() == "Windows" else "posix")
	path_env = OS.get_environment("PATH") if p_path_env == null else str(p_path_env)
	pathext = p_pathext if !p_pathext.is_empty() else OS.get_environment("PATHEXT")
	if pathext.is_empty():
		pathext = ".COM;.EXE;.BAT;.CMD"
	exists_override = p_exists
	reset_adapters()


func is_windows() -> bool:
	return platform == "windows"


func reset_adapters() -> void:
	adapters.clear()
	for key in DEFAULT_ADAPTERS.keys():
		var entry: Dictionary = DEFAULT_ADAPTERS[key].duplicate(true)
		entry["id"] = key
		entry["custom"] = false
		entry["enabled"] = true
		adapters[key] = entry
	config_errors.clear()
	loaded_sources.clear()


## Loads the global override and the project overrides. Returns
## {ok, errors, sources}.
func load_for_project(workspace_root: String, global_path: String = "user://debug.json") -> Dictionary:
	reset_adapters()
	_load_file(global_path, "debug")

	var root := Paths.normalize(workspace_root)
	var restricted := !root.is_empty() and workspace_trust.is_valid() \
		and !bool(workspace_trust.call(root))
	if !root.is_empty() and !restricted:
		_load_file(root.path_join(".griddycode.json"), "debug")
		_load_file(root.path_join(".griddycode").path_join("debug.json"), "debug")

	return {
		"ok": config_errors.is_empty(),
		"errors": config_errors.duplicate(true),
		"sources": loaded_sources.duplicate(),
		"restricted": restricted,
	}


## Applies one parsed config object (used by tests and .griddycode.json).
func apply_config(data: Variant, source: String = "config") -> Dictionary:
	if !(data is Dictionary):
		config_errors.append({"source": source, "error": "The debug config is not a JSON object."})
		return {"ok": false, "error": "The debug config is not a JSON object."}

	var object: Dictionary = data
	if object.get("debug") is Dictionary:
		object = object["debug"]
	elif object.get("adapters") is Dictionary:
		object = object["adapters"]

	for raw_key in object.keys():
		var key := str(raw_key).strip_edges().to_lower()
		if key.is_empty() or key == "enabled" or key == "adapters" or key == "debug":
			continue
		_apply_adapter(key, object[raw_key], source)
	return {"ok": true, "error": ""}


func _load_file(path: String, key: String = "debug") -> void:
	if path.is_empty() or !_file_exists(path):
		return

	var text := FileAccess.get_file_as_string(path)
	if text.strip_edges().is_empty():
		config_errors.append({"source": path, "error": "The file is empty."})
		return

	var parsed: Variant = JSON.parse_string(text)
	if !(parsed is Dictionary):
		config_errors.append({"source": path, "error": "The file is not a JSON object."})
		return

	loaded_sources.append(path)
	if key == "debug" and parsed.get("debug") is Dictionary:
		parsed = parsed["debug"]
	apply_config(parsed, path)


func _apply_adapter(key: String, raw: Variant, source: String) -> void:
	var entry: Dictionary
	if adapters.has(key):
		entry = adapters[key]
	else:
		entry = {
			"id": key,
			"display": key.capitalize(),
			"extensions": [],
			"languages": [],
			"commands": [],
			"command": "",
			"args": [],
			"launch": {},
			"implemented": true,
			"custom": true,
			"enabled": true,
			"install": {},
		}

	if raw is String:
		entry["command"] = str(raw)
		entry["commands"] = [str(raw)]
	elif raw is Dictionary:
		var object: Dictionary = raw
		for field in ["display", "command"]:
			if object.has(field):
				entry[field] = str(object[field])
		for field in ["extensions", "languages", "commands", "args"]:
			if object.get(field) is Array:
				entry[field] = (object[field] as Array).duplicate()
		if object.get("launch") is Dictionary:
			var launch: Dictionary = entry.get("launch", {}).duplicate(true)
			launch.merge(object["launch"], true)
			entry["launch"] = launch
		if object.get("install") is Dictionary:
			entry["install"] = (object["install"] as Dictionary).duplicate(true)
		if object.has("implemented"):
			entry["implemented"] = bool(object["implemented"])
		if object.has("enabled"):
			entry["enabled"] = bool(object["enabled"])
		if object.has("command") and entry["commands"] is Array and (entry["commands"] as Array).is_empty():
			entry["commands"] = [str(object["command"])]
	else:
		config_errors.append({"source": source, "error": "Adapter \"%s\" is not an object or command string." % key})
		return

	entry["custom"] = bool(entry.get("custom", false)) or !DEFAULT_ADAPTERS.has(key)
	adapters[key] = entry


## Adapter profile for one file, honouring a detected language override first.
func adapter_for_path(path: String, language: String = "") -> Dictionary:
	var id := adapter_id_for_path(path, language)
	return adapters.get(id, {}) if !id.is_empty() else {}


func adapter_id_for_path(path: String, language: String = "") -> String:
	var key := str(language).strip_edges().to_lower()
	if !key.is_empty() and LANGUAGE_ALIASES.has(key):
		var candidate := str(LANGUAGE_ALIASES[key])
		if adapters.has(candidate):
			return candidate
	var extension := str(path).get_extension().to_lower()
	if EXTENSION_ADAPTERS.has(extension):
		var by_extension := str(EXTENSION_ADAPTERS[extension])
		if adapters.has(by_extension):
			return by_extension
	for id in adapters.keys():
		var row: Dictionary = adapters[id]
		var extensions: Variant = row.get("extensions", [])
		if extensions is Array and (extensions as Array).has(extension):
			return str(id)
		var languages: Variant = row.get("languages", [])
		if !key.is_empty() and languages is Array and (languages as Array).has(key):
			return str(id)
	return ""


func adapter(id: String) -> Dictionary:
	return adapters.get(str(id), {})


func adapter_rows() -> Array:
	var rows: Array = []
	for id in adapters.keys():
		var row: Dictionary = adapters[id]
		rows.append({
			"id": str(id),
			"display": str(row.get("display", id)),
			"extensions": row.get("extensions", []),
			"implemented": bool(row.get("implemented", false)),
			"enabled": bool(row.get("enabled", true)),
			"found": !str(row.get("command", "")).is_empty() and !_resolve_command(row).is_empty(),
			"command": str(row.get("command", "")),
			"install": row.get("install", {}),
		})
	rows.sort_custom(func(a, b) -> bool: return str(a.display).naturalnocasecmp_to(str(b.display)) < 0)
	return rows


## Turns a profile into everything DapClient needs to start. The returned
## `launch` object has placeholders resolved and is safe to send as-is.
## Returns {ok, error, adapter_id, display, command_path, args, launch, cwd,
## install, implemented}.
func resolve(profile: Dictionary, file_path: String, workspace_root: String = "", port: int = 0) -> Dictionary:
	var id := str(profile.get("id", ""))
	var display := str(profile.get("display", id))
	var install: Variant = profile.get("install", {})
	var help: Dictionary = install if install is Dictionary else {}

	if profile.is_empty():
		return {"ok": false, "error": "No debug adapter is configured for this file.", "install": help, "adapter_id": id}
	if !bool(profile.get("enabled", true)):
		return {"ok": false, "error": "%s debugging is disabled in the debug config." % display, "install": help, "adapter_id": id}
	if !bool(profile.get("implemented", false)):
		return {
			"ok": false,
			"error": "%s is scaffolded but not implemented yet. Python (debugpy) is the supported adapter in this build." % display,
			"install": help,
			"adapter_id": id,
			"implemented": false,
		}

	var file := Paths.normalize(file_path)
	if file.is_empty():
		return {"ok": false, "error": "Open a saved file before starting the debugger.", "install": help, "adapter_id": id}
	var dir := file.get_base_dir()
	var workspace := Paths.normalize(workspace_root)
	if workspace.is_empty():
		workspace = dir

	var command_path := _resolve_command(profile)
	if command_path.is_empty():
		var command := str(profile.get("command", ""))
		return {
			"ok": false,
			"error": "The debug adapter command \"%s\" was not found on PATH." % command,
			"install": help,
			"adapter_id": id,
			"executable": command,
		}

	# The resolved interpreter path also answers `$python` inside a launch
	# object, which is what debugpy wants when the target must use the same
	# interpreter as the adapter.
	var tokens := {
		"$port": str(port),
		"$file": file,
		"$dir": dir,
		"$workspace": workspace,
		"$python": command_path,
	}

	var args: Array = []
	var raw_args: Variant = profile.get("args", [])
	if raw_args is Array:
		for argument in raw_args:
			args.append(substitute(str(argument), tokens))

	var launch: Dictionary = {}
	var raw_launch: Variant = profile.get("launch", {})
	if raw_launch is Dictionary:
		launch = _substitute_object(raw_launch, tokens)
	if !launch.has("request"):
		launch["request"] = "launch"
	if !launch.has("program") and file != "":
		launch["program"] = file
	if !launch.has("cwd"):
		launch["cwd"] = dir

	return {
		"ok": true,
		"error": "",
		"adapter_id": id,
		"display": display,
		"command_path": command_path,
		"args": args,
		"launch": launch,
		"cwd": str(launch.get("cwd", dir)),
		"install": help,
		"implemented": true,
	}


## Replaces $port / $file / $dir / $workspace / $python in a string.
static func substitute(text: String, tokens: Dictionary) -> String:
	var out := text
	for key in tokens.keys():
		out = out.replace(str(key), str(tokens[key]))
	return out


func _substitute_object(value: Variant, tokens: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	if value is Dictionary:
		for key in (value as Dictionary).keys():
			out[str(key)] = _substitute_value((value as Dictionary)[key], tokens)
	return out


func _substitute_value(value: Variant, tokens: Dictionary) -> Variant:
	if value is String:
		return substitute(str(value), tokens)
	if value is Array:
		var list: Array = []
		for item in value:
			list.append(_substitute_value(item, tokens))
		return list
	if value is Dictionary:
		return _substitute_object(value, tokens)
	return value


func install_help(id: String) -> Dictionary:
	var row := adapter(id)
	var help: Variant = row.get("install", {})
	return help if help is Dictionary else {}


func supported_display() -> String:
	var names: Array[String] = []
	for id in adapters.keys():
		if bool(adapters[id].get("implemented", false)):
			names.append(str(adapters[id].get("display", id)))
	return ", ".join(names)


func _resolve_command(profile: Dictionary) -> String:
	var candidates: Array = []
	var raw: Variant = profile.get("commands", [])
	if raw is Array:
		candidates = (raw as Array).duplicate()
	var primary := str(profile.get("command", "")).strip_edges()
	if !primary.is_empty() and !candidates.has(primary):
		candidates.push_front(primary)
	for candidate in candidates:
		var name := str(candidate).strip_edges()
		if name.is_empty():
			continue
		var resolved := _find_executable(name)
		if !resolved.is_empty():
			return resolved
	return ""


func _find_executable(name: String) -> String:
	if executable_resolver.is_valid():
		return str(executable_resolver.call(name))
	return find_executable(name)


## PATH + PATHEXT lookup. Kept here so a DapConfig works without RuntimeCatalog
## (tests, future editors, headless callers).
func find_executable(name: String) -> String:
	var clean := name.strip_edges().trim_prefix("\"").trim_suffix("\"")
	if clean.is_empty():
		return ""
	if clean.contains("/") or clean.contains("\\") or (clean.length() > 1 and clean[1] == ":"):
		return clean if _exists(clean) else ""
	if path_env.is_empty():
		return ""

	var separator := ";" if is_windows() else ":"
	var folders := path_env.split(separator, false)
	var extensions: Array[String] = [""]
	if is_windows() and !_has_extension(clean):
		for extension in pathext.split(";", false):
			var trimmed := extension.strip_edges()
			if !trimmed.is_empty():
				extensions.append(trimmed)
				if trimmed != trimmed.to_lower():
					extensions.append(trimmed.to_lower())

	for folder in folders:
		var base := str(folder).strip_edges().trim_suffix("\\").trim_suffix("/")
		if base.is_empty():
			continue
		for extension in extensions:
			var candidate := base + "/" + clean + extension
			if _exists(candidate):
				return candidate
	return ""


static func _has_extension(name: String) -> bool:
	var file := name.get_file()
	var dot := file.rfind(".")
	return dot > 0 and dot < file.length() - 1


func _exists(path: String) -> bool:
	if exists_override.is_valid():
		return bool(exists_override.call(path))
	return FileAccess.file_exists(path)


func _file_exists(path: String) -> bool:
	if exists_override.is_valid() and !path.begins_with("user://") and !path.begins_with("res://"):
		return bool(exists_override.call(path))
	return FileAccess.file_exists(path)
