// MARK: - FILE: AetherCompositorShaders.metal

#if defined(__METAL_VERSION__)

#include <metal_stdlib>
using namespace metal;

// MARK: - Shared GPU Particle & Stereoscopic Multi-View Uniform Layouts (16-Byte Aligned)

struct AetherCurlParticle {
    float4 positionAndAge;      // xyz = world position (m), w = normalized age [0..1]
    float4 velocityAndSeed;     // xyz = world velocity (m/s), w = per-particle deterministic seed [0..1]
    float4 colorAndSize;        // rgb = linear HDR tint, w = billboard radius (m)
};

struct AetherCompositorUniforms {
    float4x4 viewProjectionMatrix[2];   // Per-eye stereoscopic reverse-Z View * Projection
    float4 cameraRightWorld[2];         // xyz = per-eye world right vector
    float4 cameraUpWorld[2];            // xyz = per-eye world up vector
    float4 eyePositionWorld[2];         // xyz = per-eye world origin
    float4 attractorCenterAndRadius;    // xyz = central orbital core world pos, w = target shell radius
    float4 leftPalmAndPinch;            // xyz = left palm world pos, w = left pinch engagement [0/1]
    float4 rightPalmAndPinch;           // xyz = right palm world pos, w = right pinch engagement [0/1]
    float4 simulationTiming;            // x = dt, y = elapsedTime, z = curlSpatialFreq, w = curlStrength
    float4 acousticModulation;          // x = binauralBeatHz, y = cutoffNorm, z = resonance, w = bloomBoost
    float4 spectralEnergyBands;         // x = subBand, y = lowBand, z = highBand, w = rmsAmplitude
    float4 fftBinsPacked[16];           // 64 perceptual FFT bins packed as 16 x float4
    uint eyeIndex;
    uint isLayeredStereo;
    uint particleCount;
    uint frameCounter;
};

struct AetherStereoParticleVaryings {
    float4 clipPosition [[position]];
    uint layerIndex [[render_target_array_index]];
    uint viewportIndex [[viewport_array_index]];
    float2 quadUV;
    float4 hdrColor;
    float sparklePhase;
};

struct AetherStereoAuroraDomeVaryings {
    float4 clipPosition [[position]];
    uint layerIndex [[render_target_array_index]];
    uint viewportIndex [[viewport_array_index]];
    float3 worldRayDir;
    float2 domeUV;
};

// MARK: - Deterministic 3D Hash & Quintic C2 Gradient/Value Noise with Analytical Derivatives

inline float3 aetherHash33(int3 cell) {
    uint3 q = uint3(cell) * uint3(1597334673u, 3812015801u, 2798796415u);
    q = (q.x ^ q.y ^ q.z) * uint3(1597334673u, 3812015801u, 2798796415u);
    float3 unit = float3(q) * (1.0f / 4294967295.0f);
    return normalize(unit * 2.0f - 1.0f + 1.0e-5f);
}

