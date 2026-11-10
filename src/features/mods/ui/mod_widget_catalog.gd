extends RefCounted

## Declarative widget catalog and reconciler (Phase 2).
##
## A mod sends JSON-shaped specs; this class turns them into Godot Controls and
## updates existing nodes in place when the spec changes. No engine object ever
## crosses the Lua boundary: the UI registry keeps ids and this class owns nodes.
##
## Spec:
##   { type = "panel", id = "counter", title = "Counter", spacing = 6,
##     children = [ { type = "label", text = "..." }, ... ] }
##
## Containers: panel, vbox, hbox, grid, scroll.
## Leaves: label, heading, richtext, button, checkbox, slider, spin, progress,
##         separator, divider, spacer, input, text, option, badge, code_block,
##         tabs, canvas.
## Shell-only: editor (a reserved rectangle; the host frames the world there).
##
## Phase 3 adds `width`, `height` and `grow` so a shell layout can express the
## plan's hbox/vbox example without inventing properties.

const ModCanvas = preload("res://src/features/mods/ui/mod_canvas.gd")

const MAX_WIDGETS := 200
const MAX_DEPTH := 8

const TYPES := [
	"panel", "vbox", "hbox", "grid", "scroll",
	"label", "heading", "richtext", "button", "checkbox", "slider", "spin",
	"progress", "separator", "divider", "spacer", "input", "text", "option",
	"badge", "code_block", "tabs", "canvas", "editor",
]

const CONTAINERS := ["panel", "vbox", "hbox", "grid", "scroll"]

var _context: Dictionary = {}
var _count: int = 0
var _auto: int = 0


func _init(context: Dictionary = {}) -> void:
	_context = context


func build(spec: Dictionary, id_prefix: String) -> Control:
	_count = 0
	_auto = 0
	return _build(spec, id_prefix, 0)


func apply(node: Control, spec: Dictionary, id_prefix: String) -> Control:
	_count = 0
	_auto = 0
	if node == null or !is_instance_valid(node):
		return _build(spec, id_prefix, 0)
	if str(node.get_meta("mod_type", "")) != str(spec.get("type", "panel")):
		node.queue_free()
		return _build(spec, id_prefix, 0)

	_apply_node(node, spec, id_prefix, 0)
	return node


## Recursively checks shape, types, depth and the widget budget. UI validation
## happens before any node is created, so a bad mount cannot leave half a panel
## behind.
static func validate(spec: Variant) -> Dictionary:
	if !(spec is Dictionary):
		return {"ok": false, "error": "A widget specification must be an object."}
	var state := {"count": 0}
	var error := _validate_node(spec as Dictionary, 0, state)
	if !error.is_empty():
		return {"ok": false, "error": error}
	return {"ok": true, "error": ""}


static func _validate_node(spec: Dictionary, depth: int, state: Dictionary) -> String:
	if depth > MAX_DEPTH:
		return "Widget nesting is limited to %d levels." % MAX_DEPTH
	state["count"] = int(state["count"]) + 1
	if int(state["count"]) > MAX_WIDGETS:
		return "A mount is limited to %d widgets." % MAX_WIDGETS

	var type := str(spec.get("type", "panel"))
	if !TYPES.has(type):
		return "'%s' is not a widget type." % type
	if spec.has("id") and typeof(spec["id"]) != TYPE_STRING:
		return "Widget ids must be strings."
	# Reject children on non-containers: they would never be built, and the
	# mod gets a silent no-op otherwise.
	if spec.has("children") and !CONTAINERS.has(type):
		return "'%s' cannot have children." % type

	if spec.has("children"):
		if !(spec["children"] is Array):
			return "children must be an array."
		for child in spec["children"]:
			if !(child is Dictionary):
				return "Every child must be an object."
			var child_error := _validate_node(child as Dictionary, depth + 1, state)
			if !child_error.is_empty():
				return child_error

	return ""


