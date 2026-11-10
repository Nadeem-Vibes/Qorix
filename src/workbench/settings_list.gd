extends ScrollContainer

const SETTING = preload("res://src/workbench/setting.tscn")
const SETTING_CATEGORY = preload("res://src/workbench/setting_category.tscn")
const UPDATE = preload("res://src/workbench/update.tscn")
const FOCUS_NAV = preload("res://src/platform/focus_nav.gd")

# The note is a world-space panel (the settings menu is inside a Node2D), so
# these are world pixels, not screen pixels. At the settings camera zoom they
# are 1:1.
const NOTE_WIDTH := 520.0
const NOTE_GAP := 28.0
const NOTE_MARGIN := 18.0

@onready var _vbox: VBoxContainer = $VBox

# property -> the controls that display it, so keyboard-driven changes (e.g.
# Ctrl+= for the editor font size) can update the open panel without rebuilding
# every row and the full system-font dropdown.
var _rows: Dictionary = {}

var _note: PanelContainer
var _note_title: RichTextLabel
var _note_body: RichTextLabel
var _note_tween: Tween
var _note_generation: int = 0

# Called when the node enters the scene tree for the first time.
func _ready():
	# Wait for the first theme load unless it already happened (a failed load
	# still notifies on_theme_load, so this wait is always bounded).
	if !LuaSingleton.theme_load_attempted:
		await LuaSingleton.on_theme_load;

	create_note()
	setup_settings()

	LuaSingleton.on_settings_change.connect(setup_settings)

	var parent := get_parent()
	if parent != null:
		parent.visibility_changed.connect(_on_parent_visibility_changed)

	get_v_scroll_bar().value_changed.connect(_on_scroll)

func setup_settings() -> void:
	var previous_scroll := scroll_vertical

	_hide_note_now()
	style_note()  # themes can change while the panel exists
	setup_scrollbar()
	_rows.clear()

	# Remove immediately, not queue_free: the old rows must not contribute to
	# the scroll height while the new ones are being built.
	for child in _vbox.get_children():
		_vbox.remove_child(child)
		child.queue_free()

	# Version + update check first: it doubles as the panel header.
	_vbox.add_child(UPDATE.instantiate())
	_add_shortcuts_button()

	var entries := LuaSingleton.settings
	var grouped: Dictionary = {}

	for setting in entries:
		var category := str(setting.get("category", ""))
		if !grouped.has(category):
			grouped[category] = []
		grouped[category].append(setting)

	for category in LuaSingleton.settings_categories():
		var key := str(category.get("key", ""))
		if !grouped.has(key):
			continue

		create_category(str(category.get("display", key)))

		for setting in grouped[key]:
			create_setting(setting)

		grouped.erase(key)

	# A setting added without a known category still shows up instead of
	# silently vanishing from the panel.
	var leftovers: Array = []
	for key in grouped.keys():
		leftovers.append_array(grouped[key])

	if !leftovers.is_empty():
		create_category("Other")
		for setting in leftovers:
			create_setting(setting)

	# The last row would otherwise sit exactly on the clipping edge. The tail
	# gives it room to scroll fully into view.
	var tail := Control.new()
	tail.custom_minimum_size = Vector2(0, 16)
	_vbox.add_child(tail)

	# Toggling a setting low in the list rebuilds the rows; keep the reader's
	# place instead of throwing them back to the top.
	set_deferred("scroll_vertical", previous_scroll)

	# Rows are generated in code, so their controls are not focusable by
	# default. Give every check button, slider and dropdown a Tab stop.
	FOCUS_NAV.configure_tree(_vbox)


## Keyboard entry point used when the settings overlay opens.
func focus_first() -> void:
	var target := FOCUS_NAV.first_focusable(_vbox)
	if target == null:
		return
	target.grab_focus()
	ensure_control_visible(target)

func _add_shortcuts_button() -> void:
	var button := Button.new()
	button.text = "⌨  Keyboard Shortcuts..."
	button.tooltip_text = "Rebind every command, including the ones with no default shortcut (Ctrl+Alt+K)."
	button.add_theme_color_override("font_color", LuaSingleton.gui.font_color)
	button.add_theme_color_override("font_hover_color", LuaSingleton.gui.selection_color)
	button.pressed.connect(_open_keybindings)
	_vbox.add_child(button)


