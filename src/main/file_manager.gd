class_name FileManager
extends Node2D

## Coordinator: window/HUD/dialog glue. Open buffers, their EditorViews and
## the document <-> view mapping live in DocumentManager.

@onready var editor_host = $EditorHost
@onready var file_dialog = %FileDialog
@onready var settings_panel: Node2D = %Settings
@onready var info_panel: Node2D = %Info
@onready var theme_chooser_panel = %ThemeChooser
@onready var comments_panel: Control = %Comments
@onready var background: ColorRect = %Background
@onready var external_background: ColorRect = %ExternalBackground
@onready var camera = %Cam
@onready var canvas_layer: CanvasLayer = $CanvasLayer
const NOTICE = preload("res://src/workbench/notice.tscn")

var current_file: String;
var current_dir: String = "/";

const FIND_SCRIPT = preload("res://src/workbench/find_replace.gd")
const TABS_SCRIPT = preload("res://src/workbench/tabs_bar.gd")
const PALETTE_SCRIPT = preload("res://src/workbench/palette_panel.gd")
const TERMINAL_SCRIPT = preload("res://src/workbench/terminal_panel.gd")
const MINIMAP_SCRIPT = preload("res://src/editor/minimap.gd")
const RUN_SERVICE_SCRIPT = preload("res://src/features/run/run_service.gd")
const OUTPUT_PANEL_SCRIPT = preload("res://src/features/run/output_panel.gd")
const LSP_MANAGER_SCRIPT = preload("res://src/features/lsp/lsp_manager.gd")
const LSP_PANEL_SCRIPT = preload("res://src/features/lsp/lsp_panel.gd")
const LSP_HOVER_SCRIPT = preload("res://src/features/lsp/lsp_hover_panel.gd")
const LSP_SIGNATURE_SCRIPT = preload("res://src/features/lsp/lsp_signature_panel.gd")
const LSP_PICKER_SCRIPT = preload("res://src/features/lsp/lsp_picker.gd")
const DAP_MANAGER_SCRIPT = preload("res://src/features/debug/dap_manager.gd")
const DEBUG_PANEL_SCRIPT = preload("res://src/features/debug/debug_panel.gd")
const GIT_SERVICE_SCRIPT = preload("res://src/features/git/git_service.gd")
const SOURCE_CONTROL_PANEL_SCRIPT = preload("res://src/features/git/source_control_panel.gd")
const GIT_DIFF_DIALOG_SCRIPT = preload("res://src/features/git/git_diff_dialog.gd")
const GIT_DIFF = preload("res://src/features/git/git_diff.gd")
const GUESSLANG_SCRIPT = preload("res://src/features/run/guesslang_service.gd")
const DOCUMENTS_SCRIPT = preload("res://src/editor/document_manager.gd")
const OVERLAYS_SCRIPT = preload("res://src/editor/overlay_controller.gd")
const INPUT_SCRIPT = preload("res://src/editor/input_controller.gd")
const WORKSPACE_SCRIPT = preload("res://src/platform/workspace_service.gd")
const SEARCH_SERVICE_SCRIPT = preload("res://src/platform/search_service.gd")
const SESSION_SCRIPT = preload("res://src/platform/session_service.gd")
const TRUST_SCRIPT = preload("res://src/platform/trust_service.gd")
const FILE_TREE_SCRIPT = preload("res://src/workbench/file_tree_panel.gd")
const SEARCH_PANEL_SCRIPT = preload("res://src/workbench/search_panel.gd")
const BUILTIN_COMMANDS_SCRIPT = preload("res://src/platform/builtin_commands.gd")
const COMMAND_REGISTRY_SCRIPT = preload("res://src/platform/command_registry.gd")
const KEYBINDING_SERVICE_SCRIPT = preload("res://src/platform/keybinding_service.gd")
const TOP_BAR_SCRIPT = preload("res://src/workbench/top_bar.gd")
const NOTIFICATION_CENTER_SCRIPT = preload("res://src/workbench/notification_center.gd")
const FOCUS_NAV = preload("res://src/platform/focus_nav.gd")
const KEYBINDINGS_PANEL_SCRIPT = preload("res://src/workbench/keybindings_panel.gd")
const DIALOG_COORDINATOR_SCRIPT = preload("res://src/workbench/dialog_coordinator.gd")

# Phase 1 — mod core. The manager owns discovery, activation and teardown; the
# failure cards are the only UI it needs until the partial-UI work in Phase 2.
const MOD_MANAGER_SCRIPT = preload("res://src/features/mods/mod_manager.gd")
const MOD_FAILURE_CARDS_SCRIPT = preload("res://src/features/mods/ui/mod_failure_cards.gd")
const MOD_UI_REGISTRY_SCRIPT = preload("res://src/features/mods/ui/mod_ui_registry.gd")
const MOD_SETTINGS_PANEL_SCRIPT = preload("res://src/features/mods/ui/mod_settings_panel.gd")

# Phase 3 — shell framing and the learning engine. The composition root builds
# the nodes (overlay, hint bubble, shell layers); the services stay RefCounted and
# testable.
const SHELL_SERVICE_SCRIPT = preload("res://src/features/mods/shell/shell_service.gd")
const GUIDE_SERVICE_SCRIPT = preload("res://src/features/learning/guide/guide_service.gd")
const GUIDE_OVERLAY_SCRIPT = preload("res://src/features/learning/guide/guide_overlay.gd")
const GUIDE_HINTS_SCRIPT = preload("res://src/features/learning/guide/guide_hint_layer.gd")
const EXERCISE_SERVICE_SCRIPT = preload("res://src/features/learning/exercise/exercise_service.gd")
const VALIDATION_SCRIPT = preload("res://src/features/learning/exercise/exercise_validation.gd")

# Phase 9 — beginner layer
const TEMPLATE_SERVICE_SCRIPT = preload("res://src/features/learning/beginner/template_service.gd")
const WELCOME_SERVICE_SCRIPT = preload("res://src/features/learning/beginner/welcome_service.gd")
const ONBOARDING_SERVICE_SCRIPT = preload("res://src/features/learning/beginner/onboarding_service.gd")
const HISTORY_SERVICE_SCRIPT = preload("res://src/features/learning/beginner/history_service.gd")
const GLOSSARY_SERVICE_SCRIPT = preload("res://src/features/learning/beginner/glossary_service.gd")
const BEGINNER_MODE_SCRIPT = preload("res://src/features/learning/beginner/beginner_mode_service.gd")
const PREVIEW_SERVER_SCRIPT = preload("res://src/features/learning/beginner/preview_server.gd")
const WELCOME_PANEL_SCRIPT = preload("res://src/features/learning/beginner/welcome_panel.gd")
const COACH_PANEL_SCRIPT = preload("res://src/features/learning/beginner/coach_panel.gd")
const HISTORY_DIALOG_SCRIPT = preload("res://src/features/learning/beginner/history_dialog.gd")
const GLOSSARY = preload("res://src/features/learning/beginner/glossary_service.gd")
# Built-in course (Python Journey): catalog service + dock.
const COURSE_SERVICE_SCRIPT = preload("res://src/features/learning/courses/course_service.gd")
const COURSE_PANEL_SCRIPT = preload("res://src/features/learning/courses/course_panel.gd")
const RuntimeCatalog = preload("res://src/features/run/runtime_catalog.gd")
const COURSE_OWNER := "griddycode.python_journey"

# Explicit preload instead of the global `PathUtils` class name: the global
# class cache can be stale in an already-open editor session, which makes the
# parser report "Identifier PathUtils not declared". Preloading is cache-proof.
const Paths = preload("res://src/base/path_utils.gd")

# folders quick-open never descends into (huge, generated, or invisible)
const SCAN_SKIP_DIRS = [".git", "node_modules", "__pycache__", ".venv", "venv", ".godot", "build", "dist"]

## Engine flags that consume the following argument. They are not user file
## arguments: treating them as a CLI launch used to skip session restore and
## save the process cwd as the workspace.
const CLI_VALUE_FLAGS := {
	"--scene": true,
	"--script": true,
	"--path": true,
	"--main-pack": true,
	"--editor-pid": true,
	"--position": true,
	"--resolution": true,
	"--screen": true,
	"--rendering-method": true,
	"--rendering-driver": true,
	"--audio-driver": true,
	"--display-driver": true,
	"--gpu-index": true,
	"--fixed-fps": true,
	"--time-scale": true,
	"--write-movie": true,
	"--remote-debug": true,
	"--breakpoints": true,
	"--log-file": true,
	"--xr-mode": true,
}

const MAX_CLOSED_TABS = 20
const LEFT_DOCK_WIDTH = 320.0
const EXTERNAL_POLL_SECONDS = 1.5
## A typing pause long enough to be a deliberate stop, not a key repeat.
const LANGUAGE_DETECT_SECONDS = 1.0

# Runtime services
var documents = null
var overlays = null
var input_controller = null
var workspace = null
var search_service = null
var session = null
var trust_service = null
var commands = null
var keybindings = null
var builtin_commands = null

# Phase 1/2 mod core
var mods = null
var mod_failure_cards: Control
var mod_ui: Control
var mod_settings_panel: Control
var _mod_log_dialog: AcceptDialog

# Phase 3 services and their screen/world nodes.
var mod_validation = null
var mod_guide = null
var mod_exercise = null
var mod_shell_service = null
var guide_overlay = null
var guide_hints: Control
var _mod_world_saved := true
var _mod_panic_msec := 0
## GuessLang-style offline language detector. Pure RefCounted; loads its
## profiles lazily on first use so startup never blocks on n-gram vectors.
var language_detector = null

# Phase 9 services and HUD
var templates = null
var welcome = null
var onboarding = null
var history = null
var glossary = null
var beginner_mode = null
var preview_server = null
var course_service = null
var course_panel: Control
var course_lesson: String = ""
var course_typed: bool = false
var course_timer: Timer
var _course_python_resolved := -1
var welcome_panel: Control
var coach_panel: PanelContainer
var history_dialog: AcceptDialog

# HUD docks
var top_bar: Control
var notification_center: Control
var file_tree: Control
var search_panel: Control
var source_control_panel: Control
var keybindings_panel: Control

# Background persistence / disk watching
var session_timer: Timer
var external_timer: Timer
var language_detect_timer: Timer
var git_refresh_timer: Timer
var git_gutter_timer: Timer
var history_timer: Timer
var glossary_timer: Timer
var _pending_detect_document = null
var _pending_git_gutter_document = null
var _session_recovered: bool = false
var _session_loaded: bool = false
var _lsp_problem_total: int = 0
var _debug_execution_path: String = ""
var _debug_execution_line: int = -1

# Compatibility views over DocumentManager for the rest of the UI.
var open_tabs: Array:
	get:
		return documents.documents if documents != null else []
var active_tab: int:
	get:
		return documents.active_index if documents != null else -1
var active_view: CodeEdit:
	get:
		return documents.active_view() if documents != null else null

var find_panel: Control
var palette: Control
var tabs: TabBar
var terminal: PanelContainer
var output_panel: PanelContainer
var minimap = null
var cursor_effect = null
var run_service: Node
var lsp_manager: Node
var dap_manager: Node
var git_service: Node
## Screen-space HUD CanvasLayer. LSP dialogs and floating panels parent here
## so they do not scale or pan with the world-space camera.
var hud: CanvasLayer
var lsp_panel: PanelContainer
var lsp_hover_panel: PanelContainer
var lsp_signature_panel: PanelContainer
var lsp_picker: PanelContainer
var debug_panel: PanelContainer

# native save-as + reload/keep-mine prompts
var save_dialog: FileDialog
var folder_dialog: FileDialog
var mod_import_dialog: FileDialog
var template_folder_dialog: FileDialog
var external_dialog: ConfirmationDialog
var compare_dialog: AcceptDialog
var compare_buffer_edit: CodeEdit
var compare_disk_edit: CodeEdit
var compare_buffer_label: Label
var compare_disk_label: Label
var git_diff_dialog: AcceptDialog
var close_dialog: ConfirmationDialog
var close_tab_dialog: ConfirmationDialog
var dialog_coordinator

var _save_as_index: int = -1
var _pending_close_index: int = -1
var _close_tab_index: int = -1
var _external_document = null
var _external_mtime: int = 0
var _closed_tabs: Array = []
var _quitting: bool = false
var _restoring_session: bool = false
var _notice_base_offset := Vector2.ZERO
var _pending_template_id: String = ""
var _glossary_pending: Dictionary = {}
var _trust_prompted_root: String = ""
var trust_dialog: ConfirmationDialog
var _history_interval: int = 60
var _history_warned: bool = false
## Files that already showed the large-file notice this session.
var _large_file_warned: Dictionary = {}

func _ready():
	# Without this, SceneTree auto-accepts the OS close request and the
	# confirmation below never gets a chance to run.
	get_tree().auto_accept_quit = false

	# Notices share the scene's old UI layer. Remember their designed inset so
	# the left dock can push them out of its way instead of clipping them.
	# (offset is ignored by the engine; only the transform applies.)
	_notice_base_offset = canvas_layer.transform.origin

	# Trust has to be known before the HUD builds the language and debug
	# managers: both read project config files while they initialize.
	trust_service = TRUST_SCRIPT.new()
	trust_service.load()

	_fit_window_to_usable_desktop()
	_setup_editor_services()
	_setup_commands()
	_setup_hud()
	_setup_overlays()
	_setup_dialogs()

	# Mods start after the HUD, dialogs and trust service exist, and before the
	# first user interaction. This is the single composition-root call from the
	# Phase 1 plan; no other startup step is reordered.
	_setup_mods()

	print(OS.get_cmdline_args())
	if LuaSingleton.discord_sdk:
		DiscordSDK.app_id = 1220393467738591242 # Application ID

		DiscordSDK.large_image = "griddycode" # Image key from the Discord portal's "Art Assets"; kept so the existing asset keeps working.
		DiscordSDK.large_image_text = "https://github.com/Nadeem-vibes/Qorix"
		DiscordSDK.start_timestamp = int(Time.get_unix_time_from_system())
	var running_on_gaming_os = OS.get_name() == "Windows"
	if running_on_gaming_os:
		current_dir = "C:/"

	var path = []

	# in order to be compatible with the gayming OS...
	var pwd_cmd = "pwd"
	# I didn't know that godot doesn't execute
	# commands within batch on Windows...
	var exec_args = []

	if running_on_gaming_os:
		# running "cd" (in batch) without any args will only print the path
		pwd_cmd = "cmd.exe"
		exec_args.append("/C")
		exec_args.append("cd")

	OS.execute(pwd_cmd, exec_args, path)

	if running_on_gaming_os:
		# EWW GROSS
		# why are we still using CRLF?
		path[0] = path[0].replace("\r", "")
	path = path[0].replace("\n", "")

	var cli_file := _cli_file_from_args(path)
	var is_cli := !cli_file.is_empty()
	if is_cli:
		current_file = cli_file
		current_dir = cli_file.get_base_dir()
	print("INFO: Running inside CLI mode: ", is_cli)

	inject_lua()
	check_for_reserved()

	# Themes are listed before anything that can emit on_theme_load (the
	# accessibility palette re-applies during the settings import, which runs
	# inside load_game). The Ctrl+T picker populates on the first emission, so
	# listing here guarantees it never reads the one-theme startup default.
	LuaSingleton.themes = list_themes()

	load_game(is_cli)

	LuaSingleton.setup_theme(LuaSingleton.theme)
	refresh_commands()

	_restore_session(is_cli)
	_sync_git_workspace()

	# Apply Beginner Mode last: settings are loaded inside load_game(), and the
	# session restore can reopen docks that a simplified UI should hide.
	_initialize_beginner_mode()
	# Settings are loaded by now; point the course at the UI language.
	_on_course_locale_refresh()

	file_dialog.setup()
	_start_background_timers()

	if documents.count() == 0:
		open_file(current_file)

	if documents.count() == 0:
		LuaSingleton.setup_discord_sdk("Idle", "")
		if _setting_bool("show_welcome", true) and welcome_panel != null:
			open_welcome()
		else:
			overlays.toggle(file_dialog)
			warn("Welcome to [color=#85c6ff]Qorix[/color]! Please select a file, then press CTRL + I to get started! :D")
	elif _session_recovered:
		warn("[color=#85c6ff]Session recovered[/color]: restored tabs and unsaved buffers from before the last crash.")
	else:
		editor_host.grab_active_focus()

	# A tutorial that was interrupted resumes at the same step.
	if onboarding != null and onboarding.is_active() and coach_panel != null:
		coach_panel.show_state(onboarding.snapshot())

## Returns an existing file explicitly requested on the command line. Engine
## flags are ignored: the Godot editor launches the project with --scene, and
## treating that as a CLI file used to skip session restore and save the cwd as
## the workspace. Only a positional file argument counts as CLI mode.
func _cli_file_from_args(cwd: String) -> String:
	var args := OS.get_cmdline_args()
	var base := cwd.replace("\\", "/")
	var i := 0
	while i < args.size():
		var arg := str(args[i])
		if arg.begins_with("-"):
			if CLI_VALUE_FLAGS.has(arg):
				i += 2
			else:
				i += 1
			continue
		if arg.is_empty() or arg == ".":
			i += 1
			continue

		var candidate := arg.replace("\\", "/")
		if !candidate.is_absolute_path():
			candidate = base.path_join(candidate)
		candidate = Paths.normalize(candidate)
		if FileAccess.file_exists(candidate):
			return candidate
		i += 1

	return ""


## Wires the editor services (documents, overlays, shortcuts) to the scene.
func _setup_editor_services() -> void:
	# The cursor trail is drawn in the world, right above the code, so it
	# scales with the camera exactly like the caret it belongs to.
	cursor_effect = $CursorEffect

	language_detector = GUESSLANG_SCRIPT.new()

	documents = DOCUMENTS_SCRIPT.new()
	documents.name = "Documents"
	documents.editor = self
	documents.host = editor_host
	add_child(documents)

	overlays = OVERLAYS_SCRIPT.new()
	overlays.name = "Overlays"
	overlays.editor = self
	overlays.camera = camera
	overlays.background = background
	add_child(overlays)

	input_controller = INPUT_SCRIPT.new()
	input_controller.name = "InputController"
	input_controller.editor = self
	add_child(input_controller)

	# Workspace index + global search + crash-safe session persistence. The
	# services are Nodes so their chunked pumps run on the main loop; the
	# session store is pure data and does not need a node.
	workspace = WORKSPACE_SCRIPT.new()
	workspace.name = "Workspace"
	add_child(workspace)

	search_service = SEARCH_SERVICE_SCRIPT.new()
	search_service.name = "SearchService"
	search_service.workspace = workspace
	add_child(search_service)

	# Worker threads are the runtime default. Headless runs keep the
	# deterministic frame-sliced path their suites pump explicitly.
	var headless := DisplayServer.get_name() == "headless"
	workspace.threaded_indexing = !headless
	search_service.threaded = !headless

	# Source control runs every git command on its own worker thread. The
	# editor only ever sees parsed snapshots and diff results.
	git_service = GIT_SERVICE_SCRIPT.new()
	git_service.name = "GitService"
	add_child(git_service)
	git_service.repo_changed.connect(_on_git_repo_changed)
	git_service.snapshot_changed.connect(_on_git_snapshot_changed)
	git_service.head_changed.connect(_on_git_head_changed)
	git_service.baseline_ready.connect(_on_git_baseline_ready)
	git_service.diff_ready.connect(_on_git_diff_ready)
	git_service.operation_finished.connect(_on_git_operation_finished)

	session = SESSION_SCRIPT.new()
	session.begin_session()

	workspace.root_changed.connect(_on_workspace_root_changed)
	workspace.index_finished.connect(_on_workspace_index_finished)

	documents.documents_changed.connect(_on_documents_changed)
	documents.active_document_changed.connect(_on_active_document_changed)
	documents.document_dirty_changed.connect(_on_document_dirty_changed)

	# Untitled buffers have no extension to answer "what language is this?".
	# Watch typing and detect after a short pause instead of on every key.
	editor_host.view_content_changed.connect(_on_view_content_changed)
	editor_host.view_created.connect(_on_editor_view_created)
	language_detect_timer = Timer.new()
	language_detect_timer.name = "LanguageDetect"
	language_detect_timer.wait_time = LANGUAGE_DETECT_SECONDS
	language_detect_timer.one_shot = true
	language_detect_timer.timeout.connect(_on_language_detect_timeout)
	add_child(language_detect_timer)

	# Phase 9: the beginner layer. The services are pure data/behaviour; FileManager
	# decides when to snapshot, show a card or start the preview server.
	templates = TEMPLATE_SERVICE_SCRIPT.new()
	welcome = WELCOME_SERVICE_SCRIPT.new()
	onboarding = ONBOARDING_SERVICE_SCRIPT.new()
	history = HISTORY_SERVICE_SCRIPT.new()
	glossary = GLOSSARY_SERVICE_SCRIPT.new()
	beginner_mode = BEGINNER_MODE_SCRIPT.new()

	preview_server = PREVIEW_SERVER_SCRIPT.new()
	preview_server.name = "PreviewServer"
	add_child(preview_server)

	onboarding.state_changed.connect(_on_onboarding_state_changed)
	onboarding.completed.connect(_on_onboarding_completed)

	# Hovering is debounced separately from the LSP request: the glossary card
	# only appears when the language server had nothing to say.
	glossary_timer = Timer.new()
	glossary_timer.name = "GlossaryHover"
	glossary_timer.wait_time = 0.55
	glossary_timer.one_shot = true
	glossary_timer.timeout.connect(_on_glossary_timer_timeout)
	add_child(glossary_timer)

	LuaSingleton.on_theme_load.connect(_on_theme_load)
	_on_theme_load()


