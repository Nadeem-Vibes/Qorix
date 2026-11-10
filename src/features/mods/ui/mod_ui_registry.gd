extends Control

## Mod UI registry: slots, mounted widgets, event routing, modals and layout
## overrides (Phase 2).
##
## The registry is host-owned. It is the only object that creates Controls for a
## mod, and it dispatches widget events back through ModManager into that mod's
## Lua task. Shell takeover is deliberately absent: Phase 2 mounts partial UI
## beside the editor, not in place of it.

signal widget_event(mod_id: String, widget_id: String, event: String, payload: Dictionary)
signal dialog_closed(mod_id: String, dialog_id: String)

const Result = preload("res://src/features/mods/mod_result.gd")
const Catalog = preload("res://src/features/mods/ui/mod_widget_catalog.gd")

const SLOTS := {
	"right": 4,
	"center": 4,
}
const EVENTS := ["click", "submit", "change", "select"]
const MAX_DIALOGS := 6
const MAX_HANDLERS := 8

var manager = null

var _dispatch: Callable = Callable()
var _notify: Callable = Callable()
var _set_core_visible: Callable = Callable()

var _right_column: VBoxContainer
var _center_column: VBoxContainer
var _modal_layer: Control
var _modal_stack: VBoxContainer

## id -> {id, local, mod_id, slot, spec, node}
var _mounts: Dictionary = {}
## widget id -> Control
var _nodes: Dictionary = {}
## widget id -> mod id
var _owners: Dictionary = {}
## widget id -> event -> [{handle, mod_id}]
var _handlers: Dictionary = {}
## [{id, mod_id, spec, node, catalog}]
var _dialogs: Array = []
## mod id -> panel -> previous visibility
var _layout: Dictionary = {}
var _next_mount: int = 0
var _next_dialog: int = 0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_right_column = VBoxContainer.new()
	_right_column.name = "ModDockRight"
	_right_column.set_anchors_and_offsets_preset(Control.PRESET_RIGHT_WIDE)
	_right_column.offset_left = -344.0
	_right_column.offset_right = -92.0
	_right_column.offset_top = 62.0
	_right_column.offset_bottom = -20.0
	_right_column.add_theme_constant_override("separation", 8)
	# Layout only. Qorix routes GUI clicks to the LAST control in tree
	# order, not the z_index, so a PASS strip would swallow every click inside
	# its rectangle (it was eating the buttons of the built-in course dock and
	# any other right-hand panel overlapping it). IGNORE lets empty space fall
	# through; mounted mod widgets still receive their own events.
	_right_column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_right_column)

	_center_column = VBoxContainer.new()
	_center_column.name = "ModDockCenter"
	# Full-rect with a top inset instead of a negative-height rect: anchored
	# to the top edge only, offset_bottom must stay >= offset_top.
	_center_column.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_center_column.offset_left = 360.0
	_center_column.offset_right = -360.0
	_center_column.offset_top = 80.0
	_center_column.offset_bottom = 0.0
	_center_column.alignment = BoxContainer.ALIGNMENT_BEGIN
	_center_column.add_theme_constant_override("separation", 8)
	_center_column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_center_column)

	_modal_layer = Control.new()
	_modal_layer.name = "ModModals"
	_modal_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_modal_layer.mouse_filter = Control.MOUSE_FILTER_STOP
	_modal_layer.visible = false
	add_child(_modal_layer)

	var dim := ColorRect.new()
	dim.name = "Dim"
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.02, 0.02, 0.04, 0.55)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_modal_layer.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_modal_layer.add_child(center)

	_modal_stack = VBoxContainer.new()
	_modal_stack.name = "Stack"
	_modal_stack.custom_minimum_size = Vector2(640, 0)
	_modal_stack.add_theme_constant_override("separation", 8)
	_modal_stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(_modal_stack)


## Called by the composition root after the node is in the tree.
func setup(context: Dictionary) -> void:
	if context.has("manager"):
		manager = context["manager"]
	if context.has("dispatch") and context["dispatch"] is Callable:
		_dispatch = context["dispatch"]
	if context.has("notify") and context["notify"] is Callable:
		_notify = context["notify"]
	if context.has("set_core_visible") and context["set_core_visible"] is Callable:
		_set_core_visible = context["set_core_visible"]


# ── SHELL ADOPTION ─────────────────────────────────────────────────────────

