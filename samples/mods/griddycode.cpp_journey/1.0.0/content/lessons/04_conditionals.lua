-- Lesson 4: if and else choose a branch. Braces define each block, and the
-- freeform phase changes the score so the other branch runs.

return {
	id = "04_conditionals",
	number = 4,
	title = "Conditionals",
	summary = "if and else choose which block of code runs.",
	coach = "C++ runs the block under if only when the condition is true. Braces keep each branch together.",
	file = "cpp_journey/04_conditionals.cpp",
	starter = "",
	exercise = {
		title = "Pass or retry",
		prompt = "Type the if branch, then change the score and add the else branch.",
		typing = {
			target = "#include <iostream>\n\nint main() {\n    int score = 75;\n    if (score >= 60) {\n        std::cout << \"pass\\n\";\n    }\n    return 0;\n}\n",
			display = { scope = "line", chars = 80 },
			marks = {
				{ id = "condition", text = "if (score >= 60) {" },
				{ id = "body", text = "        std::cout << \"pass\\n\";" },
			},
			hints = {
				{ on = "start", text = "The condition stays inside parentheses. The body is indented by four spaces." },
				{ on = "mark", mark = "condition", text = ">= means greater than or equal to. 75 satisfies it." },
				{ on = "mark", mark = "body", text = "The output line is inside the braces, so it belongs to if." },
				{ on = "mistake", mistake = 2, text = "Check the parentheses, both braces and the semicolon in the body." },
				{ on = "complete", text = "The if branch compiles. Now make the other branch run." },
			},
		},
		freeform = {
			prompt = "Change score to 40 and add an else branch that prints retry.",
			example = "#include <iostream>\n\nint main() {\n    int score = 40;\n    if (score >= 60) {\n        std::cout << \"pass\\n\";\n    } else {\n        std::cout << \"retry\\n\";\n    }\n    return 0;\n}\n",
			hint = "else goes after the closing brace of if. It has its own braces and body.",
			run = {
				timeout_ms = 20000,
				tests = {
					{ name = "retry branch", type = "stdout_contains", value = "retry" },
					{ name = "pass branch is not taken", type = "stdout_regex", value = "(?s)^(?!.*pass).*retry" },
					{ name = "clean exit", type = "exit_code", value = 0 },
				},
			},
			text = {
				tests = {
					{ name = "new score", type = "regex", value = "score\\s*=\\s*40\\s*;" },
					{ name = "else branch", type = "contains", value = "else {" },
					{ name = "retry print", type = "regex", value = "std::cout\\s*<<\\s*\"retry\\\\n\"" },
				},
			},
		},
	},
}
