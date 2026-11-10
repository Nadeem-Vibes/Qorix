extends RefCounted

## Offline plain-language glossary.
##
## One JSON file per language lives in `res://resources/glossary/`. A hover looks up the
## word under the pointer; the explicit "Explain this" command can also explain
## the current selection. No network request is ever made, and an unknown word
## simply produces no card instead of an error.

const Store = preload("res://src/base/file_store.gd")
const Paths = preload("res://src/base/path_utils.gd")

const ROOT := "res://resources/glossary"

const LANGUAGE_BY_EXTENSION := {
	"py": "python",
	"pyw": "python",
	"html": "html",
	"htm": "html",
	"css": "css",
	"js": "javascript",
	"mjs": "javascript",
	"cjs": "javascript",
	"jsx": "javascript",
	"c": "c",
	"h": "c",
}

var root_path: String = ROOT

var _cache: Dictionary = {}
var _errors: Dictionary = {}


func language_for_path(path: String) -> String:
	var extension := Paths.extension(path).to_lower()
	return str(LANGUAGE_BY_EXTENSION.get(extension, ""))


func has_language(language: String) -> bool:
	return !load_language(language).is_empty()


## Returns the language document, or {} when there is no glossary for it.
## {version, language, display, entries}. Entries are indexed by term/alias in
## a separate lookup table so a hover is a dictionary hit, not a linear scan.
func load_language(language: String) -> Dictionary:
	var key := str(language).strip_edges().to_lower()
	if key.is_empty():
		return {}
	if _cache.has(key):
		return _cache[key]

	var path := root_path.path_join(key + ".json")
	var result: Dictionary = Store.load_json(path)
	if !bool(result.get("ok", false)):
		_errors[key] = str(result.get("error", "The glossary file could not be read."))
		_cache[key] = {}
		return {}

	var data: Dictionary = result.get("data", {})
	var entries: Array = []
	var raw_entries: Variant = data.get("entries", [])
	if raw_entries is Array:
		for raw in raw_entries:
			if !(raw is Dictionary):
				continue
			var entry := _normalize_entry(raw)
			if !entry.is_empty():
				entries.append(entry)

	var document := {
		"version": int(data.get("version", 1)),
		"language": str(data.get("language", key)),
		"display": str(data.get("display", key.capitalize())),
		"entries": entries,
	}
	_cache[key] = document
	return document


func error_for(language: String) -> String:
	load_language(language)
	return str(_errors.get(str(language).to_lower(), ""))


## Looks a word up in one language. The result always has `found`; when true it
## also carries term, plain, example, language and display.
func lookup(language: String, word: String) -> Dictionary:
	var document := load_language(language)
	if document.is_empty():
		return {"found": false, "language": str(language)}

	var candidates := _candidates(word)
	for candidate in candidates:
		for entry in document.get("entries", []):
			if _normalize_word(str(entry.get("term", ""))) == candidate:
				return _result(entry, document)
			for alias in entry.get("aliases", []):
				if _normalize_word(str(alias)) == candidate:
					return _result(entry, document)
	return {"found": false, "language": str(document.get("language", language))}


func lookup_for_path(path: String, word: String) -> Dictionary:
	var language := language_for_path(path)
	if language.is_empty():
		return {"found": false, "language": ""}
	return lookup(language, word)


func explain_at(path: String, line_text: String, column: int) -> Dictionary:
	return lookup_for_path(path, word_at(line_text, column))


func language_display(language: String) -> String:
	return str(load_language(language).get("display", str(language).capitalize()))


## BBCode for the floating hover panel. Code is escaped because RichTextLabel
## treats square brackets as markup even inside [code].
func bbcode(entry: Dictionary) -> String:
	if !bool(entry.get("found", false)):
		return ""
	var term := str(entry.get("term", ""))
	var language := str(entry.get("display", entry.get("language", "")))
	var plain := str(entry.get("plain", ""))
	var example := str(entry.get("example", ""))

	var out := "[color=#8bd5ff][b]%s[/b][/color]" % _escape_bbcode(term)
	if !language.is_empty():
		out += "  [color=#7f848e]%s[/color]" % _escape_bbcode(language)
	if !plain.is_empty():
		out += "\n" + _escape_bbcode(plain)
	if !example.is_empty():
		out += "\n[color=#7f848e]Example[/color]\n[code]%s[/code]" % _escape_bbcode(example)
	return out


