// MARK: - FILE: VolumetricCausticsKernels.metal

#include <metal_stdlib>
using namespace metal;

// 64-byte host/GPU uniform contract (matches Swift `AcoustoOpticCausticUniforms`, stride == 64, align == 8)
struct AcoustoOpticCausticUniforms {
    uint gridWidth;             // offset 0
    uint gridHeight;            // offset 4
    uint photonCount;           // offset 8
    uint integrationSteps;      // offset 12
    float baseRefractiveIndex;  // offset 16: n0 (water = 1.333)
    float cauchyDispersionB;    // offset 20: B in um^2 (e.g. 0.0031..0.0125)
    float acoustoOpticKappa;    // offset 24: Gladstone-Dale piezo-optic coupling kappa_ao
    float anisotropyG;          // offset 28: Henyey-Greenstein asymmetry g in (-1, 1)
    float stepSizeCells;        // offset 32: base Eikonal step length in grid cells
    float photonEnergyScale;    // offset 36: per-photon radiant flux normalization
    float2 lightDirectionXY;    // offset 40: oblique incident beam tilt (x, y)
    uint frameSeed;             // offset 48: temporal QMC / PCG frame decorrelation seed
    float slabDepthCells;       // offset 52: total optical slab thickness in grid cells
    float emaAlpha;             // offset 56: temporal exponential moving average blend factor
    float toneMapCompression;   // offset 60: Reinhard highlight compression shoulder coefficient
};

namespace aether_caustics {
    // Fixed-point quantization scale (2^16) for lock-free uint32 atomic accumulation
    constant float kCausticQuantScale = 65536.0f;
    constant float kInvCausticQuantScale = 1.0f / 65536.0f;
    // Four-pi steradians (4 * pi) for 3D Henyey-Greenstein phase normalization
    constant float kFourPiSteradians = 12.566370614359172f;
    constant float kInvFourPiSteradians = 0.07957747154594767f;
    // Eikonal Schlieren visual gain calibrating cell-space gradient to optical path curvature
    constant float kEikonalGradientGain = 4.5f;
    // Beer-Lambert per-step optical attenuation coefficient (nepers per cell)
    constant float kBeerLambertExtinctionPerCell = 0.018f;
    // Minimum photon throughput and corner splat weight thresholds for early culling
    constant float kMinPhotonThroughput = 0.05f;
    constant float kMinCornerSplatWeight = 0.08f;
    constant float kMaxQuantizedChannelRadiance = 64.0f;

    // 8 stratified visible wavelength bands spanning [380, 700] nm
    constant float kSpectralWavelengthBandsNm[8] = {
        380.0f, 425.71429f, 471.42857f, 517.14286f,
        562.85714f, 608.57143f, 654.28571f, 700.0f
    };

    // Precomputed 1 / lambda_um^2 (um^-2) for the 8 spectral anchor bands (eliminates per-step division)
    constant float kSpectralInvLambdaUmSq[8] = {
        6.9252078f, 5.5177665f, 4.4995394f, 3.7392014f,
        3.1564841f, 2.7000836f, 2.3359570f, 2.0408163f
    };

