// MARK: - FILE: TensorNetworkQuantumOptimizer.swift

import Foundation
import simd
#if canImport(Accelerate)
import Accelerate
#endif

// MARK: - 0. Pre-Allocated chi_max = 16 Bond Slice Bank (Wait-Free / Zero-Allocation 90Hz Gesture Slicing)

/// Inline pre-allocated buffer of capacity `chi_max = 16` stored in four `SIMD4<Float>` registers.
/// Updating `activeBondDimensionSlice` (`2...16`) from 90Hz spatial pinch gestures changes only the active
/// slice index without triggering any heap `Array` allocation on the real-time audio or compositor path.
public struct PreallocatedMPSBondSliceBank: Codable, Sendable, Equatable {
    public static let chiMax: Int = 16
    public static let minBondSlice: Int = 2

    public var slice0: SIMD4<Float>
    public var slice1: SIMD4<Float>
    public var slice2: SIMD4<Float>
    public var slice3: SIMD4<Float>
    public private(set) var activeBondDimensionSlice: Int

    public init(
        singularValues: [Double] = [1.0],
        activeBondDimensionSlice: Int = PreallocatedMPSBondSliceBank.chiMax
    ) {
        var flat: (
            Float, Float, Float, Float,
            Float, Float, Float, Float,
            Float, Float, Float, Float,
            Float, Float, Float, Float
        ) = (
            1.0, 0.0, 0.0, 0.0,
            0.0, 0.0, 0.0, 0.0,
            0.0, 0.0, 0.0, 0.0,
            0.0, 0.0, 0.0, 0.0
        )
        withUnsafeMutableBytes(of: &flat) { rawBuf in
            let ptr = rawBuf.bindMemory(to: Float.self)
            let count = min(singularValues.count, Self.chiMax)
            for idx in 0..<count {
                let v = singularValues[idx]
                ptr[idx] = (v.isFinite && v > 0.0) ? Float(v) : 0.0
            }
        }
        self.slice0 = SIMD4<Float>(flat.0, flat.1, flat.2, flat.3)
        self.slice1 = SIMD4<Float>(flat.4, flat.5, flat.6, flat.7)
        self.slice2 = SIMD4<Float>(flat.8, flat.9, flat.10, flat.11)
        self.slice3 = SIMD4<Float>(flat.12, flat.13, flat.14, flat.15)
        self.activeBondDimensionSlice = min(max(activeBondDimensionSlice, Self.minBondSlice), Self.chiMax)
    }

    /// O(1) wait-free update of the active bond slice index (`2...16`) with zero heap allocations.
    @inline(__always)
    public mutating func selectActiveBondSlice(_ targetChi: Int) {
        activeBondDimensionSlice = min(max(targetChi, Self.minBondSlice), Self.chiMax)
    }

    @inline(__always)
    public func singularValue(at index: Int) -> Float {
        switch index {
        case 0: return slice0[0]
        case 1: return slice0[1]
        case 2: return slice0[2]
        case 3: return slice0[3]
        case 4: return slice1[0]
        case 5: return slice1[1]
        case 6: return slice1[2]
        case 7: return slice1[3]
        case 8: return slice2[0]
        case 9: return slice2[1]
        case 10: return slice2[2]
        case 11: return slice2[3]
        case 12: return slice3[0]
        case 13: return slice3[1]
        case 14: return slice3[2]
        case 15: return slice3[3]
        default: return 0.0
        }
    }

    public struct ActiveBondSliceMetrics: Sendable, Equatable {
        public let vonNeumannEntropyNats: Float
        public let renyi2Purity: Float
        public let schmidtRank: Float
        public let harmonicTension: Float
        public let spectralInharmonicity: Float

        public var entropyNats: Float { vonNeumannEntropyNats }
        public var purity: Float { renyi2Purity }
    }

    /// Evaluates normalized Von Neumann entropy, Rényi-2 purity, Schmidt rank, and harmonic modulation across `0..<activeBondDimensionSlice`
    /// purely in registers without any heap `Array` allocation.
    @inline(__always)
    public func evaluateActiveSliceMetrics() -> ActiveBondSliceMetrics {
        let activeCount = min(max(activeBondDimensionSlice, Self.minBondSlice), Self.chiMax)
        var normSq: Float = 0.0
        for idx in 0..<activeCount {
            let s = max(0.0, singularValue(at: idx))
            normSq += s * s
        }
        guard normSq > 1.0e-20 else {
            return ActiveBondSliceMetrics(
                vonNeumannEntropyNats: 0.0,
                renyi2Purity: 1.0,
                schmidtRank: 1.0,
                harmonicTension: 0.0,
                spectralInharmonicity: 1.0
            )
        }
        let invNormSq = 1.0 / normSq
        var entropy: Float = 0.0
        var purity: Float = 0.0
        for idx in 0..<activeCount {
            let s = max(0.0, singularValue(at: idx))
            let p = (s * s) * invNormSq
            if p > 1.0e-15 {
                entropy -= p * logf(p)
                purity += p * p
            }
        }
        let clampedEntropy = max(0.0, entropy)
        let clampedPurity = min(max(purity, 1.0 / Float(Self.chiMax)), 1.0)
        let effectiveRank = min(max(1.0 / max(1.0e-6, clampedPurity), 1.0), Float(activeCount))
        let maxEntropy = Float(MPSTelemetrySnapshot.maxSpin3HalfBipartiteEntropyNats)
        let tension = min(max(clampedEntropy / maxEntropy, 0.0), 1.0)
        let inharmonicity = 1.0 + 1.5 * min(max(1.0 - clampedPurity, 0.0), 1.0)
        return ActiveBondSliceMetrics(
            vonNeumannEntropyNats: clampedEntropy,
            renyi2Purity: clampedPurity,
            schmidtRank: effectiveRank,
            harmonicTension: tension,
            spectralInharmonicity: inharmonicity
        )
    }
}

// MARK: - 1. Matrix Product State Telemetry Snapshot & Core Tensor

public struct MPSTelemetrySnapshot: Codable, Sendable, Equatable {
    public static let maxSpin3HalfBipartiteEntropyNats: Double = log(16.0)

    public let siteCount: Int
    public let maxBondDimension: Int
    public let schmidtSingularValues: [Double]
    public let vonNeumannEntropyNats: Double
    public let renyi2Purity: Double
    public let variationalEnergy: Double
    public let discardedTruncationWeight: Double

    public init(
        siteCount: Int,
        maxBondDimension: Int,
        schmidtSingularValues: [Double],
        vonNeumannEntropyNats: Double,
        renyi2Purity: Double,
        variationalEnergy: Double,
        discardedTruncationWeight: Double = 0.0
    ) {
        self.siteCount = siteCount
        self.maxBondDimension = maxBondDimension
        self.schmidtSingularValues = schmidtSingularValues
        self.vonNeumannEntropyNats = max(0.0, vonNeumannEntropyNats)
        self.renyi2Purity = min(max(renyi2Purity, 0.0), 1.0)
        self.variationalEnergy = variationalEnergy
        self.discardedTruncationWeight = min(max(discardedTruncationWeight, 0.0), 1.0)
    }

    public var centralEntanglementEntropy: Float {
        Float(vonNeumannEntropyNats)
    }

    public var groundStateEnergyEstimate: Float {
        Float(variationalEnergy)
    }

    public var mappedHarmonicTension: Float {
        let normalized = vonNeumannEntropyNats / Self.maxSpin3HalfBipartiteEntropyNats
        return Float(min(max(normalized, 0.0), 1.0))
    }

    public var mappedSpectralInharmonicity: Float {
        let impurity = min(max(1.0 - renyi2Purity, 0.0), 1.0)
        return Float(1.0 + 1.5 * impurity)
    }

    public var maxEntanglementEntropyNats: Double {
        vonNeumannEntropyNats
    }

    public var groundStateEnergy: Double {
        variationalEnergy
    }

    public var effectiveSchmidtRank: Double {
        1.0 / max(1e-12, renyi2Purity)
    }

    public var totalTruncationError: Double {
        let sumSq = schmidtSingularValues.reduce(0.0) { $0 + $1 * $1 }
        let unnormalizedDeficit = max(0.0, 1.0 - sumSq)
        return max(discardedTruncationWeight, unnormalizedDeficit)
    }
}

public struct MPSCoreTensor: Codable, Sendable, Equatable {
    public let leftBond: Int
    public let physicalDim: Int
    public let rightBond: Int
    /// Row-major storage of shape `[leftBond, physicalDim, rightBond]`
    public var storage: [Double]

    public init(leftBond: Int, physicalDim: Int = 4, rightBond: Int, storage: [Double]) {
        self.leftBond = leftBond
        self.physicalDim = physicalDim
        self.rightBond = rightBond
        self.storage = storage
    }

    @inline(__always)
    public func index(_ alphaL: Int, _ phys: Int, _ alphaR: Int) -> Int {
        (alphaL * physicalDim + phys) * rightBond + alphaR
    }

    @inline(__always)
    public subscript(alphaL: Int, phys: Int, alphaR: Int) -> Double {
        get { storage[index(alphaL, phys, alphaR)] }
        set { storage[index(alphaL, phys, alphaR)] = newValue }
    }
}

// MARK: - 2. 6-Site Tensor-Train Matrix Product State Engine & QR-Preconditioned One-Sided Jacobi SVD

public struct MatrixProductStateEngine: Sendable, Equatable {
    public static let defaultSiteCount: Int = 6
    public static let physicalDimension: Int = 4
    public static let hilbertSpaceDimension: Int = 4_096 // 4^6
    public static let hardMaxBondCap: Int = 16

    public var cores: [MPSCoreTensor]
    public let maxBondDim: Int
    public var midCutSingularValues: [Double]
    public var cumulativeTruncationError: Double
    public var preallocatedBondSliceBank: PreallocatedMPSBondSliceBank

    public init(stateVector: [Float], maxBondDim: Int = 16) {
        self.init(stateVector: stateVector.map(Double.init), maxBondDim: maxBondDim)
    }

    /// Decomposes any 4096-element quantum state vector (`d = 4`, `N = 6` sites) into a left-canonical
    /// Matrix Product State `cores[0..<6]` using QR-preconditioned One-Sided Jacobi SVD.
    public init(stateVector: [Double], maxBondDim: Int = 16) {
        let chiMax = min(max(1, maxBondDim), Self.hardMaxBondCap)
        self.maxBondDim = chiMax

        var psi = [Double](repeating: 0.0, count: Self.hilbertSpaceDimension)
        let copyCount = min(stateVector.count, Self.hilbertSpaceDimension)
        for i in 0..<copyCount {
            let v = stateVector[i]
            psi[i] = v.isFinite ? v : 0.0
        }

        // Normalize state vector (fallback to |000000> if identically zero)
        var normSq = 0.0
        for amp in psi {
            normSq += amp * amp
        }
        if normSq > 1e-24 {
            let invNorm = 1.0 / sqrt(normSq)
            for i in 0..<psi.count {
                psi[i] *= invNorm
            }
        } else {
            psi[0] = 1.0
        }

        // Sequential Tensor-Train SVD across cuts k = 1, 2, 3, 4, 5
        var builtCores: [MPSCoreTensor] = []
        builtCores.reserveCapacity(Self.defaultSiteCount)

        var remainder = psi
        var leftRank = 1
        var rightPhysProd = Self.hilbertSpaceDimension
        var capturedCut3Spectrum: [Double] = [1.0]
        var accumulatedDiscardedWeight = 0.0

        for site in 0..<(Self.defaultSiteCount - 1) {
            let rows = leftRank * Self.physicalDimension
            rightPhysProd /= Self.physicalDimension
            let cols = rightPhysProd

            let svd = Self.jacobiSVDWithTruncation(
                matrix: remainder,
                rows: rows,
                cols: cols,
                maxRank: chiMax
            )
            accumulatedDiscardedWeight += svd.discardedWeight

            // Normalize retained singular values after rank truncation to preserve ||psi||_2 == 1
            var sNormSq = 0.0
            for sv in svd.s {
                sNormSq += sv * sv
            }
            let sScale = sNormSq > 1e-24 ? (1.0 / sqrt(sNormSq)) : 1.0
            var normalizedS = [Double](repeating: 0.0, count: svd.rank)
            for k in 0..<svd.rank {
                normalizedS[k] = svd.s[k] * sScale
            }

            if site == 2 {
                // Cut k = 3 separates sites {0, 1, 2} from {3, 4, 5}
                capturedCut3Spectrum = normalizedS
            }

            builtCores.append(
                MPSCoreTensor(
                    leftBond: leftRank,
                    physicalDim: Self.physicalDimension,
                    rightBond: svd.rank,
                    storage: svd.u
                )
            )

            // Next remainder = diag(normalizedS) * V^T of shape [svd.rank, cols]
            var nextRem = [Double](repeating: 0.0, count: svd.rank * cols)
            for r in 0..<svd.rank {
                let sVal = normalizedS[r]
                let rowOffset = r * cols
                for c in 0..<cols {
                    nextRem[rowOffset + c] = sVal * svd.vt[rowOffset + c]
                }
            }
            remainder = nextRem
            leftRank = svd.rank
        }

        // Final core (site 5): shape [leftRank, 4, 1]
        builtCores.append(
            MPSCoreTensor(
                leftBond: leftRank,
                physicalDim: Self.physicalDimension,
                rightBond: 1,
                storage: remainder
            )
        )

        self.cores = builtCores
        self.midCutSingularValues = capturedCut3Spectrum
        self.cumulativeTruncationError = min(1.0, max(0.0, accumulatedDiscardedWeight))
        self.preallocatedBondSliceBank = PreallocatedMPSBondSliceBank(
            singularValues: capturedCut3Spectrum,
            activeBondDimensionSlice: max(2, chiMax)
        )
    }