## Plain text for notices, tests and accessibility.
func plain_text(entry: Dictionary) -> String:
	if !bool(entry.get("found", false)):
		return ""
	var parts: Array[String] = [str(entry.get("term", ""))]
	var plain := str(entry.get("plain", ""))
	if !plain.is_empty():
		parts.append(plain)
	var example := str(entry.get("example", ""))
	if !example.is_empty():
		parts.append("Example: " + example)
	return " — ".join(parts)


## Expands the word around `column` on a line. Used by the hover fallback and
## by the explicit command (which passes the whole selected line + column 0).
static func word_at(line_text: String, column: int) -> String:
	if line_text.is_empty():
		return ""
	var safe_column := clampi(column, 0, line_text.length())
	var start := safe_column
	var end := safe_column
	var is_word := func(character: String) -> bool:
		if character.is_empty():
			return false
		return "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_".contains(character)

	while start > 0 and is_word.call(line_text[start - 1]):
		start -= 1
	while end < line_text.length() and is_word.call(line_text[end]):
		end += 1
	if start == end:
		# The pointer may sit just after the word (CodeEdit reports the caret
		# column after the character under the mouse).
		start = maxi(0, safe_column - 1)
		end = safe_column
		while start > 0 and is_word.call(line_text[start - 1]):
			start -= 1
		while end < line_text.length() and is_word.call(line_text[end]):
			end += 1
	return line_text.substr(start, end - start)


func clear_cache() -> void:
	_cache.clear()
	_errors.clear()


func _normalize_entry(raw: Dictionary) -> Dictionary:
	var term := str(raw.get("term", "")).strip_edges()
	if term.is_empty():
		return {}
	var aliases: Array = []
	var raw_aliases: Variant = raw.get("aliases", [])
	if raw_aliases is Array:
		for alias in raw_aliases:
			var value := str(alias).strip_edges()
			if !value.is_empty():
				aliases.append(value)
	return {
		"term": term,
		"term_key": _normalize_word(term),
		"aliases": aliases,
		"plain": str(raw.get("plain", "")),
		"example": str(raw.get("example", "")),
	}


func _result(entry: Dictionary, document: Dictionary) -> Dictionary:
	return {
		"found": true,
		"term": str(entry.get("term", "")),
		"plain": str(entry.get("plain", "")),
		"example": str(entry.get("example", "")),
		"language": str(document.get("language", "")),
		"display": str(document.get("display", "")),
	}


func _candidates(word: String) -> Array:
	var out: Array = []
	var clean := _normalize_word(word)
	if clean.is_empty():
		return out
	out.append(clean)

	# "print()" -> "print"; "list.append" -> "list" then "append".
	var without_call := _normalize_word(clean.trim_suffix("()"))
	if !without_call.is_empty() and !out.has(without_call):
		out.append(without_call)

	if clean.contains("."):
		var parts := clean.split(".")
		if !parts.is_empty():
			var first := _normalize_word(str(parts[0]))
			if !first.is_empty() and !out.has(first):
				out.append(first)
			var last := _normalize_word(str(parts[parts.size() - 1]))
			if !last.is_empty() and !out.has(last):
				out.append(last)
	return out


static func _normalize_word(value: String) -> String:
	var out := ""
	for character in value.strip_edges().to_lower():
		if "abcdefghijklmnopqrstuvwxyz0123456789_".contains(character):
			out += character
		elif character == "." and !out.ends_with("."):
			out += character
	return out.trim_suffix(".")


static func _escape_bbcode(value: String) -> String:
	return value.replace("[", "[lb]")
