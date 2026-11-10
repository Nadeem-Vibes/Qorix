extends RefCounted

## Dependency graph resolution for the installed mod set.
##
## One active version per mod (the registry hands the highest installed valid
## version in), so this is a plain graph problem: required edges must exist and
## satisfy their range, optional edges are activated only when they can be, and
## the topological order is deterministic (lexicographic tie-break) so two runs
## activate mods in the same order.

const SemverRange = preload("res://src/features/mods/semver_range.gd")
const Manifest = preload("res://src/features/mods/mod_manifest.gd")


## `manifests` is id -> normalized manifest. Returns
## {ok, order, errors: [{code, message, ids}], warnings: [{code, message, ids}]}.
static func resolve(manifests: Dictionary) -> Dictionary:
	var errors: Array = []
	var warnings: Array = []

	var ids: Array = manifests.keys()
	ids.sort()

	var edges: Dictionary = {}
	var indegree: Dictionary = {}
	for id in ids:
		edges[id] = []
		indegree[id] = 0

	# Declared conflicts are symmetric; report each pair once.
	for id in ids:
		var manifest: Dictionary = manifests[id]
		var conflicts: Variant = manifest.get("conflicts", [])
		if !(conflicts is Array):
			continue
		for item in conflicts:
			var other := str(item)
			if other == str(id):
				continue
			if manifests.has(other) and str(id) < other:
				errors.append({
					"code": "dependency.conflict",
					"message": "'%s' and '%s' declare a conflict; disable one of them." % [str(id), other],
					"ids": [str(id), other],
				})

	for id in ids:
		var manifest: Dictionary = manifests[id]
		var version := str(manifest.get("version", ""))

		var dependencies: Variant = manifest.get("dependencies", {})
		if dependencies is Dictionary:
			var dep_ids: Array = (dependencies as Dictionary).keys()
			dep_ids.sort()
			for dep_key in dep_ids:
				var dep_id := str(dep_key)
				var range_text := str((dependencies as Dictionary)[dep_key])
				if !manifests.has(dep_id):
					errors.append({
						"code": "dependency.missing",
						"message": "'%s' requires '%s' %s, which is not installed." % [str(id), dep_id, range_text],
						"ids": [str(id), dep_id],
					})
					continue
				var dep_version := str((manifests[dep_id] as Dictionary).get("version", ""))
				if !SemverRange.satisfies(dep_version, range_text):
					errors.append({
						"code": "dependency.version",
						"message": "'%s' requires '%s' %s, but %s is installed." % [str(id), dep_id, range_text, dep_version],
						"ids": [str(id), dep_id],
					})
					continue
				edges[dep_id].append(id)
				indegree[id] += 1

		var optional: Variant = manifest.get("optional", {})
		if optional is Dictionary:
			var optional_ids: Array = (optional as Dictionary).keys()
			optional_ids.sort()
			for dep_key in optional_ids:
				var dep_id := str(dep_key)
				var range_text := str((optional as Dictionary)[dep_key])
				if !manifests.has(dep_id):
					warnings.append({
						"code": "dependency.optional_missing",
						"message": "'%s' optionally integrates with '%s', which is not installed." % [str(id), dep_id],
						"ids": [str(id), dep_id],
					})
					continue
				var dep_version := str((manifests[dep_id] as Dictionary).get("version", ""))
				if !SemverRange.satisfies(dep_version, range_text):
					warnings.append({
						"code": "dependency.optional_version",
						"message": "'%s' optionally wants '%s' %s, but %s is installed." % [str(id), dep_id, range_text, dep_version],
						"ids": [str(id), dep_id],
					})
					continue
				edges[dep_id].append(id)
				indegree[id] += 1

		if !Manifest.is_valid_id(str(id)):
			errors.append({
				"code": "manifest.invalid",
				"message": "'%s' is not a valid mod id." % str(id),
				"ids": [str(id)],
			})

	# Kahn's algorithm with a sorted ready list.
	var ready: Array = []
	for id in ids:
		if int(indegree[id]) == 0:
			ready.append(id)
	ready.sort()

	var order: Array = []
	while !ready.is_empty():
		var next := str(ready.pop_front())
		order.append(next)

		var targets: Array = edges.get(next, [])
		targets.sort()
		for target in targets:
			indegree[target] = int(indegree[target]) - 1
			if int(indegree[target]) == 0:
				ready.append(str(target))
		ready.sort()

	if order.size() != ids.size():
		var remaining: Array = []
		for id in ids:
			if !order.has(id):
				remaining.append(id)
		remaining.sort()
		var cycle := _find_cycle(remaining, edges)
		errors.append({
			"code": "dependency.cycle",
			"message": "Dependency cycle: %s." % " -> ".join(cycle),
			"ids": cycle,
		})

	return {
		"ok": errors.is_empty(),
		"order": order,
		"errors": errors,
		"warnings": warnings,
	}


## Walks dependents inside the unresolved remainder until a node repeats.
static func _find_cycle(nodes: Array, edges: Dictionary) -> Array:
	if nodes.is_empty():
		return []

	var inside: Dictionary = {}
	for node in nodes:
		inside[str(node)] = true

	var path: Array = []
	var seen_at: Dictionary = {}
	var current := str(nodes[0])

	while !seen_at.has(current):
		seen_at[current] = path.size()
		path.append(current)

		var next := ""
		var targets: Array = edges.get(current, [])
		targets.sort()
		for target in targets:
			if inside.has(str(target)):
				next = str(target)
				break
		if next.is_empty():
			break
		current = next

	if seen_at.has(current):
		return path.slice(int(seen_at[current]))
	return path
