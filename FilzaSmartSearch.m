// Smarter native search; no replacement UI, no text-storage modifications.
@import Foundation;
@import UIKit;
#import <objc/runtime.h>
#import <objc/message.h>

static char kFZSSearchEditorKey;
static __thread BOOL gFZSFileSearch;
static IMP gFZSSearchFilesOriginal;
static IMP gFZSFileTextOriginal;
static IMP gFZSEditorAppearOriginal;
static IMP gFZSScrollOriginal;

static NSArray<NSString *> *FZSTokens(NSString *query) {
    if (![query isKindOfClass:NSString.class] || !query.length || query.length > 160)
        return @[];
    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    NSMutableString *word = [NSMutableString string];
    NSCharacterSet *alnum = NSCharacterSet.alphanumericCharacterSet;
    NSCharacterSet *lower = NSCharacterSet.lowercaseLetterCharacterSet;
    NSCharacterSet *upper = NSCharacterSet.uppercaseLetterCharacterSet;
    NSLocale *locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    unichar last = 0;
    for (NSUInteger i = 0; i < query.length; ++i) {
        unichar c = [query characterAtIndex:i];
        if (![alnum characterIsMember:c]) {
            if (word.length) { [tokens addObject:word.copy]; [word setString:@""]; }
            last = 0;
            continue;
        }
        if (last && [lower characterIsMember:last] &&
            [upper characterIsMember:c] && word.length) {
            [tokens addObject:word.copy];
            [word setString:@""];
        }
        NSString *character = [NSString stringWithCharacters:&c length:1];
        NSString *folded = [character stringByFoldingWithOptions:
            NSDiacriticInsensitiveSearch | NSCaseInsensitiveSearch locale:locale];
        [word appendString:folded ?: character];
        last = c;
        if (tokens.count >= 8) break;
    }
    if (word.length && tokens.count < 8) [tokens addObject:word.copy];
    NSMutableOrderedSet<NSString *> *unique = [NSMutableOrderedSet orderedSet];
    for (NSString *token in tokens)
        if (token.length && token.length <= 64) [unique addObject:token];
    return unique.array;
}

static NSString *FZSCharRegex(unichar c) {
    switch (c) {
        case 'a': return @"[aáàâãäåāăą]";
        case 'e': return @"[eéèêëēĕėęě]";
        case 'i': return @"[iíìîïĩīĭįı]";
        case 'o': return @"[oóòôõöōŏőø]";
        case 'u': return @"[uúùûüũūŭůűų]";
        case 'c': return @"[cçćĉċč]";
        case 'n': return @"[nñńņň]";
        case 'y': return @"[yýÿŷ]";
        case 's': return @"[sśŝşš]";
        case 'z': return @"[zźżž]";
        case 'l': return @"[lĺļľł]";
        case 'd': return @"[dďđ]";
        case 't': return @"[tţťŧ]";
        default: {
            NSString *cString = [NSString stringWithCharacters:&c length:1];
            return [NSRegularExpression escapedPatternForString:cString];
        }
    }
}
static NSString *FZSTokenRegex(NSString *token) {
    NSMutableString *pattern = [NSMutableString string];
    for (NSUInteger i = 0; i < token.length; ++i)
        [pattern appendString:FZSCharRegex([token characterAtIndex:i])];
    return pattern;
}

