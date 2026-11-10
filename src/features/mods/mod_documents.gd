extends RefCounted

## Document API bridge (Phase 2).
##
## The editor's Document objects are host state; mods only see monotonic integer
## ids. Columns are codepoint columns and every edit rejects a column that falls
## inside a grapheme cluster. Text is UTF-8 at the Lua boundary.
##
## The service is deliberately duck-typed against FileManager so the headless
## suites can drive it with a small host stub.

const Result = preload("res://src/features/mods/mod_result.gd")
const Columns = preload("res://src/features/mods/mod_text_columns.gd")
const Paths = preload("res://src/base/path_utils.gd")

const MAX_TEXT_BYTES := 8 * 1024 * 1024

var editor = null


func _init(editor_ref = null) -> void:
	editor = editor_ref


# ── QUERIES ─────────────────────────────────────────────────────────────────

func active() -> Dictionary:
	var document = _active_document()
	return Result.ok(int(document.id) if document != null else 0)


func list() -> Dictionary:
	var documents = _documents()
	if documents == null:
		return Result.ok([])

	var out: Array = []
	for document in documents.documents:
		out.append(int(document.id))
	return Result.ok(out)


func text(payload: Dictionary) -> Dictionary:
	var found := _document(payload)
	if !found.get("ok", false):
		return found
	var document = found["value"]
	return Result.ok(str(document.text()))


func cursor(payload: Dictionary) -> Dictionary:
	var found := _document(payload)
	if !found.get("ok", false):
		return found
	var document = found["value"]
	var view = document.view
	if view == null or !is_instance_valid(view):
		return Result.ok({"line": int(document.caret_line), "col": int(document.caret_column)})
	return Result.ok({
		"line": int(view.get_caret_line()),
		"col": int(view.get_caret_column()),
	})


func selection(payload: Dictionary) -> Dictionary:
	var found := _document(payload)
	if !found.get("ok", false):
		return found
	var document = found["value"]
	var view = document.view
	if view == null or !is_instance_valid(view) or !view.has_selection():
		return Result.ok({"has": false, "from": {}, "to": {}, "text": ""})

	var from := {"line": int(view.get_selection_from_line()), "col": int(view.get_selection_from_column())}
	var to := {"line": int(view.get_selection_to_line()), "col": int(view.get_selection_to_column())}
	var content := str(document.text())
	var start := Columns.offset_of(content, int(from["line"]), int(from["col"]))
	var finish := Columns.offset_of(content, int(to["line"]), int(to["col"]))
	if start < 0 or finish < start:
		return Result.ok({"has": false, "from": from, "to": to, "text": ""})

	return Result.ok({
		"has": true,
		"from": from,
		"to": to,
		"text": content.substr(start, finish - start),
	})


func is_dirty(payload: Dictionary) -> Dictionary:
	var found := _document(payload)
	if !found.get("ok", false):
		return found
	return Result.ok(bool((found["value"] as Variant).modified))


func path(payload: Dictionary) -> Dictionary:
	var found := _document(payload)
	if !found.get("ok", false):
		return found
	return Result.ok(str((found["value"] as Variant).path))


func language(payload: Dictionary) -> Dictionary:
	var found := _document(payload)
	if !found.get("ok", false):
		return found
	var document = found["value"]
	return Result.ok(str(document.language_extension()))


# ── ACTIONS ─────────────────────────────────────────────────────────────────

func open(payload: Dictionary) -> Dictionary:
	var raw := str(payload.get("path", ""))
	if raw.strip_edges().is_empty():
		return Result.error("path.invalid", "The document path is empty.")

	var resolved := _resolve(raw, false)
	if !resolved.get("ok", false):
		return resolved
	var full: String = resolved["value"]

	if !FileAccess.file_exists(full):
		return Result.error("doc.not_found", "The file '%s' does not exist." % raw)

	var documents = _documents()
	if documents == null:
		return Result.error("state.invalid", "No document manager is available.")

	var existing = documents.find_by_path(full)
	if existing != null:
		documents.activate_document(existing)
		return Result.ok(int(existing.id))

	if editor == null or !editor.has_method("open_file"):
		return Result.error("state.invalid", "The editor cannot open documents in this context.")
	editor.open_file(full)

	var document = _documents().find_by_path(full)
	if document == null:
		return Result.error("doc.open_failed", "The editor did not open '%s'." % raw)
	return Result.ok(int(document.id))


