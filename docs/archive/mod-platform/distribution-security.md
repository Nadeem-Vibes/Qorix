# Phase 6 — Distribution Security

Status: **implemented; automated gates pass, external review and consent study
pending.** This is the Phase 6 scope from §16 of the architecture plan: a
validated package format, a SHA-256 registry, Ed25519 publisher signatures,
publisher identity, permission-growth re-consent, update/rollback,
uninstall/data retention, an import review UI and threat tests.

Gate G is not signed yet. The malicious-archive suite, the
signature-before-extraction path, permission re-consent and rollback are green
in the headless suite. Two Gate G items need people: an external security
review and a five-user consent study. See [Gate G evidence](#gate-g-evidence)
and [`security-review.md`](../../mods/security-review.md).

## What Phase 6 adds

| Area | Implementation |
| --- | --- |
| Package format | `.gcm` or `.zip`; a ZIP container with a root `manifest.json`, Lua/assets and an optional `signature.json`; see [`package-format.md`](../../mods/package-format.md) |
| Archive validation | Full central-directory parse and in-memory read before anything is extracted: path traversal, absolute paths, symlinks, duplicate names, ZIP64, encryption, unsupported methods, size/ratio caps, blocked extensions, CRC and declared-size checks |
| Canonical digest | SHA-256 over sorted relative paths and file bytes, excluding the root `signature.json`; the same digest is used by the registry, consent records and signatures |
| Ed25519 signatures | Pure-GDScript implementation in `src/features/mods/ed25519.gd`; the signature binds the digest, publisher id and public key with the `GRIDDYCODE-MOD-PACKAGE-V1` domain |
| Publisher identity | `user://mod_publishers.json` with first-use pinning: `new`, `trusted`, `key_changed`, `unsigned` and `invalid`; a changed key needs explicit re-trust |
| Permission-growth consent | `ModInstaller.inspect()` compares the package's sensitive permissions with the consent record; an update that grows permissions stays blocked until the user accepts the new list |
| Update and rollback | Same id and a higher version is an update; the previous version folder stays on disk; rollback rewrites the active registry record only after rechecking the folder digest and signature |
| Uninstall and data | Removes every installed version, revokes consent and keeps `user://mod_data/<id>` unless `remove_data` is explicit |
| Import review UI | Native `.gcm`/`.zip` picker, a review dialog with publisher, fingerprint, signature state, permission growth, contents and policy blockers, then an install gate; installed cards show signature/risk and expose rollback/uninstall |
| Tooling | `Tools/mod_package.gd` and the PowerShell wrapper support `keygen`, `pack`, `sign`, `digest` and `verify`; see [`publisher-guide.md`](../../mods/publisher-guide.md) |
| Threat tests | Phase 6 suites cover malicious archives, signature vectors and tampering, trust pinning, policy, rollback, uninstall and the review UI |

## Install order

Every import follows this order in `src/features/mods/mod_installer.gd`. A package
is never extracted before validation and signature verification succeed:

1. `ModPackage.validate_archive()` parses the central directory, reads every
   entry into memory, validates the manifest and verifies `signature.json`.
2. `ModInstaller.inspect()` classifies the publisher, version policy and
   permission growth. This mutates nothing.
3. `ModInstaller.install()` repeats the inspection, refuses if the package
   changed, and extracts into an empty staging folder.
4. The extracted folder is validated again and its digest must equal the
   reviewed digest.
5. Only then is the folder moved to
   `user://mods/<id>/<version>/` and the registry record written. An existing
   same-version folder is moved aside and restored if the write fails.
6. `ModManager.import_package()` rescans, writes the consent record when the
   user accepted the permissions, and optionally activates the mod.

## Gate G evidence

| Gate G item | Automated evidence | Human evidence |
| --- | --- | --- |
| Malicious archive suite passes | `tests/suites/test_mod_package.gd` (119 checks): traversal, absolute and drive paths, backslashes, symlinks, encryption, ZIP64, duplicate/case-colliding names, blocked extensions, per-entry/total/ratio limits, bad manifests, CRC lies, wrong container. `test_mod_installer.gd` also refuses a package swapped after review | Not applicable |
| Signatures verified before extraction | `ModPackage.validate_archive()` verifies `signature.json` and reports `signature.invalid`; `ModInstaller.inspect()` extracts nothing and `install()` revalidates before staging. `test_mod_installer.gd`: `test_inspect_is_side_effect_free_and_trust_gates_install`, `test_invalid_signature_is_never_installable`, `test_package_swapped_after_review_is_refused`; `test_mod_import.gd`: `test_signed_import_trust_activation_and_restart` | Not applicable |
| Permission growth requires re-consent | `test_mod_installer.gd`: `test_permission_growth_requires_reconsent`; `test_mod_import.gd`: `test_permission_growth_blocks_then_consent_activates`; `test_mod_import_ui.gd`: `test_permission_growth_needs_consent_and_honors_activate_off` | Five-user consent study pending |
| Rollback works | `test_mod_installer.gd`: `test_rollback_restores_previous_and_verifies_bytes` (digest and tamper rejection); `test_mod_import.gd`: `test_update_reactivates_and_rollback_restores`; `test_mod_import_ui.gd`: card rollback confirmation and status | Not applicable |
| Security review has no open critical/high findings | Automated review in [`security-review.md`](../../mods/security-review.md) records no open critical or high finding; the full headless suite is green | External human review pending |
| Consent flow understood by five test users | Copy, gating and denial paths are exercised by `test_mod_import_ui.gd` | Pending; this cannot be performed headlessly |

The full headless run at the Mod Platform 1.0 gate reports **7056 checks across
82 suites, exit 0**, including the Phase 7 hardening and C++ course suites. The
five Phase 6 suites contribute **502 checks**:

| Suite | Checks | Focus |
| --- | --- | --- |
| `test_mod_ed25519.gd` | 94 | SHA-512 vectors, RFC 8032 sign/verify, tampering, non-canonical scalars, low-order keys, package message |
| `test_mod_package.gd` | 119 | Archive validation, extraction, digest, packing, malicious archives, signature metadata |
| `test_mod_installer.gd` | 145 | Trust/pinning, unsigned opt-in, version policy, permission growth, rollback, uninstall, review/install race |
| `test_mod_import.gd` | 88 | Manager-level import, activation, restart, update/rollback, uninstall |
| `test_mod_import_ui.gd` | 56 | Review dialog, trust/consent gating, signature/risk cards, rollback/uninstall controls |

Tooling was verified end-to-end through the documented PowerShell wrapper:
`keygen → pack → sign → verify --require-signature → digest` against the
Platform Tour sample. The signed package verifies with the generated
fingerprint, and the wrapper uses the same validator and signature code as the
editor.

## Using the feature

Import from the Mods page or the command palette:

1. **Mods…** → **Import package…**, or **Import Mod Package…** from the
   command palette, chooses a `.gcm` or `.zip`.
2. The review dialog shows the package name/id/version, author, publisher id,
   short key fingerprint, signature state, update kind, permission growth and
   risk, declared permissions, file/directory counts and the canonical digest.
3. Resolve every blocker. A new publisher needs **Trust publisher**; a changed
   key needs **Replace the pinned key**; an unsigned package needs **Allow this
   unsigned package**; an existing version needs **Replace**; an older version
   needs **Allow installing an older version**. Permission growth needs **I
   accept these permissions**. **Install** stays disabled until every blocker
   and the consent gate are satisfied.
4. Installed cards show the signature chip, permission-risk summary and, when
   applicable, **Roll back to v…** and **Uninstall…**. Uninstall keeps data by
   default and offers an explicit delete-data action.

To build and sign a package, follow [`publisher-guide.md`](../../mods/publisher-guide.md).

## Files

| Path | Purpose |
| --- | --- |
| `src/features/mods/mod_package.gd` | ZIP parse, archive/folder validation, canonical digest, signature verification, extraction and packing |
| `src/features/mods/ed25519.gd` | Pure-GDScript Ed25519 and SHA-512 |
| `src/features/mods/mod_publishers.gd` | Publisher trust store, pinning and key-change classification |
| `src/features/mods/mod_installer.gd` | Review, policy, install, rollback and uninstall |
| `src/features/mods/mod_registry.gd` | Active version, hash, signature and previous-version record |
| `src/features/mods/mod_manager.gd` | Distribution bridge: inspect/import/rollback/uninstall, activation and publisher APIs |
| `src/features/mods/ui/mod_settings_panel.gd` | Import review dialog and installed-card controls |
| `src/main/file_manager.gd` | `mods.import` command and native package picker |
| `Tools/mod_package.gd` | Key generation, pack, sign, digest and verify CLI |
| `Tools/mod_package.ps1` | PowerShell wrapper for the CLI |
| `tests/suites/test_mod_ed25519.gd` | Ed25519 and SHA-512 suite |
| `tests/suites/test_mod_package.gd` | Archive, digest and signature suite |
| `tests/suites/test_mod_installer.gd` | Installer lifecycle suite |
| `tests/suites/test_mod_import.gd` | Manager import lifecycle suite |
| `tests/suites/test_mod_import_ui.gd` | Import review and card UI suite |

## Tests

```bash
godot --headless --path . --script res://tests/test_runner.gd
```

All Phase 6 suites are registered at the end of `tests/test_runner.gd`. The
runner prints every failed assertion and exits non-zero if any check fails. The
malicious fixtures intentionally produce `CRC error reading file from zip
archive` and similar engine messages; those are expected output from tests that
assert rejection, not test failures.

## Pending external checks

These are Gate G items that cannot be completed in this environment:

1. **External security review.** An independent reviewer should focus on the
   ZIP parser, digest/signature binding, publisher pinning, extraction order
   and rollback path. The review worksheet is in
   [`security-review.md`](../../mods/security-review.md).
2. **Five-user consent study.** Walk five people who have not seen the design
   through install, permission growth, denial, key change and uninstall.
   Record whether they can explain what the publisher signature proves, what
   the permissions grant, why re-consent is needed and how to remove the mod.
3. **Desktop walkthrough.** Confirm the native picker, dialog layout, focus
   order, tooltips and status messages on a desktop build; the headless suite
   drives the same panel code but cannot judge readability.
4. **Key-custody check.** Confirm the publisher's private key file is stored
   offline or with appropriate filesystem permissions; v1 has no key
   passphrase.

## Related phases

- [`developer-preview.md`](developer-preview.md) — Developer Preview and the
  frozen API that packages target.
- [`../../mods/known-issues.md`](../../mods/known-issues.md) — updated status of
  the preview limitations.
- [`contracts.md`](contracts.md) — error and permission
  contracts used by the installer and review UI.

Phase 7 (performance/accessibility hardening and public 1.0) is implemented
separately; see [`hardening.md`](hardening.md).
