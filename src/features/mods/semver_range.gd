extends RefCounted

## Semver ranges for mod manifests and dependency declarations.
##
## VersionUtils already orders versions; this adds the range grammar mod authors
## declare: `^1.2.0`, `~1.2`, `>=1.0.0 <2.0.0`, `1.2.3`, `*` and `||` groups.
## Pre-release/build suffixes are ignored for ordering because VersionUtils
## ignores them too; a mod asking for `^1.2.0` therefore accepts `1.2.0-beta`.
##
## The supported grammar is deliberately small: caret, tilde, comparison
## operators, exact versions, wildcard, comma/space AND and `||` OR.

const Version = preload("res://src/base/version_utils.gd")

const MAX_RANGE_LENGTH := 200
const OPERATORS := [">=", "<=", "^", "~", ">", "<", "="]


## Strict three-part semver, optionally with a pre-release/build suffix.
static func is_version(text: String) -> bool:
	var value := str(text).strip_edges()
	if value.is_empty() or value.length() > 80:
		return false
	return _match("^[0-9]+\\.[0-9]+\\.[0-9]+([-+][0-9A-Za-z.-]+)?$", value)


## True when the whole range string parses.
static func is_range(text: String) -> bool:
	return bool(parse(text).get("ok", false))


## Parses a range into OR groups of AND terms.
## Returns {ok, groups: [[{op, version, parts}]], error}.
static func parse(range_text: String) -> Dictionary:
	var text := str(range_text).strip_edges()
	if text.length() > MAX_RANGE_LENGTH:
		return _invalid("The range is longer than %d characters." % MAX_RANGE_LENGTH)
	if text.is_empty() or text == "*":
		return {"ok": true, "groups": [], "error": ""}

	var groups: Array = []
	for raw_group in text.split("||", true):
		var group := raw_group.strip_edges()
		if group.is_empty():
			return _invalid("Empty range group.")

		var terms: Array = []
		for raw_term in group.replace(",", " ").split(" ", false):
			var term := _parse_term(str(raw_term))
			if !term.get("ok", false):
				return term
			terms.append(term["value"])

		if terms.is_empty():
			return _invalid("No comparison in '%s'." % group)
		groups.append(terms)

	return {"ok": true, "groups": groups, "error": ""}


## True when `version` satisfies `range_text`. An invalid range rejects
## everything rather than silently accepting it.
static func satisfies(version: String, range_text: String) -> bool:
	if !is_version(version):
		return false

	var parsed := parse(range_text)
	if !parsed.get("ok", false):
		return false

	var groups: Array = parsed["groups"]
	if groups.is_empty():
		return true

	for group in groups:
		var matched := true
		for term in group:
			if !_matches(version, term):
				matched = false
				break
		if matched:
			return true

	return false


# ── INTERNALS ───────────────────────────────────────────────────────────────

static func _parse_term(raw: String) -> Dictionary:
	var text := raw.strip_edges()
	if text.is_empty():
		return _invalid("Empty comparison.")

	if text == "*":
		return {"ok": true, "value": {"op": "*", "version": "0.0.0", "parts": 0}}

	var op := "="
	for candidate in OPERATORS:
		if text.begins_with(candidate):
			op = candidate
			text = text.substr(candidate.length()).strip_edges()
			break

	if text.is_empty():
		return _invalid("'%s' has no version." % raw)

	if text.begins_with("v") or text.begins_with("V"):
		text = text.substr(1)

	var parts := text.split(".", true)
	if !_match("^[0-9]+(\\.[0-9]+){0,2}$", text) or parts.size() > 3:
		return _invalid("'%s' is not a valid version." % raw)

	for part in parts:
		if part.is_empty() or !part.is_valid_int():
			return _invalid("'%s' is not a valid version." % raw)

	var numbers: Array = []
	for part in parts:
		numbers.append(int(part))

	if op == "=" and parts.size() < 3:
		# Exact partial versions behave like a patch wildcard: "=1.2" is the
		# 1.2.x line, which is what an author writing it means.
		return {
			"ok": true,
			"value": {"op": "~", "version": _join(numbers), "parts": parts.size()},
		}

	return {
		"ok": true,
		"value": {"op": op, "version": _join(numbers), "parts": parts.size()},
	}


static func _matches(version: String, term: Dictionary) -> bool:
	var op := str(term.get("op", "="))
	if op == "*":
		return true

	var target := str(term.get("version", "0.0.0"))
	var comparison := Version.compare_versions(version, target)

	match op:
		"=":
			return comparison == 0
		">":
			return comparison > 0
		"<":
			return comparison < 0
		">=":
			return comparison >= 0
		"<=":
			return comparison <= 0
		"^":
			return comparison >= 0 and Version.compare_versions(version, _caret_ceiling(target)) < 0
		"~":
			return comparison >= 0 and Version.compare_versions(version, _tilde_ceiling(target, int(term.get("parts", 3)))) < 0

	return false


## ^1.2.3 -> 2.0.0, ^0.2.3 -> 0.3.0, ^0.0.3 -> 0.0.4.
static func _caret_ceiling(version: String) -> String:
	var parts := _numbers(version)
	if parts[0] > 0:
		return "%d.0.0" % (parts[0] + 1)
	if parts[1] > 0:
		return "0.%d.0" % (parts[1] + 1)
	return "0.0.%d" % (parts[2] + 1)


## ~1.2.3 -> 1.3.0, ~1.2 -> 1.3.0, ~1 -> 2.0.0.
static func _tilde_ceiling(version: String, parts_count: int) -> String:
	var parts := _numbers(version)
	if parts_count <= 1:
		return "%d.0.0" % (parts[0] + 1)
	return "%d.%d.0" % [parts[0], parts[1] + 1]


static func _numbers(version: String) -> Array:
	var cleaned := version.strip_edges()
	if cleaned.begins_with("v") or cleaned.begins_with("V"):
		cleaned = cleaned.substr(1)
	var dash := cleaned.find("-")
	if dash != -1:
		cleaned = cleaned.substr(0, dash)
	var plus := cleaned.find("+")
	if plus != -1:
		cleaned = cleaned.substr(0, plus)

	var parts := cleaned.split(".", true)
	var out: Array = []
	for index in range(3):
		out.append(int(parts[index]) if index < parts.size() and str(parts[index]).is_valid_int() else 0)
	return out


static func _join(parts: Array) -> String:
	var out: Array = []
	for index in range(3):
		out.append(int(parts[index]) if index < parts.size() else 0)
	return "%d.%d.%d" % out


static func _match(pattern: String, value: String) -> bool:
	var regex := RegEx.new()
	if regex.compile(pattern) != OK:
		return false
	return regex.search(value) != null


static func _invalid(message: String) -> Dictionary:
	return {"ok": false, "groups": [], "error": message}
