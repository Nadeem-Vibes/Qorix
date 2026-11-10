extends PanelContainer

const UI_MOTION = preload("res://src/platform/ui_motion.gd")

## Bottom dock for captured runs.
##
## The panel never owns a process: RunService emits output/result signals and
## this script renders them. That keeps the UI replaceable and means a run can
## keep going while the drawer is closed.
##
## Output is BBCode because every path the compiler prints becomes a real
## link. Diagnoses are rendered as short cards with a "Show me the fix" action,
## which jumps to the reported line and surfaces the fix text.

const OutputLinks = preload("res://src/features/run/output_links.gd")
const ErrorFeedback = preload("res://src/features/run/error_feedback.gd")
const RuntimeCatalog = preload("res://src/features/run/runtime_catalog.gd")

static func _t(text: String) -> String:
	return TranslationServer.translate(text)

const PANEL_HEIGHT := 320.0
const RENDER_INTERVAL := 0.08

var editor = null
var run_service = null
var editor_area: Control

var output_label: RichTextLabel
var output_scroll: ScrollContainer
var status_label: Label
var command_label: Label
var run_button: Button
var terminal_button: Button
var stop_button: Button
var explain_button: Button
var clear_button: Button
var config_button: Button

var _run_button_base := ""
var _code_base_bottom: float = 0.0
var _animating: bool = false
var _show_explanations: bool = true
var _cleared: bool = false
var _live_output: String = ""
var _dirty: bool = true
var _last_render_msec: int = 0

var _file_line: RegEx
var _diagnoses: Array = []
var _feedback: RefCounted = null


func _ready() -> void:
	editor = _find_editor()
	if editor == null:
		return

	run_service = editor.run_service
	editor_area = editor.editor_host
	_code_base_bottom = editor_area.offset_bottom

	theme = LuaSingleton.editor_theme
	visible = false
	modulate.a = 0.0

	set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	offset_top = -PANEL_HEIGHT
	offset_bottom = 0

	_file_line = OutputLinks.compile()

	_build_ui()
	_connect_run_service()
	LuaSingleton.on_theme_load.connect(restyle)
	LuaSingleton.on_settings_change.connect(_on_settings_change)
	restyle()
	_render()


func _build_ui() -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 5)
	add_child(box)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 6)
	box.add_child(header)

	var title := Label.new()
	title.text = "Run"
	title.add_theme_font_size_override("font_size", 14)
	header.add_child(title)

	run_button = Button.new()
	run_button.text = "▶ Run"
	run_button.tooltip_text = "Run the current file (F5)"
	run_button.pressed.connect(_run_pressed)
	header.add_child(run_button)

	terminal_button = Button.new()
	terminal_button.text = "Run in Terminal"
	terminal_button.tooltip_text = "Run the current file in the terminal (F6) — for programs that read keyboard input"
	terminal_button.pressed.connect(_terminal_pressed)
	header.add_child(terminal_button)

	stop_button = Button.new()
	stop_button.text = "■ Stop"
	stop_button.tooltip_text = "Stop the running program (Shift+F5)"
	stop_button.pressed.connect(_stop_pressed)
	stop_button.disabled = true
	header.add_child(stop_button)

	explain_button = Button.new()
	explain_button.toggle_mode = true
	explain_button.button_pressed = true
	explain_button.text = "Explain: On"
	explain_button.tooltip_text = "Show short, language-aware explanations below the output."
	explain_button.toggled.connect(_on_explain_toggled)
	header.add_child(explain_button)

	clear_button = Button.new()
	clear_button.text = "Clear"
	clear_button.tooltip_text = "Clear the latest output and diagnoses."
	clear_button.pressed.connect(clear)
	header.add_child(clear_button)

	config_button = Button.new()
	config_button.text = "Config"
	config_button.tooltip_text = "Open this project's .griddycode/run.json"
	config_button.pressed.connect(_config_pressed)
	header.add_child(config_button)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)

	var close_button := Button.new()
	close_button.text = "✕"
	close_button.tooltip_text = "Close the Run panel (the program keeps running)"
	close_button.pressed.connect(close)
	header.add_child(close_button)

	status_label = Label.new()
	status_label.text = "Ready"
	status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_label.clip_text = true
	box.add_child(status_label)

	command_label = Label.new()
	command_label.text = ""
	command_label.clip_text = true
	command_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(command_label)

	output_scroll = ScrollContainer.new()
	output_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	output_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(output_scroll)

	var inner := VBoxContainer.new()
	inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	output_scroll.add_child(inner)

	output_label = RichTextLabel.new()
	output_label.bbcode_enabled = true
	output_label.fit_content = true
	output_label.scroll_active = false
	output_label.selection_enabled = true
	output_label.context_menu_enabled = true
	output_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	output_label.custom_minimum_size = Vector2(0, 160)
	output_label.meta_clicked.connect(_on_meta_clicked)
	inner.add_child(output_label)


