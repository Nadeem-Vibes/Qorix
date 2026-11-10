extends PanelContainer

const UI_MOTION = preload("res://src/platform/ui_motion.gd")

## Bottom dock for language-server state: Problems, Servers and Log.
##
## Faults are rendered from LspManager, never computed here. The panel only
## decides how to present them: a jumpable problems list, a server roster with
## install instructions, and the raw protocol log for the moments when a server
## refuses to start.

const PANEL_HEIGHT := 330.0
const RENDER_INTERVAL := 0.15

var editor = null
var manager = null
var editor_area: Control

var _header_status: Label
var _tabs: TabBar
var _restart_button: Button
var _clear_button: Button
var _close_button: Button

var _problems_page: VBoxContainer
var _problem_filter: LineEdit
var _problem_list: ItemList
var _problem_detail: RichTextLabel
var _problem_empty: Label

var _servers_page: VBoxContainer
var _server_list: ItemList
var _server_detail: RichTextLabel
var _install_box: VBoxContainer
var _install_scroll: ScrollContainer

var _log_page: VBoxContainer
var _log_view: RichTextLabel
var _log_scroll: ScrollContainer

var _pages: Array[Control] = []
var _current_tab: int = 0
var _base_bottom: float = 0.0
var _animating: bool = false
var _dirty: bool = true
var _last_render_msec: int = 0

var _problem_items: Array = []
var _server_rows: Array = []
var _forced_install: Dictionary = {}
var _selected_server: int = -1


func _ready() -> void:
	editor = _find_editor()
	if editor == null:
		return
	manager = editor.lsp_manager
	editor_area = editor.editor_host
	_base_bottom = editor_area.offset_bottom if editor_area != null else 0.0

	theme = LuaSingleton.editor_theme
	visible = false
	modulate.a = 0.0
	set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	offset_top = -PANEL_HEIGHT
	offset_bottom = 0

	_build_ui()
	_connect_manager()
	LuaSingleton.on_theme_load.connect(restyle)
	LuaSingleton.on_settings_change.connect(_on_settings_change)
	restyle()
	select_tab(0, false)


func _find_editor() -> FileManager:
	var node = get_parent()
	while node != null and !(node is FileManager):
		node = node.get_parent()
	return node


func _connect_manager() -> void:
	if manager == null:
		return
	manager.diagnostics_updated.connect(_mark_dirty)
	manager.servers_updated.connect(_mark_dirty)
	manager.log_updated.connect(_mark_dirty)
	manager.missing_server.connect(_on_missing_server)
	manager.server_failed.connect(_on_server_failed)


# ── UI ──────────────────────────────────────────────────────────────────────

func _build_ui() -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	add_child(box)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 6)
	box.add_child(header)

	var title := Label.new()
	title.text = "Language"
	title.add_theme_font_size_override("font_size", 14)
	header.add_child(title)

	_tabs = TabBar.new()
	_tabs.add_tab("Problems")
	_tabs.add_tab("Servers")
	_tabs.add_tab("Log")
	_tabs.current_tab = 0
	_tabs.tab_changed.connect(_on_tab_changed)
	header.add_child(_tabs)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)

	_header_status = Label.new()
	_header_status.text = "No problems"
	_header_status.clip_text = true
	_header_status.custom_minimum_size = Vector2(260, 0)
	_header_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	header.add_child(_header_status)

	_restart_button = Button.new()
	_restart_button.text = "⟳ Restart"
	_restart_button.tooltip_text = "Stop and restart every language server (LSP: Restart Servers)"
	_restart_button.pressed.connect(_on_restart_pressed)
	header.add_child(_restart_button)

	_clear_button = Button.new()
	_clear_button.text = "Clear"
	_clear_button.tooltip_text = "Clear the current tab (problems or log)"
	_clear_button.pressed.connect(_on_clear_pressed)
	header.add_child(_clear_button)

	_close_button = Button.new()
	_close_button.text = "✕"
	_close_button.tooltip_text = "Close the Language panel"
	_close_button.pressed.connect(close)
	header.add_child(_close_button)

	_problems_page = VBoxContainer.new()
	_problems_page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_problems_page.add_theme_constant_override("separation", 4)
	box.add_child(_problems_page)
	_build_problems_page(_problems_page)

	_servers_page = VBoxContainer.new()
	_servers_page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_servers_page.add_theme_constant_override("separation", 4)
	box.add_child(_servers_page)
	_build_servers_page(_servers_page)

	_log_page = VBoxContainer.new()
	_log_page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(_log_page)
	_build_log_page(_log_page)

	_pages = [_problems_page, _servers_page, _log_page]
	_apply_page()