## A shell owns its own CanvasLayer, but its widgets use the same ids, event
## routing and `editor.ui.on` registration as a partial mount. The shell hands
## its built root here once; `release_tree` forgets it on exit.
func adopt_tree(mod_id: String, node: Node) -> void:
	if node == null or !is_instance_valid(node):
		return
	_index_nodes(str(mod_id), node)


func release_tree(node: Node) -> void:
	if node == null or !is_instance_valid(node):
		return
	_forget_widgets(node)


## Entry point the shell catalog uses for widget events. A partial mount uses
## the same path, so a mod cannot tell where its widget lives.
func dispatch_widget_event(widget_id: String, event: String, payload: Dictionary) -> void:
	_on_widget_event(str(widget_id), str(event), payload if payload is Dictionary else {})


# ── MOUNTS ──────────────────────────────────────────────────────────────────

func mount(mod_id: String, slot: String, spec: Dictionary) -> Dictionary:
	var key := str(slot)
	if !SLOTS.has(key):
		return Result.error("ui.widget_invalid", "'%s' is not a UI slot. Use one of: %s." % [slot, ", ".join(SLOTS.keys())])
	if _slot_count(key) >= int(SLOTS[key]):
		return Result.error("ui.slot_full", "The '%s' slot already holds %d widgets." % [key, int(SLOTS[key])])

	var validated := Catalog.validate(spec)
	if !validated.get("ok", false):
		return Result.error("ui.widget_invalid", str(validated.get("error", "The widget specification is invalid.")))

	var mount_spec := spec.duplicate(true)
	var local := str(mount_spec.get("id", ""))
	if local.is_empty():
		_next_mount += 1
		local = "_mount%d" % _next_mount
		mount_spec["id"] = local

	var id := mod_id + "." + local
	if _mounts.has(id):
		return Result.error("ui.widget_invalid", "A widget with the id '%s' is already mounted." % id)

	var catalog := Catalog.new({"on_event": Callable(self, "_on_widget_event")})
	var node := catalog.build(mount_spec, mod_id)
	node.set_meta("mod_widget_id", id)
	node.set_meta("mod_mount_id", id)
	node.name = "ModMount_" + _safe_name(local)

	(_right_column if key == "right" else _center_column).add_child(node)
	_mounts[id] = {
		"id": id,
		"local": local,
		"mod_id": mod_id,
		"slot": key,
		"spec": mount_spec,
		"node": node,
	}
	_index_nodes(mod_id, node)
	return Result.ok(id)


func update(mod_id: String, id: String, spec: Dictionary) -> Dictionary:
	var mount := _mount_for(mod_id, id)
	if mount.is_empty():
		return Result.error("ui.widget_invalid", "No mounted widget '%s' belongs to this mod." % id)

	var validated := Catalog.validate(spec)
	if !validated.get("ok", false):
		return Result.error("ui.widget_invalid", str(validated.get("error", "The widget specification is invalid.")))

	var mount_spec := spec.duplicate(true)
	mount_spec["id"] = str(mount.get("local", ""))
	var root: Control = mount["node"]
	# Widget ids are stable across an in-place update, so keep their event
	# handlers. `_prune_handlers` drops only ids that no longer exist.
	_forget_widgets(root, true)

	var catalog := Catalog.new({"on_event": Callable(self, "_on_widget_event")})
	var updated := catalog.apply(root, mount_spec, mod_id)
	if updated != root:
		var parent := root.get_parent()
		if parent != null:
			var index := root.get_index()
			parent.add_child(updated)
			parent.move_child(updated, index)
			root.queue_free()
	updated.set_meta("mod_widget_id", str(mount["id"]))
	updated.set_meta("mod_mount_id", str(mount["id"]))
	mount["node"] = updated
	mount["spec"] = mount_spec
	_index_nodes(mod_id, updated)
	_prune_handlers()
	return Result.ok(str(mount["id"]))


func unmount(mod_id: String, id: String) -> Dictionary:
	var mount := _mount_for(mod_id, id)
	if mount.is_empty():
		return Result.ok(false)

	var root: Control = mount["node"]
	_forget_widgets(root)
	_mounts.erase(str(mount["id"]))
	if is_instance_valid(root):
		root.queue_free()
	return Result.ok(true)


func set_widget_visible(mod_id: String, id: String, visible: bool) -> Dictionary:
	var mount := _mount_for(mod_id, id)
	if mount.is_empty():
		return Result.error("ui.widget_invalid", "No mounted widget '%s' belongs to this mod." % id)
	var root: Control = mount["node"]
	if is_instance_valid(root):
		root.visible = visible
	return Result.ok(true)


