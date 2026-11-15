// WQFiles-style AppGroup UUID -> group identifier resolver, presentation only.
// Based on the lookup order in kolbicz/WQFiles WQAccess.m (GPL-3.0-or-later).
// This component does not create or activate sandbox extensions.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Exact direct AppGroup UUID directory; normalized to /private/var.
// Returns nil for non-group, nested, or malformed paths.
FOUNDATION_EXPORT NSString * _Nullable WQFilzaCanonicalAppGroupPath(NSString * _Nullable path);

// Read-only label from existing xattr / container metadata / ContainerManager.
// Does not change any path, lease, or filesystem item.
FOUNDATION_EXPORT NSString * _Nullable WQFilzaAppGroupLabelForPath(NSString * _Nullable path);

NS_ASSUME_NONNULL_END
