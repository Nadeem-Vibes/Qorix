extends "res://tests/support/test_case.gd"

const KeyChordScript = preload("res://src/platform/key_chord.gd")


func test_parse_modifiers_and_letters() -> void:
	var chord: Dictionary = KeyChordScript.parse("Ctrl+Shift+P")
	assert_true(chord.get("ok", false), "Ctrl+Shift+P parses")
	assert_eq(int(chord.get("keycode", 0)), KEY_P)
	assert_true(bool(chord.get("ctrl", false)), "ctrl is set")
	assert_true(bool(chord.get("shift", false)), "shift is set")
	assert_false(bool(chord.get("alt", false)), "alt is clear")
	assert_eq(str(chord.get("text", "")), "Ctrl+Shift+P")


func test_parse_accepts_aliases_and_any_order() -> void:
	var chord: Dictionary = KeyChordScript.parse("shift+control+s")
	assert_true(chord.get("ok", false), "aliases parse")
	assert_eq(str(chord.get("text", "")), "Ctrl+Shift+S")


func test_parse_function_keys() -> void:
	assert_eq(int(KeyChordScript.parse("F5").get("keycode", 0)), KEY_F5)
	assert_eq(str(KeyChordScript.parse("f12").get("text", "")), "F12")


func test_parse_punctuation_and_shifted_symbols() -> void:
	var backtick: Dictionary = KeyChordScript.parse("Ctrl+`")
	assert_eq(int(backtick.get("keycode", 0)), KEY_QUOTELEFT)
	assert_eq(str(backtick.get("text", "")), "Ctrl+`")

	var plus: Dictionary = KeyChordScript.parse("Ctrl++")
	assert_true(plus.get("ok", false), "Ctrl++ parses")
	assert_eq(int(plus.get("keycode", 0)), KEY_EQUAL)
	assert_true(bool(plus.get("shift", false)), "plus carries the shifted layer")


func test_parse_rejects_incomplete_shortcuts() -> void:
	assert_false(KeyChordScript.parse("").get("ok", false), "empty is invalid")
	assert_false(KeyChordScript.parse("Ctrl+").get("ok", false), "modifier without a key is invalid")
	assert_false(KeyChordScript.parse("Ctrl+Shift").get("ok", false), "only modifiers is invalid")
	assert_false(KeyChordScript.parse("Ctrl+A+B").get("ok", false), "two keys is invalid")
	assert_false(KeyChordScript.parse("Ctrl+NotAKey").get("ok", false), "unknown key is invalid")


func test_matches_requires_exact_modifiers() -> void:
	var save: Dictionary = KeyChordScript.parse("Ctrl+S")
	var save_as: Dictionary = KeyChordScript.parse("Ctrl+Shift+S")

	var event := InputEventKey.new()
	event.physical_keycode = KEY_S
	event.ctrl_pressed = true
	event.pressed = true

	assert_true(KeyChordScript.matches(event, save), "Ctrl+S matches Ctrl+S")
	assert_false(KeyChordScript.matches(event, save_as), "Ctrl+S does not match Ctrl+Shift+S")

	event.shift_pressed = true
	assert_false(KeyChordScript.matches(event, save), "Ctrl+Shift+S does not match Ctrl+S")
	assert_true(KeyChordScript.matches(event, save_as), "Ctrl+Shift+S matches Ctrl+Shift+S")


func test_matches_ignores_key_release_and_echo() -> void:
	var chord: Dictionary = KeyChordScript.parse("Ctrl+S")
	var event := InputEventKey.new()
	event.physical_keycode = KEY_S
	event.ctrl_pressed = true
	event.pressed = false
	assert_false(KeyChordScript.matches(event, chord), "release does not match")

	event.pressed = true
	event.echo = true
	assert_false(KeyChordScript.matches(event, chord), "echo does not match")


func test_from_event_round_trips() -> void:
	var event := InputEventKey.new()
	event.physical_keycode = KEY_H
	event.ctrl_pressed = true
	event.alt_pressed = true
	event.pressed = true

	var chord: Dictionary = KeyChordScript.from_event(event)
	assert_true(chord.get("ok", false), "from_event succeeds")
	assert_eq(str(chord.get("text", "")), "Ctrl+Alt+H")
	assert_true(KeyChordScript.matches(event, chord), "from_event result matches its event")


func test_same_compares_every_modifier() -> void:
	var a: Dictionary = KeyChordScript.parse("Ctrl+K")
	var b: Dictionary = KeyChordScript.parse("ctrl+k")
	var c: Dictionary = KeyChordScript.parse("Ctrl+Shift+K")
	assert_true(KeyChordScript.same(a, b), "same ignores case")
	assert_false(KeyChordScript.same(a, c), "same sees the shift difference")


func test_accelerator_sets_modifier_masks() -> void:
	var accelerator: int = KeyChordScript.to_accelerator(KeyChordScript.parse("Ctrl+Shift+P"))
	assert_true((accelerator & KEY_MASK_CTRL) != 0, "accelerator has ctrl")
	assert_true((accelerator & KEY_MASK_SHIFT) != 0, "accelerator has shift")
	assert_eq(accelerator & ~(KEY_MASK_CTRL | KEY_MASK_SHIFT | KEY_MASK_ALT | KEY_MASK_META), KEY_P)