    // Precomputed unit offset vectors for the 8-connected 3x3 resolve neighborhood (eliminates per-pixel normalize)
    constant float2 kResolveNeighborOffsets[8] = {
        float2(-1.0f, -1.0f), float2(0.0f, -1.0f), float2(1.0f, -1.0f),
        float2(-1.0f,  0.0f),                      float2(1.0f,  0.0f),
        float2(-1.0f,  1.0f), float2(0.0f,  1.0f), float2(1.0f,  1.0f)
    };
    constant float2 kResolveNeighborUnitDirs[8] = {
        float2(-0.70710678f, -0.70710678f), float2(0.0f, -1.0f), float2(0.70710678f, -0.70710678f),
        float2(-1.0f,         0.0f),                             float2(1.0f,        0.0f),
        float2(-0.70710678f,  0.70710678f), float2(0.0f,  1.0f), float2(0.70710678f,  0.70710678f)
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

    // Cauchy dispersion + Gladstone-Dale acousto-optic coupling using pre-hoisted baseDispersionN:
    // n(x, lambda) = baseDispersionN(lambda) * (1 + kappa_ao * p(x))
    inline float refractiveIndexFromBase(
        float baseDispersionN,
        float pressure,
        float kappaAO
    ) {
        float densityMod = max(0.05f, fma(kappaAO, pressure, 1.0f));
        return max(1.0001f, baseDispersionN * densityMod);
    }

    inline float refractiveIndex(
        float wavelengthNm,
        float pressure,
        float n0,
        float cauchyB,
        float kappaAO
    ) {
        float lambdaUm = max(0.25f, wavelengthNm * 1.0e-3f);
        float invLambdaSq = 1.0f / (lambdaUm * lambdaUm);
        float baseN = fma(cauchyB, invLambdaSq, n0);
        return refractiveIndexFromBase(baseN, pressure, kappaAO);
    }

    // Henyey-Greenstein volumetric phase function using hardware fast::rsqrt
    inline float henyeyGreensteinPhase(float cosTheta, float g) {
        float clampedG = clamp(g, -0.98f, 0.98f);
        float gSq = clampedG * clampedG;
        float denom = max(1.0e-4f, fma(-2.0f * clampedG, clamp(cosTheta, -1.0f, 1.0f), 1.0f + gSq));
        float invSqrtDenom = fast::rsqrt(denom);
        float invDenom32 = (invSqrtDenom * invSqrtDenom) * invSqrtDenom;
        return (1.0f - gSq) * kInvFourPiSteradians * invDenom32;
    }

    // Analytic inverse-CDF importance sampler for Henyey-Greenstein scattering cosine
    inline float sampleHenyeyGreensteinCosTheta(float xi01, float g) {
        float clampedG = clamp(g, -0.98f, 0.98f);
        float xi = clamp(xi01, 0.0f, 1.0f);
        if (abs(clampedG) < 1.0e-4f) {
            return fma(-2.0f, xi, 1.0f);
        }
        float gSq = clampedG * clampedG;
        float frac = (1.0f - gSq) / fma(2.0f * clampedG, xi, 1.0f - clampedG);
        return clamp((1.0f + gSq - frac * frac) / (2.0f * clampedG), -1.0f, 1.0f);
    }

    // Wyman, Sloan & Shirley (2013) piecewise Gaussian CIE 1931 XYZ -> Linear Display-P3 & sRGB
    inline float asymmetricGaussian(float x, float mu, float s1, float s2) {
        float t = (x - mu) * (x < mu ? s1 : s2);
        return fast::exp(-0.5f * t * t);
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

    inline float3 xyzToLinearSRGB(float3 xyz) {
        float3 linearRGB = float3(
             3.2406f * xyz.x - 1.5372f * xyz.y - 0.4986f * xyz.z,
            -0.9689f * xyz.x + 1.8758f * xyz.y + 0.0415f * xyz.z,
             0.0557f * xyz.x - 0.2040f * xyz.y + 1.0570f * xyz.z
        );
        return max(linearRGB, float3(0.0f));
    }

    inline float3 wavelengthToLinearSRGB(float wavelengthNm) {
        return xyzToLinearSRGB(wavelengthToCIE1931XYZ(wavelengthNm));
    }

    // Fused 6-tap bilinear pressure & central-difference gradient evaluation
    // Replaces 20 redundant global memory loads per step with 6 coalesced reads.
    inline float3 samplePressureAndGradientFused(
        device const float* pressureField,
        float2 pos,
        int w,
        int h
    ) {
        float2 maxCoord = float2(float(w - 1), float(h - 1));
        float2 clamped = clamp(pos, float2(0.0f), maxCoord);
        int x0 = min(int(clamped.x), w - 2);
        int y0 = min(int(clamped.y), h - 2);
        float fx = clamped.x - float(x0);
        float fy = clamped.y - float(y0);

        int row0 = y0 * w;
        int row1 = (y0 + 1) * w;
        float p00 = pressureField[row0 + x0];
        float p10 = pressureField[row0 + x0 + 1];
        float p01 = pressureField[row1 + x0];
        float p11 = pressureField[row1 + x0 + 1];

        float top = fma(fx, p10 - p00, p00);
        float bot = fma(fx, p11 - p01, p01);
        float localP = fma(fy, bot - top, top);

        int xm1 = max(0, x0 - 1);
        int ym1 = max(0, y0 - 1);
        float pL = pressureField[row0 + xm1];
        float pD = pressureField[ym1 * w + x0];

        // Blended sub-cell bilinear derivative + central difference stencil
        float dPdxCell = fma(fy, (p11 - p01) - (p10 - p00), p10 - p00);
        float dPdyCell = fma(fx, (p11 - p10) - (p01 - p00), p01 - p00);
        float dPdxCentral = 0.5f * (p10 - pL);
        float dPdyCentral = 0.5f * (p01 - pD);

        float2 gradP = 0.5f * float2(dPdxCell + dPdxCentral, dPdyCell + dPdyCentral);
        return float3(localP, gradP.x, gradP.y);
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
    uint rng = tid * 1973u + 9277u + uniforms.frameSeed * 2654435761u;

    // Stratified 2D aperture position + decorrelated Latin-square spectral band in [380, 700] nm
    uint strataSide = max(1u, uint(sqrt(float(uniforms.photonCount))));
    float invStrataSide = 1.0f / float(strataSide);
    uint sx = tid % strataSide;
    uint sy = (tid / strataSide) % strataSide;

    float2 uv = float2(
        (float(sx) + aether_caustics::rand01(rng)) * invStrataSide,
        (float(sy) + aether_caustics::rand01(rng)) * invStrataSide
    );

    // Decorrelate spectral band from column index sx using Latin-square hash
    uint bandIdx = (sx + 3u * sy + uniforms.frameSeed) & 7u;
    float baseBandNm = aether_caustics::kSpectralWavelengthBandsNm[bandIdx];
    float wavelengthJitter = fma(aether_caustics::rand01(rng), 18.0f, -9.0f);
    float wavelengthNm = clamp(baseBandNm + wavelengthJitter, 380.0f, 700.0f);

    // Single CIE 1931 XYZ evaluation -> Linear Display-P3 & sRGB (50% fewer exp() calls)
    float3 xyz = aether_caustics::wavelengthToCIE1931XYZ(wavelengthNm);
    float3 p3RGB = aether_caustics::xyzToLinearDisplayP3(xyz);
    float3 srgb = aether_caustics::xyzToLinearSRGB(xyz);
    float3 spectralRGB = mix(srgb, p3RGB, 0.5f) * uniforms.photonEnergyScale;

    float2 maxDomain = float2(float(w - 1), float(h - 1));
    float2 pos = uv * maxDomain;
    float3 rayDir = fast::normalize(float3(uniforms.lightDirectionXY.x, uniforms.lightDirectionXY.y, 1.0f));
    float3 initialDir = rayDir;

    // Hoist loop-invariant Cauchy refractive index and acousto-optic gradient coupling outside march loop
    float lambdaUm = wavelengthNm * 1.0e-3f;
    float invLambdaUmSq = (abs(wavelengthJitter) < 1.0e-3f)
        ? aether_caustics::kSpectralInvLambdaUmSq[bandIdx]
        : (1.0f / (lambdaUm * lambdaUm));
    float baseDispersionN = fma(uniforms.cauchyDispersionB, invLambdaUmSq, uniforms.baseRefractiveIndex);
    float gradNScale = baseDispersionN * uniforms.acoustoOpticKappa;

    // Surface entry Snell refraction modulated by initial local pressure
    float3 entryPG = aether_caustics::samplePressureAndGradientFused(pressureField, pos, w, h);
    float entryN = aether_caustics::refractiveIndexFromBase(
        baseDispersionN,
        entryPG.x,
        uniforms.acoustoOpticKappa
    );
    rayDir.xy /= entryN;
    rayDir = fast::normalize(rayDir);

    uint maxSteps = min(max(uniforms.integrationSteps, 4u), 64u);
    float baseStepCells = max(0.05f, uniforms.stepSizeCells);
    float targetSlabDepth = (uniforms.slabDepthCells > 0.1f)
        ? uniforms.slabDepthCells
        : (baseStepCells * float(maxSteps));
    float marchedDepth = 0.0f;
    float throughput = 1.0f;
    bool exitedDomain = false;

    for (uint step = 0u; step < maxSteps; ++step) {
        float3 samplePG = aether_caustics::samplePressureAndGradientFused(pressureField, pos, w, h);
        float localP = samplePG.x;
        float2 gradP = samplePG.yz;

        float localN = aether_caustics::refractiveIndexFromBase(
            baseDispersionN,
            localP,
            uniforms.acoustoOpticKappa
        );
        float2 gradN = gradNScale * gradP;

        // Adaptive step sizing: stretch up to 1.85x in low-gradient regions, refine to 1.0x at caustic cusps
        float gradMagSq = dot(gradN, gradN);
        float adaptiveScale = clamp(1.85f * fast::rsqrt(1.0f + 24.0f * gradMagSq), 1.0f, 1.85f);
        float ds = min(baseStepCells * adaptiveScale, targetSlabDepth - marchedDepth);

        // Symplectic Hamiltonian / Eikonal ray-bending: d/ds(n * dx/ds) = grad(n(x, lambda))
        float3 opticalMomentum = localN * rayDir;
        float bendStep = ds * aether_caustics::kEikonalGradientGain;
        opticalMomentum.xy = fma(gradN, float2(bendStep), opticalMomentum.xy);
        rayDir = fast::normalize(opticalMomentum);

        pos = fma(rayDir.xy, float2(ds), pos);
        marchedDepth += ds;
        throughput *= fast::exp(-aether_caustics::kBeerLambertExtinctionPerCell * ds);

        // Early-exit on domain boundary escape, total internal reflection stall, slab completion, or low throughput
        if (pos.x < 0.0f || pos.x >= maxDomain.x || pos.y < 0.0f || pos.y >= maxDomain.y) {
            exitedDomain = true;
            break;
        }
        if (marchedDepth >= targetSlabDepth || throughput < aether_caustics::kMinPhotonThroughput || rayDir.z <= 0.05f) {
            break;
        }
    }

    if (exitedDomain || throughput < aether_caustics::kMinPhotonThroughput) {
        return;
    }

    // Weight arrival by Henyey-Greenstein phase function & gated bilinear splat to receiver grid
    float cosScatter = dot(rayDir, initialDir);
    float hgWeight = aether_caustics::henyeyGreensteinPhase(cosScatter, uniforms.anisotropyG);
    float3 finalRGB = spectralRGB * (throughput * fma(2.2f, hgWeight, 0.35f));

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
        float wCorner = weights[corner];
        if (wCorner < aether_caustics::kMinCornerSplatWeight) {
            continue;
        }
        float3 contrib = clamp(
            finalRGB * wCorner,
            float3(0.0f),
            float3(aether_caustics::kMaxQuantizedChannelRadiance)
        );
        uint qR = uint(fma(contrib.r, aether_caustics::kCausticQuantScale, 0.5f));
        uint qG = uint(fma(contrib.g, aether_caustics::kCausticQuantScale, 0.5f));
        uint qB = uint(fma(contrib.b, aether_caustics::kCausticQuantScale, 0.5f));
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
    float invQuant = aether_caustics::kInvCausticQuantScale;

    float lightLenSq = dot(uniforms.lightDirectionXY, uniforms.lightDirectionXY);
    float2 lightDir = (lightLenSq > 1.0e-8f)
        ? (uniforms.lightDirectionXY * fast::rsqrt(lightLenSq))
        : float2(0.0f, 1.0f);
    float g = clamp(uniforms.anisotropyG, -0.50f, 0.85f);

    int centerBaseIdx = (y * w + x) * 3;
    float3 scatteredRGB = float3(
        float(accumRGBQuantized[centerBaseIdx + 0]) * invQuant,
        float(accumRGBQuantized[centerBaseIdx + 1]) * invQuant,
        float(accumRGBQuantized[centerBaseIdx + 2]) * invQuant
    );
    float weightSum = 1.0f;

    // 8-neighbor anisotropic Henyey-Greenstein in-scattering using precomputed unit offset table
    for (uint nIdx = 0u; nIdx < 8u; ++nIdx) {
        float2 offset = aether_caustics::kResolveNeighborOffsets[nIdx];
        int nx = clamp(x + int(offset.x), 0, w - 1);
        int ny = clamp(y + int(offset.y), 0, h - 1);
        int baseIdx = (ny * w + nx) * 3;
        float3 sampleRGB = float3(
            float(accumRGBQuantized[baseIdx + 0]) * invQuant,
            float(accumRGBQuantized[baseIdx + 1]) * invQuant,
            float(accumRGBQuantized[baseIdx + 2]) * invQuant
        );

        float cosTheta = dot(aether_caustics::kResolveNeighborUnitDirs[nIdx], lightDir);
        float weight = 0.35f * aether_caustics::henyeyGreensteinPhase(cosTheta, g);
        scatteredRGB = fma(sampleRGB, float3(weight), scatteredRGB);
        weightSum += weight;
    }

    float3 currentRGB = scatteredRGB / max(weightSum, 1.0e-5f);
    float compression = (uniforms.toneMapCompression > 0.0f) ? uniforms.toneMapCompression : 0.65f;
    float3 mappedRGB = currentRGB / fma(float3(compression), currentRGB, float3(1.0f));

    int cellIdx = y * w + x;
    float4 prev = historyAndResolvedRGB[cellIdx];
    float emaAlpha = (uniforms.emaAlpha > 0.0f && uniforms.emaAlpha <= 1.0f) ? uniforms.emaAlpha : 0.24f;
    float3 blended = mix(prev.rgb, mappedRGB, emaAlpha);
    historyAndResolvedRGB[cellIdx] = float4(clamp(blended, float3(0.0f), float3(1.0f)), 1.0f);
}
