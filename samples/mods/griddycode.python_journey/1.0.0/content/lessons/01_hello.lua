return {
  id = "01_hello",
  number = 1,
  title = "Hello",
  summary = "Write your first script",
  coach = "Practice hello in Python Learning Journey.",
  file = "python_journey/01_hello.py",
  exercise = {
    typing = {
      target = "print(\"Hello, Python!\\n\")\n",
      marks = {
        {
          id = "core",
          text = "print(\"Hello, Python!",
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
      example = "print(\"Hello, Python!\\n\")\n",
      run = {
        tests = {
          {
            name = "stdout",
            type = "stdout_contains",
            value = "Hello, Python!",
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
