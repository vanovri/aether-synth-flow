// MARK: - FILE: VolumetricCausticsKernels.metal

#include <metal_stdlib>
using namespace metal;

struct AcoustoOpticCausticUniforms {
    uint gridWidth;
    uint gridHeight;
    uint photonCount;
    uint integrationSteps;
    float baseRefractiveIndex;  // n0 (e.g. 1.333)
    float cauchyDispersionB;    // B in um^2 (e.g. 0.0031)
    float acoustoOpticKappa;    // Gladstone-Dale kappa_ao (e.g. 0.045)
    float anisotropyG;          // Henyey-Greenstein g in (-1, 1)
    float stepSizeCells;
    float photonEnergyScale;
    float2 lightDirectionXY;
};

namespace aether_caustics {
    constant float kCausticQuantScale = 65536.0f;
    constant float kSpectralWavelengthBandsNm[8] = {
        380.0f, 425.71429f, 471.42857f, 517.14286f,
        562.85714f, 608.57143f, 654.28571f, 700.0f
    };

    inline uint pcgHash(uint input) {
        uint state = input * 747796405u + 2891336453u;
        uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
        return (word >> 22u) ^ word;
    }

    inline float rand01(thread uint& rngState) {
        rngState = pcgHash(rngState);
        return float(rngState >> 8u) * (1.0f / 16777216.0f);
    }

    // Cauchy dispersion + Gladstone-Dale acousto-optic coupling:
    // n(x, lambda) = (n0 + B / lambda_um^2) * (1 + kappa_ao * p(x))
    inline float refractiveIndex(
        float wavelengthNm,
        float pressure,
        float n0,
        float cauchyB,
        float kappaAO
    ) {
        float lambdaUm = max(0.25f, wavelengthNm * 1.0e-3f);
        float baseN = n0 + cauchyB / (lambdaUm * lambdaUm);
        return max(1.0001f, baseN * max(0.05f, 1.0f + kappaAO * pressure));
    }

    // Henyey-Greenstein volumetric phase function
    inline float henyeyGreensteinPhase(float cosTheta, float g) {
        float clampedG = clamp(g, -0.98f, 0.98f);
        float gSq = clampedG * clampedG;
        float denom = max(1.0e-4f, 1.0f + gSq - 2.0f * clampedG * clamp(cosTheta, -1.0f, 1.0f));
        return (1.0f - gSq) / (12.566370614f * denom * sqrt(denom));
    }

    // Wyman, Sloan & Shirley (2013) piecewise Gaussian CIE 1931 XYZ -> Linear Display-P3 & sRGB
    inline float asymmetricGaussian(float x, float mu, float s1, float s2) {
        float t = (x - mu) * (x < mu ? s1 : s2);
        return exp(-0.5f * t * t);
    }

    inline float3 wavelengthToCIE1931XYZ(float wavelengthNm) {
        if (wavelengthNm < 360.0f || wavelengthNm > 780.0f) {
            return float3(0.0f);
        }

        float xBar = 1.056f * asymmetricGaussian(wavelengthNm, 599.8f, 0.0264f, 0.0323f)
                   + 0.362f * asymmetricGaussian(wavelengthNm, 442.0f, 0.0624f, 0.0374f)
                   - 0.065f * asymmetricGaussian(wavelengthNm, 501.1f, 0.0490f, 0.0382f);

        float yBar = 0.821f * asymmetricGaussian(wavelengthNm, 568.8f, 0.0213f, 0.0247f)
                   + 0.286f * asymmetricGaussian(wavelengthNm, 530.9f, 0.0613f, 0.0322f);

        float zBar = 1.217f * asymmetricGaussian(wavelengthNm, 437.0f, 0.0845f, 0.0278f)
                   + 0.681f * asymmetricGaussian(wavelengthNm, 459.0f, 0.0385f, 0.0725f);

        return max(float3(xBar, yBar, zBar), float3(0.0f));
    }

    inline float3 xyzToLinearDisplayP3(float3 xyz) {
        float3 p3 = float3(
             2.4934969f * xyz.x - 0.9313836f * xyz.y - 0.4027108f * xyz.z,
            -0.8294890f * xyz.x + 1.7626641f * xyz.y + 0.0236247f * xyz.z,
             0.0358458f * xyz.x - 0.0761724f * xyz.y + 0.9568845f * xyz.z
        );
        return max(p3, float3(0.0f));
    }

    inline float3 wavelengthToLinearSRGB(float wavelengthNm) {
        float3 xyz = wavelengthToCIE1931XYZ(wavelengthNm);
        float3 linearRGB = float3(
             3.2406f * xyz.x - 1.5372f * xyz.y - 0.4986f * xyz.z,
            -0.9689f * xyz.x + 1.8758f * xyz.y + 0.0415f * xyz.z,
             0.0557f * xyz.x - 0.2040f * xyz.y + 1.0570f * xyz.z
        );
        return max(linearRGB, float3(0.0f));
    }

