#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Only the little colour at the heart of the orb, moving like liquid: the same three colours and the same
// soft size as before, but instead of three blobs circling each other the colour is carried by a slowly
// turning, warped flow (after the MetalForge orb study), and its outline keeps changing shape.

static float gf_hash(float2 p) {
    p = fract(p * float2(127.1, 311.7));
    p += float2(dot(p, p + float2(34.56)));
    return fract(p.x * p.y);
}

static float gf_noise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 w = f * f * (3.0 - 2.0 * f);
    return mix(mix(gf_hash(i), gf_hash(i + float2(1.0, 0.0)), w.x),
               mix(gf_hash(i + float2(0.0, 1.0)), gf_hash(i + float2(1.0, 1.0)), w.x), w.y);
}

static float gf_fbm(float2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 4; i++) {
        v += a * gf_noise(p);
        p = float2(1.6 * p.x - 1.2 * p.y, 1.2 * p.x + 1.6 * p.y);
        a *= 0.5;
    }
    return v;
}

/// Drawn into the orb's 200 × 200 space. `phase` is the orb's own clock (it runs faster while active).
static half4 gf_flowColor(float2 position, half4 color, float4 bounds,
                                   float phase,
                                   half4 c0, half4 c1, half4 c2,   // opaque colours
                                   float s0, float s1, float s2) { // their strengths
    float2 size = bounds.zw;
    float unit = 100.0 * size.x / 200.0;
    // Centre of the light, as before (101, 104 in the 200-point drawing); 1 unit = 100 points.
    float2 p = (position - float2(101.0, 104.0) * size.x / 200.0) / unit;

    // About one turn every 7 seconds at rest (like the study), much faster while active.
    float ang = phase * 2.6;
    float2 q = p * 1.9 + float2(3.1, 1.7);

    // The flow: a slowly turning field whose direction varies from place to place.
    float ph1 = 6.2831853 * gf_fbm(q * 1.05 + float2(3.7, 17.3));
    float am1 = 0.55 + 0.9 * gf_fbm(q * 0.85 + float2(27.1, 9.4));
    float2 o1 = 0.48 * am1 * float2(cos(ang + ph1), sin(ang + ph1));
    float ph2 = 6.2831853 * gf_fbm(q * 2.7 + float2(43.9, 5.2));
    float2 o2 = 0.16 * float2(cos(ph2 - 1.3 * ang), sin(ph2 - 1.3 * ang));
    float2 wp = (q + o1 + o2) * 1.2;

    // Its outline: about as big as the old glow, but breathing and changing shape with the flow.
    float edge = 0.54 * (0.78 + 0.45 * gf_fbm(wp * 0.9 + float2(5.2, 1.3)));
    float r = length(p + 0.08 * o1);
    float mask = 1.0 - smoothstep(edge * 0.15, edge, r);

    // Which colour, where: carried along by the flow, so the colours slide into each other.
    float h = gf_fbm(wp * 0.6 + float2(13.1, 4.7));
    // The colours follow each other round a cycle (pink → blue → lavender → pink), so all three keep showing
    // up as the liquid turns, with soft but visible borders between them.
    float x = fract(h * 2.4) * 3.0;
    float k = floor(x);
    float f = smoothstep(0.15, 0.85, fract(x));
    float3 cs[3] = { float3(c0.rgb), float3(c1.rgb), float3(c2.rgb) };
    float ss[3] = { s0, s1, s2 };
    int i0 = int(k) % 3;
    int i1 = (i0 + 1) % 3;
    float3 col = mix(cs[i0], cs[i1], f);
    float strength = mix(ss[i0], ss[i1], f);
    // Veins of denser colour inside the patch, moving with the flow.
    float veins = 0.7 + 0.45 * smoothstep(0.35, 0.70, gf_fbm(wp * 0.9 + float2(2.3, 7.9)));
    float a = saturate(mask * strength * 1.35 * veins);

    // No bright core: the whole patch is liquid.
    return half4(half3(col * a), half(a));
}

[[ stitchable ]] half4 orbGlowFlow(float2 position, half4 color, float4 bounds,
                                   float phase, half4 c0, half4 c1, half4 c2,
                                   float s0, float s1, float s2) {
    return gf_flowColor(position, color, bounds, phase, c0, c1, c2, s0, s1, s2);
}

// The finger depresses the front surface. The changed normal bends reflection locally;
// this is a height field, not an outlined ring or a second sphere fading over the first.
[[ stitchable ]] half4 orbContactSurface(float2 position, half4 color, float4 bounds, float pressure, float2 contact) {
    float2 p = (position - bounds.xy - bounds.zw * 0.5 - contact) / (min(bounds.z, bounds.w) * 0.5);
    float r2 = dot(p, p);
    float dent = exp(-r2 / 0.24);
    float2 slope = pressure * p * dent * 7.0;
    float3 normal = normalize(float3(-slope.x, -slope.y, 1.0));
    float3 light = normalize(float3(-0.55, -0.72, 0.72));
    float delta = dot(normal, light) - light.z;
    float mask = pressure * exp(-r2 / 0.72);
    float a = 0.24 * (1.0 - exp(-abs(delta) * 3.0)) * mask;
    float3 ink = delta > 0 ? float3(1.0) : float3(0.26, 0.29, 0.33);
    return half4(half3(ink * a), half(a));
}

// Match the existing stretched-square light in final local bounds, avoiding shaded
// pixels that would subsequently be compressed away for a tall narrow droplet.
[[ stitchable ]] half4 orbGlowFlowRect(float2 position, half4 color, float4 bounds,
                                      float phase, half4 c0, half4 c1, half4 c2,
                                      float s0, float s1, float s2) {
    float2 unitPosition = (position - bounds.xy) / bounds.zw;
    return gf_flowColor(unitPosition * 200.0, color, float4(0, 0, 200, 200),
                       phase, c0, c1, c2, s0, s1, s2);
}
