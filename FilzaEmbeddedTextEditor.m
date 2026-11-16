// Filza text-editor companion. Does not modify Filza's plist editor or access backend.
@import UIKit;
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreFoundation/CoreFoundation.h>

typedef NS_ENUM(NSInteger, FEDFormat) {
    FEDFormatPlistXML = 1, FEDFormatPlistBinary, FEDFormatJSON,
    FEDFormatText, FEDFormatBytes
};

@interface FEDPayload : NSObject
@property(nonatomic, strong) id value;
@property(nonatomic) FEDFormat format;
@end
@implementation FEDPayload @end

static NSString *FEDFormatName(FEDFormat format) {
    switch (format) {
        case FEDFormatPlistXML: return @"XML plist";
        case FEDFormatPlistBinary: return @"binary plist";
        case FEDFormatJSON: return @"JSON";
        case FEDFormatText: return @"UTF-8";
        default: return @"raw bytes";
    }
}

static FEDPayload *FEDParse(NSData *data) {
    if (!data) return nil;
    FEDPayload *item = [FEDPayload new];
    NSPropertyListFormat plistFormat = NSPropertyListXMLFormat_v1_0;
    id plist = [NSPropertyListSerialization propertyListWithData:data
        options:NSPropertyListMutableContainersAndLeaves format:&plistFormat error:nil];
    if (plist) {
        item.value = plist;
        item.format = plistFormat == NSPropertyListBinaryFormat_v1_0
            ? FEDFormatPlistBinary : FEDFormatPlistXML;
        return item;
    }
    id json = [NSJSONSerialization JSONObjectWithData:data
        options:NSJSONReadingMutableContainers | NSJSONReadingFragmentsAllowed error:nil];
    if (json) {
        item.value = json;
        item.format = FEDFormatJSON;
        return item;
    }
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (text) {
        // Reject NUL-containing pseudo-text. Those bytes must stay editable as bytes.
        if ([text rangeOfString:[NSString stringWithFormat:@"%C", (unichar)0]].location == NSNotFound) {
            item.value = text;
            item.format = FEDFormatText;
            return item;
        }
    }
    item.value = [data copy];
    item.format = FEDFormatBytes;
    return item;
}

static NSData *FEDEncode(FEDPayload *item, NSError **error) {
    if (!item) return nil;
    switch (item.format) {
        case FEDFormatPlistXML:
        case FEDFormatPlistBinary:
            return [NSPropertyListSerialization dataWithPropertyList:item.value
                format:(item.format == FEDFormatPlistBinary
                    ? NSPropertyListBinaryFormat_v1_0 : NSPropertyListXMLFormat_v1_0)
                options:0 error:error];
        case FEDFormatJSON:
            return [NSJSONSerialization dataWithJSONObject:item.value
                options:NSJSONWritingPrettyPrinted | NSJSONWritingFragmentsAllowed error:error];
        case FEDFormatText:
            return [item.value isKindOfClass:NSString.class]
                ? [item.value dataUsingEncoding:NSUTF8StringEncoding] : nil;
        default:
            return [item.value isKindOfClass:NSData.class] ? item.value : nil;
    }
}