# ── BUILD ───────────────────────────────────────────────────────────────────

func _build(spec: Dictionary, id_prefix: String, depth: int) -> Control:
	_count += 1
	var type := str(spec.get("type", "panel"))
	var local := _local_id(spec)
	var global := id_prefix + "." + local if !id_prefix.is_empty() else local

	var node := _create_node(type)
	node.name = "ModWidget_" + _safe_name(local)
	node.set_meta("mod_type", type)
	node.set_meta("mod_widget_id", global)
	node.set_meta("mod_local_id", local)
	node.set_meta("mod_prefix", id_prefix)
	node.set_meta("mod_field", str(spec.get("field", local)))

	if CONTAINERS.has(type):
		var body := _container_body(node, type)
		node.set_meta("mod_body", body)
		for child in _children(spec):
			if _count >= MAX_WIDGETS:
				break
			var built_child := _build(child, id_prefix, depth + 1)
			body.add_child(built_child)
			_configure_label_layout(built_child, child)

	_apply_node(node, spec, id_prefix, depth)
	_connect_events(node, type, global)
	return node


func _create_node(type: String) -> Control:
	match type:
		"panel":
			var panel := PanelContainer.new()
			panel.add_theme_stylebox_override("panel", panel_style())
			panel.mouse_filter = Control.MOUSE_FILTER_STOP
			var frame := VBoxContainer.new()
			frame.name = "Frame"
			frame.add_theme_constant_override("separation", 6)
			var body := VBoxContainer.new()
			body.name = "Body"
			body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			body.size_flags_vertical = Control.SIZE_EXPAND_FILL
			body.add_theme_constant_override("separation", 6)
			frame.add_child(body)
			panel.add_child(frame)
			panel.set_meta("mod_frame", frame)
			panel.set_meta("mod_body", body)
			return panel
		"vbox":
			var box := VBoxContainer.new()
			box.add_theme_constant_override("separation", 6)
			# Containers are layout only. Leaving them on STOP made a shell's
			# column swallow clicks that should reach the editor slot.
			box.mouse_filter = Control.MOUSE_FILTER_IGNORE
			return box
		"hbox":
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 6)
			row.mouse_filter = Control.MOUSE_FILTER_IGNORE
			return row
		"grid":
			var grid := GridContainer.new()
			grid.columns = 2
			grid.add_theme_constant_override("h_separation", 6)
			grid.add_theme_constant_override("v_separation", 6)
			grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
			return grid
		"scroll":
			var scroll := ScrollContainer.new()
			scroll.custom_minimum_size = Vector2(0, 120)
			var inner := VBoxContainer.new()
			inner.name = "Body"
			inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			inner.add_theme_constant_override("separation", 6)
			scroll.add_child(inner)
			return scroll
		"label":
			var label := Label.new()
			label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			return label
		"heading":
			var heading := Label.new()
			heading.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			heading.add_theme_font_size_override("font_size", 20)
			return heading
		"richtext":
			var rich := RichTextLabel.new()
			rich.bbcode_enabled = true
			rich.fit_content = true
			rich.scroll_active = false
			return rich
		"button":
			var button := Button.new()
			button.focus_mode = Control.FOCUS_ALL
			return button
		"tabs":
			var tabs := TabBar.new()
			tabs.focus_mode = Control.FOCUS_ALL
			return tabs
		"canvas":
			var canvas := ModCanvas.new()
			canvas.custom_minimum_size = Vector2(120, 60)
			canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
			return canvas
		"editor":
			# A reserved rectangle, never a parent for the CodeEdit. The shell
			# reads its rect and the camera frames the world inside it.
			var slot := Control.new()
			slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
			slot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			slot.size_flags_vertical = Control.SIZE_EXPAND_FILL
			slot.custom_minimum_size = Vector2(160, 120)
			return slot
		"checkbox":
			var check := CheckBox.new()
			check.focus_mode = Control.FOCUS_ALL
			return check
		"slider":
			var slider := HSlider.new()
			slider.min_value = 0
			slider.max_value = 100
			slider.step = 1
			slider.focus_mode = Control.FOCUS_ALL
			return slider
		"spin":
			var spin := SpinBox.new()
			spin.min_value = 0
			spin.max_value = 100
			spin.step = 1
			return spin
		"progress":
			var progress := ProgressBar.new()
			progress.max_value = 100
			progress.value = 0
			progress.show_percentage = false
			return progress
		"separator":
			return HSeparator.new()
		"divider":
			return VSeparator.new()
		"spacer":
			var space := Control.new()
			space.custom_minimum_size = Vector2(0, 8)
			return space
		"input":
			var input := LineEdit.new()
			input.focus_mode = Control.FOCUS_ALL
			return input
		"text":
			var text := TextEdit.new()
			text.custom_minimum_size = Vector2(0, 96)
			text.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
			return text
		"option":
			var option := OptionButton.new()
			option.focus_mode = Control.FOCUS_ALL
			return option
		"badge":
			var badge := PanelContainer.new()
			badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
			var badge_style := StyleBoxFlat.new()
			badge_style.bg_color = Color(0.24, 0.32, 0.48, 0.9)
			badge_style.set_corner_radius_all(4)
			badge_style.content_margin_left = 6
			badge_style.content_margin_right = 6
			badge_style.content_margin_top = 1
			badge_style.content_margin_bottom = 1
			badge.add_theme_stylebox_override("panel", badge_style)
			var badge_label := Label.new()
			badge_label.name = "BadgeText"
			badge_label.add_theme_font_size_override("font_size", 11)
			badge.add_child(badge_label)
			return badge
		"code_block":
			var block := PanelContainer.new()
			block.add_theme_stylebox_override("panel", panel_style())
			block.mouse_filter = Control.MOUSE_FILTER_IGNORE
			var block_label := Label.new()
			block_label.name = "CodeText"
			block_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			block_label.add_theme_font_size_override("font_size", 13)
			block.add_child(block_label)
			return block

	return Control.new()


