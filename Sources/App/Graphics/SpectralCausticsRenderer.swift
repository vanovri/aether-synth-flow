// MARK: - FILE: SpectralCausticsRenderer.swift

import Foundation
import SwiftUI
import simd
#if canImport(Metal) && !os(watchOS)
import Metal
#endif

// MARK: - 0. 64-Byte Host/GPU Uniform Contract & Adaptive Frame-Time Quality Governor

/// Host-side mirror of `AcoustoOpticCausticUniforms` in `VolumetricCausticsKernels.metal` (`size == 64`, `stride == 64`, `alignment == 8`).
public struct AcoustoOpticCausticUniforms: Sendable, Equatable {
    public static let expectedByteStride: Int = 64

    public var gridWidth: UInt32
    public var gridHeight: UInt32
    public var photonCount: UInt32
    public var integrationSteps: UInt32
    public var baseRefractiveIndex: Float
    public var cauchyDispersionB: Float
    public var acoustoOpticKappa: Float
    public var anisotropyG: Float
    public var stepSizeCells: Float
    public var photonEnergyScale: Float
    public var lightDirectionXY: SIMD2<Float>
    public var frameSeed: UInt32
    public var slabDepthCells: Float
    public var emaAlpha: Float
    public var toneMapCompression: Float

    public init(
        gridWidth: UInt32 = 48,
        gridHeight: UInt32 = 48,
        photonCount: UInt32 = 16_384,
        integrationSteps: UInt32 = 24,
        baseRefractiveIndex: Float = 1.333,
        cauchyDispersionB: Float = 0.0031,
        acoustoOpticKappa: Float = 0.045,
        anisotropyG: Float = 0.72,
        stepSizeCells: Float = 0.85,
        photonEnergyScale: Float = 0.42,
        lightDirectionXY: SIMD2<Float> = SIMD2<Float>(0.14, 0.09),
        frameSeed: UInt32 = 1,
        slabDepthCells: Float = 10.2,
        emaAlpha: Float = 0.24,
        toneMapCompression: Float = 0.65
    ) {
        self.gridWidth = gridWidth
        self.gridHeight = gridHeight
        self.photonCount = photonCount
        self.integrationSteps = integrationSteps
        self.baseRefractiveIndex = baseRefractiveIndex
        self.cauchyDispersionB = cauchyDispersionB
        self.acoustoOpticKappa = acoustoOpticKappa
        self.anisotropyG = anisotropyG
        self.stepSizeCells = stepSizeCells
        self.photonEnergyScale = photonEnergyScale
        self.lightDirectionXY = lightDirectionXY
        self.frameSeed = frameSeed
        self.slabDepthCells = slabDepthCells
        self.emaAlpha = emaAlpha
        self.toneMapCompression = toneMapCompression
    }
}

/// Real-time adaptive quality governor targeting `< 6.5 ms` GPU/frame time with a hard `< 8.0 ms` ceiling (120 Hz ProMotion budget).
public struct CausticsQualityGovernor: Sendable, Equatable {
    public static let targetFrameTimeMs: Double = 6.5
    public static let hardCapFrameTimeMs: Double = 8.0
    public static let recoveryFrameTimeMs: Double = 4.8
    public static let minQualityScale: Float = 0.20

    public let minPhotonCount: Int
    public let maxPhotonCount: Int
    public let minIntegrationSteps: Int
    public let maxIntegrationSteps: Int

    public private(set) var qualityScale: Float
    public private(set) var activePhotonCount: Int
    public private(set) var activeIntegrationSteps: Int
    public private(set) var smoothedFrameTimeMs: Double
    public private(set) var lastFrameTimeMs: Double
    public private(set) var sampledFrameCount: Int
    public private(set) var consecutiveOverBudgetFrames: Int
    public private(set) var totalEmergencyThrottleCount: Int

    public init(
        minPhotonCount: Int = 1_024,
        maxPhotonCount: Int = 16_384,
        minIntegrationSteps: Int = 6,
        maxIntegrationSteps: Int = 32,
        initialQualityScale: Float = 1.0
    ) {
        let safeMinPhotons = max(256, minPhotonCount)
        let safeMaxPhotons = max(safeMinPhotons, maxPhotonCount)
        let safeMinSteps = max(4, minIntegrationSteps)
        let safeMaxSteps = max(safeMinSteps, maxIntegrationSteps)
        let clampedQ = min(max(initialQualityScale, Self.minQualityScale), 1.0)

        self.minPhotonCount = safeMinPhotons
        self.maxPhotonCount = safeMaxPhotons
        self.minIntegrationSteps = safeMinSteps
        self.maxIntegrationSteps = safeMaxSteps
        self.qualityScale = clampedQ
        self.activePhotonCount = Self.quantizePhotonCount(
            scale: clampedQ,
            minPhotons: safeMinPhotons,
            maxPhotons: safeMaxPhotons
        )
        self.activeIntegrationSteps = Self.quantizeIntegrationSteps(
            scale: clampedQ,
            minSteps: safeMinSteps,
            maxSteps: safeMaxSteps
        )
        self.smoothedFrameTimeMs = 0.0
        self.lastFrameTimeMs = 0.0
        self.sampledFrameCount = 0
        self.consecutiveOverBudgetFrames = 0
        self.totalEmergencyThrottleCount = 0
    }

    @inline(__always)
    private static func quantizePhotonCount(scale: Float, minPhotons: Int, maxPhotons: Int) -> Int {
        let raw = Int((Float(maxPhotons) * scale).rounded())
        let aligned = max(64, raw & ~63)
        return min(max(aligned, minPhotons), maxPhotons)
    }

    @inline(__always)
    private static func quantizeIntegrationSteps(scale: Float, minSteps: Int, maxSteps: Int) -> Int {
        let stepFactor: Float = 0.40 + 0.60 * scale
        let raw = Int((Float(maxSteps) * stepFactor).rounded())
        return min(max(raw, minSteps), maxSteps)
    }

