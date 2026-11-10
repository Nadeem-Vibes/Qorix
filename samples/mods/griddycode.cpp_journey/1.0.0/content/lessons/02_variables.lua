-- Lesson 2: a variable names a value, and its type is written before the name.
-- The freeform phase changes the value after initialization and prints it.

return {
	id = "02_variables",
	number = 2,
	title = "Variables",
	summary = "A C++ variable has a type, a name and a value.",
	coach = "std::string holds text; int holds whole numbers. The type comes first.",
	file = "cpp_journey/02_variables.cpp",
	starter = "",
	exercise = {
		title = "Name and age",
		prompt = "Type the variables, then change age and print both values.",
		typing = {
			target = "#include <iostream>\n#include <string>\n\nint main() {\n    std::string name = \"Ada\";\n    int age = 36;\n    std::cout << \"Hello, \" << name << \"\\n\";\n    return 0;\n}\n",
			display = { scope = "line", chars = 80 },
			marks = {
				{ id = "string", text = "std::string name = \"Ada\";" },
				{ id = "int", text = "int age = 36;" },
				{ id = "output", text = "    std::cout << \"Hello, \" << name << \"\\n\";" },
			},
			hints = {
				{ on = "start", text = "Two includes are needed because the program uses text and streams." },
				{ on = "mark", mark = "string", text = "std::string is the text type. Ada stays in quotes." },
				{ on = "mark", mark = "int", text = "36 has no quotes because it is a number." },
				{ on = "mark", mark = "output", text = "Chain << pieces together: text, then the variable, then a newline." },
				{ on = "mistake", mistake = 2, text = "Check the type before each name and the semicolon at the end." },
				{ on = "complete", text = "The greeting reuses the variable. Now update its value." },
			},
		},
		freeform = {
			prompt = "Change age to 37 after it is declared, then print name, is and age on one line.",
			example = "#include <iostream>\n#include <string>\n\nint main() {\n    std::string name = \"Ada\";\n    int age = 36;\n    age = 37;\n    std::cout << \"Hello, \" << name << \"\\n\";\n    std::cout << name << \" is \" << age << \"\\n\";\n    return 0;\n}\n",
			hint = "Assign age = 37; on its own line, then chain name, the text is, and age into std::cout.",
			run = {
				timeout_ms = 20000,
				tests = {
					{ name = "greeting", type = "stdout_contains", value = "Hello, Ada" },
					{ name = "updated age", type = "stdout_contains", value = "Ada is 37" },
					{ name = "clean exit", type = "exit_code", value = 0 },
				},
			},
			text = {
				tests = {
					{ name = "age assignment", type = "regex", value = "age\\s*=\\s*37\\s*;" },
					{ name = "string type", type = "contains", value = "std::string" },
					{ name = "output", type = "contains", value = "std::cout" },
				},
			},
		},
	},
}
