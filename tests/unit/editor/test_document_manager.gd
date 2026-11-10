extends "res://tests/support/test_case.gd"

## DocumentManager is the index/lifecycle brain behind tabs. EditorHost and
## EditorView normally provide the nodes, but they need the full scene and its
## autoloads; these stubs isolate the bookkeeping this suite is about.

const Documents = preload("res://src/editor/document_manager.gd")


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

	func get_caret_line() -> int:
		return caret_line

	func set_caret_line(value: int) -> void:
		caret_line = value

	func get_caret_column() -> int:
		return caret_column

	func set_caret_column(value: int) -> void:
		caret_column = value

	func get_line_count() -> int:
		return text.split("\n").size()

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


var host: HostStub
var documents: Node


func before_each() -> void:
	host = HostStub.new()
	documents = Documents.new()
	documents.host = host
	documents.editor = null
	documents._ready()


func after_each() -> void:
	documents.free()
	host.free()


func test_open_document_creates_a_view_and_activates_it() -> void:
	var document = documents.open_document("C:/proj/a.txt", "hello\nworld")

	assert_eq(documents.count(), 1)
	assert_eq(documents.active_index, 0)
	assert_eq(documents.active_document(), document)
	assert_eq(document.text(), "hello\nworld")
	assert_eq(host.views.size(), 1)
	assert_eq(host.active_view, document.view)


func test_new_untitled_titles_are_numbered_and_flagged() -> void:
	var first = documents.new_untitled()
	var second = documents.new_untitled()

	assert_eq(first.title(), "Untitled 1")
	assert_eq(second.title(), "Untitled 2")
	assert_true(first.untitled)
	assert_true(second.untitled)
	assert_false(first.modified)


func test_new_untitled_with_content_starts_dirty() -> void:
	var document = documents.new_untitled("scratch", "Recovered")

	assert_eq(document.title(), "Recovered")
	assert_true(document.modified)
	assert_eq(document.text(), "scratch")


func test_switching_tabs_captures_and_restores_caret_scroll_and_selection() -> void:
	var first = documents.open_document("C:/proj/a.txt", "one\ntwo\nthree")
	first.view.caret_line = 2
	first.view.caret_column = 3
	first.view.scroll_vertical = 9
	first.view.scroll_horizontal = 4
	first.view.selection_active = true
	first.view.selection_from = Vector2i(1, 0)
	first.view.selection_to = Vector2i(1, 3)

	# Opening the second document stashes the first one's live state.
	var second = documents.open_document("C:/proj/b.txt", "beta")
	assert_eq(documents.active_index, 1)
	assert_eq(first.caret_line, 2)
	assert_eq(first.caret_column, 3)
	assert_eq(first.scroll_vertical, 9)
	assert_true(first.has_selection_state)

	second.view.caret_line = 0
	second.view.caret_column = 2

	documents.activate_index(0)
	assert_eq(host.active_view, first.view)
	assert_eq(first.view.caret_line, 2)
	assert_eq(first.view.caret_column, 3)
	assert_eq(first.view.scroll_vertical, 9)
	assert_eq(first.view.scroll_horizontal, 4)
	assert_true(first.view.selection_active)
	assert_eq(first.view.selection_from, Vector2i(1, 0))
	assert_eq(first.view.selection_to, Vector2i(1, 3))

	documents.activate_index(1)
	assert_eq(host.active_view, second.view)
	assert_eq(second.view.caret_line, 0)
	assert_eq(second.view.caret_column, 2)


func test_removing_the_active_middle_tab_selects_the_next_one() -> void:
	var first = documents.open_document("C:/proj/a.txt", "a")
	var second = documents.open_document("C:/proj/b.txt", "b")
	var third = documents.open_document("C:/proj/c.txt", "c")

	documents.activate_index(1)
	documents.remove_document(1)

	assert_eq(documents.count(), 2)
	assert_eq(documents.active_index, 1)
	assert_eq(documents.active_document(), third)
	assert_eq(host.active_view, third.view)
	assert_eq(documents.at(0), first)
	assert_eq(host.views.size(), 2)


func test_removing_a_tab_before_the_active_one_keeps_the_same_document() -> void:
	var first = documents.open_document("C:/proj/a.txt", "a")
	var second = documents.open_document("C:/proj/b.txt", "b")
	var third = documents.open_document("C:/proj/c.txt", "c")

	documents.activate_index(1)
	documents.remove_document(0)

	assert_eq(documents.count(), 2)
	assert_eq(documents.active_index, 0)
	assert_eq(documents.active_document(), second)
	assert_eq(host.active_view, second.view)
	assert_ne(documents.active_document(), first)
	assert_ne(documents.active_document(), third)


func test_removing_the_last_tab_clears_the_active_document() -> void:
	documents.open_document("C:/proj/a.txt", "a")

	documents.remove_document(0)

	assert_eq(documents.count(), 0)
	assert_eq(documents.active_index, -1)
	assert_eq(documents.active_document(), null)
	assert_eq(host.active_view, null)
	assert_eq(host.views.size(), 0)


func test_duplicate_dirty_notifications_only_fire_when_the_flag_changes() -> void:
	var document = documents.open_document("C:/proj/a.txt", "a")
	var dirty_events: Array = []
	documents.document_dirty_changed.connect(func(changed): dirty_events.append(changed))

	host.view_content_changed.emit(document.view)
	assert_true(document.modified)
	assert_eq(dirty_events.size(), 1)

	host.view_content_changed.emit(document.view)
	assert_eq(dirty_events.size(), 1)

	document.mark_clean()
	host.view_content_changed.emit(document.view)
	assert_eq(dirty_events.size(), 2)
	assert_eq(dirty_events[1], document)


func test_find_by_path_ignores_separator_spelling() -> void:
	var document = documents.open_document("C:/Proj/File.txt", "x")

	assert_eq(documents.find_by_path("C:\\Proj\\File.txt"), document)
	assert_eq(documents.find_by_path("C:/Proj/Other.txt"), null)
	assert_eq(documents.find_by_path(""), null)
