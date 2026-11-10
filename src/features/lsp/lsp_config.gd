extends RefCounted

## Built-in language-server definitions plus the layered per-project config.
##
## A profile describes how to start one server for one language (or family of
## languages), where its project root is, and how to install it when it is not
## on PATH. Nothing here starts a process; `lsp_client.gd` does that.
##
## Config files, lowest priority first:
##   built-in profiles
##   user://lsp.json
##   <workspace>/.griddycode.json          (the "lsp" key)
##   <workspace>/.griddycode/lsp.json
##
## Shape:
##   {
##     "lsp": {
##       "python": {
##         "command": "pyright-langserver",
##         "args": ["--stdio"],
##         "root_markers": ["pyproject.toml", ".git"]
##       }
##     }
##   }

const Paths = preload("res://src/base/path_utils.gd")

const LANGUAGE_ALIASES := {
	"python": "python", "py": "python", "python3": "python", "pyi": "python",
	"javascript": "javascript", "js": "javascript", "node": "javascript", "nodejs": "javascript",
	"javascriptreact": "javascriptreact", "jsx": "javascriptreact",
	"typescript": "typescript", "ts": "typescript",
	"typescriptreact": "typescriptreact", "tsx": "typescriptreact",
	"c": "c", "h": "c",
	"cpp": "cpp", "c++": "cpp", "cxx": "cpp", "cc": "cpp",
	"rust": "rust", "rs": "rust",
	"go": "go", "golang": "go",
}

const EXTENSION_LANGUAGES := {
	"py": "python", "pyw": "python", "pyi": "python",
	"js": "javascript", "mjs": "javascript", "cjs": "javascript",
	"jsx": "javascriptreact",
	"ts": "typescript", "mts": "typescript", "cts": "typescript",
	"tsx": "typescriptreact",
	"c": "c", "h": "c",
	"cpp": "cpp", "cc": "cpp", "cxx": "cpp",
	"hpp": "cpp", "hh": "cpp", "hxx": "cpp",
	"rs": "rust",
	"go": "go",
}

const DEFAULT_PROFILES := {
	"python": {
		"display": "Python",
		"language_ids": {"python": "python"},
		"extensions": ["py", "pyw", "pyi"],
		"command": "pyright-langserver",
		"args": ["--stdio"],
		"root_markers": ["pyproject.toml", "pyrightconfig.json", "setup.py", "setup.cfg", "requirements.txt", "tox.ini", ".git"],
		"install": {
			"title": "Install Python support",
			"hint": "Qorix uses Pyright for completion, hover, diagnostics and go-to-definition in Python.",
			"commands": ["npm install -g pyright", "pip install pyright"],
			"url": "https://microsoft.github.io/pyright/#/installation",
			"url_label": "Open the Pyright installation guide",
		},
	},
	"typescript": {
		"display": "TypeScript / JavaScript",
		"language_ids": {
			"javascript": "javascript",
			"javascriptreact": "javascriptreact",
			"typescript": "typescript",
			"typescriptreact": "typescriptreact",
		},
		"extensions": ["ts", "tsx", "mts", "cts", "js", "jsx", "mjs", "cjs"],
		"command": "typescript-language-server",
		"args": ["--stdio"],
		"root_markers": ["tsconfig.json", "jsconfig.json", "package.json", ".git"],
		"install": {
			"title": "Install TypeScript / JavaScript support",
			"hint": "Install the TypeScript language server. It provides completion, diagnostics, hover and symbol navigation for JS and TS.",
			"commands": ["npm install -g typescript typescript-language-server"],
			"url": "https://github.com/typescript-language-server/typescript-language-server#installation",
			"url_label": "Open the TypeScript language server guide",
		},
	},
	"rust": {
		"display": "Rust",
		"language_ids": {"rust": "rust"},
		"extensions": ["rs"],
		"command": "rust-analyzer",
		"args": [],
		"root_markers": ["Cargo.toml", "rust-toolchain.toml", "rust-toolchain", ".git"],
		"install": {
			"title": "Install Rust support",
			"hint": "rust-analyzer ships with rustup. Add the component, then reopen Qorix.",
			"commands": ["rustup component add rust-analyzer"],
			"url": "https://rust-analyzer.github.io/manual.html#installation",
			"url_label": "Open the rust-analyzer installation guide",
		},
	},
	"cpp": {
		"display": "C / C++",
		"language_ids": {"c": "c", "cpp": "cpp"},
		"extensions": ["c", "h", "cpp", "cc", "cxx", "hpp", "hh", "hxx"],
		"command": "clangd",
		"args": [],
		"root_markers": ["compile_commands.json", "compile_flags.txt", "CMakeLists.txt", ".clangd", "Makefile", ".git"],
		"install": {
			"title": "Install C / C++ support",
			"hint": "Install clangd (it usually ships with LLVM or your compiler toolchain) and put it on PATH.",
			"commands": [],
			"url": "https://clangd.llvm.org/installation",
			"url_label": "Open the clangd installation guide",
		},
	},
	"go": {
		"display": "Go",
		"language_ids": {"go": "go"},
		"extensions": ["go"],
		"command": "gopls",
		"args": [],
		"root_markers": ["go.mod", "go.work", ".git"],
		"install": {
			"title": "Install Go support",
			"hint": "Install gopls with the Go toolchain, then reopen Qorix.",
			"commands": ["go install golang.org/x/tools/gopls@latest"],
			"url": "https://go.dev/gopls/",
			"url_label": "Open the gopls installation guide",
		},
	},
}

