# Migration notes — to API 1.0 (Developer Preview)

## What changed at the freeze

In earlier previews the native API, permission annotations and error codes were
experimental. The Developer Preview freezes them as **API 1.0.0**:

| Constant | Value |
| --- | --- |
| `Api.API_VERSION` | `1` |
| `Api.API_SEMVER` | `"1.0.0"` |
| `Api.API_STATUS` | `"frozen"` |
| `Api.API_FROZEN` | `true` |
| Native methods | 100 |
| Golden surface hash | `f0b0f31993c7924ceae2301d902c5ff26ac7510582a86bc17797dbe9fb6bbf09` |

No method was renamed, removed or re-annotated to produce 1.0. The freeze makes
the existing surface a promise; it is not a redesign. Manifests that declared
`api = 1` and worked in the previous Developer Preview continue to load. `status_report()`
now also exposes `api_semver`, `api_frozen`, `preview_build`, `developer_mode`,
`dev_root`, `dev_mods`, `dev_watched` and `hot_reload`; these are host
diagnostics, not mod-callable methods, so the 100-method contract is unchanged.

## Mod author checklist

1. **Declare the API version.** The manifest needs `"api": 1` and a
   `min_editor` no newer than the build you test on (`1.4.0` for this preview).
2. **Use only catalogued permissions.** `input.observe` and `network` are
   reserved and rejected. A manifest with `"permission"` instead of
   `"permissions"` is rejected by design.
3. **Plan for explicit consent.** A mod declaring `documents.read`,
   `documents.write`, `files.*`, `workspace.read`, `run`, `ui.shell`, or the
   clipboard/terminal/layout permissions starts in the `blocked` state until the
   user grants consent. `core` is granted on install. Do not treat
   `editor.permissions.has` as an entitlement.
4. **Trust is separate from consent.** `files.*`, `run` and `terminal.write`
   also need a trusted workspace. Handle `trust.required` with a clear
   notification and a path that does not require the capability.
5. **Use stable ids and namespaces.** Command ids are `<mod_id>.<local>`;
   widget ids become `<mod_id>.<local_id>`; events emitted by a mod must be
   namespaced to it.
6. **Clean up in `deactivate()`.** Unmount panels, cancel timers and release
   dialog handlers. The host tears down registrations, but an explicit
   `deactivate` keeps reloads predictable.
7. **Do not rely on module load order.** `require` is cached per activation;
   `lib` modules return a table and may be loaded lazily.
8. **Keep data under the mod id.** Storage, progress and settings live under
   `user://mod_data/<id>/`; do not write next to the package.

## If you developed against an earlier preview

- The native method names and permission annotations are unchanged from earlier
  previews. A mod that used `docs.*`, `ui.*`, `guide.*`, `exercise.*` or
  `ui.shell.*` needs no API rewrite.
- The Mods page now labels the release **Developer Preview · API 1.0** and adds
  a **dev · hot reload** badge for copies loaded from `user://mods_dev`.
- Developer mode is on for debug builds and with `--mod-dev`. The preview build
  feature is `mod_preview` or the `--mod-preview` flag. Neither changes mod
  behaviour; they change labeling and which roots are scanned.
- Hot reload is new and watches only `main.lua` and `lib/**/*.lua` in
  `user://mods_dev`. Installed mods are never watched. A manifest edit needs a
  restart or the Mods page **Reload** button.

## If you have legacy `langs/` or `themes/` Lua

The classic plugin format (`user://langs`, `user://themes`) is not an API 1 mod.
It is not migrated automatically, is not listed in the Mods manager, and keeps
its existing loading and restart behaviour. The mod platform does not wrap it as
"Legacy" in the preview because doing so would imply a consent and lifecycle
model it does not have. Porting a language or theme extension to a real mod is
possible only for the surfaces API 1 exposes; syntax highlighting and theme
mutation are not part of API 1.0.

## Compatibility and deprecation policy after 1.0

- **Additive changes stay in API 1.** New methods, new optional fields or new
  widget types are allowed, but they must update the golden fixture, this doc
  set and the samples in the same change. Existing calls keep their meaning.
- **Permission changes need a consent migration.** Adding a permission to an
  existing mod, tightening a permission, or making a permission trust-gated
  requires a fresh consent prompt and a note here. A stored record that does not
  cover the new set is not reused silently.
- **Breaking changes require API 2 and an adapter.** Renaming or removing a
  native method, changing its argument shape, or changing an error code's
  meaning cannot happen inside 1.x. The host keeps API 1 available alongside
  API 2 during a migration window.
- **Error codes are stable names.** New codes are additive. Existing codes keep
  their documented meaning; `Result.CODES` is the source of truth.

## Version support

The preview targets editor `1.4.x`. `min_editor` is required on every manifest;
`max_editor` is optional and blocks activation, not installation, so a user can
update instead of losing a package. A manifest that targets an API other than 1
is blocked with `manifest.version_range`; there is no implicit downgrade or
upgrade of a package.

## Rollback

Installed packages keep a previous version in the registry when an update
changes the package hash or version. Deleting `user://mod_registry.json` makes
the next launch rebuild discovery from disk; mod data under
`user://mod_data/<id>/` is untouched. For a developer copy, restore the folder
from version control and restart; hot reload applies the next save.