## One command registry and one shortcut service for the whole editor. The
## registry is filled before the HUD exists so the generated menus and toolbar
## can read it during their own _ready().
func _setup_commands() -> void:
	commands = COMMAND_REGISTRY_SCRIPT.new()

	builtin_commands = BUILTIN_COMMANDS_SCRIPT.new()
	builtin_commands.editor = self
	builtin_commands.register_all(commands)

	# The Mods page is a host command, not a mod. Registering it here means the
	# generated menus and the command palette both find it like any other page.
	commands.register("mods.manage", {
		"label": "Mods…",
		"category": "View",
		"handler": Callable(self, "open_mods_settings"),
		"show_in_menu": true,
	})
	commands.register("mods.import", {
		"label": "Import Mod Package…",
		"category": "Mods",
		"handler": Callable(self, "open_mod_import_dialog"),
		"show_in_menu": true,
	})
	commands.executed.connect(_on_command_executed)

	keybindings = KEYBINDING_SERVICE_SCRIPT.new()
	keybindings.name = "Keybindings"
	keybindings.setup(commands)
	add_child(keybindings)
	keybindings.load_bindings()


## Re-registers list-valued commands (recent workspaces). Called when the
## palette or the shortcut editor opens and after either list changes.
func refresh_commands() -> void:
	if builtin_commands != null:
		builtin_commands.refresh_dynamic()

func check_for_reserved() -> void:
	var folders = ["langs", "themes"]

	for folder in folders:
		if !DirAccess.dir_exists_absolute("user://" + folder):
			DirAccess.make_dir_recursive_absolute("user://" + folder)

func get_drives() -> Array:
	# Windows: probe the standard drive letters. Every other platform has a
	# single "/" root that already contains every mounted volume.
	if OS.get_name() != "Windows":
		return ["/"]

	var drives = []
	for i in range(65, 91):
		var letter = char(i)
		if DirAccess.dir_exists_absolute(letter + ":/"):
			drives.append(letter + ":/")

	return drives

func _on_file_dialog_file_selected(path: String) -> void:
	open_file(path)

func inject_lua() -> void:
	DirAccess.make_dir_absolute("user://themes")
	DirAccess.make_dir_absolute("user://langs")

	var themes = DirAccess.open("res://resources/lua/themes").get_files()
	var plugins = DirAccess.open("res://resources/lua/plugins").get_files()

	for theme in themes:
		copy_if_not_exist("themes", "themes", theme)
	for plugin in plugins:
		copy_if_not_exist("langs", "plugins", plugin)
	_repair_broken_language_plugins()

func copy_from_res(from: String, to: String) -> void:
	var file_from = FileAccess.open(from, FileAccess.READ)
	var file_to = FileAccess.open(to, FileAccess.WRITE)
	file_to.store_buffer(file_from.get_buffer(file_from.get_length()))
	file_to = null
	file_from = null

func copy_if_not_exist(user_path: String, res_path: String, file: String) -> void:
	if !file.contains("lua"): return

	var path = "user://" + user_path + "/" + file;
	var current_path = "res://resources/lua/" + res_path + "/" + file;

	# Only copy when the file is missing. Re-copying on every launch used to
	# delete the user's version, wiping out any edits they made to built-ins.
	if FileAccess.file_exists(path): return

	copy_from_res(current_path, path)

## Built-in plugins are user-editable, so they are normally never overwritten.
## A few older builds shipped css.lua with a Lua syntax error that made every
## CSS file render without colors. Repair exactly that known-bad line once;
## a user copy that no longer contains it is left untouched.
func _repair_broken_language_plugins() -> void:
	var path := "user://langs/css.lua"
	if !FileAccess.file_exists(path): return
	if !FileAccess.get_file_as_string(path).contains("for keyword in css_keywords do"): return
	copy_from_res("res://resources/lua/plugins/css.lua", path)

# ── MOD CORE (PHASE 1) ──────────────────────────────────────────────────────

func _setup_mods() -> void:
	# Partial UI lives in a host-owned overlay. Creating it before the manager
	# lets the manager hand the same registry to every mod; teardown clears a
	# mod's mounts, dialogs and layout overrides by id.
	mod_ui = MOD_UI_REGISTRY_SCRIPT.new()
	mod_ui.name = "ModUi"
	hud.add_child(mod_ui)

	_setup_mod_learning()

	mods = MOD_MANAGER_SCRIPT.new()
	mods.name = "ModManager"
	add_child(mods)

	mod_failure_cards = MOD_FAILURE_CARDS_SCRIPT.new()
	mod_failure_cards.name = "ModFailureCards"
	hud.add_child(mod_failure_cards)
	mod_failure_cards.retry_requested.connect(_on_mod_retry_requested)
	mod_failure_cards.disable_requested.connect(_on_mod_disable_requested)
	mod_failure_cards.log_requested.connect(_show_mod_log)

	mods.notice.connect(_on_mod_notice)
	mods.failure_reported.connect(_on_mod_failure)
	mods.failure_cleared.connect(_on_mod_failure_cleared)

	mods.setup({
		"command_registry": commands,
		"keybinding_service": keybindings,
		"trust_service": trust_service,
		"workspace_root": Callable(self, "workspace_root_for_tools"),
		"editor_version": LuaSingleton.version,
		"developer_mode": OS.is_debug_build() or OS.get_cmdline_args().has("--mod-dev"),
		"preview_build": OS.has_feature("mod_preview") or OS.get_cmdline_args().has("--mod-preview"),
		"editor": self,
		"ui": mod_ui,
		"run_service": run_service,
		"shell": mod_shell_service,
		"guide": mod_guide,
		"exercise": mod_exercise,
		"validator": mod_validation,
	})

	mod_ui.setup({
		"manager": mods,
		"dispatch": Callable(self, "_dispatch_mod_handler"),
		"notify": Callable(self, "_on_mod_ui_notify"),
		"set_core_visible": Callable(self, "_set_core_panel_visible"),
	})

	mod_settings_panel = MOD_SETTINGS_PANEL_SCRIPT.new()
	mod_settings_panel.name = "ModSettings"
	hud.add_child(mod_settings_panel)
	mod_settings_panel.setup(mods, self)
	mod_settings_panel.log_requested.connect(_show_mod_log)
	mod_settings_panel.import_requested.connect(open_mod_import_dialog)

	if run_service != null:
		run_service.run_finished.connect(_on_run_finished_for_mods)
		run_service.run_blocked.connect(_on_run_blocked_for_mods)

	var report: Dictionary = mods.start()
	if !report.get("ok", false):
		push_warning("[mods] " + str(report.get("error", "Mod start failed.")))


## Builds the Phase 3 services and nodes. Called from `_setup_mods` after the
## partial-UI registry exists and before the manager activates the first mod.
func _setup_mod_learning() -> void:
	mod_validation = VALIDATION_SCRIPT.new()
	mod_validation.set_run_bridge(
		Callable(self, "_start_validation_run"),
		Callable(self, "_stop_validation_run"),
	)

	guide_overlay = GUIDE_OVERLAY_SCRIPT.new()
	guide_overlay.name = "GuideOverlay"
	editor_host.add_child(guide_overlay)
	if LuaSingleton.gui != null:
		guide_overlay.set_colors(
			LuaSingleton.gui.font_color,
			LuaSingleton.gui.selection_color,
			Color("#f7768e"),
		)

	guide_hints = GUIDE_HINTS_SCRIPT.new()
	guide_hints.name = "GuideHints"
	hud.add_child(guide_hints)

	mod_guide = GUIDE_SERVICE_SCRIPT.new()
	mod_guide.setup({
		"find_document": Callable(self, "_find_mod_document"),
		"active_document": Callable(self, "_active_mod_document"),
		"publish": Callable(self, "_publish_mod_event"),
		"overlay": guide_overlay,
		"hints": guide_hints,
		"validator": mod_validation,
		"mark_dirty": Callable(self, "_mark_mod_document_dirty"),
	})

	mod_exercise = EXERCISE_SERVICE_SCRIPT.new()
	mod_exercise.setup({
		"guide": mod_guide,
		"validator": mod_validation,
		"find_document": Callable(self, "_find_mod_document"),
		"active_document": Callable(self, "_active_mod_document"),
		"publish": Callable(self, "_publish_mod_event"),
		"show_hint": Callable(self, "_show_mod_hint"),
		"mark_dirty": Callable(self, "_mark_mod_document_dirty"),
	})

	mod_shell_service = SHELL_SERVICE_SCRIPT.new()
	mod_shell_service.setup({
		"panels": Callable(self, "shell_panels"),
		"add_layer": Callable(self, "_add_mod_shell_layer"),
		"remove_layer": Callable(self, "_remove_mod_shell_layer"),
		"apply_insets": Callable(self, "_apply_shell_insets"),
		"set_world_visible": Callable(self, "_set_mod_world_visible"),
		"ui": mod_ui,
		"mod_name": Callable(self, "_mod_display_name"),
		"set_shell_marker": Callable(self, "_set_shell_crash_marker"),
		"viewport_size": Callable(self, "_viewport_size"),
		"restore_editor_focus": Callable(self, "_restore_editor_focus"),
	})


func _dispatch_mod_handler(id: String, handle: int, payload: Variant) -> Dictionary:
	if mods == null:
		return {}
	return mods.invoke_handler(id, handle, payload)


# ── PHASE 3 BRIDGES ─────────────────────────────────────────────────────────

## Root panic path: exits the shell, and a second press inside two seconds (or a
## press with no shell) disables every mod for this session. Never routed through
## a mod.
func handle_mod_panic() -> void:
	if mods == null:
		return
	var now := Time.get_ticks_msec()
	var result: Dictionary = mods.panic_mods()
	if bool(result.get("had_shell", false)):
		_mod_panic_msec = now
		warn("[color=#85c6ff]MODS[/color]: Exited the mod shell. Press Ctrl+Alt+Shift+Esc again within two seconds to disable all mods.")
		return

	if _mod_panic_msec > 0 and now - _mod_panic_msec <= 2000:
		_mod_panic_msec = 0
		mods.disable_all_for_session("All mods were disabled from the panic shortcut.")
		warn("[color=#e0af68]MODS[/color]: All mods are disabled for this session.")
		return

	_mod_panic_msec = 0
	mods.disable_all_for_session("All mods were disabled from the panic shortcut.")
	warn("[color=#e0af68]MODS[/color]: All mods are disabled for this session.")


func filter_mod_guide_input(event: Dictionary) -> Dictionary:
	if mods == null:
		return {"action": "pass"}
	return mods.filter_guide_input(event)


## The filter decided a key is the expected structural chunk. Inserting here
## keeps the native undo stack: `insert_text_at_caret` is one edit.
func apply_mod_guide_insert(text: String) -> void:
	var view = active_view
	if view == null or text.is_empty():
		return
	view.insert_text_at_caret(text)


func _find_mod_document(id: Variant):
	if documents == null:
		return null
	return documents.find_by_id(int(id))


func _active_mod_document():
	return documents.active_document() if documents != null else null


func _mark_mod_document_dirty(document) -> void:
	if documents != null:
		documents.mark_dirty(document)


func _mod_display_name(id: String) -> String:
	if mods != null and mods.has_method("display_name"):
		return str(mods.display_name(str(id)))
	return str(id)


func _set_shell_crash_marker(active: bool) -> void:
	if mods != null and mods.has_method("mark_shell_active"):
		mods.mark_shell_active(bool(active))


## A shell with an editor slot owns the screen; the code view is the typing
## surface, so focus returns to it after the takeover and after any shell
## widget action. Without this, focus would stay on a shell button and every
## keystroke would be silently swallowed.
func _restore_editor_focus() -> void:
	if editor_host != null and is_instance_valid(editor_host) and editor_host.has_method("grab_active_focus"):
		editor_host.grab_active_focus()


func _viewport_size() -> Vector2:
	return get_viewport().get_visible_rect().size


func _add_mod_shell_layer(layer: CanvasLayer) -> void:
	if layer != null and layer.get_parent() == null:
		add_child(layer)


func _remove_mod_shell_layer(layer: CanvasLayer) -> void:
	if layer != null and layer.get_parent() == self:
		remove_child(layer)


func _apply_shell_insets(values: Dictionary) -> void:
	if camera == null:
		return
	if bool(values.get("active", true)):
		camera.set_content_insets(values)
	else:
		camera.clear_content_insets()


## Hides the whole world for a quiz-only shell and remembers what it was. Returns
## the previous visibility so the shell can restore it exactly.
func _set_mod_world_visible(visible: bool) -> Variant:
	if editor_host == null:
		return true
	var previous: bool = editor_host.visible
	if !visible:
		_mod_world_saved = previous
		editor_host.visible = false
		if external_background != null:
			external_background.visible = false
		if cursor_effect != null:
			cursor_effect.visible = false
	else:
		editor_host.visible = _mod_world_saved
		if external_background != null:
			external_background.visible = true
		if cursor_effect != null:
			cursor_effect.visible = true
	return previous


## Core panels a shell may hide. Names are stable because a mod can hide the
## same panels through editor.ui.layout.set_visible.
func shell_panels() -> Dictionary:
	var panels: Dictionary = {}
	for entry in [
		["top_bar", top_bar],
		["tabs", tabs],
		["explorer", file_tree],
		["search", search_panel],
		["source_control", source_control_panel],
		["minimap", minimap],
		["terminal", terminal],
		["output", output_panel],
		["problems", lsp_panel],
		["debugger", debug_panel],
		["notifications", notification_center],
		["welcome", welcome_panel],
		["coach", coach_panel],
	]:
		var node: Variant = entry[1]
		if node != null and is_instance_valid(node):
			panels[str(entry[0])] = node
	return panels


func _show_mod_hint(text: String) -> void:
	if guide_hints == null:
		return
	var size := get_viewport().get_visible_rect().size
	guide_hints.show_hint(str(text), Vector2(size.x * 0.5, size.y * 0.5), 6.0)


func _start_validation_run(path: String, options: Dictionary) -> void:
	if run_service == null:
		return
	run_service.call_deferred("run", path, options)


func _stop_validation_run() -> void:
	if run_service != null:
		run_service.call_deferred("stop")


func _on_mod_ui_notify(text: String, severity: String) -> void:
	_on_mod_notice(text, severity)


func open_mods_settings() -> void:
	if mod_settings_panel == null:
		warn("[color=yellow]MODS[/color]: The Mods page is not available yet.")
		return
	mod_settings_panel.open()


## Opens the native package picker. Every package goes through the panel's
## review dialog; the picker never installs anything itself.
func open_mod_import_dialog() -> void:
	if mod_import_dialog == null:
		warn("[color=yellow]MODS[/color]: The package picker is not available yet.")
		return
	open_mods_settings()
	mod_import_dialog.popup_centered_ratio(0.6)


func _on_mod_import_selected(path: String) -> void:
	open_mods_settings()
	if mod_settings_panel != null and mod_settings_panel.has_method("open_import"):
		mod_settings_panel.open_import(path)


## Maps a core panel name to its node. Returning null tells the UI registry
## that the name is not part of this build, so layout overrides fail closed.
func _set_core_panel_visible(panel: String, visible: bool) -> Variant:
	var node: CanvasItem = null
	match str(panel):
		"terminal":
			node = terminal
		"output":
			node = output_panel
		"problems", "language":
			node = lsp_panel
		"debugger":
			node = debug_panel
		"minimap":
			node = minimap
		"file_tree":
			node = file_tree
		"search":
			node = search_panel
		"source_control":
			node = source_control_panel
		_:
			return null
	if node == null or !is_instance_valid(node):
		return null
	var previous := node.visible
	node.visible = visible
	return previous


## Publishes a host event without letting a mod failure affect the editor.
func _publish_mod_event(name: String, payload: Dictionary) -> void:
	if mods == null or !mods.started:
		return
	var result: Dictionary = mods.publish(name, payload)
	if !result.get("ok", false) and str(result.get("code", "")) != "event.invalid":
		push_warning("[mods] event %s: %s" % [name, str(result.get("error", ""))])


func _on_command_executed(id: String, args: Array) -> void:
	var safe_args: Array = []
	for value in args:
		safe_args.append(str(value))
	_publish_mod_event("command.executed", {"id": str(id), "args": safe_args})


func _run_event_payload(info: Dictionary) -> Dictionary:
	return {
		"path": str(info.get("target", info.get("path", ""))),
		"command": str(info.get("command", "")),
		"mode": str(info.get("mode", "")),
		"profile": str(info.get("profile", info.get("language", ""))),
	}


func _on_run_finished_for_mods(_output: String, exit_code: int) -> void:
	# A validation run resolves through the learning engine; the mod still sees
	# run.finished, exactly like a run the user started.
	if mods != null:
		mods.notify_run_finished(_output, exit_code)
	var result: Dictionary = run_service.last_result if run_service != null else {}
	_publish_mod_event("run.finished", {
		"exit_code": int(exit_code),
		"status": str(result.get("status", "finished" if exit_code == 0 else "failed")),
		"stopped": bool(result.get("stopped", false)),
		"duration_ms": int(result.get("duration_ms", 0)),
		"truncated": bool(result.get("truncated", false)),
	})


func _on_run_blocked_for_mods(result: Dictionary) -> void:
	_publish_mod_event("run.blocked", {"reason": str(result.get("status", "blocked")), "message": str(result.get("message", ""))})


func _on_mod_notice(message: String, severity: String) -> void:
	var color := "#85c6ff"
	if severity == "error":
		color = "#f7768e"
	elif severity == "warning":
		color = "#e0af68"
	warn("[color=%s]Mods[/color]: %s" % [color, message])