var platform: String = ""
var path_env: String = ""
var pathext: String = ""
var exists_override: Callable = Callable()
## Optional PATH lookup owned by the caller (the manager passes RuntimeCatalog).
var executable_resolver: Callable = Callable()

## Optional consent gate. Called with the workspace root; when it returns
## false, the project's .griddycode.json and .griddycode/lsp.json are ignored.
## Opening a cloned repository must never be enough to name a process to run.
## Left invalid in tests and headless callers, which keeps them trusted.
var workspace_trust: Callable = Callable()

var profiles: Dictionary = {}
var config_errors: Array = []
var loaded_sources: Array = []


func _init(p_platform: String = "", p_path_env: Variant = null, p_pathext: String = "", p_exists: Callable = Callable()) -> void:
	platform = p_platform if !p_platform.is_empty() else ("windows" if OS.get_name() == "Windows" else "posix")
	path_env = OS.get_environment("PATH") if p_path_env == null else str(p_path_env)
	pathext = p_pathext if !p_pathext.is_empty() else OS.get_environment("PATHEXT")
	if pathext.is_empty():
		pathext = ".COM;.EXE;.BAT;.CMD"
	exists_override = p_exists
	reset_profiles()


func is_windows() -> bool:
	return platform == "windows"


func reset_profiles() -> void:
	profiles.clear()
	for key in DEFAULT_PROFILES.keys():
		var entry: Dictionary = DEFAULT_PROFILES[key].duplicate(true)
		entry["id"] = key
		entry["custom"] = false
		entry["enabled"] = true
		profiles[key] = entry
	config_errors.clear()
	loaded_sources.clear()


## Loads the global override and the project overrides. Returns
## {ok, errors, sources}.
func load_for_project(workspace_root: String, global_path: String = "user://lsp.json") -> Dictionary:
	reset_profiles()

	# Loading is best-effort: a malformed project file must not stop the editor.
	_load_file(global_path, "lsp")
	var root := Paths.normalize(workspace_root)
	var restricted := !root.is_empty() and workspace_trust.is_valid() \
		and !bool(workspace_trust.call(root))
	if !root.is_empty() and !restricted:
		_load_file(root.path_join(".griddycode.json"), "lsp")
		_load_file(root.path_join(".griddycode").path_join("lsp.json"), "lsp")

	return {
		"ok": config_errors.is_empty(),
		"errors": config_errors.duplicate(true),
		"sources": loaded_sources.duplicate(),
		"restricted": restricted,
	}