    inline float samplePressureBilinear(
        device const float* pressureField,
        float2 pos,
        int w,
        int h
    ) {
        float2 clamped = clamp(pos, float2(0.0f), float2(float(w - 1), float(h - 1)));
        int x0 = min(int(clamped.x), w - 2);
        int y0 = min(int(clamped.y), h - 2);
        float fx = clamped.x - float(x0);
        float fy = clamped.y - float(y0);

        float p00 = pressureField[y0 * w + x0];
        float p10 = pressureField[y0 * w + x0 + 1];
        float p01 = pressureField[(y0 + 1) * w + x0];
        float p11 = pressureField[(y0 + 1) * w + x0 + 1];

        return mix(mix(p00, p10, fx), mix(p01, p11, fx), fy);
    }

    inline float2 samplePressureGradient(
        device const float* pressureField,
        float2 pos,
        int w,
        int h
    ) {
        float pR = samplePressureBilinear(pressureField, pos + float2(1.0f, 0.0f), w, h);
        float pL = samplePressureBilinear(pressureField, pos - float2(1.0f, 0.0f), w, h);
        float pU = samplePressureBilinear(pressureField, pos + float2(0.0f, 1.0f), w, h);
        float pD = samplePressureBilinear(pressureField, pos - float2(0.0f, 1.0f), w, h);
        return 0.5f * float2(pR - pL, pU - pD);
    }
}

// MARK: - Spectral Acousto-Optic Photon Caustic Tracing Kernel (380..700nm)

kernel void aetherTraceAcoustoOpticPhotons(
    device const float* pressureField                 [[buffer(0)]],
    device atomic_uint* accumRGBQuantized             [[buffer(1)]],
    constant AcoustoOpticCausticUniforms& uniforms    [[buffer(2)]],
    uint tid                                          [[thread_position_in_grid]]
) {
    if (tid >= uniforms.photonCount || uniforms.gridWidth < 4u || uniforms.gridHeight < 4u) {
        return;
    }

    int w = int(uniforms.gridWidth);
    int h = int(uniforms.gridHeight);
    uint rng = tid * 1973u + 9277u;

    // Stratified 2D aperture position + stratified visible wavelength in [380, 700] nm
    uint strataSide = max(1u, uint(sqrt(float(uniforms.photonCount))));
    uint sx = tid % strataSide;
    uint sy = (tid / strataSide) % strataSide;

    float2 uv = float2(
        (float(sx) + aether_caustics::rand01(rng)) / float(strataSide),
        (float(sy) + aether_caustics::rand01(rng)) / float(strataSide)
    );

    // Select one of the 8 spectral bands in [380, 700] nm with sub-band jitter
    uint bandIdx = tid & 7u;
    float baseBandNm = aether_caustics::kSpectralWavelengthBandsNm[bandIdx];
    float wavelengthJitter = (aether_caustics::rand01(rng) - 0.5f) * 18.0f;
    float wavelengthNm = clamp(baseBandNm + wavelengthJitter, 380.0f, 700.0f);
    float3 xyz = aether_caustics::wavelengthToCIE1931XYZ(wavelengthNm);
    float3 p3RGB = aether_caustics::xyzToLinearDisplayP3(xyz);
    float3 srgb = aether_caustics::wavelengthToLinearSRGB(wavelengthNm);
    float3 spectralRGB = mix(srgb, p3RGB, 0.5f) * uniforms.photonEnergyScale;

    float2 pos = uv * float2(float(w - 1), float(h - 1));
    float3 rayDir = normalize(float3(uniforms.lightDirectionXY.x, uniforms.lightDirectionXY.y, 1.0f));
    float3 initialDir = rayDir;

    float lambdaUm = wavelengthNm * 1.0e-3f;
    float baseDispersionN = uniforms.baseRefractiveIndex + uniforms.cauchyDispersionB / (lambdaUm * lambdaUm);
    uint maxSteps = min(max(uniforms.integrationSteps, 4u), 64u);

    for (uint step = 0u; step < maxSteps; ++step) {
        float localP = aether_caustics::samplePressureBilinear(pressureField, pos, w, h);
        float localN = aether_caustics::refractiveIndex(
            wavelengthNm,
            localP,
            uniforms.baseRefractiveIndex,
            uniforms.cauchyDispersionB,
            uniforms.acoustoOpticKappa
        );

        // Symplectic Hamiltonian / Eikonal ray-bending: d/ds(n * dx/ds) = grad(n(x, lambda))
        float2 gradP = aether_caustics::samplePressureGradient(pressureField, pos, w, h);
        float2 gradN = baseDispersionN * uniforms.acoustoOpticKappa * gradP;

        float3 opticalMomentum = localN * rayDir;
        opticalMomentum.xy += gradN * (uniforms.stepSizeCells * 4.5f);
        rayDir = normalize(opticalMomentum);

        pos += rayDir.xy * uniforms.stepSizeCells;
        if (pos.x < 0.0f || pos.x >= float(w - 1) || pos.y < 0.0f || pos.y >= float(h - 1)) {
            break;
        }
    }

    // Weight arrival by Henyey-Greenstein phase function & bilinearly splat to receiver grid
    float cosScatter = dot(rayDir, initialDir);
    float hgWeight = aether_caustics::henyeyGreensteinPhase(cosScatter, uniforms.anisotropyG);
    float3 finalRGB = spectralRGB * (0.35f + 2.2f * hgWeight);

    int x0 = clamp(int(pos.x), 0, w - 2);
    int y0 = clamp(int(pos.y), 0, h - 2);
    float fx = clamp(pos.x - float(x0), 0.0f, 1.0f);
    float fy = clamp(pos.y - float(y0), 0.0f, 1.0f);

    float weights[4] = {
        (1.0f - fx) * (1.0f - fy),
        fx * (1.0f - fy),
        (1.0f - fx) * fy,
        fx * fy
    };
    int indices[4] = {
        (y0 * w + x0) * 3,
        (y0 * w + x0 + 1) * 3,
        ((y0 + 1) * w + x0) * 3,
        ((y0 + 1) * w + x0 + 1) * 3
    };

    for (int corner = 0; corner < 4; ++corner) {
        float3 contrib = clamp(finalRGB * weights[corner], float3(0.0f), float3(64.0f));
        uint qR = uint(contrib.r * aether_caustics::kCausticQuantScale + 0.5f);
        uint qG = uint(contrib.g * aether_caustics::kCausticQuantScale + 0.5f);
        uint qB = uint(contrib.b * aether_caustics::kCausticQuantScale + 0.5f);
        int baseIdx = indices[corner];
        if (qR > 0u) { atomic_fetch_add_explicit(&accumRGBQuantized[baseIdx + 0], qR, memory_order_relaxed); }
        if (qG > 0u) { atomic_fetch_add_explicit(&accumRGBQuantized[baseIdx + 1], qG, memory_order_relaxed); }
        if (qB > 0u) { atomic_fetch_add_explicit(&accumRGBQuantized[baseIdx + 2], qB, memory_order_relaxed); }
    }
}