func _on_mod_failure(id: String, failure: Dictionary) -> void:
	if mod_failure_cards != null:
		mod_failure_cards.show_failure(id, failure, mods != null and mods.developer_mode)


func _on_mod_failure_cleared(id: String) -> void:
	if mod_failure_cards != null:
		mod_failure_cards.clear(id)


func _on_mod_retry_requested(id: String) -> void:
	if mods == null:
		return
	var result: Dictionary = mods.reload_mod(id)
	if result.get("ok", false):
		if mod_failure_cards != null:
			mod_failure_cards.clear(id)
		return

	var failure: Variant = result.get("error", {})
	var message := str(failure.get("message", "Reload failed.")) if failure is Dictionary else "Reload failed."
	warn("[color=#f7768e]Mods[/color]: " + message)


func _on_mod_disable_requested(id: String) -> void:
	if mods == null:
		return
	mods.set_enabled(id, false, "Disabled by the user after a failure.")
	if mod_failure_cards != null:
		mod_failure_cards.clear(id)


func _show_mod_log(id: String) -> void:
	if mods == null:
		return

	if _mod_log_dialog == null:
		_mod_log_dialog = AcceptDialog.new()
		_mod_log_dialog.title = "Mod log"
		_mod_log_dialog.size = Vector2i(900, 600)

		var viewer := CodeEdit.new()
		viewer.name = "Log"
		viewer.editable = false
		viewer.placeholder_text = "No log lines."
		viewer.custom_minimum_size = Vector2(860, 540)
		_mod_log_dialog.add_child(viewer)
		add_child(_mod_log_dialog)

	var viewer := _mod_log_dialog.get_node_or_null("Log")
	if viewer is CodeEdit:
		(viewer as CodeEdit).text = mods.diagnostics.text(id)

	_mod_log_dialog.title = "Mod log — " + str(id)
	_mod_log_dialog.popup_centered()


func _document_event_payload(document, include_text: bool = true) -> Dictionary:
	var payload := {
		"id": int(document.id),
		"path": str(document.path),
		"title": str(document.title()),
		"dirty": bool(document.modified),
	}
	if include_text:
		payload["language"] = str(document.language_extension())
	return payload


func warn(notice: String) -> void:
	if notification_center != null and notification_center.has_method("push"):
		var severity := "info"
		if notice.to_lower().contains("error") or notice.to_lower().contains("could not"):
			severity = "error"
		elif notice.to_lower().contains("warning") or notice.to_lower().contains("failed"):
			severity = "warning"
		notification_center.push(notice, severity)
		return

	var node = NOTICE.instantiate()
	canvas_layer.add_child(node)
	node.set_notice(notice)
	get_tree().create_timer(5).timeout.connect(func() -> void:
		if is_instance_valid(node):
			node.queue_free()
	)

# ── DOCUMENTS ────────────────────────────────────────────────────────────────

func open_file(path: String) -> void:
	if path.is_empty(): return

	var normalized := Paths.normalize(path)
	if normalized.is_empty(): return

	# already open in a tab? switch to it instead of re-reading from disk.
	# same_file() folds separator/case spelling so "C:\foo" and "c:/foo"
	# cannot become two tabs for the same document.
	var existing = documents.find_by_path(normalized)
	if existing != null:
		documents.activate_document(existing)
		return

	if !FileAccess.file_exists(normalized):
		warn("[color=yellow]WARNING[/color]: Could not open \"%s\" — the file does not exist." % normalized)
		return

	var src = Fs._load(normalized)
	var open_started := Time.get_ticks_usec()
	documents.open_document(normalized, src)
	var open_msec := float(Time.get_ticks_usec() - open_started) / 1000.0
	var opened_doc = documents.active_document()
	if opened_doc != null and opened_doc.view != null and bool(opened_doc.view.get("large_file")):
		# Acceptance instrumentation: a 10,000-line file must open in under
		# 300 ms. The line is only printed for large-file-mode documents so
		# normal editing output stays quiet.
		print("INFO: large file %s opened in %.1f ms" % [normalized.get_file(), open_msec])

	# A file opened from outside the index (native picker, CLI, a program that
	# created it after the build) becomes part of quick open too.
	if workspace != null and workspace.has_workspace() and workspace.is_inside_workspace(normalized):
		if workspace.file_for_path(normalized) == null:
			workspace.note_changed(normalized)
			if file_tree != null:
				file_tree.refresh_all()

	if welcome != null:
		welcome.remember_file(normalized)
	_onboarding_document_opened()
	_sync_git_for_file(normalized)
	editor_host.grab_active_focus()

	var opened = documents.find_by_path(normalized)
	if opened != null:
		_publish_mod_event("document.opened", _document_event_payload(opened))

# ── LANGUAGE DETECTION ──────────────────────────────────────────────────────

## "Detect Language" command. Applies the best match as a manual override; a
## low-confidence answer is still applied because the user explicitly asked,
## but the notice says so and "Clear Detected Language" undoes it.
func detect_language(apply_override: bool = true) -> Dictionary:
	var document = documents.active_document()
	if document == null:
		warn("[color=yellow]LANGUAGE[/color]: Open a file first.")
		return {}
	if language_detector == null:
		warn("[color=yellow]LANGUAGE[/color]: The detector is unavailable.")
		return {}

	var result: Dictionary = language_detector.detect(document.text(), str(document.path))
	if !bool(result.get("ok", false)):
		warn("[color=yellow]LANGUAGE[/color]: %s" % str(result.get("message", "Could not identify this file.")))
		return result

	var language := str(result.get("language", ""))
	var confidence := float(result.get("confidence", 0.0))
	if language.is_empty() or language == "text":
		warn("[color=yellow]LANGUAGE[/color]: This looks like plain text; no language override was applied.")
		return result

	if apply_override:
		_apply_detected_language(document, result, "manual")
		var suffix := ""
		if confidence < language_detector.auto_confidence():
			suffix = " This is a weak match; use \"Clear Detected Language\" if it is wrong."
		warn("[color=#8bd5ff]LANGUAGE[/color]: Detected [b]%s[/b] (%d%% confidence). Highlighting and Run now use it.%s" % [
			str(result.get("display", language)), int(round(confidence * 100.0)), suffix,
		])
	else:
		warn("[color=#8bd5ff]LANGUAGE[/color]: Closest match: [b]%s[/b] (%d%% confidence)." % [
			str(result.get("display", language)), int(round(confidence * 100.0)),
		])
	return result


func clear_language_override() -> void:
	var document = documents.active_document()
	if document == null:
		return
	if !document.has_language_override():
		warn("[color=yellow]LANGUAGE[/color]: This file is already using its extension.")
		return
	document.clear_language_override(false)
	_refresh_document_language(document)
	warn("[color=#8bd5ff]LANGUAGE[/color]: Language override cleared; using .%s again." % document.extension())


## Every new tab gets its own LSP-facing signals. Connecting here (rather
## than in EditorView) keeps the widget independent of FileManager internals.
func _on_editor_view_created(view) -> void:
	if view == null:
		return
	view.hover_requested.connect(_on_view_hover_requested)
	view.definition_requested.connect(_on_view_definition_requested)
	view.caret_moved.connect(_on_view_caret_moved)
	view.problem_gutter_clicked.connect(_on_view_problem_gutter_clicked)
	view.action_gutter_clicked.connect(_on_view_action_gutter_clicked)
	view.git_gutter_clicked.connect(_on_view_git_gutter_clicked)
	view.debug_gutter_clicked.connect(_on_view_debug_gutter_clicked)
	_sync_debug_gutter(view.document)


func _on_view_hover_requested(view, line: int, column: int) -> void:
	if lsp_manager != null:
		lsp_manager.hover_symbol(view, line, column)
	_schedule_glossary(view, line, column)


func _on_view_definition_requested(view) -> void:
	if lsp_manager != null:
		lsp_manager.request_definition(view)


func _on_view_caret_moved(view, _line: int, _column: int) -> void:
	if mods != null:
		mods.notify_guide_caret(view)
	if glossary_timer != null:
		glossary_timer.stop()
	_glossary_pending = {}
	if lsp_manager != null:
		lsp_manager.schedule_signature(view)


func _on_view_problem_gutter_clicked(view, line: int) -> void:
	if cursor_effect != null and cursor_effect.has_method("pulse"):
		cursor_effect.pulse()
	if view != null and view.has_method("pulse_diagnostic"):
		view.pulse_diagnostic(line)
	if lsp_manager != null and view != null and view.document != null:
		lsp_manager.show_problems_at_line(view.document, line)


func _on_view_action_gutter_clicked(view, line: int) -> void:
	if cursor_effect != null and cursor_effect.has_method("pulse"):
		cursor_effect.pulse()
	if lsp_manager != null:
		lsp_manager.request_code_actions(view, line, -1, true)


func _on_lsp_diagnostics_updated() -> void:
	var total := 0
	if lsp_manager != null:
		total = int(lsp_manager.problem_counts().get("total", 0))
	# Only auto-open when the problem count grows, so a periodic republish
	# does not fight the user who just closed the panel.
	if total > _lsp_problem_total and _setting_bool("lsp_auto_open_problems", false):
		if lsp_panel != null:
			lsp_panel.open(0)
	_lsp_problem_total = total


## Typing in an untitled buffer (or a plain .txt file) is the only case where
## the extension cannot answer "what language is this?". Debounce the scan so
## a fast typist does not run every language profile on every keystroke.
func _on_view_content_changed(view) -> void:
	var document = view.document if view != null else null
	if document == null:
		return
	_publish_mod_event("document.changed", _document_event_payload(document))
	if mods != null:
		mods.notify_guide_text(view)
	if lsp_manager != null:
		lsp_manager.document_changed(document)
	_schedule_git_gutter(document)
	if onboarding != null and onboarding.is_active():
		onboarding.notify_typed()
	if language_detect_timer == null:
		return
	if document != documents.active_document():
		return
	if !_should_auto_detect_while_typing(document):
		return
	_pending_detect_document = document
	language_detect_timer.start()


func _on_language_detect_timeout() -> void:
	var document = _pending_detect_document
	_pending_detect_document = null
	if document == null or document != documents.active_document():
		return
	if !_should_auto_detect_while_typing(document):
		return
	_maybe_auto_detect(document, true, true)


## A manual override always wins. An automatic one also stops the scan: it
## already changed the highlighting, and re-guessing on every pause would make
## the colors and the notification flicker.
func _should_auto_detect_while_typing(document) -> bool:
	if document == null or language_detector == null:
		return false
	if !_setting_bool("auto_detect_language", true):
		return false
	if document.has_language_override():
		return false
	return document.untitled or str(document.extension()) == "txt"


## Auto-detect when the extension cannot answer the question (an untitled
## buffer, plain .txt, or a type Qorix has no language file for).
## `notify` is false during session restore so reopening ten notes does not
## produce ten notifications. `allow_retry` is used while typing: a short
## buffer that is not yet recognizable must be checked again after the user
## writes more, so it does not set the one-shot `attempted` flag.
func _maybe_auto_detect(document, notify: bool = true, allow_retry: bool = false) -> void:
	if document == null or language_detector == null:
		return
	if document.has_language_override():
		return
	if bool(document.language_detection_attempted) and !allow_retry:
		return
	if !_setting_bool("auto_detect_language", true):
		return

	var extension: String = str(document.extension())
	var service = LuaSingleton.language_service
	if extension != "txt" and service != null and service.has_language(extension):
		return

	var text: String = str(document.text())
	if text.strip_edges().length() < language_detector.min_chars():
		return

	var result: Dictionary = language_detector.detect(text, str(document.path))
	if !bool(result.get("ok", false)) or !bool(result.get("auto", false)):
		if !allow_retry:
			document.language_detection_attempted = true
		return
	var language := str(result.get("language", ""))
	if language.is_empty() or language == "text":
		if !allow_retry:
			document.language_detection_attempted = true
		return

	document.language_detection_attempted = true
	_apply_detected_language(document, result, "auto")
	if notify:
		_notify_detected_language(document, result)


func _notify_detected_language(document, result: Dictionary) -> void:
	var display := str(result.get("display", result.get("language", "")))
	var percent := int(round(float(result.get("confidence", 0.0)) * 100.0))

	if document.untitled:
		var extension := _preferred_extension(document)
		var hint := "saving will suggest a matching extension"
		if !extension.is_empty():
			hint = "saving will suggest a .%s file" % extension
		warn("[color=#8bd5ff]LANGUAGE[/color]: Detected [b]%s[/b] (%d%% confidence). Highlighting and Run now use it; %s." % [display, percent, hint])
		return

	warn("[color=#8bd5ff]LANGUAGE[/color]: Detected [b]%s[/b] (%d%% confidence) in this plain-text file. Highlighting and Run now use it; Command Palette → \"Clear Detected Language\" undoes this." % [display, percent])


func _apply_detected_language(document, result: Dictionary, source: String) -> void:
	var language := str(result.get("language", ""))
	var highlight := str(result.get("highlight", ""))
	if highlight.is_empty() and language_detector != null:
		highlight = language_detector.highlight_for(language)
	document.set_language_override(language, highlight, source)
	_refresh_document_language(document)
	if tabs != null:
		tabs.sync()


func _refresh_document_language(document) -> void:
	if document == null:
		return
	var extension: String = str(document.language_extension())
	if document.view != null and is_instance_valid(document.view):
		document.view.set_language_extension(extension)
	if document == documents.active_document():
		LuaSingleton.setup_extension(extension)
	if lsp_manager != null:
		lsp_manager.sync_open_documents()
		if document == documents.active_document():
			lsp_manager.active_document_changed(document)


func select_tab(index: int) -> void:
	documents.activate_index(index)

func close_tab(index: int) -> void:
	if index == -1: index = active_tab
	if index < 0 or index >= open_tabs.size(): return

	var document = documents.at(index)

	# Unsaved documents need an explicit choice. Saved files are still saved
	# on close; a failed save keeps the tab open.
	if document.modified:
		if document.untitled:
			_prompt_unsaved_tab_close(index)
			return
		if !_save_document(document):
			return

	_remove_document(index)

func _prompt_unsaved_tab_close(index: int) -> void:
	if close_tab_dialog == null or close_tab_dialog.visible: return
	var document = documents.at(index)
	if document == null: return

	_close_tab_index = index
	close_tab_dialog.dialog_text = "\"%s\" has unsaved changes.\n\nSave before closing?" % document.title()
	close_tab_dialog.popup_centered()

func _on_close_tab_save() -> void:
	var index := _close_tab_index
	_close_tab_index = -1
	close_tab_dialog.hide()

	if index < 0 or index >= open_tabs.size(): return
	save_as(index, true)

func _on_close_tab_discard(action: StringName) -> void:
	if action != &"discard": return

	var index := _close_tab_index
	_close_tab_index = -1
	close_tab_dialog.hide()

	var document = documents.at(index)
	if document == null: return
	# Don't save: drop the dirty flag so _remove_document() doesn't prompt again.
	document.mark_clean()
	_remove_document(index)

func _on_close_tab_canceled() -> void:
	_close_tab_index = -1
	close_tab_dialog.hide()

## Removes a tab that is safe to discard. The caller is responsible for saving
## or explicitly discarding unsaved contents first.
func _remove_document(index: int) -> void:
	var document = documents.at(index)
	if document == null: return
	var closing_document_id := int(document.id)

	_publish_mod_event("document.closed", _document_event_payload(document, false))

	# A guide or exercise session bound to this document would keep a stale
	# view and own the learning-engine slot; stop it instead of letting it
	# anchor hints to a freed view.
	if mod_guide != null and mod_guide.has_method("stop_for_document"):
		mod_guide.stop_for_document(closing_document_id, "The lesson's file was closed.")
	if mod_exercise != null and mod_exercise.has_method("stop_for_document"):
		mod_exercise.stop_for_document(closing_document_id, "The exercise's file was closed.")

	# The active view owns the live caret/selection; flush it before the view
	# is freed so reopen can restore the exact spot.
	documents.capture_active_state()

	_closed_tabs.append({
		"path": document.path,
		"title": document.title(),
		"text": document.text(),
		"untitled": document.untitled,
		"caret_line": document.caret_line,
		"caret_column": document.caret_column,
		"language": document.language_override,
		"language_highlight": document.language_highlight,
		"language_source": document.language_source,
	})
	if _closed_tabs.size() > MAX_CLOSED_TABS:
		_closed_tabs.pop_front()

	documents.remove_document(index)
	if lsp_manager != null:
		lsp_manager.sync_open_documents()

func save_current() -> void:
	var document = documents.active_document()
	if document == null: return

	if document.untitled or document.path.is_empty():
		save_as(active_tab)
		return

	_save_document(document)

## Returns false when the write failed, so callers can refuse to discard.
func _save_document(document) -> bool:
	if document == null: return false

	var path := str(document.path)
	if path.is_empty(): return false

	var content: String = document.text()
	# Keep the version that is about to be replaced. This is what "Restore
	# previous version" offers after a bad edit.
	_snapshot_disk(path, "before_save")

	var result: Dictionary = Fs.save(path, content)
	if !result.get("ok", false):
		warn("[color=red]SAVE FAILED[/color]: %s" % str(result.get("error", "Unknown error.")))
		return false

	document.mark_clean()
	document.disk_mtime = _mtime(path)
	_publish_mod_event("document.saved", _document_event_payload(document))
	_note_file_changed(path)
	if welcome != null:
		welcome.remember_file(path)
	if preview_server != null:
		preview_server.notify_changed(path)
	if lsp_manager != null:
		lsp_manager.document_saved(document)
	_schedule_git_gutter(document)
	if git_service != null and git_service.has_repo():
		git_service.refresh(true)

	if tabs != null:
		tabs.sync()
	return true

## Opens the native save dialog for the given tab (active by default).
## close_after: close the tab only once the write succeeds.
func save_as(index: int = -1, close_after: bool = false) -> void:
	if index == -1: index = active_tab
	var document = documents.at(index)
	if document == null: return

	_save_as_index = index
	_pending_close_index = index if close_after else -1

	var extensions := _save_extensions_for(document)
	var filter := _save_filter_for(document, extensions)
	var filters := PackedStringArray()
	if !filter.is_empty() and filter != "*.* ; All files":
		filters.append(filter)
	filters.append("*.* ; All files")
	save_dialog.filters = filters

	var target := str(document.path)
	if !target.is_empty():
		save_dialog.current_path = target
		save_dialog.current_dir = target.get_base_dir()
		save_dialog.current_file = target.get_file()
	else:
		var base_dir := workspace_root_for_tools()
		save_dialog.current_dir = base_dir if !base_dir.is_empty() else "user://"
		save_dialog.current_file = _default_save_name(document, extensions)

	save_dialog.popup_centered_ratio(0.6)


## The language key Save As should use: a detected/manual profile id first,
## then the highlighter extension, then the file's own extension.
func _save_language_key(document) -> String:
	var language := str(document.language_override)
	if language.is_empty():
		language = str(document.language_highlight)
	if language.is_empty():
		language = str(document.extension())
	return language


## Extensions Save As should offer, canonical first. Detection stores the
## profile id in `language_override`; a saved file falls back to its own
## extension so the dialog still offers a matching filter.
func _save_extensions_for(document) -> Array:
	var language := _save_language_key(document)
	if language_detector != null:
		var detected: Array = language_detector.extensions_for(language)
		if !detected.is_empty():
			return detected
	var current := str(document.extension())
	return [current] if !current.is_empty() else []


func _preferred_extension(document) -> String:
	var extensions := _save_extensions_for(document)
	return str(extensions[0]) if !extensions.is_empty() else ""