inline float4 aetherGradientNoiseWithDerivatives3D(float3 p) {
    float3 cellFloor = floor(p);
    int3 i = int3(cellFloor);
    float3 f = p - cellFloor;

    float3 u = f * f * f * (f * (f * 6.0f - 15.0f) + 10.0f);
    float3 du = 30.0f * f * f * (f * (f - 2.0f) + 1.0f);

    float3 g000 = aetherHash33(i + int3(0, 0, 0));
    float3 g100 = aetherHash33(i + int3(1, 0, 0));
    float3 g010 = aetherHash33(i + int3(0, 1, 0));
    float3 g110 = aetherHash33(i + int3(1, 1, 0));
    float3 g001 = aetherHash33(i + int3(0, 0, 1));
    float3 g101 = aetherHash33(i + int3(1, 0, 1));
    float3 g011 = aetherHash33(i + int3(0, 1, 1));
    float3 g111 = aetherHash33(i + int3(1, 1, 1));

    float v000 = dot(g000, f - float3(0.0f, 0.0f, 0.0f));
    float v100 = dot(g100, f - float3(1.0f, 0.0f, 0.0f));
    float v010 = dot(g010, f - float3(0.0f, 1.0f, 0.0f));
    float v110 = dot(g110, f - float3(1.0f, 1.0f, 0.0f));
    float v001 = dot(g001, f - float3(0.0f, 0.0f, 1.0f));
    float v101 = dot(g101, f - float3(1.0f, 0.0f, 1.0f));
    float v011 = dot(g011, f - float3(0.0f, 1.0f, 1.0f));
    float v111 = dot(g111, f - float3(1.0f, 1.0f, 1.0f));

    float k0 = v000;
    float k1 = v100 - v000;
    float k2 = v010 - v000;
    float k3 = v001 - v000;
    float k4 = v000 - v100 - v010 + v110;
    float k5 = v000 - v010 - v001 + v011;
    float k6 = v000 - v100 - v001 + v101;
    float k7 = -v000 + v100 + v010 - v110 + v001 - v101 - v011 + v111;

    float3 gInterp = g000
        + u.x * (g100 - g000)
        + u.y * (g010 - g000)
        + u.z * (g001 - g000)
        + u.x * u.y * (g000 - g100 - g010 + g110)
        + u.y * u.z * (g000 - g010 - g001 + g011)
        + u.z * u.x * (g000 - g100 - g001 + g101)
        + u.x * u.y * u.z * (-g000 + g100 + g010 - g110 + g001 - g101 - g011 + g111);

    float value = k0
        + k1 * u.x
        + k2 * u.y
        + k3 * u.z
        + k4 * u.x * u.y
        + k5 * u.y * u.z
        + k6 * u.z * u.x
        + k7 * u.x * u.y * u.z;

    float3 deriv = gInterp + du * float3(
        k1 + k4 * u.y + k6 * u.z + k7 * u.y * u.z,
        k2 + k5 * u.z + k4 * u.x + k7 * u.z * u.x,
        k3 + k6 * u.x + k5 * u.y + k7 * u.x * u.y
    );

    return float4(value, deriv);
}

inline float3 evaluateDivergenceFreeCurl3D(float3 worldPos, float spatialScale, float timeSec) {
    float3 q = worldPos * spatialScale + float3(0.0f, timeSec * 0.14f, -timeSec * 0.11f);

    float4 psiX1 = aetherGradientNoiseWithDerivatives3D(q + float3(17.3f, -9.1f, 4.7f));
    float4 psiY1 = aetherGradientNoiseWithDerivatives3D(q + float3(-31.7f, 23.4f, -12.9f));
    float4 psiZ1 = aetherGradientNoiseWithDerivatives3D(q + float3(43.1f, 11.8f, 29.5f));

    float3 qFine = q * 2.07f + float3(-timeSec * 0.21f, 5.2f, timeSec * 0.18f);
    float4 psiX2 = aetherGradientNoiseWithDerivatives3D(qFine + float3(7.9f, 19.4f, -21.3f));
    float4 psiY2 = aetherGradientNoiseWithDerivatives3D(qFine + float3(-14.6f, -27.2f, 8.8f));
    float4 psiZ2 = aetherGradientNoiseWithDerivatives3D(qFine + float3(25.0f, -6.5f, 34.1f));

    float3 gradPsiX = (psiX1.yzw + 0.5f * 2.07f * psiX2.yzw) * spatialScale;
    float3 gradPsiY = (psiY1.yzw + 0.5f * 2.07f * psiY2.yzw) * spatialScale;
    float3 gradPsiZ = (psiZ1.yzw + 0.5f * 2.07f * psiZ2.yzw) * spatialScale;

    return float3(
        gradPsiZ.y - gradPsiY.z,
        gradPsiX.z - gradPsiZ.x,
        gradPsiY.x - gradPsiX.y
    );
}

inline float sampleFFTSpectrum64(constant float4 *fftBinsPacked, float normalizedCoord) {
    float clamped = clamp(normalizedCoord, 0.0f, 0.9999f) * 63.0f;
    uint idx0 = uint(clamped);
    uint idx1 = min(idx0 + 1u, 63u);
    float frac = clamped - float(idx0);

    float v0 = fftBinsPacked[idx0 >> 2u][idx0 & 3u];
    float v1 = fftBinsPacked[idx1 >> 2u][idx1 & 3u];
    return mix(v0, v1, frac);
}

inline float3 aetherCosineAuroraPalette(float t, float bloomBoost) {
    float3 a = float3(0.26f, 0.44f, 0.70f);
    float3 b = float3(0.34f, 0.36f, 0.30f);
    float3 c = float3(1.00f, 1.00f, 1.00f);
    float3 d = float3(0.02f, 0.22f, 0.54f);
    float3 rgb = a + b * cos(6.2831853f * (c * t + d));
    return rgb * (1.12f + bloomBoost * 1.45f);
}

