#include <metal_stdlib>
using namespace metal;

typedef struct {
    float4 position [[position]];
    float2 texCoord;
} VertexOut;

typedef struct {
    float2 scale;
} AspectUniforms;

vertex VertexOut vertex_main(uint vid [[vertex_id]], constant AspectUniforms& uniforms [[buffer(0)]]) {
    constant float2 positions[6] = {
        float2(-1, -1), float2(1, -1), float2(-1, 1),
        float2(-1,  1), float2(1, -1), float2( 1, 1)
    };
    constant float2 texCoords[6] = {
        float2(0, 1), float2(1, 1), float2(0, 0),
        float2(0, 0), float2(1, 1), float2(1, 0)
    };
    VertexOut out;
    out.position = float4(positions[vid].x * uniforms.scale.x,
                          positions[vid].y * uniforms.scale.y, 0, 1);
    out.texCoord = texCoords[vid];
    return out;
}

fragment float4 fragment_main(
    VertexOut in [[stage_in]],
    texture2d<float, access::sample> yTexture [[texture(0)]],
    texture2d<float, access::sample> cbCrTexture [[texture(1)]]
) {
    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
    float y  = yTexture.sample(s, in.texCoord).r;
    float2 cbcr = cbCrTexture.sample(s, in.texCoord).rg;

    // BT.601 full range (NV12 = full range by default)
    float cb = cbcr.r - 0.5;
    float cr = cbcr.g - 0.5;
    float r = y                + 1.402    * cr;
    float g = y - 0.344136 * cb - 0.714136 * cr;
    float b = y + 1.772    * cb;
    return float4(r, g, b, 1.0);
}
