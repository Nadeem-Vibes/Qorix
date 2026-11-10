extends PanelContainer

const UI_MOTION = preload("res://src/platform/ui_motion.gd")

## Bottom dock for one debug session: transport controls, Variables / Watch,
## Call Stack and the Debug Console.
##
## The panel never talks to the adapter. DapManager owns the session and emits
## state; this script renders it and forwards clicks. That keeps a paused
## program inspectable while the dock is closed and makes the UI replaceable.

const PANEL_HEIGHT := 386.0
const RENDER_INTERVAL := 0.10
const MAX_TREE_ITEMS := 1200
const CONSOLE_HISTORY_LIMIT := 60

var editor = null
var manager = null
var editor_area: Control

var _header_status: Label
var _start_button: Button
var _over_button: Button
var _into_button: Button
var _out_button: Button
var _stop_button: Button
var _clear_console_button: Button
var _close_button: Button

var _tabs: TabBar
var _variables_page: VBoxContainer
var _watch_page: VBoxContainer
var _variables_tree: Tree
var _watch_tree: Tree
var _watch_input: LineEdit
var _watch_add_button: Button
var _watch_remove_button: Button
var _watch_refresh_button: Button
var _stack_list: ItemList
var _console_view: RichTextLabel
var _console_scroll: ScrollContainer
var _prompt: LineEdit
var _install_box: VBoxContainer

var _pages: Array[Control] = []
var _current_tab: int = 0
var _base_bottom: float = 0.0
var _animating: bool = false
var _dirty: bool = true
var _last_render_msec: int = 0

var _install_help: Dictionary = {}
var _selected_watch: int = -1
var _expanded_refs: Dictionary = {}
var _collapsed_refs: Dictionary = {}
var _tree_item_budget: int = 0
var _building_stack: bool = false
var _tracked_refs: Array = []          # [TreeItem, variablesReference, label]
var _last_expand_poll_msec: int = 0
var _pending_expansion: Dictionary = {}
var _last_state: String = "idle"
var _base_position := Vector2.ZERO

var _history: Array[String] = []
var _history_index: int = 0


func _ready() -> void:
	editor = _find_editor()
	if editor == null:
		return
	manager = editor.dap_manager
	editor_area = editor.editor_host
	_base_bottom = editor_area.offset_bottom if editor_area != null else 0.0

	theme = LuaSingleton.editor_theme
	visible = false
	modulate.a = 0.0
	set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	offset_top = -PANEL_HEIGHT
	offset_bottom = 0
	_base_position = position

	_build_ui()
	_connect_manager()
	LuaSingleton.on_theme_load.connect(restyle)
	LuaSingleton.on_settings_change.connect(_on_settings_change)
	restyle()
	_update_buttons()
	_render()


func _find_editor() -> FileManager:
	var node = get_parent()
	while node != null and !(node is FileManager):
		node = node.get_parent()
	return node


func _connect_manager() -> void:
	if manager == null:
		return
	manager.state_changed.connect(_on_state_changed)
	manager.log_updated.connect(_mark_dirty)
	manager.breakpoints_changed.connect(_mark_dirty)
	manager.session_started.connect(_on_session_started)
	manager.session_ended.connect(_on_session_ended)
	manager.missing_adapter.connect(_on_missing_adapter)


# ── UI ──────────────────────────────────────────────────────────────────────

