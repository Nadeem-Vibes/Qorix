class_name EditorView
extends CodeEdit

## One CodeEdit per open document. Owning the widget is what gives every tab
## its own undo stack, carets, selection, folds and scroll position.

signal content_changed(view)
signal hover_requested(view, line, column)
signal definition_requested(view)
signal caret_moved(view, line, column)
signal problem_gutter_clicked(view, line)
signal action_gutter_clicked(view, line)
signal git_gutter_clicked(view, line)
signal debug_gutter_clicked(view, line)
signal large_file_mode_changed(view, is_large)

const VARIABLE = preload("res://resources/icons/variable.png")
const FUNCTION = preload("res://resources/icons/function.png")
const LspText = preload("res://src/features/lsp/lsp_text.gd")
const AccessibilityHelpers = preload("res://src/platform/a11y.gd")
const CompletionScanScript = preload("res://src/platform/completion_scan.gd")
const UI_MOTION = preload("res://src/platform/ui_motion.gd")

## Diagnostics and the action lightbulb share one gutter. Two 16 px strips
## pushed the code too far from the line numbers; one strip keeps the marks
## without the dead space.
const GUTTER_WIDTH := 14
## A slim strip left of the diagnostics gutter. Added / modified / deleted
## marks are one character wide, so it does not need the full 14 px.
const GIT_GUTTER_WIDTH := 10
## Breakpoints get their own clickable strip so a click can never be mistaken
## for a diagnostics or Git action.
const DEBUG_GUTTER_WIDTH := 16

var document = null
var file_modified: bool = false
var language_extension: String = "txt"

var _loading: bool = false
var _completion_pending: bool = false
var _completion_delay: float = 0.0
var _completion_labels: Dictionary = {}

## Large-file mode. The two mirrors keep the per-keystroke decision free of
## settings lookups (compat_entry() duplicates a whole dictionary).
var large_file: bool = false
var _large_file_enabled: bool = true
var _large_file_threshold: int = AccessibilityHelpers.DEFAULT_LARGE_FILE_LINES

## Cached longest-line length for the camera. Recomputed at most twice a
## second, and only when the text actually changed.
var _longest_length: int = -1
var _longest_dirty: bool = true
var _longest_idle: float = 0.0

## Incremented for every completion request so an asynchronous language-server
## answer from an older request can be discarded.
var _completion_generation: int = 0

var _debug_gutter: int = -1
var _breakpoint_lines: Array[int] = []
var _execution_line: int = -1
var _painted_debug_lines: Array[int] = []

var _lsp_gutter: int = -1
var _painted_lsp_lines: Array[int] = []

var _git_gutter: int = -1
var _git_marks: Dictionary = {}
var _painted_git_lines: Array[int] = []
var _worst_diagnostics: Dictionary = {}
var _action_line: int = -1
var _last_diagnostics: Array = []
var _last_diagnostic_uri: String = ""
var _diagnostic_pulse_lines: Dictionary = {}


func _ready() -> void:
	symbol_tooltip_on_hover = true
	symbol_lookup_on_click = true
	theme = LuaSingleton.editor_theme
	text_changed.connect(_on_text_changed)
	code_completion_requested.connect(_on_code_completion_requested)
	symbol_hovered.connect(_on_symbol_hovered)
	symbol_lookup.connect(_on_symbol_lookup)
	symbol_validate.connect(_on_symbol_validate)
	caret_changed.connect(_on_caret_changed)
	gutter_clicked.connect(_on_gutter_clicked)
	_setup_debug_gutter()
	_setup_git_gutter()
	_setup_lsp_gutters()

	apply_theme()
	apply_settings()
	apply_language()


func load_document(doc, content: String) -> void:
	document = doc
	language_extension = doc.language_extension()

	_loading = true
	text = content
	_loading = false

	clear_git_marks()
	file_modified = doc.modified
	_longest_dirty = true
	apply_theme()
	apply_settings()
	apply_language()
	_refresh_large_file_mode(true)


