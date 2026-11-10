extends RefCounted

## Typed, coalesced event bus with per-mod isolation.
##
## Mods never call each other. A mod emits only `mod.<its own id>.*`; the host
## emits the reserved catalogue events. Every delivery is a task in the target
## mod's own Lua state, so one handler blowing its budget cannot stop the others.
##
## `tick()` drives coalescing and dispatch. The composition root ticks it once per
## frame; tests tick it explicitly, which keeps timing deterministic.

signal delivery_failed(mod_id: String, event_name: String, result: Dictionary)
signal queue_dropped(mod_id: String, event_name: String)

const Result = preload("res://src/features/mods/mod_result.gd")
const Json = preload("res://src/features/mods/mod_json.gd")

const MAX_QUEUE := 256
const MAX_DISPATCH_PER_TICK := 128
const DISPATCH_BUDGET_USEC := 2000
const MAX_PAYLOAD_BYTES := 16 * 1024
const MAX_EVENT_NAME_LENGTH := 128

## event name -> {coalesce_ms}. Presence in this table means "host event";
## anything else must be namespaced `mod.<id>.`.
const CATALOGUE := {
	"app.ready": {"coalesce_ms": 0},
	"app.quitting": {"coalesce_ms": 0},
	"app.mods_ready": {"coalesce_ms": 0},
	"workspace.opened": {"coalesce_ms": 0},
	"workspace.closed": {"coalesce_ms": 0},
	"document.opened": {"coalesce_ms": 0},
	"document.closed": {"coalesce_ms": 0},
	"document.saved": {"coalesce_ms": 0},
	"document.activated": {"coalesce_ms": 0},
	"document.dirty_changed": {"coalesce_ms": 0},
	"document.changed": {"coalesce_ms": 100},
	"editor.caret_moved": {"coalesce_ms": 100},
	"editor.selection_changed": {"coalesce_ms": 100},
	"command.executed": {"coalesce_ms": 0},
	"theme.changed": {"coalesce_ms": 0},
	"settings.changed": {"coalesce_ms": 0},
	"run.started": {"coalesce_ms": 0},
	"run.output": {"coalesce_ms": 100},
	"run.finished": {"coalesce_ms": 0},
	"run.blocked": {"coalesce_ms": 0},
	"terminal.opened": {"coalesce_ms": 0},
	"terminal.closed": {"coalesce_ms": 0},
	"exercise.started": {"coalesce_ms": 0},
	"exercise.phase_changed": {"coalesce_ms": 0},
	"exercise.submitted": {"coalesce_ms": 0},
	"exercise.completed": {"coalesce_ms": 0},
	"exercise.failed": {"coalesce_ms": 0},
	"exercise.stopped": {"coalesce_ms": 0},
	"guide.started": {"coalesce_ms": 0},
	"guide.progress": {"coalesce_ms": 150},
	"guide.segment": {"coalesce_ms": 0},
	"guide.mistake": {"coalesce_ms": 500},
	"guide.diverged": {"coalesce_ms": 0},
	"guide.validated": {"coalesce_ms": 0},
	"guide.completed": {"coalesce_ms": 0},
	"guide.stopped": {"coalesce_ms": 0},
	"mod.activated": {"coalesce_ms": 0},
	"mod.deactivated": {"coalesce_ms": 0},
	"mod.failed": {"coalesce_ms": 0},
}

## subscription id -> {id, mod_id, name, handle, priority, seq}
var _subscriptions: Dictionary = {}
var _by_name: Dictionary = {}
var _queues: Dictionary = {}
var _coalesced: Dictionary = {}
var _dropped: Dictionary = {}
var _next_id: int = 0
var _cursor: int = 0
var _clock_ms: float = 0.0
var _dispatch: Callable = Callable()


func set_dispatch(callable: Callable) -> void:
	_dispatch = callable


func subscribe(mod_id: String, name: String, handle: int, priority: int = 0) -> Dictionary:
	var event_name := str(name)
	if !is_subscribable(event_name, mod_id):
		return Result.error(
			"event.invalid",
			"'%s' is not a host event or one of this mod's own events." % event_name,
		)
	if int(handle) <= 0:
		return Result.error("event.invalid", "A subscription needs a positive handler id.")

	_next_id += 1
	var subscription := {
		"id": _next_id,
		"mod_id": str(mod_id),
		"name": event_name,
		"handle": int(handle),
		"priority": int(priority),
		"seq": _next_id,
	}
	_subscriptions[_next_id] = subscription

	if !_by_name.has(event_name):
		_by_name[event_name] = []
	_by_name[event_name].append(_next_id)
	(_by_name[event_name] as Array).sort_custom(Callable(self, "_sorts_before"))

	return Result.ok(_next_id)


