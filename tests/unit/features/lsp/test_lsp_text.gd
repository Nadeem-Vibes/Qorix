extends "res://tests/support/test_case.gd"

const LspText = preload("res://src/features/lsp/lsp_text.gd")


# ── URIs ────────────────────────────────────────────────────────────────────

func test_windows_path_round_trips_through_a_uri() -> void:
	var uri: String = LspText.path_to_uri("C:\\work\\my file.py")

	assert_eq(uri, "file:///C:/work/my%20file.py")
	assert_eq(LspText.uri_to_path(uri), "C:/work/my file.py")


func test_posix_path_round_trips_through_a_uri() -> void:
	var uri: String = LspText.path_to_uri("/home/user/project/a.py")

	assert_eq(uri, "file:///home/user/project/a.py")
	assert_eq(LspText.uri_to_path(uri), "/home/user/project/a.py")


func test_unicode_path_is_percent_encoded_as_utf8() -> void:
	var uri: String = LspText.path_to_uri("/home/é/文件.py")

	assert_true(uri.contains("%C3%A9"))
	assert_true(uri.contains("%E6%96%87%E4%BB%B6"))
	assert_eq(LspText.uri_to_path(uri), "/home/é/文件.py")


func test_unc_path_uses_the_authority_form() -> void:
	var uri: String = LspText.path_to_uri("\\\\server\\share\\a b.txt")

	assert_eq(uri, "file://server/share/a%20b.txt")
	assert_eq(LspText.uri_to_path(uri), "//server/share/a b.txt")


func test_uri_query_and_fragment_are_not_part_of_the_path() -> void:
	assert_eq(LspText.uri_to_path("file:///C:/a.py?line=1#frag"), "C:/a.py")


func test_empty_paths_are_empty_uris() -> void:
	assert_eq(LspText.path_to_uri(""), "")
	assert_eq(LspText.uri_to_path(""), "")


# ── UTF-16 POSITIONS ───────────────────────────────────────────────────────

func test_utf16_length_counts_surrogate_pairs() -> void:
	assert_eq(LspText.utf16_length("plain"), 5)
	assert_eq(LspText.utf16_length("a😀b"), 4)
	assert_eq(LspText.utf16_length("😀😀"), 4)


func test_utf16_and_codepoint_columns_convert_both_ways() -> void:
	var line := "a😀b"
	assert_eq(LspText.utf16_to_column(line, 0), 0)
	assert_eq(LspText.utf16_to_column(line, 1), 1)
	assert_eq(LspText.utf16_to_column(line, 3), 2)
	assert_eq(LspText.utf16_to_column(line, 4), 3)
	assert_eq(LspText.utf16_to_column(line, 99), 3)
	assert_eq(LspText.column_to_utf16(line, 0), 0)
	assert_eq(LspText.column_to_utf16(line, 1), 1)
	assert_eq(LspText.column_to_utf16(line, 2), 3)
	assert_eq(LspText.column_to_utf16(line, 99), 4)


func test_a_column_inside_a_surrogate_pair_clamps_before_it() -> void:
	assert_eq(LspText.utf16_to_column("a😀b", 2), 1)


func test_position_to_caret_uses_code_points() -> void:
	var text := "a😀b\ncd"
	var caret: Dictionary = LspText.position_to_caret(text, 0, 3)

	assert_eq(caret.get("line"), 0)
	assert_eq(caret.get("column"), 2)
	assert_eq(caret.get("index"), 2)
	assert_eq(LspText.position_to_caret(text, 1, 1).get("index"), 5)


func test_position_past_the_end_clamps_to_the_document_end() -> void:
	var text := "abc\n"
	var caret: Dictionary = LspText.position_to_caret(text, 42, 0)

	assert_eq(caret.get("line"), 1)
	assert_eq(caret.get("index"), text.length())


func test_caret_to_position_handles_surrogate_pairs() -> void:
	assert_eq(LspText.caret_to_position("a😀b\ncd", 0, 2), {"line": 0, "character": 3})
	assert_eq(LspText.caret_to_position("a😀b\ncd", 1, 1), {"line": 1, "character": 1})


# ── TEXT EDITS ──────────────────────────────────────────────────────────────

func _edit(line: int, character: int, end_line: int, end_character: int, new_text: String) -> Dictionary:
	return {
		"range": {
			"start": {"line": line, "character": character},
			"end": {"line": end_line, "character": end_character},
		},
		"newText": new_text,
	}


