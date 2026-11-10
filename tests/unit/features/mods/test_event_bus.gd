extends TestCase

## Event bus: ordering, coalescing, queue caps, namespaces and unsubscription.

const Bus = preload("res://src/features/mods/events/event_bus.gd")

var calls: Array = []
var bus = null


func before_each() -> void:
	calls = []
	bus = Bus.new()
	bus.set_dispatch(func(mod_id: String, handle: int, payload: Dictionary) -> Dictionary:
		calls.append({"mod": mod_id, "handle": handle, "payload": payload})
		return {"ok": true}
	)


func test_publish_and_dispatch() -> void:
	var subscription: Dictionary = bus.subscribe("griddycode.one", "document.saved", 7)
	check(subscription.get("ok", false), "subscription accepted")

	bus.publish("document.saved", {"doc": 3, "path": "main.py"})
	check(calls.is_empty(), "nothing dispatches before tick")

	bus.tick(0.0)
	assert_eq(calls.size(), 1)
	assert_eq(calls[0]["handle"], 7)
	assert_eq(calls[0]["payload"]["doc"], 3)


func test_unknown_host_event_rejected() -> void:
	var result: Dictionary = bus.publish("document.exploded", {})
	check(!result.get("ok", false), "unknown host event rejected")
	assert_eq(str(result["error"]["code"]), "event.invalid")


func test_mod_namespaces() -> void:
	var own: Dictionary = bus.publish("mod.griddycode.one.tick", {"n": 1}, "griddycode.one")
	check(own.get("ok", false), "own namespace allowed")

	var reserved: Dictionary = bus.publish("document.saved", {}, "griddycode.one")
	check(!reserved.get("ok", false), "reserved event refused to mods")
	assert_eq(str(reserved["error"]["code"]), "event.forbidden")

	var other: Dictionary = bus.publish("mod.griddycode.two.tick", {}, "griddycode.one")
	check(!other.get("ok", false), "other namespace refused")
	assert_eq(str(other["error"]["code"]), "event.forbidden")

	var subscription: Dictionary = bus.subscribe("griddycode.one", "mod.griddycode.two.tick", 1)
	check(!subscription.get("ok", false), "cross-mod subscription refused")


func test_coalescing_last_wins() -> void:
	bus.subscribe("griddycode.one", "document.changed", 1)
	bus.publish("document.changed", {"length": 1})
	bus.publish("document.changed", {"length": 2})

	bus.tick(50.0)
	check(calls.is_empty(), "still inside the window")

	bus.tick(60.0)
	assert_eq(calls.size(), 1)
	assert_eq(calls[0]["payload"]["length"], 2)


func test_queue_cap_and_drop_report() -> void:
	bus.subscribe("griddycode.one", "document.saved", 1)
	for index in range(300):
		bus.publish("document.saved", {"index": index})

	assert_eq(bus.queue_depth("griddycode.one"), 256)
	assert_eq(bus.dropped_count("griddycode.one"), 44)

	bus.tick(0.0)
	check(calls.size() > 0, "queued events dispatch")
	check(calls[0]["payload"]["index"] > 0, "oldest events were dropped first")


func test_priority_then_registration_order() -> void:
	bus.subscribe("griddycode.one", "document.saved", 10, 0)
	bus.subscribe("griddycode.one", "document.saved", 20, -1)
	bus.publish("document.saved", {})

	bus.tick(0.0)
	assert_eq(calls.size(), 2)
	assert_eq(calls[0]["handle"], 20)
	assert_eq(calls[1]["handle"], 10)


func test_unsubscribe_clears_pending() -> void:
	var subscription: Dictionary = bus.subscribe("griddycode.one", "document.changed", 1)
	bus.publish("document.changed", {"length": 1})
	bus.unsubscribe(int(subscription["value"]))
	bus.tick(200.0)

	check(calls.is_empty(), "coalesced delivery was removed")
	assert_eq(bus.subscription_count("griddycode.one"), 0)


func test_payload_validation() -> void:
	bus.subscribe("griddycode.one", "document.saved", 1)
	check(!bus.publish("document.saved", "text").get("ok", false), "non-object payload rejected")
	check(!bus.publish("document.saved", {"callable": Callable()}).get("ok", false), "non-JSON payload rejected")

	var huge := {}
	huge["text"] = "x".repeat(20 * 1024)
	check(!bus.publish("document.saved", huge).get("ok", false), "oversized payload rejected")


func test_unsubscribe_all() -> void:
	bus.subscribe("griddycode.one", "document.saved", 1)
	bus.subscribe("griddycode.one", "document.closed", 2)
	bus.subscribe("griddycode.two", "document.saved", 3)
	bus.unsubscribe_all("griddycode.one")

	assert_eq(bus.subscription_count("griddycode.one"), 0)
	assert_eq(bus.subscription_count("griddycode.two"), 1)