func _build_ui() -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	add_child(box)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 6)
	box.add_child(header)

	var title := Label.new()
	title.text = "Debug"
	title.add_theme_font_size_override("font_size", 14)
	header.add_child(title)

	_start_button = _make_button("▶ Start", "Start a debug session (Ctrl+F5). Paused sessions continue instead.")
	_start_button.pressed.connect(_start_pressed)
	header.add_child(_start_button)

	_over_button = _make_button("Step Over", "Run the current line and stop on the next one (F10).")
	_over_button.pressed.connect(_step_over_pressed)
	header.add_child(_over_button)

	_into_button = _make_button("Step Into", "Step into the function on this line (F11).")
	_into_button.pressed.connect(_step_into_pressed)
	header.add_child(_into_button)

	_out_button = _make_button("Step Out", "Run until the current function returns (Shift+F11).")
	_out_button.pressed.connect(_step_out_pressed)
	header.add_child(_out_button)

	_stop_button = _make_button("■ Stop", "Stop the debug session (Ctrl+Shift+F5).")
	_stop_button.pressed.connect(_stop_pressed)
	header.add_child(_stop_button)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)

	_header_status = Label.new()
	_header_status.text = "Ready"
	_header_status.clip_text = true
	_header_status.custom_minimum_size = Vector2(250, 0)
	_header_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	header.add_child(_header_status)

	_clear_console_button = _make_button("Clear Console", "Clear the Debug Console output.")
	_clear_console_button.pressed.connect(_clear_console_pressed)
	header.add_child(_clear_console_button)

	_close_button = _make_button("✕", "Close the Debugger panel (the session keeps running).")
	_close_button.pressed.connect(close)
	header.add_child(_close_button)

	_install_box = VBoxContainer.new()
	_install_box.visible = false
	_install_box.add_theme_constant_override("separation", 3)
	box.add_child(_install_box)

	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.split_offset = 360
	box.add_child(split)

	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(290, 0)
	left.add_theme_constant_override("separation", 3)
	split.add_child(left)

	_tabs = TabBar.new()
	_tabs.add_tab("Variables")
	_tabs.add_tab("Watch")
	_tabs.current_tab = 0
	_tabs.tab_changed.connect(_on_tab_changed)
	left.add_child(_tabs)

	_variables_page = VBoxContainer.new()
	_variables_page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.add_child(_variables_page)
	_variables_tree = _make_tree()
	_variables_tree.item_collapsed.connect(_on_variables_collapsed)
	_variables_page.add_child(_variables_tree)

	_watch_page = VBoxContainer.new()
	_watch_page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_watch_page.add_theme_constant_override("separation", 3)
	left.add_child(_watch_page)

	var watch_row := HBoxContainer.new()
	watch_row.add_theme_constant_override("separation", 4)
	_watch_page.add_child(watch_row)

	_watch_input = LineEdit.new()
	_watch_input.placeholder_text = "Watch expression…"
	_watch_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_watch_input.text_submitted.connect(_on_watch_submitted)
	watch_row.add_child(_watch_input)

	_watch_add_button = _make_button("Add", "Add this expression to the watch list.")
	_watch_add_button.pressed.connect(_add_watch_from_input)
	watch_row.add_child(_watch_add_button)

	_watch_tree = _make_tree()
	_watch_tree.item_selected.connect(_on_watch_selected)
	_watch_tree.item_collapsed.connect(_on_watch_collapsed)
	_watch_page.add_child(_watch_tree)

	var watch_actions := HBoxContainer.new()
	watch_actions.add_theme_constant_override("separation", 4)
	_watch_page.add_child(watch_actions)

	_watch_remove_button = _make_button("Remove", "Remove the selected watch expression.")
	_watch_remove_button.disabled = true
	_watch_remove_button.pressed.connect(_remove_selected_watch)
	watch_actions.add_child(_watch_remove_button)

	_watch_refresh_button = _make_button("Refresh", "Evaluate every watch expression again while paused.")
	_watch_refresh_button.pressed.connect(_refresh_watches)
	watch_actions.add_child(_watch_refresh_button)

	_pages = [_variables_page, _watch_page]
	_apply_page()

	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 3)
	split.add_child(right)

	var stack_title := Label.new()
	stack_title.text = "Call Stack"
	stack_title.add_theme_font_size_override("font_size", 12)
	right.add_child(stack_title)

	_stack_list = ItemList.new()
	_stack_list.custom_minimum_size = Vector2(0, 92)
	_stack_list.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_stack_list.item_selected.connect(_on_stack_selected)
	right.add_child(_stack_list)

	var console_title := Label.new()
	console_title.text = "Debug Console"
	console_title.add_theme_font_size_override("font_size", 12)
	right.add_child(console_title)

	_console_scroll = ScrollContainer.new()
	_console_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_console_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right.add_child(_console_scroll)

	_console_view = RichTextLabel.new()
	_console_view.bbcode_enabled = true
	_console_view.fit_content = true
	_console_view.scroll_active = false
	_console_view.selection_enabled = true
	_console_view.context_menu_enabled = true
	_console_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_console_view.custom_minimum_size = Vector2(0, 120)
	_console_scroll.add_child(_console_view)

	_prompt = LineEdit.new()
	_prompt.placeholder_text = "Evaluate an expression while paused…"
	_prompt.editable = false
	_prompt.text_submitted.connect(_on_prompt_submitted)
	_prompt.gui_input.connect(_on_prompt_input)
	right.add_child(_prompt)


