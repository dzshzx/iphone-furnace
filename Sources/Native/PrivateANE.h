#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
// NSUserDefaults key holding the stage entered before an unsupported private call.
// Written before each such call and removed by -close; the next launch reads and removes it.
FOUNDATION_EXPORT NSString *const FurnaceANEInterruptedStageKey;
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
