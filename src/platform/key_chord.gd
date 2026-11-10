class_name KeyChord
extends RefCounted

## A keyboard shortcut parsed once and shared by the command registry, the
## InputMap builder and the keybinding editor.
##
## Chords use physical keycodes, exactly like the old project.godot actions, so
## a shortcut keeps working when the keyboard layout changes. The canonical
## text form is "Ctrl+Shift+P"; parsing accepts modifiers in any order and the
## common aliases (Cmd, Option, Esc, PgUp, ...).
##
## A parsed chord is a plain Dictionary:
##   {ok, keycode, ctrl, alt, shift, meta, text, error}

const MODIFIER_ALIASES := {
	"ctrl": "ctrl",
	"control": "ctrl",
	"shift": "shift",
	"alt": "alt",
	"option": "alt",
	"opt": "alt",
	"meta": "meta",
	"cmd": "meta",
	"command": "meta",
	"super": "meta",
	"win": "meta",
}

## Named keys that are not a single character. Values are either a keycode or
## [keycode, shift] for symbols that live on the shifted layer.
const NAMED_KEYS := {
	"escape": KEY_ESCAPE,
	"esc": KEY_ESCAPE,
	"space": KEY_SPACE,
	"spacebar": KEY_SPACE,
	"tab": KEY_TAB,
	"enter": KEY_ENTER,
	"return": KEY_ENTER,
	"backspace": KEY_BACKSPACE,
	"delete": KEY_DELETE,
	"del": KEY_DELETE,
	"insert": KEY_INSERT,
	"ins": KEY_INSERT,
	"home": KEY_HOME,
	"end": KEY_END,
	"pageup": KEY_PAGEUP,
	"pgup": KEY_PAGEUP,
	"pagedown": KEY_PAGEDOWN,
	"pgdn": KEY_PAGEDOWN,
	"up": KEY_UP,
	"arrowup": KEY_UP,
	"down": KEY_DOWN,
	"arrowdown": KEY_DOWN,
	"left": KEY_LEFT,
	"arrowleft": KEY_LEFT,
	"right": KEY_RIGHT,
	"arrowright": KEY_RIGHT,
	"backtick": KEY_QUOTELEFT,
	"grave": KEY_QUOTELEFT,
	"quoteleft": KEY_QUOTELEFT,
	"minus": KEY_MINUS,
	"equal": KEY_EQUAL,
	"equals": KEY_EQUAL,
	"plus": [KEY_EQUAL, true],
	"comma": KEY_COMMA,
	"period": KEY_PERIOD,
	"dot": KEY_PERIOD,
	"slash": KEY_SLASH,
	"backslash": KEY_BACKSLASH,
	"semicolon": KEY_SEMICOLON,
	"apostrophe": KEY_APOSTROPHE,
	"quote": KEY_APOSTROPHE,
	"bracketleft": KEY_BRACKETLEFT,
	"leftbracket": KEY_BRACKETLEFT,
	"bracketright": KEY_BRACKETRIGHT,
	"rightbracket": KEY_BRACKETRIGHT,
	"printscreen": KEY_PRINT,
	"pause": KEY_PAUSE,
	"capslock": KEY_CAPSLOCK,
	"numlock": KEY_NUMLOCK,
	"scrolllock": KEY_SCROLLLOCK,
}

## Single-character keys. Shift symbols carry the shifted layer with them.
const CHARACTER_KEYS := {
	"`": KEY_QUOTELEFT,
	"~": [KEY_QUOTELEFT, true],
	"-": KEY_MINUS,
	"_": [KEY_MINUS, true],
	"=": KEY_EQUAL,
	"+": [KEY_EQUAL, true],
	"[": KEY_BRACKETLEFT,
	"{": [KEY_BRACKETLEFT, true],
	"]": KEY_BRACKETRIGHT,
	"}": [KEY_BRACKETRIGHT, true],
	"\\": KEY_BACKSLASH,
	"|": [KEY_BACKSLASH, true],
	";": KEY_SEMICOLON,
	":": [KEY_SEMICOLON, true],
	"'": KEY_APOSTROPHE,
	"\"": [KEY_APOSTROPHE, true],
	",": KEY_COMMA,
	"<": [KEY_COMMA, true],
	".": KEY_PERIOD,
	">": [KEY_PERIOD, true],
	"/": KEY_SLASH,
	"?": [KEY_SLASH, true],
	"1": KEY_1, "!": [KEY_1, true],
	"2": KEY_2, "@": [KEY_2, true],
	"3": KEY_3, "#": [KEY_3, true],
	"4": KEY_4, "$": [KEY_4, true],
	"5": KEY_5, "%": [KEY_5, true],
	"6": KEY_6, "^": [KEY_6, true],
	"7": KEY_7, "&": [KEY_7, true],
	"8": KEY_8, "*": [KEY_8, true],
	"9": KEY_9, "(": [KEY_9, true],
	"0": KEY_0, ")": [KEY_0, true],
}


