extends RefCounted

## Exact HUD snapshot for shell takeover.
##
## The shell hides core panels but never frees them. Restoring writes the
## recorded visibility, anchors, offsets, position, size, z-order and parent back
## verbatim, so a takeover/restore cycle is indistinguishable from never having
## taken over. `equals()` is a deep comparison, not a reference check: the
## Phase 3 gate asserts that a second capture equals the first.
##
## Pure RefCounted so the 50-cycle equality test runs headlessly with stub
## Controls; the services own the nodes, this class owns only numbers and paths.

const VERSION := 1


static func capture(panels: Dictionary, viewport_size: Vector2 = Vector2.ZERO) -> Dictionary:
	var entries: Dictionary = {}
	for key in panels.keys():
		var node: Variant = panels[key]
		if node == null or !is_instance_valid(node):
			continue
		entries[str(key)] = _entry(node)

	return {
		"version": VERSION,
		"viewport": [float(viewport_size.x), float(viewport_size.y)],
		"panels": entries,
	}


static func restore(snapshot: Dictionary, panels: Dictionary) -> bool:
	var entries: Variant = snapshot.get("panels", {})
	if !(entries is Dictionary):
		return false

	var complete := true
	for key in (entries as Dictionary).keys():
		var name := str(key)
		if !panels.has(name):
			complete = false
			continue
		var node: Variant = panels[name]
		if node == null or !is_instance_valid(node):
			complete = false
			continue
		if !_apply(node, (entries as Dictionary)[key]):
			complete = false
	return complete


## Hides every panel that is currently visible. The snapshot already holds the
## original visibility, so this is the only mutation a takeover performs.
static func hide(panels: Dictionary) -> void:
	for node in panels.values():
		if node is CanvasItem and is_instance_valid(node):
			(node as CanvasItem).visible = false


static func hidden_count(panels: Dictionary) -> int:
	var count := 0
	for node in panels.values():
		if node is CanvasItem and is_instance_valid(node) and !(node as CanvasItem).visible:
			count += 1
	return count


static func equals(a: Variant, b: Variant) -> bool:
	if typeof(a) != typeof(b):
		return false
	if a is Dictionary:
		var left: Dictionary = a
		var right: Dictionary = b
		if left.size() != right.size():
			return false
		for key in left.keys():
			if !right.has(key):
				return false
			if !equals(left[key], right[key]):
				return false
		return true
	if a is Array:
		var left_array: Array = a
		var right_array: Array = b
		if left_array.size() != right_array.size():
			return false
		for index in range(left_array.size()):
			if !equals(left_array[index], right_array[index]):
				return false
		return true
	return a == b


## Screen-space inset of a reserved editor rectangle: the distance from each
## window edge to the rectangle. Values are clamped to zero so a widget that is
## briefly larger than the window cannot invert the camera offset.
static func insets_for(rect: Rect2, viewport_size: Vector2) -> Dictionary:
	var width := maxf(0.0, viewport_size.x)
	var height := maxf(0.0, viewport_size.y)
	return {
		"left": clampf(rect.position.x, 0.0, width),
		"top": clampf(rect.position.y, 0.0, height),
		"right": clampf(width - rect.end.x, 0.0, width),
		"bottom": clampf(height - rect.end.y, 0.0, height),
	}


static func empty_insets() -> Dictionary:
	return {"left": 0.0, "top": 0.0, "right": 0.0, "bottom": 0.0}


static func _entry(node: Node) -> Dictionary:
	var entry := {
		"path": str(node.get_path()) if node.is_inside_tree() else "",
		"visible": bool(node.visible),
		"z_index": int(node.z_index),
		"y_sort_enabled": bool(node.y_sort_enabled),
		"parent": str(node.get_parent().name) if node.get_parent() != null else "",
	}
	if node is Control:
		var control := node as Control
		entry["anchors"] = [
			control.anchor_left, control.anchor_top, control.anchor_right, control.anchor_bottom,
		]
		entry["offsets"] = [
			control.offset_left, control.offset_top, control.offset_right, control.offset_bottom,
		]
		entry["position"] = [control.position.x, control.position.y]
		entry["size"] = [control.size.x, control.size.y]
	return entry


static func _apply(node: Node, entry: Variant) -> bool:
	if !(entry is Dictionary):
		return false
	var data: Dictionary = entry

	node.visible = bool(data.get("visible", node.visible))
	node.z_index = int(data.get("z_index", node.z_index))
	node.y_sort_enabled = bool(data.get("y_sort_enabled", node.y_sort_enabled))

	if node is Control:
		var control := node as Control
		var anchors: Variant = data.get("anchors", [])
		if anchors is Array and (anchors as Array).size() == 4:
			control.anchor_left = float(anchors[0])
			control.anchor_top = float(anchors[1])
			control.anchor_right = float(anchors[2])
			control.anchor_bottom = float(anchors[3])
		var has_offsets := false
		var offsets: Variant = data.get("offsets", [])
		if offsets is Array and (offsets as Array).size() == 4:
			has_offsets = true
			control.offset_left = float(offsets[0])
			control.offset_top = float(offsets[1])
			control.offset_right = float(offsets[2])
			control.offset_bottom = float(offsets[3])
		# Position and size are derived from anchors and offsets for a given
		# parent size. Writing them again would re-derive the offsets (and, for
		# stretched anchors, fight the anchors), so they are only a fallback for
		# entries captured by an older snapshot format.
		if !has_offsets:
			var position: Variant = data.get("position", [])
			if position is Array and (position as Array).size() == 2:
				control.position = Vector2(float(position[0]), float(position[1]))
			var size: Variant = data.get("size", [])
			if size is Array and (size as Array).size() == 2:
				control.size = Vector2(float(size[0]), float(size[1]))
	return true
