extends RefCounted

## Pure parsers for the Git commands used by GitService.
##
## Git output is parsed in the worker thread; this script has no scene or
## engine dependencies so every branch of the format can be unit tested.

## A single status can contain thousands of untracked files. The panel cannot
## usefully draw all of them, so the lists stop here while the counts keep
## counting. This is what keeps a huge repository from freezing the UI.
const MAX_ROWS := 3000

const STATUS_LABELS := {
	"M": "Modified",
	"A": "Added",
	"D": "Deleted",
	"R": "Renamed",
	"C": "Copied",
	"T": "Type changed",
	"U": "Conflicted",
	"?": "Untracked",
}


static func parse_status(text: String) -> Dictionary:
	var result := {
		"ok": true,
		"branch": "",
		"head": "",
		"upstream": "",
		"ahead": 0,
		"behind": 0,
		"detached": false,
		"initial": false,
		"files": [],
		"staged": [],
		"unstaged": [],
		"staged_count": 0,
		"unstaged_count": 0,
		"truncated": false,
		"error": "",
	}

	var lines := text.split("\n")
	for raw_line in lines:
		var line := raw_line.trim_suffix("\r")
		if line.is_empty():
			continue

		if line.begins_with("# branch.oid "):
			result["head"] = line.substr(13).strip_edges()
			result["initial"] = str(result["head"]) == "(initial)"
			continue
		if line.begins_with("# branch.head "):
			var head := line.substr(14).strip_edges()
			result["detached"] = head == "(detached)"
			result["branch"] = "" if result["detached"] else head
			continue
		if line.begins_with("# branch.upstream "):
			result["upstream"] = line.substr(18).strip_edges()
			continue
		if line.begins_with("# branch.ab "):
			var counts := line.substr(12).strip_edges().split(" ", false)
			for count in counts:
				if count.begins_with("+"):
					result["ahead"] = maxi(0, count.substr(1).to_int())
				elif count.begins_with("-"):
					result["behind"] = maxi(0, count.substr(1).to_int())
			continue
		if line.begins_with("#"):
			continue

		var entry := {}
		if line.begins_with("1 "):
			entry = _parse_ordinal_entry(line)
		elif line.begins_with("2 "):
			entry = _parse_rename_entry(line)
		elif line.begins_with("u "):
			entry = _parse_unmerged_entry(line)
		elif line.begins_with("? "):
			entry = {
				"path": unquote_path(line.substr(2)),
				"orig_path": "",
				"index_status": "?",
				"worktree_status": "?",
				"untracked": true,
				"conflicted": false,
				"renamed": false,
			}
		elif line.begins_with("! "):
			# Ignored files are deliberately not shown in Source Control.
			continue

		if entry.is_empty():
			continue

		var index_status := str(entry.get("index_status", "."))
		var worktree_status := str(entry.get("worktree_status", "."))
		var untracked := bool(entry.get("untracked", false))
		var conflicted := bool(entry.get("conflicted", false))

		entry["status"] = _status_for(index_status, worktree_status, untracked, conflicted)
		entry["status_label"] = str(STATUS_LABELS.get(str(entry["status"]), "Changed"))

		if index_status != "." and index_status != "?" and !conflicted:
			result["staged_count"] = int(result["staged_count"]) + 1
			if (result["staged"] as Array).size() < MAX_ROWS:
				(result["staged"] as Array).append(entry)
			else:
				result["truncated"] = true

		if untracked or conflicted or (worktree_status != "." and worktree_status != "?"):
			result["unstaged_count"] = int(result["unstaged_count"]) + 1
			if (result["unstaged"] as Array).size() < MAX_ROWS:
				(result["unstaged"] as Array).append(entry)
			else:
				result["truncated"] = true

		if (result["files"] as Array).size() < MAX_ROWS:
			(result["files"] as Array).append(entry)
		else:
			result["truncated"] = true

	return result


static func _parse_ordinal_entry(line: String) -> Dictionary:
	# 1 XY sub mH mI mW hH hI path
	var parts := line.split(" ", true, 8)
	if parts.size() < 9:
		return {}
	return {
		"path": unquote_path(parts[8]),
		"orig_path": "",
		"index_status": parts[1].substr(0, 1),
		"worktree_status": parts[1].substr(1, 1),
		"untracked": false,
		"conflicted": false,
		"renamed": false,
	}


static func _parse_rename_entry(line: String) -> Dictionary:
	# 2 XY sub mH mI mW hH hI Xscore path<TAB>original
	var parts := line.split(" ", true, 9)
	if parts.size() < 10:
		return {}

	var names := parts[9].split("\t", false)
	var new_path := unquote_path(names[0] if names.size() > 0 else "")
	var old_path := unquote_path(names[1] if names.size() > 1 else "")
	return {
		"path": new_path,
		"orig_path": old_path,
		"index_status": parts[1].substr(0, 1),
		"worktree_status": parts[1].substr(1, 1),
		"untracked": false,
		"conflicted": false,
		"renamed": true,
	}


