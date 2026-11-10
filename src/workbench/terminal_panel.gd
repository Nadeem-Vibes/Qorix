extends PanelContainer

const UI_MOTION = preload("res://src/platform/ui_motion.gd")

# Terminal panel (HUD, bottom dock): Ctrl+` toggles. A real shell in a real
# pseudoterminal via godot-xterm — prompts, echo, colors and Ctrl+C belong to
# the shell itself, nothing here is simulated.
#
# Multiple shells live side by side as tabs (Ctrl+Shift+` opens a new one).
# Every tab owns its own Terminal renderer and TerminalSession process; only
# the selected one is visible, so background shells keep running and keep
# their scrollback when you switch away, like a real terminal drawer.
#
# Deliberately bypasses the toggle()/active_overlay system: the terminal stays
# docked at the bottom while you keep editing, like VS Code. It manages its own
# visibility and guards against input spam with its own transitioning flag.
#
# The Terminal class comes from the godot-xterm GDExtension, so it is resolved
# dynamically: if the extension isn't loaded (the editor needs ONE restart
# after the addon was added) the panel still appears and explains why, instead
# of failing to compile and taking the whole HUD down with it.

const PANEL_HEIGHT := 300.0

var editor: FileManager
# The area that shrinks to make room for the docked terminal. EditorHost fills
# the old single-CodeEdit rect, so it is the thing to animate now.
var editor_area: Control

## One Dictionary per tab: id, title, terminal (Terminal), session
## (TerminalSession), pending (Array of commands), starting, closed, status.
var entries: Array = []
var active_index: int = -1

var tab_bar: TabBar
var add_button: Button
var clear_button: Button
var kill_button: Button
var cwd_label: Label
var terminal_holder: Control

var _sync_tab_selection: bool = false
var _animating: bool = false
var _next_terminal_id: int = 1
var _code_base_bottom: float = 0.0  # the code area's resting layout
var _base_position := Vector2.ZERO

func _ready() -> void:
	editor = _find_editor()
	editor_area = editor.editor_host
	editor.terminal = self
	_code_base_bottom = editor_area.offset_bottom

	theme = LuaSingleton.editor_theme
	visible = false
	modulate.a = 0.0

	set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	offset_top = -PANEL_HEIGHT
	offset_bottom = 0
	_base_position = position

	var box = VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	add_child(box)

	var header = HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	box.add_child(header)

	tab_bar = TabBar.new()
	tab_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tab_bar.max_tab_width = 220
	tab_bar.tab_close_display_policy = TabBar.CLOSE_BUTTON_SHOW_ALWAYS
	tab_bar.select_with_rmb = false
	# tab order must stay 1:1 with entries; drags would scramble which tab maps
	# to which shell
	tab_bar.drag_to_rearrange_enabled = false
	# keep the keyboard focus in the terminal, not on the strip
	tab_bar.focus_mode = Control.FOCUS_NONE
	header.add_child(tab_bar)
	tab_bar.tab_changed.connect(_on_tab_changed)
	tab_bar.tab_close_pressed.connect(_on_tab_close_pressed)

	add_button = Button.new()
	add_button.text = "+"
	add_button.tooltip_text = "New terminal (Ctrl+Shift+`)"
	add_button.pressed.connect(new_terminal)
	header.add_child(add_button)

	clear_button = Button.new()
	clear_button.text = "Clear"
	clear_button.pressed.connect(clear_active)
	header.add_child(clear_button)

	kill_button = Button.new()
	kill_button.text = "Kill"
	kill_button.pressed.connect(kill_session)
	header.add_child(kill_button)

	var close_button = Button.new()
	close_button.text = "✕"
	close_button.pressed.connect(close)
	header.add_child(close_button)

	# status strip: shell + live working directory of the active tab
	var status = HBoxContainer.new()
	box.add_child(status)

	cwd_label = Label.new()
	cwd_label.text = ""
	cwd_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cwd_label.clip_text = true
	status.add_child(cwd_label)

	terminal_holder = Control.new()
	terminal_holder.custom_minimum_size = Vector2(0, 200)
	terminal_holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(terminal_holder)

	LuaSingleton.on_theme_load.connect(restyle)
	LuaSingleton.on_settings_change.connect(restyle)

	if !_addon_ready():
		# godot-xterm's GDExtension isn't loaded yet — say so instead of
		# failing silently (a restart of the editor fixes this)
		var notice = Label.new()
		notice.text = "godot-xterm not loaded — restart the editor once to enable the terminal."
		notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		notice.size_flags_vertical = Control.SIZE_EXPAND_FILL
		box.add_child(notice)
		add_button.disabled = true
		clear_button.disabled = true
		kill_button.disabled = true
		restyle()
		return

	# Start with one tab ready to go. The shell itself is forked lazily on the
	# first open(), once the panel has a real size to give the PTY.
	_create_terminal(_default_cwd())
	restyle()

	print("[terminal] godot-xterm ready — press Ctrl+` to toggle")

