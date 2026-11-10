extends "res://tests/support/test_case.gd"

const Parser = preload("res://src/features/git/git_status_parser.gd")
const Service = preload("res://src/features/git/git_service.gd")


func test_branch_header_and_ahead_behind() -> void:
	var status := Parser.parse_status(
		"# branch.oid 0123456789abcdef\n" +
		"# branch.head main\n" +
		"# branch.upstream origin/main\n" +
		"# branch.ab +2 -1\n"
	)
	assert_eq(status["head"], "0123456789abcdef")
	assert_eq(status["branch"], "main")
	assert_eq(status["upstream"], "origin/main")
	assert_eq(status["ahead"], 2)
	assert_eq(status["behind"], 1)
	assert_false(status["detached"])
	assert_false(status["initial"])


func test_detached_and_initial_heads() -> void:
	var detached := Parser.parse_status(
		"# branch.oid abc\n# branch.head (detached)\n"
	)
	assert_true(detached["detached"])
	assert_eq(detached["branch"], "")

	var initial := Parser.parse_status(
		"# branch.oid (initial)\n# branch.head main\n"
	)
	assert_true(initial["initial"])
	assert_eq(initial["branch"], "main")


func test_changed_untracked_and_staged_files_are_grouped() -> void:
	var status := Parser.parse_status(
		"# branch.oid abc\n# branch.head main\n" +
		"1 .M N... 100644 100644 100644 abc def src/app.gd\n" +
		"1 M. N... 100644 100644 100644 abc def staged.txt\n" +
		"? new.txt\n" +
		"! ignored.log\n"
	)
	assert_eq(status["staged_count"], 1)
	assert_eq(status["unstaged_count"], 2)
	assert_eq(status["staged"][0]["path"], "staged.txt")
	assert_eq(status["staged"][0]["status"], "M")
	assert_eq(status["unstaged"][0]["path"], "src/app.gd")
	assert_eq(status["unstaged"][0]["status"], "M")
	assert_eq(status["unstaged"][1]["path"], "new.txt")
	assert_eq(status["unstaged"][1]["status"], "?")
	assert_true(status["unstaged"][1]["untracked"])


func test_rename_records_both_paths() -> void:
	var status := Parser.parse_status(
		"# branch.oid abc\n# branch.head main\n" +
		"2 R. N... 100644 100644 100644 abc def R100 renamed.txt\told.txt\n"
	)
	assert_eq(status["staged_count"], 1)
	var entry: Dictionary = status["staged"][0]
	assert_eq(entry["path"], "renamed.txt")
	assert_eq(entry["orig_path"], "old.txt")
	assert_true(entry["renamed"])
	assert_eq(entry["status"], "R")


func test_conflicts_are_unstaged_and_marked() -> void:
	var status := Parser.parse_status(
		"# branch.oid abc\n# branch.head main\n" +
		"u UU N... 100644 100644 100644 100644 abc def ghi conflict.txt\n"
	)
	assert_eq(status["staged_count"], 0)
	assert_eq(status["unstaged_count"], 1)
	var entry: Dictionary = status["unstaged"][0]
	assert_eq(entry["path"], "conflict.txt")
	assert_true(entry["conflicted"])
	assert_eq(entry["status"], "U")


func test_quoted_paths_are_decoded() -> void:
	assert_eq(Parser.unquote_path("\"with\\ttab.txt\""), "with\ttab.txt")
	assert_eq(Parser.unquote_path("\"quote\\\"name.txt\""), "quote\"name.txt")
	assert_eq(Parser.unquote_path("\"caf\\303\\251.txt\""), "café.txt")
	assert_eq(Parser.unquote_path("plain path.txt"), "plain path.txt")


func test_status_rows_are_capped_without_losing_counts() -> void:
	var body := "# branch.head main\n"
	for i in range(Parser.MAX_ROWS + 5):
		body += "? file_%d.txt\n" % i
	var status := Parser.parse_status(body)
	assert_eq(status["unstaged_count"], Parser.MAX_ROWS + 5)
	assert_eq((status["unstaged"] as Array).size(), Parser.MAX_ROWS)
	assert_true(status["truncated"])


