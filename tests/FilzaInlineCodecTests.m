// Native Foundation-only regression suite for the *same* decoder used
// by the iOS Filza editor. No private user data is used.
#define FILZA_INLINE_CODEC_TESTS 1
#import "../FilzaInlineTextEditor.m"

static void FZIRequire(BOOL condition, NSString *message) {
    if (condition) return;
    NSLog(@"[FAIL] %@", message);
    abort();
}
static NSData *FZIPlist(id object, NSPropertyListFormat fmt) {
    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:object
        format:fmt options:0 error:&error];
    FZIRequire(data != nil, error.localizedDescription ?: @"encode failed");
    return data;
}
static id FZIReadPlist(NSData *bytes) {
    NSError *error = nil;
    id decoded = [NSPropertyListSerialization propertyListWithData:bytes
        options:NSPropertyListMutableContainersAndLeaves format:NULL error:&error];
    FZIRequire(decoded != nil, error.localizedDescription ?: @"decode failed");
    return decoded;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSMutableDictionary *abprops = [NSMutableDictionary dictionaryWithCapacity:6916];
        for (NSUInteger i=0; i<6916; ++i) {
            NSString *key = [NSString stringWithFormat:@"%lu", (unsigned long)i];
            abprops[key] = @{@"value":[NSString stringWithFormat:@"v%lu",
                                       (unsigned long)i], @"expoKey":@7};
        }
        NSData *binaryABProps = FZIPlist(abprops,
            NSPropertyListBinaryFormat_v1_0);
        NSData *opaque = [NSData dataWithBytes:
            "\x00\x01\x02\x03\x04\x05\x06\x07"
            "\x08\x09\x0A\x0B\x0C\x0D\x0E\x0F" length:16];
        NSData *nestedJSON = [NSJSONSerialization dataWithJSONObject:
            @{@"opaque":[opaque base64EncodedStringWithOptions:0]}
            options:0 error:nil];
        NSData *admc = [NSJSONSerialization dataWithJSONObject:@[
            @{@"id":@0, @"title":@"Sample",
              @"nested":[nestedJSON base64EncodedStringWithOptions:0]}]
            options:0 error:nil];
        NSData *policy = FZIPlist(@{@"archive":@"NSKeyedArchiver",
            @"objects":@[@0, @"original"]}, NSPropertyListBinaryFormat_v1_0);
        NSString *identifier = [opaque base64EncodedStringWithOptions:0];
        NSDictionary *root = @{
            @"gabp.ofrep-test@s.whatsapp.netp":binaryABProps,
            @"admc":admc,
            @"DownloadPolicy":policy,
            @"OwnCountryCode":identifier
        };
        NSString *source = [[NSString alloc] initWithData:
            FZIPlist(root, NSPropertyListXMLFormat_v1_0)
            encoding:NSUTF8StringEncoding];
        FZIProjection *projection = FZIMakeProjection(source);
        FZIRequire(projection != nil, @"inline projection must be reversible");
        FZIRequire([projection.display containsString:@"WhatsApp ABProps"],
            @"ABProps block must have a searchable category label");
        FZIRequire([projection.display containsString:@"<key>1004</key>"],
            @"all 6,916 numeric ABProps values must be visible");
        FZIRequire([projection.display containsString:@"\"nested\" : {"],
            @"nested Base64 JSON must appear directly as decoded JSON");
        FZIRequire([projection.display rangeOfString:@"__filza_inline_base64_v1__"].location == NSNotFound,
            @"transport metadata must never appear in the user-visible editor");
        FZIRequire([projection.display containsString:@"00 01 02 03"],
            @"short opaque Base64 must decode to HEX");
        NSError *error=nil;
        NSString *identical = FZIValidateAndRestore(
            projection, projection.display, &error);
        FZIRequire([identical isEqualToString:source],
            error.localizedDescription ?: @"no-op roundtrip changed source XML");
        NSString *edited = [projection.display
            stringByReplacingOccurrencesOfString:@"v1004"
            withString:@"EDITED"];
        edited = [edited stringByReplacingOccurrencesOfString:@"Sample"
            withString:@"Changed"];
        edited = [edited stringByReplacingOccurrencesOfString:@"\"opaque\" : \"00 01"
            withString:@"\"opaque\" : \"FF 01"];
        FZIRequire(![edited isEqualToString:projection.display],
            @"test must actually modify the visible projection");
        error=nil;
        NSString *restored=FZIValidateAndRestore(projection,edited,&error);
        FZIRequire(restored != nil,
            error.localizedDescription ?: @"edited inline XML did not rebuild");
        NSDictionary *finalRoot = FZIReadPlist([restored
            dataUsingEncoding:NSUTF8StringEncoding]);
        NSDictionary *finalABProps = FZIReadPlist(
            finalRoot[@"gabp.ofrep-test@s.whatsapp.netp"]);
        FZIRequire(finalABProps.count == 6916,
            @"number of ABProps entries was changed");
        FZIRequire([finalABProps[@"1004"][@"value"] isEqual:@"EDITED"],
            @"edited parameter did not persist");
        FZIRequire([finalRoot[@"DownloadPolicy"] isEqual:policy],
            @"unchanged binary data must be preserved exactly");
        NSArray *finalAdmc=[NSJSONSerialization JSONObjectWithData:
            finalRoot[@"admc"] options:0 error:&error];
        FZIRequire([finalAdmc[0][@"title"] isEqualToString:@"Changed"],
            @"nested JSON edit was not re-encoded correctly");
        NSData *nestedData=[[NSData alloc] initWithBase64EncodedString:
            finalAdmc[0][@"nested"] options:0];
        NSDictionary *nestedDecoded=[NSJSONSerialization JSONObjectWithData:
            nestedData options:0 error:&error];
        NSData *opaqueModified=[[NSData alloc] initWithBase64EncodedString:
            nestedDecoded[@"opaque"] options:0];
        FZIRequire(opaqueModified.length == 16 &&
            ((const unsigned char *)opaqueModified.bytes)[0] == 0xFF,
            @"edited HEX inside nested JSON/Base64 did not round-trip");
        FZIRequire([finalRoot[@"OwnCountryCode"] isEqualToString:identifier],
            @"untouched Base64 value must retain its original representation");
        NSData *backToBinary = FZIPlist(finalRoot,
            NSPropertyListBinaryFormat_v1_0);
        FZIRequire([[backToBinary subdataWithRange:NSMakeRange(0,8)]
            isEqualToData:[@"bplist00" dataUsingEncoding:NSUTF8StringEncoding]],
            @"root binary format must remain bplist00 after conversion");
        NSString *broken = [projection.display
            stringByReplacingOccurrencesOfString:@"\"title\" : \"Sample\""
            withString:@"\"title\" : invalid"];
        FZIRequire(![broken isEqualToString:projection.display],
            @"broken JSON scenario was not constructed");
        NSError *badError=nil;
        NSString *invalid=FZIValidateAndRestore(projection,broken,&badError);
        FZIRequire(invalid == nil, @"invalid JSON must be rejected before saving");
        NSLog(@"[PASS] native inline codec: 6916 ABProps, nested JSON/Base64, "
              @"short HEX, valid edits, byte-preserving no-op, malformed JSON");
    }
    return 0;
}
