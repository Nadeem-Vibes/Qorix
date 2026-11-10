extends PanelContainer

# Find & Replace panel (HUD): toggle with Ctrl+F / Ctrl+H.
# Enter / Next → forward, Prev → backward (wraps around), Replace replaces the
# current match, Replace all does what it says. Live counter shown as "n / m".

const MAX_MATCHES = 10000

var editor: FileManager

# The view that currently owns the painted search highlights; switching tabs
# must clear the old one before painting the new one.
var _search_view = null

var find_edit: LineEdit
var replace_edit: LineEdit
var status: Label
var match_case_btn: CheckBox

var matches: Array = []  # of Vector2i(line, col)
var match_index: int = -1

func _ready() -> void:
	editor = _find_editor()

	theme = LuaSingleton.editor_theme
	visible = false
	modulate.a = 0.0

	set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	offset_left = -560
	offset_top = 28
	offset_right = -10
	offset_bottom = 84

	var box = VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	add_child(box)

	var row1 = HBoxContainer.new()
	row1.add_theme_constant_override("separation", 4)
	box.add_child(row1)

	var row2 = HBoxContainer.new()
	row2.add_theme_constant_override("separation", 4)
	box.add_child(row2)

	find_edit = LineEdit.new()
	find_edit.placeholder_text = "Find..."
	find_edit.custom_minimum_size = Vector2(200, 0)
	find_edit.text_changed.connect(_on_find_changed)
	find_edit.text_submitted.connect(func(_t): _jump(1))
	row1.add_child(find_edit)

	match_case_btn = CheckBox.new()
	match_case_btn.text = "Match case"
	# default OFF — case-insensitive matches PascalCase/snake_case to a plain
	# lowercase query; tick the box when you really want exact case
	match_case_btn.button_pressed = false
	match_case_btn.toggled.connect(func(_t): _rescan())
	row1.add_child(match_case_btn)

	status = Label.new()
	row1.add_child(status)

	var close_btn = Button.new()
	close_btn.text = "✕"
	close_btn.pressed.connect(close_self)
	row1.add_child(close_btn)

	replace_edit = LineEdit.new()
	replace_edit.placeholder_text = "Replace with..."
	replace_edit.custom_minimum_size = Vector2(200, 0)
	replace_edit.text_submitted.connect(func(_t): _on_replace())
	row2.add_child(replace_edit)

	var replace_btn = Button.new()
	replace_btn.text = "Replace"
	replace_btn.pressed.connect(_on_replace)
	row2.add_child(replace_btn)

	var replace_all_btn = Button.new()
	replace_all_btn.text = "Replace all"
	replace_all_btn.pressed.connect(_on_replace_all)
	row2.add_child(replace_all_btn)

	# restyle on theme loads too — see palette_panel.gd / tabs_bar.gd
	LuaSingleton.on_theme_load.connect(restyle)
	LuaSingleton.on_settings_change.connect(restyle)

	# live counter + highlight refresh while the active file is edited
	editor.editor_host.view_created.connect(_on_view_created)
	editor.editor_host.active_view_changed.connect(_on_active_view_changed)
	for view in editor.editor_host.views:
		_on_view_created(view)

	restyle()

func _find_editor() -> FileManager:
	var node = get_parent()
	while node != null and !(node is FileManager):
		node = node.get_parent()
	return node

## The document currently on screen. Documents each own an EditorView, so
## every operation has to resolve the view afresh instead of caching one.
func _view():
	return editor.active_view if editor != null else null

func open() -> void:
	# re-assert the anchored top-right position on every open so the panel can
	# never end up off-screen, whatever earlier cycles did to the offsets
	set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	offset_left = -560
	offset_top = 28
	offset_right = -10
	offset_bottom = 84

	var view = _view()
	if view != null:
		var selection = view.get_selected_text()
		if selection != "":
			find_edit.text = selection

	_rescan()
	find_edit.grab_focus()
	find_edit.select_all()

func open_for_replace() -> void:
	open()
	replace_edit.grab_focus()

func on_open() -> void:
	open()

func on_close() -> void:
	clear_highlights()

func _on_active_view_changed(_view) -> void:
	if visible:
		_rescan()

func _on_view_created(view) -> void:
	if view == null or !is_instance_valid(view):
		return
	view.text_changed.connect(_on_code_changed)
	_style_view(view)

func close_self() -> void:
	# fade only (no slide, no background dim) and drop the engine highlights.
	# OverlayController calls on_close(), which clears the paint.
	editor.overlays.close(self)

# drops the in-code match paint; called from every close path (ESC / ✕ and
# the direct Ctrl+F toggle)
func clear_highlights() -> void:
	_sync_engine_search("")

func _input(event: InputEvent) -> void:
	if !visible: return

	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		close_self()

func _on_find_changed(_text: String) -> void:
	_rescan()

func _on_code_changed() -> void:
	# keep matches + highlights current when the file is edited while open
	if visible and find_edit != null and !find_edit.text.is_empty():
		_rescan()