func _connect_run_service() -> void:
	if run_service == null:
		return
	run_service.run_started.connect(_on_run_started)
	run_service.output_changed.connect(_on_output_changed)
	run_service.run_finished.connect(_on_run_finished)
	run_service.run_blocked.connect(_on_run_blocked)
	run_service.state_changed.connect(_on_state_changed)


func _find_editor() -> FileManager:
	var node = get_parent()
	while node != null and !(node is FileManager):
		node = node.get_parent()
	return node


# ── LIFECYCLE ───────────────────────────────────────────────────────────────

func toggle() -> void:
	if visible:
		close()
	else:
		open()


func open() -> void:
	if _animating or visible:
		return

	# The terminal and the Run panel share the bottom strip. Opening one
	# closes the other without an animation so the code area has one base.
	var terminal = editor.terminal if editor != null else null
	if terminal != null and terminal.visible and terminal.has_method("hide_now"):
		terminal.hide_now()
	var lsp_panel = editor.lsp_panel if editor != null else null
	if lsp_panel != null and lsp_panel.visible and lsp_panel.has_method("hide_now"):
		lsp_panel.hide_now()
	var debug_panel = editor.debug_panel if editor != null else null
	if debug_panel != null and debug_panel.visible and debug_panel.has_method("hide_now"):
		debug_panel.hide_now()

	if editor_area != null:
		_code_base_bottom = editor_area.base_bottom()
	_animating = true
	visible = true
	_dirty = true

	var tw := create_tween()
	tw.tween_property(self, "modulate:a", 1.0, UI_MOTION.duration())
	if editor_area != null:
		tw.parallel().tween_property(editor_area, "offset_bottom", _code_base_bottom - PANEL_HEIGHT, UI_MOTION.duration())
	tw.tween_callback(func() -> void: _animating = false)


func close() -> void:
	if _animating or !visible:
		return
	if editor_area != null:
		_code_base_bottom = editor_area.base_bottom()
	_animating = true

	var tw := create_tween()
	tw.tween_property(self, "modulate:a", 0.0, UI_MOTION.duration())
	if editor_area != null:
		tw.parallel().tween_property(editor_area, "offset_bottom", _code_base_bottom, UI_MOTION.duration())
	tw.tween_callback(func() -> void:
		visible = false
		_animating = false
	)
	if editor != null and editor.editor_host != null:
		editor.editor_host.grab_active_focus()


## Used when the terminal takes the bottom strip: no tween, no focus change.
func hide_now() -> void:
	if !visible:
		return
	visible = false
	modulate.a = 0.0
	_animating = false
	if editor_area != null:
		_code_base_bottom = editor_area.base_bottom()
		editor_area.offset_bottom = _code_base_bottom


func _run_pressed() -> void:
	if run_service != null:
		run_service.run()


func _terminal_pressed() -> void:
	if run_service != null:
		run_service.run("", {"force_terminal": true})


func _stop_pressed() -> void:
	if run_service != null:
		run_service.stop()


func _config_pressed() -> void:
	if run_service != null:
		run_service.open_config()


func _on_explain_toggled(enabled: bool) -> void:
	_show_explanations = enabled
	explain_button.text = "Explain: On" if enabled else "Explain: Off"
	_dirty = true


func clear() -> void:
	_cleared = true
	_live_output = ""
	_diagnoses = []
	_dirty = true


# ── RUN SIGNALS ─────────────────────────────────────────────────────────────

func _on_run_started(info: Dictionary) -> void:
	_cleared = false
	_live_output = ""
	_diagnoses = []
	_dirty = true
	open()
	_update_buttons()
	_render()


func _on_output_changed(output: String) -> void:
	_live_output = output
	_dirty = true


func _on_run_finished(_output: String, _exit_code: int) -> void:
	_dirty = true
	_update_buttons()
	_render()


func _on_run_blocked(_result: Dictionary) -> void:
	_cleared = false
	_dirty = true
	open()
	_update_buttons()
	_render()


