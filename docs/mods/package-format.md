# Package format — `.gcm`

Status: **implemented.** This document describes the package container
that `ModPackage` validates and `ModInstaller` installs. It is a ZIP container,
not a custom binary format. `.gcm` is the preferred extension; `.zip` is
accepted for compatibility.

## Container layout

```text
my-mod-1.2.0.gcm
├── manifest.json          required, exactly at the root
├── main.lua               the manifest's entry file
├── lib/                   optional Lua modules
│   └── helpers.lua
├── assets/                optional images/content
│   └── icon.png
└── signature.json         optional, root only
```

- The package is a normal ZIP archive. Store (`method 0`) and deflate
  (`method 8`) are supported.
- `manifest.json` must exist at the archive root with exactly that name. The
  manifest schema and required fields are documented in
  [`manifest-reference.md`](manifest-reference.md).
- The declared `entry` must be a file in the package. The declared
  `assets.icon`, when present, must also be a file.
- Mods remain Lua-only. Native libraries and scripts are rejected by
  extension, not merely hidden from the loader.
- `signature.json` is optional. Without it the package is **unsigned** and
  requires an explicit user opt-in before install.

## Limits

Limits are enforced from the central directory and then checked again on the
real decompressed bytes and CRC32 values.

| Limit | Value |
| --- | --- |
| Package file | 64 MiB |
| Entries (files + directories) | 4096 |
| Total uncompressed size | 64 MiB |
| One uncompressed file | 16 MiB |
| Compression ratio | 100:1 for entries at or above 256 KiB |
| Entry path | 240 characters |
| Directory entry compressed payload | 4096 bytes, with zero uncompressed content |
| `signature.json` | 64 KiB |
| `manifest.json` | 256 KiB |

ZIP64, multi-disk archives and encrypted entries are rejected. Directory
entries may not carry data; the small compressed allowance exists because
Godot's `ZIPPacker` emits deflated empty directory entries.

## Path rules

Every entry name must satisfy all of these:

- Use forward slashes; backslashes are rejected.
- Be relative: no leading `/`, drive letter, UNC prefix or empty segment.
- Be at most 240 characters.
- Contain no `.` or `..` segments, and no segment ending in a dot or space.
- Contain no control characters and none of `<>:"|?*`.
- Avoid Windows reserved device names (`con`, `prn`, `aux`, `nul`, `com1`…,
  `lpt1`…), including names with an extension such as `con.txt`.
- Be unique case-insensitively. `Main.lua` and `main.lua` in one archive are a
  duplicate and reject the whole package.

Symbolic links are rejected from the ZIP external attributes. File entries
marked as directories and directory entries marked as files are rejected.
Entries that are neither regular files nor directories are rejected.

## Blocked file types

Executable, native and script-container extensions are rejected wherever they
appear. The authoritative list is `BLOCKED_EXTENSIONS` in
`src/features/mods/mod_package.gd`; it currently covers:

```text
exe dll so dylib bat cmd com msi scr pif ps1 psm1 sh bash zsh fish
jar vbs vbe js jse wsf wsh hta reg lnk url cpl sys drv ocx xll ko wasm luac
```

A package may contain `.lua`, data, Markdown, images and other non-executable
assets. A blocked file is a package error, not a warning.

## Canonical digest

The package digest is SHA-256 over the file tree, excluding the root
`signature.json`. It is independent of ZIP ordering and compression.

For every file, sorted by relative path ascending:

```text
UTF-8(relative_path)
0x00
8-byte big-endian byte length
raw file bytes
```

The SHA-256 of that stream is the digest, written as 64 lowercase hex
characters. Directories are not hashed. The registry, consent records,
publisher signatures and rollback checks all bind to this same digest.

`ModPackage.digest_folder()` computes the same value for an extracted installed
folder, so a package digest can be compared with the bytes on disk.

## `signature.json`

