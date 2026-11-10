return {
  id = "05_loops",
  number = 5,
  title = "Loops",
  summary = "Repeat with loops",
  coach = "Practice loops in Python Learning Journey.",
  file = "python_journey/05_loops.py",
  exercise = {
    typing = {
      target = "for i in range(1, 6):\n    print(i)\n",
      marks = {
        {
          id = "core",
          text = "for i in range(1, 6):\n    print(i)\n",
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
      example = "for i in range(1, 6):\n    print(i)\n",
      run = {
        tests = {
          {
            name = "stdout",
            type = "stdout_contains",
            value = "5",
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
            value = "5",
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
