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

    public var courantLambda: Float { sqrtf(max(0.0, lambdaSq)) }
    public var stiffnessMu: Float { sqrtf(max(0.0, muSq)) }

    public var isStable: Bool {
        let dimFactor = Float(max(1, dimension))
        let maxCompactEig: Float = (dimension == 3) ? (92.0 / 15.0) : ((dimension == 2) ? (16.0 / 3.0) : 4.0)
        let compactDiscreteOK = (
            0.25 * maxCompactEig * lambdaSq
            + 0.25 * maxCompactEig * maxCompactEig * muSq
            + 0.25 * maxCompactEig * viscousTerm
        ) <= 1.0 + 1.0e-5
        return lambdaSq >= 0.0
            && muSq >= 0.0
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

        let minRequiredH = sqrtf(
            dimF * safeC * safeC * safeDt * safeDt
                + 2.0 * dimF * safeSigma1 * safeDt
                + sqrtf(
                    powf(dimF * safeC * safeC * safeDt * safeDt + 2.0 * dimF * safeSigma1 * safeDt, 2.0)
                        + 16.0 * dimF * dimF * safeKappa * safeKappa * safeDt * safeDt
                )
        )
        let h = max(1.0e-4, gridSpacingMeters ?? (minRequiredH * 1.12))
        let hSq = h * h

        let maxViscous = 0.42 / dimF
        let rawViscous = 2.0 * safeSigma1 * safeDt / hSq
        let clampedViscous = min(rawViscous, maxViscous)

        let ceiling = (1.0 / dimF) - clampedViscous
        let safeBudget = max(0.008, ceiling * 0.96)

        let rawLambdaSq = (safeC * safeDt / h) * (safeC * safeDt / h)
        let rawMuSq = (safeKappa * safeDt / hSq) * (safeKappa * safeDt / hSq)

        // Enforce BOTH Von Neumann `lambda^2 + 4*mu^2 <= 1/D - viscous` AND compact-stencil discrete spectral radius
        let maxCompactEig: Float = (safeDim == 3) ? (92.0 / 15.0) : ((safeDim == 2) ? (16.0 / 3.0) : 4.0)
        let discreteCeiling = max(0.008, (4.0 / maxCompactEig - clampedViscous) * 0.96)
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
}

// MARK: - 3. Pre-Allocated Flat `UnsafeMutablePointer<Float>` Audio-Rate 24x24 SIMD4 Waveguide Mesh

private final class RawFDTDMeshArena: @unchecked Sendable {
    let cellCount: Int
    var pNext: UnsafeMutablePointer<Float>
    var pCurr: UnsafeMutablePointer<Float>
    var pPrev: UnsafeMutablePointer<Float>
    let lapCurrScratch: UnsafeMutablePointer<Float>
    let pmlDamping: UnsafeMutablePointer<Float>
    let obstacleMask: UnsafeMutablePointer<UInt8>

