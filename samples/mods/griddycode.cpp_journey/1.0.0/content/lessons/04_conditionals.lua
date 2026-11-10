return {
  id = "04_conditionals",
  number = 4,
  title = "Conditionals",
  summary = "Branch with if",
  coach = "Practice conditionals in C++ Learning Journey.",
  file = "cpp_journey/04_conditionals.cpp",
  exercise = {
    typing = {
      target = "#include <iostream>\nint main() {\n    int score = 75;\n    if (score >= 60) {\n        std::cout << \"pass\" << std::endl;\n    }\n    return 0;\n}\n",
      marks = {
        {
          id = "core",
          text = "#include <iostream>\nint main() {\n    int score = 75;\n    if (score >= 60) {\n        std::cout << \"pass\" << std::endl;\n    }\n    return 0;\n}\n",
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
      prompt = "Complete conditionals and run it.",
      hint = "Use the example as a guide.",
      example = "#include <iostream>\nint main() {\n    int score = 75;\n    if (score >= 60) {\n        std::cout << \"pass\" << std::endl;\n    }\n    return 0;\n}\n",
      run = {
        tests = {
          {
            name = "stdout",
            type = "stdout_contains",
            value = "pass",
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
            value = "pass",
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
