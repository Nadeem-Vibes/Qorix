# Known issues — Developer Preview

This is the honest limitation list for the preview. "Open" means known and
accepted for this preview, not necessarily permanent. Report a new issue through
[`feedback.md`](feedback.md).

The distribution work resolved the signature, archive-validation, import and
rollback items in the first table. The external security review and the
five-user consent study remain open Gate G items.

## Release and distribution

| Issue | Impact | Workaround / status |
| --- | --- | --- |
| No public mod distribution, registry or auto-update | Local `.gcm`/`.zip` import exists, but there is still no browsable registry, download transport or automatic update feed | Share and import a signed package; hosted distribution, search and auto-update remain future work |
| ~~No publisher signatures or authenticity checks~~ | **Resolved.** Packages can be signed with Ed25519; the publisher key is pinned on first use and a changed key needs explicit re-trust. Unsigned packages still require an explicit opt-in | Sign with `tools/mod-package/mod_package.ps1`; see [`publisher-guide.md`](publisher-guide.md) |
| ~~No archive installer in the preview~~ | **Resolved.** `.gcm`/`.zip` import validates the whole archive and verifies the signature before extraction, then validates the extracted folder and digest | Use **Import package…** on the Mods page; see [`package-format.md`](package-format.md) |
| ~~No rollback command in the Mods page~~ | **Resolved.** A previous version can be restored from the mod card after its recorded digest and signature are rechecked | Use **Roll back to v…**; version folders stay on disk and data under `user://mod_data` is preserved |
| External security review is pending (Gate G) | The automated threat suite is green, but no independent reviewer has signed off | Gate G remains open; use the worksheet in [`security-review.md`](security-review.md) |
| Five-user consent study is pending (Gate G) | Review copy and gating are tested headlessly, but comprehension has not been measured with people | Run the study before declaring Gate G complete |
| No revocation, expiry or trusted timestamp | A compromised or rotated publisher key stays trusted until the user replaces or forgets it; `signed_at` is self-asserted | Prefer a new publisher id for a compromised key, or re-trust the replacement explicitly; hosted revocation is future work |
| Publisher private keys are plaintext JSON | Anyone with the key file can sign as that publisher; v1 has no key passphrase or hardware-key support | Keep the private file offline or encrypted, never commit it; see [`publisher-guide.md`](publisher-guide.md) |
| Preview is opt-in and labeled | A release build runs as a normal editor unless built with `mod_preview` or started with `--mod-preview` | Use the preview presets or the flag; the app and Mods page show the label |

## API and permission surface

| Issue | Impact | Workaround / status |
| --- | --- | --- |
| No network access | Mods cannot make HTTP requests or open sockets | `network` is catalogued as reserved and rejected by manifest validation; there is no API method |
| No raw input observation | Mods cannot read arbitrary keystrokes | `input.observe` is reserved and rejected; use commands, key bindings or UI events |
| `terminal.read` and `terminal.write` are catalogued but have no native methods in API 1.0 | Declaring them grants nothing today; the manifest accepts the names | Treat them as forward-compatible placeholders; do not rely on terminal access |
| `settings.read` is catalogued but no native method exposes global editor settings | Declaring it grants nothing today | Read only the mod's own declared settings with `editor.settings.get` |
| One code viewport | A shell layout may reserve at most one `editor` widget; a second is `shell.editor_slot` | Design around one viewport; multiple viewports are out of scope for API 1 |
| No world-space UI or arbitrary engine embedding | Mod UI is the declarative widget catalog plus shell/partial mounts | Use the documented widgets; richer rendering is post-1.0 work |
| API 1 is single-major | A mod targeting another API is blocked | Target API 1; breaking changes require API 2 and an adapter |
| Error messages are English-only | Localized error UX is not part of the preview | Use error codes for branching; see `mod_result.gd` |

## Developer mode and hot reload

