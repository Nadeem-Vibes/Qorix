extends RefCounted

## Standalone native callables for E4/E6. It deliberately does not hold a
## reference to the Lua host, so pushing these into Lua cannot create a
## host -> Lua -> host reference cycle.

var calls: int = 0
var saved: Callable = Callable()


func echo(value: Variant) -> Variant:
	calls += 1
	return value


func echo_type(value: Variant) -> String:
	calls += 1
	return type_string(typeof(value))


func sleep_ms(milliseconds: int) -> int:
	calls += 1
	OS.delay_msec(milliseconds)
	return milliseconds


func invoke(payload: Dictionary) -> Variant:
	calls += 1
	if !saved.is_valid():
		return null
	return saved.call(payload.get("a", 0), payload.get("b", 0))
