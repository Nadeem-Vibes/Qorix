extends PanelContainer

# Prompt panel (HUD): Ctrl+P quick-open by file name, Ctrl+Shift+P command
# palette. One panel, two modes — both drive the same type → filter → Enter
# run flow. Pure HUD: fade in place (toggle(node, false, 0)), never slides,
# never dims the code.

const MAX_SHOWN = 300

# Explicit preload rather than the global `FuzzyMatch` name: this keeps the
# panel loadable even when the editor's global class cache is stale.
const Fuzzy = preload("res://src/base/fuzzy_match.gd")
const UI_MOTION = preload("res://src/platform/ui_motion.gd")

var editor: FileManager

var prompt: LineEdit
var list: ItemList
var status: Label

var items: Array = []      # [{label, path}] for files, [{label, cb}] for commands
var filtered: Array = []   # subset of items, each with a "score"
var selected: int = 0
var mode: String = ""      # "files" / "commands"
var _base_position := Vector2.ZERO
var _tween: Tween

func _ready() -> void:
	editor = _find_editor()

	theme = LuaSingleton.editor_theme
	visible = false
	modulate.a = 0.0

	set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	offset_left = -360
	offset_right = 360
	offset_top = 68
	# The panel must have a real height: a zero-height PanelContainer draws no
	# backdrop and the list rows would float straight on top of the code.
	# 6px content margin + prompt row + separation + 300px list + 6px bottom.
	offset_bottom = 424
	_base_position = position

	var box = VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	add_child(box)

	var row = HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	box.add_child(row)

	prompt = LineEdit.new()
	prompt.custom_minimum_size = Vector2(430, 0)
	prompt.text_changed.connect(_on_prompt_changed)
	prompt.text_submitted.connect(func(_t): confirm())
	row.add_child(prompt)

	status = Label.new()
	row.add_child(status)

	var close_btn = Button.new()
	close_btn.text = "✕"
	close_btn.pressed.connect(close_self)
	row.add_child(close_btn)

	list = ItemList.new()
	list.custom_minimum_size = Vector2(0, 300)
	list.item_selected.connect(func(index): selected = index)
	list.item_activated.connect(func(index):
		selected = index
		confirm()
		prompt.grab_focus()
	)
	box.add_child(list)

	# restyle on BOTH signals: the theme's real colors only exist after
	# setup_theme() runs (this panel is created before that in
	# file_manager._ready), and restyle() here previously only listened to
	# on_settings_change — so the list kept the gui defaults, where
	# font_color == background_color and file names were unreadable.
	LuaSingleton.on_theme_load.connect(restyle)
	LuaSingleton.on_settings_change.connect(restyle)
	restyle()

func _find_editor() -> FileManager:
	var node = get_parent()
	while node != null and !(node is FileManager):
		node = node.get_parent()
	return node

func open_for_files() -> void:
	if mode != "files": prompt.text = ""
	mode = "files"
	prompt.placeholder_text = "Type a file from the current folder..."
	# With a workspace the list is answered by the in-memory index on every
	# keystroke; the one-shot scan is only the no-workspace fallback.
	items = editor.quick_open_files() if !_using_workspace() else []
	refilter()
	_open_focus()

func open_for_commands() -> void:
	if mode != "commands": prompt.text = ""
	mode = "commands"
	prompt.placeholder_text = "Type a command..."
	if editor != null and editor.has_method("refresh_commands"):
		editor.refresh_commands()
	_seed_items(_build_commands())
	_open_focus()

func _using_workspace() -> bool:
	return editor != null and editor.workspace != null and editor.workspace.has_workspace()

func _seed_items(new_items: Array) -> void:
	items = new_items
	refilter()

func _open_focus() -> void:
	visible = true
	modulate.a = 0.0
	position = _base_position + Vector2(0, -6)
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
	_tween.set_parallel(true)
	_tween.tween_property(self, "modulate:a", 1.0, UI_MOTION.duration(0.18))
	_tween.tween_property(self, "position", _base_position, UI_MOTION.duration(0.18))
	prompt.grab_focus()
	prompt.select_all()

# COMMANDS

func _build_commands() -> Array:
	var cmds: Array = []
	cmds.append({"label": "Open file by name (quick open)", "display": "Open file by name (quick open)", "mode_switch": "files", "order": -1})

	if editor == null or editor.commands == null:
		return cmds

	# One list, straight from the registry. No command names are duplicated
	# here: adding a command (or a theme/recent-folder entry) is enough for it
	# to show up in the palette with its effective shortcut.
	var order := 0
	for command in editor.commands.all():
		if bool(command.get("hidden", false)):
			continue
		var command_id := str(command.get("id", ""))
		var label := str(command.get("label", command_id))
		var shortcut := str(command.get("shortcut", ""))
		var display := label if shortcut.is_empty() else "%s    %s" % [label, shortcut]
		cmds.append({
			"label": label,
			"display": display,
			"command": command_id,
			"category": str(command.get("category", "")),
			"defer": bool(command.get("defer_execute", false)),
			"enabled": editor.commands.is_enabled(command_id),
			"order": order,
		})
		order += 1

	return cmds

# LIST FLOW

func _on_prompt_changed(_text: String) -> void:
	refilter()