## Used by reload-from-disk and external-change handling.
func set_document_text(content: String, mark_clean: bool = true) -> void:
	_loading = true
	text = content
	_loading = false
	clear_git_marks()
	# Line-based diagnostic marks point at the old buffer's lines now.
	clear_diagnostic_marks()
	_longest_dirty = true
	cancel_completion()
	_refresh_large_file_mode(true)
	# The host sizes the world from the active document; a plain text swap
	# never emits content_changed (it must not dirty the buffer), so tell the
	# host to re-measure directly. Without this, reloading a *longer* file
	# clipped the tail until the user typed something.
	var host := get_parent()
	if host is EditorHost:
		(host as EditorHost).refresh_height()

	if mark_clean:
		file_modified = false


func set_language_extension(extension: String) -> void:
	language_extension = extension
	apply_language()


func apply_theme() -> void:
	add_theme_color_override("background_color", LuaSingleton.gui.background_color)
	add_theme_color_override("current_line_color", LuaSingleton.gui.current_line_color)
	add_theme_color_override("selection_color", LuaSingleton.gui.selection_color)
	add_theme_color_override("font_color", LuaSingleton.gui.font_color)
	add_theme_color_override("word_highlighted_color", LuaSingleton.gui.word_highlighted_color)
	add_theme_color_override("completion_background_color", LuaSingleton.gui.completion_background_color)
	add_theme_color_override("completion_selected_color", LuaSingleton.gui.completion_selected_color)
	add_theme_color_override("caret_color", LuaSingleton.gui.caret_color)
	_repaint_diagnostics()
	_repaint_git_marks()
	_repaint_debug_gutter()


func apply_language() -> void:
	if LuaSingleton.language_service == null:
		return

	# Large files get no highlighter at all: a CodeHighlighter rescans the
	# buffer on every edit, which is exactly the cost large-file mode exists to
	# avoid. Text stays readable in the theme's font colour.
	if large_file:
		syntax_highlighter = null
		return

	syntax_highlighter = LuaSingleton.language_service.get_highlighter(language_extension)


func apply_settings() -> void:
	_read_large_file_settings()
	_set_from_setting("caret_type")
	_set_from_setting("caret_blink")
	_set_from_setting("caret_interval")
	_set_from_setting("draw_line_numbers")
	_set_from_setting("code_completion")
	_set_from_setting("indentation_size")
	_set_from_setting("indentation_automatic")
	_set_from_setting("indentation_use_spaces")
	_set_from_setting("auto_brace_completion")
	_set_from_setting("auto_brace_highlight_matching")
	_set_from_setting("git_gutter")
	_update_gutter_widths()
	# Scrolling and the minimap are NOT applied here: the CodeEdit grows to
	# fit its content and never scrolls internally (the camera does that), and
	# its built-in minimap is painted inside a 2044 x 44630 world-space canvas
	# that the zoomed camera never shows. Both live outside the view now —
	# the camera owns the scroll, Minimap owns the strip.


## Re-evaluates large-file mode after the mode/threshold setting changed. The
## character count is only copied here, not on every ordinary settings tick.
func refresh_large_file_mode() -> void:
	_read_large_file_settings()
	_refresh_large_file_mode(true)


## Applies one editor setting to this view (used when the settings panel
## changes a value at runtime).
func apply_setting(property: String, value: Variant) -> void:
	match property:
		"caret_type":
			caret_type = int(value)
		"caret_blink":
			caret_blink = bool(value)
		"caret_interval":
			caret_blink_interval = float(value)
		"draw_line_numbers":
			gutters_draw_line_numbers = bool(value)
		"code_completion":
			code_completion_enabled = bool(value)
		"indentation_size":
			indent_size = int(value)
		"indentation_automatic":
			indent_automatic = bool(value)
		"indentation_use_spaces":
			indent_use_spaces = bool(value)
		"auto_brace_completion":
			auto_brace_completion_enabled = bool(value)
		"auto_brace_highlight_matching":
			auto_brace_completion_highlight_matching = bool(value)
		"git_gutter":
			_update_gutter_widths()
			_repaint_git_marks()
		"large_file_mode":
			_large_file_enabled = bool(value)
			_refresh_large_file_mode(true)
		"large_file_threshold":
			_large_file_threshold = int(value)
			_refresh_large_file_mode(true)


func _set_from_setting(property: String) -> void:
	var found = LuaSingleton.get_setting(property)
	if found.size() < 2 or found[1] == -1:
		return
	apply_setting(property, found[0].get("value", null))