// MARK: - 1. Double-Buffered 16,384-Particle Curl-Noise + 64-Bin FFT Shockwave Compute Kernel

kernel void aetherCurlNoiseParticleKernel(
    const device AetherCurlParticle *particlesIn [[buffer(0)]],
    device AetherCurlParticle *particlesOut [[buffer(1)]],
    constant AetherCompositorUniforms &uniforms [[buffer(2)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= uniforms.particleCount) {
        return;
    }

    AetherCurlParticle p = particlesIn[gid];
    float3 pos = p.positionAndAge.xyz;
    float age = p.positionAndAge.w;
    float3 vel = p.velocityAndSeed.xyz;
    float seed = p.velocityAndSeed.w;

    float dt = clamp(uniforms.simulationTiming.x, 0.0005f, 0.050f);
    float elapsed = uniforms.simulationTiming.y;
    float curlScale = uniforms.simulationTiming.z;
    float curlStrength = uniforms.simulationTiming.w;

    float beatHz = uniforms.acousticModulation.x;
    float cutoffNorm = uniforms.acousticModulation.y;
    float resonance = uniforms.acousticModulation.z;
    float bloomBoost = uniforms.acousticModulation.w;

    // 1. Divergence-free 3D curl-noise velocity field
    float3 curlVel = evaluateDivergenceFreeCurl3D(pos, curlScale, elapsed) * curlStrength;

    // 2. Central gravitational shell attraction + Keplerian swirl
    float3 attractor = uniforms.attractorCenterAndRadius.xyz;
    float targetRadius = uniforms.attractorCenterAndRadius.w * (1.0f + 0.24f * bloomBoost);
    float3 toParticle = pos - attractor;
    float dist = length(toParticle);
    float3 radialDir = (dist > 1.0e-4f) ? (toParticle / dist) : float3(0.0f, 1.0f, 0.0f);

    float shellError = targetRadius - dist;
    float3 gravityForce = radialDir * (shellError * (1.65f + resonance * 1.35f));

    // Bimanual palm micro-attractors when hands pinch
    float3 toLeftPalm = uniforms.leftPalmAndPinch.xyz - pos;
    float3 toRightPalm = uniforms.rightPalmAndPinch.xyz - pos;
    float leftDistSq = max(0.025f, dot(toLeftPalm, toLeftPalm));
    float rightDistSq = max(0.025f, dot(toRightPalm, toRightPalm));
    float3 bimanualPull = normalize(toLeftPalm + 1e-5f) * (0.12f * uniforms.leftPalmAndPinch.w / leftDistSq)
        + normalize(toRightPalm + 1e-5f) * (0.12f * uniforms.rightPalmAndPinch.w / rightDistSq);

    // 3. Radial acoustic shockwave forces driven by the 64-bin FFT spectrum
    float radialBinCoord = clamp(dist / max(0.25f, targetRadius * 2.0f), 0.0f, 1.0f);
    float binEnergy = sampleFFTSpectrum64(uniforms.fftBinsPacked, fract(radialBinCoord * 0.7f + seed * 0.3f));
    float shockPhase = sin(dist * 9.5f - elapsed * (4.0f + beatHz * 0.25f));
    float3 shockwaveForce = radialDir * (binEnergy * (0.55f + 0.85f * max(0.0f, shockPhase)));

    float3 orbitAxis = normalize(float3(0.14f * sin(elapsed * 0.23f), 1.0f, 0.11f * cos(elapsed * 0.19f)));
    float3 tangentDir = cross(orbitAxis, radialDir);
    float swirlSpeed = 0.36f + (beatHz / 40.0f) * 0.95f + uniforms.spectralEnergyBands.x * 0.45f;
    float3 orbitalSwirl = tangentDir * swirlSpeed;

    // 4. Symplectic integration with exponential drag
    float3 desiredVel = curlVel + gravityForce + shockwaveForce + orbitalSwirl + bimanualPull;
    float damping = exp(-2.7f * dt);
    vel = vel * damping + desiredVel * (1.0f - damping);
    pos += vel * dt;

    // 5. Lifetime & deterministic spherical shell respawn
    age += dt * (0.082f + 0.045f * fract(seed * 13.37f));
    if (age >= 1.0f || dist > 5.8f || !isfinite(pos.x)) {
        age = fract(age);
        float u = fract(seed + float(gid) * 0.6180339887f + elapsed * 0.031f);
        float v = fract(seed * 7.13f + float(gid) * 0.3819660112f);
        float theta = 6.2831853f * u;
        float cosPhi = 1.0f - 2.0f * v;
        float sinPhi = sqrt(max(0.0f, 1.0f - cosPhi * cosPhi));
        float spawnR = targetRadius * (0.62f + 0.56f * fract(seed * 29.1f));
        pos = attractor + float3(sinPhi * cos(theta), cosPhi * 0.72f, sinPhi * sin(theta)) * spawnR;
        vel *= 0.25f;
    }

    float paletteCoord = fract(seed * 0.60f + cutoffNorm * 0.40f + binEnergy * 0.35f - elapsed * 0.04f);
    float lifeEnvelope = sin(clamp(age, 0.0f, 1.0f) * 3.14159265f);
    float3 hdrTint = aetherCosineAuroraPalette(paletteCoord, bloomBoost + binEnergy * 0.45f)
        * (0.35f + 0.90f * lifeEnvelope);
    float sizeMeters = (0.0042f + 0.0068f * fract(seed * 5.7f))
        * (1.0f + 0.55f * bloomBoost + 0.35f * binEnergy)
        * (0.55f + 0.55f * lifeEnvelope);

    AetherCurlParticle nextP;
    nextP.positionAndAge = float4(pos, age);
    nextP.velocityAndSeed = float4(vel, seed);
    nextP.colorAndSize = float4(hdrTint, sizeMeters);
    particlesOut[gid] = nextP;
}

// MARK: - 2. Stereoscopic Particle Billboard Shaders ([[render_target_array_index]])

vertex AetherStereoParticleVaryings aetherStereoParticleVertex(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    const device AetherCurlParticle *particles [[buffer(0)]],
    constant AetherCompositorUniforms &uniforms [[buffer(1)]]
) {
    // 6-vertex two-triangle quad in [-1, +1]^2 (compatible with MTLPrimitiveTypeTriangle + layered rendering)
    const float2 quadTriangleCorners[6] = {
        float2(-1.0f, -1.0f),
        float2( 1.0f, -1.0f),
        float2(-1.0f,  1.0f),
        float2(-1.0f,  1.0f),
        float2( 1.0f, -1.0f),
        float2( 1.0f,  1.0f)
    };

    uint particleIdx = instanceID % uniforms.particleCount;
    uint eye = (uniforms.isLayeredStereo != 0u)
        ? min(instanceID / max(1u, uniforms.particleCount), 1u)
        : min(uniforms.eyeIndex, 1u);

    AetherCurlParticle p = particles[particleIdx];
    float2 corner = quadTriangleCorners[vertexID % 6u];
    float radius = p.colorAndSize.w;

    float3 rightVec = uniforms.cameraRightWorld[eye].xyz;
    float3 upVec = uniforms.cameraUpWorld[eye].xyz;
    float3 worldVertex = p.positionAndAge.xyz + (rightVec * corner.x + upVec * corner.y) * radius;

    AetherStereoParticleVaryings out;
    out.clipPosition = uniforms.viewProjectionMatrix[eye] * float4(worldVertex, 1.0f);
    out.layerIndex = (uniforms.isLayeredStereo != 0u) ? eye : 0u;
    out.viewportIndex = (uniforms.isLayeredStereo != 0u) ? eye : 0u;
    out.quadUV = corner;
    out.hdrColor = float4(p.colorAndSize.xyz, 1.0f);
    out.sparklePhase = p.velocityAndSeed.w * 6.2831853f
        + uniforms.simulationTiming.y * uniforms.acousticModulation.x * 0.35f;
    return out;
}

fragment float4 aetherStereoParticleFragment(
    AetherStereoParticleVaryings in [[stage_in]]
) {
    float r2 = dot(in.quadUV, in.quadUV);
    if (r2 > 1.0f) {
        discard_fragment();
    }

    float softHalo = exp(-3.6f * r2);
    float coreSpike = max(0.0f, 1.0f - sqrt(r2));
    float shimmer = 0.88f + 0.12f * sin(in.sparklePhase);
    float intensity = (softHalo * 0.74f + coreSpike * coreSpike * 0.68f) * shimmer;

    return float4(in.hdrColor.rgb * intensity, intensity);
}

// MARK: - 3. Stereoscopic Procedural Aurora Sky Dome Shaders ([[render_target_array_index]])

vertex AetherStereoAuroraDomeVaryings aetherStereoAuroraDomeVertex(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    constant AetherCompositorUniforms &uniforms [[buffer(0)]]
) {
    // Procedural 32 x 16 UV sphere dome (32 * 16 * 6 = 3,072 vertices per eye)
    const uint azSegments = 32u;
    const uint elSegments = 16u;

    uint quadIndex = vertexID / 6u;
    uint triCorner = vertexID % 6u;

    uint azIdx = quadIndex % azSegments;
    uint elIdx = min(quadIndex / azSegments, elSegments - 1u);

    const uint2 cornerOffsets[6] = {
        uint2(0u, 0u), uint2(1u, 0u), uint2(0u, 1u),
        uint2(0u, 1u), uint2(1u, 0u), uint2(1u, 1u)
    };
    uint2 offset = cornerOffsets[triCorner];

    float u = float(azIdx + offset.x) / float(azSegments);
    float v = float(elIdx + offset.y) / float(elSegments);

    float theta = u * 6.2831853f;
    float phi = v * 3.14159265f;
    float sinPhi = sin(phi);
    float3 unitDir = float3(sinPhi * cos(theta), cos(phi), sinPhi * sin(theta));

    uint eye = (uniforms.isLayeredStereo != 0u) ? min(instanceID, 1u) : min(uniforms.eyeIndex, 1u);
    float3 domeCenter = uniforms.eyePositionWorld[eye].xyz;
    float3 worldPos = domeCenter + unitDir * 14.0f;

    AetherStereoAuroraDomeVaryings out;
    out.clipPosition = uniforms.viewProjectionMatrix[eye] * float4(worldPos, 1.0f);
    out.layerIndex = (uniforms.isLayeredStereo != 0u) ? eye : 0u;
    out.viewportIndex = (uniforms.isLayeredStereo != 0u) ? eye : 0u;
    out.worldRayDir = unitDir;
    out.domeUV = float2(u, v);
    return out;
}

fragment float4 aetherStereoAuroraDomeFragment(
    AetherStereoAuroraDomeVaryings in [[stage_in]],
    constant AetherCompositorUniforms &uniforms [[buffer(0)]]
) {
    float3 dir = normalize(in.worldRayDir);
    float elevation = dir.y;

    // Concentrate aurora curtains in upper spatial hemisphere while keeping lower floor subtle for passthrough comfort
    float horizonMask = smoothstep(-0.18f, 0.32f, elevation) * (1.0f - smoothstep(0.86f, 0.99f, elevation));
    if (horizonMask <= 0.002f) {
        discard_fragment();
    }

    float elapsed = uniforms.simulationTiming.y;
    float beatHz = uniforms.acousticModulation.x;
    float bloom = uniforms.acousticModulation.w;

    float azimuthNorm = fract(atan2(dir.z, dir.x) * (1.0f / 6.2831853f) + 0.5f);
    float fftRibbon = sampleFFTSpectrum64(uniforms.fftBinsPacked, azimuthNorm);

    float4 n1 = aetherGradientNoiseWithDerivatives3D(dir * 3.2f + float3(elapsed * 0.08f, -elapsed * 0.05f, 0.0f));
    float4 n2 = aetherGradientNoiseWithDerivatives3D(dir * 6.8f + float3(-elapsed * 0.12f, elapsed * 0.09f, 2.4f));

    float curtainWave = sin((dir.x * 5.0f + dir.z * 4.2f + n1.x * 2.6f) + elapsed * (0.35f + beatHz * 0.02f));
    float curtainBand = pow(max(0.0f, 0.5f + 0.5f * curtainWave), 3.4f);
    float fineFilament = 0.65f + 0.35f * n2.x;

    float auroraAlpha = horizonMask * curtainBand * fineFilament * (0.10f + 0.28f * fftRibbon + 0.16f * bloom);
    float3 auroraColor = aetherCosineAuroraPalette(
        fract(azimuthNorm + elevation * 0.35f - elapsed * 0.025f),
        bloom + fftRibbon * 0.5f
    );

    return float4(auroraColor * auroraAlpha, auroraAlpha * 0.55f);
}

#endif