func refilter() -> void:
	var query: String = prompt.text

	# Workspace files bypass the preloaded `items` list entirely: quick_open
	# ranks the in-memory index (already lowercased) on every keystroke.
	if mode == "files" and _using_workspace():
		filtered = editor.workspace.quick_open_items(query, MAX_SHOWN)
		_populate()
		return

	filtered.clear()
	for item in items:
		var score = Fuzzy.score(item.label, query)
		if score != -1.0:
			filtered.append({
				"label": item.label,
				"display": item.get("display", item.label),
				"path": item.get("path", ""),
				"cb": item.get("cb"),
				"command": item.get("command", ""),
				"category": item.get("category", ""),
				"defer": item.get("defer", false),
				"enabled": item.get("enabled", true),
				"order": item.get("order", 0),
				"mode_switch": item.get("mode_switch", ""),
				"score": score,
			})

	if query.is_empty():
		filtered.sort_custom(func(a, b) -> bool: return int(a.order) < int(b.order))
	else:
		filtered.sort_custom(_sorter)
	_populate()

func _sorter(a, b) -> bool:
	if a.score != b.score: return a.score < b.score
	return a.label.naturalnocasecmp_to(b.label) < 0

func _populate() -> void:
	list.clear()

	var shown = mini(filtered.size(), MAX_SHOWN)
	for i in range(shown):
		var item = filtered[i]
		list.add_item(str(item.get("display", item.get("label", ""))))
		list.set_item_disabled(i, !bool(item.get("enabled", true)))
		list.set_item_tooltip(i, str(item.get("category", "")))

	selected = 0
	if shown > 0: list.select(0)

	status.text = _status_text()

func _status_text() -> String:
	if mode == "files" and _using_workspace() and editor.workspace.building and prompt.text.is_empty():
		return "Indexing folder... %d files" % editor.workspace.index_size()
	if filtered.is_empty():
		if prompt.text.is_empty():
			return "No files here" if mode == "files" else "No commands"
		return "No matches"
	if mode == "files":
		var noun := "matches" if !prompt.text.is_empty() else "files"
		if filtered.size() >= MAX_SHOWN:
			return "first %d %s" % [filtered.size(), noun]
		return "%d %s" % [filtered.size(), noun]
	return "%d commands" % filtered.size()

func move(dir: int) -> void:
	if filtered.is_empty(): return

	selected = (selected + dir + filtered.size()) % filtered.size()
	list.select(selected)
	if list.has_method("ensure_current_is_visible"):
		list.ensure_current_is_visible()

func confirm() -> void:
	if filtered.is_empty(): return
	if selected < 0 or selected >= filtered.size(): selected = 0
	_run(filtered[selected])

func _run(item: Dictionary) -> void:
	var mode_switch = item.get("mode_switch", "")
	if mode_switch != "":
		# swapping modes keeps the panel open, no toggle involved
		if mode_switch == "files": open_for_files()
		else: open_for_commands()
		return

	var command_id := str(item.get("command", ""))
	var enabled := bool(item.get("enabled", true))
	var defer := bool(item.get("defer", false))

	close_self()

	var path = item.get("path", "")
	if path != "":
		editor.open_file(path)
		return

	if !command_id.is_empty():
		if !enabled:
			return
		if defer:
			# OverlayController ignores opens while a fade is running. Wait for
			# the palette to finish closing before the command opens its panel.
			get_tree().create_timer(0.3).timeout.connect(func() -> void:
				editor.commands.execute(command_id)
			)
		else:
			editor.commands.execute(command_id)
		return

	# Kept for plugin-provided palette items that still carry a callable.
	var cb = item.get("cb")
	if cb: cb.call()

func close_self() -> void:
	editor.overlays.close(self)

# INPUT / EFFECTS

func _input(event: InputEvent) -> void:
	if !visible: return

	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		close_self()

func _process(_delta: float) -> void:
	if !visible: return
	# Only nudge the selection while the prompt owns the keyboard. When focus
	# is on the ItemList (user clicked a row), the list navigates itself via
	# ui_up/ui_down and reports through item_selected — moving here too would
	# step the selection twice per key press.
	if !prompt.has_focus(): return

	if Input.is_action_just_pressed("ui_up"):   move(-1)
	if Input.is_action_just_pressed("ui_down"): move(1)

func restyle() -> void:
	var panel = StyleBoxFlat.new()
	panel.bg_color = LuaSingleton.gui.background_color
	panel.set_content_margin_all(6)
	panel.content_margin_left = 10
	panel.content_margin_right = 10
	panel.corner_radius_top_left = 4
	panel.corner_radius_top_right = 4
	panel.border_width_bottom = 1
	panel.border_color = LuaSingleton.gui.current_line_color
	add_theme_stylebox_override("panel", panel)

	status.add_theme_color_override("font_color", LuaSingleton.keywords.comments)

	# strip the ItemList's own chrome so rows sit straight on the background
	list.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	list.add_theme_stylebox_override("focus", StyleBoxEmpty.new())

	var sel = StyleBoxFlat.new()
	sel.bg_color = LuaSingleton.gui.selection_color
	sel.set_content_margin_all(2)
	list.add_theme_stylebox_override("selected", sel)

	# readability guard: some themes ship a font_color that sits almost on top
	# of the background (the gui defaults even have them identical) — fall back
	# to a contrasting shade so the rows can always be read.
	var font = LuaSingleton.gui.font_color
	var bg = LuaSingleton.gui.background_color
	if absf(font.get_luminance() - bg.get_luminance()) < 0.22:
		font = Color(0.92, 0.92, 0.92) if bg.get_luminance() < 0.5 else Color(0.09, 0.09, 0.09)

	list.add_theme_color_override("font_color", font)
	list.add_theme_color_override("font_hovered_color", font)
	list.add_theme_color_override("font_selected_color", font)
