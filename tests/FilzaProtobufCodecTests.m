#import <Foundation/Foundation.h>
#import "FilzaProtobufCodec.h"

static NSData *Bytes(NSString *hex) {
    NSMutableData *data = [NSMutableData data];
    for (NSUInteger i = 0; i + 1 < hex.length; i += 2) {
        unsigned int value = 0;
        NSString *pair = [hex substringWithRange:NSMakeRange(i, 2)];
        NSScanner *scanner = [NSScanner scannerWithString:pair];
        if (![scanner scanHexInt:&value]) return nil;
        uint8_t byte = (uint8_t)value;
        [data appendBytes:&byte length:1];
    }
    return data;
}
static void Check(BOOL condition, NSString *message) {
    if (!condition) { NSLog(@"FAIL: %@", message); exit(1); }
}
int main(void) {
    @autoreleasepool {
        // Three actual records taken from the 83,634-byte source. This test
        // fixture contains no authentication or account tokens.
        NSData *spotify = Bytes(@"0a501a070a0557686974652a1f696f732d666561747572652d72656d6f7465636f6e66696775726174696f6e321b627574746f6e5f636f6c6f725f64756d6d795f70726f706572747940eac5e20448c3cf200a320a0208012a11696f732d666561747572652d6c6f67696e321061615f746573745f70726f706572747940eae0e504488b87270a4c0a002a23696f732d666561747572652d636c69656e746d6573736167696e67706c6174666f726d321b6261636b5f6f6e6c696e655f747269676765725f656e61626c656440e0bb514883ce2d10a7c8c0d69e341a2c31613061393663322d303939642d356638652d346465662d6466353864383261353063653a3239303133353652167263733a223330363639313137343130353464373922");
        NSError *error = nil;
        NSDictionary *doc = FPBDecode(spotify, NO, &error);
        Check(doc != nil, [NSString stringWithFormat:@"Spotify decoded: %@", error]);
        Check([doc[@"records"] count] == 3, @"Spotify record count");
        Check([FPBEncode(doc, &error) isEqualToData:spotify], @"Spotify byte-perfect no-edit roundtrip");
        NSMutableDictionary *edited = [doc mutableCopy];
        NSMutableArray *records = [doc[@"records"] mutableCopy];
        NSMutableDictionary *record = [records[1] mutableCopy];
        record[@"value"] = @NO;
        records[1] = record;
        edited[@"records"] = records;
        NSData *changed = FPBEncode(edited, &error);
        Check(changed && ![changed isEqualToData:spotify], @"Spotify boolean edited");
        NSDictionary *decodedAgain = FPBDecode(changed, NO, &error);
        Check(decodedAgain != nil && ![decodedAgain[@"records"][1][@"value"] boolValue], @"Spotify bool preserved after reparse");
        // No heuristics for generic varints. Field 1 is 150; fields 2-4
        // respectively contain UTF8, fixed32 and fixed64 wire values.
        NSData *generic = Bytes(@"089601120568656c6c6f1d01020304210900000000000000");
        NSDictionary *genericDoc = FPBDecode(generic, YES, &error);
        Check(genericDoc != nil, @"Generic wire decoded");
        Check([FPBEncode(genericDoc, &error) isEqualToData:generic], @"Generic exact roundtrip");
        Check([genericDoc[@"fields"][0][@"value"] isEqual:@"150"], @"Generic uint64 retains decimal representation");
        NSMutableDictionary *genericEdited = [genericDoc mutableCopy];
        NSMutableArray *fields = [genericDoc[@"fields"] mutableCopy];
        NSMutableDictionary *field = [fields[1] mutableCopy];
        field[@"value"] = @"world";
        fields[1] = field;
        genericEdited[@"fields"] = fields;
        NSData *newGeneric = FPBEncode(genericEdited, &error);
        Check(newGeneric != nil && ![newGeneric isEqualToData:generic], @"Generic UTF8 edit encoded");
        Check([FPBDecode(newGeneric, YES, &error)[@"fields"][1][@"value"] isEqual:@"world"], @"Generic text edit roundtripped");
        Check(FPBDecode(Bytes(@"0a06ff"), YES, &error) == nil, @"Truncated wire rejected");
        Check(FPBDecode(Bytes(@"0b0c"), YES, &error) == nil, @"Unsupported groups rejected");
        NSLog(@"PASS: Spotify + generic Protobuf encode/decode and invalid-input cases");
    }
    return 0;
}
