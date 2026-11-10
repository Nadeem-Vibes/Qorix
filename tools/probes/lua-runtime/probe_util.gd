extends RefCounted

## Shared helpers for Phase 0 probe results.


static func first_value(result: Dictionary) -> Variant:
	var values: Variant = result.get("values", null)
	if values is Array:
		return values[1] if values.size() > 1 else null
	if values is Dictionary:
		if values.has(1):
			return values.get(1)
		return values.get("1", null)
	return null


static func all_ok(checks: Array) -> bool:
	if checks.is_empty():
		return false
	for check in checks:
		if !bool(check.get("ok", false)):
			return false
	return true


static func status(checks: Array, limitations: Array = []) -> String:
	if !all_ok(checks):
		return "fail"
	return "partial" if !limitations.is_empty() else "pass"


static func check(name: String, ok: bool, detail: String, metrics: Dictionary = {}) -> Dictionary:
	return {
		"name": name,
		"ok": ok,
		"detail": detail,
		"metrics": metrics,
	}


static func sha256_file(path: String) -> String:
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		return ""
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(bytes)
	return context.finish().hex_encode()


static func file_size(path: String) -> int:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return -1
	var size := file.get_length()
	file.close()
	return size
