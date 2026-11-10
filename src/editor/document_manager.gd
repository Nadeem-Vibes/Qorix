class_name DocumentManager
extends Node

## Owns the list of open documents and the document <-> EditorView mapping.
## FileManager is the coordinator around it (dialogs, warnings, persistence).

signal documents_changed
signal active_document_changed(document)
signal document_dirty_changed(document)

const DOCUMENT = preload("res://src/editor/document.gd")
const Paths = preload("res://src/base/path_utils.gd")

var editor = null
var host = null

var documents: Array = []
var active_index: int = -1

var _untitled_counter: int = 0
var _next_document_id: int = 0


func _ready() -> void:
	if host != null:
		host.view_content_changed.connect(_on_view_content_changed)


func count() -> int:
	return documents.size()


func at(index: int):
	if index < 0 or index >= documents.size():
		return null
	return documents[index]


func active_document():
	return at(active_index)


func active_view():
	var doc = active_document()
	return doc.view if doc != null else null


func index_of(document) -> int:
	return documents.find(document)


## Monotonic ids: closing a tab never lets a stale handle address a new one.
func find_by_id(id: int) -> Variant:
	for document in documents:
		if int(document.id) == int(id):
			return document
	return null


func find_by_path(path: String):
	if path.is_empty():
		return null

	for document in documents:
		if Paths.same_file(str(document.path), path):
			return document
	return null


func open_document(path: String, content: String):
	_next_document_id += 1
	var document = DOCUMENT.new()
	document.id = _next_document_id
	document.path = path
	document.display_name = path.get_file()
	document.untitled = false
	document.modified = false
	document.disk_mtime = editor._mtime(path) if editor != null else 0
	document.set_pending_text(content)

	_append_document(document)
	return document


func new_untitled(content: String = "", title: String = ""):
	if title.is_empty():
		_untitled_counter += 1
		title = "Untitled %d" % _untitled_counter

	_next_document_id += 1
	var document = DOCUMENT.new()
	document.id = _next_document_id
	document.path = ""
	document.display_name = title
	document.untitled = true
	document.modified = !content.is_empty()
	document.disk_mtime = 0
	document.set_pending_text(content)

	_append_document(document)
	return document


func _append_document(document) -> void:
	capture_active_state()

	documents.append(document)
	var view = host.create_view(document)

	active_index = documents.size() - 1
	host.activate(view)
	document.restore_state()

	documents_changed.emit()
	active_document_changed.emit(document)


func activate_index(index: int) -> void:
	if index < 0 or index >= documents.size():
		return
	if index == active_index:
		return

	capture_active_state()

	active_index = index
	var document = documents[index]
	host.activate(document.view)
	document.restore_state()

	active_document_changed.emit(document)


func activate_document(document) -> void:
	var index := index_of(document)
	if index != -1:
		activate_index(index)


func remove_document(index: int) -> void:
	var document = at(index)
	if document == null:
		return

	var was_active := index == active_index
	if was_active:
		capture_active_state()

	host.destroy_view(document.view)
	documents.remove_at(index)

	if documents.is_empty():
		active_index = -1
		active_document_changed.emit(null)
	elif was_active:
		active_index = mini(index, documents.size() - 1)
		var next_document = documents[active_index]
		host.activate(next_document.view)
		next_document.restore_state()
		active_document_changed.emit(next_document)
	elif index < active_index:
		active_index -= 1

	documents_changed.emit()


func capture_active_state() -> void:
	var document = active_document()
	if document != null:
		document.capture_state()


## Marks a document dirty after a host application of text (mod edits, restores).
## Emitting here keeps tabs, session snapshots and listeners in one path.
func mark_dirty(document) -> void:
	if document == null or bool(document.modified):
		return
	document.mark_dirty()
	document_dirty_changed.emit(document)


func _on_view_content_changed(view) -> void:
	var document = view.document
	if document == null:
		return

	if document.modified:
		return

	document.mark_dirty()
	document_dirty_changed.emit(document)