static func blank() -> Dictionary:
	return {
		"ok": false,
		"keycode": 0,
		"ctrl": false,
		"alt": false,
		"shift": false,
		"meta": false,
		"text": "",
		"error": "",
	}


## Parses "Ctrl+Shift+P" / "F5" / "Ctrl+`" into a chord dictionary.
static func parse(value: String) -> Dictionary:
	var result := blank()
	var raw := value.strip_edges()
	if raw.is_empty():
		result["error"] = "No keys were entered."
		return result

	# "Ctrl++" would otherwise split into a trailing empty token: rewrite the
	# final plus into a named "Plus" key before splitting.
	if raw.ends_with("++"):
		raw = raw.substr(0, raw.length() - 2) + "+Plus"

	var tokens := raw.split("+", false)
	if tokens.is_empty():
		result["error"] = "No keys were entered."
		return result

	var key_token := ""
	for token in tokens:
		var piece := str(token).strip_edges()
		if piece.is_empty():
			continue

		var modifier: String = str(MODIFIER_ALIASES.get(piece.to_lower(), ""))
		if !modifier.is_empty():
			result[modifier] = true
			continue

		if !key_token.is_empty():
			result["error"] = "Use exactly one key after the modifiers."
			return result
		key_token = piece

	if key_token.is_empty():
		result["error"] = "A shortcut needs a key, not only modifiers."
		return result

	var key := _key_for_token(key_token)
	if int(key["keycode"]) == 0:
		result["error"] = "Unknown key: " + key_token
		return result

	result["ok"] = true
	result["keycode"] = int(key["keycode"])
	result["shift"] = bool(result["shift"]) or bool(key.get("shift", false))
	result["text"] = format(result)
	return result


## Canonical text form, used everywhere a shortcut is displayed.
static func format(chord: Dictionary) -> String:
	if chord.is_empty() or !bool(chord.get("ok", false)):
		return str(chord.get("text", "")) if chord is Dictionary else ""
	var parts: Array[String] = []
	if bool(chord.get("ctrl", false)):
		parts.append("Ctrl")
	if bool(chord.get("alt", false)):
		parts.append("Alt")
	if bool(chord.get("shift", false)):
		parts.append("Shift")
	if bool(chord.get("meta", false)):
		parts.append("Meta")
	parts.append(display_key(int(chord.get("keycode", 0))))
	return "+".join(parts)


static func normalize(value: String) -> String:
	var chord := parse(value)
	return str(chord.get("text", value)) if chord.get("ok", false) else value


## Exact match: extra modifiers must not fire a shorter binding (Ctrl+Shift+S
## saves as, it does not also save). Physical keycode first, then keycode, so
## events built by the engine and by tests both work.
static func matches(event: InputEventKey, chord: Dictionary) -> bool:
	if event == null or chord.is_empty() or !bool(chord.get("ok", false)):
		return false
	if !event.pressed or event.echo:
		return false

	var code := int(event.physical_keycode)
	if code == 0:
		code = int(event.keycode)
	if code != int(chord.get("keycode", 0)):
		return false

	return (
		bool(event.ctrl_pressed) == bool(chord.get("ctrl", false))
		and bool(event.alt_pressed) == bool(chord.get("alt", false))
		and bool(event.shift_pressed) == bool(chord.get("shift", false))
		and bool(event.meta_pressed) == bool(chord.get("meta", false))
	)


static func from_event(event: InputEventKey) -> Dictionary:
	var result := blank()
	if event == null:
		result["error"] = "No key event."
		return result

	var code := int(event.physical_keycode)
	if code == 0:
		code = int(event.keycode)
	if code == 0:
		result["error"] = "That key cannot be used."
		return result

	result["ok"] = true
	result["keycode"] = code
	result["ctrl"] = bool(event.ctrl_pressed)
	result["alt"] = bool(event.alt_pressed)
	result["shift"] = bool(event.shift_pressed)
	result["meta"] = bool(event.meta_pressed)
	result["text"] = format(result)
	return result


