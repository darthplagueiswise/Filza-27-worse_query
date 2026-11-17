#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
// Only accepts a fully consumed, canonical, byte-identical Thrift Compact struct.
FOUNDATION_EXPORT NSDictionary * _Nullable FZICompactThriftDecode(NSData *source);
FOUNDATION_EXPORT NSData * _Nullable FZICompactThriftEncode(NSDictionary *tree);
// Returns a JSON-serializable view with field IDs retained in private metadata.
FOUNDATION_EXPORT id _Nullable FZICompactThriftDisplay(NSDictionary *tree);
// Rebuilds a typed tree after changing values, rejecting edits to wire IDs/types.
FOUNDATION_EXPORT NSData * _Nullable FZICompactThriftEncodeEdited(
    NSDictionary *sourceTree, id readable, NSError **error);
NS_ASSUME_NONNULL_END
