class_name TextSearchBackend
extends "res://src/platform/search_backend.gd"

## Plain literal search for the indexed workspace.
##
## Files are read in the service's time slices, so even a 5,000-file folder
## never blocks a frame for long. Binary files are rejected with a NUL probe
## and a small extension list, and oversized files are skipped so a stray
## minified bundle or log cannot stall the scan.

const SearchText = preload("res://src/platform/search_text.gd")
const PathUtils = preload("res://src/base/path_utils.gd")

const DEFAULT_MAX_FILE_SIZE := 2 * 1024 * 1024
const DEFAULT_MAX_MATCHES_PER_FILE := 200

const BINARY_EXTENSIONS := {
	"png": true, "jpg": true, "jpeg": true, "gif": true, "bmp": true,
	"ico": true, "webp": true, "tga": true, "svgz": true,
	"zip": true, "gz": true, "bz2": true, "xz": true, "7z": true,
	"rar": true, "tar": true,
	"exe": true, "dll": true, "so": true, "dylib": true, "bin": true,
	"pdf": true, "doc": true, "docx": true, "xls": true, "xlsx": true,
	"ppt": true, "pptx": true,
	"mp3": true, "wav": true, "ogg": true, "ogv": true, "mp4": true,
	"webm": true, "mov": true, "avi": true, "mkv": true, "flac": true,
	"ttf": true, "otf": true, "woff": true, "woff2": true,
	"class": true, "pyc": true, "o": true, "a": true, "lib": true,
	"sqlite": true, "db": true,
}


func _scan_file(path: String, _rel: String) -> Dictionary:
	var extension := PathUtils.extension(path).to_lower()
	if BINARY_EXTENSIONS.has(extension):
		return {"ok": true, "matches": [], "error": ""}

	var max_size := int(options.get("max_file_size", DEFAULT_MAX_FILE_SIZE))
	var max_per_file := maxi(1, int(options.get("max_matches_per_file", DEFAULT_MAX_MATCHES_PER_FILE)))

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"ok": false, "matches": [], "error": "Could not read " + path}

	var size := file.get_length()
	if max_size > 0 and size > max_size:
		file = null
		return {"ok": true, "matches": [], "error": ""}

	# Probe raw bytes before decoding: get_as_text() drops everything from the
	# first NUL onward, so a String probe can never detect binary content.
	var probe := file.get_buffer(mini(size, SearchText.BINARY_PROBE))
	if SearchText.is_binary(probe):
		file = null
		return {"ok": true, "matches": [], "error": ""}

	file.seek(0)
	var content := file.get_as_text()
	file = null

	if content.is_empty():
		return {"ok": true, "matches": [], "error": ""}

	var case_sensitive := bool(options.get("case_sensitive", false))
	var matched := content.find(query) != -1 if case_sensitive else content.findn(query) != -1
	if !matched:
		return {"ok": true, "matches": [], "error": ""}

	var matches: Array = []
	var lines := content.split("\n")
	var length := query.length()

	for line_index in range(lines.size()):
		var line: String = lines[line_index]
		if line.ends_with("\r"):
			line = line.substr(0, line.length() - 1)

		var columns := SearchText.find_columns(line, query, case_sensitive)
		for column in columns:
			matches.append({
				"line": line_index,
				"column": column,
				"length": length,
				"preview": SearchText.preview_of(line, column, length),
			})
			if matches.size() >= max_per_file:
				return {"ok": true, "matches": matches, "error": ""}

	return {"ok": true, "matches": matches, "error": ""}
