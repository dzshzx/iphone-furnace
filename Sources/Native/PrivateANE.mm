// Private API sequence and MIL blob layout adapted from maderix/ANE (MIT).
// See THIRD_PARTY_NOTICES.md. These calls remain experimental on iOS.
#import "PrivateANE.h"
#import <IOSurface/IOSurfaceRef.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach/kern_return.h>
#include <cmath>

@implementation FurnaceANE {
    id _model;
    id _request;
    id _descriptor;
    NSData *_milData;
    NSData *_weightData;
    NSArray *_surfaceWrappers;
    IOSurfaceRef _input;
    IOSurfaceRef _output;
    NSString *_directory;
    NSString *_stage;
    NSInteger _channels;
    BOOL _loaded;
}

- (NSString *)stage { return _stage ?: @"未验证"; }
- (void)setProbeStage:(NSString *)stage {
    _stage = stage;
    // Persist before crossing an unsupported ABI. A process crash cannot be
    // caught with @try, so the next launch reads this marker instead.
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:stage forKey:@"privateANE.interruptedStage"];
    [defaults synchronize];
}
- (BOOL)fail:(NSString *)message underlying:(NSError *)underlying output:(NSError **)error {
    if (error) *error = [NSError errorWithDomain:@"Furnace.PrivateANE" code:1 userInfo:@{
        NSLocalizedDescriptionKey: [NSString stringWithFormat:@"私有 ANE %@：%@%@", self.stage, message,
            underlying ? [@" · " stringByAppendingString:underlying.localizedDescription] : @""]
    }];
    return NO;
}

