// MARK: - FILE: FDTDWaveguideKernels.metal

#include <metal_stdlib>
using namespace metal;

// MARK: - 1. 96-Byte Scalar-Aligned Host/GPU Uniform Contract (2D & 3D FDTD + Visualizer)

struct FDTDWavefieldUniforms {
    uint gridWidth;
    uint gridHeight;
    uint gridDepth;
    uint pmlThickness;
    uint boundaryMode;       // 0 = Absorbing Cubic PML, 1 = Rigid Dirichlet, 2 = Rigid Neumann
    uint stepIndex;
    float lambdaSq;          // (c * dt / h)^2
    float muSq;              // (kappa * dt / h^2)^2
    float sigma0Dt;          // sigma_0 * dt
    float viscousCoeff;      // 2 * sigma_1 * dt / h^2
    float pmlSigmaMaxDt;     // sigma_max * dt
    float nonlinearGamma;    // Cubic Berger tension gamma_nl
    float dtSquared;         // dt^2
    float sourceX;
    float sourceY;
    float sourceZ;
    float sourceValue;
    float sourceSigmaCells;
    float micLeftX;
    float micLeftY;
    float micRightX;
    float micRightY;
    float displayGain;
    float accentHue;
};

// Obstacle cell codes in `obstacleMask`:
// 0 = Free acoustic medium
// 1 = Dirichlet pressure-release / absorbing pin (p = 0)
// 2 = Neumann rigid reflecting wall / diffraction barrier / Helmholtz wall (dp/dn = 0)
// 3 = Refractive acoustic metamaterial lens cell (uses `relativeSpeedSq` buffer)

namespace aether_fdtd_core {
    inline int linearIndex2D(int x, int y, int w) {
        return y * w + x;
    }

    inline int linearIndex3D(int x, int y, int z, int w, int h) {
        return (z * h + y) * w + x;
    }

    // Samples neighbor pressure with exact Dirichlet (p=0) and Neumann (mirror centerVal) interior obstacle support.
    inline float fetchCell2D(
        device const float* field,
        device const uchar* obstacleMask,
        int nx,
        int ny,
        int w,
        int h,
        uint boundaryMode,
        float centerVal
    ) {
        if (nx < 0 || nx >= w || ny < 0 || ny >= h) {
            if (boundaryMode == 2u) {
                int cx = clamp(nx, 0, w - 1);
                int cy = clamp(ny, 0, h - 1);
                return field[linearIndex2D(cx, cy, w)];
            }
            return 0.0f;
        }
        int idx = linearIndex2D(nx, ny, w);
        uchar mask = obstacleMask[idx];
        if (mask == 1u) {
            return 0.0f;
        } else if (mask == 2u) {
            return centerVal;
        }
        return field[idx];
    }

    inline float fetchCell3D(
        device const float* field,
        device const uchar* obstacleMask,
        int nx,
        int ny,
        int nz,
        int w,
        int h,
        int d,
        uint boundaryMode,
        float centerVal
    ) {
        if (nx < 0 || nx >= w || ny < 0 || ny >= h || nz < 0 || nz >= d) {
            if (boundaryMode == 2u) {
                int cx = clamp(nx, 0, w - 1);
                int cy = clamp(ny, 0, h - 1);
                int cz = clamp(nz, 0, d - 1);
                return field[linearIndex3D(cx, cy, cz, w, h)];
            }
            return 0.0f;
        }
        int idx = linearIndex3D(nx, ny, nz, w, h);
        uchar mask = obstacleMask[idx];
        if (mask == 1u) {
            return 0.0f;
        } else if (mask == 2u) {
            return centerVal;
        }
        return field[idx];
    }