func _container_body(node: Control, type: String) -> Control:
	if type == "panel":
		var stored: Variant = node.get_meta("mod_body", null)
		if stored is Control:
			return stored as Control
		return node.get_child(0) as Control
	if type == "scroll":
		return node.get_child(0) as Control
	# vbox and hbox are their own body.
	return node


func _apply_node(node: Control, spec: Dictionary, id_prefix: String, depth: int) -> void:
	var type := str(spec.get("type", "panel"))

	if spec.has("visible"):
		node.visible = bool(spec["visible"])
	if spec.has("tooltip") or spec.has("hint"):
		node.tooltip_text = str(spec.get("tooltip", spec.get("hint", "")))
	if spec.has("disabled") and _has_property(node, "disabled"):
		node.set("disabled", bool(spec["disabled"]))
	if spec.has("min_width") or spec.has("min_height") or spec.has("width") or spec.has("height"):
		node.custom_minimum_size = Vector2(
			float(spec.get("width", spec.get("min_width", node.custom_minimum_size.x))),
			float(spec.get("height", spec.get("min_height", node.custom_minimum_size.y))),
		)
	if spec.has("expand") and node is Control:
		(node as Control).size_flags_horizontal = Control.SIZE_EXPAND_FILL if bool(spec["expand"]) else Control.SIZE_SHRINK_BEGIN
	if spec.has("grow") and node is Control:
		var grow := float(spec.get("grow", 0.0)) > 0.0
		(node as Control).size_flags_horizontal = Control.SIZE_EXPAND_FILL if grow else Control.SIZE_SHRINK_BEGIN
		(node as Control).size_flags_vertical = Control.SIZE_EXPAND_FILL if grow else Control.SIZE_SHRINK_BEGIN

	if spec.has("color") and (node is Label or node is RichTextLabel):
		var color := Color.from_string(str(spec["color"]), _theme_color("font_color", Color.WHITE))
		if node is Label:
			(node as Label).add_theme_color_override("font_color", color)
		else:
			(node as RichTextLabel).add_theme_color_override("default_color", color)
	if spec.has("font_size") and (node is Label or node is Button):
		node.add_theme_font_size_override("font_size", int(spec["font_size"]))

	match type:
		"panel":
			_apply_panel(node as PanelContainer, spec, id_prefix)
		"vbox", "hbox":
			var box := node as BoxContainer
			box.add_theme_constant_override("separation", int(spec.get("spacing", 6)))
			var body := node.get_meta("mod_body", node) as Control
			_apply_children(body, _children(spec), id_prefix, depth)
		"grid":
			var grid := node as GridContainer
			if spec.has("columns"):
				grid.columns = maxi(1, int(spec["columns"]))
			var body := node.get_meta("mod_body", node) as Control
			_apply_children(body, _children(spec), id_prefix, depth)
		"scroll":
			var body := node.get_meta("mod_body", node) as Control
			_apply_children(body, _children(spec), id_prefix, depth)
		"label", "heading", "button", "checkbox":
			if spec.has("text"):
				if node is Label:
					(node as Label).text = str(spec["text"])
				elif node is Button:
					(node as Button).text = str(spec["text"])
				elif node is CheckBox:
					(node as CheckBox).text = str(spec["text"])
			if spec.has("align") and node is Label:
				(node as Label).horizontal_alignment = _alignment(str(spec["align"]))
			if spec.has("checked") and node is CheckBox:
				_set_blocked(node, "button_pressed", bool(spec["checked"]))
		"badge":
			var badge_label := node.get_node_or_null("BadgeText")
			if badge_label is Label and spec.has("text"):
				(badge_label as Label).text = str(spec["text"])
		"code_block":
			var code_label := node.get_node_or_null("CodeText")
			if code_label is Label and spec.has("text"):
				(code_label as Label).text = str(spec["text"])
			if code_label is Label and spec.has("font_size"):
				(code_label as Label).add_theme_font_size_override("font_size", int(spec["font_size"]))
		"tabs":
			_apply_tabs(node as TabBar, spec)
		"canvas":
			(node as ModCanvas).set_ops(spec.get("ops", []))
		"editor":
			pass
		"richtext":
			if spec.has("text"):
				(node as RichTextLabel).text = _sanitize_mod_bbcode(str(spec["text"]))
		"slider":
			var slider := node as HSlider
			slider.min_value = float(spec.get("min", slider.min_value))
			slider.max_value = float(spec.get("max", slider.max_value))
			slider.step = maxf(0.0001, float(spec.get("step", slider.step)))
			if spec.has("value"):
				_set_blocked(slider, "value", float(spec["value"]))
		"spin":
			var spin := node as SpinBox
			spin.min_value = float(spec.get("min", spin.min_value))
			spin.max_value = float(spec.get("max", spin.max_value))
			spin.step = maxf(0.0001, float(spec.get("step", spin.step)))
			if spec.has("value"):
				_set_blocked(spin, "value", float(spec["value"]))
		"progress":
			var progress := node as ProgressBar
			progress.max_value = float(spec.get("max", 100.0))
			if spec.has("value"):
				_set_blocked(progress, "value", float(spec["value"]))
		"spacer":
			var space := node as Control
			space.custom_minimum_size = Vector2(
				float(spec.get("width", 0)),
				float(spec.get("height", spec.get("size", 8))),
			)
		"input":
			var input := node as LineEdit
			if spec.has("placeholder"):
				input.placeholder_text = str(spec["placeholder"])
			if spec.has("editable"):
				input.editable = bool(spec["editable"])
			if spec.has("text") and input.text != str(spec["text"]):
				input.text = str(spec["text"])
		"text":
			var editor := node as TextEdit
			if spec.has("editable"):
				editor.editable = bool(spec["editable"])
			if spec.has("text") and editor.text != str(spec["text"]):
				editor.text = str(spec["text"])
		"option":
			_apply_options(node as OptionButton, spec)


