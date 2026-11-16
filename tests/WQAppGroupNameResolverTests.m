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
        NSString *systemData = [@"/private/var/containers/Data/System/"
                                 stringByAppendingString:uuid];
        NSString *mobileSystemData = [@"/private/var/mobile/Containers/Data/System/"
                                       stringByAppendingString:uuid];
        NSString *systemGroup = [@"/private/var/containers/Shared/SystemGroup/"
                                  stringByAppendingString:uuid];
        NSString *mobileSystemGroup = [@"/private/var/mobile/Containers/Shared/SystemGroup/"
                                        stringByAppendingString:uuid];
        verify(WQFilzaContainerClassForPath(canonical) == 7,
               @"AppGroup metadata class 7");
        verify([WQFilzaCanonicalAppGroupPath(systemData) isEqualToString:systemData] &&
               WQFilzaContainerClassForPath(systemData) == 12,
               @"system data UUID must resolve as class 12");
        verify([WQFilzaCanonicalAppGroupPath(mobileSystemData) isEqualToString:mobileSystemData] &&
               WQFilzaContainerClassForPath(mobileSystemData) == 12,
               @"mobile System Data alias must resolve as class 12");
        verify([WQFilzaCanonicalAppGroupPath(systemGroup) isEqualToString:systemGroup] &&
               WQFilzaContainerClassForPath(systemGroup) == 13,
               @"system group UUID must resolve as class 13");
        verify([WQFilzaCanonicalAppGroupPath(mobileSystemGroup) isEqualToString:mobileSystemGroup] &&
               WQFilzaContainerClassForPath(mobileSystemGroup) == 13,
               @"mobile SystemGroup alias must resolve as class 13");
        verify(WQFilzaContainerClassForPath(
            [@"/var/containers/Data/System/" stringByAppendingString:uuid]) == 12,
            @"/var/containers system path must be recognized");
        verify(WQFilzaContainerClassForPath(
            [@"/var/containers/Shared/SystemGroup/" stringByAppendingString:uuid]) == 13,
            @"/var/containers system group path must be recognized");
        verify(WQFilzaCanonicalAppGroupPath(
            [systemGroup stringByAppendingPathComponent:@"Library"]) == nil,
            @"nested system group path must retain its real name");
        verify(WQFilzaCanonicalAppGroupPath(
            [systemData stringByAppendingPathComponent:@"Library"]) == nil,
            @"nested system data path must retain its real name");
        verify(WQFilzaCanonicalAppGroupPath(
            @"/var/containers/Shared/SystemGroup/not-a-uuid") == nil,
            @"system group must have UUID basename");
        verify(WQFilzaCanonicalAppGroupPath(
            [@"/var/containers/Data/InternalDaemon/" stringByAppendingString:uuid]) == nil,
            @"internal daemon is not System Data");
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