func _open_keybindings() -> void:
	var node := get_parent()
	while node != null and !(node is FileManager):
		node = node.get_parent()
	if node != null:
		node.open_keybindings()


func create_category(display: String) -> void:
	var node = SETTING_CATEGORY.instantiate()

	_vbox.add_child(node)

	var label: RichTextLabel = node.get_node("Control/RichTextLabel")

	label.clear()

	label.push_color(LuaSingleton.gui.selection_color)
	label.add_text("▌")
	label.pop()

	label.push_color(LuaSingleton.gui.font_color)
	label.add_text("  %s  " % display.to_upper())
	label.pop()

	# The dashes turn the header into a section divider without spending an
	# extra row of vertical space. Length is reduced by the title length so
	# every divider ends on the same column.
	var line := Color(
		LuaSingleton.gui.font_color.r,
		LuaSingleton.gui.font_color.g,
		LuaSingleton.gui.font_color.b,
		0.22
	)
	label.push_color(line)
	label.add_text("─".repeat(maxi(8, 36 - display.length())))
	label.pop()

func create_setting(setting: Dictionary) -> void:
	var text: String = str(setting.get("display", ""))
	var icon: String = str(setting.get("icon", ""))
	var value: Variant = setting.get("value")
	var options: Array = setting.get("options", [])
	var property: String = str(setting.get("property", ""))
	var description: String = str(setting.get("description", ""))
	var unit: String = setting.unit if setting.has("unit") else "";
	var _min = setting.min if setting.has("min") else 0;
	var _max = setting.max if setting.has("max") else 0;
	var precision = setting.precision if setting.has("precision") else false;

	var node = SETTING.instantiate()

	_vbox.add_child(node)

	var label: RichTextLabel = node.get_node("Control/RichTextLabel");

	var slider: HSlider = node.get_node("Control2/HSlider")
	var checkbutton: CheckButton = node.get_node("Control2/CheckButton");
	var value_label: RichTextLabel = node.get_node("Control4/Value");
	var dropdown: OptionButton = node.get_node("Control5/OptionButton");

	_rows[property] = {
		"slider": slider,
		"checkbutton": checkbutton,
		"dropdown": dropdown,
		"value_label": value_label,
		"options": options,
		"unit": unit,
	}

	label.add_theme_color_override("default_color", LuaSingleton.gui.font_color);
	value_label.add_theme_color_override("default_color", LuaSingleton.gui.font_color);

	# labels are read-only here: clicking one should not start a text selection
	label.selection_enabled = false
	value_label.selection_enabled = false

	label.clear()

	label.push_color(LuaSingleton.keywords.values().pick_random())
	label.add_text(icon)
	label.pop()

	label.add_text("  %s" % text)

	# A quiet "?" is the affordance for the hover note; the whole label (not
	# just the glyph) is the hover target.
	if !description.is_empty():
		label.push_color(LuaSingleton.keywords.get("comments", LuaSingleton.gui.font_color))
		label.add_text("  ?")
		label.pop()

		label.mouse_default_cursor_shape = Control.CURSOR_HELP
		label.mouse_entered.connect(_show_note.bind(text, description, label))
		label.mouse_exited.connect(_hide_note)

	_fit_label_to_row(label, node)

	if !precision:
		slider.step = 1

	slider.max_value = _max
	slider.min_value = _min

	checkbutton.hide()
	slider.hide()
	dropdown.hide()
	value_label.hide()

	if typeof(value) == Variant.Type.TYPE_BOOL:
		checkbutton.show()

		checkbutton.button_pressed = value;
	elif options.size() != 0:
		dropdown.show()

		for option in options:
			if option is Dictionary:
				dropdown.add_item(str(option.get("display", option.get("value", ""))))
				dropdown.set_item_metadata(dropdown.item_count - 1, option.get("value", null))
			else:
				dropdown.add_item(str(option))
				dropdown.set_item_metadata(dropdown.item_count - 1, option)

		# Values are stable IDs (font display names), not list positions.
		dropdown.selected = _option_index(options, value)
	else:
		value_label.show()

		set_label(value_label, unit, value)

		slider.show()
		slider.value = value

	slider.value_changed.connect(_slider_value_change.bind(property, value_label, unit))
	checkbutton.toggled.connect(_check_button_change.bind(property))
	dropdown.item_selected.connect(_dropdown_change.bind(property, dropdown))