func test_apply_text_edits_inserts_and_replaces() -> void:
	var text := "hello world\nsecond\n"
	var result: Dictionary = LspText.apply_text_edits(text, [
		_edit(0, 0, 0, 5, "HELLO"),
		_edit(0, 5, 0, 5, ","),
		_edit(1, 0, 1, 6, "SECOND"),
	])

	assert_true(result.get("ok"))
	assert_eq(result.get("text"), "HELLO, world\nSECOND\n")
	assert_eq(result.get("applied"), 3)


func test_apply_text_edits_handles_surrogate_positions() -> void:
	var text := "a😀b\n"
	var result: Dictionary = LspText.apply_text_edits(text, [_edit(0, 3, 0, 3, "!")])

	assert_true(result.get("ok"))
	assert_eq(result.get("text"), "a😀!b\n")


func test_apply_text_edits_rejects_overlaps() -> void:
	var text := "abcdef"
	var result: Dictionary = LspText.apply_text_edits(text, [
		_edit(0, 0, 0, 3, "X"),
		_edit(0, 2, 0, 4, "Y"),
	])

	assert_false(result.get("ok"))
	assert_eq(result.get("text"), text)
	assert_true(str(result.get("error")).contains("overlapping"))


func test_apply_text_edits_accepts_touching_ranges() -> void:
	var result: Dictionary = LspText.apply_text_edits("abc", [
		_edit(0, 0, 0, 1, "A"),
		_edit(0, 1, 0, 2, "B"),
	])

	assert_true(result.get("ok"))
	assert_eq(result.get("text"), "ABc")


func test_an_edit_past_the_end_appends() -> void:
	var result: Dictionary = LspText.apply_text_edits("abc", [_edit(9, 0, 9, 0, "!")])

	assert_true(result.get("ok"))
	assert_eq(result.get("text"), "abc!")


func test_edits_for_view_resolves_caret_columns() -> void:
	var edits: Array = LspText.edits_for_view("a😀b", [_edit(0, 1, 0, 3, "X")])

	assert_eq(edits.size(), 1)
	assert_eq(edits[0].get("from_column"), 1)
	assert_eq(edits[0].get("to_column"), 2)
	assert_eq(edits[0].get("new_text"), "X")


func test_empty_edit_lists_are_a_no_op() -> void:
	var result: Dictionary = LspText.apply_text_edits("abc", [])

	assert_true(result.get("ok"))
	assert_eq(result.get("text"), "abc")
	assert_eq(result.get("applied"), 0)


# ── WORKSPACE EDITS ────────────────────────────────────────────────────────

func test_workspace_edit_merges_changes_and_document_changes() -> void:
	var edit := {
		"changes": {
			"file:///a.py": [_edit(0, 0, 0, 1, "A")],
		},
		"documentChanges": [
			{
				"textDocument": {"uri": "file:///a.py", "version": 3},
				"edits": [_edit(0, 2, 0, 3, "C")],
			},
			{
				"kind": "rename",
				"oldUri": "file:///old.py",
				"newUri": "file:///new.py",
			},
		],
	}
	var normalized: Dictionary = LspText.normalize_workspace_edit(edit)

	assert_true(normalized.get("ok"))
	assert_eq(normalized.get("files", {}).get("file:///a.py").size(), 2)
	assert_eq(normalized.get("operations").size(), 1)


func test_workspace_edit_applies_to_texts() -> void:
	var edit := {
		"changes": {
			"file:///a.py": [_edit(0, 0, 0, 1, "A")],
			"file:///b.py": [_edit(0, 0, 0, 1, "B")],
		},
	}
	var result: Dictionary = LspText.apply_to_texts(edit, {
		"file:///a.py": "abc",
		"file:///b.py": "xyz",
	})

	assert_true(result.get("ok"))
	assert_eq(result.get("texts", {}).get("file:///a.py"), "Abc")
	assert_eq(result.get("texts", {}).get("file:///b.py"), "Byz")
	assert_eq(result.get("applied_uris").size(), 2)


func test_workspace_edit_reports_a_missing_document() -> void:
	var edit := {"changes": {"file:///missing.py": [_edit(0, 0, 0, 1, "A")]}}
	var result: Dictionary = LspText.apply_to_texts(edit, {})

	assert_false(result.get("ok"))
	assert_true(result.get("errors", [])[0].contains("missing.py"))


func test_malformed_workspace_edit_is_rejected() -> void:
	var result: Dictionary = LspText.normalize_workspace_edit("nope")

	assert_false(result.get("ok"))
	assert_true(result.get("errors", []).size() > 0)


# ── MARKDOWN / HOVER ───────────────────────────────────────────────────────

