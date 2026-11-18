#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Lossless editor support. A known Spotify remote-config schema is presented
// with semantic names; other protobuf files use an explicit wire-level JSON.
// The generic path never guesses that an arbitrary byte sequence is a message.
FOUNDATION_EXPORT NSDictionary * _Nullable FPBDecode(NSData *bytes,
                                                     BOOL allowGeneric,
                                                     NSError **error);
FOUNDATION_EXPORT NSData * _Nullable FPBEncode(NSDictionary *document,
                                               NSError **error);
NS_ASSUME_NONNULL_END