## Applies one parsed config object (used by tests and .griddycode.json).
func apply_config(data: Variant, source: String = "config") -> Dictionary:
	if !(data is Dictionary):
		config_errors.append({"source": source, "error": "The config is not a JSON object."})
		return {"ok": false, "error": "The config is not a JSON object."}

	var object: Dictionary = data
	if object.get("lsp") is Dictionary:
		object = object["lsp"]
	elif object.get("servers") is Dictionary:
		object = object["servers"]

	for raw_key in object.keys():
		var key := str(raw_key).strip_edges().to_lower()
		if key.is_empty():
			continue
		if key == "enabled" or key == "servers" or key == "lsp":
			continue
		_apply_profile(key, object[raw_key], source)
	return {"ok": true, "error": ""}


func _load_file(path: String, key: String = "lsp") -> void:
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
	if key == "lsp" and parsed.get("lsp") is Dictionary:
		parsed = parsed["lsp"]
	apply_config(parsed, path)


func _apply_profile(key: String, raw: Variant, source: String) -> void:
	var entry: Dictionary
	if profiles.has(key):
		entry = profiles[key]
	else:
		entry = {
			"id": key,
			"display": key.capitalize(),
			"language_ids": {key: key},
			"extensions": [],
			"command": "",
			"args": [],
			"root_markers": [".git"],
			"install": {},
			"enabled": true,
			"custom": true,
		}
		profiles[key] = entry

	if raw is String:
		entry["command"] = str(raw)
		entry["custom"] = true
		return
	if !(raw is Dictionary):
		config_errors.append({"source": source, "error": "Profile \"%s\" is not an object." % key})
		return

	var override: Dictionary = raw
	if override.has("command"):
		entry["command"] = str(override["command"])
		entry["custom"] = true
	if override.has("args") and override["args"] is Array:
		entry["args"] = override["args"].duplicate()
	if override.has("root_markers") and override["root_markers"] is Array:
		entry["root_markers"] = override["root_markers"].duplicate()
	if override.has("extensions") and override["extensions"] is Array:
		entry["extensions"] = override["extensions"].duplicate()
	if override.has("display"):
		entry["display"] = str(override["display"])
	if override.has("enabled"):
		entry["enabled"] = bool(override["enabled"])
	if override.has("install") and override["install"] is Dictionary:
		entry["install"] = override["install"].duplicate(true)
	if override.has("initialization_options") and override["initialization_options"] is Dictionary:
		entry["initialization_options"] = override["initialization_options"].duplicate(true)
	if override.has("settings") and override["settings"] is Dictionary:
		entry["settings"] = override["settings"].duplicate(true)

	if override.has("language_ids") and override["language_ids"] is Dictionary:
		entry["language_ids"] = override["language_ids"].duplicate()
	elif override.has("languages") and override["languages"] is Array:
		var ids := {}
		for language in override["languages"]:
			var name := _normalize_language(str(language))
			if !name.is_empty():
				ids[name] = name
		entry["language_ids"] = ids
	elif override.has("language_id"):
		entry["language_ids"] = {key: str(override["language_id"])}
		entry["language_id"] = str(override["language_id"])


# ── LANGUAGE LOOKUP ────────────────────────────────────────────────────────

static func normalize_language(value: String) -> String:
	return _normalize_language(value)


static func _normalize_language(value: String) -> String:
	var text := value.strip_edges().to_lower().trim_prefix(".")
	if text.is_empty():
		return ""
	return str(LANGUAGE_ALIASES.get(text, text))


func language_for_extension(extension: String) -> String:
	var ext := extension.strip_edges().to_lower().trim_prefix(".")
	if ext.is_empty():
		return ""
	var language := str(EXTENSION_LANGUAGES.get(ext, ""))
	if language.is_empty():
		return ""
	return language if !profile_for_language(language).is_empty() else ""


