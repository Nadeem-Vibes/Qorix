# Security review — distribution

Status: **automated review complete; external human review pending.** Gate G is
not signed. The automated threat suite is green and this review records no open
critical or high finding, but an independent reviewer has not yet examined the
implementation and the five-user consent study has not been run.

## Scope

In scope:

- the `.gcm`/`.zip` parser, archive validation and extraction;
- the canonical SHA-256 digest and its use in the registry and consent records;
- Ed25519 signature generation/verification and `signature.json` metadata;
- publisher trust and key pinning;
- `ModInstaller.inspect()`, `install()`, `rollback()` and `uninstall()`;
- update/downgrade policy, permission-growth re-consent and data retention;
- the import review UI and installed-mod cards.

Out of scope here (covered elsewhere or by later work):

- the Lua sandbox, task budgets, memory limits and API capability enforcement
  (platform suites);
- the local filesystem/OS boundary and process isolation;
- a hosted registry, download transport, revocation service or auto-update;
- accessibility, localization and platform hardening.

## Assets and trust boundaries

| Asset | Why it matters |
| --- | --- |
| Workspace files and mod data | A malicious package must not read or overwrite outside its grants |
| Editor process and memory | Native libraries and script containers must never enter the mod tree |
| Installed mod code | An update must not silently replace code the user reviewed |
| Publisher trust store | Pinning is the only link between a signature and an identity the user approved |
| Consent records | Permission growth must be visible and re-approved |
| User attention | A confusing review dialog is a security control failure |

Trust boundaries:

1. **Package file → validator.** The archive is untrusted. Nothing is extracted
   until the whole archive validates, the manifest parses and any signature
   verifies.
2. **Signature → publisher identity.** A valid signature is not trust. The
   first key for a publisher id is pinned only after the user sees the id and
   fingerprint; a changed key requires explicit replacement.
3. **Review → install.** Review mutates nothing. Install revalidates the file
   and refuses if the package changed between the two calls.
4. **Install → activation.** Code is placed only under
   `user://mods/<id>/<version>/`; activation then goes through the mod-core
   consent and sandbox path.
5. **Local user data.** `user://mod_publishers.json`, the registry and consent
   records are local trusted state. A local attacker who can already write
   `user://` is outside the remote-package threat model.

## Threat table