## "*.py, *.pyw ; Python files" for the detected language. The native dialog
## shows this in its file-type dropdown instead of the old "All files (*.*)".
func _save_filter_for(document, extensions: Array) -> String:
	if extensions.is_empty():
		return "*.* ; All files"

	var patterns := ""
	for extension in extensions:
		if !patterns.is_empty():
			patterns += ", "
		patterns += "*." + str(extension)

	var language := _save_language_key(document)
	var label := ""
	if language_detector != null:
		label = str(language_detector.profile_for(language).get("display", ""))
	if label.is_empty():
		label = str(extensions[0]).to_upper()
	return "%s ; %s files" % [patterns, label]


func _default_save_name(document, extensions: Array) -> String:
	var title := str(document.title())
	if extensions.is_empty():
		return title
	var extension := str(extensions[0])
	if title.get_extension().to_lower() == extension.to_lower():
		return title
	return title + "." + extension


func _on_save_as_file_selected(path: String) -> void:
	var index := _save_as_index
	_save_as_index = -1

	var document = documents.at(index)
	if document == null:
		_pending_close_index = -1
		return

	var target := Paths.normalize(path)
	if target.is_empty():
		_pending_close_index = -1
		return

	# The dialog starts with "Untitled 1.py" for a detected Python buffer. If
	# the user erases the extension, keep the detected language's canonical one
	# instead of writing an extensionless file.
	if document.has_language_override() and target.get_file().get_extension().is_empty():
		var extension := _preferred_extension(document)
		if !extension.is_empty():
			target = target.trim_suffix(".") + "." + extension

	# Two tabs must never point at the same canonical file: saving one would
	# silently overwrite the other's buffer.
	for other in open_tabs:
		if other == document: continue
		if Paths.same_file(str(other.path), target):
			warn("[color=yellow]WARNING[/color]: \"%s\" is already open in another tab." % target)
			_pending_close_index = -1
			return

	var content: String = document.text()
	var previous_path := str(document.path)
	# Saving over an existing file is still a replacement: keep its old bytes.
	_snapshot_disk(target, "before_save")

	var result: Dictionary = Fs.save(target, content)
	if !result.get("ok", false):
		warn("[color=red]SAVE FAILED[/color]: %s" % str(result.get("error", "Unknown error.")))
		_pending_close_index = -1
		return

	document.path = target
	document.display_name = target.get_file()
	document.untitled = false
	document.disk_mtime = _mtime(target)
	document.mark_clean()
	if welcome != null:
		welcome.remember_file(target)
	if preview_server != null:
		preview_server.notify_changed(target)
	_onboarding_document_opened()

	# A new name/extension is a new answer to "what language is this?".
	# Dropping the override here also removes a stale GuessLang guess made for
	# a .txt file before it became a real .py/.js file.
	if document.has_language_override():
		document.clear_language_override(true)

	if workspace != null and workspace.has_workspace():
		if previous_path.is_empty():
			workspace.note_created(target)
		else:
			workspace.note_renamed(previous_path, target)
		if file_tree != null:
			file_tree.refresh_all()

	if document.view != null and is_instance_valid(document.view):
		document.view.set_language_extension(document.language_extension())

	# Save As changes the repository path the document belongs to.
	_sync_git_for_file(target)
	_reset_git_baseline(document)
	_request_git_baseline(document)

	if index == active_tab:
		current_file = target
		LuaSingleton.setup_extension(document.language_extension())
		_maybe_auto_detect(document, true)
		LuaSingleton.setup_discord_sdk("Editing " + target.get_file(), "In " + current_dir.split("/")[-1])

	if tabs != null:
		tabs.sync()

	if lsp_manager != null:
		# The URI changed. This closes the old didOpen and opens the new
		# path, so diagnostics and features follow the file to its new name.
		if index == active_tab:
			lsp_manager.active_document_changed(document)
		else:
			lsp_manager.sync_open_documents()

	if _pending_close_index != -1:
		var closing := _pending_close_index
		_pending_close_index = -1
		close_tab(closing)

func _on_save_as_canceled() -> void:
	_save_as_index = -1
	_pending_close_index = -1

func new_tab() -> void:
	documents.new_untitled("", "")
	_onboarding_document_opened()
	editor_host.grab_active_focus()

func _append_untitled_tab(content: String, title: String = "") -> Variant:
	var document = documents.new_untitled(content, title)
	_onboarding_document_opened()
	editor_host.grab_active_focus()
	return document

func reopen_last_closed_tab() -> void:
	if _closed_tabs.is_empty():
		warn("[color=yellow]WARNING[/color]: There is no recently closed tab to reopen.")
		return

	var entry: Dictionary = _closed_tabs.pop_back()
	var path := str(entry.get("path", ""))

	if !path.is_empty() and FileAccess.file_exists(path):
		open_file(path)
		var document = documents.active_document()
		if document != null:
			_restore_closed_language(document, entry)
			document.caret_line = int(entry.get("caret_line", 0))
			document.caret_column = int(entry.get("caret_column", 0))
			document.restore_state()
		return

	# The file is gone (or the entry was untitled): bring the text back as an
	# unsaved buffer so it can still be saved somewhere else.
	var reopened = _append_untitled_tab(str(entry.get("text", "")), str(entry.get("title", "")))
	if reopened != null:
		_restore_closed_language(reopened, entry)


func _restore_closed_language(document, entry: Dictionary) -> void:
	var language := str(entry.get("language", ""))
	var highlight := str(entry.get("language_highlight", ""))
	if language.is_empty() and highlight.is_empty():
		return
	document.set_language_override(language, highlight, str(entry.get("language_source", "manual")))
	_refresh_document_language(document)

func sync_tab_dirty() -> void:
	if tabs == null: return
	tabs.sync()

# ── SETTINGS / SESSION ───────────────────────────────────────────────────────

func _mtime(path: String) -> int:
	if path.is_empty() or !FileAccess.file_exists(path): return 0
	return FileAccess.get_modified_time(ProjectSettings.globalize_path(path))


# ── SESSION RESTORE / PERSISTENCE ────────────────────────────────────────────

## Compatibility read for settings that may not exist in an older schema.
func _setting_value(key: String, fallback: Variant) -> Variant:
	var found = LuaSingleton.get_setting(key)
	if found is Array and found.size() >= 2 and int(found[1]) != -1:
		return found[0].get("value", fallback)
	return fallback


func _setting_bool(key: String, fallback: bool) -> bool:
	return bool(_setting_value(key, fallback))


## Called once at startup, after the theme is ready and legacy data.save has
## been loaded. CLI launches deliberately skip document/panel restore so the
## requested file is what opens.
func _restore_session(cli: bool) -> void:
	if session == null:
		return

	var loaded: Dictionary = session.load_session()
	_session_loaded = bool(loaded.get("ok", false))
	_session_recovered = _session_loaded and bool(loaded.get("recovered", false))

	var data: Dictionary = {}
	if _session_loaded:
		data = loaded.get("data", {})

	if cli:
		if !current_file.is_empty() and FileAccess.file_exists(current_file):
			var opened: Dictionary = workspace.open_folder(current_file.get_base_dir(), false)
			if bool(opened.get("ok", false)):
				current_dir = workspace.root
		return

	var restored_workspace := false
	if _session_loaded:
		var root := str(data.get("workspace_root", ""))
		if !root.is_empty() and DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(root)):
			var opened: Dictionary = workspace.open_folder(root, false)
			if bool(opened.get("ok", false)):
				current_dir = workspace.root
				restored_workspace = true

	var restore_enabled := _setting_bool("restore_session", true)
	if !restored_workspace and restore_enabled:
		# A previous CLI-launch bug overwrote session.json with an empty
		# workspace. If there is nothing to restore, reopen the most recent
		# workspace instead of silently falling back to the process cwd.
		var raw_docs: Variant = data.get("documents", [])
		var has_documents: bool = raw_docs is Array and !raw_docs.is_empty()
		if !has_documents and workspace != null:
			for raw_recent in workspace.recent_workspaces:
				var recent := str(raw_recent)
				if recent.is_empty() or !DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(recent)):
					continue
				set_workspace(recent, false)
				break

	if !_session_loaded or !restore_enabled:
		return

	_restoring_session = true
	_restore_documents(data)
	_restore_panels(data)
	_restoring_session = false

	# Restored documents that did not activate last still deserve their one
	# auto-detection attempt. Notifications stay silent during restore.
	for document in open_tabs:
		_maybe_auto_detect(document, false)


func _restore_documents(data: Dictionary) -> void:
	var raw_documents: Variant = data.get("documents", [])
	if !(raw_documents is Array):
		return

	var missing_backups := 0

	for raw in raw_documents:
		if !(raw is Dictionary):
			continue

		var entry: Dictionary = raw
		var path := str(entry.get("path", ""))
		var untitled := bool(entry.get("untitled", path.is_empty()))
		var title := str(entry.get("title", ""))
		var modified := bool(entry.get("modified", false))
		var has_text := entry.has("text")
		var text := str(entry.get("text", ""))
		var document = null

		if !untitled and !path.is_empty() and FileAccess.file_exists(path):
			var disk := Fs._load(path)
			document = documents.open_document(path, disk)
			if modified and has_text and text != disk:
				document.set_text(text, false)
				document.mark_dirty()
			elif modified and !has_text:
				missing_backups += 1
		elif untitled:
			if !has_text and !modified:
				continue
			document = documents.new_untitled(text, title)
		elif has_text and !text.is_empty():
			# The saved file disappeared while the editor was closed, but the
			# backup still has the bytes: recover them as an unsaved buffer.
			var recovered_title := title if !title.is_empty() else path.get_file() + " (missing)"
			document = documents.new_untitled(text, recovered_title)

		if document == null:
			continue

		if modified and !document.modified:
			document.mark_dirty()

		document.caret_line = maxi(0, int(entry.get("caret_line", 0)))
		document.caret_column = maxi(0, int(entry.get("caret_column", 0)))
		document.scroll_vertical = maxi(0, int(entry.get("scroll_vertical", 0)))
		document.scroll_horizontal = maxi(0, int(entry.get("scroll_horizontal", 0)))
		document.has_selection_state = bool(entry.get("has_selection", false))
		document.selection_from_line = maxi(0, int(entry.get("selection_from_line", 0)))
		document.selection_from_column = maxi(0, int(entry.get("selection_from_column", 0)))
		document.selection_to_line = maxi(0, int(entry.get("selection_to_line", 0)))
		document.selection_to_column = maxi(0, int(entry.get("selection_to_column", 0)))
		document.encoding = str(entry.get("encoding", document.encoding))
		document.line_endings = str(entry.get("line_endings", document.line_endings))

		var language := str(entry.get("language", ""))
		var language_highlight := str(entry.get("language_highlight", ""))
		if !language.is_empty() or !language_highlight.is_empty():
			document.set_language_override(language, language_highlight, str(entry.get("language_source", "manual")))
			if document.view != null and is_instance_valid(document.view):
				document.view.set_language_extension(document.language_extension())
		document.restore_state()

	if missing_backups > 0:
		warn("[color=yellow]SESSION[/color]: %d unsaved buffer backup(s) were missing; the disk version was opened instead." % missing_backups)

	if documents.count() > 0:
		var active := clampi(int(data.get("active_index", 0)), 0, documents.count() - 1)
		documents.activate_index(active)


func _restore_panels(data: Dictionary) -> void:
	var panels: Dictionary = {}
	var raw_panels: Variant = data.get("panels", {})
	if raw_panels is Dictionary:
		panels = raw_panels

	# Only one left dock can hold the slot. The order is the priority used when
	# an older/corrupt snapshot claims several were open at once.
	if bool(panels.get("search", false)) and search_panel != null:
		search_panel.open()
	elif bool(panels.get("git", false)) and source_control_panel != null:
		var raw_git: Variant = data.get("git", {})
		if raw_git is Dictionary:
			source_control_panel.restore_session(raw_git)
		else:
			source_control_panel.open()
	elif bool(panels.get("file_tree", false)) and file_tree != null:
		file_tree.open()

	if terminal != null:
		var raw_terminal: Variant = data.get("terminal", {})
		if raw_terminal is Dictionary:
			terminal.restore_session(raw_terminal)

	if output_panel != null:
		var raw_output: Variant = data.get("output", {})
		if raw_output is Dictionary:
			output_panel.restore_session(raw_output)

	if lsp_panel != null:
		var raw_lsp: Variant = data.get("lsp", {})
		if raw_lsp is Dictionary:
			lsp_panel.restore_session(raw_lsp)

	if debug_panel != null:
		var raw_debug: Variant = data.get("debug", {})
		if raw_debug is Dictionary:
			debug_panel.restore_session(raw_debug)


func _snapshot_session() -> Dictionary:
	if documents != null:
		documents.capture_active_state()

	var list: Array = []
	for document in open_tabs:
		var entry := {
			"path": str(document.path),
			"title": document.title(),
			"untitled": document.untitled,
			"modified": document.modified,
			"caret_line": document.caret_line,
			"caret_column": document.caret_column,
			"scroll_vertical": document.scroll_vertical,
			"scroll_horizontal": document.scroll_horizontal,
			"has_selection": document.has_selection_state,
			"selection_from_line": document.selection_from_line,
			"selection_from_column": document.selection_from_column,
			"selection_to_line": document.selection_to_line,
			"selection_to_column": document.selection_to_column,
			"encoding": document.encoding,
			"line_endings": document.line_endings,
			"language": document.language_override,
			"language_highlight": document.language_highlight,
			"language_source": document.language_source,
		}
		# Only dirty/untitled buffers need a backup; clean saved files reopen
		# from disk. SessionService copies these strings out to backup files.
		if document.modified or document.untitled:
			entry["text"] = document.text()
		list.append(entry)

	var terminal_data: Dictionary = {}
	if terminal != null:
		terminal_data = terminal.capture_session()

	var output_data: Dictionary = {}
	if output_panel != null:
		output_data = output_panel.capture_session()

	var lsp_data: Dictionary = {}
	if lsp_panel != null:
		lsp_data = lsp_panel.capture_session()

	var git_data: Dictionary = {}
	if source_control_panel != null:
		git_data = source_control_panel.capture_session()

	var debug_data: Dictionary = {}
	if debug_panel != null:
		debug_data = debug_panel.capture_session()

	return {
		"workspace_root": workspace.root if workspace != null else "",
		"active_index": maxi(active_tab, 0),
		"documents": list,
		"terminal": terminal_data,
		"output": output_data,
		"lsp": lsp_data,
		"git": git_data,
		"debug": debug_data,
		"panels": {
			"file_tree": file_tree != null and file_tree.visible,
			"search": search_panel != null and search_panel.visible,
			"git": source_control_panel != null and source_control_panel.visible,
			"terminal": terminal != null and terminal.visible,
			"output": output_panel != null and output_panel.visible,
			"lsp": lsp_panel != null and lsp_panel.visible,
			"debug": debug_panel != null and debug_panel.visible,
		},
	}


func _save_session(final: bool) -> void:
	if session == null:
		return

	var snapshot := _snapshot_session()
	var result: Dictionary
	if final:
		result = session.finish_session(snapshot)
	else:
		result = session.save_session(snapshot)

	if !result.get("ok", false):
		push_warning("Could not save session: " + str(result.get("error", "")))


func _start_background_timers() -> void:
	if session != null:
		var seconds := float(_setting_value("session_autosave", 20))
		session_timer = Timer.new()
		session_timer.name = "SessionAutosave"
		session_timer.wait_time = maxf(5.0, seconds)
		session_timer.one_shot = false
		session_timer.timeout.connect(_on_session_timer_timeout)
		add_child(session_timer)
		session_timer.start()

	external_timer = Timer.new()
	external_timer.name = "ExternalChangeWatch"
	external_timer.wait_time = EXTERNAL_POLL_SECONDS
	external_timer.one_shot = false
	external_timer.timeout.connect(_on_external_timer_timeout)
	add_child(external_timer)
	external_timer.start()

	# Source Control polling is deliberately slower than the disk watcher and
	# only runs while the dock is visible. A huge repository therefore costs
	# nothing while the user is editing with the panel closed.
	git_refresh_timer = Timer.new()
	git_refresh_timer.name = "GitAutoRefresh"
	git_refresh_timer.wait_time = 5.0
	git_refresh_timer.one_shot = false
	git_refresh_timer.timeout.connect(_on_git_refresh_timer_timeout)
	add_child(git_refresh_timer)
	_sync_git_auto_refresh()

	# Typing repaints the active gutter after a short pause instead of running
	# a whole-buffer diff on every keypress.
	git_gutter_timer = Timer.new()
	git_gutter_timer.name = "GitGutterDelay"
	git_gutter_timer.wait_time = 0.25
	git_gutter_timer.one_shot = true
	git_gutter_timer.timeout.connect(_on_git_gutter_timer_timeout)
	add_child(git_gutter_timer)

	# A modified buffer is copied into History on a quiet timer, so an hour of
	# typing without pressing Save still leaves something to go back to.
	history_timer = Timer.new()
	history_timer.name = "HistoryAutosave"
	history_timer.one_shot = false
	history_timer.timeout.connect(_on_history_timer_timeout)
	add_child(history_timer)
	apply_history_setting()


func _on_session_timer_timeout() -> void:
	if _quitting or session == null or documents == null:
		return
	_save_session(false)


func _on_external_timer_timeout() -> void:
	if !_setting_bool("external_change_check", true):
		return
	_check_external_changes()


## Applies the persisted back-up interval to the running timer. Called at
## startup and whenever the setting changes.
func apply_history_setting() -> void:
	var seconds := int(_setting_value("history_interval", 60))
	_history_interval = clampi(seconds, 15, 600)
	if history_timer == null:
		return
	history_timer.wait_time = float(_history_interval)
	if _setting_bool("history_enabled", true) and !_quitting:
		if history_timer.is_stopped():
			history_timer.start()
	else:
		history_timer.stop()


func _on_history_timer_timeout() -> void:
	if !_setting_bool("history_enabled", true):
		return
	_snapshot_dirty_documents("autosave")

## The project asks for a 1920x1080 window, but the Windows taskbar is not part
## of that area. A windowed client at y=0 can hang ~2 terminal rows under the
## taskbar, and borderless fullscreen can leave the taskbar drawn over the
## terminal dock. Keep the window inside the desktop's usable rect: maximize
## fullscreen (the OS respects the taskbar there), and clamp/nudge a windowed
## game once at startup so every pixel of the editor is actually visible.
func _fit_window_to_usable_desktop() -> void:
	var mode := DisplayServer.window_get_mode()
	var screen := DisplayServer.window_get_current_screen()
	var usable := DisplayServer.screen_get_usable_rect(screen)
	if usable.size.x <= 0 or usable.size.y <= 0:
		return

	# A borderless fullscreen window spans the whole screen while the taskbar
	# stays on top of it, hiding the bottom rows of the terminal. Maximized
	# mode uses the work area instead; keep real exclusive fullscreen alone.
	if mode == DisplayServer.WINDOW_MODE_FULLSCREEN:
		if usable.size != DisplayServer.screen_get_size(screen):
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MAXIMIZED)
		return

	if mode != DisplayServer.WINDOW_MODE_WINDOWED:
		return

	var size := DisplayServer.window_get_size()
	var fitted := Vector2i(mini(size.x, usable.size.x), mini(size.y, usable.size.y))
	if fitted != size:
		DisplayServer.window_set_size(fitted)

	var pos := DisplayServer.window_get_position()
	var clamped := Vector2i(
		clampi(pos.x, usable.position.x, maxi(usable.position.x, usable.end.x - fitted.x)),
		clampi(pos.y, usable.position.y, maxi(usable.position.y, usable.end.y - fitted.y))
	)
	if clamped != pos:
		DisplayServer.window_set_position(clamped)