## The language id Qorix should use for a document, honouring a detected
## language override and falling back to the file extension.
func language_for_document(path: String, override: Variant = "") -> String:
	var raw := _normalize_language(str(override))
	if !raw.is_empty() and !profile_for_language(raw).is_empty():
		return raw

	var extension := Paths.extension(path).to_lower()
	return language_for_extension(extension)


## Returns a duplicate of the profile that serves `language`, or {}. The copy
## carries `language_id`, the exact id sent to the server.
func profile_for_language(language: String, path: String = "") -> Dictionary:
	var normalized := _normalize_language(language)
	if normalized.is_empty():
		return {}

	for key in profiles.keys():
		var profile: Dictionary = profiles[key]
		if !bool(profile.get("enabled", true)):
			continue
		var language_ids: Dictionary = profile.get("language_ids", {})
		if key == normalized or language_ids.has(normalized):
			var copy: Dictionary = profile.duplicate(true)
			copy["language"] = normalized
			copy["language_id"] = _language_id_for(profile, normalized, path)
			return copy
	return {}


func _language_id_for(profile: Dictionary, language: String, path: String) -> String:
	var language_ids: Dictionary = profile.get("language_ids", {})
	if language_ids.has(language):
		return str(language_ids[language])

	var extension := Paths.extension(path).to_lower()
	if !extension.is_empty():
		var from_extension := str(EXTENSION_LANGUAGES.get(extension, ""))
		if language_ids.has(from_extension):
			return str(language_ids[from_extension])

	if profile.has("language_id"):
		return str(profile["language_id"])
	return str(profile.get("id", language))


func has_language(language: String) -> bool:
	return !profile_for_language(language).is_empty()


## Every language id a profile can serve, for the Servers panel.
func languages_for(profile: Dictionary) -> Array:
	var out: Array = []
	var language_ids: Variant = profile.get("language_ids", {})
	if language_ids is Dictionary:
		for key in language_ids.keys():
			out.append(str(key))
	if out.is_empty():
		out.append(str(profile.get("id", "")))
	return out


func profiles_sorted() -> Array:
	var out: Array = []
	for key in profiles.keys():
		var profile: Dictionary = profiles[key]
		if !bool(profile.get("enabled", true)):
			continue
		out.append(profile)
	out.sort_custom(func(a, b) -> bool:
		return str(a.get("display", a.get("id", ""))).naturalnocasecmp_to(str(b.get("display", b.get("id", "")))) < 0
	)
	return out


# ── PROJECT ROOT ───────────────────────────────────────────────────────────

## Walks up from the file looking for the nearest root marker. Falls back to
## the workspace root when the file is inside it, otherwise the file's folder.
func root_for(profile: Dictionary, file_path: String, workspace_root: String = "") -> String:
	var path := Paths.normalize(file_path)
	if path.is_empty():
		return Paths.normalize(workspace_root)

	var workspace := Paths.normalize(workspace_root)
	var markers: Array = profile.get("root_markers", [])
	var current := path.get_base_dir()
	var guard := 0

	while !current.is_empty() and guard < 48:
		if _has_any_marker(current, markers):
			return current
		if !workspace.is_empty() and Paths.same_file(current, workspace):
			break
		var parent := current.get_base_dir()
		if parent.is_empty() or parent == current:
			break
		current = parent
		guard += 1

	if !workspace.is_empty() and Paths.is_subpath(workspace, path):
		return workspace
	return path.get_base_dir()


func _has_any_marker(folder: String, markers: Array) -> bool:
	for marker in markers:
		var name := str(marker).strip_edges()
		if name.is_empty():
			continue
		var candidate := folder.path_join(name)
		if _file_exists(candidate) or DirAccess.dir_exists_absolute(candidate) or DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(candidate)):
			return true
	return false


# ── EXECUTABLES / INSTALL HELP ─────────────────────────────────────────────

