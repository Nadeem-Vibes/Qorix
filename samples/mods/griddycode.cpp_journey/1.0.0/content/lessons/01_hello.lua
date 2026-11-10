-- Lesson 1: a C++ program needs a header for input/output, a main function and
-- a return value. The typing phase builds the smallest complete program; the
-- freeform phase adds a second stream insertion.

return {
	id = "01_hello",
	number = 1,
	title = "Hello, C++",
	summary = "A C++ program starts at main and writes through std::cout.",
	coach = "#include <iostream> brings in the stream tools. Every statement ends with a semicolon.",
	file = "cpp_journey/01_hello.cpp",
	starter = "",
	exercise = {
		title = "Say hello",
		prompt = "Type the complete program, then add a second output line.",
		typing = {
			target = "#include <iostream>\n\nint main() {\n    std::cout << \"Hello, Qorix!\" << std::endl;\n    return 0;\n}\n",
			display = { scope = "line", chars = 80 },
			marks = {
				{ id = "include", text = "#include <iostream>" },
				{ id = "main", text = "int main() {" },
				{ id = "output", text = "    std::cout << \"Hello, Qorix!\" << std::endl;" },
			},
			hints = {
				{ on = "start", text = "Type the program exactly. The blank line after the include is part of the target." },
				{ on = "mark", mark = "include", text = "The include line begins with # and has no semicolon." },
				{ on = "mark", mark = "main", text = "Execution starts at main. The braces open and close the function body." },
				{ on = "mark", mark = "output", text = "std::cout is the output stream. << sends text into it." },
				{ on = "mistake", mistake = 2, text = "Check the angle brackets, the quotes and the semicolon." },
				{ on = "complete", text = "That is a complete C++ program. Now add one more line." },
			},
		},
		freeform = {
			prompt = "Add a second line that prints Hello, C++! and keep the program compiling.",
			example = "#include <iostream>\n\nint main() {\n    std::cout << \"Hello, Qorix!\" << \"\\n\";\n    std::cout << \"Hello, C++!\" << \"\\n\";\n    return 0;\n}\n",
			hint = "Add another std::cout statement before return. Each statement needs its own semicolon.",
			run = {
				timeout_ms = 20000,
				tests = {
					{ name = "first line", type = "stdout_contains", value = "Hello, Qorix!" },
					{ name = "second line", type = "stdout_contains", value = "Hello, C++!" },
					{ name = "clean exit", type = "exit_code", value = 0 },
				},
			},
			text = {
				tests = {
					{ name = "include", type = "contains", value = "#include <iostream>" },
					{ name = "second line", type = "regex", value = "std::cout\\s*<<\\s*\"Hello, C\\+\\+!\"" },
					{ name = "return", type = "contains", value = "return 0;" },
				},
			},
		},
	},
}
