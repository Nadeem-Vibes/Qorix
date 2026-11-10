extends Control

## Right-edge dock for the built-in Python Journey course.
##
## The panel is a thin view over FileManager's course runtime: the guide /
## exercise engine owns the learning, FileManager owns the wiring, this dock
## owns the pixels. State is polled a few times a second while it is visible,
## so re-opening a half-done lesson (or finishing one elsewhere) never goes
## stale.

const WIDTH := 360.0
const POLL_SECONDS := 0.25
const UI_MOTION = preload("res://src/platform/ui_motion.gd")

var editor: FileManager = null


static func _t(text: String) -> String:
	return TranslationServer.translate(text)

var _lesson_list: VBoxContainer
var _progress_label: Label
var _lesson_title: Label
var _phase_label: Label
var _prompt_label: Label
var _result_label: Label
var _example_label: Label
var _hint_label: Label
var _check_button: Button
var _example_button: Button
var _hint_button: Button
var _next_button: Button
var _retry_button: Button
var _exit_button: Button
var _example_shown: bool = false
var _hint_shown: bool = false
var _poll: float = 0.0
var _tween: Tween = null
var _lesson_buttons: Dictionary = {}


func _ready() -> void:
	editor = _find_editor()
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	z_index = 31

	set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	offset_left = -(WIDTH + 12.0)
	offset_right = -12.0
	offset_top = 96.0
	# Anchor the bottom edge instead of fixing it: the dock tracks the window
	# height (long localized text and big fonts grew past a fixed 464 px and
	# clipped the action row off-screen), and the scroll container below keeps
	# every button reachable even on very short windows.
	anchor_top = 0.0
	anchor_bottom = 1.0
	offset_bottom = -12.0

	_build()
	LuaSingleton.on_theme_load.connect(restyle)
	LuaSingleton.on_settings_change.connect(restyle)
	restyle()


func _find_editor() -> FileManager:
	var node = get_parent()
	while node != null and !(node is FileManager):
		node = node.get_parent()
	return node


func _build() -> void:
	var panel := PanelContainer.new()
	panel.name = "Panel"
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(panel)

	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)

	var body := VBoxContainer.new()
	body.name = "Body"
	body.add_theme_constant_override("separation", 8)
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(body)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	body.add_child(header)

	var titles := VBoxContainer.new()
	titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	titles.add_theme_constant_override("separation", 0)
	header.add_child(titles)

	var eyebrow := Label.new()
	eyebrow.text = _t("LEARNING")
	eyebrow.add_theme_font_size_override("font_size", 10)
	titles.add_child(eyebrow)

	var title := Label.new()
	title.text = _t("Python Journey")
	title.add_theme_font_size_override("font_size", 19)
	title.name = "Title"
	titles.add_child(title)

	var close := Button.new()
	close.text = "✕"
	close.tooltip_text = _t("Close the course dock. Your progress is saved.")
	close.focus_mode = Control.FOCUS_NONE
	close.pressed.connect(hide_course)
	header.add_child(close)

	_lesson_list = VBoxContainer.new()
	_lesson_list.name = "Lessons"
	_lesson_list.add_theme_constant_override("separation", 4)
	body.add_child(_lesson_list)

	_progress_label = Label.new()
	_progress_label.name = "Progress"
	_progress_label.add_theme_font_size_override("font_size", 11)
	body.add_child(_progress_label)

	var rule := HSeparator.new()
	body.add_child(rule)

	_lesson_title = Label.new()
	_lesson_title.name = "LessonTitle"
	_lesson_title.add_theme_font_size_override("font_size", 15)
	_lesson_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(_lesson_title)

	_phase_label = Label.new()
	_phase_label.name = "Phase"
	_phase_label.add_theme_font_size_override("font_size", 11)
	body.add_child(_phase_label)

	_prompt_label = Label.new()
	_prompt_label.name = "Prompt"
	_prompt_label.add_theme_font_size_override("font_size", 13)
	_prompt_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(_prompt_label)

	_example_label = Label.new()
	_example_label.name = "Example"
	_example_label.add_theme_font_size_override("font_size", 11)
	_example_label.visible = false
	_example_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(_example_label)

	var example_row := HBoxContainer.new()
	example_row.add_theme_constant_override("separation", 6)
	body.add_child(example_row)

	_example_button = Button.new()
	_example_button.text = _t("Show example")
	_example_button.tooltip_text = _t("Reveal what the finished file looks like.")
	_example_button.pressed.connect(_toggle_example)
	example_row.add_child(_example_button)

	_hint_button = Button.new()
	_hint_button.text = _t("Need a hint?")
	_hint_button.tooltip_text = _t("Show a hint for this phase.")
	_hint_button.pressed.connect(_toggle_hint)
	example_row.add_child(_hint_button)

	_hint_label = Label.new()
	_hint_label.name = "Hint"
	_hint_label.add_theme_font_size_override("font_size", 12)
	_hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint_label.visible = false
	body.add_child(_hint_label)

	_result_label = Label.new()
	_result_label.name = "Result"
	_result_label.add_theme_font_size_override("font_size", 12)
	_result_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(_result_label)

	_check_button = Button.new()
	_check_button.text = _t("Check my code")
	_check_button.tooltip_text = _t("Run the tests for this lesson. The typing phase must be finished first.")
	_check_button.custom_minimum_size = Vector2(0, 36)
	_check_button.pressed.connect(_on_check)
	body.add_child(_check_button)

	var nav_row := HBoxContainer.new()
	nav_row.add_theme_constant_override("separation", 6)
	body.add_child(nav_row)

	_retry_button = Button.new()
	_retry_button.text = _t("Retry lesson")
	_retry_button.tooltip_text = _t("Start this lesson over from its starter text.")
	_retry_button.pressed.connect(_on_retry)
	nav_row.add_child(_retry_button)

	_next_button = Button.new()
	_next_button.text = _t("Next lesson →")
	_next_button.tooltip_text = _t("Continue with the next lesson.")
	_next_button.pressed.connect(_on_next)
	_next_button.visible = false
	nav_row.add_child(_next_button)

	_exit_button = Button.new()
	_exit_button.text = _t("Exit course")
	_exit_button.tooltip_text = _t("Leave the lesson. Your place is saved.")
	_exit_button.pressed.connect(_on_exit)
	nav_row.add_child(_exit_button)


