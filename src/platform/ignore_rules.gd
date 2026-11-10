class_name IgnoreRules
extends RefCounted

## A small, ordered .gitignore matcher.
##
## Rules are added with add_file() for every .gitignore met while walking, in
## increasing directory depth. Later rules win, and a negated rule can bring a
## path back. The caller decides whether it is safe to prune an ignored
## directory: if any negation exists, keep walking and filter entries instead.
##
## Supported syntax: blank lines/comments, `!` negation, trailing `/` for
## directories only, leading `/` anchoring, `*`, `?`, `[abc]` and `**`.

var has_negation: bool = false

var _rules: Array = []


## Adds every line of one .gitignore. `base_rel` is the folder of the file
## relative to the workspace root ("" for the root file).
func add_file(base_rel: String, text: String) -> void:
	var base := base_rel.strip_edges().trim_prefix("/").trim_suffix("/")
	var order := 0
	for raw_line in text.split("\n"):
		_add_line(base, raw_line, order)
		order += 1


func _add_line(base: String, raw_line: String, order: int) -> void:
	var line := raw_line.strip_edges()
	if line.is_empty() or line.begins_with("#"):
		return

	var negate := line.begins_with("!")
	if negate:
		line = line.substr(1).strip_edges()
	if line.is_empty():
		return

	var dir_only := line.ends_with("/")
	if dir_only:
		line = line.trim_suffix("/")
	var anchored := line.begins_with("/")
	if anchored:
		line = line.substr(1)
	if line.is_empty():
		return

	var rooted := anchored or line.contains("/")

	# The part of the expression that identifies the ignored path itself.
	var prefix := ""
	if !base.is_empty():
		prefix = _escape(base) + "/"
	var head := ""
	if rooted:
		head = "^" + prefix + _glob_to_regex(line)
	else:
		# A pattern without a slash matches a name at any depth below its own
		# .gitignore, so nesting has to be part of the expression.
		head = "^" + prefix + "(?:.*/)?" + _glob_to_regex(line)

	var exact := _regex(head + "$")
	if exact == null:
		return
	# A directory rule also ignores everything inside that directory. This is
	# a separate expression so a plain file whose name merely equals the
	# directory (`build`) is not treated as a directory.
	var descendants: RegEx = null
	if dir_only:
		descendants = _regex(head + "(?:/.*)$")

	_rules.append({
		"regex": exact,
		"descendants": descendants,
		"negate": negate,
		"dir_only": dir_only,
		"base": base,
		"depth": 0 if base.is_empty() else base.split("/").size(),
		"order": order,
	})
	if negate:
		has_negation = true

	# Root-first, then source order inside one file.
	_rules.sort_custom(func(a, b) -> bool:
		if int(a.depth) != int(b.depth):
			return int(a.depth) < int(b.depth)
		if str(a.base) != str(b.base):
			return str(a.base) < str(b.base)
		return int(a.order) < int(b.order)
	)


func _regex(expression: String) -> RegEx:
	var regex := RegEx.new()
	if regex.compile(expression) != OK:
		return null
	return regex


func _glob_to_regex(pattern: String) -> String:
	var out := ""
	var i := 0
	while i < pattern.length():
		var character := pattern[i]
		if character == "*":
			if i + 1 < pattern.length() and pattern[i + 1] == "*":
				i += 1
				if i + 1 < pattern.length() and pattern[i + 1] == "/":
					i += 1
					out += "(?:.*/)?"
				else:
					out += ".*"
			else:
				out += "[^/]*"
		elif character == "?":
			out += "[^/]"
		elif character == "[":
			var end := pattern.find("]", i + 1)
			if end == -1:
				out += "\\["
			else:
				out += pattern.substr(i, end - i + 1)
				i = end
		else:
			out += _escape(character)
		i += 1
	return out


static func _escape(text: String) -> String:
	var out := ""
	for character in text:
		if character in [".", "+", "*", "?", "^", "$", "(", ")", "[", "]", "{", "}", "|", "\\", "/"]:
			out += "\\" + str(character)
		else:
			out += str(character)
	return out


## True when the path is ignored by the rules loaded so far.
func matches(rel_path: String, is_dir: bool = false) -> bool:
	var path := rel_path.strip_edges().trim_prefix("/")
	if path.is_empty():
		return false

	var ignored := false
	for rule in _rules:
		var matched := false
		if (rule.regex as RegEx).search(path) != null:
			# An exact match on a directory-only rule means the queried path
			# itself is that directory, so a same-named file stays visible.
			matched = is_dir or !bool(rule.dir_only)
		elif rule.descendants != null and (rule.descendants as RegEx).search(path) != null:
			matched = true

		if matched:
			ignored = !bool(rule.negate)
	return ignored


func is_empty() -> bool:
	return _rules.is_empty()