func _make_button(text: String, tooltip: String) -> Button:
	var button := Button.new()
	button.text = text
	button.tooltip_text = tooltip
	button.focus_mode = Control.FOCUS_NONE
	return button


func _make_tree() -> Tree:
	var tree := Tree.new()
	tree.hide_root = true
	tree.columns = 2
	tree.column_titles_visible = true
	tree.set_column_title(0, "Name")
	tree.set_column_title(1, "Value")
	tree.set_column_expand(0, true)
	tree.set_column_expand(1, true)
	tree.set_column_custom_minimum_width(0, 120)
	tree.set_column_custom_minimum_width(1, 150)
	tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tree.select_mode = Tree.SELECT_ROW
	return tree


func _apply_page() -> void:
	for index in range(_pages.size()):
		_pages[index].visible = index == _current_tab


func _on_tab_changed(index: int) -> void:
	_current_tab = clampi(index, 0, _pages.size() - 1)
	_apply_page()
	_dirty = true
	_render()


# ── LIFECYCLE ───────────────────────────────────────────────────────────────

func toggle() -> void:
	if visible:
		close()
	else:
		open(_current_tab)


func open(tab: int = -1) -> void:
	if tab >= 0:
		select_tab(tab)
	if visible:
		_render()
		return

	if editor != null:
		if editor.terminal != null and editor.terminal.visible and editor.terminal.has_method("hide_now"):
			editor.terminal.hide_now()
		if editor.output_panel != null and editor.output_panel.visible and editor.output_panel.has_method("hide_now"):
			editor.output_panel.hide_now()
		if editor.lsp_panel != null and editor.lsp_panel.visible and editor.lsp_panel.has_method("hide_now"):
			editor.lsp_panel.hide_now()

	if editor_area != null:
		_base_bottom = editor_area.base_bottom()
	_dirty = true
	_animating = true
	visible = true
	position = _base_position + Vector2(0, 6)
	_render()

	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(self, "modulate:a", 1.0, UI_MOTION.duration(0.2))
	tw.tween_property(self, "position", _base_position, UI_MOTION.duration(0.2))
	if editor_area != null:
		tw.tween_property(editor_area, "offset_bottom", _base_bottom - PANEL_HEIGHT, UI_MOTION.duration(0.2))
	tw.chain()
	tw.tween_callback(func() -> void: _animating = false)


