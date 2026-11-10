class_name CommentsOverlay

extends Control

@onready var color_rect: ColorRect = $ColorRect
@onready var container: Comments = $VBoxContainer

func _ready():
	color_rect.color = LuaSingleton.gui.current_line_color

func on_open():
	# Re-read the theme color and refresh the shuffled quotes each time.
	color_rect.color = LuaSingleton.gui.current_line_color
	container.setup()

func on_close():
	container.setup()
