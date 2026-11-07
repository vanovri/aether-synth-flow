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


// MARK: - 3D SDF Sphere-Traced Raymarcher Helpers (Toroidal-Knot + Orbiting Metaballs + GGX + AO)

namespace aether_sdf {
    struct SDFSceneParams {
        float time;
        float lowEnergy;
        float midEnergy;
        float highEnergy;
        float focusProgress;
    };

    inline float smoothMinPoly(float d1, float d2, float k) {
        float safeK = max(k, 0.001);
        float h = clamp(0.5 + 0.5 * (d2 - d1) / safeK, 0.0, 1.0);
        return mix(d2, d1, h) - safeK * h * (1.0 - h);
    }

    inline float2 rotate2D(float2 v, float angle) {
        float s = sin(angle);
        float c = cos(angle);
        return float2(c * v.x - s * v.y, s * v.x + c * v.y);
    }

    // Smooth-blended (2,3)-twisted toroidal knot + 4 audio-reactive orbiting metaballs
    inline float evaluateCoreSDF(float3 p, thread const SDFSceneParams& params) {
        float t = params.time;
        float low = clamp(params.lowEnergy, 0.0, 1.5);
        float mid = clamp(params.midEnergy, 0.0, 1.5);
        float high = clamp(params.highEnergy, 0.0, 1.5);
        float prog = clamp(params.focusProgress, 0.0, 1.0);

        // Rotate core sculpture slowly in 3D
        float3 q = p;
        q.xz = rotate2D(q.xz, t * 0.42);
        q.yz = rotate2D(q.yz, sin(t * 0.27) * 0.38);

        // Twisted (2,3) toroidal-knot cross-section
        float majorRadius = 0.76 + 0.08 * low + 0.05 * prog;
        float phi = atan2(q.z, q.x);
        float radialXZ = length(q.xz) - majorRadius;
        float2 crossSec = float2(radialXZ, q.y);

        // Twist cross-section by 1.5 * phi (forming continuous Moebius / trefoil knot harmonics)
        crossSec = rotate2D(crossSec, phi * 1.5 + t * 0.65);

        float lobeOffset = 0.19 + 0.07 * mid + 0.04 * sin(t * 1.3 + phi * 3.0);
        float tubeRadius = 0.165 + 0.038 * low + 0.015 * sin(phi * 6.0 - t * 2.4) * high;

        float strandA = length(crossSec - float2(lobeOffset, 0.0)) - tubeRadius;
        float strandB = length(crossSec + float2(lobeOffset, 0.0)) - tubeRadius;
        float dKnot = smoothMinPoly(strandA, strandB, 0.16 + 0.06 * mid);

        // Inner harmonic nucleus sphere
        float nucleusRadius = 0.30 + 0.09 * low + 0.04 * sin(t * 2.1);
        float dNucleus = length(q) - nucleusRadius;
        float dScene = smoothMinPoly(dKnot, dNucleus, 0.32 + 0.10 * low);

        // 4 orbiting metaballs smoothly fusing into the toroidal field
        float blendK = 0.28 + 0.12 * mid;
        for (int i = 0; i < 4; ++i) {
            float fi = float(i);
            float phase = t * (0.78 + 0.14 * fi) + fi * 1.5707963;
            float orbitR = 1.04 + 0.14 * sin(t * 0.53 + fi * 2.1) - 0.12 * prog;
            float tilt = 0.48 * sin(phase * 0.7 + fi);
            float3 ballCenter = float3(
                cos(phase) * orbitR,
                sin(phase * 1.3 + fi) * 0.42 + tilt * 0.25,
                sin(phase) * orbitR
            );
            float ballRadius = 0.145 + 0.045 * high + 0.02 * sin(t * 3.2 + fi * 1.7);
            float dBall = length(p - ballCenter) - ballRadius;
            dScene = smoothMinPoly(dScene, dBall, blendK);
        }

        return dScene * 0.82; // Conservative Lipschitz factor for twisted coordinates
    }

