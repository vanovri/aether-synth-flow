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

    // Wyman, Sloan & Shirley (2013) piecewise Gaussian CIE 1931 XYZ -> Linear sRGB
    inline float asymmetricGaussian(float x, float mu, float s1, float s2) {
        float t = (x - mu) * (x < mu ? s1 : s2);
        return exp(-0.5f * t * t);
    }

    inline float3 wavelengthToLinearSRGB(float wavelengthNm) {
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

        float3 linearRGB = float3(
             3.2406f * xBar - 1.5372f * yBar - 0.4986f * zBar,
            -0.9689f * xBar + 1.8758f * yBar + 0.0415f * zBar,
             0.0557f * xBar - 0.2040f * yBar + 1.0570f * zBar
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

    float wavelengthFraction = fract(float(tid) * 0.61803398875f + 0.5f * aether_caustics::rand01(rng));
    float wavelengthNm = mix(380.0f, 700.0f, wavelengthFraction);
    float3 spectralRGB = aether_caustics::wavelengthToLinearSRGB(wavelengthNm) * uniforms.photonEnergyScale;

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

        // Eikonal refractive index gradient grad(n) = baseDispersionN * kappa_ao * grad(p)
        float2 gradP = aether_caustics::samplePressureGradient(pressureField, pos, w, h);
        float2 gradN = baseDispersionN * uniforms.acoustoOpticKappa * gradP;

        // Bend optical tangent vector toward higher refractive index regions
        rayDir.xy += (gradN / max(localN, 1.0f)) * uniforms.stepSizeCells * 4.5f;
        rayDir = normalize(rayDir);

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