func create(payload: Dictionary) -> Dictionary:
	var documents = _documents()
	if documents == null:
		return Result.error("state.invalid", "No document manager is available.")

	var content := str(payload.get("text", ""))
	if content.to_utf8_buffer().size() > MAX_TEXT_BYTES:
		return Result.error("doc.too_large", "The document text is larger than %d bytes." % MAX_TEXT_BYTES)

	var raw := str(payload.get("path", "")).strip_edges()
	var document = null

	if !raw.is_empty():
		var resolved := _resolve(raw, false)
		if !resolved.get("ok", false):
			return resolved
		var full: String = resolved["value"]

		if FileAccess.file_exists(full):
			return Result.error(
				"doc.exists",
				"The document '%s' already exists; open it with docs.open." % raw,
			)

		document = documents.open_document(full, content)
	else:
		document = documents.new_untitled(content)

	if document == null:
		return Result.error("doc.open_failed", "The editor did not create the document.")

	var language := str(payload.get("language", "")).strip_edges()
	if !language.is_empty():
		document.set_language_override(language, language, "manual")
		if document.view != null and is_instance_valid(document.view):
			document.view.set_language_extension(language)

	if !content.is_empty():
		documents.mark_dirty(document)
	documents.activate_document(document)
	return Result.ok(int(document.id))


func set_text(payload: Dictionary) -> Dictionary:
	var found := _document(payload)
	if !found.get("ok", false):
		return found
	var document = found["value"]
	var content := str(payload.get("text", ""))
	return _write_text(document, content, 0)


func insert(payload: Dictionary) -> Dictionary:
	var found := _document(payload)
	if !found.get("ok", false):
		return found
	var document = found["value"]

	var content := str(document.text())
	var line := int(payload.get("line", 0))
	var column := int(payload.get("col", 0))
	var addition := str(payload.get("text", ""))
	if addition.is_empty():
		return Result.ok(false)

	var line_text := Columns.line_at(content, line)
	if line < 0 or line >= Columns.line_count(content) or column < 0 or column > line_text.length():
		return Result.error("doc.invalid_position", "The insertion position is outside the document.")
	if !Columns.is_boundary(line_text, column):
		var split := Columns.split_columns(line_text, column)
		return Result.error(
			"doc.column_splits_grapheme",
			"Column %d splits a grapheme cluster; use %s." % [column, str(split)],
			{"columns": split},
		)

	var offset := Columns.offset_of(content, line, column)
	if offset < 0:
		return Result.error("doc.invalid_position", "The insertion position is outside the document.")

	var merged := content.substr(0, offset) + addition + content.substr(offset)
	return _write_text(document, merged, offset + addition.length())