    // Analytical 4-sample tetrahedron SDF gradient normal
    inline float3 computeTetrahedronNormal(float3 p, thread const SDFSceneParams& params) {
        const float eps = 0.0018;
        const float2 k = float2(1.0, -1.0);
        return normalize(
            k.xyy * evaluateCoreSDF(p + k.xyy * eps, params) +
            k.yyx * evaluateCoreSDF(p + k.yyx * eps, params) +
            k.yxy * evaluateCoreSDF(p + k.yxy * eps, params) +
            k.xxx * evaluateCoreSDF(p + k.xxx * eps, params)
        );
    }

    // 5-step SDF Ambient Occlusion
    inline float computeAmbientOcclusion5(float3 p, float3 n, thread const SDFSceneParams& params) {
        float occ = 0.0;
        float weight = 0.95;
        for (int step = 1; step <= 5; ++step) {
            float h = 0.035 * float(step);
            float d = evaluateCoreSDF(p + n * h, params);
            occ += max(0.0, h - d) * weight;
            weight *= 0.68;
        }
        return clamp(1.0 - 2.4 * occ, 0.08, 1.0);
    }

    // Cook-Torrance GGX Microfacet Specular BRDF
    inline float3 cookTorranceGGX(
        float3 n,
        float3 v,
        float3 l,
        float roughness,
        float3 f0
    ) {
        float3 h = normalize(v + l);
        float nDotL = max(dot(n, l), 0.0);
        float nDotV = max(dot(n, v), 0.001);
        float nDotH = max(dot(n, h), 0.0);
        float vDotH = max(dot(v, h), 0.0);

        if (nDotL <= 0.0) {
            return float3(0.0);
        }

        float alpha = max(roughness * roughness, 0.002);
        float alphaSq = alpha * alpha;

        // Trowbridge-Reitz GGX Normal Distribution D
        float denom = nDotH * nDotH * (alphaSq - 1.0) + 1.0;
        float dTerm = alphaSq / max(3.14159265 * denom * denom, 1.0e-5);

        // Smith Schlick-GGX Geometry G
        float k = (roughness + 1.0);
        k = (k * k) * 0.125;
        float gV = nDotV / (nDotV * (1.0 - k) + k);
        float gL = nDotL / (nDotL * (1.0 - k) + k);
        float gTerm = gV * gL;

        // Schlick Fresnel F
        float3 fTerm = f0 + (1.0 - f0) * pow(clamp(1.0 - vDotH, 0.0, 1.0), 5.0);

        return (dTerm * gTerm * fTerm) / max(4.0 * nDotV * nDotL, 1.0e-4);
    }
}

// MARK: - Stitchable 64-Step Sphere-Traced 3D SDF Raymarched Core Shader

