#import <Flutter/Flutter.h>

NS_ASSUME_NONNULL_BEGIN
@interface SoniNoteBridge : NSObject
- (instancetype)initWithMessenger:(NSObject<FlutterBinaryMessenger> *)messenger;
- (void)close;
@end
NS_ASSUME_NONNULL_END
