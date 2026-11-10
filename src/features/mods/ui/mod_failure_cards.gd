extends Control

## Failure cards for mods that stopped.
##
## One card per failed mod, stacked above the bottom-left corner so it does not
## cover the editor's own top bar or the notification stack. The card names the
## mod, quotes the error and offers the three actions from the Phase 1 plan:
## Open log, Disable, and Reload (developer builds only).

signal retry_requested(mod_id: String)
signal disable_requested(mod_id: String)
signal log_requested(mod_id: String)

const UiTheme = preload("res://src/workbench/ui_theme.gd")

const WIDTH := 440.0
const MAX_CARDS := 4

var _cards: Dictionary = {}
var _stack: VBoxContainer


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	offset_left = 16.0
	offset_right = 16.0 + WIDTH
	offset_top = -260.0
	offset_bottom = -16.0

	_stack = VBoxContainer.new()
	_stack.name = "Cards"
	_stack.add_theme_constant_override("separation", 6)
	_stack.alignment = BoxContainer.ALIGNMENT_END
	_stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stack.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_stack)


func show_failure(mod_id: String, failure: Dictionary, can_reload: bool = false) -> void:
	var key := str(mod_id)
	if key.is_empty():
		return

	if _cards.has(key):
		clear(key)

	while _cards.size() >= MAX_CARDS:
		# Dictionary preserves insertion order in Godot 4, so keys()[0] is the
		# oldest card.
		var oldest: String = str(_cards.keys()[0])
		clear(oldest)

	var card := PanelContainer.new()
	card.name = "ModFailure_" + key.replace(".", "_")
	card.custom_minimum_size = Vector2(WIDTH, 0)
	card.add_theme_stylebox_override("panel", _card_style())

	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 4)
	card.add_child(body)

	var title := Label.new()
	title.text = "Mod stopped: " + str(failure.get("name", key))
	title.add_theme_color_override("font_color", Color("#f7768e"))
	body.add_child(title)

	var message := Label.new()
	# Cap the quote: a mod error can be up to 8 KB, which would push the card
	# (and the whole stack) off the top of the screen. The full text is one
	# click away via Open log.
	var full_message := str(failure.get("message", "The mod stopped."))
	var preview := full_message
	if preview.length() > 300:
		preview = preview.substr(0, 300).strip_edges() + "…"
	message.text = preview
	message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	message.add_theme_color_override("font_color", LuaSingleton.gui.font_color)
	body.add_child(message)

	var code := Label.new()
	code.text = str(failure.get("code", "mod.failed"))
	code.add_theme_color_override("font_color", Color("#e0af68"))
	code.add_theme_font_size_override("font_size", 12)
	body.add_child(code)

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 6)
	body.add_child(actions)

	actions.add_child(_button("Open log", func() -> void: log_requested.emit(key)))
	actions.add_child(_button("Disable", func() -> void: disable_requested.emit(key)))
	if can_reload:
		actions.add_child(_button("Reload", func() -> void: retry_requested.emit(key)))

	_stack.add_child(card)
	_cards[key] = card


func clear(mod_id: String) -> void:
	var key := str(mod_id)
	if !_cards.has(key):
		return
	var card: Variant = _cards[key]
	_cards.erase(key)
	if card is Node and is_instance_valid(card):
		(card as Node).queue_free()


func clear_all() -> void:
	for key in _cards.keys():
		clear(str(key))


func card_count() -> int:
	return _cards.size()


func _button(text: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_ALL
	button.pressed.connect(action)
	return button


func _card_style() -> StyleBoxFlat:
	var style := UiTheme.panel_style()
	style.content_margin_top = 10
	style.content_margin_bottom = 10
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.border_width_left = 3
	style.border_color = Color("#f7768e")
	return style
