// MARK: - FILE: FDTDWaveguideSolver.swift

import Foundation
import Observation
import simd
#if canImport(Metal) && !os(watchOS)
import Metal
#endif

// MARK: - 1. 96-Byte Scalar-Aligned Host/GPU Uniform Contract (Matches `FDTDWaveguideKernels.metal`)

public struct FDTDWavefieldUniforms: Sendable, Equatable {
    public var gridWidth: UInt32
    public var gridHeight: UInt32
    public var gridDepth: UInt32
    public var pmlThickness: UInt32
    public var boundaryMode: UInt32
    public var stepIndex: UInt32
    public var lambdaSq: Float
    public var muSq: Float
    public var sigma0Dt: Float
    public var viscousCoeff: Float
    public var pmlSigmaMaxDt: Float
    public var nonlinearGamma: Float
    public var dtSquared: Float
    public var sourceX: Float
    public var sourceY: Float
    public var sourceZ: Float
    public var sourceValue: Float
    public var sourceSigmaCells: Float
    public var micLeftX: Float
    public var micLeftY: Float
    public var micRightX: Float
    public var micRightY: Float
    public var displayGain: Float
    public var accentHue: Float

    public init(
        gridWidth: UInt32 = 128,
        gridHeight: UInt32 = 128,
        gridDepth: UInt32 = 1,
        pmlThickness: UInt32 = 16,
        boundaryMode: UInt32 = 0,
        stepIndex: UInt32 = 0,
        lambdaSq: Float = 0.25,
        muSq: Float = 0.001,
        sigma0Dt: Float = 0.0002,
        viscousCoeff: Float = 0.0005,
        pmlSigmaMaxDt: Float = 0.32,
        nonlinearGamma: Float = 0.04,
        dtSquared: Float = 1.0e-8,
        sourceX: Float = 32.0,
        sourceY: Float = 64.0,
        sourceZ: Float = 0.0,
        sourceValue: Float = 0.0,
        sourceSigmaCells: Float = 2.6,
        micLeftX: Float = 84.0,
        micLeftY: Float = 46.0,
        micRightX: Float = 84.0,
        micRightY: Float = 82.0,
        displayGain: Float = 3.2,
        accentHue: Float = 0.54
    ) {
        self.gridWidth = gridWidth
        self.gridHeight = gridHeight
        self.gridDepth = gridDepth
        self.pmlThickness = pmlThickness
        self.boundaryMode = boundaryMode
        self.stepIndex = stepIndex
        self.lambdaSq = lambdaSq
        self.muSq = muSq
        self.sigma0Dt = sigma0Dt
        self.viscousCoeff = viscousCoeff
        self.pmlSigmaMaxDt = pmlSigmaMaxDt
        self.nonlinearGamma = nonlinearGamma
        self.dtSquared = dtSquared
        self.sourceX = sourceX
        self.sourceY = sourceY
        self.sourceZ = sourceZ
        self.sourceValue = sourceValue
        self.sourceSigmaCells = sourceSigmaCells
        self.micLeftX = micLeftX
        self.micLeftY = micLeftY
        self.micRightX = micRightX
        self.micRightY = micRightY
        self.displayGain = displayGain
        self.accentHue = accentHue
    }
}

// MARK: - 2. Courant-Friedrichs-Lewy (CFL) Von Neumann Stability Enforcer

public struct FDTDCFLParameters: Sendable, Equatable {
    /// Maximum discrete Laplacian eigenvalue `max_k(-L_hat(k*h))` for 1D 3-pt (`4`), 2D 9-pt ISO (`16/3`), and 3D 27-pt Patra-Karttunen (`92/15`).
    public static let maxCompactEigenvalue1D: Float = 4.0
    public static let maxCompactEigenvalue2D: Float = 16.0 / 3.0
    public static let maxCompactEigenvalue3D: Float = 92.0 / 15.0
    public static let safetyMarginFactor: Float = 0.96

    public let dimension: Int
    public let waveSpeed: Float
    public let stiffnessKappa: Float
    public let gridSpacingMeters: Float
    public let timeStepSeconds: Float
    public let sigma0: Float
    public let sigma1: Float

    /// Squared Courant number `lambda^2 = (c * dt / h)^2`, clamped to guarantee Von Neumann stability.
    public let lambdaSq: Float
    /// Squared fourth-order biharmonic stiffness parameter `mu^2 = (kappa * dt / h^2)^2`.
    public let muSq: Float
    /// Frequency-dependent visco-thermal damping coefficient `2 * sigma1 * dt / h^2`.
    public let viscousTerm: Float
    /// Theoretical Von Neumann stability ceiling `1 / D - 2 * sigma1 * dt / h^2`.
    public let stabilityCeiling: Float
    public let wasClampedForStability: Bool

    public var wasClamped: Bool { wasClampedForStability }
    public var courantLambda: Float { sqrtf(max(0.0, lambdaSq)) }
    public var stiffnessMu: Float { sqrtf(max(0.0, muSq)) }

    public static func maxCompactEigenvalue(forDimension dim: Int) -> Float {
        if dim >= 3 {
            return maxCompactEigenvalue3D
        } else if dim == 2 {
            return maxCompactEigenvalue2D
        }
        return maxCompactEigenvalue1D
    }

    public init(
        waveSpeedMetersPerSec: Float,
        stiffnessKappa: Float,
        sigma0: Float,
        sigma1: Float,
        timeStepSeconds: Float,
        gridSpacingMeters: Float,
        spatialDimensions: Int
    ) {
        self.init(
            dimension: spatialDimensions,
            waveSpeed: waveSpeedMetersPerSec,
            stiffnessKappa: stiffnessKappa,
            gridSpacingMeters: gridSpacingMeters,
            timeStepSeconds: timeStepSeconds,
            sigma0: sigma0,
            sigma1: sigma1
        )
    }

    /// Exact Schur-Cohn / Von Neumann stability predicate verifying both standard Courant `S <= 1/sqrt(D)`
    /// (`lambda^2 + 4*mu^2 + v <= 1/D`) and compact stencil spectral radius (`0.25*E_max*(lambda^2 + E_max*mu^2 + 2*v) <= 1`).
    public var isStable: Bool {
        let dimFactor = Float(max(1, dimension))
        let maxCompactEig = Self.maxCompactEigenvalue(forDimension: dimension)
        let compactTerm1 = 0.25 * maxCompactEig * lambdaSq
        let compactTerm2 = 0.25 * maxCompactEig * maxCompactEig * muSq
        let compactTerm3 = 0.50 * maxCompactEig * viscousTerm
        let compactDiscreteOK = (compactTerm1 + compactTerm2 + compactTerm3) <= 1.0 + 1.0e-5
            && (maxCompactEig * viscousTerm) <= 2.0 + 1.0e-5
        return lambdaSq >= 0.0
            && muSq >= 0.0
            && viscousTerm >= 0.0
            && (lambdaSq + 4.0 * muSq) <= (1.0 / dimFactor - viscousTerm) + 1.0e-5
            && compactDiscreteOK
    }

    public init(
        dimension: Int = 2,
        waveSpeed: Float = 343.0,
        stiffnessKappa: Float = 0.0,
        gridSpacingMeters: Float? = nil,
        timeStepSeconds: Float = 1.0 / 48_000.0,
        sigma0: Float = 1.2,
        sigma1: Float = 0.0004
    ) {
        let safeDim = min(max(dimension, 1), 3)
        let dimF = Float(safeDim)
        let safeDt = max(1.0e-7, timeStepSeconds)
        let safeC = max(1.0, waveSpeed)
        let safeKappa = max(0.0, stiffnessKappa)
        let safeSigma0 = max(0.0, sigma0)
        let safeSigma1 = max(0.0, sigma1)

        let baseTerm = dimF * safeC * safeC * safeDt * safeDt + 2.0 * dimF * safeSigma1 * safeDt
        let discTerm = powf(baseTerm, 2.0) + 16.0 * dimF * dimF * safeKappa * safeKappa * safeDt * safeDt
        let minRequiredH = sqrtf(baseTerm + sqrtf(discTerm))
        let h = max(1.0e-4, gridSpacingMeters ?? (minRequiredH * 1.12))
        let hSq = h * h

        let maxCompactEig = Self.maxCompactEigenvalue(forDimension: safeDim)
        let maxViscous = min(0.42 / dimF, (2.0 / maxCompactEig) * Self.safetyMarginFactor)
        let rawViscous = 2.0 * safeSigma1 * safeDt / hSq
        let clampedViscous = min(rawViscous, maxViscous)

        let ceiling = (1.0 / dimF) - clampedViscous
        let safeBudget = max(0.008, ceiling * Self.safetyMarginFactor)

        let rawLambda = safeC * safeDt / h
        let rawLambdaSq = rawLambda * rawLambda
        let rawMu = safeKappa * safeDt / hSq
        let rawMuSq = rawMu * rawMu

        // Enforce BOTH Von Neumann `lambda^2 + 4*mu^2 <= 1/D - viscous` AND compact-stencil `lambda^2 + E_max*mu^2 <= 4/E_max - 2*viscous`
        let discreteCeiling = max(0.008, (4.0 / maxCompactEig - 2.0 * clampedViscous) * Self.safetyMarginFactor)
        let effectiveCeiling = min(safeBudget, discreteCeiling)
        let biharmWeight = max(4.0, maxCompactEig)

        let combinedRaw = rawLambdaSq + biharmWeight * rawMuSq
        if combinedRaw <= effectiveCeiling && rawViscous <= maxViscous {
            self.lambdaSq = rawLambdaSq
            self.muSq = rawMuSq
            self.wasClampedForStability = false
        } else {
            let scale = effectiveCeiling / max(combinedRaw, 1.0e-9)
            self.lambdaSq = rawLambdaSq * scale
            self.muSq = rawMuSq * scale
            self.wasClampedForStability = true
        }

        self.dimension = safeDim
        self.waveSpeed = safeC
        self.stiffnessKappa = safeKappa
        self.gridSpacingMeters = h
        self.timeStepSeconds = safeDt
        self.sigma0 = safeSigma0
        self.sigma1 = safeSigma1
        self.viscousTerm = clampedViscous
        self.stabilityCeiling = ceiling
    }

    /// Returns a copy guaranteed to satisfy the CFL bound for `targetDimension` (e.g. when a 1D/2D struct is assigned to a 2D/3D tank).
    public func clamped(toDimension targetDimension: Int) -> FDTDCFLParameters {
        let safeTarget = min(max(targetDimension, 1), 3)
        if safeTarget == dimension && isStable {
            return self
        }
        return FDTDCFLParameters(
            dimension: safeTarget,
            waveSpeed: waveSpeed,
            stiffnessKappa: stiffnessKappa,
            gridSpacingMeters: gridSpacingMeters,
            timeStepSeconds: timeStepSeconds,
            sigma0: sigma0,
            sigma1: sigma1
        )
    }

    /// Maximum stable local `lambda^2` ceiling for a given spatial dimension after accounting for `viscousTerm` and `muSq`.
    public func maxLocalLambdaSq(forDimension targetDimension: Int? = nil) -> Float {
        let d = min(max(targetDimension ?? dimension, 1), 3)
        let dimF = Float(d)
        let eMax = Self.maxCompactEigenvalue(forDimension: d)
        let vSafe = min(max(0.0, viscousTerm), 0.42 / dimF)
        let stdMax = (1.0 / dimF - vSafe) * Self.safetyMarginFactor - 4.0 * muSq
        let compactMax = (4.0 / eMax - 2.0 * vSafe) * Self.safetyMarginFactor - eMax * muSq
        return max(0.0, min(stdMax, compactMax))
    }

    // MARK: - Von Neumann Numerical Dispersion Relation & Bandwidth Limits

    /// Discrete-to-continuous phase velocity ratio `c_num / c` from the Von Neumann dispersion relation
    /// `sin^2(omega * dt / 2) = (lambda^2 / 4) * (-L_hat(k * h))` for the 2D 9-pt ISO or 3D 27-pt Patra-Karttunen stencil.
    public static func phaseVelocityRatio(
        pointsPerWavelength ppw: Float,
        courantLambda lambda: Float,
        dimension: Int = 2,
        propagationAngleRadians theta: Float = 0.0
    ) -> Float {
        let safePPW = max(2.05, ppw)
        let safeLambda = min(max(lambda, 1.0e-4), 1.0 / sqrtf(Float(max(1, dimension))))
        let kh = (2.0 * Float.pi) / safePPW

        let negLapSymbol: Float
        if dimension >= 3 {
            // Evaluate along worst-case or specified angle in 3D (interpolating axial theta=0 to body-diagonal)
            let ux = cosf(theta)
            let uy = sinf(theta) * (1.0 / sqrtf(2.0))
            let uz = sinf(theta) * (1.0 / sqrtf(2.0))
            let cx = cosf(kh * ux)
            let cy = cosf(kh * uy)
            let cz = cosf(kh * uz)
            let faces = 2.0 * (cx + cy + cz)
            let edges = 4.0 * (cx * cy + cy * cz + cz * cx)
            let corners = 8.0 * cx * cy * cz
            let lap = (7.0 / 15.0) * faces + (1.0 / 10.0) * edges + (1.0 / 30.0) * corners - (64.0 / 15.0)
            negLapSymbol = max(0.0, -lap)
        } else if dimension == 2 {
            let kxH = kh * cosf(theta)
            let kyH = kh * sinf(theta)
            let cx = cosf(kxH)
            let cy = cosf(kyH)
            let lap = (4.0 / 3.0) * (cx + cy) + (2.0 / 3.0) * cx * cy - (10.0 / 3.0)
            negLapSymbol = max(0.0, -lap)
        } else {
            negLapSymbol = max(0.0, 2.0 - 2.0 * cosf(kh))
        }

        let sinArg = min(1.0, 0.5 * safeLambda * sqrtf(negLapSymbol))
        let omegaDt = 2.0 * asinf(sinArg)
        return omegaDt / max(1.0e-7, safeLambda * kh)
    }

    /// Worst-case directional relative phase velocity error `max_theta |c_num(ppw, theta)/c - 1|`.
    public static func worstDirectionalDispersionError(
        pointsPerWavelength ppw: Float,
        courantLambda lambda: Float,
        dimension: Int = 2
    ) -> Float {
        let errAxial = abs(phaseVelocityRatio(pointsPerWavelength: ppw, courantLambda: lambda, dimension: dimension, propagationAngleRadians: 0.0) - 1.0)
        let errDiag = abs(phaseVelocityRatio(pointsPerWavelength: ppw, courantLambda: lambda, dimension: dimension, propagationAngleRadians: Float.pi * 0.25) - 1.0)
        if dimension >= 3 {
            let bodyAngle = acosf(1.0 / sqrtf(3.0))
            let errBody = abs(phaseVelocityRatio(pointsPerWavelength: ppw, courantLambda: lambda, dimension: 3, propagationAngleRadians: bodyAngle) - 1.0)
            return max(errAxial, max(errDiag, errBody))
        }
        return max(errAxial, errDiag)
    }

    /// Minimum points-per-wavelength `N_ppw` required to keep numerical phase velocity dispersion within `maxPhaseVelocityError` (default 2%).
    public func minimumPointsPerWavelength(maxPhaseVelocityError tolerance: Float = 0.02) -> Float {
        let safeTol = min(max(tolerance, 0.001), 0.15)
        let lam = max(0.05, courantLambda)
        var low: Float = 2.2
        var high: Float = 64.0
        for _ in 0..<24 {
            let mid = 0.5 * (low + high)
            let err = Self.worstDirectionalDispersionError(
                pointsPerWavelength: mid,
                courantLambda: lam,
                dimension: dimension
            )
            if err <= safeTol {
                high = mid
            } else {
                low = mid
            }
        }
        return high
    }

