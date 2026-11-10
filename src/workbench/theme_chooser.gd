extends OptionButton

func _ready():
	if !LuaSingleton.theme_load_attempted:
		await LuaSingleton.on_theme_load;

	# The list can only be populated once themes have been enumerated (see
	# FileManager, which lists them before the first on_theme_load emission).
	clear()
	for _theme in LuaSingleton.themes:
		add_item(_theme)

	var current := LuaSingleton.themes.find(LuaSingleton.theme)
	selected = current if current != -1 else 0
