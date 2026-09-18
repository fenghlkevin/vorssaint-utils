// Adapted from OnlySwitch (MIT), commit de3bf17fa8338412a0c9b4d8d36a6b9e19a5952a.
// Copyright (c) 2021 jack. See Resources/OnlySwitch-LICENSE.txt.
//
//  MenuBarClientCoreBridge.h
//  OnlySwitch
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MenuBarClientCoreBridge : NSObject

@property (nonatomic, readonly, getter=isAvailable) BOOL available;
+ (BOOL)hasEligibleCodeSignature;

- (void)activateWithAllowedSystemItems:(NSArray<NSNumber *> *)systemItems
              allowedBundleIdentifiers:(NSArray<NSString *> *)bundleIdentifiers
                            completion:(void (^)(NSError * _Nullable error))completion;
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