func _sync_engine_search(term: String) -> void:
	var view = _view()

	# Switching tabs leaves the previous view alive (and highlighted), so
	# clear the old paint before touching the new view.
	if _search_view != null and is_instance_valid(_search_view) and _search_view != view:
		_search_view.set_search_text("")

	_search_view = view if !term.is_empty() else null
	if view == null or !view.has_method("set_search_text"):
		return

	# TextEdit paints every occurrence of the term directly into the code with
	# its own search highlighter ("search_highlight_color" theme color)
	view.set_search_text(term)
	if view.has_method("set_search_flags"):
		view.set_search_flags(TextEdit.SEARCH_MATCH_CASE if match_case_btn.button_pressed else 0)

func _rescan() -> void:
	matches.clear()
	match_index = -1

	var view = _view()
	var term: String = find_edit.text
	if term.is_empty():
		status.text = ""
		_sync_engine_search("")
		return
	if view == null:
		status.text = ""
		return

	# direct scan over the text itself instead of CodeEdit.search(): one clear
	# code path for case handling and no dependency on engine search semantics
	var needle: String = term if match_case_btn.button_pressed else term.to_lower()

	var line_count = view.get_line_count()
	for line in range(line_count):
		if matches.size() >= MAX_MATCHES:
			break

		var text: String = view.get_line(line)
		var hay: String = text if match_case_btn.button_pressed else text.to_lower()

		var col = hay.find(needle)
		while col != -1:
			matches.append(Vector2i(line, col))

			if matches.size() >= MAX_MATCHES:
				break
			if needle.is_empty():
				break
			col = hay.find(needle, col + needle.length())

	if matches.is_empty():
		status.text = "0 results"
	else:
		status.text = "%d" % matches.size()

	# paint every occurrence straight into the code, not just the selected one
	_sync_engine_search(term)

func _jump(direction: int) -> void:
	if find_edit.text.is_empty(): return
	if matches.is_empty():
		status.text = "No results"
		return

	var view = _view()
	if view == null: return

	# walk relative to the caret so Enter keeps moving through the file
	var caret = Vector2i(view.get_caret_line(), view.get_caret_column())
	var target = -1

	if direction > 0:
		for i in range(matches.size()):
			if _after(matches[i], caret):
				target = i
				break
		if target == -1:
			target = 0  # wrap around
	else:
		for i in range(matches.size() - 1, -1, -1):
			if _before(matches[i], caret):
				target = i
				break
		if target == -1:
			target = matches.size() - 1

	_show_match(target)

func _after(pos: Vector2i, caret: Vector2i) -> bool:
	return pos.x > caret.x or (pos.x == caret.x and pos.y > caret.y)

func _before(pos: Vector2i, caret: Vector2i) -> bool:
	return pos.x < caret.x or (pos.x == caret.x and pos.y < caret.y)

func _show_match(index: int) -> void:
	match_index = index

	var view = _view()
	if view == null: return

	var pos: Vector2i = matches[index]
	var term: String = find_edit.text

	# caret first (to the end of the match, so Enter keeps moving forward),
	# then the selection on top of it
	view.set_caret_line(pos.x)
	view.set_caret_column(pos.y + term.length())
	view.select(pos.x, pos.y, pos.x, pos.y + term.length())

	status.text = "%d / %d" % [index + 1, matches.size()]

func _on_replace() -> void:
	if find_edit.text.is_empty(): return
	if matches.is_empty():
		status.text = "No results"
		return

	if match_index == -1:
		_jump(1)
		if match_index == -1: return

	var view = _view()
	if view == null: return

	var pos: Vector2i = matches[match_index]
	var term: String = find_edit.text

	# the replacement is inlined onto a single line on purpose: keeping it
	# single-line keeps every remaining match's offsets valid
	view.select(pos.x, pos.y, pos.x, pos.y + term.length())
	view.insert_text_at_caret(replace_edit.text.replace("\n", " "))

	_rescan()
	if !matches.is_empty():
		_jump(1)  # continue after the replacement

func _on_replace_all() -> void:
	var term: String = find_edit.text
	if term.is_empty() or matches.is_empty(): return

	var view = _view()
	if view == null: return

	var count = matches.size()
	var rep: String = replace_edit.text.replace("\n", " ")

	# replace from the bottom up so earlier match offsets stay valid
	for i in range(matches.size() - 1, -1, -1):
		var pos: Vector2i = matches[i]
		view.select(pos.x, pos.y, pos.x, pos.y + term.length())
		view.insert_text_at_caret(rep)

	_rescan()

	status.text = "Replaced %d" % count

func restyle() -> void:
	var panel = StyleBoxFlat.new()
	panel.bg_color = LuaSingleton.gui.background_color
	panel.set_content_margin_all(6)
	panel.content_margin_left = 10
	panel.content_margin_right = 10
	panel.corner_radius_bottom_left = 4
	panel.corner_radius_bottom_right = 4
	panel.border_width_bottom = 1
	panel.border_color = LuaSingleton.gui.current_line_color
	add_theme_stylebox_override("panel", panel)

	status.add_theme_color_override("font_color", LuaSingleton.keywords.comments)

	# warm translucent fill behind every match in the code; re-asserted on
	# every theme change so settings/theme restyling can't wash it out
	if editor != null and editor.editor_host != null:
		for view in editor.editor_host.views:
			_style_view(view)

func _style_view(view) -> void:
	if view == null or !is_instance_valid(view):
		return
	view.add_theme_color_override("search_highlight_color", Color(1.0, 0.72, 0.1, 0.38))
