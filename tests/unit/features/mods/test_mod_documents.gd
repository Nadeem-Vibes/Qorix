extends "res://tests/support/test_case.gd"

## Phase 2 documents API. A real DocumentManager drives the bookkeeping; the
## view/host are small stubs so this stays headless, exactly like the existing
## DocumentManager suite.

const Documents = preload("res://src/features/mods/mod_documents.gd")
const DocumentManager = preload("res://src/editor/document_manager.gd")
const Columns = preload("res://src/features/mods/mod_text_columns.gd")
const Result = preload("res://src/features/mods/mod_result.gd")
const Store = preload("res://src/base/file_store.gd")

const ROOT := "user://griddy_phase2/documents"


class ViewStub:
	extends Node

	var document = null
	var text: String = ""
	var file_modified: bool = false
	var caret_line: int = 0
	var caret_column: int = 0
	var scroll_vertical: int = 0
	var scroll_horizontal: int = 0
	var selection_active: bool = false
	var selection_from := Vector2i.ZERO
	var selection_to := Vector2i.ZERO

	func set_document_text(content: String, mark_clean: bool = true) -> void:
		text = content
		if mark_clean:
			file_modified = false

	func get_caret_line() -> int:
		return caret_line

	func set_caret_line(value: int) -> void:
		caret_line = value

	func get_caret_column() -> int:
		return caret_column

	func set_caret_column(value: int) -> void:
		caret_column = value

	func get_line_count() -> int:
		return maxi(1, text.split("\n").size())

	func get_line(index: int) -> String:
		var lines := text.split("\n")
		if index < 0 or index >= lines.size():
			return ""
		return lines[index]

	func has_selection() -> bool:
		return selection_active

	func get_selection_from_line() -> int:
		return selection_from.x

	func get_selection_from_column() -> int:
		return selection_from.y

	func get_selection_to_line() -> int:
		return selection_to.x

	func get_selection_to_column() -> int:
		return selection_to.y

	func select(from_line: int, from_column: int, to_line: int, to_column: int) -> void:
		selection_from = Vector2i(from_line, from_column)
		selection_to = Vector2i(to_line, to_column)
		selection_active = true


class HostStub:
	extends Node

	signal view_content_changed(view)

	var views: Array = []
	var active_view = null

	func create_view(document):
		var view := ViewStub.new()
		view.document = document
		view.text = document.pending_text()
		document.view = view
		document.clear_pending_text()
		views.append(view)
		add_child(view)
		return view

	func activate(view) -> void:
		active_view = view

	func destroy_view(view) -> void:
		views.erase(view)
		if active_view == view:
			active_view = null
		if is_instance_valid(view):
			view.free()


class WorkspaceStub:
	var root: String

	func has_workspace() -> bool:
		return !root.is_empty()

	func workspace_name() -> String:
		return root.get_file()


class EditorStub:
	extends Node

	var documents = null
	var workspace = null
	var lsp_manager = null

	func workspace_root_for_tools() -> String:
		return workspace.root if workspace != null and workspace.has_workspace() else ""

	func open_file(path: String) -> void:
		documents.open_document(path, FileAccess.get_file_as_string(path))

	func _remove_document(index: int) -> void:
		documents.remove_document(index)

	func _save_document(document) -> bool:
		var result: Dictionary = Store.save(str(document.path), str(document.text()))
		if !result.get("ok", false):
			return false
		document.mark_clean()
		return true


var host: HostStub
var documents: Node
var editor: EditorStub
var docs


func before_each() -> void:
	_clean(ROOT)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ROOT))
	_write(ROOT.path_join("notes.txt"), "alpha\nbeta")

	host = HostStub.new()
	documents = DocumentManager.new()
	documents.host = host
	documents.editor = null
	documents._ready()

	editor = EditorStub.new()
	editor.documents = documents
	editor.workspace = WorkspaceStub.new()
	editor.workspace.root = ROOT
	docs = Documents.new(editor)


func after_each() -> void:
	docs = null
	editor.free()
	documents.free()
	host.free()
	_clean(ROOT)


func test_grapheme_boundaries_and_offsets() -> void:
	var combined := "e\u0301x"
	assert_true(Columns.is_boundary(combined, 0), "start is a boundary")
	assert_true(Columns.is_boundary(combined, 2), "after combining mark is a boundary")
	assert_false(Columns.is_boundary(combined, 1), "inside a cluster is not")
	assert_eq(Columns.split_columns(combined, 1), [0, 2], "split reports neighbours")

	assert_eq(Columns.line_count("a\nb\n"), 3, "trailing newline keeps an empty line")
	assert_eq(Columns.offset_of("a\nbc", 1, 1), 3, "offset crosses lines")
	assert_eq(Columns.position_of("a\nbc", 3), {"line": 1, "col": 1}, "position is the inverse")
	assert_eq(Columns.position_of("a\nbc", 2), {"line": 1, "col": 0}, "offset after a newline maps to the next line")


func test_open_create_and_list_documents() -> void:
	var opened: Dictionary = docs.open({"path": "notes.txt"})
	check(opened.get("ok", false), "open succeeds")
	var doc_id := int(opened.get("value", 0))
	check(doc_id > 0, "stable id returned")
	assert_eq(documents.count(), 1)
	assert_eq(int(docs.active().get("value", 0)), doc_id)
	assert_eq(str(docs.text({"doc": doc_id}).get("value", "")), "alpha\nbeta")
	assert_eq(docs.list().get("value", []), [doc_id])

	var created: Dictionary = docs.create({"text": "scratch"})
	check(created.get("ok", false), "create succeeds")
	var scratch_id := int(created.get("value", 0))
	assert_true(bool(docs.is_dirty({"doc": scratch_id}).get("value", false)), "content starts dirty")
	assert_eq(documents.count(), 2)
	assert_eq(docs.list().get("value", []), [doc_id, scratch_id])