    // Isotropic 9-point compact 2D Laplacian stencil L_h(p):
    // Axial weight = 2/3, Diagonal weight = 1/6, Center weight = -10/3 (4th-order isotropic dispersion accuracy).
    inline float compactLaplacian9Pt2D(
        device const float* field,
        device const uchar* obstacleMask,
        int x,
        int y,
        int w,
        int h,
        uint boundaryMode
    ) {
        int idx = linearIndex2D(x, y, w);
        uchar selfMask = obstacleMask[idx];
        if (selfMask == 1u || selfMask == 2u) {
            return 0.0f;
        }
        float c = field[idx];

        float axial = fetchCell2D(field, obstacleMask, x - 1, y, w, h, boundaryMode, c)
                    + fetchCell2D(field, obstacleMask, x + 1, y, w, h, boundaryMode, c)
                    + fetchCell2D(field, obstacleMask, x, y - 1, w, h, boundaryMode, c)
                    + fetchCell2D(field, obstacleMask, x, y + 1, w, h, boundaryMode, c);

        float diag  = fetchCell2D(field, obstacleMask, x - 1, y - 1, w, h, boundaryMode, c)
                    + fetchCell2D(field, obstacleMask, x + 1, y - 1, w, h, boundaryMode, c)
                    + fetchCell2D(field, obstacleMask, x - 1, y + 1, w, h, boundaryMode, c)
                    + fetchCell2D(field, obstacleMask, x + 1, y + 1, w, h, boundaryMode, c);

        return (2.0f / 3.0f) * axial + (1.0f / 6.0f) * diag - (10.0f / 3.0f) * c;
    }

    // Iterated compact 2D biharmonic operator L_h^2(p) = L_h(L_h(p)) on the isotropic 9-point stencil.
    inline float compactBiharmonic2D(
        device const float* field,
        device const uchar* obstacleMask,
        int x,
        int y,
        int w,
        int h,
        uint boundaryMode
    ) {
        float lC = compactLaplacian9Pt2D(field, obstacleMask, x, y, w, h, boundaryMode);

        auto safeLap = [&](int nx, int ny) -> float {
            if (nx < 0 || nx >= w || ny < 0 || ny >= h) {
                return (boundaryMode == 2u) ? lC : 0.0f;
            }
            uchar m = obstacleMask[linearIndex2D(nx, ny, w)];
            if (m == 1u) return 0.0f;
            if (m == 2u) return lC;
            return compactLaplacian9Pt2D(field, obstacleMask, nx, ny, w, h, boundaryMode);
        };

        float axialL = safeLap(x - 1, y) + safeLap(x + 1, y) + safeLap(x, y - 1) + safeLap(x, y + 1);
        float diagL  = safeLap(x - 1, y - 1) + safeLap(x + 1, y - 1) + safeLap(x - 1, y + 1) + safeLap(x + 1, y + 1);
        return (2.0f / 3.0f) * axialL + (1.0f / 6.0f) * diagL - (10.0f / 3.0f) * lC;
    }

    // Isotropic 27-point Patra-Karttunen compact 3D Laplacian stencil L_h(p):
    // 6 face neighbors = 7/15, 12 edge neighbors = 1/10, 8 corner neighbors = 1/30, center = -64/15.
    inline float compactLaplacian27Pt3D(
        device const float* field,
        device const uchar* obstacleMask,
        int x,
        int y,
        int z,
        int w,
        int h,
        int d,
        uint boundaryMode
    ) {
        int idx = linearIndex3D(x, y, z, w, h);
        uchar selfMask = obstacleMask[idx];
        if (selfMask == 1u || selfMask == 2u) {
            return 0.0f;
        }
        float c = field[idx];

        float faces = 0.0f;
        float edges = 0.0f;
        float corners = 0.0f;

        for (int dz = -1; dz <= 1; ++dz) {
            for (int dy = -1; dy <= 1; ++dy) {
                for (int dx = -1; dx <= 1; ++dx) {
                    int manhattan = abs(dx) + abs(dy) + abs(dz);
                    if (manhattan == 0) continue;
                    float val = fetchCell3D(field, obstacleMask, x + dx, y + dy, z + dz, w, h, d, boundaryMode, c);
                    if (manhattan == 1) {
                        faces += val;
                    } else if (manhattan == 2) {
                        edges += val;
                    } else {
                        corners += val;
                    }
                }
            }
        }

        return (7.0f / 15.0f) * faces + (1.0f / 10.0f) * edges + (1.0f / 30.0f) * corners - (64.0f / 15.0f) * c;
    }