func focus(mod_id: String, id: String) -> Dictionary:
	var node := _node_for(mod_id, id)
	if node == null:
		return Result.error("ui.widget_invalid", "No widget '%s' belongs to this mod." % id)
	if node is Control:
		(node as Control).grab_focus()
	return Result.ok(true)


func on(mod_id: String, id: String, event: String, handle: int) -> Dictionary:
	var node := _node_for(mod_id, id)
	if node == null:
		return Result.error("ui.widget_invalid", "No widget '%s' belongs to this mod." % id)
	if !EVENTS.has(str(event)):
		return Result.error("ui.widget_invalid", "Unknown widget event '%s'." % str(event))
	if int(handle) <= 0:
		return Result.error("api.bad_args", "A widget handler needs a positive id.")

	var key := str(id)
	if !key.begins_with(mod_id + "."):
		key = mod_id + "." + key
	if !_handlers.has(key):
		_handlers[key] = {}
	if !(_handlers[key] as Dictionary).has(str(event)):
		_handlers[key][str(event)] = []
	var list: Array = _handlers[key][str(event)]
	if list.size() >= MAX_HANDLERS:
		return Result.error("ui.widget_invalid", "A widget event may have at most %d handlers." % MAX_HANDLERS)
	list.append({"handle": int(handle), "mod_id": mod_id})
	return Result.ok(true)


func notify(text: String, severity: String = "info") -> Dictionary:
	if _notify.is_valid():
		_notify.call(text, severity)
		return Result.ok(true)
	return Result.ok(false)


func theme_token(name: String) -> Dictionary:
	var key := str(name)
	var colors := {
		"background": "background_color",
		"foreground": "font_color",
		"selection": "selection_color",
		"current_line": "current_line_color",
		"caret": "caret_color",
		"accent": "selection_color",
		"error": "",
		"warning": "",
		"success": "",
	}
	if !colors.has(key):
		return Result.error("api.bad_args", "Unknown theme token '%s'." % key)

	var fallback := {
		"background": "#181825",
		"foreground": "#cdd6f4",
		"selection": "#585b70",
		"current_line": "#313244",
		"caret": "#f5e0dc",
		"accent": "#89b4fa",
		"error": "#f7768e",
		"warning": "#e0af68",
		"success": "#9ece6a",
	}
	if key == "error" or key == "warning" or key == "success":
		return Result.ok(str(fallback[key]))

	var property := str(colors[key])
	var lua = _lua_singleton()
	if lua != null and lua.gui != null:
		var value: Variant = lua.gui.get(property)
		if value is Color:
			return Result.ok("#" + (value as Color).to_html(false))
	return Result.ok(str(fallback[key]))


func _lua_singleton():
	var loop := Engine.get_main_loop()
	return loop.root.get_node_or_null("LuaSingleton") if loop != null else null


func set_core_panel_visible(mod_id: String, panel: String, visible: bool) -> Dictionary:
	if !_set_core_visible.is_valid():
		return Result.error("state.invalid", "Core panel visibility is not available.")
	var key := str(mod_id)
	var previous: Variant = _set_core_visible.call(str(panel), visible)
	if previous == null:
		return Result.error("api.bad_args", "Unknown core panel '%s'." % str(panel))

	if !_layout.has(key):
		_layout[key] = {}
	if !(_layout[key] as Dictionary).has(str(panel)):
		_layout[key][str(panel)] = bool(previous)
	return Result.ok(true)


# ── DIALOGS ─────────────────────────────────────────────────────────────────

func dialog(mod_id: String, spec: Dictionary) -> Dictionary:
	if _dialogs.size() >= MAX_DIALOGS:
		return Result.error("ui.slot_full", "At most %d modals can be open." % MAX_DIALOGS)

	_next_dialog += 1
	var id := mod_id + ".dialog." + str(_next_dialog)
	var card := _build_dialog(mod_id, id, spec)
	_modal_stack.add_child(card)
	_trap_focus(card)
	_index_nodes(mod_id, card)
	_dialogs.append({
		"id": id,
		"mod_id": mod_id,
		"spec": spec.duplicate(true),
		"node": card,
	})
	_nodes[id] = card
	_owners[id] = mod_id
	_refresh_modals()
	return Result.ok(id)


