#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface YTLUserDefaults : NSUserDefaults

@property (class, readonly, strong) YTLUserDefaults *standardUserDefaults;

- (void)reset;

+ (void)resetUserDefaults;

+ (BOOL)cachedBoolForKey:(NSString *)key;

+ (NSInteger)cachedIntegerForKey:(NSString *)key;

@end

NS_ASSUME_NONNULL_END
