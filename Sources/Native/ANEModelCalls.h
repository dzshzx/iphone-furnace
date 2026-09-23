#pragma once
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <pthread/qos.h>

namespace furnace::ane {
inline constexpr unsigned int modelQoS = 0;

inline BOOL compileModel(id model, NSError **error) {
    return ((BOOL(*)(id,SEL,unsigned int,id,NSError**))objc_msgSend)(model,
        NSSelectorFromString(@"compileWithQoS:options:error:"), modelQoS, @{}, error);
}

inline BOOL loadModel(id model, NSError **error) {
    return ((BOOL(*)(id,SEL,unsigned int,id,NSError**))objc_msgSend)(model,
        NSSelectorFromString(@"loadWithQoS:options:error:"), modelQoS, @{}, error);
}

inline BOOL evaluateModel(id model, id request, NSError **error) {
    return ((BOOL(*)(id,SEL,unsigned int,id,id,NSError**))objc_msgSend)(model,
        NSSelectorFromString(@"evaluateWithQoS:options:request:error:"), modelQoS, @{}, request, error);
}

inline BOOL unloadModel(id model, NSError **error) {
    return ((BOOL(*)(id,SEL,unsigned int,NSError**))objc_msgSend)(model,
        NSSelectorFromString(@"unloadWithQoS:error:"), modelQoS, error);
}
}