func close_dialog(mod_id: String, id: String) -> Dictionary:
	# Dialogs are stored oldest first. An explicit id closes that dialog;
	# an empty id closes the newest one for this mod.
	var target := ""
	for entry in _dialogs:
		if str(entry.get("mod_id", "")) != mod_id:
			continue
		if str(id).is_empty():
			target = str(entry.get("id", ""))
		elif str(entry.get("id", "")) == str(id):
			target = str(entry.get("id", ""))
			break
	if target.is_empty():
		return Result.ok(false)

	for index in range(_dialogs.size()):
		var entry: Dictionary = _dialogs[index]
		if str(entry.get("id", "")) != target:
			continue
		var node: Control = entry["node"]
		_forget_widgets(node)
		_nodes.erase(target)
		_owners.erase(target)
		_handlers.erase(target)
		_dialogs.remove_at(index)
		if is_instance_valid(node):
			node.queue_free()
		break

	_refresh_modals()
	dialog_closed.emit(mod_id, target)
	return Result.ok(true)


func dialog_count() -> int:
	return _dialogs.size()


## Phase 7 accessibility audit of the UI this host built for mods.
##
## It checks the mechanics the host controls: every interactive widget is
## keyboard-focusable and has a non-empty text or tooltip label, and tab order
## follows scene-tree order. It cannot replace a real screen-reader pass; it
## catches the common regressions in the declarative catalog before one ships.
func accessibility_audit() -> Dictionary:
	var issues: Array = []
	var widgets := 0
	var interactive := 0
	var focusable := 0

	var ids: Array = _nodes.keys()
	ids.sort()
	for raw_id in ids:
		var node: Variant = _nodes[raw_id]
		if !(node is Control) or !is_instance_valid(node):
			continue
		if node.is_queued_for_deletion():
			continue
		var control: Control = node
		widgets += 1
		if !_is_interactive(control):
			continue
		interactive += 1
		var widget_id := str(raw_id)
		if control.focus_mode != Control.FOCUS_ALL:
			issues.append({
				"id": widget_id,
				"problem": "not keyboard focusable",
			})
		else:
			focusable += 1
		if !_has_accessible_label(control):
			issues.append({
				"id": widget_id,
				"problem": "no text or tooltip label",
			})

	var ok := issues.is_empty()
	var detail := "%d widget(s), %d interactive, %d focusable; %d issue(s)." % [
		widgets, interactive, focusable, issues.size(),
	]
	if widgets == 0:
		detail = "No mod widgets are mounted in this session."
	return {
		"ok": ok,
		"widgets": widgets,
		"interactive": interactive,
		"focusable": focusable,
		"issues": issues,
		"detail": detail,
	}


func mount_count(mod_id: String = "") -> int:
	if str(mod_id).is_empty():
		return _mounts.size()
	var count := 0
	for mount in _mounts.values():
		if str((mount as Dictionary).get("mod_id", "")) == str(mod_id):
			count += 1
	return count


# ── RESET ───────────────────────────────────────────────────────────────────

func reset_mod(mod_id: String) -> void:
	for id in _mounts.keys().duplicate():
		var mount: Dictionary = _mounts[id]
		if str(mount.get("mod_id", "")) == mod_id:
			unmount(mod_id, str(id))

	for index in range(_dialogs.size() - 1, -1, -1):
		var entry: Dictionary = _dialogs[index]
		if str(entry.get("mod_id", "")) == mod_id:
			close_dialog(mod_id, str(entry.get("id", "")))

	if _layout.has(mod_id):
		for panel in (_layout[mod_id] as Dictionary).keys():
			if _set_core_visible.is_valid():
				_set_core_visible.call(str(panel), bool(_layout[mod_id][panel]))
		_layout.erase(mod_id)

	var stale: Array = []
	for id in _nodes.keys():
		if str(_owners.get(str(id), "")) == mod_id:
			stale.append(id)
	for id in stale:
		_nodes.erase(id)
		_owners.erase(id)
		_handlers.erase(id)


# ── INTERNALS ───────────────────────────────────────────────────────────────

func _on_widget_event(widget_id: String, event: String, payload: Dictionary) -> void:
	var mod_id := str(_owners.get(widget_id, ""))
	if mod_id.is_empty():
		return

	var detail := payload.duplicate(true)
	detail["source"] = widget_id
	detail["event"] = event

	var handlers: Variant = (_handlers.get(widget_id, {}) as Dictionary).get(event, [])
	for entry in handlers:
		var handler: Dictionary = entry
		if !_dispatch.is_valid():
			continue
		_dispatch.call(str(handler.get("mod_id", mod_id)), int(handler.get("handle", 0)), detail)

	widget_event.emit(mod_id, widget_id, event, detail)


