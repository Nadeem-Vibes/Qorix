-- Python values have types. The freeform phase asks type() to report them, and
-- the run check looks for the exact class names Python prints.

return {
	id = "03_types",
	number = 3,
	title = "Types",
	summary = "Numbers and text are different types, and type() names them.",
	coach = "type(value) returns the kind of value: int, float or str.",
	file = "python_journey/03_types.py",
	starter = "",
	exercise = {
		title = "Ask for the type",
		prompt = "Type the three values, then print type(count), type(price) and type(label).",
		typing = {
			target = "count = 3\nprice = 2.5\nlabel = \"coffee\"\n",
			display = { scope = "line", chars = 64 },
			marks = {
				{ id = "int", text = "3" },
				{ id = "float", text = "2.5" },
				{ id = "str", text = "\"coffee\"" },
			},
			hints = {
				{ on = "start", text = "Three lines, one value each. Decimals use a dot, not a comma." },
				{ on = "mark", mark = "int", text = "3 has no decimal point, so Python stores it as an int." },
				{ on = "mark", mark = "float", text = "2.5 has a decimal point, so Python stores it as a float." },
				{ on = "mark", mark = "str", text = "Text in quotes is a str." },
				{ on = "mistake", mistake = 2, text = "Check the decimal point and the quotes around coffee." },
				{ on = "complete", text = "Now ask Python to report each type." },
			},
		},
		freeform = {
			prompt = "Print type(count), type(price) and type(label), one per line.",
			example = "count = 3\nprice = 2.5\nlabel = \"coffee\"\nprint(type(count))\nprint(type(price))\nprint(type(label))\n",
			hint = "Put each value inside type(), then give each result its own print line.",
			run = {
				timeout_ms = 15000,
				tests = {
					{ name = "int type", type = "stdout_contains", value = "<class 'int'>" },
					{ name = "float type", type = "stdout_contains", value = "<class 'float'>" },
					{ name = "str type", type = "stdout_contains", value = "<class 'str'>" },
					{ name = "clean exit", type = "exit_code", value = 0 },
				},
			},
			text = {
				tests = {
					{ name = "count type", type = "contains", value = "type(count)" },
					{ name = "price type", type = "contains", value = "type(price)" },
					{ name = "label type", type = "contains", value = "type(label)" },
				},
			},
		},
	},
}
