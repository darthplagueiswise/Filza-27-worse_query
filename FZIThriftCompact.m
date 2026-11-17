// Schema-independent Apache Thrift Compact wire codec used by Filza's native
// text editor. Only values appear in the view; type/id metadata stays here.
// Reference: apache/thrift doc/specs/thrift-compact-protocol.md (wire spec).
// No private Meta schema, permissions, or filesystem code is used.
#import <Foundation/Foundation.h>
#import <stdint.h>
#import <string.h>

static const NSUInteger kTCMaxBytes=4*1024*1024;
static const NSUInteger kTCMaxDepth=34;
static const NSUInteger kTCMaxNodes=30000;

typedef struct {
    const uint8_t *bytes;
    NSUInteger length, cursor, nodes;
    BOOL invalid;
} TCReader;

static NSString *TCType(uint8_t c) {
    switch(c) {
        case 1: case 2: return @"bool";
        case 3: return @"byte";
        case 4: return @"i16";
        case 5: return @"i32";
        case 6: return @"i64";
        case 7: return @"double";
        case 8: return @"string";
        case 9: return @"list";
        case 10: return @"set";
        case 11: return @"map";
        case 12: return @"struct";
        case 13: return @"uuid";
        default: return nil;
    }
}
static uint8_t TCCode(NSString *s) {
    if([s isEqualToString:@"bool"]) return 1;
    if([s isEqualToString:@"byte"]) return 3;
    if([s isEqualToString:@"i16"]) return 4;
    if([s isEqualToString:@"i32"]) return 5;
    if([s isEqualToString:@"i64"]) return 6;
    if([s isEqualToString:@"double"]) return 7;
    if([s isEqualToString:@"string"]) return 8;
    if([s isEqualToString:@"list"]) return 9;
    if([s isEqualToString:@"set"]) return 10;
    if([s isEqualToString:@"map"]) return 11;
    if([s isEqualToString:@"struct"]) return 12;
    if([s isEqualToString:@"uuid"]) return 13;
    return 0;
}
static uint8_t TCByte(TCReader *r) {
    if(r->invalid || r->cursor>=r->length) {r->invalid=YES;return 0;}
    return r->bytes[r->cursor++];
}
static NSData *TCBytes(TCReader *r,NSUInteger n) {
    if(r->invalid || n>r->length-r->cursor) {r->invalid=YES;return nil;}
    NSData *data=[NSData dataWithBytes:r->bytes+r->cursor length:n];
    r->cursor+=n;return data;
}
static uint64_t TCVar(TCReader *r) {
    uint64_t result=0;
    for(unsigned i=0;i<10;i++) {
        uint8_t b=TCByte(r);if(r->invalid)return 0;
        if(i==9 && b>1){r->invalid=YES;return 0;}
        result|=((uint64_t)(b&0x7f))<<(7*i);
        if(!(b&0x80))return result;
    }
    r->invalid=YES;return 0;
}
static int64_t TCZig(uint64_t u) {
    int64_t value=(int64_t)(u>>1);
    return (u&1)?~value:value;
}
static id TCReadValue(TCReader *r,uint8_t typ,NSUInteger depth,BOOL inField);
static NSDictionary *TCReadStruct(TCReader *r,NSUInteger depth);
static NSData *TCEncode(NSDictionary *tree);
static NSDictionary *TCDecodeData(NSData *raw,NSUInteger depth);