func _on_text_changed() -> void:
	if _loading:
		return

	# Line numbers shift while typing, so stale gutter marks would point at the
	# wrong line until the server republishes. Drop them now; diagnostics come
	# back within a few hundred milliseconds.
	clear_diagnostic_marks()

	file_modified = true
	content_changed.emit(self)
	_longest_dirty = true
	_completion_generation += 1
	_refresh_large_file_mode()

	# Completion walks the whole buffer twice in Lua. Debounce it instead of
	# running on every keypress.
	_completion_delay = 0.35
	_completion_pending = true


func _process(delta: float) -> void:
	# The camera only needs the length of the longest line, and splitting the
	# buffer every frame is what made large files stutter. Measure lazily.
	_longest_idle -= delta
	if _longest_dirty and _longest_idle <= 0.0:
		_recompute_longest()

	if !_completion_pending:
		return

	_completion_delay -= delta
	if _completion_delay <= 0.0:
		_completion_pending = false
		request_code_completion()


func _on_code_completion_requested() -> void:
	_completion_generation += 1
	var generation := _completion_generation
	_completion_labels.clear()

	if large_file or !code_completion_enabled:
		cancel_completion()
		return

	if LuaSingleton.language_service != null:
		var state: Dictionary = LuaSingleton.language_service.get_extension(language_extension)
		if !bool(state.get("error", false)):
			var lua = state.get("lua")
			if lua != null:
				# The plugins walk the text twice. Scan a bounded window around
				# the caret instead of handing over the whole file.
				var scan: Dictionary = CompletionScanScript.window(
					text, get_caret_line(), get_caret_column()
				)
				var content := str(scan.get("text", ""))
				var scan_line := int(scan.get("line", get_caret_line()))
				var scan_column := int(scan.get("column", get_caret_column()))

				var function_names = lua.call_function("detect_functions", [content, scan_line, scan_column])
				var variable_names = lua.call_function("detect_variables", [content, scan_line, scan_column])

				if typeof(function_names) == Variant.Type.TYPE_ARRAY:
					for each in unique_array(function_names):
						_completion_labels[_completion_key(str(each), str(each) + "()")] = true
						add_code_completion_option(CodeEdit.KIND_FUNCTION, each, each + "()", LuaSingleton.keywords.function, FUNCTION)
				if typeof(variable_names) == Variant.Type.TYPE_ARRAY:
					for each in unique_array(variable_names):
						_completion_labels[_completion_key(str(each), str(each))] = true
						add_code_completion_option(CodeEdit.KIND_VARIABLE, each, each, LuaSingleton.keywords.variable, VARIABLE)

	update_code_completion_options(true)

	# The language server answers asynchronously. Merge its items into the
	# popup the Lua pass just opened instead of replacing it, so local symbol
	# suggestions and server suggestions share one list.
	var manager = _lsp_manager()
	if manager != null:
		var line := get_caret_line()
		var column := get_caret_column()
		manager.request_completion(self, line, column, func(items: Array) -> void:
			_merge_lsp_completion(items, line, column, generation)
		)


func _merge_lsp_completion(items: Array, line: int, column: int, generation: int) -> void:
	if generation != _completion_generation:
		# A newer request (or a cancelled one) owns the popup now.
		return
	if _loading or !has_focus():
		return
	if line != get_caret_line() or column != get_caret_column():
		# The user moved or typed while the server was thinking; stale items
		# would land at the wrong position.
		return
	var added := 0
	for item in items:
		if !(item is Dictionary):
			continue
		var data: Dictionary = item
		var label := str(data.get("label", ""))
		var insert_text := str(data.get("insert_text", label))
		if label.is_empty():
			continue
		var key := _completion_key(label, insert_text)
		if _completion_labels.has(key):
			continue
		_completion_labels[key] = true
		var kind := _completion_kind(int(data.get("kind", 1)))
		var color := _completion_color(str(data.get("category", "plain")))
		var icon: Resource = _completion_icon(str(data.get("category", "plain")))
		add_code_completion_option(kind, label, insert_text, color, icon)
		added += 1

	if added > 0:
		update_code_completion_options(true)


func _completion_key(label: String, insert_text: String) -> String:
	return label.to_lower() + "\n" + insert_text.to_lower()


