# Filza — reversible native text editor for encoded data

The feature runs in the **existing** `TGFastTextEditViewController` and
`ICTextView/HCodeAttributedString`. It does not replace Filza's plist editor,
text editor UI, filesystem access, permissions, or native Save button.

## Design

A document session contains two representations:

1. **Source snapshot**: the exact XML/JSON text loaded by Filza and all
   original Base64 strings/NSData representations. This is never rewritten
   just to make a value readable.
2. **Readable projection**: transient editor text that shows Base64 content
   as JSON, XML plist, UTF-8, or editable hex bytes.

Every projected node is linked to its original encoding and JSON path in
backend-only metadata, never in an extra JSON field or a visible marker.
An unchanged node reconstructs the identical original encoded text.

The native Save handler receives **reconstructed source text**, never the
synthetic readable projection. Only a decoded value the user changed is
re-encoded; the other encoded values remain their original strings/bytes.
For a nested edit, the edited node and **only its necessary containing
Base64 layers** must be rebuilt, from the innermost value outward.

## Supported formats

- XML plist `<data>` contents and Base64 stored in plist `<string>` values.
- Nested XML/binary plists recursively, preserving the original inner plist
  format (binary remains `bplist00` on write).
- JSON arrays and objects stored inside Base64 NSData/string values; nested
  Base64 JSON string fields are decoded recursively.
- Standalone JSON documents opened in Filza's text editor.
- Base64 and Base64URL with or without `=` padding; original alphabet,
  padding preference, and line wrapping are kept when modifying a value.
- Printable UTF-8 content; otherwise the decoded bytes are shown in editable
  HEX notation instead of being mislabeled as text.
- Ordinary non-encoded values continue to be editable as usual.

**Plain words can also happen to be valid Base64 syntax.** Decoding every
4-character word would corrupt the UI (for example, ordinary identifiers and
names). The editor checks canonical encoding and uses structure/printability
and Base64 transport features to avoid false positives. An undecidable short
unmarked value remains unchanged rather than being converted speculatively.
Opaque/compressed/encrypted data cannot necessarily be rendered as meaningful
JSON or plist; unknown bytes use HEX. Very large documents and deeply nested
records are bounded to prevent exhausting the iPhone's memory.

## Minimal write behavior

- **No edits:** returns the original document, byte-identical.
- **One edited XML Base64 leaf:** restores only that body from the original
  XML source, retaining surrounding tags, whitespace, unrelated Base64
  strings and line endings.
- **One edited JSON leaf:** indexes the original JSON scalar ranges, replaces
  only modified values, and validates that parsing yields the edited structure.
  Unmodified formatting, order and unrelated Base64 strings are unchanged.
- **Changed JSON object/array shape:** only that JSON carrier may need full
  JSON serialization; the outer encoded-document tree is still selective.
- **Ambiguous original JSON/invalid edited XML, JSON or HEX:** refuses Save and
  displays an error; does not silently write a partially decoded document.
- **Original outer binary plist:** Filza's own `loadText` transforms it into
  XML for text editing and its original native Save decides the binary output
  format. The reversible codec operates on that XML view.

A direct inspection of the original Filza 4.0 Mach-O confirms the relevant
`loadText` call path uses `propertyListWithData:` and
`dataWithPropertyList:format:` before calling `ICTextView.setText:`.
`saveClicked:` reads the text view, validates/parses the resulting data,
and writes through Filza's existing privileged file service. This patch
does not hook that service.

## Regression tests

`tests/FilzaInlineCodecTests.m` exercises the same Foundation-only source
used by the iOS editor. Scenarios include 6,916 numeric synthetic ABProps
entries, original binary plist data, nested JSON/Base64/HEX edits, Base64URL,
untouched sibling values, a byte-identical no-op, JSON scalar-only source
rewrites and malformed input refusal. The Xcode 27 Actions workflow runs
these tests before Theos compilation and packaging.

## Research and implementation choice

- [Apple PropertyListSerialization](https://developer.apple.com/documentation/foundation/propertylistserialization)
  reliably validates XML/binary plists and preserves semantic values, but
  reserialization alone does **not** preserve original layout.
- [libimobiledevice/libplist](https://github.com/libimobiledevice/libplist)
  is a capable XML/binary plist parser/converter but converts whole documents
  rather than providing this editor's selective byte-preserving overlay.
- [json-zig](https://github.com/sakakibara/json-zig) demonstrates a lossless
  source-token model. This implementation uses native Foundation with a
  range-based JSON scalar editor, avoiding bundling a Zig runtime into iOS.

No third-party parser code has been copied; this is a native Objective-C
integration with the stock Filza editor. A successful CI build proves
compilation and codec tests, **not** visual correctness on a physical iPhone.

## iOS editor freeze and UUID regression (2026-11-16)

- UUID strings like `659E2047-9BC6-4413-9702-1940A688D834` are never Base64.
- Binary payloads without known readable content remain in their original Base64 transport: there is **no implicit HEX view**.
- Base64 words that decode to real UTF-8 and recognized JSON or plist containers still display inline; parent Base64 is restored only on edited values.
- The editor retains the native `HCodeAttributedString` colored content. Only Base64 leaf *bodies* are replaced with source-range edits; other colored XML tags/keys are never replaced.
- The serializer runs on a background queue. The main thread only performs individual text-storage edits and does not highlight the entire document.
- Visual projection is skipped when it exceeds a resource safety limit instead of freezing; the untouched original editor remains available.
- iPhone runtime testing is still needed to confirm TextKit drawing and responsiveness on real large plists.