func _build_problems_page(page: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	page.add_child(row)

	_problem_filter = LineEdit.new()
	_problem_filter.placeholder_text = "Filter problems by file, message or source…"
	_problem_filter.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_problem_filter.text_changed.connect(func(_text: String) -> void:
		_dirty = true
		_refresh_problems()
	)
	row.add_child(_problem_filter)

	_problem_empty = Label.new()
	_problem_empty.add_theme_font_size_override("font_size", 11)
	row.add_child(_problem_empty)

	_problem_list = ItemList.new()
	_problem_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_problem_list.custom_minimum_size = Vector2(0, 150)
	_problem_list.item_activated.connect(_on_problem_activated)
	_problem_list.item_selected.connect(_on_problem_selected)
	page.add_child(_problem_list)

	_problem_detail = RichTextLabel.new()
	_problem_detail.bbcode_enabled = true
	_problem_detail.fit_content = false
	_problem_detail.scroll_active = true
	_problem_detail.selection_enabled = true
	_problem_detail.custom_minimum_size = Vector2(0, 56)
	page.add_child(_problem_detail)


func _build_servers_page(page: VBoxContainer) -> void:
	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.split_offset = 320
	page.add_child(split)

	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 4)
	split.add_child(left)

	_server_list = ItemList.new()
	_server_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_server_list.custom_minimum_size = Vector2(240, 140)
	_server_list.item_selected.connect(_on_server_selected)
	left.add_child(_server_list)

	_server_detail = RichTextLabel.new()
	_server_detail.bbcode_enabled = true
	_server_detail.fit_content = false
	_server_detail.scroll_active = true
	_server_detail.selection_enabled = true
	_server_detail.custom_minimum_size = Vector2(0, 140)
	_server_detail.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.add_child(_server_detail)

	_install_scroll = ScrollContainer.new()
	_install_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_install_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_install_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	split.add_child(_install_scroll)

	_install_box = VBoxContainer.new()
	_install_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_install_box.add_theme_constant_override("separation", 6)
	_install_scroll.add_child(_install_box)


func _build_log_page(page: VBoxContainer) -> void:
	_log_scroll = ScrollContainer.new()
	_log_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	page.add_child(_log_scroll)

	_log_view = RichTextLabel.new()
	_log_view.bbcode_enabled = false
	_log_view.fit_content = true
	_log_view.scroll_active = false
	_log_view.selection_enabled = true
	_log_view.context_menu_enabled = true
	_log_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_log_view.custom_minimum_size = Vector2(0, 150)
	_log_scroll.add_child(_log_view)


# ── LIFECYCLE ───────────────────────────────────────────────────────────────

func toggle() -> void:
	if visible:
		close()
	else:
		open(_current_tab)


func open(tab: int = -1) -> void:
	if _animating or visible:
		if tab >= 0:
			select_tab(tab)
		return

	if editor != null:
		if editor.terminal != null and editor.terminal.visible and editor.terminal.has_method("hide_now"):
			editor.terminal.hide_now()
		if editor.output_panel != null and editor.output_panel.visible and editor.output_panel.has_method("hide_now"):
			editor.output_panel.hide_now()
		if editor.debug_panel != null and editor.debug_panel.visible and editor.debug_panel.has_method("hide_now"):
			editor.debug_panel.hide_now()

	if tab >= 0:
		select_tab(tab)
	_dirty = true
	refresh()
	if editor_area != null:
		_base_bottom = editor_area.base_bottom()
	_animating = true
	visible = true

	var tw := create_tween()
	tw.tween_property(self, "modulate:a", 1.0, UI_MOTION.duration())
	if editor_area != null:
		tw.parallel().tween_property(editor_area, "offset_bottom", _base_bottom - PANEL_HEIGHT, UI_MOTION.duration())
	tw.tween_callback(func() -> void: _animating = false)


