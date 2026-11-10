extends "res://tests/support/test_case.gd"


func test_empty_query_matches_everything() -> void:
	assert_eq(FuzzyMatch.score("anything", ""), 0.0)


func test_exact_match_beats_everything() -> void:
	assert_eq(FuzzyMatch.score("main.py", "main.py"), -1000.0)


func test_no_match_returns_minus_one() -> void:
	assert_eq(FuzzyMatch.score("palette_panel.gd", "xyz"), -1.0)


func test_match_is_case_insensitive() -> void:
	assert_ne(FuzzyMatch.score("Main.PY", "mpy"), -1.0)


func test_tighter_matches_score_lower() -> void:
	var tight := FuzzyMatch.score("panel.gd", "pnl")
	var loose := FuzzyMatch.score("palette_panel.gd", "pnl")

	assert_ne(tight, -1.0)
	assert_ne(loose, -1.0)
	assert_true(tight < loose, "tight match (%s) should beat loose match (%s)" % [tight, loose])


func test_name_boundaries_get_a_bonus() -> void:
	var boundary := FuzzyMatch.score("foo_bar", "b")
	var middle := FuzzyMatch.score("foobar", "b")

	assert_true(boundary < middle, "boundary hit (%s) should beat middle hit (%s)" % [boundary, middle])


func test_earlier_match_wins() -> void:
	assert_true(FuzzyMatch.score("alpha.txt", "a") < FuzzyMatch.score("beta_alpha.txt", "a"))