func _on_state_changed() -> void:
	_update_buttons()
	_dirty = true


func _on_settings_change() -> void:
	restyle()
	_dirty = true


## Session snapshot: whether the drawer was open and whether explanations were
## visible. Output itself is intentionally not persisted (it can be huge and
## stale; rerunning is one keypress).
func capture_session() -> Dictionary:
	return {
		"open": visible,
		"explanations": _show_explanations,
	}


func restore_session(data: Dictionary) -> void:
	_show_explanations = bool(data.get("explanations", true))
	if explain_button != null:
		explain_button.button_pressed = _show_explanations
		explain_button.text = "Explain: On" if _show_explanations else "Explain: Off"
	if bool(data.get("open", false)):
		open()


func _update_buttons() -> void:
	if run_service == null:
		return
	var state: Dictionary = run_service.last_result
	var running := bool(run_service.running) or str(state.get("status", "")) == "starting"
	stop_button.disabled = !running
	run_button.disabled = running
	if explain_button != null:
		explain_button.button_pressed = _show_explanations
		explain_button.text = "Explain: On" if _show_explanations else "Explain: Off"


# ── RENDERING ───────────────────────────────────────────────────────────────

func _process(_delta: float) -> void:
	if !visible or !_dirty:
		return
	var now := Time.get_ticks_msec()
	if now - _last_render_msec < int(RENDER_INTERVAL * 1000.0):
		return
	_last_render_msec = now
	_render()


func _render() -> void:
	if output_label == null:
		return
	_dirty = false
	_update_buttons()

	if run_service == null:
		output_label.text = _empty_text("Run support is not available.")
		return

	var result: Dictionary = run_service.last_result
	var running := bool(run_service.running)
	var status := str(result.get("status", "idle"))
	_diagnoses = result.get("diagnoses", []) if result.get("diagnoses", []) is Array else []

	_update_status(result, running, status)

	if _cleared:
		output_label.text = _empty_text("Output cleared. Press Run to start again.")
		return

	if running and _live_output.is_empty() and result.is_empty():
		output_label.text = _empty_text("Starting…")
		return

	var output := _live_output if running else str(result.get("output", ""))
	if output.is_empty() and result.is_empty():
		output_label.text = _empty_text(_idle_hint())
		return

	var text := ""
	var header := _run_header(result, running)
	if !header.is_empty():
		text += header + "\n"

	if output.is_empty():
		text += "[color=%s]%s[/color]\n" % [_c("comments"), "No output yet." if running else "The program printed nothing."]
	else:
		text += _linkify(output)

	if !running:
		if bool(result.get("truncated", false)):
			text += "\n[color=%s]Output was truncated to keep the panel responsive.[/color]\n" % _c("variable")

		var config_errors: Array = result.get("config_errors", [])
		if config_errors is Array and !config_errors.is_empty():
			text += "\n[color=%s][b]Run config warning[/b][/color]\n" % _c("variable")
			for message in config_errors:
				text += _escape(str(message)) + "\n"

		var install: Array = result.get("install", [])
		if install is Array and !install.is_empty():
			text += _render_install(install)

		if _show_explanations and !_diagnoses.is_empty():
			text += _render_diagnoses()

		var message := str(result.get("message", ""))
		if !message.is_empty() and str(result.get("status", "")) == "blocked":
			text += "\n[color=%s]%s[/color]\n" % [_c("variable"), _escape(message)]

	output_label.text = text.strip_edges() + "\n"


func _run_header(result: Dictionary, running: bool) -> String:
	var display := str(result.get("display", ""))
	var command := str(result.get("command", ""))
	var cwd := str(result.get("cwd", ""))
	if display.is_empty() and command.is_empty():
		return ""

	var bits: Array[String] = []
	if !display.is_empty():
		bits.append("[b]%s[/b]" % _escape(display))
	if !command.is_empty():
		bits.append("[color=%s]$ %s[/color]" % [_c("comments"), _escape(command)])
	if !cwd.is_empty():
		bits.append("[color=%s]in %s[/color]" % [_c("comments"), _escape(cwd)])
	if running:
		bits.append("[color=%s]running…[/color]" % _c("function"))
	return "   ".join(bits)


