class_name PathUtils
extends RefCounted

## Path helpers shared by every file-facing part of the editor.
##
## The editor accepts paths from several sources (the custom picker, the CLI,
## quick-open, native save dialogs) and they do not always spell the same file
## the same way: C:/foo vs C:\foo vs c:/foo, trailing slashes, ./ and ../.
## normalize() gives us one display form; canonical() gives us one identity
## form; same_file() compares identities.

## Lexically normalizes a path: forward slashes, no duplicate separators, no
## trailing slash (except a root), and . / .. segments resolved. It keeps
## res://, user:// and UNC prefixes intact.
static func normalize(path: String) -> String:
	if path.is_empty():
		return ""

	var rest := path.replace("\\", "/")
	var prefix := ""

	# Require at least two characters before "://": "C://foo" is a Windows
	# drive path with duplicate separators, not a one-letter URL scheme.
	var scheme_index := rest.find("://")
	if scheme_index > 1:
		prefix = rest.substr(0, scheme_index + 3)
		rest = rest.substr(scheme_index + 3)
	elif rest.begins_with("//"):
		prefix = "//"
		rest = rest.substr(2)
	elif rest.begins_with("/"):
		prefix = "/"
		rest = rest.substr(1)

	var absolute := !prefix.is_empty()
	var parts := rest.split("/", false)
	var out: Array[String] = []

	for part in parts:
		if part.is_empty() or part == ".":
			continue

		if part == "..":
			if !out.is_empty() and out[out.size() - 1] != "..":
				out.remove_at(out.size() - 1)
			elif !absolute:
				out.append("..")
			continue

		out.append(part)

	var result := prefix + "/".join(out)
	if result.is_empty():
		return "/" if absolute else ""

	# Drive roots lose their slash during the rebuild ("C:" -> "C:/").
	if result.length() == 2 and result[1] == ":":
		result += "/"

	return result


## Stable identity for comparisons. Uses the absolute path (res:// and user://
## are globalized) and folds case on Windows, where the filesystem does.
## Do not use this for display; normalize() keeps the user's casing.
static func canonical(path: String) -> String:
	if path.is_empty():
		return ""

	var result := normalize(ProjectSettings.globalize_path(path))
	if OS.get_name() == "Windows":
		result = result.to_lower()

	return result


static func same_file(a: String, b: String) -> bool:
	if a.is_empty() or b.is_empty():
		return false

	return canonical(a) == canonical(b)


## True when path is root itself or lives below it. Segment-aware, so
## "/tmp/foo2" is not treated as a child of "/tmp/foo".
static func is_subpath(root: String, path: String) -> bool:
	var canonical_root := canonical(root)
	var canonical_path := canonical(path)

	if canonical_root.is_empty() or canonical_path.is_empty():
		return false
	if canonical_root == canonical_path:
		return true
	if canonical_root == "/":
		return canonical_path.begins_with("/")
	if canonical_root.ends_with("/"):
		return canonical_path.begins_with(canonical_root)

	return canonical_path.begins_with(canonical_root + "/")


## Extension without the dot, or "" when there is none. Dotfiles such as
## ".gitignore" do not count as having an extension.
static func extension(path: String) -> String:
	if path.is_empty():
		return ""

	var file_name := normalize(path).get_file()
	var dot := file_name.rfind(".")
	if dot <= 0 or dot == file_name.length() - 1:
		return ""

	return file_name.substr(dot + 1)
