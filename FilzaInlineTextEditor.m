// Inline Base64 projection for Filza's existing text editor.
// The visible text is transient; native save receives reconstructed XML.
// This file does not alter Filza's plist editor, file-browser, or sandbox backend.
@import UIKit;
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
@end
@implementation FZIBlock @end

@interface FZIProjection : NSObject
@property(nonatomic, copy) NSString *original;
@property(nonatomic, copy) NSString *display;
@property(nonatomic, strong) NSArray<FZIBlock *> *blocks;
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
static NSData *FZIBase64(NSString *raw) {
    NSMutableString *s = [NSMutableString string];
    NSCharacterSet *whitespace = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    NSCharacterSet *alphabet = [NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/="];
    for (NSUInteger i=0; i<raw.length; i++) {
        unichar ch=[raw characterAtIndex:i];
        if ([whitespace characterIsMember:ch]) continue;
        if (![alphabet characterIsMember:ch]) return nil;
        [s appendFormat:@"%C",ch];
    }
    if (!s.length || s.length % 4) return nil;
    NSData *data=[[NSData alloc] initWithBase64EncodedString:s options:0];
    if (!data || ![[data base64EncodedStringWithOptions:0] isEqualToString:s])
        return nil;
    return data;
}
static NSString *FZIRewrap64(NSData *data, NSString *original) {
    NSString *s=[data base64EncodedStringWithOptions:0];
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

// Scan only primitive plist tags. The outermost spans remain stable even
// while their projected binary plist contains nested <string>/<data> tags.
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

static NSString *FZIProjectDecodedData(NSData *bytes, FZIBlock *block, NSUInteger depth) {
    if (depth>18 || bytes.length>16*1024*1024) return nil;
    NSPropertyListFormat format=NSPropertyListXMLFormat_v1_0;
    id plist=[NSPropertyListSerialization propertyListWithData:bytes
        options:NSPropertyListMutableContainersAndLeaves format:&format error:nil];
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
        NSData *pretty=[NSJSONSerialization dataWithJSONObject:json
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
                    NSData *pretty=[NSJSONSerialization dataWithJSONObject:embedded
                        options:NSJSONWritingPrettyPrinted error:nil];
                    if(pretty) {
                        block.encoding=FZIEncodingJSONInString;
                        value=[[NSString alloc] initWithData:pretty
                            encoding:NSUTF8StringEncoding];
                    }
                } else if(plain.length>=16) {
                    NSData *decoded=FZIBase64(plain);
                    if(decoded) {
                        block.originalBytes=decoded;
                        value=FZIProjectDecodedData(decoded,block,depth+1);
                        // If it looks like an ordinary word rather than encoded
                        // structure, do not replace it with a hex wall.
                        if(block.encoding==FZIEncodingHex && plain.length<48) {
                            block.encoding=FZIEncodingIdentity;
                            value=nil;
                        }
                    }
                }
            }
        }
        // Match the original field's leading/trailing line breaks. The
        // surrounding <data>/<string> tags and every other line stay intact.
        if(value) {
            NSString *head=FZILeadingSpace(originalBody);
            NSString *tail=FZITrailingSpace(originalBody);
            // No extra per-line indentation: child blocks must retain
            // the exact text they recorded for lossless round-tripping.
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
        bytes=[NSJSONSerialization dataWithJSONObject:json
            options:NSJSONWritingFragmentsAllowed error:error];
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
    if(!text || text.length>36*1024*1024 ||
       [text rangeOfString:@"<plist"].location==NSNotFound) return nil;
    NSData *bytes=[text dataUsingEncoding:NSUTF8StringEncoding];
    id structure=[NSPropertyListSerialization propertyListWithData:bytes
        options:0 format:NULL error:nil];
    if(!structure) return nil;
    FZIProjection *projection=[FZIProjection new];
    projection.original=text;
    NSMutableArray *blocks=[NSMutableArray array];
    projection.display=FZIProjectXML(text,blocks,0);
    if([projection.display isEqualToString:text]) return nil;
    projection.blocks=blocks;
    // A projection must be lossless before it is ever shown.
    NSError *error=nil;
    NSString *roundtrip=FZIRestoreXML(projection.display,blocks,&error);
    return [roundtrip isEqualToString:text] ? projection : nil;
}

static NSString *FZIValidateAndRestore(FZIProjection *projection,
                                        NSString *visible,NSError **error) {
    NSString *xml=FZIRestoreXML(visible,projection.blocks,error);
    if(!xml) return nil;
    // Fully validate the newly assembled plist before passing it to Filza.
    NSData *data=[xml dataUsingEncoding:NSUTF8StringEncoding];
    id parsed=[NSPropertyListSerialization propertyListWithData:data
        options:0 format:NULL error:error];
    if(!parsed) return nil;
    return xml;
}

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

static NSMapTable<UIViewController *,FZIActive *> *gFZIActive;
static IMP gFZIOrigDidAppear;
static IMP gFZIOrigText;
static IMP gFZIOrigSetText;
static IMP gFZIOrigSendAction;
static __thread BOOL gFZISaving;
// Only scalar TLS is allowed under ARC. Retain temporary Objective-C values
// in the current thread's dictionary for the duration of the native save.
static NSString *const kFZISaveContextKey = @"FilzaInlineData.NativeSaveContext";
static BOOL gFZIInternalChange;

static void FZIShowError(UIViewController *controller,NSError *error) {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:
        @"Cannot safely save decoded plist"
        message:error.localizedDescription ?: @"Invalid nested data"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
        style:UIAlertActionStyleDefault handler:nil]];
    [controller presentViewController:alert animated:YES completion:nil];
}