| Threat | Control | Evidence |
| --- | --- | --- |
| ZIP slip / `../` traversal | `_path_problem()` rejects empty, `.` and `..` segments; extraction joins only validated relative paths | `test_mod_package.gd`: `test_rejects_unsafe_paths` |
| Absolute, drive-letter or backslash paths | Rejected before extraction | `test_rejects_unsafe_paths` |
| Windows reserved names, trailing dots/spaces, control characters, `<>:"|?*` | Rejected per segment | `test_rejects_unsafe_paths` |
| Symlink entries | ZIP external-attribute type `0xA000` is rejected | `test_rejects_symlinks_encryption_and_zip64` |
| Duplicate or case-colliding entries | Case-insensitive `seen` map rejects the archive | `test_rejects_duplicate_names_and_file_directory_collisions` |
| ZIP64, multi-disk, encrypted entries, unsupported methods | Central-directory parser rejects each case | `test_rejects_symlinks_encryption_and_zip64` |
| Disk exhaustion / compression bomb | 64 MiB package, 4096 entries, 64 MiB total, 16 MiB per entry and 100:1 ratio above 256 KiB | `test_rejects_blocked_extensions_and_oversized_entries`, `test_rejects_too_many_entries_and_total_size` |
| Native or executable payload | `BLOCKED_EXTENSIONS` rejects `.exe`, `.dll`, `.so`, `.ps1`, `.js`, `.wasm`, `.luac` and related containers | `test_rejects_blocked_extensions_and_oversized_entries`, `test_folder_rejects_blocked_files_and_missing_manifest` |
| Malicious or incomplete manifest | `Manifest.validate()`; entry and declared icon must exist in the package | `test_rejects_missing_and_invalid_manifest` |
| Lying central-directory sizes or CRC | Every file is read once during validation and rechecked on real size/CRC during extraction | `test_extract_rejects_lying_crc`; validation re-reads all entries |
| Package substituted between review and install | `install()` repeats `inspect()` and rejects a changed archive | `test_package_swapped_after_review_is_refused` |
| Digest mismatch after extraction | Extracted folder is validated and its canonical digest must equal the reviewed digest | `test_mod_installer.gd`: `test_inspect_is_side_effect_free_and_trust_gates_install` |
| Signature forgery or content tampering | Ed25519 verification over a domain-separated message binding digest, publisher id and public key | `test_mod_ed25519.gd` (RFC 8032 vectors, tampering, non-canonical scalars, low-order keys); `test_mod_package.gd`: `test_signature_roundtrip_and_content_tamper` |
| Signature metadata swapped | `schema`, `algorithm`, publisher id, key and digest field lengths and values are validated; unknown fields rejected; `key_id` must match the fingerprint | `test_signature_metadata_rejections`, `test_signature_requires_supported_schema` |
| Publisher impersonation or key substitution | First-use pinning; `new` needs trust, `key_changed` needs re-trust and `replace_key`; invalid signatures are never installable | `test_mod_installer.gd`: `test_trusted_publisher_and_key_change_retrust`, `test_invalid_signature_is_never_installable` |
| Unsigned package accepted silently | Install is blocked unless `allow_unsigned` is explicit; the registry records the exception | `test_unsigned_import_requires_explicit_opt_in`, `test_mod_import.gd`: `test_unsigned_import_needs_the_manager_opt_in` |
| Permission creep on update | Sensitive permissions are compared with the consent record; growth blocks activation until the new list is accepted | `test_permission_growth_requires_reconsent`, `test_permission_growth_blocks_then_consent_activates`, `test_permission_growth_needs_consent_and_honors_activate_off` |
| Downgrade or replay of an older package | Version comparison distinguishes install/update/reinstall/replace/downgrade; downgrade needs explicit opt-in; previous versions stay on disk for rollback | `test_update_replace_and_downgrade_policy` |
| Tampered rollback target | Rollback revalidates the folder, compares its digest with the recorded hash, verifies the signature and rechecks publisher trust | `test_rollback_restores_previous_and_verifies_bytes` |
| Data loss on uninstall | Data under `user://mod_data/<id>` is kept by default; deletion requires an explicit action passed as `remove_data` | `test_uninstall_keeps_data_or_removes_it`; `test_mod_import_ui.gd`: `test_uninstall_keeps_data_by_default` |
| Path escape through id/version at install, rollback or uninstall | Manifest id is schema-validated, target paths are checked with `Paths.is_subpath()` and rollback paths must be inside the mod's version folder | Installer path guards; manifest and version suites |
| Corrupt trust store | `FileStore` reports a structured error and the publisher store writes a backup rather than silently trusting partial data | `mod_publishers.gd` load/store handling and existing `test_fs`/store suites |
| Review UI hides a blocker | Install stays disabled until blockers and the consent gate are resolved; publisher, fingerprint, risk and growth are rendered as text | `test_mod_import_ui.gd` (56 checks) |

## Findings

### Automated review

No open **critical** or **high** finding was identified in the automated
review. The following residual risks are accepted for distribution and must be
included in the external review:

