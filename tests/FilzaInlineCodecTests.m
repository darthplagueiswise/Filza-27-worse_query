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
        FZIRequire([projection.display rangeOfString:@"<!-- WhatsApp ABProps"].location == NSNotFound,
            @"the generic codec must not inject application-specific XML comments");
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
        // Top-level JSON opened in the same native text editor: the Base64
        // payload is readable, but untouched surrounding JSON stays byte equal.
        NSData *rootJSONPayload=[NSJSONSerialization dataWithJSONObject:
            @{@"config":@{@"enabled":@YES, @"version":@3}}
            options:0 error:nil];
        NSString *encodedRootJSON=[rootJSONPayload base64EncodedStringWithOptions:0];
        NSString *rootJSONString=[NSString stringWithFormat:
            @"{ \"ordinary\" : \"metadata\", \"payload\" : \"%@\", \"untouched\" : 7 }\n",
            encodedRootJSON];
        FZIProjection *rootProjection=FZIMakeProjection(rootJSONString);
        FZIRequire(rootProjection != nil, @"root JSON Base64 projection required");
        FZIRequire([rootProjection.display containsString:@"\"enabled\""],
            @"root JSON Base64 must display decoded JSON");
        FZIRequire([rootProjection.display containsString:@"metadata"],
            @"ordinary strings must not be mistaken for Base64");
        NSError *rootError=nil;
        FZIRequire([[FZIValidateAndRestore(rootProjection,
            rootProjection.display,&rootError) description] isEqual:rootJSONString],
            @"untouched JSON must be byte-for-byte identical");
        NSString *jsonEdited=[rootProjection.display
            stringByReplacingOccurrencesOfString:@"\"version\" : 3"
            withString:@"\"version\" : 4"];
        FZIRequire(![jsonEdited isEqual:rootProjection.display],
            @"root JSON edit is visible");
        NSString *restoredJSON=FZIValidateAndRestore(rootProjection,jsonEdited,&rootError);
        FZIRequire(restoredJSON != nil,
            rootError.localizedDescription ?: @"root JSON save failure");
        id restoredJSONRoot=[NSJSONSerialization JSONObjectWithData:
            [restoredJSON dataUsingEncoding:NSUTF8StringEncoding]
            options:0 error:&rootError];
        NSData *restoredJSONBytes=[[NSData alloc]
            initWithBase64EncodedString:restoredJSONRoot[@"payload"] options:0];
        id restoredJSONPayload=[NSJSONSerialization JSONObjectWithData:
            restoredJSONBytes options:0 error:&rootError];
        FZIRequire([restoredJSONPayload[@"config"][@"version"] isEqual:@4],
            @"root JSON nested Base64 edit not persisted");
        // The original JSON file is not globally pretty-printed or compacted:
        // replacing one encoded value must preserve all other characters.
        FZIRequire([restoredJSON hasPrefix:
            @"{ \"ordinary\" : \"metadata\", \"payload\" : \""],
            @"the JSON prefix must remain byte-identical after a nested edit");
        FZIRequire([restoredJSON hasSuffix:
            @"\", \"untouched\" : 7 }\n"],
            @"the JSON suffix (spaces/newline) must remain byte-identical");


        // URL-safe and unpadded Base64 are valid encodings, not plain text.
        NSData *urlBytes=[NSData dataWithBytes:
            "\xfb\xff\xfe\xfa\xf9\xf8\xff\xfe\xfd" length:9];
        NSString *urlEncoded=[[urlBytes base64EncodedStringWithOptions:0]
            stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
        urlEncoded=[urlEncoded stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
        NSString *urlXML=[NSString stringWithFormat:
            @"<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>url</key><string>%@</string></dict></plist>",
            urlEncoded];
        FZIProjection *urlProjection=FZIMakeProjection(urlXML);
        FZIRequire(urlProjection != nil &&
            [urlProjection.display containsString:@"FB FF"],
            @"Base64URL should project as readable HEX");
        NSString *urlEdited=[urlProjection.display
            stringByReplacingOccurrencesOfString:@"FB FF"
            withString:@"FA FF"];
        NSError *urlError=nil;
        NSString *urlRestored=FZIValidateAndRestore(urlProjection,urlEdited,&urlError);
        FZIRequire(urlRestored != nil, urlError.localizedDescription ?: @"Base64URL failed");
        NSDictionary *urlOutput=FZIReadPlist([urlRestored
            dataUsingEncoding:NSUTF8StringEncoding]);
        NSString *savedURL=urlOutput[@"url"];
        FZIRequire([savedURL containsString:@"_"] || [savedURL containsString:@"-"],
            @"Base64URL alphabet must be preserved");
        FZIRequire([savedURL rangeOfString:@"="].location==NSNotFound,
            @"unmodified Base64URL padding style must be retained");

        // Unchanged unrelated XML <data> payload must retain its exact bytes
        // and original Base64 line wrapping, even when another field is edited.
        NSString *wrappedXML=@"<?xml version=\"1.0\"?><plist version=\"1.0\"><dict>"
            @"<key>unchanged</key><data>\n  AQIDBAUG\n  BwgJCgsM\n</data>"
            @"<key>modified</key><string>SGVsbG8gV29ybGQh</string>"
            @"</dict></plist>";
        FZIProjection *wrappedProjection=FZIMakeProjection(wrappedXML);
        FZIRequire(wrappedProjection!=nil, @"two independent encoded fields");
        NSString *wrappedEdit=[wrappedProjection.display
            stringByReplacingOccurrencesOfString:@"Hello World!"
            withString:@"Hello Filza!"];
        NSString *wrappedRestored=FZIValidateAndRestore(wrappedProjection,wrappedEdit,NULL);
        FZIRequire([wrappedRestored containsString:@"<data>\n  AQIDBAUG\n  BwgJCgsM\n</data>"],
            @"unchanged Base64 bytes and line wrapping must not be rewritten");
        FZIRequire([wrappedRestored containsString:@"SGVsbG8gV29ybGQh"]==NO,
            @"changed Base64 field must be updated");

        // A JSON object packed into XML <data> is edited from the same
        // readable projection. Its original JSON spacing and untouched
        // sibling tokens are preserved before the outer Base64 is rebuilt.
        NSString *originalNestedJSON=@"{ \"first\" : 1, \"payload\" : \"SGVsbG8=\", \"other\" : \"AQID\" }\n";
        NSString *nestedCarrier=[NSString stringWithFormat:
            @"<?xml version=\"1.0\"?><plist version=\"1.0\"><dict>"
             "<key>nested</key><data>%@</data></dict></plist>",
            [[originalNestedJSON dataUsingEncoding:NSUTF8StringEncoding]
                base64EncodedStringWithOptions:0]];
        FZIProjection *nestedProjection=FZIMakeProjection(nestedCarrier);
        if (!nestedProjection || ![nestedProjection.display containsString:@"Hello"]) {
            NSMutableArray *diagnosticBlocks=[NSMutableArray array];
            NSString *projected=FZIProjectXML(nestedCarrier,diagnosticBlocks,0);
            NSError *scanError=nil;
            NSString *restored=FZIRestoreXML(projected,diagnosticBlocks,&scanError);
            NSLog(@"[FZI_DEBUG] nested=%@ blocks=%lu restoredEqual=%d err=%@ original=%@",
                  projected,(unsigned long)diagnosticBlocks.count,
                  [restored isEqualToString:nestedCarrier],
                  scanError.localizedDescription,nestedCarrier);
        }
        FZIRequire(nestedProjection!=nil &&
                   [nestedProjection.display containsString:@"Hello"],
                   @"JSON nested in XML Base64 must decode for editing");
        NSString *nestedEdited=[nestedProjection.display
            stringByReplacingOccurrencesOfString:@"Hello" withString:@"Filza"];
        NSError *nestedErr=nil;
        NSString *nestedResult=FZIValidateAndRestore(nestedProjection,
            nestedEdited,&nestedErr);
        FZIRequire(nestedResult!=nil,
            nestedErr.localizedDescription ?: @"rebuild nested data JSON");
        NSDictionary *nestedPlist=FZIReadPlist(
            [nestedResult dataUsingEncoding:NSUTF8StringEncoding]);
        NSString *savedJSON=[[NSString alloc] initWithData:nestedPlist[@"nested"]
                                                 encoding:NSUTF8StringEncoding];
        FZIRequire([savedJSON hasPrefix:@"{ \"first\" : 1, \"payload\" : \""],
                   @"original embedded JSON prefix must be preserved");
        FZIRequire([savedJSON hasSuffix:@"\", \"other\" : \"AQID\" }\n"],
                   @"untouched embedded Base64 sibling and JSON whitespace must remain");
        NSDictionary *nestedDictionary=[NSJSONSerialization JSONObjectWithData:
            nestedPlist[@"nested"] options:0 error:nil];
        NSString *changedInner=[[NSString alloc] initWithData:
            [[NSData alloc] initWithBase64EncodedString:nestedDictionary[@"payload"]
                                              options:0] encoding:NSUTF8StringEncoding];
        FZIRequire([changedInner isEqualToString:@"Filza"],
                   @"edited Base64 inside XML data JSON was not re-encoded");

        NSLog(@"[PASS] native inline codec: 6916 ABProps, nested JSON/Base64, "
              @"short HEX, valid edits, byte-preserving no-op, malformed JSON");
    }
    return 0;
}
