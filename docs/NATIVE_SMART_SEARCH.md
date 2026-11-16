# Filza native fuzzy search

This component enhances **existing** search UI; no new editor, popup, toolbar button, or replacement text view.

## Audited native paths (Filza base binary)

- File browser: SearchController.searchFiles builds an NSRegularExpression
  using [SearchController text], enumerates filenames and checks matches.
  Filename searches use searchType = 0.
- Text editor: TGFastTextEditViewController.textEditor is an ICTextView;
  searchBar:textDidChange: and nextOrprevious: call
  ICTextView.scrollToMatch:searchDirection:.
- ICTextView.initializeSearchWithPattern: creates ICRegularExpression from
  the original document and native search options. That class handles
  match indexes, highlights and previous/next navigation.

The bridge intercepts **only the query argument** at those native call
sites. It does NOT change UITextView.text, attributed text, text storage,
HHighlightr or syntax highlighting. All matching/highlighting remains
native.

## Matching rules

- Case-insensitive, including all-uppercase and mixed-case.
- Accent folding for common Latin letters, including Portuguese.
- Spaces, underscores and hyphens split input into independent terms.
- CamelCase query boundaries also split into terms.
- Multiple terms can appear in any order, within the same filename or
  the same text line. They must all be present.
- An explicit prefix 're:' passes the remaining query through as a
  regular expression for advanced searches.
- A short single-term query matches any substring.
- Up to eight distinct terms, max 160 characters per query; queries
  outside this limit use the existing native behavior.

Examples:

    internal settings => internal_Settings
    internal settings => SettingsInternal
    internal settings => INTERNAL-SETTINGS
    cafe              => Café
    settings internal => SettingsInternal
    re:^settings      => unchanged regular expression

The file search retains filename/type filtering and native results; its
non-name search types are left unchanged. Text-editor search uses the
native ICTextView match index, count, and next/previous navigation.
For multiple terms, native highlighting will encompass the matching
line, since a full line contains all terms even when their order differs.

## Notes / verification

- The presence of a method in static Objective-C metadata is not proof
  that every Filza runtime calls it. Verify on the exact built IPA.
- There are no changes to the original plist editor, file writing, or
  filesystem access backend.
- Compilation in GitHub Actions validates ABI/source compatibility,
  not the actual match behavior on iOS. Device verification still needed.
- The existing inline Base64 projection and its UI issues are a
  separate feature and are not changed by this search component.
