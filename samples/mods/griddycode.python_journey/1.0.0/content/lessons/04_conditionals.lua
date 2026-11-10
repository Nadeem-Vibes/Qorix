return {
  id = "04_conditionals",
  number = 4,
  title = "Conditionals",
  summary = "Branch with if",
  coach = "Practice conditionals in Python Learning Journey.",
  file = "python_journey/04_conditionals.py",
  exercise = {
    typing = {
      target = "score = 75\nif score >= 60:\n    print(\"pass\")\n",
      marks = {
        {
          id = "core",
          text = "score = 75\nif score >= 60:\n    print(\"pass\")\n",
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
      example = "score = 75\nif score >= 60:\n    print(\"pass\")\n",
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