- (BOOL)prepareWithChannels:(NSInteger)channels error:(NSError **)error {
    @try {
        [self setProbeStage:@"加载框架"];
        if (channels != 256 && channels != 384 && channels != 512)
            return [self fail:@"不支持的通道数" underlying:nil output:error];
        _channels = channels;
        // Keep the framework loaded for the process lifetime: ObjC classes
        // cannot safely be unregistered by dlclose.
        if (!dlopen("/System/Library/PrivateFrameworks/AppleNeuralEngine.framework/AppleNeuralEngine", RTLD_NOW | RTLD_LOCAL))
            return [self fail:@"框架不可访问" underlying:nil output:error];
        Class descriptorClass = NSClassFromString(@"_ANEInMemoryModelDescriptor");
        Class modelClass = NSClassFromString(@"_ANEInMemoryModel");
        Class requestClass = NSClassFromString(@"_ANERequest");
        Class surfaceClass = NSClassFromString(@"_ANEIOSurfaceObject");
        SEL descriptorSEL = NSSelectorFromString(@"modelWithMILText:weights:optionsPlist:");
        SEL modelSEL = NSSelectorFromString(@"inMemoryModelWithDescriptor:");
        SEL surfaceSEL = NSSelectorFromString(@"objectWithIOSurface:");
        SEL requestSEL = NSSelectorFromString(@"requestWithInputs:inputIndices:outputs:outputIndices:weightsBuffer:perfStats:procedureIndex:");
        if (![descriptorClass respondsToSelector:descriptorSEL] || ![modelClass respondsToSelector:modelSEL] ||
            ![surfaceClass respondsToSelector:surfaceSEL] || ![requestClass respondsToSelector:requestSEL])
            return [self fail:@"类或方法不可用" underlying:nil output:error];

        [self setProbeStage:@"构建模型"];
        const NSInteger depth = 16;
        NSUInteger weightSize = channels * channels * 2;
        NSUInteger chunkSize = 64 + weightSize;
        NSMutableData *weights = [NSMutableData dataWithLength:64 + chunkSize * depth];
        uint8_t *bytes = static_cast<uint8_t *>(weights.mutableBytes);
        bytes[0] = 1; bytes[4] = 2;
        for (NSInteger layer = 0; layer < depth; ++layer) {
            uint8_t *chunk = bytes + 64 + chunkSize * layer;
            chunk[0] = 0xEF; chunk[1] = 0xBE; chunk[2] = 0xAD; chunk[3] = 0xDE;
            chunk[4] = 1; chunk[10] = 0x10;
            _Float16 *values = reinterpret_cast<_Float16 *>(chunk + 64);
            for (NSInteger row = 0; row < channels; ++row) {
                double sum = 0;
                for (NSInteger col = 0; col < channels; ++col) sum += 1 + ((row + col + layer) % 7);
                for (NSInteger col = 0; col < channels; ++col)
                    values[row * channels + col] = (_Float16)((1 + ((row + col + layer) % 7)) / sum);
            }
        }
        NSMutableString *mil = [NSMutableString stringWithString:
            @"program(1.3)\n[buildInfo = dict<string, string>({{\"coremlc-component-MIL\", \"3510.2.1\"}, {\"coremlc-version\", \"3505.4.1\"}, {\"coremltools-component-milinternal\", \"\"}, {\"coremltools-version\", \"9.0\"}})]\n{\n"];
        [mil appendFormat:@"func main<ios18>(tensor<fp16, [1, %ld, 64, 64]> x) {\n", (long)channels];
        [mil appendString:
            @"string pad_type = const()[name=string(\"pad_type\"), val=string(\"valid\")];\n"
             "tensor<int32, [2]> strides = const()[name=string(\"strides\"), val=tensor<int32, [2]>([1,1])];\n"
             "tensor<int32, [4]> pad = const()[name=string(\"pad\"), val=tensor<int32, [4]>([0,0,0,0])];\n"
             "tensor<int32, [2]> dilations = const()[name=string(\"dilations\"), val=tensor<int32, [2]>([1,1])];\n"
             "int32 groups = const()[name=string(\"groups\"), val=int32(1)];\n"];
        NSString *previous = @"x";
        for (NSInteger i = 0; i < depth; ++i) {
            [mil appendFormat:@"tensor<fp16, [%ld,%ld,1,1]> W%ld = const()[name=string(\"W%ld\"), val=tensor<fp16, [%ld,%ld,1,1]>(BLOBFILE(path=string(\"@model_path/weights/weight.bin\"), offset=uint64(%lu)))];\n",
                (long)channels, (long)channels, (long)i, (long)i, (long)channels, (long)channels, (unsigned long)(64 + i * chunkSize)];
            [mil appendFormat:@"tensor<fp16, [1,%ld,64,64]> c%ld = conv(dilations=dilations, groups=groups, pad=pad, pad_type=pad_type, strides=strides, weight=W%ld, x=%@)[name=string(\"c%ld\")];\n",
                (long)channels, (long)i, (long)i, previous, (long)i];
            [mil appendFormat:@"tensor<fp16, [1,%ld,64,64]> r%ld = relu(x=c%ld)[name=string(\"r%ld\")];\n", (long)channels, (long)i, (long)i, (long)i];
            previous = [NSString stringWithFormat:@"r%ld", (long)i];
        }
        [mil appendFormat:@"} -> (%@);\n}\n", previous];
        NSData *milData = [mil dataUsingEncoding:NSUTF8StringEncoding];
        id descriptor = ((id(*)(id,SEL,id,id,id))objc_msgSend)(descriptorClass, descriptorSEL, milData,
            @{@"@model_path/weights/weight.bin": @{@"offset": @0, @"data": weights}}, nil);
        // Retain every input for the entire experiment; ownership across an
        // undocumented ABI must not depend on the local autorelease pool.
        _descriptor = descriptor; _milData = milData; _weightData = weights;
        _model = descriptor ? ((id(*)(id,SEL,id))objc_msgSend)(modelClass, modelSEL, descriptor) : nil;
        for (NSString *method in @[@"hexStringIdentifier", @"compileWithQoS:options:error:", @"loadWithQoS:options:error:",
                                   @"evaluateWithQoS:options:request:error:", @"unloadWithQoS:error:"]) {
            if (![_model respondsToSelector:NSSelectorFromString(method)])
                return [self fail:[@"模型接口缺失 " stringByAppendingString:method] underlying:nil output:error];
        }
        NSString *identifier = ((id(*)(id,SEL))objc_msgSend)(_model, NSSelectorFromString(@"hexStringIdentifier"));
        NSLog(@"[DEBUG-private-ane-id] type=%@ value=%@", identifier ? NSStringFromClass(identifier.class) : @"nil", identifier);
        NSCharacterSet *nonHex = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"] invertedSet];
        if (![identifier isKindOfClass:NSString.class] || identifier.length == 0 || identifier.length > 256 ||
            [identifier rangeOfCharacterFromSet:nonHex].location != NSNotFound)
            return [self fail:@"模型标识无效" underlying:nil output:error];
        _directory = [NSTemporaryDirectory() stringByAppendingPathComponent:identifier];
        NSFileManager *fm = NSFileManager.defaultManager;
        NSError *underlying = nil;
        if (![fm createDirectoryAtPath:[_directory stringByAppendingPathComponent:@"weights"] withIntermediateDirectories:YES attributes:nil error:&underlying] ||
            ![milData writeToFile:[_directory stringByAppendingPathComponent:@"model.mil"] options:NSDataWritingAtomic error:&underlying] ||
            ![weights writeToFile:[_directory stringByAppendingPathComponent:@"weights/weight.bin"] options:NSDataWritingAtomic error:&underlying])
            return [self fail:@"临时模型写入失败" underlying:underlying output:error];
        [self setProbeStage:@"编译"];
        if (!((BOOL(*)(id,SEL,unsigned int,id,NSError**))objc_msgSend)(_model, NSSelectorFromString(@"compileWithQoS:options:error:"), 0, @{}, &underlying))
            return [self fail:@"编译被拒绝或失败" underlying:underlying output:error];
        [self setProbeStage:@"加载"];
        if (!((BOOL(*)(id,SEL,unsigned int,id,NSError**))objc_msgSend)(_model, NSSelectorFromString(@"loadWithQoS:options:error:"), 0, @{}, &underlying))
            return [self fail:@"加载被拒绝或失败" underlying:underlying output:error];
        _loaded = YES;
        NSDictionary *surfaceProperties = @{
            (id)kIOSurfaceWidth: @4096, (id)kIOSurfaceHeight: @(channels),
            (id)kIOSurfaceBytesPerElement: @2, (id)kIOSurfaceBytesPerRow: @8192,
            (id)kIOSurfaceAllocSize: @(channels * 8192), (id)kIOSurfacePixelFormat: @0
        };
        _input = IOSurfaceCreate((__bridge CFDictionaryRef)surfaceProperties);
        _output = IOSurfaceCreate((__bridge CFDictionaryRef)surfaceProperties);
        if (!_input || !_output) return [self fail:@"IOSurface 分配失败" underlying:nil output:error];
        id inputWrapper = ((id(*)(id,SEL,IOSurfaceRef))objc_msgSend)(surfaceClass, surfaceSEL, _input);
        id outputWrapper = ((id(*)(id,SEL,IOSurfaceRef))objc_msgSend)(surfaceClass, surfaceSEL, _output);
        if (!inputWrapper || !outputWrapper) return [self fail:@"IOSurface 包装失败" underlying:nil output:error];
        _surfaceWrappers = @[inputWrapper, outputWrapper];
        _request = ((id(*)(id,SEL,id,id,id,id,id,id,id))objc_msgSend)(requestClass, requestSEL,
            @[inputWrapper], @[@0], @[outputWrapper], @[@0], nil, nil, @0);
        if (!_request) return [self fail:@"请求创建失败" underlying:nil output:error];
        [self setProbeStage:@"执行与校验"];
        if (![self evaluateWithInput:0.25f error:error] || ![self evaluateWithInput:0.5f error:error]) return NO;
        [self setProbeStage:@"执行中"];
        return YES;
    } @catch (NSException *exception) {
        return [self fail:exception.reason ?: @"Objective-C 异常" underlying:nil output:error];
    }
}