func _apply_panel(panel: PanelContainer, spec: Dictionary, id_prefix: String) -> void:
	panel.add_theme_stylebox_override("panel", panel_style())

	var body: Control = panel.get_meta("mod_body") as Control if panel.has_meta("mod_body") else null
	if body == null:
		return
	var frame: Control = panel.get_meta("mod_frame") as Control if panel.has_meta("mod_frame") else null
	if frame == null:
		# Migrate a panel built by the pre-frame catalog: body was the only
		# child before a title row could be inserted beside it.
		frame = VBoxContainer.new()
		frame.name = "Frame"
		frame.add_theme_constant_override("separation", 6)
		if body.get_parent() != null:
			body.get_parent().remove_child(body)
		frame.add_child(body)
		panel.add_child(frame)
		panel.set_meta("mod_frame", frame)

	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	(body as BoxContainer).add_theme_constant_override("separation", int(spec.get("spacing", 6)))

	var title := str(spec.get("title", ""))
	var title_row: Control = panel.get_meta("mod_title_row") as Control if panel.has_meta("mod_title_row") else null
	if title_row != null and title_row.get_parent() != frame:
		if title_row.get_parent() != null:
			title_row.get_parent().remove_child(title_row)
		frame.add_child(title_row)
		frame.move_child(title_row, 0)
	if !title.is_empty():
		if title_row == null:
			var row := VBoxContainer.new()
			row.name = "TitleRow"
			row.add_theme_constant_override("separation", 2)

			var label := Label.new()
			label.name = "Title"
			label.add_theme_color_override("font_color", _theme_color("font_color", Color.WHITE))
			label.add_theme_font_size_override("font_size", int(spec.get("title_size", 14)))
			row.add_child(label)
			row.add_child(HSeparator.new())

			frame.add_child(row)
			frame.move_child(row, 0)
			panel.set_meta("mod_title_row", row)
			title_row = row
		(title_row.get_node("Title") as Label).text = title
		title_row.visible = true
	elif title_row != null:
		title_row.visible = false

	_apply_children(body, _children(spec), id_prefix, 1)


