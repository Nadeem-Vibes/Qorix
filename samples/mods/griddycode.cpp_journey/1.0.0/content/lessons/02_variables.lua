return {
  id = "02_variables",
  number = 2,
  title = "Variables",
  summary = "Store values",
  coach = "Practice variables in C++ Learning Journey.",
  file = "cpp_journey/02_variables.cpp",
  exercise = {
    typing = {
      target = "#include <iostream>\n#include <string>\nint main() {\n    std::string name = \"Ada\";\n    int age = 30;\n    std::cout << name << \" \" << age << std::endl;\n    return 0;\n}\n",
      marks = {
        {
          id = "core",
          text = "#include <iostream>\n#include <string>\nint main() {\n    std::string name = \"Ada\";\n    int age = 30;\n    std::cout << name << \" \" << age << std::endl;\n    return 0;\n}\n",
        },
      },
      hints = {
        {
          on = "start",
          text = "Start typing the starter file.",
        },
        {
          on = "mark",
          mark = "core",
          text = "Keep going.",
        },
        {
          on = "complete",
          text = "Typing complete.",
        },
      },
    },
    freeform = {
      prompt = "Complete variables and run it.",
      hint = "Use the example as a guide.",
      example = "#include <iostream>\n#include <string>\nint main() {\n    std::string name = \"Ada\";\n    int age = 30;\n    std::cout << name << \" \" << age << std::endl;\n    return 0;\n}\n",
      run = {
        tests = {
          {
            name = "stdout",
            type = "stdout_contains",
            value = "Ada 30",
          },
          {
            name = "exit",
            type = "exit_code",
            value = "0",
          },
        },
      },
      text = {
        tests = {
          {
            name = "contains",
            type = "contains",
            value = "Ada",
          },
        },
      },
      hints = {
        {
          on = "freeform",
          text = "Run the program and compare output.",
        },
      },
    },
  },
}
