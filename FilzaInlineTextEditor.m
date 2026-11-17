// Inline Base64 projection for Filza's existing text editor.
// The visible text is transient; native save receives reconstructed XML.
// This file does not alter Filza's plist editor, file-browser, or sandbox backend.
#if defined(FILZA_INLINE_CODEC_TESTS)
#import <Foundation/Foundation.h>
#else
@import UIKit;
#endif
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreFoundation/CoreFoundation.h>

typedef NS_ENUM(NSUInteger, FZIEncoding) {
    FZIEncodingIdentity = 0,
    FZIEncodingPlistBinary,
    FZIEncodingPlistXML,
    FZIEncodingJSON,
    FZIEncodingText,
    FZIEncodingHex,
    FZIEncodingJSONInString
};

@interface FZISpan : NSObject
@property(nonatomic, copy) NSString *tag;
@property(nonatomic) NSRange opening, body, closing;
@end
@implementation FZISpan @end

@interface FZIBlock : NSObject
@property(nonatomic, copy) NSString *tag;
@property(nonatomic, copy) NSString *originalBody, *displayBody;
@property(nonatomic) FZIEncoding encoding;
@property(nonatomic, strong) NSArray<FZIBlock *> *children;
@property(nonatomic, strong) NSData *originalBytes;
@property(nonatomic, copy) NSString *displayIndent;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *jsonEncodings;
@end
@implementation FZIBlock @end

@interface FZIProjection : NSObject
@property(nonatomic, copy) NSString *original;
@property(nonatomic, copy) NSString *display;
@property(nonatomic, strong) NSArray<FZIBlock *> *blocks;
@property(nonatomic) BOOL rootJSON;
@property(nonatomic, copy) NSDictionary<NSString *, NSDictionary *> *rootJSONEncodings;
@end
@implementation FZIProjection @end

static NSError *FZIError(NSString *reason) {
    return [NSError errorWithDomain:@"FilzaInlineData" code:1
        userInfo:@{NSLocalizedDescriptionKey:reason ?: @"Invalid embedded data"}];
}

static NSString *FZIIndent(NSString *text, NSString *indent) {
    NSArray *lines = [text componentsSeparatedByString:@"\n"];
    return [lines componentsJoinedByString:
        [NSString stringWithFormat:@"\n%@", indent ?: @""]];
}

static NSString *FZILeadingSpace(NSString *text) {
    NSUInteger i = 0;
    while (i < text.length &&
           [NSCharacterSet.whitespaceAndNewlineCharacterSet characterIsMember:
               [text characterAtIndex:i]]) i++;
    return [text substringToIndex:i];
}
static NSString *FZITrailingSpace(NSString *text) {
    NSUInteger i = text.length;
    while (i && [NSCharacterSet.whitespaceAndNewlineCharacterSet characterIsMember:
                 [text characterAtIndex:i - 1]]) i--;
    return [text substringFromIndex:i];
}