static func same(a: Dictionary, b: Dictionary) -> bool:
	if a.is_empty() or b.is_empty():
		return false
	if !bool(a.get("ok", false)) or !bool(b.get("ok", false)):
		return false
	return (
		int(a.get("keycode", 0)) == int(b.get("keycode", 0))
		and bool(a.get("ctrl", false)) == bool(b.get("ctrl", false))
		and bool(a.get("alt", false)) == bool(b.get("alt", false))
		and bool(a.get("shift", false)) == bool(b.get("shift", false))
		and bool(a.get("meta", false)) == bool(b.get("meta", false))
	)


static func is_modifier_key(code: int) -> bool:
	return code in [KEY_CTRL, KEY_SHIFT, KEY_ALT, KEY_META]


## InputEventKey keycode for a token. Returns {keycode, shift}.
static func _key_for_token(token: String) -> Dictionary:
	var lower := token.to_lower()

	if NAMED_KEYS.has(lower):
		var named: Variant = NAMED_KEYS[lower]
		if named is Array:
			return {"keycode": int(named[0]), "shift": bool(named[1])}
		return {"keycode": int(named), "shift": false}

	if CHARACTER_KEYS.has(token):
		var character: Variant = CHARACTER_KEYS[token]
		if character is Array:
			return {"keycode": int(character[0]), "shift": bool(character[1])}
		return {"keycode": int(character), "shift": false}

	# Function keys: F1 ... F24
	if lower.begins_with("f") and lower.substr(1).is_valid_int():
		var number := int(lower.substr(1))
		if number >= 1 and number <= 24:
			return {"keycode": int(KEY_F1) + number - 1, "shift": false}

	# A single letter. Layout-independent physical keycodes use the US
	# positions, which is what physical_keycode expects.
	if token.length() == 1:
		var upper := token.to_upper()
		var code := upper.unicode_at(0)
		if code >= 65 and code <= 90:
			return {"keycode": int(KEY_A) + code - 65, "shift": false}
		if code >= 48 and code <= 57:
			return {"keycode": int(KEY_0) + code - 48, "shift": false}

	# Last resort: let the engine name keycodes ("KP_1", "F13", ...).
	var found := int(OS.find_keycode_from_string(token))
	if found != 0:
		return {"keycode": found, "shift": false}

	return {"keycode": 0, "shift": false}


static func display_key(code: int) -> String:
	match code:
		KEY_ESCAPE: return "Esc"
		KEY_SPACE: return "Space"
		KEY_TAB: return "Tab"
		KEY_ENTER: return "Enter"
		KEY_BACKSPACE: return "Backspace"
		KEY_DELETE: return "Delete"
		KEY_INSERT: return "Insert"
		KEY_HOME: return "Home"
		KEY_END: return "End"
		KEY_PAGEUP: return "PgUp"
		KEY_PAGEDOWN: return "PgDn"
		KEY_UP: return "Up"
		KEY_DOWN: return "Down"
		KEY_LEFT: return "Left"
		KEY_RIGHT: return "Right"
		KEY_QUOTELEFT: return "`"
		KEY_MINUS: return "-"
		KEY_EQUAL: return "="
		KEY_COMMA: return ","
		KEY_PERIOD: return "."
		KEY_SLASH: return "/"
		KEY_BACKSLASH: return "\\"
		KEY_SEMICOLON: return ";"
		KEY_APOSTROPHE: return "'"
		KEY_BRACKETLEFT: return "["
		KEY_BRACKETRIGHT: return "]"
		KEY_PRINT: return "PrintScreen"
		KEY_PAUSE: return "Pause"
		KEY_CAPSLOCK: return "CapsLock"
		KEY_NUMLOCK: return "NumLock"
		KEY_SCROLLLOCK: return "ScrollLock"

	var text := OS.get_keycode_string(code)
	return text if !text.is_empty() else "Key%d" % code


## PopupMenu accelerators (the right-aligned shortcut column).
static func to_accelerator(chord: Dictionary) -> int:
	if chord.is_empty() or !bool(chord.get("ok", false)):
		return 0
	var accel := int(chord.get("keycode", 0))
	if bool(chord.get("ctrl", false)):
		accel = accel | KEY_MASK_CTRL
	if bool(chord.get("alt", false)):
		accel = accel | KEY_MASK_ALT
	if bool(chord.get("shift", false)):
		accel = accel | KEY_MASK_SHIFT
	if bool(chord.get("meta", false)):
		accel = accel | KEY_MASK_META
	return accel