## Autowrapping labels have a one-pixel minimum width. That is fine inside a
## vertical stack, but in a row it makes a title wrap one letter per line and
## stretches the whole row. Row labels keep their text width unless the spec
## explicitly gives them a width or asks them to grow; `wrap = true` is the
## explicit opt-in for a wrapping row label.
func _configure_label_layout(node: Control, spec: Dictionary) -> void:
	var type := str(spec.get("type", ""))
	if type != "label" and type != "heading":
		return
	if !(node is Label):
		return
	var label := node as Label
	var explicit: Variant = spec.get("wrap", null)
	if explicit is bool:
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART if bool(explicit) else TextServer.AUTOWRAP_OFF
		return

	var parent := node.get_parent()
	var in_row := parent is HBoxContainer or parent is GridContainer
	var sized := spec.has("width") or spec.has("min_width") or bool(spec.get("expand", false)) or float(spec.get("grow", 0.0)) > 0.0
	label.autowrap_mode = TextServer.AUTOWRAP_OFF if in_row and !sized else TextServer.AUTOWRAP_WORD_SMART


func _apply_children(body: Control, children: Array, id_prefix: String, depth: int) -> void:
	var existing := body.get_children()
	var used: Array = []
	# Reuse candidates are matched by the mod's widget id first. An index-only
	# match fed node A's state into node B when the spec reordered two
	# same-type children. Auto-generated ids are positional by definition, so
	# they still fall back to index matching.
	var by_id: Dictionary = {}
	for child in existing:
		var widget_id := str(child.get_meta("mod_widget_id", ""))
		if !widget_id.is_empty() and !by_id.has(widget_id):
			by_id[widget_id] = child

	for index in range(children.size()):
		var child_spec: Dictionary = children[index]
		var child_type := str(child_spec.get("type", "panel"))

		var candidate: Node = null
		var local_id := str(child_spec.get("id", ""))
		if !local_id.is_empty():
			var global_id := id_prefix + "." + local_id if !id_prefix.is_empty() else local_id
			if by_id.has(global_id):
				var id_match := by_id[global_id] as Node
				if !used.has(id_match) and str(id_match.get_meta("mod_type", "")) == child_type:
					candidate = id_match
		if candidate == null and index < existing.size():
			var index_match := existing[index]
			if index_match is Control and !used.has(index_match) \
					and str(index_match.get_meta("mod_type", "")) == child_type:
				candidate = index_match

		if candidate is Control:
			body.move_child(candidate, index)
			_apply_node(candidate as Control, child_spec, id_prefix, depth + 1)
			_configure_label_layout(candidate as Control, child_spec)
			used.append(candidate)
		else:
			if _count >= MAX_WIDGETS:
				break
			var created := _build(child_spec, id_prefix, depth + 1)
			body.add_child(created)
			body.move_child(created, index)
			_configure_label_layout(created, child_spec)
			used.append(created)

	for child in existing:
		if !used.has(child) and !child.is_queued_for_deletion():
			child.queue_free()