static BOOL TCPrintable(NSString *text) {
    if(!text || !text.length)return NO;
    for(NSUInteger i=0;i<text.length;i++){
        unichar c=[text characterAtIndex:i];
        if((c<0x20 && c!='\n' && c!='\r' && c!='\t') ||
           (c>=0x7f && c<=0x9f))return NO;
    }
    return YES;
}
static NSDictionary *TCReadStruct(TCReader *r,NSUInteger depth) {
    if(depth>kTCMaxDepth || ++r->nodes>kTCMaxNodes){r->invalid=YES;return nil;}
    NSMutableArray *fields=[NSMutableArray array];
    int64_t previous=0;
    for(;;) {
        uint8_t h=TCByte(r);if(r->invalid)return nil;
        if(h==0)break;
        uint8_t typ=h&15,delta=h>>4;
        NSString *name=TCType(typ);
        if(!name){r->invalid=YES;return nil;}
        int64_t fieldId=delta?previous+delta:TCZig(TCVar(r));
        if(r->invalid || fieldId<=0 || fieldId>32767){r->invalid=YES;return nil;}
        previous=fieldId;
        id value=(typ==1)?@YES:(typ==2)?@NO:TCReadValue(r,typ,depth+1,YES);
        if(!value){r->invalid=YES;return nil;}
        [fields addObject:@{@"id":@(fieldId),@"type":name,@"value":value}];
        if(fields.count>kTCMaxNodes){r->invalid=YES;return nil;}
    }
    return @{@"fields":fields};
}
static id TCReadValue(TCReader *r,uint8_t typ,NSUInteger depth,BOOL inField) {
    if(depth>kTCMaxDepth || ++r->nodes>kTCMaxNodes){r->invalid=YES;return nil;}
    switch(typ) {
        case 1: case 2: {
            uint8_t b=TCByte(r);
            if(b!=1 && b!=2){r->invalid=YES;return nil;}
            return @(b==1);
        }
        case 3: return @((int8_t)TCByte(r));
        case 4: case 5: case 6: {
            int64_t number=TCZig(TCVar(r));
            if(r->invalid || (typ==4 && (number<INT16_MIN || number>INT16_MAX)) ||
               (typ==5 && (number<INT32_MIN || number>INT32_MAX))) {
                r->invalid=YES;return nil;
            }
            return @(number);
        }
        case 7: {
            NSData *eight=TCBytes(r,8);if(!eight)return nil;
            uint64_t bits=0;const uint8_t *p=eight.bytes;
            for(unsigned i=0;i<8;i++)bits|=((uint64_t)p[i])<<(8*i);
            double x;memcpy(&x,&bits,8);
            if(!isfinite(x)){r->invalid=YES;return nil;}
            return @(x);
        }
        case 8: {
            uint64_t n=TCVar(r);
            if(r->invalid || n>kTCMaxBytes || n>r->length-r->cursor){
                r->invalid=YES;return nil;
            }
            NSData *raw=TCBytes(r,(NSUInteger)n);if(!raw)return nil;
            if(raw.length>=16 && depth+1<kTCMaxDepth) {
                NSDictionary *inner=TCDecodeData(raw,depth+1);
                if(inner)return @{@"nested_thrift":inner};
            }
            NSString *utf8=[[NSString alloc] initWithData:raw
                                               encoding:NSUTF8StringEncoding];
            if(TCPrintable(utf8))return @{@"text":utf8};
            return @{@"unclassified_base64":[raw base64EncodedStringWithOptions:0]};
        }
        case 9: case 10: {
            uint8_t header=TCByte(r),elem=header&15;
            uint64_t count=header>>4;
            if(count==15)count=TCVar(r);
            NSString *type=TCType(elem);
            if(r->invalid || !type || count>kTCMaxNodes){r->invalid=YES;return nil;}
            NSMutableArray *items=[NSMutableArray arrayWithCapacity:(NSUInteger)count];
            for(uint64_t i=0;i<count;i++){
                id item=TCReadValue(r,elem,depth+1,NO);
                if(!item)return nil;
                [items addObject:item];
            }
            return @{@"element_type":type,@"items":items};
        }
        case 11: {
            uint64_t count=TCVar(r);if(r->invalid || count>kTCMaxNodes){r->invalid=YES;return nil;}
            uint8_t keyType=0,valueType=0;
            if(count) {
                uint8_t header=TCByte(r);
                keyType=header>>4;valueType=header&15;
                if(!TCType(keyType)||!TCType(valueType)){r->invalid=YES;return nil;}
            }
            NSMutableArray *entries=[NSMutableArray arrayWithCapacity:(NSUInteger)count];
            for(uint64_t i=0;i<count;i++){
                id key=TCReadValue(r,keyType,depth+1,NO);
                id val=TCReadValue(r,valueType,depth+1,NO);
                if(!key || !val)return nil;
                [entries addObject:@[key,val]];
            }
            return @{@"key_type":TCType(keyType)?:@"stop",
                     @"value_type":TCType(valueType)?:@"stop",
                     @"entries":entries};
        }
        case 12: return TCReadStruct(r,depth+1);
        case 13: {
            NSData *sixteen=TCBytes(r,16);if(!sixteen)return nil;
            uuid_t raw;memcpy(raw,sixteen.bytes,16);
            NSUUID *uuid=[[NSUUID alloc] initWithUUIDBytes:raw];
            return uuid.UUIDString ?: nil;
        }
    }
    r->invalid=YES;return nil;
}

typedef struct {BOOL bad;NSUInteger nodes;} TCWriter;
static void TCOut(NSMutableData *out,uint8_t b){[out appendBytes:&b length:1];}
static void TCVarOut(NSMutableData *out,uint64_t v){
    while(v>=128){TCOut(out,(uint8_t)((v&127)|128));v>>=7;}
    TCOut(out,(uint8_t)v);
}
static void TCZigOut(NSMutableData *out,int64_t v){
    uint64_t zig=((uint64_t)v<<1)^(uint64_t)(v>>63);
    TCVarOut(out,zig);
}
static BOOL TCWriteValue(NSMutableData *out,TCWriter *w,NSString *typ,id value,
                         NSUInteger depth,BOOL field);