## Resolves the profile's command through PATH. Returns
## {ok, path, command, error}.
func resolve_command(profile: Dictionary) -> Dictionary:
	var command := str(profile.get("command", "")).strip_edges()
	if command.is_empty():
		return {"ok": false, "path": "", "command": "", "error": "The profile has no command."}

	var path := ""
	if executable_resolver.is_valid():
		path = str(executable_resolver.call(command))
	else:
		path = find_executable(command)

	if path.is_empty() and _looks_like_path(command) and _file_exists(command):
		path = Paths.normalize(command)

	return {
		"ok": !path.is_empty(),
		"path": path,
		"command": command,
		"error": "" if !path.is_empty() else "\"%s\" was not found on PATH." % command,
	}


func server_status(language: String, file_path: String, workspace_root: String = "") -> Dictionary:
	var profile := profile_for_language(language, file_path)
	if profile.is_empty():
		return {"ok": false, "language": language, "profile": {}, "error": "This language has no LSP profile."}

	var resolved := resolve_command(profile)
	var root := root_for(profile, file_path, workspace_root)
	return {
		"ok": bool(resolved.get("ok", false)),
		"language": language,
		"profile": profile,
		"root": root,
		"command": str(resolved.get("command", "")),
		"command_path": str(resolved.get("path", "")),
		"install": install_help(str(profile.get("id", language)), profile),
		"error": str(resolved.get("error", "")),
	}


## Data for the Servers tab. It never starts anything.
func server_entries() -> Array:
	var out: Array = []
	for profile in profiles_sorted():
		var resolved := resolve_command(profile)
		var install := install_help(str(profile.get("id", "")), profile)
		out.append({
			"id": str(profile.get("id", "")),
			"display": str(profile.get("display", profile.get("id", ""))),
			"languages": languages_for(profile),
			"command": str(profile.get("command", "")),
			"command_path": str(resolved.get("path", "")),
			"found": bool(resolved.get("ok", false)),
			"args": profile.get("args", []).duplicate(),
			"root_markers": profile.get("root_markers", []).duplicate(),
			"custom": bool(profile.get("custom", false)),
			"install": install,
		})
	return out


func install_help(profile_key: String, profile: Dictionary = {}) -> Dictionary:
	if profile.is_empty():
		profile = profiles.get(profile_key, {})
	var source: Dictionary = profile.get("install", {}) if profile.get("install", {}) is Dictionary else {}
	var raw_commands: Variant = source.get("commands", [])
	var commands: Array = []
	if raw_commands is String:
		commands = [raw_commands]
	elif raw_commands is Array:
		commands = (raw_commands as Array).duplicate()
	if commands.is_empty():
		for item in [source.get("command_windows", ""), source.get("command_posix", "")]:
			var command := str(item).strip_edges()
			if !command.is_empty() and !commands.has(command):
				commands.append(command)

	return {
		"language": profile_key,
		"title": str(source.get("title", "Install language support")),
		"hint": str(source.get("hint", "Install the language server for this language, then reopen Qorix.")),
		"commands": commands,
		"url": str(source.get("url", "")),
		"url_label": str(source.get("url_label", "Open the installation guide")),
		"executable": str(profile.get("command", "")),
	}


# ── PATH LOOKUP (fallback when no resolver was injected) ───────────────────

func find_executable(name: String) -> String:
	var clean := name.strip_edges().trim_prefix("\"").trim_suffix("\"")
	if clean.is_empty():
		return ""

	if _looks_like_path(clean):
		if _file_exists(clean):
			return clean
		var normalized := Paths.normalize(clean)
		if _file_exists(normalized):
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
		var base := str(folder).strip_edges().trim_suffix("\\").trim_suffix("/")
		if base.is_empty():
			continue
		for extension in extensions:
			var candidate := base + "/" + clean + extension
			if _file_exists(candidate):
				return candidate
	return ""


static func _looks_like_path(word: String) -> bool:
	return word.contains("/") or word.contains("\\") or (word.length() > 1 and word[1] == ":")


static func _has_extension(name: String) -> bool:
	var file := name.get_file()
	var dot := file.rfind(".")
	return dot > 0 and dot < file.length() - 1


func _file_exists(path: String) -> bool:
	if exists_override.is_valid():
		return bool(exists_override.call(path))
	return FileAccess.file_exists(path)