    inline float compactBiharmonic3D(
        device const float* field,
        device const uchar* obstacleMask,
        int x,
        int y,
        int z,
        int w,
        int h,
        int d,
        uint boundaryMode
    ) {
        float lC = compactLaplacian27Pt3D(field, obstacleMask, x, y, z, w, h, d, boundaryMode);
        float faces = 0.0f;
        float edges = 0.0f;
        float corners = 0.0f;

        for (int dz = -1; dz <= 1; ++dz) {
            for (int dy = -1; dy <= 1; ++dy) {
                for (int dx = -1; dx <= 1; ++dx) {
                    int manhattan = abs(dx) + abs(dy) + abs(dz);
                    if (manhattan == 0) continue;
                    int nx = x + dx;
                    int ny = y + dy;
                    int nz = z + dz;
                    float lVal = 0.0f;
                    if (nx < 0 || nx >= w || ny < 0 || ny >= h || nz < 0 || nz >= d) {
                        lVal = (boundaryMode == 2u) ? lC : 0.0f;
                    } else {
                        uchar m = obstacleMask[linearIndex3D(nx, ny, nz, w, h)];
                        if (m == 1u) lVal = 0.0f;
                        else if (m == 2u) lVal = lC;
                        else lVal = compactLaplacian27Pt3D(field, obstacleMask, nx, ny, nz, w, h, d, boundaryMode);
                    }
                    if (manhattan == 1) faces += lVal;
                    else if (manhattan == 2) edges += lVal;
                    else corners += lVal;
                }
            }
        }
        return (7.0f / 15.0f) * faces + (1.0f / 10.0f) * edges + (1.0f / 30.0f) * corners - (64.0f / 15.0f) * lC;
    }

    // Polynomial cubic Perfectly Matched Layer sponge damping profile: sigma_pml(d) = sigma_max * (d / L_pml)^3
    inline float cubicPMLProfile(int x, int y, int z, int w, int h, int d, int pmlWidth, float sigmaMaxDt) {
        if (pmlWidth <= 0 || sigmaMaxDt <= 0.0f) {
            return 0.0f;
        }
        float total = 0.0f;
        int distX = min(x, w - 1 - x);
        if (distX < pmlWidth) {
            float ux = float(pmlWidth - distX) / float(pmlWidth);
            total += sigmaMaxDt * (ux * ux * ux);
        }
        int distY = min(y, h - 1 - y);
        if (distY < pmlWidth) {
            float uy = float(pmlWidth - distY) / float(pmlWidth);
            total += sigmaMaxDt * (uy * uy * uy);
        }
        if (d > 1) {
            int distZ = min(z, d - 1 - z);
            if (distZ < pmlWidth) {
                float uz = float(pmlWidth - distZ) / float(pmlWidth);
                total += sigmaMaxDt * (uz * uz * uz);
            }
        }
        return total;
    }

    // Von Neumann CFL Stability Enforcer: lambda^2 + 4 * mu^2 <= 1/D - 2 * sigma_1 * dt / h^2
    inline void enforceCFLBound(
        int dimension,
        float rawLambdaSq,
        float rawMuSq,
        float rawViscous,
        thread float& safeLambdaSq,
        thread float& safeMuSq,
        thread float& safeViscous
    ) {
        float invD = 1.0f / float(max(1, dimension));
        safeViscous = clamp(rawViscous, 0.0f, invD * 0.45f);
        float cflCeiling = max(0.005f, (invD - safeViscous) * 0.96f);

        float clampedL = max(0.0f, rawLambdaSq);
        float clampedM = max(0.0f, rawMuSq);
        float lhs = clampedL + 4.0f * clampedM;
        if (lhs > cflCeiling) {
            float scale = cflCeiling / max(lhs, 1.0e-9f);
            clampedL *= scale;
            clampedM *= scale;
        }
        safeLambdaSq = clampedL;
        safeMuSq = clampedM;
    }
}

// MARK: - 2. Primary 2D/3D Visco-Thermal Dispersive Biharmonic FDTD Compute Kernel