func _find_editor() -> FileManager:
	var node = get_parent()
	while node != null and !(node is FileManager):
		node = node.get_parent()
	return node

## True while the terminal renderer owns the keyboard. InputController uses
## this to route only global + terminal-scope shortcuts while typing a shell
## command, so Ctrl+F stays in the terminal instead of opening editor find.
func is_terminal_focused() -> bool:
	if !visible:
		return false
	var focus: Control = get_viewport().gui_get_focus_owner()
	return focus != null and is_ancestor_of(focus)

func _addon_ready() -> bool:
	return ClassDB.class_exists("Terminal") and ClassDB.class_exists("PTY")

func _active_entry() -> Dictionary:
	if active_index < 0 or active_index >= entries.size():
		return {}
	return entries[active_index]

func _is_active(entry: Dictionary) -> bool:
	var active := _active_entry()
	return !active.is_empty() and active.id == entry.id

# TABS ─────────────────────────────────────────────────────────────

## Create a tab and its Terminal/TerminalSession pair. The shell is not
## started here: callers activate the tab and _ensure_started() forks it once
## the renderer has a settled grid. `start_cwd` survives a session restart.
func _create_terminal(start_cwd: String = "") -> Dictionary:
	var terminal = ClassDB.instantiate("Terminal")
	terminal.name = "Terminal%d" % _next_terminal_id
	terminal.custom_minimum_size = Vector2(0, 200)
	terminal.size_flags_vertical = Control.SIZE_EXPAND_FILL
	terminal.visible = false
	terminal_holder.add_child(terminal)
	terminal.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var session := TerminalSession.new()
	session.name = "Session"
	terminal.add_child(session)

	var entry := {
		"id": _next_terminal_id,
		"title": "Terminal %d" % _next_terminal_id,
		"terminal": terminal,
		"session": session,
		"pending": [],
		"starting": false,
		"closed": false,
		"status": "",
		"start_cwd": start_cwd,
	}
	_next_terminal_id += 1
	entries.append(entry)

	# Same wiring as godot-xterm's own editor terminal: typing flows out to the
	# shell, terminal resizes resize the PTY, shell output renders back.
	terminal.data_sent.connect(session.write)
	terminal.size_changed.connect(session.resizev)
	session.data_received.connect(terminal.write)
	session.exited.connect(_on_session_exited.bind(entry))

	# tabs created after a theme switch still get the current ANSI palette
	_style_terminal(terminal)

	active_index = entries.size() - 1
	_rebuild_tabs()
	_apply_active_visibility()
	_update_status()
	return entry

func _rebuild_tabs() -> void:
	_sync_tab_selection = true
	tab_bar.clear_tabs()
	for entry in entries:
		tab_bar.add_tab(entry.title)
	if active_index >= 0 and active_index < tab_bar.tab_count:
		tab_bar.current_tab = active_index
	_sync_tab_selection = false
	_update_tab_tooltips()

func _apply_active_visibility() -> void:
	for i in range(entries.size()):
		entries[i].terminal.visible = i == active_index