func _completion_kind(kind: int) -> int:
	match kind:
		2, 3, 4:
			return CodeEdit.KIND_FUNCTION
		5, 6, 10, 20, 21:
			return CodeEdit.KIND_VARIABLE
		7, 8, 9, 22, 25:
			return CodeEdit.KIND_CLASS
		13:
			return CodeEdit.KIND_ENUM
		14:
			return CodeEdit.KIND_PLAIN_TEXT
		15:
			return CodeEdit.KIND_PLAIN_TEXT
	return CodeEdit.KIND_PLAIN_TEXT


func _completion_color(category: String) -> Color:
	var key := "symbol"
	match category:
		"function": key = "function"
		"variable": key = "variable"
		"class": key = "annotation"
		"constant": key = "symbol"
		"keyword": key = "reserved"
		"snippet": key = "member"
		"plain": key = "symbol"
	var value: Variant = LuaSingleton.keywords.get(key)
	return value if value is Color else LuaSingleton.gui.font_color


func _completion_icon(category: String) -> Resource:
	match category:
		"function": return FUNCTION
		"variable", "constant": return VARIABLE
	return null


func _lsp_manager():
	var node = get_parent()
	while node != null:
		if node is FileManager:
			return node.lsp_manager
		node = node.get_parent()
	return null


func unique_array(arr: Array) -> Array:
	var out := {}
	for element in arr:
		out[element] = element
	return out.values()


func get_longest_line(lines: Array = text.split("\n")) -> String:
	return longest_line_in(lines)


## Cached length for the camera. Never splits the buffer here.
func get_longest_line_length() -> int:
	if _longest_length < 0:
		_recompute_longest()
	return _longest_length


func _recompute_longest() -> void:
	_longest_dirty = false
	_longest_idle = 0.5
	var total := get_line_count()
	if total <= 0:
		_longest_length = 0
		return

	# A 10k-line file is sampled rather than walked: the zoom fit is a visual
	# hint, and 200 measurements are indistinguishable from 10,000 there.
	var step := 1
	if large_file:
		step = maxi(1, int(ceil(float(total) / 200.0)))

	var longest := 0
	for i in range(0, total, step):
		longest = maxi(longest, get_line(i).length())
	_longest_length = longest


func _read_large_file_settings() -> void:
	var mode: Array = LuaSingleton.get_setting("large_file_mode")
	if mode.size() >= 2 and int(mode[1]) != -1:
		_large_file_enabled = bool(mode[0].get("value", true))

	var threshold: Array = LuaSingleton.get_setting("large_file_threshold")
	if threshold.size() >= 2 and int(threshold[1]) != -1:
		_large_file_threshold = int(threshold[0].get("value", AccessibilityHelpers.DEFAULT_LARGE_FILE_LINES))


## Re-evaluates large-file mode. `force` re-reads the character count, which
## copies the whole buffer: only load/reload/settings changes can afford that.
func _refresh_large_file_mode(force: bool = false) -> void:
	var chars := text.length() if force else 0
	var next := _large_file_enabled and AccessibilityHelpers.is_large_file(
		get_line_count(), chars, _large_file_threshold
	)

	if next == large_file and !force:
		return

	var changed := next != large_file
	large_file = next
	_longest_dirty = true
	_longest_idle = 0.0

	if !changed:
		return

	cancel_completion()
	if large_file:
		# Diagnostic marks painted before the file crossed the threshold would
		# otherwise stay on screen even though new ones are suppressed.
		clear_diagnostic_marks()
	apply_language()
	large_file_mode_changed.emit(self, large_file)


## Cancels a pending debounce and invalidates any language-server answer that
## is still in flight.
func cancel_completion() -> void:
	_completion_generation += 1
	_completion_pending = false
	_completion_delay = 0.0
	if has_method("cancel_code_completion"):
		cancel_code_completion()


static func longest_line_in(lines: Array) -> String:
	var longest := ""
	for line in lines:
		var str_line := str(line)
		if str_line.length() > longest.length():
			longest = str_line
	return longest


# ── DEBUG GUTTER ────────────────────────────────────────────────────────────

func _setup_debug_gutter() -> void:
	add_gutter()
	_debug_gutter = get_gutter_count() - 1
	set_gutter_type(_debug_gutter, TextEdit.GUTTER_TYPE_STRING)
	set_gutter_draw(_debug_gutter, true)
	set_gutter_clickable(_debug_gutter, true)
	set_gutter_width(_debug_gutter, DEBUG_GUTTER_WIDTH)
	set_gutter_name(_debug_gutter, "debug")


