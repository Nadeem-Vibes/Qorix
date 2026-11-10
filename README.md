# Qorix

Qorix is a powerful, beginner-friendly code editor designed to grow with
developers, from their first lines of code to professional software
development.

It is a desktop application built with Godot 4.7 and GDScript. It combines a
world-space code canvas with a familiar editor shell: tabs, a file tree, quick
open, command palette, search and replace, an integrated terminal, run output,
source control and debugging.

Repositories:

- **Qorix** (this repository): https://github.com/Nadeem-vibes/Qorix
- **Original upstream project**: https://github.com/face-hh/griddycode

> Qorix is an extensively modified and independently developed fork of
> [GriddyCode](https://github.com/face-hh/griddycode), the open-source code
> editor originally created by Face and licensed under the
> [Apache License 2.0](LICENSE). The upstream project is unmaintained; Qorix
> keeps the project's heritage and its license. See
> [License and attribution](#license-and-attribution).

New installations start in **Beginner Mode**: larger text, plain-language
menus and settings, automatic local file history and a guided two-minute
tutorial on the welcome screen. Turn it off at any time from Preferences →
Getting Started, the welcome screen checkbox, or the command palette. The
welcome screen also offers the built-in **Python Journey** — five guided
lessons from your first `print()` to your first loop. See the
[Getting started guide](docs/user/getting-started.md).

Press `Ctrl` + `I` in the editor for the built-in introduction.

## Status

The current tree includes the editor refactor, run pipeline, language-server
support, Git integration, the Python debugger, accessibility/localization
settings, beginner guidance and the opt-in Lua mod platform Developer Preview.
The mod API is frozen at 1.0 for the preview, but the public 1.0 release gate
still has desktop and external-review work outstanding.

See the [codebase overview](docs/developer/codebase-overview.md) for the
architecture and the [manual test checklist](docs/developer/manual-test-checklist.md)
for the desktop verification pass.

## Supported platforms

| Platform | Status | Notes |
| --- | --- | --- |
| Windows 10/11, x86_64 | Supported | Reference platform; installer and portable ZIP are published by the release workflow. |
| Linux, x86_64 | Preview | Exported and usable, but the desktop support matrix is not signed off. |
| macOS | Preview | No signed build or completed desktop accessibility pass yet. |
| Android, iOS, Web | Unsupported | Qorix is a desktop application. |

Qorix uses Godot **4.7.2** in CI and release builds. The project uses the
GL Compatibility renderer and bundles the Nerd Font and emoji fallbacks needed
by its file picker, settings and editor UI; installing a Nerd Font separately
is not required.

## Features

- Multi-tab editing with undo history, selections, zoom, minimap and dynamic
  document height.
- Workspace folders, file tree operations, recent folders, session restore,
  autosave and external-change detection.
- Quick open (`Ctrl` + `P`), command palette (`Ctrl` + `Shift` + `P`), find and
  replace, global search, ignore rules and background indexing.
- Built-in terminal tabs plus captured or interactive run configurations.
  Captured runs provide streaming output, exit status, duration, friendly error
  explanations and clickable `file:line` links.
- Language Server Protocol support for Python, JavaScript/TypeScript, Rust,
  C/C++ and Go. Servers are discovered on `PATH`; Qorix does not download
  or install them.
- Git source control with status, staging, diffs, commits, branches, pull,
  push, save points and changed-line markers. Git credentials remain managed
  by Git's own credential helper.
- Debug Adapter Protocol support for Python through `debugpy`, including
  breakpoints, stepping, call stacks, variables, watches and a debug console.
- A complete built-in Python Journey: five guided lessons on the welcome
  screen, with ghost-text typing, run-backed checks of your program (text
  checks when Python is missing) and saved progress. `Ctrl` + `Alt` + `J`,
  or Help → Python Journey.
- Beginner Mode for first-time programmers: reversible larger text, plain-language
  menus and settings, automatic local History (previous versions), a four-step
  resumable tutorial, starter templates, hover glossary explanations and
  consequence-first confirmations. On by default for new installations.
- Themes, bundled and system fonts, localization, high-contrast and
  dyslexia-friendly options, reduced motion, accessibility checks and large
  file/search performance work.
- Legacy Lua language plugins and themes, plus the newer consent-based Lua mod
  platform described below.

Detailed guides:

- [Getting started](docs/user/getting-started.md) — install, first launch, templates, friendly errors
- [Run configurations and output](docs/user/run-and-output.md)
- [Language servers](docs/user/language-servers.md)
- [Git and save points](docs/user/git.md)
- [Python debugger](docs/user/debugger.md)
- [Accessibility, localization and performance](docs/user/accessibility-localization-performance.md)

## Keyboard shortcuts

The most useful defaults are:

| Action | Shortcut |
| --- | --- |
| Open file | `Ctrl` + `O` |
| Open folder | `Ctrl` + `Shift` + `O` |
| Save | `Ctrl` + `S` |
| Close tab | `Ctrl` + `W` |
| Quick open file | `Ctrl` + `P` |
| Command palette | `Ctrl` + `Shift` + `P` |
| Find / replace | `Ctrl` + `F` / `Ctrl` + `H` |
| Global search | `Ctrl` + `Shift` + `F` |
| Toggle terminal | `Ctrl` + `` ` `` |
| Python Journey course | `Ctrl` + `Alt` + `J` |
| Run current file | `F5` |
| Run current file in terminal | `F6` |
| Stop the running program | `Shift` + `F5` |
| Start/continue debugging | `Ctrl` + `F5` |
| Stop debugging | `Ctrl` + `Shift` + `F5` |
| Toggle breakpoint | `F9` |
| Zoom in/out | `Ctrl` + `=` / `Ctrl` + `-` |
| Settings | `Ctrl` + `,` |
| About/introduction | `Ctrl` + `I` |

Shortcuts can be changed in the keybindings settings and from the command
palette. The command palette displays the effective shortcut.

## Lua extensions

### Legacy language plugins and themes

The original Lua extension folders remain supported:

| OS | User data folder |
| --- | --- |
| Windows | `%APPDATA%\Godot\app_userdata\Qorix` |
| Linux | `~/.local/share/godot/app_userdata/Qorix` |
| macOS | `~/Library/Application Support/Godot/app_userdata/Qorix` |

Place language files in `langs` and theme files in `themes` inside that folder.
For contributors, repository copies live in [`resources/lua/plugins`](resources/lua/plugins) and
[`resources/lua/themes`](resources/lua/themes). A language file is named for its extension, such as
`toml.lua`; a theme can use any filename. Restart Qorix, or switch to
another extension and back, after changing a legacy plugin.

Legacy files are intentionally not treated as installed mods: they have no
mod permissions, consent prompt, sandbox or uninstall action. See the
[mod-platform migration notes](docs/mods/migration-notes.md)
before choosing which extension system to use.

Language plugins can provide:

| Method | Purpose |
| --- | --- |
| `highlight(keyword, color)` | Highlight a keyword using a built-in syntax color. |
| `highlight_region(start, end, color, line_only)` | Highlight a delimited region. |
| `add_comment(comment)` | Add a quote to the `Ctrl` + `L` comments menu. |
| `detect_functions(content, line, column)` | Return function names for completion. |
| `detect_variables(content, line, column)` | Return variable names for completion. |

Themes can use `set_keywords(property, color)`, `set_gui(property, color)` and
`disable_glow()`. The available properties and colors are listed in
[`resources/lua/definitions.lua`](resources/lua/definitions.lua).

### Mod platform Developer Preview (API 1.0)

The mod platform is opt-in and is **not yet a public 1.0 release**. Mods run
with explicit consent and permission checks. Distribution, signatures and a
registry are documented as later release work.

- Start with the [developer guide](docs/mods/developer-guide.md)
  and [frozen API reference](docs/mods/api-reference.md).
- Read the [manifest reference](docs/mods/manifest-reference.md),
  [known issues](docs/mods/known-issues.md) and
  [feedback guide](docs/mods/feedback.md).
- Try the [sample mods](samples/mods/README.md), especially the
  [Platform Tour](samples/mods/griddycode.platform_tour/1.0.0/README.md).
- Installed mods use `user://mods/<id>/<version>/`; development copies use
  `user://mods_dev/<id>/<version>/`.
- Debug builds enable developer mode. Release builds can opt in with
  `--mod-dev`; saving `main.lua` or `lib/**/*.lua` hot-reloads a development
  mod after a short debounce.
- `--mod-preview` or the `mod_preview` export feature labels the build as a
  Developer Preview. `--safe-mode` starts without the active mod set, and
  `Ctrl` + `Alt` + `Shift` + `Esc` is the panic shortcut.

The archived [Developer Preview gate record](docs/archive/mod-platform/developer-preview.md)
contains the automated evidence and the remaining window checks. The archived
[hardening record](docs/archive/mod-platform/hardening.md) contains the platform
policy and public-release checklist.

## Building and contributing

```bash
git clone https://github.com/Nadeem-vibes/Qorix.git
cd Qorix
```

Install [Godot 4.7.2](https://godotengine.org/) and open the repository as a
Godot project. Run the project with `F6`/`F5`, or from a terminal:

```bash
godot --path .
```

The normal headless gate is:

```bash
godot --headless --path . --script res://tests/test_runner.gd
```

The runner currently reports **7,056 checks across 82 suites** on the verified
Godot 4.7.2 environment and must exit with code 0. Additional integration
runners cover Git, the debugger and acceptance behavior; their prerequisites
and commands are listed in the [manual checklist](docs/developer/manual-test-checklist.md).

For changes:

1. Make the smallest focused change and keep the editor usable on the supported
   Windows configuration.
2. Run the headless suite and any relevant integration or manual checks.
3. Update the related documentation when behavior or configuration changes.
4. Open a pull request with a clear description and test results. Do not submit
   generated executables.

See [CONTRIBUTING.md](CONTRIBUTING.md) for the short contributor guide. To
report a vulnerability privately, follow [SECURITY.md](SECURITY.md).

## Releases

The release workflow runs the headless suite with Godot 4.7.2, exports the
Windows x86_64 GL Compatibility build, creates an Inno Setup installer and a
portable ZIP, then publishes them for version tags:

```bash
git tag v1.0.0
git push origin v1.0.0
```

The workflow's current application package version is `0.1.0`; update the
release workflow and installer definition together when changing it.

## License and attribution

Qorix is a derivative work of
[GriddyCode](https://github.com/face-hh/griddycode) by Face, licensed under
the [Apache License 2.0](LICENSE). The original copyright notices and license
text are preserved unchanged; see [NOTICE](NOTICE) for the attribution summary.

Qorix claims no ownership of the upstream code and does not imply endorsement
by the original author. The fork is maintained by
[Nadeem-vibes](https://github.com/Nadeem-vibes).

See [LICENSE](LICENSE) for the full Apache License 2.0 text.