    /// Updates `qualityScale`, `activePhotonCount`, and `activeIntegrationSteps` from a measured frame duration in milliseconds.
    public mutating func recordFrameTime(milliseconds: Double) {
        guard milliseconds.isFinite && milliseconds > 0.0 else { return }

        lastFrameTimeMs = milliseconds
        if sampledFrameCount == 0 {
            smoothedFrameTimeMs = milliseconds
        } else {
            smoothedFrameTimeMs = 0.35 * milliseconds + 0.65 * smoothedFrameTimeMs
        }
        sampledFrameCount += 1

        if milliseconds >= Self.hardCapFrameTimeMs {
            consecutiveOverBudgetFrames += 1
            totalEmergencyThrottleCount += 1
            let ratio = Float(Self.targetFrameTimeMs / max(milliseconds, 0.1))
            let emergencyCap = qualityScale * 0.75
            let proportional = qualityScale * ratio
            qualityScale = max(Self.minQualityScale, min(emergencyCap, proportional))
        } else if milliseconds > Self.targetFrameTimeMs || smoothedFrameTimeMs > Self.targetFrameTimeMs {
            consecutiveOverBudgetFrames += 1
            let effectiveMs = max(smoothedFrameTimeMs, milliseconds)
            let ratio = Float(Self.targetFrameTimeMs / max(effectiveMs, 0.1))
            let dampedFactor = max(Float(0.80), ratio * 0.95)
            qualityScale = max(Self.minQualityScale, qualityScale * dampedFactor)
        } else {
            consecutiveOverBudgetFrames = 0
            if smoothedFrameTimeMs < Self.recoveryFrameTimeMs && milliseconds < Self.targetFrameTimeMs {
                qualityScale = min(1.0, qualityScale + 0.05)
            }
        }

        activePhotonCount = Self.quantizePhotonCount(
            scale: qualityScale,
            minPhotons: minPhotonCount,
            maxPhotons: maxPhotonCount
        )
        activeIntegrationSteps = Self.quantizeIntegrationSteps(
            scale: qualityScale,
            minSteps: minIntegrationSteps,
            maxSteps: maxIntegrationSteps
        )
    }

    /// Records GPU execution duration directly from `MTLCommandBuffer` hardware timestamps (`gpuEndTime - gpuStartTime`).
    public mutating func recordGPUTimestamps(gpuStartTimeSeconds: Double, gpuEndTimeSeconds: Double) {
        guard gpuStartTimeSeconds.isFinite,
              gpuEndTimeSeconds.isFinite,
              gpuStartTimeSeconds > 0.0,
              gpuEndTimeSeconds > gpuStartTimeSeconds else {
            return
        }
        let elapsedMs = (gpuEndTimeSeconds - gpuStartTimeSeconds) * 1_000.0
        recordFrameTime(milliseconds: elapsedMs)
    }

    #if canImport(Metal) && !os(watchOS)
    public mutating func recordCommandBuffer(_ commandBuffer: MTLCommandBuffer) {
        recordGPUTimestamps(
            gpuStartTimeSeconds: commandBuffer.gpuStartTime,
            gpuEndTimeSeconds: commandBuffer.gpuEndTime
        )
    }
    #endif
}

// MARK: - 1. Pure-Swift Acousto-Optic Physics & Spectral Photon Caustics Engine

public enum SpectralCausticsRenderer: Sendable {
    @inline(__always)
    public static func sellmeierRefractiveIndex(wavelengthNm: Float, dispersionStrength: Float = 1.0) -> Float {
        AcoustoOpticCausticsEngine.refractiveIndex(
            wavelengthNm: wavelengthNm,
            pressure: 0.0,
            n0: 1.333,
            cauchyB: 0.0031 * max(0.05, dispersionStrength),
            kappaAO: 0.045
        )
    }

    @inline(__always)
    public static func cie1931RGB(wavelengthNm: Float) -> SIMD3<Float> {
        AcoustoOpticCausticsEngine.wavelengthToLinearSRGB(wavelengthNm)
    }
}

public enum AcoustoOpticCausticsEngine: Sendable {
    public static let minVisibleWavelengthNm: Float = 380.0
    public static let maxVisibleWavelengthNm: Float = 700.0
    public static let defaultHardwarePhotonCount: Int = 16_384
    /// Water base refractive index at standard temperature (`n_0 = 1.333`).
    public static let waterBaseRefractiveIndex: Float = 1.333
    /// Physical Cauchy dispersion coefficient (`B = 0.0031 um^2`).
    public static let defaultCauchyDispersionB: Float = 0.0031
    /// Default Gladstone-Dale acousto-optic piezo-optic coupling (`kappa_ao = 0.045`).
    public static let defaultAcoustoOpticKappa: Float = 0.045
    /// Four-pi steradians (`4 * pi`) for 3D Henyey-Greenstein phase normalization.
    public static let fourPiSteradians: Float = 4.0 * Float.pi
    /// Beer-Lambert optical extinction per cell during volumetric ray-marching.
    public static let beerLambertExtinctionPerCell: Float = 0.018
    /// Minimum photon throughput before Russian-roulette / threshold termination.
    public static let minPhotonThroughput: Float = 0.05
    /// Minimum bilinear corner weight required to commit an irradiance splat.
    public static let minCornerSplatWeight: Float = 0.08

    public static let spectralWavelengthBandsNm: [Float] = [
        380.0, 425.7143, 471.4286, 517.1429,
        562.8571, 608.5714, 654.2857, 700.0
    ]

    /// Precomputed `1 / lambda_um^2` (`um^-2`) for the 8 spectral anchor bands.
    public static let spectralInvLambdaUmSq: [Float] = [
        6.9252078, 5.5177665, 4.4995394, 3.7392014,
        3.1564841, 2.7000836, 2.3359570, 2.0408163
    ]

    /// Cauchy optical dispersion + Gladstone-Dale acousto-optic pressure coupling:
    /// `n(x, lambda) = (n0 + B / lambda_um^2) * (1 + kappa_ao * p(x))`.
    /// Shorter blue wavelengths (`400 nm`) yield strictly higher refractive index than red (`680 nm`).
    @inline(__always)
    public static func refractiveIndex(
        wavelengthNm: Float,
        pressure: Float,
        n0: Float = 1.333,
        cauchyB: Float = 0.0031,
        kappaAO: Float = 0.045
    ) -> Float {
        let lambdaUm = max(0.25, wavelengthNm * 1.0e-3)
        let baseN = n0 + cauchyB / (lambdaUm * lambdaUm)
        let coupled = baseN * max(0.05, 1.0 + kappaAO * pressure)
        return max(1.0001, coupled)
    }

