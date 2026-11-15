// Adapted specifically from kolbicz/WQFiles WQAccess.m's wq_container_label()
// and wq_container_identifier_lookup() (GPL-3.0-or-later).
// Read-only AppGroup name resolution; the filesystem backend is untouched.
#import "WQAppGroupNameResolver.h"
#import <dlfcn.h>
#import <limits.h>
#import <stdbool.h>
#import <stdint.h>
#import <sys/stat.h>
#import <sys/xattr.h>
#import <unistd.h>
#import <string.h>

static NSString *const kWQFilzaAppGroupRoot =
    @"/private/var/mobile/Containers/Shared/AppGroup/";

static NSString *WQFilzaNormalizedPath(NSString *path)
{
    if (![path isKindOfClass:NSString.class] || ![path hasPrefix:@"/"]) return nil;
    NSString *normalized = [path stringByStandardizingPath];
    if ([normalized isEqualToString:@"/var"] || [normalized hasPrefix:@"/var/"])
        normalized = [@"/private" stringByAppendingString:normalized];
    return normalized;
}

NSString *WQFilzaCanonicalAppGroupPath(NSString *path)
{
    NSString *normalized = WQFilzaNormalizedPath(path);
    if (![normalized hasPrefix:kWQFilzaAppGroupRoot]) return nil;
    NSString *uuid = [normalized substringFromIndex:kWQFilzaAppGroupRoot.length];
    if (uuid.length != 36 || ![[NSUUID alloc] initWithUUIDString:uuid]) return nil;
    return normalized;
}

// Only the directory itself is resolved. A virtual Filza link can be used
// as a display source, but its real destination must be an AppGroup UUID.
static NSString *WQFilzaPhysicalGroupPath(NSString *path)
{
    NSString *normalized = WQFilzaNormalizedPath(path);
    NSString *direct = WQFilzaCanonicalAppGroupPath(normalized);
    if (direct.length) return direct;
    if (![[NSUUID alloc] initWithUUIDString:normalized.lastPathComponent]) return nil;
    char resolved[PATH_MAX] = {0};
    if (!realpath(normalized.fileSystemRepresentation, resolved)) return nil;
    NSString *physical = [NSString stringWithUTF8String:resolved];
    return WQFilzaCanonicalAppGroupPath(physical);
}

static BOOL WQFilzaValidGroupIdentifier(NSString *identifier)
{
    return [identifier isKindOfClass:NSString.class] &&
        [identifier hasPrefix:@"group."] && identifier.length > 6 &&
        identifier.length < 256 &&
        [identifier rangeOfCharacterFromSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]].location == NSNotFound &&
        [identifier rangeOfString:@"/"].location == NSNotFound;
}

static NSString *WQFilzaGroupXattr(NSString *path)
{
    char value[512] = {0};
    ssize_t size = getxattr(path.fileSystemRepresentation,
        "com.apple.containermanager.identifier", value, sizeof(value) - 1, 0, 0);
    if (size <= 0 || size >= (ssize_t)sizeof(value)) return nil;
    NSString *identifier = [[NSString alloc] initWithBytes:value length:(NSUInteger)size
                                                  encoding:NSUTF8StringEncoding];
    return WQFilzaValidGroupIdentifier(identifier) ? identifier : nil;
}

typedef void *(*WQFilzaQueryCreate)(void);
typedef void (*WQFilzaQueryClass)(void *, uint64_t);
typedef void (*WQFilzaQueryIterate)(void *, bool (^)(void *));
typedef void (*WQFilzaQueryFree)(void *);
typedef const char *(*WQFilzaQueryString)(void *);

