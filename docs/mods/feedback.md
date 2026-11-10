# Feedback channel — Developer Preview

The preview exists to find problems before public release. Feedback is welcome
from mod authors, testers and users running the opt-in build.

## Where to report

- **Bugs, UX problems and documentation gaps:** open an issue with the
  [Mod Preview feedback form](https://github.com/Nadeem-vibes/Qorix/issues/new?template=mod-preview.yml).
  The form is stored at `.github/ISSUE_TEMPLATE/mod-preview.yml` and asks for
  the details below.
- **Proposals and API questions:** open a discussion or an issue and prefix the
  title with `[mod-preview]`. API 1.0 is frozen; proposals for new methods are
  considered for an additive 1.x change or API 2, not as a breaking edit.
- **Security problems:** do **not** open a public issue. Use a private
  [GitHub security advisory](https://github.com/Nadeem-vibes/Qorix/security/advisories/new).
  Include the smallest reproduction and whether the sandbox, consent, path,
  event, UI or shell boundary is involved. The preview blocks release on an open
  critical or high security finding.

## What to include

1. Qorix version (`LuaSingleton.version`, for example `v1.4.0`) and the
   exact build: normal, `--mod-dev`, `--mod-preview`, or the exported preview
   preset.
2. Operating system and version, plus the desktop session (X11/Wayland) on
   Linux.
3. Mod id and version, and whether it came from `user://mods` or
   `user://mods_dev`.
4. The exact error code and message from the failure card, Mods page or mod log.
   Codes are stable API 1.0 names; quote them verbatim.
5. Steps to reproduce, expected behavior, actual behavior and a screenshot or
   log excerpt if useful.
6. The smallest `main.lua` / `manifest.json` that shows the problem. Remove
   private paths and tokens.

Do not attach a full `user://` tree. The mod log, the manifest and the relevant
source file are enough. No telemetry is collected; the report is entirely
manual.

## Triage

| Severity | Meaning | Preview handling |
| --- | --- | --- |
| Critical | Sandbox escape, consent or trust bypass, arbitrary code execution outside the mod, data loss, crash loop that blocks the editor | Blocks preview release; fix and re-run the full suite before any build |
| High | API returns wrong data, shell restore/panic failure, hot reload corrupts storage, accessibility blocker | Fix before the next preview build; add a regression test |
| Medium | Isolated behavior wrong, confusing error, missing doc for an existing surface | Schedule in the preview window or document as a known issue |
| Low | Cosmetic, wording, nice-to-have | Backlog; may be deferred to 1.x |

Every accepted critical/high bug gets a test in the headless suite. A fix is not
merged on a red tree; CI runs `godot --headless --path . --script
res://tests/test_runner.gd` and the release workflow repeats it before export.

## What happens after the preview

- API 1.0 stays additive after the freeze. A report may produce a new method or
  a new optional field; it will not rename or remove an existing one.
- A permission change requires a new consent record and an entry in
  [`migration-notes.md`](migration-notes.md).
- Confirmed limitations are moved into [`known-issues.md`](known-issues.md)
  with a workaround. Fixed items are removed from that page and called out in
  the preview release notes.
- Distribution signatures, archive validation and rollback are covered by the
  [publisher guide](publisher-guide.md) and [package format](package-format.md);
  reports about installing untrusted archives are routed there, not patched
  into the preview.

## Before filing

Check [`known-issues.md`](known-issues.md) and the
[`developer-guide.md`](developer-guide.md) troubleshooting table. Many preview
surprises are deliberate: installed mods do not hot-reload, manifest edits need
a restart, and sensitive permissions start blocked until consent.