    /// Computes Snell's transmitted angle `theta_t = asin(sin(theta_i) / n(lambda, p))`
    /// when a collimated beam enters the dispersive acousto-optic medium from air (`n_air = 1.0`).
    /// Because `n(400nm) > n(680nm)`, shorter blue light bends closer to the surface normal (`|theta_t(400)| < |theta_t(680)|`,
    /// i.e. larger angular deflection `|theta_i - theta_t|`) than red light!
    @inline(__always)
    public static func snellRefractionAngleRadians(
        incidentRadians: Float,
        wavelengthNm: Float,
        pressure: Float
    ) -> Float {
        let nMedium = refractiveIndex(wavelengthNm: wavelengthNm, pressure: pressure)
        let sinTransmitted = min(max(sinf(incidentRadians) / nMedium, -1.0), 1.0)
        return asinf(sinTransmitted)
    }

    /// Angular deflection magnitude `|theta_incident - theta_transmitted|` in radians.
    @inline(__always)
    public static func snellAngularDeflectionRadians(
        incidentRadians: Float,
        wavelengthNm: Float,
        pressure: Float
    ) -> Float {
        let refracted = snellRefractionAngleRadians(
            incidentRadians: incidentRadians,
            wavelengthNm: wavelengthNm,
            pressure: pressure
        )
        return abs(incidentRadians - refracted)
    }

    /// Computes the symplectic Hamiltonian / Eikonal ray deflection angle in radians across a pressure gradient `grad(p)`.
    /// Under identical `grad(p) != 0`, shorter violet wavelengths (`400 nm`) experience a strictly greater
    /// dispersive refractive gradient `grad(n) = (n0 + B / lambda^2) * kappa_ao * grad(p)` and bend at a larger angle than red (`700 nm`).
    @inline(__always)
    public static func refractionDeflectionAngleRadians(
        wavelengthNm: Float,
        pressure: Float = 0.0,
        pressureGradientMagnitude: Float,
        stepDistance: Float = 1.0,
        n0: Float = 1.333,
        cauchyB: Float = 0.0125,
        kappaAO: Float = 0.085
    ) -> Float {
        let snellPart = snellAngularDeflectionRadians(
            incidentRadians: 0.45,
            wavelengthNm: wavelengthNm,
            pressure: pressure
        )
        let lambdaUm = max(0.25, wavelengthNm * 1.0e-3)
        let baseDispN = n0 + cauchyB / (lambdaUm * lambdaUm)
        let gradN = abs(pressureGradientMagnitude) * baseDispN * kappaAO
        let schlierenPart = atanf(gradN * max(0.01, stepDistance))
        return snellPart + schlierenPart
    }

    @inline(__always)
    private static func asymmetricGaussian(_ x: Float, mu: Float, sigmaLeft: Float, sigmaRight: Float) -> Float {
        let t = (x - mu) * (x < mu ? sigmaLeft : sigmaRight)
        return expf(-0.5 * t * t)
    }

    /// Wyman, Sloan & Shirley (2013) CIE 1931 2-degree piecewise Gaussian color-matching functions `XYZ`.
    @inline(__always)
    public static func wavelengthToCIE1931XYZ(_ wavelengthNm: Float) -> SIMD3<Float> {
        guard wavelengthNm >= 360.0 && wavelengthNm <= 780.0 else {
            return .zero
        }

        let x1 = 1.056 * asymmetricGaussian(wavelengthNm, mu: 599.8, sigmaLeft: 0.0264, sigmaRight: 0.0323)
        let x2 = 0.362 * asymmetricGaussian(wavelengthNm, mu: 442.0, sigmaLeft: 0.0624, sigmaRight: 0.0374)
        let x3 = 0.065 * asymmetricGaussian(wavelengthNm, mu: 501.1, sigmaLeft: 0.0490, sigmaRight: 0.0382)
        let xBar = x1 + x2 - x3

        let y1 = 0.821 * asymmetricGaussian(wavelengthNm, mu: 568.8, sigmaLeft: 0.0213, sigmaRight: 0.0247)
        let y2 = 0.286 * asymmetricGaussian(wavelengthNm, mu: 530.9, sigmaLeft: 0.0613, sigmaRight: 0.0322)
        let yBar = y1 + y2

        let z1 = 1.217 * asymmetricGaussian(wavelengthNm, mu: 437.0, sigmaLeft: 0.0845, sigmaRight: 0.0278)
        let z2 = 0.681 * asymmetricGaussian(wavelengthNm, mu: 459.0, sigmaLeft: 0.0385, sigmaRight: 0.0725)
        let zBar = z1 + z2

        return SIMD3<Float>(max(0.0, xBar), max(0.0, yBar), max(0.0, zBar))
    }

    /// Converts CIE 1931 `XYZ` tristimulus values into Linear Display-P3 wide-gamut RGB (`D65` white point).
    @inline(__always)
    public static func xyzToLinearDisplayP3(_ xyz: SIMD3<Float>) -> SIMD3<Float> {
        let r =  2.4934969 * xyz.x - 0.9313836 * xyz.y - 0.4027108 * xyz.z
        let g = -0.8294890 * xyz.x + 1.7626641 * xyz.y + 0.0236247 * xyz.z
        let b =  0.0358458 * xyz.x - 0.0761724 * xyz.y + 0.9568845 * xyz.z
        return SIMD3<Float>(max(0.0, r), max(0.0, g), max(0.0, b))
    }