// Same metadata-only container query used by WQFiles. Intentionally asks
// only for class 7 and does not set flags, parts, tokens, or access rights.
static NSDictionary<NSString *, NSDictionary *> *WQFilzaReadOnlyGroupSnapshot(void)
{
    void *library = dlopen("/usr/lib/system/libsystem_containermanager.dylib",
                           RTLD_NOW | RTLD_LOCAL);
    if (!library) return @{};
    WQFilzaQueryCreate create = (WQFilzaQueryCreate)dlsym(library, "container_query_create");
    WQFilzaQueryClass setClass = (WQFilzaQueryClass)dlsym(library, "container_query_set_class");
    WQFilzaQueryIterate iterate = (WQFilzaQueryIterate)dlsym(library, "container_query_iterate_results_sync");
    WQFilzaQueryFree freeQuery = (WQFilzaQueryFree)dlsym(library, "container_query_free");
    WQFilzaQueryString getPath = (WQFilzaQueryString)dlsym(library, "container_object_get_path");
    WQFilzaQueryString getIdentifier = (WQFilzaQueryString)dlsym(library, "container_object_get_identifier");
    if (!getIdentifier)
        getIdentifier = (WQFilzaQueryString)dlsym(library, "container_result_get_identifier");
    if (!create || !setClass || !iterate || !freeQuery || !getPath || !getIdentifier) {
        dlclose(library);
        return @{};
    }

    NSMutableDictionary<NSString *, NSDictionary *> *found = [NSMutableDictionary dictionary];
    void *query = create();
    if (query) {
        setClass(query, 7);
        @try {
            iterate(query, ^bool(void *object) {
                if (!object) return true;
                const char *rawPath = getPath(object);
                const char *rawIdentifier = getIdentifier(object);
                if (!rawPath || !rawIdentifier) return true;
                NSString *path = WQFilzaCanonicalAppGroupPath(
                    [NSString stringWithUTF8String:rawPath]);
                NSString *identifier = [NSString stringWithUTF8String:rawIdentifier];
                if (!path || !WQFilzaValidGroupIdentifier(identifier)) return true;
                struct stat st = {0};
                NSMutableDictionary *entry = [NSMutableDictionary dictionaryWithObject:identifier
                                                                                forKey:@"identifier"];
                if (lstat(path.fileSystemRepresentation, &st) == 0 && S_ISDIR(st.st_mode)) {
                    entry[@"dev"] = @((uint64_t)st.st_dev);
                    entry[@"ino"] = @((uint64_t)st.st_ino);
                }
                NSDictionary *existing = found[path];
                if (!existing) found[path] = entry;
                else if (![existing[@"identifier"] isEqualToString:identifier])
                    [found removeObjectForKey:path]; // conflicting name: no guess
                return true;
            });
        } @catch (NSException *exception) {
            NSLog(@"[WQAppGroupNames] metadata enumeration unavailable: %@", exception.name);
        }
        freeQuery(query);
    }
    dlclose(library);
    return [found copy];
}

static NSString *WQFilzaGroupQueryLabel(NSString *path)
{
    static NSObject *lock;
    static NSDictionary<NSString *, NSDictionary *> *cached;
    static NSTimeInterval cachedAt;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });

    @synchronized (lock) {
        NSTimeInterval now = NSDate.date.timeIntervalSinceReferenceDate;
        if (!cached || now - cachedAt > 60) {
            cached = WQFilzaReadOnlyGroupSnapshot();
            cachedAt = now;
        }
        NSDictionary *entry = cached[path];
        NSString *identifier = entry[@"identifier"];
        if (!WQFilzaValidGroupIdentifier(identifier)) return nil;
        // Match the WQFiles inode/device guard where filesystem identity is
        // visible; a replaced folder never inherits a stale cached label.
        if (entry[@"dev"] && entry[@"ino"]) {
            struct stat st = {0};
            if (lstat(path.fileSystemRepresentation, &st) != 0 ||
                !S_ISDIR(st.st_mode) ||
                [entry[@"dev"] unsignedLongLongValue] != (uint64_t)st.st_dev ||
                [entry[@"ino"] unsignedLongLongValue] != (uint64_t)st.st_ino)
                return nil;
        }
        return identifier;
    }
}

static NSString *WQFilzaGroupMetadataLabel(NSString *path)
{
    NSString *plistPath = [path stringByAppendingPathComponent:
        @".com.apple.mobile_container_manager.metadata.plist"];
    NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    NSString *identifier = [metadata[@"MCMMetadataIdentifier"]
        isKindOfClass:NSString.class] ? metadata[@"MCMMetadataIdentifier"] : nil;
    return WQFilzaValidGroupIdentifier(identifier) ? identifier : nil;
}

NSString *WQFilzaAppGroupLabelForPath(NSString *path)
{
    NSString *physical = WQFilzaPhysicalGroupPath(path);
    if (!physical) return nil;
    NSString *label = WQFilzaGroupXattr(physical);
    if (label.length) return label;
    label = WQFilzaGroupQueryLabel(physical);
    if (label.length) return label;
    return WQFilzaGroupMetadataLabel(physical);
}
