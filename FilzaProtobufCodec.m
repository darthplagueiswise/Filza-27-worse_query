#import "FilzaProtobufCodec.h"
#import <CoreFoundation/CoreFoundation.h>
#import <errno.h>
#import <stdint.h>

static NSString *const FPBDomain = @"FilzaProtobuf";
static const NSUInteger FPBMaxBytes = 8 * 1024 * 1024;
static const NSUInteger FPBMaxFields = 50000;

static BOOL FPBFail(NSError **error, NSString *reason) {
    if (error) *error = [NSError errorWithDomain:FPBDomain code:1
                                         userInfo:@{NSLocalizedDescriptionKey:reason ?: @"Invalid Protobuf"}];
    return NO;
}
static BOOL FPBReadVarint(NSData *data, NSUInteger *offset, uint64_t *result) {
    const uint8_t *p = data.bytes;
    uint64_t value = 0;
    for (NSUInteger i = 0; i < 10; ++i) {
        if (*offset >= data.length) return NO;
        uint8_t b = p[(*offset)++];
        if (i == 9 && b > 1) return NO;
        value |= (uint64_t)(b & 127) << (i * 7);
        if (!(b & 128)) { *result = value; return YES; }
    }
    return NO;
}
static void FPBWriteVarint(NSMutableData *data, uint64_t value) {
    do {
        uint8_t byte = (uint8_t)(value & 127);
        value >>= 7;
        if (value) byte |= 128;
        [data appendBytes:&byte length:1];
    } while (value);
}
static BOOL FPBNumber(id obj, uint64_t *value) {
    if (![obj isKindOfClass:NSString.class] && ![obj isKindOfClass:NSNumber.class]) return NO;
    if ([obj isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)obj) == CFBooleanGetTypeID()) return NO;
    NSString *text = [obj description];
    if (!text.length || [text hasPrefix:@"-"]) return NO;
    for (NSUInteger i = 0; i < text.length; ++i) {
        unichar c = [text characterAtIndex:i];
        if (c < '0' || c > '9') return NO;
    }
    errno = 0;
    unsigned long long parsed = strtoull(text.UTF8String, NULL, 10);
    if (errno == ERANGE) return NO;
    *value = (uint64_t)parsed;
    return YES;
}
static BOOL FPBReadFields(NSData *data, NSArray<NSDictionary *> **out, NSError **error) {
    if (![data isKindOfClass:NSData.class] || data.length > FPBMaxBytes)
        return FPBFail(error, @"Invalid input or Protobuf exceeds 8 MiB");
    NSMutableArray *fields = [NSMutableArray array];
    NSUInteger offset = 0;
    while (offset < data.length) {
        if (fields.count >= FPBMaxFields)
            return FPBFail(error, @"Too many Protobuf fields");
        uint64_t key = 0;
        if (!FPBReadVarint(data, &offset, &key) ||
            (key >> 3) == 0 || (key >> 3) >= (1ULL << 29))
            return FPBFail(error, @"Invalid Protobuf field tag");
        uint32_t wire = (uint32_t)(key & 7);
        id value = nil;
        if (wire == 0) {
            uint64_t n = 0;
            if (!FPBReadVarint(data, &offset, &n))
                return FPBFail(error, @"Truncated Protobuf varint");
            value = [NSString stringWithFormat:@"%llu", (unsigned long long)n];
        } else if (wire == 1 || wire == 5) {
            NSUInteger length = wire == 1 ? 8 : 4;
            if (length > data.length - offset)
                return FPBFail(error, @"Truncated fixed-width Protobuf field");
            value = [data subdataWithRange:NSMakeRange(offset, length)];
            offset += length;
        } else if (wire == 2) {
            uint64_t length = 0;
            if (!FPBReadVarint(data, &offset, &length) || length > data.length - offset)
                return FPBFail(error, @"Truncated length-delimited Protobuf field");
            value = [data subdataWithRange:NSMakeRange(offset, (NSUInteger)length)];
            offset += (NSUInteger)length;
        } else {
            return FPBFail(error, @"Unsupported Protobuf wire type (including groups)");
        }
        [fields addObject:@{@"field":@((NSUInteger)(key >> 3)),
                            @"wire":@(wire), @"value":value}];
    }
    if (!fields.count) return FPBFail(error, @"Empty Protobuf message");
    *out = fields;
    return YES;
}
static BOOL FPBWriteField(NSMutableData *output, uint64_t field, uint32_t wire,
                          id value, NSError **error) {
    if (!field || field >= (1ULL << 29) ||
        (wire != 0 && wire != 1 && wire != 2 && wire != 5))
        return FPBFail(error, @"Unsupported field number / wire type");
    FPBWriteVarint(output, (field << 3) | wire);
    if (wire == 0) {
        uint64_t number = 0;
        if (!FPBNumber(value, &number)) return FPBFail(error, @"Expected unsigned 64-bit integer");
        FPBWriteVarint(output, number);
        return YES;
    }
    if (![value isKindOfClass:NSData.class])
        return FPBFail(error, @"Expected raw bytes");
    NSData *bytes = value;
    if (wire == 1 && bytes.length != 8) return FPBFail(error, @"fixed64 must have 8 bytes");
    if (wire == 5 && bytes.length != 4) return FPBFail(error, @"fixed32 must have 4 bytes");
    if (wire == 2) FPBWriteVarint(output, bytes.length);
    [output appendData:bytes];
    return YES;
}
static NSString *FPBString(NSData *bytes) {
    if (![bytes isKindOfClass:NSData.class]) return nil;
    NSString *value = [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding];
    if (value && [[value dataUsingEncoding:NSUTF8StringEncoding] isEqualToData:bytes]) return value;
    return nil;
}
static NSString *FPBHex(NSData *data) {
    const uint8_t *p = data.bytes;
    NSMutableString *out = [NSMutableString stringWithCapacity:data.length * 2];
    for (NSUInteger i = 0; i < data.length; ++i) [out appendFormat:@"%02x", p[i]];
    return out;
}
static NSData *FPBUnhex(NSString *value) {
    if (![value isKindOfClass:NSString.class] || value.length % 2) return nil;
    NSMutableData *bytes = [NSMutableData dataWithLength:value.length / 2];
    uint8_t *out = bytes.mutableBytes;
    for (NSUInteger i = 0; i < value.length; i += 2) {
        int n[2];
        for (int j = 0; j < 2; ++j) {
            unichar c = [value characterAtIndex:i + j];
            n[j] = c >= '0' && c <= '9' ? (int)(c - '0') :
                   c >= 'a' && c <= 'f' ? (int)(c - 'a' + 10) :
                   c >= 'A' && c <= 'F' ? (int)(c - 'A' + 10) : -1;
        }
        if (n[0] < 0 || n[1] < 0) return nil;
        out[i / 2] = (uint8_t)((n[0] << 4) | n[1]);
    }
    return bytes;
}
static BOOL FPBIsHumanText(NSString *value) {
    if (!value) return NO;
    for (NSUInteger i = 0; i < value.length; ++i) {
        unichar c = [value characterAtIndex:i];
        if ((c < 32 && c != 9 && c != 10 && c != 13) || c == 127) return NO;
    }
    return YES;
}
static BOOL FPBExact(NSArray *fields, NSUInteger position, uint64_t tag, uint32_t wire) {
    if (position >= fields.count) return NO;
    return [fields[position][@"field"] unsignedLongLongValue] == tag &&
           [fields[position][@"wire"] unsignedIntValue] == wire;
}
static NSDictionary *FPBDecodeSpotify(NSData *data, NSArray<NSDictionary *> *root) {
    if (root.count < 4) return nil;
    NSUInteger end = root.count;
    if (!FPBExact(root, end - 3, 2, 0) ||
        !FPBExact(root, end - 2, 3, 2) ||
        !FPBExact(root, end - 1, 10, 2)) return nil;
    NSString *footer3 = FPBString(root[end - 2][@"value"]);
    NSString *footer10 = FPBString(root[end - 1][@"value"]);
    if (!footer3 || !footer10) return nil;
    NSMutableArray *records = [NSMutableArray arrayWithCapacity:end - 3];
    for (NSUInteger i = 0; i < end - 3; ++i) {
        if (!FPBExact(root, i, 1, 2)) return nil;
        NSArray *f = nil;
        if (!FPBReadFields(root[i][@"value"], &f, NULL) || f.count != 5 ||
            !FPBExact(f, 1, 5, 2) || !FPBExact(f, 2, 6, 2) ||
            !FPBExact(f, 3, 8, 0) || !FPBExact(f, 4, 9, 0)) return nil;
        NSUInteger kind = [f[0][@"field"] unsignedIntegerValue];
        if ([f[0][@"wire"] unsignedIntegerValue] != 2 || kind < 1 || kind > 3) return nil;
        NSArray *sub = nil;
        NSData *payload = f[0][@"value"];
        // An empty boolean/integer uses an empty embedded message.
        if (!payload.length) sub = @[];
        else if (!FPBReadFields(payload, &sub, NULL)) return nil;
        id typedValue = nil;
        NSString *type = nil;
        if (kind == 1) {
            if (!sub.count) typedValue = @NO;
            else if (sub.count == 1 && FPBExact(sub, 0, 1, 0) &&
                     [sub[0][@"value"] isEqualToString:@"1"]) typedValue = @YES;
            else return nil;
            type = @"bool";
        } else if (kind == 2) {
            if (!sub.count) typedValue = @0;
            else if (sub.count == 1 && FPBExact(sub, 0, 1, 0)) {
                uint64_t value = 0;
                if (!FPBNumber(sub[0][@"value"], &value)) return nil;
                typedValue = @(value);
            } else return nil;
            type = @"uint64";
        } else {
            if (sub.count != 1 || !FPBExact(sub, 0, 1, 2)) return nil;
            typedValue = FPBString(sub[0][@"value"]);
            if (!typedValue) return nil;
            type = @"string";
        }
        NSString *module = FPBString(f[1][@"value"]);
        NSString *property = FPBString(f[2][@"value"]);
        uint64_t field8 = 0, field9 = 0;
        if (!module || !property ||
            !FPBNumber(f[3][@"value"], &field8) ||
            !FPBNumber(f[4][@"value"], &field9)) return nil;
        [records addObject:@{@"module":module, @"property":property,
                             @"type":type, @"value":typedValue,
                             @"field_8":@(field8), @"field_9":@(field9)}];
    }
    uint64_t ts = 0;
    if (!FPBNumber(root[end - 3][@"value"], &ts)) return nil;
    return @{@"format":@"Spotify iOS remote-config / Protobuf wire format (inferred schema)",
             @"schema_note":@"Edit value. Record order, field_8, field_9 and footer are preserved.",
             @"footer":@{@"field_2":@(ts), @"field_3":footer3, @"field_10":footer10},
             @"records":records};
}
static NSData *FPBEncodeSpotify(NSDictionary *doc, NSError **error) {
    NSArray *records = doc[@"records"];
    NSDictionary *footer = doc[@"footer"];
    if (![records isKindOfClass:NSArray.class] || ![footer isKindOfClass:NSDictionary.class] ||
        records.count > FPBMaxFields) {
        FPBFail(error, @"Missing Protobuf records/footer");
        return nil;
    }
    NSMutableData *result = [NSMutableData data];
    for (id item in records) {
        if (![item isKindOfClass:NSDictionary.class]) {
            FPBFail(error, @"Each record must be an object");
            return nil;
        }
        NSDictionary *record = item;
        if (record.count != 6 ||
            ![record[@"module"] isKindOfClass:NSString.class] ||
            ![record[@"property"] isKindOfClass:NSString.class] ||
            ![record[@"type"] isKindOfClass:NSString.class]) {
            FPBFail(error, @"Record must have module, property, type, value, field_8, field_9");
            return nil;
        }
        NSString *type = record[@"type"];
        id value = record[@"value"];
        uint64_t kind = 0;
        NSMutableData *payload = [NSMutableData data];
        if ([type isEqualToString:@"bool"]) {
            if (![value isKindOfClass:NSNumber.class] ||
                CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID()) {
                FPBFail(error, @"Boolean requires true or false"); return nil;
            }
            kind = 1;
            if ([value boolValue] && !FPBWriteField(payload, 1, 0, @"1", error)) return nil;
        } else if ([type isEqualToString:@"uint64"]) {
            uint64_t number = 0;
            if (!FPBNumber(value, &number)) {
                FPBFail(error, @"Unsigned integer out of range"); return nil;
            }
            kind = 2;
            if (number && !FPBWriteField(payload, 1, 0, [NSString stringWithFormat:@"%llu", (unsigned long long)number], error)) return nil;
        } else if ([type isEqualToString:@"string"]) {
            if (![value isKindOfClass:NSString.class]) {
                FPBFail(error, @"String value required"); return nil;
            }
            kind = 3;
            if (!FPBWriteField(payload, 1, 2, [value dataUsingEncoding:NSUTF8StringEncoding], error)) return nil;
        } else {
            FPBFail(error, @"Unsupported record value type"); return nil;
        }
        uint64_t f8 = 0, f9 = 0;
        if (!FPBNumber(record[@"field_8"], &f8) || !FPBNumber(record[@"field_9"], &f9)) {
            FPBFail(error, @"field_8 / field_9 must be uint64"); return nil;
        }
        NSMutableData *encoded = [NSMutableData data];
        if (!FPBWriteField(encoded, kind, 2, payload, error) ||
            !FPBWriteField(encoded, 5, 2, [record[@"module"] dataUsingEncoding:NSUTF8StringEncoding], error) ||
            !FPBWriteField(encoded, 6, 2, [record[@"property"] dataUsingEncoding:NSUTF8StringEncoding], error) ||
            !FPBWriteField(encoded, 8, 0, [NSString stringWithFormat:@"%llu", (unsigned long long)f8], error) ||
            !FPBWriteField(encoded, 9, 0, [NSString stringWithFormat:@"%llu", (unsigned long long)f9], error) ||
            !FPBWriteField(result, 1, 2, encoded, error)) return nil;
        if (result.length > FPBMaxBytes) { FPBFail(error, @"Output exceeds 8 MiB"); return nil; }
    }
    uint64_t ts = 0;
    if (footer.count != 3 || !FPBNumber(footer[@"field_2"], &ts) ||
        ![footer[@"field_3"] isKindOfClass:NSString.class] ||
        ![footer[@"field_10"] isKindOfClass:NSString.class]) {
        FPBFail(error, @"Invalid or incomplete footer"); return nil;
    }
    if (!FPBWriteField(result, 2, 0, [NSString stringWithFormat:@"%llu", (unsigned long long)ts], error) ||
        !FPBWriteField(result, 3, 2, [footer[@"field_3"] dataUsingEncoding:NSUTF8StringEncoding], error) ||
        !FPBWriteField(result, 10, 2, [footer[@"field_10"] dataUsingEncoding:NSUTF8StringEncoding], error)) return nil;
    if (result.length > FPBMaxBytes) { FPBFail(error, @"Output exceeds 8 MiB"); return nil; }
    return result;
}
static NSDictionary *FPBDecodeGeneric(NSArray<NSDictionary *> *root) {
    NSMutableArray *fields = [NSMutableArray arrayWithCapacity:root.count];
    for (NSDictionary *field in root) {
        uint32_t wire = [field[@"wire"] unsignedIntValue];
        id raw = field[@"value"];
        NSString *format = nil, *value = nil;
        if (wire == 0) {
            format = @"uint64"; value = raw;
        } else if (wire == 2) {
            NSString *string = FPBString(raw);
            if (FPBIsHumanText(string)) { format = @"utf8"; value = string; }
            else { format = @"hex"; value = FPBHex(raw); }
        } else {
            format = @"hex"; value = FPBHex(raw);
        }
        [fields addObject:@{@"field":field[@"field"], @"wire":@(wire),
                            @"encoding":format, @"value":value}];
    }
    return @{@"format":@"protobuf-wire-lossless",
             @"schema_note":@"Generic wire view: uint64 is not automatically boolean; hex is raw bytes (not Base64). Repeated fields keep their original order.",
             @"fields":fields};
}
static NSData *FPBEncodeGeneric(NSDictionary *doc, NSError **error) {
    NSArray *fields = doc[@"fields"];
    if (![fields isKindOfClass:NSArray.class] || fields.count > FPBMaxFields) {
        FPBFail(error, @"Invalid generic Protobuf fields"); return nil;
    }
    NSMutableData *result = [NSMutableData data];
    for (id entry in fields) {
        if (![entry isKindOfClass:NSDictionary.class] || [entry count] != 4) {
            FPBFail(error, @"Each wire-level field must have field, wire, encoding and value"); return nil;
        }
        uint64_t field = 0, wireValue = 0;
        if (!FPBNumber(entry[@"field"], &field) || !FPBNumber(entry[@"wire"], &wireValue)) {
            FPBFail(error, @"Invalid field number or wire type"); return nil;
        }
        uint32_t wire = (uint32_t)wireValue;
        NSString *encoding = entry[@"encoding"];
        NSString *value = entry[@"value"];
        if (![encoding isKindOfClass:NSString.class] || ![value isKindOfClass:NSString.class]) {
            FPBFail(error, @"Invalid wire-level field value"); return nil;
        }
        id bytesOrNumber = nil;
        if (wire == 0 && [encoding isEqualToString:@"uint64"]) {
            bytesOrNumber = value;
        } else if (wire == 2 && [encoding isEqualToString:@"utf8"]) {
            bytesOrNumber = [value dataUsingEncoding:NSUTF8StringEncoding];
        } else if ((wire == 1 || wire == 2 || wire == 5) && [encoding isEqualToString:@"hex"]) {
            bytesOrNumber = FPBUnhex(value);
        } else {
            FPBFail(error, @"Wire type and encoding mismatch"); return nil;
        }
        if (!bytesOrNumber || !FPBWriteField(result, field, wire, bytesOrNumber, error)) {
            if (bytesOrNumber == nil) FPBFail(error, @"Invalid hexadecimal bytes");
            return nil;
        }
        if (result.length > FPBMaxBytes) { FPBFail(error, @"Output exceeds 8 MiB"); return nil; }
    }
    return result;
}
NSData *FPBEncode(NSDictionary *document, NSError **error) {
    if (![document isKindOfClass:NSDictionary.class]) {
        FPBFail(error, @"JSON root must be an object"); return nil;
    }
    if (document[@"records"] && document[@"footer"]) return FPBEncodeSpotify(document, error);
    if ([document[@"format"] isEqualToString:@"protobuf-wire-lossless"])
        return FPBEncodeGeneric(document, error);
    FPBFail(error, @"Unsupported Protobuf document format");
    return nil;
}
NSDictionary *FPBDecode(NSData *bytes, BOOL allowGeneric, NSError **error) {
    NSArray<NSDictionary *> *root = nil;
    if (!FPBReadFields(bytes, &root, error)) return nil;
    NSDictionary *doc = FPBDecodeSpotify(bytes, root);
    if (!doc && allowGeneric) doc = FPBDecodeGeneric(root);
    if (!doc) { FPBFail(error, @"Unknown Protobuf schema; kept the original Filza editor"); return nil; }
    NSData *reconstructed = FPBEncode(doc, error);
    if (!reconstructed || ![bytes isEqualToData:reconstructed]) {
        FPBFail(error, @"Non-canonical or unrecognized Protobuf: byte-exact roundtrip failed");
        return nil;
    }
    return doc;
}