func _select(index: int) -> void:
	if index < 0 or index >= entries.size():
		return
	active_index = index
	_apply_active_visibility()
	_update_status()
	if !visible:
		return
	_activate_entry(entries[index])

func _on_tab_changed(index: int) -> void:
	if _sync_tab_selection:
		return
	_select(index)

func _on_tab_close_pressed(index: int) -> void:
	close_terminal(index)

## Open a fresh shell in a new tab (Ctrl+Shift+` / the + button).
func new_terminal() -> void:
	if !_addon_ready():
		open()
		return
	if _animating:
		# let an in-flight open/close finish so we don't add a tab to a panel
		# that is about to slide shut
		await get_tree().create_timer(0.2).timeout
		if !is_inside_tree():
			return
	var entry := _create_terminal(_default_cwd())
	if visible:
		_activate_entry(entry)
	else:
		open()

## Close one terminal tab (defaults to the active one). Closing the last tab
## closes the drawer; the next open() starts a fresh shell.
func close_terminal(index: int = -1) -> void:
	if entries.is_empty():
		return
	if index < 0:
		index = active_index
	if index < 0 or index >= entries.size():
		return

	var entry: Dictionary = entries[index]
	entry.closed = true
	entry.session.kill()
	_dispose_entry(entry)
	entries.remove_at(index)

	if entries.is_empty():
		active_index = -1
		_rebuild_tabs()
		_apply_active_visibility()
		_update_status()
		if visible:
			_close_if_empty_after_animation()
		return

	if index < active_index:
		active_index -= 1
	elif index == active_index:
		active_index = mini(index, entries.size() - 1)

	_rebuild_tabs()
	_apply_active_visibility()
	_update_status()
	if visible:
		_activate_entry(entries[active_index])

## Closing the last tab during the open/close slide must wait for the tween:
## close() refuses to run while _animating.
func _close_if_empty_after_animation() -> void:
	while _animating:
		await get_tree().process_frame
	if visible and entries.is_empty():
		close()

## Free a closed tab's nodes, but only once a pending start() coroutine has
## finished — so it never resumes on a freed object.
func _dispose_entry(entry: Dictionary) -> void:
	var terminal = entry.terminal
	while entry.starting:
		await get_tree().process_frame
	if is_instance_valid(terminal):
		terminal.queue_free()

# LIFECYCLE ────────────────────────────────────────────────────────

func toggle() -> void:
	if _animating:
		return
	if visible:
		close()
	else:
		open()

func open() -> void:
	if _animating:
		return

	# The Run output dock and the terminal share the bottom strip.
	if editor != null and editor.output_panel != null and editor.output_panel.visible:
		if editor.output_panel.has_method("hide_now"):
			editor.output_panel.hide_now()
	if editor != null and editor.lsp_panel != null and editor.lsp_panel.visible:
		if editor.lsp_panel.has_method("hide_now"):
			editor.lsp_panel.hide_now()
	if editor != null and editor.debug_panel != null and editor.debug_panel.visible:
		if editor.debug_panel.has_method("hide_now"):
			editor.debug_panel.hide_now()

	if entries.is_empty() and _addon_ready():
		_create_terminal(_default_cwd())

	# The editor host grows and shrinks with the document, so the resting
	# height must be read now instead of trusting the value cached in _ready.
	if editor_area != null:
		_code_base_bottom = editor_area.base_bottom()
	_animating = true
	visible = true
	position = _base_position + Vector2(0, 6)

	if !entries.is_empty() and (active_index < 0 or active_index >= entries.size()):
		active_index = entries.size() - 1
	_rebuild_tabs()
	_apply_active_visibility()
	_update_status()

	# slide the code area up so the terminal docks into its own strip instead
	# of covering the editor, in sync with the fade-in
	var tw = create_tween()
	tw.set_parallel(true)
	tw.tween_property(self, "modulate:a", 1.0, UI_MOTION.duration(0.2))
	tw.tween_property(self, "position", _base_position, UI_MOTION.duration(0.2))
	tw.tween_property(editor_area, "offset_bottom", _code_base_bottom - PANEL_HEIGHT, UI_MOTION.duration(0.2))
	tw.chain()
	tw.tween_callback(func(): _animating = false)

	if !entries.is_empty():
		_activate_entry(entries[active_index])