kernel void aetherStepFDTDWavefield(
    device const float* pCurr                    [[buffer(0)]],
    device const float* pPrev                    [[buffer(1)]],
    device float* pNext                          [[buffer(2)]],
    device const uchar* obstacleMask             [[buffer(3)]],
    device const float* relativeSpeedSq          [[buffer(4)]],
    constant FDTDWavefieldUniforms& uniforms     [[buffer(5)]],
    uint3 gid                                    [[thread_position_in_grid]]
) {
    int w = int(uniforms.gridWidth);
    int h = int(uniforms.gridHeight);
    int d = max(1, int(uniforms.gridDepth));
    int x = int(gid.x);
    int y = int(gid.y);
    int z = int(gid.z);

    if (x >= w || y >= h || z >= d) {
        return;
    }

    bool is3D = (d > 1);
    int idx = is3D ? aether_fdtd_core::linearIndex3D(x, y, z, w, h)
                   : aether_fdtd_core::linearIndex2D(x, y, w);

    uchar mask = obstacleMask[idx];
    if (mask == 1u || mask == 2u) {
        pNext[idx] = 0.0f;
        return;
    }

    // Outer Dirichlet / PML termination rim
    bool isOuterBorder = (x == 0 || y == 0 || x == w - 1 || y == h - 1)
                      || (is3D && (z == 0 || z == d - 1));
    if (isOuterBorder && uniforms.boundaryMode != 2u) {
        pNext[idx] = 0.0f;
        return;
    }

    int dim = is3D ? 3 : 2;
    float safeLambdaSq = 0.0f;
    float safeMuSq = 0.0f;
    float safeViscous = 0.0f;
    aether_fdtd_core::enforceCFLBound(
        dim,
        uniforms.lambdaSq,
        uniforms.muSq,
        uniforms.viscousCoeff,
        safeLambdaSq,
        safeMuSq,
        safeViscous
    );

    float p0 = pCurr[idx];
    float pOld = pPrev[idx];

    float lapCurr = 0.0f;
    float lapPrev = 0.0f;
    float biharm = 0.0f;

    if (is3D) {
        lapCurr = aether_fdtd_core::compactLaplacian27Pt3D(pCurr, obstacleMask, x, y, z, w, h, d, uniforms.boundaryMode);
        lapPrev = (safeViscous > 0.0f)
            ? aether_fdtd_core::compactLaplacian27Pt3D(pPrev, obstacleMask, x, y, z, w, h, d, uniforms.boundaryMode)
            : 0.0f;
        biharm = (safeMuSq > 0.0f)
            ? aether_fdtd_core::compactBiharmonic3D(pCurr, obstacleMask, x, y, z, w, h, d, uniforms.boundaryMode)
            : 0.0f;
    } else {
        lapCurr = aether_fdtd_core::compactLaplacian9Pt2D(pCurr, obstacleMask, x, y, w, h, uniforms.boundaryMode);
        lapPrev = (safeViscous > 0.0f)
            ? aether_fdtd_core::compactLaplacian9Pt2D(pPrev, obstacleMask, x, y, w, h, uniforms.boundaryMode)
            : 0.0f;
        biharm = (safeMuSq > 0.0f)
            ? aether_fdtd_core::compactBiharmonic2D(pCurr, obstacleMask, x, y, w, h, uniforms.boundaryMode)
            : 0.0f;
    }

    // Local refractive metamaterial speed + Berger cubic nonlinear gradient tension
    float speedFactor = clamp(relativeSpeedSq[idx], 0.12f, 1.35f);
    float gradX = 0.5f * (
        aether_fdtd_core::fetchCell2D(pCurr, obstacleMask, min(x + 1, w - 1), y, w, h, uniforms.boundaryMode, p0)
        - aether_fdtd_core::fetchCell2D(pCurr, obstacleMask, max(x - 1, 0), y, w, h, uniforms.boundaryMode, p0)
    );
    float gradY = 0.5f * (
        aether_fdtd_core::fetchCell2D(pCurr, obstacleMask, x, min(y + 1, h - 1), w, h, uniforms.boundaryMode, p0)
        - aether_fdtd_core::fetchCell2D(pCurr, obstacleMask, x, max(y - 1, 0), w, h, uniforms.boundaryMode, p0)
    );
    float gradNormSq = min(gradX * gradX + gradY * gradY, 2.0f);
    float nlTension = 1.0f + max(0.0f, uniforms.nonlinearGamma) * gradNormSq;

    float invD = 1.0f / float(dim);
    float maxLocalLambdaSq = max(0.0f, (invD - safeViscous) * 0.96f - 4.0f * safeMuSq);
    float effLambdaSq = min(safeLambdaSq * speedFactor * nlTension, maxLocalLambdaSq);

    // Spatial Gaussian acoustic excitation f_exc(x, t)
    float forceTerm = 0.0f;
    if (abs(uniforms.sourceValue) > 1.0e-7f) {
        float dx = float(x) - uniforms.sourceX;
        float dy = float(y) - uniforms.sourceY;
        float dz = is3D ? (float(z) - uniforms.sourceZ) : 0.0f;
        float invTwoSigmaSq = 1.0f / max(0.35f, 2.0f * uniforms.sourceSigmaCells * uniforms.sourceSigmaCells);
        float distSq = dx * dx + dy * dy + dz * dz;
        if (distSq <= 18.0f * uniforms.sourceSigmaCells * uniforms.sourceSigmaCells) {
            forceTerm = uniforms.dtSquared * uniforms.sourceValue * exp(-distSq * invTwoSigmaSq);
        }
    }

    float pmlSigma = (uniforms.boundaryMode == 0u)
        ? aether_fdtd_core::cubicPMLProfile(x, y, z, w, h, d, int(uniforms.pmlThickness), uniforms.pmlSigmaMaxDt)
        : 0.0f;
    float sigmaTotalDt = max(0.0f, uniforms.sigma0Dt + pmlSigma);
    float invDenom = 1.0f / (1.0f + sigmaTotalDt);

    float nextPressure = invDenom * (
        2.0f * p0
        - (1.0f - sigmaTotalDt) * pOld
        + effLambdaSq * lapCurr
        + safeViscous * (lapCurr - lapPrev)
        - safeMuSq * biharm
        + forceTerm
    );

    pNext[idx] = isfinite(nextPressure) ? clamp(nextPressure, -16.0f, 16.0f) : 0.0f;
}

