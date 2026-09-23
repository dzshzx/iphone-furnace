#import "PrivateANE.h"
#include <cstdio>

int main() {
    @autoreleasepool {
        for (NSNumber *channels in @[@256, @384, @512]) {
            FurnaceANE *bridge = [FurnaceANE new];
            NSError *error = nil;
            BOOL ok = [bridge prepareModelWithChannels:channels.integerValue error:&error];
            fprintf(stderr, "private ANE channels=%ld model construction=%s stage=%s error=%s\n",
                    channels.longValue, ok ? "YES" : "NO", bridge.stage.UTF8String,
                    error ? error.localizedDescription.UTF8String : "none");
            [bridge close];
            if (!ok) return 1;
        }
        fprintf(stderr, "Model construction verified; ANE compilation, load and execution require device evidence.\n");
        return 0;
    }
}