func _render_diagnoses() -> String:
	var text := "\n[color=%s]────────────────────────────────────────[/color]\n" % _c("comments")
	for i in range(_diagnoses.size()):
		var diagnosis: Dictionary = _diagnoses[i]
		if !(diagnosis is Dictionary):
			continue
		var severity := str(diagnosis.get("severity", "error"))
		var color := _severity_color(severity)
		var title := str(diagnosis.get("title", "Problem"))
		var message := str(diagnosis.get("message", ""))
		var explain := str(diagnosis.get("explain", ""))
		var fix := str(diagnosis.get("fix", ""))

		text += "\n[color=%s][b]%s[/b][/color]\n" % [color, _escape(title)]
		if !message.is_empty():
			text += _escape(message) + "\n"
		if !explain.is_empty():
			text += "[color=%s]%s[/color]\n" % [_c("comments"), _escape(explain)]

		var actions: Array[String] = []
		if str(diagnosis.get("dedupe_key", "")) == "python-eof":
			# The captured runner cannot answer input(), so make the terminal
			# path one click away even when detection missed a stdin reader.
			actions.append("[url=%s][ %s ][/url]" % [_meta({"kind": "terminal"}), _escape(_t("Run in Terminal (F6)"))])
		if !fix.is_empty():
			actions.append("[url=%s][ %s ][/url]" % [_meta({"kind": "fix", "index": i}), _escape(_t("Show me the fix"))])
		var file := str(diagnosis.get("file", ""))
		var line := int(diagnosis.get("line", 0))
		if !file.is_empty() and line > 0:
			actions.append("[url=%s][ Open %s:%d ][/url]" % [
				_meta({"kind": "open", "path": file, "line": line, "column": int(diagnosis.get("column", 0))}),
				_escape(file.get_file()), line,
			])
		var card_id := str(diagnosis.get("dedupe_key", diagnosis.get("id", "")))
		if !card_id.is_empty():
			# One-tap vote so beginners can tell us whether an explanation
			# actually helped. Stored only on this computer.
			actions.append("[url=%s][ %s ][/url]" % [_meta({"kind": "feedback", "index": i, "rating": "up"}), _escape(_t("This explains it"))])
			actions.append("[url=%s][ %s ][/url]" % [_meta({"kind": "feedback", "index": i, "rating": "down"}), _escape(_t("Still confusing"))])
		if !actions.is_empty():
			text += "[color=%s]%s[/color]\n" % [_c("function"), "   ".join(actions)]
		if !fix.is_empty():
			text += "[color=%s]Fix: %s[/color]\n" % [_c("string"), _escape(fix)]

	return text


func _render_install(install: Array) -> String:
	var text := "\n[color=%s][b]Install what this run needs[/b][/color]\n" % _c("variable")
	for item in install:
		if !(item is Dictionary):
			continue
		var help: Dictionary = item.get("install", {})
		if !(help is Dictionary):
			help = {}
		var title := str(help.get("title", "A required program is missing"))
		var hint := str(help.get("hint", ""))
		var url := str(help.get("url", ""))
		var winget := str(help.get("winget", ""))
		var winget_label := str(help.get("winget_label", "Install with winget"))
		text += "\n[color=%s][b]%s[/b][/color]\n" % [_c("variable"), _escape(title)]
		if !hint.is_empty():
			text += _escape(hint) + "\n"
		if !url.is_empty():
			text += "[url=%s][ Open install page ][/url]\n" % _meta({"kind": "url", "url": url})
		if !winget.is_empty() and _winget_available():
			# One click, one confirmation, and the installer runs in a visible
			# terminal tab — nothing happens invisibly.
			text += "[url=%s][ %s ][/url]\n" % [
				_meta({"kind": "winget", "command": winget, "label": winget_label}),
				_escape(winget_label),
			]
	return text


func _empty_text(message: String) -> String:
	return "[color=%s]%s[/color]\n" % [_c("comments"), _escape(message)]


func _idle_hint() -> String:
	return "Press F5 (or the Run button) to run the current file. Compiler errors and exceptions show up here with a line link and a suggested fix.\n\nPrograms that need keyboard input run in the terminal: press F6, or use the Command Palette → \"Run Current File in Terminal\"."


