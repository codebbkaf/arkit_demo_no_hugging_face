/// Metal shader 原始碼，執行時以 `MTLDevice.makeLibrary(source:)` 編譯。
/// 不用 `.metal` 檔是為了不依賴需另外下載的 Xcode Metal Toolchain。
nonisolated enum ShaderSource {
    static let metal = #"""
#include <metal_stdlib>
using namespace metal;

// MARK: - 點雲

struct PointUniforms {
    float4x4 mvp;
    float pointSize;
    float yMin;
    float yMax;
    uint colorMode; // 0 = 真實色, 1 = 高度色
};

struct PointIn {
    float3 position [[attribute(0)]];
    float4 color [[attribute(1)]];
};

struct PointOut {
    float4 position [[position]];
    float size [[point_size]];
    float4 color;
};

// 藍 → 青 → 綠 → 黃 → 紅
static float3 heightRamp(float t) {
    t = saturate(t);
    float3 c0 = float3(0.10, 0.20, 0.90);
    float3 c1 = float3(0.00, 0.80, 0.90);
    float3 c2 = float3(0.20, 0.85, 0.25);
    float3 c3 = float3(0.95, 0.85, 0.10);
    float3 c4 = float3(0.90, 0.15, 0.10);
    float s = t * 4.0;
    if (s < 1.0) return mix(c0, c1, s);
    if (s < 2.0) return mix(c1, c2, s - 1.0);
    if (s < 3.0) return mix(c2, c3, s - 2.0);
    return mix(c3, c4, s - 3.0);
}

vertex PointOut pointVertex(PointIn in [[stage_in]],
                            constant PointUniforms &u [[buffer(1)]]) {
    PointOut out;
    out.position = u.mvp * float4(in.position, 1.0);
    out.size = u.pointSize;
    if (u.colorMode == 1) {
        float t = (in.position.y - u.yMin) / max(u.yMax - u.yMin, 1e-5);
        out.color = float4(heightRamp(t), 1.0);
    } else {
        out.color = float4(in.color.rgb, 1.0);
    }
    return out;
}

fragment float4 pointFragment(PointOut in [[stage_in]], float2 coord [[point_coord]]) {
    if (length(coord - 0.5) > 0.5) {
        discard_fragment();
    }
    return in.color;
}

// MARK: - 相機背景

struct BackgroundUniforms {
    float2 uv[4];
};

struct BackgroundOut {
    float4 position [[position]];
    float2 uv;
};

vertex BackgroundOut backgroundVertex(uint vid [[vertex_id]],
                                      constant BackgroundUniforms &u [[buffer(0)]]) {
    const float2 positions[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    BackgroundOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
    out.uv = u.uv[vid];
    return out;
}

fragment float4 backgroundFragment(BackgroundOut in [[stage_in]],
                                   texture2d<float> luma [[texture(0)]],
                                   texture2d<float> chroma [[texture(1)]]) {
    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    const float4x4 ycbcrToRGB = float4x4(
        float4(+1.0000f, +1.0000f, +1.0000f, +0.0000f),
        float4(+0.0000f, -0.3441f, +1.7720f, +0.0000f),
        float4(+1.4020f, -0.7141f, +0.0000f, +0.0000f),
        float4(-0.7010f, +0.5291f, -0.8860f, +1.0000f));
    float4 ycbcr = float4(luma.sample(s, in.uv).r, chroma.sample(s, in.uv).rg, 1.0);
    float4 rgb = ycbcrToRGB * ycbcr;
    // 稍微壓暗，讓疊加的點比較明顯
    return float4(rgb.rgb * 0.75, 1.0);
}
"""#
}
