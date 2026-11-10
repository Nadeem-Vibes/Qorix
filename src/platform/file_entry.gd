class_name FileEntry
extends RefCounted

## One indexed file in the workspace. Deliberately tiny and allocation-light:
## a 5,000 file workspace keeps 5,000 of these in memory for instant quick
## open, so no node, no script per entry and no per-entry signal.

var path: String = ""       ## absolute path (forward slashes)
var rel: String = ""        ## path relative to the workspace root
var name: String = ""       ## file name
var ext: String = ""        ## extension without the dot ("" when none)
var size: int = 0           ## bytes
var mtime: int = 0          ## Unix timestamp of the last modification

# Pre-lowered copies for the fuzzy matcher: quick open runs on every keypress
# and lowercasing 5,000 relative paths each time is wasted work.
var rel_lower: String = ""
var name_lower: String = ""


func _init(
	p_path: String = "",
	p_rel: String = "",
	p_name: String = "",
	p_ext: String = "",
	p_size: int = 0,
	p_mtime: int = 0
) -> void:
	path = p_path
	rel = p_rel
	name = p_name
	ext = p_ext
	size = p_size
	mtime = p_mtime
	rel_lower = p_rel.to_lower()
	name_lower = p_name.to_lower()


func to_dict() -> Dictionary:
	return {
		"path": path,
		"rel": rel,
		"name": name,
		"ext": ext,
		"size": size,
		"mtime": mtime,
	}
