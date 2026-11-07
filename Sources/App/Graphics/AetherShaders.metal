// MARK: - FILE: AetherShaders.metal

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

namespace aether_math {
    inline float hash21(float2 p) {
        p = fract(p * float2(127.1, 311.7));
        p += dot(p, p + 45.32);
        return fract(p.x * p.y);
    }

    inline float valueNoise(float2 p) {
        float2 i = floor(p);
        float2 f = fract(p);
        float2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);

        float a = hash21(i + float2(0.0, 0.0));
        float b = hash21(i + float2(1.0, 0.0));
        float c = hash21(i + float2(0.0, 1.0));
        float d = hash21(i + float2(1.0, 1.0));

        return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
    }

    inline float fbm5(float2 p) {
        float value = 0.0;
        float amplitude = 0.52;
        const float2x2 rot = float2x2(float2(0.80, 0.60), float2(-0.60, 0.80));
        for (int octave = 0; octave < 5; ++octave) {
            value += amplitude * valueNoise(p);
            p = rot * p * 2.03 + float2(13.7, 7.9);
            amplitude *= 0.50;
        }
        return value;
    }

    inline float3 cosineAuroraPalette(float t, float accentHue) {
        float3 a = float3(0.10, 0.13, 0.24);
        float3 b = float3(0.38, 0.36, 0.48);
        float3 c = float3(1.00, 1.00, 1.00);
        float3 d = fract(float3(accentHue, accentHue + 0.19, accentHue + 0.38));
        return clamp(a + b * cos(6.2831853 * (c * t + d)), 0.0, 1.0);
    }
}

// MARK: - Stitchable Domain-Warping Fluid Aurora Background Shader

[[ stitchable ]] half4 aetherAurora(
    float2 position,
    half4 currentColor,
    float2 size,
    float time,
    float audioAmplitude,
    float beatFrequency,
    float accentHue,
    float focusProgress
) {
    float2 safeSize = max(size, float2(1.0, 1.0));
    float2 uv = position / safeSize;
    float aspect = safeSize.x / safeSize.y;

    float2 centered = (uv - 0.5) * float2(aspect, 1.0);
    float radialDist = length(centered);

    float flowRate = 0.065 + clamp(beatFrequency, 0.5, 48.0) * 0.0018;
    float t = time * flowRate;
    float amp = clamp(audioAmplitude, 0.0, 1.0);

    float2 p = centered * 2.35;

    float2 q = float2(
        aether_math::fbm5(p + float2(0.0, t * 0.85)),
        aether_math::fbm5(p + float2(5.2, 1.3 - t * 0.65))
    );

    float2 r = float2(
        aether_math::fbm5(p + 3.15 * q + float2(1.7 + t * 0.55, 9.2) + amp * 0.45),
        aether_math::fbm5(p + 3.15 * q + float2(8.3, 2.8 - t * 0.72) - amp * 0.38)
    );

    float field = aether_math::fbm5(p + 2.85 * r);

    float curtainWave = sin((centered.x * 3.6 + r.x * 2.8) - time * 0.45) * 0.5 + 0.5;
    float ribbon = smoothstep(0.28, 0.92, field) * pow(curtainWave, 1.65 - amp * 0.55);

    float3 deepSpace = float3(0.022, 0.028, 0.058);
    float3 spectral = aether_math::cosineAuroraPalette(field * 1.15 + length(q) * 0.35 - t * 0.25, accentHue);
    float3 secondaryGlow = aether_math::cosineAuroraPalette(length(r) * 0.85 + 0.28, fract(accentHue + 0.22));

    float3 col = deepSpace;
    col += spectral * (field * field * (0.85 + amp * 0.95));
    col += secondaryGlow * ribbon * (0.48 + amp * 0.85);

    float targetRadius = 0.29;
    float ringDelta = abs(radialDist - targetRadius);
    float halo = exp(-ringDelta * 26.0) * (0.16 + 0.42 * clamp(focusProgress, 0.0, 1.0) + 0.35 * amp);
    col += secondaryGlow * halo;

    float2 starCell = floor(uv * safeSize * 0.18);
    float starSeed = aether_math::hash21(starCell);
    if (starSeed > 0.9945) {
        float twinkle = 0.5 + 0.5 * sin(time * 2.8 + starSeed * 62.83);
        col += float3(0.65, 0.78, 1.0) * twinkle * 0.28 * (1.0 - ribbon);
    }

    float vignette = 1.0 - smoothstep(0.32, 1.08, radialDist);
    col *= (0.45 + 0.55 * vignette);
    col = col / (1.0 + col * 0.32);

    return half4(half3(col), currentColor.a > half(0.0) ? currentColor.a : half(1.0));
}

// MARK: - Stitchable Interactive Wave-Equation Ripple & Chromatic Dispersion Layer Shader

[[ stitchable ]] half4 interactiveRipple(
    float2 position,
    SwiftUI::Layer layer,
    float2 size,
    float2 touchOrigin,
    float rippleAge,
    float rippleEnergy,
    float audioAmplitude
) {
    float energy = clamp(rippleEnergy, 0.0, 1.5);
    if (energy <= 0.001) {
        return layer.sample(position);
    }

    float2 safeSize = max(size, float2(1.0, 1.0));
    float minDim = min(safeSize.x, safeSize.y);

    float2 delta = position - touchOrigin;
    float dist = length(delta);
    float2 dir = dist > 0.0001 ? (delta / dist) : float2(0.0, 0.0);

    float normalizedDist = dist / max(minDim, 1.0);
    float waveSpeed = 0.72;
    float waveFront = rippleAge * waveSpeed;

    float frontDelta = normalizedDist - waveFront;
    float envelope = exp(-frontDelta * frontDelta * 58.0) * exp(-rippleAge * 2.15) * exp(-normalizedDist * 1.6);

    float carrierWave = sin(frontDelta * 52.0 - rippleAge * 14.0);
    float displacementAmplitude = (18.0 + 14.0 * clamp(audioAmplitude, 0.0, 1.0)) * energy;
    float offsetPixels = carrierWave * envelope * displacementAmplitude;

    float2 refractedPos = clamp(position + dir * offsetPixels, float2(0.0), safeSize - float2(1.0));

    float dispersion = offsetPixels * 0.16;
    half r = layer.sample(clamp(refractedPos + dir * dispersion, float2(0.0), safeSize - float2(1.0))).r;
    half g = layer.sample(refractedPos).g;
    half4 baseSample = layer.sample(clamp(refractedPos - dir * dispersion, float2(0.0), safeSize - float2(1.0)));
    half b = baseSample.b;

    half caustic = half(max(0.0, carrierWave) * envelope * energy * 0.24);
    half3 finalRGB = clamp(half3(r, g, b) + half3(caustic * half(0.75), caustic * half(0.9), caustic), half3(0.0), half3(1.0));

    return half4(finalRGB, baseSample.a);
}