// MARK: - Anisotropic Henyey-Greenstein Volumetric Caustics Resolve & Temporal EMA Kernel

kernel void aetherResolveVolumetricCaustics(
    device const uint* accumRGBQuantized              [[buffer(0)]],
    device float4* historyAndResolvedRGB              [[buffer(1)]],
    constant AcoustoOpticCausticUniforms& uniforms    [[buffer(2)]],
    uint2 gid                                         [[thread_position_in_grid]]
) {
    if (gid.x >= uniforms.gridWidth || gid.y >= uniforms.gridHeight) {
        return;
    }

    int w = int(uniforms.gridWidth);
    int h = int(uniforms.gridHeight);
    int x = int(gid.x);
    int y = int(gid.y);
    float invQuant = 1.0f / aether_caustics::kCausticQuantScale;

    float2 lightDir = length(uniforms.lightDirectionXY) > 1.0e-4f
        ? normalize(uniforms.lightDirectionXY)
        : float2(0.0f, 1.0f);
    float g = clamp(uniforms.anisotropyG, -0.50f, 0.85f);

    float3 scatteredRGB = float3(0.0f);
    float weightSum = 0.0f;

    // 3x3 anisotropic Henyey-Greenstein volumetric in-scattering kernel
    for (int dy = -1; dy <= 1; ++dy) {
        int ny = clamp(y + dy, 0, h - 1);
        for (int dx = -1; dx <= 1; ++dx) {
            int nx = clamp(x + dx, 0, w - 1);
            int baseIdx = (ny * w + nx) * 3;
            float3 sampleRGB = float3(
                float(accumRGBQuantized[baseIdx + 0]) * invQuant,
                float(accumRGBQuantized[baseIdx + 1]) * invQuant,
                float(accumRGBQuantized[baseIdx + 2]) * invQuant
            );

            float weight = 1.0f;
            if (dx != 0 || dy != 0) {
                float2 offsetDir = normalize(float2(float(dx), float(dy)));
                float cosTheta = dot(offsetDir, lightDir);
                float phase = aether_caustics::henyeyGreensteinPhase(cosTheta, g);
                weight = 0.35f * phase;
            }
            scatteredRGB += sampleRGB * weight;
            weightSum += weight;
        }
    }

    float3 currentRGB = scatteredRGB / max(weightSum, 1.0e-5f);
    // ACES-inspired filmic compression for iridescent caustic highlights
    float3 mappedRGB = currentRGB / (1.0f + 0.65f * currentRGB);

    int cellIdx = y * w + x;
    float4 prev = historyAndResolvedRGB[cellIdx];
    float emaAlpha = 0.24f;
    float3 blended = mix(prev.rgb, mappedRGB, emaAlpha);
    historyAndResolvedRGB[cellIdx] = float4(clamp(blended, float3(0.0f), float3(1.0f)), 1.0f);
}
