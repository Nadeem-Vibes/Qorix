extends RefCounted

## Clipboard bridge (Phase 2). Reads and writes are explicit permissions; the
## value is capped so a mod cannot use the clipboard as an unbounded buffer.

const Result = preload("res://src/features/mods/mod_result.gd")

const MAX_CHARS := 1024 * 1024


func write(payload: Dictionary) -> Dictionary:
	var text := str(payload.get("text", ""))
	if text.length() > MAX_CHARS:
		return Result.error("clipboard.too_large", "Clipboard text is limited to %d characters." % MAX_CHARS)
	DisplayServer.clipboard_set(text)
	return Result.ok(true)


func read(_payload: Dictionary = {}) -> Dictionary:
	var text := DisplayServer.clipboard_get()
	if text.length() > MAX_CHARS:
		return Result.error("clipboard.too_large", "The clipboard is larger than %d characters." % MAX_CHARS)
	return Result.ok(text)