## The engine's focus search is tree-global, so a modal's Tab key otherwise
## drifts into the editor behind the dim layer. Wire the dialog's focusable
## controls into a ring of next/previous neighbors — Tab and Shift+Tab then
## cycle inside the modal — and land focus on the first control.
func _trap_focus(card: Control) -> void:
	var focusables: Array[Control] = []
	_collect_focusables(card, focusables)
	var count := focusables.size()
	if count == 0:
		return
	for index in range(count):
		var current := focusables[index]
		current.focus_next = current.get_path_to(focusables[(index + 1) % count])
		current.focus_previous = current.get_path_to(focusables[(index - 1 + count) % count])
	focusables[0].grab_focus()


func _collect_focusables(node: Node, out: Array[Control]) -> void:
	for child in node.get_children():
		if child is Control:
			var control := child as Control
			if control.focus_mode != Control.FOCUS_NONE:
				out.append(control)
		_collect_focusables(child, out)


func _build_dialog(mod_id: String, id: String, spec: Dictionary) -> PanelContainer:
	var card := PanelContainer.new()
	card.name = "ModDialog"
	card.custom_minimum_size = Vector2(640, 0)
	card.add_theme_stylebox_override("panel", Catalog.panel_style())
	card.set_meta("mod_widget_id", id)
	card.set_meta("mod_type", "dialog")

	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 8)
	body.mouse_filter = Control.MOUSE_FILTER_STOP
	card.add_child(body)

	var title := Label.new()
	title.text = str(spec.get("title", "Mod"))
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", _theme_color("font_color", Color.WHITE))
	body.add_child(title)

	var text := str(spec.get("message", spec.get("text", "")))
	if !text.is_empty():
		var label := Label.new()
		label.text = text
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.add_theme_color_override("font_color", _theme_color("font_color", Color.WHITE))
		body.add_child(label)

	var content: Variant = spec.get("body")
	if content is Dictionary:
		var catalog := Catalog.new({"on_event": Callable(self, "_on_widget_event")})
		body.add_child(catalog.build(content, mod_id))
	elif spec.get("children") is Array:
		var catalog := Catalog.new({"on_event": Callable(self, "_on_widget_event")})
		body.add_child(catalog.build({"type": "vbox", "children": spec["children"]}, mod_id))

	var buttons: Array = _dialog_buttons(spec)
	if !buttons.is_empty():
		var row := HBoxContainer.new()
		row.alignment = BoxContainer.ALIGNMENT_END
		row.add_theme_constant_override("separation", 6)
		for definition in buttons:
			var data: Dictionary = definition
			var button := Button.new()
			button.text = str(data.get("label", "OK"))
			button.focus_mode = Control.FOCUS_ALL
			if bool(data.get("primary", false)):
				button.add_theme_color_override("font_color", _theme_color("selection_color", Color("#89b4fa")))
			var button_id := str(data.get("id", "ok"))
			button.pressed.connect(func() -> void:
				var values := _collect_values(card)
				var payload := {
					"button": button_id,
					"confirmed": button_id != "cancel" and button_id != "no",
					"values": values,
				}
				if values.has("value"):
					payload["value"] = values["value"]
				_on_widget_event(id, "click", payload)
				close_dialog(mod_id, id)
			)
			row.add_child(button)
		body.add_child(row)

	return card


func _dialog_buttons(spec: Dictionary) -> Array:
	if spec.get("buttons") is Array:
		var out: Array = []
		for item in spec["buttons"]:
			if item is Dictionary:
				out.append(item)
			else:
				out.append({"id": str(item), "label": str(item)})
		return out

	if spec.has("confirm") or spec.has("cancel"):
		return [
			{"id": "cancel", "label": str(spec.get("cancel", "Cancel"))},
			{"id": "confirm", "label": str(spec.get("confirm", "Confirm")), "primary": true},
		]

	return [{"id": "ok", "label": str(spec.get("ok", "OK")), "primary": true}]


## Collects field values from a dialog body before it closes. Widgets expose
## `mod_field` (the explicit `field` in the spec, or their local id), so a
## prompt callback receives the text the user typed.
func _collect_values(root: Node) -> Dictionary:
	var out: Dictionary = {}
	_collect_values_into(root, out)
	return out