static NSString *FEDCompactBase64(NSString *value) {
    NSString *compact = [[value componentsSeparatedByCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet] componentsJoinedByString:@""];
    if (compact.length < 4 || compact.length % 4) return nil;
    NSCharacterSet *invalid = [[NSCharacterSet
        characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/="] invertedSet];
    if ([compact rangeOfCharacterFromSet:invalid].location != NSNotFound) return nil;
    NSRange padding = [compact rangeOfString:@"="];
    if (padding.location != NSNotFound && padding.location < compact.length - 2) return nil;
    return compact;
}

static NSData *FEDDecodeBase64(NSString *text) {
    NSString *compact = FEDCompactBase64(text);
    if (!compact) return nil;
    NSData *decoded = [[NSData alloc] initWithBase64EncodedString:compact options:0];
    if (!decoded) return nil;
    // Guard accidental interpretation of ordinary words as Base64.
    NSString *canonical = [decoded base64EncodedStringWithOptions:0];
    return [canonical isEqualToString:compact] ? decoded : nil;
}

static NSString *FEDRewrapBase64(NSData *data, NSString *original) {
    NSString *encoded = [data base64EncodedStringWithOptions:0];
    NSRange newline = [original rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet];
    if (newline.location == NSNotFound || newline.location == 0) return encoded;
    NSUInteger column = MIN((NSUInteger)120, newline.location);
    if (column < 16) return encoded;
    NSString *separator = [original containsString:@"\r\n"] ? @"\r\n" : @"\n";
    NSMutableString *wrapped = [NSMutableString string];
    for (NSUInteger offset = 0; offset < encoded.length; offset += column) {
        if (offset) [wrapped appendString:separator];
        [wrapped appendString:[encoded substringWithRange:
            NSMakeRange(offset, MIN(column, encoded.length - offset))]];
    }
    return wrapped;
}

static FEDPayload *FEDPayloadInString(NSString *value, BOOL *base64) {
    if (base64) *base64 = NO;
    if (![value isKindOfClass:NSString.class]) return nil;
    NSData *decoded = FEDDecodeBase64(value);
    if (decoded) {
        FEDPayload *payload = FEDParse(decoded);
        // Only surface clearly encoded data; short natural-language strings
        // must retain the ordinary string editor.
        BOOL hasPadding = [value containsString:@"="];
        if (payload && (payload.format != FEDFormatBytes || decoded.length > 24)
            && (hasPadding || value.length > 32 || payload.format <= FEDFormatJSON)) {
            if (base64) *base64 = YES;
            return payload;
        }
    }
    NSData *raw = [value dataUsingEncoding:NSUTF8StringEncoding];
    FEDPayload *structured = FEDParse(raw);
    return structured && structured.format <= FEDFormatJSON ? structured : nil;
}

static NSString *FEDHex(NSData *data) {
    NSMutableString *result = [NSMutableString stringWithCapacity:data.length * 2];
    const unsigned char *bytes = data.bytes;
    for (NSUInteger index = 0; index < data.length; index++) {
        if (index && index % 16 == 0) [result appendString:@"\n"];
        else if (index) [result appendString:@" "];
        [result appendFormat:@"%02X", bytes[index]];
    }
    return result;
}

static NSData *FEDUnhex(NSString *text) {
    NSString *value = [[text componentsSeparatedByCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet] componentsJoinedByString:@""];
    if (value.length % 2) return nil;
    NSMutableData *data = [NSMutableData dataWithCapacity:value.length / 2];
    NSCharacterSet *hex = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"];
    for (NSUInteger position = 0; position < value.length; position += 2) {
        NSString *pair = [value substringWithRange:NSMakeRange(position, 2)];
        if ([pair rangeOfCharacterFromSet:hex.invertedSet].location != NSNotFound)
            return nil;
        unsigned int byte = 0;
        NSScanner *scanner = [NSScanner scannerWithString:pair];
        if (![scanner scanHexInt:&byte]) return nil;
        unsigned char valueByte = (unsigned char)byte;
        [data appendBytes:&valueByte length:1];
    }
    return data;
}

@interface FEDInputViewController : UIViewController
@property(nonatomic, copy) NSString *initialValue;
@property(nonatomic, copy) NSString *heading;
@property(nonatomic, copy) NSString *(^onApply)(NSString *value); // nil means success
@property(nonatomic, strong) UITextView *editor;
@end

@implementation FEDInputViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.heading ?: @"Edit value";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.editor = [[UITextView alloc] initWithFrame:CGRectZero];
    self.editor.translatesAutoresizingMaskIntoConstraints = NO;
    self.editor.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
    self.editor.text = self.initialValue ?: @"";
    self.editor.autocorrectionType = UITextAutocorrectionTypeNo;
    self.editor.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.editor.smartQuotesType = UITextSmartQuotesTypeNo;
    self.editor.smartDashesType = UITextSmartDashesTypeNo;
    self.editor.alwaysBounceVertical = YES;
    [self.view addSubview:self.editor];
    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.editor.topAnchor constraintEqualToAnchor:guide.topAnchor],
        [self.editor.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor],
        [self.editor.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:8],
        [self.editor.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-8]
    ]];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"Apply"
            style:UIBarButtonItemStyleDone target:self action:@selector(fedApply)];
}
- (void)fedApply {
    NSString *error = self.onApply ? self.onApply(self.editor.text ?: @"") : nil;
    if (error.length) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Invalid value"
            message:error preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
            style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    } else {
        [self.navigationController popViewControllerAnimated:YES];
    }
}
@end

