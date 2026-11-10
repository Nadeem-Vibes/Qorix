-- Loops repeat work. The typing phase prints numbers; the freeform phase prints
-- their squares, so the run check can compare the whole output sequence.

return {
	id = "05_loops",
	number = 5,
	title = "Loops",
	summary = "for repeats a block once for every value in a range.",
	coach = "range(1, 6) produces 1, 2, 3, 4 and 5. The stop value is not included.",
	file = "python_journey/05_loops.py",
	starter = "",
	exercise = {
		title = "Square numbers",
		prompt = "Type the loop, then change print(number) to print(number * number).",
		typing = {
			target = "for number in range(1, 6):\n    print(number)\n",
			display = { scope = "line", chars = 64 },
			marks = {
				{ id = "range", text = "range(1, 6)" },
				{ id = "body", text = "    print(number)" },
			},
			hints = {
				{ on = "start", text = "The print line inside the loop is indented by four spaces." },
				{ on = "mark", mark = "range", text = "range(1, 6) stops before 6, so the loop runs five times." },
				{ on = "mark", mark = "body", text = "number takes each value in turn." },
				{ on = "mistake", mistake = 2, text = "Check the colon after the range and the four spaces before print." },
				{ on = "complete", text = "The loop works. Now make it print squares instead." },
			},
		},
		freeform = {
			prompt = "Change the body to print(number * number). Keep the same range.",
			example = "for number in range(1, 6):\n    print(number * number)\n",
			hint = "Multiply number by itself inside print(). The indentation stays the same.",
			run = {
				timeout_ms = 15000,
				tests = {
					{ name = "squares", type = "stdout_regex", value = "(?m)^1\\s+4\\s+9\\s+16\\s+25\\s*$" },
					{ name = "clean exit", type = "exit_code", value = 0 },
				},
			},
			text = {
				tests = {
					{ name = "range", type = "contains", value = "range(1, 6)" },
					{ name = "square print", type = "regex", value = "print\\(\\s*number\\s*\\*\\s*number\\s*\\)" },
				},
			},
		},
	},
}