func close() -> void:
	if _animating:
		return
	if editor_area != null:
		_code_base_bottom = editor_area.base_bottom()
	_animating = true

	var tw = create_tween()
	tw.set_parallel(true)
	tw.tween_property(self, "modulate:a", 0.0, UI_MOTION.duration(0.2))
	tw.tween_property(self, "position", _base_position + Vector2(0, 6), UI_MOTION.duration(0.2))
	tw.tween_property(editor_area, "offset_bottom", _code_base_bottom, UI_MOTION.duration(0.2))
	tw.chain()
	tw.tween_callback(func():
		visible = false
		position = _base_position
		_animating = false
	)

	editor.editor_host.grab_active_focus()


## Used when the Run output dock takes the bottom strip: no tween and no focus
## change, so the shared editor height is correct before the other dock opens.
func hide_now() -> void:
	if !visible:
		return
	visible = false
	modulate.a = 0.0
	_animating = false
	if editor_area != null:
		_code_base_bottom = editor_area.base_bottom()
		editor_area.offset_bottom = _code_base_bottom

## Focus a tab's renderer and make sure its shell is alive. Shells start
## lazily, only once their tab is visible and the terminal grid has settled.
func _activate_entry(entry: Dictionary) -> void:
	if entry.closed or !visible:
		return
	if entry.session.running:
		entry.session.resizev(Vector2i(entry.terminal.get_cols(), entry.terminal.get_rows()))
	else:
		_ensure_started(entry)
	entry.terminal.grab_focus()

func _ensure_started(entry: Dictionary) -> void:
	if entry.closed or entry.starting:
		return
	if entry.session.running:
		return

	var terminal = entry.terminal
	if !terminal.visible:
		return

	entry.starting = true
	entry.status = ""
	_update_status()

	# wait until the Terminal's grid settles before forking — reading the
	# size while the panel is still laying out (or hidden: 0 cols) forks
	# the shell into a stale grid, which ConPTY renders with the prompt
	# pushed below the visible area
	var last := Vector2i(terminal.get_cols(), terminal.get_rows())
	var guard := 0
	while guard < 12:
		await get_tree().process_frame
		if entry.closed or !terminal.visible:
			entry.starting = false
			return
		var now := Vector2i(terminal.get_cols(), terminal.get_rows())
		if now.x > 0 and now == last:
			break
		last = now
		guard += 1

	if entry.closed:
		entry.starting = false
		return

	var ok: bool = await entry.session.start(
		terminal.get_cols(),
		terminal.get_rows(),
		str(entry.get("start_cwd", _default_cwd()))
	)
	entry.starting = false
	if entry.closed:
		# the tab went away while start() was settling — don't leave a shell
		# behind just because its node is about to be freed
		entry.session.kill()
		return

	if ok:
		entry.status = ""
		# remember the folder this tab belonged to for session restore
		if !entry.session.cwd.is_empty():
			entry.start_cwd = entry.session.cwd
		# cinch the shell grid onto the visible grid right away — the
		# addon debounces ConPTY resize over several frames, which can
		# otherwise leave the bottom line below the fold until the next
		# repaint
		entry.session.resizev(Vector2i(terminal.get_cols(), terminal.get_rows()))
		print("[terminal %d] %s running in %s" % [entry.id, entry.session.shell, entry.session.cwd])
		# ConPTY keeps bringing the console online for a beat after fork()
		# returns; a write landing inside that window interleaves with the
		# first prompt echo (mangled leading characters / shifted command).
		# One frame of breathing room before the queued commands go out —
		# same reasoning as terminal_session's respawn settle window
		await get_tree().process_frame
		if entry.closed:
			return
		_flush_pending(entry)
	else:
		entry.status = "failed to start shell"

	_update_status()