static NSString *FZIXMLEscape(NSString *text) {
    NSDictionary *replacements = @{@"&":@"&amp;", @"<":@"&lt;",
                                    @">":@"&gt;", @"\"":@"&quot;", @"'":@"&apos;"};
    NSMutableString *s = [text mutableCopy];
    for (NSString *key in @[@"&", @"<", @">", @"\"", @"'"])
        [s replaceOccurrencesOfString:key withString:replacements[key]
            options:0 range:NSMakeRange(0, s.length)];
    return s;
}
static NSString *FZIXMLUnescape(NSString *text) {
    // Large configuration plists contain thousands of ordinary values.
    if([text rangeOfString:@"&"].location==NSNotFound) return text;
    // Decode a leaf <string> with the native plist parser, including numeric entities.
    NSString *xml = [NSString stringWithFormat:
        @"<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><string>%@</string></plist>",
        text ?: @""];
    id value = [NSPropertyListSerialization propertyListWithData:
        [xml dataUsingEncoding:NSUTF8StringEncoding]
        options:0 format:NULL error:nil];
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static NSString *FZIHex(NSData *bytes) {
    const unsigned char *data = bytes.bytes;
    NSMutableString *hex = [NSMutableString stringWithCapacity:bytes.length * 3];
    for (NSUInteger i = 0; i < bytes.length; i++) {
        if (i && !(i % 16)) [hex appendString:@"\n"];
        else if (i) [hex appendString:@" "];
        [hex appendFormat:@"%02X", data[i]];
    }
    return hex;
}
static NSData *FZIUnhex(NSString *text) {
    NSMutableString *compact = [NSMutableString string];
    NSCharacterSet *white = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    NSCharacterSet *hex = [NSCharacterSet
        characterSetWithCharactersInString:@"0123456789abcdefABCDEF"];
    for (NSUInteger i=0; i<text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if ([white characterIsMember:c]) continue;
        if (![hex characterIsMember:c]) return nil;
        [compact appendFormat:@"%C",c];
    }
    if (compact.length % 2) return nil;
    NSMutableData *result = [NSMutableData dataWithCapacity:compact.length/2];
    for (NSUInteger i=0; i<compact.length; i+=2) {
        unsigned byte=0;
        NSScanner *scanner = [NSScanner scannerWithString:
            [compact substringWithRange:NSMakeRange(i,2)]];
        if (![scanner scanHexInt:&byte]) return nil;
        uint8_t b=(uint8_t)byte;
        [result appendBytes:&b length:1];
    }
    return result;
}
// Accept the four common transport variants: standard/URL-safe, with or
// without padding, including whitespace-wrapped XML <data> payloads.
// Successful decoding alone is not proof a plain plist string is Base64.
static NSData *FZIBase64(NSString *raw) {
    if (![raw isKindOfClass:NSString.class] || !raw.length) return nil;
    NSMutableString *encoded=[NSMutableString string];
    NSCharacterSet *whitespace=NSCharacterSet.whitespaceAndNewlineCharacterSet;
    NSCharacterSet *alphabet=[NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/-_="];
    BOOL standard=NO, urlSafe=NO;
    for (NSUInteger i=0;i<raw.length;i++) {
        unichar ch=[raw characterAtIndex:i];
        if ([whitespace characterIsMember:ch]) continue;
        if (![alphabet characterIsMember:ch]) return nil;
        if (ch=='+' || ch=='/') standard=YES;
        if (ch=='-' || ch=='_') urlSafe=YES;
        [encoded appendFormat:@"%C",ch];
    }
    if (standard && urlSafe) return nil;
    if (!encoded.length || encoded.length%4==1) return nil;
    NSString *normalized=[[encoded stringByReplacingOccurrencesOfString:@"-"
        withString:@"+"] stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
    NSRange firstPadding=[normalized rangeOfString:@"="];
    if (firstPadding.location!=NSNotFound) {
        if (normalized.length%4) return nil;
        NSString *suffix=[normalized substringFromIndex:firstPadding.location];
        if (suffix.length>2 || [suffix stringByTrimmingCharactersInSet:
            [NSCharacterSet characterSetWithCharactersInString:@"="]].length)
            return nil;
    } else if (normalized.length%4) {
        NSUInteger padding=4-normalized.length%4;
        normalized=[normalized stringByPaddingToLength:normalized.length+padding
                                             withString:@"=" startingAtIndex:0];
    }
    NSData *bytes=[[NSData alloc] initWithBase64EncodedString:normalized options:0];
    if (!bytes || ![[bytes base64EncodedStringWithOptions:0]
                      isEqualToString:normalized]) return nil;
    return bytes;
}

static BOOL FZILooksLikeBase64(NSString *candidate, NSData *bytes) {
    if (!bytes || !candidate.length) return NO;
    if ([candidate rangeOfCharacterFromSet:[NSCharacterSet
         characterSetWithCharactersInString:@"=+/-_"]].location!=NSNotFound)
        return YES;
    if (bytes.length>=8 && !memcmp(bytes.bytes,"bplist00",8)) return YES;
    NSString *trimmed=[[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding];
    if (trimmed) {
        trimmed=[trimmed stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if ([trimmed hasPrefix:@"{"] || [trimmed hasPrefix:@"["] ||
            [trimmed hasPrefix:@"<?xml"] || [trimmed hasPrefix:@"<plist"])
            return YES;
        // A Base64-looking word is not sufficient: "metadata", "override",
        // etc. must remain ordinary strings if their decoded bytes are noise.
        BOOL readable=YES;
        for (NSUInteger i=0;i<trimmed.length;i++) {
            unichar c=[trimmed characterAtIndex:i];
            if (c<0x20 && c!='\t' && c!='\r' && c!='\n') {
                readable=NO; break;
            }
        }
        if (readable && candidate.length>=8 && trimmed.length>=3) return YES;
    }
    return candidate.length>=16;
}
static NSString *FZIRewrap64(NSData *data, NSString *original) {
    NSString *s=[data base64EncodedStringWithOptions:0];
    // A modified Base64URL value remains URL-safe; an unpadded transport
    // remains unpadded. Unedited values bypass this method entirely.
    BOOL urlSafe=([original rangeOfString:@"-"].location!=NSNotFound ||
                  [original rangeOfString:@"_"].location!=NSNotFound);
    BOOL padded=([original rangeOfString:@"="].location!=NSNotFound);
    if (urlSafe) {
        s=[[s stringByReplacingOccurrencesOfString:@"+" withString:@"-"]
            stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    }
    if (!padded)
        s=[s stringByReplacingOccurrencesOfString:@"=" withString:@""];
    NSString *leading=FZILeadingSpace(original);
    NSString *trailing=FZITrailingSpace(original);
    NSString *inner=[original substringWithRange:NSMakeRange(leading.length,
        original.length-leading.length-trailing.length)];
    NSArray *lines=[inner componentsSeparatedByCharactersInSet:
        NSCharacterSet.newlineCharacterSet];
    NSUInteger width=0;
    for (NSString *line in lines) {
        NSString *compact=[line stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceCharacterSet];
        if (compact.length >= 16) { width=compact.length; break; }
    }
    if (lines.count < 2 || width < 16 || width > 256) return
        [NSString stringWithFormat:@"%@%@%@",leading,s,trailing];
    NSString *lastWhitespace = @"";
    NSRange newline=[leading rangeOfCharacterFromSet:
        NSCharacterSet.newlineCharacterSet options:NSBackwardsSearch];
    if (newline.location!=NSNotFound)
        lastWhitespace=[leading substringFromIndex:newline.location+1];
    NSString *separator=[original containsString:@"\r\n"] ? @"\r\n":@"\n";
    NSMutableString *wrapped=[NSMutableString stringWithString:leading];
    for (NSUInteger i=0; i<s.length; i+=width) {
        if (i) [wrapped appendFormat:@"%@%@",separator,lastWhitespace];
        [wrapped appendString:[s substringWithRange:
            NSMakeRange(i,MIN(width,s.length-i))]];
    }
    [wrapped appendString:trailing];
    return wrapped;
}

// Locate primitive XML value nodes. Only their display bodies are virtual;
// original bytes remain in FZIProjection until the corresponding value changes.
static NSArray<FZISpan *> *FZISpans(NSString *source, NSError **error) {
    static NSRegularExpression *regex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        regex=[NSRegularExpression regularExpressionWithPattern:
            @"<(/?)(data|string)(?:\\s[^>]*)?>"
            options:NSRegularExpressionCaseInsensitive error:nil];
    });
    NSArray<NSTextCheckingResult *> *matches=[regex matchesInString:source
        options:0 range:NSMakeRange(0,source.length)];
    NSMutableArray<FZISpan *> *found=[NSMutableArray array];
    NSMutableArray<FZISpan *> *stack=[NSMutableArray array];
    for (NSTextCheckingResult *m in matches) {
        BOOL closing=[m rangeAtIndex:1].length>0;
        NSString *tag=[[source substringWithRange:[m rangeAtIndex:2]] lowercaseString];
        if (!closing) {
            FZISpan *span=[FZISpan new];
            span.tag=tag;
            span.opening=m.range;
            [stack addObject:span];
        } else {
            FZISpan *span=stack.lastObject;
            if (!span || ![span.tag isEqualToString:tag]) {
                if(error)*error=FZIError(@"Edited text contains an unmatched <data> or <string> tag.");
                return nil;
            }
            span.closing=m.range;
            span.body=NSMakeRange(NSMaxRange(span.opening),
                m.range.location-NSMaxRange(span.opening));
            [stack removeLastObject];
            if(!stack.count) [found addObject:span];
        }
    }
    if(stack.count) {
        if(error)*error=FZIError(@"Edited text has an unclosed <data> or <string> tag.");
        return nil;
    }
    return found;
}

// Foundation also accepts bare OpenStep plist scalars such as "Hello".
// Treating arbitrary UTF-8 as plist would insert <string>...</string> markup
// into embedded JSON and make the read-only projection non-reversible.
static BOOL FZIHasPlistEnvelope(NSData *bytes) {
    if (!bytes.length) return NO;
    if (bytes.length>=8 && memcmp(bytes.bytes,"bplist00",8)==0) return YES;
    NSString *source=[[NSString alloc] initWithData:bytes
        encoding:NSUTF8StringEncoding];
    if (!source) return NO;
    NSString *trim=[source stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return ([trim hasPrefix:@"<plist"] ||
            (([trim hasPrefix:@"<?xml"] || [trim hasPrefix:@"<!DOCTYPE"]) &&
             [trim rangeOfString:@"<plist"].location!=NSNotFound));
}

static NSString *FZIPlistBody(NSData *bytes) {
    NSString *xml=[[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding];
    NSRange start=[xml rangeOfString:@"<plist"];
    if(start.location==NSNotFound) return nil;
    NSRange open=[xml rangeOfString:@">" options:0
        range:NSMakeRange(start.location,xml.length-start.location)];
    NSRange end=[xml rangeOfString:@"</plist>" options:NSBackwardsSearch];
    if(open.location==NSNotFound || end.location==NSNotFound ||
        end.location < NSMaxRange(open)) return nil;
    return [xml substringWithRange:NSMakeRange(NSMaxRange(open),
        end.location-NSMaxRange(open))];
}

static NSData *FZIPlistData(NSString *body, NSPropertyListFormat format, NSError **error) {
    NSString *xml=[NSString stringWithFormat:
        @"<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\">%@</plist>",body];
    id parsed=[NSPropertyListSerialization propertyListWithData:
        [xml dataUsingEncoding:NSUTF8StringEncoding]
        options:NSPropertyListMutableContainersAndLeaves format:NULL error:error];
    if(!parsed) return nil;
    return [NSPropertyListSerialization dataWithPropertyList:parsed
        format:format options:0 error:error];
}

static NSString *FZIProjectXML(NSString *, NSMutableArray<FZIBlock *> *, NSUInteger);
static NSString *FZIRestoreXML(NSString *, NSArray<FZIBlock *> *, NSError **);

// JSON/Base64 transport metadata belongs exclusively to the backend.
// The text editor sees only decoded JSON/XML/HEX values, never serialized
// marker objects, original Base64 copies or bookkeeping keys.
static NSString *FZIJSONPath(NSString *parent, NSString *member) {
    NSString *escaped = [[member stringByReplacingOccurrencesOfString:@"~"
        withString:@"~0"] stringByReplacingOccurrencesOfString:@"/"
        withString:@"~1"];
    return [parent stringByAppendingFormat:@"/%@", escaped];
}
// Build a source-range index for JSON values. The editor may pretty-print
// the *view*, but saving modifies only the original scalar token ranges.
// This avoids serializing untouched whitespace, key order and Base64 siblings.
static void FZIJSONSkipSpace(NSString *text, NSUInteger *pos) {
    NSCharacterSet *space=NSCharacterSet.whitespaceAndNewlineCharacterSet;
    while (*pos<text.length && [space characterIsMember:[text characterAtIndex:*pos]])
        (*pos)++;
}
static NSString *FZIJSONReadQuoted(NSString *text, NSUInteger *pos,
                                   NSRange *fullRange) {
    NSUInteger start=*pos;
    if (start>=text.length || [text characterAtIndex:start]!='"') return nil;
    (*pos)++;
    BOOL escape=NO;
    while (*pos<text.length) {
        unichar ch=[text characterAtIndex:(*pos)++];
        if (escape) { escape=NO; continue; }
        if (ch=='\\') { escape=YES; continue; }
        if (ch=='"') {
            NSRange span=NSMakeRange(start,*pos-start);
            if (fullRange) *fullRange=span;
            NSString *literal=[text substringWithRange:span];
            if ([literal rangeOfString:@"\\"].location==NSNotFound)
                return [literal substringWithRange:NSMakeRange(1,literal.length-2)];
            NSData *encoded=[[NSString stringWithFormat:@"[%@]",literal]
                dataUsingEncoding:NSUTF8StringEncoding];
            NSArray *one=[NSJSONSerialization JSONObjectWithData:encoded
                options:0 error:nil];
            return [one isKindOfClass:NSArray.class] && one.count==1 &&
                [one[0] isKindOfClass:NSString.class] ? one[0] : nil;
        }
    }
    return nil;
}
static BOOL FZIJSONIndexValues(NSString *text, NSUInteger *pos, NSString *path,
                        NSMutableDictionary<NSString *, NSValue *> *ranges,
                        NSUInteger depth) {
    if (depth>64) return NO;
    FZIJSONSkipSpace(text,pos);
    if (*pos>=text.length) return NO;
    unichar ch=[text characterAtIndex:*pos];
    if (ch=='{') {
        (*pos)++;
        FZIJSONSkipSpace(text,pos);
        if (*pos<text.length && [text characterAtIndex:*pos]=='}') {
            (*pos)++; return YES;
        }
        NSMutableSet<NSString *> *seenKeys=[NSMutableSet set];
        while (*pos<text.length) {
            NSString *key=FZIJSONReadQuoted(text,pos,NULL);
            if (!key || [seenKeys containsObject:key]) return NO;
            [seenKeys addObject:key];
            FZIJSONSkipSpace(text,pos);
            if (*pos>=text.length || [text characterAtIndex:*pos]!=':') return NO;
            (*pos)++;
            if (!FZIJSONIndexValues(text,pos,FZIJSONPath(path,key),ranges,depth+1))
                return NO;
            FZIJSONSkipSpace(text,pos);
            if (*pos>=text.length) return NO;
            unichar sep=[text characterAtIndex:(*pos)++];
            if (sep=='}') return YES;
            if (sep!=',') return NO;
            FZIJSONSkipSpace(text,pos);
        }
        return NO;
    }
    if (ch=='[') {
        (*pos)++;
        FZIJSONSkipSpace(text,pos);
        if (*pos<text.length && [text characterAtIndex:*pos]==']') {
            (*pos)++; return YES;
        }
        NSUInteger index=0;
        while (*pos<text.length) {
            NSString *element=FZIJSONPath(path,[NSString stringWithFormat:
                @"%lu",(unsigned long)index++]);
            if (!FZIJSONIndexValues(text,pos,element,ranges,depth+1)) return NO;
            FZIJSONSkipSpace(text,pos);
            if (*pos>=text.length) return NO;
            unichar sep=[text characterAtIndex:(*pos)++];
            if (sep==']') return YES;
            if (sep!=',') return NO;
        }
        return NO;
    }
    NSUInteger start=*pos;
    if (ch=='"') {
        if (!FZIJSONReadQuoted(text,pos,NULL)) return NO;
    } else {
        while (*pos<text.length) {
            unichar c=[text characterAtIndex:*pos];
            if (c==',' || c=='}' || c==']' ||
                [NSCharacterSet.whitespaceAndNewlineCharacterSet characterIsMember:c])
                break;
            (*pos)++;
        }
    }
    if (*pos==start || ranges[path]) return NO; // Duplicate JSON key path: unsafe.
    ranges[path]=[NSValue valueWithRange:NSMakeRange(start,*pos-start)];
    return YES;
}
static BOOL FZIJSONChangedLeaves(id before,id after,NSString *path,
    NSDictionary<NSString *,NSValue *> *ranges,NSMutableArray<NSDictionary *> *changes,
    NSUInteger depth) {
    if (depth>64) return NO;
    if ([before isKindOfClass:NSDictionary.class] &&
        [after isKindOfClass:NSDictionary.class]) {
        NSDictionary *left=before,*right=after;
        if (left.count!=right.count) return NO;
        for (NSString *key in left) {
            if (!right[key] || !FZIJSONChangedLeaves(left[key],right[key],
                FZIJSONPath(path,key),ranges,changes,depth+1)) return NO;
        }
        return YES;
    }
    if ([before isKindOfClass:NSArray.class] &&
        [after isKindOfClass:NSArray.class]) {
        NSArray *left=before,*right=after;
        if (left.count!=right.count) return NO;
        for (NSUInteger i=0;i<left.count;i++)
            if (!FZIJSONChangedLeaves(left[i],right[i],FZIJSONPath(path,
                [NSString stringWithFormat:@"%lu",(unsigned long)i]),
                ranges,changes,depth+1)) return NO;
        return YES;
    }
    // When container shape changed, fall back to a validated full JSON
    // serialization; no source-range patch can safely express the addition.
    if ([before isKindOfClass:NSDictionary.class] ||
        [after isKindOfClass:NSDictionary.class] ||
        [before isKindOfClass:NSArray.class] ||
        [after isKindOfClass:NSArray.class]) return NO;
    if ([before isEqual:after]) return YES;
    NSValue *range=ranges[path];
    if (!range) return NO;
    NSData *asArray=[NSJSONSerialization dataWithJSONObject:@[after]
        options:NSJSONWritingFragmentsAllowed error:nil];
    NSString *encoded=[[NSString alloc] initWithData:asArray
        encoding:NSUTF8StringEncoding];
    if (encoded.length<2) return NO;
    NSString *token=[encoded substringWithRange:NSMakeRange(1,encoded.length-2)];
    [changes addObject:@{@"range":range,@"token":token}];
    return YES;
}
static NSString *FZIJSONRestoreSelective(NSString *original,id changed,
                                         NSError **error) {
    if (!original || !changed) return nil;
    NSData *sourceData=[original dataUsingEncoding:NSUTF8StringEncoding];
    id originalTree=[NSJSONSerialization JSONObjectWithData:sourceData
        options:NSJSONReadingFragmentsAllowed error:nil];
    if (!originalTree) return nil;
    if ([originalTree isEqual:changed]) return original;
    NSMutableDictionary<NSString *,NSValue *> *ranges=[NSMutableDictionary dictionary];
    NSUInteger cursor=0;
    BOOL indexed=FZIJSONIndexValues(original,&cursor,@"",ranges,0);
    FZIJSONSkipSpace(original,&cursor);
    indexed=indexed && cursor==original.length;
    if (!indexed) {
        // Never canonicalize an ambiguous JSON document (duplicate keys,
        // unsupported lexical layout, etc.) and silently drop original data.
        if (error) *error=FZIError(
            @"Original JSON contains ambiguous members; only its unchanged bytes can be saved.");
        return nil;
    }
    NSMutableArray<NSDictionary *> *changes=[NSMutableArray array];
    if (indexed && FZIJSONChangedLeaves(originalTree,changed,@"",
        ranges,changes,0)) {
        NSMutableString *updated=[original mutableCopy];
        NSArray *sorted=[changes sortedArrayUsingComparator:
            ^NSComparisonResult(NSDictionary *a,NSDictionary *b) {
                NSUInteger x=[a[@"range"] rangeValue].location;
                NSUInteger y=[b[@"range"] rangeValue].location;
                if (x>y) return NSOrderedAscending;
                if (x<y) return NSOrderedDescending;
                return NSOrderedSame;
            }];
        for (NSDictionary *edit in sorted)
            [updated replaceCharactersInRange:[edit[@"range"] rangeValue]
                                    withString:edit[@"token"]];
        id reparsed=[NSJSONSerialization JSONObjectWithData:
            [updated dataUsingEncoding:NSUTF8StringEncoding]
            options:NSJSONReadingFragmentsAllowed error:nil];
        if ([reparsed isEqual:changed]) return updated;
        if (error) *error=FZIError(@"Edited JSON failed byte-preserving validation.");
        return nil;
    }
    // Structural edits necessarily change more than one scalar. Serialize
    // only that particular JSON payload, never adjacent encoded fields.
    NSData *reencoded=[NSJSONSerialization dataWithJSONObject:changed
        options:NSJSONWritingFragmentsAllowed error:error];
    return reencoded ? [[NSString alloc] initWithData:reencoded
        encoding:NSUTF8StringEncoding] : nil;
}

static id FZIProjectJSONValue(id value, NSString *path,
    NSMutableDictionary<NSString *, NSDictionary *> *records, NSUInteger depth);
static id FZIRestoreJSONValue(id value, NSString *path,
    NSDictionary<NSString *, NSDictionary *> *records, NSUInteger depth,
    NSError **error);
static id FZIRestoreJSONNode(id value, NSString *path,
    NSDictionary<NSString *, NSDictionary *> *records, NSUInteger depth,
    BOOL inspectCurrent, NSError **error);

static id FZIProjectJSONValue(id value, NSString *path,
    NSMutableDictionary<NSString *, NSDictionary *> *records, NSUInteger depth) {
    if (depth > 14) return value;
    if ([value isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *out = [NSMutableDictionary dictionaryWithCapacity:
            [value count]];
        for (NSString *key in value)
            out[key] = FZIProjectJSONValue(value[key], FZIJSONPath(path,key),
                records,depth+1) ?: NSNull.null;
        return out;
    }
    if ([value isKindOfClass:NSArray.class]) {
        NSMutableArray *out = [NSMutableArray arrayWithCapacity:[value count]];
        NSUInteger i=0;
        for (id part in value) {
            NSString *childPath = FZIJSONPath(path,
                [NSString stringWithFormat:@"%lu", (unsigned long)i++]);
            [out addObject:FZIProjectJSONValue(part,childPath,
                records,depth+1) ?: NSNull.null];
        }
        return out;
    }
    if (![value isKindOfClass:NSString.class] || [value length] < 4) return value;
    NSString *string = (NSString *)value;
    NSData *bytes = FZIBase64(string);
    if (!bytes || bytes.length > 4 * 1024 * 1024 ||
        !FZILooksLikeBase64(string,bytes)) return value;
    NSString *format = nil;
    id decoded = nil;
    NSPropertyListFormat plistFormat = NSPropertyListXMLFormat_v1_0;
    id plist = FZIHasPlistEnvelope(bytes) ?
        [NSPropertyListSerialization propertyListWithData:bytes
            options:0 format:&plistFormat error:nil] : nil;
    if (plist) {
        NSData *asXML = [NSPropertyListSerialization dataWithPropertyList:plist
            format:NSPropertyListXMLFormat_v1_0 options:0 error:nil];
        decoded = FZIPlistBody(asXML);
        if (decoded) format = plistFormat == NSPropertyListBinaryFormat_v1_0
            ? @"bplist" : @"xmlplist";
    }
    if (!format) {
        id json = [NSJSONSerialization JSONObjectWithData:bytes
            options:NSJSONReadingFragmentsAllowed error:nil];
        if (json) {
            format = @"json";
            decoded = FZIProjectJSONValue(json,path,records,depth+1);
        }
    }
    if (!format) {
        NSString *text = [[NSString alloc] initWithData:bytes
            encoding:NSUTF8StringEncoding];
        if (text && [text rangeOfString:
            [NSString stringWithFormat:@"%C", (unichar)0]].location == NSNotFound) {
            format = @"utf8";
            decoded = text;
        }
    }
    if (!format) { format = @"hex"; decoded = FZIHex(bytes); }
    if (!decoded) return value;
    records[path] = @{@"format":format, @"original":string,
                      @"display":decoded};
    return decoded;
}

static id FZIRestoreJSONValue(id value, NSString *path,
    NSDictionary<NSString *, NSDictionary *> *records, NSUInteger depth,
    NSError **error) {
    return FZIRestoreJSONNode(value,path,records,depth,YES,error);
}

static id FZIRestoreJSONNode(id value, NSString *path,
    NSDictionary<NSString *, NSDictionary *> *records, NSUInteger depth,
    BOOL inspectCurrent, NSError **error) {
    if (depth > 14) {
        if (error) *error = FZIError(@"Embedded JSON exceeds maximum nesting depth.");
        return nil;
    }
    NSDictionary *metadata = inspectCurrent ? records[path] : nil;
    if (metadata) {
        id unchangedView = metadata[@"display"];
        NSString *original = metadata[@"original"];
        NSString *format = metadata[@"format"];
        if (unchangedView && [unchangedView isEqual:value]) return original;
        NSData *bytes = nil;
        if ([format isEqualToString:@"bplist"] ||
            [format isEqualToString:@"xmlplist"]) {
            if (![value isKindOfClass:NSString.class]) {
                if (error) *error = FZIError(@"Embedded plist must remain XML text.");
                return nil;
            }
            bytes = FZIPlistData(value, [format isEqualToString:@"bplist"] ?
                NSPropertyListBinaryFormat_v1_0 :
                NSPropertyListXMLFormat_v1_0,error);
        } else if ([format isEqualToString:@"json"]) {
            // Restore children first; this location is the parent encoder.
            // A nested Base64 value may have its own metadata under this path.
            id child = FZIRestoreJSONNode(value,path,records,depth+1,NO,error);
            if (!child) return nil;
            NSString *originalJSON=[[NSString alloc] initWithData:
                FZIBase64(original) encoding:NSUTF8StringEncoding];
            NSString *rebuilt=FZIJSONRestoreSelective(originalJSON,child,error);
            bytes=[rebuilt dataUsingEncoding:NSUTF8StringEncoding];
        } else if ([format isEqualToString:@"utf8"]) {
            if (![value isKindOfClass:NSString.class]) {
                if (error) *error = FZIError(@"Embedded UTF-8 must remain text.");
                return nil;
            }
            bytes = [value dataUsingEncoding:NSUTF8StringEncoding];
        } else if ([format isEqualToString:@"hex"]) {
            if (![value isKindOfClass:NSString.class]) {
                if (error) *error = FZIError(@"Embedded bytes require hexadecimal text.");
                return nil;
            }
            bytes = FZIUnhex(value);
        }
        if (!bytes) {
            if (error && !*error)
                *error = FZIError(@"Could not encode edited Base64 JSON value.");
            return nil;
        }
        return FZIRewrap64(bytes,original);
    }
    if ([value isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *out = [NSMutableDictionary dictionaryWithCapacity:
            [value count]];
        for (NSString *key in value) {
            id child=FZIRestoreJSONNode(value[key],FZIJSONPath(path,key),records,
                depth+1,YES,error);
            if (!child) return nil;
            out[key]=child;
        }
        return out;
    }
    if ([value isKindOfClass:NSArray.class]) {
        NSMutableArray *out = [NSMutableArray arrayWithCapacity:[value count]];
        NSUInteger i=0;
        for (id item in value) {
            NSString *childPath=FZIJSONPath(path,
                [NSString stringWithFormat:@"%lu",(unsigned long)i++]);
            id child=FZIRestoreJSONNode(item,childPath,records,depth+1,YES,error);
            if (!child) return nil;
            [out addObject:child];
        }
        return out;
    }
    return value;
}

static NSString *FZIProjectDecodedData(NSData *bytes, FZIBlock *block, NSUInteger depth) {
    if (depth>18 || bytes.length>16*1024*1024) return nil;
    NSPropertyListFormat format=NSPropertyListXMLFormat_v1_0;
    id plist=FZIHasPlistEnvelope(bytes) ?
        [NSPropertyListSerialization propertyListWithData:bytes
            options:NSPropertyListMutableContainersAndLeaves format:&format
            error:nil] : nil;
    if(plist) {
        NSData *xmlBytes=[NSPropertyListSerialization dataWithPropertyList:plist
            format:NSPropertyListXMLFormat_v1_0 options:0 error:nil];
        NSString *body=FZIPlistBody(xmlBytes);
        if(body) {
            block.encoding=format==NSPropertyListBinaryFormat_v1_0
                ? FZIEncodingPlistBinary : FZIEncodingPlistXML;
            NSMutableArray *children=[NSMutableArray array];
            NSString *visible=FZIProjectXML(
                [body stringByTrimmingCharactersInSet:
                    NSCharacterSet.newlineCharacterSet],children,depth+1);
            block.children=children;
            return visible;
        }
    }
    id json=[NSJSONSerialization JSONObjectWithData:bytes
        options:NSJSONReadingFragmentsAllowed error:nil];
    if(json) {
        block.jsonEncodings = [NSMutableDictionary dictionary];
        id readable = FZIProjectJSONValue(json, @"", block.jsonEncodings, depth + 1);
        NSData *pretty=[NSJSONSerialization dataWithJSONObject:readable
            options:NSJSONWritingPrettyPrinted|NSJSONWritingFragmentsAllowed error:nil];
        if(pretty) {
            block.encoding=FZIEncodingJSON;
            return [[NSString alloc] initWithData:pretty
                encoding:NSUTF8StringEncoding];
        }
    }
    NSString *utf8=[[NSString alloc] initWithData:bytes
        encoding:NSUTF8StringEncoding];
    if(utf8 && [utf8 rangeOfString:
        [NSString stringWithFormat:@"%C",(unichar)0]].location==NSNotFound &&
        [utf8 rangeOfString:@"</data>"].location==NSNotFound &&
        [utf8 rangeOfString:@"</string>"].location==NSNotFound) {
        block.encoding=FZIEncodingText;
        return utf8;
    }
    block.encoding=FZIEncodingHex;
    return FZIHex(bytes);
}

static NSString *FZIProjectXML(NSString *source,
                               NSMutableArray<FZIBlock *> *blocks, NSUInteger depth) {
    if(depth>18 || source.length>36*1024*1024) return source;
    NSError *scanError=nil;
    NSArray<FZISpan *> *spans=FZISpans(source,&scanError);
    if(!spans) return source;
    NSMutableString *out=[NSMutableString string];
    NSUInteger cursor=0;
    for(FZISpan *span in spans) {
        [out appendString:[source substringWithRange:
            NSMakeRange(cursor,span.opening.location-cursor)]];
        [out appendString:[source substringWithRange:span.opening]];
        NSString *originalBody=[source substringWithRange:span.body];
        FZIBlock *block=[FZIBlock new];
        block.tag=span.tag;
        block.originalBody=originalBody;
        block.encoding=FZIEncodingIdentity;
        NSString *value=nil;
        if([span.tag isEqualToString:@"data"]) {
            NSData *decoded=FZIBase64(originalBody);
            if(decoded) {
                block.originalBytes=decoded;
                value=FZIProjectDecodedData(decoded,block,depth+1);
            }
        } else {
            NSString *plain=FZIXMLUnescape(originalBody);
            if(plain.length) {
                // Embedded JSON in a plist string stays a string on disk.
                NSData *bytes=[plain dataUsingEncoding:NSUTF8StringEncoding];
                id embedded=[NSJSONSerialization JSONObjectWithData:bytes
                    options:NSJSONReadingFragmentsAllowed error:nil];
                NSString *trimmed=[plain stringByTrimmingCharactersInSet:
                    NSCharacterSet.whitespaceAndNewlineCharacterSet];
                if(( [embedded isKindOfClass:NSDictionary.class] ||
                     [embedded isKindOfClass:NSArray.class] ) &&
                    ( [trimmed hasPrefix:@"{"] || [trimmed hasPrefix:@"["] )) {
                    block.jsonEncodings = [NSMutableDictionary dictionary];
                    id readable = FZIProjectJSONValue(embedded, @"", block.jsonEncodings, depth + 1);
                    NSData *pretty=[NSJSONSerialization dataWithJSONObject:readable
                        options:NSJSONWritingPrettyPrinted error:nil];
                    if(pretty) {
                        block.encoding=FZIEncodingJSONInString;
                        value=[[NSString alloc] initWithData:pretty
                            encoding:NSUTF8StringEncoding];
                    }
                } else if(plain.length>=4) {
                    NSData *decoded=FZIBase64(plain);
                    if(decoded && FZILooksLikeBase64(plain,decoded)) {
                        block.originalBytes=decoded;
                        value=FZIProjectDecodedData(decoded,block,depth+1);
                        // Display opaque Base64 as editable HEX too. Short values
                        // (e.g. 16-byte identifiers) must not be silently hidden.
                    }
                }
            }
        }
        // Match the original field's leading/trailing line breaks. The
        // surrounding <data>/<string> tags and every other line stay intact.
        if(value) {
            NSString *head=FZILeadingSpace(originalBody);
            NSString *tail=FZITrailingSpace(originalBody);
            // Indent only the visual representation. The exact indentation
            // introduced here is removed before reconstructing changed data.
            if (block.encoding != FZIEncodingText) {
                NSRange previousNewline = [source rangeOfString:@"\n"
                    options:NSBackwardsSearch
                    range:NSMakeRange(0, span.opening.location)];
                NSString *base = @"";
                if (previousNewline.location != NSNotFound) {
                    base = [source substringWithRange:NSMakeRange(
                        NSMaxRange(previousNewline),
                        span.opening.location - NSMaxRange(previousNewline))];
                    if ([base rangeOfCharacterFromSet:
                        [[NSCharacterSet characterSetWithCharactersInString:@" \t"]
                            invertedSet]].location != NSNotFound) base = @"";
                }
                block.displayIndent = [base stringByAppendingString:@"  "];
                value = FZIIndent(value, block.displayIndent);
            }
            block.displayBody=[NSString stringWithFormat:@"%@%@%@",head,value,tail];
        } else block.displayBody=originalBody;
        [blocks addObject:block];
        [out appendString:block.displayBody];
        [out appendString:[source substringWithRange:span.closing]];
        cursor=NSMaxRange(span.closing);
    }
    [out appendString:[source substringFromIndex:cursor]];
    return out;
}

static NSString *FZIWithoutOriginalPadding(NSString *visible, FZIBlock *block) {
    NSString *head=FZILeadingSpace(block.originalBody);
    NSString *tail=FZITrailingSpace(block.originalBody);
    NSString *v=visible;
    if(head.length && [v hasPrefix:head])
        v=[v substringFromIndex:head.length];
    if(tail.length && [v hasSuffix:tail])
        v=[v substringToIndex:v.length-tail.length];
    if (block.displayIndent.length && [v containsString:@"\n"]) {
        // Dedent just the exact spacing inserted for this projected block;
        // JSON and embedded plist values preserve their own inner spacing.
        NSArray *lines = [v componentsSeparatedByString:@"\n"];
        NSMutableArray *decoded = [NSMutableArray arrayWithCapacity:lines.count];
        for (NSUInteger index=0; index<lines.count; index++) {
            NSString *line = lines[index];
            if (index && [line hasPrefix:block.displayIndent])
                line = [line substringFromIndex:block.displayIndent.length];
            [decoded addObject:line];
        }
        v = [decoded componentsJoinedByString:@"\n"];
    }
    return v;
}

static NSString *FZIRestoreBlock(NSString *body, FZIBlock *block, NSError **error) {
    if([body isEqualToString:block.displayBody]) return block.originalBody;
    if(block.encoding==FZIEncodingIdentity) {
        // This was a regular string, or an unrecognized data blob.
        if([block.tag isEqualToString:@"data"] && !FZIBase64(body)) {
            if(error)*error=FZIError(@"Modified raw <data> must contain valid Base64.");
            return nil;
        }
        return body;
    }
    NSString *content=FZIWithoutOriginalPadding(body,block);
    NSData *bytes=nil;
    if(block.encoding==FZIEncodingPlistBinary ||
       block.encoding==FZIEncodingPlistXML) {
        NSString *restored=FZIRestoreXML(content,block.children ?: @[],error);
        if(!restored) return nil;
        bytes=FZIPlistData(restored,
            block.encoding==FZIEncodingPlistBinary ?
                NSPropertyListBinaryFormat_v1_0 : NSPropertyListXMLFormat_v1_0,error);
        if(!bytes) return nil;
    } else if(block.encoding==FZIEncodingJSON ||
              block.encoding==FZIEncodingJSONInString) {
        id json=[NSJSONSerialization JSONObjectWithData:
            [content dataUsingEncoding:NSUTF8StringEncoding]
            options:NSJSONReadingFragmentsAllowed error:error];
        if(!json) return nil;
        id restored = FZIRestoreJSONValue(json, @"", block.jsonEncodings ?: @{}, 0, error);
        if(!restored) return nil;
        NSString *originalJSON=block.encoding==FZIEncodingJSONInString
            ? FZIXMLUnescape(block.originalBody)
            : [[NSString alloc] initWithData:block.originalBytes
                encoding:NSUTF8StringEncoding];
        NSString *rebuilt=FZIJSONRestoreSelective(originalJSON,restored,error);
        bytes=[rebuilt dataUsingEncoding:NSUTF8StringEncoding];
        if(!bytes) return nil;
    } else if(block.encoding==FZIEncodingText) {
        bytes=[content dataUsingEncoding:NSUTF8StringEncoding];
    } else if(block.encoding==FZIEncodingHex) {
        bytes=FZIUnhex(content);
        if(!bytes && error) *error=FZIError(@"Invalid hexadecimal bytes in decoded field.");
    }
    if(!bytes) return nil;
    if(block.encoding==FZIEncodingHex && block.originalBytes.length >= 8) {
        if(!memcmp(block.originalBytes.bytes,"bplist00",8)) {
            id root=[NSPropertyListSerialization propertyListWithData:bytes
                options:0 format:NULL error:nil];
            if(!root) {
                if(error)*error=FZIError(
                    @"Edited binary plist bytes are invalid; original data was preserved.");
                return nil;
            }
        }
    }
    if(block.encoding==FZIEncodingJSONInString)
        return FZIXMLEscape([[NSString alloc] initWithData:bytes
            encoding:NSUTF8StringEncoding]);
    NSString *encoded=FZIRewrap64(bytes,block.originalBody);
    return [block.tag isEqualToString:@"string"] ? FZIXMLEscape(encoded) : encoded;
}

static NSString *FZIRestoreXML(NSString *visible, NSArray<FZIBlock *> *blocks,
                               NSError **error) {
    NSArray<FZISpan *> *spans=FZISpans(visible,error);
    if(!spans) return nil;
    if(spans.count!=blocks.count) {
        if(error)*error=FZIError(
            @"The count of <data>/<string> elements changed. Save was cancelled to protect the file.");
        return nil;
    }
    NSMutableString *out=[NSMutableString string];
    NSUInteger cursor=0;
    for(NSUInteger i=0;i<spans.count;i++) {
        FZISpan *span=spans[i];
        FZIBlock *block=blocks[i];
        if(![span.tag isEqualToString:block.tag]) {
            if(error)*error=FZIError(
                @"A <data> or <string> element was replaced with another type.");
            return nil;
        }
        [out appendString:[visible substringWithRange:
            NSMakeRange(cursor,span.body.location-cursor)]];
        NSString *original=FZIRestoreBlock([visible substringWithRange:span.body],
            block,error);
        if(!original) return nil;
        [out appendString:original];
        cursor=NSMaxRange(span.body);
    }
    [out appendString:[visible substringFromIndex:cursor]];
    return out;
}

static FZIProjection *FZIMakeProjection(NSString *text) {
    if (!text || text.length>36*1024*1024) return nil;
    NSData *bytes=[text dataUsingEncoding:NSUTF8StringEncoding];
    if (!bytes) return nil;
    FZIProjection *projection=[FZIProjection new];
    projection.original=text;
    if ([text rangeOfString:@"<plist"].location!=NSNotFound) {
        id plist=[NSPropertyListSerialization propertyListWithData:bytes
            options:0 format:NULL error:nil];
        if (!plist) return nil;
        NSMutableArray *blocks=[NSMutableArray array];
        projection.display=FZIProjectXML(text,blocks,0);
        if ([projection.display isEqualToString:text]) return nil;
        projection.blocks=blocks;
        NSError *error=nil;
        NSString *roundtrip=FZIRestoreXML(projection.display,blocks,&error);
        return [roundtrip isEqualToString:text] ? projection : nil;
    }
    // The same original text editor can also open JSON documents. Project
    // Base64 JSON string values in the view, but preserve the untouched
    // original JSON source byte-for-byte on Save.
    id json=[NSJSONSerialization JSONObjectWithData:bytes
        options:NSJSONReadingFragmentsAllowed error:nil];
    if (![json isKindOfClass:NSDictionary.class] &&
        ![json isKindOfClass:NSArray.class]) return nil;
    NSMutableDictionary *records=[NSMutableDictionary dictionary];
    id readable=FZIProjectJSONValue(json,@"",records,0);
    if (!records.count) return nil;
    NSData *display=[NSJSONSerialization dataWithJSONObject:readable
        options:NSJSONWritingPrettyPrinted|NSJSONWritingFragmentsAllowed
        error:nil];
    if (!display) return nil;
    projection.display=[[NSString alloc] initWithData:display
        encoding:NSUTF8StringEncoding];
    projection.rootJSON=YES;
    projection.rootJSONEncodings=[records copy];
    if (!projection.display.length) return nil;
    return projection;
}

static NSString *FZIValidateAndRestore(FZIProjection *projection,
                                        NSString *visible,NSError **error) {
    if (!projection || !visible) {
        if (error) *error=FZIError(@"The editor has no active encoded document.");
        return nil;
    }
    if (projection.rootJSON) {
        if ([visible isEqualToString:projection.display]) return projection.original;
        id parsed=[NSJSONSerialization JSONObjectWithData:
            [visible dataUsingEncoding:NSUTF8StringEncoding]
            options:NSJSONReadingFragmentsAllowed error:error];
        if (!parsed) return nil;
        id restored=FZIRestoreJSONValue(parsed,@"",
            projection.rootJSONEncodings ?: @{},0,error);
        if (!restored) return nil;
        return FZIJSONRestoreSelective(projection.original,restored,error);
    }
    NSString *xml=FZIRestoreXML(visible,projection.blocks,error);
    if (!xml) return nil;
    // Fully validate the newly assembled plist before passing it to Filza.
    NSData *data=[xml dataUsingEncoding:NSUTF8StringEncoding];
    id parsed=[NSPropertyListSerialization propertyListWithData:data
        options:0 format:NULL error:error];
    if (!parsed) return nil;
    return xml;
}

#if !defined(FILZA_INLINE_CODEC_TESTS)
// Controller identification is scoped to Filza's existing text/code editor.
// No navigation item or button is added. The plist editor is excluded.
static BOOL FZIIsNativeTextEditor(UIViewController *controller) {
    NSString *name=NSStringFromClass(controller.class).lowercaseString;
    if([name hasPrefix:@"fzi"] || [name hasPrefix:@"fed"] ||
       [name containsString:@"plist"] || [name containsString:@"hex"] ||
       [name containsString:@"browser"]) return NO;
    return ([name containsString:@"text"] || [name containsString:@"code"]) &&
           ([name containsString:@"edit"] || [name containsString:@"view"]);
}
static UITextView *FZIFindTextView(UIView *v, NSUInteger depth) {
    if(!v || depth>18) return nil;
    if([v isKindOfClass:UITextView.class]) return (UITextView *)v;
    for(UIView *subview in v.subviews) {
        UITextView *found=FZIFindTextView(subview,depth+1);
        if(found) return found;
    }
    return nil;
}

@interface FZIActive : NSObject
@property(nonatomic, weak) UIViewController *controller;
@property(nonatomic, weak) UITextView *editor;
@property(nonatomic, strong) FZIProjection *projection;
@end
@implementation FZIActive @end

// Native TGFastTextEditViewController / ICTextView integration, as
// identified in the original Filza Mach-O. No global UIApplication hooks.
static NSMapTable<UIViewController *,FZIActive *> *gFZIActive;
static IMP gFZIOriginalEditorAppear = NULL;
static IMP gFZIOriginalEditorSave = NULL;
static IMP gFZIOriginalICText = NULL;
static NSString *const kFZINativeSaveKey = @"FilzaInlineData.NativeSave";

static void FZIShowError(UIViewController *controller, NSError *error) {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Invalid embedded plist"
        message:error.localizedDescription ?: @"Could not restore the original encoded data."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
        style:UIAlertActionStyleDefault handler:nil]];
    [controller presentViewController:alert animated:YES completion:nil];
}
static UITextView *FZINativeEditor(UIViewController *controller) {
    SEL selector = NSSelectorFromString(@"textEditor");
    if (![controller respondsToSelector:selector]) return nil;
    UITextView *editor = ((id (*)(id, SEL))objc_msgSend)(controller, selector);
    return [editor isKindOfClass:NSClassFromString(@"ICTextView")] ? editor : nil;
}
static void FZIProjectInNativeEditor(UIViewController *controller) {
    if (![controller isKindOfClass:NSClassFromString(@"TGFastTextEditViewController")])
        return;
    UITextView *view = FZINativeEditor(controller);
    if (!view || !gFZIOriginalICText) return;
    NSTextStorage *storage = view.textStorage;
    // Without the stock HCodeAttributedString, transforming the entire
    // string could strip syntax colors. Keep the untouched native editor.
    if (![storage isKindOfClass:NSClassFromString(@"HCodeAttributedString")]) return;
    if ([gFZIActive objectForKey:controller]) return;
    NSString *original = ((id (*)(id, SEL))gFZIOriginalICText)(
        view, @selector(text));
    FZIProjection *projection = FZIMakeProjection(original);
    if (!projection) return;
    FZIActive *session = [FZIActive new];
    session.controller = controller;
    session.editor = view;
    session.projection = projection;
    NSRange selection = view.selectedRange;
    [storage beginEditing];
    [storage replaceCharactersInRange:NSMakeRange(0, storage.length)
        withString:projection.display];
    [storage endEditing];
    [gFZIActive setObject:session forKey:controller];
    view.selectedRange = NSMakeRange(MIN(selection.location, storage.length), 0);
    // Invoke the native highlighter on its own NSTextStorage. In contrast to
    // UITextView.setText:, this keeps Filza's own syntax palette and hooks.
    SEL highlight = NSSelectorFromString(@"highlight:");
    if ([storage respondsToSelector:highlight]) {
        ((void (*)(id, SEL, NSRange))objc_msgSend)(
            storage, highlight, NSMakeRange(0, storage.length));
    }
    NSLog(@"[FilzaInlineData] native syntax-colored projection: %lu source blocks",
        (unsigned long)projection.blocks.count);
}
static id FZINativeICText(id self, SEL selector) {
    NSDictionary *context = [NSThread currentThread].threadDictionary[kFZINativeSaveKey];
    if (context[@"editor"] == self && context[@"xml"])
        return context[@"xml"];
    return ((id (*)(id, SEL))gFZIOriginalICText)(self, selector);
}
static void FZINativeEditorDidAppear(id self, SEL cmd, BOOL animated) {
    ((void (*)(id, SEL, BOOL))gFZIOriginalEditorAppear)(self, cmd, animated);
    UIViewController *controller = (UIViewController *)self;
    FZIProjectInNativeEditor(controller);
    __weak UIViewController *weakController = controller;
    for (NSNumber *milliseconds in @[@150, @450]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            milliseconds.unsignedLongLongValue * NSEC_PER_MSEC),
            dispatch_get_main_queue(), ^{
                if (weakController) FZIProjectInNativeEditor(weakController);
            });
    }
}
static void FZINativeEditorSaveClicked(id self, SEL cmd, id sender) {
    FZIActive *session = [gFZIActive objectForKey:self];
    if (!session || !session.editor || !session.projection) {
        ((void (*)(id, SEL, id))gFZIOriginalEditorSave)(self, cmd, sender);
        return;
    }
    UITextView *view = session.editor;
    NSString *visible = ((id (*)(id, SEL))gFZIOriginalICText)(
        view, @selector(text));
    NSError *error = nil;
    NSString *xml = FZIValidateAndRestore(session.projection, visible, &error);
    if (!xml) {
        FZIShowError((UIViewController *)self,
            error ?: FZIError(@"The decoded content could not be safely re-encoded."));
        return;
    }
    NSMutableDictionary *context = NSThread.currentThread.threadDictionary;
    id previous = context[kFZINativeSaveKey];
    context[kFZINativeSaveKey] = @{@"editor":view, @"xml":xml};
    @try {
        // Filza's original saveClicked: reads ICTextView.text and validates
        // the plist. It will now receive correctly re-encoded <data> fields.
        ((void (*)(id, SEL, id))gFZIOriginalEditorSave)(self, cmd, sender);
    } @finally {
        if (previous) context[kFZINativeSaveKey] = previous;
        else [context removeObjectForKey:kFZINativeSaveKey];
    }
}
__attribute__((constructor)) static void FZIInstall(void) {
    gFZIActive = [NSMapTable weakToStrongObjectsMapTable];
    Class controller = NSClassFromString(@"TGFastTextEditViewController");
    Class editor = NSClassFromString(@"ICTextView");
    if (!controller || !editor) return;
    Method appear = class_getInstanceMethod(controller, @selector(viewDidAppear:));
    Method save = class_getInstanceMethod(controller, @selector(saveClicked:));
    Method text = class_getInstanceMethod(editor, @selector(text));
    if (!appear || !save || !text) return;
    gFZIOriginalEditorAppear = method_getImplementation(appear);
    gFZIOriginalEditorSave = method_getImplementation(save);
    gFZIOriginalICText = method_getImplementation(text);
    class_replaceMethod(editor, @selector(text), (IMP)FZINativeICText,
        method_getTypeEncoding(text));
    class_replaceMethod(controller, @selector(viewDidAppear:),
        (IMP)FZINativeEditorDidAppear, method_getTypeEncoding(appear));
    class_replaceMethod(controller, @selector(saveClicked:),
        (IMP)FZINativeEditorSaveClicked, method_getTypeEncoding(save));
}

#endif // !FILZA_INLINE_CODEC_TESTS