static BOOL TCWriteStruct(NSMutableData *out,TCWriter *w,NSDictionary *tree,
                          NSUInteger depth) {
    if(depth>kTCMaxDepth || ++w->nodes>kTCMaxNodes ||
       ![tree isKindOfClass:NSDictionary.class])return NO;
    NSArray *fields=tree[@"fields"];
    if(![fields isKindOfClass:NSArray.class] || fields.count>kTCMaxNodes)return NO;
    int64_t previous=0;
    for(id obj in fields){
        if(![obj isKindOfClass:NSDictionary.class])return NO;
        NSNumber *identifier=obj[@"id"];NSString *typ=obj[@"type"];id value=obj[@"value"];
        if(![identifier isKindOfClass:NSNumber.class] || !value ||
           ![typ isKindOfClass:NSString.class])return NO;
        int64_t fid=identifier.longLongValue;
        if(fid<=0 || fid>32767)return NO;
        uint8_t compact=TCCode(typ);if(!compact)return NO;
        if(compact==1) {
            if(![value isKindOfClass:NSNumber.class])return NO;
            compact=[value boolValue]?1:2;
        }
        int64_t delta=fid-previous;
        if(delta>0 && delta<=15)TCOut(out,(uint8_t)((delta<<4)|compact));
        else {TCOut(out,compact);TCZigOut(out,fid);}
        previous=fid;
        if(compact!=1 && compact!=2 &&
           !TCWriteValue(out,w,typ,value,depth+1,YES))return NO;
        if(out.length>kTCMaxBytes)return NO;
    }
    TCOut(out,0);return YES;
}
static BOOL TCWriteValue(NSMutableData *out,TCWriter *w,NSString *typ,id value,
                         NSUInteger depth,BOOL field) {
    if(depth>kTCMaxDepth || ++w->nodes>kTCMaxNodes)return NO;
    uint8_t compact=TCCode(typ);if(!compact)return NO;
    if(compact>=1 && compact<=7 && ![value isKindOfClass:NSNumber.class])return NO;
    switch(compact) {
        case 1: TCOut(out,[value boolValue]?1:2);return YES;
        case 3: {
            int64_t n=[value longLongValue];if(n<-128 || n>127)return NO;
            TCOut(out,(uint8_t)(int8_t)n);return YES;
        }
        case 4: case 5: case 6: {
            int64_t n=[value longLongValue];
            if((compact==4 && (n<INT16_MIN||n>INT16_MAX))||
               (compact==5 && (n<INT32_MIN||n>INT32_MAX)))return NO;
            TCZigOut(out,n);return YES;
        }
        case 7: {
            double x=[value doubleValue];if(!isfinite(x))return NO;
            uint64_t bits;memcpy(&bits,&x,8);
            for(unsigned i=0;i<8;i++)TCOut(out,(uint8_t)(bits>>(8*i)));
            return YES;
        }
        case 8: {
            if(![value isKindOfClass:NSDictionary.class])return NO;
            NSDictionary *obj=value;
            NSData *bytes=nil;
            if([obj[@"text"] isKindOfClass:NSString.class])
                bytes=[obj[@"text"] dataUsingEncoding:NSUTF8StringEncoding];
            else if([obj[@"nested_thrift"] isKindOfClass:NSDictionary.class]){
                NSMutableData *nested=[NSMutableData data];TCWriter inner={0};
                if(!TCWriteStruct(nested,&inner,obj[@"nested_thrift"],depth+1))return NO;
                bytes=nested;
            } else if([obj[@"unclassified_base64"] isKindOfClass:NSString.class])
                bytes=[[NSData alloc] initWithBase64EncodedString:
                    obj[@"unclassified_base64"] options:0];
            if(!bytes || bytes.length>kTCMaxBytes)return NO;
            TCVarOut(out,bytes.length);[out appendData:bytes];return YES;
        }
        case 9: case 10: {
            if(![value isKindOfClass:NSDictionary.class])return NO;
            NSString *t=value[@"element_type"];NSArray *items=value[@"items"];
            uint8_t element=TCCode(t);
            if(!element || ![items isKindOfClass:NSArray.class] ||
               items.count>kTCMaxNodes)return NO;
            NSUInteger n=items.count;
            if(n<15)TCOut(out,(uint8_t)((n<<4)|element));
            else {TCOut(out,(uint8_t)(0xf0|element));TCVarOut(out,n);}
            for(id child in items)
                if(!TCWriteValue(out,w,t,child,depth+1,NO))return NO;
            return YES;
        }
        case 11: {
            if(![value isKindOfClass:NSDictionary.class])return NO;
            NSArray *entries=value[@"entries"];
            if(![entries isKindOfClass:NSArray.class] || entries.count>kTCMaxNodes)return NO;
            TCVarOut(out,entries.count);
            if(!entries.count)return YES;
            NSString *kt=value[@"key_type"],*vt=value[@"value_type"];
            uint8_t key=TCCode(kt),val=TCCode(vt);
            if(!key||!val)return NO;
            TCOut(out,(uint8_t)((key<<4)|val));
            for(id e in entries){
                if(![e isKindOfClass:NSArray.class] || [e count]!=2)return NO;
                if(!TCWriteValue(out,w,kt,e[0],depth+1,NO) ||
                   !TCWriteValue(out,w,vt,e[1],depth+1,NO))return NO;
            }
            return YES;
        }
        case 12: return TCWriteStruct(out,w,value,depth+1);
        case 13: {
            if(![value isKindOfClass:NSString.class])return NO;
            NSUUID *uuid=[[NSUUID alloc] initWithUUIDString:value];if(!uuid)return NO;
            uuid_t raw;[uuid getUUIDBytes:raw];[out appendBytes:raw length:16];
            return YES;
        }
    }
    return NO;
}
static NSData *TCEncode(NSDictionary *tree) {
    NSMutableData *buffer=[NSMutableData data];
    TCWriter writer={0};
    if(!TCWriteStruct(buffer,&writer,tree,0) || buffer.length>kTCMaxBytes)return nil;
    return buffer;
}
static NSDictionary *TCDecodeData(NSData *raw,NSUInteger depth) {
    if(!raw || raw.length<8 || raw.length>kTCMaxBytes || depth>kTCMaxDepth)
        return nil;
    TCReader reader={raw.bytes,raw.length,0,0,NO};
    NSDictionary *root=TCReadStruct(&reader,depth);
    if(reader.invalid || reader.cursor!=raw.length ||
       ![root[@"fields"] count])return nil;
    // Compact has no file signature. A canonical full byte-exact roundtrip
    // is required before any arbitrary binary is shown as Thrift.
    NSData *reencoded=TCEncode(root);
    return [reencoded isEqualToData:raw]?root:nil;
}

