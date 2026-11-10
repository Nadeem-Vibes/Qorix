extends RefCounted

## E8 — Ghost alignment and Unicode mapping (pure part).
##
## Verifies TextServer grapheme segmentation and the codepoint/byte mapping the
## guide matcher depends on. Pixel alignment against drawn glyphs still needs a
## window and screenshots; that part is explicitly left pending.

const Util = preload("res://tools/probes/lua-runtime/probe_util.gd")

const FIXTURES := [
	{"name": "ascii", "text": "abc", "clusters": 3},
	{"name": "combining_acute", "text": "e\u0301", "clusters": 1},
	{"name": "precomposed_e_acute", "text": "é", "clusters": 1},
	{"name": "cjk", "text": "日本語", "clusters": 3},
	{"name": "devanagari", "text": "नमस्ते", "clusters": -1},
	{"name": "hebrew", "text": "שלום", "clusters": 4},
	{"name": "arabic", "text": "مرحبا", "clusters": 5},
	{"name": "emoji_skin_tone", "text": "👍🏽", "clusters": 1},
	{"name": "zwj_family", "text": "👨‍👩‍👧‍👦", "clusters": -1},
	{"name": "tab", "text": "\t", "clusters": 1},
	{"name": "mixed", "text": "a\té👍🏽", "clusters": 4},
]


func run(_ctx: Dictionary) -> Dictionary:
	var checks: Array = []
	var limitations: Array = []
	var fixtures: Dictionary = {}

	var text_server := TextServerManager.get_primary_interface()
	if text_server == null or !text_server.has_method("string_get_character_breaks"):
		return {
			"probe": "E8",
			"title": "Ghost alignment and Unicode mapping",
			"status": "fail",
			"checks": [Util.check("text_server", false, "No primary TextServer with string_get_character_breaks")],
			"limitations": [],
		}

	var segmentation_ok := true
	var unit := "codepoints"

	for fixture in FIXTURES:
		var text := str(fixture["text"])
		var breaks: PackedInt32Array = text_server.string_get_character_breaks(text, "")
		var break_array := _to_array(breaks)
		var codepoints := text.length()
		var bytes := text.to_utf8_buffer().size()
		# TextServer returns each cluster's end position: [1, 2, 3] for "abc"
		# and [2] for "e" + U+0301. The leading 0 is implicit.
		var clusters := 0 if text.is_empty() else break_array.size()
		var expected := int(fixture["clusters"])
		var expected_ok := expected < 0 or clusters == expected

		if !break_array.is_empty() and bytes != codepoints:
			var max_break := int(break_array.max())
			unit = "bytes" if max_break > codepoints else "codepoints"

		fixtures[fixture["name"]] = {
			"breaks": break_array,
			"clusters": clusters,
			"codepoints": codepoints,
			"bytes": bytes,
			"expected": expected,
			"expected_ok": expected_ok,
		}

		if !expected_ok:
			segmentation_ok = false
		if expected == -1:
			limitations.append(
				"%s segments into %d clusters over %d codepoints; inspect whether this matches the lesson content before relying on per-cluster ghost placement." % [
					str(fixture["name"]), clusters, codepoints,
				]
			)

	checks.append(Util.check(
		"grapheme_segmentation",
		segmentation_ok,
		"break unit=%s; fixtures=%s" % [unit, _fixture_summary(fixtures)],
		fixtures,
	))

	# A column that splits a grapheme cluster must be rejected. Codepoint
	# columns are the public API contract, so normalize byte offsets first.
	var combining := "e\u0301"
	var combining_breaks := _to_array(text_server.string_get_character_breaks(combining, ""))
	var boundaries := _codepoint_boundaries(combining, combining_breaks, unit)
	var inside_column := 1
	var is_boundary := boundaries.has(inside_column)
	checks.append(Util.check(
		"split_cluster_detected",
		boundaries.has(0) and boundaries.has(combining.length()) and !is_boundary,
		"boundaries=%s; column %d splits the cluster: %s" % [str(boundaries), inside_column, str(!is_boundary)],
		{"boundaries": boundaries},
	))

	var edit := CodeEdit.new()
	edit.text = "abc\né"
	var rect: Rect2i = edit.get_rect_at_line_column(0, 1)
	var rect_ok := rect is Rect2i and is_finite(float(rect.position.x)) and is_finite(float(rect.position.y))
	checks.append(Util.check(
		"caret_rect_api",
		rect_ok,
		"get_rect_at_line_column(0, 1)=%s" % str(rect),
		{"rect": str(rect)},
	))
	edit.free()

	limitations.append(
		"Pixel alignment of ghost glyphs against drawn text (tabs, zoom 100/150/200%, proportional fonts) requires a window and screenshots; it is not proven by this headless run."
	)

	return {
		"probe": "E8",
		"title": "Ghost alignment and Unicode mapping (pure part)",
		"status": Util.status(checks, limitations),
		"checks": checks,
		"limitations": limitations,
		"metrics": {
			"break_unit": unit,
			"fixtures": fixtures,
		},
		"notes": [
			"TextServer character breaks split the ZWJ family into multiple clusters on this build; that is the documented caveat, not a silent pass.",
			"Columns are codepoints, matching TextEdit.get_caret_column(); byte offsets are converted before split checks.",
		],
	}


func _to_array(packed: PackedInt32Array) -> Array:
	var out: Array = []
	for value in packed:
		out.append(int(value))
	return out


func _codepoint_boundaries(text: String, breaks: Array, unit: String) -> Array:
	var mapped: Array = []
	if unit == "bytes":
		var byte_to_codepoint: Dictionary = {}
		var byte_offset := 0
		for codepoint_index in text.length():
			byte_to_codepoint[byte_offset] = codepoint_index
			byte_offset += _utf8_length(text.unicode_at(codepoint_index))
		byte_to_codepoint[byte_offset] = text.length()
		for value in breaks:
			mapped.append(int(byte_to_codepoint.get(int(value), -1)))
	else:
		mapped = breaks.duplicate()

	var out: Array = [0]
	for value in mapped:
		if int(value) >= 0 and int(value) < text.length() and !out.has(int(value)):
			out.append(int(value))
	if !out.has(text.length()):
		out.append(text.length())
	return out


func _utf8_length(codepoint: int) -> int:
	if codepoint <= 0x7F:
		return 1
	if codepoint <= 0x7FF:
		return 2
	if codepoint <= 0xFFFF:
		return 3
	return 4


func _fixture_summary(fixtures: Dictionary) -> String:
	var parts: Array = []
	for name in fixtures:
		var entry: Dictionary = fixtures[name]
		parts.append("%s=%d/%d" % [name, int(entry["clusters"]), int(entry["codepoints"])])
	return ", ".join(parts)