[[ stitchable ]] half4 aetherRaymarchedCore(
    float2 position,
    half4 currentColor,
    float2 size,
    float time,
    float lowEnergy,
    float midEnergy,
    float highEnergy,
    float accentHue,
    float focusProgress,
    float2 cameraOrbit
) {
    float2 safeSize = max(size, float2(1.0, 1.0));
    float2 uv = (position - 0.5 * safeSize) / min(safeSize.x, safeSize.y);
    float radial2D = length(uv);

    // Circular spatial portal boundary mask
    if (radial2D > 0.5) {
        return half4(0.0h);
    }

    aether_sdf::SDFSceneParams sceneParams;
    sceneParams.time = time;
    sceneParams.lowEnergy = clamp(lowEnergy, 0.0, 1.5);
    sceneParams.midEnergy = clamp(midEnergy, 0.0, 1.5);
    sceneParams.highEnergy = clamp(highEnergy, 0.0, 1.5);
    sceneParams.focusProgress = clamp(focusProgress, 0.0, 1.0);

    // Interactive 2-axis orbital camera rig
    float yaw = cameraOrbit.x + time * 0.12;
    float pitch = clamp(cameraOrbit.y, -1.25, 1.25);
    float camDist = 3.25 - 0.22 * sceneParams.focusProgress;

    float cosP = cos(pitch);
    float3 ro = float3(
        sin(yaw) * cosP * camDist,
        sin(pitch) * camDist,
        cos(yaw) * cosP * camDist
    );

    float3 forward = normalize(-ro);
    float3 worldUp = float3(0.0, 1.0, 0.0);
    float3 right = normalize(cross(forward, worldUp));
    float3 up = cross(right, forward);

    float focalLength = 1.42;
    float3 rd = normalize(uv.x * right - uv.y * up + focalLength * forward);

    // Palette colors derived from accentHue
    float3 baseTint = aether_math::cosineAuroraPalette(0.18 + 0.12 * sceneParams.midEnergy, accentHue);
    float3 rimTint = aether_math::cosineAuroraPalette(0.54 + 0.20 * sceneParams.highEnergy, fract(accentHue + 0.18));
    float3 sssTint = aether_math::cosineAuroraPalette(0.35, fract(accentHue + 0.08));

    // Deep portal background + volumetric corona accumulator
    float3 col = float3(0.015, 0.020, 0.045) + baseTint * (0.08 * (1.0 - radial2D * 1.6));
    float volumetricGlow = 0.0;

    // 64-step sphere-traced SDF raymarching loop
    float tRay = 0.25;
    const float maxDist = 6.2;
    bool hitSurface = false;

    for (int step = 0; step < 64; ++step) {
        float3 samplePos = ro + rd * tRay;
        float dist = aether_sdf::evaluateCoreSDF(samplePos, sceneParams);

        // Accumulate volumetric energy halo near surface shell
        volumetricGlow += exp(-max(dist, 0.0) * 9.5) * 0.014;

        if (dist < 0.0012) {
            hitSurface = true;
            break;
        }
        tRay += dist;
        if (tRay > maxDist) {
            break;
        }
    }

    if (hitSurface) {
        float3 hitPos = ro + rd * tRay;
        float3 normal = aether_sdf::computeTetrahedronNormal(hitPos, sceneParams);
        float3 viewDir = -rd;

        float ao = aether_sdf::computeAmbientOcclusion5(hitPos, normal, sceneParams);

        float3 keyLight = normalize(float3(0.62, 0.74, 0.45));
        float3 fillLight = normalize(float3(-0.70, -0.25, 0.65));

        float nDotLKey = max(dot(normal, keyLight), 0.0);
        float nDotLFill = max(dot(normal, fillLight), 0.0);

        float roughness = clamp(0.24 - 0.10 * sceneParams.highEnergy, 0.07, 0.45);
        float3 f0 = mix(float3(0.06), baseTint, 0.45);

        float3 specKey = aether_sdf::cookTorranceGGX(normal, viewDir, keyLight, roughness, f0);
        float3 specFill = aether_sdf::cookTorranceGGX(normal, viewDir, fillLight, roughness * 1.35, f0 * 0.7);

        // Schlick Fresnel rim glow
        float nDotV = max(dot(normal, viewDir), 0.0);
        float fresnel = pow(clamp(1.0 - nDotV, 0.0, 1.0), 5.0);

        // Volumetric subsurface scattering through translucent SDF interior
        float3 sssProbePos = hitPos + normalize(keyLight - normal * 0.65) * 0.22;
        float sssThickness = clamp(0.5 + aether_sdf::evaluateCoreSDF(sssProbePos, sceneParams) * 2.4, 0.0, 1.0);
        float backLight = pow(clamp(dot(viewDir, -keyLight + normal * 0.45), 0.0, 1.0), 3.0);
        float3 subsurface = sssTint * (0.28 + 0.65 * sceneParams.lowEnergy) * sssThickness * (0.35 + 0.65 * backLight);

        float3 diffuse = baseTint * (0.16 + 0.72 * nDotLKey + 0.24 * nDotLFill) * ao;
        float3 specular = specKey * nDotLKey * float3(1.15, 1.12, 1.22) + specFill * nDotLFill * rimTint * 0.65;
        float3 rimGlow = rimTint * fresnel * (0.85 + 0.75 * sceneParams.highEnergy);

        col = diffuse + specular + subsurface + rimGlow;
    }

    // Add volumetric corona & tone-map smoothly
    col += rimTint * volumetricGlow * (0.55 + 0.65 * sceneParams.midEnergy);
    col = col / (1.0 + col * 0.42);

    float portalEdgeAlpha = 1.0 - smoothstep(0.475, 0.50, radial2D);
    half outAlpha = half(portalEdgeAlpha) * (currentColor.a > 0.0h ? currentColor.a : 1.0h);
    return half4(half3(clamp(col, 0.0, 1.0)), outAlpha);
}