func close() -> void:
	if _animating or !visible:
		return
	if editor_area != null:
		_base_bottom = editor_area.base_bottom()
	_animating = true
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(self, "modulate:a", 0.0, UI_MOTION.duration(0.2))
	tw.tween_property(self, "position", _base_position + Vector2(0, 6), UI_MOTION.duration(0.2))
	if editor_area != null:
		tw.tween_property(editor_area, "offset_bottom", _base_bottom, UI_MOTION.duration(0.2))
	tw.chain()
	tw.tween_callback(func() -> void:
		visible = false
		position = _base_position
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


func select_tab(index: int) -> void:
	_current_tab = clampi(index, 0, _pages.size() - 1)
	if _tabs != null and _tabs.current_tab != _current_tab:
		_tabs.current_tab = _current_tab
	_apply_page()
	_dirty = true


## Focuses the Debug Console prompt for the "Evaluate" command.
func focus_console() -> void:
	if _prompt == null:
		return
	select_tab(0)
	_dirty = true
	_render()
	_prompt.grab_focus()


func capture_session() -> Dictionary:
	var data: Dictionary = manager.capture_session() if manager != null else {}
	data["open"] = visible
	data["tab"] = _current_tab
	return data


func restore_session(data: Dictionary) -> void:
	if manager != null and !data.is_empty():
		manager.restore_session(data)
	_current_tab = clampi(int(data.get("tab", 0)), 0, maxi(_pages.size() - 1, 0))
	if _tabs != null:
		_tabs.current_tab = _current_tab
	_apply_page()
	if bool(data.get("open", false)):
		open(_current_tab)


# ── MANAGER SIGNALS ─────────────────────────────────────────────────────────

func _on_state_changed() -> void:
	var current := str(manager.state) if manager != null else "idle"
	if _header_status != null and current != _last_state and UI_MOTION.feedback_allowed():
		_header_status.modulate.a = 0.65
		var state_tween := create_tween()
		state_tween.tween_property(_header_status, "modulate:a", 1.0, UI_MOTION.feedback_duration(0.18))
	# A new pause can reuse adapter reference numbers for different values, so
	# expansion state is only meaningful within one stop.
	if current == "stopped" and _last_state != "stopped":
		_expanded_refs.clear()
		_collapsed_refs.clear()
		_pending_expansion.clear()
	_last_state = current
	_update_buttons()
	_dirty = true


func _on_session_started(_info: Dictionary) -> void:
	_install_help = {}
	_clear_install_card()
	open()
	_dirty = true
	_render()


func _on_session_ended(_info: Dictionary) -> void:
	_dirty = true
	_update_buttons()
	_render()


func _on_missing_adapter(help: Dictionary) -> void:
	_install_help = help.duplicate(true)
	_render_install_card()
	open(0)


func _on_settings_change() -> void:
	restyle()
	_dirty = true


func _mark_dirty() -> void:
	_dirty = true


# ── TOOLBAR ─────────────────────────────────────────────────────────────────

func _start_pressed() -> void:
	if manager == null:
		return
	if manager.is_stopped():
		manager.continue_execution()
	else:
		manager.start_debugging()


func _stop_pressed() -> void:
	if manager != null:
		manager.stop_debugging()


func _step_over_pressed() -> void:
	if manager != null:
		manager.step_over()


func _step_into_pressed() -> void:
	if manager != null:
		manager.step_into()


func _step_out_pressed() -> void:
	if manager != null:
		manager.step_out()


func _clear_console_pressed() -> void:
	if manager != null:
		manager.clear_console()
		_dirty = true


func _update_buttons() -> void:
	if manager == null:
		for button in [_start_button, _over_button, _into_button, _out_button, _stop_button]:
			if button != null:
				button.disabled = true
		return
	var state := str(manager.state)
	var stopped := state == "stopped"
	var active: bool = manager.is_active()
	var busy := state == "starting" or state == "initializing" or state == "running" or state == "terminating"

	if _start_button != null:
		_start_button.disabled = busy
		_start_button.text = "Continue" if stopped else ("Starting…" if state == "starting" or state == "initializing" else ("Running" if state == "running" else ("Stopping…" if state == "terminating" else "▶ Start")))
	for button in [_over_button, _into_button, _out_button]:
		if button != null:
			button.disabled = !stopped
	if _stop_button != null:
		_stop_button.disabled = !active and state != "terminating"
	if _prompt != null:
		_prompt.editable = stopped
		_prompt.placeholder_text = "Evaluate an expression…" if stopped else "Pause at a breakpoint to evaluate expressions…"


# ── RENDERING ───────────────────────────────────────────────────────────────

func _process(_delta: float) -> void:
	if !visible:
		return
	var now := Time.get_ticks_msec()
	if now - _last_expand_poll_msec >= 150:
		_last_expand_poll_msec = now
		_poll_expanded_variables()
	if !_dirty:
		return
	if now - _last_render_msec < int(RENDER_INTERVAL * 1000.0):
		return
	_last_render_msec = now
	_render()


func _render() -> void:
	if _variables_tree == null:
		return
	_dirty = false
	_tracked_refs.clear()
	_update_buttons()
	_update_status()
	_render_variables()
	_render_watches()
	_render_stack()
	_render_console()


func _update_status() -> void:
	if _header_status == null:
		return
	if manager == null:
		_header_status.text = "Debugger unavailable"
		return
	_header_status.text = manager.status_text()
	_header_status.tooltip_text = manager.last_error
	var color := _c("comments", Color(0.55, 0.6, 0.65))
	if manager.is_stopped():
		var reason := str(manager.stop_reason)
		color = _c("error", Color(1.0, 0.4, 0.4)) if reason == "exception" else _c("variable", Color(0.85, 0.7, 0.3))
	elif manager.is_running():
		color = _c("string", Color(0.5, 0.85, 0.55))
	elif manager.state == "starting" or manager.state == "initializing":
		color = _c("function", Color(0.4, 0.75, 1.0))
	_header_status.add_theme_color_override("font_color", color)


func _render_variables() -> void:
	if _variables_tree == null:
		return
	_variables_tree.clear()
	_tree_item_budget = MAX_TREE_ITEMS
	var root := _variables_tree.create_item()
	if manager == null or !manager.is_stopped():
		var hint := _variables_tree.create_item(root)
		hint.set_text(0, "Start debugging and pause at a breakpoint to inspect variables.")
		hint.set_custom_color(0, _c("comments", Color(0.55, 0.6, 0.65)))
		hint.set_selectable(0, false)
		return

	var scopes: Array = manager.scope_items()
	if scopes.is_empty():
		var empty := _variables_tree.create_item(root)
		empty.set_text(0, "The adapter returned no variable scopes.")
		empty.set_custom_color(0, _c("comments", Color(0.55, 0.6, 0.65)))
		empty.set_selectable(0, false)
		return

	for scope in scopes:
		if !(scope is Dictionary):
			continue
		var reference := int(scope.get("variables_reference", 0))
		var item := _variables_tree.create_item(root)
		item.set_text(0, str(scope.get("name", "Scope")))
		item.set_text(1, "")
		item.set_metadata(0, {"reference": reference})
		item.set_custom_color(0, _c("function", Color(0.4, 0.75, 1.0)))
		item.collapsed = _collapsed_refs.has(reference)
		if reference > 0:
			_add_variable_children(_variables_tree, item, reference, 0)


func _add_variable_children(tree: Tree, parent: TreeItem, reference: int, depth: int) -> void:
	if reference <= 0 or manager == null or depth > 5:
		return
	var rows: Array = manager.variables_for(reference)
	if rows.is_empty():
		return
	for row in rows:
		if _tree_item_budget <= 0 or !(row is Dictionary):
			return
		_tree_item_budget -= 1
		var child_ref := int(row.get("variables_reference", 0))
		var item := tree.create_item(parent)
		item.set_text(0, str(row.get("name", "")))
		var value := str(row.get("value", ""))
		var type := str(row.get("type", ""))
		if !type.is_empty():
			value += "  [" + type + "]"
		item.set_text(1, value)
		item.set_tooltip_text(1, value)
		item.set_metadata(0, {"reference": child_ref})
		if child_ref > 0:
			_tracked_refs.append([item, child_ref])
			if _expanded_refs.has(child_ref):
				_add_variable_children(tree, item, child_ref, depth + 1)
			else:
				# A dummy child is what makes the expand arrow appear. Expanding
				# asks the adapter for this reference and rebuilds the tree.
				var placeholder := tree.create_item(item)
				placeholder.set_text(0, "…")
				placeholder.set_selectable(0, false)
				placeholder.set_custom_color(0, _c("comments", Color(0.55, 0.6, 0.65)))
				item.collapsed = !_expanded_refs.has(child_ref)


func _on_variables_collapsed(item: TreeItem) -> void:
	_on_reference_collapsed(item)


func _on_watch_collapsed(item: TreeItem) -> void:
	_on_reference_collapsed(item)


func _on_reference_collapsed(item: TreeItem) -> void:
	if item == null:
		return
	var meta: Variant = item.get_metadata(0)
	if meta is Dictionary:
		var reference := int((meta as Dictionary).get("reference", 0))
		if reference <= 0:
			return
		# Tree.item_collapsed fires for BOTH expand and collapse, and also for
		# programmatic collapsed assignments. Branch on the real state instead
		# of assuming the worst: recording an expand as a collapse is what made
		# a quick re-render re-fold a variable the user had just opened.
		if item.is_collapsed():
			_collapsed_refs[reference] = true
			_expanded_refs.erase(reference)
		else:
			_collapsed_refs.erase(reference)
			_expanded_refs[reference] = true
			if manager != null and manager.variables_for(reference).is_empty() \
					and !_pending_expansion.has(reference):
				_pending_expansion[reference] = true
				manager.request_variables(reference)
			_dirty = true


## Tree.item_collapsed reports both expand and collapse and is the primary
## signal (see _on_reference_collapsed). This light poll is the safety net:
## it notices an item the user opened whose flag bookkeeping fell behind and
## asks the adapter for its children.
func _poll_expanded_variables() -> void:
	if manager == null or !manager.is_stopped():
		return
	for tracked in _tracked_refs:
		if !(tracked is Array) or (tracked as Array).size() < 2:
			continue
		var item: Variant = tracked[0]
		var reference := int(tracked[1])
		if !is_instance_valid(item) or reference <= 0:
			continue
		if (item as TreeItem).is_collapsed():
			continue
		if _collapsed_refs.has(reference):
			_collapsed_refs.erase(reference)
			_expanded_refs[reference] = true
			_dirty = true
		if _expanded_refs.has(reference) and manager.variables_for(reference).is_empty() and !_pending_expansion.has(reference):
			_pending_expansion[reference] = true
			_expanded_refs[reference] = true
			manager.request_variables(reference)


func _render_watches() -> void:
	if _watch_tree == null:
		return
	_watch_tree.clear()
	_tree_item_budget = MAX_TREE_ITEMS
	var root := _watch_tree.create_item()
	if manager == null:
		return
	var rows: Array = manager.watch_items()
	if rows.is_empty():
		var hint := _watch_tree.create_item(root)
		hint.set_text(0, "No watch expressions. Add one above.")
		hint.set_custom_color(0, _c("comments", Color(0.55, 0.6, 0.65)))
		hint.set_selectable(0, false)
		return

	var selected_item: TreeItem = null
	for index in range(rows.size()):
		var row: Dictionary = rows[index]
		var item := _watch_tree.create_item(root)
		item.set_text(0, str(row.get("expression", "")))
		var value := ""
		var color := _c("font", LuaSingleton.gui.font_color)
		if bool(row.get("pending", false)):
			value = "evaluating…"
			color = _c("comments", Color(0.55, 0.6, 0.65))
		elif !bool(row.get("ok", false)):
			value = str(row.get("error", "not available"))
			color = _c("error", Color(1.0, 0.4, 0.4))
		else:
			value = str(row.get("value", ""))
			var type := str(row.get("type", ""))
			if !type.is_empty():
				value += "  [" + type + "]"
			color = _c("string", Color(0.5, 0.85, 0.55))
		item.set_text(1, value)
		item.set_custom_color(1, color)
		item.set_metadata(0, {"watch": index, "reference": int(row.get("variables_reference", 0))})
		if int(row.get("variables_reference", 0)) > 0:
			_tracked_refs.append([item, int(row.get("variables_reference", 0))])
			var placeholder := _watch_tree.create_item(item)
			placeholder.set_text(0, "…")
			placeholder.set_selectable(0, false)
			placeholder.set_custom_color(0, _c("comments", Color(0.55, 0.6, 0.65)))
		if index == _selected_watch:
			selected_item = item
	if selected_item != null:
		selected_item.select(0)
	else:
		_selected_watch = -1
	_update_watch_buttons()


func _update_watch_buttons() -> void:
	if _watch_remove_button != null:
		_watch_remove_button.disabled = _selected_watch < 0 or manager == null or _selected_watch >= manager.watches.size()
	if _watch_refresh_button != null:
		_watch_refresh_button.disabled = manager == null or !manager.is_stopped() or manager.watches.is_empty()


func _render_stack() -> void:
	if _stack_list == null:
		return
	_building_stack = true
	_stack_list.clear()
	var rows: Array = manager.frame_items() if manager != null else []
	if rows.is_empty():
		_stack_list.add_item("No paused call stack.")
		_stack_list.set_item_disabled(0, true)
		_building_stack = false
		return
	for row in rows:
		var index := _stack_list.item_count
		var text := "%s — %s:%d" % [
			str(row.get("name", "?")), str(row.get("file", "")), int(row.get("line", 1)),
		]
		_stack_list.add_item(text)
		_stack_list.set_item_metadata(index, int(row.get("index", index)))
		if bool(row.get("selected", false)):
			_stack_list.select(index)
	_building_stack = false


func _render_console() -> void:
	if _console_view == null:
		return
	if manager == null:
		_console_view.text = _console_empty("Debugger unavailable.")
		return
	var entries: Array = manager.console_entries_copy()
	if entries.is_empty():
		_console_view.text = _console_empty("Output from the program and the debug adapter appears here.")
		return
	var text := ""
	for entry in entries:
		if !(entry is Dictionary):
			continue
		var kind := str(entry.get("kind", "output"))
		var body := str(entry.get("text", ""))
		if body.is_empty():
			continue
		text += "[color=%s]%s[/color]" % [_console_color(kind), _escape_bbcode(body)]
	_console_view.text = text
	_scroll_console_to_bottom()


func _console_color(kind: String) -> String:
	match kind:
		"input":
			return _c("function", Color(0.4, 0.75, 1.0))
		"result":
			return _c("string", Color(0.5, 0.85, 0.55))
		"error":
			return _c("error", Color(1.0, 0.4, 0.4))
		"system":
			return _c("comments", Color(0.55, 0.6, 0.65))
	return _c("font", LuaSingleton.gui.font_color)


func _console_empty(message: String) -> String:
	return "[color=%s]%s[/color]" % [_c("comments", Color(0.55, 0.6, 0.65)), _escape_bbcode(message)]


func _scroll_console_to_bottom() -> void:
	if _console_scroll == null:
		return
	await get_tree().process_frame
	if _console_scroll == null:
		return
	var bar := _console_scroll.get_v_scroll_bar()
	_console_scroll.scroll_vertical = int(bar.max_value)


# ── CONSOLE / WATCH ACTIONS ─────────────────────────────────────────────────

func _on_prompt_submitted(text: String) -> void:
	var expression := text.strip_edges()
	if expression.is_empty() or manager == null:
		return
	_history.append(expression)
	if _history.size() > CONSOLE_HISTORY_LIMIT:
		_history.pop_front()
	_history_index = _history.size()
	_prompt.text = ""
	manager.evaluate(expression)
	_prompt.grab_focus()


func _on_prompt_input(event: InputEvent) -> void:
	if !(event is InputEventKey) or !event.pressed:
		return
	var key := (event as InputEventKey).keycode
	if key == KEY_UP and !_history.is_empty():
		_history_index = maxi(_history_index - 1, 0)
		_prompt.text = _history[_history_index]
		_prompt.caret_column = _prompt.text.length()
		get_viewport().set_input_as_handled()
	elif key == KEY_DOWN and !_history.is_empty():
		_history_index = mini(_history_index + 1, _history.size())
		_prompt.text = _history[_history_index] if _history_index < _history.size() else ""
		_prompt.caret_column = _prompt.text.length()
		get_viewport().set_input_as_handled()


func _on_watch_submitted(text: String) -> void:
	_add_watch(text)


func _add_watch_from_input() -> void:
	if _watch_input != null:
		_add_watch(_watch_input.text)


func _add_watch(text: String) -> void:
	if manager == null:
		return
	var expression := text.strip_edges()
	if expression.is_empty():
		return
	if !manager.add_watch(expression):
		if editor != null:
			editor.warn("[color=yellow]DEBUG[/color]: \"%s\" is already watched." % expression)
		return
	if _watch_input != null:
		_watch_input.text = ""
	_dirty = true
	_render()


func _on_watch_selected() -> void:
	var items: PackedInt32Array = _watch_tree.get_selected_items()
	if items.is_empty():
		_selected_watch = -1
	else:
		var item := _watch_tree.get_selected()
		var meta: Variant = item.get_metadata(0) if item != null else null
		_selected_watch = int((meta as Dictionary).get("watch", -1)) if meta is Dictionary else -1
	_update_watch_buttons()


func _remove_selected_watch() -> void:
	if manager == null or _selected_watch < 0:
		return
	manager.remove_watch(_selected_watch)
	_selected_watch = -1
	_dirty = true
	_render()


func _refresh_watches() -> void:
	if manager != null:
		manager.refresh_watches_now()
		_dirty = true


func _on_stack_selected(index: int) -> void:
	if UI_MOTION.feedback_allowed() and _stack_list != null:
		_stack_list.modulate.a = 0.75
		var tween := create_tween()
		tween.tween_property(_stack_list, "modulate:a", 1.0, UI_MOTION.feedback_duration(0.12))
	if _building_stack or manager == null:
		return
	var rows: Array = manager.frame_items()
	if index >= 0 and index < rows.size():
		manager.select_frame(int(rows[index].get("index", index)))


# ── INSTALL CARD ────────────────────────────────────────────────────────────

func _render_install_card() -> void:
	_clear_install_card()
	if _install_help.is_empty() or _install_box == null:
		return
	_install_box.visible = true

	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = _shade(LuaSingleton.gui.background_color, 0.06)
	style.set_content_margin_all(7)
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.border_width_left = 2
	style.border_color = _c("variable", Color(0.85, 0.7, 0.3))
	panel.add_theme_stylebox_override("panel", style)
	_install_box.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 3)
	panel.add_child(box)

	var title := Label.new()
	title.text = str(_install_help.get("title", "Debug adapter not available"))
	title.add_theme_color_override("font_color", _c("variable", Color(0.85, 0.7, 0.3)))
	box.add_child(title)

	var hint := Label.new()
	hint.text = str(_install_help.get("hint", ""))
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 11)
	box.add_child(hint)

	var commands: Array = _install_help.get("commands", [])
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
		label.add_theme_color_override("font_color", _c("string", Color(0.5, 0.85, 0.55)))
		row.add_child(label)
		var copy := _make_button("Copy", "Copy this command to the clipboard.")
		copy.pressed.connect(func() -> void:
			DisplayServer.clipboard_set(text)
			if editor != null:
				editor.warn("[color=#8bd5ff]DEBUG[/color]: Install command copied: " + text)
		)
		row.add_child(copy)

	var url := str(_install_help.get("url", ""))
	if !url.is_empty():
		var open_button := _make_button(str(_install_help.get("url_label", "Open install page")), url)
		open_button.pressed.connect(func() -> void: OS.shell_open(url))
		box.add_child(open_button)


