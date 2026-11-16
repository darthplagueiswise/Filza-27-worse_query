# Inline decoded plist data in Filza's EXISTING Text Editor

This replaces the earlier Base64 navigation button implementation.
No new toolbar button, menu, sheet, or secondary editor is installed.
Filza's original plist editor is intentionally untouched.

## What is different

A plist opened as **Text** is still displayed in Filza's syntax-highlighted
text editor, with the same visible <plist>, <dict>, <key>, <data>, and
<string> markup. Instead of Base64 noise between the *existing* <data>
tags, the content is projected inline as its decoded plist dictionary,
JSON, readable UTF-8, or hexadecimal data.

For example, the existing markup:

    <key>DownloadPolicy</key>
    <data>YnBsaXN0MDD...</data>

is displayed *in that exact part of the document* as something like:

    <key>DownloadPolicy</key>
    <data>
        <dict>
            <key>$archiver</key>
            <string>NSKeyedArchiver</string>
            ...
        </dict>
    </data>

The view is a **reversible projection**. It is not a valid disk plist until
the original Base64 encodings are restored by the save bridge. Ordinary
text outside the projected fields is left in place, byte-for-byte at the
string level (subject to the original file encoding and native Filza save).

Plists embedded inside <data> are rendered recursively (maximum 18 levels).
JSON text embedded in <string> fields is pretty-printed in place.
Unrecognized binary fields display hexadecimal; their original bytes remain
unchanged if not edited. Foundation's property-list XML serializer may not
represent some NSKeyedArchive UID data; such data falls back to HEX rather
than creating an invalid or lossy fake representation.

## Saving

When the native editor's save/done action is dispatched through UIKit,
the text getter temporarily supplies a rebuilt XML document:
- Unedited projected fields recover their **exact original Base64**, including
  all original line breaks.
- Edited nested plists are encoded in their original binary/XML form, then
  all parent layers are encoded back to Base64.
- Edited embedded JSON is parsed and reserialized.
- Edited raw bytes are strictly validated as hexadecimal.
- Before the original Filza save action proceeds, the whole reconstructed
  plist is validated. Invalid nested data block the save with an error.

The *visible editor text* is never replaced with Base64 on-screen.

**Runtime caveat:** the original Filza executable is closed-source. This
bridge uses the native text/code editor UIViewController, UITextView and
UIKit save-action dispatch points. If a particular Filza build saves from a
custom internal text buffer, performs asynchronous text reads, or does not
dispatch its save action via UIApplication, the native save path must be
investigated and adapted against that exact build. This is NOT proof that
the file was safely rewritten on-device just because a CI build succeeds.

Binary plist on-disk preservation also depends on Filza's native save
implementation; its text editor may save XML rather than binary. The
original source format must be independently verified on device.

## Scope

The filesystem backend, app-group resolver, plist viewer, file navigation,
and all existing Filza features remain unchanged. This does not change
filesystem entitlements or introduce a new write primitive.

## Testing

1. Open a copy of a known plist through **Text Editor**, not Plist Editor.
2. Confirm there is NO Base64 button; decoded content appears inline.
3. Without editing, save a copy and compare its parsed tree to the source.
4. Edit an inner numeric/string/boolean field and save; reopen and validate
   the new nested plist bytes and the unchanged outer fields.
5. For binary originals, compare initial and final on-disk header (bplist00)
   and report format drift instead of assuming it stayed binary.
6. Test malformed embedded data; saving must fail before corrupting the file.