    public init(
        cores: [MPSCoreTensor],
        maxBondDim: Int = 16,
        midCutSingularValues: [Double]? = nil,
        cumulativeTruncationError: Double = 0.0
    ) {
        self.cores = cores
        let clampedChi = min(max(1, maxBondDim), Self.hardMaxBondCap)
        self.maxBondDim = clampedChi
        let resolvedSigmas: [Double]
        if let explicit = midCutSingularValues {
            resolvedSigmas = explicit
        } else {
            resolvedSigmas = Self.computeBipartiteSchmidtValues(cores: cores, cutSite: 3)
        }
        self.midCutSingularValues = resolvedSigmas
        self.cumulativeTruncationError = min(1.0, max(0.0, cumulativeTruncationError))
        self.preallocatedBondSliceBank = PreallocatedMPSBondSliceBank(
            singularValues: resolvedSigmas,
            activeBondDimensionSlice: max(2, clampedChi)
        )
    }

    /// Updates only the active slice index (`2...16`) on the pre-allocated `chi_max = 16` bond buffer
    /// without allocating any new `Array` on the real-time gesture path.
    @inline(__always)
    public mutating func setActiveBondDimensionSlice(_ targetChi: Int) {
        preallocatedBondSliceBank.selectActiveBondSlice(targetChi)
    }

    public static func decompose(stateVector: [Double], maxBondDim: Int = 16) -> MatrixProductStateEngine {
        MatrixProductStateEngine(stateVector: stateVector, maxBondDim: maxBondDim)
    }

    /// Constructs a canonical maximally entangled product of 3 Bell pairs across cut `k = 3`:
    /// `(1 / sqrt(rank)) * sum_{m=0..<rank} |m>_{012} (x) |m>_{345}` (`rank = 8` for 3 qubit-Bell pairs, or any `1...64`),
    /// yielding `rank` equal Schmidt singular values and exact `S_vN = ln(rank)`.
    public static func makeMaximallyEntangledBellState(schmidtRank: Int = 8) -> [Double] {
        let r = min(max(1, schmidtRank), 64)
        var psi = [Double](repeating: 0.0, count: hilbertSpaceDimension)
        let amp = 1.0 / sqrt(Double(r))
        for m in 0..<r {
            let globalIndex = m * 64 + m
            psi[globalIndex] = amp
        }
        return psi
    }

    /// Constructs a canonical separable product state `|0>^{\otimes 6}` (`S_vN == 0`, `P_2 == 1`).
    public static func makeSeparableProductState() -> [Double] {
        var psi = [Double](repeating: 0.0, count: hilbertSpaceDimension)
        psi[0] = 1.0
        return psi
    }

    /// Reconstructs the dense 4096-element state vector by sequentially contracting `cores[0..<6]`.
    public func reconstructStateVector() -> [Double] {
        guard !cores.isEmpty else { return [] }
        var tensor = cores[0].storage
        var leftDim = cores[0].leftBond * cores[0].physicalDim
        var bondDim = cores[0].rightBond

        for site in 1..<cores.count {
            let core = cores[site]
            let phys = core.physicalDim
            let nextBond = core.rightBond
            let physNext = phys * nextBond
            var contracted = [Double](repeating: 0.0, count: leftDim * physNext)

            for l in 0..<leftDim {
                let lBase = l * bondDim
                let outLBase = l * physNext
                for b in 0..<bondDim {
                    let tVal = tensor[lBase + b]
                    guard abs(tVal) > 1e-18 else { continue }
                    let coreBase = b * physNext
                    for pn in 0..<physNext {
                        contracted[outLBase + pn] += tVal * core.storage[coreBase + pn]
                    }
                }
            }
            tensor = contracted
            leftDim *= phys
            bondDim = nextBond
        }
        return tensor
    }

    /// Evaluates bipartite Schmidt singular values, Von Neumann Entanglement Entropy `S_vN = -sum(p_i * ln(p_i))`,
    /// and Rényi-2 Purity `sum(p_i^2)` across cut `k = 3`.
    public func evaluateEntanglement(variationalEnergy: Double = 0.0) -> MPSTelemetrySnapshot {
        let sigmas = Self.computeBipartiteSchmidtValues(cores: cores, cutSite: 3)
        let metrics = Self.entropyAndPurity(fromSingularValues: sigmas)
        var actualMaxBond = 1
        for core in cores {
            let b = max(core.leftBond, core.rightBond)
            if b > actualMaxBond {
                actualMaxBond = b
            }
        }

        return MPSTelemetrySnapshot(
            siteCount: cores.count,
            maxBondDimension: actualMaxBond,
            schmidtSingularValues: sigmas,
            vonNeumannEntropyNats: metrics.vonNeumannEntropyNats,
            renyi2Purity: metrics.renyi2Purity,
            variationalEnergy: variationalEnergy,
            discardedTruncationWeight: cumulativeTruncationError
        )
    }

    public static func entropyAndPurity(
        fromSingularValues sigmas: [Double]
    ) -> (vonNeumannEntropyNats: Double, renyi2Purity: Double) {
        var totalWeight = 0.0
        for s in sigmas where s > 0.0 {
            totalWeight += s * s
        }
        guard totalWeight > 1e-24 else {
            return (0.0, 1.0)
        }

        var entropy = 0.0
        var purity = 0.0
        for s in sigmas where s > 0.0 {
            let p = (s * s) / totalWeight
            if p > 1e-18 {
                entropy -= p * log(p)
                purity += p * p
            }
        }
        return (max(0.0, entropy), min(max(purity, 0.0), 1.0))
    }

    /// Computes gauge-invariant bipartite Schmidt singular values across `cutSite` (`1..<cores.count`)
    /// in `O(N * chi^3 * d)` time via thin Householder QR (left sweep) and LQ (right sweep) without
    /// materializing the dense `d^(N/2) x d^(N/2)` matrix.
    public static func computeBipartiteSchmidtValues(cores: [MPSCoreTensor], cutSite: Int = 3) -> [Double] {
        guard cores.count >= 2, cutSite >= 1, cutSite < cores.count else {
            return [1.0]
        }

        // 1. Left-to-right thin QR sweep across sites 0..<cutSite -> upper-triangular factor R_L [rRows x midBond]
        var rCols = cores[0].leftBond
        guard rCols == 1 else { return [1.0] }
        var rMat: [Double] = [1.0]
        var rRows = 1

        for s in 0..<cutSite {
            let c = cores[s]
            let lBond = c.leftBond
            let phys = c.physicalDim
            let nextBond = c.rightBond
            guard lBond == rCols, c.storage.count == lBond * phys * nextBond else {
                return [1.0]
            }

            let physNext = phys * nextBond
            var absorbed = [Double](repeating: 0.0, count: rRows * physNext)
            for i in 0..<rRows {
                let rBase = i * lBond
                let outBase = i * physNext
                for b in 0..<lBond {
                    let rv = rMat[rBase + b]
                    guard abs(rv) > 1e-18 else { continue }
                    let cBase = b * physNext
                    for pn in 0..<physNext {
                        absorbed[outBase + pn] += rv * c.storage[cBase + pn]
                    }
                }
            }

            let qr = qrOrthogonalize(matrix: absorbed, rows: rRows * phys, cols: nextBond)
            rMat = qr.r
            rRows = qr.rank
            rCols = nextBond
        }

        // 2. Right-to-left thin LQ sweep across sites (cores.count - 1)...cutSite -> lower-triangular L_R [midBond x lCols]
        var lRows = cores[cores.count - 1].rightBond
        guard lRows == 1 else { return [1.0] }
        var lMat: [Double] = [1.0]
        var lCols = 1

        for s in stride(from: cores.count - 1, through: cutSite, by: -1) {
            let c = cores[s]
            let lBond = c.leftBond
            let phys = c.physicalDim
            let rBond = c.rightBond
            guard rBond == lRows, c.storage.count == lBond * phys * rBond else {
                return [1.0]
            }

            let leftPhys = lBond * phys
            var absorbed = [Double](repeating: 0.0, count: leftPhys * lCols)
            for lp in 0..<leftPhys {
                let cBase = lp * rBond
                let outBase = lp * lCols
                for b in 0..<rBond {
                    let cv = c.storage[cBase + b]
                    guard abs(cv) > 1e-18 else { continue }
                    let lBase = b * lCols
                    for j in 0..<lCols {
                        absorbed[outBase + j] += cv * lMat[lBase + j]
                    }
                }
            }

            let lq = lqOrthogonalize(matrix: absorbed, rows: lBond, cols: phys * lCols)
            lMat = lq.l
            lRows = lBond
            lCols = lq.rank
        }

        guard rCols == lRows else { return [1.0] }
        let midBond = rCols
        var center = [Double](repeating: 0.0, count: rRows * lCols)
        for i in 0..<rRows {
            let rBase = i * midBond
            let cBase = i * lCols
            for b in 0..<midBond {
                let rv = rMat[rBase + b]
                guard abs(rv) > 1e-18 else { continue }
                let lBase = b * lCols
                for j in 0..<lCols {
                    center[cBase + j] += rv * lMat[lBase + j]
                }
            }
        }

        let svd = jacobiSVDWithTruncation(
            matrix: center,
            rows: rRows,
            cols: lCols,
            maxRank: hardMaxBondCap
        )
        return svd.s
    }

    // MARK: - QR-Preconditioned One-Sided Jacobi Singular Value Decomposition (Flat Contiguous Storage)

    /// Computes thin SVD `A = U * diag(s) * V^T` via QR-preconditioned One-Sided Jacobi orthogonal rotations.
    /// - `matrix`: row-major `[rows x cols]`
    /// - Returns: `(u: [rows x rank], s: [rank], vt: [rank x cols], rank: Int)` with `U^T U = I` and `V^T V = I`.
    public static func jacobiSVD(
        matrix: [Double],
        rows: Int,
        cols: Int,
        maxRank: Int
    ) -> (u: [Double], s: [Double], vt: [Double], rank: Int) {
        let res = jacobiSVDWithTruncation(matrix: matrix, rows: rows, cols: cols, maxRank: maxRank)
        return (res.u, res.s, res.vt, res.rank)
    }

    /// Computes thin SVD along with the relative discarded Schmidt weight `sum_{k >= rank} sigma_k^2 / sum_{all} sigma_k^2`.
    public static func jacobiSVDWithTruncation(
        matrix: [Double],
        rows: Int,
        cols: Int,
        maxRank: Int
    ) -> (u: [Double], s: [Double], vt: [Double], rank: Int, discardedWeight: Double) {
        precondition(rows > 0 && cols > 0 && matrix.count == rows * cols, "Invalid matrix dimensions for jacobiSVD")
        let targetMaxRank = max(1, min(min(rows, cols), maxRank))

        if rows < cols {
            // Wide matrix: transpose A (cols x rows), solve tall A^T = U_t * S * V_t^T => A = V_t * S * U_t^T
            var aT = [Double](repeating: 0.0, count: cols * rows)
            for r in 0..<rows {
                let rowBase = r * cols
                for c in 0..<cols {
                    aT[c * rows + r] = matrix[rowBase + c]
                }
            }
            let tall = jacobiSVDTallPreconditioned(matrix: aT, rows: cols, cols: rows, maxRank: targetMaxRank)
            let rank = tall.rank

            // U = (V_t)^T_transposed -> tall.vt is [rank x rows], transpose to [rows x rank]
            var uOut = [Double](repeating: 0.0, count: rows * rank)
            for k in 0..<rank {
                let vtBase = k * rows
                for r in 0..<rows {
                    uOut[r * rank + k] = tall.vt[vtBase + r]
                }
            }

            // V^T = (U_t)^T -> tall.u is [cols x rank], transpose to [rank x cols]
            var vtOut = [Double](repeating: 0.0, count: rank * cols)
            for k in 0..<rank {
                let vtBase = k * cols
                for c in 0..<cols {
                    vtOut[vtBase + c] = tall.u[c * rank + k]
                }
            }

            return (uOut, tall.s, vtOut, rank, tall.discardedWeight)
        } else {
            return jacobiSVDTallPreconditioned(matrix: matrix, rows: rows, cols: cols, maxRank: targetMaxRank)
        }
    }

