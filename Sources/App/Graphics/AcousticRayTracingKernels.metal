// MARK: - FILE: AcousticRayTracingKernels.metal

#include <metal_stdlib>
#include <metal_raytracing>
using namespace metal;
using namespace metal::raytracing;

// 16-byte aligned GPU structures for C/Metal/Swift layout parity across Apple Silicon targets

struct AcousticMaterialGPU {
    float4 absorption;   // 4-band alpha in [0.01, 0.95] at (125, 500, 2000, 8000 Hz)
    float4 scattering;   // 4-band scattering s in [0.05, 0.95] at (125, 500, 2000, 8000 Hz)
};

struct AcousticTriangleMetaGPU {
    float4 normalAndArea;   // xyz = unit inward/surface normal, w = triangle area (m^2)
    uint4 indicesAndMat;    // x,y,z = vertex indices, w = material index
};

struct AcousticInstanceMetaGPU {
    uint4 offsets;          // x = triangleMetaOffset, y = materialOverridePlusOne, z,w = reserved
};

struct AcousticTraceUniformsGPU {
    float4 sourcePosAndSpeed;       // xyz = source 3D position, w = speed of sound c (343.0 m/s)
    float4 listenerPosAndRadius;    // xyz = listener head 3D position, w = listener capture sphere radius
    float4 listenerRightAndMaxDist; // xyz = listener head +X right basis, w = max trace distance
    float4 listenerUpAndTimeBinDt;  // xyz = listener head +Y up basis, w = histogram time bin dt (s)
    float4 listenerFwdAndAirScale;  // xyz = listener head +Z forward basis, w = air absorption multiplier
    float4 airAttenuationPerMeter;  // 4-band atmospheric attenuation m_b (Nepers/m)
    uint4 counts;                   // x = rayCount (4096), y = maxBounces (16), z = timeBinCount, w = dirSectorCount
    uint4 limits;                   // x = maxRecordedSegments, y = triangleCount, z = materialCount, w = seedSalt
};

struct AcousticRaySegmentGPU {
    float4 startAndBounce;          // xyz = world start, w = bounce index
    float4 endAndDominantBand;      // xyz = world end, w = dominant octave band [0..3]
    float4 bandEnergy;              // 4-band remaining ray energy
};

namespace aether_hw_acoustics {
    inline void atomicAddFloat(device atomic_uint* addr, float val) {
        if (val <= 0.0f || !isfinite(val)) {
            return;
        }
        uint expected = atomic_load_explicit(addr, memory_order_relaxed);
        while (true) {
            float current = as_type<float>(expected);
            float nextVal = current + val;
            uint desired = as_type<uint>(nextVal);
            if (atomic_compare_exchange_weak_explicit(
                    addr,
                    &expected,
                    desired,
                    memory_order_relaxed,
                    memory_order_relaxed)) {
                break;
            }
        }
    }

    inline float3 fibonacciSpherePoint(uint rayIndex, uint totalRays) {
        const float goldenAngle = 2.39996322972865332f;
        float n = max(float(totalRays), 1.0f);
        float y = 1.0f - 2.0f * (float(rayIndex) + 0.5f) / n;
        float radial = sqrt(max(0.0f, 1.0f - y * y));
        float theta = goldenAngle * float(rayIndex);
        return normalize(float3(radial * cos(theta), y, radial * sin(theta)));
    }

    // Stateless radical inverse base-2 (Van der Corput / Sobol dim 0)
    inline float radicalInverseBase2(uint bits) {
        bits = (bits << 16u) | (bits >> 16u);
        bits = ((bits & 0x55555555u) << 1u) | ((bits & 0xAAAAAAAAu) >> 1u);
        bits = ((bits & 0x33333333u) << 2u) | ((bits & 0xCCCCCCCCu) >> 2u);
        bits = ((bits & 0x0F0F0F0Fu) << 4u) | ((bits & 0xF0F0F0F0u) >> 4u);
        bits = ((bits & 0x00FF00FFu) << 8u) | ((bits & 0xFF00FF00u) >> 8u);
        return float(bits) * 2.3283064365386963e-10f;
    }