func close() -> void:
	if _animating or !visible:
		return
	if editor_area != null:
		_base_bottom = editor_area.base_bottom()
	_animating = true
	var tw := create_tween()
	tw.tween_property(self, "modulate:a", 0.0, UI_MOTION.duration())
	if editor_area != null:
		tw.parallel().tween_property(editor_area, "offset_bottom", _base_bottom, UI_MOTION.duration())
	tw.tween_callback(func() -> void:
		visible = false
		_animating = false
	)
	if editor != null and editor.editor_host != null:
		editor.editor_host.grab_active_focus()


func hide_now() -> void:
	if !visible:
		return
	visible = false
	modulate.a = 0.0
	_animating = false
	if editor_area != null:
		_base_bottom = editor_area.base_bottom()
		editor_area.offset_bottom = _base_bottom


func capture_session() -> Dictionary:
	return {"open": visible, "tab": _current_tab}


func restore_session(data: Dictionary) -> void:
	select_tab(clampi(int(data.get("tab", 0)), 0, 2), false)
	if bool(data.get("open", false)):
		open(_current_tab)


func open_install(help: Dictionary) -> void:
	_forced_install = help.duplicate(true)
	_selected_server = -1
	_dirty = true
	open(1)


func select_tab(index: int, mark_dirty: bool = true) -> void:
	_current_tab = clampi(index, 0, 2)
	if _tabs != null and _tabs.current_tab != _current_tab:
		_tabs.current_tab = _current_tab
	_apply_page()
	if mark_dirty:
		_dirty = true


func _apply_page() -> void:
	for i in range(_pages.size()):
		_pages[i].visible = i == _current_tab
	if _clear_button != null:
		_clear_button.text = "Clear log" if _current_tab == 2 else "Clear"


func _on_tab_changed(index: int) -> void:
	_current_tab = clampi(index, 0, 2)
	_apply_page()
	_dirty = true
	refresh()


func _mark_dirty() -> void:
	_dirty = true


func _on_settings_change() -> void:
	restyle()
	_dirty = true


func _on_missing_server(help: Dictionary) -> void:
	_forced_install = help.duplicate(true)
	_selected_server = -1
	_dirty = true
	# A missing compiler is actionable, not background noise: reveal its card
	# on the Servers tab even when the panel is already open (usually on
	# Problems after a failed edit).
	open(1)


func _on_server_failed(display: String, message: String) -> void:
	if editor != null:
		editor.warn("[color=yellow]LSP[/color]: %s: %s" % [display, message])


# ── REFRESH ─────────────────────────────────────────────────────────────────

func _process(_delta: float) -> void:
	if !visible or !_dirty:
		return
	var now := Time.get_ticks_msec()
	if now - _last_render_msec < int(RENDER_INTERVAL * 1000.0):
		return
	_last_render_msec = now
	refresh()


func refresh() -> void:
	if manager == null or !is_inside_tree():
		return
	_dirty = false
	_update_header()
	if _current_tab == 0:
		_refresh_problems()
	elif _current_tab == 1:
		_refresh_servers()
	else:
		_refresh_log()


func _update_header() -> void:
	if _header_status == null or manager == null:
		return
	var counts: Dictionary = manager.problem_counts()
	var total := int(counts.get("total", 0))
	if total == 0:
		_header_status.text = "No problems"
		_header_status.add_theme_color_override("font_color", _c("comments", Color(0.55, 0.6, 0.65)))
		return
	_header_status.text = "%d error(s) · %d warning(s) · %d total" % [
		int(counts.get("error", 0)), int(counts.get("warning", 0)), total,
	]
	var color := _c("comments", Color(0.55, 0.6, 0.65))
	if int(counts.get("error", 0)) > 0:
		color = _c("error", Color(1.0, 0.4, 0.4))
	elif int(counts.get("warning", 0)) > 0:
		color = _c("variable", Color(0.85, 0.7, 0.3))
	_header_status.add_theme_color_override("font_color", color)