    /// Converts CIE 1931 `XYZ` tristimulus values into Linear sRGB (`D65` primaries) without re-evaluating Gaussian CMFs.
    @inline(__always)
    public static func xyzToLinearSRGB(_ xyz: SIMD3<Float>) -> SIMD3<Float> {
        let r =  3.2406 * xyz.x - 1.5372 * xyz.y - 0.4986 * xyz.z
        let g = -0.9689 * xyz.x + 1.8758 * xyz.y + 0.0415 * xyz.z
        let b =  0.0557 * xyz.x - 0.2040 * xyz.y + 1.0570 * xyz.z
        return SIMD3<Float>(max(0.0, r), max(0.0, g), max(0.0, b))
    }

    /// Wyman, Sloan & Shirley (2013) CIE 1931 2-degree piecewise Gaussian color-matching functions
    /// transformed into non-negative Linear sRGB (`D65` primaries).
    @inline(__always)
    public static func wavelengthToLinearSRGB(_ wavelengthNm: Float) -> SIMD3<Float> {
        let xyz = wavelengthToCIE1931XYZ(wavelengthNm)
        return xyzToLinearSRGB(xyz)
    }

    /// Normalized Henyey-Greenstein volumetric scattering phase function (`integral over 4*pi sr == 1.0`).
    @inline(__always)
    public static func henyeyGreensteinPhase(cosTheta: Float, anisotropyG: Float) -> Float {
        let g = min(max(anisotropyG, -0.98), 0.98)
        let mu = min(max(cosTheta, -1.0), 1.0)
        let gSq = g * g
        let denom = max(1.0e-5, 1.0 + gSq - 2.0 * g * mu)
        return (1.0 - gSq) / (fourPiSteradians * denom * sqrtf(denom))
    }

    /// Analytic inverse-CDF importance sampler for the Henyey-Greenstein scattering cosine `cos(theta)` in `[-1, 1]`.
    /// Satisfies `E[cos(theta)] == anisotropyG` across `(-0.98, 0.98)` with exact isotropic limit `1 - 2*xi` as `g -> 0`.
    @inline(__always)
    public static func sampleHenyeyGreensteinCosTheta(uniformRandom01: Float, anisotropyG: Float) -> Float {
        let g = min(max(anisotropyG, -0.98), 0.98)
        let xi = min(max(uniformRandom01, 0.0), 1.0)
        if abs(g) < 1.0e-4 {
            return 1.0 - 2.0 * xi
        }
        let gSq = g * g
        let denom = 1.0 - g + 2.0 * g * xi
        let ratio = (1.0 - gSq) / max(1.0e-6, denom)
        let cosTheta = (1.0 + gSq - ratio * ratio) / (2.0 * g)
        return min(max(cosTheta, -1.0), 1.0)
    }

    /// Fused 6-tap bilinear pressure and central-difference gradient evaluation on an `UnsafeBufferPointer<Float>`.
    /// Replaces 20 bounds-checked array loads per ray-march step with 6 direct pointer reads.
    @inline(__always)
    private static func samplePressureAndGradientUnsafe(
        _ grid: UnsafeBufferPointer<Float>,
        size: Int,
        x: Float,
        y: Float
    ) -> SIMD3<Float> {
        let maxCoord = Float(size - 1)
        let cx = min(max(x, 0.0), maxCoord)
        let cy = min(max(y, 0.0), maxCoord)
        let x0 = min(Int(cx), size - 2)
        let y0 = min(Int(cy), size - 2)
        let fx = cx - Float(x0)
        let fy = cy - Float(y0)

        let row0 = y0 * size
        let row1 = (y0 + 1) * size
        let p00 = grid[row0 + x0]
        let p10 = grid[row0 + x0 + 1]
        let p01 = grid[row1 + x0]
        let p11 = grid[row1 + x0 + 1]

        let top = p00 + fx * (p10 - p00)
        let bot = p01 + fx * (p11 - p01)
        let localP = top + fy * (bot - top)

        let xm1 = max(0, x0 - 1)
        let ym1 = max(0, y0 - 1)
        let pL = grid[row0 + xm1]
        let pD = grid[ym1 * size + x0]

        let dPdxCell = (p10 - p00) + fy * ((p11 - p01) - (p10 - p00))
        let dPdyCell = (p01 - p00) + fx * ((p11 - p10) - (p01 - p00))
        let dPdxCentral = 0.5 * (p10 - pL)
        let dPdyCentral = 0.5 * (p01 - pD)

        let gradX = 0.5 * (dPdxCell + dPdxCentral)
        let gradY = 0.5 * (dPdyCell + dPdyCentral)
        return SIMD3<Float>(localP, gradX, gradY)
    }

