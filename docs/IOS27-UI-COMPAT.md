# Filza 4.0 — iOS 27 UI crash compatibility backport

## Provenance

This backport was reconstructed by byte-comparing three user-provided archives:
`Filza.ipa`, `Filza-iOS27-array-guards-UNSIGNED.ipa`, and
`Filza-4.0-iOS27-plist-editor-fixed-UNSIGNED.ipa`.
The final archive was reported to work on the user's test device.

Only two resources differed between the first and final archives:

| Path relative to Filza.app | Change |
| --- | --- |
| `Filza` | Eight ARM64 BL call sites redirect to two bounds-checked helpers |
| `TGPlistViewController.nib` | Remove legacy `UISearchDisplayController` and five related outlet/delegate connections |

Original ARM64 call sites: `0x224964`, `0x2249a8`, `0xafd78`,
`0xafe00`, `0xafe40`, `0xb0124`, `0xb01ac`, `0xb01ec`.
The two small helper functions replace the unused iOS 7 Touch ID
implementation starting at `0x22463c`.

The NIB removal fixes the exception at `-[UISearchDisplayController initWithCoder:]`
on the structured plist editor load path. It may disable the editor's legacy
search UI. No plist persistence, serialization, sandbox, or exploit logic is changed.

## Compatibility contract

The patch is **version-specific**, not a universal iOS 27 patch.
It requires the exact original resource SHA-256 values:

- `Filza`: `467e01e7c5e4df57311a6329624f29c94e51088a383d651b51687725684b5d09`
- `TGPlistViewController.nib`: `0c18ed9d23356e75f625f2ccfe47a8d9b4ee6e1ef31d05e8e9298e3d2247420a`

Expected outputs:

- `Filza`: `5078da6f6e84138eac6212993cc89e2ba10c45f83e6c2953e90c193efcbbcbbe`
- `TGPlistViewController.nib`: `7b721f251c9f84b273f696df251d8e67a42b79aef564a556e0f97bc9105aab40`

`scripts/filza-ios27-ui-compat.py` requires both inputs to match their known
original or known patched hashes. A mismatch aborts without writing either file.
Deltas are in `scripts/filza-ios27-ui-compat.json`; no complete proprietary
Mach-O or NIB resource is committed.

## CI workflow

`.github/workflows/diagnose-full-build.yml` now uses the native
`xcode-27` ARM64 macOS runner and explicitly checks the iPhoneOS SDK major
version. Theos still targets **minimum iOS 17.0**; selecting Xcode/iOS SDK 27
does **not** change the deployment target to 27.

The workflow:

1. Downloads the SHA-256-pinned base IPA.
2. Checks resource compatibility **before** building the tweak.
3. Builds the existing tweak and bundled dependencies using Xcode 27.
4. Applies the UI backport to the base app's executable and NIB at staging.
5. Packages an unsigned IPA and uploads it as a workflow artifact.

**Important:** The repository currently pins
`FilzaSlop-v1.0.2-unsigned.ipa` with SHA-256
`b11ce30a2db6f6bc77773ed30bdb855d7c847830891b14d21230f2d893d5f223`.
Its executable/NIB equivalence to the original user-provided Filza 4.0 IPA
must be verified in CI. A different upstream build will deliberately fail
the preflight; never disable the SHA checks or apply offsets blindly.

This is a build of the existing tweak plus a prebuilt Filza app, **not** a
source-level recompilation of the proprietary Filza executable. The IPA is
unsigned and must be signed appropriately for installation.

## Local reproducer

After extracting the original Filza IPA:

```sh
python3 scripts/filza-ios27-ui-compat.py --app Payload/Filza.app --check-only
python3 scripts/filza-ios27-ui-compat.py --app Payload/Filza.app
```

The script can safely be rerun; already patched resources are detected by hash.
For device testing, use disposable plist files first and verify reading,
editing, saving, reopening, and the Security screen. No automated CI job can
prove iOS runtime behavior.