    // Stateless radical inverse base-3 (Halton dim 1)
    inline float radicalInverseBase3(uint n) {
        float invBase = 1.0f / 3.0f;
        float factor = invBase;
        float result = 0.0f;
        uint current = n;
        while (current > 0u) {
            uint digit = current % 3u;
            result += float(digit) * factor;
            current /= 3u;
            factor *= invBase;
        }
        return result;
    }

    // Stateless Sobol direction generator (dim 2) for Russian Roulette
    inline float sobolDim2(uint index) {
        uint v = 0x80000000u;
        uint r = 0u;
        uint i = index;
        while (i != 0u) {
            if ((i & 1u) != 0u) {
                r ^= v;
            }
            i >>= 1u;
            v ^= (v >> 1u);
        }
        return float(r) * 2.3283064365386963e-10f;
    }

    inline float3 qmcSample3D(uint rayIndex, uint bounceIndex, uint salt) {
        uint seqIndex = (rayIndex + 1u) * 53u + bounceIndex * 1009u + (salt & 0xFFFFu);
        float u1 = fract(radicalInverseBase2(seqIndex) + float(rayIndex & 2047u) * 0.00048828125f);
        float u2 = fract(radicalInverseBase3(seqIndex) + float(bounceIndex) * 0.61803398875f);
        float u3 = fract(sobolDim2(seqIndex ^ 0x9E3779B9u));
        return float3(u1, u2, u3);
    }

    inline void makeOrthonormalBasis(float3 n, thread float3& t, thread float3& b) {
        if (n.z < -0.99999f) {
            t = float3(0.0f, -1.0f, 0.0f);
            b = float3(-1.0f, 0.0f, 0.0f);
            return;
        }
        float a = 1.0f / (1.0f + n.z);
        float d = -n.x * n.y * a;
        t = normalize(float3(1.0f - n.x * n.x * a, d, -n.x));
        b = normalize(float3(d, 1.0f - n.y * n.y * a, -n.y));
    }

    inline float3 sampleCosineHemisphere(float2 u, float3 normal) {
        float phi = 6.28318530718f * u.x;
        float cosTheta = sqrt(clamp(1.0f - u.y, 0.0f, 1.0f));
        float sinTheta = sqrt(clamp(u.y, 0.0f, 1.0f));
        float3 t, b;
        makeOrthonormalBasis(normal, t, b);
        return normalize(t * (cos(phi) * sinTheta) + b * (sin(phi) * sinTheta) + normal * cosTheta);
    }

    // Maps incident vector in listener head frame (+X right, +Y up, +Z forward) to spherical sector [0 .. dirSectorCount-1]
    inline uint sphericalDirectionSector(
        float3 incomingToListenerWorld,
        float3 headRight,
        float3 headUp,
        float3 headForward,
        uint dirSectorCount
    ) {
        if (dirSectorCount <= 1u) {
            return 0u;
        }
        float3 localVec = normalize(float3(
            dot(incomingToListenerWorld, headRight),
            dot(incomingToListenerWorld, headUp),
            dot(incomingToListenerWorld, headForward)
        ));
        // Azimuth theta in [-pi, pi], Elevation phi in [-pi/2, pi/2]
        float azimuth = atan2(localVec.x, localVec.z);
        float elevation = asin(clamp(localVec.y, -1.0f, 1.0f));

        uint azBins = max(1u, dirSectorCount / 2u);
        uint elBins = max(1u, dirSectorCount / azBins);

        float azNorm = clamp((azimuth + 3.14159265359f) * (1.0f / 6.28318530718f), 0.0f, 0.99999f);
        float elNorm = clamp((elevation + 1.57079632679f) * (1.0f / 3.14159265359f), 0.0f, 0.99999f);

        uint azIdx = min(uint(azNorm * float(azBins)), azBins - 1u);
        uint elIdx = min(uint(elNorm * float(elBins)), elBins - 1u);
        return min(elIdx * azBins + azIdx, dirSectorCount - 1u);
    }