    private static func jacobiSVDTallPreconditioned(
        matrix: [Double],
        rows: Int,
        cols: Int,
        maxRank: Int
    ) -> (u: [Double], s: [Double], vt: [Double], rank: Int, discardedWeight: Double) {
        if rows > cols {
            // Precondition tall matrix (rows > cols) via thin Householder QR: A = Q * R
            let qr = qrOrthogonalize(matrix: matrix, rows: rows, cols: cols)
            let rSVD = oneSidedJacobiCoreFlat(matrix: qr.r, rows: cols, cols: cols, maxRank: maxRank)
            let rank = rSVD.rank

            // U = Q [rows x cols] * U_R [cols x rank] -> [rows x rank]
            var uOut = [Double](repeating: 0.0, count: rows * rank)
            for r in 0..<rows {
                let qBase = r * cols
                let uBase = r * rank
                for c in 0..<cols {
                    let qVal = qr.q[qBase + c]
                    guard abs(qVal) > 1e-18 else { continue }
                    let urBase = c * rank
                    for k in 0..<rank {
                        uOut[uBase + k] += qVal * rSVD.u[urBase + k]
                    }
                }
            }
            return (uOut, rSVD.s, rSVD.vt, rank, rSVD.discardedWeight)
        } else {
            return oneSidedJacobiCoreFlat(matrix: matrix, rows: rows, cols: cols, maxRank: maxRank)
        }
    }

    /// Flat-buffer One-Sided Hestenes-Jacobi SVD without nested array heap allocations.
    private static func oneSidedJacobiCoreFlat(
        matrix: [Double],
        rows: Int,
        cols: Int,
        maxRank: Int
    ) -> (u: [Double], s: [Double], vt: [Double], rank: Int, discardedWeight: Double) {
        // Store W and V in flat column-major arrays: column `c` occupies `[c * rows ..< (c + 1) * rows]`
        var wFlat = [Double](repeating: 0.0, count: cols * rows)
        for r in 0..<rows {
            let rowBase = r * cols
            for c in 0..<cols {
                wFlat[c * rows + r] = matrix[rowBase + c]
            }
        }

        var vFlat = [Double](repeating: 0.0, count: cols * cols)
        for c in 0..<cols {
            vFlat[c * cols + c] = 1.0
        }

        let maxSweeps = 45
        if cols >= 2 {
            for _ in 0..<maxSweeps {
                var maxRelativeOffDiag = 0.0

                for p in 0..<(cols - 1) {
                    let pWBase = p * rows
                    let pVBase = p * cols
                    for q in (p + 1)..<cols {
                        let qWBase = q * rows
                        let qVBase = q * cols

                        var alpha = 0.0
                        var beta = 0.0
                        var gamma = 0.0
                        var alphaVec = SIMD4<Double>.zero
                        var betaVec = SIMD4<Double>.zero
                        var gammaVec = SIMD4<Double>.zero
                        var r = 0
                        while r + 4 <= rows {
                            let wpVec = SIMD4<Double>(
                                wFlat[pWBase + r],
                                wFlat[pWBase + r + 1],
                                wFlat[pWBase + r + 2],
                                wFlat[pWBase + r + 3]
                            )
                            let wqVec = SIMD4<Double>(
                                wFlat[qWBase + r],
                                wFlat[qWBase + r + 1],
                                wFlat[qWBase + r + 2],
                                wFlat[qWBase + r + 3]
                            )
                            alphaVec += wpVec * wpVec
                            betaVec += wqVec * wqVec
                            gammaVec += wpVec * wqVec
                            r += 4
                        }
                        alpha = alphaVec[0] + alphaVec[1] + alphaVec[2] + alphaVec[3]
                        beta = betaVec[0] + betaVec[1] + betaVec[2] + betaVec[3]
                        gamma = gammaVec[0] + gammaVec[1] + gammaVec[2] + gammaVec[3]
                        while r < rows {
                            let wp = wFlat[pWBase + r]
                            let wq = wFlat[qWBase + r]
                            alpha += wp * wp
                            beta += wq * wq
                            gamma += wp * wq
                            r += 1
                        }

                        let denomScale = sqrt(alpha * beta)
                        guard denomScale > 1e-30 else { continue }
                        let rel = abs(gamma) / denomScale
                        if rel > maxRelativeOffDiag {
                            maxRelativeOffDiag = rel
                        }

                        if rel > 1e-15 {
                            let zeta = (beta - alpha) / (2.0 * gamma)
                            let signZeta: Double = zeta >= 0.0 ? 1.0 : -1.0
                            let t = signZeta / (abs(zeta) + sqrt(1.0 + zeta * zeta))
                            let cRot = 1.0 / sqrt(1.0 + t * t)
                            let sRot = cRot * t

                            let cVec = SIMD4<Double>(repeating: cRot)
                            let sVec = SIMD4<Double>(repeating: sRot)
                            var rRot = 0
                            while rRot + 4 <= rows {
                                let wpVec = SIMD4<Double>(
                                    wFlat[pWBase + rRot],
                                    wFlat[pWBase + rRot + 1],
                                    wFlat[pWBase + rRot + 2],
                                    wFlat[pWBase + rRot + 3]
                                )
                                let wqVec = SIMD4<Double>(
                                    wFlat[qWBase + rRot],
                                    wFlat[qWBase + rRot + 1],
                                    wFlat[qWBase + rRot + 2],
                                    wFlat[qWBase + rRot + 3]
                                )
                                let npVec = cVec * wpVec - sVec * wqVec
                                let nqVec = sVec * wpVec + cVec * wqVec
                                wFlat[pWBase + rRot] = npVec[0]
                                wFlat[pWBase + rRot + 1] = npVec[1]
                                wFlat[pWBase + rRot + 2] = npVec[2]
                                wFlat[pWBase + rRot + 3] = npVec[3]
                                wFlat[qWBase + rRot] = nqVec[0]
                                wFlat[qWBase + rRot + 1] = nqVec[1]
                                wFlat[qWBase + rRot + 2] = nqVec[2]
                                wFlat[qWBase + rRot + 3] = nqVec[3]
                                rRot += 4
                            }
                            while rRot < rows {
                                let wp = wFlat[pWBase + rRot]
                                let wq = wFlat[qWBase + rRot]
                                wFlat[pWBase + rRot] = cRot * wp - sRot * wq
                                wFlat[qWBase + rRot] = sRot * wp + cRot * wq
                                rRot += 1
                            }
                            for r in 0..<cols {
                                let vp = vFlat[pVBase + r]
                                let vq = vFlat[qVBase + r]
                                vFlat[pVBase + r] = cRot * vp - sRot * vq
                                vFlat[qVBase + r] = sRot * vp + cRot * vq
                            }
                        }
                    }
                }

                if maxRelativeOffDiag < 1e-14 {
                    break
                }
            }
        }

        // Compute singular values ||W[:, c]||_2 and sort descending
        var colNorms = [(index: Int, sigma: Double)]()
        colNorms.reserveCapacity(cols)
        var totalSpectralWeight = 0.0
        for c in 0..<cols {
            let cBase = c * rows
            var sq = 0.0
            for r in 0..<rows {
                let wVal = wFlat[cBase + r]
                sq += wVal * wVal
            }
            totalSpectralWeight += sq
            colNorms.append((c, sqrt(sq)))
        }
        colNorms.sort { $0.sigma > $1.sigma }

        let topSigma = colNorms.first?.sigma ?? 0.0
        let cutoff = topSigma * 1e-12
        var nonZeroCount = 0
        for item in colNorms where item.sigma > cutoff {
            nonZeroCount += 1
        }
        let rank = max(1, min(maxRank, nonZeroCount))

        var retainedSpectralWeight = 0.0
        for k in 0..<rank {
            let s = colNorms[k].sigma
            retainedSpectralWeight += s * s
        }
        let discardedWeight: Double
        if totalSpectralWeight > 1e-30 {
            discardedWeight = max(0.0, (totalSpectralWeight - retainedSpectralWeight) / totalSpectralWeight)
        } else {
            discardedWeight = 0.0
        }

        // Build column-orthonormal U [rows x rank] in column-major flat buffer first, then transpose to row-major
        var uColsFlat = [Double](repeating: 0.0, count: rank * rows)
        var sValues = [Double](repeating: 0.0, count: rank)
        var vtOut = [Double](repeating: 0.0, count: rank * cols)
        var candidate = [Double](repeating: 0.0, count: rows)

        for k in 0..<rank {
            let origIdx = colNorms[k].index
            let sigma = colNorms[k].sigma
            sValues[k] = sigma
            let uColBase = k * rows
            let wColBase = origIdx * rows

            if sigma > 1e-15 {
                let invS = 1.0 / sigma
                for r in 0..<rows {
                    uColsFlat[uColBase + r] = wFlat[wColBase + r] * invS
                }
            } else {
                // Complete orthonormal column via 2-pass Modified Gram-Schmidt against columns 0..<k
                for attempt in 0..<rows {
                    for r in 0..<rows { candidate[r] = 0.0 }
                    candidate[(k + attempt) % rows] = 1.0
                    for _ in 0..<2 {
                        for prev in 0..<k {
                            let prevBase = prev * rows
                            var dot = 0.0
                            for r in 0..<rows {
                                dot += candidate[r] * uColsFlat[prevBase + r]
                            }
                            for r in 0..<rows {
                                candidate[r] -= dot * uColsFlat[prevBase + r]
                            }
                        }
                    }
                    var nSq = 0.0
                    for r in 0..<rows { nSq += candidate[r] * candidate[r] }
                    if nSq > 1e-24 {
                        let inv = 1.0 / sqrt(nSq)
                        for r in 0..<rows {
                            uColsFlat[uColBase + r] = candidate[r] * inv
                        }
                        break
                    }
                }
            }

            let vtRowBase = k * cols
            let vColBase = origIdx * cols
            for c in 0..<cols {
                vtOut[vtRowBase + c] = vFlat[vColBase + c]
            }
        }

        var uOut = [Double](repeating: 0.0, count: rows * rank)
        for r in 0..<rows {
            let rowBase = r * rank
            for k in 0..<rank {
                uOut[rowBase + k] = uColsFlat[k * rows + r]
            }
        }

        return (uOut, sValues, vtOut, rank, discardedWeight)
    }
}

// MARK: - 3. 2-Site DMRG Variational Optimizer (6-Site Transverse-Field Spin-3/2 Ising MPO)

public struct DMRGVariationalOptimizer: Sendable {
    public let anisotropyDelta: Double
    public let maxBondDim: Int
    public let lanczosIterations: Int

    public init(
        anisotropyDelta: Double = 1.0,
        maxBondDim: Int = 16,
        lanczosIterations: Int = 8
    ) {
        self.anisotropyDelta = anisotropyDelta
        self.maxBondDim = min(max(2, maxBondDim), MatrixProductStateEngine.hardMaxBondCap)
        self.lanczosIterations = max(2, lanczosIterations)
    }

    /// Runs 2-site DMRG sweeps directly on `mps` in-place using cached left/right MPO environments,
    /// returning the final telemetry snapshot and updating `mps.cores` to the variational ground state.
    public func runSweeps(
        mps: inout MatrixProductStateEngine,
        sweepCount: Int = 2
    ) -> MPSTelemetrySnapshot {
        let snaps = executeCachedSweeps(
            mps: &mps,
            couplingJ: anisotropyDelta,
            transverseFieldH: 0.5,
            sweeps: max(1, sweepCount),
            maxBondDim: maxBondDim,
            restoreLeftCanonicalAtEnd: true
        )
        return snaps.last ?? mps.evaluateEntanglement()
    }

