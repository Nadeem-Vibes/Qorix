# Security policy

## Supported versions

Security fixes target the current `master` branch and the latest published
release. Older releases and the Developer Preview builds are not maintained
with backports.

## Reporting a vulnerability

Please do not open a public issue for a security problem.

Use GitHub's private vulnerability reporting form for this repository
(**Security** tab, then **Report a vulnerability**). If private reporting is not
available, open a minimal public issue asking the maintainers for a private
channel, without exploit details or affected user data.

Include, when possible:

- Editor version and build label.
- Platform and how Qorix was started.
- A description of the impact and the smallest reproduction.
- Whether the issue involves mods, language servers, the debugger, Git, the
  terminal, file handling or the update checker.
- Any relevant logs with secrets, tokens and file contents removed.

Never send publisher private keys, session tokens or unredacted mod data.

## Scope

In scope:

- The editor and its file, workspace, terminal and process handling.
- Mod package parsing, digest/signature binding, publisher pinning, permission
  consent, extraction order and rollback.
- Language-server and debugger process launching and configuration.
- The update checker and release packaging scripts.

The mod platform is capability-checked, not an OS sandbox: a mod runs
in-process with the permissions the user granted. A mod doing something its
declared permissions allow is not a vulnerability by itself. See the
[mod security review](docs/mods/security-review.md) and
[known issues](docs/mods/known-issues.md).

## Disclosure

Maintainers will acknowledge a report, investigate it and coordinate a fix and
disclosure timeline with the reporter. The external security review of the mod
platform is still pending; findings are tracked in
[docs/mods/security-review.md](docs/mods/security-review.md). There is no bug
bounty.