func _clear_install_card() -> void:
	if _install_box == null:
		return
	for child in _install_box.get_children():
		_install_box.remove_child(child)
		child.queue_free()
	_install_box.visible = false


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

	var font := _ui_font()
	var font_size := _font_size()
	for button in [_start_button, _over_button, _into_button, _out_button, _stop_button,
			_clear_console_button, _close_button, _watch_add_button, _watch_remove_button,
			_watch_refresh_button]:
		if button != null:
			button.add_theme_font_override("font", font)
	for line_edit in [_watch_input, _prompt]:
		if line_edit != null:
			line_edit.add_theme_font_override("font", font)
			line_edit.add_theme_font_size_override("font_size", font_size)
	if _tabs != null:
		_tabs.add_theme_font_override("font", font)
		_tabs.add_theme_font_size_override("font_size", font_size)
		_tabs.add_theme_color_override("font_selected_color", _c("function", Color(0.4, 0.75, 1.0)))
	if _console_view != null:
		_console_view.add_theme_font_override("normal_font", font)
		_console_view.add_theme_font_override("bold_font", font)
		_console_view.add_theme_font_override("mono_font", font)
		_console_view.add_theme_font_size_override("normal_font_size", font_size)
		_console_view.add_theme_font_size_override("bold_font_size", font_size)
		_console_view.add_theme_color_override("default_color", LuaSingleton.gui.font_color)
	for tree in [_variables_tree, _watch_tree]:
		_style_tree(tree, font, font_size)
	_style_list(_stack_list, font, font_size)
	if _header_status != null:
		_header_status.add_theme_font_override("font", font)
	_dirty = true