static void FZIProjectInNativeEditor(UIViewController *controller) {
    if(!FZIIsNativeTextEditor(controller)) return;
    UITextView *view=FZIFindTextView(controller.view,0);
    if(!view) return;
    NSString *text=((id(*)(id,SEL))gFZIOrigText)(view,@selector(text));
    if(!text.length) return;
    FZIActive *session=[gFZIActive objectForKey:controller];
    if(session && session.editor==view) {
        // Existing editing state, including unsaved changes, is left intact.
        return;
    }
    FZIProjection *projection=FZIMakeProjection(text);
    if(!projection) return;
    session=[FZIActive new];
    session.controller=controller;
    session.editor=view;
    session.projection=projection;
    [gFZIActive setObject:session forKey:controller];
    NSRange selection=view.selectedRange;
    gFZIInternalChange=YES;
    ((void(*)(id,SEL,id))gFZIOrigSetText)(view,@selector(setText:),
        projection.display);
    gFZIInternalChange=NO;
    view.selectedRange=NSMakeRange(MIN(selection.location,view.text.length),0);
    // Do not send textViewDidChange here: the underlying disk document
    // is unchanged. The real editor handles user edits normally.
    NSLog(@"[FilzaInlineData] showing decoded fields inline in %@",
        NSStringFromClass(controller.class));
}
static NSString *FZIHookText(id self,SEL cmd) {
    if (gFZISaving) {
        NSDictionary *ctx = [NSThread currentThread].threadDictionary[kFZISaveContextKey];
        if (ctx[@"editor"] == self && ctx[@"xml"]) return ctx[@"xml"];
    }
    return ((id(*)(id,SEL))gFZIOrigText)(self,cmd);
}
static void FZIHookSetText(id self,SEL cmd,id value) {
    ((void(*)(id,SEL,id))gFZIOrigSetText)(self,cmd,value);
}

static void FZIHookDidAppear(id self, SEL cmd, BOOL animated) {
    ((void(*)(id,SEL,BOOL))gFZIOrigDidAppear)(self,cmd,animated);
    UIViewController *vc=(UIViewController *)self;
    if(!FZIIsNativeTextEditor(vc)) return;
    FZIProjectInNativeEditor(vc);
    __weak UIViewController *weak=vc;
    for(NSNumber *delay in @[@150,@450]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            delay.unsignedLongLongValue*NSEC_PER_MSEC),
            dispatch_get_main_queue(),^{ if(weak) FZIProjectInNativeEditor(weak); });
    }
}

static BOOL FZIIsSaveAction(UIViewController *controller, SEL selector,id sender) {
    NSString *name=NSStringFromSelector(selector).lowercaseString;
    if([name containsString:@"save"] || [name containsString:@"done"] ||
       [name containsString:@"commit"] || [name containsString:@"finish"])
        return YES;
    if([sender isKindOfClass:UIBarButtonItem.class]) {
        UINavigationItem *navigation=controller.navigationItem;
        NSString *title = [((UIBarButtonItem *)sender).title lowercaseString] ?: @"";
        BOOL labeledSave = [title containsString:@"save"] ||
            [title containsString:@"done"] || [title containsString:@"salvar"];
        return (sender == navigation.leftBarButtonItem && labeledSave) ||
            (sender == navigation.rightBarButtonItem && labeledSave);
    }
    return NO;
}