## Paints breakpoint dots. `lines` are 0-based editor lines.
func set_breakpoint_lines(lines: Array) -> void:
	_breakpoint_lines.clear()
	for line in lines:
		var index := int(line)
		if index >= 0 and !_breakpoint_lines.has(index):
			_breakpoint_lines.append(index)
	_breakpoint_lines.sort()
	_repaint_debug_gutter()


## Paints the paused line. Pass -1 when the session is running or finished.
func set_execution_line(line: int) -> void:
	_execution_line = line if line >= 0 else -1
	_repaint_debug_gutter()


func clear_debug_marks() -> void:
	_breakpoint_lines.clear()
	_execution_line = -1
	_repaint_debug_gutter()


func debug_mark_at(line: int) -> String:
	if line == _execution_line:
		return "execution"
	if _breakpoint_lines.has(line):
		return "breakpoint"
	return ""


func debug_gutter_line_count() -> int:
	return _painted_debug_lines.size()


func _repaint_debug_gutter() -> void:
	if _debug_gutter < 0 or _debug_gutter >= get_gutter_count():
		return
	for line in _painted_debug_lines:
		if line >= 0 and line < get_line_count():
			set_line_gutter_text(line, _debug_gutter, "")
	_painted_debug_lines.clear()

	var line_count := get_line_count()
	for line in _breakpoint_lines:
		if line < 0 or line >= line_count:
			continue
		set_line_gutter_text(line, _debug_gutter, "●")
		set_line_gutter_item_color(line, _debug_gutter, _severity_color(1))
		_painted_debug_lines.append(line)

	if _execution_line >= 0 and _execution_line < line_count:
		set_line_gutter_text(_execution_line, _debug_gutter, "▶")
		set_line_gutter_item_color(_execution_line, _debug_gutter, _severity_color(2))
		if !_painted_debug_lines.has(_execution_line):
			_painted_debug_lines.append(_execution_line)


# ── GIT GUTTER ──────────────────────────────────────────────────────────────

func _setup_git_gutter() -> void:
	add_gutter()
	_git_gutter = get_gutter_count() - 1
	set_gutter_type(_git_gutter, TextEdit.GUTTER_TYPE_STRING)
	set_gutter_draw(_git_gutter, true)
	set_gutter_clickable(_git_gutter, true)
	set_gutter_width(_git_gutter, GIT_GUTTER_WIDTH)
	set_gutter_name(_git_gutter, "git")


## `marks` is {0-based line: "added" | "modified" | "deleted"}. Counts and
## other metadata keys are ignored, so the dictionary from GitDiff.line_diff()
## can be passed as-is.
func set_git_marks(marks: Dictionary) -> void:
	var previous := _git_marks.duplicate()
	_git_marks = marks.duplicate()
	_repaint_git_marks()
	for line in _git_marks.keys():
		if str(previous.get(line, "")) != str(_git_marks[line]):
			_pulse_gutter_line(int(line), _git_mark_color(str(_git_marks[line])))


func clear_git_marks() -> void:
	_git_marks.clear()
	_repaint_git_marks()


func git_gutter_line_count() -> int:
	return _painted_git_lines.size()


func git_mark_at(line: int) -> String:
	return str(_git_marks.get(line, ""))


func _repaint_git_marks() -> void:
	if _git_gutter < 0 or _git_gutter >= get_gutter_count():
		return
	for line in _painted_git_lines:
		if line >= 0 and line < get_line_count():
			set_line_gutter_text(line, _git_gutter, "")
	_painted_git_lines.clear()

	if !_setting_bool("git_gutter", true):
		return

	var lines: Array = _git_marks.keys()
	lines.sort()
	for line in lines:
		var index := int(line)
		var kind := str(_git_marks[line])
		if kind != "added" and kind != "modified" and kind != "deleted":
			continue
		if index < 0 or index >= get_line_count():
			continue
		set_line_gutter_text(index, _git_gutter, _git_glyph(kind))
		set_line_gutter_item_color(index, _git_gutter, _git_mark_color(kind))
		_painted_git_lines.append(index)


func _git_glyph(kind: String) -> String:
	if kind == "added":
		return "+"
	if kind == "deleted":
		return "−"
	return "▎"