## Queue a command to type into the active tab's shell (Enter included). If
## that shell isn't running yet it is sent right after the session starts.
func run_command(command: String) -> void:
	if entries.is_empty() and _addon_ready():
		_create_terminal()
	if !visible and _addon_ready():
		open()

	var entry := _active_entry()
	if entry.is_empty():
		return

	if entry.session.running:
		entry.session.write(command + "\r")
	else:
		entry.pending.append(command)
		_ensure_started(entry)

func _flush_pending(entry: Dictionary) -> void:
	for command in entry.pending:
		entry.session.write(command + "\r")
	entry.pending.clear()

func clear_active() -> void:
	var entry := _active_entry()
	if !entry.is_empty():
		entry.terminal.clear()

func kill_session() -> void:
	var entry := _active_entry()
	if entry.is_empty():
		return
	entry.status = "shell killed"
	entry.session.kill()
	_update_status()

func _on_session_exited(exit_code: int, signal_code: int, entry: Dictionary) -> void:
	var reason := "code %d" % exit_code
	if signal_code != 0:
		reason += ", signal %d" % signal_code
	entry.status = "shell exited (%s)" % reason
	if _is_active(entry):
		_update_status()

## The shell behind the selected tab, for callers like RunManager.stop().
func get_active_session() -> TerminalSession:
	var entry := _active_entry()
	return entry.session if !entry.is_empty() else null

func _update_status() -> void:
	var entry := _active_entry()
	if entry.is_empty():
		cwd_label.text = ""
		kill_button.disabled = true
		return

	if entry.session.running:
		cwd_label.text = "%s — in %s" % [entry.session.shell, entry.session.cwd]
	elif entry.starting:
		cwd_label.text = "starting shell…"
	elif !entry.status.is_empty():
		cwd_label.text = entry.status
	else:
		cwd_label.text = "shell not running — press Ctrl+` to respawn"
	kill_button.disabled = !entry.session.running
	_update_tab_tooltips()

func _update_tab_tooltips() -> void:
	if tab_bar.tab_count != entries.size():
		return
	for i in range(entries.size()):
		var entry: Dictionary = entries[i]
		var tip: String = entry.title
		if entry.session.running:
			tip = "%s — %s" % [entry.session.shell, entry.session.cwd]
		elif !entry.status.is_empty():
			tip = "%s (%s)" % [entry.title, entry.status]
		tab_bar.set_tab_tooltip(i, tip)


## The folder new shells (and restored tabs) start in. The workspace root is a
## better default than whatever file happened to be opened last; outside a
## workspace it falls back to the editor's current directory.
func _default_cwd() -> String:
	if editor == null:
		return ""
	if editor.has_method("workspace_root_for_tools"):
		var root = editor.workspace_root_for_tools()
		if root is String and !root.is_empty():
			return root
	return str(editor.current_dir)


## Session snapshot: tab titles and the folder each shell was started in.
## Output is a plain Dictionary so SessionService can sanitize/persist it.
func capture_session() -> Dictionary:
	var list: Array = []
	for entry in entries:
		var folder := str(entry.get("start_cwd", ""))
		if entry.session.running and !entry.session.cwd.is_empty():
			folder = entry.session.cwd
		list.append({
			"title": str(entry.get("title", "")),
			"start_cwd": folder,
		})

	return {
		"open": visible,
		"active_index": maxi(active_index, 0),
		"entries": list,
	}


## Rebuilds the tabs from a saved session. Shells are still lazy: only the
## active tab forks, exactly like a normal startup. Call after the HUD exists.
func restore_session(data: Dictionary) -> void:
	if !_addon_ready():
		return

	var saved: Variant = data.get("entries", [])
	if !(saved is Array):
		saved = []

	for entry in entries.duplicate():
		entry.closed = true
		entry.session.kill()
		if is_instance_valid(entry.terminal):
			entry.terminal.queue_free()
	entries.clear()

	_next_terminal_id = 1
	active_index = -1

	for raw in saved:
		if !(raw is Dictionary):
			continue
		var folder := str(raw.get("start_cwd", raw.get("cwd", "")))
		var entry := _create_terminal(folder)
		var title := str(raw.get("title", "")).strip_edges()
		if !title.is_empty() and title.length() <= 80:
			entry.title = title

	if entries.is_empty():
		_create_terminal(_default_cwd())

	active_index = clampi(int(data.get("active_index", entries.size() - 1)), 0, entries.size() - 1)
	_rebuild_tabs()
	_apply_active_visibility()
	_update_status()

	if bool(data.get("open", false)):
		open()

