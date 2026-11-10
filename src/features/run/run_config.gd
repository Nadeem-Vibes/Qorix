extends RefCounted

## Resolves "how do I run this file?" for one project.
##
## Configuration is layered, lowest priority first:
##   1. Qorix's built-in profiles
##   2. user://run.json
##   3. <workspace>/.griddycode.json
##   4. <workspace>/.griddycode/run.json
##
## The on-disk shape is intentionally the small one from the roadmap:
##
##   {
##     "run": {
##       "python": { "command": "python -u $file", "cwd": "$workspace" },
##       "node":   { "command": "node $file", "cwd": "$dir" },
##       "server": {
##         "command": "python -u $file", "cwd": "$workspace",
##         "extensions": ["py"], "mode": "terminal"
##       }
##     }
##   }
##
## Everything here is pure data + string work: no nodes, no PTY, no UI, so the
## headless suite can exercise the resolution rules without launching a shell.

const Paths = preload("res://src/base/path_utils.gd")

## One entry per language family. `extensions`/`aliases` decide matching;
## `runtimes` tells the preflight which executables must exist. Commands are
## shell snippets with placeholders, not argv arrays: users can write pipelines,
## `&&` chains and redirections just like in the terminal.
const DEFAULT_PROFILES := {
	"python": {
		"display": "Python", "language": "python",
		"extensions": ["py", "pyw", "pyi"], "aliases": ["py", "python3"],
		"command": "python -u $file", "cwd": "$dir", "runtimes": ["python"],
		# Most beginner Python programs call input(). Captured runs cannot
		# answer a prompt, so RunService sends detectable stdin readers to the
		# terminal instead of failing them with EOFError.
		"auto_terminal": true,
	},
	"javascript": {
		"display": "JavaScript", "language": "javascript",
		"extensions": ["js", "mjs", "cjs", "jsx"], "aliases": ["js", "node"],
		"command": "node $file", "cwd": "$dir", "runtimes": ["node"],
	},
	"typescript": {
		"display": "TypeScript", "language": "typescript",
		"extensions": ["ts", "tsx"], "aliases": ["ts"],
		"command": "node $file", "cwd": "$dir", "runtimes": ["node"],
	},
	"lua": {
		"display": "Lua", "language": "lua",
		"extensions": ["lua"], "aliases": [],
		"command": "lua $file", "cwd": "$dir", "runtimes": ["lua"],
	},
	"ruby": {
		"display": "Ruby", "language": "ruby",
		"extensions": ["rb"], "aliases": ["rb"],
		"command": "ruby $file", "cwd": "$dir", "runtimes": ["ruby"],
	},
	"php": {
		"display": "PHP", "language": "php",
		"extensions": ["php"], "aliases": [],
		"command": "php $file", "cwd": "$dir", "runtimes": ["php"],
	},
	"go": {
		"display": "Go", "language": "go",
		"extensions": ["go"], "aliases": ["golang"],
		"command": "go run $file", "cwd": "$dir", "runtimes": ["go"],
	},
	"perl": {
		"display": "Perl", "language": "perl",
		"extensions": ["pl", "pm"], "aliases": [],
		"command": "perl $file", "cwd": "$dir", "runtimes": ["perl"],
	},
	"r": {
		"display": "R", "language": "r",
		"extensions": ["r"], "aliases": [],
		"command": "Rscript $file", "cwd": "$dir", "runtimes": ["Rscript"],
	},
	"shell": {
		"display": "Shell", "language": "shell",
		"extensions": ["sh", "bash", "zsh"], "aliases": ["sh", "bash"],
		"command": "bash $file", "cwd": "$dir", "runtimes": ["bash"],
	},
	"batch": {
		"display": "Windows batch", "language": "batch",
		"extensions": ["bat", "cmd"], "aliases": ["cmd"],
		"command": "$file", "cwd": "$dir", "runtimes": [],
	},
	"powershell": {
		"display": "PowerShell", "language": "powershell",
		"extensions": ["ps1"], "aliases": ["ps"],
		"command": "powershell -ExecutionPolicy ByPass -File $file", "cwd": "$dir",
		"runtimes": ["powershell"],
	},
	"dart": {
		"display": "Dart", "language": "dart",
		"extensions": ["dart"], "aliases": [],
		"command": "dart run $file", "cwd": "$dir", "runtimes": ["dart"],
	},
	"zig": {
		"display": "Zig", "language": "zig",
		"extensions": ["zig"], "aliases": [],
		"command": "zig run $file", "cwd": "$dir", "runtimes": ["zig"],
	},
	"nim": {
		"display": "Nim", "language": "nim",
		"extensions": ["nim"], "aliases": [],
		"command": "nim compile --verbosity:0 --hints:off --run $file", "cwd": "$dir",
		"runtimes": ["nim"],
	},
	"haskell": {
		"display": "Haskell", "language": "haskell",
		"extensions": ["hs"], "aliases": [],
		"command": "runghc $file", "cwd": "$dir", "runtimes": ["runghc"],
	},
	"gleam": {
		"display": "Gleam", "language": "gleam",
		"extensions": ["gleam"], "aliases": [],
		"command": "gleam run -m $fileNameWithoutExt", "cwd": "$dir", "runtimes": ["gleam"],
	},
	"elixir": {
		"display": "Elixir", "language": "elixir",
		"extensions": ["exs", "ex"], "aliases": [],
		"command": "elixir $file", "cwd": "$dir", "runtimes": ["elixir"],
	},
	"rust": {
		"display": "Rust", "language": "rust",
		"extensions": ["rs"], "aliases": [],
		"command": "rustc $file -o $fileNoExt && $fileNoExt", "cwd": "$dir",
		"runtimes": ["rustc"],
	},
	"c": {
		"display": "C", "language": "c",
		"extensions": ["c"], "aliases": [],
		"command": "gcc $file -o $fileNoExt && $fileNoExt", "cwd": "$dir",
		"runtimes": ["gcc"],
	},
	"cpp": {
		"display": "C++", "language": "cpp",
		"extensions": ["cpp", "cc", "cxx", "c++"], "aliases": ["c++"],
		"command": "g++ $file -o $fileNoExt && $fileNoExt", "cwd": "$dir",
		"runtimes": ["g++"],
	},
	"java": {
		"display": "Java", "language": "java",
		"extensions": ["java"], "aliases": [],
		"command": "javac $fileName && java $fileNameWithoutExt", "cwd": "$dir",
		"runtimes": ["javac", "java"],
	},
}

