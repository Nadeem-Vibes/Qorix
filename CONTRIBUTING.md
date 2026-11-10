# Contributing to Qorix

Thanks for helping improve Qorix. The project is a Godot 4.7 desktop code
editor written in GDScript.

## Before you start

- Read the [README](README.md) for features, shortcuts and build steps.
- Read the [codebase overview](docs/developer/codebase-overview.md) for the
  layer map and the main runtime flows.
- For the mod platform, start with the [developer guide](docs/mods/developer-guide.md)
  and the frozen [API reference](docs/mods/api-reference.md).
- Search existing issues before opening a new one. Use the issue templates for
  bugs, features and mod preview feedback.

## Development setup

1. Install [Godot 4.7.2](https://godotengine.org/).
2. Open the repository as a Godot project, or run `godot --path .`.
3. Keep changes focused. Preserve existing behavior unless the change is the
   point of the pull request.
4. Do not commit generated executables, exported builds or the `.godot/` cache.

## Tests

Run the headless gate before opening a pull request:

```bash
godot --headless --path . --script res://tests/test_runner.gd
```

It must print `All tests passed` and exit with code 0. Integration runners for
Git, the debugger and acceptance behavior, plus the manual pass, are listed in
the [manual test checklist](docs/developer/manual-test-checklist.md).

When behavior, configuration or public APIs change, update the matching page
under `docs/user/`, `docs/developer/` or `docs/mods/`.

## Source layout

- `src/main/` — composition root, main scene and autoloads.
- `src/base/` — pure helpers.
- `src/platform/` — editor-agnostic services.
- `src/editor/` — document model, view host and editor scenes.
- `src/workbench/` — shell UI panels and dialogs.
- `src/features/{run,lsp,git,debug,mods,learning}/` — feature modules.
- `resources/` — bundled fonts, icons, shaders, Lua content and templates.
- `tests/{unit,integration,support}/` — suites mirroring the source layers.
- `tools/` — packaging, probes, installer and the Rust audio analyser.

## Pull requests

- Explain what changed, why, and which checks you ran.
- Include reproduction steps for bug fixes.
- Keep documentation and tests in the same pull request as the code.
- Be respectful and assume good intent in reviews.

## License

Qorix is licensed under the Apache License 2.0. By contributing, you agree
that your contribution is provided under the same license.
