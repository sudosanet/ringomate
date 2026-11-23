let toonPostSource = """
struct OITOut {
    uint part [[color(1)]];
    float4 accum [[color(2)]];
    float reveal [[color(3)]];
};

fragment OITOut oit_fragment(SHADE_ARGS) {
    float4 c = shade(in, front, frame, mat, diffuseTex, sphereTex, toonTex, s, shadowMap, cmp).color;
    if (c.a < 0.01) discard_fragment();
    float z = in.position.z;
    float weight = clamp(c.a * max(1e-2, 3e3 * pow(1.0 - z, 3.0)), 1e-2, 3e3);
    OITOut out;
    out.part = in.part;
    out.accum = c * weight;
    out.reveal = c.a;
    return out;
}

struct CompositeOut { float4 color [[color(0)]]; };

vertex float4 composite_vertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    return float4(p * 2.0 - 1.0, 0.0, 1.0);
}

fragment CompositeOut composite_fragment(float4 pos [[position]], float4 accum [[color(2)]], float reveal [[color(3)]]) {
    if (reveal >= 0.999) discard_fragment();
    float3 average = accum.rgb / clamp(accum.a, 1e-5, 5e4);
    CompositeOut out;
    out.color = float4(average * (1.0 - reveal), 1.0 - reveal);
    return out;
}

kernel void bloom_down(texture2d<float, access::sample> src [[texture(0)]],
                       texture2d<float, access::write> dst [[texture(1)]],
                       uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    constexpr sampler lin(filter::linear, address::clamp_to_edge);
    float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
    dst.write(src.sample(lin, uv), gid);
}

kernel void bloom_blur(texture2d<float, access::read> src [[texture(0)]],
                       texture2d<float, access::write> dst [[texture(1)]],
                       constant int2& dir [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    const float w[5] = {0.227, 0.194, 0.122, 0.054, 0.016};
    int2 size = int2(src.get_width(), src.get_height());
    float4 sum = src.read(gid) * w[0];
    for (int k = 1; k < 5; k++) {
        int2 a = clamp(int2(gid) + dir * k * 2, int2(0), size - 1);
        int2 b = clamp(int2(gid) - dir * k * 2, int2(0), size - 1);
        sum += (src.read(uint2(a)) + src.read(uint2(b))) * w[k];
    }
    dst.write(sum, gid);
}

struct BloomOut { float4 color [[color(0)]]; };

kernel void part_resolve(texture2d_ms<uint, access::read> src [[texture(0)]],
                         texture2d<uint, access::write> dst [[texture(1)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    uint part = 0;
    for (uint i = 0; i < src.get_num_samples() && part == 0; i++) part = src.read(gid, i).r;
    dst.write(uint4(part), gid);
}

fragment BloomOut bloom_composite(float4 pos [[position]], float4 dst [[color(0)]],
                                  texture2d<float> bloom [[texture(0)]], constant float& strength [[buffer(0)]]) {
    constexpr sampler lin(filter::linear, address::clamp_to_edge);
    float2 uv = pos.xy / float2(bloom.get_width() * 2, bloom.get_height() * 2);
    float3 g = bloom.sample(lin, uv).rgb;
    BloomOut out;
    out.color = float4(min(dst.rgb + g * strength * dst.a, dst.a), dst.a);
    return out;
}

vertex VOut edge_vertex(uint vid [[vertex_id]],
                        constant Frame& frame [[buffer(0)]],
                        const device packed_float3* positions [[buffer(1)]],
                        const device float2* uvs [[buffer(3)]],
                        const device uint4* boneIndices [[buffer(4)]],
                        const device float4* boneWeights [[buffer(5)]],
                        const device float4x4* skin [[buffer(6)]],
                        constant Material& mat [[buffer(7)]],
                        const device uchar* parts [[buffer(8)]],
                        const device packed_float3* smoothNormals [[buffer(9)]],
                        const device float* edgeScale [[buffer(10)]],
                        const device SdefVertex* sdef [[buffer(11)]]) {
    uint4 i = boneIndices[vid];
    float4 w = boneWeights[vid];
    float4x4 m = skin_matrix(vid, i, w, skin, sdef, frame.viewport.w != 0.0);
    float4 clip = frame.viewProj * (m * float4(float3(positions[vid]), 1.0));
    float3 n = (m * float4(float3(smoothNormals[vid]), 0.0)).xyz;
    float2 dir = (frame.viewProj * float4(n, 0.0)).xy * frame.viewport.xy;
    float len = length(dir);
    float px = mat.edgeParams.x * edgeScale[vid] * frame.viewport.z;
    if (len > 1e-6) clip.xy += dir / len * px * 2.0 / frame.viewport.xy * clip.w;
    VOut out;
    out.position = clip;
    out.normal = n;
    out.uv = uvs[vid];
    out.lightPos = float4(0.0, 0.0, 0.0, 1.0);
    out.part = parts[vid];
    return out;
}

fragment FOut edge_fragment(VOut in [[stage_in]], constant Frame& frame [[buffer(0)]], constant Material& mat [[buffer(7)]],
                            texture2d<float> diffuseTex [[texture(0)]], sampler s [[sampler(0)]]) {
    float a = mat.edgeColor.a * mat.diffuse.a;
    if (a < 0.05) discard_fragment();
    float3 rgb = mat.edgeColor.rgb;
    if (frame.look.y > 0.0) {
        float3 base = mat.diffuse.rgb;
        if (mat.textures.x != 0) {
            float4 t = diffuseTex.sample(s, in.uv);
            base *= t.a > 0.0 ? t.rgb / t.a : float3(0.0);
        }
        rgb = mix(rgb, base * base * 0.5, frame.look.y);
    }
    FOut out;
    out.color = float4(rgb * a, a);
    out.part = in.part;
    out.glow = float4(0.0);
    return out;
}

struct GroundOut { float4 position [[position]]; float2 p; };

vertex GroundOut ground_vertex(uint vid [[vertex_id]], constant Frame& frame [[buffer(0)]]) {
    float2 c = float2((vid << 1) & 2, vid & 2) * 2.0 - 1.0;
    float2 size = float2(frame.ground.z, frame.ground.z * 0.14);
    GroundOut out;
    out.p = c;
    out.position = frame.viewProj * float4(frame.ground.xy + c * size, 0.0, 1.0);
    return out;
}

fragment FOut ground_fragment(GroundOut in [[stage_in]], constant Frame& frame [[buffer(0)]]) {
    float a = (1.0 - smoothstep(0.3, 1.0, length(in.p))) * frame.ground.w;
    if (a < 0.004) discard_fragment();
    FOut out;
    out.color = float4(0.0, 0.0, 0.0, a);
    out.part = 0;
    out.glow = float4(0.0);
    return out;
}
"""
