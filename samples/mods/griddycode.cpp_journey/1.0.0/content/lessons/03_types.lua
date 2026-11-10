return {
  id = "03_types",
  number = 3,
  title = "Types",
  summary = "Inspect core C++ types",
  coach = "Practice types in C++ Learning Journey.",
  file = "cpp_journey/03_types.cpp",
  exercise = {
    typing = {
      target = "#include <iostream>\n#include <string>\nint main() {\n    int count = 3;\n    double price = 4.5;\n    char grade = 'A';\n    bool ready = true;\n    std::string label = \"ok\";\n    std::cout << count << \" \" << price << \" \" << grade << \" \" << ready << \" \" << label << std::endl;\n    return 0;\n}\n",
      marks = {
        {
          id = "core",
          text = "#include <iostream>\n#include <string>\nint main() {\n    int count = 3;\n    double price = 4.5;\n    char grade = 'A';\n    bool ready = true;\n    std::string label = \"ok\";\n    std::cout << count << \" \" << price << \" \" << grade << \" \" << ready << \" \" << label << std::endl;\n    return 0;\n}\n",
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
      prompt = "Complete types and run it.",
      hint = "Use the example as a guide.",
      example = "#include <iostream>\n#include <string>\nint main() {\n    int count = 3;\n    double price = 4.5;\n    char grade = 'A';\n    bool ready = true;\n    std::string label = \"ok\";\n    std::cout << count << \" \" << price << \" \" << grade << \" \" << std::boolalpha << ready << \" \" << label << std::endl;\n    return 0;\n}\n",
      run = {
        tests = {
          {
            name = "stdout",
            type = "stdout_contains",
            value = "ok",
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
            value = "ok",
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
