extends RefCounted

## Builds the menu bar straight from CommandRegistry. Nothing here knows the
## name of a single command: labels, groups, shortcuts, enabled states and
## check marks all come from the registry entries.

const KeyChordScript = preload("res://src/platform/key_chord.gd")

const CATEGORY_ORDER := [
	"File", "Edit", "View", "Workspace", "Terminal", "Run",
	"Preferences", "Help", "Other",
]


static func build(menu_bar: MenuBar, registry, on_execute: Callable) -> void:
	if menu_bar == null or registry == null:
		return

	for child in menu_bar.get_children():
		menu_bar.remove_child(child)
		child.queue_free()

	var groups: Dictionary = {}
	for command in registry.all():
		if bool(command.get("hidden", false)) or !bool(command.get("show_in_menu", true)):
			continue
		var category := str(command.get("category", "Other"))
		if !groups.has(category):
			groups[category] = []
		groups[category].append(command)

	var categories: Array[String] = []
	for category in CATEGORY_ORDER:
		if groups.has(category):
			categories.append(category)

	var leftovers: Array[String] = []
	for category in groups.keys():
		if !categories.has(str(category)):
			leftovers.append(str(category))
	leftovers.sort()
	categories.append_array(leftovers)

	for category in categories:
		var popup := PopupMenu.new()
		# Grouping stays on the registry's stable category id; only the title
		# the reader sees is translated.
		popup.name = TranslationServer.translate(category)
		popup.add_theme_font_size_override("font_size", 13)
		menu_bar.add_child(popup)

		var entries: Array[String] = []
		for command in groups.get(category, []):
			var command_id := str(command.get("id", ""))
			var label := str(command.get("label", command_id))
			var index := entries.size()
			entries.append(command_id)

			if command.has("checked"):
				popup.add_check_item(label, index)
				popup.set_item_checked(index, registry.is_checked(command_id))
			else:
				popup.add_item(label, index)

			var chord := KeyChordScript.parse(str(command.get("shortcut", "")))
			if chord.get("ok", false):
				popup.set_item_accelerator(index, KeyChordScript.to_accelerator(chord))

			popup.set_item_disabled(index, !registry.is_enabled(command_id))

		popup.id_pressed.connect(func(index: int) -> void:
			if index >= 0 and index < entries.size():
				on_execute.call(entries[index])
		)