- (BOOL)evaluateWithInput:(float)value error:(NSError **)error {
    @try {
        if (!_loaded || !_request) return [self fail:@"尚未加载" underlying:nil output:error];
        if (IOSurfaceLock(_input, 0, nullptr) != KERN_SUCCESS)
            return [self fail:@"输入锁定失败" underlying:nil output:error];
        _Float16 *input = static_cast<_Float16 *>(IOSurfaceGetBaseAddress(_input));
        for (NSInteger i = 0; i < _channels * 4096; ++i) input[i] = (_Float16)value;
        IOSurfaceUnlock(_input, 0, nullptr);
        NSError *underlying = nil;
        BOOL ok = ((BOOL(*)(id,SEL,unsigned int,id,id,NSError**))objc_msgSend)(_model,
            NSSelectorFromString(@"evaluateWithQoS:options:request:error:"), 0, @{}, _request, &underlying);
        if (!ok) return [self fail:@"执行失败" underlying:underlying output:error];
        if (IOSurfaceLock(_output, kIOSurfaceLockReadOnly, nullptr) != KERN_SUCCESS)
            return [self fail:@"输出锁定失败" underlying:nil output:error];
        const _Float16 *output = static_cast<const _Float16 *>(IOSurfaceGetBaseAddress(_output));
        BOOL valid = YES;
        for (NSInteger i = 0; i < _channels * 4096; i += 4096) {
            float result = static_cast<float>(output[i]);
            if (!std::isfinite(result) || std::abs(result - value) > 0.03f) { valid = NO; break; }
        }
        IOSurfaceUnlock(_output, kIOSurfaceLockReadOnly, nullptr);
        if (!valid) return [self fail:@"输出未通过数值校验" underlying:nil output:error];
        return YES;
    } @catch (NSException *exception) {
        return [self fail:exception.reason ?: @"执行异常" underlying:nil output:error];
    }
}

- (void)close {
    @try {
        if (_loaded) {
            [self setProbeStage:@"卸载"];
            NSError *error = nil;
            ((BOOL(*)(id,SEL,unsigned int,NSError**))objc_msgSend)(_model, NSSelectorFromString(@"unloadWithQoS:error:"), 0, &error);
        }
    } @catch (NSException *exception) { /* Already stopping. Resources below still need releasing. */ }
    _loaded = NO;
    _request = nil; _model = nil;
    _descriptor = nil; _milData = nil; _weightData = nil; _surfaceWrappers = nil;
    if (_input) { CFRelease(_input); _input = nullptr; }
    if (_output) { CFRelease(_output); _output = nullptr; }
    if (_directory) { [NSFileManager.defaultManager removeItemAtPath:_directory error:nil]; _directory = nil; }
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"privateANE.interruptedStage"];
}
- (void)dealloc { [self close]; }
@end