func _setup_hud() -> void:
	# screen-space controls live in their own CanvasLayer: they stay put while
	# the camera zooms around the code.
	hud = CanvasLayer.new()
	hud.name = "HUD"
	add_child(hud)

	# Language support listens to documents and settings, not to any one
	# panel. Create it before the HUD panels so their _ready() can read it.
	lsp_manager = LSP_MANAGER_SCRIPT.new()
	lsp_manager.name = "LspManager"
	lsp_manager.editor = self
	add_child(lsp_manager)
	lsp_manager.diagnostics_updated.connect(_on_lsp_diagnostics_updated)

	# The debugger owns its adapter session and breakpoints. Like language
	# support it is a plain Node, not a panel, so a paused program stays
	# inspectable and a running session survives closing the dock.
	dap_manager = DAP_MANAGER_SCRIPT.new()
	dap_manager.name = "DapManager"
	dap_manager.editor = self
	add_child(dap_manager)
	dap_manager.set_workspace(workspace.root if workspace != null else "")
	dap_manager.session_started.connect(_on_debug_session_started)
	dap_manager.session_ended.connect(_on_debug_session_ended)
	dap_manager.execution_line_changed.connect(_on_debug_execution_line_changed)
	dap_manager.navigate_requested.connect(_on_debug_navigate_requested)
	dap_manager.breakpoints_changed.connect(_on_debug_breakpoints_changed)

	# Generated menus + toolbar. It owns the strip above the tabs, so nothing
	# below it needs to know which commands exist.
	top_bar = TOP_BAR_SCRIPT.new()
	top_bar.name = "TopBar"
	hud.add_child(top_bar)

	notification_center = NOTIFICATION_CENTER_SCRIPT.new()
	notification_center.name = "NotificationCenter"
	hud.add_child(notification_center)

	# The minimap goes first on purpose: Godot hands a click to the LAST
	# child in tree order, not to the topmost z_index, so a strip added last
	# would swallow the clicks of the find panel that overlaps it.
	minimap = MINIMAP_SCRIPT.new()
	minimap.name = "Minimap"
	hud.add_child(minimap)

	tabs = TABS_SCRIPT.new()
	tabs.name = "Tabs"
	hud.add_child(tabs)

	find_panel = FIND_SCRIPT.new()
	find_panel.name = "Find"
	hud.add_child(find_panel)

	# Left docks. They are added before the centered overlays so those keep
	# receiving clicks where they overlap, but after the tab strip so their
	# own header rows stay clickable.
	file_tree = FILE_TREE_SCRIPT.new()
	file_tree.name = "FileTree"
	hud.add_child(file_tree)

	search_panel = SEARCH_PANEL_SCRIPT.new()
	search_panel.name = "SearchPanel"
	hud.add_child(search_panel)

	source_control_panel = SOURCE_CONTROL_PANEL_SCRIPT.new()
	source_control_panel.name = "SourceControl"
	hud.add_child(source_control_panel)

	palette = PALETTE_SCRIPT.new()
	palette.name = "Palette"
	hud.add_child(palette)

	keybindings_panel = KEYBINDINGS_PANEL_SCRIPT.new()
	keybindings_panel.name = "Keybindings"
	hud.add_child(keybindings_panel)

	# One run path only: RunService owns capture and terminal mode, so the
	# legacy run_manager.gd is no longer instantiated alongside it.
	run_service = RUN_SERVICE_SCRIPT.new()
	run_service.name = "RunService"
	run_service.editor = self
	add_child(run_service)
	run_service.run_started.connect(_on_run_started)
	run_service.output_changed.connect(_on_run_output_changed)

	# added last so the docked terminal draws on top of the other HUD panels
	terminal = TERMINAL_SCRIPT.new()
	terminal.name = "Terminal"
	hud.add_child(terminal)

	# Run output is a second bottom dock. It hides the terminal when it opens
	# and the terminal hides it in return, so only one bottom panel owns the
	# shared strip at a time.
	output_panel = OUTPUT_PANEL_SCRIPT.new()
	output_panel.name = "RunOutput"
	hud.add_child(output_panel)

	# Language support owns the third bottom dock. Problems / Servers / Log
	# share the strip with the terminal and Run output.
	lsp_panel = LSP_PANEL_SCRIPT.new()
	lsp_panel.name = "Language"
	hud.add_child(lsp_panel)

	# Debugger shares the same bottom strip. It is created after the LSP dock
	# so it draws above it when both are briefly visible during a transition.
	debug_panel = DEBUG_PANEL_SCRIPT.new()
	debug_panel.name = "Debugger"
	hud.add_child(debug_panel)

	# Floating help cards. Added after the docks so they draw above them;
	# the picker is last because it is the only focus-taking overlay.
	lsp_signature_panel = LSP_SIGNATURE_SCRIPT.new()
	lsp_signature_panel.name = "LspSignature"
	hud.add_child(lsp_signature_panel)

	lsp_hover_panel = LSP_HOVER_SCRIPT.new()
	lsp_hover_panel.name = "LspHover"
	hud.add_child(lsp_hover_panel)

	lsp_picker = LSP_PICKER_SCRIPT.new()
	lsp_picker.name = "LspPicker"
	hud.add_child(lsp_picker)

	# The welcome screen covers the whole editor, so it goes above every dock.
	# The tutorial card stays above the code but below the welcome backdrop.
	welcome_panel = WELCOME_PANEL_SCRIPT.new()
	welcome_panel.name = "Welcome"
	hud.add_child(welcome_panel)

	coach_panel = COACH_PANEL_SCRIPT.new()
	coach_panel.name = "Coach"
	hud.add_child(coach_panel)

	# The built-in Python Journey course: dock + progress + engine wiring.
	# Created here with the coach; lessons themselves start from the welcome
	# screen, the Help menu or the command palette.
	_setup_course(hud)

	# the dock shrinks the minimap's bottom edge
	minimap.attach_terminal(terminal)
	minimap.attach_bottom_dock(output_panel)
	minimap.attach_bottom_dock(lsp_panel)
	minimap.attach_bottom_dock(debug_panel)

	# ... and the file tree's, so its last row is not hidden under the drawer
	file_tree.attach_terminal(terminal)
	file_tree.attach_bottom_dock(output_panel)
	file_tree.attach_bottom_dock(lsp_panel)
	file_tree.attach_bottom_dock(debug_panel)
	# the search dock shares the same slot, so it needs the same bottom inset
	search_panel.attach_terminal(terminal)
	search_panel.attach_bottom_dock(output_panel)
	search_panel.attach_bottom_dock(lsp_panel)
	search_panel.attach_bottom_dock(debug_panel)
	source_control_panel.attach_bottom_dock(terminal)
	source_control_panel.attach_bottom_dock(output_panel)
	source_control_panel.attach_bottom_dock(lsp_panel)
	source_control_panel.attach_bottom_dock(debug_panel)

	tabs.sync()

	# Generated HUD rows are not focusable by default, which makes whole docks
	# unreachable by keyboard. Give every interactive control a Tab stop.
	FOCUS_NAV.configure_tree(self)

	if editor_host != null:
		editor_host.view_large_file_changed.connect(_on_view_large_file_changed)
	_sync_large_file_mode()

func _setup_overlays() -> void:
	overlays.camera = camera
	overlays.background = background
	overlays.prepare([
		file_dialog,
		settings_panel,
		info_panel,
		theme_chooser_panel,
		comments_panel,
		find_panel,
		palette,
		keybindings_panel,
	])

func _setup_dialogs() -> void:
	dialog_coordinator = DIALOG_COORDINATOR_SCRIPT.new()
	var dialogs: Dictionary = dialog_coordinator.setup(self)
	save_dialog = dialogs["save_dialog"]
	folder_dialog = dialogs["folder_dialog"]
	mod_import_dialog = dialogs["mod_import_dialog"]
	template_folder_dialog = dialogs["template_folder_dialog"]
	history_dialog = dialogs["history_dialog"]
	external_dialog = dialogs["external_dialog"]
	compare_dialog = dialogs["compare_dialog"]
	compare_buffer_label = dialogs["compare_buffer_label"]
	compare_buffer_edit = dialogs["compare_buffer_edit"]
	compare_disk_label = dialogs["compare_disk_label"]
	compare_disk_edit = dialogs["compare_disk_edit"]
	git_diff_dialog = dialogs["git_diff_dialog"]
	close_tab_dialog = dialogs["close_tab_dialog"]
	close_dialog = dialogs["close_dialog"]

# ── COMMAND-ORIENTED ACTIONS ────────────────────────────────────────────────
#
# Commands call these instead of poking panels directly. Keyboard routing,
# menus, the toolbar and the palette all end up here, so every entry point
# shares one implementation.

func toggle_find() -> void:
	if find_panel == null or overlays == null:
		return
	overlays.toggle(find_panel, false, 0)


func toggle_replace() -> void:
	if find_panel == null or overlays == null:
		return
	var was_open: bool = overlays.is_open(find_panel)
	overlays.toggle(find_panel, false, 0)
	if !was_open and overlays.is_open(find_panel):
		find_panel.open_for_replace()


func toggle_palette_files() -> void:
	if palette == null or overlays == null:
		return
	var was_open: bool = overlays.is_open(palette)
	overlays.toggle(palette, false, 0)
	if !was_open and overlays.is_open(palette):
		palette.open_for_files()


func toggle_palette_commands() -> void:
	if palette == null or overlays == null:
		return
	var was_open: bool = overlays.is_open(palette)
	overlays.toggle(palette, false, 0)
	if !was_open and overlays.is_open(palette):
		refresh_commands()
		palette.open_for_commands()


func open_settings() -> void:
	if settings_panel == null or overlays == null:
		return
	overlays.toggle(settings_panel, true, (18 * 7.5) * 2)


## Opens the shortcut editor, stepping out of another overlay first. The
## OverlayController shows one panel at a time and ignores opens while a fade
## is running, so this waits for the close before opening.
func open_keybindings() -> void:
	if keybindings_panel == null or overlays == null:
		return
	if overlays.is_open(keybindings_panel):
		overlays.close(keybindings_panel)
		return

	if overlays.has_open_panel():
		overlays.close_all()
		while overlays.is_animating():
			await get_tree().process_frame
		await get_tree().create_timer(OverlayController.ANIMATION_TIME + 0.02).timeout

	while overlays.is_animating():
		await get_tree().process_frame
	overlays.open(keybindings_panel, false, 0)

# ── PHASE 9: BEGINNER LAYER ─────────────────────────────────────────────────

func open_welcome(section: String = "") -> void:
	if welcome_panel == null:
		return
	welcome_panel.open(section)


## A template card (welcome screen or the "Start from a template" command).
## The folder picker is always shown: a starter project should never land in a
## folder the person did not choose.
func create_from_template(template_id: String) -> void:
	if templates == null:
		warn("[color=yellow]TEMPLATE[/color]: Templates are unavailable.")
		return
	var entry: Dictionary = templates.get_template(template_id)
	if entry.is_empty():
		warn("[color=yellow]TEMPLATE[/color]: Unknown template \"%s\"." % template_id)
		return

	_pending_template_id = str(entry.get("id", template_id))
	if welcome != null:
		welcome.mark_welcome_seen()
	if template_folder_dialog == null:
		_create_template_in(workspace_root_for_tools())
		return

	var start := workspace_root_for_tools()
	if start.is_empty():
		start = OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	if !start.is_empty():
		template_folder_dialog.current_dir = start
	template_folder_dialog.popup_centered_ratio(0.6)


func _on_template_folder_selected(path: String) -> void:
	_create_template_in(path)


func _on_template_folder_canceled() -> void:
	_pending_template_id = ""


func _create_template_in(folder: String) -> void:
	var template_id := _pending_template_id
	_pending_template_id = ""
	if template_id.is_empty() or templates == null:
		return

	var result: Dictionary = templates.create(template_id, folder)
	if !bool(result.get("ok", false)):
		warn("[color=red]TEMPLATE[/color]: %s" % str(result.get("error", "Could not create the template.")))
		return

	var primary := str(result.get("primary", ""))
	if primary.is_empty() or !FileAccess.file_exists(primary):
		warn("[color=red]TEMPLATE[/color]: The template was created, but its main file could not be opened.")
		return

	if workspace != null and workspace.has_workspace() and workspace.is_inside_workspace(primary):
		for created_path in result.get("paths", []):
			workspace.note_created(str(created_path))
		if file_tree != null:
			file_tree.refresh_all()

	open_file(primary)
	focus_run_button()
	warn("[color=#8bd5ff]TEMPLATE[/color]: Created [b]%s[/b] in %s" % [
		str(result.get("template", {}).get("label", template_id)),
		str(result.get("folder", folder)),
	])


## Puts keyboard focus on the Run toolbar button. Beginner templates should end
## with the next action already selected instead of leaving focus in a menu.
func focus_run_button() -> void:
	if top_bar == null:
		return
	# Document changes do not rebuild the toolbar, so the Run button may still
	# be disabled from the empty editor state.
	top_bar.refresh()
	call_deferred("_focus_run_button_deferred")


func _focus_run_button_deferred() -> void:
	if top_bar == null:
		return
	var buttons: Variant = top_bar.get("toolbar_buttons")
	if !(buttons is Dictionary):
		return
	var button: Variant = (buttons as Dictionary).get("run.run")
	if button is Button and is_instance_valid(button):
		(button as Button).focus_mode = Control.FOCUS_ALL
		(button as Button).grab_focus()


# ── ONBOARDING ──────────────────────────────────────────────────────────────

func start_onboarding(replay: bool = true) -> void:
	if onboarding == null:
		return
	onboarding.start(replay)
	# Replaying with a file already on screen should not ask the person to open
	# one again; the step advances to "type a line".
	_onboarding_document_opened()
	if coach_panel != null:
		coach_panel.show_state(onboarding.snapshot())
	warn("[color=#8bd5ff]TUTORIAL[/color]: Four steps — open, type, run, see the output. Skip any time.")


func onboarding_action() -> void:
	if onboarding == null:
		return
	var state: Dictionary = onboarding.snapshot()
	var step := int(state.get("step", 0))
	match step:
		0:
			if workspace != null and workspace.has_workspace():
				_pending_template_id = "python"
				_create_template_in(workspace_root_for_tools())
			else:
				create_from_template("python")
		1:
			if editor_host != null:
				editor_host.grab_active_focus()
		2:
			prepare_run_snapshot()
			if run_service != null:
				run_service.run()
		3:
			if output_panel != null:
				output_panel.open()
			if onboarding.is_active() and run_service != null:
				onboarding.notify_output(str(run_service.last_result.get("output", "")))


func skip_onboarding() -> void:
	if onboarding == null:
		return
	onboarding.skip()
	if coach_panel != null:
		coach_panel.hide_now()
	warn("[color=#8bd5ff]TUTORIAL[/color]: Skipped. Replay it from Help > Start Tutorial.")


func _onboarding_document_opened() -> void:
	if onboarding != null and onboarding.is_active():
		onboarding.notify_document_open()


func _on_onboarding_state_changed(state: Dictionary) -> void:
	if coach_panel == null:
		return
	coach_panel.show_state(state)
	if welcome_panel != null and bool(state.get("active", false)):
		# The tutorial needs the editor, not the start screen.
		welcome_panel.visible = false


func _on_onboarding_completed() -> void:
	warn("[color=#8bd5ff]TUTORIAL COMPLETE[/color]: You made a program run and read its output. That is the whole loop: edit, run, read. Next, try the web page template from the welcome screen — or press Help > Start Tutorial to replay this any time.")


func _on_run_started(_info: Dictionary) -> void:
	_publish_mod_event("run.started", _run_event_payload(_info))
	if onboarding != null and onboarding.is_active():
		onboarding.notify_run()
	if coach_panel != null and onboarding != null:
		coach_panel.show_state(onboarding.snapshot())


func _on_run_output_changed(output: String) -> void:
	# The event bus caps payloads at 16 KiB. Send the tail so a mod can watch
	# progress without the editor duplicating a whole build log every frame.
	var tail := output.substr(maxi(0, output.length() - 6000))
	_publish_mod_event("run.output", {"output": tail, "length": output.length()})
	if onboarding != null and onboarding.is_active():
		onboarding.notify_output(output)


# ── HISTORY ─────────────────────────────────────────────────────────────────

func open_history() -> void:
	if history_dialog == null:
		return
	var document = documents.active_document() if documents != null else null
	if document == null:
		warn("[color=yellow]HISTORY[/color]: Open a file first. History belongs to saved files.")
		return
	history_dialog.open_document(document)


## Writes a snapshot back to disk and into the open tab. The current buffer is
## snapshotted first, so a restore can be undone.
func restore_history_snapshot(path: String, file_name: String) -> Dictionary:
	if history == null:
		return {"ok": false, "error": "History is unavailable.", "content": "", "snapshot": {}}

	var document = documents.find_by_path(path) if documents != null else null
	var current := str(document.text()) if document != null else (Fs._load(path) if FileAccess.file_exists(path) else "")
	_snapshot_path(path, current, "before_restore")

	var result: Dictionary = history.restore(path, file_name)
	if !bool(result.get("ok", false)):
		return result

	var content := str(result.get("content", ""))
	if document != null:
		document.set_text(content, true)
		document.disk_mtime = _mtime(path)
		if lsp_manager != null:
			lsp_manager.document_changed(document)
		_reset_git_baseline(document)
		_request_git_baseline(document)
		if tabs != null:
			tabs.sync()
	if preview_server != null:
		preview_server.notify_changed(path)
	warn("[color=#8bd5ff]HISTORY[/color]: Restored the version from %s." % str(result.get("snapshot", {}).get("time_label", "earlier")))
	return result


## Keeps the bytes currently on disk. Called before a write path replaces them.
func _snapshot_disk(path: String, reason: String) -> void:
	if history == null or path.is_empty() or !FileAccess.file_exists(path):
		return
	if !_setting_bool("history_enabled", true):
		return
	history.snapshot(path, Fs._load(path), reason)


func _snapshot_path(path: String, content: String, reason: String) -> void:
	if history == null or path.is_empty():
		return
	if !_setting_bool("history_enabled", true):
		return
	history.snapshot(path, content, reason)


func _snapshot_dirty_documents(reason: String) -> void:
	if history == null or documents == null or !_setting_bool("history_enabled", true):
		return
	for document in open_tabs:
		if document == null or document.untitled or str(document.path).is_empty():
			continue
		if !document.modified:
			continue
		_snapshot_path(str(document.path), str(document.text()), reason)


## Saves a pre-run checkpoint for every open, path-backed document. RunService
## saves dirty buffers itself, so this must happen before it starts.
func prepare_run_snapshot() -> void:
	if history == null or documents == null or !_setting_bool("history_enabled", true):
		return
	for document in open_tabs:
		if document == null or document.untitled or str(document.path).is_empty():
			continue
		_snapshot_path(str(document.path), str(document.text()), "before_run")


# ── LIVE PREVIEW ────────────────────────────────────────────────────────────