| ID | Severity | Finding | Status / mitigation |
| --- | --- | --- | --- |
| R1 | Medium | No independent security review yet | Gate G open; reviewer worksheet below |
| R2 | Medium | No revocation, key-expiry or transparency mechanism. A compromised publisher key stays trusted until the user replaces or forgets it | Key-change review shows both fingerprints; document incident guidance; hosted revocation is future work |
| R3 | Medium | Unsigned-package opt-in can be socially engineered | Review copy says the origin cannot be verified; opt-in is per import and recorded; public distribution should be signed |
| R4 | Low | `signed_at` and `display_name` are self-asserted metadata, not covered by the signature | Treat as display-only; do not use for freshness or identity decisions |
| R5 | Low | Ed25519 is pure GDScript and not constant-time | Local package verification only; no server-side or long-term secret use; RFC 8032 and rejection tests; native crypto is future work |
| R6 | Low | The local trust store is user-writable; malware already running as the user can replace both trust and packages | Outside the remote-package threat model; OS account security is the boundary |
| R7 | Low | Validation reads the whole archive into memory (bounded at 64 MiB) | Bounded and user-initiated; transient memory only |
| R8 | Low | No anti-malware scanning; a signed package can still contain harmful Lua | Capability model, consent and Lua sandbox are the controls; signatures establish origin, not safety |
| R9 | Process | Five-user consent study not run | Gate G open; cannot be performed headlessly |

No finding above is rated critical or high. R1 and R9 are gate items, not code
defects; the external reviewer may add or re-rate findings.

## Gate G checklist

| Item | State | Notes |
| --- | --- | --- |
| Malicious archive suite passes | ✅ | `test_mod_package.gd` 119 checks, plus installer race/tamper tests |
| Signatures verified before extraction | ✅ | `validate_archive()` verifies; `inspect()` extracts nothing; `install()` revalidates |
| Permission growth requires re-consent | ✅ | Installer, manager and UI suites |
| Rollback works | ✅ | Digest and signature rechecked before the active record changes |
| Security review has no open critical/high findings | ⏳ | Automated review: none. External review pending |
| Consent flow understood by five test users | ⏳ | Headless copy/gating tests pass; human study pending |

## Reproduction

```powershell
# Full headless suite (exit 0 expected)
C:\Godot\Godot.exe --headless --path . --script res://tests/test_runner.gd
```

Distribution suites can be run individually through the same runner; the malicious
fixtures intentionally print `CRC error reading file from zip archive` and
similar engine messages. A failed rejection test is a real failure; the engine
message alone is noise from the test that proves rejection.

## Reviewer worksheet

Please focus on these areas and record a severity for every finding:

1. **ZIP parser.** Central-directory/local-header disagreement, malformed extra
   fields, data descriptors, duplicate names with different case, path
   encodings, trailing dots/spaces, reserved device names, absolute paths and
   symlink attributes.
2. **Digest and signature binding.** Confirm that no file can change without
   changing the digest and that no metadata (publisher id, public key,
   package hash) can be swapped without invalidating the signature.
3. **Ordering.** Confirm that no path can write before validation and that a
   package swapped between review and install is refused.
4. **Publisher pinning.** Try a new publisher, a changed key, a re-trust, a
   forgotten publisher and a corrupt trust store.
5. **Permission growth.** Confirm that an update cannot activate with a
   sensitive permission the user has not accepted, including a same-version
   replacement and a downgrade.
6. **Rollback and uninstall.** Tamper with the previous version folder, its
   manifest, a file, a signature and the path recorded in the registry;
   confirm rollback refuses. Confirm uninstall keeps data by default and
   revokes consent.
7. **Unsigned path.** Confirm the opt-in is explicit, per import, and does not
   lower the bar for later signed packages.
8. **UI comprehension.** Walk a first-time user through trust, key change,
   permission growth, denial, cancel, uninstall and data deletion. Record what
   they think the signature proves and what a permission allows.

## Sign-off

| Role | Name | Date | Result |
| --- | --- | --- | --- |
| Automated review (implementation) | Qorix distribution | 2026-11-07 | No open critical/high; residuals R1–R9 |
| External security reviewer | — | — | Pending |
| Five-user consent study | — | — | Pending |

Gate G remains **open** until the external reviewer and the consent study are
recorded above.