## The setting scenes draw their labels by scaling 66 px text down to roughly
## 15 px. Those labels sit inside plain Controls, so the row never hears about
## their height: a wrapped name was clipped by the label's authored one-line
## rect and the following row started on top of it. Match the label rect to
## its wrapped content and give the row the same height on screen.
func _fit_label_to_row(label: RichTextLabel, row: Control) -> void:
	var content_height := float(label.get_content_height())
	if content_height <= 0.0:
		return

	label.size.y = content_height

	row.custom_minimum_size.y = maxf(
		row.custom_minimum_size.y,
		(label.position.y + content_height) * label.scale.y
	)

# ── SCROLLBAR ───────────────────────────────────────────────────────────────

func setup_scrollbar() -> void:
	var bar := get_v_scroll_bar()
	if bar == null:
		return

	# A thin grabber instead of Godot's default scrollbar chrome, so it fits
	# the flat editor look.
	bar.custom_minimum_size = Vector2(4, 0)
	bar.add_theme_stylebox_override("scroll", StyleBoxEmpty.new())

	var font: Color = LuaSingleton.gui.font_color
	var accent: Color = LuaSingleton.gui.selection_color

	var grabber := StyleBoxFlat.new()
	grabber.bg_color = Color(font.r, font.g, font.b, 0.18)
	grabber.corner_radius_top_left = 2
	grabber.corner_radius_top_right = 2
	grabber.corner_radius_bottom_left = 2
	grabber.corner_radius_bottom_right = 2
	bar.add_theme_stylebox_override("grabber", grabber)

	var highlighted: StyleBoxFlat = grabber.duplicate()
	highlighted.bg_color = Color(accent.r, accent.g, accent.b, 0.55)
	bar.add_theme_stylebox_override("grabber_highlight", highlighted)

	var pressed: StyleBoxFlat = grabber.duplicate()
	pressed.bg_color = accent
	bar.add_theme_stylebox_override("grabber_pressed", pressed)

func _on_scroll(_value: float) -> void:
	# The row that opened the note may have moved out from under the cursor.
	_hide_note()

# ── HOVER NOTE ──────────────────────────────────────────────────────────────

func create_note() -> void:
	if _note != null:
		return

	var parent := get_parent()
	if parent == null:
		return

	_note = PanelContainer.new()
	_note.name = "SettingNote"
	_note.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_note.z_index = 20
	_note.theme = LuaSingleton.editor_theme
	_note.modulate.a = 0.0
	_note.visible = false

	parent.add_child(_note)

	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 3)
	_note.add_child(box)

	_note_title = RichTextLabel.new()
	_note_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_note_title.bbcode_enabled = true
	_note_title.scroll_active = false
	_note_title.fit_content = true
	_note_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_note_title.custom_minimum_size = Vector2(NOTE_WIDTH, 0)
	_note_title.add_theme_font_size_override("normal_font_size", 15)
	box.add_child(_note_title)

	_note_body = RichTextLabel.new()
	_note_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_note_body.bbcode_enabled = true
	_note_body.scroll_active = false
	_note_body.fit_content = true
	_note_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_note_body.custom_minimum_size = Vector2(NOTE_WIDTH, 0)
	_note_body.add_theme_font_size_override("normal_font_size", 15)
	box.add_child(_note_body)

	style_note()

func style_note() -> void:
	if _note == null:
		return

	var style := StyleBoxFlat.new()
	style.bg_color = LuaSingleton.gui.background_color.lightened(0.07)
	style.border_color = LuaSingleton.gui.selection_color
	style.border_width_left = 2
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.corner_radius_top_left = 2
	style.corner_radius_top_right = 2
	style.corner_radius_bottom_left = 2
	style.corner_radius_bottom_right = 2
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 8
	style.content_margin_bottom = 8

	_note.add_theme_stylebox_override("panel", style)

func _show_note(setting_name: String, description: String, anchor: Control) -> void:
	if _note == null or anchor == null or !is_instance_valid(anchor):
		return

	_note_generation += 1
	var generation := _note_generation

	_note_title.clear()
	_note_title.push_color(LuaSingleton.gui.selection_color)
	_note_title.add_text(setting_name)
	_note_title.pop()

	_note_body.clear()
	_note_body.add_text(description)

	# Let the wrapped label report its real height before placing the panel.
	await get_tree().process_frame

	if generation != _note_generation or !is_instance_valid(anchor):
		return

	_note.size = _note.get_combined_minimum_size()
	_position_note(anchor)

	if _note_tween != null:
		_note_tween.kill()

	if !_note.visible:
		_note.modulate.a = 0.0
		_note.show()

	_note_tween = create_tween()
	_note_tween.tween_property(_note, "modulate:a", 1.0, 0.12)