func _refresh_problems() -> void:
	if _problem_list == null:
		return
	var previous := _current_problem_key()
	_problem_items = manager.problem_items()
	var query := _problem_filter.text.strip_edges().to_lower() if _problem_filter != null else ""
	var shown := 0
	_problem_list.clear()

	for item in _problem_items:
		if !(item is Dictionary):
			continue
		var data: Dictionary = item
		if !query.is_empty():
			var haystack := "%s %s %s %s" % [
				str(data.get("file", "")), str(data.get("path", "")),
				str(data.get("message", "")), str(data.get("source", "")),
			]
			if haystack.to_lower().find(query) < 0:
				continue
		var index := _problem_list.item_count
		var text := "%s  %s:%d  %s" % [
			str(data.get("symbol", "•")),
			str(data.get("file", "file")),
			int(data.get("line", 0)) + 1,
			str(data.get("message", "Problem")),
		]
		_problem_list.add_item(text)
		_problem_list.set_item_metadata(index, data)
		_problem_list.set_item_tooltip(index, str(data.get("label", data.get("message", ""))))
		_problem_list.set_item_custom_fg_color(index, _severity_color(int(data.get("severity", 3))))
		shown += 1

	if shown == 0:
		var message := "No problems reported yet. Gutter marks appear as the language server analyzes open files."
		if !query.is_empty():
			message = "No problems match the filter."
		elif _problem_items.is_empty():
			message = "No problems reported. Open a Python, TypeScript, Rust, C/C++ or Go file to start a server."
		_problem_list.add_item(message)
		_problem_list.set_item_disabled(0, true)
		_problem_detail.text = ""
	else:
		# A diagnostics republish rebuilds the list; keep the selection on the
		# same problem instead of jumping back to the top row.
		var restore := 0
		if !previous.is_empty():
			for index in range(_problem_list.item_count):
				var md: Variant = _problem_list.get_item_metadata(index)
				if md is Dictionary and _problem_key_matches(md as Dictionary, previous):
					restore = index
					break
		_problem_list.select(restore)
		_on_problem_selected(restore)

	if _problem_empty != null:
		_problem_empty.text = "" if shown == 0 else "%d problem(s)" % shown


func _current_problem_key() -> Dictionary:
	if _problem_list == null:
		return {}
	var selected := _problem_list.get_selected_items()
	if selected.is_empty():
		return {}
	var md: Variant = _problem_list.get_item_metadata(int(selected[0]))
	if md is Dictionary:
		var data: Dictionary = md
		return {
			"file": str(data.get("file", data.get("path", ""))),
			"line": int(data.get("line", 0)),
			"message": str(data.get("message", "")),
		}
	return {}


func _problem_key_matches(data: Dictionary, key: Dictionary) -> bool:
	return str(data.get("file", data.get("path", ""))) == str(key.get("file", "")) \
		and int(data.get("line", 0)) == int(key.get("line", -1)) \
		and str(data.get("message", "")) == str(key.get("message", ""))


func _on_problem_selected(index: int) -> void:
	var data: Variant = _problem_list.get_item_metadata(index)
	if !(data is Dictionary):
		return
	var item: Dictionary = data
	var lines: Array[String] = []
	lines.append("[b]%s[/b]" % _escape(str(item.get("message", "Problem"))))
	var source := str(item.get("source", ""))
	var code := str(item.get("code", ""))
	if !source.is_empty() or !code.is_empty():
		lines.append("[color=#9aa4b2]%s%s[/color]" % [source, (" · " + code) if !code.is_empty() else ""])
	var path := str(item.get("path", ""))
	lines.append("[color=#9aa4b2]%s:%d[/color]" % [path, int(item.get("line", 0)) + 1])
	var related: Variant = item.get("diagnostic", {})
	if related is Dictionary:
		var info: Variant = (related as Dictionary).get("related_information", [])
		if info is Array and !info.is_empty():
			lines.append("[color=#9aa4b2]%d related location(s)[/color]" % (info as Array).size())
	lines.append("[color=#8bd5ff]Enter or double-click to open the file at that line[/color]")
	_problem_detail.text = "\n".join(lines)