| Issue | Impact | Workaround / status |
| --- | --- | --- |
| Hot reload watches only `main.lua` and `lib/**/*.lua` | Editing `content/*.lua`, manifest, assets or a file outside `lib` does not reload | Restart or press **Reload** on the Mods page; keep reloadable modules under `lib/` |
| Manifest changes are not hot-reloaded | Changing permissions, settings or dependencies appears to do nothing until restart | Restart or **Reload**; re-consent may be required |
| Reload loses session state | Lua locals, widget mounts, commands, timers and dialog handlers are rebuilt; storage/progress/settings survive | Persist durable state in `editor.storage` or `editor.progress`; keep `deactivate()` complete |
| Debounce is not instant | There is a visible delay (about 0.4–0.7 s with defaults) between save and reload | Expected; adjust poll/debounce only in host/test contexts |
| Polling uses mtime plus size | A same-second rewrite that keeps both the timestamp and size identical may be missed | Save again, touch the file, or press **Reload**; there is no filesystem watch handle in the preview |
| Installed mods are never watched | A copy under `user://mods` cannot hot-reload, even in developer mode | Develop under `user://mods_dev` |
| Safe mode and panic disable reload | No mod is watched or reactivated after safe mode/session disable | Restart normally when the problem is fixed |
| A syntax error during reload leaves the mod failed | The failure card appears instead of the old version | Fix the file and save again (developer mode) or **Reload**; use **Open log** |
| No storage migration hooks | Changing a storage schema means writing your own version field | Store a schema version in KV and migrate lazily |

## Platform, UI and accessibility

| Issue | Impact | Workaround / status |
| --- | --- | --- |
| Windows is the reference platform | Behavior is verified primarily on Windows | Linux is preview-only, best effort; macOS is not supported |
| Linux desktop pass has not been run | Hot reload, presets and labels are unverified on Linux | Treat Linux as preview-only this cycle |
| Keyboard-only, screen-reader, IME and real-window checks are pending | The accessibility gates are not signed on a desktop build | Use the pending checklist in [`../developer/manual-test-checklist.md`](../developer/manual-test-checklist.md); report accessibility problems with exact focus order |
| Frame-time and typing-latency budgets are headless-only | Real rendering cost under a shell takeover is unmeasured | Keep widget trees small; report slow layouts with the widget count |
| Reference course needs Python and a trusted workspace | The five-lesson freeform validation cannot run without both | Install Python, open the workspace folder, mark it trusted |
| Screenshots are pending | Docs show no captured preview UI | Use [`../archive/mod-platform/reference-course-screenshots.md`](../archive/mod-platform/reference-course-screenshots.md) |

## Diagnostics and support

| Issue | Impact | Workaround / status |
| --- | --- | --- |
| No telemetry or automatic crash upload | Reports depend on the user copying the log | Include the log and exact error code in the issue; no data is sent automatically |
| Per-mod logs are in memory and the failure card only opens the current log | Reproducing an earlier failure can lose context | Copy the log before disabling or restarting |
| The Mods page is the only management surface | No CLI installer or batch consent flow | Manage folders and consent from the page |
| `permissions.has` can disagree with the actual call | It is display-only by design, not an entitlement | Handle `permission.denied` and `trust.required` at the call site |
| Godot 4.7.2 on Windows can exit with `0xC0000005` after `[ DONE ] savepack` during headless export | A shell build script sees a failed process even though the executable or PCK is complete; the normal preset reproduces it | Use `tools/mod-package/build_mod_preview.ps1`, which requires the completion marker and a non-empty artifact before treating the shutdown crash as benign. Smoke-test the artifact with `--headless --quit-after 5` |

## Not bugs

These are deliberate API 1.0 decisions:

- A mod cannot read another mod's storage, settings or progress.
- A mod cannot execute a host command or another mod's command.
- A mod cannot open a workspace folder; the host owns the trust boundary.
- `documents.write` does not imply `documents.read`; reading text needs its own
  consent.
- Consent is bound to the package hash, so editing an installed package can
  invalidate consent.
- Panic (`Ctrl+Alt+Shift+Esc`) takes precedence over every mod input filter.