func _git_mark_color(kind: String) -> Color:
	var key := "error"
	if kind == "added":
		key = "string"
	elif kind == "modified":
		key = "variable"
	var value: Variant = LuaSingleton.keywords.get(key)
	if value is Color:
		return value
	if kind == "added":
		return Color("#6a9955")
	if kind == "deleted":
		return Color("#e06c75")
	return Color("#d7ba7d")


# ── LSP GUTTERS AND DIAGNOSTICS ────────────────────────────────────────────

func _setup_lsp_gutters() -> void:
	add_gutter()
	_lsp_gutter = get_gutter_count() - 1
	set_gutter_type(_lsp_gutter, TextEdit.GUTTER_TYPE_STRING)
	set_gutter_draw(_lsp_gutter, true)
	set_gutter_clickable(_lsp_gutter, true)
	set_gutter_width(_lsp_gutter, GUTTER_WIDTH)
	set_gutter_name(_lsp_gutter, "lsp")


func _update_gutter_widths() -> void:
	if _debug_gutter >= 0:
		set_gutter_width(_debug_gutter, DEBUG_GUTTER_WIDTH)
	if _git_gutter >= 0:
		set_gutter_width(_git_gutter, GIT_GUTTER_WIDTH if _setting_bool("git_gutter", true) else 0)
	if _lsp_gutter < 0:
		return
	var show := _setting_bool("lsp_diagnostics", true) or _setting_bool("lsp_lightbulb", true)
	set_gutter_width(_lsp_gutter, GUTTER_WIDTH if show else 0)
	# Toggling diagnostics keeps the shared gutter at 14 px when the lightbulb
	# is still on, so repaint instead of relying on the width to hide marks.
	if !_last_diagnostics.is_empty():
		_repaint_diagnostics()


## Paints the worst diagnostic per line into the LSP gutter and tints the
## line. A diagnostic wins over the lightbulb on the same line; the lightbulb
## returns as soon as the diagnostic is gone.
func set_diagnostics(diagnostics: Array) -> void:
	if large_file:
		return
	var previous_lines := _worst_diagnostics.keys()
	_last_diagnostics = diagnostics.duplicate(true)
	clear_diagnostic_marks(false)
	if _lsp_gutter < 0 or _lsp_gutter >= get_gutter_count():
		return

	var worst: Dictionary = {}
	for diagnostic in diagnostics:
		if !(diagnostic is Dictionary):
			continue
		var data: Dictionary = diagnostic
		var line := LspText.diagnostic_line(data)
		if line < 0 or line >= get_line_count():
			continue
		var previous: Variant = worst.get(line)
		if previous == null or LspText.severity_rank(int(data.get("severity", 3))) < LspText.severity_rank(int(previous.severity)):
			worst[line] = data

	_worst_diagnostics = worst
	var lines: Array = worst.keys()
	lines.sort()
	for line in lines:
		_refresh_lsp_gutter_line(int(line))
		if !previous_lines.has(line):
			_pulse_gutter_line(int(line), _severity_color(int(worst[line].get("severity", 3))))
	if _action_line >= 0:
		_refresh_lsp_gutter_line(_action_line)


func pulse_diagnostic(line: int) -> void:
	if _worst_diagnostics.has(line):
		_pulse_gutter_line(line, _severity_color(int(_worst_diagnostics[line].get("severity", 3))))


func _pulse_gutter_line(line: int, color: Color) -> void:
	if line < 0 or line >= get_line_count() or !UI_MOTION.feedback_allowed():
		return
	var tint := color
	tint.a = 0.22
	_diagnostic_pulse_lines[line] = true
	set_line_background_color(line, tint)
	get_tree().create_timer(UI_MOTION.feedback_duration(0.24)).timeout.connect(func() -> void:
		_diagnostic_pulse_lines.erase(line)
		if is_instance_valid(self) and _worst_diagnostics.has(line):
			var base := _severity_color(int(_worst_diagnostics[line].get("severity", 3)))
			base.a = 0.10
			set_line_background_color(line, base)
		elif is_instance_valid(self):
			set_line_background_color(line, Color(0, 0, 0, 0))
	)