// UIKit dispatches Filza's existing checkmark/save bar action through this
// path. Only during that exact dispatch does .text return reconstructed XML.
// The visible UITextView never turns back into Base64 when editing or scrolling.
static BOOL FZIHookSendAction(id app,SEL cmd,SEL action,id target,id sender,id event) {
    UIViewController *controller=[target isKindOfClass:UIViewController.class]
        ? (UIViewController *)target : nil;
    FZIActive *session=controller ? [gFZIActive objectForKey:controller]:nil;
    if(!session && [sender isKindOfClass:UIBarButtonItem.class]) {
        NSEnumerator *controllers=gFZIActive.keyEnumerator;
        UIViewController *candidate=nil;
        while((candidate=controllers.nextObject)) {
            if(!FZIIsNativeTextEditor(candidate)) continue;
            UINavigationItem *item=candidate.navigationItem;
            BOOL matching=sender==item.leftBarButtonItem ||
                sender==item.rightBarButtonItem ||
                [item.leftBarButtonItems containsObject:sender] ||
                [item.rightBarButtonItems containsObject:sender];
            if(matching) {
                controller=candidate;
                session=[gFZIActive objectForKey:candidate];
                break;
            }
        }
    }
    BOOL shouldRestore=session && FZIIsSaveAction(controller,action,sender);
    if(!shouldRestore)
        return ((BOOL(*)(id,SEL,SEL,id,id,id))gFZIOrigSendAction)(
            app,cmd,action,target,sender,event);
    UITextView *view=session.editor;
    if(!view)
        return ((BOOL(*)(id,SEL,SEL,id,id,id))gFZIOrigSendAction)(
            app,cmd,action,target,sender,event);
    NSString *visible=((id(*)(id,SEL))gFZIOrigText)(view,@selector(text));
    NSError *error=nil;
    NSString *xml=FZIValidateAndRestore(session.projection,visible,&error);
    if(!xml) {
        FZIShowError(controller,error);
        return YES; // handled: fail closed, do not save invalid Base64.
    }
    NSMutableDictionary *threadValues = [NSThread currentThread].threadDictionary;
    id oldContext = threadValues[kFZISaveContextKey];
    BOOL oldFlag = gFZISaving;
    threadValues[kFZISaveContextKey] = @{@"editor":view, @"xml":xml};
    gFZISaving = YES;
    BOOL result = NO;
    @try {
        result = ((BOOL(*)(id,SEL,SEL,id,id,id))gFZIOrigSendAction)(
            app,cmd,action,target,sender,event);
    } @finally {
        if (oldContext) threadValues[kFZISaveContextKey] = oldContext;
        else [threadValues removeObjectForKey:kFZISaveContextKey];
        gFZISaving = oldFlag;
    }
    return result;
}

__attribute__((constructor)) static void FZIInstall(void) {
    gFZIActive=[NSMapTable weakToStrongObjectsMapTable];
    Method didAppear=class_getInstanceMethod(UIViewController.class,
        @selector(viewDidAppear:));
    Method getText=class_getInstanceMethod(UITextView.class,@selector(text));
    Method setText=class_getInstanceMethod(UITextView.class,@selector(setText:));
    Method dispatch=class_getInstanceMethod(UIApplication.class,
        @selector(sendAction:to:from:forEvent:));
    if(!didAppear || !getText || !setText || !dispatch) return;
    gFZIOrigDidAppear=method_getImplementation(didAppear);
    gFZIOrigText=method_getImplementation(getText);
    gFZIOrigSetText=method_getImplementation(setText);
    gFZIOrigSendAction=method_getImplementation(dispatch);
    method_setImplementation(didAppear,(IMP)FZIHookDidAppear);
    method_setImplementation(getText,(IMP)FZIHookText);
    method_setImplementation(setText,(IMP)FZIHookSetText);
    method_setImplementation(dispatch,(IMP)FZIHookSendAction);
}
