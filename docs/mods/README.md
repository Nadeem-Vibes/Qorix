# Mod platform

Qorix's mod platform is an opt-in Developer Preview with a frozen API 1.0.
Mods run in a sandbox and every capability is gated by an explicit permission
and a consent record.

## Start here

- [developer-guide.md](developer-guide.md) — build a mod from folder to running
  code.
- [api-reference.md](api-reference.md) — the frozen native and Lua surface.
- [manifest-reference.md](manifest-reference.md) — every manifest field and
  permission.
- [partial-ui-guide.md](partial-ui-guide.md) — declarative widgets, slots and
  document/file semantics.
- [migration-notes.md](migration-notes.md) — moving from earlier previews.
- [known-issues.md](known-issues.md) — the honest limitation list.
- [feedback.md](feedback.md) — how to report a problem.

## Courses and samples

- [course-user-guide.md](course-user-guide.md) — the five-lesson Python
  course.
- [course-author-guide.md](course-author-guide.md) — build your own course mod.
- [samples/mods/README.md](../../samples/mods/README.md) — runnable sample
  mods, including the Platform Tour.

## Packaging and distribution

- [package-format.md](package-format.md) — the `.gcm`/`.zip` container, digest
  and signature metadata.
- [publisher-guide.md](publisher-guide.md) — key generation, packing, signing
  and verification.
- [preview-packaging.md](preview-packaging.md) — test-gated Developer Preview
  exports.
- [security-review.md](security-review.md) — threat model, residual risks and
  the Gate G worksheet.
- [support.md](support.md) — support policy, recovery and diagnostics.
- [release-notes.md](release-notes.md) — the current platform release notes.

## Verify the contract

```bash
godot --headless --path . --script res://tests/test_runner.gd
```

The runner covers the mod suites under `tests/unit/features/mods/`, including
the golden API surface, package validation, installer and import flows.
