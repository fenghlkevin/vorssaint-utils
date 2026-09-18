// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Bounded YAML-to-JSON conversion. Rejects duplicate keys, aliases and custom tags.
FOUNDATION_EXPORT NSData * _Nullable VPYAMLToJSON(NSData *data, NSError **error);
NS_ASSUME_NONNULL_END
