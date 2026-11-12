#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/home/.cargo" "$TMP/bin" "$TMP/src/rust-core" "$TMP/out"
# Reproduces the hosted runner failure: sourcing this file exits the caller.
printf 'exit 73\n' > "$TMP/home/.cargo/env"

cat > "$TMP/bin/rustup" <<'EOT'
#!/usr/bin/env bash
exit 0
EOT
cat > "$TMP/bin/cargo" <<'EOT'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$OBSERVED_CARGO_ARGS"
exit 42
EOT
chmod +x "$TMP/bin/rustup" "$TMP/bin/cargo"

# This stub never builds the Rust library; it tests only shell preflight.
set +e
HOME="$TMP/home" PATH="$TMP/bin:$PATH" OBSERVED_CARGO_ARGS="$TMP/cargo-args" \
  bash "$ROOT/scripts/build-nfcard-ffi.sh" "$TMP/src" "$TMP/out" > "$TMP/stdout-stderr" 2>&1
status=$?
set -e

if [[ $status -ne 42 || ! -f "$TMP/cargo-args" ]]; then
  echo "FAIL: expected stub Cargo to be reached (exit=42); observed exit=$status" >&2
  cat "$TMP/stdout-stderr" >&2
  exit 1
fi
if [[ "$(cat "$TMP/cargo-args")" != 'build --release --target aarch64-apple-ios' ]]; then
  echo "FAIL: wrong Cargo arguments" >&2
  cat "$TMP/cargo-args" >&2
  exit 1
fi
echo 'PASS: unsafe cargo/env does not terminate build before Cargo'