func unsubscribe(subscription_id: int) -> Dictionary:
	var id := int(subscription_id)
	if !_subscriptions.has(id):
		return Result.ok(false)

	var subscription: Dictionary = _subscriptions[id]
	_subscriptions.erase(id)

	var name := str(subscription.get("name", ""))
	if _by_name.has(name):
		(_by_name[name] as Array).erase(id)
		if (_by_name[name] as Array).is_empty():
			_by_name.erase(name)

	_coalesced.erase(id)

	var mod_id := str(subscription.get("mod_id", ""))
	if _queues.has(mod_id):
		var queue: Array = _queues[mod_id]
		var kept: Array = []
		for delivery in queue:
			if int(delivery.get("sub_id", -1)) != id:
				kept.append(delivery)
		_queues[mod_id] = kept

	return Result.ok(true)


func unsubscribe_all(mod_id: String) -> void:
	var id := str(mod_id)
	var remove: Array = []
	for subscription_id in _subscriptions.keys():
		if str((_subscriptions[subscription_id] as Dictionary).get("mod_id", "")) == id:
			remove.append(subscription_id)
	for subscription_id in remove:
		unsubscribe(int(subscription_id))
	_queues.erase(id)
	_dropped.erase(id)


## Host events plus the mod's own `mod.<id>.*` namespace. Cross-mod event flow is
## deliberately not part of v1.
func is_subscribable(name: String, mod_id: String) -> bool:
	if CATALOGUE.has(str(name)):
		return true
	return is_mod_event(str(name), str(mod_id))


func is_reserved(name: String) -> bool:
	return CATALOGUE.has(str(name))


func is_mod_event(name: String, mod_id: String) -> bool:
	var prefix := "mod." + str(mod_id) + "."
	return str(name).begins_with(prefix) and str(name).length() > prefix.length()


## Publishes an event. Host callers leave `source_mod_id` empty; mod callers pass
## their id so only their namespace is writable.
func publish(name: String, payload: Variant = null, source_mod_id: String = "") -> Dictionary:
	var event_name := str(name)
	if event_name.is_empty() or event_name.length() > MAX_EVENT_NAME_LENGTH:
		return Result.error("event.invalid", "Event names are 1-%d characters." % MAX_EVENT_NAME_LENGTH)

	var from_mod := !str(source_mod_id).is_empty()
	if is_reserved(event_name):
		if from_mod:
			return Result.error("event.forbidden", "'%s' is a host event and cannot be emitted by a mod." % event_name)
	elif from_mod:
		if !is_mod_event(event_name, source_mod_id):
			return Result.error(
				"event.forbidden",
				"Mods may only emit events under 'mod.%s.'." % source_mod_id,
			)
	else:
		return Result.error("event.invalid", "'%s' is not a known event." % event_name)

	var value: Variant = {} if payload == null else payload
	if !(value is Dictionary):
		return Result.error("event.invalid", "Event payloads must be objects.")
	if !Json.is_value(value, 0):
		return Result.error("event.invalid", "Event payloads must be JSON-serializable.")
	var size := Json.size_bytes(value)
	if size > MAX_PAYLOAD_BYTES:
		return Result.error(
			"event.invalid",
			"The payload is %d bytes; the limit is %d." % [size, MAX_PAYLOAD_BYTES],
		)

	var window := int(CATALOGUE.get(event_name, {}).get("coalesce_ms", 0))
	var queued := 0
	var coalesced := 0

	for subscription_id in _by_name.get(event_name, []):
		if !_subscriptions.has(subscription_id):
			continue
		if window > 0:
			_coalesced[int(subscription_id)] = {
				"sub_id": int(subscription_id),
				"payload": (value as Dictionary).duplicate(true),
				"due": _clock_ms + float(window),
			}
			coalesced += 1
		else:
			_enqueue(int(subscription_id), value)
			queued += 1

	return Result.ok({"queued": queued, "coalesced": coalesced})


