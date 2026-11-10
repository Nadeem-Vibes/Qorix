extends RefCounted

## Finds the executables a run command needs before Qorix tries to start
## a shell. A missing compiler should produce a friendly install card in the
## Run panel, not a raw "not recognized" line from cmd.exe.
##
## The checks are intentionally conservative: only the first word of each shell
## segment is considered, shell built-ins are skipped, and an absolute path in
## a later segment is treated as a build output (for example
## `gcc main.c -o main.exe && main.exe`) rather than a missing program.

const Paths = preload("res://src/base/path_utils.gd")

## A profile asks for `python`; any of these satisfy it. The first found wins,
## so a Windows install that only ships the `py` launcher still runs.
const RUNTIME_GROUPS := {
	"python": ["python", "python3", "py"],
	"node": ["node", "nodejs"],
	"gcc": ["gcc", "clang"],
	"g++": ["g++", "clang++"],
	"clang": ["clang"],
	"clang++": ["clang++"],
	"java": ["java"],
	"javac": ["javac"],
	"go": ["go"],
	"rustc": ["rustc"],
	"lua": ["lua", "lua5.4", "lua5.3"],
	"ruby": ["ruby"],
	"php": ["php"],
	"perl": ["perl"],
	"bash": ["bash", "sh"],
	"powershell": ["powershell", "pwsh"],
	"dart": ["dart"],
	"zig": ["zig"],
	"nim": ["nim"],
	"runghc": ["runghc"],
	"gleam": ["gleam"],
	"elixir": ["elixir"],
	"rscript": ["Rscript"],
}

const ALIASES := {
	"python3": "python", "py": "python", "python2": "python",
	"nodejs": "node", "node.exe": "node",
	"javaw": "java", "javac.exe": "javac",
	"golang": "go", "go.exe": "go",
	"rustc.exe": "rustc", "bash.exe": "bash", "sh": "bash",
	"pwsh": "powershell", "powershell.exe": "powershell",
	"rscript": "rscript",
}

const SHELL_BUILTINS := {
	"cd": true, "chdir": true, "echo": true, "set": true, "export": true,
	"unset": true, "if": true, "then": true, "else": true, "elif": true,
	"fi": true, "for": true, "while": true, "do": true, "done": true,
	"case": true, "esac": true, "function": true, "return": true,
	"exit": true, "call": true, "start": true, "title": true, "color": true,
	"mkdir": true, "md": true, "rmdir": true, "rd": true, "del": true,
	"erase": true, "copy": true, "xcopy": true, "move": true, "ren": true,
	"rename": true, "type": true, "dir": true, "cls": true, "clear": true,
	"setlocal": true, "endlocal": true, "pushd": true, "popd": true,
	"pause": true, "timeout": true, "where": true, "which": true,
	"printf": true, "test": true, "true": true, "false": true,
	"source": true, ".": true, ":": true, "read": true, "sleep": true,
	"touch": true, "cat": true, "rm": true, "cp": true, "mv": true,
	"ls": true, "pwd": true, "env": true, "sudo": true, "chmod": true,
}

var platform: String = ""
var path_env: String = ""
var pathext: String = ""
var exists_override: Callable = Callable()


func _init(p_platform: String = "", p_path_env: Variant = null, p_pathext: String = "", p_exists: Callable = Callable()) -> void:
	platform = p_platform if !p_platform.is_empty() else ("windows" if OS.get_name() == "Windows" else "posix")
	path_env = OS.get_environment("PATH") if p_path_env == null else str(p_path_env)
	pathext = p_pathext if !p_pathext.is_empty() else OS.get_environment("PATHEXT")
	if pathext.is_empty():
		pathext = ".COM;.EXE;.BAT;.CMD"
	exists_override = p_exists


func is_windows() -> bool:
	return platform == "windows"