func test_markdown_converts_bold_code_and_links() -> void:
	var bbcode: String = LspText.markdown_to_bbcode("**bold** and `code` [link](https://x)")

	assert_eq(bbcode, "[b]bold[/b] and [code]code[/code] [url=https://x]link[/url]")


func test_markdown_escapes_bbcode_injection() -> void:
	var bbcode: String = LspText.markdown_to_bbcode("[color=red]no[/color]")

	assert_true(bbcode.contains("[lb]color=red]"))
	assert_false(bbcode.contains("[color=red]"))


func test_markdown_code_fence_is_preserved() -> void:
	var bbcode: String = LspText.markdown_to_bbcode("```py\nprint(1)\n```")

	assert_eq(bbcode, "[code]\nprint(1)\n[/code]")


func test_markdown_plain_removes_formatting() -> void:
	var plain: String = LspText.markdown_to_plain("**bold** `code` [link](https://x)\n")

	assert_eq(plain, "bold code link")


func test_hover_normalizes_a_markup_content() -> void:
	var hover: Dictionary = LspText.normalize_hover({
		"contents": {"kind": "markdown", "value": "**name** — a value"},
		"range": {"start": {"line": 1, "character": 2}, "end": {"line": 1, "character": 5}},
	})

	assert_true(hover.get("ok"))
	assert_eq(hover.get("bbcode"), "[b]name[/b] — a value")
	assert_eq(hover.get("plain"), "name — a value")
	assert_eq(hover.get("range", {}).get("start", {}).get("line"), 1)


func test_hover_normalizes_an_array_of_plaintext_parts() -> void:
	var hover: Dictionary = LspText.normalize_hover({
		"contents": [
			{"language": "python", "value": "def foo()"},
			{"kind": "plaintext", "value": "Does a thing."},
		],
	})

	assert_true(hover.get("ok"))
	assert_true(hover.get("bbcode").contains("[code]def foo()[/code]"))
	assert_true(hover.get("plain").contains("Does a thing."))


func test_empty_hover_is_not_ok() -> void:
	assert_false(LspText.normalize_hover(null).get("ok"))
	assert_false(LspText.normalize_hover("").get("ok"))


# ── DIAGNOSTICS ─────────────────────────────────────────────────────────────

func test_diagnostics_are_normalized() -> void:
	var parsed: Dictionary = LspText.normalize_publish_diagnostics({
		"uri": "file:///a.py",
		"version": 4,
		"diagnostics": [{
			"range": {"start": {"line": 2, "character": 3}, "end": {"line": 2, "character": 8}},
			"severity": 1,
			"message": "Undefined name",
			"source": "Pyright",
			"code": "reportUndefinedVariable",
		}],
	})

	assert_eq(parsed.get("uri"), "file:///a.py")
	assert_eq(parsed.get("version"), 4)
	var diagnostic: Dictionary = parsed.get("diagnostics", [])[0]
	assert_eq(diagnostic.get("severity_name"), "error")
	assert_eq(diagnostic.get("code"), "reportUndefinedVariable")
	assert_eq(LspText.diagnostic_line(diagnostic), 2)
	assert_eq(LspText.diagnostic_column(diagnostic), 3)
	assert_true(LspText.diagnostic_label(diagnostic).contains("Pyright reportUndefinedVariable"))


func test_diagnostic_codes_that_are_objects_are_kept_as_text() -> void:
	var diagnostic: Dictionary = LspText.normalize_diagnostic({
		"message": "x", "code": {"value": "E42", "target": "https://x"},
	})

	assert_eq(diagnostic.get("code"), "E42")


func test_diagnostic_severity_defaults_to_information() -> void:
	var diagnostic: Dictionary = LspText.normalize_diagnostic({"message": "x"})

	assert_eq(diagnostic.get("severity"), 3)
	assert_eq(diagnostic.get("severity_name"), "information")


# ── COMPLETION ──────────────────────────────────────────────────────────────

func test_completion_list_is_normalized_and_snippets_expand() -> void:
	var parsed: Dictionary = LspText.normalize_completion({
		"isIncomplete": true,
		"items": [
			{
				"label": "greet",
				"kind": 3,
				"detail": "function",
				"insertTextFormat": 2,
				"insertText": "greet(${1:name})",
				"documentation": {"kind": "markdown", "value": "**Says hi.**"},
				"tags": [1],
			},
			{"label": "plain", "kind": 1},
		],
	})

	assert_true(parsed.get("is_incomplete"))
	var first: Dictionary = parsed.get("items", [])[0]
	assert_eq(first.get("insert_text"), "greet(name)")
	assert_eq(first.get("category"), "function")
	assert_eq(first.get("kind_name"), "function")
	assert_eq(first.get("documentation_plain"), "Says hi.")
	assert_true(first.get("deprecated"))
	assert_eq(parsed.get("items", [])[1].get("insert_text"), "plain")