    /// Maximum physical frequency `f_max = c_eff / (h * N_ppw)` before numerical phase-velocity dispersion exceeds `maxPhaseVelocityError`.
    public func dispersionLimitedMaxFrequency(maxPhaseVelocityError tolerance: Float = 0.02) -> Float {
        let ppw = minimumPointsPerWavelength(maxPhaseVelocityError: tolerance)
        let effectiveWaveSpeed = courantLambda * gridSpacingMeters / max(1.0e-7, timeStepSeconds)
        let nyquistCap = 0.45 / max(1.0e-7, timeStepSeconds)
        return min(nyquistCap, effectiveWaveSpeed / max(1.0e-5, gridSpacingMeters * ppw))
    }

    /// Default 2% phase-velocity dispersion cutoff frequency `f_max` in Hz.
    public var dispersionLimitedMaxFrequency: Float {
        dispersionLimitedMaxFrequency(maxPhaseVelocityError: 0.02)
    }

    /// Recommended excitation source -3 dB bandwidth in Hz to prevent high-frequency numerical dispersion rings.
    public var recommendedSourceBandwidth: Float {
        dispersionLimitedMaxFrequency(maxPhaseVelocityError: 0.02)
    }

    /// Minimum spatial Gaussian standard deviation `sigma_min` (in grid cells) whose -3 dB wavenumber stays below `k_max = 2*pi / N_ppw`.
    public func minimumGaussianSigmaCells(maxPhaseVelocityError tolerance: Float = 0.02) -> Float {
        let ppw = minimumPointsPerWavelength(maxPhaseVelocityError: tolerance)
        // Half-power (-3 dB) wavenumber for exp(-r^2/(2*sigma^2)) is k_3dB * h = sqrt(ln 2) / sigma <= 2*pi / ppw
        let sigma3dB = (sqrtf(logf(2.0)) / (2.0 * Float.pi)) * ppw
        return max(1.2, sigma3dB)
    }
}

// MARK: - 3. Pre-Allocated Flat `UnsafeMutablePointer<Float>` Audio-Rate 24x24 SIMD4 Waveguide Mesh

private final class RawFDTDMeshArena: @unchecked Sendable {
    let cellCount: Int
    var pNext: UnsafeMutablePointer<Float>
    var pCurr: UnsafeMutablePointer<Float>
    var pPrev: UnsafeMutablePointer<Float>
    let lapCurrScratch: UnsafeMutablePointer<Float>
    let lapPrevScratch: UnsafeMutablePointer<Float>
    let pmlDamping: UnsafeMutablePointer<Float>
    let obstacleMask: UnsafeMutablePointer<UInt8>

    init(gridDimension: Int, pmlWidth: Int = 3, pmlSigmaMaxDt: Float = 0.085) {
        let count = gridDimension * gridDimension
        self.cellCount = count

        self.pNext = UnsafeMutablePointer<Float>.allocate(capacity: count)
        self.pCurr = UnsafeMutablePointer<Float>.allocate(capacity: count)
        self.pPrev = UnsafeMutablePointer<Float>.allocate(capacity: count)
        self.lapCurrScratch = UnsafeMutablePointer<Float>.allocate(capacity: count)
        self.lapPrevScratch = UnsafeMutablePointer<Float>.allocate(capacity: count)
        self.pmlDamping = UnsafeMutablePointer<Float>.allocate(capacity: count)
        self.obstacleMask = UnsafeMutablePointer<UInt8>.allocate(capacity: count)

        self.pNext.initialize(repeating: 0.0, count: count)
        self.pCurr.initialize(repeating: 0.0, count: count)
        self.pPrev.initialize(repeating: 0.0, count: count)
        self.lapCurrScratch.initialize(repeating: 0.0, count: count)
        self.lapPrevScratch.initialize(repeating: 0.0, count: count)
        self.obstacleMask.initialize(repeating: 0, count: count)

        let safeSigmaMax = min(max(0.0, pmlSigmaMaxDt), 0.48)
        for y in 0..<gridDimension {
            let dy = min(y, gridDimension - 1 - y)
            let sy: Float
            if dy < pmlWidth {
                let uy = Float(pmlWidth - dy) / Float(pmlWidth)
                sy = safeSigmaMax * uy * uy * uy
            } else {
                sy = 0.0
            }
            for x in 0..<gridDimension {
                let dx = min(x, gridDimension - 1 - x)
                let sx: Float
                if dx < pmlWidth {
                    let ux = Float(pmlWidth - dx) / Float(pmlWidth)
                    sx = safeSigmaMax * ux * ux * ux
                } else {
                    sx = 0.0
                }
                self.pmlDamping[y * gridDimension + x] = min(sx + sy, 0.96)
            }
        }
    }

    init(cloning other: RawFDTDMeshArena) {
        let count = other.cellCount
        self.cellCount = count
        self.pNext = UnsafeMutablePointer<Float>.allocate(capacity: count)
        self.pCurr = UnsafeMutablePointer<Float>.allocate(capacity: count)
        self.pPrev = UnsafeMutablePointer<Float>.allocate(capacity: count)
        self.lapCurrScratch = UnsafeMutablePointer<Float>.allocate(capacity: count)
        self.lapPrevScratch = UnsafeMutablePointer<Float>.allocate(capacity: count)
        self.pmlDamping = UnsafeMutablePointer<Float>.allocate(capacity: count)
        self.obstacleMask = UnsafeMutablePointer<UInt8>.allocate(capacity: count)

        self.pNext.initialize(from: other.pNext, count: count)
        self.pCurr.initialize(from: other.pCurr, count: count)
        self.pPrev.initialize(from: other.pPrev, count: count)
        self.lapCurrScratch.initialize(from: other.lapCurrScratch, count: count)
        self.lapPrevScratch.initialize(from: other.lapPrevScratch, count: count)
        self.pmlDamping.initialize(from: other.pmlDamping, count: count)
        self.obstacleMask.initialize(from: other.obstacleMask, count: count)
    }

    deinit {
        pNext.deinitialize(count: cellCount)
        pNext.deallocate()
        pCurr.deinitialize(count: cellCount)
        pCurr.deallocate()
        pPrev.deinitialize(count: cellCount)
        pPrev.deallocate()
        lapCurrScratch.deinitialize(count: cellCount)
        lapCurrScratch.deallocate()
        lapPrevScratch.deinitialize(count: cellCount)
        lapPrevScratch.deallocate()
        pmlDamping.deinitialize(count: cellCount)
        pmlDamping.deallocate()
        obstacleMask.deinitialize(count: cellCount)
        obstacleMask.deallocate()
    }

    @inline(__always)
    func rotateTripleBuffers() {
        let recycled = pPrev
        pPrev = pCurr
        pCurr = pNext
        pNext = recycled
    }

    func zeroWaveState() {
        pNext.update(repeating: 0.0, count: cellCount)
        pCurr.update(repeating: 0.0, count: cellCount)
        pPrev.update(repeating: 0.0, count: cellCount)
        lapCurrScratch.update(repeating: 0.0, count: cellCount)
        lapPrevScratch.update(repeating: 0.0, count: cellCount)
    }
}

public struct RealtimeFDTDResonatorKernel: @unchecked Sendable {
    public static let gridDimension: Int = 24
    public static let cellCount: Int = 576
    /// Reference audio sample rate (48 kHz) at which discrete plate modal parameters are calibrated.
    public static let referenceSampleRate: Double = 48_000.0
    /// One-pole DC-blocker feedback pole `R = 0.9965` (~26.7 Hz high-pass corner at 48 kHz).
    public static let dcBlockerPole: Float = 0.9965
    /// Output hyperbolic tangent soft-clip drive gain.
    public static let outputSaturationDrive: Float = 2.1
    /// Maximum input excitation magnitude before spatial force injection.
    public static let maxExcitationAmplitude: Float = 2.5
    /// Force injection coupling gain into the 3x3 excitation footprint.
    public static let excitationInjectionGain: Float = 0.14
    /// Per-cell hard pressure safety clamp for real-time audio stability.
    public static let pressureSafetyClamp: Float = 4.0

    public let sampleRate: Double
    private let dt: Float
    private let rateScale: Float
    private var arena: RawFDTDMeshArena

    // One-pole DC-blocking filters for stereo virtual microphone probes
    private var dcBlockXLeft: Float = 0.0
    private var dcBlockYLeft: Float = 0.0
    private var dcBlockXRight: Float = 0.0
    private var dcBlockYRight: Float = 0.0

    // Pre-allocated 2nd-order Butterworth anti-dispersion low-pass biquad state (zero heap allocation)
    private var excLPZ1: Float = 0.0
    private var excLPZ2: Float = 0.0
    private var excLPB0: Float = 1.0
    private var excLPB1: Float = 0.0
    private var excLPB2: Float = 0.0
    private var excLPA1: Float = 0.0
    private var excLPA2: Float = 0.0
    private var cachedCutoffLambdaSq: Float = -1.0

    public var leftMicNormalized: SIMD2<Float> = SIMD2<Float>(0.30, 0.44)
    public var rightMicNormalized: SIMD2<Float> = SIMD2<Float>(0.70, 0.56)

    public var pNextPointer: UnsafeMutablePointer<Float> { arena.pNext }
    public var pCurrPointer: UnsafeMutablePointer<Float> { arena.pCurr }
    public var pPrevPointer: UnsafeMutablePointer<Float> { arena.pPrev }
    public var pmlDampingPointer: UnsafeMutablePointer<Float> { arena.pmlDamping }
    public var obstacleMaskPointer: UnsafeMutablePointer<UInt8> { arena.obstacleMask }

    public init(sampleRate: Double = 48_000.0) {
        let safeRate = max(8_000.0, sampleRate)
        self.sampleRate = safeRate
        self.dt = Float(1.0 / safeRate)
        self.rateScale = Float(Self.referenceSampleRate / safeRate)
        self.arena = RawFDTDMeshArena(
            gridDimension: Self.gridDimension,
            pmlWidth: 3,
            pmlSigmaMaxDt: min(0.45, 0.085 * Float(Self.referenceSampleRate / safeRate))
        )
    }

    /// Computes CFL-guaranteed `(baseLambdaSq, maxLocalLambdaSq, muSq, viscous)` for the 24x24 9-point isotropic resonator.
    @inline(__always)
    public func resolveStableCoefficients(
        waveSpeed: Float,
        stiffnessKappa: Float,
        dampingSigma: Float
    ) -> (baseLambdaSq: Float, maxLocalLambdaSq: Float, muSq: Float, viscous: Float) {
        let normSpeed = min(max((waveSpeed - 80.0) / 600.0, 0.0), 1.0)
        let normKappa = min(max(stiffnessKappa, 0.0), 1.0)
        let dampNorm = min(max(dampingSigma * 0.1, 0.0), 1.0)

        let rawViscous: Float = (0.0025 + 0.0035 * dampNorm) * rateScale
        let viscous: Float = min(max(0.0, rawViscous), 0.21)

        let stdBudget: Float = (0.5 - viscous) * 0.95
        let compactBudget: Float = (0.75 - 2.0 * viscous) * 0.95
        let cflBudget: Float = max(0.015, min(stdBudget, compactBudget))

        let rateScaleSq: Float = rateScale * rateScale
        let rawMuSq: Float = (0.0008 + 0.0165 * normKappa * normKappa) * rateScaleSq
        let muSq: Float = min(rawMuSq, cflBudget / 8.0)

        let rawLambdaSq: Float = (0.055 + 0.245 * normSpeed) * rateScaleSq
        let biharmPenalty: Float = (16.0 / 3.0) * muSq
        let maxLocalLambdaSq: Float = max(0.01, cflBudget - biharmPenalty)
        let baseLambdaSq: Float = min(rawLambdaSq, max(0.015, cflBudget - 6.0 * muSq))
        return (baseLambdaSq, maxLocalLambdaSq, muSq, viscous)
    }

    /// Maximum excitation frequency `f_max` in Hz before 2D 9-point isotropic numerical dispersion exceeds `maxPhaseVelocityError`.
    public func dispersionLimitedMaxFrequency(
        waveSpeed: Float = 343.0,
        stiffnessKappa: Float = 0.18,
        dampingSigma: Float = 1.8,
        maxPhaseVelocityError: Float = 0.02
    ) -> Float {
        let coeffs = resolveStableCoefficients(
            waveSpeed: waveSpeed,
            stiffnessKappa: stiffnessKappa,
            dampingSigma: dampingSigma
        )
        let lambda = sqrtf(max(1.0e-4, coeffs.baseLambdaSq))
        let safeTol = min(max(maxPhaseVelocityError, 0.002), 0.15)
        var low: Float = 2.2
        var high: Float = 32.0
        for _ in 0..<20 {
            let mid = 0.5 * (low + high)
            let err = FDTDCFLParameters.worstDirectionalDispersionError(
                pointsPerWavelength: mid,
                courantLambda: lambda,
                dimension: 2
            )
            if err <= safeTol {
                high = mid
            } else {
                low = mid
            }
        }
        let fs = Float(sampleRate)
        return min(0.45 * fs, (lambda / high) * fs)
    }

    public var dispersionLimitedMaxFrequency: Float {
        dispersionLimitedMaxFrequency(waveSpeed: 343.0)
    }

    public var recommendedSourceBandwidth: Float {
        dispersionLimitedMaxFrequency(waveSpeed: 343.0)
    }

    @inline(__always)
    private mutating func updateExcitationLowPassIfNeeded(baseLambdaSq: Float) {
        guard abs(baseLambdaSq - cachedCutoffLambdaSq) > 1.0e-5 else { return }
        cachedCutoffLambdaSq = baseLambdaSq
        let lambda = sqrtf(max(1.0e-4, baseLambdaSq))
        let ppw = FDTDCFLParameters.worstDirectionalDispersionError(
            pointsPerWavelength: 6.5,
            courantLambda: lambda,
            dimension: 2
        ) <= 0.025 ? 6.5 : 8.0
        let fs = Float(sampleRate)
        let fc = min(max((lambda / ppw) * fs, 180.0), 0.44 * fs)
        let w0 = 2.0 * Float.pi * fc / fs
        let cosW0 = cosf(w0)
        let sinW0 = sinf(w0)
        let alpha = sinW0 * 0.70710678
        let invA0 = 1.0 / (1.0 + alpha)
        let b1 = (1.0 - cosW0) * invA0
        excLPB0 = 0.5 * b1
        excLPB1 = b1
        excLPB2 = 0.5 * b1
        excLPA1 = -2.0 * cosW0 * invA0
        excLPA2 = (1.0 - alpha) * invA0
    }

    @inline(__always)
    private mutating func filterExcitationBandLimited(_ rawExcitation: Float, baseLambdaSq: Float) -> Float {
        updateExcitationLowPassIfNeeded(baseLambdaSq: baseLambdaSq)
        let x = min(max(rawExcitation, -Self.maxExcitationAmplitude), Self.maxExcitationAmplitude)
        let y = excLPB0 * x + excLPZ1
        excLPZ1 = excLPB1 * x - excLPA1 * y + excLPZ2
        excLPZ2 = excLPB2 * x - excLPA2 * y
        return y.isFinite ? y : 0.0
    }

    /// Ensures independent state if a parent `ProceduralSynthKernel` struct was copied before rendering.
    public mutating func detachCopyIfShared() {
        if !isKnownUniquelyReferenced(&arena) {
            arena = RawFDTDMeshArena(cloning: arena)
        }
    }

    public mutating func reset() {
        arena.zeroWaveState()
        dcBlockXLeft = 0.0
        dcBlockYLeft = 0.0
        dcBlockXRight = 0.0
        dcBlockYRight = 0.0
        excLPZ1 = 0.0
        excLPZ2 = 0.0
        cachedCutoffLambdaSq = -1.0
    }