const DEFAULT_CONFIG_TEXT := """{
  "run": {
    "python": {
      "command": "python -u $file",
      "cwd": "$workspace"
    },
    "node": {
      "command": "node $file",
      "cwd": "$dir"
    },
    "server": {
      "command": "python -u $file",
      "cwd": "$workspace",
      "extensions": ["py"],
      "mode": "terminal"
    }
  }
}
"""

const SHELL_LANGUAGES := {
	"python": "python", "python2": "python", "python3": "python",
	"node": "javascript", "nodejs": "javascript", "deno": "javascript",
	"ruby": "ruby", "perl": "perl", "php": "php", "lua": "lua",
	"bash": "shell", "sh": "shell", "zsh": "shell", "dash": "shell",
	"Rscript": "r", "rustc": "rust", "go": "go", "javac": "java",
}

var profiles: Dictionary = {}
var sources: Array = []
var errors: Array = []

var workspace_root: String = ""
var file_path: String = ""
var file_text: String = ""
var respect_shebang: bool = true
var platform: String = ""
var search_path: String = "user://run.json"


func _init() -> void:
	platform = "windows" if OS.get_name() == "Windows" else "posix"
	reset()


func reset() -> void:
	profiles = DEFAULT_PROFILES.duplicate(true)
	sources.clear()
	errors.clear()
	workspace_root = ""
	file_path = ""
	file_text = ""
	respect_shebang = true


