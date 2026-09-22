#include <metal_stdlib>
using namespace metal;

kernel void furnace_compute(device float *output [[buffer(0)]],
                            constant uint &iterations [[buffer(1)]],
                            constant uint &seed [[buffer(2)]],
                            texture2d<float, access::sample> source [[texture(0)]],
                            constant uint &useTexture [[buffer(3)]],
                            uint tid [[thread_position_in_grid]]) {
    float4 a = float4(0.11f, 0.23f, 0.37f, 0.49f) + float((tid ^ seed) & 255) * 0.0001f;
    float4 b = a.wzyx + 0.031f;
    float4 c = a.yxwz + 0.071f;
    float4 d = a.zwxy + 0.019f;
    constexpr sampler s(coord::normalized, address::repeat, filter::linear);
    for (uint i = 0; i < iterations; ++i) {
        a = fma(a, float4(0.99991f), b * 0.000037f);
        b = fma(b, float4(0.99989f), c * 0.000043f);
        c = fma(c, float4(0.99987f), d * 0.000053f);
        d = fma(d, float4(0.99993f), a * 0.000031f);
        if (useTexture && ((i & 15) == 0)) {
            float2 uv = float2(float((tid + i + seed) & 1023) / 1024.0f, a.x + b.y);
            d += source.sample(s, uv) * 0.0001f;
        }
    }
    output[tid] = dot(a + b + c + d, float4(0.25f));
}