## Escapes the tag openers that could load local files ([img], [font=...]);
## every other tag stays available for mod formatting.
static func _sanitize_mod_bbcode(text: String) -> String:
	var out := text
	for needle in ["[img", "[font", "[/img", "[/font"]:
		var index := 0
		while true:
			var found := out.findn(needle, index)
			if found == -1:
				break
			out = out.substr(0, found) + "[lb]" + out.substr(found + 1)
			index = found + 4
	return out


func _children(spec: Dictionary) -> Array:
	var value: Variant = spec.get("children", [])
	return value if value is Array else []


func _apply_tabs(tabs: TabBar, spec: Dictionary) -> void:
	var titles: Array = []
	var raw: Variant = spec.get("items", spec.get("tabs", []))
	if raw is Array:
		for item in raw:
			if item is Dictionary:
				titles.append(str((item as Dictionary).get("text", (item as Dictionary).get("label", ""))))
			else:
				titles.append(str(item))

	var signature := ",".join(titles)
	if str(tabs.get_meta("mod_tabs", "")) != signature:
		while tabs.tab_count > 0:
			tabs.remove_tab(0)
		for title in titles:
			tabs.add_tab(str(title))
		tabs.set_meta("mod_tabs", signature)

	if spec.has("current"):
		_set_blocked(tabs, "current_tab", clampi(int(spec["current"]), 0, maxi(0, tabs.tab_count - 1)))


func _apply_options(option: OptionButton, spec: Dictionary) -> void:
	var entries: Array = []
	var raw: Variant = spec.get("options", [])
	if raw is Array:
		for item in raw:
			if item is Dictionary:
				entries.append({"label": str(item.get("label", item.get("id", ""))), "value": item.get("value", item.get("id", ""))})
			else:
				entries.append({"label": str(item), "value": str(item)})

	var signature := JSON.stringify(entries)
	if str(option.get_meta("mod_options", "")) != signature:
		option.clear()
		for entry in entries:
			option.add_item(str(entry["label"]))
			option.set_item_metadata(option.item_count - 1, entry["value"])
		option.set_meta("mod_options", signature)

	if spec.has("selected"):
		_set_blocked(option, "selected", clampi(int(spec["selected"]), 0, maxi(0, option.item_count - 1)))
	elif spec.has("value"):
		for index in range(option.item_count):
			if str(option.get_item_metadata(index)) == str(spec["value"]):
				_set_blocked(option, "selected", index)
				break