## Optional consent gate, same contract as LspConfig.workspace_trust. Run
## profiles name a shell command, so an untrusted workspace must not supply
## them.
var workspace_trust: Callable = Callable()


## Loads every layer for one file. The returned Dictionary mirrors the fields
## so a caller can log exactly which files contributed and which lines failed.
func load_for_project(
	p_workspace_root: String,
	p_file_path: String,
	p_file_text: String = "",
	p_respect_shebang: bool = true,
	p_search_path: String = "user://run.json"
) -> Dictionary:
	reset()

	workspace_root = Paths.normalize(p_workspace_root)
	file_path = Paths.normalize(p_file_path)
	file_text = p_file_text
	respect_shebang = p_respect_shebang
	search_path = p_search_path

	if !search_path.is_empty():
		_load_config_file(search_path)

	var restricted := !workspace_root.is_empty() and workspace_trust.is_valid() \
		and !bool(workspace_trust.call(workspace_root))
	if !workspace_root.is_empty() and !restricted:
		for relative in [".griddycode.json", ".griddycode/run.json"]:
			var path := workspace_root.path_join(relative)
			if FileAccess.file_exists(path):
				_load_config_file(path)

	return {
		"ok": errors.is_empty(),
		"profiles": profiles.size(),
		"sources": sources.duplicate(),
		"errors": errors.duplicate(),
		"restricted": restricted,
	}


func _load_config_file(path: String) -> void:
	if !FileAccess.file_exists(path):
		return

	var text := FileAccess.get_file_as_string(path)
	if text.strip_edges().is_empty():
		errors.append("%s is empty." % path.get_file())
		return

	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		errors.append("%s is not a valid JSON object." % path.get_file())
		return

	apply_config(parsed, path)


## Public for tests and future "validate config" commands. Later layers win.
func apply_config(data: Dictionary, source: String = "<memory>") -> void:
	var run_data: Variant = data.get("run")
	if typeof(run_data) != TYPE_DICTIONARY:
		# Friendly shortcut: a bare map of profiles is accepted too.
		if _looks_like_profiles(data):
			run_data = data
		else:
			errors.append("%s has no \"run\" object." % source.get_file())
			return

	var accepted := 0
	for key in run_data.keys():
		var profile_id := str(key).strip_edges()
		if profile_id.is_empty():
			continue

		var raw: Variant = run_data[key]
		var incoming: Dictionary = {}
		if raw is String:
			incoming = {"command": str(raw)}
		elif raw is Dictionary:
			incoming = raw.duplicate(true)
		else:
			errors.append("%s: profile \"%s\" must be an object or a command string." % [source.get_file(), profile_id])
			continue

		var existing_id := _id_for_key(profile_id)
		var merged: Dictionary = profiles.get(existing_id, {}).duplicate(true)
		if merged.is_empty():
			merged = {"display": profile_id.capitalize(), "extensions": [], "aliases": []}

		for field in incoming.keys():
			merged[str(field)] = incoming[field]

		merged["id"] = existing_id
		merged["source"] = source
		merged["custom"] = true

		if !merged.has("command") or str(merged.get("command", "")).strip_edges().is_empty():
			errors.append("%s: profile \"%s\" has no command." % [source.get_file(), profile_id])
			continue

		_normalize_profile(merged, existing_id)
		profiles[existing_id] = merged
		accepted += 1

	if accepted > 0:
		sources.append(source)


func _looks_like_profiles(data: Dictionary) -> bool:
	if data.is_empty() || data.has("run"):
		return false
	for key in data.keys():
		var value: Variant = data[key]
		if !(value is Dictionary) and !(value is String):
			return false
		if value is Dictionary and !value.has("command"):
			return false
	return true


func _id_for_key(key: String) -> String:
	var normalized := _normalize_match(key)
	if profiles.has(normalized):
		return normalized

	for id in profiles.keys():
		var profile: Dictionary = profiles[id]
		if _list_has(profile.get("extensions", []), normalized):
			return str(id)
		if _list_has(profile.get("aliases", []), normalized):
			return str(id)
	return normalized