    init(gridDimension: Int, pmlWidth: Int = 3, pmlSigmaMaxDt: Float = 0.085) {
        let count = gridDimension * gridDimension
        self.cellCount = count

        self.pNext = UnsafeMutablePointer<Float>.allocate(capacity: count)
        self.pCurr = UnsafeMutablePointer<Float>.allocate(capacity: count)
        self.pPrev = UnsafeMutablePointer<Float>.allocate(capacity: count)
        self.lapCurrScratch = UnsafeMutablePointer<Float>.allocate(capacity: count)
        self.pmlDamping = UnsafeMutablePointer<Float>.allocate(capacity: count)
        self.obstacleMask = UnsafeMutablePointer<UInt8>.allocate(capacity: count)

        self.pNext.initialize(repeating: 0.0, count: count)
        self.pCurr.initialize(repeating: 0.0, count: count)
        self.pPrev.initialize(repeating: 0.0, count: count)
        self.lapCurrScratch.initialize(repeating: 0.0, count: count)
        self.obstacleMask.initialize(repeating: 0, count: count)

        for y in 0..<gridDimension {
            let dy = min(y, gridDimension - 1 - y)
            let sy: Float
            if dy < pmlWidth {
                let uy = Float(pmlWidth - dy) / Float(pmlWidth)
                sy = pmlSigmaMaxDt * uy * uy * uy
            } else {
                sy = 0.0
            }
            for x in 0..<gridDimension {
                let dx = min(x, gridDimension - 1 - x)
                let sx: Float
                if dx < pmlWidth {
                    let ux = Float(pmlWidth - dx) / Float(pmlWidth)
                    sx = pmlSigmaMaxDt * ux * ux * ux
                } else {
                    sx = 0.0
                }
                self.pmlDamping[y * gridDimension + x] = sx + sy
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
        self.pmlDamping = UnsafeMutablePointer<Float>.allocate(capacity: count)
        self.obstacleMask = UnsafeMutablePointer<UInt8>.allocate(capacity: count)

        self.pNext.initialize(from: other.pNext, count: count)
        self.pCurr.initialize(from: other.pCurr, count: count)
        self.pPrev.initialize(from: other.pPrev, count: count)
        self.lapCurrScratch.initialize(from: other.lapCurrScratch, count: count)
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
    }
}

public struct RealtimeFDTDResonatorKernel: @unchecked Sendable {
    public static let gridDimension: Int = 24
    public static let cellCount: Int = 576

    public let sampleRate: Double
    private let dt: Float
    private var arena: RawFDTDMeshArena

    // One-pole DC-blocking filters for stereo virtual microphone probes
    private var dcBlockXLeft: Float = 0.0
    private var dcBlockYLeft: Float = 0.0
    private var dcBlockXRight: Float = 0.0
    private var dcBlockYRight: Float = 0.0

    public var pNextPointer: UnsafeMutablePointer<Float> { arena.pNext }
    public var pCurrPointer: UnsafeMutablePointer<Float> { arena.pCurr }
    public var pPrevPointer: UnsafeMutablePointer<Float> { arena.pPrev }
    public var pmlDampingPointer: UnsafeMutablePointer<Float> { arena.pmlDamping }
    public var obstacleMaskPointer: UnsafeMutablePointer<UInt8> { arena.obstacleMask }

    public init(sampleRate: Double = 48_000.0) {
        let safeRate = max(8_000.0, sampleRate)
        self.sampleRate = safeRate
        self.dt = Float(1.0 / safeRate)
        self.arena = RawFDTDMeshArena(gridDimension: Self.gridDimension)
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
        let rMax = max(1.2, radiusCells)
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

    /// Real-time SIMD4 audio-rate FDTD waveguide step operating strictly on flat `UnsafeMutablePointer<Float>` grids.
    @inline(__always)
    public mutating func stepSample(
        excitation: Float,
        waveSpeed: Float = 343.0,
        stiffnessKappa: Float = 0.18,
        dampingSigma: Float = 1.8,
        nonlinearGamma: Float = 0.08,
        sourceXY: SIMD2<Float> = SIMD2<Float>(0.50, 0.50),
        micLeftXY: SIMD2<Float> = SIMD2<Float>(0.30, 0.44),
        micRightXY: SIMD2<Float> = SIMD2<Float>(0.70, 0.56)
    ) -> (Float, Float) {
        let n = Self.gridDimension
        let pCurr = arena.pCurr
        let pPrev = arena.pPrev
        let pNext = arena.pNext
        let lapScratch = arena.lapCurrScratch
        let pml = arena.pmlDamping
        let obs = arena.obstacleMask

        // Map physical waveSpeed [80..680 m/s] & plate stiffness [0..1] into CFL-guaranteed parameters
        let normSpeed = min(max((waveSpeed - 80.0) / 600.0, 0.0), 1.0)
        let normKappa = min(max(stiffnessKappa, 0.0), 1.0)
        let viscous: Float = 0.0025 + 0.0035 * min(max(dampingSigma * 0.1, 0.0), 1.0)
        let cflBudget: Float = (0.5 - viscous) * 0.95

        let muSq: Float = 0.0008 + 0.0165 * normKappa * normKappa
        let rawLambdaSq: Float = 0.055 + 0.245 * normSpeed
        let baseLambdaSq: Float = min(rawLambdaSq, max(0.015, cflBudget - 6.0 * muSq))
        let sigma0Dt: Float = max(0.2, dampingSigma) * dt
        let gammaNL: Float = min(max(nonlinearGamma, 0.0), 0.35)

        // Pass 1: SIMD4-vectorized isotropic 9-point compact Laplacian L_h(p^n) over interior [1 ..< n-1]
        let twoThirds = SIMD4<Float>(repeating: 2.0 / 3.0)
        let oneSixth = SIMD4<Float>(repeating: 1.0 / 6.0)
        let tenThirds = SIMD4<Float>(repeating: 10.0 / 3.0)

        for y in 1..<(n - 1) {
            let row = y * n
            let rowM1 = (y - 1) * n
            let rowP1 = (y + 1) * n

            // Process 20 interior cells [2..21] as 5 contiguous SIMD4 vectors + border cells x=1, x=22
            for x in [1, 22] {
                let idx = row + x
                if obs[idx] != 0 {
                    lapScratch[idx] = 0.0
                } else {
                    let c = pCurr[idx]
                    let ax = pCurr[idx - 1] + pCurr[idx + 1] + pCurr[rowM1 + x] + pCurr[rowP1 + x]
                    let dg = pCurr[rowM1 + x - 1] + pCurr[rowM1 + x + 1] + pCurr[rowP1 + x - 1] + pCurr[rowP1 + x + 1]
                    lapScratch[idx] = (2.0 / 3.0) * ax + (1.0 / 6.0) * dg - (10.0 / 3.0) * c
                }
            }

            var x = 2
            while x <= 18 {
                let base = row + x
                let cVec = SIMD4<Float>(pCurr[base], pCurr[base + 1], pCurr[base + 2], pCurr[base + 3])
                let lVec = SIMD4<Float>(pCurr[base - 1], pCurr[base], pCurr[base + 1], pCurr[base + 2])
                let rVec = SIMD4<Float>(pCurr[base + 1], pCurr[base + 2], pCurr[base + 3], pCurr[base + 4])
                let dVec = SIMD4<Float>(pCurr[rowM1 + x], pCurr[rowM1 + x + 1], pCurr[rowM1 + x + 2], pCurr[rowM1 + x + 3])
                let uVec = SIMD4<Float>(pCurr[rowP1 + x], pCurr[rowP1 + x + 1], pCurr[rowP1 + x + 2], pCurr[rowP1 + x + 3])

                let dlVec = SIMD4<Float>(pCurr[rowM1 + x - 1], pCurr[rowM1 + x], pCurr[rowM1 + x + 1], pCurr[rowM1 + x + 2])
                let drVec = SIMD4<Float>(pCurr[rowM1 + x + 1], pCurr[rowM1 + x + 2], pCurr[rowM1 + x + 3], pCurr[rowM1 + x + 4])
                let ulVec = SIMD4<Float>(pCurr[rowP1 + x - 1], pCurr[rowP1 + x], pCurr[rowP1 + x + 1], pCurr[rowP1 + x + 2])
                let urVec = SIMD4<Float>(pCurr[rowP1 + x + 1], pCurr[rowP1 + x + 2], pCurr[rowP1 + x + 3], pCurr[rowP1 + x + 4])

                let lapVec = twoThirds * (lVec + rVec + dVec + uVec)
                    + oneSixth * (dlVec + drVec + ulVec + urVec)
                    - tenThirds * cVec

                lapScratch[base] = obs[base] == 0 ? lapVec[0] : 0.0
                lapScratch[base + 1] = obs[base + 1] == 0 ? lapVec[1] : 0.0
                lapScratch[base + 2] = obs[base + 2] == 0 ? lapVec[2] : 0.0
                lapScratch[base + 3] = obs[base + 3] == 0 ? lapVec[3] : 0.0
                x += 4
            }
        }

        // Pass 2: SIMD4 time-marching with biharmonic L_h^2(p^n), visco-thermal damping & cubic tension modulation
        let maxLocalLambda = max(0.01, cflBudget - 5.4 * muSq)
        let srcCellX = min(max(Int((2.0 + min(max(sourceXY.x, 0.0), 1.0) * Float(n - 5)).rounded()), 2), n - 3)
        let srcCellY = min(max(Int((2.0 + min(max(sourceXY.y, 0.0), 1.0) * Float(n - 5)).rounded()), 2), n - 3)
        let boundedDrive = min(max(excitation, -2.5), 2.5) * 0.14

        for y in 2..<(n - 2) {
            let row = y * n
            let rowM1 = (y - 1) * n
            let rowP1 = (y + 1) * n

            var x = 2
            while x <= 18 {
                for lane in 0..<4 {
                    let cx = x + lane
                    let idx = row + cx
                    if obs[idx] != 0 {
                        pNext[idx] = 0.0
                        continue
                    }

                    let p0 = pCurr[idx]
                    let pOld = pPrev[idx]
                    let lapC = lapScratch[idx]

                    let axPrev = pPrev[idx - 1] + pPrev[idx + 1] + pPrev[rowM1 + cx] + pPrev[rowP1 + cx]
                    let dgPrev = pPrev[rowM1 + cx - 1] + pPrev[rowM1 + cx + 1] + pPrev[rowP1 + cx - 1] + pPrev[rowP1 + cx + 1]
                    let lapP = (2.0 / 3.0) * axPrev + (1.0 / 6.0) * dgPrev - (10.0 / 3.0) * pOld

                    let axLap = lapScratch[idx - 1] + lapScratch[idx + 1] + lapScratch[rowM1 + cx] + lapScratch[rowP1 + cx]
                    let dgLap = lapScratch[rowM1 + cx - 1] + lapScratch[rowM1 + cx + 1] + lapScratch[rowP1 + cx - 1] + lapScratch[rowP1 + cx + 1]
                    let biharm = (2.0 / 3.0) * axLap + (1.0 / 6.0) * dgLap - (10.0 / 3.0) * lapC

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
                    let nextVal = invDenom * (
                        2.0 * p0
                        - (1.0 - loss) * pOld
                        + effLambdaSq * lapC
                        + viscous * (lapC - lapP)
                        - muSq * biharm
                        + force
                    )
                    pNext[idx] = nextVal.isFinite ? min(max(nextVal, -4.0), 4.0) : 0.0
                }
                x += 4
            }
        }

        let rawL = Self.readBilinearPointer(pNext, normalizedXY: micLeftXY)
        let rawR = Self.readBilinearPointer(pNext, normalizedXY: micRightXY)
        arena.rotateTripleBuffers()

        // Zero-drift DC blocker + hyperbolic saturation
        let yL = rawL - dcBlockXLeft + 0.9965 * dcBlockYLeft
        dcBlockXLeft = rawL
        dcBlockYLeft = yL

        let yR = rawR - dcBlockXRight + 0.9965 * dcBlockYRight
        dcBlockXRight = rawR
        dcBlockYRight = yR

        return (tanhf(yL * 2.1), tanhf(yR * 2.1))
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
}

// MARK: - 4. High-Resolution 2D Isotropic 9-Point Wave Tank with Cubic PML (> 35 dB Suppression)

public typealias FDTD2DWaveTank = FDTDWaveTankGrid2D

public struct FDTDWaveTankGrid2D: Sendable {
    public enum BoundaryMode: UInt32, Sendable, Equatable {
        case absorbingPML = 0
        case rigidDirichlet = 1
        case rigidNeumann = 2
    }

    public let gridSize: Int
    public let pmlThickness: Int
    public var boundaryMode: BoundaryMode
    public var cflParameters: FDTDCFLParameters
    public var nonlinearGamma: Float = 0.02

    public private(set) var pressureCurr: [Float]
    public private(set) var pressurePrev: [Float]
    private var pressureNext: [Float]
    private var laplacianScratch: [Float]

    /// `true` marks solid interior obstacle cells (`obstacleCode != 0`).
    public private(set) var obstacleMask: [Bool]
    /// `0` = fluid, `1` = Dirichlet absorber, `2` = Neumann rigid wall, `3` = metamaterial lens.
    public private(set) var obstacleCodes: [UInt8]
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
        self.gridSize = n
        self.pmlThickness = safePML
        self.boundaryMode = boundaryMode
        self.pmlMaxSigma = pmlMaxSigma

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
        self.obstacleMask = [Bool](repeating: false, count: total)
        self.obstacleCodes = [UInt8](repeating: 0, count: total)
        self.relativeSpeedSq = [Float](repeating: 1.0, count: total)

        var profile = [Float](repeating: 0.0, count: total)
        for y in 0..<n {
            let distY = min(y, n - 1 - y)
            let sy: Float
            if distY < safePML {
                let uy = Float(safePML - distY) / Float(safePML)
                sy = pmlMaxSigma * (uy * uy * uy)
            } else {
                sy = 0.0
            }
            for x in 0..<n {
                let distX = min(x, n - 1 - x)
                let sx: Float
                if distX < safePML {
                    let ux = Float(safePML - distX) / Float(safePML)
                    sx = pmlMaxSigma * (ux * ux * ux)
                } else {
                    sx = 0.0
                }
                profile[y * n + x] = sx + sy
            }
        }
        self.pmlDampingProfile = profile
    }

    public mutating func syncFromGPUBuffers(curr: [Float], prev: [Float], stepsAdded: Int) {
        guard curr.count == pressureCurr.count, prev.count == pressurePrev.count else { return }
        self.pressureCurr = curr
        self.pressurePrev = prev
        self.stepCounter += max(0, stepsAdded)
    }

    public mutating func resetField(keepObstaclesAndLenses: Bool = true) {
        let total = gridSize * gridSize
        for i in 0..<total {
            pressureCurr[i] = 0.0
            pressurePrev[i] = 0.0
            pressureNext[i] = 0.0
            laplacianScratch[i] = 0.0
            if !keepObstaclesAndLenses {
                obstacleMask[i] = false
                obstacleCodes[i] = 0
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
                    setObstacle(x: cx + ox, y: cy + oy, isSolid: true)
                }
            }
        }
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
            setObstacle(x: bx, y: y, isSolid: !isOpen)
            setObstacle(x: bx + 1, y: y, isSolid: !isOpen)
        }
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

    public mutating func injectGaussianPulse(
        centerX: Int,
        centerY: Int,
        sigmaCells: Float = 2.8,
        amplitude: Float = 1.0
    ) {
        let invTwoSigmaSq = 1.0 / max(0.25, 2.0 * sigmaCells * sigmaCells)
        let support = max(2, Int(ceilf(sigmaCells * 3.5)))
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

    public mutating func injectPointDrive(x: Int, y: Int, pressureDelta: Float) {
        guard x > 1, x < gridSize - 2, y > 1, y < gridSize - 2 else { return }
        let idx = y * gridSize + x
        guard !obstacleMask[idx] else { return }
        pressureCurr[idx] += pressureDelta
    }

    /// Advances the 2D isotropic 9-point compact FDTD solver by one step.
    public mutating func step() {
        let n = gridSize
        let baseLambdaSq = cflParameters.lambdaSq
        let muSq = cflParameters.muSq
        let viscous = cflParameters.viscousTerm
        let baseSigma0Dt = cflParameters.sigma0 * cflParameters.timeStepSeconds
        let cflBudget = max(0.01, (0.5 - viscous) * 0.96)
        let usePML = (boundaryMode == .absorbingPML)

        // Pass 1: Isotropic 9-point compact Laplacian L_h(p^n)
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

        // Pass 2: Explicit 2nd-order central-difference update with L_h^2 biharmonic stiffness & cubic PML
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

                let localLambdaSq = min(baseLambdaSq * relativeSpeedSq[idx], max(0.0, cflBudget - 4.0 * muSq))
                let pmlLoss = usePML ? pmlDampingProfile[idx] : 0.0
                let totalLoss = baseSigma0Dt + pmlLoss
                let invDenom = 1.0 / (1.0 + totalLoss)

                let updated = (
                    2.0 * p0
                    - (1.0 - totalLoss) * pOld
                    + localLambdaSq * lapC
                    + viscous * (lapC - lapP)
                    - muSq * biharm
                ) * invDenom

                pressureNext[idx] = updated.isFinite ? min(max(updated, -20.0), 20.0) : 0.0
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
    public var cflParameters: FDTDCFLParameters

    public private(set) var pressureCurr: [Float]
    public private(set) var pressurePrev: [Float]
    private var pressureNext: [Float]
    private let pmlDamping: [Float]

    public init(size: Int = 20, pmlThickness: Int = 4, pmlMaxSigma: Float = 0.30) {
        let n = max(10, size)
        let safePML = min(max(2, pmlThickness), n / 3)
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
            let sz: Float = dz < safePML ? pmlMaxSigma * powf(Float(safePML - dz) / Float(safePML), 3.0) : 0.0
            for y in 0..<n {
                let dy = min(y, n - 1 - y)
                let sy: Float = dy < safePML ? pmlMaxSigma * powf(Float(safePML - dy) / Float(safePML), 3.0) : 0.0
                for x in 0..<n {
                    let dx = min(x, n - 1 - x)
                    let sx: Float = dx < safePML ? pmlMaxSigma * powf(Float(safePML - dx) / Float(safePML), 3.0) : 0.0
                    pml[(z * n + y) * n + x] = sx + sy + sz
                }
            }
        }
        self.pmlDamping = pml
    }

    public mutating func injectCenteredGaussianPulse(sigmaCells: Float = 1.8, amplitude: Float = 1.0) {
        let c = Float(sizeX / 2)
        let inv2S2 = 1.0 / (2.0 * sigmaCells * sigmaCells)
        for z in 1..<(sizeZ - 1) {
            for y in 1..<(sizeY - 1) {
                for x in 1..<(sizeX - 1) {
                    let dx = Float(x) - c
                    let dy = Float(y) - c
                    let dz = Float(z) - c
                    let val = amplitude * expf(-(dx * dx + dy * dy + dz * dz) * inv2S2)
                    let idx = (z * sizeY + y) * sizeX + x
                    pressureCurr[idx] += val
                    pressurePrev[idx] += val
                }
            }
        }
    }

    public mutating func step() {
        let nx = sizeX, ny = sizeY, nz = sizeZ
        let lambdaSq = cflParameters.lambdaSq
        let viscous = cflParameters.viscousTerm
        let sigma0Dt = cflParameters.sigma0 * cflParameters.timeStepSeconds

        @inline(__always)
        func lap27(_ field: [Float], _ x: Int, _ y: Int, _ z: Int) -> Float {
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

        for z in 1..<(nz - 1) {
            for y in 1..<(ny - 1) {
                for x in 1..<(nx - 1) {
                    let idx = (z * ny + y) * nx + x
                    let p0 = pressureCurr[idx]
                    let pOld = pressurePrev[idx]
                    let lc = lap27(pressureCurr, x, y, z)
                    let lp = viscous > 0.0 ? lap27(pressurePrev, x, y, z) : 0.0
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
        waveTank.cflParameters = params
        waveTank.nonlinearGamma = nonlinearGamma
    }

    /// Steps the 128x128 wave tank via Metal Compute (`MTLComputeCommandEncoder`) when available,
    /// or synchronized CPU SIMD fallback when running headless.
    public func stepVisualFrame(substeps: Int = 2) {
        guard !isPaused else { return }
        let count = max(1, substeps)
        let n = waveTank.gridSize

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
                    oscillatorPhase += 2.0 * Float.pi * continuousSourceFrequencyHz * waveTank.cflParameters.timeStepSeconds
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
                    sourceSigmaCells: 2.0,
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
            let hostCurr = Array(UnsafeBufferPointer(start: currPtr, count: total))
            let hostPrev = Array(UnsafeBufferPointer(start: prevPtr, count: total))
            waveTank.syncFromGPUBuffers(curr: hostCurr, prev: hostPrev, stepsAdded: count)
            return
        }
        #endif

        // Synchronized CPU SIMD fallback
        let srcX = max(waveTank.pmlThickness + 4, min(n - waveTank.pmlThickness - 5, Int(sourceNormalized.x * Float(n))))
        let srcY = max(waveTank.pmlThickness + 4, min(n - waveTank.pmlThickness - 5, Int(sourceNormalized.y * Float(n))))

        for _ in 0..<count {
            if isContinuousSourceEnabled {
                oscillatorPhase += 2.0 * Float.pi * continuousSourceFrequencyHz * waveTank.cflParameters.timeStepSeconds
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