@interface FEDSession : NSObject
@property(nonatomic, strong) FEDPayload *document;
@property(nonatomic, strong) NSData *originalFile;
@property(nonatomic, weak) UITextView *nativeTextView;
@property(nonatomic, copy) NSString *filePath;
@property(nonatomic) BOOL applyToNativeText;
@property(nonatomic) BOOL dirty;
@end
@implementation FEDSession @end

@interface FEDTreeViewController : UITableViewController <UISearchResultsUpdating>
@property(nonatomic, strong) id node;
@property(nonatomic, strong) FEDSession *session;
@property(nonatomic, copy) void (^onMutation)(void);
@property(nonatomic, strong) NSArray *keys;
@property(nonatomic, copy) NSString *filter;
@property(nonatomic) BOOL isRoot;
@end

static id FEDValue(id node, id key) {
    if ([node isKindOfClass:NSDictionary.class]) return node[key];
    if ([node isKindOfClass:NSArray.class]) return node[[key unsignedIntegerValue]];
    return nil;
}
static void FEDSetValue(id node, id key, id newValue) {
    if ([node isKindOfClass:NSMutableDictionary.class]) node[key] = newValue;
    else if ([node isKindOfClass:NSMutableArray.class])
        node[[key unsignedIntegerValue]] = newValue;
}
static NSString *FEDDescription(id value) {
    if ([value isKindOfClass:NSDictionary.class])
        return [NSString stringWithFormat:@"Dictionary · %lu keys",
            (unsigned long)[value count]];
    if ([value isKindOfClass:NSArray.class])
        return [NSString stringWithFormat:@"Array · %lu items",
            (unsigned long)[value count]];
    if ([value isKindOfClass:NSData.class]) {
        FEDPayload *p = FEDParse(value);
        return [NSString stringWithFormat:@"DATA → %@ · %lu bytes",
            FEDFormatName(p.format), (unsigned long)[value length]];
    }
    if ([value isKindOfClass:NSString.class]) {
        BOOL base64 = NO;
        FEDPayload *p = FEDPayloadInString(value, &base64);
        if (p) return [NSString stringWithFormat:@"%@ → %@",
            base64 ? @"Base64" : @"Embedded", FEDFormatName(p.format)];
        return [value length] > 110
            ? [[value substringToIndex:110] stringByAppendingString:@"…"] : value;
    }
    if ([value isKindOfClass:NSNumber.class]) {
        BOOL isBool = CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
        return isBool ? ([value boolValue] ? @"Boolean · true" : @"Boolean · false")
            : [NSString stringWithFormat:@"Number · %@", value];
    }
    if ([value isKindOfClass:NSDate.class]) return [value description];
    if (value == NSNull.null) return @"null";
    return [value description] ?: @"Unknown";
}

@implementation FEDTreeViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 55;
    UISearchController *search = [[UISearchController alloc]
        initWithSearchResultsController:nil];
    search.searchResultsUpdater = self;
    search.obscuresBackgroundDuringPresentation = NO;
    search.searchBar.placeholder = @"Find keys and values";
    self.navigationItem.searchController = search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    [self fedRefreshKeys];
    if (self.isRoot) {
        self.navigationItem.leftBarButtonItem =
            [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                target:self action:@selector(fedCancel)];
        self.navigationItem.rightBarButtonItem =
            [[UIBarButtonItem alloc] initWithTitle:@"Save"
                style:UIBarButtonItemStyleDone target:self action:@selector(fedSave)];
    }
}
- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    self.filter = searchController.searchBar.text;
    [self fedRefreshKeys];
}
- (void)fedRefreshKeys {
    if ([self.node isKindOfClass:NSDictionary.class]) {
        NSArray *keys = [[self.node allKeys] sortedArrayUsingComparator:
            ^NSComparisonResult(id one, id two) {
                return [[one description] compare:[two description]
                    options:NSNumericSearch | NSCaseInsensitiveSearch];
            }];
        if (self.filter.length) {
            NSPredicate *predicate = [NSPredicate predicateWithBlock:
                ^BOOL(id key, NSDictionary *bindings) {
                    NSString *name = [key description];
                    NSString *value = FEDDescription(FEDValue(self.node, key));
                    return [name rangeOfString:self.filter options:
                        NSCaseInsensitiveSearch].location != NSNotFound ||
                        [value rangeOfString:self.filter options:
                        NSCaseInsensitiveSearch].location != NSNotFound;
                }];
            keys = [keys filteredArrayUsingPredicate:predicate];
        }
        self.keys = keys;
    } else if ([self.node isKindOfClass:NSArray.class]) {
        NSMutableArray *keys = [NSMutableArray array];
        for (NSUInteger i = 0; i < [self.node count]; i++) {
            NSNumber *index = @(i);
            if (!self.filter.length ||
                [[index description] localizedCaseInsensitiveContainsString:self.filter] ||
                [FEDDescription(FEDValue(self.node, index))
                    localizedCaseInsensitiveContainsString:self.filter])
                [keys addObject:index];
        }
        self.keys = keys;
    } else self.keys = @[];
    [self.tableView reloadData];
}
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.keys.count;
}
- (UITableViewCell *)tableView:(UITableView *)table
    cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellID = @"FZEmbeddedTree";
    UITableViewCell *cell = [table dequeueReusableCellWithIdentifier:cellID];
    if (!cell) cell = [[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellID];
    id key = self.keys[(NSUInteger)indexPath.row];
    id value = FEDValue(self.node, key);
    cell.textLabel.text = [key description];
    cell.textLabel.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightMedium];
    cell.detailTextLabel.text = FEDDescription(value);
    cell.detailTextLabel.numberOfLines = 2;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}
