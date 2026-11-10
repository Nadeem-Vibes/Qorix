-- Conditionals choose a branch. The typing phase builds the if branch; the
-- freeform phase adds else and changes the score so the other branch runs.

return {
	id = "04_conditionals",
	number = 4,
	title = "Conditionals",
	summary = "if and else let a program choose which lines run.",
	coach = "Python runs the indented block under if only when the condition is true.",
	file = "python_journey/04_conditionals.py",
	starter = "",
	exercise = {
		title = "Pass or retry",
		prompt = "Type the if branch, then change score to 40 and add the else branch.",
		typing = {
			target = "score = 75\nif score >= 60:\n    print(\"pass\")\n",
			display = { scope = "line", chars = 72 },
			marks = {
				{ id = "condition", text = "score >= 60" },
				{ id = "indent", text = "    print(\"pass\")" },
			},
			hints = {
				{ on = "start", text = "The print line is indented by four spaces. Keep them." },
				{ on = "mark", mark = "condition", text = ">= means greater than or equal to. 75 satisfies it." },
				{ on = "mark", mark = "indent", text = "The indented line belongs to the if block." },
				{ on = "mistake", mistake = 2, text = "Check the colon at the end of the if line and the four spaces before print." },
				{ on = "complete", text = "The if branch works. Now make the other branch run." },
			},
		},
		freeform = {
			prompt = "Change score to 40. Add else: and print(\"retry\") with the same indentation.",
			example = "score = 40\nif score >= 60:\n    print(\"pass\")\nelse:\n    print(\"retry\")\n",
			hint = "else sits at the same level as if. Its print line is indented by four spaces.",
			run = {
				timeout_ms = 15000,
				tests = {
					{ name = "retry branch", type = "stdout_contains", value = "retry" },
					{ name = "pass branch is not taken", type = "stdout_regex", value = "(?s)^(?!.*pass).*retry" },
					{ name = "clean exit", type = "exit_code", value = 0 },
				},
			},
			text = {
				tests = {
					{ name = "new score", type = "regex", value = "score\\s*=\\s*40" },
					{ name = "else branch", type = "contains", value = "else:" },
					{ name = "retry print", type = "regex", value = "print\\(['\"]retry['\"]\\)" },
				},
			},
		},
	},
}