func _process(delta: float) -> void:
	if !visible:
		return
	_poll += delta
	if _poll >= POLL_SECONDS:
		_poll = 0.0
		refresh()


func show_course() -> void:
	refresh()
	visible = true
	if _tween != null and _tween.is_valid():
		_tween.kill()
	if UI_MOTION.allowed():
		var final_left := offset_left
		offset_left = -(WIDTH + 48.0)
		modulate.a = 0.0
		_tween = create_tween()
		_tween.set_parallel(true)
		_tween.tween_property(self, "offset_left", final_left, 0.22).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		_tween.tween_property(self, "modulate:a", 1.0, 0.22).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	else:
		modulate.a = 1.0


func hide_course() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	visible = false


func refresh() -> void:
	if editor == null or editor.course_service == null:
		return
	_rebuild_lessons()
	_refresh_state()


func _rebuild_lessons() -> void:
	# Lesson buttons are created once and updated in place. Recreating them on
	# every poll would swap the button out from under the cursor: the press
	# never completes and hover never lands, which reads as "dead buttons".
	if _lesson_list == null:
		return
	var lessons: Array = editor.course_service.lessons()
	var completed: int = 0
	for lesson in lessons:
		var id := str(lesson.get("id", ""))
		if editor.course_service.is_done(id):
			completed += 1

	var seen: Dictionary = {}
	for lesson in lessons:
		var id := str(lesson.get("id", ""))
		var number := int(lesson.get("number", 0))
		var done: bool = editor.course_service.is_done(id)
		var current: bool = editor.course_lesson == id
		seen[id] = true

		var button: Button = _lesson_buttons.get(id) as Button
		if button == null or !is_instance_valid(button):
			button = Button.new()
			button.alignment = HORIZONTAL_ALIGNMENT_LEFT
			button.toggle_mode = true
			button.custom_minimum_size = Vector2(0, 30)
			button.pressed.connect(func() -> void: _on_lesson_pressed(id))
			_lesson_list.add_child(button)
			_lesson_buttons[id] = button

		var want_text := "%d  %s%s" % [number, str(lesson.get("title", id)), "   ✓" if done else ""]
		if button.text != want_text:
			button.text = want_text
		button.tooltip_text = str(lesson.get("summary", ""))
		if button.button_pressed != current:
			button.set_pressed_no_signal(current)
		panel_only_style(button, done, current)

	# Drop buttons whose lesson disappeared from the catalog.
	for id in _lesson_buttons.keys():
		if !seen.has(id):
			var stale: Button = _lesson_buttons[id] as Button
			if stale != null and is_instance_valid(stale):
				stale.queue_free()
			_lesson_buttons.erase(id)

	if _progress_label != null:
		var total: int = editor.course_service.total_lessons()
		if completed == total and total > 0:
			_progress_label.text = _t("All %d lessons complete! Open Help → Python Journey to replay any lesson.") % total
		else:
			_progress_label.text = _t("%d of %d lessons complete") % [completed, total]