    /// Injects a raised-cosine spatial pluck directly into the pre-allocated flat `pCurr`/`pPrev` pointers (zero heap allocation).
    @inline(__always)
    public mutating func triggerRaisedCosinePluck(
        normalizedX: Float = 0.5,
        normalizedY: Float = 0.5,
        amplitude: Float = 0.85,
        radiusCells: Float = 2.6
    ) {
        let n = Self.gridDimension
        let cx = 2.5 + min(max(normalizedX, 0.0), 1.0) * Float(n - 6)
        let cy = 2.5 + min(max(normalizedY, 0.0), 1.0) * Float(n - 6)
        let rMax = max(1.5, radiusCells)
        let pCurr = arena.pCurr
        let pPrev = arena.pPrev
        let obs = arena.obstacleMask

        let xMin = max(2, Int(floorf(cx - rMax)))
        let xMax = min(n - 3, Int(ceilf(cx + rMax)))
        let yMin = max(2, Int(floorf(cy - rMax)))
        let yMax = min(n - 3, Int(ceilf(cy + rMax)))

        for y in yMin...yMax {
            let row = y * n
            for x in xMin...xMax {
                let idx = row + x
                if obs[idx] != 0 { continue }
                let dist = hypotf(Float(x) - cx, Float(y) - cy)
                if dist <= rMax {
                    let window = 0.5 * (1.0 + cosf(Float.pi * dist / rMax))
                    let delta = amplitude * window
                    pCurr[idx] += delta
                    pPrev[idx] += delta
                }
            }
        }
    }

    @inline(__always)
    private static func readBilinearPointer(
        _ field: UnsafePointer<Float>,
        normalizedXY: SIMD2<Float>
    ) -> Float {
        let n = gridDimension
        let gx = 2.0 + min(max(normalizedXY.x, 0.0), 1.0) * Float(n - 5)
        let gy = 2.0 + min(max(normalizedXY.y, 0.0), 1.0) * Float(n - 5)
        let x0 = min(max(Int(gx), 1), n - 3)
        let y0 = min(max(Int(gy), 1), n - 3)
        let fx = gx - Float(x0)
        let fy = gy - Float(y0)

        let row0 = y0 * n
        let row1 = (y0 + 1) * n
        let v00 = field[row0 + x0]
        let v10 = field[row0 + x0 + 1]
        let v01 = field[row1 + x0]
        let v11 = field[row1 + x0 + 1]

        let top = v00 + fx * (v10 - v00)
        let bot = v01 + fx * (v11 - v01)
        return top + fy * (bot - top)
    }

    @inline(__always)
    private static func scalarLaplacian9PtAt(
        _ field: UnsafePointer<Float>,
        row: Int,
        rowM1: Int,
        rowP1: Int,
        x: Int
    ) -> Float {
        let idx = row + x
        let c = field[idx]
        let ax = field[idx - 1] + field[idx + 1] + field[rowM1 + x] + field[rowP1 + x]
        let dg = field[rowM1 + x - 1] + field[rowM1 + x + 1] + field[rowP1 + x - 1] + field[rowP1 + x + 1]
        return (2.0 / 3.0) * ax + (1.0 / 6.0) * dg - (10.0 / 3.0) * c
    }

    @inline(__always)
    private static func simd4Laplacian9PtAt(
        _ field: UnsafePointer<Float>,
        row: Int,
        rowM1: Int,
        rowP1: Int,
        x: Int,
        twoThirds: SIMD4<Float>,
        oneSixth: SIMD4<Float>,
        tenThirds: SIMD4<Float>
    ) -> SIMD4<Float> {
        let base = row + x
        let cVec = SIMD4<Float>(field[base], field[base + 1], field[base + 2], field[base + 3])
        let lVec = SIMD4<Float>(field[base - 1], field[base], field[base + 1], field[base + 2])
        let rVec = SIMD4<Float>(field[base + 1], field[base + 2], field[base + 3], field[base + 4])
        let dVec = SIMD4<Float>(field[rowM1 + x], field[rowM1 + x + 1], field[rowM1 + x + 2], field[rowM1 + x + 3])
        let uVec = SIMD4<Float>(field[rowP1 + x], field[rowP1 + x + 1], field[rowP1 + x + 2], field[rowP1 + x + 3])

        let dlVec = SIMD4<Float>(field[rowM1 + x - 1], field[rowM1 + x], field[rowM1 + x + 1], field[rowM1 + x + 2])
        let drVec = SIMD4<Float>(field[rowM1 + x + 1], field[rowM1 + x + 2], field[rowM1 + x + 3], field[rowM1 + x + 4])
        let ulVec = SIMD4<Float>(field[rowP1 + x - 1], field[rowP1 + x], field[rowP1 + x + 1], field[rowP1 + x + 2])
        let urVec = SIMD4<Float>(field[rowP1 + x + 1], field[rowP1 + x + 2], field[rowP1 + x + 3], field[rowP1 + x + 4])

        let axialVec: SIMD4<Float> = (lVec + rVec) + (dVec + uVec)
        let diagVec: SIMD4<Float> = (dlVec + drVec) + (ulVec + urVec)
        let scaledAxial: SIMD4<Float> = twoThirds * axialVec
        let scaledDiag: SIMD4<Float> = oneSixth * diagVec
        let scaledCenter: SIMD4<Float> = tenThirds * cVec
        return (scaledAxial + scaledDiag) - scaledCenter
    }

    /// Real-time SIMD4 audio-rate FDTD waveguide step operating strictly on flat `UnsafeMutablePointer<Float>` grids (zero heap allocation).
    @inline(__always)
    public mutating func stepSample(
        excitation: Float,
        waveSpeed: Float = 343.0,
        stiffnessKappa: Float = 0.18,
        dampingSigma: Float = 1.8,
        nonlinearGamma: Float = 0.08,
        sourceXY: SIMD2<Float> = SIMD2<Float>(0.50, 0.50),
        micLeftXY: SIMD2<Float>? = nil,
        micRightXY: SIMD2<Float>? = nil
    ) -> (Float, Float) {
        let n = Self.gridDimension
        let pCurr = arena.pCurr
        let pPrev = arena.pPrev
        let pNext = arena.pNext
        let lapScratch = arena.lapCurrScratch
        let lapPrevScratch = arena.lapPrevScratch
        let pml = arena.pmlDamping
        let obs = arena.obstacleMask

        let coeffs = resolveStableCoefficients(
            waveSpeed: waveSpeed,
            stiffnessKappa: stiffnessKappa,
            dampingSigma: dampingSigma
        )
        let baseLambdaSq = coeffs.baseLambdaSq
        let maxLocalLambda = coeffs.maxLocalLambdaSq
        let muSq = coeffs.muSq
        let viscous = coeffs.viscous
        let sigma0Dt: Float = max(0.2, dampingSigma) * dt
        let gammaNL: Float = min(max(nonlinearGamma, 0.0), 0.35)

        let bandLimitedExcitation = filterExcitationBandLimited(excitation, baseLambdaSq: baseLambdaSq)
        let boundedDrive = bandLimitedExcitation * Self.excitationInjectionGain

        // Pass 1: SIMD4-vectorized isotropic 9-point compact Laplacian L_h(p^n) and L_h(p^{n-1}) over interior [1 ..< n-1]
        let twoThirds = SIMD4<Float>(repeating: 2.0 / 3.0)
        let oneSixth = SIMD4<Float>(repeating: 1.0 / 6.0)
        let tenThirds = SIMD4<Float>(repeating: 10.0 / 3.0)

        for y in 1..<(n - 1) {
            let row = y * n
            let rowM1 = (y - 1) * n
            let rowP1 = (y + 1) * n

            // Border columns x = 1 and x = 22 (zero array literal allocation on audio thread)
            let idxLeft = row + 1
            if obs[idxLeft] != 0 {
                lapScratch[idxLeft] = 0.0
                lapPrevScratch[idxLeft] = 0.0
            } else {
                lapScratch[idxLeft] = Self.scalarLaplacian9PtAt(pCurr, row: row, rowM1: rowM1, rowP1: rowP1, x: 1)
                lapPrevScratch[idxLeft] = Self.scalarLaplacian9PtAt(pPrev, row: row, rowM1: rowM1, rowP1: rowP1, x: 1)
            }

            let idxRight = row + (n - 2)
            if obs[idxRight] != 0 {
                lapScratch[idxRight] = 0.0
                lapPrevScratch[idxRight] = 0.0
            } else {
                lapScratch[idxRight] = Self.scalarLaplacian9PtAt(pCurr, row: row, rowM1: rowM1, rowP1: rowP1, x: n - 2)
                lapPrevScratch[idxRight] = Self.scalarLaplacian9PtAt(pPrev, row: row, rowM1: rowM1, rowP1: rowP1, x: n - 2)
            }

            // 20 interior columns [2..21] as 5 contiguous SIMD4 vectors
            var x = 2
            while x <= 18 {
                let base = row + x
                let lapCVec = Self.simd4Laplacian9PtAt(
                    pCurr,
                    row: row,
                    rowM1: rowM1,
                    rowP1: rowP1,
                    x: x,
                    twoThirds: twoThirds,
                    oneSixth: oneSixth,
                    tenThirds: tenThirds
                )
                let lapPVec = Self.simd4Laplacian9PtAt(
                    pPrev,
                    row: row,
                    rowM1: rowM1,
                    rowP1: rowP1,
                    x: x,
                    twoThirds: twoThirds,
                    oneSixth: oneSixth,
                    tenThirds: tenThirds
                )

                lapScratch[base] = obs[base] == 0 ? lapCVec[0] : 0.0
                lapScratch[base + 1] = obs[base + 1] == 0 ? lapCVec[1] : 0.0
                lapScratch[base + 2] = obs[base + 2] == 0 ? lapCVec[2] : 0.0
                lapScratch[base + 3] = obs[base + 3] == 0 ? lapCVec[3] : 0.0

                lapPrevScratch[base] = obs[base] == 0 ? lapPVec[0] : 0.0
                lapPrevScratch[base + 1] = obs[base + 1] == 0 ? lapPVec[1] : 0.0
                lapPrevScratch[base + 2] = obs[base + 2] == 0 ? lapPVec[2] : 0.0
                lapPrevScratch[base + 3] = obs[base + 3] == 0 ? lapPVec[3] : 0.0
                x += 4
            }
        }

        // Pass 2: Full SIMD4 time-marching with biharmonic L_h^2(p^n), visco-thermal damping & cubic tension modulation
        let srcCellX = min(max(Int((2.0 + min(max(sourceXY.x, 0.0), 1.0) * Float(n - 5)).rounded()), 2), n - 3)
        let srcCellY = min(max(Int((2.0 + min(max(sourceXY.y, 0.0), 1.0) * Float(n - 5)).rounded()), 2), n - 3)

        let halfVec = SIMD4<Float>(repeating: 0.5)
        let oneVec = SIMD4<Float>(repeating: 1.0)
        let twoVec = SIMD4<Float>(repeating: 2.0)
        let gradCapVec = SIMD4<Float>(repeating: 1.5)
        let baseLambdaVec = SIMD4<Float>(repeating: baseLambdaSq)
        let maxLambdaVec = SIMD4<Float>(repeating: maxLocalLambda)
        let gammaVec = SIMD4<Float>(repeating: gammaNL)
        let viscousVec = SIMD4<Float>(repeating: viscous)
        let muSqVec = SIMD4<Float>(repeating: muSq)
        let sigma0DtVec = SIMD4<Float>(repeating: sigma0Dt)
        let minClampVec = SIMD4<Float>(repeating: -Self.pressureSafetyClamp)
        let maxClampVec = SIMD4<Float>(repeating: Self.pressureSafetyClamp)

        for y in 2..<(n - 2) {
            let row = y * n
            let rowM1 = (y - 1) * n
            let rowP1 = (y + 1) * n
            let dySrc = abs(y - srcCellY)

            var x = 2
            while x <= 18 {
                let base = row + x
                let p0Vec = SIMD4<Float>(pCurr[base], pCurr[base + 1], pCurr[base + 2], pCurr[base + 3])
                let pOldVec = SIMD4<Float>(pPrev[base], pPrev[base + 1], pPrev[base + 2], pPrev[base + 3])
                let lapCVec = SIMD4<Float>(lapScratch[base], lapScratch[base + 1], lapScratch[base + 2], lapScratch[base + 3])
                let lapPVec = SIMD4<Float>(lapPrevScratch[base], lapPrevScratch[base + 1], lapPrevScratch[base + 2], lapPrevScratch[base + 3])

                let biharmVec = Self.simd4Laplacian9PtAt(
                    lapScratch,
                    row: row,
                    rowM1: rowM1,
                    rowP1: rowP1,
                    x: x,
                    twoThirds: twoThirds,
                    oneSixth: oneSixth,
                    tenThirds: tenThirds
                )

                let lCurr = SIMD4<Float>(pCurr[base - 1], pCurr[base], pCurr[base + 1], pCurr[base + 2])
                let rCurr = SIMD4<Float>(pCurr[base + 1], pCurr[base + 2], pCurr[base + 3], pCurr[base + 4])
                let dCurr = SIMD4<Float>(pCurr[rowM1 + x], pCurr[rowM1 + x + 1], pCurr[rowM1 + x + 2], pCurr[rowM1 + x + 3])
                let uCurr = SIMD4<Float>(pCurr[rowP1 + x], pCurr[rowP1 + x + 1], pCurr[rowP1 + x + 2], pCurr[rowP1 + x + 3])

                let gxVec: SIMD4<Float> = halfVec * (rCurr - lCurr)
                let gyVec: SIMD4<Float> = halfVec * (uCurr - dCurr)
                let rawGradSq: SIMD4<Float> = gxVec * gxVec + gyVec * gyVec
                let gradSqVec: SIMD4<Float> = simd_min(rawGradSq, gradCapVec)
                let nlFactor: SIMD4<Float> = oneVec + gammaVec * gradSqVec
                let effLambdaVec: SIMD4<Float> = simd_min(baseLambdaVec * nlFactor, maxLambdaVec)

                var forceVec = SIMD4<Float>.zero
                if dySrc <= 1 {
                    for lane in 0..<4 {
                        let dxSrc = abs((x + lane) - srcCellX)
                        if dxSrc <= 1 {
                            let weight: Float = (dxSrc == 0 && dySrc == 0) ? 1.0 : ((dxSrc + dySrc == 1) ? 0.5 : 0.25)
                            forceVec[lane] = boundedDrive * weight
                        }
                    }
                }

                let pmlVec = SIMD4<Float>(pml[base], pml[base + 1], pml[base + 2], pml[base + 3])
                let lossVec: SIMD4<Float> = sigma0DtVec + pmlVec
                let invDenomVec: SIMD4<Float> = oneVec / (oneVec + lossVec)

                let waveTerm: SIMD4<Float> = twoVec * p0Vec - (oneVec - lossVec) * pOldVec
                let lapTerm: SIMD4<Float> = effLambdaVec * lapCVec + viscousVec * (lapCVec - lapPVec)
                let stiffTerm: SIMD4<Float> = muSqVec * biharmVec
                let totalNumer: SIMD4<Float> = (waveTerm + lapTerm) - stiffTerm + forceVec
                let nextVec: SIMD4<Float> = invDenomVec * totalNumer
                let clampedVec: SIMD4<Float> = simd_clamp(nextVec, minClampVec, maxClampVec)

                for lane in 0..<4 {
                    let idx = base + lane
                    if obs[idx] != 0 {
                        pNext[idx] = 0.0
                    } else {
                        let v = nextVec[lane]
                        pNext[idx] = v.isFinite ? clampedVec[lane] : 0.0
                    }
                }
                x += 4
            }
        }

        let effLeftMic = micLeftXY ?? leftMicNormalized
        let effRightMic = micRightXY ?? rightMicNormalized
        let rawL = Self.readBilinearPointer(pNext, normalizedXY: effLeftMic)
        let rawR = Self.readBilinearPointer(pNext, normalizedXY: effRightMic)
        arena.rotateTripleBuffers()

        // Zero-drift DC blocker + hyperbolic saturation
        let yL = rawL - dcBlockXLeft + Self.dcBlockerPole * dcBlockYLeft
        dcBlockXLeft = rawL
        dcBlockYLeft = yL

        let yR = rawR - dcBlockXRight + Self.dcBlockerPole * dcBlockYRight
        dcBlockXRight = rawR
        dcBlockYRight = yR

        return (tanhf(yL * Self.outputSaturationDrive), tanhf(yR * Self.outputSaturationDrive))
    }

