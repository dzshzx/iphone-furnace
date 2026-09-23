#import "PrivateANE.h"
#include <cstdio>

int main() {
    @autoreleasepool {
        FurnaceANE *bridge = [FurnaceANE new];
        NSError *error = nil;
        BOOL ok = [bridge prepareWithChannels:256 error:&error];
        fprintf(stderr, "private ANE prepare=%s stage=%s error=%s\n", ok ? "YES" : "NO",
                bridge.stage.UTF8String, error ? error.localizedDescription.UTF8String : "none");
        [bridge close];
        return ok ? 0 : 1;
    }
}
