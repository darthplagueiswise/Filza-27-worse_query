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
        FZIRequire([projection.display rangeOfString:@"00 01 02 03"].location==NSNotFound,
            @"opaque binary must not appear as misleading HEX");
        FZIRequire([projection.display containsString:identifier],
            @"opaque Base64 without a readable payload must stay unchanged");
        FZIRequire(projection.visualEdits.count>0 &&
            [FZIApplyVisualEdits(source,projection.visualEdits)
                isEqualToString:projection.display],
            @"visual edits must exactly reproduce the reversible projection");
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
        FZIRequire([nestedDecoded[@"opaque"] isEqualToString:identifier],
            @"untouched opaque binary Base64 inside JSON must stay byte-identical");
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
            stringByReplacingOccurrencesOfString:@"\"version\":3"
            withString:@"\"version\":4"];
        if ([jsonEdited isEqualToString:rootProjection.display])
            jsonEdited=[rootProjection.display
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


        // Base64URL that decodes to readable Unicode stays URL-safe and
        // unpadded. Opaque random bytes are never shown as HEX.
        NSString *urlEncoded=@"8J-YgA"; // UTF-8 😀 in unpadded Base64URL
        NSString *urlXML=[NSString stringWithFormat:
            @"<?xml version=\"1.0\"?><plist version=\"1.0\"><dict>"
             "<key>url</key><string>%@</string></dict></plist>",urlEncoded];
        FZIProjection *urlProjection=FZIMakeProjection(urlXML);
        FZIRequire(urlProjection!=nil &&
            [urlProjection.display containsString:@"😀"],
            @"readable UTF-8 in Base64URL should appear as text");
        NSString *urlEdited=[urlProjection.display
            stringByReplacingOccurrencesOfString:@"😀" withString:@"👋"];
        NSString *urlRestored=FZIValidateAndRestore(urlProjection,urlEdited,NULL);
        FZIRequire(urlRestored!=nil, @"Base64URL edit must save");
        NSDictionary *urlOutput=FZIReadPlist([urlRestored
            dataUsingEncoding:NSUTF8StringEncoding]);
        NSString *savedURL=urlOutput[@"url"];
        FZIRequire([savedURL hasPrefix:@"8J-"] &&
            [savedURL rangeOfString:@"="].location==NSNotFound,
            @"edited Base64URL must retain its alphabet and padding style");

        NSString *uid1=@"659E2047-9BC6-4413-9702-1940A688D834";
        NSString *uid2=@"7A36FB3D-DA2B-4883-ADB1-DC89E09AF507";
        NSString *uidXML=[NSString stringWithFormat:
            @"<?xml version=\"1.0\"?><plist version=\"1.0\"><dict>"
             "<key>first</key><string>%@</string>"
             "<key>second</key><string>%@</string>"
             "<key>encodedWord</key><string>SGVsbG8=</string>"
             "<key>notEncoded</key><string>metadata</string>"
             "</dict></plist>",uid1,uid2];
        FZIProjection *uidProjection=FZIMakeProjection(uidXML);
        FZIRequire(uidProjection!=nil,@"Base64 word should decode beside UUIDs");
        FZIRequire([uidProjection.display containsString:uid1] &&
                   [uidProjection.display containsString:uid2],
            @"UUIDs must never be decoded or displayed as binary");
        FZIRequire([uidProjection.display containsString:
            @"<string>Hello</string>"],@"Base64 word must decode to readable text");
        FZIRequire([uidProjection.display containsString:
            @"<string>metadata</string>"],@"ordinary text must stay unchanged");
        FZIRequire(uidProjection.visualEdits.count==1 &&
            [FZIApplyVisualEdits(uidXML,uidProjection.visualEdits)
                isEqualToString:uidProjection.display],
            @"only one encoded field should change in the colored text view");
        FZIRequire([FZIValidateAndRestore(uidProjection,
            uidProjection.display,NULL) isEqualToString:uidXML],
            @"UUID and original Base64 must be lossless when saving without edits");

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

        // JSON strings are not XML nodes. In particular a binary plist
        // decoded into a JSON string contains literal <string>...</string>
        // tags, and unrelated JSON strings may contain the same markup.
        NSDictionary *twoLevelPlist=@{@"inner":@"before", @"flag":@1};
        NSData *twoLevelBinary=FZIPlist(twoLevelPlist,
            NSPropertyListBinaryFormat_v1_0);
        NSString *twoLevelB64=[twoLevelBinary base64EncodedStringWithOptions:0];
        NSDictionary *twoLevelJSON=@{@"plist":twoLevelB64,
                                    @"literal":@"<string>keep me</string>",
                                    @"untouched":@"not encoded"};
        NSData *twoLevelJSONData=[NSJSONSerialization dataWithJSONObject:
            twoLevelJSON options:0 error:nil];
        NSString *twoLevelXML=[NSString stringWithFormat:
            @"<?xml version=\"1.0\"?><plist version=\"1.0\"><dict>"
             "<key>nested</key><data>%@</data></dict></plist>",
            [twoLevelJSONData base64EncodedStringWithOptions:0]];
        FZIProjection *twoLevelView=FZIMakeProjection(twoLevelXML);
        FZIRequire(twoLevelView!=nil,
            @"JSON containing inner binary plist must form a reversible projection");
        FZIRequire([twoLevelView.display containsString:@"before"] &&
                   [twoLevelView.display containsString:@"keep me"],
            @"recursive binary plist and JSON literal must be readable");
        NSString *twoLevelNoop=FZIValidateAndRestore(twoLevelView,
            twoLevelView.display,NULL);
        FZIRequire([twoLevelNoop isEqualToString:twoLevelXML],
            @"unchanged recursive document must preserve exact XML and Base64");
        NSString *twoLevelEdited=[twoLevelView.display
            stringByReplacingOccurrencesOfString:@"before"
            withString:@"after"];
        FZIRequire(![twoLevelEdited isEqualToString:twoLevelView.display],
            @"nested binary plist edit must change the visible projection");
        NSError *twoLevelError=nil;
        NSString *twoLevelOutput=FZIValidateAndRestore(twoLevelView,
            twoLevelEdited,&twoLevelError);
        FZIRequire(twoLevelOutput!=nil,
            twoLevelError.localizedDescription ?: @"nested binary plist failed");
        NSDictionary *twoLevelOuter=FZIReadPlist(
            [twoLevelOutput dataUsingEncoding:NSUTF8StringEncoding]);
        NSDictionary *twoLevelEncodedJSON=[NSJSONSerialization JSONObjectWithData:
            twoLevelOuter[@"nested"] options:0 error:nil];
        FZIRequire([twoLevelEncodedJSON[@"literal"] isEqualToString:
            @"<string>keep me</string>"], @"literal JSON markup must remain unchanged");
        FZIRequire([twoLevelEncodedJSON[@"untouched"] isEqualToString:
            @"not encoded"], @"plain JSON sibling must remain unchanged");
        NSData *twoLevelRebuilt=[[NSData alloc] initWithBase64EncodedString:
            twoLevelEncodedJSON[@"plist"] options:0];
        FZIRequire(twoLevelRebuilt.length>=8 &&
            !memcmp(twoLevelRebuilt.bytes,"bplist00",8),
            @"edited inner plist must retain original binary format");
        NSDictionary *twoLevelResult=FZIReadPlist(twoLevelRebuilt);
        FZIRequire([twoLevelResult[@"inner"] isEqualToString:@"after"],
            @"nested binary plist value was not re-encoded");

        // This fixture was generated independently with Python Apache Thrift.
        // It includes list-of-struct, signed varint, nested binary Thrift,
        // map and bool. It contains no private user data.
        NSString *thriftFixture=@"GSwYE2NsaWVudF9pcF9kaXNjb3ZlcnkVkE4YIRgcaHR0cHM6Ly9leGFtcGxlLm5ldC9lbmRwb2ludBUOAAAYDWNsaWVudF91cGxvYWQRABsBhAVsaW1pdEIA";
        NSData *thriftBytes=[[NSData alloc] initWithBase64EncodedString:
            thriftFixture options:0];
        NSDictionary *typedThrift=FZICompactThriftDecode(thriftBytes);
        FZIRequire(typedThrift!=nil,@"Thrift Compact fixture must fully decode");
        FZIRequire([FZICompactThriftEncode(typedThrift)
            isEqualToData:thriftBytes],@"Thrift Compact must re-encode byte-exact");
        NSDictionary *thriftView=FZICompactThriftDisplay(typedThrift);
        FZIRequire([thriftView isKindOfClass:NSDictionary.class],
            @"Thrift projection must be an editable JSON object");
        NSDictionary *thriftTask=thriftView[@"field_1"][0];
        FZIRequire([thriftTask[@"field_1"] isEqualToString:
            @"client_ip_discovery"],@"Thrift nested task name must be readable");
        FZIRequire([thriftTask[@"field_2"] isEqual:@5000],
            @"Thrift typed integer must be readable");
        FZIRequire([thriftTask[@"field_3"][@"field_1"] isEqualToString:
            @"https://example.net/endpoint"],@"nested Thrift binary must be readable");
        NSData *mutableData=[NSJSONSerialization dataWithJSONObject:thriftView
            options:0 error:nil];
        NSMutableDictionary *editableThrift=[NSJSONSerialization
            JSONObjectWithData:mutableData options:NSJSONReadingMutableContainers
            error:nil];
        editableThrift[@"field_1"][0][@"field_2"]=@6000;
        NSError *thriftError=nil;
        NSData *reencodedThrift=FZICompactThriftEncodeEdited(typedThrift,
            editableThrift,&thriftError);
        FZIRequire(reencodedThrift!=nil,
            thriftError.localizedDescription ?: @"Thrift edit must reencode");
        NSDictionary *parsedAfter=FZICompactThriftDisplay(
            FZICompactThriftDecode(reencodedThrift));
        FZIRequire([parsedAfter[@"field_1"][0][@"field_2"] isEqual:@6000],
            @"edited Thrift integer was not saved");
        FZIRequire([parsedAfter[@"field_1"][0][@"field_3"]
            isEqual:thriftTask[@"field_3"]],
            @"untouched nested Thrift structure must remain unchanged");
        // Meta's official Compact Protocol uses CType::Float=13
        // (4-byte little-endian IEEE 754), NOT UUID. Check both directions.
        const uint8_t floatCompactBytes[]={
            0x1d, 0x00, 0x00, 0xc0, 0x3f, // field_1 float 1.5
            0x18, 0x05, 'h','e','l','l','o', // field_2 string
            0x00 // stop
        };
        NSData *floatCompact=[NSData dataWithBytes:floatCompactBytes
                                           length:sizeof(floatCompactBytes)];
        NSDictionary *floatTree=FZICompactThriftDecode(floatCompact);
        FZIRequire(floatTree!=nil,@"Meta Compact float code 13 should decode");
        FZIRequire([FZICompactThriftEncode(floatTree) isEqualToData:floatCompact],
            @"Meta Compact float fixture must round-trip byte exact");
        NSDictionary *floatView=FZICompactThriftDisplay(floatTree);
        FZIRequire([floatView[@"field_1"] isEqual:@1.5f] &&
                   [floatView[@"field_2"] isEqualToString:@"hello"],
            @"float must be a 32-bit number, not a UUID");
        NSMutableDictionary *floatEdited=[floatView mutableCopy];
        floatEdited[@"field_1"]=@2.5f;
        NSData *floatOutput=FZICompactThriftEncodeEdited(floatTree,floatEdited,NULL);
        const uint8_t expectedFloat[]={
            0x1d, 0x00, 0x00, 0x20, 0x40,
            0x18, 0x05, 'h','e','l','l','o',0x00
        };
        FZIRequire([floatOutput isEqualToData:
            [NSData dataWithBytes:expectedFloat length:sizeof(expectedFloat)]],
            @"edited float must preserve the correct Compact wire format");
        FZIRequire(FZICompactThriftEncodeEdited(floatTree,
            @{@"field_1":@(1e40),@"field_2":@"hello"},NULL)==nil,
            @"float overflow must refuse save instead of corrupting bytes");

        // Empty Thrift strings remain ordinary editable text, not an
        // unclassified binary token. Real plist sample contains such values.
        NSData *typedJSON=[NSJSONSerialization dataWithJSONObject:typedThrift
            options:0 error:nil];
        NSMutableDictionary *emptyTyped=[NSJSONSerialization JSONObjectWithData:
            typedJSON options:NSJSONReadingMutableContainers error:nil];
        emptyTyped[@"fields"][0][@"value"][@"items"][0][@"fields"][0]
            [@"value"]=@{@"text":@""};
        NSData *emptyBinary=FZICompactThriftEncode(emptyTyped);
        NSDictionary *emptyDecoded=FZICompactThriftDecode(emptyBinary);
        FZIRequire(emptyDecoded!=nil && [emptyDecoded[@"fields"][0][@"value"]
            [@"items"][0][@"fields"][0][@"value"][@"text"] isEqualToString:@""],
            @"empty string must decode as editable text");
        NSMutableDictionary *emptyReadable=[NSJSONSerialization JSONObjectWithData:
            [NSJSONSerialization dataWithJSONObject:
             FZICompactThriftDisplay(emptyDecoded) options:0 error:nil]
            options:NSJSONReadingMutableContainers error:nil];
        emptyReadable[@"field_1"][0][@"field_1"]=@"edited-empty";
        NSData *emptySaved=FZICompactThriftEncodeEdited(emptyDecoded,
            emptyReadable,NULL);
        FZIRequire(emptySaved!=nil && [[FZICompactThriftDisplay(
            FZICompactThriftDecode(emptySaved)) objectForKey:@"field_1"][0]
            [@"field_1"] isEqualToString:@"edited-empty"],
            @"empty string changed to nonempty must survive Thrift re-encoding");

        NSString *thriftXML=[NSString stringWithFormat:
            @"<?xml version=\"1.0\"?><plist version=\"1.0\"><dict>"
             "<key>bootstrap_config</key><string>%@</string>"
             "<key>FBLoginUUID</key><string>659E2047-9BC6-4413-9702-1940A688D834</string>"
             "</dict></plist>",thriftFixture];
        FZIProjection *thriftProjected=FZIMakeProjection(thriftXML);
        FZIRequire(thriftProjected!=nil &&
            [thriftProjected.display containsString:@"client_ip_discovery"],
            @"Thrift Compact must be rendered by native inline editor");
        FZIRequire([thriftProjected.display containsString:
            @"659E2047-9BC6-4413-9702-1940A688D834"],
            @"UUID adjacent to Thrift must stay original");
        FZIRequire([FZIValidateAndRestore(thriftProjected,
            thriftProjected.display,NULL) isEqualToString:thriftXML],
            @"no-op Thrift must preserve original Base64 and plist text");
        NSString *thriftEdit=[thriftProjected.display
            stringByReplacingOccurrencesOfString:@"5000" withString:@"6000"];
        NSString *savedThrift=FZIValidateAndRestore(thriftProjected,
            thriftEdit,&thriftError);
        FZIRequire(savedThrift!=nil,
            thriftError.localizedDescription ?: @"Thrift edited XML must restore");
        NSDictionary *savedThriftPlist=FZIReadPlist(
            [savedThrift dataUsingEncoding:NSUTF8StringEncoding]);
        NSData *recoveredThrift=[[NSData alloc] initWithBase64EncodedString:
            savedThriftPlist[@"bootstrap_config"] options:0];
        NSDictionary *recoveredView=FZICompactThriftDisplay(
            FZICompactThriftDecode(recoveredThrift));
        FZIRequire([recoveredView[@"field_1"][0][@"field_2"] isEqual:@6000],
            @"modified Thrift field was not recoded to Base64");
        FZIRequire([savedThriftPlist[@"FBLoginUUID"] isEqualToString:
            @"659E2047-9BC6-4413-9702-1940A688D834"],
            @"neighboring UUID must not change after Thrift Save");
        NSLog(@"[PASS] native inline codec: 6916 ABProps, nested JSON/Base64, "
              @"short HEX, valid edits, byte-preserving no-op, malformed JSON");
    }
    return 0;
}
