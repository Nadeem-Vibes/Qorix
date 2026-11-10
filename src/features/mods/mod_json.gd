extends RefCounted

## JSON-value guard shared by mod storage, progress, settings and the event bus.
##
## A Lua mod can only hand the host values that survive a JSON round trip. That
## keeps persistence deterministic, stops engine objects from leaking across the
## capability boundary, and makes every quota a byte count instead of a guess.

const MAX_DEPTH := 16


## True when `value` is null, a boolean, a number, a string, or an array/object
## made only of those. Object keys must be strings.
static func is_value(value: Variant, depth: int = 0) -> bool:
	if depth > MAX_DEPTH:
		return false

	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING, TYPE_STRING_NAME:
			return true
		TYPE_ARRAY:
			for item in value:
				if !is_value(item, depth + 1):
					return false
			return true
		TYPE_DICTIONARY:
			for key in value.keys():
				if typeof(key) != TYPE_STRING and typeof(key) != TYPE_STRING_NAME:
					return false
				if !is_value(value[key], depth + 1):
					return false
			return true

	return false


## UTF-8 size of the value as JSON. Used by the KV quota.
static func size_bytes(value: Variant) -> int:
	if !is_value(value):
		return -1
	return JSON.stringify(value).to_utf8_buffer().size()


## Deep copy for storage. JSON-safe values contain no engine resources, so a
## duplicate is enough to stop a mod mutating host state through a shared table.
static func clone(value: Variant) -> Variant:
	if !is_value(value):
		return null
	return value.duplicate(true) if (value is Array or value is Dictionary) else value


## Normalizes a value that arrived from Lua. Lua has one number type, so integer
## settings would otherwise arrive as floats; JSON.stringify writes 4.0 as 4.0,
## which is valid but noisy in stored files.
static func normalize(value: Variant) -> Variant:
	match typeof(value):
		TYPE_FLOAT:
			var number: float = value
			if is_finite(number) and number == floor(number) and absf(number) <= 9007199254740992.0:
				return int(number)
			return number
		TYPE_ARRAY:
			var out: Array = []
			for item in value:
				out.append(normalize(item))
			return out
		TYPE_DICTIONARY:
			var out_dict: Dictionary = {}
			for key in value.keys():
				out_dict[str(key)] = normalize(value[key])
			return out_dict
		TYPE_STRING_NAME:
			return str(value)
	return value


## Accepts a Lua table that marshalled as an Array or as an integer-keyed
## Dictionary and returns a plain Array. Anything else is empty.
static func as_array(value: Variant) -> Array:
	if value is Array:
		return value
	if !(value is Dictionary):
		return []

	var source: Dictionary = value
	var keys: Array = source.keys()
	var numeric := true
	for key in keys:
		if typeof(key) != TYPE_INT and !(typeof(key) == TYPE_FLOAT and float(key) == floor(float(key))):
			numeric = false
			break
	if !numeric:
		return []

	keys.sort()
	var out: Array = []
	for key in keys:
		out.append(source[key])
	return out