## App shutdown: terminate every shell so no cmd.exe is left behind.
func shutdown() -> void:
	for entry in entries:
		entry.session.kill()

func restyle() -> void:
	var panel = StyleBoxFlat.new()
	panel.bg_color = LuaSingleton.gui.background_color
	panel.set_content_margin_all(6)
	panel.content_margin_left = 10
	panel.content_margin_right = 10
	panel.corner_radius_top_left = 4
	panel.corner_radius_top_right = 4
	panel.border_width_top = 1
	panel.border_color = LuaSingleton.gui.current_line_color
	add_theme_stylebox_override("panel", panel)

	cwd_label.add_theme_color_override("font_color", LuaSingleton.keywords.comments)
	_style_tab_bar()

	# the ANSI palette can only be styled when the extension is loaded
	for entry in entries:
		if is_instance_valid(entry.terminal):
			_style_terminal(entry.terminal)

func _style_tab_bar() -> void:
	tab_bar.add_theme_color_override("font_selected_color", LuaSingleton.gui.font_color)
	tab_bar.add_theme_color_override("font_unselected_color", LuaSingleton.keywords.comments)
	tab_bar.add_theme_color_override("font_hovered_color", LuaSingleton.gui.font_color)

	var selected = StyleBoxFlat.new()
	selected.bg_color = LuaSingleton.gui.background_color.lightened(0.03)
	selected.set_content_margin_all(6)
	selected.content_margin_left = 12
	selected.content_margin_right = 14
	selected.corner_radius_top_left = 4
	selected.corner_radius_top_right = 4

	var unselected = selected.duplicate()
	unselected.bg_color = LuaSingleton.gui.background_color.darkened(0.08)

	var hovered = selected.duplicate()
	hovered.bg_color = LuaSingleton.gui.background_color.darkened(0.04)

	tab_bar.add_theme_stylebox_override("tab_selected", selected)
	tab_bar.add_theme_stylebox_override("tab_unselected", unselected)
	tab_bar.add_theme_stylebox_override("tab_hovered", hovered)

func _style_terminal(terminal) -> void:
	# map the Lua theme onto the terminal's ANSI palette
	terminal.add_theme_color_override("background_color", LuaSingleton.gui.background_color)
	terminal.add_theme_color_override("foreground_color", LuaSingleton.gui.font_color)
	terminal.add_theme_color_override("cursor_color", LuaSingleton.gui.caret_color)

	terminal.add_theme_color_override("ansi_0_color", LuaSingleton.gui.background_color.darkened(0.35))
	terminal.add_theme_color_override("ansi_1_color", LuaSingleton.keywords.error)      # red
	terminal.add_theme_color_override("ansi_2_color", LuaSingleton.keywords.string)     # green
	terminal.add_theme_color_override("ansi_3_color", LuaSingleton.keywords.variable)   # yellow
	terminal.add_theme_color_override("ansi_4_color", LuaSingleton.keywords.function)   # blue
	terminal.add_theme_color_override("ansi_5_color", LuaSingleton.keywords.reserved)   # magenta
	terminal.add_theme_color_override("ansi_6_color", LuaSingleton.keywords.operator)   # cyan
	terminal.add_theme_color_override("ansi_7_color", LuaSingleton.gui.font_color)      # white

	# bright variants = lightened base colors
	for i in range(8):
		var base: Color = terminal.get_theme_color("ansi_%d_color" % i)
		terminal.add_theme_color_override("ansi_%d_color" % (i + 8), base.lightened(0.35))