## Splits a command on the separators a shell would treat as statement
## boundaries. Quotes protect separators inside arguments; redirections such as
## `2>&1` are not split.
static func command_segments(command: String) -> Array[String]:
	var out: Array[String] = []
	var current := ""
	var quote := ""
	var i := 0

	while i < command.length():
		var character := command[i]
		if !quote.is_empty():
			current += character
			if character == quote:
				quote = ""
			i += 1
			continue

		if character == "\"" or character == "'":
			quote = character
			current += character
			i += 1
			continue

		if character == "&" and i + 1 < command.length() and command[i + 1] == "&":
			out.append(current)
			current = ""
			i += 2
			continue
		if character == "|" and i + 1 < command.length() and command[i + 1] == "|":
			out.append(current)
			current = ""
			i += 2
			continue
		if character == ";" or character == "\n" or character == "|":
			out.append(current)
			current = ""
			i += 1
			continue
		if character == "&":
			# `2>&1` is a redirection, not a command separator.
			if i > 0 and (command[i - 1] == ">" or command[i - 1] == "<"):
				current += character
			else:
				out.append(current)
				current = ""
			i += 1
			continue

		current += character
		i += 1

	out.append(current)
	return out


## First shell word of one segment, with quotes removed. Returns "" for an
## empty/comment-only segment.
static func first_word(segment: String) -> String:
	var text := segment.strip_edges()
	while !text.is_empty() and (text.begins_with("(") or text.begins_with("@")):
		text = text.substr(1).strip_edges()
	if text.is_empty() or text.begins_with("#"):
		return ""

	var quote := ""
	var out := ""
	var i := 0
	while i < text.length():
		var character := text[i]
		if !quote.is_empty():
			if character == quote:
				quote = ""
			else:
				out += character
			i += 1
			continue
		if character == "\"" or character == "'":
			quote = character
			i += 1
			continue
		if character == " " or character == "\t" or character == "<" or character == ">":
			break
		if character == ")":
			break
		out += character
		i += 1
	return out


## Reads the executable names a profile needs. Explicit `runtimes` wins;
## otherwise the first word of each shell segment is inferred, skipping
## built-ins and build-output paths.
func runtime_names(profile: Dictionary, command: String) -> Array[String]:
	var declared: Variant = profile.get("runtimes", [])
	var out: Array[String] = []
	if declared is String:
		declared = [declared]
	if declared is Array:
		for item in declared:
			var name := str(item).strip_edges()
			if !name.is_empty() and !out.has(name):
				out.append(name)
	if !out.is_empty():
		return out

	var segments := command_segments(command)
	for index in range(segments.size()):
		var word := first_word(segments[index])
		if word.is_empty() or word.begins_with("$"):
			continue
		var key := word.to_lower()
		if SHELL_BUILTINS.has(key):
			continue
		if word.begins_with("-"):
			continue
		if _looks_like_path(word):
			# A later absolute path is most often the compiled binary on the
			# right side of `&&`; it does not exist yet on the first run.
			if index > 0:
				continue
			if _exists(word) or _exists(Paths.normalize(word)):
				continue
		if !out.has(word):
			out.append(word)
	return out


static func _looks_like_path(word: String) -> bool:
	return word.contains("/") or word.contains("\\") or (word.length() > 1 and word[1] == ":")


## Resolves one requested name through its fallback group.
## Returns {requested, group, resolved, path}.
func resolve_runtime(name: String) -> Dictionary:
	var requested := name.strip_edges().strip_edges()
	var key := requested.to_lower()
	var group := str(ALIASES.get(key, key))
	var candidates: Array = RUNTIME_GROUPS.get(group, [requested])

	for candidate in candidates:
		var path := find_executable(str(candidate))
		if !path.is_empty():
			return {
				"requested": requested,
				"group": group,
				"resolved": str(candidate),
				"path": path,
			}

	if _looks_like_path(requested) and _exists(requested):
		return {
			"requested": requested,
			"group": group,
			"resolved": requested,
			"path": requested,
		}

	return {"requested": requested, "group": group, "resolved": "", "path": ""}