    /// Evaluates the exact variational expectation energy `<psi | H | psi> / <psi | psi>` on the 4096D 6-site state
    /// for `H = -J * sum_{i=0..4} Z_i Z_{i+1} - h * sum_{i=0..5} X_i`.
    public static func expectationEnergy(
        stateVector: [Double],
        couplingJ: Double,
        transverseFieldH: Double
    ) -> Double {
        let mps = MatrixProductStateEngine(stateVector: stateVector, maxBondDim: 16)
        let mpo = buildSixSiteSpin3HalfMPO(couplingJ: couplingJ, transverseFieldH: transverseFieldH)
        var workspace = DMRGContractionWorkspace()
        return evaluateMPOExpectation(cores: mps.cores, mpo: mpo, workspace: &workspace)
    }

    public static func runSweeps(
        initialState: [Float],
        couplingJ: Double = 1.0,
        transverseFieldH: Double = 0.5,
        sweeps: Int = 4,
        maxBondDim: Int = 16
    ) -> [MPSTelemetrySnapshot] {
        runSweeps(
            initialState: initialState.map(Double.init),
            couplingJ: couplingJ,
            transverseFieldH: transverseFieldH,
            sweeps: sweeps,
            maxBondDim: maxBondDim
        )
    }

    public static func runSweeps(
        initialState: [Double],
        couplingJ: Double = 1.0,
        transverseFieldH: Double = 0.5,
        sweeps: Int = 4,
        maxBondDim: Int = 16
    ) -> [MPSTelemetrySnapshot] {
        DMRGVariationalOptimizer(
            anisotropyDelta: couplingJ,
            maxBondDim: maxBondDim,
            lanczosIterations: 8
        ).runSweeps(
            initialState: initialState,
            couplingJ: couplingJ,
            transverseFieldH: transverseFieldH,
            sweeps: sweeps,
            maxBondDim: maxBondDim
        )
    }

    /// Executes 2-Site DMRG variational sweeps across the 6-site bio-acoustic tensor network,
    /// strictly lowering `variationalEnergy` relative to a random or excited initial state.
    public func runSweeps(
        initialState: [Double],
        couplingJ: Double = 1.0,
        transverseFieldH: Double = 0.5,
        sweeps: Int = 4,
        maxBondDim: Int = 16
    ) -> [MPSTelemetrySnapshot] {
        let chiMax = min(max(2, maxBondDim), MatrixProductStateEngine.hardMaxBondCap)
        var engine = MatrixProductStateEngine(stateVector: initialState, maxBondDim: chiMax)
        return executeCachedSweeps(
            mps: &engine,
            couplingJ: couplingJ,
            transverseFieldH: transverseFieldH,
            sweeps: max(1, sweeps),
            maxBondDim: chiMax,
            restoreLeftCanonicalAtEnd: false
        )
    }

    private func executeCachedSweeps(
        mps: inout MatrixProductStateEngine,
        couplingJ: Double,
        transverseFieldH: Double,
        sweeps: Int,
        maxBondDim: Int,
        restoreLeftCanonicalAtEnd: Bool
    ) -> [MPSTelemetrySnapshot] {
        let totalSweeps = max(1, sweeps)
        let chiMax = min(max(2, maxBondDim), MatrixProductStateEngine.hardMaxBondCap)
        let mpo = Self.buildSixSiteSpin3HalfMPO(couplingJ: couplingJ, transverseFieldH: transverseFieldH)
        var workspace = DMRGContractionWorkspace()

        // Ensure sites 0..4 are left-canonical and sites 5..1 are right-canonicalized so bond (0,1) is in exact mixed gauge
        Self.leftCanonicalizeByQR(&mps.cores, upToSite: mps.cores.count - 1)
        Self.rightCanonicalizeFromRight(&mps.cores, downToSite: 1, maxBondDim: chiMax)

        // Precompute and cache left and right MPO environments across all sweeps:
        // leftEnv[i] has shape [chiL, mpoBondL, chiL] before site i
        // rightEnv[i+1] has shape [chiR, mpoBondR, chiR] after site i
        var leftEnv = Array(repeating: [1.0], count: 7)
        var rightEnv = Array(repeating: [1.0], count: 7)
        for site in stride(from: 5, through: 1, by: -1) {
            rightEnv[site] = Self.contractRightStep(
                rightEnv: rightEnv[site + 1],
                core: mps.cores[site],
                mpoSite: mpo[site],
                workspace: &workspace
            )
        }

        var snapshots: [MPSTelemetrySnapshot] = []
        snapshots.reserveCapacity(totalSweeps)
        let baseKrylov = max(4, min(14, lanczosIterations))

        for sweepIdx in 0..<totalSweeps {
            let krylovDim = min(16, baseKrylov + sweepIdx * 2)
            var sweepMaxDiscarded = 0.0

            // 1. Left-to-Right 2-site sweep: bonds (0,1), (1,2), (2,3), (3,4), (4,5)
            for site in 0..<5 {
                let disc = Self.optimizeTwoSiteBond(
                    site: site,
                    movingRight: true,
                    krylovDim: krylovDim,
                    maxBondDim: chiMax,
                    mpo: mpo,
                    cores: &mps.cores,
                    leftEnv: &leftEnv,
                    rightEnv: &rightEnv,
                    workspace: &workspace
                )
                if disc > sweepMaxDiscarded {
                    sweepMaxDiscarded = disc
                }
            }

            // 2. Right-to-Left 2-site sweep: bonds (4,5), (3,4), (2,3), (1,2), (0,1)
            for site in stride(from: 4, through: 0, by: -1) {
                let disc = Self.optimizeTwoSiteBond(
                    site: site,
                    movingRight: false,
                    krylovDim: krylovDim,
                    maxBondDim: chiMax,
                    mpo: mpo,
                    cores: &mps.cores,
                    leftEnv: &leftEnv,
                    rightEnv: &rightEnv,
                    workspace: &workspace
                )
                if disc > sweepMaxDiscarded {
                    sweepMaxDiscarded = disc
                }
            }

            // After right-to-left sweep finishes at site 0, rightEnv[1] and cores[0] give <psi|H|psi> in O(chi^3 d w)
            let topEnv = Self.contractRightStep(
                rightEnv: rightEnv[1],
                core: mps.cores[0],
                mpoSite: mpo[0],
                workspace: &workspace
            )
            var normSq = 0.0
            for v in mps.cores[0].storage {
                normSq += v * v
            }
            let energy = (topEnv.first ?? 0.0) / max(1e-24, normSq)

            mps.cumulativeTruncationError = max(mps.cumulativeTruncationError, sweepMaxDiscarded)
            mps.midCutSingularValues = MatrixProductStateEngine.computeBipartiteSchmidtValues(
                cores: mps.cores,
                cutSite: 3
            )
            snapshots.append(mps.evaluateEntanglement(variationalEnergy: energy))
        }

        if restoreLeftCanonicalAtEnd {
            Self.leftCanonicalizeByQR(&mps.cores, upToSite: mps.cores.count - 1)
            mps.midCutSingularValues = MatrixProductStateEngine.computeBipartiteSchmidtValues(
                cores: mps.cores,
                cutSite: 3
            )
        }

        return snapshots
    }

    // MARK: - Preallocated Flat Workspace & Sequential O(chi^3 d^2) Tensor Contractions

    internal struct DMRGContractionWorkspace: Sendable {
        var t1: [Double]
        var t2: [Double]
        var t3: [Double]
        var envT1: [Double]
        var envT2: [Double]
        var thetaBuf: [Double]
        var matVecOut: [Double]
        var krylovBasisFlat: [Double]
        var tridiagTFlat: [Double]
        var tridiagVFlat: [Double]
        var alphas: [Double]
        var betas: [Double]

        init() {
            let maxChi = MatrixProductStateEngine.hardMaxBondCap // 16
            let maxW = 3
            self.t1 = [Double](repeating: 0.0, count: maxChi * maxW * 16 * maxChi)
            self.t2 = [Double](repeating: 0.0, count: maxChi * 4 * maxW * 4 * maxChi)
            self.t3 = [Double](repeating: 0.0, count: maxChi * 16 * maxW * maxChi)
            self.envT1 = [Double](repeating: 0.0, count: maxChi * maxW * 4 * maxChi)
            self.envT2 = [Double](repeating: 0.0, count: maxChi * 4 * maxW * maxChi)
            self.thetaBuf = [Double](repeating: 0.0, count: maxChi * 16 * maxChi)
            self.matVecOut = [Double](repeating: 0.0, count: maxChi * 16 * maxChi)
            self.krylovBasisFlat = [Double](repeating: 0.0, count: 16 * maxChi * 16 * maxChi)
            self.tridiagTFlat = [Double](repeating: 0.0, count: 16 * 16)
            self.tridiagVFlat = [Double](repeating: 0.0, count: 16 * 16)
            self.alphas = [Double](repeating: 0.0, count: 16)
            self.betas = [Double](repeating: 0.0, count: 16)
        }
    }

    internal struct MPOSiteTensor: Sendable {
        let leftBond: Int
        let rightBond: Int
        /// Dense storage `[leftBond, rightBond, 4, 4]` for `(wL, wR, sOut, sIn)`
        let data: [Double]

        @inline(__always)
        func index(_ wL: Int, _ wR: Int, _ sOut: Int, _ sIn: Int) -> Int {
            (((wL * rightBond + wR) * 4 + sOut) * 4) + sIn
        }
    }

    internal static func buildSixSiteSpin3HalfMPO(
        couplingJ: Double,
        transverseFieldH: Double
    ) -> [MPOSiteTensor] {
        // Physical d = 4 Spin-3/2 operators (real symmetric -> exact Hermitian Hamiltonian):
        // Z = diag(1.5, 0.5, -0.5, -1.5)
        // X = Spin-3/2 S^x ladder operator
        var opI = [Double](repeating: 0.0, count: 16)
        var opZ = [Double](repeating: 0.0, count: 16)
        var opX = [Double](repeating: 0.0, count: 16)

        let zDiag = [1.5, 0.5, -0.5, -1.5]
        for s in 0..<4 {
            opI[s * 4 + s] = 1.0
            opZ[s * 4 + s] = zDiag[s]
        }
        let c01 = 0.5 * sqrt(3.0)
        opX[0 * 4 + 1] = c01; opX[1 * 4 + 0] = c01
        opX[1 * 4 + 2] = 1.0; opX[2 * 4 + 1] = 1.0
        opX[2 * 4 + 3] = c01; opX[3 * 4 + 2] = c01

        func setBlock(_ storage: inout [Double], rightDim: Int, wL: Int, wR: Int, scale: Double, op: [Double]) {
            let base = (wL * rightDim + wR) * 16
            for idx in 0..<16 {
                storage[base + idx] = scale * op[idx]
            }
        }

        // Site 0: [1 x 3] = [-h X, -J Z, I]
        var w0 = [Double](repeating: 0.0, count: 1 * 3 * 16)
        setBlock(&w0, rightDim: 3, wL: 0, wR: 0, scale: -transverseFieldH, op: opX)
        setBlock(&w0, rightDim: 3, wL: 0, wR: 1, scale: -couplingJ, op: opZ)
        setBlock(&w0, rightDim: 3, wL: 0, wR: 2, scale: 1.0, op: opI)

        // Bulk sites 1..4: [3 x 3] = [[I, 0, 0], [Z, 0, 0], [-h X, -J Z, I]]
        var wBulk = [Double](repeating: 0.0, count: 3 * 3 * 16)
        setBlock(&wBulk, rightDim: 3, wL: 0, wR: 0, scale: 1.0, op: opI)
        setBlock(&wBulk, rightDim: 3, wL: 1, wR: 0, scale: 1.0, op: opZ)
        setBlock(&wBulk, rightDim: 3, wL: 2, wR: 0, scale: -transverseFieldH, op: opX)
        setBlock(&wBulk, rightDim: 3, wL: 2, wR: 1, scale: -couplingJ, op: opZ)
        setBlock(&wBulk, rightDim: 3, wL: 2, wR: 2, scale: 1.0, op: opI)

        // Site 5: [3 x 1] = [[I], [Z], [-h X]]
        var w5 = [Double](repeating: 0.0, count: 3 * 1 * 16)
        setBlock(&w5, rightDim: 1, wL: 0, wR: 0, scale: 1.0, op: opI)
        setBlock(&w5, rightDim: 1, wL: 1, wR: 0, scale: 1.0, op: opZ)
        setBlock(&w5, rightDim: 1, wL: 2, wR: 0, scale: -transverseFieldH, op: opX)

        return [
            MPOSiteTensor(leftBond: 1, rightBond: 3, data: w0),
            MPOSiteTensor(leftBond: 3, rightBond: 3, data: wBulk),
            MPOSiteTensor(leftBond: 3, rightBond: 3, data: wBulk),
            MPOSiteTensor(leftBond: 3, rightBond: 3, data: wBulk),
            MPOSiteTensor(leftBond: 3, rightBond: 3, data: wBulk),
            MPOSiteTensor(leftBond: 3, rightBond: 1, data: w5)
        ]
    }