func _on_problem_activated(index: int) -> void:
	var data: Variant = _problem_list.get_item_metadata(index)
	if data is Dictionary and manager != null:
		manager.activate_problem(data)


func _refresh_servers() -> void:
	if _server_list == null or manager == null:
		return
	_server_rows = manager.server_rows()
	var previous := _selected_server
	_server_list.clear()
	for i in range(_server_rows.size()):
		var row: Dictionary = _server_rows[i]
		var symbol := "○"
		var color := _c("comments", Color(0.55, 0.6, 0.65))
		if bool(row.get("ready", false)):
			symbol = "●"
			color = _c("string", Color(0.5, 0.85, 0.55))
		elif bool(row.get("running", false)):
			symbol = "◐"
			color = _c("variable", Color(0.85, 0.7, 0.3))
		elif !bool(row.get("found", false)):
			symbol = "✕"
			color = _c("error", Color(1.0, 0.4, 0.4))
		var status := "ready" if bool(row.get("ready", false)) else ("starting" if bool(row.get("running", false)) else ("found" if bool(row.get("found", false)) else "not installed"))
		var text := "%s  %s — %s" % [symbol, str(row.get("display", row.get("id", ""))), status]
		_server_list.add_item(text)
		_server_list.set_item_custom_fg_color(i, color)
		_server_list.set_item_tooltip(i, str(row.get("command", "")))

	if _server_rows.is_empty():
		_server_list.add_item("No language profiles configured.")
		_server_list.set_item_disabled(0, true)
		_server_detail.text = ""
		_render_install_cards([])
		return

	if previous < 0 or previous >= _server_rows.size():
		previous = 0
		var target := str(_forced_install.get("language", ""))
		if !target.is_empty():
			for i in range(_server_rows.size()):
				if str(_server_rows[i].get("id", "")) == target:
					previous = i
					break
	_server_list.select(previous)
	_selected_server = previous
	_render_server_detail(previous)


func _on_server_selected(index: int) -> void:
	_selected_server = index
	_render_server_detail(index)


func _render_server_detail(index: int) -> void:
	if index < 0 or index >= _server_rows.size():
		return
	var row: Dictionary = _server_rows[index]
	var lines: Array[String] = []
	lines.append("[b]%s[/b]" % _escape(str(row.get("display", row.get("id", "")))))
	var languages: Array = row.get("languages", [])
	if !languages.is_empty():
		lines.append("[color=#9aa4b2]Languages:[/color] " + ", ".join(languages))
	lines.append("[color=#9aa4b2]Command:[/color] " + _escape(str(row.get("command", ""))))
	var args: Array = row.get("args", [])
	if !args.is_empty():
		lines.append("[color=#9aa4b2]Args:[/color] " + _escape(" ".join(args)))
	var markers: Array = row.get("root_markers", [])
	if !markers.is_empty():
		lines.append("[color=#9aa4b2]Root markers:[/color] " + ", ".join(markers))
	var roots: Array = row.get("roots", [])
	if !roots.is_empty():
		lines.append("[color=#9aa4b2]Running in:[/color] " + _escape("\n".join(roots)))
	if !bool(row.get("found", false)):
		lines.append("[color=#f0b45a]The executable is not on PATH.[/color]")
	elif bool(row.get("ready", false)):
		lines.append("[color=#7ecb8b]Running and ready.[/color]")
	elif bool(row.get("running", false)):
		lines.append("[color=#f0b45a]Starting…[/color]")
	else:
		lines.append("[color=#9aa4b2]Found; starts when a matching file is active.[/color]")
	_server_detail.text = "\n".join(lines)

	var cards: Array = []
	if !_forced_install.is_empty():
		cards.append(_forced_install)
		if str(_forced_install.get("language", "")) == str(row.get("language", "")) or !bool(row.get("found", false)):
			_forced_install = {}
	if !bool(row.get("found", false)):
		var install: Variant = row.get("install", {})
		if install is Dictionary and !(install as Dictionary).is_empty():
			cards.append(install)
	if cards.is_empty() and manager != null:
		cards = manager.install_cards()
	_render_install_cards(_dedupe_cards(cards))