The signature is an Ed25519 signature over a domain-separated message. It is
not a signature over the ZIP bytes, so re-compressing or reordering the archive
does not invalidate it; changing any file, path or the manifest does.

```json
{
  "schema": 1,
  "algorithm": "ed25519",
  "publisher_id": "com.example.studio",
  "public_key": "64 lowercase hex characters",
  "signature": "128 lowercase hex characters",
  "package_hash": "64 lowercase hex characters",
  "key_id": "64 lowercase hex characters",
  "signed_at": 1767225600,
  "display_name": "Example Studio"
}
```

| Field | Required | Rule |
| --- | --- | --- |
| `schema` | yes | Must be `1` |
| `algorithm` | yes | Must be `ed25519` |
| `publisher_id` | yes | 2–64 characters, lowercase `a-z`, `0-9`, `.`, `_`, `-`; used as the trust-store key |
| `public_key` | yes | 32-byte Ed25519 public key as 64 hex characters |
| `signature` | yes | 64-byte Ed25519 signature as 128 hex characters |
| `package_hash` | yes | Must equal the canonical digest |
| `key_id` | no | If present, must equal SHA-256 of `public_key` (the fingerprint) |
| `signed_at` | no | Informational Unix timestamp; not validated for freshness |
| `display_name` | no | Human-readable publisher name shown in the review UI |

Unknown fields are rejected rather than ignored. The signature block itself is
not part of the digest, so it cannot sign itself.

The signed message is UTF-8:

```text
GRIDDYCODE-MOD-PACKAGE-V1
<package_hash>
<publisher_id>
<public_key>
```

The version line is the domain separator. Binding the publisher id and public
key means an attacker cannot move a valid signature to another publisher id or
swap the embedded key without invalidating it. `signed_at` and `display_name`
are not signed; they are display metadata.

## Validation and extraction order

`ModPackage.validate_archive(path)` is the only review entry point:

1. Check extension, existence, non-empty file and the 64 MiB package cap.
2. Parse the end-of-central-directory record and every central-directory
   entry. Reject ZIP64, multi-disk, encryption, unsupported compression,
   unsafe paths, duplicates, symlinks, blocked files and size/ratio violations.
3. Read every file into memory, enforcing real sizes and CRC32 values.
4. Parse and validate `manifest.json`; check the entry and declared icon.
5. Compute the canonical digest.
6. If `signature.json` is present, validate its schema and metadata, require
   `package_hash == digest`, and verify the Ed25519 signature.

No file is written to disk during validation. `ModPackage.extract()` is only
called after `validate_archive()` succeeds, and it re-checks each entry's real
size and CRC before writing. `ModInstaller.install()` then validates the
extracted folder and requires its digest to match the reviewed digest.

## Creating a package

The supported workflow is the repository tool:

```powershell
# Unsigned package from a folder
.\Tools\mod_package.ps1 pack --dir .\MyMod --out .\MyMod.gcm

# Sign a validated package
.\Tools\mod_package.ps1 sign --package .\MyMod.gcm `
    --key .\Keys\com.example.studio.private.json `
    --out .\MyMod.signed.gcm

# Verify before publishing
.\Tools\mod_package.ps1 verify --package .\MyMod.signed.gcm --require-signature
```

The tool uses the same validator and Ed25519 code as the editor, so a package
it creates follows the imported-package rules exactly. See
[`publisher-guide.md`](publisher-guide.md) for key generation and custody.

`pack` excludes an existing root `signature.json` and writes an unsigned
archive; `sign` never modifies its input. Both commands write `.gcm`/`.zip`
only.

## What the format does not provide

- No hosted registry, automatic update feed or download path in v1. Packages
  are imported from a local file.
- No revocation list, key expiry, trusted timestamp or transparency log. A
  compromised publisher key stays trusted until the user replaces or forgets
  it.
- No multiple signatures. One package has at most one publisher signature.
- No anti-malware scanner. The capability boundary and explicit consent limit
  what a mod can do; they do not make arbitrary Lua safe.