func _normalize_profile(profile: Dictionary, id: String) -> void:
	profile["id"] = id
	profile["display"] = str(profile.get("display", id.capitalize()))
	profile["language"] = str(profile.get("language", id)).to_lower()
	profile["extensions"] = _normalize_list(profile.get("extensions", []))
	profile["aliases"] = _normalize_list(profile.get("aliases", []))
	profile["match"] = _normalize_list(profile.get("match", []))
	profile["languages"] = _normalize_list(profile.get("languages", []))
	profile["runtimes"] = _normalize_list(profile.get("runtimes", []))
	if profile.has("runtime"):
		var runtime := str(profile.get("runtime", "")).strip_edges()
		profile["runtimes"] = [runtime] if !runtime.is_empty() else []
	profile["command"] = str(profile.get("command", "")).strip_edges()
	profile["cwd"] = str(profile.get("cwd", "$dir"))
	profile["mode"] = normalize_mode(profile.get("mode", "capture"), bool(profile.get("interactive", false)))
	profile["auto_terminal"] = bool(profile.get("auto_terminal", false))
	profile["append_file"] = bool(profile.get("append_file", true))
	profile["enabled"] = bool(profile.get("enabled", true))
	profile["default"] = bool(profile.get("default", id == "default"))


static func normalize_mode(value: Variant, interactive: bool = false) -> String:
	if interactive:
		return "terminal"
	var mode := str(value).strip_edges().to_lower()
	if mode in ["terminal", "interactive", "shell"]:
		return "terminal"
	return "capture"


static func _normalize_list(value: Variant) -> Array:
	var out: Array = []
	if value is String:
		value = [value]
	if !(value is Array):
		return out

	for item in value:
		var text := _normalize_match(str(item))
		if text.is_empty() or out.has(text):
			continue
		out.append(text)
	return out


static func _normalize_match(value: String) -> String:
	var text := value.strip_edges().to_lower()
	if text.begins_with("."):
		text = text.substr(1)
	if text.begins_with("*."):
		text = text.substr(2)
	return text


static func _list_has(list: Variant, value: String) -> bool:
	if !(list is Array):
		return false
	for item in list:
		if _normalize_match(str(item)) == value:
			return true
	return false


## The profile that should run `p_file_path`. Custom profiles always beat the
## built-in table so a project can override Python without editing source.
func profile_for(p_file_path: String = "", language: String = "") -> Dictionary:
	var path := Paths.normalize(p_file_path if !p_file_path.is_empty() else file_path)
	var extension := Paths.extension(path).to_lower()
	var lang := language.strip_edges().to_lower()

	var custom := _find_match(extension, lang, true)
	if !custom.is_empty():
		return custom

	if respect_shebang:
		var derived := shebang_profile()
		if !derived.is_empty():
			return derived

	var builtin := _find_match(extension, lang, false)
	if !builtin.is_empty():
		return builtin

	return _default_profile()


func _find_match(extension: String, language: String, custom_only: bool) -> Dictionary:
	for id in profiles.keys():
		var profile: Dictionary = profiles[id]
		if !bool(profile.get("enabled", true)):
			continue
		if custom_only and !bool(profile.get("custom", false)):
			continue

		var profile_id := str(id).to_lower()
		var names := [profile_id]
		names.append(str(profile.get("language", "")).to_lower())
		names.append_array(profile.get("extensions", []))
		names.append_array(profile.get("aliases", []))
		names.append_array(profile.get("match", []))
		names.append_array(profile.get("languages", []))

		if !extension.is_empty() and names.has(extension):
			return _finalize(profile, id)
		if !language.is_empty() and names.has(language):
			return _finalize(profile, id)

	return {}


func _default_profile() -> Dictionary:
	for id in profiles.keys():
		var profile: Dictionary = profiles[id]
		if bool(profile.get("default", false)) and bool(profile.get("enabled", true)):
			return _finalize(profile, id)
	return {}


