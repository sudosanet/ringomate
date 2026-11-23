/// ponytail: QDEF は BDEF4 で近似。隠れた素体の削除のシェーダーは SDEF も BDEF2 で近似。
private let toonSurfaceSource = """
#include <metal_stdlib>
using namespace metal;

struct Frame {
    float4x4 viewProj;
    float4 lightDir;
    float4 lightColor;
    float4 viewport;
    float4 ramp;
    float4 extra;
    float4x4 lightViewProj;
    float4 look;
    float4 tint;
    float4 ground;
};

constant int shadingPathConstant [[function_constant(0)]];
constant int shadingPath = is_function_constant_defined(shadingPathConstant) ? shadingPathConstant : 0;

struct Material {
    float4 diffuse;
    float4 ambient;
    float4 specular;
    int4 textures;
    float4 edgeColor;
    float4 edgeParams;
    float4 mtoonShade;
    float4 mtoonRim;
    float4 mtoonParams;
    float4 mtoonEmissive;
    float4 look; // x: リムなし（顔・目） y: 肌の暖かい影 z: MToon の影の持ち上げ
};

struct VOut {
    float4 position [[position]];
    float3 normal;
    float2 uv;
    float4 lightPos;
    uint part [[flat]];
};

struct FOut {
    float4 color [[color(0)]];
    uint part [[color(1)]];
    float4 glow [[color(4)]];
};

struct Shaded {
    float4 color;
    float3 glow;
};

struct SdefVertex { float4 c; float4 rw0; float4 rw1; };

static float4 quat_of(float3x3 m) {
    float tr = m[0][0] + m[1][1] + m[2][2];
    if (tr > 0.0) {
        float s = sqrt(tr + 1.0) * 2.0;
        return float4((m[1][2] - m[2][1]) / s, (m[2][0] - m[0][2]) / s, (m[0][1] - m[1][0]) / s, 0.25 * s);
    } else if (m[0][0] > m[1][1] && m[0][0] > m[2][2]) {
        float s = sqrt(1.0 + m[0][0] - m[1][1] - m[2][2]) * 2.0;
        return float4(0.25 * s, (m[1][0] + m[0][1]) / s, (m[2][0] + m[0][2]) / s, (m[1][2] - m[2][1]) / s);
    } else if (m[1][1] > m[2][2]) {
        float s = sqrt(1.0 + m[1][1] - m[0][0] - m[2][2]) * 2.0;
        return float4((m[1][0] + m[0][1]) / s, 0.25 * s, (m[2][1] + m[1][2]) / s, (m[2][0] - m[0][2]) / s);
    }
    float s = sqrt(1.0 + m[2][2] - m[0][0] - m[1][1]) * 2.0;
    return float4((m[2][0] + m[0][2]) / s, (m[2][1] + m[1][2]) / s, 0.25 * s, (m[0][1] - m[1][0]) / s);
}

static float3x3 mat_of(float4 q) {
    float x = q.x, y = q.y, z = q.z, w = q.w;
    return float3x3(float3(1 - 2 * (y * y + z * z), 2 * (x * y + w * z), 2 * (x * z - w * y)),
                    float3(2 * (x * y - w * z), 1 - 2 * (x * x + z * z), 2 * (y * z + w * x)),
                    float3(2 * (x * z + w * y), 2 * (y * z - w * x), 1 - 2 * (x * x + y * y)));
}

static float4x4 skin_matrix(uint vid, uint4 i, float4 w, const device float4x4* skin,
                            const device SdefVertex* sdef, bool hasSdef) {
    if (hasSdef && sdef[vid].c.w != 0.0) {
        float4x4 m0 = skin[i.x], m1 = skin[i.y];
        float scale = length(m0[0].xyz);
        float3x3 r0 = float3x3(m0[0].xyz, m0[1].xyz, m0[2].xyz) / max(scale, 1e-6);
        float3x3 r1 = float3x3(m1[0].xyz, m1[1].xyz, m1[2].xyz) / max(length(m1[0].xyz), 1e-6);
        float4 q0 = quat_of(r0), q1 = quat_of(r1);
        if (dot(q0, q1) < 0.0) q1 = -q1;
        float3x3 r = mat_of(normalize(q0 * w.x + q1 * w.y)) * scale;
        SdefVertex sd = sdef[vid];
        float3 t = (m0 * float4(sd.rw0.xyz, 1.0)).xyz * w.x + (m1 * float4(sd.rw1.xyz, 1.0)).xyz * w.y - r * sd.c.xyz;
        return float4x4(float4(r[0], 0.0), float4(r[1], 0.0), float4(r[2], 0.0), float4(t, 1.0));
    }
    return skin[i.x] * w.x + skin[i.y] * w.y + skin[i.z] * w.z + skin[i.w] * w.w;
}

vertex VOut toon_vertex(uint vid [[vertex_id]],
                        constant Frame& frame [[buffer(0)]],
                        const device packed_float3* positions [[buffer(1)]],
                        const device packed_float3* normals [[buffer(2)]],
                        const device float2* uvs [[buffer(3)]],
                        const device uint4* boneIndices [[buffer(4)]],
                        const device float4* boneWeights [[buffer(5)]],
                        const device float4x4* skin [[buffer(6)]],
                        const device uchar* parts [[buffer(8)]],
                        const device SdefVertex* sdef [[buffer(11)]]) {
    uint4 i = boneIndices[vid];
    float4 w = boneWeights[vid];
    float4x4 m = skin_matrix(vid, i, w, skin, sdef, frame.viewport.w != 0.0);
    float4 world = m * float4(float3(positions[vid]), 1.0);
    VOut out;
    out.position = frame.viewProj * world;
    out.normal = normalize((m * float4(float3(normals[vid]), 0.0)).xyz);
    out.uv = uvs[vid];
    out.lightPos = frame.lightViewProj * world;
    out.part = parts[vid];
    return out;
}

vertex float4 shadow_vertex(uint vid [[vertex_id]],
                            constant Frame& frame [[buffer(0)]],
                            const device packed_float3* positions [[buffer(1)]],
                            const device uint4* boneIndices [[buffer(4)]],
                            const device float4* boneWeights [[buffer(5)]],
                            const device float4x4* skin [[buffer(6)]],
                            const device SdefVertex* sdef [[buffer(11)]]) {
    uint4 i = boneIndices[vid];
    float4 w = boneWeights[vid];
    float4x4 m = skin_matrix(vid, i, w, skin, sdef, frame.viewport.w != 0.0);
    return frame.lightViewProj * (m * float4(float3(positions[vid]), 1.0));
}

fragment void shadow_fragment() {}

static float selfShadow(VOut in, constant Frame& frame, depth2d<float> shadowMap, sampler cmp) {
    if (frame.extra.z == 0.0) return 1.0;
    float3 p = in.lightPos.xyz / in.lightPos.w;
    float2 uv = float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
    if (any(uv < 0.0) || any(uv > 1.0)) return 1.0;
    float texel = 1.0 / float(shadowMap.get_width());
    float bias = 0.002;
    float lit = 0.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            lit += shadowMap.sample_compare(cmp, uv + float2(x, y) * texel * 2.0, p.z - bias);
        }
    }
    return smoothstep(0.2, 0.8, lit / 9.0);
}

static Shaded shade(VOut in, bool front, constant Frame& frame, constant Material& mat,
                    texture2d<float> diffuseTex, texture2d<float> sphereTex, texture2d<float> toonTex, sampler s,
                    depth2d<float> shadowMap, sampler cmp) {
    float3 n = normalize(in.normal) * (front ? 1.0 : -1.0);
    float shadow = selfShadow(in, frame, shadowMap, cmp);
    float lambert = dot(n, -frame.lightDir.xyz);
    if (mat.edgeParams.y != 0.0 || mat.edgeParams.w != 0.0) {
        lambert = lambert * frame.lightDir.w + (0.8 - frame.lightDir.w);
        shadow = mix(shadow, 1.0, 0.75);
    }
    float ndl = mix(min(lambert, -0.2), lambert, shadow);

    if (shadingPath == 1 && mat.edgeParams.z != 0.0) {
        float t = frame.extra.w;
        float2 uv = in.uv + mat.mtoonParams.zw * t;
        float a = mat.mtoonEmissive.w * t;
        if (a != 0.0) {
            float2 c = uv - 0.5;
            uv = float2(c.x * cos(a) - c.y * sin(a), c.x * sin(a) + c.y * cos(a)) + 0.5;
        }
        float3 base = mat.diffuse.rgb;
        float alpha = mat.diffuse.a;
        if (mat.textures.x != 0) {
            float4 tex = diffuseTex.sample(s, uv);
            base *= tex.a > 0.0 ? tex.rgb / tex.a : float3(0.0);
            alpha *= tex.a;
        }
        float toony = mat.mtoonParams.x;
        float lo = -1.0 + toony, hi = 1.0 - toony;
        float lit = saturate((lambert + mat.mtoonShade.w - lo) / max(hi - lo, 1e-3)) * mix(1.0, shadow, 0.5);
        float3 shadeTex = float3(1.0);
        if (mat.textures.y != 0) {
            float4 st = sphereTex.sample(s, uv);
            shadeTex = st.a > 0.0 ? st.rgb / st.a : float3(0.0);
        }
        float3 shadeColor = mat.mtoonShade.rgb * shadeTex;
        if (mat.look.z != 0.0) shadeColor = max(shadeColor, base * 0.55);
        shadeColor = mix(shadeColor, shadeColor * frame.tint.rgb, frame.look.z);
        float3 color = mix(mix(shadeColor, base, lit), base, 0.3);
        float facing = 1.0 - saturate(abs(n.z));
        float3 rim = (1.0 - mat.look.x) * mix(mat.mtoonRim.rgb, mat.mtoonRim.rgb * frame.tint.rgb, frame.look.z) * pow(saturate(facing + mat.mtoonParams.y), max(mat.mtoonRim.w, 1e-3));
        float3 emissive = mat.mtoonEmissive.rgb;
        if (mat.textures.z != 0) {
            float4 et = toonTex.sample(s, uv);
            emissive *= et.a > 0.0 ? et.rgb / et.a : float3(0.0);
        }
        color += rim + emissive;
        color += frame.lightColor.rgb * pow(facing, 4.0) * saturate(ndl + 0.3) * frame.extra.y * (1.0 - mat.look.x);
        alpha = saturate(alpha);
        Shaded out;
        out.color = float4(saturate(color) * alpha, alpha);
        out.glow = emissive * alpha;
        return out;
    }

    float3 color = saturate(mat.ambient.rgb + mat.diffuse.rgb * frame.lightColor.rgb);
    float alpha = mat.diffuse.a;

    if (mat.textures.x != 0) {
        // テクスチャは乗算済みのアルファで持つので、ここで戻す
        float4 t = diffuseTex.sample(s, in.uv);
        color *= t.a > 0.0 ? t.rgb / t.a : float3(0.0);
        alpha *= t.a;
    }
    float3 glow = float3(0.0);
    if (mat.textures.y != 0 && mat.textures.w != 0) {
        float2 suv = float2(n.x * 0.5 + 0.5, -n.y * 0.5 + 0.5);
        float3 sp = sphereTex.sample(s, suv).rgb;
        color = mat.textures.w == 2 ? color + sp : color * sp;
        if (mat.textures.w == 2) glow = sp;
    }
    float w = max(frame.ramp.w, 1e-3);
    float3 toon = mat.textures.z != 0
        ? toonTex.sample(s, float2(0.0, saturate(0.5 - ndl * 0.5))).rgb
        : mix(mix(frame.ramp.rgb, frame.ramp.rgb * frame.tint.rgb, frame.look.z) * (mat.look.y != 0.0 ? float3(1.06, 0.94, 0.92) : float3(1.0)),
              float3(1.0), smoothstep(-w, w, ndl));
    color *= toon;
    if (frame.look.x > 0.0 && mat.specular.w > 0.0) {
        float3 h = normalize(-frame.lightDir.xyz + float3(0.0, 0.0, -1.0));
        color += mat.specular.rgb * frame.lightColor.rgb * pow(saturate(dot(n, h)), mat.specular.w) * shadow * frame.look.x;
    }
    float rim = pow(1.0 - saturate(abs(n.z)), 4.0) * saturate(ndl + 0.3) * frame.extra.y * (1.0 - mat.look.x);
    color += mix(frame.lightColor.rgb, frame.lightColor.rgb * frame.tint.rgb, frame.look.z) * rim;
    alpha = saturate(alpha);
    Shaded out;
    out.color = float4(saturate(color) * alpha, alpha);
    out.glow = glow * alpha;
    return out;
}

#define SHADE_ARGS VOut in [[stage_in]], bool front [[front_facing]], constant Frame& frame [[buffer(0)]], \
    constant Material& mat [[buffer(7)]], texture2d<float> diffuseTex [[texture(0)]], \
    texture2d<float> sphereTex [[texture(1)]], texture2d<float> toonTex [[texture(2)]], sampler s [[sampler(0)]], \
    depth2d<float> shadowMap [[texture(3)]], sampler cmp [[sampler(1)]]

fragment FOut toon_fragment(SHADE_ARGS) {
    Shaded sh = shade(in, front, frame, mat, diffuseTex, sphereTex, toonTex, s, shadowMap, cmp);
    if (sh.color.a < 0.05) discard_fragment();
    FOut out;
    out.color = sh.color;
    out.part = in.part;
    out.glow = float4(sh.glow, sh.color.a);
    return out;
}

fragment FOut see_fragment(SHADE_ARGS) {
    // カメラ（−Z）を向いた面だけ（後ろ髪越しに透けない）
    float facing = smoothstep(0.2, 0.5, -normalize(in.normal).z);
    if (!front || facing <= 0.0) discard_fragment();
    float4 c = shade(in, front, frame, mat, diffuseTex, sphereTex, toonTex, s, shadowMap, cmp).color * (frame.extra.x * facing);
    if (c.a < 0.02) discard_fragment();
    FOut out;
    out.color = c;
    out.part = in.part;
    out.glow = float4(0.0);
    return out;
}

"""

/// 半透明の合成・ブルーム・地面の影は ToonShaderPost.swift
let toonShaderSource = toonSurfaceSource + toonPostSource