NSDictionary *FZICompactThriftDecode(NSData *source) {
    return TCDecodeData(source,0);
}
NSData *FZICompactThriftEncode(NSDictionary *tree) {
    return TCEncode(tree);
}

// The UI is deliberately schema-free. The wire field IDs and all types stay
// in the backing tree; users see ordinary JSON objects with field_# keys.
static NSString *TCFieldKey(NSNumber *identifier) {
    return [NSString stringWithFormat:@"field_%lld",identifier.longLongValue];
}
static id TCViewType(NSString *type,id typed,NSUInteger depth) {
    if(depth>kTCMaxDepth)return nil;
    if([type isEqualToString:@"struct"]){
        if(![typed isKindOfClass:NSDictionary.class])return nil;
        NSMutableDictionary *view=[NSMutableDictionary dictionary];
        for(NSDictionary *field in typed[@"fields"]){
            NSString *key=TCFieldKey(field[@"id"]);
            if(view[key])return nil; // duplicate Thrift field ID: cannot map
            id child=TCViewType(field[@"type"],field[@"value"],depth+1);
            if(!child)return nil;
            view[key]=child;
        }
        return view;
    }
    if([type isEqualToString:@"list"] || [type isEqualToString:@"set"]){
        NSString *t=typed[@"element_type"];
        NSMutableArray *out=[NSMutableArray array];
        for(id item in typed[@"items"]){
            id val=TCViewType(t,item,depth+1);if(!val)return nil;
            [out addObject:val];
        }
        return out;
    }
    if([type isEqualToString:@"map"]){
        NSMutableArray *entries=[NSMutableArray array];
        NSString *kt=typed[@"key_type"],*vt=typed[@"value_type"];
        for(NSArray *pair in typed[@"entries"]){
            id key=TCViewType(kt,pair[0],depth+1);
            id value=TCViewType(vt,pair[1],depth+1);
            if(!key || !value)return nil;
            [entries addObject:@{@"key":key,@"value":value}];
        }
        return entries;
    }
    if([type isEqualToString:@"string"]){
        if(typed[@"text"])return typed[@"text"];
        if(typed[@"nested_thrift"])
            return TCViewType(@"struct",typed[@"nested_thrift"],depth+1);
        if(typed[@"unclassified_base64"])return typed[@"unclassified_base64"];
        return nil;
    }
    return typed;
}
id FZICompactThriftDisplay(NSDictionary *tree) {
    return TCViewType(@"struct",tree,0);
}