    private static func leftCanonicalizeByQR(
        _ cores: inout [MPSCoreTensor],
        upToSite maxSite: Int
    ) {
        let limit = min(maxSite, cores.count - 1)
        guard limit >= 1 else { return }
        for site in 0..<limit {
            let core = cores[site]
            let rows = core.leftBond * core.physicalDim
            let cols = core.rightBond
            let qr = MatrixProductStateEngine.qrOrthogonalize(
                matrix: core.storage,
                rows: rows,
                cols: cols
            )
            let rank = qr.rank
            cores[site] = MPSCoreTensor(
                leftBond: core.leftBond,
                physicalDim: core.physicalDim,
                rightBond: rank,
                storage: qr.q
            )

            // Absorb R [rank x cols] into left bond of cores[site + 1] [cols x (phys * nextRight)]
            let nextCore = cores[site + 1]
            let rightCols = nextCore.physicalDim * nextCore.rightBond
            var updatedNext = [Double](repeating: 0.0, count: rank * rightCols)
            for k in 0..<rank {
                let rBase = k * cols
                let outBase = k * rightCols
                for b in 0..<cols {
                    let rVal = qr.r[rBase + b]
                    guard abs(rVal) > 1e-18 else { continue }
                    let nextBase = b * rightCols
                    for rc in 0..<rightCols {
                        updatedNext[outBase + rc] += rVal * nextCore.storage[nextBase + rc]
                    }
                }
            }
            var normSq = 0.0
            for v in updatedNext { normSq += v * v }
            if normSq > 1e-24 {
                let invNorm = 1.0 / sqrt(normSq)
                for idx in 0..<updatedNext.count {
                    updatedNext[idx] *= invNorm
                }
            }
            cores[site + 1] = MPSCoreTensor(
                leftBond: rank,
                physicalDim: nextCore.physicalDim,
                rightBond: nextCore.rightBond,
                storage: updatedNext
            )
        }
    }

    private static func rightCanonicalizeFromRight(
        _ cores: inout [MPSCoreTensor],
        downToSite minSite: Int,
        maxBondDim: Int
    ) {
        for site in stride(from: cores.count - 1, through: max(1, minSite), by: -1) {
            let core = cores[site]
            let rows = core.leftBond
            let cols = core.physicalDim * core.rightBond
            let lq = MatrixProductStateEngine.lqOrthogonalize(
                matrix: core.storage,
                rows: rows,
                cols: cols
            )
            let rank = min(lq.rank, maxBondDim)
            var qTrunc = [Double](repeating: 0.0, count: rank * cols)
            for k in 0..<rank {
                let srcBase = k * cols
                let dstBase = k * cols
                for c in 0..<cols {
                    qTrunc[dstBase + c] = lq.q[srcBase + c]
                }
            }

            cores[site] = MPSCoreTensor(
                leftBond: rank,
                physicalDim: core.physicalDim,
                rightBond: core.rightBond,
                storage: qTrunc
            )

            // Absorb L [rows x rank] into right bond of cores[site - 1]
            let leftCore = cores[site - 1]
            let leftRows = leftCore.leftBond * leftCore.physicalDim
            var updatedLeft = [Double](repeating: 0.0, count: leftRows * rank)
            for lr in 0..<leftRows {
                let leftBase = lr * rows
                let outBase = lr * rank
                for b in 0..<rows {
                    let lv = leftCore.storage[leftBase + b]
                    guard abs(lv) > 1e-18 else { continue }
                    let lMatBase = b * lq.rank
                    for k in 0..<rank {
                        updatedLeft[outBase + k] += lv * lq.l[lMatBase + k]
                    }
                }
            }
            var normSq = 0.0
            for v in updatedLeft { normSq += v * v }
            if normSq > 1e-24 {
                let invNorm = 1.0 / sqrt(normSq)
                for idx in 0..<updatedLeft.count {
                    updatedLeft[idx] *= invNorm
                }
            }
            cores[site - 1] = MPSCoreTensor(
                leftBond: leftCore.leftBond,
                physicalDim: leftCore.physicalDim,
                rightBond: rank,
                storage: updatedLeft
            )
        }
    }

    /// Updates left MPO environment `L'[aOut, wR, aIn]` from `L[lOut, wL, lIn]` via sequential 3-step `O(chi^3 d w + chi^2 d^2 w^2)` contraction.
    internal static func contractLeftStep(
        leftEnv: [Double],
        core: MPSCoreTensor,
        mpoSite: MPOSiteTensor,
        workspace: inout DMRGContractionWorkspace
    ) -> [Double] {
        let lDim = core.leftBond
        let rDim = core.rightBond
        let wLeft = mpoSite.leftBond
        let wRight = mpoSite.rightBond

        // Step 1: envT1[lOut, wL, sIn, aIn] = sum_{lIn} leftEnv[lOut, wL, lIn] * core[lIn, sIn, aIn]
        let lwCount = lDim * wLeft
        let sR = 4 * rDim
        let t1Count = lwCount * sR
        if workspace.envT1.count < t1Count {
            workspace.envT1 = [Double](repeating: 0.0, count: t1Count)
        } else {
            for i in 0..<t1Count { workspace.envT1[i] = 0.0 }
        }

        for lw in 0..<lwCount {
            let t1Base = lw * sR
            let envBase = lw * lDim
            for lIn in 0..<lDim {
                let envVal = leftEnv[envBase + lIn]
                guard abs(envVal) > 1e-18 else { continue }
                let coreBase = lIn * sR
                for sr in 0..<sR {
                    workspace.envT1[t1Base + sr] += envVal * core.storage[coreBase + sr]
                }
            }
        }

        // Step 2: envT2[lOut, sOut, wR, aIn] = sum_{wL, sIn} mpoSite[wL, wR, sOut, sIn] * envT1[lOut, wL, sIn, aIn]
        let wRDim = wRight * rDim
        let t2Count = lDim * 4 * wRDim
        if workspace.envT2.count < t2Count {
            workspace.envT2 = [Double](repeating: 0.0, count: t2Count)
        } else {
            for i in 0..<t2Count { workspace.envT2[i] = 0.0 }
        }

        for lOut in 0..<lDim {
            for wL in 0..<wLeft {
                for sIn in 0..<4 {
                    let t1Base = ((lOut * wLeft + wL) * 4 + sIn) * rDim
                    for wR in 0..<wRight {
                        for sOut in 0..<4 {
                            let opVal = mpoSite.data[mpoSite.index(wL, wR, sOut, sIn)]
                            guard abs(opVal) > 1e-18 else { continue }
                            let t2Base = ((lOut * 4 + sOut) * wRight + wR) * rDim
                            for aIn in 0..<rDim {
                                workspace.envT2[t2Base + aIn] += opVal * workspace.envT1[t1Base + aIn]
                            }
                        }
                    }
                }
            }
        }

        // Step 3: out[aOut, wR, aIn] = sum_{lOut, sOut} core[lOut, sOut, aOut] * envT2[lOut, sOut, wR, aIn]
        var out = [Double](repeating: 0.0, count: rDim * wRDim)
        let lsCount = lDim * 4
        for lsOut in 0..<lsCount {
            let coreBase = lsOut * rDim
            let t2Base = lsOut * wRDim
            for aOut in 0..<rDim {
                let braVal = core.storage[coreBase + aOut]
                guard abs(braVal) > 1e-18 else { continue }
                let outBase = aOut * wRDim
                for waIn in 0..<wRDim {
                    out[outBase + waIn] += braVal * workspace.envT2[t2Base + waIn]
                }
            }
        }
        return out
    }

    /// Updates right MPO environment `R'[aOut, wL, aIn]` from `R[rOut, wR, rIn]` via sequential 3-step `O(chi^3 d w + chi^2 d^2 w^2)` contraction.
    internal static func contractRightStep(
        rightEnv: [Double],
        core: MPSCoreTensor,
        mpoSite: MPOSiteTensor,
        workspace: inout DMRGContractionWorkspace
    ) -> [Double] {
        let lDim = core.leftBond
        let rDim = core.rightBond
        let wLeft = mpoSite.leftBond
        let wRight = mpoSite.rightBond

        // Step 1: envT1[aIn, sIn, rOut, wR] = sum_{rIn} core[aIn, sIn, rIn] * rightEnv[rOut, wR, rIn]
        let asCount = lDim * 4
        let rwCount = rDim * wRight
        let t1Count = asCount * rwCount
        if workspace.envT1.count < t1Count {
            workspace.envT1 = [Double](repeating: 0.0, count: t1Count)
        } else {
            for i in 0..<t1Count { workspace.envT1[i] = 0.0 }
        }

        for asIn in 0..<asCount {
            let coreBase = asIn * rDim
            let t1Base = asIn * rwCount
            for rw in 0..<rwCount {
                let envBase = rw * rDim
                var sum = 0.0
                for rIn in 0..<rDim {
                    sum += core.storage[coreBase + rIn] * rightEnv[envBase + rIn]
                }
                workspace.envT1[t1Base + rw] = sum
            }
        }

        // Step 2: envT2[aIn, wL, sOut, rOut] = sum_{sIn, wR} mpoSite[wL, wR, sOut, sIn] * envT1[aIn, sIn, rOut, wR]
        let sR = 4 * rDim
        let t2Count = lDim * wLeft * sR
        if workspace.envT2.count < t2Count {
            workspace.envT2 = [Double](repeating: 0.0, count: t2Count)
        } else {
            for i in 0..<t2Count { workspace.envT2[i] = 0.0 }
        }

        for aIn in 0..<lDim {
            for sIn in 0..<4 {
                let asIn = aIn * 4 + sIn
                for wR in 0..<wRight {
                    for wL in 0..<wLeft {
                        for sOut in 0..<4 {
                            let opVal = mpoSite.data[mpoSite.index(wL, wR, sOut, sIn)]
                            guard abs(opVal) > 1e-18 else { continue }
                            let t2Base = ((aIn * wLeft + wL) * 4 + sOut) * rDim
                            for rOut in 0..<rDim {
                                let t1Idx = (asIn * rDim + rOut) * wRight + wR
                                workspace.envT2[t2Base + rOut] += opVal * workspace.envT1[t1Idx]
                            }
                        }
                    }
                }
            }
        }

        // Step 3: out[aOut, wL, aIn] = sum_{sOut, rOut} core[aOut, sOut, rOut] * envT2[aIn, wL, sOut, rOut]
        var out = [Double](repeating: 0.0, count: lDim * wLeft * lDim)
        for aOut in 0..<lDim {
            let braBase = aOut * sR
            for aIn in 0..<lDim {
                for wL in 0..<wLeft {
                    let t2Base = (aIn * wLeft + wL) * sR
                    var sum = 0.0
                    for sr in 0..<sR {
                        sum += core.storage[braBase + sr] * workspace.envT2[t2Base + sr]
                    }
                    out[(aOut * wLeft + wL) * lDim + aIn] = sum
                }
            }
        }
        return out
    }

    internal static func evaluateMPOExpectation(
        cores: [MPSCoreTensor],
        mpo: [MPOSiteTensor],
        workspace: inout DMRGContractionWorkspace
    ) -> Double {
        var env = [1.0]
        var normEnv = [1.0]
        var idData = [Double](repeating: 0.0, count: 16)
        for s in 0..<4 { idData[s * 4 + s] = 1.0 }
        let idMPO = MPOSiteTensor(leftBond: 1, rightBond: 1, data: idData)

        for site in 0..<cores.count {
            env = contractLeftStep(leftEnv: env, core: cores[site], mpoSite: mpo[site], workspace: &workspace)
            normEnv = contractLeftStep(leftEnv: normEnv, core: cores[site], mpoSite: idMPO, workspace: &workspace)
        }
        let denom = max(1e-24, normEnv.first ?? 1.0)
        return (env.first ?? 0.0) / denom
    }