    /// Scalar reference implementation of `stepSample` for numerical equivalence verification in unit tests.
    public mutating func stepSampleScalarReference(
        excitation: Float,
        waveSpeed: Float = 343.0,
        stiffnessKappa: Float = 0.18,
        dampingSigma: Float = 1.8,
        nonlinearGamma: Float = 0.08,
        sourceXY: SIMD2<Float> = SIMD2<Float>(0.50, 0.50),
        micLeftXY: SIMD2<Float>? = nil,
        micRightXY: SIMD2<Float>? = nil
    ) -> (Float, Float) {
        let n = Self.gridDimension
        let pCurr = arena.pCurr
        let pPrev = arena.pPrev
        let pNext = arena.pNext
        let lapScratch = arena.lapCurrScratch
        let pml = arena.pmlDamping
        let obs = arena.obstacleMask

        let coeffs = resolveStableCoefficients(
            waveSpeed: waveSpeed,
            stiffnessKappa: stiffnessKappa,
            dampingSigma: dampingSigma
        )
        let baseLambdaSq = coeffs.baseLambdaSq
        let maxLocalLambda = coeffs.maxLocalLambdaSq
        let muSq = coeffs.muSq
        let viscous = coeffs.viscous
        let sigma0Dt: Float = max(0.2, dampingSigma) * dt
        let gammaNL: Float = min(max(nonlinearGamma, 0.0), 0.35)

        let bandLimitedExcitation = filterExcitationBandLimited(excitation, baseLambdaSq: baseLambdaSq)
        let boundedDrive = bandLimitedExcitation * Self.excitationInjectionGain

        for y in 1..<(n - 1) {
            let row = y * n
            let rowM1 = (y - 1) * n
            let rowP1 = (y + 1) * n
            for x in 1..<(n - 1) {
                let idx = row + x
                if obs[idx] != 0 {
                    lapScratch[idx] = 0.0
                } else {
                    lapScratch[idx] = Self.scalarLaplacian9PtAt(pCurr, row: row, rowM1: rowM1, rowP1: rowP1, x: x)
                }
            }
        }

        let srcCellX = min(max(Int((2.0 + min(max(sourceXY.x, 0.0), 1.0) * Float(n - 5)).rounded()), 2), n - 3)
        let srcCellY = min(max(Int((2.0 + min(max(sourceXY.y, 0.0), 1.0) * Float(n - 5)).rounded()), 2), n - 3)

        for y in 2..<(n - 2) {
            let row = y * n
            let rowM1 = (y - 1) * n
            let rowP1 = (y + 1) * n
            for cx in 2..<(n - 2) {
                let idx = row + cx
                if obs[idx] != 0 {
                    pNext[idx] = 0.0
                    continue
                }
                let p0 = pCurr[idx]
                let pOld = pPrev[idx]
                let lapC = lapScratch[idx]
                let lapP = Self.scalarLaplacian9PtAt(pPrev, row: row, rowM1: rowM1, rowP1: rowP1, x: cx)
                let biharm = Self.scalarLaplacian9PtAt(lapScratch, row: row, rowM1: rowM1, rowP1: rowP1, x: cx)

                let gx = 0.5 * (pCurr[idx + 1] - pCurr[idx - 1])
                let gy = 0.5 * (pCurr[rowP1 + cx] - pCurr[rowM1 + cx])
                let gradSq = min(gx * gx + gy * gy, 1.5)
                let effLambdaSq = min(baseLambdaSq * (1.0 + gammaNL * gradSq), maxLocalLambda)

                var force: Float = 0.0
                let dxSrc = abs(cx - srcCellX)
                let dySrc = abs(y - srcCellY)
                if dxSrc <= 1 && dySrc <= 1 {
                    let weight: Float = (dxSrc == 0 && dySrc == 0) ? 1.0 : ((dxSrc + dySrc == 1) ? 0.5 : 0.25)
                    force = boundedDrive * weight
                }

                let loss = sigma0Dt + pml[idx]
                let invDenom = 1.0 / (1.0 + loss)
                let waveTerm = 2.0 * p0 - (1.0 - loss) * pOld
                let lapTerm = effLambdaSq * lapC + viscous * (lapC - lapP)
                let nextVal = invDenom * ((waveTerm + lapTerm) - muSq * biharm + force)
                pNext[idx] = nextVal.isFinite ? min(max(nextVal, -Self.pressureSafetyClamp), Self.pressureSafetyClamp) : 0.0
            }
        }

        let effLeftMic = micLeftXY ?? leftMicNormalized
        let effRightMic = micRightXY ?? rightMicNormalized
        let rawL = Self.readBilinearPointer(pNext, normalizedXY: effLeftMic)
        let rawR = Self.readBilinearPointer(pNext, normalizedXY: effRightMic)
        arena.rotateTripleBuffers()

        let yL = rawL - dcBlockXLeft + Self.dcBlockerPole * dcBlockYLeft
        dcBlockXLeft = rawL
        dcBlockYLeft = yL

        let yR = rawR - dcBlockXRight + Self.dcBlockerPole * dcBlockYRight
        dcBlockXRight = rawR
        dcBlockYRight = yR

        return (tanhf(yL * Self.outputSaturationDrive), tanhf(yR * Self.outputSaturationDrive))
    }

    @inline(__always)
    public mutating func processSample(excitation: Float, stiffness: Float) -> (Float, Float) {
        stepSample(
            excitation: excitation,
            waveSpeed: 343.0,
            stiffnessKappa: stiffness,
            dampingSigma: 1.8,
            nonlinearGamma: 0.08
        )
    }

    @inline(__always)
    public mutating func triggerPluckedImpulse(amplitude: Float = 0.85) {
        triggerRaisedCosinePluck(amplitude: amplitude)
    }

    @inline(__always)
    public mutating func stepSample(
        excitationInput: Float,
        waveSpeed: Float = 343.0,
        stiffnessNormalize: Float = 0.18,
        dampingSigma0: Float = 1.8,
        nonlinearTension: Float = 0.08
    ) -> SIMD2<Float> {
        let (l, r) = stepSample(
            excitation: excitationInput,
            waveSpeed: waveSpeed,
            stiffnessKappa: stiffnessNormalize,
            dampingSigma: dampingSigma0,
            nonlinearGamma: nonlinearTension
        )
        return SIMD2<Float>(l, r)
    }
}

// MARK: - 4. High-Resolution 2D Isotropic 9-Point Wave Tank with Cubic PML (> 35 dB Suppression)

public typealias FDTD2DWaveTank = FDTDWaveTankGrid2D

public struct FDTDWaveTankGrid2D: Sendable {
    public enum BoundaryMode: UInt32, Sendable, Equatable {
        case absorbingPML = 0
        case rigidDirichlet = 1
        case rigidNeumann = 2

        public static let reflectiveDirichlet: BoundaryMode = .rigidDirichlet
    }

    public static let pressureSafetyClamp: Float = 20.0

    public let gridSize: Int
    public let pmlThickness: Int
    public var boundaryMode: BoundaryMode
    public var cflParameters: FDTDCFLParameters {
        didSet {
            if cflParameters.dimension != 2 || !cflParameters.isStable {
                cflParameters = cflParameters.clamped(toDimension: 2)
            }
        }
    }
    public var nonlinearGamma: Float = 0.02

    public var dispersionLimitedMaxFrequency: Float {
        cflParameters.dispersionLimitedMaxFrequency
    }

    public var recommendedSourceBandwidth: Float {
        cflParameters.recommendedSourceBandwidth
    }

    public private(set) var pressureCurr: [Float]
    public private(set) var pressurePrev: [Float]
    private var pressureNext: [Float]
    private var laplacianScratch: [Float]
    private var laplacianPrevScratch: [Float]

    /// `true` marks solid interior obstacle cells (`obstacleCode != 0`).
    public private(set) var obstacleMask: [Bool]
    /// `0` = fluid, `1` = Dirichlet absorber, `2` = Neumann rigid wall, `3` = metamaterial lens.
    public private(set) var obstacleCodes: [UInt8]
    /// Precomputed center-cell weight `10/3 - (2/3)*N_axialNeumann - (1/6)*N_diagNeumann` for branchless SIMD8 Laplacian.
    private var stencilCenterWeight: [Float]
    /// Precomputed `1.0` for fluid/lens cells and `0.0` for solid obstacle cells (`code == 1 || code == 2`).
    private var fluidMaskFloat: [Float]
    /// Per-cell relative squared wave speed `(c_local / c_0)^2` for refractive acoustic lenses.
    public private(set) var relativeSpeedSq: [Float]
    /// Precomputed cubic PML sponge profile `sigma_max * (d / L_pml)^3`.
    public let pmlDampingProfile: [Float]
    public let pmlMaxSigma: Float
    public private(set) var stepCounter: Int = 0

    public init(
        gridSize: Int = 128,
        pmlThickness: Int = 16,
        boundaryMode: BoundaryMode = .absorbingPML,
        pmlMaxSigma: Float = 0.34
    ) {
        let n = max(32, gridSize)
        let safePML = min(max(4, pmlThickness), n / 3)
        let safeMaxSigma = min(max(0.0, pmlMaxSigma), 0.48)
        self.gridSize = n
        self.pmlThickness = safePML
        self.boundaryMode = boundaryMode
        self.pmlMaxSigma = safeMaxSigma

        self.cflParameters = FDTDCFLParameters(
            dimension: 2,
            waveSpeed: 343.0,
            stiffnessKappa: 0.0,
            gridSpacingMeters: 0.015,
            timeStepSeconds: 0.015 * 0.50 / 343.0,
            sigma0: 0.0,
            sigma1: 0.000015
        )

        let total = n * n
        self.pressureCurr = [Float](repeating: 0.0, count: total)
        self.pressurePrev = [Float](repeating: 0.0, count: total)
        self.pressureNext = [Float](repeating: 0.0, count: total)
        self.laplacianScratch = [Float](repeating: 0.0, count: total)
        self.laplacianPrevScratch = [Float](repeating: 0.0, count: total)
        self.obstacleMask = [Bool](repeating: false, count: total)
        self.obstacleCodes = [UInt8](repeating: 0, count: total)
        self.stencilCenterWeight = [Float](repeating: 10.0 / 3.0, count: total)
        self.fluidMaskFloat = [Float](repeating: 1.0, count: total)
        self.relativeSpeedSq = [Float](repeating: 1.0, count: total)

        var profile = [Float](repeating: 0.0, count: total)
        for y in 0..<n {
            let distY = min(y, n - 1 - y)
            let sy: Float
            if distY < safePML {
                let uy = Float(safePML - distY) / Float(safePML)
                sy = safeMaxSigma * (uy * uy * uy)
            } else {
                sy = 0.0
            }
            for x in 0..<n {
                let distX = min(x, n - 1 - x)
                let sx: Float
                if distX < safePML {
                    let ux = Float(safePML - distX) / Float(safePML)
                    sx = safeMaxSigma * (ux * ux * ux)
                } else {
                    sx = 0.0
                }
                profile[y * n + x] = min(sx + sy, 0.96)
            }
        }
        self.pmlDampingProfile = profile
    }

    private mutating func rebuildObstacleStencilWeights() {
        let n = gridSize
        obstacleCodes.withUnsafeBufferPointer { codeBuf in
            stencilCenterWeight.withUnsafeMutableBufferPointer { wBuf in
                fluidMaskFloat.withUnsafeMutableBufferPointer { mBuf in
                    guard let codes = codeBuf.baseAddress,
                          let weights = wBuf.baseAddress,
                          let masks = mBuf.baseAddress else { return }
                    for i in 0..<(n * n) {
                        let c = codes[i]
                        masks[i] = (c == 1 || c == 2) ? 0.0 : 1.0
                        weights[i] = (c == 1 || c == 2) ? 0.0 : (10.0 / 3.0)
                    }
                    for y in 1..<(n - 1) {
                        let row = y * n
                        let rowM1 = (y - 1) * n
                        let rowP1 = (y + 1) * n
                        for x in 1..<(n - 1) {
                            let idx = row + x
                            let c = codes[idx]
                            if c == 1 || c == 2 {
                                continue
                            }
                            var axNeumann: Int = 0
                            if codes[idx - 1] == 2 { axNeumann += 1 }
                            if codes[idx + 1] == 2 { axNeumann += 1 }
                            if codes[rowM1 + x] == 2 { axNeumann += 1 }
                            if codes[rowP1 + x] == 2 { axNeumann += 1 }

                            var dgNeumann: Int = 0
                            if codes[rowM1 + x - 1] == 2 { dgNeumann += 1 }
                            if codes[rowM1 + x + 1] == 2 { dgNeumann += 1 }
                            if codes[rowP1 + x - 1] == 2 { dgNeumann += 1 }
                            if codes[rowP1 + x + 1] == 2 { dgNeumann += 1 }

                            let axSub = (2.0 / 3.0) * Float(axNeumann)
                            let dgSub = (1.0 / 6.0) * Float(dgNeumann)
                            weights[idx] = (10.0 / 3.0) - axSub - dgSub
                        }
                    }
                }
            }
        }
    }

    public mutating func syncFromGPUBuffers(curr: [Float], prev: [Float], stepsAdded: Int) {
        guard curr.count == pressureCurr.count, prev.count == pressurePrev.count else { return }
        self.pressureCurr = curr
        self.pressurePrev = prev
        for i in 0..<obstacleMask.count where obstacleMask[i] {
            self.pressureCurr[i] = 0.0
            self.pressurePrev[i] = 0.0
        }
        self.stepCounter += max(0, stepsAdded)
    }

    /// Zero-allocation GPU buffer synchronization directly into pre-allocated `[Float]` storage.
    public mutating func syncFromGPUPointers(
        currPtr: UnsafePointer<Float>,
        prevPtr: UnsafePointer<Float>,
        count: Int,
        stepsAdded: Int
    ) {
        guard count == pressureCurr.count, count == pressurePrev.count else { return }
        var localCurr = pressureCurr
        var localPrev = pressurePrev
        pressureCurr = []
        pressurePrev = []
        fluidMaskFloat.withUnsafeBufferPointer { maskBuf in
            localCurr.withUnsafeMutableBufferPointer { cBuf in
                localPrev.withUnsafeMutableBufferPointer { pBuf in
                    guard let cDst = cBuf.baseAddress,
                          let pDst = pBuf.baseAddress,
                          let mask = maskBuf.baseAddress else { return }
                    for i in 0..<count {
                        let m = mask[i]
                        cDst[i] = currPtr[i] * m
                        pDst[i] = prevPtr[i] * m
                    }
                }
            }
        }
        pressureCurr = localCurr
        pressurePrev = localPrev
        stepCounter += max(0, stepsAdded)
    }

    public mutating func resetField(keepObstaclesAndLenses: Bool = true) {
        let total = gridSize * gridSize
        for i in 0..<total {
            pressureCurr[i] = 0.0
            pressurePrev[i] = 0.0
            pressureNext[i] = 0.0
            laplacianScratch[i] = 0.0
            laplacianPrevScratch[i] = 0.0
            if !keepObstaclesAndLenses {
                obstacleMask[i] = false
                obstacleCodes[i] = 0
                stencilCenterWeight[i] = 10.0 / 3.0
                fluidMaskFloat[i] = 1.0
                relativeSpeedSq[i] = 1.0
            }
        }
        stepCounter = 0
    }

    public mutating func clearObstacles() {
        for i in 0..<obstacleMask.count {
            obstacleMask[i] = false
            if obstacleCodes[i] == 1 || obstacleCodes[i] == 2 {
                obstacleCodes[i] = 0
            }
        }
        rebuildObstacleStencilWeights()
    }

