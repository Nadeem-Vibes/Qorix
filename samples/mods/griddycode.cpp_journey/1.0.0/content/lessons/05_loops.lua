return {
  id = "05_loops",
  number = 5,
  title = "Loops",
  summary = "Repeat with loops",
  coach = "Practice loops in C++ Learning Journey.",
  file = "cpp_journey/05_loops.cpp",
  exercise = {
    typing = {
      target = "#include <iostream>\nint main() {\n    for (int i = 1; i <= 5; ++i) {\n        std::cout << i << \" \";\n    }\n    std::cout << std::endl;\n    return 0;\n}\n",
      marks = {
        {
          id = "core",
          text = "#include <iostream>\nint main() {\n    for (int i = 1; i <= 5; ++i) {\n        std::cout << i << \" \";\n    }\n    std::cout << std::endl;\n    return 0;\n}\n",
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
      prompt = "Complete loops and run it.",
      hint = "Use the example as a guide.",
      example = "#include <iostream>\nint main() {\n    for (int i = 1; i <= 5; ++i) {\n        std::cout << i << \" \";\n    }\n    std::cout << std::endl;\n    return 0;\n}\n",
      run = {
        tests = {
          {
            name = "stdout",
            type = "stdout_contains",
            value = "1 2 3 4 5",
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
            value = "1",
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