func open_preview() -> void:
	var document = documents.active_document() if documents != null else null
	if document == null or str(document.path).is_empty():
		warn("[color=yellow]PREVIEW[/color]: Open an HTML or Markdown file first.")
		return

	var path := str(document.path)
	var extension := Paths.extension(path).to_lower()
	if extension != "html" and extension != "htm" and extension != "md" and extension != "markdown":
		warn("[color=yellow]PREVIEW[/color]: Preview opens HTML and Markdown files. Use Run for code files.")
		return
	if preview_server == null:
		warn("[color=yellow]PREVIEW[/color]: The preview server is unavailable.")
		return

	var root := workspace_root_for_tools()
	if root.is_empty() or !Paths.is_subpath(root, path):
		root = path.get_base_dir()
	var target_root := Paths.normalize(root)
	if preview_server.is_running() and Paths.normalize(preview_server.root_path) != target_root:
		preview_server.stop()
	if !preview_server.is_running():
		var port := int(_setting_value("preview_port", 0))
		var started: Dictionary = preview_server.start(target_root, port, path)
		if !bool(started.get("ok", false)):
			warn("[color=red]PREVIEW[/color]: %s" % str(started.get("error", "Could not start the preview server.")))
			return
	var result: Dictionary = preview_server.open_in_browser(path)
	if !bool(result.get("ok", false)):
		warn("[color=red]PREVIEW[/color]: %s" % str(result.get("error", "Could not open the preview.")))
		return
	warn("[color=#8bd5ff]PREVIEW[/color]: %s — reloads when you save." % str(result.get("url", "")))


# ── GLOSSARY ────────────────────────────────────────────────────────────────

func _schedule_glossary(view, line: int, column: int) -> void:
	if glossary == null or glossary_timer == null or view == null or view.document == null:
		return
	if !_setting_bool("glossary_enabled", true):
		return
	if _glossary_language(view.document).is_empty():
		return
	_glossary_pending = {"view": view, "line": line, "column": column}
	glossary_timer.start()


func _on_glossary_timer_timeout() -> void:
	var pending := _glossary_pending
	_glossary_pending = {}
	if pending.is_empty() or glossary == null:
		return
	# The language server had the first chance; do not cover its card.
	if lsp_hover_panel != null and lsp_hover_panel.visible:
		return
	var view = pending.get("view")
	if view == null or !is_instance_valid(view) or view.document == null:
		return
	var language := _glossary_language(view.document)
	if language.is_empty():
		return
	var line := int(pending.get("line", 0))
	var column := int(pending.get("column", 0))
	var line_text := str(view.get_line(clampi(line, 0, maxi(0, view.get_line_count() - 1))))
	var entry: Dictionary = glossary.lookup(language, glossary.word_at(line_text, column))
	if !bool(entry.get("found", false)):
		return
	if lsp_hover_panel != null:
		lsp_hover_panel.show_message(glossary.bbcode(entry), view, line, column)


func _glossary_language(document) -> String:
	if document == null or glossary == null:
		return ""
	var language: String = glossary.language_for_path(str(document.path))
	if !language.is_empty():
		return language
	var override := str(document.language_override)
	if !override.is_empty() and glossary.has_language(override):
		return override
	var highlight := str(document.language_highlight)
	if !highlight.is_empty() and glossary.has_language(highlight):
		return highlight
	return ""


## Help > Explain This. Uses the selection when there is one, otherwise the word
## under the caret. Works even when hover is disabled.
func explain_current_word() -> void:
	if glossary == null:
		return
	var document = documents.active_document() if documents != null else null
	if document == null:
		warn("[color=yellow]EXPLAIN[/color]: Open a file first.")
		return
	var view = editor_host.active_view if editor_host != null else null
	if view == null or !is_instance_valid(view):
		return
	var language := _glossary_language(document)
	if language.is_empty():
		warn("[color=yellow]EXPLAIN[/color]: There is no plain-language glossary for this file type yet.")
		return

	var word := ""
	if view.has_selection():
		var selected := str(view.get_selected_text()).strip_edges()
		word = glossary.word_at(selected, 0) if !selected.is_empty() else ""
	if word.is_empty():
		var line: int = view.get_caret_line()
		var line_text := str(view.get_line(line))
		word = glossary.word_at(line_text, view.get_caret_column())
	var entry: Dictionary = glossary.lookup(language, word)
	if !bool(entry.get("found", false)):
		if word.is_empty():
			warn("[color=yellow]EXPLAIN[/color]: Put the caret on a word or select one.")
		else:
			warn("[color=yellow]EXPLAIN[/color]: No explanation for \"%s\" yet." % word)
		return
	if lsp_hover_panel != null:
		lsp_hover_panel.show_message(glossary.bbcode(entry), view, view.get_caret_line(), view.get_caret_column())


# ── BEGINNER MODE ───────────────────────────────────────────────────────────

func beginner_mode_enabled() -> bool:
	return beginner_mode != null and beginner_mode.is_enabled()


func set_beginner_mode(enabled: bool) -> void:
	# Persist silently; the normal settings change path would call back into
	# apply_beginner_mode() while the mode is half-applied.
	LuaSingleton.set_setting_value("beginner_mode", enabled)
	apply_beginner_mode(enabled)
	warn("[color=#8bd5ff]BEGINNER MODE[/color]: %s" % ("On — larger text, plain labels, simpler menus." if enabled else "Off — advanced tools and your previous text size are back."))


## Applies the reversible beginner presentation. Safe to call repeatedly and at
## startup: the service remembers the original font/zoom.
func apply_beginner_mode(enabled: bool, _startup: bool = false) -> void:
	if beginner_mode == null:
		return

	var font_now := int(_setting_value("editor_font_size", 16))
	var zoom_now := float(_setting_value("zoom_intensity", 1.0))
	var result: Dictionary

	if enabled:
		result = beginner_mode.enable(font_now, zoom_now)
		var target_font := int(result.get("font_size", BEGINNER_MODE_SCRIPT.MIN_FONT_SIZE))
		var target_zoom := float(result.get("zoom", BEGINNER_MODE_SCRIPT.MIN_ZOOM))
		if font_now < target_font:
			LuaSingleton.change_setting("editor_font_size", target_font)
		if zoom_now < target_zoom:
			LuaSingleton.change_setting("zoom_intensity", target_zoom)
		# Only an interactive enable declutters the docks. A startup enable
		# leaves the session layout alone: the workspace the user arranged
		# (or the session restore opened) is theirs, and closing it behind
		# their back would be a surprise, not simplification.
		if _startup:
			_beginner_closed_panels.clear()
		else:
			_hide_advanced_panels()
	else:
		result = beginner_mode.disable()
		if bool(result.get("changed", false)):
			var previous_font := int(result.get("font_size", 0))
			var previous_zoom := float(result.get("zoom", 0.0))
			if previous_font > 0:
				LuaSingleton.change_setting("editor_font_size", previous_font)
			if previous_zoom > 0.0:
				LuaSingleton.change_setting("zoom_intensity", previous_zoom)
		# Bring back the docks that enabling Beginner Mode closed, unless
		# they are open again already (the user may have reopened one).
		_restore_advanced_panels()

	if commands != null:
		commands.set_beginner_mode(enabled)
	if LuaSingleton.settings_service != null:
		LuaSingleton.settings_service.set_beginner_mode(enabled)
	if top_bar != null:
		top_bar.refresh()
	LuaSingleton.on_settings_change.emit()


func _initialize_beginner_mode() -> void:
	if beginner_mode == null:
		return
	var enabled := _setting_bool("beginner_mode", false)
	if !enabled and _is_fresh_install() and (onboarding == null or !onboarding.is_completed()):
		# A brand-new installation starts in Beginner Mode: larger text, plain
		# labels, simpler menus, and the welcome screen already offers the
		# four-step tutorial. The value is persisted so the mode survives
		# restarts; anyone who wants the full interface can turn it off from
		# Preferences > Getting Started, the Beginner Mode command, or the
		# toggle on the welcome screen.
		enabled = true
		LuaSingleton.set_setting_value("beginner_mode", true)
	apply_beginner_mode(enabled, true)


## True only when no settings.json was loaded at startup, i.e. the app has
## never saved settings on this computer. Legacy data.save imports flip
## loaded_from_file() to true, so returning users never see the change.
func _is_fresh_install() -> bool:
	var service = LuaSingleton.settings_service
	if service == null or !service.has_method("loaded_from_file"):
		return false
	return !service.loaded_from_file()


## Docks closed by an interactive Beginner Mode enable, so a disable can
## bring them back. Startup enables never touch docks, so this is always
## a record of what the user lost in that moment.
var _beginner_closed_panels: Array[String] = []


# ── PYTHON JOURNEY (built-in course) ───────────────────────────────────────

## Creates the course dock and progress service, and hooks a 0.25 s watcher
## that marks progress and completion notices from the exercise engine.
func _setup_course(hud: CanvasLayer) -> void:
	course_service = COURSE_SERVICE_SCRIPT.new()
	course_panel = COURSE_PANEL_SCRIPT.new()
	course_panel.name = "Course"
	hud.add_child(course_panel)
	course_timer = Timer.new()
	course_timer.name = "CourseWatch"
	course_timer.wait_time = 0.25
	course_timer.one_shot = false
	course_timer.timeout.connect(_course_watch)
	add_child(course_timer)
	course_service.set_locale(_course_locale_value())
	LuaSingleton.on_settings_change.connect(_on_course_locale_refresh)


## Reads the UI language setting for the course copy. "en" is the fallback
## and the default.
func _course_locale_value() -> String:
	var service = LuaSingleton.settings_service
	if service != null:
		return str(service.get_value("ui_language", "en"))
	return "en"


func _on_course_locale_refresh() -> void:
	if course_service != null and course_service.has_method("set_locale"):
		course_service.set_locale(_course_locale_value())


func _course_watch() -> void:
	if course_lesson.is_empty() or mod_exercise == null:
		return
	var ps: Dictionary = mod_exercise.public_state()
	var state := str(ps.get("state", ""))
	var phase_kind := str(ps.get("phase_kind", ""))
	if phase_kind == "freeform" and !course_typed:
		course_typed = true
		course_service.mark_typed(course_lesson)
	if state == "completed":
		course_service.mark_done(course_lesson)
		var lesson: Dictionary = course_service.lesson(course_lesson)
		var title := str(lesson.get("title", course_lesson))
		var next_id: String = course_service.next_lesson_id(course_lesson)
		if next_id.is_empty():
			warn("[color=#8bd5ff]JOURNEY[/color]: %s" % TranslationServer.translate("All five lessons complete. You are a programmer now — the rest of Qorix is yours."))
		else:
			warn("[color=#8bd5ff]JOURNEY[/color]: %s" % (TranslationServer.translate("%s done. Press Ctrl+Alt+J for the next lesson.") % title))
		_course_watch_stop()
	elif state == "stopped":
		course_lesson = ""
		course_typed = false
		_course_watch_stop()


func _course_watch_stop() -> void:
	if course_timer != null:
		course_timer.stop()


## Everything the dock needs to render itself, in one dictionary.
func course_snapshot() -> Dictionary:
	var out := {
		"lesson_id": course_lesson,
		"completed": course_service.completed_count() if course_service != null else 0,
		"total": course_service.total_lessons() if course_service != null else 0,
		"state": "idle",
		"phase_kind": "",
		"phase_label": "Type it",
		"prompt": "",
		"title": "",
		"results": [],
	}
	if mod_exercise == null or course_lesson.is_empty():
		return out
	var ps: Dictionary = mod_exercise.public_state()
	out["state"] = str(ps.get("state", "idle"))
	out["phase_kind"] = str(ps.get("phase_kind", ""))
	out["phase_label"] = "Make it yours" if out["phase_kind"] == "freeform" else "Type it"
	out["prompt"] = str(ps.get("prompt", ""))
	out["title"] = str(ps.get("title", ""))
	var validation: Variant = ps.get("validation", {})
	if validation is Dictionary:
		var result: Variant = validation.get("result", {})
		if result is Dictionary:
			out["results"] = result.get("results", [])
	return out


func _course_lesson_path(lesson_file: String) -> String:
	if workspace == null or !workspace.has_workspace():
		return ""
	var file := lesson_file.strip_edges()
	if file.is_empty():
		return ""
	return workspace.root.path_join(file)


func _course_python_available() -> bool:
	if _course_python_resolved == -1:
		var catalog = RuntimeCatalog.new()
		var found := catalog.find_executable("python")
		if found.is_empty():
			found = catalog.find_executable("python3")
		if found.is_empty():
			found = catalog.find_executable("py")
		_course_python_resolved = 1 if !found.is_empty() else 0
	return _course_python_resolved == 1


## Starts a lesson (or restarts the current one when called for the same
## lesson). Workspace + Python enable run-backed validation; anything else
## falls back to text checks and says so once.
func course_start_lesson(lesson_id: String) -> void:
	if course_service == null or mod_exercise == null:
		return
	var catalog: Dictionary = course_service.load_catalog()
	if !bool(catalog.get("ok", false)):
		warn("[color=red]JOURNEY[/color]: %s" % str(catalog.get("error", TranslationServer.translate("The course could not load."))))
		return
	var lsn: Dictionary = course_service.lesson(lesson_id)
	if lsn.is_empty():
		warn("[color=yellow]JOURNEY[/color]: %s" % (TranslationServer.translate("There is no lesson called %s.") % str(lesson_id)))
		return
	if mod_exercise.is_live() and str(mod_exercise.owner_id) != COURSE_OWNER:
		warn("[color=yellow]JOURNEY[/color]: %s" % TranslationServer.translate("A mod already owns the learning engine. Exit it first."))
		return
	if mod_exercise.is_live():
		mod_exercise.stop(COURSE_OWNER, TranslationServer.translate("Restarted the lesson."))

	var lesson_file := str(lsn.get("file", ""))
	var path := _course_lesson_path(lesson_file)
	var document = null
	if !path.is_empty():
		if !DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(path.get_base_dir())):
			DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
		if !FileAccess.file_exists(path):
			var fresh := FileAccess.open(path, FileAccess.WRITE)
			if fresh != null:
				fresh.store_string(str(lsn.get("starter", "")))
				fresh = null
		open_file(path)
		document = documents.active_document() if documents != null else null
	else:
		document = _append_untitled_tab(str(lsn.get("starter", "")), str(lsn.get("title", "Lesson")) + ".py")
	if document == null:
		warn("[color=yellow]JOURNEY[/color]: %s" % TranslationServer.translate("The lesson document could not be created."))
		return

	var use_run := !path.is_empty() and _course_python_available()
	if !path.is_empty() and !use_run:
		warn("[color=yellow]JOURNEY[/color]: %s" % TranslationServer.translate("Python isn't installed, so this lesson checks your code as text. Install Python 3 (or reopen Qorix after installing it) to run lessons for real."))

	var spec: Dictionary = course_service.build_spec(lsn, int(document.id), use_run)
	var result: Dictionary = mod_exercise.start(COURSE_OWNER, spec)
	if !result.get("ok", false):
		warn("[color=yellow]JOURNEY[/color]: %s" % (TranslationServer.translate("The lesson could not start — %s") % str(result.get("error", "unknown error"))))
		return

	course_lesson = lesson_id
	course_typed = false
	if course_timer != null:
		course_timer.start()
	if welcome_panel != null and welcome_panel.visible:
		welcome_panel.visible = false
	toggle_course_panel(true)


func toggle_course_panel(show: Variant = null) -> void:
	if course_panel == null:
		return
	var want := !course_panel.visible if show == null else bool(show)
	if want:
		course_panel.show_course()
	else:
		course_panel.hide_course()


func course_check() -> void:
	if course_lesson.is_empty() or mod_exercise == null:
		warn("[color=yellow]JOURNEY[/color]: %s" % TranslationServer.translate("No lesson is running. Open one from the welcome screen or Help > Python Journey."))
		return
	var result: Dictionary = mod_exercise.submit(COURSE_OWNER)
	if !result.get("ok", false):
		warn("[color=yellow]JOURNEY[/color]: %s" % str(result.get("error", "The check could not run.")))


func course_retry_lesson() -> void:
	if course_lesson.is_empty():
		return
	course_start_lesson(course_lesson)


func course_next_lesson() -> void:
	if course_service == null:
		return
	var next_id: String = course_service.next_lesson_id(course_lesson)
	if next_id.is_empty():
		warn("[color=#8bd5ff]JOURNEY[/color]: %s" % TranslationServer.translate("Every lesson is done. Replay any lesson from the panel."))
		return
	course_start_lesson(next_id)


func course_stop() -> void:
	if mod_exercise != null and mod_exercise.is_live() and str(mod_exercise.owner_id) == COURSE_OWNER:
		mod_exercise.stop(COURSE_OWNER, TranslationServer.translate("Left the course."))
	course_lesson = ""
	course_typed = false
	_course_watch_stop()
	toggle_course_panel(false)


func _hide_advanced_panels() -> void:
	_beginner_closed_panels.clear()
	var panels := {
		"source_control_panel": source_control_panel,
		"search_panel": search_panel,
		"lsp_panel": lsp_panel,
		"debug_panel": debug_panel,
		"terminal": terminal,
	}
	for name in panels:
		var panel = panels[name]
		if panel != null and panel.visible:
			panel.hide_now()
			_beginner_closed_panels.append(str(name))


func _restore_advanced_panels() -> void:
	for name in _beginner_closed_panels:
		var panel = get(str(name))
		if panel != null and !panel.visible and panel.has_method("toggle"):
			panel.toggle()
	_beginner_closed_panels.clear()


func quick_open_files() -> Array:
	# Quick open is answered by the in-memory workspace index. The old bounded
	# disk sweep remains only as a fallback for sessions with no workspace.
	if workspace != null and workspace.has_workspace():
		return workspace.quick_open_items("", 3000)

	var root: String = current_dir
	if root.is_empty(): root = "/"

	var out: Array = []
	var stack: Array = [["", 0]]  # [relative subpath, depth]
	var budget = 3000

	while stack.size() > 0:
		if out.size() >= budget: break

		var top: Array = stack.pop_back()
		var rel: String = top[0]
		var depth = top[1]
		var dir_path: String = root if rel == "" else root.path_join(rel)

		var d = DirAccess.open(dir_path)
		if d == null: continue

		d.list_dir_begin()
		var name = d.get_next()
		while name != "":
			if d.current_is_dir():
				if !name.begins_with(".") and !SCAN_SKIP_DIRS.has(name) and depth < 6:
					stack.append([rel.path_join(name), depth + 1])
			elif !name.begins_with(".") and out.size() < budget:
				out.append({"label": rel.path_join(name), "path": dir_path.path_join(name)})
			name = d.get_next()
		d.list_dir_end()

	# natural sort so the empty-query list is browsable
	out.sort_custom(func(a, b): return a.label.naturalnocasecmp_to(b.label) < 0)
	return out


# ── WORKSPACE / LEFT DOCKS ───────────────────────────────────────────────────

## The single answer every project-config loader asks before honouring
## <workspace>/.griddycode*. A folder nobody has trusted is restricted.
func is_workspace_trusted(root: String) -> bool:
	return trust_service != null and trust_service.is_trusted(root)


func _ensure_trust_dialog() -> ConfirmationDialog:
	if trust_dialog != null and is_instance_valid(trust_dialog):
		return trust_dialog
	if hud == null:
		return null

	trust_dialog = ConfirmationDialog.new()
	trust_dialog.name = "WorkspaceTrust"
	trust_dialog.title = "Workspace Trust"
	trust_dialog.ok_button_text = "Trust folder"
	trust_dialog.cancel_button_text = "Don't trust"
	trust_dialog.confirmed.connect(_on_workspace_trust_confirmed)
	trust_dialog.canceled.connect(_on_workspace_trust_canceled)
	hud.add_child(trust_dialog)
	return trust_dialog


## Asks once per folder per run. Restricting is the default: the folder still
## opens for editing, but project-level LSP, debug and run profiles are
## ignored until the user says otherwise.
func _maybe_prompt_workspace_trust(root: String) -> void:
	if root.is_empty() or trust_service == null or trust_service.is_trusted(root):
		return
	if _trust_prompted_root == root:
		return

	var dialog := _ensure_trust_dialog()
	if dialog == null:
		return

	_trust_prompted_root = root
	dialog.dialog_text = (
		"Do you trust the authors of the files in this folder?\n\n"
		+ root
		+ "\n\nQorix only honours .griddycode.json and .griddycode/*.json "
		+ "from a trusted folder. These are the legacy GriddyCode workspace "
		+ "files, kept for compatibility. They can name a program to start, so "
		+ "opening a cloned repository is not enough by itself.\n\n"
		+ "You can open and edit files either way; only project-level commands "
		+ "are restricted."
	)
	dialog.popup_centered()