// MARK: - 3. Legacy Compatibility Compute Entry Point

struct FDTDWaveguideUniforms {
    uint gridWidth;
    uint gridHeight;
    uint pmlThickness;
    uint enablePML;
    float lambdaSq;
    float muSq;
    float sigma0Dt;
    float viscousTerm;
    float pmlMaxSigma;
    float nonlinearTension;
    float2 reservedPadding;
};

kernel void aetherStepFDTDWaveguide2D(
    device const float* pCurr                  [[buffer(0)]],
    device const float* pPrev                  [[buffer(1)]],
    device float* pNext                        [[buffer(2)]],
    device const uchar* obstacleMask           [[buffer(3)]],
    device const float* relativeWaveSpeedSq    [[buffer(4)]],
    constant FDTDWaveguideUniforms& uniforms   [[buffer(5)]],
    uint2 gid                                  [[thread_position_in_grid]]
) {
    int w = int(uniforms.gridWidth);
    int h = int(uniforms.gridHeight);
    int x = int(gid.x);
    int y = int(gid.y);
    if (x >= w || y >= h) return;

    int idx = y * w + x;
    if (obstacleMask[idx] == 1u || obstacleMask[idx] == 2u || x == 0 || y == 0 || x == w - 1 || y == h - 1) {
        pNext[idx] = 0.0f;
        return;
    }

    float safeL = 0.0f;
    float safeM = 0.0f;
    float safeV = 0.0f;
    aether_fdtd_core::enforceCFLBound(2, uniforms.lambdaSq, uniforms.muSq, uniforms.viscousTerm, safeL, safeM, safeV);

    float p0 = pCurr[idx];
    float pOld = pPrev[idx];
    float lapC = aether_fdtd_core::compactLaplacian9Pt2D(pCurr, obstacleMask, x, y, w, h, 0u);
    float lapP = (safeV > 0.0f) ? aether_fdtd_core::compactLaplacian9Pt2D(pPrev, obstacleMask, x, y, w, h, 0u) : 0.0f;
    float bih  = (safeM > 0.0f) ? aether_fdtd_core::compactBiharmonic2D(pCurr, obstacleMask, x, y, w, h, 0u) : 0.0f;

    float lens = clamp(relativeWaveSpeedSq[idx], 0.12f, 1.35f);
    float nl = 1.0f + max(0.0f, uniforms.nonlinearTension) * min(p0 * p0, 1.0f);
    float effL = min(safeL * lens * nl, max(0.0f, (0.5f - safeV) * 0.96f - 4.0f * safeM));
    float pml = (uniforms.enablePML != 0u)
        ? aether_fdtd_core::cubicPMLProfile(x, y, 0, w, h, 1, int(uniforms.pmlThickness), uniforms.pmlMaxSigma)
        : 0.0f;
    float loss = max(0.0f, uniforms.sigma0Dt + pml);
    float nextVal = (2.0f * p0 - (1.0f - loss) * pOld + effL * lapC + safeV * (lapC - lapP) - safeM * bih) / (1.0f + loss);
    pNext[idx] = isfinite(nextVal) ? clamp(nextVal, -16.0f, 16.0f) : 0.0f;
}

// MARK: - 4. Real-Time Wavefield Visualizer Shaders (`+p` Cyan, `-p` Magenta, Gold Obstacles)

