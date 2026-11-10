# Publisher guide — signing and trust

Status: **implemented.** This guide is for mod authors who publish `.gcm`
packages and for users who review them. The format itself is documented in
[`package-format.md`](package-format.md).

A signature proves that the package was signed by the key embedded in
`signature.json`. It does **not** prove that the publisher is trustworthy. The
editor therefore pins a publisher key on first use: a new publisher, or a
publisher whose key changed, stays blocked until the user explicitly trusts the
key fingerprint shown in the review dialog.

## 1. Generate a publisher key

```powershell
.\Tools\mod_package.ps1 keygen `
    --publisher com.example.studio `
    --display-name "Example Studio" `
    --out .\Keys
```

Output:

```text
Created ...\Keys\com.example.studio.private.json
Keep this file private. Anyone with it can sign packages as this publisher.
Public key:   <64 hex characters>
Fingerprint:  <64 hex characters>
Public file:  ...\Keys\com.example.studio.public.json
```

The publisher id is a namespace, not a verified legal identity. Use a reversed
domain or another stable id you control. It must be 2–64 characters of
lowercase `a-z`, `0-9`, `.`, `_` and `-`, and it is the key in the local trust
store.

The fingerprint is SHA-256 of the 32-byte public key. It is what the review
dialog shows in a grouped short form; the full value is in the tooltip.

### Private-key custody

`<publisher>.private.json` contains the raw 32-byte seed as hex. **Anyone with
that file can sign packages as this publisher.** V1 has no key passphrase and
no hardware-key support.

- Keep the private file out of the mod repository, build artifacts and chat.
- Prefer an offline machine or an encrypted volume for signing.
- Do not share the private file with testers; share only the signed package.
- Back it up. Losing it means you cannot publish updates under the same
  publisher id unless users accept a replacement key.
- The public file is safe to publish; it is only a convenience record.

## 2. Build an unsigned package

```powershell
.\Tools\mod_package.ps1 pack --dir .\MyMod --out .\MyMod.gcm
```

`pack` validates the folder with the same rules as an imported package and
writes an unsigned archive. It prints the canonical digest. A folder layout
looks like:

```text
MyMod/
├── manifest.json
├── main.lua
├── lib/
│   └── helpers.lua
└── assets/
    └── icon.png
```

An existing root `signature.json` in the folder is excluded; sign after
packing, not before. Do not edit the archive after signing.

## 3. Sign the package

```powershell
.\Tools\mod_package.ps1 sign `
    --package .\MyMod.gcm `
    --key .\Keys\com.example.studio.private.json `
    --out .\MyMod.signed.gcm
```

`sign` validates the input, computes the digest, builds the domain-separated
message, signs it and writes a new archive with `signature.json`. The input is
not modified. The command refuses to write to the input path.

The signature binds:

- the canonical package digest (every file path and byte),
- the publisher id,
- the public key.

Re-compressing or reordering the ZIP does not break the signature. Changing a
Lua file, the manifest, a path or the embedded publisher metadata does.

## 4. Verify before publishing

```powershell
.\Tools\mod_package.ps1 verify --package .\MyMod.signed.gcm --require-signature
```

Expected output includes:

```text
Mod:         com.example.studio.my_mod v1.2.0
Digest:      <64 hex characters>
Signature:   valid
Publisher:   com.example.studio
Fingerprint: <64 hex characters>
```

If the archive is unsigned, `--require-signature` exits non-zero. Use
`digest --package <file>` when you only need the canonical digest.

## 5. What users see

On import, the review dialog shows:

- package name, id, version, author and description;
- **Publisher id**, **Key fingerprint** (short form, full value in the
  tooltip), signature state and `signed_at` when present;
- for a new publisher: “Signature is valid. This publisher is not trusted
  yet.” and a **Trust publisher** checkbox;
- for a changed key: the old pinned fingerprint and a **Replace the pinned
  key** checkbox;
- permission growth, risk level and plain-language grants;
- update kind (install/update/reinstall/replace/downgrade), whether a rollback
  is available, contents and digest;
- every blocker that must be resolved before **Install** becomes enabled.

Trust is stored per publisher id in `user://mod_publishers.json`:

