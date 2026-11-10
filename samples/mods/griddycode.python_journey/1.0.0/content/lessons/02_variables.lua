-- Variables hold values so a program can reuse them. The freeform phase adds a
-- second value and prints both, so the saved program produces "Ada is 36".

return {
	id = "02_variables",
	number = 2,
	title = "Variables",
	summary = "A name stores a value, and print() can show the value later.",
	coach = "An assignment puts the value on the right into the name on the left.",
	file = "python_journey/02_variables.py",
	starter = "",
	exercise = {
		title = "Name and age",
		prompt = "Type the assignment, then add age = 36 and two print lines.",
		typing = {
			target = "name = \"Ada\"\n",
			display = { scope = "line", chars = 64 },
			marks = {
				{ id = "name", text = "name" },
				{ id = "value", text = "\"Ada\"" },
			},
			hints = {
				{ on = "start", text = "Type the assignment exactly. The equals sign is not a comparison here." },
				{ on = "mark", mark = "name", text = "name is the label you choose. It is not text, so it has no quotes." },
				{ on = "mark", mark = "value", text = "Ada is text, so it stays inside quotes." },
				{ on = "mistake", mistake = 2, text = "Check the equals sign and both pairs of quotes." },
				{ on = "complete", text = "The name now holds Ada. Reuse it in the printed greeting." },
			},
		},
		freeform = {
			prompt = "Add age = 36, then print(\"Hello, \" + name) and print(name, \"is\", age).",
			example = "name = \"Ada\"\nage = 36\nprint(\"Hello, \" + name)\nprint(name, \"is\", age)\n",
			hint = "Put age on its own line. The two print calls use the variables instead of repeating their values.",
			run = {
				timeout_ms = 15000,
				tests = {
					{ name = "greeting", type = "stdout_contains", value = "Hello, Ada" },
					{ name = "age", type = "stdout_contains", value = "Ada is 36" },
					{ name = "clean exit", type = "exit_code", value = 0 },
				},
			},
			text = {
				tests = {
					{ name = "age assignment", type = "regex", value = "age\\s*=\\s*36" },
					{ name = "greeting", type = "contains", value = "print(" },
					{ name = "name reuse", type = "contains", value = "name" },
				},
			},
		},
	},
}
