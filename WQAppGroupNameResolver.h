// WQFiles-style AppGroup UUID -> group identifier resolver, presentation only.
// Based on the lookup order in kolbicz/WQFiles WQAccess.m (GPL-3.0-or-later).
// This component does not create or activate sandbox extensions.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Exact direct UUID directory for AppGroups, System Data and SystemGroups;
// normalized to /private/var. Returns nil for unsupported/nested paths.
FOUNDATION_EXPORT NSString * _Nullable WQFilzaCanonicalAppGroupPath(NSString * _Nullable path);

// Read-only class lookup for supported UUID roots (7 AppGroup, 12 System
// Data, 13 SystemGroup); 0 for any other path.
FOUNDATION_EXPORT NSInteger WQFilzaContainerClassForPath(NSString * _Nullable path);

// Read-only label from existing xattr / container metadata / ContainerManager.
// Does not change any path, lease, or filesystem item.
FOUNDATION_EXPORT NSString * _Nullable WQFilzaAppGroupLabelForPath(NSString * _Nullable path);

NS_ASSUME_NONNULL_END
