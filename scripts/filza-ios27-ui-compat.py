#!/usr/bin/env python3
"""Backport the two verified Filza 4.0 iOS 27 UI fixes to a matching base.

This does not touch dylibs, sandbox access, signing, or the worse_query implementation.
Fails closed if either input differs from the exact known original or patched hash.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import tempfile


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def rewrite_macho(original: bytes, patch: dict) -> bytes:
    result = bytearray(original)
    for entry in patch["patches"]:
        off = int(entry["offset"], 16)
        before, after = bytes.fromhex(entry["before"]), bytes.fromhex(entry["after"])
        if len(before) != len(after) or original[off:off + len(before)] != before:
            raise ValueError(f"Mach-O patch preimage mismatch at 0x{off:x}")
        result[off:off + len(after)] = after
    return bytes(result)


def rewrite_nib(original: bytes, patch: dict) -> bytes:
    pieces = []
    cursor = 0
    for entry in patch["patches"]:
        start, end = entry["start"], entry["end"]
        if not (cursor <= start <= end <= len(original)):
            raise ValueError("NIB patch offsets overlap or are out of bounds")
        pieces.extend([original[cursor:start], bytes.fromhex(entry["replacement"])])
        cursor = end
    pieces.append(original[cursor:])
    return b"".join(pieces)


def apply(app: Path, manifest: dict, check_only: bool) -> None:
    pending = []
    for kind, transform in [("mach_o", rewrite_macho), ("nib", rewrite_nib)]:
        meta = manifest[kind]
        path = app / meta["path"]
        content = path.read_bytes()
        got = sha256(content)
        if got == meta["sha256_after"]:
            print(f"{kind}: already patched, SHA-256 {got}")
            continue
        if got != meta["sha256_before"]:
            raise ValueError(f"{kind}: unknown version at {path}, SHA-256 {got}; aborting")
        changed = transform(content, meta)
        if sha256(changed) != meta["sha256_after"]:
            raise ValueError(f"{kind}: target checksum did not match; aborting")
        pending.append((path, changed))
        print(f"{kind}: validated {len(content)} -> {len(changed)} bytes")
    if check_only:
        print("Check only; no files modified")
        return
    for path, changed in pending:
        mode = path.stat().st_mode & 0o777
        with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as tmp:
            tmp.write(changed)
            staged = Path(tmp.name)
        try:
            os.chmod(staged, mode)
            staged.replace(path)
        finally:
            staged.unlink(missing_ok=True)
    print("UI compatibility patch complete; binary signature must be reapplied")


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--app", type=Path, required=True, help="Unpacked Filza.app directory")
    p.add_argument("--manifest", type=Path, default=Path(__file__).with_suffix(".json"))
    p.add_argument("--check-only", action="store_true")
    args = p.parse_args()
    manifest = json.loads(args.manifest.read_text())
    if manifest.get("schema") != 1:
        p.error("unsupported manifest schema")
    apply(args.app, manifest, args.check_only)


if __name__ == "__main__":
    main()
