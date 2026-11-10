extends CanvasLayer

## The shell's own layer: host chrome, the declarative layout and the reserved
## editor rectangle.
##
## It sits above the core HUD (layer 100). The layout is built by the widget
## catalog with the mod id as its id prefix, so `editor.ui.on` addresses shell
## widgets exactly like partial mounts. The host chrome is a child of this layer,
## added before the content and reserved above it; the layout cannot hide it.
##
## Insets are recomputed from the reserved `editor` widget every frame and only
## emitted when they change. That keeps a window resize and a widget diff in the
## same path, without polling the camera.
##
## Keyboard focus returns to the code view when the shell holds an editor slot
## and after every shell widget event: buttons in the shell keep their own
## focus, and a learning course must not strand the typing surface behind them.

signal insets_changed(insets: Dictionary)
signal exit_requested

const Chrome = preload("res://src/features/mods/shell/shell_chrome.gd")
const Snapshot = preload("res://src/features/mods/shell/shell_snapshot.gd")
const Catalog = preload("res://src/features/mods/ui/mod_widget_catalog.gd")

const CHROME_HEIGHT := 34.0
const LAYER := 100

var mod_id := ""
var ui = null

var _chrome: Control
var _root: Control
var _content: Control
var _built: Control
var _catalog = null
var _editors: Array = []
var _last_insets: Dictionary = {}
## Hands the keyboard back to the code view (a Callable with no arguments,
## provided by the host as `restore_editor_focus`). A shell that owns the
## screen must not leave the focus stranded on a shell button: the code view
## is the typing surface.
var _restore_focus: Callable = Callable()


func setup(layout_spec: Dictionary, mod_name: String, owner_id: String, ui_registry = null, on_exit: Callable = Callable(), restore_focus: Callable = Callable()) -> void:
	name = "ModShell"
	layer = LAYER
	mod_id = str(owner_id)
	ui = ui_registry

	_chrome = Chrome.new()
	_chrome.setup(mod_name)
	_chrome.exit_requested.connect(_request_exit)
	add_child(_chrome)

	_root = Control.new()
	_root.name = "Root"
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_root)

	_content = Control.new()
	_content.name = "Content"
	_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_content.offset_top = CHROME_HEIGHT
	_root.add_child(_content)

	_catalog = Catalog.new({"on_event": Callable(self, "_on_widget_event")})
	_built = _catalog.build(layout_spec, mod_id)
	_built.name = "Layout"
	_built.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# The built tree must not swallow clicks over the reserved editor slot.
	# Panels and interactive widgets still stop input; layout containers pass
	# it through to the real CodeEdit in the world behind the shell.
	_built.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_content.add_child(_built)

	if ui != null and ui.has_method("adopt_tree"):
		ui.adopt_tree(mod_id, _built)
	if on_exit.is_valid():
		exit_requested.connect(func() -> void: on_exit.call())

	_restore_focus = restore_focus

	_collect_editors(_built)
	if !_editors.is_empty():
		_restore_editor_focus()
	set_process(true)


func teardown() -> void:
	set_process(false)
	if ui != null and ui.has_method("release_tree") and _built != null:
		ui.release_tree(_built)
	if _built != null and is_instance_valid(_built):
		_built.queue_free()
	_built = null
	if _chrome != null and is_instance_valid(_chrome):
		_chrome.queue_free()
	_chrome = null
	if _root != null and is_instance_valid(_root):
		_root.queue_free()
	_root = null
	_content = null
	_editors.clear()


func editor_widget_count() -> int:
	return _editors.size()


func content_height() -> float:
	return maxf(0.0, get_viewport().get_visible_rect().size.y - CHROME_HEIGHT)


func _process(_delta: float) -> void:
	if !is_inside_tree():
		return
	var next := current_insets()
	if next != _last_insets:
		_last_insets = next
		insets_changed.emit(next.duplicate(true))


func current_insets() -> Dictionary:
	var editor := _visible_editor()
	if editor == null:
		return Snapshot.empty_insets()
	var viewport := get_viewport()
	if viewport == null:
		return Snapshot.empty_insets()
	return Snapshot.insets_for(editor.get_global_rect(), viewport.get_visible_rect().size)


func layout_root() -> Control:
	return _built


func _visible_editor() -> Control:
	for widget in _editors:
		if widget is Control and is_instance_valid(widget) and (widget as Control).is_visible_in_tree():
			return widget as Control
	return null


func _collect_editors(node: Node) -> void:
	if str(node.get_meta("mod_type", "")) == "editor":
		_editors.append(node)
	for child in node.get_children():
		_collect_editors(child)


func _on_widget_event(widget_id: String, event: String, payload: Dictionary) -> void:
	if ui != null and ui.has_method("dispatch_widget_event"):
		ui.dispatch_widget_event(widget_id, event, payload)
	# The shell owns the screen; its buttons keep their own keyboard focus, so
	# the code view would never see another keystroke without the trip back.
	# Only when the shell reserves the code view: a quiz shell that hides the
	# world must not strand the invisible view on the focus.
	if !_editors.is_empty():
		_restore_editor_focus()


func _request_exit() -> void:
	exit_requested.emit()


## Hands keyboard focus back to the code view. Called at takeover (when the
## shell holds an editor slot) and after every shell widget event. The
## handler that emitted the event has already run by the time this fires.
func _restore_editor_focus() -> void:
	if _restore_focus.is_valid():
		_restore_focus.call()