func _collect_values_into(node: Node, out: Dictionary) -> void:
	var field := str(node.get_meta("mod_field", ""))
	if !field.is_empty():
		if node is LineEdit:
			out[field] = (node as LineEdit).text
		elif node is TextEdit:
			out[field] = (node as TextEdit).text
		elif node is CheckBox:
			out[field] = (node as CheckBox).button_pressed
		elif node is OptionButton:
			var option := node as OptionButton
			out[field] = option.get_item_metadata(option.selected) if option.selected >= 0 else ""
		elif node is SpinBox:
			out[field] = (node as SpinBox).value
		elif node is HSlider:
			out[field] = (node as HSlider).value
	for child in node.get_children():
		_collect_values_into(child, out)


func _refresh_modals() -> void:
	var visible := !_dialogs.is_empty()
	_modal_layer.visible = visible
	if visible:
		# Mod dialogs must sit above everything else in the HUD, including the
		# Mods settings page (which is added later in tree order). GUI clicks
		# resolve in tree order at equal z, so being the last child wins.
		move_to_front()
	for index in range(_dialogs.size()):
		var node: Control = (_dialogs[index] as Dictionary)["node"]
		if is_instance_valid(node):
			node.visible = index == _dialogs.size() - 1


func _mount_for(mod_id: String, id: String) -> Dictionary:
	if _mounts.has(str(id)):
		var direct: Dictionary = _mounts[str(id)]
		return direct if str(direct.get("mod_id", "")) == mod_id else {}
	var key := str(mod_id) + "." + str(id)
	var found: Variant = _mounts.get(key)
	return found if found is Dictionary else {}


func _node_for(mod_id: String, id: String) -> Node:
	var key := str(id)
	if !key.begins_with(mod_id + "."):
		key = mod_id + "." + key
	if !_nodes.has(key):
		return null
	var node: Variant = _nodes[key]
	if !(node is Node) or !is_instance_valid(node):
		return null
	return node as Node


func _index_nodes(mod_id: String, node: Node) -> void:
	# Removed children are queued for deletion but stay in the tree until the
	# frame ends. Do not re-index them, or their handlers would outlive them.
	if node == null or !is_instance_valid(node) or node.is_queued_for_deletion():
		return
	var widget_id := str(node.get_meta("mod_widget_id", ""))
	if !widget_id.is_empty():
		_nodes[widget_id] = node
		_owners[widget_id] = mod_id
	for child in node.get_children():
		_index_nodes(mod_id, child)


func _forget_widgets(node: Node, keep_handlers: bool = false) -> void:
	var widget_id := str(node.get_meta("mod_widget_id", ""))
	if !widget_id.is_empty():
		_nodes.erase(widget_id)
		_owners.erase(widget_id)
		if !keep_handlers:
			_handlers.erase(widget_id)
	for child in node.get_children():
		_forget_widgets(child, keep_handlers)


func _prune_handlers() -> void:
	for widget_id in _handlers.keys():
		if !_nodes.has(widget_id):
			_handlers.erase(widget_id)


func _is_interactive(node: Control) -> bool:
	return node is Button or node is CheckBox or node is HSlider or node is SpinBox \
		or node is LineEdit or node is TextEdit or node is OptionButton or node is TabBar


func _has_accessible_label(node: Control) -> bool:
	var tooltip := str(node.tooltip_text).strip_edges()
	if !tooltip.is_empty():
		return true
	if node is Button:
		return !str((node as Button).text).strip_edges().is_empty()
	if node is CheckBox:
		return !str((node as CheckBox).text).strip_edges().is_empty()
	if node is LineEdit:
		return !str((node as LineEdit).placeholder_text).strip_edges().is_empty()
	if node is TextEdit:
		return true
	if node is OptionButton:
		return (node as OptionButton).item_count > 0
	if node is TabBar:
		return (node as TabBar).tab_count > 0
	# Sliders and spin boxes have no text of their own; their tooltip is the
	# only host-visible label.
	return false


func _slot_count(slot: String) -> int:
	var count := 0
	for mount in _mounts.values():
		if str((mount as Dictionary).get("slot", "")) == slot:
			count += 1
	return count


func _safe_name(value: String) -> String:
	var out := ""
	for index in range(value.length()):
		var character := value[index]
		if character.is_valid_identifier() or character == "_" or character.is_valid_int():
			out += character
	return out if !out.is_empty() else "Widget"


func _theme_color(property: String, fallback: Color) -> Color:
	var lua = _lua_singleton()
	if lua == null or lua.gui == null:
		return fallback
	var value: Variant = lua.gui.get(property)
	return value if value is Color else fallback