## Clears every mark this view painted. `hide_action` is false while a fresh
## diagnostic set is replacing the old one, so the caret lightbulb survives.
func clear_diagnostic_marks(hide_action: bool = true) -> void:
	if _lsp_gutter >= 0 and _lsp_gutter < get_gutter_count():
		for line in _painted_lsp_lines:
			if line >= 0 and line < get_line_count():
				set_line_gutter_text(line, _lsp_gutter, "")
				set_line_background_color(line, Color(0, 0, 0, 0))
	_painted_lsp_lines.clear()
	_worst_diagnostics.clear()
	if hide_action:
		_action_line = -1


func _refresh_lsp_gutter_line(line: int) -> void:
	if _lsp_gutter < 0 or _lsp_gutter >= get_gutter_count():
		return
	if line < 0 or line >= get_line_count():
		return

	var has_diagnostic := _setting_bool("lsp_diagnostics", true) and _worst_diagnostics.has(line)
	var has_action := line == _action_line and _setting_bool("lsp_lightbulb", true)
	if !has_diagnostic and !has_action:
		set_line_gutter_text(line, _lsp_gutter, "")
		set_line_background_color(line, Color(0, 0, 0, 0))
		_painted_lsp_lines.erase(line)
		return

	if !_painted_lsp_lines.has(line):
		_painted_lsp_lines.append(line)

	if has_diagnostic:
		var diagnostic: Dictionary = _worst_diagnostics[line]
		var severity := int(diagnostic.get("severity", 3))
		var color := _severity_color(severity)
		set_line_gutter_text(line, _lsp_gutter, LspText.severity_symbol(severity))
		set_line_gutter_item_color(line, _lsp_gutter, color)
		var tint := color
		tint.a = 0.10
		set_line_background_color(line, tint)
		return

	set_line_background_color(line, Color(0, 0, 0, 0))
	set_line_gutter_text(line, _lsp_gutter, "✦")
	set_line_gutter_item_color(line, _lsp_gutter, _severity_color(3))


## Shows or hides the lightbulb for the active caret line.
func set_action_available(available: bool, line: int = -1) -> void:
	var previous := _action_line
	_action_line = -1
	if previous >= 0:
		_refresh_lsp_gutter_line(previous)
	if !available or line < 0 or !_setting_bool("lsp_lightbulb", true):
		return
	if line >= get_line_count():
		return
	_action_line = line
	_refresh_lsp_gutter_line(line)


func _repaint_diagnostics() -> void:
	if _last_diagnostics.is_empty():
		return
	set_diagnostics(_last_diagnostics.duplicate(true))


func _severity_color(severity: int) -> Color:
	var key := LspText.severity_color_key(severity)
	var value: Variant = LuaSingleton.keywords.get(key)
	if value is Color:
		return value
	if key == "error":
		return Color("#e06c75")
	if key == "comments":
		return Color("#7f8c98")
	return Color("#e5c07b")


func _setting_bool(setting_name: String, fallback: bool) -> bool:
	var found = LuaSingleton.get_setting(setting_name)
	if found == null or found.size() < 2 or found[1] == -1:
		return fallback
	return bool(found[0].get("value", fallback))


func _on_symbol_hovered(symbol: String, line: int, column: int) -> void:
	if symbol.strip_edges().is_empty():
		return
	# The LSP manager and the offline glossary both decide for themselves
	# whether hover is enabled; filtering here would also silence the glossary
	# when the language-server tooltip is turned off.
	hover_requested.emit(self, line, column)


func _on_symbol_lookup(_symbol: String, _line: int, _column: int) -> void:
	definition_requested.emit(self)


func _on_symbol_validate(symbol: String) -> void:
	set_symbol_lookup_word_as_valid(!symbol.strip_edges().is_empty())


func _on_caret_changed() -> void:
	caret_moved.emit(self, get_caret_line(), get_caret_column())


func _on_gutter_clicked(line: int, gutter: int) -> void:
	if gutter == _debug_gutter:
		debug_gutter_clicked.emit(self, line)
		return
	if gutter == _git_gutter:
		if _git_marks.has(line):
			git_gutter_clicked.emit(self, line)
		return
	if gutter != _lsp_gutter:
		return
	if _worst_diagnostics.has(line):
		problem_gutter_clicked.emit(self, line)
	elif line == _action_line:
		action_gutter_clicked.emit(self, line)