## Searches PATH (and PATHEXT on Windows). A test can inject `exists_override`
## so the lookup rules do not depend on what is installed on the build machine.
func find_executable(name: String) -> String:
	var clean := name.strip_edges().trim_prefix("\"").trim_suffix("\"")
	if clean.is_empty():
		return ""

	if _looks_like_path(clean):
		if _exists(clean):
			return clean
		var normalized := Paths.normalize(clean)
		if _exists(normalized):
			return normalized
		return ""

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
		var base := str(folder).strip_edges()
		if base.is_empty():
			continue
		base = base.trim_suffix("\\").trim_suffix("/")
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


## Preflight for one resolved run command.
## Returns {ok, checks, missing, replacements}.
func check_profile(profile: Dictionary, command: String) -> Dictionary:
	var names := runtime_names(profile, command)
	var checks: Array = []
	var missing: Array = []
	var replacements: Dictionary = {}

	for name in names:
		var resolved := resolve_runtime(name)
		checks.append(resolved)
		if str(resolved.get("resolved", "")).is_empty():
			missing.append({
				"executable": name,
				"group": str(resolved.get("group", name)),
				"install": install_help(name),
			})
			continue
		var resolved_name := str(resolved.get("resolved", ""))
		if resolved_name.to_lower() != name.to_lower():
			replacements[name] = resolved_name

	return {
		"ok": missing.is_empty(),
		"checks": checks,
		"missing": missing,
		"replacements": replacements,
	}


## Rewrites only an executable at the start of a shell statement, never a
## filename argument that happens to contain the same word.
static func replace_executable(command: String, requested: String, resolved: String) -> String:
	var escaped := _regex_escape(requested)
	var regex := RegEx.new()
	if regex.compile("(?i)(^|&&|\\|\\||;|\\||\\r?\\n)(\\s*)" + escaped + "(?=\\s|$)") != OK:
		return command
	var replacement := resolved
	if replacement.contains(" ") or replacement.contains("\t"):
		replacement = "\"%s\"" % replacement
	return regex.sub(command, "$1$2" + replacement, true)


static func _regex_escape(value: String) -> String:
	var out := ""
	for i in range(value.length()):
		var character := value[i]
		if "\\^$.|?*+()[]{}".contains(character):
			out += "\\" + character
		else:
			out += character
	return out


