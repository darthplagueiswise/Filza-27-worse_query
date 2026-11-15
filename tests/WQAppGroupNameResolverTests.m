// Minimal path-scope regression tests for WQFiles AppGroup name resolution.
// Intended to run on the macOS arm64 Xcode runner, without an iOS device.
#import <Foundation/Foundation.h>
#import "../WQAppGroupNameResolver.h"

static void verify(BOOL condition, NSString *message)
{
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

int main(void)
{
    @autoreleasepool {
        NSString *uuid = @"AABBCCDD-1122-3344-5566-77889900AABB";
        NSString *canonical = [@"/private/var/mobile/Containers/Shared/AppGroup/"
                                stringByAppendingString:uuid];
        NSString *shortPath = [@"/var/mobile/Containers/Shared/AppGroup/"
                                stringByAppendingString:uuid];
        verify([WQFilzaCanonicalAppGroupPath(canonical) isEqualToString:canonical],
               @"direct AppGroup UUID path");
        verify([WQFilzaCanonicalAppGroupPath(shortPath) isEqualToString:canonical],
               @"/var alias canonicalization");
        verify(WQFilzaCanonicalAppGroupPath([canonical stringByAppendingPathComponent:@"Library"]) == nil,
               @"nested paths must keep their real labels");
        verify(WQFilzaCanonicalAppGroupPath(
            [@"/var/mobile/Containers/Data/Application/" stringByAppendingString:uuid]) == nil,
            @"app data is not an AppGroup");
        verify(WQFilzaCanonicalAppGroupPath(
            @"/var/mobile/Containers/Shared/AppGroup/not-a-uuid") == nil,
            @"invalid UUIDs are not groups");
        verify(WQFilzaCanonicalAppGroupPath(
            [canonical stringByAppendingString:@"-extra"]) == nil,
            @"partial UUID matches are forbidden");
        verify(WQFilzaAppGroupLabelForPath(@"/tmp/non-group") == nil,
               @"non-group lookup is side-effect free");
        puts("WQ AppGroup path-scope tests passed");
    }
    return 0;
}