func test_branches_and_log_are_parsed() -> void:
	var branches := Parser.parse_branches(
		"main\u001f*\u001forigin/main\u001f1700000000\n" +
		"feature\u001f\u001f\u001f1690000000\n"
	)
	assert_eq(branches.size(), 2)
	assert_eq(branches[0]["name"], "main")
	assert_true(branches[0]["current"])
	assert_eq(branches[0]["upstream"], "origin/main")
	assert_eq(branches[1]["name"], "feature")

	var log := Parser.parse_log(
		"abc123\u001fabc\u001fAda\u001fada@example.test\u001f1700000000\u001f2 hours ago\u001fmain\u001fFix the thing\u001e" +
		"def456\u001fdef\u001fGrace\u001fgrace@example.test\u001f1690000000\u001f1 day ago\u001f\u001fAdd tests\u001e"
	)
	assert_eq(log.size(), 2)
	assert_eq(log[0]["hash"], "abc123")
	assert_eq(log[0]["short"], "abc")
	assert_eq(log[0]["author"], "Ada")
	assert_eq(log[0]["subject"], "Fix the thing")
	assert_eq(log[1]["subject"], "Add tests")


func test_repo_root_is_found_from_a_nested_path() -> void:
	var base := OS.get_temp_dir().replace("\\", "/").path_join("griddy_git_root_%d" % Time.get_ticks_usec())
	var nested := base.path_join("src").path_join("deep")
	assert_eq(DirAccess.make_dir_recursive_absolute(nested), OK)
	assert_eq(DirAccess.make_dir_absolute(base.path_join(".git")), OK)

	# An empty .git folder is not a repository; Git itself rejects it.
	assert_eq(Service.find_repo_root(nested), "")

	var head := FileAccess.open(base.path_join(".git").path_join("HEAD"), FileAccess.WRITE)
	assert_true(head != null)
	head.store_string("ref: refs/heads/main\n")
	head.close()

	assert_eq(Service.find_repo_root(nested), base)
	assert_eq(Service.relative_to(base, nested.path_join("file.gd")), "src/deep/file.gd")
	assert_eq(Service.relative_to(base, base), "")

	DirAccess.remove_absolute(base.path_join(".git").path_join("HEAD"))
	DirAccess.remove_absolute(base.path_join(".git"))
	DirAccess.remove_absolute(nested)
	DirAccess.remove_absolute(base.path_join("src"))
	DirAccess.remove_absolute(base)


func test_gitdir_file_describes_a_worktree() -> void:
	var base := OS.get_temp_dir().replace("\\", "/").path_join("griddy_git_worktree_%d" % Time.get_ticks_usec())
	var worktree := base.path_join("worktree")
	var gitdir := base.path_join("repo").path_join(".git").path_join("worktrees").path_join("wt")
	assert_eq(DirAccess.make_dir_recursive_absolute(worktree), OK)
	assert_eq(DirAccess.make_dir_recursive_absolute(gitdir), OK)

	var head := FileAccess.open(gitdir.path_join("HEAD"), FileAccess.WRITE)
	assert_true(head != null)
	head.store_string("ref: refs/heads/wt\n")
	head.close()

	var link := FileAccess.open(worktree.path_join(".git"), FileAccess.WRITE)
	assert_true(link != null)
	link.store_string("gitdir: ../repo/.git/worktrees/wt\n")
	link.close()

	assert_eq(Service.find_repo_root(worktree), worktree)

	DirAccess.remove_absolute(worktree.path_join(".git"))
	DirAccess.remove_absolute(gitdir.path_join("HEAD"))
	DirAccess.remove_absolute(gitdir)
	DirAccess.remove_absolute(base.path_join("repo").path_join(".git").path_join("worktrees"))
	DirAccess.remove_absolute(base.path_join("repo").path_join(".git"))
	DirAccess.remove_absolute(base.path_join("repo"))
	DirAccess.remove_absolute(worktree)
	DirAccess.remove_absolute(base)
