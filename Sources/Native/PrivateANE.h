#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface FurnaceANE : NSObject
@property(nonatomic, readonly, copy) NSString *stage;
// Construct and materialize the model without compiling/loading ANE hardware.
// The normal prepare path uses this same boundary; native CI probes it directly.
- (BOOL)prepareModelWithChannels:(NSInteger)channels error:(NSError **)error;
- (BOOL)prepareWithChannels:(NSInteger)channels error:(NSError **)error NS_SWIFT_NAME(prepare(channels:));
- (BOOL)evaluateWithInput:(float)value error:(NSError **)error NS_SWIFT_NAME(evaluate(input:));
- (void)close;
@end
NS_ASSUME_NONNULL_END
