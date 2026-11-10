class_name FocusNav
extends RefCounted

## Keyboard focus helpers. Godot already moves focus with Tab; the problem was
## that many generated controls were left at FOCUS_NONE, so whole panels could
## not be reached or read without a mouse. `configure_tree()` fixes that once a
## HUD/panel has been built.

## Controls that are interactive enough to deserve a focus stop.
static func is_interactive(control: Control) -> bool:
	if control == null or !is_instance_valid(control):
		return false
	return control is BaseButton \
		or control is Range \
		or control is LineEdit \
		or control is TextEdit \
		or control is Tree \
		or control is ItemList \
		or control is TabBar


static func is_focusable(control: Control) -> bool:
	if !is_interactive(control):
		return false
	if !control.visible or control.focus_mode == Control.FOCUS_NONE:
		return false
	if control.has_meta("focus_skip"):
		return false
	return true


## Gives every interactive control a focus stop. Controls that deliberately
## opted out (`focus_mode = FOCUS_NONE` plus the "focus_skip" metadata) and
## hidden controls are left alone.
static func configure_tree(root: Node) -> int:
	if root == null:
		return 0

	var changed := 0
	var stack: Array[Node] = [root]
	while !stack.is_empty():
		var node: Node = stack.pop_back()
		if node is Control:
			var control: Control = node as Control
			# is_visible_in_tree() is false for a control hidden anywhere up its
			# ancestry; its descendants can never take focus either, so the whole
			# subtree can be skipped.
			if !control.is_visible_in_tree():
				continue
			if is_interactive(control) and control.focus_mode == Control.FOCUS_NONE \
					and !control.has_meta("focus_skip"):
				control.focus_mode = Control.FOCUS_ALL
				changed += 1
		for child in node.get_children():
			stack.append(child)
	return changed


## The first visible, focusable control under `root`, depth-first. Used when a
## panel opens so keyboard users land inside it instead of behind it.
static func first_focusable(root: Node) -> Control:
	if root == null:
		return null

	var stack: Array[Node] = [root]
	while !stack.is_empty():
		var node: Node = stack.pop_front()
		if node is Control:
			var control: Control = node as Control
			if is_focusable(control):
				return control
			if !control.visible:
				continue
		for child in node.get_children():
			stack.append(child)
	return null
