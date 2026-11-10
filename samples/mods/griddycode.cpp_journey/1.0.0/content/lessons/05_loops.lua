-- Lesson 5: a for loop repeats a block. The typing phase prints the counter and
-- the freeform phase prints squares, so the output is a sequence to compare.

return {
	id = "05_loops",
	number = 5,
	title = "Loops",
	summary = "for repeats a block and advances a counter.",
	coach = "for (int i = 1; i <= 5; ++i) starts at 1, keeps going while i is at most 5, and increments after each pass.",
	file = "cpp_journey/05_loops.cpp",
	starter = "",
	exercise = {
		title = "Square numbers",
		prompt = "Type the loop, then change the output to print each square.",
		typing = {
			target = "#include <iostream>\n\nint main() {\n    for (int i = 1; i <= 5; ++i) {\n        std::cout << i << \" \";\n    }\n    std::cout << \"\\n\";\n    return 0;\n}\n",
			display = { scope = "line", chars = 80 },
			marks = {
				{ id = "header", text = "for (int i = 1; i <= 5; ++i) {" },
				{ id = "body", text = "        std::cout << i << \" \";" },
			},
			hints = {
				{ on = "start", text = "The loop header has three parts separated by semicolons: start, condition and step." },
				{ on = "mark", mark = "header", text = "++i adds one after each pass. <= includes 5, so the loop runs five times." },
				{ on = "mark", mark = "body", text = "The body is indented by four spaces inside the braces." },
				{ on = "mistake", mistake = 2, text = "Check the two semicolons in the loop header and the braces around the body." },
				{ on = "complete", text = "The loop prints 1 to 5. Now make it print squares." },
			},
		},
		freeform = {
			prompt = "Change the loop body to print i * i on its own line. Keep the same range.",
			example = "#include <iostream>\n\nint main() {\n    for (int i = 1; i <= 5; ++i) {\n        std::cout << i * i << \"\\n\";\n    }\n    return 0;\n}\n",
			hint = "Multiply i by itself inside the output statement. The loop header stays the same.",
			run = {
				timeout_ms = 20000,
				tests = {
					{ name = "squares", type = "stdout_regex", value = "(?s)^1\\s+4\\s+9\\s+16\\s+25\\s*$" },
					{ name = "clean exit", type = "exit_code", value = 0 },
				},
			},
			text = {
				tests = {
					{ name = "range", type = "contains", value = "i <= 5" },
					{ name = "square output", type = "regex", value = "std::cout\\s*<<\\s*i\\s*\\*\\s*i" },
				},
			},
		},
	},
}