static NSString *FZSSmartPattern(NSString *query, BOOL editor) {
    if (![query isKindOfClass:NSString.class] || !query.length) return query;
    // Explicit advanced regular-expression input remains available.
    if ([query hasPrefix:@"re:"]) return [query substringFromIndex:3];
    NSArray<NSString *> *tokens = FZSTokens(query);
    if (!tokens.count) return query;
    if (tokens.count == 1)
        return [@"(?i)" stringByAppendingString:FZSTokenRegex(tokens.firstObject)];
    // A result must contain all words, in any order, on the same line/name.
    // Match a line (editor) or entire filename (browser), not whole documents.
    NSMutableString *pattern = [NSMutableString stringWithString:
        editor ? @"(?im)^" : @"(?i)^"];
    for (NSString *token in tokens)
        [pattern appendFormat:@"(?=[^\\r\\n]*%@)", FZSTokenRegex(token)];
    [pattern appendString:editor ? @"[^\\r\\n]+" : @"[^\\r\\n]*$"];
    if (![NSRegularExpression regularExpressionWithPattern:pattern
            options:0 error:nil])
        return query;
    return pattern;
}

// The stock SearchController uses self.text to build an NSRegularExpression
// inside searchFiles and tests lastPathComponent for filename searches.
// Intercept this getter only while that particular worker method is running.
static void FZSNativeSearchFiles(id self, SEL cmd) {
    BOOL previous = gFZSFileSearch;
    gFZSFileSearch = YES;
    @try {
        ((void (*)(id, SEL))gFZSSearchFilesOriginal)(self, cmd);
    } @finally {
        gFZSFileSearch = previous;
    }
}
static id FZSNativeSearchText(id self, SEL cmd) {
    id query = ((id (*)(id, SEL))gFZSFileTextOriginal)(self, cmd);
    if (!gFZSFileSearch || ![query isKindOfClass:NSString.class]) return query;
    SEL typeSel = NSSelectorFromString(@"searchType");
    if ([self respondsToSelector:typeSel] &&
        ((NSInteger (*)(id, SEL))objc_msgSend)(self, typeSel) != 0)
        return query; // Keep non-name search modes (size/type) intact.
    return FZSSmartPattern(query, NO);
}

// Stock TGFastTextEditViewController owns an ICTextView. Tag that text
// surface only; no other ICTextView or text editor is affected.
static void FZSNativeEditorAppear(id self, SEL cmd, BOOL animated) {
    ((void (*)(id, SEL, BOOL))gFZSEditorAppearOriginal)(self, cmd, animated);
    SEL editorSel = NSSelectorFromString(@"textEditor");
    if (![self respondsToSelector:editorSel]) return;
    id editor = ((id (*)(id, SEL))objc_msgSend)(self, editorSel);
    if ([editor isKindOfClass:NSClassFromString(@"ICTextView")])
        objc_setAssociatedObject(editor, &kFZSSearchEditorKey, @YES,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static void FZSNativeScrollMatch(id self, SEL cmd, NSString *query, NSInteger direction) {
    if (objc_getAssociatedObject(self, &kFZSSearchEditorKey))
        query = FZSSmartPattern(query, YES);
    ((void (*)(id, SEL, id, NSInteger))gFZSScrollOriginal)(
        self, cmd, query, direction);
}

static void FZSSwap(Class cls, SEL selector, IMP replacement, IMP *previous) {
    if (!cls) return;
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return;
    *previous = method_getImplementation(method);
    if (*previous != replacement)
        class_replaceMethod(cls, selector, replacement, method_getTypeEncoding(method));
}
__attribute__((constructor)) static void FZSInstall(void) {
    Class search = NSClassFromString(@"SearchController");
    Class controller = NSClassFromString(@"TGFastTextEditViewController");
    Class editor = NSClassFromString(@"ICTextView");
    FZSSwap(search, @selector(searchFiles),
        (IMP)FZSNativeSearchFiles, &gFZSSearchFilesOriginal);
    FZSSwap(search, @selector(text),
        (IMP)FZSNativeSearchText, &gFZSFileTextOriginal);
    FZSSwap(controller, @selector(viewDidAppear:),
        (IMP)FZSNativeEditorAppear, &gFZSEditorAppearOriginal);
    FZSSwap(editor, NSSelectorFromString(@"scrollToMatch:searchDirection:"),
        (IMP)FZSNativeScrollMatch, &gFZSScrollOriginal);
}