## User-facing install guidance for a missing executable. Kept data-only so
## the output panel decides how to render the link.
func install_help(name: String) -> Dictionary:
	var key := str(ALIASES.get(name.to_lower(), name.to_lower()))
	var windows := is_windows()

	var help := {
		"executable": name,
		"group": key,
		"title": "\"%s\" was not found on PATH" % name,
		"hint": "Install it, then reopen Qorix so it picks up the updated PATH.",
		"url": "",
	}

	match key:
		"python":
			help["title"] = "Python isn't installed (or isn't on PATH)"
			help["hint"] = "Install Python 3 and tick \"Add python.exe to PATH\" in the installer, then reopen Qorix."
			help["url"] = "https://www.python.org/downloads/"
			if windows:
				help["winget"] = "winget install --id Python.Python.3.12 --exact --accept-source-agreements --accept-package-agreements"
				help["winget_label"] = "Install Python 3.12 with winget"
		"node":
			help["title"] = "Node.js isn't installed (or isn't on PATH)"
			help["hint"] = "Install the LTS release of Node.js, then reopen Qorix."
			help["url"] = "https://nodejs.org/en/download"
			if windows:
				help["winget"] = "winget install --id OpenJS.NodeJS.LTS --accept-source-agreements --accept-package-agreements"
				help["winget_label"] = "Install Node.js LTS with winget"
		"gcc", "g++":
			help["title"] = "A C/C++ compiler isn't installed (or isn't on PATH)"
			if windows:
				help["hint"] = "Install MinGW-w64 through MSYS2, add its bin folder to PATH, then reopen Qorix."
				help["url"] = "https://www.msys2.org/"
			else:
				help["hint"] = "Install gcc/g++ with your system package manager, then reopen Qorix."
				help["url"] = "https://gcc.gnu.org/install/"
		"javac", "java":
			help["title"] = "Java (JDK) isn't installed (or isn't on PATH)"
			help["hint"] = "Install a JDK 17 or newer and add its bin folder to PATH, then reopen Qorix."
			help["url"] = "https://adoptium.net/"
		"go":
			help["title"] = "Go isn't installed (or isn't on PATH)"
			help["hint"] = "Install Go and reopen Qorix; the installer adds go.exe to PATH."
			help["url"] = "https://go.dev/dl/"
		"rustc":
			help["title"] = "Rust isn't installed (or isn't on PATH)"
			help["hint"] = "Install Rust with rustup, then reopen Qorix."
			help["url"] = "https://rustup.rs/"
		"lua":
			help["title"] = "Lua isn't installed (or isn't on PATH)"
			help["hint"] = "Install Lua 5.4 and make sure lua.exe is on PATH."
			help["url"] = "https://www.lua.org/download.html"
		"ruby":
			help["title"] = "Ruby isn't installed (or isn't on PATH)"
			help["hint"] = "Install Ruby with RubyInstaller (Windows) or your package manager, then reopen Qorix."
			help["url"] = "https://www.ruby-lang.org/en/downloads/"
		"php":
			help["title"] = "PHP isn't installed (or isn't on PATH)"
			help["hint"] = "Install PHP and add its folder to PATH, then reopen Qorix."
			help["url"] = "https://www.php.net/downloads"
		"bash":
			help["title"] = "Bash isn't installed (or isn't on PATH)"
			help["hint"] = "On Windows, install Git for Windows (which ships bash) or use WSL, then reopen Qorix."
			help["url"] = "https://git-scm.com/downloads"
		"powershell":
			help["title"] = "PowerShell isn't installed (or isn't on PATH)"
			help["hint"] = "Install PowerShell 7, then reopen Qorix."
			help["url"] = "https://learn.microsoft.com/powershell/scripting/install/installing-powershell"
		"dart":
			help["title"] = "Dart isn't installed (or isn't on PATH)"
			help["hint"] = "Install the Dart SDK and add its bin folder to PATH."
			help["url"] = "https://dart.dev/get-dart"
		"zig":
			help["title"] = "Zig isn't installed (or isn't on PATH)"
			help["hint"] = "Download Zig, extract it, and add the folder to PATH."
			help["url"] = "https://ziglang.org/download/"
		"nim":
			help["title"] = "Nim isn't installed (or isn't on PATH)"
			help["hint"] = "Install Nim with choosenim or your package manager."
			help["url"] = "https://nim-lang.org/install.html"
		"runghc":
			help["title"] = "Haskell (runghc) isn't installed (or isn't on PATH)"
			help["hint"] = "Install GHCup, then reopen Qorix."
			help["url"] = "https://www.haskell.org/ghcup/"
		"gleam":
			help["title"] = "Gleam isn't installed (or isn't on PATH)"
			help["hint"] = "Install Gleam and reopen Qorix."
			help["url"] = "https://gleam.run/getting-started/installing/"
		"elixir":
			help["title"] = "Elixir isn't installed (or isn't on PATH)"
			help["hint"] = "Install Elixir and reopen Qorix."
			help["url"] = "https://elixir-lang.org/install.html"
		"perl":
			help["title"] = "Perl isn't installed (or isn't on PATH)"
			help["hint"] = "Install Perl and make sure perl.exe is on PATH."
			help["url"] = "https://www.perl.org/get.html"
		"rscript":
			help["title"] = "R isn't installed (or isn't on PATH)"
			help["hint"] = "Install R and add its bin folder to PATH."
			help["url"] = "https://cran.r-project.org/"

	return help
