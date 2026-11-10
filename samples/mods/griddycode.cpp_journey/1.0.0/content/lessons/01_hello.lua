return {
  id = "01_hello",
  number = 1,
  title = "Hello",
  summary = "Write your first C++ program",
  coach = "Practice hello in C++ Learning Journey.",
  file = "cpp_journey/01_hello.cpp",
  exercise = {
    typing = {
      target = "#include <iostream>\nint main() {\n    std::cout << \"Hello, C++!\" << std::endl;\n    return 0;\n}\n",
      marks = {
        {
          id = "core",
          text = "#include <iostream>\nint main() {\n    std::cout << \"Hello, C++!\" << std::endl;\n    return 0;\n}\n",
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
      prompt = "Complete hello and run it.",
      hint = "Use the example as a guide.",
      example = "#include <iostream>\nint main() {\n    std::cout << \"Hello, C++!\" << std::endl;\n    return 0;\n}\n",
      run = {
        tests = {
          {
            name = "stdout",
            type = "stdout_contains",
            value = "Hello, C++!",
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
            value = "Hello,",
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
