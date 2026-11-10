class_name VersionUtils
extends RefCounted

## Semantic-ish version comparison for the updater. Handles a leading "v" and
## pre-release/build suffixes ("1.2.3-beta" -> 1.2.3), compares components as
## integers (so 1.10 > 1.9), and treats missing components as zero.

static func _parts(version: String) -> PackedStringArray:
	var cleaned := version.strip_edges()
	if cleaned.begins_with("v") or cleaned.begins_with("V"):
		cleaned = cleaned.substr(1)

	# Ignore pre-release/build metadata for ordering.
	var dash := cleaned.find("-")
	if dash != -1:
		cleaned = cleaned.substr(0, dash)

	var plus := cleaned.find("+")
	if plus != -1:
		cleaned = cleaned.substr(0, plus)

	return cleaned.split(".", true)


## 1 when a > b, -1 when a < b, 0 when equal.
static func compare_versions(a: String, b: String) -> int:
	var left := _parts(a)
	var right := _parts(b)
	var count := maxi(left.size(), right.size())

	for i in range(count):
		var left_value := int(left[i]) if i < left.size() else 0
		var right_value := int(right[i]) if i < right.size() else 0

		if left_value > right_value:
			return 1
		if left_value < right_value:
			return -1

	return 0


static func is_higher_version(current: String, candidate: String) -> bool:
	return compare_versions(candidate, current) > 0