- (void)fedError:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Embedded Data"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
        style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)fedChanged {
    if (self.onMutation) self.onMutation();
    self.session.dirty = YES;
    [self fedRefreshKeys];
}
- (void)fedTextForKey:(id)key initial:(NSString *)initial
    title:(NSString *)title converter:(id (^)(NSString *text, NSString **error))convert {
    FEDInputViewController *editor = [FEDInputViewController new];
    editor.heading = title;
    editor.initialValue = initial ?: @"";
    __weak typeof(self) weakSelf = self;
    editor.onApply = ^NSString *(NSString *text) {
        NSString *failure = nil;
        id updated = convert(text, &failure);
        if (!updated) return failure ?: @"Could not convert the edited value.";
        FEDTreeViewController *owner = weakSelf;
        if (!owner) return @"Editor is no longer available.";
        FEDSetValue(owner.node, key, updated);
        [owner fedChanged];
        return nil;
    };
    [self.navigationController pushViewController:editor animated:YES];
}
- (void)fedOpenEmbedded:(FEDPayload *)payload atKey:(id)key
    originalValue:(id)original isBase64:(BOOL)base64 {
    if (![payload.value isKindOfClass:NSDictionary.class] &&
        ![payload.value isKindOfClass:NSArray.class]) {
        if (payload.format <= FEDFormatJSON) {
            NSData *originalBytes = FEDEncode(payload, nil);
            NSString *originalText = [[NSString alloc] initWithData:originalBytes
                encoding:NSUTF8StringEncoding];
            if (payload.format == FEDFormatPlistBinary) originalText = nil;
            if (!originalText) {
                // Scalar binary plists are unusual; edit as raw hexadecimal bytes.
                [self fedTextForKey:key initial:FEDHex(originalBytes ?: [NSData data])
                    title:@"Embedded binary data · HEX"
                    converter:^id(NSString *updated, NSString **failure) {
                        NSData *bytes = FEDUnhex(updated);
                        if (!bytes) { *failure = @"Invalid hex data."; return nil; }
                        return base64 ? FEDRewrapBase64(bytes, original)
                            : ([original isKindOfClass:NSData.class] ? bytes : original);
                    }];
            } else {
                [self fedTextForKey:key initial:originalText
                    title:@"Embedded JSON/plist scalar"
                    converter:^id(NSString *updated, NSString **failure) {
                        FEDPayload *candidate = FEDParse([updated dataUsingEncoding:NSUTF8StringEncoding]);
                        if (!candidate || candidate.format != payload.format) {
                            *failure = @"This value must remain valid embedded JSON/plist.";
                            return nil;
                        }
                        NSData *bytes = FEDEncode(candidate, nil);
                        return base64 ? FEDRewrapBase64(bytes, original)
                            : ([original isKindOfClass:NSData.class] ? bytes : updated);
                    }];
            }
            return;
        }
        if (payload.format == FEDFormatText) {
            [self fedTextForKey:key initial:payload.value title:@"Decoded UTF-8"
                converter:^id(NSString *updated, NSString **failure) {
                    NSData *bytes = [updated dataUsingEncoding:NSUTF8StringEncoding];
                    return base64 ? FEDRewrapBase64(bytes, original)
                        : ([original isKindOfClass:NSData.class] ? bytes : updated);
                }];
            return;
        }
        if (payload.format == FEDFormatBytes) {
            [self fedTextForKey:key initial:FEDHex(payload.value) title:@"Decoded bytes · HEX"
                converter:^id(NSString *updated, NSString **failure) {
                    NSData *bytes = FEDUnhex(updated);
                    if (!bytes) { *failure = @"Expected hexadecimal bytes (00–FF)."; return nil; }
                    return base64 ? FEDRewrapBase64(bytes, original) : bytes;
                }];
            return;
        }
    }
    FEDTreeViewController *child = [FEDTreeViewController new];
    child.node = payload.value;
    child.session = self.session;
    child.title = [key description];
    __weak typeof(self) weakSelf = self;
    child.onMutation = ^{
        NSError *error = nil;
        NSData *bytes = FEDEncode(payload, &error);
        if (!bytes) {
            [weakSelf fedError:error.localizedDescription ?: @"Encoding failed."];
            return;
        }
        id restored = base64 ? FEDRewrapBase64(bytes, original)
            : ([original isKindOfClass:NSData.class] ? bytes
                : [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding]);
        if (!restored) {
            [weakSelf fedError:@"Could not restore the original field type."];
            return;
        }
        FEDTreeViewController *owner = weakSelf;
        if (!owner) return;
        FEDSetValue(owner.node, key, restored);
        [owner fedChanged];
    };
    [self.navigationController pushViewController:child animated:YES];
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [table deselectRowAtIndexPath:indexPath animated:YES];
    id key = self.keys[(NSUInteger)indexPath.row];
    id value = FEDValue(self.node, key);
    if ([value isKindOfClass:NSDictionary.class] ||
        [value isKindOfClass:NSArray.class]) {
        FEDTreeViewController *child = [FEDTreeViewController new];
        child.node = value; child.session = self.session;
        child.title = [key description]; child.onMutation = self.onMutation;
        [self.navigationController pushViewController:child animated:YES];
        return;
    }
    if ([value isKindOfClass:NSData.class]) {
        [self fedOpenEmbedded:FEDParse(value) atKey:key originalValue:value isBase64:NO];
        return;
    }
    if ([value isKindOfClass:NSString.class]) {
        BOOL base64 = NO;
        FEDPayload *embedded = FEDPayloadInString(value, &base64);
        if (embedded) {
            [self fedOpenEmbedded:embedded atKey:key originalValue:value isBase64:base64];
        } else if (FEDDecodeBase64(value)) {
            // Base64 without a recognized signature still remains accessible.
            UIAlertController *choose = [UIAlertController alertControllerWithTitle:
                [key description] message:@"Choose how to interpret this string"
                preferredStyle:UIAlertControllerStyleActionSheet];
            __weak typeof(self) weakSelf = self;
            [choose addAction:[UIAlertAction actionWithTitle:@"Edit original string"
                style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                    [weakSelf fedTextForKey:key initial:value title:@"Edit original string"
                        converter:^id(NSString *text, NSString **failure) { return text; }];
                }]];
            [choose addAction:[UIAlertAction actionWithTitle:@"Decode as Base64"
                style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                    NSData *decoded = FEDDecodeBase64(value);
                    [weakSelf fedOpenEmbedded:FEDParse(decoded) atKey:key
                        originalValue:value isBase64:YES];
                }]];
            [choose addAction:[UIAlertAction actionWithTitle:@"Cancel"
                style:UIAlertActionStyleCancel handler:nil]];
            choose.popoverPresentationController.sourceView = table;
            choose.popoverPresentationController.sourceRect =
                [table rectForRowAtIndexPath:indexPath];
            [self presentViewController:choose animated:YES completion:nil];
        } else {
            [self fedTextForKey:key initial:value title:@"Edit string"
                converter:^id(NSString *text, NSString **error) { return text; }];
        }
        return;
    }
    if ([value isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) {
        UIAlertController *choose = [UIAlertController
            alertControllerWithTitle:[key description] message:@"Boolean value"
            preferredStyle:UIAlertControllerStyleActionSheet];
        __weak typeof(self) weakSelf = self;
        for (NSNumber *flag in @[@YES, @NO]) {
            [choose addAction:[UIAlertAction actionWithTitle:
                flag.boolValue ? @"true" : @"false"
                style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                    FEDSetValue(weakSelf.node, key, flag);
                    [weakSelf fedChanged];
                }]];
        }
        [choose addAction:[UIAlertAction actionWithTitle:@"Cancel"
            style:UIAlertActionStyleCancel handler:nil]];
        choose.popoverPresentationController.sourceView = table;
        choose.popoverPresentationController.sourceRect =
            [table rectForRowAtIndexPath:indexPath];
        [self presentViewController:choose animated:YES completion:nil];
        return;
    }
    if ([value isKindOfClass:NSNumber.class]) {
        [self fedTextForKey:key initial:[value stringValue] title:@"Edit number"
            converter:^id(NSString *text, NSString **failure) {
                NSString *trim = [text stringByTrimmingCharactersInSet:
                    NSCharacterSet.whitespaceAndNewlineCharacterSet];
                NSScanner *scanner = [NSScanner scannerWithString:trim];
                double parsed = 0;
                if (!trim.length || ![scanner scanDouble:&parsed] ||
                    !scanner.isAtEnd || !isfinite(parsed)) {
                    *failure = @"Enter a valid finite number."; return nil;
                }
                if ([trim rangeOfCharacterFromSet:
                    [NSCharacterSet characterSetWithCharactersInString:@".eE"]]
                    .location == NSNotFound) {
                    long long integer = 0;
                    NSScanner *integerScanner = [NSScanner scannerWithString:trim];
                    if ([integerScanner scanLongLong:&integer] && integerScanner.isAtEnd)
                        return @(integer);
                }
                return @(parsed);
            }];
        return;
    }
    if ([value isKindOfClass:NSDate.class]) {
        NSISO8601DateFormatter *dates = [NSISO8601DateFormatter new];
        dates.formatOptions = NSISO8601DateFormatWithInternetDateTime;
        [self fedTextForKey:key initial:[dates stringFromDate:value] title:@"ISO-8601 date"
            converter:^id(NSString *text, NSString **failure) {
                NSDate *date = [dates dateFromString:text];
                if (!date) *failure = @"Enter an ISO-8601 date.";
                return date;
            }];
        return;
    }
    if (value == NSNull.null) {
        [self fedTextForKey:key initial:@"" title:@"Replace null with string"
            converter:^id(NSString *text, NSString **failure) { return text; }];
        return;
    }
    [self fedError:@"Unsupported value type; the original bytes remain untouched."];
}
- (void)fedCancel { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)fedSave {
    if (!self.session.dirty) { [self fedCancel]; return; }
    NSError *error = nil;
    NSData *bytes = FEDEncode(self.session.document, &error);
    if (!bytes) {
        [self fedError:error.localizedDescription ?: @"Failed to rebuild document."];
        return;
    }
    FEDPayload *verification = FEDParse(bytes);
    if (!verification || verification.format != self.session.document.format) {
        [self fedError:@"Rebuilt document failed format validation."];
        return;
    }
    if (self.session.applyToNativeText) {
        NSString *text = [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding];
        UITextView *native = self.session.nativeTextView;
        if (!text || !native) {
            [self fedError:@"The original text editor is no longer available."];
            return;
        }
        // Hand off to Filza's real text editor. Filza still owns its Save flow.
        native.text = text;
        if ([native.delegate respondsToSelector:@selector(textViewDidChange:)])
            [native.delegate textViewDidChange:native];
        [NSNotificationCenter.defaultCenter postNotificationName:
            UITextViewTextDidChangeNotification object:native];
        [self dismissViewControllerAnimated:YES completion:nil];
        return;
    }
    NSString *path = self.session.filePath;
    if (!path.length) { [self fedError:@"No original file path was found."]; return; }
    NSData *current = [NSData dataWithContentsOfFile:path options:0 error:&error];
    if (!current || ![current isEqualToData:self.session.originalFile]) {
        [self fedError:@"The file changed after opening. Nothing was overwritten."];
        return;
    }
    // Back up exact original bytes before attempting a same-path write.
    NSString *documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!documents.length) { [self fedError:@"Could not locate backup storage."]; return; }
    NSString *backupFolder = [documents stringByAppendingPathComponent:
        @"FilzaEmbeddedDataBackups"];
    if (![NSFileManager.defaultManager createDirectoryAtPath:backupFolder
        withIntermediateDirectories:YES attributes:nil error:&error]) {
        [self fedError:error.localizedDescription ?: @"Backup folder failed."];
        return;
    }
    NSString *backup = [backupFolder stringByAppendingPathComponent:
        [NSString stringWithFormat:@"%@-%@.bak", path.lastPathComponent,
            NSUUID.UUID.UUIDString]];
    if (![current writeToFile:backup options:NSDataWritingAtomic error:&error]) {
        [self fedError:error.localizedDescription ?: @"Backup failed; original untouched."];
        return;
    }
    if (![bytes writeToFile:path options:0 error:&error]) {
        [self fedError:[NSString stringWithFormat:
            @"Save failed. Original backup is at %@. %@", backup,
            error.localizedDescription ?: @""]];
        return;
    }
    NSData *recheck = [NSData dataWithContentsOfFile:path options:0 error:nil];
    if (![recheck isEqualToData:bytes]) {
        [current writeToFile:path options:0 error:nil];
        [self fedError:[NSString stringWithFormat:
            @"Read-back verification failed. Original backup retained at %@", backup]];
        return;
    }
    [self dismissViewControllerAnimated:YES completion:nil];
}
@end

