extends TestCase

## Dependency resolution: ordering, missing nodes, range failures, cycles,
## optional edges and declared conflicts.

const Resolver = preload("res://src/features/mods/mod_resolver.gd")


func _manifest(id: String, version: String = "1.0.0", dependencies: Dictionary = {}, optional: Dictionary = {}, conflicts: Array = []) -> Dictionary:
	return {
		"id": id,
		"name": id,
		"version": version,
		"dependencies": dependencies,
		"optional": optional,
		"conflicts": conflicts,
	}


func _codes(result: Dictionary) -> Array:
	var out: Array = []
	for error in result.get("errors", []):
		out.append(str(error.get("code", "")))
	return out


func test_topological_order() -> void:
	var result := Resolver.resolve({
		"a.app": _manifest("a.app", "1.0.0"),
		"b.app": _manifest("b.app", "1.0.0", {"a.app": "^1.0.0"}),
		"c.app": _manifest("c.app", "1.0.0", {"b.app": "^1.0.0"}),
	})
	check(result.get("ok", false), "valid graph resolves")
	assert_eq(result.get("order"), ["a.app", "b.app", "c.app"])


func test_deterministic_independent_order() -> void:
	var manifests := {
		"z.app": _manifest("z.app"),
		"a.app": _manifest("a.app"),
		"m.app": _manifest("m.app"),
	}
	assert_eq(Resolver.resolve(manifests).get("order"), ["a.app", "m.app", "z.app"])
	assert_eq(Resolver.resolve(manifests).get("order"), ["a.app", "m.app", "z.app"])


func test_missing_dependency() -> void:
	var result := Resolver.resolve({
		"a.app": _manifest("a.app", "1.0.0", {"missing.mod": "^1.0.0"}),
	})
	check(!result.get("ok", false), "missing dependency blocks")
	check(_codes(result).has("dependency.missing"), "missing code")
	assert_eq((result["errors"][0] as Dictionary).get("ids"), ["a.app", "missing.mod"])


func test_version_mismatch() -> void:
	var result := Resolver.resolve({
		"a.app": _manifest("a.app", "1.0.0", {"base.mod": "^2.0.0"}),
		"base.mod": _manifest("base.mod", "1.4.0"),
	})
	check(!result.get("ok", false), "range mismatch blocks")
	check(_codes(result).has("dependency.version"), "version code")


func test_cycle() -> void:
	var result := Resolver.resolve({
		"a.app": _manifest("a.app", "1.0.0", {"b.app": "^1.0.0"}),
		"b.app": _manifest("b.app", "1.0.0", {"a.app": "^1.0.0"}),
	})
	check(!result.get("ok", false), "cycle blocks")
	check(_codes(result).has("dependency.cycle"), "cycle code")
	check(str((result["errors"][0] as Dictionary).get("message", "")).contains("a.app"), "cycle names the path")


func test_optional_dependency() -> void:
	var missing := Resolver.resolve({
		"a.app": _manifest("a.app", "1.0.0", {}, {"extra.mod": "^1.0.0"}),
	})
	check(missing.get("ok", false), "missing optional does not block")
	assert_eq(missing.get("order"), ["a.app"])
	check(!(missing.get("warnings", []) as Array).is_empty(), "missing optional warns")

	var present := Resolver.resolve({
		"a.app": _manifest("a.app", "1.0.0", {}, {"b.app": "^1.0.0"}),
		"b.app": _manifest("b.app", "1.2.0"),
	})
	check(present.get("ok", false), "present optional resolves")
	assert_eq(present.get("order"), ["b.app", "a.app"])


func test_conflicts() -> void:
	var result := Resolver.resolve({
		"a.app": _manifest("a.app", "1.0.0", {}, {}, ["b.app"]),
		"b.app": _manifest("b.app", "1.0.0"),
	})
	check(!result.get("ok", false), "declared conflict blocks")
	check(_codes(result).has("dependency.conflict"), "conflict code")
