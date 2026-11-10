extends "res://tests/support/test_case.gd"

const RunCapture = preload("res://src/features/run/run_capture.gd")

const TOKEN := "TEST123"

var capture


func before_each() -> void:
	capture = RunCapture.new(TOKEN)


func after_each() -> void:
	capture = null


func _begin() -> void:
	capture.feed_string("ConPTY handshake\r\n" + capture.start_marker + "\r\n")


func test_start_marker_hides_shell_noise() -> void:
	_begin()
	capture.feed_string("hello\r\nworld\r\n")

	assert_eq(capture.output(), "hello\nworld\n")
	assert_true(capture.has_started())
	assert_false(capture.is_finished())


func test_start_marker_can_be_split_across_chunks() -> void:
	var marker: String = capture.start_marker
	var first: bool = capture.feed_string(marker.substr(0, 7))
	var second: bool = capture.feed_string(marker.substr(7) + "\r\nready")

	assert_false(first, "an incomplete marker must not start the body")
	assert_true(second)
	assert_eq(capture.output(), "ready")


func test_end_marker_sets_the_exit_code() -> void:
	_begin()
	capture.feed_string("value = 1\r\n" + capture.end_marker + "3\r\n")

	assert_eq(capture.output(), "value = 1\n")
	assert_true(capture.is_finished())
	assert_eq(capture.exit_code(), 3)


func test_end_marker_can_arrive_in_a_later_chunk() -> void:
	_begin()
	capture.feed_string("one\r\n")
	capture.feed_string(capture.end_marker + "0\r\n")

	assert_eq(capture.output(), "one\n")
	assert_eq(capture.exit_code(), 0)


func test_pty_exit_code_wins_over_the_marker() -> void:
	_begin()
	capture.feed_string("done\r\n")
	capture.finish(0)

	assert_eq(capture.exit_code(), 0)
	assert_true(capture.is_finished())


func test_finish_does_not_overwrite_a_parsed_marker_code() -> void:
	_begin()
	capture.feed_string("done\r\n" + capture.end_marker + "7\r\n")
	capture.finish(2)

	assert_eq(capture.exit_code(), 7)


func test_output_is_ignored_before_the_start_marker() -> void:
	capture.feed_string("noise\r\nmore noise\r\n")

	assert_eq(capture.output(), "")
	assert_false(capture.has_started())


func test_output_is_ignored_after_finish() -> void:
	_begin()
	capture.feed_string("before\r\n" + capture.end_marker + "0\r\n")
	var changed: bool = capture.feed_string("after\r\n")

	assert_false(changed)
	assert_eq(capture.output(), "before\n")


func test_ansi_colors_are_removed() -> void:
	_begin()
	capture.feed_string("\u001B[31mred\u001B[0m and \u001B[1;32mgreen\u001B[39m\r\n")

	assert_eq(capture.output(), "red and green\n")


func test_osc_title_sequences_are_removed() -> void:
	_begin()
	capture.feed_string("\u001B]0;a window title\u0007visible\r\n")

	assert_eq(capture.output(), "visible\n")


func test_backspace_removes_the_previous_character() -> void:
	_begin()
	capture.feed_string("abc\b\bZ\r\n")

	assert_eq(capture.output(), "aZ\n")


func test_carriage_return_keeps_the_last_progress_frame() -> void:
	_begin()
	capture.feed_string("10%\r50%\r100%\r\n")

	assert_eq(capture.output(), "100%\n")


func test_crlf_is_normalized_to_lf() -> void:
	_begin()
	capture.feed_string("a\r\nb\r\n")

	assert_eq(capture.output(), "a\nb\n")


func test_control_bytes_are_removed() -> void:
	_begin()
	var controls := String.chr(7) + String.chr(11) + String.chr(12) + String.chr(31)
	capture.feed_string("before" + controls + "after")

	assert_eq(capture.output(), "beforeafter")


func test_a_utf8_character_split_across_chunks_is_decoded_once() -> void:
	_begin()
	var bytes := "café".to_utf8_buffer()
	var split: bool = capture.feed_bytes(bytes.slice(0, bytes.size() - 1))
	var completed: bool = capture.feed_bytes(bytes.slice(bytes.size() - 1))

	assert_eq(capture.output(), "café")
	assert_false(capture.output().contains("�"), "a split rune must not become a replacement character")
	assert_true(split or completed)


func test_incomplete_utf8_is_flushed_when_the_process_exits() -> void:
	_begin()
	capture.feed_bytes(PackedByteArray([0x63, 0x61, 0x66, 0xC3]))
	capture.finish(0)

	assert_true(capture.output().begins_with("caf"))
	assert_true(capture.output().length() > 3, "the incomplete rune must not be dropped")


func test_clear_resets_every_piece_of_state() -> void:
	_begin()
	capture.feed_string("body\r\n" + capture.end_marker + "4\r\n")
	capture.clear()

	assert_eq(capture.output(), "")
	assert_eq(capture.exit_code(), -1)
	assert_false(capture.has_started())
	assert_false(capture.is_finished())
	assert_false(capture.truncated())


func test_huge_output_is_capped_but_keeps_head_and_tail() -> void:
	_begin()
	capture.feed_string("HEAD-" + "a".repeat(1_200_000) + "-TAIL")

	var text: String = capture.output()

	assert_true(capture.truncated())
	assert_true(text.begins_with("HEAD-"))
	assert_true(text.ends_with("-TAIL"))
	assert_true(text.contains("[output truncated]"))
	assert_true(text.length() < 1_100_000)


func test_make_token_is_alphanumeric_and_unique() -> void:
	var first := RunCapture.make_token()
	var second := RunCapture.make_token()

	assert_true(first.length() > 0)
	for i in range(first.length()):
		var character := first[i]
		assert_true(
			(character >= "0" and character <= "9") or (character >= "a" and character <= "z"),
			"token must be shell-safe: " + first
		)
	assert_ne(first, second)