func _connect_events(node: Control, type: String, global: String) -> void:
	var context := _context
	if context.is_empty():
		return
	var emit := Callable(context.get("on_event", Callable()))

	match type:
		"button":
			(node as Button).pressed.connect(func() -> void:
				_emit(emit, global, "click", {"value": (node as Button).text})
			)
		"checkbox":
			(node as CheckBox).toggled.connect(func(pressed: bool) -> void:
				_emit(emit, global, "change", {"checked": pressed})
			)
		"slider":
			(node as HSlider).value_changed.connect(func(value: float) -> void:
				_emit(emit, global, "change", {"value": value})
			)
		"spin":
			(node as SpinBox).value_changed.connect(func(value: float) -> void:
				_emit(emit, global, "change", {"value": value})
			)
		"input":
			(node as LineEdit).text_submitted.connect(func(value: String) -> void:
				_emit(emit, global, "submit", {"text": value})
			)
			(node as LineEdit).focus_exited.connect(func() -> void:
				_emit(emit, global, "change", {"text": (node as LineEdit).text})
			)
		"option":
			(node as OptionButton).item_selected.connect(func(index: int) -> void:
				var option := node as OptionButton
				_emit(emit, global, "select", {
					"index": index,
					"text": option.get_item_text(index) if index >= 0 and index < option.item_count else "",
					"value": option.get_item_metadata(index) if index >= 0 and index < option.item_count else null,
				})
			)
		"tabs":
			(node as TabBar).tab_changed.connect(func(index: int) -> void:
				var tabs := node as TabBar
				_emit(emit, global, "select", {
					"index": index,
					"text": tabs.get_tab_title(index) if index >= 0 and index < tabs.tab_count else "",
				})
			)


func _emit(callback: Callable, widget_id: String, event: String, payload: Dictionary) -> void:
	if callback.is_valid():
		callback.call(widget_id, event, payload)


func _local_id(spec: Dictionary) -> String:
	var explicit := str(spec.get("id", ""))
	if !explicit.is_empty():
		return explicit
	_auto += 1
	return "_auto%d" % _auto


func _safe_name(value: String) -> String:
	var out := ""
	for index in range(value.length()):
		var character := value[index]
		if character.is_valid_identifier() or character == "_" or character.is_valid_int():
			out += character
	return out if !out.is_empty() else "Widget"


func _alignment(value: String) -> HorizontalAlignment:
	match value.to_lower():
		"center":
			return HORIZONTAL_ALIGNMENT_CENTER
		"right":
			return HORIZONTAL_ALIGNMENT_RIGHT
		_:
			return HORIZONTAL_ALIGNMENT_LEFT


func _has_property(node: Object, property: String) -> bool:
	for entry in node.get_property_list():
		if str(entry.get("name", "")) == property:
			return true
	return false


func _set_blocked(node: Object, property: String, value: Variant) -> void:
	node.set_block_signals(true)
	node.set(property, value)
	node.set_block_signals(false)


# ── THEME ───────────────────────────────────────────────────────────────────

static func panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.corner_radius_top_left = 5
	style.corner_radius_top_right = 5
	style.corner_radius_bottom_left = 5
	style.corner_radius_bottom_right = 5
	style.border_width_left = 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.bg_color = _theme_color("background_color", Color("#181825"))
	style.border_color = _theme_color("current_line_color", Color("#313244"))
	return style


static func _lua_singleton():
	var loop := Engine.get_main_loop()
	return loop.root.get_node_or_null("LuaSingleton") if loop != null else null


static func _theme_color(property: String, fallback: Color) -> Color:
	var lua = _lua_singleton()
	if lua == null or lua.gui == null:
		return fallback
	var value: Variant = lua.gui.get(property)
	return value if value is Color else fallback
