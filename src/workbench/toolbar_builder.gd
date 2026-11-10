extends RefCounted

## Builds the only toolbar in the editor from CommandRegistry entries flagged
## with show_in_toolbar. Tooltips carry the *effective* shortcut, so rebinding a
## command updates both the palette and the button tooltip.

static func build(container: HBoxContainer, registry, on_execute: Callable, buttons: Dictionary = {}) -> void:
	if container == null or registry == null:
		return

	buttons.clear()
	for child in container.get_children():
		container.remove_child(child)
		child.queue_free()

	var commands: Array = []
	for command in registry.all():
		if !bool(command.get("show_in_toolbar", false)):
			continue
		if bool(command.get("hidden", false)):
			continue
		commands.append(command)

	commands.sort_custom(func(a, b) -> bool:
		return int(a.get("toolbar_order", 100)) < int(b.get("toolbar_order", 100))
	)

	for command in commands:
		var command_id := str(command.get("id", ""))
		var label := str(command.get("label", command_id))
		var icon := str(command.get("icon", ""))
		var shortcut := str(command.get("shortcut", ""))

		var button := Button.new()
		button.name = "Tool_" + command_id.replace(".", "_")
		button.text = icon if !icon.is_empty() else label
		button.flat = true
		button.focus_mode = Control.FOCUS_NONE
		button.custom_minimum_size = Vector2(28, 22)
		button.tooltip_text = _tooltip(label, shortcut)
		button.disabled = !registry.is_enabled(command_id)
		button.pressed.connect(on_execute.bind(command_id))
		container.add_child(button)
		buttons[command_id] = button


static func _tooltip(label: String, shortcut: String) -> String:
	return "%s (%s)" % [label, shortcut] if !shortcut.is_empty() else label