func tick(delta_ms: float) -> void:
	_clock_ms += maxf(0.0, delta_ms)

	var due: Array = []
	for subscription_id in _coalesced.keys():
		if float((_coalesced[subscription_id] as Dictionary).get("due", 0.0)) <= _clock_ms:
			due.append(subscription_id)
	due.sort()
	for subscription_id in due:
		var pending: Dictionary = _coalesced[subscription_id]
		_coalesced.erase(subscription_id)
		_enqueue(int(pending.get("sub_id", 0)), pending.get("payload", {}))

	if !_dispatch.is_valid():
		return

	var started := Time.get_ticks_usec()
	var processed := 0
	while processed < MAX_DISPATCH_PER_TICK:
		var available: Array = []
		for mod_id in _queues.keys():
			if !(_queues[mod_id] as Array).is_empty():
				available.append(mod_id)
		if available.is_empty():
			return
		available.sort()

		var index := _cursor % available.size()
		var mod_id := str(available[index])
		var queue: Array = _queues[mod_id]
		var delivery: Dictionary = queue.pop_front()
		_cursor = (index + 1) % available.size()
		processed += 1

		_deliver(delivery)

		if Time.get_ticks_usec() - started >= DISPATCH_BUDGET_USEC:
			return


func _deliver(delivery: Dictionary) -> void:
	if !_dispatch.is_valid():
		return

	var mod_id := str(delivery.get("mod_id", ""))
	var result: Variant = _dispatch.call(mod_id, int(delivery.get("handle", 0)), delivery.get("payload", {}))
	if result is Dictionary and !bool((result as Dictionary).get("ok", false)):
		delivery_failed.emit(mod_id, str(delivery.get("name", "")), result)


func _enqueue(subscription_id: int, payload: Variant) -> void:
	if !_subscriptions.has(subscription_id):
		return

	var subscription: Dictionary = _subscriptions[subscription_id]
	var mod_id := str(subscription.get("mod_id", ""))
	if !_queues.has(mod_id):
		_queues[mod_id] = []

	var queue: Array = _queues[mod_id]
	queue.append({
		"sub_id": subscription_id,
		"mod_id": mod_id,
		"name": str(subscription.get("name", "")),
		"handle": int(subscription.get("handle", 0)),
		"payload": (payload as Dictionary).duplicate(true) if payload is Dictionary else {},
	})

	while queue.size() > MAX_QUEUE:
		queue.pop_front()
		_dropped[mod_id] = int(_dropped.get(mod_id, 0)) + 1
		queue_dropped.emit(mod_id, str(subscription.get("name", "")))


func _sorts_before(a: Variant, b: Variant) -> bool:
	var left: Dictionary = _subscriptions.get(int(a), {})
	var right: Dictionary = _subscriptions.get(int(b), {})
	var left_priority := int(left.get("priority", 0))
	var right_priority := int(right.get("priority", 0))
	if left_priority != right_priority:
		return left_priority < right_priority
	return int(left.get("seq", 0)) < int(right.get("seq", 0))


# ── INTROSPECTION (tests, diagnostics UI) ───────────────────────────────────

func queue_depth(mod_id: String) -> int:
	var queue: Variant = _queues.get(str(mod_id))
	return (queue as Array).size() if queue is Array else 0


func coalesced_count(mod_id: String = "") -> int:
	if str(mod_id).is_empty():
		return _coalesced.size()
	var count := 0
	for subscription_id in _coalesced.keys():
		var subscription: Dictionary = _subscriptions.get(int(subscription_id), {})
		if str(subscription.get("mod_id", "")) == str(mod_id):
			count += 1
	return count


func dropped_count(mod_id: String) -> int:
	return int(_dropped.get(str(mod_id), 0))


func subscription_count(mod_id: String = "") -> int:
	if str(mod_id).is_empty():
		return _subscriptions.size()
	var count := 0
	for subscription in _subscriptions.values():
		if str((subscription as Dictionary).get("mod_id", "")) == str(mod_id):
			count += 1
	return count


func subscriptions_for(mod_id: String) -> Array:
	var out: Array = []
	for subscription in _subscriptions.values():
		if str((subscription as Dictionary).get("mod_id", "")) == str(mod_id):
			out.append((subscription as Dictionary).duplicate(true))
	return out


func clear() -> void:
	_subscriptions.clear()
	_by_name.clear()
	_queues.clear()
	_coalesced.clear()
	_dropped.clear()
	_dispatch = Callable()
	_next_id = 0
	_cursor = 0
	_clock_ms = 0.0