func _on_workspace_trust_confirmed() -> void:
	var root: String = workspace.root if workspace != null else ""
	if trust_service == null:
		return
	var result: Dictionary = trust_service.trust(root)
	if !result.get("ok", false):
		warn("[color=red]TRUST[/color]: %s" % str(result.get("error", "Could not save the trusted folder.")))
		return

	# Re-read the project layers now that they are allowed.
	if lsp_manager != null and lsp_manager.has_method("reload_config"):
		lsp_manager.reload_config()
	if dap_manager != null and dap_manager.has_method("reload_config"):
		dap_manager.reload_config()
	warn("[color=#8bd5ff]TRUST[/color]: Folder trusted; project language, debug and run configs are now active.")


func _on_workspace_trust_canceled() -> void:
	warn("[color=yellow]TRUST[/color]: Folder not trusted. Project config files are ignored; built-in profiles still work.")


## Opens a folder as the workspace. Returns false (with a notice) when the
## folder is missing or is a drive root.
func set_workspace(path: String, remember: bool = true) -> bool:
	if workspace == null:
		return false

	var result: Dictionary = workspace.open_folder(path, remember)
	if !result.get("ok", false):
		warn("[color=red]WORKSPACE[/color]: %s" % str(result.get("error", "Could not open the folder.")))
		return false

	current_dir = workspace.root
	if file_tree != null:
		file_tree.open()
	refresh_commands()

	warn("Workspace: [color=#85c6ff]%s[/color]" % workspace.workspace_name())
	return true


func open_folder_dialog() -> void:
	if folder_dialog == null:
		return
	var start := workspace_root_for_tools()
	if !start.is_empty():
		folder_dialog.current_dir = start
	folder_dialog.popup_centered_ratio(0.6)


func _on_folder_selected(path: String) -> void:
	set_workspace(path)


## Root used by RunManager's $workspaceRoot, new terminal tabs and save dialogs.
func workspace_root_for_tools() -> String:
	if workspace != null and workspace.has_workspace():
		return workspace.root
	return current_dir


func _on_workspace_root_changed(root: String) -> void:
	if !root.is_empty():
		current_dir = root
		_publish_mod_event("workspace.opened", {"root": str(root), "name": str(workspace.workspace_name()) if workspace != null else ""})
		if file_dialog != null:
			file_dialog.go_to(root)
	else:
		_publish_mod_event("workspace.closed", {})
	if lsp_manager != null:
		lsp_manager.set_workspace(root)
	if dap_manager != null:
		dap_manager.set_workspace(root)
	if git_service != null:
		git_service.set_workspace(root)
	_maybe_prompt_workspace_trust(root)


func _on_workspace_index_finished(files: int, truncated: bool) -> void:
	if truncated:
		warn("[color=yellow]WORKSPACE[/color]: index capped at %d files; quick open and search only cover the indexed part." % files)


func toggle_file_tree() -> void:
	if file_tree != null:
		file_tree.toggle()


func toggle_global_search() -> void:
	if search_panel != null:
		search_panel.toggle()


## The two left docks share one slot; the caller wins.
func open_left_dock(panel) -> void:
	if file_tree != null and file_tree != panel and file_tree.visible:
		file_tree.hide_now()
	if search_panel != null and search_panel != panel and search_panel.visible:
		search_panel.hide_now()
	if source_control_panel != null and source_control_panel != panel and source_control_panel.visible:
		source_control_panel.hide_now()


## The bottom strip is shared by the terminal and the Run output drawer. Both
## can exist at once (a captured run + a terminal tab), but only one is visible.
func bottom_dock_top() -> float:
	var top := 0.0
	if terminal != null and terminal.visible:
		top = minf(top, terminal.offset_top)
	if output_panel != null and output_panel.visible:
		top = minf(top, output_panel.offset_top)
	if lsp_panel != null and lsp_panel.visible:
		top = minf(top, lsp_panel.offset_top)
	if debug_panel != null and debug_panel.visible:
		top = minf(top, debug_panel.offset_top)
	return top


func has_bottom_dock() -> bool:
	return (terminal != null and terminal.visible) \
		or (output_panel != null and output_panel.visible) \
		or (lsp_panel != null and lsp_panel.visible) \
		or (debug_panel != null and debug_panel.visible)


func toggle_lsp_panel(tab: int = 0) -> void:
	if lsp_panel == null:
		return
	if lsp_panel.visible:
		lsp_panel.close()
	else:
		lsp_panel.open(tab)


func open_lsp_panel(tab: int = 0) -> void:
	if lsp_panel != null:
		lsp_panel.open(tab)


func close_lsp_panel() -> void:
	if lsp_panel != null:
		lsp_panel.close()


func lsp_servers_available() -> bool:
	return lsp_manager != null


func toggle_run_panel() -> void:
	if output_panel != null:
		output_panel.toggle()


func open_run_panel() -> void:
	if output_panel != null:
		output_panel.open()


func close_run_panel() -> void:
	if output_panel != null:
		output_panel.close()


## Keeps the camera's usable width in sync with whichever dock is open.
func update_left_inset() -> void:
	if camera == null:
		return
	var is_open := (file_tree != null and file_tree.visible) \
		or (search_panel != null and search_panel.visible) \
		or (source_control_panel != null and source_control_panel.visible)
	camera.left_inset = LEFT_DOCK_WIDTH if is_open else 0.0
	if canvas_layer != null:
		# Notices would otherwise sit underneath the dock and lose their first
		# few words; slide them into the remaining code area while it is open.
		# CanvasLayer.offset is ignored by the engine (only transform applies),
		# so move the layer itself.
		canvas_layer.transform = Transform2D(
			Vector2.RIGHT,
			Vector2.DOWN,
			Vector2(_notice_base_offset.x + (LEFT_DOCK_WIDTH if is_open else 0.0), _notice_base_offset.y)
		)


# ── DEBUGGER ────────────────────────────────────────────────────────────────

## Saves every modified buffer that already has a path. A debug adapter runs
## files from disk, so the program it starts must match the code on screen.
func save_all_for_debug() -> Dictionary:
	for document in open_tabs:
		if document == null or !document.modified:
			continue
		if document.untitled or str(document.path).is_empty():
			continue
		if !_save_document(document):
			return {"ok": false, "error": "Could not save \"" + document.title() + "\"."}
	return {"ok": true, "error": ""}


func toggle_debug_panel(tab: int = -1) -> void:
	if debug_panel == null:
		return
	if debug_panel.visible:
		debug_panel.close()
	else:
		debug_panel.open(tab)


func open_debug_panel(tab: int = -1) -> void:
	if debug_panel != null:
		debug_panel.open(tab)


func close_debug_panel() -> void:
	if debug_panel != null:
		debug_panel.close()


## Opens the dock and puts the caret in the evaluate prompt. The manager only
## accepts evaluations while paused, so the command is disabled otherwise.
func focus_debug_console() -> void:
	open_debug_panel()
	if debug_panel != null:
		debug_panel.focus_console()


func debug_start_or_continue() -> void:
	if dap_manager == null:
		return
	if dap_manager.is_stopped():
		dap_manager.continue_execution()
		return
	if dap_manager.is_active():
		warn("[color=yellow]DEBUG[/color]: A debug session is already running.")
		return
	var result: Dictionary = dap_manager.start_debugging()
	if bool(result.get("ok", false)):
		open_debug_panel()
	else:
		# _start_failed already reported the reason; opening the dock shows the
		# console and, when relevant, the adapter install card.
		open_debug_panel()


func debug_stop() -> void:
	if dap_manager != null:
		dap_manager.stop_debugging()


func debug_step_over() -> void:
	if dap_manager != null:
		dap_manager.step_over()


func debug_step_into() -> void:
	if dap_manager != null:
		dap_manager.step_into()


func debug_step_out() -> void:
	if dap_manager != null:
		dap_manager.step_out()


## F9. The target is whichever line the caret is on in the active tab.
func toggle_breakpoint_at_cursor() -> void:
	if dap_manager == null:
		return
	var document = documents.active_document()
	if document == null or document.view == null:
		warn("[color=yellow]DEBUG[/color]: Open a file first.")
		return
	if document.untitled or str(document.path).is_empty():
		warn("[color=yellow]DEBUG[/color]: Save this buffer before adding a breakpoint.")
		return
	var line: int = document.view.get_caret_line()
	var added: bool = dap_manager.toggle_breakpoint(str(document.path), line)
	_sync_debug_gutter(document)
	if added:
		warn("[color=#8bd5ff]DEBUG[/color]: Breakpoint at line %d." % (line + 1))
	else:
		warn("[color=#8bd5ff]DEBUG[/color]: Breakpoint removed from line %d." % (line + 1))


func clear_all_breakpoints() -> void:
	if dap_manager == null:
		return
	dap_manager.clear_breakpoints()
	_sync_all_debug_gutters()


func _on_view_debug_gutter_clicked(view, line: int) -> void:
	if view == null or view.document == null or dap_manager == null:
		return
	var document = view.document
	if document.untitled or str(document.path).is_empty():
		warn("[color=yellow]DEBUG[/color]: Save this buffer before adding a breakpoint.")
		return
	dap_manager.toggle_breakpoint(str(document.path), line)
	_sync_debug_gutter(document)


func _on_debug_breakpoints_changed() -> void:
	_sync_all_debug_gutters()


## Reapplies breakpoint dots (and the paused-line marker) to one open view.
func _sync_debug_gutter(document) -> void:
	if document == null or document.view == null or !is_instance_valid(document.view):
		return
	var view = document.view
	if dap_manager == null or document.untitled or str(document.path).is_empty():
		view.clear_debug_marks()
		return
	view.set_breakpoint_lines(dap_manager.breakpoint_lines(str(document.path)))
	if !_debug_execution_path.is_empty() and Paths.same_file(str(document.path), _debug_execution_path):
		view.set_execution_line(_debug_execution_line)
	else:
		view.set_execution_line(-1)


func _sync_all_debug_gutters() -> void:
	for document in open_tabs:
		_sync_debug_gutter(document)


func _on_debug_session_started(_info: Dictionary) -> void:
	_debug_execution_path = ""
	_debug_execution_line = -1


func _on_debug_session_ended(_info: Dictionary) -> void:
	_debug_execution_path = ""
	_debug_execution_line = -1
	for document in open_tabs:
		if document.view != null and is_instance_valid(document.view):
			document.view.set_execution_line(-1)


func _on_debug_execution_line_changed(path: String, line: int) -> void:
	_debug_execution_path = str(path)
	_debug_execution_line = line
	for document in open_tabs:
		if document == null or document.view == null or !is_instance_valid(document.view):
			continue
		if Paths.same_file(str(document.path), _debug_execution_path):
			document.view.set_execution_line(line)
		else:
			document.view.set_execution_line(-1)


## A paused frame may live in a file that is not open yet. Opening it here
## keeps the manager free of tab/bookkeeping rules.
func _on_debug_navigate_requested(path: String, line: int, column: int) -> void:
	if path.is_empty():
		return
	var was_open := documents.find_by_path(path) != null
	open_search_result(path, line, column)
	if !was_open:
		var document = documents.find_by_path(path)
		_sync_debug_gutter(document)
		if document != null and document.view != null and is_instance_valid(document.view):
			if Paths.same_file(str(document.path), _debug_execution_path):
				document.view.set_execution_line(_debug_execution_line)


# ── SOURCE CONTROL (GIT) ────────────────────────────────────────────────────

func toggle_source_control() -> void:
	if source_control_panel != null:
		source_control_panel.toggle()


func open_source_control(tab: int = -1) -> void:
	if source_control_panel != null:
		source_control_panel.open(tab)


## The beginner path. Every open, modified buffer is written to disk first:
## staging reads files, not editor memory, so a save point must not silently
## leave the user's unsaved edits out of the commit.
func create_save_point() -> void:
	if git_service == null or !git_service.has_repo():
		warn("[color=yellow]SAVE POINT[/color]: Open a folder with a Git repository first.")
		open_source_control(0)
		return
	if git_service.is_busy():
		warn("[color=yellow]SAVE POINT[/color]: Git is still running another command. Try again in a moment.")
		return

	for document in open_tabs:
		if !document.modified:
			continue
		if document.untitled or str(document.path).is_empty():
			warn("[color=yellow]SAVE POINT[/color]: Save this untitled tab first; it has no file to commit.")
			return
		if !_save_document(document):
			warn("[color=red]SAVE POINT[/color]: Could not save \"%s\"." % document.title())
			return

	git_service.save_point()


func git_pull() -> void:
	if git_service == null or !git_service.has_repo():
		warn("[color=yellow]GIT[/color]: Open a folder with a Git repository first.")
		return
	git_service.pull()


func git_push() -> void:
	if git_service == null or !git_service.has_repo():
		warn("[color=yellow]GIT[/color]: Open a folder with a Git repository first.")
		return
	git_service.push()


## With no message this opens the commit box, which is what the command palette
## and the Git menu use. A message runs immediately.
func git_commit(message: String = "") -> void:
	if git_service == null or !git_service.has_repo():
		warn("[color=yellow]GIT[/color]: Open a folder with a Git repository first.")
		return
	var text := message.strip_edges()
	if text.is_empty():
		open_source_control(0)
		if source_control_panel != null and source_control_panel.has_method("focus_commit"):
			source_control_panel.focus_commit()
		return
	git_service.commit(text)


func show_git_diff_for(path: String) -> void:
	if git_diff_dialog == null or path.is_empty():
		return

	var document = documents.find_by_path(path) if documents != null else null
	if document != null and str(document.path).is_empty():
		git_diff_dialog.show_message("Untitled buffers have no Git history.")
		git_diff_dialog.popup_centered_ratio(0.8)
		return

	if document != null:
		if !document.git_baseline_known and !document.git_baseline_pending:
			_request_git_baseline(document)
		git_diff_dialog.open_document(document)
		return

	if git_service == null or !git_service.has_repo():
		git_diff_dialog.show_message("This file is not inside a Git repository.")
		git_diff_dialog.popup_centered_ratio(0.8)
		return

	# `git diff` has no HEAD copy to compare an untracked file against, so the
	# dialog would otherwise claim "no changes". Say what is actually true.
	if bool(_git_entry_for_path(path).get("untracked", false)):
		git_diff_dialog.show_message("This file is new and not tracked yet.\n\nStage it to see its diff.")
		git_diff_dialog.popup_centered_ratio(0.8)
		return

	git_diff_dialog.show_loading("Reading changes from Git…", path)
	git_diff_dialog.popup_centered_ratio(0.8)
	git_service.request_diff(path)


func _git_entry_for_path(path: String) -> Dictionary:
	if git_service == null or !git_service.has_repo():
		return {}
	var rel: String = git_service.relative_to(git_service.repo_root, path)
	if rel.is_empty():
		return {}
	for entry in git_service.last_snapshot.get("files", []):
		if entry is Dictionary and str(entry.get("path", "")) == rel:
			return entry
	return {}


func apply_git_setting(property: String, value: Variant) -> void:
	if property == "git_auto_refresh":
		_sync_git_auto_refresh()


func _sync_git_workspace() -> void:
	if git_service == null:
		return
	git_service.set_workspace(workspace_root_for_tools())


## Open files outside a workspace still belong to a repository when they sit
## inside one. Only replace the service's folder when there is nothing useful
## to scan: repeated set_workspace() calls are cheap because the repo root is
## compared before any command runs.
func _sync_git_for_file(path: String) -> void:
	if git_service == null or path.is_empty():
		return
	if workspace != null and workspace.has_workspace():
		return
	var folder := path.get_base_dir()
	if folder.is_empty():
		return
	if git_service.has_repo() and !git_service.relative_to(git_service.repo_root, path).is_empty():
		return
	git_service.set_workspace(folder)


func _sync_git_auto_refresh() -> void:
	if git_refresh_timer == null:
		return
	if _setting_bool("git_auto_refresh", true):
		if git_refresh_timer.is_stopped():
			git_refresh_timer.start()
	else:
		git_refresh_timer.stop()


func _on_git_refresh_timer_timeout() -> void:
	if git_service == null or !git_service.has_repo() or git_service.is_busy():
		return
	if source_control_panel == null or !source_control_panel.visible:
		return
	git_service.refresh()


func _on_git_repo_changed(_root: String) -> void:
	for document in open_tabs:
		_reset_git_baseline(document)
	if git_service != null and git_service.has_repo():
		_request_all_git_baselines()
	else:
		_clear_all_git_gutters()


func _on_git_snapshot_changed(_snapshot: Dictionary) -> void:
	if git_service == null or !git_service.has_repo():
		return
	# The first snapshot after a workspace switch is what makes baselines
	# requestable; requests made before it are intentionally not queued.
	_request_all_git_baselines()


func _on_git_head_changed() -> void:
	for document in open_tabs:
		_reset_git_baseline(document)
	_request_all_git_baselines()


func _on_git_baseline_ready(path: String, result: Dictionary) -> void:
	var document = documents.find_by_path(path) if documents != null else null
	if document != null:
		document.git_baseline_pending = false
		document.git_baseline_known = bool(result.get("ok", false)) and bool(result.get("known", false))
		document.git_baseline_text = str(result.get("text", "")) if document.git_baseline_known else ""
		document.git_baseline_tracked = bool(result.get("tracked", false))
		_update_git_gutter(document)

	if git_diff_dialog != null and git_diff_dialog.visible:
		git_diff_dialog.baseline_arrived(path, result)


func _on_git_diff_ready(path: String, result: Dictionary) -> void:
	if git_diff_dialog != null and git_diff_dialog.visible:
		git_diff_dialog.diff_arrived(path, result)


func _on_git_operation_finished(action: String, result: Dictionary) -> void:
	var ok := bool(result.get("ok", false))
	var message := str(result.get("message", ""))
	if message.is_empty():
		message = "Done." if ok else "Git command failed."

	if action == "save_point":
		var color := "#8bd5ff" if ok else "red"
		warn("[color=%s]SAVE POINT[/color]: %s" % [color, message])
		return

	if action == "pull" or action == "push" or action == "switch_branch" or action == "init":
		if source_control_panel == null or !source_control_panel.visible:
			var color := "#8bd5ff" if ok else "yellow"
			var label := action.replace("_", " ").to_upper()
			warn("[color=%s]GIT — %s[/color]: %s" % [color, label, message])


func _on_view_git_gutter_clicked(view, _line: int) -> void:
	if view == null or view.document == null:
		return
	show_git_diff_for(str(view.document.path))


func _activate_git_document(document) -> void:
	if document == null or document.untitled or str(document.path).is_empty():
		return
	if git_service == null or !git_service.has_repo():
		return
	if document.git_baseline_known:
		_update_git_gutter(document)
	else:
		_request_git_baseline(document)


func _request_git_baseline(document) -> void:
	if document == null or git_service == null or !git_service.has_repo():
		return
	if document.untitled or str(document.path).is_empty():
		return
	if document.git_baseline_pending or document.git_baseline_known:
		return
	document.git_baseline_pending = true
	git_service.request_baseline(str(document.path))


func _request_all_git_baselines() -> void:
	if git_service == null or !git_service.has_repo():
		return
	for document in open_tabs:
		_request_git_baseline(document)