func _finalize(profile: Dictionary, id: String) -> Dictionary:
	var out := profile.duplicate(true)
	out["id"] = str(id)
	out["profile"] = str(out.get("display", id))
	out["mode"] = normalize_mode(out.get("mode", "capture"), bool(out.get("interactive", false)))
	return out


# ── SHEBANG ─────────────────────────────────────────────────────────────────

func shebang_profile() -> Dictionary:
	var first := _first_line()
	if !first.begins_with("#!") or first.begins_with("#!["):
		return {}

	var tokens: Array = first.substr(2).strip_edges().split(" ", false)
	if tokens.is_empty():
		return {}

	var interpreter := str(tokens[0])
	var args: Array = []
	var start := 1
	if interpreter.get_file().to_lower() == "env":
		start = 1
		while start < tokens.size():
			var candidate := str(tokens[start])
			if candidate.begins_with("-"):
				start += 1
				continue
			interpreter = candidate
			start += 1
			break
	for i in range(start, tokens.size()):
		var arg := str(tokens[i]).strip_edges()
		if arg.is_empty():
			continue
		args.append(arg)

	var executable := interpreter.get_file()
	if executable.is_empty():
		return {}

	var pieces: Array = [executable]
	pieces.append_array(args)
	pieces.append("$file")
	var language := str(SHELL_LANGUAGES.get(executable.to_lower(), ""))

	return {
		"id": "shebang",
		"profile": executable,
		"display": executable,
		"language": language,
		"extensions": [],
		"aliases": [],
		"command": " ".join(pieces),
		"cwd": "$dir",
		"runtimes": [executable],
		"mode": "capture",
		"auto_terminal": language == "python",
		"append_file": false,
		"custom": false,
		"source": "shebang",
	}


func _first_line() -> String:
	if !file_text.is_empty():
		return file_text.get_slice("\n", 0).trim_suffix("\r")
	if !file_path.is_empty() and FileAccess.file_exists(file_path):
		var file := FileAccess.open(file_path, FileAccess.READ)
		if file != null:
			return file.get_line()
	return ""


# ── COMMAND/CWD RESOLUTION ──────────────────────────────────────────────────

func is_windows() -> bool:
	return platform == "windows"


## Shell-quotes one value for the command string. POSIX uses single quotes so
## spaces, $, and backticks in a filename survive; cmd.exe gets double quotes.
func quote_arg(value: String) -> String:
	if is_windows():
		return '"%s"' % value.replace("/", "\\").replace('"', "")
	return "'%s'" % value.replace("'", "'\\''")


func _raw_path(value: String) -> String:
	return value.replace("/", "\\") if is_windows() else value


func variables(path: String = "", workspace: String = "") -> Dictionary:
	var target := Paths.normalize(path if !path.is_empty() else file_path)
	var root := Paths.normalize(workspace if !workspace.is_empty() else workspace_root)
	if root.is_empty():
		root = target.get_base_dir()

	var dir := target.get_base_dir()
	if dir.is_empty():
		dir = root
	var dir_slash := dir + "/" if !dir.ends_with("/") else dir
	var file_name := target.get_file()
	var base_name := file_name.get_basename()
	var no_ext := target.substr(0, target.length() - file_name.length()).path_join(base_name)
	if file_name.is_empty():
		no_ext = ""

	return {
		"file": target,
		"dir": dir,
		"dirSlash": dir_slash,
		"workspace": root,
		"fileName": file_name,
		"fileNameWithoutExt": base_name,
		"fileNoExt": no_ext,
	}