    /// Traces `photonCount` polychromatic photons (`380..700 nm`) through the 2D acoustic pressure field
    /// using Eikonal refractive bending (`d(n * s)/ds = grad(n)`), Cauchy dispersion, Henyey-Greenstein
    /// forward scattering, adaptive step sizing, and gated bilinear Wyman CIE 1931 Linear sRGB splatting.
    public static func traceCausticsField(
        pressureGrid: [Float],
        gridSize: Int,
        photonCount: Int = 4_096,
        integrationSteps: Int = 12
    ) -> [SIMD3<Float>] {
        let n = max(4, gridSize)
        let cellCount = n * n
        guard pressureGrid.count >= cellCount, photonCount > 0 else {
            return [SIMD3<Float>](repeating: .zero, count: max(0, gridSize * gridSize))
        }

        var irradiance = [SIMD3<Float>](repeating: .zero, count: cellCount)

        let strataSide = max(1, Int(sqrt(Double(photonCount)).rounded(.up)))
        let invStrata = 1.0 / Float(strataSide)
        let maxCoord = Float(n - 1)
        let n0: Float = waterBaseRefractiveIndex
        let cauchyB: Float = 0.0125 // Boosted dispersive prism visibility across visible spectrum
        let kappaAO: Float = 0.085
        let anisotropyG: Float = 0.72
        let clampedSteps = min(max(integrationSteps, 4), 64)
        let baseStepLength: Float = 0.85
        let targetSlabDepth: Float = baseStepLength * Float(clampedSteps)

        // Slight oblique illumination angle reveals vivid prismatic RGB separation at caustic cusps
        let initialBeamDir = simd_normalize(SIMD3<Float>(0.14, 0.09, 1.0))
        let energyPerPhoton = Float(cellCount) / Float(max(1, photonCount)) * 0.42

        // Precompute 64-bin spectral LUT outside photon loop to eliminate per-photon Gaussian expf() calls
        let spectralBinCount = 64
        var lutSRGB = [SIMD3<Float>](repeating: .zero, count: spectralBinCount)
        var lutBaseDispN = [Float](repeating: n0, count: spectralBinCount)
        let wavelengthSpan = maxVisibleWavelengthNm - minVisibleWavelengthNm
        for bin in 0..<spectralBinCount {
            let t = (Float(bin) + 0.5) / Float(spectralBinCount)
            let wl = minVisibleWavelengthNm + t * wavelengthSpan
            lutSRGB[bin] = wavelengthToLinearSRGB(wl) * energyPerPhoton
            let lambdaUm = wl * 1.0e-3
            lutBaseDispN[bin] = n0 + cauchyB / (lambdaUm * lambdaUm)
        }

        pressureGrid.withUnsafeBufferPointer { gridPtr in
            irradiance.withUnsafeMutableBufferPointer { irrPtr in
                for pIdx in 0..<photonCount {
                    let sx = pIdx % strataSide
                    let sy = (pIdx / strataSide) % strataSide

                    // Deterministic Halton/Fibonacci sub-cell jitter + golden-ratio spectral sampling
                    let jx = fmodf(Float(pIdx &* 73 &+ 19) * 0.00390625, 1.0)
                    let jy = fmodf(Float(pIdx &* 137 &+ 53) * 0.00390625, 1.0)
                    let u = min(max((Float(sx) + jx) * invStrata, 0.001), 0.999)
                    let v = min(max((Float(sy) + jy) * invStrata, 0.001), 0.999)

                    let specT = fmodf(Float(pIdx) * 0.61803399 + 0.13, 1.0)
                    let specBin = min(max(Int(specT * Float(spectralBinCount)), 0), spectralBinCount - 1)
                    let photonRGB = lutSRGB[specBin]
                    let baseDispN = lutBaseDispN[specBin]
                    let gradNScale = baseDispN * kappaAO

                    var pos = SIMD2<Float>(u * maxCoord, v * maxCoord)
                    var rayDir = initialBeamDir

                    // Surface entry Snell refraction modulated by initial local pressure
                    let entryPG = samplePressureAndGradientUnsafe(gridPtr, size: n, x: pos.x, y: pos.y)
                    let entryN = max(1.001, baseDispN * max(0.1, 1.0 + kappaAO * entryPG.x))
                    rayDir.x /= entryN
                    rayDir.y /= entryN
                    rayDir = simd_normalize(rayDir)

                    var marchedDepth: Float = 0.0
                    var throughput: Float = 1.0

                    for _ in 0..<clampedSteps {
                        let samplePG = samplePressureAndGradientUnsafe(gridPtr, size: n, x: pos.x, y: pos.y)
                        let localP = samplePG.x
                        let gradP = SIMD2<Float>(samplePG.y, samplePG.z)
                        let localN = max(1.001, baseDispN * max(0.1, 1.0 + kappaAO * localP))
                        let gradN = gradP * gradNScale

                        // Adaptive step sizing: stretch up to 1.75x in flat zones, 1.0x at sharp caustic gradients
                        let gradMagSq = simd_length_squared(gradN)
                        let adaptiveScale = min(max(1.75 / sqrtf(1.0 + 20.0 * gradMagSq), 1.0), 1.75)
                        let ds = min(baseStepLength * adaptiveScale, targetSlabDepth - marchedDepth)

                        // Eikonal ray curvature toward higher refractive index
                        let bendScale: Float = (ds * 5.2) / localN
                        rayDir.x += gradN.x * bendScale
                        rayDir.y += gradN.y * bendScale
                        rayDir = simd_normalize(rayDir)

                        pos += SIMD2<Float>(rayDir.x, rayDir.y) * ds
                        marchedDepth += ds
                        throughput *= (1.0 - beerLambertExtinctionPerCell * ds)

                        // Wrap toroidally inside viewport so edge photons remain bounded and continuous
                        if pos.x < 0.0 { pos.x += maxCoord }
                        if pos.x > maxCoord { pos.x -= maxCoord }
                        if pos.y < 0.0 { pos.y += maxCoord }
                        if pos.y > maxCoord { pos.y -= maxCoord }

                        if marchedDepth >= targetSlabDepth || throughput < minPhotonThroughput {
                            break
                        }
                    }

                    guard throughput >= minPhotonThroughput else { continue }

                    let cosScatter = simd_dot(rayDir, initialBeamDir)
                    let hgPhase = min(henyeyGreensteinPhase(cosTheta: cosScatter, anisotropyG: anisotropyG), 4.0)
                    let hgGain = throughput * (0.45 + 0.55 * hgPhase)
                    let weightedRGB = photonRGB * hgGain

                    let x0 = min(max(Int(pos.x), 0), n - 2)
                    let y0 = min(max(Int(pos.y), 0), n - 2)
                    let fx = min(max(pos.x - Float(x0), 0.0), 1.0)
                    let fy = min(max(pos.y - Float(y0), 0.0), 1.0)

                    let w00 = (1.0 - fx) * (1.0 - fy)
                    let w10 = fx * (1.0 - fy)
                    let w01 = (1.0 - fx) * fy
                    let w11 = fx * fy

                    let row0 = y0 * n
                    let row1 = (y0 + 1) * n
                    if w00 >= minCornerSplatWeight { irrPtr[row0 + x0] += weightedRGB * w00 }
                    if w10 >= minCornerSplatWeight { irrPtr[row0 + x0 + 1] += weightedRGB * w10 }
                    if w01 >= minCornerSplatWeight { irrPtr[row1 + x0] += weightedRGB * w01 }
                    if w11 >= minCornerSplatWeight { irrPtr[row1 + x0 + 1] += weightedRGB * w11 }
                }
            }
        }

        return irradiance
    }
}

// MARK: - 1B. Pre-Allocated Metal Compute Dispatcher & Shared Frame-Time Governor

public final class VolumetricCausticsDispatcher: @unchecked Sendable {
    public static let shared = VolumetricCausticsDispatcher()