static id TCApplyType(NSString *type,id previous,id edited,NSUInteger depth) {
    if(depth>kTCMaxDepth)return nil;
    if([type isEqualToString:@"struct"]){
        if(![edited isKindOfClass:NSDictionary.class] ||
           ![previous isKindOfClass:NSDictionary.class])return nil;
        NSArray *fields=previous[@"fields"];
        if([edited count]!=fields.count)return nil;
        NSMutableArray *updated=[NSMutableArray array];
        for(NSDictionary *field in fields){
            NSString *key=TCFieldKey(field[@"id"]);
            if(!edited[key])return nil;
            id child=TCApplyType(field[@"type"],field[@"value"],edited[key],depth+1);
            if(!child)return nil;
            [updated addObject:@{@"id":field[@"id"],@"type":field[@"type"],
                                  @"value":child}];
        }
        return @{@"fields":updated};
    }
    if([type isEqualToString:@"list"] || [type isEqualToString:@"set"]){
        NSArray *old=previous[@"items"];
        if(![edited isKindOfClass:NSArray.class] || [edited count]!=old.count)return nil;
        NSMutableArray *out=[NSMutableArray array];
        for(NSUInteger i=0;i<old.count;i++){
            id child=TCApplyType(previous[@"element_type"],old[i],edited[i],depth+1);
            if(!child)return nil;
            [out addObject:child];
        }
        return @{@"element_type":previous[@"element_type"],@"items":out};
    }
    if([type isEqualToString:@"map"]){
        NSArray *old=previous[@"entries"];
        if(![edited isKindOfClass:NSArray.class] || [edited count]!=old.count)return nil;
        NSMutableArray *out=[NSMutableArray array];
        for(NSUInteger i=0;i<old.count;i++){
            NSDictionary *pair=edited[i];
            if(![pair isKindOfClass:NSDictionary.class] || [pair count]!=2 ||
               !pair[@"key"] || !pair[@"value"])return nil;
            id k=TCApplyType(previous[@"key_type"],old[i][0],pair[@"key"],depth+1);
            id v=TCApplyType(previous[@"value_type"],old[i][1],pair[@"value"],depth+1);
            if(!k || !v)return nil;
            [out addObject:@[k,v]];
        }
        return @{@"key_type":previous[@"key_type"],
                 @"value_type":previous[@"value_type"],@"entries":out};
    }
    if([type isEqualToString:@"string"]){
        if(previous[@"nested_thrift"]){
            id updated=TCApplyType(@"struct",previous[@"nested_thrift"],edited,depth+1);
            return updated?@{@"nested_thrift":updated}:nil;
        }
        if(previous[@"unclassified_base64"])
            return [edited isEqual:previous[@"unclassified_base64"]]?previous:nil;
        if(![edited isKindOfClass:NSString.class])return nil;
        return @{@"text":edited};
    }
    if([type isEqualToString:@"uuid"])
        return [edited isKindOfClass:NSString.class] &&
            [[NSUUID alloc] initWithUUIDString:edited] ? edited : nil;
    if(![edited isKindOfClass:NSNumber.class])return nil;
    if([type isEqualToString:@"double"])return isfinite([edited doubleValue])?edited:nil;
    if([type isEqualToString:@"bool"])return edited;
    if([edited doubleValue]!=[edited longLongValue])return nil;
    long long n=[edited longLongValue];
    if([type isEqualToString:@"byte"] && (n<-128 || n>127))return nil;
    if([type isEqualToString:@"i16"] && (n<INT16_MIN || n>INT16_MAX))return nil;
    if([type isEqualToString:@"i32"] && (n<INT32_MIN || n>INT32_MAX))return nil;
    return edited;
}

NSData *FZICompactThriftEncodeEdited(NSDictionary *sourceTree,id readable,
                                      NSError **error) {
    id updated=TCApplyType(@"struct",sourceTree,readable,0);
    NSData *result=updated?TCEncode(updated):nil;
    if(!result || !FZICompactThriftDecode(result)) {
        if(error)*error=[NSError errorWithDomain:@"FZICompactThrift"
            code:1 userInfo:@{NSLocalizedDescriptionKey:
            @"Invalid Thrift value, field type, or container structure."}];
        return nil;
    }
    return result;
}