func _refresh_state() -> void:
	var snapshot: Dictionary = editor.course_snapshot() if editor.has_method("course_snapshot") else {}
	var lesson_id: String = str(snapshot.get("lesson_id", ""))

	if lesson_id.is_empty():
		_lesson_title.text = _t("Pick a lesson to begin.")
		_phase_label.text = ""
		_prompt_label.text = _t("Five short lessons. Each one types the target line, then makes the program your own.")
		_result_label.text = ""
		_result_label.modulate = Color.WHITE
		_example_label.visible = false
		_hint_label.visible = false
		_check_button.visible = false
		_retry_button.visible = false
		_next_button.visible = false
		_example_button.visible = false
		_hint_button.visible = false
		return

	var lesson: Dictionary = editor.course_service.lesson(lesson_id)
	var index := int(lesson.get("number", 0))
	_lesson_title.text = (_t("Lesson %d of %d") % [index, editor.course_service.total_lessons()]) + " · " + str(lesson.get("title", lesson_id))
	_phase_label.text = _t("Step 2 — Make it yours") if str(snapshot.get("phase_kind", "typing")) == "freeform" else _t("Step 1 — Type it")
	_prompt_label.text = str(snapshot.get("prompt", lesson.get("exercise", {}).get("prompt", "")))
	_example_button.visible = true
	_hint_button.visible = true
	_example_label.text = str(lesson.get("exercise", {}).get("freeform", {}).get("example", "")).rstrip("\n")
	_example_label.visible = _example_shown
	_example_button.text = _t("Hide example") if _example_shown else _t("Show example")
	_hint_label.text = str(lesson.get("exercise", {}).get("freeform", {}).get("hint", lesson.get("coach", "")))
	_hint_label.visible = _hint_shown
	_hint_button.text = _t("Hide hint") if _hint_shown else _t("Need a hint?")

	var state := str(snapshot.get("state", ""))
	var phase := str(snapshot.get("phase_kind", ""))
	_check_button.visible = phase == "freeform"
	_retry_button.visible = true
	_next_button.visible = state == "completed"

	match state:
		"completed":
			_result_label.text = _t("✓ Lesson complete. Nice work.")
			_result_label.modulate = Color("#9ece6a")
		"failed":
			var failed: Array = []
			for raw in snapshot.get("results", []):
				if raw is Dictionary and !bool(raw.get("passed", false)):
					var name := str(raw.get("name", "a test"))
					if !name.is_empty():
						failed.append(name)
			if failed.is_empty():
				_result_label.text = _t("Not quite yet. Look at the failing test, edit the file, then press Check again.")
			else:
				_result_label.text = _t("Not quite yet — failing: %s.") % ", ".join(failed)
			_result_label.modulate = Color("#f7768e")
		_:
			_result_label.text = "" if phase != "freeform" else _t("Edit the file, then press Check my code.")
			# Semantic tint from a previous completed/failed result must not
			# linger on the neutral message.
			_result_label.modulate = Color.WHITE


func panel_only_style(button: Button, done: bool, current: bool) -> void:
	var color: Color = LuaSingleton.gui.font_color if LuaSingleton.gui != null else Color.WHITE
	if done:
		button.add_theme_color_override("font_color", Color("#9ece6a"))
	elif current:
		button.add_theme_color_override("font_color", LuaSingleton.gui.selection_color if LuaSingleton.gui != null else color)
	else:
		button.remove_theme_color_override("font_color")


func _toggle_example() -> void:
	_example_shown = !_example_shown
	refresh()


func _toggle_hint() -> void:
	_hint_shown = !_hint_shown
	refresh()


func _on_check() -> void:
	if editor != null and editor.has_method("course_check"):
		editor.course_check()


func _on_retry() -> void:
	if editor != null and editor.has_method("course_retry_lesson"):
		editor.course_retry_lesson()


func _on_next() -> void:
	if editor != null and editor.has_method("course_next_lesson"):
		editor.course_next_lesson()


func _on_exit() -> void:
	if editor != null and editor.has_method("course_stop"):
		editor.course_stop()


func _on_lesson_pressed(id: String) -> void:
	if editor != null and editor.has_method("course_start_lesson"):
		editor.course_start_lesson(id)


func restyle() -> void:
	if LuaSingleton.gui == null:
		return
	var panel := $Panel if has_node("Panel") else null
	if panel != null:
		var style := StyleBoxFlat.new()
		style.bg_color = LuaSingleton.gui.background_color.lightened(0.05)
		style.border_color = LuaSingleton.gui.selection_color
		style.border_width_left = 1
		style.border_width_top = 1
		style.border_width_right = 1
		style.border_width_bottom = 1
		style.corner_radius_top_left = 8
		style.corner_radius_top_right = 0
		style.corner_radius_bottom_left = 8
		style.corner_radius_bottom_right = 0
		style.content_margin_left = 14
		style.content_margin_right = 14
		style.content_margin_top = 12
		style.content_margin_bottom = 12
		panel.add_theme_stylebox_override("panel", style)

	var text_color: Color = LuaSingleton.gui.font_color
	for label in _all_labels(self):
		label.add_theme_color_override("font_color", text_color)
	var lesson_buttons := _lesson_buttons.values()
	for button in _all_buttons(self):
		# Lesson buttons carry semantic colors (done = green, current =
		# selection) applied by panel_only_style; restyling must not stomp them.
		if lesson_buttons.has(button):
			continue
		button.add_theme_color_override("font_color", text_color)


func _all_labels(node: Node) -> Array:
	var out: Array = []
	for child in node.get_children():
		if child is Label:
			out.append(child)
		out.append_array(_all_labels(child))
	return out


func _all_buttons(node: Node) -> Array:
	var out: Array = []
	for child in node.get_children():
		if child is Button:
			out.append(child)
		out.append_array(_all_buttons(child))
	return out
