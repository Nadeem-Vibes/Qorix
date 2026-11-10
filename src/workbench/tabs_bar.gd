extends TabBar

const UI_MOTION = preload("res://src/platform/ui_motion.gd")

# Screen-space tab strip (HUD): one tab per open EditorDocument, synced with
# DocumentManager. Lives in a CanvasLayer so the zooming camera ignores it.

const TOP_OFFSET := 28.0
const TAB_MAX_WIDTH := 220
const TAB_MIN_WIDTH := 64
## Close button + text margins measured against the engine's layout (constant
## for this TabBar style — every tab is text_width + 44px).
const TAB_TEXT_PAD := 44.0
## Safety factor on the estimated text width before padding: engine kerned
## widths measured ~3.5% above the raw get_string_size values. Underestimating
## silently clipped tabs that don't fit inside the estimate.
const TAB_TEXT_SAFETY := 1.12
const TAB_BREATHING := 8.0

var editor: FileManager
var syncing = false  # suppresses tab_changed noise while rebuilding

func _ready() -> void:
	editor = _find_editor()

	theme = LuaSingleton.editor_theme
	set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	offset_top = TOP_OFFSET
	offset_bottom = TOP_OFFSET + 34
	max_tab_width = TAB_MAX_WIDTH
	tab_close_display_policy = TabBar.CLOSE_BUTTON_SHOW_ALWAYS
	select_with_rmb = false
	# tab order must stay 1:1 with FileManager.open_tabs; drags would scramble
	# which tab maps to which open file
	drag_to_rearrange_enabled = false
	# Clicks that hit no tab are passed to the parent chain (not to the code
	# below). The rect shrinks to the tab content so the empty right end of the
	# strip costs nothing — see _fit_width().
	mouse_filter = Control.MOUSE_FILTER_PASS

	resized.connect(_on_resized)

	tab_close_pressed.connect(_on_tab_close_pressed)
	tab_changed.connect(_on_tab_changed)
	gui_input.connect(_on_gui_input)

	# also restyle when a theme finishes loading (this HUD child's _ready runs
	# before file_manager calls setup_theme, so the first restyle reads the
	# gui defaults, where font_color == background_color)
	LuaSingleton.on_theme_load.connect(restyle)
	LuaSingleton.on_settings_change.connect(restyle)
	restyle()

func _find_editor() -> FileManager:
	var node = get_parent()
	while node != null and !(node is FileManager):
		node = node.get_parent()
	return node

## Keeps the strip sized to the tab content and shrinks max_tab_width when
## the tabs would overflow the viewport (Chrome-style: every file stays
## reachable, just narrower). The estimate comes from font metrics, not
## get_tab_rect: clipped tabs report degenerate rects, so measuring the laid
## out strip starves it — that was the bug where one tab filled the whole row.
var _fitting_width := false

func _on_resized() -> void:
	# Viewport resizes re-stretch anchored controls to the new width; pull the
	# rect back to the tab content. Guard against the recursion from our own
	# offset_right write.
	if _fitting_width: return
	_fit_width()

func _estimate_width(font: Font, font_size: int, cap: int) -> float:
	var used := TAB_BREATHING
	for index in range(get_tab_count()):
		var label := get_tab_title(index)
		var text_w := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x * TAB_TEXT_SAFETY
		used += minf(ceilf(text_w) + TAB_TEXT_PAD, float(cap))
	return used

func _fit_width() -> void:
	if _fitting_width: return
	_fitting_width = true
	var font: Font = get_theme_font("font")
	if font == null:
		font = get_theme_default_font()
	var font_size: int = get_theme_font_size("font_size")
	var viewport_width := get_viewport_rect().size.x
	var count := get_tab_count()

	var cap := TAB_MAX_WIDTH
	var used := _estimate_width(font, font_size, cap) if count > 0 else TAB_BREATHING
	if used > viewport_width and count > 0:
		# Even at the normal cap they don't fit: shrink to keep every tab
		# visible (at least TAB_MIN_WIDTH each; past ~29 tabs the bar still
		# scrolls with its built-in arrows).
		cap = maxi(TAB_MIN_WIDTH, int(floor((viewport_width - TAB_BREATHING) / float(count))))
		if cap != max_tab_width:
			max_tab_width = cap
		used = _estimate_width(font, font_size, cap)
	elif max_tab_width != TAB_MAX_WIDTH:
		max_tab_width = TAB_MAX_WIDTH

	# PRESET_TOP_WIDE: offset_right is measured inward from the right anchor.
	offset_right = minf(used, viewport_width) - viewport_width
	_fitting_width = false

func sync() -> void:
	syncing = true

	clear_tabs()

	for tab in editor.open_tabs:
		add_tab(_title(tab))

	if editor.active_tab >= 0 and editor.active_tab < get_tab_count():
		current_tab = editor.active_tab

	syncing = false
	# Tab widths depend on the text layout pass, so fit the strip after the
	# current frame instead of inline.
	call_deferred("_fit_width")

func _title(document) -> String:
	var title: String = document.title()

	if document.modified:
		title = "* " + title
	return title

func restyle() -> void:
	# Tab text width follows the theme font; refit the strip to the new tabs.
	call_deferred("_fit_width")
	add_theme_color_override("font_selected_color", LuaSingleton.gui.font_color)
	add_theme_color_override("font_unselected_color", LuaSingleton.keywords.comments)
	add_theme_color_override("font_hovered_color", LuaSingleton.gui.font_color)

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

	add_theme_stylebox_override("tab_selected", selected)
	add_theme_stylebox_override("tab_unselected", unselected)
	add_theme_stylebox_override("tab_hovered", hovered)

func _on_tab_close_pressed(index: int) -> void:
	editor.close_tab(index)

func _on_tab_changed(index: int) -> void:
	if syncing: return

	editor.select_tab(index)
	if UI_MOTION.feedback_allowed():
		modulate.a = 0.82
		var tween := create_tween()
		tween.tween_property(self, "modulate:a", 1.0, UI_MOTION.feedback_duration())

## The strip itself is focusable, so clicking a tab would otherwise leave the
## keyboard on the TabBar. Hand it back to the code either way: the switch
## then transfers focus to the new view, and clicking the active tab restores
## the caret as well.
func _on_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		editor.editor_host.grab_active_focus()
