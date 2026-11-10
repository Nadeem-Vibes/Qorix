-- Lesson content is data. The mod reads this table and hands pieces of it to
-- editor.guide and editor.exercise. A lesson has two phases: typing the target,
-- then a freeform edit that is checked by the saved program (or by text when a
-- trusted workspace is unavailable).

return {
	id = "01_hello",
	number = 1,
	title = "Hello, Qorix",
	summary = "Your first Python statement prints a line of text.",
	coach = "print() writes text to the screen. The text sits inside quotes.",
	file = "python_journey/01_hello.py",
	starter = "",
	exercise = {
		title = "Say hello",
		prompt = "Type the line, then add a second print for Python itself.",
		typing = {
			target = "print(\"Hello, Qorix!\")\n",
			display = { scope = "line", chars = 64 },
			marks = {
				{ id = "call", text = "print" },
				{ id = "message", text = "\"Hello, Qorix!\"" },
			},
			hints = {
				{ on = "start", text = "Type the line exactly. Ghost text shows the next character." },
				{ on = "mark", mark = "call", text = "print is a function: the parentheses hold its input." },
				{ on = "mark", mark = "message", text = "Quotes make this a string, not a variable." },
				{ on = "mistake", mistake = 2, text = "Check the quotes and the closing parenthesis." },
				{ on = "complete", text = "That is the whole program. Now add one more line." },
			},
		},
		freeform = {
			prompt = "Add a second line: print(\"Hello, Python!\")",
			example = "print(\"Hello, Qorix!\")\nprint(\"Hello, Python!\")\n",
			hint = "Keep the first line. Add another print with its own text.",
			run = {
				timeout_ms = 15000,
				tests = {
					{ name = "first line", type = "stdout_contains", value = "Hello, Qorix!" },
					{ name = "second line", type = "stdout_contains", value = "Hello, Python!" },
					{ name = "clean exit", type = "exit_code", value = 0 },
				},
			},
			text = {
				tests = {
					{ name = "first line", type = "contains", value = "print(\"Hello, Qorix!\")" },
					{ name = "second line", type = "regex", value = "print\\(['\"]Hello, Python!['\"]\\)" },
				},
			},
		},
	},
}