## Replaces placeholders with shell-quoted paths. Two common spellings are
## accepted: `$workspace` (roadmap) and `$workspaceRoot` (code-runner).
## If the placeholder is already inside quotes, the raw path is inserted so a
## hand-written `"$file"` does not become `""path""`.
func resolve_command(profile: Dictionary, path: String = "", workspace: String = "") -> String:
	var command := str(profile.get("command", "")).strip_edges()
	if command.is_empty():
		return ""

	var values := variables(path, workspace)
	var target := str(values["file"])

	command = _replace_path(command, "$workspaceRoot", str(values["workspace"]))
	command = _replace_path(command, "$workspace", str(values["workspace"]))
	command = _replace_path(command, "$fileNameWithoutExt", str(values["fileNameWithoutExt"]))
	command = _replace_path(command, "$fileNoExt", str(values["fileNoExt"]))
	command = _replace_path(command, "$fullFileName", target)
	command = _replace_path(command, "$fileName", str(values["fileName"]))
	command = _replace_path(command, "$dirWithoutTrailingSlash", str(values["dir"]))
	command = _replace_path(command, "$dir", str(values["dirSlash"]))
	command = _replace_path(command, "$file", target)

	if command == str(profile.get("command", "")).strip_edges() and bool(profile.get("append_file", true)):
		command = "%s %s" % [command, quote_arg(target)]

	return command.strip_edges()


func _replace_path(command: String, token: String, raw_value: String) -> String:
	var quoted := quote_arg(raw_value)
	for quote in ["\"", "'"]:
		var wrapped: String = quote + token + quote
		if command.contains(wrapped):
			command = command.replace(wrapped, _quote_inside(raw_value, quote))
	command = command.replace(token, quoted)
	return command


## A hand-written placeholder inside quotes must keep those quotes. The old
## behaviour dropped them, which broke `python "$file"` whenever the filename
## contained a space.
func _quote_inside(value: String, quote: String) -> String:
	var raw := _raw_path(value)
	if quote == "'":
		# POSIX single quotes: end the quote, emit an escaped quote, reopen.
		return "'" + raw.replace("'", "'\\''") + "'"
	if is_windows():
		return '"%s"' % raw.replace('"', "")
	# POSIX double quotes still expand $ and `, so escape those as well.
	return '"%s"' % raw.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$").replace("`", "\\`")


## cwd can use the same path placeholders, but without shell quoting.
func resolve_cwd(profile: Dictionary, path: String = "", workspace: String = "") -> String:
	var cwd := str(profile.get("cwd", "$dir")).strip_edges()
	if cwd.is_empty():
		cwd = "$dir"

	var values := variables(path, workspace)
	cwd = cwd.replace("$workspaceRoot", str(values["workspace"]))
	cwd = cwd.replace("$workspace", str(values["workspace"]))
	cwd = cwd.replace("$dirWithoutTrailingSlash", str(values["dir"]))
	cwd = cwd.replace("$dir", str(values["dir"]))
	cwd = cwd.replace("$fileNoExt", str(values["fileNoExt"]))
	cwd = cwd.replace("$file", str(values["file"]))
	cwd = cwd.replace("$fileName", str(values["fileName"]))
	cwd = cwd.replace("$fileNameWithoutExt", str(values["fileNameWithoutExt"]))

	cwd = Paths.normalize(cwd)
	if cwd.is_empty():
		cwd = str(values["dir"])
	return cwd


## A missing cwd is a common config typo. Returning a working fallback keeps
## the run useful while the caller can still warn about the correction.
func resolve_existing_cwd(profile: Dictionary, path: String = "", workspace: String = "") -> String:
	var cwd := resolve_cwd(profile, path, workspace)
	if !cwd.is_empty() and DirAccess.dir_exists_absolute(cwd):
		return cwd

	var values := variables(path, workspace)
	var file_dir := str(values["dir"])
	if !file_dir.is_empty() and DirAccess.dir_exists_absolute(file_dir):
		return file_dir
	return str(values["workspace"])


func language_for(profile: Dictionary, path: String = "") -> String:
	var language := str(profile.get("language", "")).strip_edges().to_lower()
	if !language.is_empty():
		return language
	return Paths.extension(path if !path.is_empty() else file_path).to_lower()


static func default_config_text() -> String:
	return DEFAULT_CONFIG_TEXT