func replace(payload: Dictionary) -> Dictionary:
	var found := _document(payload)
	if !found.get("ok", false):
		return found
	var document = found["value"]

	var content := str(document.text())
	var from: Variant = payload.get("from")
	var to: Variant = payload.get("to")
	if !(from is Dictionary) or !(to is Dictionary):
		return Result.error("api.bad_args", "replace needs {from={line,col}, to={line,col}}.")

	var from_line := int((from as Dictionary).get("line", 0))
	var from_col := int((from as Dictionary).get("col", 0))
	var to_line := int((to as Dictionary).get("line", 0))
	var to_col := int((to as Dictionary).get("col", 0))

	if from_line < 0 or from_line >= Columns.line_count(content) or to_line < 0 or to_line >= Columns.line_count(content):
		return Result.error("doc.invalid_position", "The replacement range is outside the document.")

	var from_text := Columns.line_at(content, from_line)
	var to_text := Columns.line_at(content, to_line)
	if from_col < 0 or from_col > from_text.length() or to_col < 0 or to_col > to_text.length():
		return Result.error("doc.invalid_position", "The replacement columns are outside their lines.")

	for check in [[from_text, from_col], [to_text, to_col]]:
		var line_text := str(check[0])
		var column := int(check[1])
		if !Columns.is_boundary(line_text, column):
			var split := Columns.split_columns(line_text, column)
			return Result.error(
				"doc.column_splits_grapheme",
				"Column %d splits a grapheme cluster; use %s." % [column, str(split)],
				{"columns": split},
			)

	var start := Columns.offset_of(content, from_line, from_col)
	var finish := Columns.offset_of(content, to_line, to_col)
	if start < 0 or finish < 0 or finish < start:
		return Result.error("doc.invalid_position", "The replacement end is before its start.")

	var addition := str(payload.get("text", ""))
	var merged := content.substr(0, start) + addition + content.substr(finish)
	return _write_text(document, merged, start + addition.length())


func set_cursor(payload: Dictionary) -> Dictionary:
	var found := _document(payload)
	if !found.get("ok", false):
		return found
	var document = found["value"]
	var view = document.view
	if view == null or !is_instance_valid(view):
		return Result.error("state.invalid", "The document has no editor view.")

	var content := str(document.text())
	var line := clampi(int(payload.get("line", 0)), 0, Columns.line_count(content) - 1)
	var limit := Columns.line_at(content, line).length()
	var column := clampi(int(payload.get("col", 0)), 0, limit)

	view.set_caret_line(line)
	view.set_caret_column(column)
	document.caret_line = line
	document.caret_column = column
	return Result.ok({"line": line, "col": column})


func set_selection(payload: Dictionary) -> Dictionary:
	var found := _document(payload)
	if !found.get("ok", false):
		return found
	var document = found["value"]
	var view = document.view
	if view == null or !is_instance_valid(view):
		return Result.error("state.invalid", "The document has no editor view.")

	var from: Variant = payload.get("from")
	var to: Variant = payload.get("to")
	if !(from is Dictionary) or !(to is Dictionary):
		return Result.error("api.bad_args", "set_selection needs {from={line,col}, to={line,col}}.")

	var content := str(document.text())
	var from_line := clampi(int((from as Dictionary).get("line", 0)), 0, Columns.line_count(content) - 1)
	var to_line := clampi(int((to as Dictionary).get("line", 0)), 0, Columns.line_count(content) - 1)
	var from_col := clampi(int((from as Dictionary).get("col", 0)), 0, Columns.line_at(content, from_line).length())
	var to_col := clampi(int((to as Dictionary).get("col", 0)), 0, Columns.line_at(content, to_line).length())

	_documents().capture_active_state()
	if document != _active_document():
		_documents().activate_document(document)

	view.select(from_line, from_col, to_line, to_col)
	document.has_selection_state = true
	document.selection_from_line = from_line
	document.selection_from_column = from_col
	document.selection_to_line = to_line
	document.selection_to_column = to_col
	return Result.ok(true)


func save(payload: Dictionary) -> Dictionary:
	var found := _document(payload)
	if !found.get("ok", false):
		return found
	var document = found["value"]
	if str(document.path).is_empty():
		return Result.error("doc.unsaved", "Untitled documents need Save As before a mod can save them.")
	if editor == null or !editor.has_method("_save_document"):
		return Result.error("state.invalid", "The editor cannot save documents in this context.")

	var saved: bool = bool(editor._save_document(document))
	if !saved:
		return Result.error("doc.save_failed", "The document could not be written.")
	return Result.ok(true)