    /// Applies the 2-site effective Hamiltonian `H_eff` to `theta[aL, s1, s2, aR]` sequentially in `O(chi^3 d^2 w)`
    /// using preallocated workspace buffers without materializing a dense `(16*chi^2) x (16*chi^2)` matrix.
    private static func applyEffectiveTwoSiteHamiltonianInPlace(
        thetaOffset: Int,
        thetaSource: [Double],
        chiL: Int,
        chiR: Int,
        leftEnv: [Double],
        w1: MPOSiteTensor,
        w2: MPOSiteTensor,
        rightEnv: [Double],
        workspace: inout DMRGContractionWorkspace
    ) {
        let wLCount = w1.leftBond
        let wMidCount = w1.rightBond
        let wRCount = w2.rightBond

        // Step 1: T1[aLOut, wL, s1In, s2In, aRIn] = sum_{aLIn} L[aLOut, wL, aLIn] * theta[aLIn, s1In, s2In, aRIn]
        let s12R = 16 * chiR
        let t1Count = chiL * wLCount * s12R
        for i in 0..<t1Count { workspace.t1[i] = 0.0 }

        for aLOut in 0..<chiL {
            for wL in 0..<wLCount {
                let t1Base = (aLOut * wLCount + wL) * s12R
                let lRowBase = (aLOut * wLCount + wL) * chiL
                for aLIn in 0..<chiL {
                    let lVal = leftEnv[lRowBase + aLIn]
                    guard abs(lVal) > 1e-18 else { continue }
                    let thBase = thetaOffset + aLIn * s12R
                    let lVec = SIMD4<Double>(repeating: lVal)
                    var idx = 0
                    while idx + 4 <= s12R {
                        let dstVec = SIMD4<Double>(
                            workspace.t1[t1Base + idx],
                            workspace.t1[t1Base + idx + 1],
                            workspace.t1[t1Base + idx + 2],
                            workspace.t1[t1Base + idx + 3]
                        ) + lVec * SIMD4<Double>(
                            thetaSource[thBase + idx],
                            thetaSource[thBase + idx + 1],
                            thetaSource[thBase + idx + 2],
                            thetaSource[thBase + idx + 3]
                        )
                        workspace.t1[t1Base + idx] = dstVec[0]
                        workspace.t1[t1Base + idx + 1] = dstVec[1]
                        workspace.t1[t1Base + idx + 2] = dstVec[2]
                        workspace.t1[t1Base + idx + 3] = dstVec[3]
                        idx += 4
                    }
                    while idx < s12R {
                        workspace.t1[t1Base + idx] += lVal * thetaSource[thBase + idx]
                        idx += 1
                    }
                }
            }
        }

        // Step 2: T2[aLOut, s1Out, wMid, s2In, aRIn] = sum_{wL, s1In} W1[wL, wMid, s1Out, s1In] * T1
        let s2R = 4 * chiR
        let t2Count = chiL * 4 * wMidCount * s2R
        for i in 0..<t2Count { workspace.t2[i] = 0.0 }

        for aLOut in 0..<chiL {
            for wL in 0..<wLCount {
                for s1In in 0..<4 {
                    let t1Base = ((aLOut * wLCount + wL) * 4 + s1In) * s2R
                    for wMid in 0..<wMidCount {
                        for s1Out in 0..<4 {
                            let op1 = w1.data[w1.index(wL, wMid, s1Out, s1In)]
                            guard abs(op1) > 1e-18 else { continue }
                            let t2Base = ((aLOut * 4 + s1Out) * wMidCount + wMid) * s2R
                            let opVec = SIMD4<Double>(repeating: op1)
                            var idx = 0
                            while idx + 4 <= s2R {
                                let dstVec = SIMD4<Double>(
                                    workspace.t2[t2Base + idx],
                                    workspace.t2[t2Base + idx + 1],
                                    workspace.t2[t2Base + idx + 2],
                                    workspace.t2[t2Base + idx + 3]
                                ) + opVec * SIMD4<Double>(
                                    workspace.t1[t1Base + idx],
                                    workspace.t1[t1Base + idx + 1],
                                    workspace.t1[t1Base + idx + 2],
                                    workspace.t1[t1Base + idx + 3]
                                )
                                workspace.t2[t2Base + idx] = dstVec[0]
                                workspace.t2[t2Base + idx + 1] = dstVec[1]
                                workspace.t2[t2Base + idx + 2] = dstVec[2]
                                workspace.t2[t2Base + idx + 3] = dstVec[3]
                                idx += 4
                            }
                            while idx < s2R {
                                workspace.t2[t2Base + idx] += op1 * workspace.t1[t1Base + idx]
                                idx += 1
                            }
                        }
                    }
                }
            }
        }

        // Step 3: T3[aLOut, s1Out, s2Out, wR, aRIn] = sum_{wMid, s2In} W2[wMid, wR, s2Out, s2In] * T2
        let t3Count = chiL * 16 * wRCount * chiR
        for i in 0..<t3Count { workspace.t3[i] = 0.0 }

        let chiL4 = chiL * 4
        for aL1 in 0..<chiL4 {
            for wMid in 0..<wMidCount {
                for s2In in 0..<4 {
                    let t2Base = ((aL1 * wMidCount + wMid) * 4 + s2In) * chiR
                    for wR in 0..<wRCount {
                        for s2Out in 0..<4 {
                            let op2 = w2.data[w2.index(wMid, wR, s2Out, s2In)]
                            guard abs(op2) > 1e-18 else { continue }
                            let t3Base = ((aL1 * 4 + s2Out) * wRCount + wR) * chiR
                            for aRIn in 0..<chiR {
                                workspace.t3[t3Base + aRIn] += op2 * workspace.t2[t2Base + aRIn]
                            }
                        }
                    }
                }
            }
        }

        // Step 4: matVecOut[aLOut, s1Out, s2Out, aROut] = sum_{wR, aRIn} T3[...] * R[aROut, wR, aRIn]
        let outCount = chiL * 16 * chiR
        for i in 0..<outCount { workspace.matVecOut[i] = 0.0 }

        let chiL16 = chiL * 16
        for aL12 in 0..<chiL16 {
            let outBase = aL12 * chiR
            for wR in 0..<wRCount {
                let t3Base = (aL12 * wRCount + wR) * chiR
                for aROut in 0..<chiR {
                    let rBase = (aROut * wRCount + wR) * chiR
                    var sum = 0.0
                    for aRIn in 0..<chiR {
                        sum += workspace.t3[t3Base + aRIn] * rightEnv[rBase + aRIn]
                    }
                    workspace.matVecOut[outBase + aROut] += sum
                }
            }
        }
    }

    private static func optimizeTwoSiteBond(
        site: Int,
        movingRight: Bool,
        krylovDim: Int,
        maxBondDim: Int,
        mpo: [MPOSiteTensor],
        cores: inout [MPSCoreTensor],
        leftEnv: inout [[Double]],
        rightEnv: inout [[Double]],
        workspace: inout DMRGContractionWorkspace
    ) -> Double {
        let c1 = cores[site]
        let c2 = cores[site + 1]
        let chiL = c1.leftBond
        let midBond = c1.rightBond
        let chiR = c2.rightBond

        // Form 2-site wave-function tensor theta[aL, s1, s2, aR] of shape [chiL * 4, 4 * chiR]
        let leftRows = chiL * 4
        let rightCols = 4 * chiR
        let dim = leftRows * rightCols
        for i in 0..<dim { workspace.thetaBuf[i] = 0.0 }

        for lr in 0..<leftRows {
            let c1Base = lr * midBond
            let thBase = lr * rightCols
            for b in 0..<midBond {
                let v1 = c1.storage[c1Base + b]
                guard abs(v1) > 1e-18 else { continue }
                let c2Base = b * rightCols
                for rc in 0..<rightCols {
                    workspace.thetaBuf[thBase + rc] += v1 * c2.storage[c2Base + rc]
                }
            }
        }

        // Minimize <theta | H_eff | theta> / <theta | theta> via flat-workspace Lanczos eigensolver
        let optTheta = lanczosLowestEigenvectorFlat(
            dim: dim,
            krylovDim: krylovDim,
            chiL: chiL,
            chiR: chiR,
            leftEnv: leftEnv[site],
            w1: mpo[site],
            w2: mpo[site + 1],
            rightEnv: rightEnv[site + 2],
            workspace: &workspace
        )

        // Split optimized 2-site tensor via QR-preconditioned One-Sided Jacobi SVD with bond truncation <= maxBondDim
        let svd = MatrixProductStateEngine.jacobiSVDWithTruncation(
            matrix: optTheta,
            rows: leftRows,
            cols: rightCols,
            maxRank: maxBondDim
        )
        var sNormSq = 0.0
        for sv in svd.s { sNormSq += sv * sv }
        let sScale = sNormSq > 1e-24 ? (1.0 / sqrt(sNormSq)) : 1.0

        if movingRight {
            cores[site] = MPSCoreTensor(
                leftBond: chiL,
                physicalDim: 4,
                rightBond: svd.rank,
                storage: svd.u
            )
            var nextRight = [Double](repeating: 0.0, count: svd.rank * rightCols)
            for k in 0..<svd.rank {
                let sVal = svd.s[k] * sScale
                let rowBase = k * rightCols
                for rc in 0..<rightCols {
                    nextRight[rowBase + rc] = sVal * svd.vt[rowBase + rc]
                }
            }
            cores[site + 1] = MPSCoreTensor(
                leftBond: svd.rank,
                physicalDim: 4,
                rightBond: chiR,
                storage: nextRight
            )
            leftEnv[site + 1] = contractLeftStep(
                leftEnv: leftEnv[site],
                core: cores[site],
                mpoSite: mpo[site],
                workspace: &workspace
            )
        } else {
            var nextLeft = [Double](repeating: 0.0, count: leftRows * svd.rank)
            for lr in 0..<leftRows {
                let rowBase = lr * svd.rank
                for k in 0..<svd.rank {
                    nextLeft[rowBase + k] = svd.u[rowBase + k] * (svd.s[k] * sScale)
                }
            }
            cores[site] = MPSCoreTensor(
                leftBond: chiL,
                physicalDim: 4,
                rightBond: svd.rank,
                storage: nextLeft
            )
            cores[site + 1] = MPSCoreTensor(
                leftBond: svd.rank,
                physicalDim: 4,
                rightBond: chiR,
                storage: svd.vt
            )
            rightEnv[site + 1] = contractRightStep(
                rightEnv: rightEnv[site + 2],
                core: cores[site + 1],
                mpoSite: mpo[site + 1],
                workspace: &workspace
            )
        }

        return svd.discardedWeight
    }

    // MARK: - Full-Reorthogonalized Flat-Workspace Lanczos + Symmetric Jacobi Tridiagonal Solver

