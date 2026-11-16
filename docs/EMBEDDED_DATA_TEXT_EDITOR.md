# Filza native inline embedded-data editor

This module extends the ORIGINAL TGFastTextEditViewController and its
ICTextView/HCodeAttributedString, not the Filza plist editor. No new toolbar,
button, sheet or secondary editor is introduced.

## Why the previous build could not save

The old code relied on intercepting UIApplication.sendAction and temporarily
changing UITextView.text. That did not reliably run before Filza's native
saveClicked: method parsed XML and tried to save it. The view therefore sent
inline JSON directly inside <data> to NSPropertyListSerialization, which is
not valid plist XML, resulting in the system "data is not in the correct
format" error.

Native Mach-O inspection of Filza confirms saveClicked: gets textEditor.text,
parses plist with propertyListWithData:options:format:error:, and uses the
native property list serializer before writing to the original path.

The revised module hooks TGFastTextEditViewController.saveClicked: DIRECTLY,
validates and re-encodes every modified <data> block, then temporarily
returns reconstructed XML from ICTextView.text for that native save call.
The original save path, permissions, metadata handling, and binary output
logic remain the responsibility of Filza.

## Visibility and syntax

- Retains the original ICTextView and HCodeAttributedString text storage.
- Replaces projected content through NSTextStorage.beginEditing/replace/
  endEditing and requests the original highlighter to repaint it.
- Maintains the existing line numbers, navigation, search bar and Save UI.
- Indents only the DISPLAY version of XML/JSON/HEX nested payloads; added
  spacing is removed when re-encoding changed blocks.
- All valid opaque Base64 values in plist strings of length >=16 are now
  shown as HEX, including 16-byte binary identifiers.
- Does not claim opaque bytes are plaintext, nor interpret encrypted data.
- Labels gabp.* blocks as "WhatsApp ABProps" with their actual entry count;
  the labels are display-only XML comments and numeric IDs are not renamed.

## Recursive formats

- XML and binary plist recursively nested in NSData/Base64.
- JSON, including Base64-containing string values inside JSON objects/arrays.
- UTF-8 text and raw bytes as HEX.
- For Base64 hidden in JSON, the display uses a reversible structured
  __filza_inline_base64_v1__ wrapper showing its type, original string and
  decoded data. This wrapper is ONLY for display/editing: it is removed from
  JSON when the value is restored to Base64.
- Binary plist inside a JSON Base64 string is presented as editable XML
  (as a JSON string), when Foundation can encode its types; otherwise HEX.
- Unchanged payloads keep their exact original encoded bytes and wrapping.
- A changed payload is fully validated, then reserialized in its original
  plist/JSON/raw format; its containing Base64 is rebuilt from inside out.
- Unsupported proprietary, compressed, or encrypted carriers remain HEX
  without falsely representing their semantics.

## Safeguards

- Editing invalid embedded JSON/XML or HEX blocks prevents Save and reports
  an error rather than writing the invalid representation.
- Edited XML/plist roots must pass NSPropertyListSerialization before Save.
- The stock native Filza save method still determines the outer format
  (XML/binary), handles original file write privileges and shows write errors.
- The module does not alter sandbox, app-group, or filesystem privileges.

## Tests

The same source file can be compiled in a Foundation-only codec test mode.
The iOS 27 GitHub Actions workflow runs tests/FilzaInlineCodecTests.m before
the full Theos build. It uses ONLY SYNTHETIC DATA (no private WhatsApp
files). The tests verify 6,916 numeric parameter values, nested JSON and
Base64, 16-byte HEX, a no-edit byte-preserving reconstruction, edits across
formats, preservation of unchanged binary children, and invalid JSON
rejection. iPhone runtime behavior and native colors/save results still
require a device test; a successful CI build does not prove UI behavior.

## Upstream prior art

The embedded detection strategy is aligned with the concepts demonstrated
by MIT-licensed Plist-Parser (mb4n6/Plist-Parser) and plb (brunerd/plb);
the Filza integration is written with native Apple Foundation/UIKit to
avoid Python/shell runtimes and keep the existing editor.
No source code was copied from those repositories.
