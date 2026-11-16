# Embedded Base64 / Plist / JSON editor — Filza Text Editor

This is a companion to Filza's built-in **Text Editor**. It does not
modify, replace, or hook the visual plist editor.

## Open

Open an XML plist or JSON file through Filza's Text Editor.
A Base64 button is added to the editor's navigation bar when the
running Filza text-editor controller and its text surface/document are found.
Tap it to browse the parsed document in a searchable, nested tree.

For a binary plist, use the Text Editor route: when the controller exposes
the active file path, the companion reads and edits the original binary plist.
It does not depend on Filza's broken plist editor.

The Text Editor class name and file-path accessors belong to Filza's
closed-source runtime, so the exact hook/UI behavior must be verified
on an installed Filza build. The button intentionally does not appear
on the plist editor.

## Nested formats

- XML and binary plist (Foundation property-list serializer)
- JSON (including JSON embedded in plist string values)
- Base64 in plist strings and JSON strings, including multiple nested levels
- Binary plist / NSKeyedArchive represented as editable plist nodes
- DATA nodes, automatically decoded to contained plist, JSON, or UTF-8
- Unknown binary payloads, editable in hexadecimal
- Boolean, number, date, string, dictionary and array values

For ambiguous strings, choose Decode as Base64 explicitly. Raw/opaque
bytes can always be edited in hexadecimal, but proprietary compressed or
encrypted formats are not magically converted to semantic objects.

When a nested value changes, the child is serialized into its original
field representation, then all parent layers are serialized in turn.
The outer XML/binary/JSON kind remains unchanged. For unedited child
data, the original NSData bytes are retained.

## Save behavior

**Text input:** The final XML or JSON is applied back to the native
UITextView and Filza's existing save flow must be used to write the file.

**Binary input:** If Filza exposes an actual file path and that path is
readable/writable with the app's existing privileges, Save writes back to
that same path. Before writing, it verifies the file has not changed
since opening and stores an original-byte backup in:

    Documents/FilzaEmbeddedDataBackups/

The saved file is reread and compared against the serialized output.
If it fails, the editor attempts to restore the original bytes and
retains the backup. No filesystem access exploit, entitlement change,
or sandbox-bypass functionality is introduced by this editor.

## Important limitations / checks

- A plist reserialized by Foundation may differ in key ordering,
  indentation, byte offsets or other encoding details despite preserving
  equivalent values. Do not assume byte-for-byte equality after edits.
- A binary NSKeyedArchive is browsed as its serialized plist graph
  (e.g. $objects); this does not instantiate arbitrary archived classes.
- Plist numbers and JSON values are edited with type validation.
- Automatic Base64 recognition is conservative to avoid altering
  ordinary strings; valid ambiguous strings have a manual decode action.
- The native text editor may use a custom view rather than UITextView.
  The button is injected only into runtime controller classes that appear
  to be text/code editors. Verify against Filza's actual text editor.
- Files requiring unavailable permissions will not become writable
  simply because this UI exists.
- A GitHub build verifies compilation, not runtime private APIs.

No OpenPlist, ProperTree or other project code was copied; this component
uses Foundation/UIKit to fit the current Objective-C tweak build.