    public mutating func clearRefractiveLenses() {
        for i in 0..<relativeSpeedSq.count {
            relativeSpeedSq[i] = 1.0
            if obstacleCodes[i] == 3 {
                obstacleCodes[i] = 0
            }
        }
    }

    public mutating func setObstacle(x: Int, y: Int, isSolid: Bool = true, isNeumannRigid: Bool = true) {
        guard x >= 0, x < gridSize, y >= 0, y < gridSize else { return }
        let idx = y * gridSize + x
        obstacleMask[idx] = isSolid
        obstacleCodes[idx] = isSolid ? (isNeumannRigid ? 2 : 1) : 0
        if isSolid {
            pressureCurr[idx] = 0.0
            pressurePrev[idx] = 0.0
        }
        rebuildObstacleStencilWeights()
    }

    public mutating func paintBrushDisk(
        centerX: Int,
        centerY: Int,
        radiusCells: Int,
        obstacleCode: UInt8,
        lensRelativeSpeed: Float = 0.62
    ) {
        let rSq = radiusCells * radiusCells
        for dy in -radiusCells...radiusCells {
            for dx in -radiusCells...radiusCells where (dx * dx + dy * dy) <= rSq {
                let gx = centerX + dx
                let gy = centerY + dy
                guard gx > 1, gx < gridSize - 2, gy > 1, gy < gridSize - 2 else { continue }
                let idx = gy * gridSize + gx
                switch obstacleCode {
                case 0:
                    obstacleMask[idx] = false
                    obstacleCodes[idx] = 0
                    relativeSpeedSq[idx] = 1.0
                case 1, 2:
                    obstacleMask[idx] = true
                    obstacleCodes[idx] = obstacleCode
                    pressureCurr[idx] = 0.0
                    pressurePrev[idx] = 0.0
                case 3:
                    obstacleMask[idx] = false
                    obstacleCodes[idx] = 3
                    relativeSpeedSq[idx] = min(max(lensRelativeSpeed * lensRelativeSpeed, 0.18), 1.25)
                default:
                    break
                }
            }
        }
        rebuildObstacleStencilWeights()
    }

    public mutating func drawWallSegment(from start: SIMD2<Int>, to end: SIMD2<Int>, thickness: Int = 1) {
        let dx = abs(end.x - start.x)
        let dy = abs(end.y - start.y)
        let steps = max(1, max(dx, dy))
        let halfT = max(0, thickness / 2)

        for s in 0...steps {
            let t = Float(s) / Float(steps)
            let cx = Int((Float(start.x) + Float(end.x - start.x) * t).rounded())
            let cy = Int((Float(start.y) + Float(end.y - start.y) * t).rounded())
            for oy in -halfT...halfT {
                for ox in -halfT...halfT {
                    let gx = cx + ox
                    let gy = cy + oy
                    guard gx >= 0, gx < gridSize, gy >= 0, gy < gridSize else { continue }
                    let idx = gy * gridSize + gx
                    obstacleMask[idx] = true
                    obstacleCodes[idx] = 2
                    pressureCurr[idx] = 0.0
                    pressurePrev[idx] = 0.0
                }
            }
        }
        rebuildObstacleStencilWeights()
    }

    /// Configures a Young double-slit diffraction barrier at `barrierX`.
    public mutating func configureDoubleSlitBarrier(
        barrierX: Int? = nil,
        slitWidthCells: Int = 5,
        slitSeparationCells: Int = 20
    ) {
        let bx = min(max(barrierX ?? (gridSize / 2), pmlThickness + 4), gridSize - pmlThickness - 5)
        let midY = gridSize / 2
        let halfSep = max(3, slitSeparationCells / 2)
        let halfSlit = max(1, slitWidthCells / 2)

        let slit1Range = (midY - halfSep - halfSlit)...(midY - halfSep + halfSlit)
        let slit2Range = (midY + halfSep - halfSlit)...(midY + halfSep + halfSlit)

        for y in 0..<gridSize {
            let isOpen = slit1Range.contains(y) || slit2Range.contains(y)
            for ox in 0...1 {
                let idx = y * gridSize + (bx + ox)
                obstacleMask[idx] = !isOpen
                obstacleCodes[idx] = isOpen ? 0 : 2
                if !isOpen {
                    pressureCurr[idx] = 0.0
                    pressurePrev[idx] = 0.0
                }
            }
        }
        rebuildObstacleStencilWeights()
    }

    /// Configures an interior Helmholtz acoustic cavity resonator with a narrow neck aperture facing the source.
    public mutating func configureHelmholtzResonator(centerX: Int? = nil, centerY: Int? = nil) {
        let cx = centerX ?? (gridSize * 56 / 100)
        let cy = centerY ?? (gridSize / 2)
        let halfW = max(8, gridSize / 9)
        let halfH = max(10, gridSize / 7)
        let neckHalf = 2

        drawWallSegment(from: SIMD2(cx - halfW, cy - halfH), to: SIMD2(cx + halfW, cy - halfH), thickness: 2)
        drawWallSegment(from: SIMD2(cx - halfW, cy + halfH), to: SIMD2(cx + halfW, cy + halfH), thickness: 2)
        drawWallSegment(from: SIMD2(cx + halfW, cy - halfH), to: SIMD2(cx + halfW, cy + halfH), thickness: 2)
        drawWallSegment(from: SIMD2(cx - halfW, cy - halfH), to: SIMD2(cx - halfW, cy - neckHalf - 1), thickness: 2)
        drawWallSegment(from: SIMD2(cx - halfW, cy + neckHalf + 1), to: SIMD2(cx - halfW, cy + halfH), thickness: 2)
    }

    /// Adds a circular biconvex/GRIN acoustic metamaterial lens (`relativeWaveSpeed < 1.0` focuses wavefronts).
    public mutating func addRefractiveAcousticLens(
        centerX: Int,
        centerY: Int,
        radiusCells: Float,
        relativeWaveSpeed: Float
    ) {
        let rSq = max(1.0, radiusCells * radiusCells)
        let speedSq = min(max(relativeWaveSpeed * relativeWaveSpeed, 0.16), 1.20)

        for y in 0..<gridSize {
            for x in 0..<gridSize {
                let dx = Float(x - centerX)
                let dy = Float(y - centerY)
                let dSq = dx * dx + dy * dy
                if dSq <= rSq {
                    let t = min(max((dSq - rSq * 0.70) / max(1.0e-5, rSq * 0.30), 0.0), 1.0)
                    let smoothEdge = 1.0 - t * t * (3.0 - 2.0 * t)
                    let idx = y * gridSize + x
                    relativeSpeedSq[idx] = 1.0 + (speedSq - 1.0) * smoothEdge
                    if !obstacleMask[idx] {
                        obstacleCodes[idx] = 3
                    }
                }
            }
        }
    }

    /// Injects a spatially band-limited Gaussian pulse (clamping `sigmaCells` to `minimumGaussianSigmaCells()`).
    public mutating func injectGaussianPulse(
        centerX: Int,
        centerY: Int,
        sigmaCells: Float = 2.8,
        amplitude: Float = 1.0
    ) {
        let safeSigma = max(sigmaCells, cflParameters.minimumGaussianSigmaCells())
        let invTwoSigmaSq = 1.0 / max(0.25, 2.0 * safeSigma * safeSigma)
        let support = max(2, Int(ceilf(safeSigma * 3.5)))
        let yMin = max(1, centerY - support)
        let yMax = min(gridSize - 2, centerY + support)
        let xMin = max(1, centerX - support)
        let xMax = min(gridSize - 2, centerX + support)

        for y in yMin...yMax {
            for x in xMin...xMax {
                let idx = y * gridSize + x
                guard !obstacleMask[idx] else { continue }
                let dx = Float(x - centerX)
                let dy = Float(y - centerY)
                let pulse = amplitude * expf(-(dx * dx + dy * dy) * invTwoSigmaSq)
                pressureCurr[idx] += pulse
                pressurePrev[idx] += pulse
            }
        }
    }

    /// Injects a spatially smoothed 3x3 isotropic point drive so high-wavenumber `(pi, pi)` grid modes are suppressed.
    public mutating func injectPointDrive(x: Int, y: Int, pressureDelta: Float) {
        guard x > 1, x < gridSize - 2, y > 1, y < gridSize - 2 else { return }
        let idx = y * gridSize + x
        guard !obstacleMask[idx] else { return }
        pressureCurr[idx] += pressureDelta * 0.50
        let axialOffsets = [-1, 1, -gridSize, gridSize]
        for off in axialOffsets {
            let nb = idx + off
            if !obstacleMask[nb] {
                pressureCurr[nb] += pressureDelta * 0.10
            }
        }
        let diagOffsets = [-gridSize - 1, -gridSize + 1, gridSize - 1, gridSize + 1]
        for off in diagOffsets {
            let nb = idx + off
            if !obstacleMask[nb] {
                pressureCurr[nb] += pressureDelta * 0.025
            }
        }
    }

    @inline(__always)
    private static func loadSIMD8(_ ptr: UnsafePointer<Float>, _ base: Int) -> SIMD8<Float> {
        SIMD8<Float>(
            ptr[base],
            ptr[base + 1],
            ptr[base + 2],
            ptr[base + 3],
            ptr[base + 4],
            ptr[base + 5],
            ptr[base + 6],
            ptr[base + 7]
        )
    }