## A missing-server notice and the selected row can describe the same server;
## render its install steps once.
func _dedupe_cards(cards: Array) -> Array:
	var out: Array = []
	var seen := {}
	for card in cards:
		if !(card is Dictionary):
			continue
		var key := str(card.get("language", "")) + "|" + str(card.get("title", "")) + "|" + str(card.get("executable", ""))
		if seen.has(key):
			continue
		seen[key] = true
		out.append(card)
	return out


func _render_install_cards(cards: Array) -> void:
	if _install_box == null:
		return
	for child in _install_box.get_children():
		_install_box.remove_child(child)
		child.queue_free()

	if cards.is_empty():
		var idle := Label.new()
		idle.text = "All configured language servers were found. A server starts the first time a matching file becomes active; its output is kept in the Log tab."
		idle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		idle.add_theme_font_size_override("font_size", 11)
		idle.add_theme_color_override("font_color", _c("comments", Color(0.55, 0.6, 0.65)))
		_install_box.add_child(idle)
		return

	for card in cards:
		if !(card is Dictionary):
			continue
		_install_box.add_child(_make_install_card(card))


func _make_install_card(help: Dictionary) -> Control:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = _shade(LuaSingleton.gui.background_color, 0.05)
	style.set_content_margin_all(8)
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.border_width_left = 2
	style.border_color = _c("variable", Color(0.85, 0.7, 0.3))
	panel.add_theme_stylebox_override("panel", style)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	panel.add_child(box)

	var title := Label.new()
	title.text = str(help.get("title", "Install language support"))
	title.add_theme_font_size_override("font_size", 13)
	title.add_theme_color_override("font_color", _c("variable", Color(0.85, 0.7, 0.3)))
	box.add_child(title)

	var hint := Label.new()
	hint.text = str(help.get("hint", ""))
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 11)
	hint.add_theme_color_override("font_color", LuaSingleton.gui.font_color)
	box.add_child(hint)

	var executable := str(help.get("executable", ""))
	if !executable.is_empty():
		var found := Label.new()
		found.text = "Looking for: " + executable
		found.add_theme_font_size_override("font_size", 11)
		found.add_theme_color_override("font_color", _c("comments", Color(0.55, 0.6, 0.65)))
		box.add_child(found)

	var commands: Array = help.get("commands", [])
	for command in commands:
		var text := str(command).strip_edges()
		if text.is_empty():
			continue
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)
		box.add_child(row)
		var label := Label.new()
		label.text = text
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.clip_text = true
		label.tooltip_text = "Run this in a terminal, then restart Qorix (or the servers)."
		label.add_theme_color_override("font_color", _c("string", Color(0.5, 0.85, 0.55)))
		row.add_child(label)
		var copy := Button.new()
		copy.text = "Copy"
		copy.tooltip_text = "Copy this command"
		copy.pressed.connect(func() -> void:
			DisplayServer.clipboard_set(text)
			if editor != null:
				editor.warn("[color=#8bd5ff]LSP[/color]: Install command copied: " + text)
		)
		row.add_child(copy)

	var url := str(help.get("url", ""))
	if !url.is_empty():
		var open := Button.new()
		open.text = str(help.get("url_label", "Open installation guide"))
		open.pressed.connect(func() -> void: OS.shell_open(url))
		box.add_child(open)

	return panel