static func _parse_unmerged_entry(line: String) -> Dictionary:
	# u XY sub m1 m2 m3 mW h1 h2 h3 path
	var parts := line.split(" ", true, 10)
	if parts.size() < 11:
		return {}
	return {
		"path": unquote_path(parts[10]),
		"orig_path": "",
		"index_status": parts[1].substr(0, 1),
		"worktree_status": parts[1].substr(1, 1),
		"untracked": false,
		"conflicted": true,
		"renamed": false,
	}


static func _status_for(index_status: String, worktree_status: String, untracked: bool, conflicted: bool) -> String:
	if untracked:
		return "?"
	if conflicted:
		return "U"
	if worktree_status != "." and worktree_status != "?":
		return worktree_status
	if index_status != "." and index_status != "?":
		return index_status
	return "M"


## Decodes the C-style quoting Git uses for paths with control characters.
## With core.quotepath=false most paths arrive unquoted; this still handles the
## legal cases Git must quote (tabs, newlines, quotes).
static func unquote_path(value: String) -> String:
	if value.length() < 2 or !value.begins_with("\"") or !value.ends_with("\""):
		return value

	var inner := value.substr(1, value.length() - 2)
	# Git octal escapes encode UTF-8 bytes, not Unicode code points. Collecting
	# bytes and decoding once turns "\303\251" into "é" instead of "Ã©".
	var bytes := PackedByteArray()
	var i := 0
	while i < inner.length():
		var character := inner[i]
		if character != "\\":
			bytes.append_array(character.to_utf8_buffer())
			i += 1
			continue

		if i + 1 >= inner.length():
			bytes.append(92)
			break

		var escape := inner[i + 1]
		match escape:
			"n":
				bytes.append(10)
				i += 2
			"t":
				bytes.append(9)
				i += 2
			"r":
				bytes.append(13)
				i += 2
			"\"":
				bytes.append(34)
				i += 2
			"\\":
				bytes.append(92)
				i += 2
			_:
				# Octal escape: up to three digits. Git only emits \0-\377, but
				# clamp rather than pass an out-of-range value to PackedByteArray.
				var digits := ""
				var cursor := i + 1
				while cursor < inner.length() and digits.length() < 3 and inner[cursor] >= "0" and inner[cursor] <= "7":
					digits += inner[cursor]
					cursor += 1
				if digits.is_empty():
					bytes.append_array(escape.to_utf8_buffer())
					i += 2
				else:
					var code := 0
					for digit in digits:
						code = code * 8 + digit.to_int()
					bytes.append(mini(code, 255))
					i = cursor

	var out := bytes.get_string_from_utf8()
	if out.is_empty() and !bytes.is_empty():
		# Not valid UTF-8 (Git does not require it). Keep the bytes visible
		# rather than silently returning an empty path.
		for byte in bytes:
			out += char(byte)
	return out


static func parse_branches(text: String) -> Array:
	# --format=%(refname:short)%1f%(HEAD)%1f%(upstream:short)%1f%(committerdate:unix)
	var branches: Array = []
	for raw_line in text.split("\n"):
		var line := raw_line.trim_suffix("\r")
		if line.is_empty():
			continue
		var fields := line.split("\u001f", true)
		if fields.is_empty():
			continue
		var name := str(fields[0]).strip_edges()
		if name.is_empty():
			continue
		branches.append({
			"name": name,
			"current": fields.size() > 1 and str(fields[1]).strip_edges() == "*",
			"upstream": str(fields[2]).strip_edges() if fields.size() > 2 else "",
			"date": int(str(fields[3]).strip_edges()) if fields.size() > 3 and str(fields[3]).strip_edges().is_valid_int() else 0,
		})
	return branches


static func parse_log(text: String) -> Array:
	# %H %h %an %ae %at %ar %D %s, records separated by %x1e
	var commits: Array = []
	for raw_record in text.split("\u001e"):
		var record := raw_record.strip_edges()
		if record.is_empty():
			continue
		var fields := record.split("\u001f", true)
		if fields.size() < 7:
			continue
		var hash := str(fields[0]).strip_edges()
		if !_is_hex(hash):
			# A subject containing a raw unit separator splits one record into
			# two; the second never starts with a hex hash. Skip it.
			continue
		commits.append({
			"hash": hash,
			"short": str(fields[1]).strip_edges(),
			"author": str(fields[2]),
			"email": str(fields[3]),
			"timestamp": int(str(fields[4]).strip_edges()) if str(fields[4]).strip_edges().is_valid_int() else 0,
			"relative": str(fields[5]),
			"decorations": str(fields[6]).strip_edges(),
			"subject": str(fields[7]) if fields.size() > 7 else "",
		})
	return commits


static func _is_hex(value: String) -> bool:
	# Git abbreviates hashes to at least four hex chars; long names are 40.
	if value.length() < 4 or value.length() > 64:
		return false
	for character in value:
		if !((character >= "0" and character <= "9") or (character >= "a" and character <= "f") or (character >= "A" and character <= "F")):
			return false
	return true


static func parse_remotes(text: String) -> Array:
	var remotes: Array = []
	for raw_line in text.split("\n"):
		var name := raw_line.trim_suffix("\r").strip_edges()
		if !name.is_empty() and !remotes.has(name):
			remotes.append(name)
	return remotes


static func status_code_label(code: String) -> String:
	return str(STATUS_LABELS.get(code, "Changed"))
