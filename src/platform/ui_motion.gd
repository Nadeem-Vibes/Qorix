class_name UiMotion
extends RefCounted

## Shared motion policy for HUD transitions and small state feedback effects.
## Reduced motion and static camera are treated as hard accessibility overrides.

const DEFAULT_DURATION := 0.15

static func allowed() -> bool:
	var lua = _lua_singleton()
	if lua == null:
		return true
	if lua.has_method("get_setting"):
		var reduced := _setting_bool(lua, "reduced_motion", false)
		var static_camera := _setting_bool(lua, "static_camera", false)
		var animations := _setting_bool(lua, "ui_animations", true)
		var polish := _setting_bool(lua, "ui_polish", true)
		return animations and polish and !reduced and !static_camera
	return true


static func feedback_allowed() -> bool:
	if !allowed():
		return false
	var lua = _lua_singleton()
	if lua != null and lua.has_method("get_setting"):
		return _setting_bool(lua, "state_feedback", true)
	return true


static func duration(base: float = DEFAULT_DURATION) -> float:
	return maxf(base, 0.0) if allowed() else 0.0


static func feedback_duration(base: float = 0.12) -> float:
	return maxf(base, 0.0) if feedback_allowed() else 0.0


static func _setting_bool(lua: Object, key: String, fallback: bool) -> bool:
	var found: Array = lua.get_setting(key)
	if found.size() < 1 or !(found[0] is Dictionary):
		return fallback
	return bool(found[0].get("value", fallback))


static func _lua_singleton():
	var scene_tree := Engine.get_main_loop() as SceneTree
	if scene_tree != null and scene_tree.root != null:
		return scene_tree.root.get_node_or_null("LuaSingleton")
	return null