    private static func lanczosLowestEigenvectorFlat(
        dim: Int,
        krylovDim: Int,
        chiL: Int,
        chiR: Int,
        leftEnv: [Double],
        w1: MPOSiteTensor,
        w2: MPOSiteTensor,
        rightEnv: [Double],
        workspace: inout DMRGContractionWorkspace
    ) -> [Double] {
        let maxK = max(2, min(min(krylovDim, 16), dim))

        var initNormSq = 0.0
        for i in 0..<dim {
            let v = workspace.thetaBuf[i]
            initNormSq += v * v
        }
        let invInitNorm = 1.0 / sqrt(max(1e-30, initNormSq))
        for i in 0..<dim {
            workspace.krylovBasisFlat[i] = workspace.thetaBuf[i] * invInitNorm
        }

        var actualSteps = 0
        for step in 0..<maxK {
            let vOffset = step * dim
            let basisSnapshot = workspace.krylovBasisFlat
            applyEffectiveTwoSiteHamiltonianInPlace(
                thetaOffset: vOffset,
                thetaSource: basisSnapshot,
                chiL: chiL,
                chiR: chiR,
                leftEnv: leftEnv,
                w1: w1,
                w2: w2,
                rightEnv: rightEnv,
                workspace: &workspace
            )

            var alpha = 0.0
            for i in 0..<dim {
                alpha += workspace.krylovBasisFlat[vOffset + i] * workspace.matVecOut[i]
            }
            workspace.alphas[step] = alpha
            actualSteps = step + 1

            // Two-pass full Gram-Schmidt re-orthogonalization against all prior Krylov vectors 0...step
            for _ in 0..<2 {
                for prev in 0...step {
                    let prevOffset = prev * dim
                    var proj = 0.0
                    for i in 0..<dim {
                        proj += workspace.krylovBasisFlat[prevOffset + i] * workspace.matVecOut[i]
                    }
                    for i in 0..<dim {
                        workspace.matVecOut[i] -= proj * workspace.krylovBasisFlat[prevOffset + i]
                    }
                }
            }

            var betaSq = 0.0
            for i in 0..<dim {
                let wVal = workspace.matVecOut[i]
                betaSq += wVal * wVal
            }
            let beta = sqrt(max(0.0, betaSq))
            if beta < 1e-12 || step + 1 == maxK {
                break
            }
            workspace.betas[step] = beta
            let invBeta = 1.0 / beta
            let nextOffset = (step + 1) * dim
            for i in 0..<dim {
                workspace.krylovBasisFlat[nextOffset + i] = workspace.matVecOut[i] * invBeta
            }
        }

        let m = actualSteps
        if m < 2 {
            var singleOut = [Double](repeating: 0.0, count: dim)
            for i in 0..<dim {
                singleOut[i] = workspace.krylovBasisFlat[i]
            }
            return singleOut
        }

        // Assemble m x m symmetric tridiagonal Krylov matrix T in flat buffer and diagonalize via Jacobi rotations
        for i in 0..<(m * m) {
            workspace.tridiagTFlat[i] = 0.0
            workspace.tridiagVFlat[i] = 0.0
        }
        for i in 0..<m {
            workspace.tridiagTFlat[i * m + i] = workspace.alphas[i]
            workspace.tridiagVFlat[i * m + i] = 1.0
            if i + 1 < m {
                let b = workspace.betas[i]
                workspace.tridiagTFlat[i * m + (i + 1)] = b
                workspace.tridiagTFlat[(i + 1) * m + i] = b
            }
        }

        for _ in 0..<40 {
            var maxOff = 0.0
            for p in 0..<(m - 1) {
                for q in (p + 1)..<m {
                    let aPQ = workspace.tridiagTFlat[p * m + q]
                    if abs(aPQ) > maxOff { maxOff = abs(aPQ) }
                    guard abs(aPQ) > 1e-14 else { continue }

                    let app = workspace.tridiagTFlat[p * m + p]
                    let aqq = workspace.tridiagTFlat[q * m + q]
                    let tau = (aqq - app) / (2.0 * aPQ)
                    let signTau: Double = tau >= 0.0 ? 1.0 : -1.0
                    let t = signTau / (abs(tau) + sqrt(1.0 + tau * tau))
                    let c = 1.0 / sqrt(1.0 + t * t)
                    let s = c * t

                    workspace.tridiagTFlat[p * m + p] = app - t * aPQ
                    workspace.tridiagTFlat[q * m + q] = aqq + t * aPQ
                    workspace.tridiagTFlat[p * m + q] = 0.0
                    workspace.tridiagTFlat[q * m + p] = 0.0

                    for k in 0..<m where k != p && k != q {
                        let akp = workspace.tridiagTFlat[k * m + p]
                        let akq = workspace.tridiagTFlat[k * m + q]
                        let newKP = c * akp - s * akq
                        let newKQ = s * akp + c * akq
                        workspace.tridiagTFlat[k * m + p] = newKP
                        workspace.tridiagTFlat[p * m + k] = newKP
                        workspace.tridiagTFlat[k * m + q] = newKQ
                        workspace.tridiagTFlat[q * m + k] = newKQ
                    }

                    for k in 0..<m {
                        let vkp = workspace.tridiagVFlat[k * m + p]
                        let vkq = workspace.tridiagVFlat[k * m + q]
                        workspace.tridiagVFlat[k * m + p] = c * vkp - s * vkq
                        workspace.tridiagVFlat[k * m + q] = s * vkp + c * vkq
                    }
                }
            }
            if maxOff < 1e-13 { break }
        }

        var minIdx = 0
        var minEig = workspace.tridiagTFlat[0]
        for i in 1..<m {
            let diagVal = workspace.tridiagTFlat[i * m + i]
            if diagVal < minEig {
                minEig = diagVal
                minIdx = i
            }
        }

        var ritzGround = [Double](repeating: 0.0, count: dim)
        for k in 0..<m {
            let weight = workspace.tridiagVFlat[k * m + minIdx]
            let bOffset = k * dim
            for i in 0..<dim {
                ritzGround[i] += weight * workspace.krylovBasisFlat[bOffset + i]
            }
        }
        var ritzNormSq = 0.0
        for i in 0..<dim {
            ritzNormSq += ritzGround[i] * ritzGround[i]
        }
        let invRitzNorm = 1.0 / sqrt(max(1e-30, ritzNormSq))
        for i in 0..<dim {
            ritzGround[i] *= invRitzNorm
        }
        return ritzGround
    }
}

// MARK: - 4. Householder QR / LQ Canonicalization & Multimodal Bio-Acoustic Control Extraction

public struct OptimalBioAcousticControl: Codable, Sendable, Equatable {
    /// Schumann-adjacent theta binaural floor frequency (Hz).
    public static let binauralThetaFloorHz: Float = 4.0
    /// Binaural entrainment span up to 18 Hz beta ceiling (Hz).
    public static let binauralEntrainmentSpanHz: Float = 14.0
    /// Earth-year 32nd-octave "OM" carrier floor frequency (Hz).
    public static let carrierFloorHz: Float = 136.1
    /// Verdi natural harmonic tuning carrier ceiling frequency (Hz).
    public static let carrierCeilingHz: Float = 432.0

    public let recommendedBinauralBeatHz: Float
    public let recommendedCarrierHz: Float
    public let recommendedTZFMIndex: Float
    public let recommendedHRTFOrbitSpeed: Float
    public let recommendedFDTDWaveguideStiffness: Float
    public let centralEntanglementEntropy: Float
    public let renyi2Purity: Float
    public let groundStateEnergy: Float

    public init(
        recommendedBinauralBeatHz: Float,
        recommendedCarrierHz: Float,
        recommendedTZFMIndex: Float,
        recommendedHRTFOrbitSpeed: Float,
        recommendedFDTDWaveguideStiffness: Float,
        centralEntanglementEntropy: Float,
        renyi2Purity: Float,
        groundStateEnergy: Float
    ) {
        self.recommendedBinauralBeatHz = recommendedBinauralBeatHz
        self.recommendedCarrierHz = recommendedCarrierHz
        self.recommendedTZFMIndex = recommendedTZFMIndex
        self.recommendedHRTFOrbitSpeed = recommendedHRTFOrbitSpeed
        self.recommendedFDTDWaveguideStiffness = recommendedFDTDWaveguideStiffness
        self.centralEntanglementEntropy = centralEntanglementEntropy
        self.renyi2Purity = renyi2Purity
        self.groundStateEnergy = groundStateEnergy
    }
}

extension MatrixProductStateEngine {
    /// Performs thin Householder QR factorization `A = Q * R` on a flat contiguous buffer
    /// (`Q` is `rows x k` column-orthonormal to machine precision even for rank-deficient inputs,
    /// `R` is `k x cols` upper-triangular with non-negative diagonal).
    public static func qrOrthogonalize(
        matrix: [Double],
        rows: Int,
        cols: Int
    ) -> (q: [Double], r: [Double], rank: Int) {
        let k = min(rows, cols)
        guard rows > 0, cols > 0, matrix.count == rows * cols else {
            return ([], [], 0)
        }

        var rWork = matrix
        var vStore = [Double](repeating: 0.0, count: k * rows)
        var activeReflector = [Bool](repeating: false, count: k)
        var dotCol = [Double](repeating: 0.0, count: max(rows, cols))

        for j in 0..<k {
            var normSq = 0.0
            for i in j..<rows {
                let val = rWork[i * cols + j]
                normSq += val * val
            }
            let normX = sqrt(normSq)
            guard normX > 1e-30 else { continue }

            let x0 = rWork[j * cols + j]
            let signX: Double = (x0 >= 0.0) ? -1.0 : 1.0
            let u1 = x0 - signX * normX

            let vBase = j * rows
            vStore[vBase + j] = u1
            var vNormSq = u1 * u1
            if j + 1 < rows {
                for i in (j + 1)..<rows {
                    let vVal = rWork[i * cols + j]
                    vStore[vBase + i] = vVal
                    vNormSq += vVal * vVal
                }
            }

            let normV = sqrt(vNormSq)
            guard normV > 1e-30 else { continue }
            let invNormV = 1.0 / normV
            for i in j..<rows {
                vStore[vBase + i] *= invNormV
            }
            activeReflector[j] = true

            // Apply H_j = I - 2 v v^T to rWork[j..<rows, j..<cols]
            for c in j..<cols { dotCol[c] = 0.0 }
            for i in j..<rows {
                let vi = vStore[vBase + i]
                let rRowBase = i * cols
                for c in j..<cols {
                    dotCol[c] += vi * rWork[rRowBase + c]
                }
            }
            for i in j..<rows {
                let twoVi = 2.0 * vStore[vBase + i]
                let rRowBase = i * cols
                for c in j..<cols {
                    rWork[rRowBase + c] -= twoVi * dotCol[c]
                }
            }
        }

        // Accumulate thin Q [rows x k] by backward application of H_{k-1} ... H_0
        var qFlat = [Double](repeating: 0.0, count: rows * k)
        for j in 0..<k {
            qFlat[j * k + j] = 1.0
        }
        for j in stride(from: k - 1, through: 0, by: -1) where activeReflector[j] {
            let vBase = j * rows
            for c in j..<k { dotCol[c] = 0.0 }
            for i in j..<rows {
                let vi = vStore[vBase + i]
                let qRowBase = i * k
                for c in j..<k {
                    dotCol[c] += vi * qFlat[qRowBase + c]
                }
            }
            for i in j..<rows {
                let twoVi = 2.0 * vStore[vBase + i]
                let qRowBase = i * k
                for c in j..<k {
                    qFlat[qRowBase + c] -= twoVi * dotCol[c]
                }
            }
        }

        // Extract upper-triangular R [k x cols] and enforce non-negative diagonal
        var rThin = [Double](repeating: 0.0, count: k * cols)
        for i in 0..<k {
            let srcBase = i * cols
            let dstBase = i * cols
            for j in i..<cols {
                rThin[dstBase + j] = rWork[srcBase + j]
            }
            if rThin[dstBase + i] < 0.0 {
                for j in i..<cols {
                    rThin[dstBase + j] = -rThin[dstBase + j]
                }
                for r in 0..<rows {
                    qFlat[r * k + i] = -qFlat[r * k + i]
                }
            }
        }

        return (qFlat, rThin, k)
    }

    /// Performs thin LQ factorization `A = L * Q` (`L` is `rows x k` lower-triangular, `Q` is `k x cols` row-orthonormal).
    public static func lqOrthogonalize(
        matrix: [Double],
        rows: Int,
        cols: Int
    ) -> (l: [Double], q: [Double], rank: Int) {
        guard rows > 0, cols > 0, matrix.count == rows * cols else {
            return ([], [], 0)
        }
        var transposed = [Double](repeating: 0.0, count: cols * rows)
        for r in 0..<rows {
            let rowBase = r * cols
            for c in 0..<cols {
                transposed[c * rows + r] = matrix[rowBase + c]
            }
        }
        let qr = qrOrthogonalize(matrix: transposed, rows: cols, cols: rows)
        let k = qr.rank
        var lMat = [Double](repeating: 0.0, count: rows * k)
        var qMat = [Double](repeating: 0.0, count: k * cols)
        for r in 0..<rows {
            let lBase = r * k
            for c in 0..<k {
                lMat[lBase + c] = qr.r[c * rows + r]
            }
        }
        for r in 0..<k {
            let qBase = r * cols
            for c in 0..<cols {
                qMat[qBase + c] = qr.q[c * k + r]
            }
        }
        return (lMat, qMat, k)
    }