    private let lock = NSLock()
    private var governor = CausticsQualityGovernor()
    private var frameCounter: UInt32 = 1
    private var reusableSampledPressure: [Float] = []

    #if canImport(Metal) && !os(watchOS)
    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var tracePipeline: MTLComputePipelineState?
    private var resolvePipeline: MTLComputePipelineState?
    private var allocatedCellCapacity: Int = 0
    private var pressureBuffer: MTLBuffer?
    private var accumRGBQuantizedBuffer: MTLBuffer?
    private var resolvedRGBBuffer: MTLBuffer?
    private var isMetalReady: Bool = false
    #endif

    public init() {
        #if canImport(Metal) && !os(watchOS)
        setupMetalPipelinesIfAvailable()
        #endif
    }

    public func currentGovernorSnapshot() -> CausticsQualityGovernor {
        lock.lock()
        defer { lock.unlock() }
        return governor
    }

    #if canImport(Metal) && !os(watchOS)
    private func setupMetalPipelinesIfAvailable() {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let queue = dev.makeCommandQueue(),
              let library = dev.makeDefaultLibrary(),
              let traceFn = library.makeFunction(name: "aetherTraceAcoustoOpticPhotons"),
              let resolveFn = library.makeFunction(name: "aetherResolveVolumetricCaustics"),
              let tracePSO = try? dev.makeComputePipelineState(function: traceFn),
              let resolvePSO = try? dev.makeComputePipelineState(function: resolveFn) else {
            self.isMetalReady = false
            return
        }
        self.device = dev
        self.commandQueue = queue
        self.tracePipeline = tracePSO
        self.resolvePipeline = resolvePSO
        self.isMetalReady = true
    }

    private func ensurePreallocatedBuffersLocked(cellCount: Int) -> Bool {
        guard isMetalReady, let dev = device else { return false }
        if cellCount <= allocatedCellCapacity,
           pressureBuffer != nil,
           accumRGBQuantizedBuffer != nil,
           resolvedRGBBuffer != nil {
            return true
        }
        let capacity = max(cellCount, 64 * 64)
        let pressureBytes = capacity * MemoryLayout<Float>.stride
        let accumBytes = capacity * 3 * MemoryLayout<UInt32>.stride
        let resolvedBytes = capacity * MemoryLayout<SIMD4<Float>>.stride

        guard let pBuf = dev.makeBuffer(length: pressureBytes, options: .storageModeShared),
              let aBuf = dev.makeBuffer(length: accumBytes, options: .storageModeShared),
              let rBuf = dev.makeBuffer(length: resolvedBytes, options: .storageModeShared) else {
            return false
        }
        memset(aBuf.contents(), 0, accumBytes)
        memset(rBuf.contents(), 0, resolvedBytes)
        self.pressureBuffer = pBuf
        self.accumRGBQuantizedBuffer = aBuf
        self.resolvedRGBBuffer = rBuf
        self.allocatedCellCapacity = capacity
        return true
    }
    #endif

    /// Renders a downsampled caustics irradiance grid using pre-allocated buffers and adaptive frame-time governance.
    public func renderDownsampledCaustics(
        sourcePressure: [Float],
        sourceGridSize: Int,
        renderGridSize: Int,
        pressureGain: Float,
        requestedPhotons: Int
    ) -> [SIMD3<Float>] {
        let renderN = max(4, renderGridSize)
        let cellCount = renderN * renderN
        let fullN = max(1, sourceGridSize)
        let strideStep = max(1, fullN / renderN)

        lock.lock()
        if reusableSampledPressure.count != cellCount {
            reusableSampledPressure = [Float](repeating: 0.0, count: cellCount)
        }
        for ry in 0..<renderN {
            let sy = min(fullN - 1, ry * strideStep)
            let srcRow = sy * fullN
            let dstRow = ry * renderN
            for rx in 0..<renderN {
                let sx = min(fullN - 1, rx * strideStep)
                let idx = srcRow + sx
                if idx < sourcePressure.count {
                    reusableSampledPressure[dstRow + rx] = sourcePressure[idx] * pressureGain
                }
            }
        }
        let sampledSnapshot = reusableSampledPressure
        let govSnap = governor
        frameCounter &+= 1
        let activeSeed = frameCounter
        lock.unlock()

        let effectivePhotons = min(requestedPhotons, govSnap.activePhotonCount)
        let effectiveSteps = min(16, govSnap.activeIntegrationSteps)

        #if canImport(Metal) && !os(watchOS)
        if let gpuOut = dispatchMetalCausticsIfAvailable(
            sampledPressure: sampledSnapshot,
            gridSize: renderN,
            photonCount: effectivePhotons,
            integrationSteps: effectiveSteps,
            frameSeed: activeSeed
        ) {
            return gpuOut
        }
        #endif

        let startNs = DispatchTime.now().uptimeNanoseconds
        let field = AcoustoOpticCausticsEngine.traceCausticsField(
            pressureGrid: sampledSnapshot,
            gridSize: renderN,
            photonCount: effectivePhotons,
            integrationSteps: effectiveSteps
        )
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000.0

        lock.lock()
        governor.recordFrameTime(milliseconds: elapsedMs)
        lock.unlock()
        return field
    }