func test_missing_and_escaping_paths_fail() -> void:
	assert_eq(Result.code_of(docs.open({"path": "missing.txt"})), "doc.not_found")
	assert_eq(Result.code_of(docs.open({"path": "../outside.txt"})), "path.invalid")
	assert_eq(Result.code_of(docs.text({"doc": 99999})), "doc.stale_handle")


func test_create_never_reopens_an_existing_path() -> void:
	# Opening an existing file is a read-side decision. create() must not become
	# a way for a write-only mod to claim the user's current tab.
	var opened: Dictionary = docs.open({"path": "notes.txt"})
	var original_id := int(opened.get("value", 0))
	var created: Dictionary = docs.create({"path": "notes.txt", "text": "replaced"})
	assert_eq(Result.code_of(created), "doc.exists")
	assert_eq(documents.count(), 1, "no second document was created")
	assert_eq(int(docs.active().get("value", 0)), original_id, "the original tab keeps focus")
	assert_eq(str(docs.text({"doc": original_id}).get("value", "")), "alpha\nbeta", "content is untouched")
	assert_true(Result.known("doc.exists"), "doc.exists is in the result catalogue")


func test_insert_replace_and_grapheme_rejection() -> void:
	var opened: Dictionary = docs.open({"path": "notes.txt"})
	var doc_id := int(opened.get("value", 0))

	var inserted: Dictionary = docs.insert({"doc": doc_id, "line": 0, "col": 5, "text": "!"})
	check(inserted.get("ok", false), "insert succeeds")
	assert_eq(str(docs.text({"doc": doc_id}).get("value", "")), "alpha!\nbeta")

	var replaced: Dictionary = docs.replace({
		"doc": doc_id,
		"from": {"line": 1, "col": 0},
		"to": {"line": 1, "col": 4},
		"text": "BETA",
	})
	check(replaced.get("ok", false), "replace succeeds")
	assert_eq(str(docs.text({"doc": doc_id}).get("value", "")), "alpha!\nBETA")

	var invalid: Dictionary = docs.insert({"doc": doc_id, "line": 9, "col": 0, "text": "x"})
	assert_eq(Result.code_of(invalid), "doc.invalid_position")

	docs.set_text({"doc": doc_id, "text": "e\u0301"})
	var split: Dictionary = docs.insert({"doc": doc_id, "line": 0, "col": 1, "text": "x"})
	assert_eq(Result.code_of(split), "doc.column_splits_grapheme")
	assert_eq(split.get("error", {}).get("details", {}).get("columns", []), [0, 2])


func test_cursor_selection_and_reveal() -> void:
	var opened: Dictionary = docs.open({"path": "notes.txt"})
	var doc_id := int(opened.get("value", 0))
	var document = documents.find_by_id(doc_id)

	docs.set_cursor({"doc": doc_id, "line": 1, "col": 2})
	assert_eq(docs.cursor({"doc": doc_id}).get("value", {}), {"line": 1, "col": 2})
	assert_eq(document.caret_line, 1)
	assert_eq(document.caret_column, 2)

	docs.set_selection({"doc": doc_id, "from": {"line": 0, "col": 1}, "to": {"line": 0, "col": 4}})
	var selection: Dictionary = docs.selection({"doc": doc_id}).get("value", {})
	assert_true(bool(selection.get("has", false)), "selection reported")
	assert_eq(str(selection.get("text", "")), "lph")
	assert_true(bool(docs.reveal({"doc": doc_id}).get("ok", false)), "reveal activates")


func test_save_and_close() -> void:
	var opened: Dictionary = docs.open({"path": "notes.txt"})
	var doc_id := int(opened.get("value", 0))
	docs.set_text({"doc": doc_id, "text": "saved"})
	assert_eq(Result.code_of(docs.save({"doc": doc_id})), "")
	assert_eq(FileAccess.get_file_as_string(ROOT.path_join("notes.txt")), "saved")
	assert_false(bool(docs.is_dirty({"doc": doc_id}).get("value", true)), "clean after save")

	docs.set_text({"doc": doc_id, "text": "dirty again"})
	var refused: Dictionary = docs.close({"doc": doc_id})
	assert_eq(Result.code_of(refused), "doc.dirty")
	assert_eq(documents.count(), 1, "refused close keeps the tab")

	var forced: Dictionary = docs.close({"doc": doc_id, "force": true})
	check(forced.get("ok", false), "force closes")
	assert_eq(documents.count(), 0)


func test_untitled_save_is_refused() -> void:
	var created: Dictionary = docs.create({"text": "scratch"})
	var doc_id := int(created.get("value", 0))
	var saved: Dictionary = docs.save({"doc": doc_id})
	assert_eq(Result.code_of(saved), "doc.unsaved")


func test_documents_require_a_real_workspace() -> void:
	editor.workspace.root = ""
	var opened: Dictionary = docs.open({"path": "notes.txt"})
	assert_eq(Result.code_of(opened), "workspace.required")


func _write(path: String, content: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(content)


func _clean(path: String) -> void:
	var db := DirAccess.open(ProjectSettings.globalize_path(path))
	if db == null:
		return
	for file_name in db.get_files():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path.path_join(str(file_name))))
	for directory_name in db.get_directories():
		_clean(path.path_join(str(directory_name)))
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path.path_join(str(directory_name))))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