    inline void accumulateDirectionalEDH(
        device atomic_uint* edhHistogram,
        uint timeBinCount,
        uint dirSectorCount,
        float timeBinDt,
        float propagationTimeSec,
        uint sectorIndex,
        float4 bandContribution
    ) {
        if (timeBinCount == 0u || dirSectorCount == 0u || timeBinDt <= 0.0f) {
            return;
        }
        uint tBin = min(uint(max(0.0f, propagationTimeSec) / timeBinDt), timeBinCount - 1u);
        uint sBin = min(sectorIndex, dirSectorCount - 1u);
        uint baseOffset = (sBin * timeBinCount + tBin) * 4u;

        atomicAddFloat(&edhHistogram[baseOffset + 0u], bandContribution.x);
        atomicAddFloat(&edhHistogram[baseOffset + 1u], bandContribution.y);
        atomicAddFloat(&edhHistogram[baseOffset + 2u], bandContribution.z);
        atomicAddFloat(&edhHistogram[baseOffset + 3u], bandContribution.w);
    }
}

// MARK: - Hardware-Accelerated 3D Acoustic Ray-Tracing Compute Kernel (4096 Fibonacci Rays x 16 Bounces)

kernel void aetherTraceAcousticRays(
    instance_acceleration_structure instanceAccel              [[buffer(0)]],
    device const AcousticTriangleMetaGPU* triangleMetas        [[buffer(1)]],
    device const AcousticMaterialGPU* materials                [[buffer(2)]],
    device const AcousticInstanceMetaGPU* instanceMetas        [[buffer(3)]],
    constant AcousticTraceUniformsGPU& uniforms                [[buffer(4)]],
    device atomic_uint* edhHistogram                           [[buffer(5)]],
    device AcousticRaySegmentGPU* recordedSegments             [[buffer(6)]],
    device atomic_uint* segmentWriteCounter                    [[buffer(7)]],
    device atomic_uint* leakedRayCounter                       [[buffer(8)]],
    uint tid                                                   [[thread_position_in_grid]]
) {
    const uint totalRays = uniforms.counts.x;
    if (tid >= totalRays) {
        return;
    }

    const uint maxBounces = min(uniforms.counts.y, 16u);
    const uint timeBinCount = uniforms.counts.z;
    const uint dirSectorCount = max(uniforms.counts.w, 1u);
    const uint maxSegments = uniforms.limits.x;
    const uint totalTriangles = max(uniforms.limits.y, 1u);
    const uint totalMaterials = max(uniforms.limits.z, 1u);
    const uint seedSalt = uniforms.limits.w;

    const float3 sourcePos = uniforms.sourcePosAndSpeed.xyz;
    const float speedOfSound = max(uniforms.sourcePosAndSpeed.w, 300.0f);
    const float invSpeed = 1.0f / speedOfSound;

    const float3 listenerPos = uniforms.listenerPosAndRadius.xyz;
    const float listenerRadius = max(uniforms.listenerPosAndRadius.w, 0.08f);
    const float maxTraceDist = max(uniforms.listenerRightAndMaxDist.w, 100.0f);
    const float timeBinDt = max(uniforms.listenerUpAndTimeBinDt.w, 0.0005f);

    const float3 headRight = normalize(uniforms.listenerRightAndMaxDist.xyz);
    const float3 headUp = normalize(uniforms.listenerUpAndTimeBinDt.xyz);
    const float3 headFwd = normalize(uniforms.listenerFwdAndAirScale.xyz);
    const float4 airM = uniforms.airAttenuationPerMeter * max(uniforms.listenerFwdAndAirScale.w, 0.0f);

    intersector<triangle_data, instancing> primaryIntersector;
    primaryIntersector.assume_geometry_type(geometry_type::triangle);
    primaryIntersector.force_opacity(forced_opacity::opaque);

    intersector<triangle_data, instancing> shadowIntersector;
    shadowIntersector.assume_geometry_type(geometry_type::triangle);
    shadowIntersector.force_opacity(forced_opacity::opaque);
    shadowIntersector.accept_any_intersection(true);

    // Direct sound line-of-sight shadow ray on ray 0
    if (tid == 0u) {
        float3 toListener = listenerPos - sourcePos;
        float directDist = length(toListener);
        if (directDist > 1.0e-3f) {
            float3 directDir = toListener / directDist;
            ray directShadow;
            directShadow.origin = sourcePos;
            directShadow.direction = directDir;
            directShadow.min_distance = 1.0e-3f;
            directShadow.max_distance = max(1.0e-3f, directDist - listenerRadius * 0.35f);

            auto occ = shadowIntersector.intersect(directShadow, instanceAccel);
            if (occ.type == intersection_type::none) {
                float invSq = 1.0f / max(0.25f, directDist * directDist);
                float4 directAir = exp(-airM * directDist);
                uint directSector = aether_hw_acoustics::sphericalDirectionSector(
                    -directDir,
                    headRight,
                    headUp,
                    headFwd,
                    dirSectorCount
                );
                aether_hw_acoustics::accumulateDirectionalEDH(
                    edhHistogram,
                    timeBinCount,
                    dirSectorCount,
                    timeBinDt,
                    directDist * invSpeed,
                    directSector,
                    directAir * invSq * 0.35f
                );
            }
        }
    }

    float3 rayOrigin = sourcePos;
    float3 rayDir = aether_hw_acoustics::fibonacciSpherePoint(tid, totalRays);
    float4 rayEnergy = float4(1.0f / float(totalRays));
    float cumulativeDistance = 0.0f;

    for (uint bounce = 0u; bounce < maxBounces; ++bounce) {
        ray r;
        r.origin = rayOrigin;
        r.direction = rayDir;
        r.min_distance = 1.0e-4f;
        r.max_distance = maxTraceDist;

        auto hit = primaryIntersector.intersect(r, instanceAccel);
        if (hit.type == intersection_type::none) {
            atomic_fetch_add_explicit(leakedRayCounter, 1u, memory_order_relaxed);
            break;
        }

        float segDist = max(hit.distance, 1.0e-4f);
        float3 hitPos = rayOrigin + rayDir * segDist;
        cumulativeDistance += segDist;

        // Atmospheric attenuation along segment
        rayEnergy *= exp(-airM * segDist);

        uint instID = hit.instance_id;
        AcousticInstanceMetaGPU instMeta = instanceMetas[instID];
        uint triIdx = min(instMeta.offsets.x + hit.primitive_id, totalTriangles - 1u);
        AcousticTriangleMetaGPU triMeta = triangleMetas[triIdx];

        uint matIdx = (instMeta.offsets.y > 0u)
            ? min(instMeta.offsets.y - 1u, totalMaterials - 1u)
            : min(triMeta.indicesAndMat.w, totalMaterials - 1u);
        AcousticMaterialGPU mat = materials[matIdx];

        // Transform object-space normal if instance transform rotated it (for orbiting satellites, normal from world or instance)
        float3 rawN = normalize(triMeta.normalAndArea.xyz);
        float3 hitNormal = (dot(rawN, rayDir) < 0.0f) ? rawN : -rawN;

        // Record sparse ray visualization segments for live 3D/2D UI projection
        if ((tid & 31u) == 0u && bounce < 6u && maxSegments > 0u) {
            uint slot = atomic_fetch_add_explicit(segmentWriteCounter, 1u, memory_order_relaxed);
            if (slot < maxSegments) {
                uint domBand = 0u;
                float maxB = rayEnergy.x;
                if (rayEnergy.y > maxB) { maxB = rayEnergy.y; domBand = 1u; }
                if (rayEnergy.z > maxB) { maxB = rayEnergy.z; domBand = 2u; }
                if (rayEnergy.w > maxB) { domBand = 3u; }

                AcousticRaySegmentGPU seg;
                seg.startAndBounce = float4(rayOrigin, float(bounce));
                seg.endAndDominantBand = float4(hitPos, float(domBand));
                seg.bandEnergy = rayEnergy * float(totalRays);
                recordedSegments[slot] = seg;
            }
        }

        // Frequency-dependent 4-band surface absorption: E <- E * (1 - alpha_b)
        float4 alpha = clamp(mat.absorption, float4(0.01f), float4(0.95f));
        float4 scatter = clamp(mat.scattering, float4(0.05f), float4(0.95f));
        rayEnergy *= (1.0f - alpha);

        float3 safeHitPos = hitPos + hitNormal * 1.5e-3f;

        // Next Event Estimation (Listener Sphere Shadow Ray)
        float3 toListener = listenerPos - safeHitPos;
        float distToListener = length(toListener);
        if (distToListener > 1.0e-3f) {
            float3 toListenerDir = toListener / distToListener;
            float cosListener = dot(hitNormal, toListenerDir);
            if (cosListener > 0.0f) {
                ray shadowRay;
                shadowRay.origin = safeHitPos;
                shadowRay.direction = toListenerDir;
                shadowRay.min_distance = 1.0e-4f;
                shadowRay.max_distance = max(1.0e-4f, distToListener - listenerRadius * 0.45f);

                auto occ = shadowIntersector.intersect(shadowRay, instanceAccel);
                if (occ.type == intersection_type::none) {
                    float dTotal = cumulativeDistance + distToListener;
                    float arrivalTime = dTotal * invSpeed;

                    float rSq = listenerRadius * listenerRadius;
                    float invSqSolidAngle = min(1.0f, rSq / max(rSq, distToListener * distToListener));
                    float3 specDir = rayDir - 2.0f * dot(rayDir, hitNormal) * hitNormal;
                    float specLobe = pow(max(0.0f, dot(specDir, toListenerDir)), 10.0f);

                    float4 brdf = scatter * (2.0f * cosListener) + (1.0f - scatter) * (specLobe * 5.0f);
                    float4 airNee = exp(-airM * distToListener);
                    float4 neeEnergy = rayEnergy * brdf * invSqSolidAngle * airNee;

                    // Incoming wave vector in listener's head frame points from bounce vertex -> listener inverted (towards source of reflection)
                    uint sector = aether_hw_acoustics::sphericalDirectionSector(
                        -toListenerDir,
                        headRight,
                        headUp,
                        headFwd,
                        dirSectorCount
                    );
                    aether_hw_acoustics::accumulateDirectionalEDH(
                        edhHistogram,
                        timeBinCount,
                        dirSectorCount,
                        timeBinDt,
                        arrivalTime,
                        sector,
                        neeEnergy
                    );
                }
            }
        }

        // Specular-to-Cosine-Hemisphere QMC bounce direction interpolation
        float3 qmc = aether_hw_acoustics::qmcSample3D(tid, bounce, seedSalt);
        float3 specReflect = normalize(rayDir - 2.0f * dot(rayDir, hitNormal) * hitNormal);
        float3 diffReflect = aether_hw_acoustics::sampleCosineHemisphere(qmc.xy, hitNormal);
        float meanScatter = 0.25f * (scatter.x + scatter.y + scatter.z + scatter.w);
        float3 nextDir = normalize(mix(specReflect, diffReflect, meanScatter));
        if (dot(nextDir, hitNormal) < 1.0e-3f) {
            nextDir = normalize(nextDir + hitNormal * (1.0e-2f - dot(nextDir, hitNormal)));
        }

        // Unbiased Russian Roulette termination after bounce 6
        if (bounce >= 6u) {
            float maxBand = max(max(rayEnergy.x, rayEnergy.y), max(rayEnergy.z, rayEnergy.w)) * float(totalRays);
            if (maxBand < 0.15f) {
                float survivalProb = clamp(maxBand / 0.15f, 0.05f, 0.95f);
                if (qmc.z >= survivalProb) {
                    break;
                }
                rayEnergy /= survivalProb;
            }
        }

        rayOrigin = safeHitPos;
        rayDir = nextDir;
    }
}
