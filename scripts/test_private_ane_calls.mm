#include "ANEModelCalls.h"
#include <cstdio>

// A model double records the real ObjC ABI calls used by FurnaceANE. It models
// the device's rejection of realtime QoS without claiming ANE hardware access.
@interface ANEModelRecorder : NSObject
@property(nonatomic, strong) NSMutableArray<NSString *> *operations;
@property(nonatomic, strong) id expectedRequest;
@property(nonatomic, strong) NSError *backendFailure;
@end

@implementation ANEModelRecorder
- (instancetype)init {
    if ((self = [super init])) _operations = [NSMutableArray new];
    return self;
}
- (BOOL)record:(NSString *)operation qos:(unsigned int)qos error:(NSError **)error {
    [self.operations addObject:operation];
    fprintf(stderr, "%s requested QoS=%u\n", operation.UTF8String, qos);
    if (qos != QOS_CLASS_DEFAULT) {
        if (error) *error = [NSError errorWithDomain:@"Furnace.TestANE" code:2 userInfo:@{
            NSLocalizedDescriptionKey: @"Ordinary signing must use explicit default QoS; realtime requests require restricted access"
        }];
        return NO;
    }
    if (self.backendFailure) {
        if (error) *error = self.backendFailure;
        return NO;
    }
    return YES;
}
- (BOOL)compileWithQoS:(unsigned int)qos options:(NSDictionary *)options error:(NSError **)error {
    return options.count == 0 && [self record:@"compile" qos:qos error:error];
}
- (BOOL)loadWithQoS:(unsigned int)qos options:(NSDictionary *)options error:(NSError **)error {
    return options.count == 0 && [self record:@"load" qos:qos error:error];
}
- (BOOL)evaluateWithQoS:(unsigned int)qos options:(NSDictionary *)options request:(id)request error:(NSError **)error {
    return request == self.expectedRequest && options.count == 0 && [self record:@"evaluate" qos:qos error:error];
}
- (BOOL)unloadWithQoS:(unsigned int)qos error:(NSError **)error {
    return [self record:@"unload" qos:qos error:error];
}
@end

int main() {
    @autoreleasepool {
        ANEModelRecorder *model = [ANEModelRecorder new];
        id request = [NSObject new];
        model.expectedRequest = request;
        NSError *error = nil;
        BOOL compiled = furnace::ane::compileModel(model, &error);
        BOOL loaded = furnace::ane::loadModel(model, &error);
        BOOL evaluated = furnace::ane::evaluateModel(model, request, &error);
        BOOL unloaded = furnace::ane::unloadModel(model, &error);
        if (!compiled || !loaded || !evaluated || !unloaded || error ||
            ![model.operations isEqualToArray:@[@"compile", @"load", @"evaluate", @"unload"]]) {
            fprintf(stderr, "ANE call regression failed: %s\n", error.localizedDescription.UTF8String ?: "wrong call sequence/arguments");
            return 1;
        }
        model.backendFailure = [NSError errorWithDomain:@"Furnace.TestANE" code:91 userInfo:nil];
        if (furnace::ane::loadModel(model, &error) || error != model.backendFailure) {
            fprintf(stderr, "Backend errors must propagate without a retry or fallback\n");
            return 1;
        }
        fprintf(stderr, "ANE compile/load/evaluate/unload use default QoS; backend errors propagate.\n");
        return 0;
    }
}