struct FDTDVisualizerVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex FDTDVisualizerVertexOut aetherFDTDQuadVertex(uint vertexID [[vertex_id]]) {
    constexpr float2 positions[4] = {
        float2(-1.0f, -1.0f),
        float2( 1.0f, -1.0f),
        float2(-1.0f,  1.0f),
        float2( 1.0f,  1.0f)
    };
    constexpr float2 uvs[4] = {
        float2(0.0f, 1.0f),
        float2(1.0f, 1.0f),
        float2(0.0f, 0.0f),
        float2(1.0f, 0.0f)
    };

    FDTDVisualizerVertexOut out;
    out.position = float4(positions[min(vertexID, 3u)], 0.0f, 1.0f);
    out.uv = uvs[min(vertexID, 3u)];
    return out;
}

fragment float4 aetherRenderFDTDWavefield(
    FDTDVisualizerVertexOut in                   [[stage_in]],
    device const float* pCurr                    [[buffer(0)]],
    device const uchar* obstacleMask             [[buffer(1)]],
    device const float* relativeSpeedSq          [[buffer(2)]],
    constant FDTDWavefieldUniforms& uniforms     [[buffer(3)]]
) {
    int w = max(2, int(uniforms.gridWidth));
    int h = max(2, int(uniforms.gridHeight));

    float gx = clamp(in.uv.x * float(w - 1), 0.0f, float(w - 1));
    float gy = clamp(in.uv.y * float(h - 1), 0.0f, float(h - 1));
    int x0 = min(int(floor(gx)), w - 2);
    int y0 = min(int(floor(gy)), h - 2);
    float fx = gx - float(x0);
    float fy = gy - float(y0);

    int i00 = y0 * w + x0;
    int i10 = i00 + 1;
    int i01 = (y0 + 1) * w + x0;
    int i11 = i01 + 1;

    uchar nearestMask = obstacleMask[int(round(gy)) * w + int(round(gx))];
    if (nearestMask == 1u || nearestMask == 2u) {
        // Brushed gold diffraction barrier / Helmholtz obstacle cell
        float3 goldBase = float3(0.92f, 0.74f, 0.24f);
        float bevel = 0.85f + 0.15f * sin((gx + gy) * 1.4f);
        return float4(goldBase * bevel, 1.0f);
    }

    float pTop = mix(pCurr[i00], pCurr[i10], fx);
    float pBot = mix(pCurr[i01], pCurr[i11], fx);
    float p = mix(pTop, pBot, fy) * max(0.25f, uniforms.displayGain);

    float posMag = tanh(max(0.0f, p));
    float negMag = tanh(max(0.0f, -p));

    float3 bgDeep = float3(0.025f, 0.032f, 0.068f);
    float3 cyanCrest = float3(0.08f, 0.92f, 1.00f);
    float3 magentaTrough = float3(0.96f, 0.16f, 0.76f);

    float3 color = bgDeep + cyanCrest * posMag + magentaTrough * negMag;
    color += float3(0.45f, 0.55f, 0.65f) * pow(max(posMag, negMag), 3.0f);

    // Subtle refractive lens tint
    float relSpeed = relativeSpeedSq[int(round(gy)) * w + int(round(gx))];
    if (abs(relSpeed - 1.0f) > 0.03f) {
        color = mix(color, float3(0.98f, 0.68f, 0.22f), 0.20f);
    }

    // PML boundary guide shading
    int pml = int(uniforms.pmlThickness);
    int edgeDist = min(min(int(gx), w - 1 - int(gx)), min(int(gy), h - 1 - int(gy)));
    if (uniforms.boundaryMode == 0u && edgeDist < pml) {
        float spongeRatio = float(pml - edgeDist) / float(max(1, pml));
        color *= (1.0f - 0.35f * spongeRatio * spongeRatio);
    }

    // Highlight virtual binaural microphone probes (Left = cyan-white ring, Right = coral-gold ring)
    float distMicL = length(float2(gx - uniforms.micLeftX, gy - uniforms.micLeftY));
    float distMicR = length(float2(gx - uniforms.micRightX, gy - uniforms.micRightY));
    if (abs(distMicL - 2.1f) < 0.65f) {
        color = mix(color, float3(0.65f, 1.0f, 1.0f), 0.88f);
    }
    if (abs(distMicR - 2.1f) < 0.65f) {
        color = mix(color, float3(1.0f, 0.72f, 0.36f), 0.88f);
    }

    return float4(clamp(color, 0.0f, 1.0f), 1.0f);
}