static UITextView *FEDFindTextView(UIView *view, NSUInteger depth) {
    if (!view || depth > 14) return nil;
    if ([view isKindOfClass:UITextView.class]) return (UITextView *)view;
    for (UIView *subview in view.subviews) {
        UITextView *found = FEDFindTextView(subview, depth + 1);
        if (found) return found;
    }
    return nil;
}
static NSString *FEDPathFromObject(id object) {
    if (!object) return nil;
    for (NSString *selectorName in @[@"filePath", @"fullPath", @"currentFilePath",
                                      @"path", @"fileURL", @"url"]) {
        SEL selector = NSSelectorFromString(selectorName);
        if (![object respondsToSelector:selector]) continue;
        Method method = class_getInstanceMethod([object class], selector);
        char returnType[16] = {0};
        if (!method) continue;
        method_getReturnType(method, returnType, sizeof(returnType));
        if (returnType[0] != '@') continue;
        id value = ((id (*)(id, SEL))objc_msgSend)(object, selector);
        if ([value isKindOfClass:NSURL.class]) value = [value path];
        if (![value isKindOfClass:NSString.class] || ![value hasPrefix:@"/"]) continue;
        BOOL directory = NO;
        if ([NSFileManager.defaultManager fileExistsAtPath:value isDirectory:&directory]
            && !directory) return value;
    }
    return nil;
}
static NSString *FEDFilePathForController(UIViewController *controller) {
    NSString *path = FEDPathFromObject(controller);
    if (path) return path;
    for (NSString *name in @[@"fileItem", @"currentFileItem", @"document", @"item"]) {
        SEL selector = NSSelectorFromString(name);
        if (![controller respondsToSelector:selector]) continue;
        Method method = class_getInstanceMethod([controller class], selector);
        char returnType[16] = {0};
        if (!method) continue;
        method_getReturnType(method, returnType, sizeof(returnType));
        if (returnType[0] != '@') continue;
        id item = ((id (*)(id, SEL))objc_msgSend)(controller, selector);
        path = FEDPathFromObject(item);
        if (path) return path;
    }
    return nil;
}