func _style_tree(tree: Tree, font: Font, font_size: int) -> void:
	if tree == null:
		return
	tree.add_theme_font_override("font", font)
	tree.add_theme_font_size_override("font_size", font_size)
	tree.add_theme_color_override("font_color", LuaSingleton.gui.font_color)
	tree.add_theme_color_override("font_selected_color", LuaSingleton.gui.font_color)
	tree.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	tree.add_theme_stylebox_override("selected", StyleBoxEmpty.new())
	var selected := StyleBoxFlat.new()
	selected.bg_color = LuaSingleton.gui.selection_color
	selected.set_content_margin_all(1)
	tree.add_theme_stylebox_override("selected_focus", selected)
	var guide: Color = LuaSingleton.gui.current_line_color
	guide.a = 0.5
	tree.add_theme_color_override("guide_color", guide)


func _style_list(list: ItemList, font: Font, font_size: int) -> void:
	if list == null:
		return
	list.add_theme_font_override("font", font)
	list.add_theme_font_size_override("font_size", font_size)
	list.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	list.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	var selected := StyleBoxFlat.new()
	selected.bg_color = LuaSingleton.gui.selection_color
	selected.set_content_margin_all(2)
	list.add_theme_stylebox_override("selected", selected)
	list.add_theme_color_override("font_color", LuaSingleton.gui.font_color)
	list.add_theme_color_override("font_selected_color", LuaSingleton.gui.font_color)


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


func _c(key: String, fallback: Color) -> String:
	var palette: Dictionary = LuaSingleton.keywords
	if palette.has(key):
		var color: Color = palette[key]
		if color.a > 0.0:
			return "#" + color.to_html(false)
	return "#" + fallback.to_html(false)


func _shade(color: Color, amount: float) -> Color:
	return color.lightened(amount) if color.get_luminance() > 0.5 else color.darkened(amount)


func _escape_bbcode(text: String) -> String:
	return text.replace("[", "[lb]")