    /// Encodes 6 multimodal physiological & acoustic state vectors (`d_k = 4` per site) into a normalized
    /// 6-site entangled state vector of dimension `4^6 = 4096` with tunable bio-acoustic coupling strength.
    public static func encodeBioAcousticStateTensor(
        eegCorticalBands4: SIMD4<Float>,
        hrvVagalMetrics4: SIMD4<Float>,
        spwvdEntropyState4: SIMD4<Float>,
        binauralOscillatorState4: SIMD4<Float>,
        hrtfFDTDWavefield4: SIMD4<Float>,
        circadianKalmanPhase4: SIMD4<Float>,
        entanglementCoupling: Float = 0.65
    ) -> [Float] {
        func normalizeSite(_ v: SIMD4<Float>) -> [Double] {
            let d0 = v[0].isFinite ? max(0.01, Double(abs(v[0])) + 0.05) : 0.25
            let d1 = v[1].isFinite ? max(0.01, Double(abs(v[1])) + 0.05) : 0.25
            let d2 = v[2].isFinite ? max(0.01, Double(abs(v[2])) + 0.05) : 0.25
            let d3 = v[3].isFinite ? max(0.01, Double(abs(v[3])) + 0.05) : 0.25
            let d = [d0, d1, d2, d3]
            let norm = sqrt(d0 * d0 + d1 * d1 + d2 * d2 + d3 * d3)
            let invNorm = 1.0 / max(1e-12, norm)
            return [d0 * invNorm, d1 * invNorm, d2 * invNorm, d3 * invNorm]
        }

        let s0 = normalizeSite(eegCorticalBands4)
        let s1 = normalizeSite(hrvVagalMetrics4)
        let s2 = normalizeSite(spwvdEntropyState4)
        let s3 = normalizeSite(binauralOscillatorState4)
        let s4 = normalizeSite(hrtfFDTDWavefield4)
        let s5 = normalizeSite(circadianKalmanPhase4)

        let gamma = min(max(Double(entanglementCoupling), 0.0), 1.0)
        var psi = [Double](repeating: 0.0, count: 4096)
        var normSq = 0.0

        for i0 in 0..<4 {
            for i1 in 0..<4 {
                for i2 in 0..<4 {
                    let bioMode = (i0 + i1 + i2) % 4
                    let prod012 = s0[i0] * s1[i1] * s2[i2]
                    let idx012 = ((i0 * 4 + i1) * 4 + i2) * 64
                    for i3 in 0..<4 {
                        for i4 in 0..<4 {
                            for i5 in 0..<4 {
                                let acoMode = (i3 + i4 + i5) % 4
                                let idx = idx012 + ((i3 * 4 + i4) * 4) + i5
                                let prodAmp = prod012 * s3[i3] * s4[i4] * s5[i5]
                                let bellResonance = (bioMode == acoMode) ? (1.0 + 1.5 * gamma) : (1.0 - 0.55 * gamma)
                                let amp = prodAmp * bellResonance
                                psi[idx] = amp
                                normSq += amp * amp
                            }
                        }
                    }
                }
            }
        }

        let invNorm = 1.0 / sqrt(max(1e-30, normSq))
        return psi.map { Float($0 * invNorm) }
    }

    /// Computes the maximum Frobenius orthogonality defect `||U^T U - I||_F` across all left-canonical cores `0..<(cores.count - 1)`.
    public func verifyLeftCanonicalOrthogonality() -> Double {
        guard cores.count > 1 else { return 0.0 }
        var maxDefect = 0.0
        for site in 0..<(cores.count - 1) {
            let core = cores[site]
            let rows = core.leftBond * core.physicalDim
            let cols = core.rightBond
            var defectSq = 0.0
            for i in 0..<cols {
                for j in 0..<cols {
                    var dot = 0.0
                    for r in 0..<rows {
                        dot += core.storage[r * cols + i] * core.storage[r * cols + j]
                    }
                    let target = (i == j) ? 1.0 : 0.0
                    let err = dot - target
                    defectSq += err * err
                }
            }
            maxDefect = max(maxDefect, sqrt(defectSq))
        }
        return maxDefect
    }

    /// Evaluates the expectation value `<psi | H | psi> / <psi | psi>` directly from the MPS cores in `O(N * chi^3 * d * w)`
    /// without reconstructing the 4096-element dense state vector or re-running TT-SVD.
    public func expectationValueNearestNeighborXXZ(anisotropyDelta: Double = 1.0) -> Double {
        let mpo = DMRGVariationalOptimizer.buildSixSiteSpin3HalfMPO(
            couplingJ: anisotropyDelta,
            transverseFieldH: 0.5
        )
        var workspace = DMRGVariationalOptimizer.DMRGContractionWorkspace()
        return DMRGVariationalOptimizer.evaluateMPOExpectation(
            cores: cores,
            mpo: mpo,
            workspace: &workspace
        )
    }

    /// Computes gauge-invariant single-site reduced density matrix diagonal expectations
    /// `E[p_k] / (d - 1)` in `[0, 1]` for all sites `0..<cores.count` via left/right norm-environment contractions.
    public func computeSingleSiteNormalizedExpectations() -> [Float] {
        let n = cores.count
        guard n > 0 else { return [] }

        // 1. Left norm environments: leftNorm[s] has shape [lBond_s x lBond_s]
        var leftNorms = Array(repeating: [1.0], count: n)
        for s in 0..<(n - 1) {
            let c = cores[s]
            let lDim = c.leftBond
            let phys = c.physicalDim
            let rDim = c.rightBond
            let nl = leftNorms[s]

            // temp[lBra, p, rKet] = sum_{lKet} nl[lBra, lKet] * c[lKet, p, rKet]
            let prCount = phys * rDim
            var temp = [Double](repeating: 0.0, count: lDim * prCount)
            for lBra in 0..<lDim {
                let nlBase = lBra * lDim
                let tBase = lBra * prCount
                for lKet in 0..<lDim {
                    let nlVal = nl[nlBase + lKet]
                    guard abs(nlVal) > 1e-18 else { continue }
                    let cBase = lKet * prCount
                    for pr in 0..<prCount {
                        temp[tBase + pr] += nlVal * c.storage[cBase + pr]
                    }
                }
            }

            // nextNL[rBra, rKet] = sum_{lBra, p} c[lBra, p, rBra] * temp[lBra, p, rKet]
            var nextNL = [Double](repeating: 0.0, count: rDim * rDim)
            let lpCount = lDim * phys
            for lp in 0..<lpCount {
                let cBase = lp * rDim
                let tBase = lp * rDim
                for rBra in 0..<rDim {
                    let braVal = c.storage[cBase + rBra]
                    guard abs(braVal) > 1e-18 else { continue }
                    let outBase = rBra * rDim
                    for rKet in 0..<rDim {
                        nextNL[outBase + rKet] += braVal * temp[tBase + rKet]
                    }
                }
            }
            leftNorms[s + 1] = nextNL
        }

        // 2. Right norm environments: rightNorm[s] has shape [rBond_s x rBond_s]
        var rightNorms = Array(repeating: [1.0], count: n)
        for s in stride(from: n - 1, through: 1, by: -1) {
            let c = cores[s]
            let lDim = c.leftBond
            let phys = c.physicalDim
            let rDim = c.rightBond
            let nr = rightNorms[s]

            // temp[lKet, p, rBra] = sum_{rKet} c[lKet, p, rKet] * nr[rBra, rKet]
            let lpCount = lDim * phys
            var temp = [Double](repeating: 0.0, count: lpCount * rDim)
            for lp in 0..<lpCount {
                let cBase = lp * rDim
                let tBase = lp * rDim
                for rBra in 0..<rDim {
                    let nrBase = rBra * rDim
                    var sum = 0.0
                    for rKet in 0..<rDim {
                        sum += c.storage[cBase + rKet] * nr[nrBase + rKet]
                    }
                    temp[tBase + rBra] = sum
                }
            }

            // prevNR[lBra, lKet] = sum_{p, rBra} c[lBra, p, rBra] * temp[lKet, p, rBra]
            let prCount = phys * rDim
            var prevNR = [Double](repeating: 0.0, count: lDim * lDim)
            for lBra in 0..<lDim {
                let braBase = lBra * prCount
                for lKet in 0..<lDim {
                    let ketBase = lKet * prCount
                    var sum = 0.0
                    for pr in 0..<prCount {
                        sum += c.storage[braBase + pr] * temp[ketBase + pr]
                    }
                    prevNR[lBra * lDim + lKet] = sum
                }
            }
            rightNorms[s - 1] = prevNR
        }

        // 3. Evaluate exact reduced density matrix diagonal Tr(rho_s * P_p) at each site s
        var expectations = [Float](repeating: 0.5, count: n)
        for s in 0..<n {
            let c = cores[s]
            let lDim = c.leftBond
            let phys = c.physicalDim
            let rDim = c.rightBond
            let nl = leftNorms[s]
            let nr = rightNorms[s]

            var weighted = 0.0
            var total = 0.0
            var mid = [Double](repeating: 0.0, count: lDim * rDim)

            for p in 0..<phys {
                for i in 0..<(lDim * rDim) { mid[i] = 0.0 }
                // mid[lBra, rKet] = sum_{lKet} nl[lBra, lKet] * c[lKet, p, rKet]
                for lBra in 0..<lDim {
                    let nlBase = lBra * lDim
                    let mBase = lBra * rDim
                    for lKet in 0..<lDim {
                        let nlVal = nl[nlBase + lKet]
                        guard abs(nlVal) > 1e-18 else { continue }
                        let cBase = (lKet * phys + p) * rDim
                        for rKet in 0..<rDim {
                            mid[mBase + rKet] += nlVal * c.storage[cBase + rKet]
                        }
                    }
                }

                // pWeight = sum_{lBra, rBra, rKet} c[lBra, p, rBra] * mid[lBra, rKet] * nr[rBra, rKet]
                var pWeight = 0.0
                for lBra in 0..<lDim {
                    let cBase = (lBra * phys + p) * rDim
                    let mBase = lBra * rDim
                    for rBra in 0..<rDim {
                        let braVal = c.storage[cBase + rBra]
                        guard abs(braVal) > 1e-18 else { continue }
                        let nrBase = rBra * rDim
                        var rSum = 0.0
                        for rKet in 0..<rDim {
                            rSum += mid[mBase + rKet] * nr[nrBase + rKet]
                        }
                        pWeight += braVal * rSum
                    }
                }
                let clampedP = max(0.0, pWeight)
                weighted += Double(p) * clampedP
                total += clampedP
            }

            if total > 1e-15 {
                let denom = Double(max(1, phys - 1)) * total
                expectations[s] = Float(min(max(weighted / denom, 0.0), 1.0))
            }
        }

        return expectations
    }
}

extension DMRGVariationalOptimizer {
    /// Extracts optimal acoustic synthesis control parameters from a DMRG-converged 6-site Matrix Product State
    /// using gauge-invariant single-site reduced density matrix marginals and central bipartite entanglement entropy.
    public static func extractOptimalBioAcousticControl(
        from mps: MatrixProductStateEngine
    ) -> OptimalBioAcousticControl {
        let telemetry = mps.evaluateEntanglement()
        let groundEnergy = Float(mps.expectationValueNearestNeighborXXZ(anisotropyDelta: 1.0))
        let siteMarginals = mps.computeSingleSiteNormalizedExpectations()

        let uBeat: Float = siteMarginals.count > 3 ? siteMarginals[3] : 0.5
        let uSpace: Float = siteMarginals.count > 4 ? siteMarginals[4] : 0.5
        let uPhase: Float = siteMarginals.count > 5 ? siteMarginals[5] : 0.5
        let maxEntropy = Float(MPSTelemetrySnapshot.maxSpin3HalfBipartiteEntropyNats)
        let entropyNorm = min(max(telemetry.centralEntanglementEntropy / maxEntropy, 0.0), 1.0)

        let beatMix: Float = 0.65 * uBeat + 0.35 * entropyNorm
        let beatHz: Float = OptimalBioAcousticControl.binauralThetaFloorHz
            + beatMix * OptimalBioAcousticControl.binauralEntrainmentSpanHz

        let carrierMix: Float = 0.60 * uSpace + 0.40 * uPhase
        let carrierSpan: Float = OptimalBioAcousticControl.carrierCeilingHz - OptimalBioAcousticControl.carrierFloorHz
        let carrierHz: Float = OptimalBioAcousticControl.carrierFloorHz + carrierMix * carrierSpan

        let tzfmMix: Float = 0.55 * entropyNorm + 0.45 * uBeat
        let tzfmIdx: Float = 0.35 + tzfmMix * 2.40

        let orbitMix: Float = 0.50 * uSpace + 0.50 * entropyNorm
        let orbitSpeed: Float = 0.08 + orbitMix * 0.72

        let stiffness: Float = 0.015 + 0.045 * uPhase

        return OptimalBioAcousticControl(
            recommendedBinauralBeatHz: beatHz,
            recommendedCarrierHz: carrierHz,
            recommendedTZFMIndex: tzfmIdx,
            recommendedHRTFOrbitSpeed: orbitSpeed,
            recommendedFDTDWaveguideStiffness: stiffness,
            centralEntanglementEntropy: telemetry.centralEntanglementEntropy,
            renyi2Purity: Float(telemetry.renyi2Purity),
            groundStateEnergy: groundEnergy
        )
    }
}
