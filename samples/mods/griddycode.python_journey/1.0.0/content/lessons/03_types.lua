return {
  id = "03_types",
  number = 3,
  title = "Types",
  summary = "Inspect types",
  coach = "Practice types in Python Learning Journey.",
  file = "python_journey/03_types.py",
  exercise = {
    typing = {
      target = "value = 3\nprint(type(value))\n",
      marks = {
        {
          id = "core",
          text = "value = 3\nprint(type(value))\n",
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
      example = "value = 3\nprint(type(value))\n",
      run = {
        tests = {
          {
            name = "stdout",
            type = "stdout_contains",
            value = "int",
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
            value = "int",
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