func _reset_git_baseline(document) -> void:
	if document == null:
		return
	document.git_baseline_text = ""
	document.git_baseline_known = false
	document.git_baseline_tracked = false
	document.git_baseline_pending = false
	if document.view != null and is_instance_valid(document.view):
		document.view.clear_git_marks()


func _schedule_git_gutter(document) -> void:
	if document == null:
		return
	if git_service == null or !git_service.has_repo():
		if document.view != null and is_instance_valid(document.view):
			document.view.clear_git_marks()
		return
	if !_setting_bool("git_gutter", true):
		if document.view != null and is_instance_valid(document.view):
			document.view.clear_git_marks()
		return
	_pending_git_gutter_document = document
	if git_gutter_timer != null:
		git_gutter_timer.start()


func _on_git_gutter_timer_timeout() -> void:
	var document = _pending_git_gutter_document
	_pending_git_gutter_document = null
	if document == null:
		return
	_update_git_gutter(document)


func _update_git_gutter(document) -> void:
	if document == null:
		return
	var view = document.view
	if view == null or !is_instance_valid(view):
		return

	if !_setting_bool("git_gutter", true):
		view.clear_git_marks()
		return
	if !document.git_baseline_known:
		view.clear_git_marks()
		return

	var text: String = document.text()
	# A gutter is a glance, not an audit. Skip enormous or binary-looking
	# buffers; the side-by-side diff dialog still works on demand.
	if text.length() > 2 * 1024 * 1024 or document.git_baseline_text.length() > 2 * 1024 * 1024:
		view.clear_git_marks()
		return

	var result := GIT_DIFF.line_diff(document.git_baseline_text, text)
	var marks: Dictionary = {}
	var raw_marks: Dictionary = result.get("marks", {})
	for line in raw_marks:
		if typeof(line) != TYPE_INT:
			continue
		var kind := str(raw_marks[line])
		if kind != "added" and kind != "modified" and kind != "deleted":
			continue
		marks[int(line)] = kind
	view.set_git_marks(marks)


func _clear_all_git_gutters() -> void:
	for document in open_tabs:
		if document.view != null and is_instance_valid(document.view):
			document.view.clear_git_marks()


## Jump from a global-search result to the exact line/column. Reuses an already
## open tab when possible, so the caret moves in that tab's own view.
func open_search_result(path: String, line: int, column: int) -> void:
	if path.is_empty():
		return

	open_file(path)
	var document = documents.active_document()
	if document == null or !Paths.same_file(str(document.path), path):
		return

	document.caret_line = maxi(line, 0)
	document.caret_column = maxi(column, 0)
	document.has_selection_state = false
	document.restore_state()
	editor_host.grab_active_focus()


## Replace All writes to disk through SearchService. Open views are refreshed
## from the new bytes, except buffers with unsaved edits: those are left alone
## and reported instead of silently losing the user's work.
func reload_documents_after_replace(paths: Array) -> void:
	var kept := 0
	for path in paths:
		var document = documents.find_by_path(str(path))
		if document == null:
			continue
		if document.modified:
			kept += 1
			continue
		document.set_text(Fs._load(str(path)), true)
		document.disk_mtime = _mtime(str(path))
		if lsp_manager != null:
			lsp_manager.document_changed(document)
		_schedule_git_gutter(document)

	if tabs != null:
		tabs.sync()
	if kept > 0:
		warn("[color=yellow]REPLACE[/color]: kept your unsaved buffer in %d open document(s)." % kept)


## Keeps open tabs pointing at the right file after a rename/move in the tree.
func note_path_renamed(old_path: String, new_path: String) -> void:
	if old_path.is_empty() or new_path.is_empty():
		return

	var old_norm := Paths.normalize(old_path)
	var new_norm := Paths.normalize(new_path)

	for document in open_tabs:
		var path := str(document.path)
		if path.is_empty():
			continue

		var updated := ""
		if Paths.same_file(path, old_norm):
			updated = new_norm
		elif Paths.is_subpath(old_norm, path):
			updated = new_norm.path_join(Paths.normalize(path).substr(old_norm.length() + 1))
		else:
			continue

		document.path = updated
		document.display_name = updated.get_file()
		document.disk_mtime = _mtime(updated)
		if document.view != null and is_instance_valid(document.view):
			document.view.set_language_extension(document.language_extension())
		_reset_git_baseline(document)
		_request_git_baseline(document)

	if tabs != null:
		tabs.sync()
	var active = documents.active_document()
	if active != null:
		current_file = str(active.path)
	if lsp_manager != null:
		lsp_manager.sync_open_documents()
		if active != null:
			lsp_manager.active_document_changed(active)


## A file/folder was deleted outside the editor (or from the tree). Unmodified
## tabs close; modified buffers survive as untitled documents so nothing is lost.
func note_path_deleted(path: String) -> void:
	if path.is_empty():
		return

	var doomed: Array = []
	for document in open_tabs:
		var document_path := str(document.path)
		if document_path.is_empty():
			continue
		if !Paths.same_file(document_path, path) and !Paths.is_subpath(path, document_path):
			continue

		if document.modified:
			var old_title: String = str(document.title())
			document.path = ""
			document.untitled = true
			document.display_name = old_title + " (deleted)"
			document.disk_mtime = 0
			document.mark_dirty()
			_reset_git_baseline(document)
		else:
			doomed.append(document)

	for document in doomed:
		var index: int = int(documents.index_of(document))
		if index != -1:
			documents.remove_document(index)

	if lsp_manager != null:
		lsp_manager.sync_open_documents()
	if tabs != null:
		tabs.sync()


## Called after any disk write the editor makes: keeps the index metadata fresh
## and repaints the tree when a file did not exist in it before.
func _note_file_changed(path: String) -> void:
	if workspace == null or !workspace.has_workspace():
		return

	var known: bool = workspace.file_for_path(path) != null
	workspace.note_changed(path)
	if !known and file_tree != null:
		file_tree.refresh_all()

func list_themes() -> Array:
	var themes_folder = DirAccess.open("user://themes")
	if themes_folder == null:
		DirAccess.make_dir_absolute("user://themes")
		themes_folder = DirAccess.open("user://themes")
	if themes_folder == null:
		return []

	var curated = [];

	for theme_file in themes_folder.get_files():
		if !theme_file.ends_with(".lua"):
			continue
		curated.append(theme_file.trim_suffix(".lua"))

	curated.sort()

	return curated;

func _notification(what):
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_on_close_requested()
	if what == MainLoop.NOTIFICATION_APPLICATION_FOCUS_OUT:
		# you usually defocus when you want to run the code, so saving is
		# needed — but only when there is something new to write.
		var document = documents.active_document()
		if document == null: return
		if !document.modified: return
		if document.untitled: return

		# Never autosave over a version that changed while we were focused:
		# the external prompt gets the decision instead.
		if _setting_bool("external_change_check", true) and _has_external_change(document):
			call_deferred("_check_external_changes")
			return

		_save_document(document)
	if what == MainLoop.NOTIFICATION_APPLICATION_FOCUS_IN:
		# give the window a moment to settle before touching dialogs
		call_deferred("_check_external_changes")

func _on_close_requested() -> void:
	if _quitting: return
	if close_dialog != null and close_dialog.visible: return

	# An external-change prompt is a decision the user still owes us; saving
	# now could silently overwrite the disk version. Bring it forward instead.
	if external_dialog != null and external_dialog.visible:
		external_dialog.popup_centered()
		return

	# Snapshot before saving documents, so a crash during the quit prompt can
	# still recover every tab and unsaved buffer.
	_save_session(false)
	# History gets the pre-close buffer as well: quitting is a save path.
	_snapshot_dirty_documents("before_close")

	var failures: Array[String] = []
	var unsaved: Array[String] = []

	# preserve every open tab, not just the one on screen
	for document in open_tabs:
		if !document.modified: continue

		if document.untitled:
			unsaved.append(document.title())
			continue

		var result: Dictionary = Fs.save(str(document.path), document.text())
		if result.get("ok", false):
			document.disk_mtime = _mtime(str(document.path))
		else:
			failures.append("%s — %s" % [str(document.path), str(result.get("error", "Unknown error."))])

	if !unsaved.is_empty() or !failures.is_empty():
		var lines: Array[String] = []
		if !unsaved.is_empty():
			lines.append("These untitled documents have not been saved:\n  " + "\n  ".join(unsaved))
		if !failures.is_empty():
			lines.append("These files could not be saved:\n  " + "\n  ".join(failures))
		lines.append("Quit anyway and lose the unsaved changes?")

		close_dialog.dialog_text = "\n\n".join(lines)
		close_dialog.popup_centered()
		return

	_finish_quit()

func _finish_quit() -> void:
	if _quitting: return
	_quitting = true

	# Deactivate mods while the engine still has a frame: this runs deactivate(),
	# unregisters commands and marks the session clean for the crash-loop guard.
	if mods != null:
		mods.stop()

	if session_timer != null:
		session_timer.stop()
	if external_timer != null:
		external_timer.stop()
	if history_timer != null:
		history_timer.stop()
	if glossary_timer != null:
		glossary_timer.stop()
	if preview_server != null:
		preview_server.stop()

	# Snapshot while the views and terminal sessions still exist. `true`
	# releases session.lock, so the next launch is treated as a clean exit.
	_save_session(true)

	save_data({
		"current_file": current_file,
		"current_dir": current_dir,
		"theme": LuaSingleton.theme,
	})
	var settings_result: Dictionary = LuaSingleton.save_settings()
	if !settings_result.get("ok", false):
		push_warning("Could not save settings: " + str(settings_result.get("error", "")))

	# don't leave an orphaned shell behind
	if terminal:
		terminal.shutdown()
	if run_service != null:
		run_service.shutdown()
	if lsp_manager != null:
		lsp_manager.shutdown()
	if dap_manager != null:
		dap_manager.shutdown()

	get_tree().quit()

func _check_external_changes() -> void:
	if _quitting: return
	if external_dialog == null or external_dialog.visible: return
	if _external_document != null: return
	if !_setting_bool("external_change_check", true): return

	for document in open_tabs:
		if !_has_external_change(document): continue

		var path := str(document.path)
		var current := _mtime(path)

		_external_document = document
		_external_mtime = current

		var reason := "was deleted on disk" if current == 0 else "changed on disk"
		external_dialog.dialog_text = "\"%s\" %s after you opened it.\n\nReload the disk version, or keep the buffer in the editor?" % [document.title(), reason]
		external_dialog.popup_centered()
		return

## True when the file behind `document` has a different mtime than the one the
## editor last saw. Untitled buffers and vanished zero-mtime files are ignored.
func _has_external_change(document) -> bool:
	if document == null or document.untitled: return false

	var path := str(document.path)
	if path.is_empty(): return false

	var previous := int(document.disk_mtime)
	var current := _mtime(path)
	if current == previous: return false
	if previous == 0 and current == 0: return false
	return true

func _reload_external_tab() -> void:
	var document = _external_document
	_external_document = null
	if compare_dialog != null and compare_dialog.visible:
		compare_dialog.hide()
	if document == null or !is_instance_valid(document): return

	var path := str(document.path)
	var content := "" if !FileAccess.file_exists(path) else Fs._load(path)

	document.set_text(content, true)
	document.disk_mtime = _mtime(path)
	if lsp_manager != null:
		lsp_manager.document_changed(document)

	# The index and tree show the disk revision the buffer now matches.
	if workspace != null and !path.is_empty():
		workspace.note_changed(path)
	if file_tree != null:
		file_tree.refresh_all()
	_schedule_git_gutter(document)
	if tabs != null:
		tabs.sync()
	warn("Reloaded \"%s\" from disk." % document.title())

func _keep_external_tab() -> void:
	var document = _external_document
	_external_document = null
	if compare_dialog != null and compare_dialog.visible:
		compare_dialog.hide()
	if document == null: return

	# Acknowledge the disk revision: the next save is expected to overwrite it.
	document.disk_mtime = _external_mtime

	# Mark the buffer dirty even if the user had not typed since opening: the
	# disk copy is now different, so closing without saving would silently
	# throw away the version they chose to keep.
	document.mark_dirty()

	var path := str(document.path)
	if workspace != null and !path.is_empty():
		workspace.note_changed(path)
	if file_tree != null:
		file_tree.refresh_all()
	if tabs != null:
		tabs.sync()

func _on_external_custom_action(action: StringName) -> void:
	if action == &"compare":
		_show_external_compare()

## Side-by-side buffer/disk diff for the still-open prompt. Read-only on both
## sides: choosing Reload or Keep mine remains the way to resolve the change.
func _show_external_compare() -> void:
	var document = _external_document
	if document == null or !is_instance_valid(document): return

	var path := str(document.path)
	compare_buffer_label.text = "Editor buffer — " + document.title()
	compare_disk_label.text = "On disk — " + path
	compare_buffer_edit.text = document.text()
	compare_disk_edit.text = "" if !FileAccess.file_exists(path) else Fs._load(path)
	dialog_coordinator.style_compare_edit(compare_buffer_edit, document.language_extension())
	dialog_coordinator.style_compare_edit(compare_disk_edit, document.language_extension())
	compare_dialog.popup_centered_ratio(0.8)

func save_data(dict: Dictionary):
	var result: Dictionary = Fs.save("user://data.save", JSON.stringify(dict))
	if !result.get("ok", false):
		push_warning("Could not save session data: " + str(result.get("error", "")))

func load_game(cli: bool = false):
	if not FileAccess.file_exists("user://data.save"):
		# No legacy session: still apply settings.json (or the defaults).
		LuaSingleton.apply_all_settings()
		return # Error! We don't have a save to load.

	var save_game = FileAccess.open("user://data.save", FileAccess.READ)
	while save_game.get_position() < save_game.get_length():
		var json_string = save_game.get_line()

		var json = JSON.new()

		var parse_result = json.parse(json_string)
		if not parse_result == OK:
			print("JSON Parse Error: ", json.get_error_message(), " in ", json_string, " at line ", json.get_error_line())
			continue

		var node_data = json.get_data()

		if !(node_data is Dictionary):
			print("WARNING: Ignoring malformed save data.")
			continue

		if !cli:
			if node_data.has("current_dir"):
				var saved_dir := str(node_data.get("current_dir", ""))
				if !saved_dir.is_empty() and DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(saved_dir)):
					current_dir = saved_dir
			if node_data.has("current_file"):
				var saved_file := str(node_data.get("current_file", ""))
				# Older buggy launches stored engine flags (for example
				# ".../--scene") here. Never try to reopen those as documents.
				current_file = saved_file if !saved_file.is_empty() and FileAccess.file_exists(saved_file) else ""

		var saved_theme := str(node_data.get("theme", ""))
		if !saved_theme.is_empty():
			LuaSingleton.theme = saved_theme

		# One-time legacy import: old builds stored settings inside data.save.
		# SettingsService ignores this once settings.json exists, so it can
		# never overwrite newer values on a later launch.
		LuaSingleton.apply_legacy_settings(node_data.get("settings", []))

	# Apply settings only after the legacy import has had a chance to run.
	LuaSingleton.apply_all_settings()

func _on_auto_save_timer_timeout():
	var document = documents.active_document()
	if document == null:
		_check_external_changes()
		return
	if !document.modified:
		_check_external_changes()
		return
	if document.untitled:
		_check_external_changes()
		return

	# Never let the periodic autosave overwrite a disk version that changed
	# after the buffer was loaded: give the prompt the decision instead.
	if _setting_bool("external_change_check", true) and _has_external_change(document):
		_check_external_changes()
		return

	_save_document(document)
	_check_external_changes()

func _on_documents_changed() -> void:
	if tabs != null:
		tabs.sync()

func _on_document_dirty_changed(_document) -> void:
	if _document != null:
		var dirty_payload := _document_event_payload(_document)
		dirty_payload["dirty"] = bool(_document.modified)
		_publish_mod_event("document.dirty_changed", dirty_payload)
	if tabs != null:
		tabs.sync()

func _on_active_document_changed(document) -> void:
	if document != null:
		_publish_mod_event("document.activated", _document_event_payload(document))
	if welcome_panel != null and document != null and welcome_panel.visible:
		welcome_panel.visible = false
	if lsp_manager != null:
		lsp_manager.active_document_changed(document)
	if document == null:
		current_file = ""
		if tabs != null:
			tabs.sync()
		LuaSingleton.setup_discord_sdk("Idle", "")
		_sync_large_file_mode()
		return

	current_file = document.path
	_maybe_auto_detect(document, !_restoring_session)
	LuaSingleton.setup_extension(document.language_extension())
	LuaSingleton.setup_discord_sdk("Editing " + document.title(), "In " + current_dir.split("/")[-1])
	_activate_git_document(document)

	if tabs != null:
		tabs.sync()
	_sync_large_file_mode()


## Re-labels the generated chrome after a language switch. Commands and
## settings translate themselves in their presentation helpers; the menus and
## tabs only need rebuilding.
func refresh_localized_ui() -> void:
	if top_bar != null:
		top_bar.refresh()
	if tabs != null:
		tabs.sync()
	LuaSingleton.on_settings_change.emit()


## Re-evaluates every open view against the current large-file threshold.
func apply_large_file_settings() -> void:
	if editor_host == null:
		return
	for view in editor_host.views:
		if is_instance_valid(view):
			view.apply_settings()
			if view.has_method("refresh_large_file_mode"):
				view.refresh_large_file_mode()
	_sync_large_file_mode()


func apply_background_indexing(enabled: bool) -> void:
	# Headless acceptance/LSP runs stay deterministic even when the setting is
	# on; the worker threads themselves are still covered by their own suite.
	var use_threads := enabled and DisplayServer.get_name() != "headless"
	if workspace != null:
		workspace.threaded_indexing = use_threads
	if search_service != null:
		search_service.threaded = use_threads


func _on_view_large_file_changed(view, _is_large: bool) -> void:
	if view == active_view:
		_sync_large_file_mode()


## Large-file mode hides the minimap for that file, not globally: leaving the
## big tab restores whatever the Minimap setting was.
func _sync_large_file_mode() -> void:
	if minimap == null:
		return

	var is_large := active_view != null and bool(active_view.get("large_file"))
	minimap.set_suppressed(is_large)

	if !is_large or current_file.is_empty() or _large_file_warned.has(current_file):
		return
	_large_file_warned[current_file] = true
	warn("[color=#8bd5ff]LARGE FILE[/color]: " + TranslationServer.translate(
		"Large file mode: minimap, syntax highlighting and completion are disabled for this file."
	))

func _on_file_dialog_ui_close() -> void:
	if overlays == null: return
	if overlays.is_open(file_dialog):
		overlays.close(file_dialog)

func _on_theme_load() -> void:
	background.color = LuaSingleton.gui.background_color
	external_background.color = LuaSingleton.gui.background_color
	_publish_mod_event("theme.changed", {"name": str(LuaSingleton.theme)})

	# the file picker's directory listing is plain RichTextLabel text
	file_dialog.add_theme_color_override("default_color", LuaSingleton.gui.font_color)

	if compare_buffer_edit != null:
		dialog_coordinator.style_compare_edit(compare_buffer_edit, "")
	if compare_disk_edit != null:
		dialog_coordinator.style_compare_edit(compare_disk_edit, "")

func preview_theme(index: int) -> void:
	var theme_picker: OptionButton = %ThemeChooser
	var theme = theme_picker.get_item_text(index)

	LuaSingleton.setup_theme(theme)
	LuaSingleton.on_settings_change.emit()

func _on_theme_chooser_item_focused(index):
	preview_theme(index)


func _on_theme_chooser_item_selected(index):
	preview_theme(index)
	LuaSingleton.theme = %ThemeChooser.get_item_text(index)