func test_completion_uses_text_edit_when_insert_text_is_missing() -> void:
	var item: Dictionary = LspText.normalize_completion_item({
		"label": "foo",
		"textEdit": {"range": {}, "newText": "foo()"},
	})

	assert_eq(item.get("insert_text"), "foo()")


func test_snippet_placeholders_and_choices_become_plain_text() -> void:
	assert_eq(LspText.snippet_to_text("for ${1:i} in ${2:items}:\n\t$0"), "for i in items:\n\t")
	assert_eq(LspText.snippet_to_text("${1|one,two|}"), "one")
	assert_eq(LspText.snippet_to_text("cost: \\$5"), "cost: $5")
	assert_eq(LspText.snippet_to_text("${TM_FILENAME}"), "")


# ── SIGNATURE HELP ──────────────────────────────────────────────────────────

func test_signature_help_is_normalized() -> void:
	var parsed: Dictionary = LspText.normalize_signature_help({
		"signatures": [{
			"label": "foo(a, b)",
			"documentation": "Does things.",
			"parameters": [{"label": "a"}, {"label": "b", "documentation": "second"}],
		}],
		"activeSignature": 0,
		"activeParameter": 1,
	})

	assert_true(parsed.get("ok"))
	assert_eq(parsed.get("signatures", [])[0].get("label"), "foo(a, b)")
	assert_eq(parsed.get("signatures", [])[0].get("parameters", [])[1].get("documentation"), "second")
	assert_eq(parsed.get("active_parameter"), 1)


func test_signature_line_bolds_the_active_parameter() -> void:
	var parsed: Dictionary = LspText.normalize_signature_help({
		"signatures": [{"label": "foo(a, b)", "parameters": [{"label": "a"}, {"label": "b"}]}],
		"activeParameter": 1,
	})

	assert_eq(LspText.signature_line(parsed.get("signatures", [])[0], 1), "foo(a, [b]b[/b])")


func test_signature_line_supports_offsets() -> void:
	var parsed: Dictionary = LspText.normalize_signature_help({
		"signatures": [{
			"label": "foo(a, b)",
			"parameters": [{"label": [4, 5]}, {"label": [7, 8]}],
		}],
		"activeParameter": 0,
	})

	assert_eq(LspText.signature_line(parsed.get("signatures", [])[0], 0), "foo([b]a[/b], b)")


func test_empty_signature_help_is_not_ok() -> void:
	assert_false(LspText.normalize_signature_help(null).get("ok"))
	assert_false(LspText.normalize_signature_help({"signatures": []}).get("ok"))


func test_call_context_detects_an_open_argument_list() -> void:
	assert_true(LspText.call_context("print(", 0, 6).get("inside"))
	assert_eq(LspText.call_context("print(", 0, 6).get("open_column"), 5)
	assert_true(LspText.call_context("x = foo(1, ", 0, 12).get("inside"))
	assert_false(LspText.call_context("x = 1", 0, 5).get("inside"))
	assert_false(LspText.call_context("foo(1)", 0, 6).get("inside"))


# ── LOCATIONS / CODE ACTIONS ────────────────────────────────────────────────

func test_locations_support_links_and_are_sorted() -> void:
	var locations: Array = LspText.normalize_locations([
		{"uri": "file:///z.py", "range": {"start": {"line": 4, "character": 1}}},
		{
			"targetUri": "file:///a.py",
			"targetSelectionRange": {"start": {"line": 2, "character": 7}},
			"targetRange": {"start": {"line": 0, "character": 0}},
		},
	])

	assert_eq(locations.size(), 2)
	assert_eq(locations[0].get("path"), "/a.py")
	assert_eq(locations[0].get("line"), 2)
	assert_eq(locations[0].get("character"), 7)
	assert_eq(locations[1].get("path"), "/z.py")


func test_code_actions_are_normalized() -> void:
	var actions: Array = LspText.normalize_code_actions([
		{"title": "Import", "kind": "quickfix", "edit": {"changes": {}}, "isPreferred": true},
		{"title": "No edit", "data": {"fix": 7}},
		"not an action",
	])

	assert_eq(actions.size(), 2)
	assert_eq(actions[0].get("title"), "Import")
	assert_true(actions[0].get("is_preferred"))
	assert_eq(actions[1].get("edit"), null)
	assert_eq(actions[1].get("data"), {"fix": 7})
	assert_eq(actions[1].get("raw").get("title"), "No edit")