    #if canImport(Metal) && !os(watchOS)
    private func dispatchMetalCausticsIfAvailable(
        sampledPressure: [Float],
        gridSize: Int,
        photonCount: Int,
        integrationSteps: Int,
        frameSeed: UInt32
    ) -> [SIMD3<Float>]? {
        let cellCount = gridSize * gridSize
        lock.lock()
        guard ensurePreallocatedBuffersLocked(cellCount: cellCount),
              let queue = commandQueue,
              let tracePSO = tracePipeline,
              let resolvePSO = resolvePipeline,
              let pBuf = pressureBuffer,
              let aBuf = accumRGBQuantizedBuffer,
              let rBuf = resolvedRGBBuffer else {
            lock.unlock()
            return nil
        }

        sampledPressure.withUnsafeBufferPointer { src in
            if let base = src.baseAddress {
                memcpy(pBuf.contents(), base, cellCount * MemoryLayout<Float>.stride)
            }
        }
        memset(aBuf.contents(), 0, cellCount * 3 * MemoryLayout<UInt32>.stride)
        lock.unlock()

        guard let cmdBuf = queue.makeCommandBuffer(),
              let encoder = cmdBuf.makeComputeCommandEncoder() else {
            return nil
        }

        let stepLen: Float = 0.85
        let energyScale = Float(cellCount) / Float(max(1, photonCount)) * 0.42
        var uniforms = AcoustoOpticCausticUniforms(
            gridWidth: UInt32(gridSize),
            gridHeight: UInt32(gridSize),
            photonCount: UInt32(max(64, photonCount)),
            integrationSteps: UInt32(max(4, integrationSteps)),
            baseRefractiveIndex: AcoustoOpticCausticsEngine.waterBaseRefractiveIndex,
            cauchyDispersionB: 0.0125,
            acoustoOpticKappa: 0.085,
            anisotropyG: 0.72,
            stepSizeCells: stepLen,
            photonEnergyScale: energyScale,
            lightDirectionXY: SIMD2<Float>(0.14, 0.09),
            frameSeed: frameSeed,
            slabDepthCells: stepLen * Float(max(4, integrationSteps)),
            emaAlpha: 0.28,
            toneMapCompression: 0.65
        )

        encoder.setComputePipelineState(tracePSO)
        encoder.setBuffer(pBuf, offset: 0, index: 0)
        encoder.setBuffer(aBuf, offset: 0, index: 1)
        encoder.setBytes(&uniforms, length: MemoryLayout<AcoustoOpticCausticUniforms>.stride, index: 2)
        let threadsPerGroup = MTLSize(width: 64, height: 1, depth: 1)
        let groupCount = MTLSize(width: (photonCount + 63) / 64, height: 1, depth: 1)
        encoder.dispatchThreadgroups(groupCount, threadsPerThreadgroup: threadsPerGroup)

        encoder.setComputePipelineState(resolvePSO)
        encoder.setBuffer(aBuf, offset: 0, index: 0)
        encoder.setBuffer(rBuf, offset: 0, index: 1)
        encoder.setBytes(&uniforms, length: MemoryLayout<AcoustoOpticCausticUniforms>.stride, index: 2)
        let tg2D = MTLSize(width: 8, height: 8, depth: 1)
        let groups2D = MTLSize(width: (gridSize + 7) / 8, height: (gridSize + 7) / 8, depth: 1)
        encoder.dispatchThreadgroups(groups2D, threadsPerThreadgroup: tg2D)

        encoder.endEncoding()

        let cpuFallbackStartNs = DispatchTime.now().uptimeNanoseconds
        cmdBuf.addCompletedHandler { [weak self] completedBuffer in
            guard let self else { return }
            let gpuStart = completedBuffer.gpuStartTime
            let gpuEnd = completedBuffer.gpuEndTime
            self.lock.lock()
            if gpuEnd > gpuStart && gpuStart > 0.0 {
                self.governor.recordCommandBuffer(completedBuffer)
            } else {
                let wallMs = Double(DispatchTime.now().uptimeNanoseconds - cpuFallbackStartNs) / 1_000_000.0
                self.governor.recordFrameTime(milliseconds: wallMs)
            }
            self.lock.unlock()
        }

        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        var outField = [SIMD3<Float>](repeating: .zero, count: cellCount)
        lock.lock()
        let resolvedPtr = rBuf.contents().bindMemory(to: SIMD4<Float>.self, capacity: cellCount)
        for i in 0..<cellCount {
            let v = resolvedPtr[i]
            outField[i] = SIMD3<Float>(v.x, v.y, v.z)
        }
        lock.unlock()
        return outField
    }
    #endif
}

// MARK: - 2. SwiftUI Shimmering Chromatic Acousto-Optic Caustics Canvas View

public struct AcoustoOpticCausticsCanvasView: View {
    public let waveTankController: VisualFDTDWaveTankController
    public let photonCount: Int
    public let accentHue: Double

    public init(
        waveTankController: VisualFDTDWaveTankController,
        photonCount: Int = 4_096,
        accentHue: Double = 0.56
    ) {
        self.waveTankController = waveTankController
        self.photonCount = max(512, photonCount)
        self.accentHue = accentHue
    }

    public var body: some View {
        GeometryReader { proxy in
            let viewportSize = proxy.size

            TimelineView(.animation) { _ in
                Canvas(rendersAsynchronously: false) { context, canvasSize in
                    waveTankController.stepVisualFrame(substeps: 2)

                    let tank = waveTankController.waveTank
                    let fullN = tank.gridSize
                    // Downsample to 48x48 optical grid for crisp 60-120fps Canvas caustic splatting
                    let renderN = min(48, fullN)

                    let caustics = VolumetricCausticsDispatcher.shared.renderDownsampledCaustics(
                        sourcePressure: tank.pressureCurr,
                        sourceGridSize: fullN,
                        renderGridSize: renderN,
                        pressureGain: 6.5,
                        requestedPhotons: photonCount
                    )

                    context.fill(
                        Path(CGRect(origin: .zero, size: canvasSize)),
                        with: .color(Color(red: 0.015, green: 0.022, blue: 0.048))
                    )

                    let cellW = canvasSize.width / CGFloat(renderN)
                    let cellH = canvasSize.height / CGFloat(renderN)
                    let prevBlend = context.blendMode
                    context.blendMode = .plusLighter

                    for ry in 0..<renderN {
                        for rx in 0..<renderN {
                            let rgb = caustics[ry * renderN + rx]
                            let mapped = SIMD3<Float>(
                                rgb.x / (1.0 + rgb.x * 0.65),
                                rgb.y / (1.0 + rgb.y * 0.65),
                                rgb.z / (1.0 + rgb.z * 0.65)
                            )
                            let luma = max(mapped.x, max(mapped.y, mapped.z))
                            guard luma > 0.015 else { continue }

                            // Fast rational Pade-like / sqrt gamma approximation for linear sRGB display
                            let clampedR = min(max(mapped.x, 0.0), 1.0)
                            let clampedG = min(max(mapped.y, 0.0), 1.0)
                            let clampedB = min(max(mapped.z, 0.0), 1.0)
                            let srgbR = Double(sqrtf(clampedR))
                            let srgbG = Double(sqrtf(clampedG))
                            let srgbB = Double(sqrtf(clampedB))

                            let rect = CGRect(
                                x: CGFloat(rx) * cellW - 0.5,
                                y: CGFloat(ry) * cellH - 0.5,
                                width: cellW + 1.0,
                                height: cellH + 1.0
                            )
                            context.fill(
                                Path(rect),
                                with: .color(Color(red: srgbR, green: srgbG, blue: srgbB))
                            )
                        }
                    }

                    context.blendMode = prevBlend
                }
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(.white.opacity(0.18), lineWidth: 1.0)
                }
                .contentShape(Rectangle())
                .gesture(
                    SpatialTapGesture()
                        .onEnded { tap in
                            let safeW = max(1.0, viewportSize.width)
                            let safeH = max(1.0, viewportSize.height)
                            let normX = Float(min(max(tap.location.x / safeW, 0.08), 0.92))
                            let normY = Float(min(max(tap.location.y / safeH, 0.08), 0.92))
                            waveTankController.triggerTouchPulse(normalizedX: normX, normalizedY: normY, amplitude: 1.35)
                        }
                )
            }
        }
    }
}

