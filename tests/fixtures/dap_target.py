"""Qorix DAP end-to-end target; line numbers are pinned by tests/dap_e2e_runner.gd."""

from dap_helper import add as helper_add


def add(a, b):
    """Add two numbers."""
    total = a + b
    return total


def main():
    base = 2
    step = 3
    value = add(base, step)
    print(f"value={value}")
    helper_add(step, 5)
    for index in range(3):
        value += index
    print(f"done={value}")


if __name__ == "__main__":
    main()