func _update_status(result: Dictionary, running: bool, status: String) -> void:
	if status_label == null:
		return
	var color := _c("comments")
	var text := "Ready"
	if running:
		text = "Running…"
		color = _c("function")
	elif status == "blocked":
		text = "Needs installation"
		color = _c("variable")
	elif status == "terminal":
		text = "Running in the terminal"
		color = _c("function")
	elif status == "failed":
		text = "Exited with code %s" % str(result.get("exit_code", "?"))
		color = _c("error")
	elif status == "stopped":
		text = "Stopped"
		color = _c("variable")
	elif status == "finished":
		var summary := str(result.get("summary", "Program finished"))
		text = summary
		var duration := int(result.get("duration_ms", 0))
		if duration > 0:
			text += "  (%.2fs)" % (duration / 1000.0)
		if int(result.get("exit_code", 0)) == 0:
			color = _c("string")
		else:
			color = _c("error")
	elif !result.is_empty():
		text = str(result.get("summary", status.capitalize()))

	status_label.text = text
	status_label.add_theme_color_override("font_color", color)

	if command_label != null:
		var command := str(result.get("command", ""))
		var cwd := str(result.get("cwd", ""))
		command_label.text = command
		command_label.tooltip_text = ("%s\n%s" % [command, cwd]).strip_edges()
		command_label.add_theme_color_override("font_color", _c("comments"))

	for button in [run_button, terminal_button, stop_button, clear_button, config_button]:
		if button != null:
			button.add_theme_font_override("font", _ui_font())


# ── LINKS / CLICKS ──────────────────────────────────────────────────────────

func _linkify(output: String) -> String:
	var result: Dictionary = run_service.last_result if run_service != null else {}
	return OutputLinks.linkify(
		output,
		_file_line,
		str(result.get("cwd", "")),
		str(result.get("workspace", "")),
		str(result.get("file", ""))
	)


var _winget_checked: bool = false
var _winget_ok: bool = false
var _winget_dialog: ConfirmationDialog = null
var _winget_command: String = ""


func _winget_available() -> bool:
	if !_winget_checked:
		_winget_checked = true
		if OS.get_name() == "Windows":
			var catalog = RuntimeCatalog.new()
			_winget_ok = !catalog.find_executable("winget").is_empty()
	return _winget_ok


func _confirm_winget_install(command: String, label: String) -> void:
	if command.strip_edges().is_empty():
		return
	if _winget_dialog == null or !is_instance_valid(_winget_dialog):
		_winget_dialog = ConfirmationDialog.new()
		_winget_dialog.name = "WingetInstall"
		_winget_dialog.title = label
		_winget_dialog.ok_button_text = "Install"
		_winget_dialog.cancel_button_text = "Not now"
		_winget_dialog.confirmed.connect(_on_winget_confirmed)
		add_child(_winget_dialog)
	_winget_dialog.title = label
	_winget_command = command
	_winget_dialog.dialog_text = (
		"Qorix is about to run this in a new terminal tab. Watch it work — "
		+ "you will be asked for administrator approval by Windows itself.\n\n"
		+ command
		+ "\n\nWhen it finishes, reopen Qorix and the program will be on PATH.")
	_winget_dialog.popup_centered_ratio(0.44)


func _on_winget_confirmed() -> void:
	var command := _winget_command
	_winget_command = ""
	if command.is_empty():
		return
	if editor != null and editor.terminal != null:
		editor.terminal.run_command(command)
		if editor.has_method("warn"):
			editor.warn("[color=#8bd5ff]WINGET[/color]: %s" % _t("Installing in the terminal. Reopen Qorix when it finishes."))


func _on_meta_clicked(meta: String) -> void:
	if !meta.begins_with("griddy:"):
		return
	var decoded := Marshalls.base64_to_utf8(meta.substr(7))
	var payload: Variant = JSON.parse_string(decoded)
	if typeof(payload) != TYPE_DICTIONARY:
		return

	match str(payload.get("kind", "")):
		"open":
			_open_at(str(payload.get("path", "")), int(payload.get("line", 0)), int(payload.get("column", 0)))
		"url":
			var url := str(payload.get("url", ""))
			if !url.is_empty():
				OS.shell_open(url)
		"terminal":
			if run_service != null:
				run_service.run("", {"force_terminal": true})
		"winget":
			_confirm_winget_install(str(payload.get("command", "")), str(payload.get("label", "Install")))
		"fix":
			_show_fix(int(payload.get("index", -1)))
		"feedback":
			_record_feedback(int(payload.get("index", -1)), str(payload.get("rating", "")))
		"config":
			# Nothing currently emits this link; keep it harmless if a mod or an
			# older run config does.
			if run_service != null and run_service.has_method("open_config"):
				run_service.open_config()


