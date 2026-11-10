class_name InputController
extends Node

## One shortcut path for the whole editor.
##
## Every key event that reaches the viewport is routed through
## KeybindingService.handle(event, scope). The service knows the scopes, so a
## terminal-focused Ctrl+F never opens the code editor's find panel, and an
## open dialog only receives global/dialog commands.
##
## The terminal's xterm renderer consumes key events in its own gui_input, so
## terminal-scope chords are caught in _input() before the renderer sees them.
## Everything else uses _unhandled_input(), the normal Godot shortcut hook.
##
## Phase 3 adds two things to `_input`, both ahead of the GUI:
##   * the mod panic chord, which must never be interceptable by a mod;
##   * the guide filter, because CodeEdit inserts text in `_gui_input` and a
##     swallowed key has to be handled before it reaches the widget.

var editor = null


func _input(event: InputEvent) -> void:
	if editor == null or editor.keybindings == null or editor.commands == null:
		return
	if !(event is InputEventKey):
		return

	var key_event: InputEventKey = event
	if !key_event.pressed or key_event.echo:
		return

	if _is_mod_panic(key_event):
		get_viewport().set_input_as_handled()
		if editor.has_method("handle_mod_panic"):
			editor.handle_mod_panic()
		return

	if _filter_guide(key_event):
		return

	# An overlay owns the keyboard (the keybinding editor captures keys in its
	# own _input). Never let a focused terminal steal those events.
	if editor.overlays == null or editor.overlays.has_open_panel():
		return
	if editor.terminal == null or !editor.terminal.is_terminal_focused():
		return

	var command_id: String = editor.keybindings.handle(event, "terminal")
	if command_id.is_empty():
		return

	get_viewport().set_input_as_handled()
	editor.commands.execute(command_id)


func _unhandled_input(event: InputEvent) -> void:
	if editor == null or editor.keybindings == null or editor.commands == null:
		return
	if !(event is InputEventKey):
		return

	# The welcome screen promises "Close (Esc)": plain Escape dismisses it.
	# Deliberately outside the keybindings path so it can never be rebound,
	# and paused while a modal overlay owns the keyboard.
	var escape_event: InputEventKey = event
	if escape_event.pressed and !escape_event.echo \
			and escape_event.keycode == KEY_ESCAPE \
			and !escape_event.ctrl_pressed and !escape_event.shift_pressed and !escape_event.alt_pressed:
		if editor.welcome_panel != null and editor.welcome_panel.visible \
				and (editor.overlays == null or !editor.overlays.has_open_panel()):
			get_viewport().set_input_as_handled()
			editor.welcome_panel.close_welcome()
			return

	var key_event: InputEventKey = event
	if !key_event.pressed or key_event.echo:
		return

	var command_id: String = editor.keybindings.handle(event, _scope())
	if command_id.is_empty():
		return

	get_viewport().set_input_as_handled()
	editor.commands.execute(command_id)


## Which binding scope owns the keyboard right now.
##
## An open overlay is a dialog even if the terminal still holds focus behind
## it. A text field outside the editor (search box, file-tree rename prompt)
## is also a dialog: editor-only shortcuts must not fire while typing there.
func _scope() -> String:
	if editor == null:
		return "global"

	if editor.overlays != null and editor.overlays.has_open_panel():
		return "dialog"

	if editor.terminal != null and editor.terminal.visible and editor.terminal.is_terminal_focused():
		return "terminal"

	if editor.active_view != null and editor.active_view.has_focus():
		return "editor"

	var focus: Control = get_viewport().gui_get_focus_owner()
	if focus == null:
		# Clicking a toolbar button or the tab strip releases focus without
		# meaning "no editor shortcuts"; treat it as the editor.
		return "editor"
	if _is_text_input(focus):
		return "dialog"
	return "editor"


func _is_text_input(control: Control) -> bool:
	return control is LineEdit or control is TextEdit or control is CodeEdit


## Ctrl+Alt+Shift+Esc. Checked before any other input path and before mods.
func _is_mod_panic(event: InputEventKey) -> bool:
	return event.keycode == KEY_ESCAPE \
		and event.ctrl_pressed \
		and event.alt_pressed \
		and event.shift_pressed


## Returns true when the key was consumed. The filter only acts while the code
## view has focus and a guide session is active; every other key passes
## natively, preserving undo, key repeat and IME behaviour.
func _filter_guide(event: InputEventKey) -> bool:
	if editor == null or !editor.has_method("filter_mod_guide_input"):
		return false
	if editor.active_view == null or !editor.active_view.has_focus():
		return false

	var decision: Dictionary = editor.filter_mod_guide_input(_semantic_key(event))
	var action := str(decision.get("action", "pass"))
	if action == "pass":
		return false

	get_viewport().set_input_as_handled()
	if action == "insert" and editor.has_method("apply_mod_guide_insert"):
		editor.apply_mod_guide_insert(str(decision.get("text", "")))
	return true


## Maps one platform key event to the filter's semantic vocabulary. Anything the
## filter does not model is `other`, which always passes.
func _semantic_key(event: InputEventKey) -> Dictionary:
	var kind := "other"
	var text := ""

	match event.keycode:
		KEY_BACKSPACE:
			kind = "backspace"
		KEY_ENTER, KEY_KP_ENTER:
			kind = "enter"
		KEY_TAB:
			# Shift+Tab is outdent; the filter models indent only.
			kind = "other" if event.shift_pressed else "tab"
		KEY_ESCAPE:
			kind = "escape"
		_:
			if event.unicode > 0:
				kind = "text"
				text = char(event.unicode)

	return {
		"kind": kind,
		"text": text,
		"ctrl": event.ctrl_pressed,
		"alt": event.alt_pressed,
		"meta": event.meta_pressed,
		# A composed key that carries no unicode is an IME candidate: never
		# filter it, or the composition would be swallowed mid-word.
		"ime": kind == "other" and event.keycode >= KEY_SPACE,
	}