    /// Advances the 2D isotropic 9-point compact FDTD solver by one step using `SIMD8<Float>` interior vectorization
    /// and zero-CoW `withUnsafeMutableBufferPointer` buffer exchange.
    public mutating func step() {
        let n = gridSize
        let safeCFL = (cflParameters.dimension == 2 && cflParameters.isStable)
            ? cflParameters
            : cflParameters.clamped(toDimension: 2)
        let maxLocalLambdaSq = safeCFL.maxLocalLambdaSq(forDimension: 2)
        let baseLambdaSq = min(safeCFL.lambdaSq, maxLocalLambdaSq)
        let muSq = safeCFL.muSq
        let viscous = safeCFL.viscousTerm
        let baseSigma0Dt = safeCFL.sigma0 * safeCFL.timeStepSeconds
        let usePML = (boundaryMode == .absorbingPML)
        let mode = boundaryMode

        // Zero-CoW local ownership swap before opening UnsafeMutableBufferPointers
        var localCurr = pressureCurr
        var localPrev = pressurePrev
        var localNext = pressureNext
        var localLapC = laplacianScratch
        var localLapP = laplacianPrevScratch
        pressureCurr = []
        pressurePrev = []
        pressureNext = []
        laplacianScratch = []
        laplacianPrevScratch = []

        localCurr.withUnsafeBufferPointer { currBuf in
            localPrev.withUnsafeBufferPointer { prevBuf in
                localNext.withUnsafeMutableBufferPointer { nextBuf in
                    localLapC.withUnsafeMutableBufferPointer { lapCBuf in
                        localLapP.withUnsafeMutableBufferPointer { lapPBuf in
                            stencilCenterWeight.withUnsafeBufferPointer { wBuf in
                                fluidMaskFloat.withUnsafeBufferPointer { maskBuf in
                                    relativeSpeedSq.withUnsafeBufferPointer { spdBuf in
                                        pmlDampingProfile.withUnsafeBufferPointer { pmlBuf in
                                            guard let pCurr = currBuf.baseAddress,
                                                  let pPrev = prevBuf.baseAddress,
                                                  let pNext = nextBuf.baseAddress,
                                                  let lapC = lapCBuf.baseAddress,
                                                  let lapP = lapPBuf.baseAddress,
                                                  let wCenter = wBuf.baseAddress,
                                                  let fluidMask = maskBuf.baseAddress,
                                                  let relSpeed = spdBuf.baseAddress,
                                                  let pml = pmlBuf.baseAddress else { return }

                                            Self.stepSIMD8Core(
                                                n: n,
                                                baseLambdaSq: baseLambdaSq,
                                                maxLocalLambdaSq: maxLocalLambdaSq,
                                                muSq: muSq,
                                                viscous: viscous,
                                                baseSigma0Dt: baseSigma0Dt,
                                                usePML: usePML,
                                                boundaryMode: mode,
                                                pCurr: pCurr,
                                                pPrev: pPrev,
                                                pNext: pNext,
                                                lapC: lapC,
                                                lapP: lapP,
                                                wCenter: wCenter,
                                                fluidMask: fluidMask,
                                                relSpeed: relSpeed,
                                                pml: pml
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // Rotate triple buffers (prev <- curr, curr <- next, next <- prev) with zero copies
        pressurePrev = localCurr
        pressureCurr = localNext
        pressureNext = localPrev
        laplacianScratch = localLapC
        laplacianPrevScratch = localLapP
        stepCounter += 1
    }

    @inline(__always)
    private static func stepSIMD8Core(
        n: Int,
        baseLambdaSq: Float,
        maxLocalLambdaSq: Float,
        muSq: Float,
        viscous: Float,
        baseSigma0Dt: Float,
        usePML: Bool,
        boundaryMode: BoundaryMode,
        pCurr: UnsafePointer<Float>,
        pPrev: UnsafePointer<Float>,
        pNext: UnsafeMutablePointer<Float>,
        lapC: UnsafeMutablePointer<Float>,
        lapP: UnsafeMutablePointer<Float>,
        wCenter: UnsafePointer<Float>,
        fluidMask: UnsafePointer<Float>,
        relSpeed: UnsafePointer<Float>,
        pml: UnsafePointer<Float>
    ) {
        let twoThirds8 = SIMD8<Float>(repeating: 2.0 / 3.0)
        let oneSixth8 = SIMD8<Float>(repeating: 1.0 / 6.0)
        let tenThirds8 = SIMD8<Float>(repeating: 10.0 / 3.0)

        // Pass 1: SIMD8-vectorized isotropic 9-point compact Laplacian L_h(p^n) and L_h(p^{n-1})
        for y in 1..<(n - 1) {
            let row = y * n
            let rowM1 = (y - 1) * n
            let rowP1 = (y + 1) * n

            var x = 1
            while x + 8 <= n - 1 {
                let base = row + x
                let mVec = loadSIMD8(fluidMask, base)
                let wVec = loadSIMD8(wCenter, base)

                let cVec = loadSIMD8(pCurr, base)
                let lVec = loadSIMD8(pCurr, base - 1)
                let rVec = loadSIMD8(pCurr, base + 1)
                let dVec = loadSIMD8(pCurr, rowM1 + x)
                let uVec = loadSIMD8(pCurr, rowP1 + x)
                let dlVec = loadSIMD8(pCurr, rowM1 + x - 1)
                let drVec = loadSIMD8(pCurr, rowM1 + x + 1)
                let ulVec = loadSIMD8(pCurr, rowP1 + x - 1)
                let urVec = loadSIMD8(pCurr, rowP1 + x + 1)

                let axC: SIMD8<Float> = (lVec + rVec) + (dVec + uVec)
                let dgC: SIMD8<Float> = (dlVec + drVec) + (ulVec + urVec)
                let rawLapC: SIMD8<Float> = (twoThirds8 * axC + oneSixth8 * dgC) - (wVec * cVec)
                let maskedLapC: SIMD8<Float> = rawLapC * mVec

                let cPrev = loadSIMD8(pPrev, base)
                let lPrev = loadSIMD8(pPrev, base - 1)
                let rPrev = loadSIMD8(pPrev, base + 1)
                let dPrev = loadSIMD8(pPrev, rowM1 + x)
                let uPrev = loadSIMD8(pPrev, rowP1 + x)
                let dlPrev = loadSIMD8(pPrev, rowM1 + x - 1)
                let drPrev = loadSIMD8(pPrev, rowM1 + x + 1)
                let ulPrev = loadSIMD8(pPrev, rowP1 + x - 1)
                let urPrev = loadSIMD8(pPrev, rowP1 + x + 1)

                let axP: SIMD8<Float> = (lPrev + rPrev) + (dPrev + uPrev)
                let dgP: SIMD8<Float> = (dlPrev + drPrev) + (ulPrev + urPrev)
                let rawLapP: SIMD8<Float> = (twoThirds8 * axP + oneSixth8 * dgP) - (wVec * cPrev)
                let maskedLapP: SIMD8<Float> = rawLapP * mVec

                for lane in 0..<8 {
                    lapC[base + lane] = maskedLapC[lane]
                    lapP[base + lane] = maskedLapP[lane]
                }
                x += 8
            }

            while x < n - 1 {
                let idx = row + x
                let m = fluidMask[idx]
                if m == 0.0 {
                    lapC[idx] = 0.0
                    lapP[idx] = 0.0
                } else {
                    let w = wCenter[idx]
                    let c = pCurr[idx]
                    let ax = pCurr[idx - 1] + pCurr[idx + 1] + pCurr[rowM1 + x] + pCurr[rowP1 + x]
                    let dg = pCurr[rowM1 + x - 1] + pCurr[rowM1 + x + 1] + pCurr[rowP1 + x - 1] + pCurr[rowP1 + x + 1]
                    lapC[idx] = (2.0 / 3.0) * ax + (1.0 / 6.0) * dg - w * c

                    let cP = pPrev[idx]
                    let axP = pPrev[idx - 1] + pPrev[idx + 1] + pPrev[rowM1 + x] + pPrev[rowP1 + x]
                    let dgP = pPrev[rowM1 + x - 1] + pPrev[rowM1 + x + 1] + pPrev[rowP1 + x - 1] + pPrev[rowP1 + x + 1]
                    lapP[idx] = (2.0 / 3.0) * axP + (1.0 / 6.0) * dgP - w * cP
                }
                x += 1
            }
        }

        // Pass 2: SIMD8 time-marching update with L_h^2 biharmonic stiffness, visco-thermal damping & cubic PML
        let one8 = SIMD8<Float>(repeating: 1.0)
        let two8 = SIMD8<Float>(repeating: 2.0)
        let baseLambda8 = SIMD8<Float>(repeating: baseLambdaSq)
        let maxLambda8 = SIMD8<Float>(repeating: maxLocalLambdaSq)
        let viscous8 = SIMD8<Float>(repeating: viscous)
        let muSq8 = SIMD8<Float>(repeating: muSq)
        let sigma0Dt8 = SIMD8<Float>(repeating: baseSigma0Dt)
        let minClamp8 = SIMD8<Float>(repeating: -pressureSafetyClamp)
        let maxClamp8 = SIMD8<Float>(repeating: pressureSafetyClamp)

        for y in 1..<(n - 1) {
            let row = y * n
            let rowM1 = (y - 1) * n
            let rowP1 = (y + 1) * n
            let canBiharmRow = (muSq > 0.0 && y >= 2 && y < n - 2)

            // Border cell x = 1 handled scalar when biharmonic is active so SIMD8 loop starts at x = 2
            var x = 1
            if canBiharmRow {
                let idx = row + 1
                if fluidMask[idx] == 0.0 {
                    pNext[idx] = 0.0
                } else {
                    let p0 = pCurr[idx]
                    let pOld = pPrev[idx]
                    let lc = lapC[idx]
                    let lp = lapP[idx]
                    let localLam = min(baseLambdaSq * relSpeed[idx], maxLocalLambdaSq)
                    let pmlLoss = usePML ? pml[idx] : 0.0
                    let totalLoss = baseSigma0Dt + pmlLoss
                    let invDenom = 1.0 / (1.0 + totalLoss)
                    let waveTerm = 2.0 * p0 - (1.0 - totalLoss) * pOld
                    let updated = (waveTerm + localLam * lc + viscous * (lc - lp)) * invDenom
                    pNext[idx] = updated.isFinite ? min(max(updated, -pressureSafetyClamp), pressureSafetyClamp) : 0.0
                }
                x = 2
            }

            let simdLimit = canBiharmRow ? (n - 2) : (n - 1)
            while x + 8 <= simdLimit {
                let base = row + x
                let mVec = loadSIMD8(fluidMask, base)
                let p0Vec = loadSIMD8(pCurr, base)
                let pOldVec = loadSIMD8(pPrev, base)
                let lcVec = loadSIMD8(lapC, base)
                let lpVec = loadSIMD8(lapP, base)
                let spdVec = loadSIMD8(relSpeed, base)

                var biharmVec = SIMD8<Float>.zero
                if canBiharmRow {
                    let lLap = loadSIMD8(lapC, base - 1)
                    let rLap = loadSIMD8(lapC, base + 1)
                    let dLap = loadSIMD8(lapC, rowM1 + x)
                    let uLap = loadSIMD8(lapC, rowP1 + x)
                    let dlLap = loadSIMD8(lapC, rowM1 + x - 1)
                    let drLap = loadSIMD8(lapC, rowM1 + x + 1)
                    let ulLap = loadSIMD8(lapC, rowP1 + x - 1)
                    let urLap = loadSIMD8(lapC, rowP1 + x + 1)
                    let axL: SIMD8<Float> = (lLap + rLap) + (dLap + uLap)
                    let dgL: SIMD8<Float> = (dlLap + drLap) + (ulLap + urLap)
                    biharmVec = (twoThirds8 * axL + oneSixth8 * dgL) - (tenThirds8 * lcVec)
                }

                let localLamVec: SIMD8<Float> = simd_min(baseLambda8 * spdVec, maxLambda8)
                let pmlVec: SIMD8<Float> = usePML ? loadSIMD8(pml, base) : .zero
                let totalLossVec: SIMD8<Float> = sigma0Dt8 + pmlVec
                let invDenomVec: SIMD8<Float> = one8 / (one8 + totalLossVec)

                let waveTerm: SIMD8<Float> = two8 * p0Vec - (one8 - totalLossVec) * pOldVec
                let lapTerm: SIMD8<Float> = localLamVec * lcVec + viscous8 * (lcVec - lpVec)
                let rawUpdated: SIMD8<Float> = ((waveTerm + lapTerm) - (muSq8 * biharmVec)) * invDenomVec
                let clampedVec: SIMD8<Float> = simd_clamp(rawUpdated, minClamp8, maxClamp8) * mVec

                for lane in 0..<8 {
                    let v = rawUpdated[lane]
                    pNext[base + lane] = v.isFinite ? clampedVec[lane] : 0.0
                }
                x += 8
            }

            while x < n - 1 {
                let idx = row + x
                if fluidMask[idx] == 0.0 {
                    pNext[idx] = 0.0
                } else {
                    let p0 = pCurr[idx]
                    let pOld = pPrev[idx]
                    let lc = lapC[idx]
                    let lp = lapP[idx]

                    var biharm: Float = 0.0
                    if canBiharmRow && x >= 2 && x < n - 2 {
                        let axL = lapC[idx - 1] + lapC[idx + 1] + lapC[rowM1 + x] + lapC[rowP1 + x]
                        let dgL = lapC[rowM1 + x - 1] + lapC[rowM1 + x + 1] + lapC[rowP1 + x - 1] + lapC[rowP1 + x + 1]
                        biharm = (2.0 / 3.0) * axL + (1.0 / 6.0) * dgL - (10.0 / 3.0) * lc
                    }

                    let localLam = min(baseLambdaSq * relSpeed[idx], maxLocalLambdaSq)
                    let pmlLoss = usePML ? pml[idx] : 0.0
                    let totalLoss = baseSigma0Dt + pmlLoss
                    let invDenom = 1.0 / (1.0 + totalLoss)
                    let waveTerm = 2.0 * p0 - (1.0 - totalLoss) * pOld
                    let lapTerm = localLam * lc + viscous * (lc - lp)
                    let updated = ((waveTerm + lapTerm) - muSq * biharm) * invDenom
                    pNext[idx] = updated.isFinite ? min(max(updated, -pressureSafetyClamp), pressureSafetyClamp) : 0.0
                }
                x += 1
            }
        }

        switch boundaryMode {
        case .absorbingPML, .rigidDirichlet:
            for i in 0..<n {
                pNext[i] = 0.0
                pNext[(n - 1) * n + i] = 0.0
                pNext[i * n] = 0.0
                pNext[i * n + (n - 1)] = 0.0
            }
        case .rigidNeumann:
            for i in 1..<(n - 1) {
                pNext[i] = pNext[n + i]
                pNext[(n - 1) * n + i] = pNext[(n - 2) * n + i]
                pNext[i * n] = pNext[i * n + 1]
                pNext[i * n + (n - 1)] = pNext[i * n + (n - 2)]
            }
            pNext[0] = pNext[n + 1]
            pNext[n - 1] = pNext[2 * n - 2]
            pNext[(n - 1) * n] = pNext[(n - 2) * n + 1]
            pNext[n * n - 1] = pNext[(n - 1) * n - 2]
        }
    }

    /// Scalar reference implementation of `step()` for verifying SIMD8 vs scalar equivalence in unit tests.
    public mutating func stepScalarReference() {
        let n = gridSize
        let safeCFL = (cflParameters.dimension == 2 && cflParameters.isStable)
            ? cflParameters
            : cflParameters.clamped(toDimension: 2)
        let maxLocalLambdaSq = safeCFL.maxLocalLambdaSq(forDimension: 2)
        let baseLambdaSq = min(safeCFL.lambdaSq, maxLocalLambdaSq)
        let muSq = safeCFL.muSq
        let viscous = safeCFL.viscousTerm
        let baseSigma0Dt = safeCFL.sigma0 * safeCFL.timeStepSeconds
        let usePML = (boundaryMode == .absorbingPML)

        for y in 1..<(n - 1) {
            let row = y * n
            let rowM1 = (y - 1) * n
            let rowP1 = (y + 1) * n
            for x in 1..<(n - 1) {
                let idx = row + x
                let code = obstacleCodes[idx]
                if code == 1 || code == 2 {
                    laplacianScratch[idx] = 0.0
                    continue
                }
                let c = pressureCurr[idx]
                let nL = obstacleCodes[idx - 1] == 2 ? c : (obstacleCodes[idx - 1] == 1 ? 0.0 : pressureCurr[idx - 1])
                let nR = obstacleCodes[idx + 1] == 2 ? c : (obstacleCodes[idx + 1] == 1 ? 0.0 : pressureCurr[idx + 1])
                let nD = obstacleCodes[rowM1 + x] == 2 ? c : (obstacleCodes[rowM1 + x] == 1 ? 0.0 : pressureCurr[rowM1 + x])
                let nU = obstacleCodes[rowP1 + x] == 2 ? c : (obstacleCodes[rowP1 + x] == 1 ? 0.0 : pressureCurr[rowP1 + x])

                let dLD = obstacleCodes[rowM1 + x - 1] == 2 ? c : (obstacleCodes[rowM1 + x - 1] == 1 ? 0.0 : pressureCurr[rowM1 + x - 1])
                let dRD = obstacleCodes[rowM1 + x + 1] == 2 ? c : (obstacleCodes[rowM1 + x + 1] == 1 ? 0.0 : pressureCurr[rowM1 + x + 1])
                let dLU = obstacleCodes[rowP1 + x - 1] == 2 ? c : (obstacleCodes[rowP1 + x - 1] == 1 ? 0.0 : pressureCurr[rowP1 + x - 1])
                let dRU = obstacleCodes[rowP1 + x + 1] == 2 ? c : (obstacleCodes[rowP1 + x + 1] == 1 ? 0.0 : pressureCurr[rowP1 + x + 1])

                laplacianScratch[idx] = (2.0 / 3.0) * (nL + nR + nD + nU)
                    + (1.0 / 6.0) * (dLD + dRD + dLU + dRU)
                    - (10.0 / 3.0) * c
            }
        }

        for y in 1..<(n - 1) {
            let row = y * n
            let rowM1 = (y - 1) * n
            let rowP1 = (y + 1) * n

            for x in 1..<(n - 1) {
                let idx = row + x
                if obstacleMask[idx] {
                    pressureNext[idx] = 0.0
                    continue
                }

                let p0 = pressureCurr[idx]
                let pOld = pressurePrev[idx]
                let lapC = laplacianScratch[idx]

                let pL = obstacleCodes[idx - 1] == 2 ? pOld : (obstacleCodes[idx - 1] == 1 ? 0.0 : pressurePrev[idx - 1])
                let pR = obstacleCodes[idx + 1] == 2 ? pOld : (obstacleCodes[idx + 1] == 1 ? 0.0 : pressurePrev[idx + 1])
                let pD = obstacleCodes[rowM1 + x] == 2 ? pOld : (obstacleCodes[rowM1 + x] == 1 ? 0.0 : pressurePrev[rowM1 + x])
                let pU = obstacleCodes[rowP1 + x] == 2 ? pOld : (obstacleCodes[rowP1 + x] == 1 ? 0.0 : pressurePrev[rowP1 + x])

                let pLD = obstacleCodes[rowM1 + x - 1] == 2 ? pOld : (obstacleCodes[rowM1 + x - 1] == 1 ? 0.0 : pressurePrev[rowM1 + x - 1])
                let pRD = obstacleCodes[rowM1 + x + 1] == 2 ? pOld : (obstacleCodes[rowM1 + x + 1] == 1 ? 0.0 : pressurePrev[rowM1 + x + 1])
                let pLU = obstacleCodes[rowP1 + x - 1] == 2 ? pOld : (obstacleCodes[rowP1 + x - 1] == 1 ? 0.0 : pressurePrev[rowP1 + x - 1])
                let pRU = obstacleCodes[rowP1 + x + 1] == 2 ? pOld : (obstacleCodes[rowP1 + x + 1] == 1 ? 0.0 : pressurePrev[rowP1 + x + 1])

                let lapP = (2.0 / 3.0) * (pL + pR + pD + pU)
                    + (1.0 / 6.0) * (pLD + pRD + pLU + pRU)
                    - (10.0 / 3.0) * pOld

                var biharm: Float = 0.0
                if muSq > 0.0 && x >= 2 && x < n - 2 && y >= 2 && y < n - 2 {
                    let axL = laplacianScratch[idx - 1] + laplacianScratch[idx + 1]
                        + laplacianScratch[rowM1 + x] + laplacianScratch[rowP1 + x]
                    let dgL = laplacianScratch[rowM1 + x - 1] + laplacianScratch[rowM1 + x + 1]
                        + laplacianScratch[rowP1 + x - 1] + laplacianScratch[rowP1 + x + 1]
                    biharm = (2.0 / 3.0) * axL + (1.0 / 6.0) * dgL - (10.0 / 3.0) * lapC
                }

                let localLambdaSq = min(baseLambdaSq * relativeSpeedSq[idx], maxLocalLambdaSq)
                let pmlLoss = usePML ? pmlDampingProfile[idx] : 0.0
                let totalLoss = baseSigma0Dt + pmlLoss
                let invDenom = 1.0 / (1.0 + totalLoss)
                let waveTerm = 2.0 * p0 - (1.0 - totalLoss) * pOld
                let lapTerm = localLambdaSq * lapC + viscous * (lapC - lapP)
                let updated = ((waveTerm + lapTerm) - muSq * biharm) * invDenom

                pressureNext[idx] = updated.isFinite ? min(max(updated, -Self.pressureSafetyClamp), Self.pressureSafetyClamp) : 0.0
            }
        }

        switch boundaryMode {
        case .absorbingPML, .rigidDirichlet:
            for i in 0..<n {
                pressureNext[i] = 0.0
                pressureNext[(n - 1) * n + i] = 0.0
                pressureNext[i * n] = 0.0
                pressureNext[i * n + (n - 1)] = 0.0
            }
        case .rigidNeumann:
            for i in 1..<(n - 1) {
                pressureNext[i] = pressureNext[n + i]
                pressureNext[(n - 1) * n + i] = pressureNext[(n - 2) * n + i]
                pressureNext[i * n] = pressureNext[i * n + 1]
                pressureNext[i * n + (n - 1)] = pressureNext[i * n + (n - 2)]
            }
            pressureNext[0] = pressureNext[n + 1]
            pressureNext[n - 1] = pressureNext[2 * n - 2]
            pressureNext[(n - 1) * n] = pressureNext[(n - 2) * n + 1]
            pressureNext[n * n - 1] = pressureNext[(n - 1) * n - 2]
        }

        swap(&pressurePrev, &pressureCurr)
        swap(&pressureCurr, &pressureNext)
        stepCounter += 1
    }

    public mutating func advance(steps: Int) {
        let count = max(0, steps)
        for _ in 0..<count {
            step()
        }
    }

    public func interiorRMSPressure() -> Float {
        let margin = pmlThickness + 2
        guard gridSize > margin * 2 else { return 0.0 }
        var sumSq: Float = 0.0
        var count = 0
        for y in margin..<(gridSize - margin) {
            let row = y * gridSize
            for x in margin..<(gridSize - margin) {
                let idx = row + x
                if !obstacleMask[idx] {
                    let p = pressureCurr[idx]
                    sumSq += p * p
                    count += 1
                }
            }
        }
        return count > 0 ? sqrtf(sumSq / Float(count)) : 0.0
    }

    public func interiorDiscreteEnergy() -> Float {
        let margin = pmlThickness
        guard gridSize > margin * 2 else { return 0.0 }
        var energy: Float = 0.0
        for y in margin..<(gridSize - margin) {
            let row = y * gridSize
            for x in margin..<(gridSize - margin) {
                let idx = row + x
                if !obstacleMask[idx] {
                    let p = pressureCurr[idx]
                    energy += p * p
                }
            }
        }
        return energy
    }

    public func totalGridEnergy() -> Float {
        var energy: Float = 0.0
        for p in pressureCurr {
            energy += p * p
        }
        return energy
    }

    public func totalInteriorMechanicalEnergy() -> Float {
        interiorDiscreteEnergy()
    }

    /// Central-difference spatial pressure gradient `(dp/dx, dp/dy)` for Track 35 Acousto-Optic Caustics.
    @inline(__always)
    public func pressureGradient(atX x: Int, y: Int) -> SIMD2<Float> {
        let n = gridSize
        guard x >= 0, x < n, y >= 0, y < n else { return .zero }
        let xm1 = max(0, x - 1)
        let xp1 = min(n - 1, x + 1)
        let ym1 = max(0, y - 1)
        let yp1 = min(n - 1, y + 1)

        let inv2H = 1.0 / (2.0 * cflParameters.gridSpacingMeters)
        let dpdx = (pressureCurr[y * n + xp1] - pressureCurr[y * n + xm1]) * inv2H
        let dpdy = (pressureCurr[yp1 * n + x] - pressureCurr[ym1 * n + x]) * inv2H
        return SIMD2<Float>(dpdx, dpdy)
    }

    public func computePressureGradientField() -> [SIMD2<Float>] {
        let n = gridSize
        var gradients = [SIMD2<Float>](repeating: .zero, count: n * n)
        for y in 0..<n {
            for x in 0..<n {
                gradients[y * n + x] = pressureGradient(atX: x, y: y)
            }
        }
        return gradients
    }
}

// MARK: - 5. 3D Isotropic 27-Point Patra-Karttunen Compact FDTD Solver

public struct FDTDWaveTankGrid3D: Sendable {
    public let sizeX: Int
    public let sizeY: Int
    public let sizeZ: Int
    public let pmlThickness: Int
    public var cflParameters: FDTDCFLParameters {
        didSet {
            if cflParameters.dimension != 3 || !cflParameters.isStable {
                cflParameters = cflParameters.clamped(toDimension: 3)
            }
        }
    }

    public var dispersionLimitedMaxFrequency: Float {
        cflParameters.dispersionLimitedMaxFrequency
    }

    public var recommendedSourceBandwidth: Float {
        cflParameters.recommendedSourceBandwidth
    }

    public private(set) var pressureCurr: [Float]
    public private(set) var pressurePrev: [Float]
    private var pressureNext: [Float]
    private let pmlDamping: [Float]

    public init(gridSize: Int, pmlThickness: Int = 4, pmlMaxSigma: Float = 0.30) {
        self.init(size: gridSize, pmlThickness: pmlThickness, pmlMaxSigma: pmlMaxSigma)
    }

    public init(size: Int = 20, pmlThickness: Int = 4, pmlMaxSigma: Float = 0.30) {
        let n = max(10, size)
        let safePML = min(max(2, pmlThickness), n / 3)
        let safeMaxSigma = min(max(0.0, pmlMaxSigma), 0.32)
        self.sizeX = n
        self.sizeY = n
        self.sizeZ = n
        self.pmlThickness = safePML
        self.cflParameters = FDTDCFLParameters(
            dimension: 3,
            waveSpeed: 343.0,
            stiffnessKappa: 0.05,
            gridSpacingMeters: 0.02,
            timeStepSeconds: 0.02 * 0.42 / 343.0,
            sigma0: 0.2,
            sigma1: 0.00002
        )

        let total = n * n * n
        self.pressureCurr = [Float](repeating: 0.0, count: total)
        self.pressurePrev = [Float](repeating: 0.0, count: total)
        self.pressureNext = [Float](repeating: 0.0, count: total)

        var pml = [Float](repeating: 0.0, count: total)
        for z in 0..<n {
            let dz = min(z, n - 1 - z)
            let sz: Float = dz < safePML ? safeMaxSigma * powf(Float(safePML - dz) / Float(safePML), 3.0) : 0.0
            for y in 0..<n {
                let dy = min(y, n - 1 - y)
                let sy: Float = dy < safePML ? safeMaxSigma * powf(Float(safePML - dy) / Float(safePML), 3.0) : 0.0
                for x in 0..<n {
                    let dx = min(x, n - 1 - x)
                    let sx: Float = dx < safePML ? safeMaxSigma * powf(Float(safePML - dx) / Float(safePML), 3.0) : 0.0
                    pml[(z * n + y) * n + x] = min(sx + sy + sz, 0.96)
                }
            }
        }
        self.pmlDamping = pml
    }

    public mutating func injectCenteredGaussianPulse(sigmaCells: Float = 1.8, amplitude: Float = 1.0) {
        injectGaussianPulse3D(
            centerX: sizeX / 2,
            centerY: sizeY / 2,
            centerZ: sizeZ / 2,
            sigmaCells: sigmaCells,
            amplitude: amplitude
        )
    }

    public mutating func injectGaussianPulse3D(
        centerX: Int,
        centerY: Int,
        centerZ: Int,
        sigmaCells: Float = 1.8,
        amplitude: Float = 1.0
    ) {
        let safeSigma = max(sigmaCells, cflParameters.minimumGaussianSigmaCells())
        let cx = Float(centerX)
        let cy = Float(centerY)
        let cz = Float(centerZ)
        let inv2S2 = 1.0 / max(0.25, 2.0 * safeSigma * safeSigma)
        for z in 1..<(sizeZ - 1) {
            for y in 1..<(sizeY - 1) {
                for x in 1..<(sizeX - 1) {
                    let dx = Float(x) - cx
                    let dy = Float(y) - cy
                    let dz = Float(z) - cz
                    let val = amplitude * expf(-(dx * dx + dy * dy + dz * dz) * inv2S2)
                    let idx = (z * sizeY + y) * sizeX + x
                    pressureCurr[idx] += val
                    pressurePrev[idx] += val
                }
            }
        }
    }

    @inline(__always)
    private static func loadSIMD4(_ ptr: UnsafePointer<Float>, _ base: Int) -> SIMD4<Float> {
        SIMD4<Float>(ptr[base], ptr[base + 1], ptr[base + 2], ptr[base + 3])
    }

    @inline(__always)
    private static func lap27Pointer(
        _ field: UnsafePointer<Float>,
        nx: Int,
        ny: Int,
        x: Int,
        y: Int,
        z: Int
    ) -> Float {
        let idx = (z * ny + y) * nx + x
        let c = field[idx]
        var faces: Float = 0.0
        var edges: Float = 0.0
        var corners: Float = 0.0
        for dz in -1...1 {
            let rz = (z + dz) * ny
            for dy in -1...1 {
                let ryz = (rz + y + dy) * nx
                for dx in -1...1 {
                    let m = abs(dx) + abs(dy) + abs(dz)
                    if m == 0 { continue }
                    let v = field[ryz + x + dx]
                    if m == 1 { faces += v }
                    else if m == 2 { edges += v }
                    else { corners += v }
                }
            }
        }
        return (7.0 / 15.0) * faces + (1.0 / 10.0) * edges + (1.0 / 30.0) * corners - (64.0 / 15.0) * c
    }

    @inline(__always)
    private static func lap27SIMD4(
        _ field: UnsafePointer<Float>,
        nx: Int,
        ny: Int,
        x: Int,
        y: Int,
        z: Int
    ) -> SIMD4<Float> {
        let base = (z * ny + y) * nx + x
        let cVec = loadSIMD4(field, base)
        var faces = SIMD4<Float>.zero
        var edges = SIMD4<Float>.zero
        var corners = SIMD4<Float>.zero
        for dz in -1...1 {
            let rz = (z + dz) * ny
            for dy in -1...1 {
                let ryz = (rz + y + dy) * nx
                for dx in -1...1 {
                    let m = abs(dx) + abs(dy) + abs(dz)
                    if m == 0 { continue }
                    let v = loadSIMD4(field, ryz + x + dx)
                    if m == 1 { faces += v }
                    else if m == 2 { edges += v }
                    else { corners += v }
                }
            }
        }
        let wFace = SIMD4<Float>(repeating: 7.0 / 15.0)
        let wEdge = SIMD4<Float>(repeating: 1.0 / 10.0)
        let wCorner = SIMD4<Float>(repeating: 1.0 / 30.0)
        let wCenter = SIMD4<Float>(repeating: 64.0 / 15.0)
        return (wFace * faces + wEdge * edges) + (wCorner * corners - wCenter * cVec)
    }

    public mutating func step() {
        let nx = sizeX, ny = sizeY, nz = sizeZ
        let safeCFL = (cflParameters.dimension == 3 && cflParameters.isStable)
            ? cflParameters
            : cflParameters.clamped(toDimension: 3)
        let lambdaSq = min(safeCFL.lambdaSq, safeCFL.maxLocalLambdaSq(forDimension: 3))
        let viscous = safeCFL.viscousTerm
        let sigma0Dt = safeCFL.sigma0 * safeCFL.timeStepSeconds

        var localCurr = pressureCurr
        var localPrev = pressurePrev
        var localNext = pressureNext
        pressureCurr = []
        pressurePrev = []
        pressureNext = []

        localCurr.withUnsafeBufferPointer { currBuf in
            localPrev.withUnsafeBufferPointer { prevBuf in
                localNext.withUnsafeMutableBufferPointer { nextBuf in
                    pmlDamping.withUnsafeBufferPointer { pmlBuf in
                        guard let pCurr = currBuf.baseAddress,
                              let pPrev = prevBuf.baseAddress,
                              let pNext = nextBuf.baseAddress,
                              let pml = pmlBuf.baseAddress else { return }

                        let one4 = SIMD4<Float>(repeating: 1.0)
                        let two4 = SIMD4<Float>(repeating: 2.0)
                        let lam4 = SIMD4<Float>(repeating: lambdaSq)
                        let visc4 = SIMD4<Float>(repeating: viscous)
                        let sig4 = SIMD4<Float>(repeating: sigma0Dt)
                        let min4 = SIMD4<Float>(repeating: -16.0)
                        let max4 = SIMD4<Float>(repeating: 16.0)

                        for z in 1..<(nz - 1) {
                            for y in 1..<(ny - 1) {
                                let rowBase = (z * ny + y) * nx
                                var x = 1
                                while x + 4 <= nx - 1 {
                                    let base = rowBase + x
                                    let p0Vec = Self.loadSIMD4(pCurr, base)
                                    let pOldVec = Self.loadSIMD4(pPrev, base)
                                    let lcVec = Self.lap27SIMD4(pCurr, nx: nx, ny: ny, x: x, y: y, z: z)
                                    let lpVec = viscous > 0.0
                                        ? Self.lap27SIMD4(pPrev, nx: nx, ny: ny, x: x, y: y, z: z)
                                        : SIMD4<Float>.zero
                                    let lossVec: SIMD4<Float> = sig4 + Self.loadSIMD4(pml, base)
                                    let waveTerm: SIMD4<Float> = two4 * p0Vec - (one4 - lossVec) * pOldVec
                                    let lapTerm: SIMD4<Float> = lam4 * lcVec + visc4 * (lcVec - lpVec)
                                    let nextVec: SIMD4<Float> = (waveTerm + lapTerm) / (one4 + lossVec)
                                    let clampedVec: SIMD4<Float> = simd_clamp(nextVec, min4, max4)
                                    for lane in 0..<4 {
                                        let v = nextVec[lane]
                                        pNext[base + lane] = v.isFinite ? clampedVec[lane] : 0.0
                                    }
                                    x += 4
                                }
                                while x < nx - 1 {
                                    let idx = rowBase + x
                                    let p0 = pCurr[idx]
                                    let pOld = pPrev[idx]
                                    let lc = Self.lap27Pointer(pCurr, nx: nx, ny: ny, x: x, y: y, z: z)
                                    let lp = viscous > 0.0 ? Self.lap27Pointer(pPrev, nx: nx, ny: ny, x: x, y: y, z: z) : 0.0
                                    let loss = sigma0Dt + pml[idx]
                                    let nextV = (2.0 * p0 - (1.0 - loss) * pOld + lambdaSq * lc + viscous * (lc - lp)) / (1.0 + loss)
                                    pNext[idx] = nextV.isFinite ? min(max(nextV, -16.0), 16.0) : 0.0
                                    x += 1
                                }
                            }
                        }
                    }
                }
            }
        }

        pressurePrev = localCurr
        pressureCurr = localNext
        pressureNext = localPrev
    }

    public mutating func stepScalarReference() {
        let nx = sizeX, ny = sizeY, nz = sizeZ
        let safeCFL = (cflParameters.dimension == 3 && cflParameters.isStable)
            ? cflParameters
            : cflParameters.clamped(toDimension: 3)
        let lambdaSq = min(safeCFL.lambdaSq, safeCFL.maxLocalLambdaSq(forDimension: 3))
        let viscous = safeCFL.viscousTerm
        let sigma0Dt = safeCFL.sigma0 * safeCFL.timeStepSeconds

        for z in 1..<(nz - 1) {
            for y in 1..<(ny - 1) {
                for x in 1..<(nx - 1) {
                    let idx = (z * ny + y) * nx + x
                    let p0 = pressureCurr[idx]
                    let pOld = pressurePrev[idx]
                    let lc = pressureCurr.withUnsafeBufferPointer {
                        Self.lap27Pointer($0.baseAddress!, nx: nx, ny: ny, x: x, y: y, z: z)
                    }
                    let lp = viscous > 0.0 ? pressurePrev.withUnsafeBufferPointer {
                        Self.lap27Pointer($0.baseAddress!, nx: nx, ny: ny, x: x, y: y, z: z)
                    } : 0.0
                    let loss = sigma0Dt + pmlDamping[idx]
                    let nextV = (2.0 * p0 - (1.0 - loss) * pOld + lambdaSq * lc + viscous * (lc - lp)) / (1.0 + loss)
                    pressureNext[idx] = nextV.isFinite ? min(max(nextV, -16.0), 16.0) : 0.0
                }
            }
        }
        swap(&pressurePrev, &pressureCurr)
        swap(&pressureCurr, &pressureNext)
    }

    public func totalEnergy() -> Float {
        pressureCurr.reduce(0.0) { $0 + $1 * $1 }
    }
}

// MARK: - 6. 128x128 120Hz Metal Compute + CPU SIMD Fallback Visual Wave Tank Controller

@Observable
@MainActor
public final class VisualFDTDWaveTankController {
    public enum TankPresetScenario: String, CaseIterable, Sendable, Identifiable {
        case anechoicPulse = "Anechoic"
        case doubleSlitDiffraction = "Double-Slit"
        case acousticConvexLens = "Metamaterial Lens"
        case helmholtzResonator = "Helmholtz"

        public var id: String { rawValue }
    }

    public enum WaveTankBrushTool: String, CaseIterable, Sendable, Identifiable {
        case shockwaveImpulse = "Shockwave"
        case diffractionWall = "Wall / Slit"
        case metamaterialLens = "Acoustic Lens"
        case eraser = "Erase"

        public var id: String { rawValue }
    }

    public private(set) var waveTank: FDTDWaveTankGrid2D
    public var activeScenario: TankPresetScenario = .doubleSlitDiffraction
    public var activeBrushTool: WaveTankBrushTool = .shockwaveImpulse
    public var isPaused: Bool = false
    public var continuousSourceFrequencyHz: Float = 220.0
    public var isContinuousSourceEnabled: Bool = true
    public var micLeftNormalized: SIMD2<Float> = SIMD2<Float>(0.68, 0.36)
    public var micRightNormalized: SIMD2<Float> = SIMD2<Float>(0.68, 0.64)
    public var sourceNormalized: SIMD2<Float> = SIMD2<Float>(0.24, 0.50)
    public private(set) var isUsingMetalCompute: Bool = false

    public var latestRMSPressure: Float {
        waveTank.interiorRMSPressure()
    }

    public var dispersionLimitedMaxFrequency: Float {
        waveTank.dispersionLimitedMaxFrequency
    }

    public var recommendedSourceBandwidth: Float {
        waveTank.recommendedSourceBandwidth
    }

    private var oscillatorPhase: Float = 0.0

    #if canImport(Metal) && !os(watchOS)
    private var metalDevice: MTLDevice?
    private var metalQueue: MTLCommandQueue?
    private var stepPipeline: MTLComputePipelineState?
    private var gpuBufA: MTLBuffer?
    private var gpuBufB: MTLBuffer?
    private var gpuBufC: MTLBuffer?
    private var gpuObstacleBuf: MTLBuffer?
    private var gpuSpeedSqBuf: MTLBuffer?
    private var gpuSlot: Int = 0
    private var gpuBuffersDirty: Bool = true
    #endif

    public init(gridSize: Int = 128, pmlThickness: Int = 16) {
        self.waveTank = FDTDWaveTankGrid2D(
            gridSize: gridSize,
            pmlThickness: pmlThickness,
            boundaryMode: .absorbingPML,
            pmlMaxSigma: 0.34
        )
        setupMetalComputePipelineIfAvailable()
        applyScenario(.doubleSlitDiffraction)
    }

    private func setupMetalComputePipelineIfAvailable() {
        #if canImport(Metal) && !os(watchOS)
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let kernelFn = library.makeFunction(name: "aetherStepFDTDWavefield"),
              let pipeline = try? device.makeComputePipelineState(function: kernelFn) else {
            self.isUsingMetalCompute = false
            return
        }

        let count = waveTank.gridSize * waveTank.gridSize
        let floatBytes = count * MemoryLayout<Float>.stride
        guard let bA = device.makeBuffer(length: floatBytes, options: .storageModeShared),
              let bB = device.makeBuffer(length: floatBytes, options: .storageModeShared),
              let bC = device.makeBuffer(length: floatBytes, options: .storageModeShared),
              let bObs = device.makeBuffer(length: count * MemoryLayout<UInt8>.stride, options: .storageModeShared),
              let bSpd = device.makeBuffer(length: floatBytes, options: .storageModeShared) else {
            self.isUsingMetalCompute = false
            return
        }

        self.metalDevice = device
        self.metalQueue = queue
        self.stepPipeline = pipeline
        self.gpuBufA = bA
        self.gpuBufB = bB
        self.gpuBufC = bC
        self.gpuObstacleBuf = bObs
        self.gpuSpeedSqBuf = bSpd
        self.isUsingMetalCompute = true
        self.gpuBuffersDirty = true
        #endif
    }

    private func uploadHostTankToGPUIfNeeded() {
        #if canImport(Metal) && !os(watchOS)
        guard isUsingMetalCompute, gpuBuffersDirty,
              let bA = gpuBufA, let bB = gpuBufB, let bC = gpuBufC,
              let bObs = gpuObstacleBuf, let bSpd = gpuSpeedSqBuf else { return }

        let count = waveTank.gridSize * waveTank.gridSize
        waveTank.pressureCurr.withUnsafeBufferPointer { src in
            bA.contents().AssumingCopy(from: src.baseAddress!, count: count)
        }
        waveTank.pressurePrev.withUnsafeBufferPointer { src in
            bB.contents().AssumingCopy(from: src.baseAddress!, count: count)
        }
        memset(bC.contents(), 0, count * MemoryLayout<Float>.stride)
        waveTank.obstacleCodes.withUnsafeBufferPointer { src in
            memcpy(bObs.contents(), src.baseAddress!, count)
        }
        waveTank.relativeSpeedSq.withUnsafeBufferPointer { src in
            bSpd.contents().AssumingCopy(from: src.baseAddress!, count: count)
        }
        gpuSlot = 0
        gpuBuffersDirty = false
        #endif
    }

    public func applyScenario(_ scenario: TankPresetScenario) {
        activeScenario = scenario
        waveTank.resetField(keepObstaclesAndLenses: false)
        let n = waveTank.gridSize

        switch scenario {
        case .anechoicPulse:
            waveTank.boundaryMode = .absorbingPML
            sourceNormalized = SIMD2<Float>(0.50, 0.50)
            waveTank.injectGaussianPulse(centerX: n / 2, centerY: n / 2, sigmaCells: 3.2, amplitude: 1.25)

        case .doubleSlitDiffraction:
            waveTank.boundaryMode = .absorbingPML
            sourceNormalized = SIMD2<Float>(0.24, 0.50)
            waveTank.configureDoubleSlitBarrier(
                barrierX: n / 2,
                slitWidthCells: max(4, n / 22),
                slitSeparationCells: max(16, n / 6)
            )
            waveTank.injectGaussianPulse(centerX: n / 4, centerY: n / 2, sigmaCells: 3.0, amplitude: 1.35)

        case .acousticConvexLens:
            waveTank.boundaryMode = .absorbingPML
            sourceNormalized = SIMD2<Float>(0.22, 0.50)
            waveTank.addRefractiveAcousticLens(
                centerX: n / 2,
                centerY: n / 2,
                radiusCells: Float(n) * 0.17,
                relativeWaveSpeed: 0.60
            )
            waveTank.injectGaussianPulse(centerX: n / 4, centerY: n / 2, sigmaCells: 3.0, amplitude: 1.30)

        case .helmholtzResonator:
            waveTank.boundaryMode = .absorbingPML
            sourceNormalized = SIMD2<Float>(0.24, 0.50)
            waveTank.configureHelmholtzResonator(centerX: (n * 58) / 100, centerY: n / 2)
            waveTank.injectGaussianPulse(centerX: n / 4, centerY: n / 2, sigmaCells: 3.0, amplitude: 1.35)
        }

        #if canImport(Metal) && !os(watchOS)
        gpuBuffersDirty = true
        #endif
    }

    public func triggerTouchPulse(normalizedX: Float, normalizedY: Float, amplitude: Float = 1.25) {
        let n = waveTank.gridSize
        let margin = waveTank.pmlThickness + 2
        let gx = min(max(Int(normalizedX * Float(n)), margin), n - margin - 1)
        let gy = min(max(Int(normalizedY * Float(n)), margin), n - margin - 1)
        waveTank.injectGaussianPulse(centerX: gx, centerY: gy, sigmaCells: 2.8, amplitude: amplitude)
        #if canImport(Metal) && !os(watchOS)
        gpuBuffersDirty = true
        #endif
    }

    public func applyInteractiveBrush(normalizedX: Float, normalizedY: Float) {
        let n = waveTank.gridSize
        let margin = waveTank.pmlThickness + 1
        let gx = min(max(Int(normalizedX * Float(n)), margin), n - margin - 1)
        let gy = min(max(Int(normalizedY * Float(n)), margin), n - margin - 1)

        switch activeBrushTool {
        case .shockwaveImpulse:
            triggerTouchPulse(normalizedX: normalizedX, normalizedY: normalizedY, amplitude: 1.35)
        case .diffractionWall:
            waveTank.paintBrushDisk(centerX: gx, centerY: gy, radiusCells: max(2, n / 42), obstacleCode: 2)
            #if canImport(Metal) && !os(watchOS)
            gpuBuffersDirty = true
            #endif
        case .metamaterialLens:
            waveTank.paintBrushDisk(centerX: gx, centerY: gy, radiusCells: max(5, n / 16), obstacleCode: 3, lensRelativeSpeed: 0.62)
            #if canImport(Metal) && !os(watchOS)
            gpuBuffersDirty = true
            #endif
        case .eraser:
            waveTank.paintBrushDisk(centerX: gx, centerY: gy, radiusCells: max(4, n / 20), obstacleCode: 0)
            #if canImport(Metal) && !os(watchOS)
            gpuBuffersDirty = true
            #endif
        }
    }

    public func clearTankGeometry() {
        waveTank.resetField(keepObstaclesAndLenses: false)
        #if canImport(Metal) && !os(watchOS)
        gpuBuffersDirty = true
        #endif
    }

    public func syncWithSynthParameters(_ params: FDTDCFLParameters, nonlinearGamma: Float = 0.04) {
        waveTank.cflParameters = params.clamped(toDimension: 2)
        waveTank.nonlinearGamma = nonlinearGamma
    }

    /// Steps the 128x128 wave tank via Metal Compute (`MTLComputeCommandEncoder`) when available,
    /// or synchronized CPU SIMD fallback when running headless.
    public func stepVisualFrame(substeps: Int = 2) {
        guard !isPaused else { return }
        let count = max(1, substeps)
        let n = waveTank.gridSize
        let bandLimitedSourceHz = min(max(continuousSourceFrequencyHz, 1.0), waveTank.dispersionLimitedMaxFrequency)
        let minSafeSigma = max(2.0, waveTank.cflParameters.minimumGaussianSigmaCells())

        #if canImport(Metal) && !os(watchOS)
        if isUsingMetalCompute,
           let queue = metalQueue,
           let pipeline = stepPipeline,
           let bA = gpuBufA, let bB = gpuBufB, let bC = gpuBufC,
           let bObs = gpuObstacleBuf, let bSpd = gpuSpeedSqBuf,
           let cmdBuf = queue.makeCommandBuffer(),
           let encoder = cmdBuf.makeComputeCommandEncoder() {

            uploadHostTankToGPUIfNeeded()
            encoder.setComputePipelineState(pipeline)

            let srcX = Float(waveTank.pmlThickness + 4) + sourceNormalized.x * Float(n - 2 * waveTank.pmlThickness - 8)
            let srcY = Float(waveTank.pmlThickness + 4) + sourceNormalized.y * Float(n - 2 * waveTank.pmlThickness - 8)

            for s in 0..<count {
                var driveVal: Float = 0.0
                if isContinuousSourceEnabled {
                    oscillatorPhase += 2.0 * Float.pi * bandLimitedSourceHz * waveTank.cflParameters.timeStepSeconds
                    if oscillatorPhase > 2.0 * Float.pi { oscillatorPhase -= 2.0 * Float.pi }
                    driveVal = 0.28 * sinf(oscillatorPhase) / max(1.0e-12, waveTank.cflParameters.timeStepSeconds * waveTank.cflParameters.timeStepSeconds)
                }

                let currBuf: MTLBuffer
                let prevBuf: MTLBuffer
                let nextBuf: MTLBuffer
                switch gpuSlot {
                case 0: currBuf = bA; prevBuf = bB; nextBuf = bC
                case 1: currBuf = bC; prevBuf = bA; nextBuf = bB
                default: currBuf = bB; prevBuf = bC; nextBuf = bA
                }

                var uniforms = FDTDWavefieldUniforms(
                    gridWidth: UInt32(n),
                    gridHeight: UInt32(n),
                    gridDepth: 1,
                    pmlThickness: UInt32(waveTank.pmlThickness),
                    boundaryMode: waveTank.boundaryMode.rawValue,
                    stepIndex: UInt32(waveTank.stepCounter + s),
                    lambdaSq: waveTank.cflParameters.lambdaSq,
                    muSq: waveTank.cflParameters.muSq,
                    sigma0Dt: waveTank.cflParameters.sigma0 * waveTank.cflParameters.timeStepSeconds,
                    viscousCoeff: waveTank.cflParameters.viscousTerm,
                    pmlSigmaMaxDt: waveTank.pmlMaxSigma,
                    nonlinearGamma: waveTank.nonlinearGamma,
                    dtSquared: waveTank.cflParameters.timeStepSeconds * waveTank.cflParameters.timeStepSeconds,
                    sourceX: srcX,
                    sourceY: srcY,
                    sourceZ: 0.0,
                    sourceValue: driveVal,
                    sourceSigmaCells: minSafeSigma,
                    micLeftX: micLeftNormalized.x * Float(n),
                    micLeftY: micLeftNormalized.y * Float(n),
                    micRightX: micRightNormalized.x * Float(n),
                    micRightY: micRightNormalized.y * Float(n),
                    displayGain: 3.2,
                    accentHue: 0.54
                )

                encoder.setBuffer(currBuf, offset: 0, index: 0)
                encoder.setBuffer(prevBuf, offset: 0, index: 1)
                encoder.setBuffer(nextBuf, offset: 0, index: 2)
                encoder.setBuffer(bObs, offset: 0, index: 3)
                encoder.setBuffer(bSpd, offset: 0, index: 4)
                encoder.setBytes(&uniforms, length: MemoryLayout<FDTDWavefieldUniforms>.stride, index: 5)

                let tgSize = MTLSize(width: 16, height: 16, depth: 1)
                let tgCount = MTLSize(width: (n + 15) / 16, height: (n + 15) / 16, depth: 1)
                encoder.dispatchThreadgroups(tgCount, threadsPerThreadgroup: tgSize)

                gpuSlot = (gpuSlot + 1) % 3
            }

            encoder.endEncoding()
            cmdBuf.commit()
            cmdBuf.waitUntilCompleted()

            let latestCurrBuf: MTLBuffer = (gpuSlot == 0) ? bA : ((gpuSlot == 1) ? bC : bB)
            let latestPrevBuf: MTLBuffer = (gpuSlot == 0) ? bB : ((gpuSlot == 1) ? bA : bC)
            let total = n * n
            let currPtr = latestCurrBuf.contents().bindMemory(to: Float.self, capacity: total)
            let prevPtr = latestPrevBuf.contents().bindMemory(to: Float.self, capacity: total)
            waveTank.syncFromGPUPointers(currPtr: currPtr, prevPtr: prevPtr, count: total, stepsAdded: count)
            return
        }
        #endif

        // Synchronized CPU SIMD fallback
        let srcX = max(waveTank.pmlThickness + 4, min(n - waveTank.pmlThickness - 5, Int(sourceNormalized.x * Float(n))))
        let srcY = max(waveTank.pmlThickness + 4, min(n - waveTank.pmlThickness - 5, Int(sourceNormalized.y * Float(n))))

        for _ in 0..<count {
            if isContinuousSourceEnabled {
                oscillatorPhase += 2.0 * Float.pi * bandLimitedSourceHz * waveTank.cflParameters.timeStepSeconds
                if oscillatorPhase > 2.0 * Float.pi {
                    oscillatorPhase -= 2.0 * Float.pi
                }
                waveTank.injectPointDrive(
                    x: srcX,
                    y: srcY,
                    pressureDelta: 0.24 * sinf(oscillatorPhase)
                )
            }
            waveTank.step()
        }
    }
}

#if canImport(Metal) && !os(watchOS)
private extension UnsafeMutableRawPointer {
    func AssumingCopy(from source: UnsafePointer<Float>, count: Int) {
        memcpy(self, source, count * MemoryLayout<Float>.stride)
    }
}
#endif