// MARK: - 3. SpectralCausticsView (FDTD Wave Tank + Spectral FFT Analyzer Coupled View)

public struct SpectralCausticsView: View {
    public let waveTankController: VisualFDTDWaveTankController
    public let spectrumBars: [Float]
    public let dominantSpectrumHz: Double
    public let liveAudioAmplitude: Double
    public let photonCount: Int

    public init(
        waveTankController: VisualFDTDWaveTankController,
        spectrumBars: [Float] = [],
        dominantSpectrumHz: Double = 216.0,
        liveAudioAmplitude: Double = 0.25,
        photonCount: Int = 4_096
    ) {
        self.waveTankController = waveTankController
        self.spectrumBars = spectrumBars
        self.dominantSpectrumHz = dominantSpectrumHz
        self.liveAudioAmplitude = liveAudioAmplitude
        self.photonCount = max(512, photonCount)
    }

    public var body: some View {
        ZStack(alignment: .bottomLeading) {
            AcoustoOpticCausticsCanvasView(
                waveTankController: waveTankController,
                photonCount: photonCount,
                accentHue: min(max(dominantSpectrumHz / 880.0, 0.42), 0.78)
            )

            HStack(spacing: 10) {
                Label(
                    String(format: "λ 380–700nm · %.0f Hz", dominantSpectrumHz),
                    systemImage: "sparkles"
                )
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))

                Spacer()

                Text(
                    String(
                        format: "n₀=1.333 · κ=%.3f · RMS %.3f",
                        0.045 + 0.040 * min(max(liveAudioAmplitude, 0.0), 1.0),
                        waveTankController.latestRMSPressure
                    )
                )
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.cyan.opacity(0.9))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(10)
        }
    }
}

// MARK: - 4. ChromaticCausticsViewportView (Direct WaveTank Snapshot Caustics Viewport)

public struct ChromaticCausticsViewportView: View {
    public let waveTank: FDTDWaveTankGrid2D
    public let audioAmplitude: Float
    public let highBandEnergy: Float
    public let accentHue: Double
    public let photonCount: Int

    public init(
        waveTank: FDTDWaveTankGrid2D,
        audioAmplitude: Float,
        highBandEnergy: Float,
        accentHue: Double,
        photonCount: Int = 3_072
    ) {
        self.waveTank = waveTank
        self.audioAmplitude = audioAmplitude
        self.highBandEnergy = highBandEnergy
        self.accentHue = accentHue
        self.photonCount = max(512, photonCount)
    }

    public var body: some View {
        Canvas(rendersAsynchronously: false) { context, canvasSize in
            let fullN = waveTank.gridSize
            let renderN = min(40, fullN)
            let gain: Float = 5.5 + min(max(audioAmplitude, 0.0), 1.0) * 3.0

            let caustics = VolumetricCausticsDispatcher.shared.renderDownsampledCaustics(
                sourcePressure: waveTank.pressureCurr,
                sourceGridSize: fullN,
                renderGridSize: renderN,
                pressureGain: gain,
                requestedPhotons: photonCount
            )

            context.fill(
                Path(CGRect(origin: .zero, size: canvasSize)),
                with: .color(Color(red: 0.015, green: 0.022, blue: 0.048))
            )

            let cellW = canvasSize.width / CGFloat(renderN)
            let cellH = canvasSize.height / CGFloat(renderN)
            let prevBlend = context.blendMode
            context.blendMode = .plusLighter

            for ry in 0..<renderN {
                for rx in 0..<renderN {
                    let rgb = caustics[ry * renderN + rx]
                    let mapped = SIMD3<Float>(
                        rgb.x / (1.0 + rgb.x * 0.65),
                        rgb.y / (1.0 + rgb.y * 0.65),
                        rgb.z / (1.0 + rgb.z * 0.65)
                    )
                    let luma = max(mapped.x, max(mapped.y, mapped.z))
                    guard luma > 0.015 else { continue }

                    let clampedR = min(max(mapped.x, 0.0), 1.0)
                    let clampedG = min(max(mapped.y, 0.0), 1.0)
                    let clampedB = min(max(mapped.z, 0.0), 1.0)
                    let srgbR = Double(sqrtf(clampedR))
                    let srgbG = Double(sqrtf(clampedG))
                    let srgbB = Double(sqrtf(clampedB))

                    let rect = CGRect(
                        x: CGFloat(rx) * cellW - 0.5,
                        y: CGFloat(ry) * cellH - 0.5,
                        width: cellW + 1.0,
                        height: cellH + 1.0
                    )
                    context.fill(
                        Path(rect),
                        with: .color(Color(red: srgbR, green: srgbG, blue: srgbB))
                    )
                }
            }

            context.blendMode = prevBlend
        }
    }
}