func close(payload: Dictionary) -> Dictionary:
	var found := _document(payload)
	if !found.get("ok", false):
		return found
	var document = found["value"]
	var documents = _documents()
	var force := bool(payload.get("force", false))

	if bool(document.modified) and !force:
		return Result.error("doc.dirty", "The document has unsaved changes; save it or pass force=true.")

	if force:
		document.mark_clean()

	var index: int = int(documents.index_of(document))
	if index < 0:
		return Result.ok(false)

	if editor != null and editor.has_method("_remove_document"):
		editor._remove_document(index)
	else:
		documents.remove_document(index)
	return Result.ok(true)


func reveal(payload: Dictionary) -> Dictionary:
	var found := _document(payload)
	if !found.get("ok", false):
		return found
	var document = found["value"]
	var documents = _documents()
	documents.activate_document(document)
	return Result.ok(true)


# ── INTERNALS ───────────────────────────────────────────────────────────────

func _document(payload: Dictionary) -> Dictionary:
	var documents = _documents()
	if documents == null:
		return Result.error("state.invalid", "No document manager is available.")
	var id := int(payload.get("doc", payload.get("id", 0)))
	var document = documents.find_by_id(id)
	if document == null:
		return Result.error("doc.stale_handle", "Document %d is not open." % id)
	return Result.ok(document)


func _documents():
	if editor == null:
		return null
	return editor.get("documents")


func _active_document():
	var documents = _documents()
	return documents.active_document() if documents != null else null


func _write_text(document, content: String, caret_offset: int) -> Dictionary:
	if content.to_utf8_buffer().size() > MAX_TEXT_BYTES:
		return Result.error("doc.too_large", "The document text is larger than %d bytes." % MAX_TEXT_BYTES)

	document.set_text(content, false)
	var documents = _documents()
	if documents != null:
		documents.mark_dirty(document)

	if caret_offset >= 0:
		var position: Dictionary = Columns.position_of(content, caret_offset)
		var view = document.view
		if view != null and is_instance_valid(view):
			view.set_caret_line(int(position["line"]))
			view.set_caret_column(int(position["col"]))
		document.caret_line = int(position["line"])
		document.caret_column = int(position["col"])

	if editor != null:
		var lsp = editor.get("lsp_manager")
		if lsp != null and lsp.has_method("sync_open_documents"):
			lsp.sync_open_documents()
	return Result.ok(true)


func _resolve(relative: String, allow_root: bool) -> Dictionary:
	var root := _workspace_root()
	if root.is_empty():
		return Result.error("workspace.required", "Open a folder before using document paths.")

	var raw := str(relative).strip_edges().replace("\\", "/")
	if raw.is_empty():
		if allow_root:
			return Result.ok(root)
		return Result.error("path.invalid", "The path is empty.")
	if raw.begins_with("/") or (raw.length() >= 2 and raw[1] == ":"):
		return Result.error("path.invalid", "Absolute paths are not allowed; use a workspace-relative path.")
	if raw.contains("..") or raw.contains(":"):
		return Result.error("path.invalid", "'%s' is not a safe workspace path." % relative)

	var full := Paths.normalize(root.path_join(raw))
	if full == Paths.normalize(root):
		if allow_root:
			return Result.ok(full)
		return Result.error("path.invalid", "The workspace root is not a document.")
	if !Paths.is_subpath(root, full):
		return Result.error("path.outside_workspace", "'%s' resolves outside the workspace." % relative)
	return Result.ok(full)


func _workspace_root() -> String:
	if editor == null:
		return ""
	# See mod_files.gd: the cwd fallback is for the host's save/run dialogs, not
	# for a mod. Without a real workspace, document paths fail with
	# workspace.required instead of resolving against the process directory.
	var workspace = editor.get("workspace")
	if workspace != null:
		if workspace.has_method("has_workspace") and workspace.has_workspace():
			return str(workspace.root)
		return ""
	if editor.has_method("workspace_root_for_tools"):
		return str(editor.workspace_root_for_tools())
	return ""