func _refresh_log() -> void:
	if _log_view == null or manager == null:
		return
	var scroll := _log_scroll.get_v_scroll_bar() if _log_scroll != null else null
	var was_at_bottom := true
	if scroll != null:
		was_at_bottom = scroll.value >= scroll.max_value - scroll.page - 8.0
	_log_view.text = manager.server_log()
	if scroll != null and was_at_bottom:
		call_deferred("_scroll_log_to_bottom")


func _scroll_log_to_bottom() -> void:
	if _log_scroll == null:
		return
	var scroll := _log_scroll.get_v_scroll_bar()
	if scroll != null:
		scroll.value = scroll.max_value


func _on_restart_pressed() -> void:
	if manager != null:
		manager.restart_servers()
		_dirty = true


func _on_clear_pressed() -> void:
	if manager == null:
		return
	if _current_tab == 2:
		manager.clear_log()
	else:
		manager.clear_diagnostics()
	_dirty = true


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

	if _header_status != null:
		_header_status.add_theme_color_override("font_color", _c("comments", Color(0.55, 0.6, 0.65)))
	if _problem_detail != null:
		_problem_detail.add_theme_color_override("default_color", LuaSingleton.gui.font_color)
		_problem_detail.add_theme_font_override("normal_font", _ui_font())
	if _server_detail != null:
		_server_detail.add_theme_color_override("default_color", LuaSingleton.gui.font_color)
		_server_detail.add_theme_font_override("normal_font", _ui_font())
	if _log_view != null:
		_log_view.add_theme_color_override("default_color", LuaSingleton.gui.font_color)
		_log_view.add_theme_font_override("normal_font", _ui_font())
		_log_view.add_theme_font_size_override("normal_font_size", _font_size())
	if _problem_filter != null:
		_problem_filter.add_theme_font_override("font", _ui_font())
	for button in [_restart_button, _clear_button, _close_button]:
		if button != null:
			button.add_theme_font_override("font", _ui_font())
	_style_list(_problem_list)
	_style_list(_server_list)
	_dirty = true


func _style_list(list: ItemList) -> void:
	if list == null:
		return
	list.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	list.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	var selected := StyleBoxFlat.new()
	selected.bg_color = LuaSingleton.gui.selection_color
	selected.set_content_margin_all(2)
	list.add_theme_stylebox_override("selected", selected)
	var font: Color = LuaSingleton.gui.font_color
	var background: Color = LuaSingleton.gui.background_color
	if absf(font.get_luminance() - background.get_luminance()) < 0.22:
		font = Color(0.92, 0.92, 0.92) if background.get_luminance() < 0.5 else Color(0.09, 0.09, 0.09)
	list.add_theme_color_override("font_color", font)
	list.add_theme_color_override("font_selected_color", font)


func _severity_color(severity: int) -> Color:
	match severity:
		1: return _c("error", Color(1.0, 0.4, 0.4))
		2: return _c("variable", Color(0.85, 0.7, 0.3))
		3: return _c("function", Color(0.4, 0.75, 1.0))
		4: return _c("comments", Color(0.55, 0.6, 0.65))
	return _c("comments", Color(0.55, 0.6, 0.65))


func _ui_font() -> Font:
	if LuaSingleton.editor_theme != null:
		return LuaSingleton.editor_theme.get_font("font", "MyType")
	return ThemeDB.fallback_font


func _font_size() -> int:
	var size := 12
	var found = LuaSingleton.get_setting("editor_font_size")
	if found is Array and found.size() >= 2 and int(found[1]) != -1:
		size = clampi(int(found[0].get("value", size)) - 4, 9, 24)
	return size


func _c(key: String, fallback: Color) -> Color:
	var value: Variant = LuaSingleton.keywords.get(key)
	if value is Color and (value as Color).a > 0.0:
		return value
	return fallback


func _shade(color: Color, amount: float) -> Color:
	var light := color.get_luminance() > 0.5
	return color.lightened(amount) if light else color.darkened(amount)


func _escape(text: String) -> String:
	return str(text).replace("[", "[lb]")