func _position_note(anchor: Control) -> void:
	var anchor_rect := anchor.get_global_rect()
	var visible_rect := _visible_world_rect()

	var target := Vector2(
		global_position.x - _note.size.x - NOTE_GAP,
		anchor_rect.position.y + anchor_rect.size.y * 0.5 - _note.size.y * 0.5
	)

	target.x = maxf(target.x, visible_rect.position.x + NOTE_MARGIN)
	target.y = clampf(
		target.y,
		visible_rect.position.y + NOTE_MARGIN,
		visible_rect.end.y - _note.size.y - NOTE_MARGIN
	)

	_note.global_position = target

func _visible_world_rect() -> Rect2:
	var viewport := get_viewport()
	if viewport == null:
		return Rect2()

	var screen_rect := Rect2(Vector2.ZERO, viewport.get_visible_rect().size)
	return viewport.get_canvas_transform().affine_inverse() * screen_rect

func _hide_note() -> void:
	_note_generation += 1

	if _note == null or !_note.visible:
		return

	var generation := _note_generation

	if _note_tween != null:
		_note_tween.kill()

	_note_tween = create_tween()
	_note_tween.tween_property(_note, "modulate:a", 0.0, 0.1)
	_note_tween.tween_callback(func() -> void:
		if generation == _note_generation:
			_note.hide()
	)

func _hide_note_now() -> void:
	_note_generation += 1

	if _note == null:
		return

	if _note_tween != null:
		_note_tween.kill()

	_note.modulate.a = 0.0
	_note.hide()

func _on_parent_visibility_changed() -> void:
	var parent := get_parent()
	if parent != null and !parent.visible:
		_hide_note_now()

## Updates the existing rows in place. Unlike setup_settings(), this never
## rebuilds the font dropdown, so it is safe to call while the panel is open.
func refresh_values() -> void:
	for setting in LuaSingleton.settings:
		var property := str(setting.get("property", ""))
		if !_rows.has(property):
			continue

		var row: Dictionary = _rows[property]
		var value = setting.get("value")
		var checkbutton: CheckButton = row["checkbutton"]
		var dropdown: OptionButton = row["dropdown"]
		var slider: HSlider = row["slider"]

		if checkbutton.visible:
			checkbutton.set_pressed_no_signal(bool(value))
		elif dropdown.visible:
			dropdown.selected = _option_index(row["options"], value)
		else:
			slider.set_value_no_signal(float(value))
			set_label(row["value_label"], str(row["unit"]), float(value))

func _option_index(options: Array, value: Variant) -> int:
	for i in range(options.size()):
		var option = options[i]
		var option_value = option.get("value", option) if option is Dictionary else option
		if option_value == value:
			return i

	return 0

func set_label(value_label: RichTextLabel, unit: String, value: float) -> void:
	value_label.clear()

	value_label.add_text(str(value) + " ")

	value_label.push_color(LuaSingleton.gui.selection_color)
	value_label.add_text(unit)
	value_label.pop()

func _slider_value_change(value: float, property: String, value_label: RichTextLabel, unit: String) -> void:
	# editor_font_size included: it is a plain layout setting now. The camera
	# zoom is driven solely by zoom_intensity (slider + Ctrl+= keys + palette
	# all write the same value), so no cross-row refresh is needed here.
	LuaSingleton.change_setting(property, value)
	set_label(value_label, unit, value)

func _check_button_change(toggled_on: bool, property: String) -> void:
	LuaSingleton.change_setting(property, toggled_on)
	# Deferred: emitting synchronously re-enters setup_settings(), which frees
	# and rebuilds every row — including the very control that signalled.
	call_deferred("_emit_settings_change")

func _dropdown_change(index: int, property: String, dropdown: OptionButton):
	LuaSingleton.change_setting(property, dropdown.get_item_metadata(index))
	# Deferred for the same re-entrancy reason as _check_button_change.
	call_deferred("_emit_settings_change")

func _emit_settings_change() -> void:
	LuaSingleton.on_settings_change.emit()