@interface FEDTextEditorAction : NSObject
@property(nonatomic, weak) UIViewController *host;
- (void)fedOpen;
@end
@implementation FEDTextEditorAction
- (void)fedOpen {
    UIViewController *host = self.host;
    if (!host) return;
    UITextView *editor = FEDFindTextView(host.view, 0);
    NSString *path = FEDFilePathForController(host);
    NSData *visible = [editor.text dataUsingEncoding:NSUTF8StringEncoding];
    FEDPayload *parsedVisible = visible.length ? FEDParse(visible) : nil;
    BOOL nativeText = parsedVisible && parsedVisible.format != FEDFormatBytes
        && parsedVisible.format != FEDFormatText;
    NSData *originalFile = nil;
    FEDPayload *payload = nil;
    if (nativeText) {
        payload = parsedVisible;
    } else if (path.length) {
        originalFile = [NSData dataWithContentsOfFile:path];
        payload = FEDParse(originalFile);
    } else if (visible.length) {
        payload = parsedVisible;
        nativeText = YES;
    }
    if (!payload || (![payload.value isKindOfClass:NSDictionary.class] &&
                     ![payload.value isKindOfClass:NSArray.class])) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:
            @"Embedded Data" message:
            @"This editor could not identify a plist/JSON dictionary or array. Open a .plist or .json as Text to inspect nested Base64."
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
            style:UIAlertActionStyleDefault handler:nil]];
        [host presentViewController:alert animated:YES completion:nil];
        return;
    }
    FEDSession *session = [FEDSession new];
    session.document = payload;
    session.originalFile = originalFile;
    session.filePath = path;
    session.applyToNativeText = nativeText;
    session.nativeTextView = editor;
    FEDTreeViewController *root = [FEDTreeViewController new];
    root.title = @"Embedded Data";
    root.node = payload.value; root.session = session; root.isRoot = YES;
    root.onMutation = ^{ session.dirty = YES; };
    UINavigationController *navigation =
        [[UINavigationController alloc] initWithRootViewController:root];
    navigation.modalPresentationStyle = UIModalPresentationFullScreen;
    [host presentViewController:navigation animated:YES completion:nil];
}
@end

