class_name FuzzyMatch
extends RefCounted

## Subsequence matcher used by quick-open and the command palette.
##
## Lower score = better match. -1 = no match. -1000 = exact match.
## Rewards early starts and tight gaps, with a bonus when a hit follows a
## name boundary ("/" "." "_" "-" or space).
static func score(text: String, query: String) -> float:
	if query.is_empty():
		return 0.0

	return score_lowered(text.to_lower(), query.to_lower())


## Same ranking, but both strings must already be lowercased. Quick open runs
## this against thousands of pre-lowered index entries on every keypress; the
## repeated to_lower() allocations were the expensive part, not the scan.
static func score_lowered(t: String, q: String) -> float:
	if q.is_empty():
		return 0.0
	if t == q:
		return -1000.0

	# Quick open usually receives a contiguous fragment ("main", "util.gd").
	# One native substring scan avoids the per-character find() loop that the
	# subsequence fallback needs, keeping 5,000-entry filtering under a frame.
	var contiguous := t.find(q)
	if contiguous != -1:
		var contiguous_penalty := 0.0
		if contiguous > 0:
			var boundary_ch := t.unicode_at(contiguous - 1)
			if boundary_ch == 47 or boundary_ch == 46 or boundary_ch == 95 or boundary_ch == 45 or boundary_ch == 32:
				contiguous_penalty -= 4.0
		return contiguous * 0.5 + contiguous_penalty

	var first := -1
	var prev := -1
	var penalty := 0.0
	var text_index := 0

	for i in range(q.length()):
		var index := t.find(q[i], text_index)
		if index == -1:
			return -1.0

		if first == -1:
			first = index
		else:
			penalty += index - prev - 1

		prev = index
		text_index = index + 1

	if first > 0:
		var ch := t.unicode_at(first - 1)
		if ch == 47 or ch == 46 or ch == 95 or ch == 45 or ch == 32:
			penalty -= 4.0

	return first * 0.5 + penalty
