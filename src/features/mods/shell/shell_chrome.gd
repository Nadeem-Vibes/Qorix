extends PanelContainer

## Host chrome strip for a shell takeover.
##
## 34 px, above the shell, outside mod control: the mod name, the panic hint and
## an **Exit mod** button. The shell layout starts below it, and the camera
## insets include its height because the reserved editor rectangle does too.
## A mod cannot hide, restyle or replace this strip.

signal exit_requested

const HEIGHT := 34.0
const PANIC_HINT := "Ctrl+Alt+Shift+Esc · exit"

var _mod_name: String = ""
var _name_label: Label
var _exit_button: Button


func setup(mod_name: String) -> void:
	_mod_name = str(mod_name)


func _ready() -> void:
	name = "ShellChrome"
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	offset_bottom = HEIGHT

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.05, 0.09, 0.98)
	style.border_color = Color(0.2, 0.3, 0.5, 0.9)
	style.border_width_bottom = 1
	add_theme_stylebox_override("panel", style)

	var row := HBoxContainer.new()
	row.name = "Row"
	row.add_theme_constant_override("separation", 10)
	add_child(row)

	_name_label = Label.new()
	_name_label.name = "ModName"
	_name_label.text = _mod_name if !_mod_name.is_empty() else "Mod"
	_name_label.add_theme_font_size_override("font_size", 13)
	row.add_child(_name_label)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)

	var hint := Label.new()
	hint.name = "PanicHint"
	hint.text = PANIC_HINT
	hint.add_theme_font_size_override("font_size", 11)
	hint.modulate = Color(1, 1, 1, 0.6)
	row.add_child(hint)

	_exit_button = Button.new()
	_exit_button.name = "ExitMod"
	_exit_button.text = "Exit mod"
	_exit_button.focus_mode = Control.FOCUS_ALL
	_exit_button.pressed.connect(func() -> void: exit_requested.emit())
	row.add_child(_exit_button)
