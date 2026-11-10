class_name EditorDocument
extends RefCounted

## One open file/buffer. The text lives in the document's EditorView so every
## tab keeps its own undo history, carets, selection, folds and scrolling.
## This object tracks identity + the state that must survive tab switches.

const Paths = preload("res://src/base/path_utils.gd")

## Stable, monotonic, never reused. Mods see this value, never the object.
var id: int = 0

var path: String = ""
var display_name: String = ""
var modified: bool = false
var untitled: bool = false

var encoding: String = "UTF-8"
var line_endings: String = "LF"
var disk_mtime: int = 0

## A language chosen by GuessLang or by the "Detect Language" command. The
## override is deliberately separate from the path: the file may be .txt while
## its contents are Python. `language_highlight` is the extension used for
## syntax/keywords, `language_override` is the id RunService matches against.
## `language_source` is "" (path), "auto" or "manual".
var language_override: String = ""
var language_highlight: String = ""
var language_source: String = ""
var language_detection_attempted: bool = false

var caret_line: int = 0
var caret_column: int = 0
var scroll_vertical: int = 0
var scroll_horizontal: int = 0
var selection_from_line: int = 0
var selection_from_column: int = 0
var selection_to_line: int = 0
var selection_to_column: int = 0
var has_selection_state: bool = false

## HEAD copy of this file, used by the Git gutter and the side-by-side diff.
## `git_baseline_known` becomes true once a baseline request finished (even for
## an untracked file, whose baseline is empty). `git_baseline_pending` prevents
## a path from being requested twice while the worker is busy.
var git_baseline_text: String = ""
var git_baseline_known: bool = false
var git_baseline_tracked: bool = false
var git_baseline_pending: bool = false

# Untyped on purpose: EditorView also refers to EditorDocument, and a typed
# pair of custom classes would be a cyclic dependency for the parser.
var view = null

# Text is only cached until the view exists.
var _pending_text: String = ""


func set_pending_text(content: String) -> void:
	_pending_text = content
	line_endings = detect_line_endings(content)
	encoding = detect_encoding(content)


func pending_text() -> String:
	return _pending_text


func clear_pending_text() -> void:
	_pending_text = ""


func text() -> String:
	if view != null and is_instance_valid(view):
		return view.text
	return _pending_text


func set_text(content: String, mark_clean: bool = true) -> void:
	_pending_text = content
	line_endings = detect_line_endings(content)
	encoding = detect_encoding(content)

	if view != null and is_instance_valid(view):
		view.set_document_text(content, mark_clean)

	if mark_clean:
		modified = false
		if view != null and is_instance_valid(view):
			view.file_modified = false


func extension() -> String:
	var ext := Paths.extension(path)
	return ext if !ext.is_empty() else "txt"


## The extension every view/comment/highlighter should use. Unlike extension()
## this honours a detected/selected language override.
func language_extension() -> String:
	if !language_highlight.is_empty():
		return language_highlight
	if !language_override.is_empty():
		return language_override
	return extension()


func has_language_override() -> bool:
	return !language_override.is_empty() or !language_highlight.is_empty()


func set_language_override(language: Variant, highlight: Variant = "", source: String = "manual") -> void:
	language_override = _clean_language(language)
	language_highlight = _clean_language(highlight)
	language_source = source if source == "auto" or source == "manual" else "manual"
	if !has_language_override():
		language_source = ""
	language_detection_attempted = true


## `allow_retry` is used by Save As: the new extension may be a plain .txt, so
## auto-detection is welcome again. A manual clear keeps the flag set, because
## "stop guessing this file" should not re-run detection on the next activation.
func clear_language_override(allow_retry: bool = false) -> void:
	language_override = ""
	language_highlight = ""
	language_source = ""
	language_detection_attempted = !allow_retry


static func _clean_language(value: Variant) -> String:
	var text := str(value).strip_edges().to_lower().trim_prefix(".")
	var out := ""
	for i in range(text.length()):
		var character := text[i]
		if "abcdefghijklmnopqrstuvwxyz0123456789_+#-".contains(character):
			out += character
	return out


func title() -> String:
	if !display_name.is_empty():
		return display_name
	if !path.is_empty():
		return path.get_file()
	return "Untitled"


func capture_state() -> void:
	if view == null or !is_instance_valid(view):
		return

	caret_line = view.get_caret_line()
	caret_column = view.get_caret_column()
	scroll_vertical = view.scroll_vertical
	scroll_horizontal = view.scroll_horizontal

	has_selection_state = view.has_selection()
	if has_selection_state:
		selection_from_line = view.get_selection_from_line()
		selection_from_column = view.get_selection_from_column()
		selection_to_line = view.get_selection_to_line()
		selection_to_column = view.get_selection_to_column()


func restore_state() -> void:
	if view == null or !is_instance_valid(view):
		return

	var last_line := maxi(0, view.get_line_count() - 1)
	var line := clampi(caret_line, 0, last_line)
	var column := clampi(caret_column, 0, view.get_line(line).length())

	view.set_caret_line(line)
	view.set_caret_column(column)

	if has_selection_state:
		view.select(
			selection_from_line,
			selection_from_column,
			selection_to_line,
			selection_to_column
		)

	# Restore scroll last: moving the caret may scroll it into view first.
	view.scroll_vertical = scroll_vertical
	view.scroll_horizontal = scroll_horizontal


func mark_dirty() -> void:
	modified = true
	if view != null and is_instance_valid(view):
		view.file_modified = true


func mark_clean() -> void:
	modified = false
	if view != null and is_instance_valid(view):
		view.file_modified = false


static func detect_line_endings(content: String) -> String:
	if content.contains("\r\n"):
		return "CRLF"
	if content.contains("\r"):
		return "CR"
	return "LF"


static func detect_encoding(content: String) -> String:
	if content.begins_with("\ufeff"):
		return "UTF-8 BOM"
	return "UTF-8"