func _record_feedback(index: int, rating: String) -> void:
	if index < 0 or index >= _diagnoses.size():
		return
	var diagnosis: Dictionary = _diagnoses[index]
	if !(diagnosis is Dictionary):
		return
	var rule_id := str(diagnosis.get("dedupe_key", diagnosis.get("id", "")))
	if rule_id.is_empty():
		return
	var language := str(diagnosis.get("language", ""))
	var store := _feedback_store()
	var result: Dictionary = store.record(rule_id, rating, language)
	if editor != null and editor.has_method("warn"):
		if bool(result.get("ok", false)):
			editor.warn("[color=#8bd5ff]THANKS[/color]: %s" % _t("Feedback saved on this computer. Your votes help make the explanations clearer."))
		else:
			editor.warn("[color=yellow]FEEDBACK[/color]: %s" % (_t("Could not save that feedback — %s") % str(result.get("error", "unknown error"))))


func _feedback_store() -> RefCounted:
	if _feedback == null:
		_feedback = ErrorFeedback.new()
	return _feedback


func _open_at(path: String, line: int, column: int) -> void:
	if path.is_empty() or line <= 0:
		return
	if !FileAccess.file_exists(path):
		if editor != null:
			editor.warn("[color=yellow]RUN[/color]: %s no longer exists." % path)
		return
	if editor != null and editor.has_method("open_search_result"):
		# Compiler output is 1-based; the editor API is 0-based.
		editor.open_search_result(path, maxi(line - 1, 0), maxi(column - 1, 0))


func _show_fix(index: int) -> void:
	if index < 0 or index >= _diagnoses.size():
		return
	var diagnosis: Dictionary = _diagnoses[index]
	var fix := str(diagnosis.get("fix", ""))
	var file := str(diagnosis.get("file", ""))
	var line := int(diagnosis.get("line", 0))
	var column := int(diagnosis.get("column", 0))

	if !file.is_empty() and line > 0:
		_open_at(file, line, column)
	if !fix.is_empty() and editor != null:
		editor.warn("[color=#8bd5ff]RUN FIX[/color]: %s" % _escape(fix))
	elif !fix.is_empty():
		DisplayServer.clipboard_set(fix)


func _meta(payload: Dictionary) -> String:
	return OutputLinks.meta(payload)


# ── THEME ───────────────────────────────────────────────────────────────────

func restyle() -> void:
	if !is_inside_tree():
		return

	var panel := StyleBoxFlat.new()
	panel.bg_color = LuaSingleton.gui.background_color
	panel.set_content_margin_all(6)
	panel.content_margin_left = 10
	panel.content_margin_right = 10
	panel.corner_radius_top_left = 4
	panel.corner_radius_top_right = 4
	panel.border_width_top = 1
	panel.border_color = LuaSingleton.gui.current_line_color
	add_theme_stylebox_override("panel", panel)

	if status_label != null:
		status_label.add_theme_color_override("font_color", _c("comments"))
	if command_label != null:
		command_label.add_theme_color_override("font_color", _c("comments"))
	if output_label != null:
		output_label.add_theme_font_override("normal_font", _mono_font())
		output_label.add_theme_font_override("bold_font", _mono_font())
		output_label.add_theme_font_override("italics_font", _mono_font())
		output_label.add_theme_font_override("mono_font", _mono_font())
		output_label.add_theme_font_size_override("normal_font_size", _font_size())
		output_label.add_theme_font_size_override("bold_font_size", _font_size())
		output_label.add_theme_color_override("default_color", LuaSingleton.gui.font_color)
	_dirty = true


func _ui_font() -> Font:
	if LuaSingleton.editor_theme != null:
		return LuaSingleton.editor_theme.get_font("font", "MyType")
	return ThemeDB.fallback_font


func _mono_font() -> Font:
	return _ui_font()


func _font_size() -> int:
	var size := 14
	var found = LuaSingleton.get_setting("editor_font_size")
	if found is Array and found.size() >= 2 and int(found[1]) != -1:
		size = clampi(int(found[0].get("value", size)) - 2, 10, 28)
	return size


func _c(key: String) -> String:
	var palette: Dictionary = LuaSingleton.keywords
	if palette.has(key):
		var color: Color = palette[key]
		return "#" + color.to_html(false)
	return "#c9d1d9"


func _severity_color(severity: String) -> String:
	match severity:
		"warning":
			return _c("variable")
		"info":
			return _c("function")
		_:
			return _c("error")


func _escape(text: String) -> String:
	return OutputLinks.escape(text)