static char kFEDActionKey;
static IMP gFEDOriginalDidAppear = NULL;
static BOOL FEDMatchesTextEditor(UIViewController *controller) {
    NSString *name = NSStringFromClass(controller.class).lowercaseString;
    if ([name hasPrefix:@"fed"] || [name containsString:@"plist"] ||
        [name containsString:@"hex"] || [name containsString:@"browser"])
        return NO;
    BOOL text = [name containsString:@"text"] || [name containsString:@"code"];
    BOOL editor = [name containsString:@"edit"] || [name containsString:@"view"];
    return text && editor && controller.navigationController != nil;
}
static void FEDInstallAccessory(UIViewController *controller) {
    if (!FEDMatchesTextEditor(controller)) return;
    // Do not add a control to unrelated text screens. Must have a text
    // surface or an explicit document path in this Filza editor instance.
    if (!FEDFindTextView(controller.view, 0) && !FEDFilePathForController(controller))
        return;
    for (UIBarButtonItem *existing in controller.navigationItem.rightBarButtonItems) {
        if ([existing.accessibilityIdentifier isEqualToString:
            @"filza.embedded-data.text-editor"]) return;
    }
    FEDTextEditorAction *action = objc_getAssociatedObject(controller, &kFEDActionKey);
    if (!action) {
        action = [FEDTextEditorAction new];
        action.host = controller;
        objc_setAssociatedObject(controller, &kFEDActionKey, action,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    UIBarButtonItem *button = [[UIBarButtonItem alloc] initWithTitle:@"Base64"
        style:UIBarButtonItemStylePlain target:action action:@selector(fedOpen)];
    button.accessibilityIdentifier = @"filza.embedded-data.text-editor";
    button.accessibilityLabel = @"Edit embedded Base64, JSON and plist";
    NSMutableArray *items = [controller.navigationItem.rightBarButtonItems mutableCopy]
        ?: [NSMutableArray array];
    [items addObject:button];
    controller.navigationItem.rightBarButtonItems = items;
}
static void FEDViewDidAppear(id self, SEL command, BOOL animated) {
    ((void (*)(id, SEL, BOOL))gFEDOriginalDidAppear)(self, command, animated);
    UIViewController *controller = (UIViewController *)self;
    if (!FEDMatchesTextEditor(controller)) return;
    FEDInstallAccessory(controller);
    __weak UIViewController *weak = controller;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC),
        dispatch_get_main_queue(), ^{ FEDInstallAccessory(weak); });
}

__attribute__((constructor)) static void FEDInstallTextEditorHook(void) {
    Method method = class_getInstanceMethod(UIViewController.class,
        @selector(viewDidAppear:));
    if (!method) return;
    gFEDOriginalDidAppear = method_getImplementation(method);
    method_setImplementation(method, (IMP)FEDViewDidAppear);
}
