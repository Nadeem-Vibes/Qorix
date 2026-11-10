-- Lesson 3: C++ has several basic types. The typing phase declares one of each
-- and prints them; the freeform phase labels the output and formats a bool.

return {
	id = "03_types",
	number = 3,
	title = "Types",
	summary = "int, double, char, bool and std::string hold different kinds of values.",
	coach = "The type fixes what a variable can store: whole numbers, decimals, one character, true/false or text.",
	file = "cpp_journey/03_types.cpp",
	starter = "",
	exercise = {
		title = "Five kinds of value",
		prompt = "Type the declarations, then print a labelled line for each value.",
		typing = {
			target = "#include <iostream>\n#include <string>\n\nint main() {\n    int count = 3;\n    double price = 2.5;\n    char grade = 'A';\n    bool ready = true;\n    std::string label = \"coffee\";\n    std::cout << count << \" \" << price << \" \" << grade << \" \" << ready << \"\\n\";\n    return 0;\n}\n",
			display = { scope = "line", chars = 96 },
			marks = {
				{ id = "int", text = "int count = 3;" },
				{ id = "double", text = "double price = 2.5;" },
				{ id = "char", text = "char grade = 'A';" },
				{ id = "bool", text = "bool ready = true;" },
				{ id = "string", text = "std::string label = \"coffee\";" },
			},
			hints = {
				{ on = "start", text = "Five declarations, one per line. A char uses single quotes; text uses double quotes." },
				{ on = "mark", mark = "int", text = "int is a whole number." },
				{ on = "mark", mark = "double", text = "double allows a decimal point." },
				{ on = "mark", mark = "char", text = "char stores one character, so 'A' uses single quotes." },
				{ on = "mark", mark = "bool", text = "bool is true or false, with no quotes." },
				{ on = "mark", mark = "string", text = "std::string needs the string header and double quotes." },
				{ on = "mistake", mistake = 2, text = "Check the decimal point, the single quotes around A and the spelling of bool." },
				{ on = "complete", text = "The values are declared. Now label each one in the output." },
			},
		},
		freeform = {
			prompt = "Print count, price, grade, label and ready with labels. Use std::boolalpha so ready prints true.",
			example = "#include <iostream>\n#include <string>\n\nint main() {\n    int count = 3;\n    double price = 2.5;\n    char grade = 'A';\n    bool ready = true;\n    std::string label = \"coffee\";\n    std::cout << \"count: \" << count << \"\\n\";\n    std::cout << \"price: \" << price << \"\\n\";\n    std::cout << \"grade: \" << grade << \"\\n\";\n    std::cout << \"label: \" << label << \"\\n\";\n    std::cout << std::boolalpha << \"ready: \" << ready << \"\\n\";\n    return 0;\n}\n",
			hint = "One output line per value. std::boolalpha changes a bool from 1 to true.",
			run = {
				timeout_ms = 20000,
				tests = {
					{ name = "count", type = "stdout_contains", value = "count: 3" },
					{ name = "price", type = "stdout_contains", value = "price: 2.5" },
					{ name = "grade", type = "stdout_contains", value = "grade: A" },
					{ name = "label", type = "stdout_contains", value = "label: coffee" },
					{ name = "bool", type = "stdout_contains", value = "ready: true" },
					{ name = "clean exit", type = "exit_code", value = 0 },
				},
			},
			text = {
				tests = {
					{ name = "double type", type = "contains", value = "double price" },
					{ name = "bool type", type = "regex", value = "bool\\s+ready" },
					{ name = "boolalpha", type = "contains", value = "std::boolalpha" },
				},
			},
		},
	},
}