```json
{
  "version": 1,
  "publishers": {
    "com.example.studio": {
      "id": "com.example.studio",
      "public_key": "<64 hex>",
      "fingerprint": "<64 hex>",
      "display_name": "Example Studio",
      "trusted_at": 1767225600,
      "last_seen_at": 1767225600,
      "previous_fingerprint": ""
    }
  }
}
```

The first trust pins the fingerprint. Later packages must use the same key.

## Key rotation

When you intentionally replace a key, sign with the new private key and send
the package through the normal review. The publisher state becomes
`key_changed`. The user sees both fingerprints and must choose **Replace the
pinned key**; install stays blocked otherwise. On approval the store records
the new fingerprint and keeps the old one in `previous_fingerprint`.

If the private key is lost or compromised:

- Prefer publishing under a new publisher id; it avoids asking users to trust
  a replacement key for the old identity.
- If the id must stay, users have to re-trust the replacement explicitly. There
  is no revocation list or signed key-rotation statement in v1, so explain the
  change through your own channel.
- Do not ask users to disable checks or install unsigned packages as a
  workaround.

## Unsigned packages

A package without `signature.json` is accepted only when the user enables
**Allow this unsigned package** in the review dialog. The registry records
`allow_unsigned: true` for that install; an update still goes through review.
Unsigned packages are intended for local development and trusted private
hand-offs, not public distribution.

Installing an unsigned package does not disable later signature checks. If the
update is signed by a new publisher, the user still sees the normal trust
prompt.

## Tool reference

| Command | Purpose |
| --- | --- |
| `keygen --publisher <id> --out <dir> [--display-name <name>] [--force]` | Create a private/public key pair |
| `pack --dir <folder> --out <package.gcm>` | Validate a folder and write an unsigned package |
| `sign --package <input> --key <private.json> --out <signed.gcm>` | Sign a validated package |
| `digest --package <package.gcm>` | Print the canonical SHA-256 digest |
| `verify --package <package.gcm> [--require-signature]` | Validate the archive and verify the signature |

Direct Godot invocation works too:

```powershell
C:\Godot\Godot.exe --headless --path . `
    --script res://tools/mod-package/mod_package.gd -- verify --package .\MyMod.signed.gcm
```

The PowerShell wrapper accepts `-Godot <path>` if the editor is not at
`C:\Godot\Godot.exe`.

## Troubleshooting

| Message / state | Meaning | Fix |
| --- | --- | --- |
| `The Ed25519 signature does not verify.` | A file, path or the manifest changed after signing, or the signature/key is wrong | Rebuild and sign the exact archive again |
| `The signature covers a different package digest.` | `package_hash` does not match the package | Re-sign; do not edit `signature.json` by hand |
| `key_id does not match the public key fingerprint.` | `key_id` is stale or copied from another key | Regenerate `signature.json` with the tool |
| `The signing key for <name> changed.` | The publisher id is pinned to another key | Confirm the change through a trusted channel, then **Replace the pinned key** |
| `This package is unsigned.` | No `signature.json` | Sign it, or enable the explicit unsigned opt-in for a trusted local build |
| `Publisher '<id>' has not been trusted yet.` | First signed package from this id | Review the fingerprint and **Trust publisher** |
| `The extracted files do not match the signed package digest.` | The archive changed between review and install, or extraction was tampered with | Re-import the original package |
| `Entry '...' has a blocked extension.` | The package contains a native/executable file | Remove it; mods are Lua-only |
| `The update is older than the installed version.` | Downgrade policy | Enable **Allow installing an older version** only if intended |
| `This version is already on disk.` | Reinstall/replace policy | Enable **Replace** to reinstall the same version |

## Performance and implementation notes

Godot's built-in `Crypto` exposes RSA but not Ed25519, so Qorix uses a
pure-GDScript Ed25519 implementation (`src/features/mods/ed25519.gd`). Signing and
verification are slower than a native library — on the order of a few hundred
milliseconds in headless tests — but they run only during package review,
install, rollback and the CLI, never in a frame loop. The implementation
rejects non-canonical scalars and low-order public keys and is covered by RFC
8032 vectors in `test_mod_ed25519.gd`.

The implementation is not constant-time. It is appropriate for local package
verification against a signature the user is about to inspect, not for
server-side signing or protecting a private key from a local timing attacker.
See [`security-review.md`](security-review.md).
