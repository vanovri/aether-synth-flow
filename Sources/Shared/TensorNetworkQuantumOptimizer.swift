// MARK: - FILE: TensorNetworkQuantumOptimizer.swift

import Foundation

// MARK: - 1. Matrix Product State Telemetry Snapshot & Core Tensor

public struct MPSTelemetrySnapshot: Codable, Sendable, Equatable {
    public let siteCount: Int
    public let maxBondDimension: Int
    public let schmidtSingularValues: [Double]
    public let vonNeumannEntropyNats: Double
    public let renyi2Purity: Double
    public let variationalEnergy: Double

    public init(
        siteCount: Int,
        maxBondDimension: Int,
        schmidtSingularValues: [Double],
        vonNeumannEntropyNats: Double,
        renyi2Purity: Double,
        variationalEnergy: Double
    ) {
        self.siteCount = siteCount
        self.maxBondDimension = maxBondDimension
        self.schmidtSingularValues = schmidtSingularValues
        self.vonNeumannEntropyNats = max(0.0, vonNeumannEntropyNats)
        self.renyi2Purity = min(max(renyi2Purity, 0.0), 1.0)
        self.variationalEnergy = variationalEnergy
    }

    public var centralEntanglementEntropy: Float {
        Float(vonNeumannEntropyNats)
    }

    public var groundStateEnergyEstimate: Float {
        Float(variationalEnergy)
    }

    public var mappedHarmonicTension: Float {
        Float(min(max(vonNeumannEntropyNats / log(16.0), 0.0), 1.0))
    }

    public var mappedSpectralInharmonicity: Float {
        Float(1.0 + 1.5 * min(max(1.0 - renyi2Purity, 0.0), 1.0))
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
        return max(0.0, 1.0 - sumSq)
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

// MARK: - 2. 6-Site Tensor-Train Matrix Product State Engine & One-Sided Jacobi SVD

public struct MatrixProductStateEngine: Sendable, Equatable {
    public static let defaultSiteCount: Int = 6
    public static let physicalDimension: Int = 4
    public static let hilbertSpaceDimension: Int = 4_096 // 4^6
    public static let hardMaxBondCap: Int = 16

    public var cores: [MPSCoreTensor]
    public let maxBondDim: Int
    public let midCutSingularValues: [Double]

    public init(stateVector: [Float], maxBondDim: Int = 16) {
        self.init(stateVector: stateVector.map(Double.init), maxBondDim: maxBondDim)
    }

    /// Decomposes any 4096-element quantum state vector (`d = 4`, `N = 6` sites) into a left/mixed-canonical
    /// Matrix Product State `cores[0..<6]` using exact One-Sided Jacobi SVD.
    public init(stateVector: [Double], maxBondDim: Int = 16) {
        let chiMax = min(max(1, maxBondDim), Self.hardMaxBondCap)
        self.maxBondDim = chiMax

        var psi = [Double](repeating: 0.0, count: Self.hilbertSpaceDimension)
        for i in 0..<min(stateVector.count, Self.hilbertSpaceDimension) {
            psi[i] = stateVector[i].isFinite ? stateVector[i] : 0.0
        }

        // Normalize state vector (fallback to |000000> if identically zero)
        var normSq = 0.0
        for amp in psi { normSq += amp * amp }
        if normSq > 1e-24 {
            let invNorm = 1.0 / sqrt(normSq)
            for i in 0..<psi.count { psi[i] *= invNorm }
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

        for site in 0..<(Self.defaultSiteCount - 1) {
            let rows = leftRank * Self.physicalDimension
            rightPhysProd /= Self.physicalDimension
            let cols = rightPhysProd

            let svd = Self.jacobiSVD(
                matrix: remainder,
                rows: rows,
                cols: cols,
                maxRank: chiMax
            )

            // Normalize retained singular values after rank truncation to preserve ||psi||_2 == 1
            var sNormSq = 0.0
            for sv in svd.s { sNormSq += sv * sv }
            let sScale = sNormSq > 1e-24 ? (1.0 / sqrt(sNormSq)) : 1.0
            let normalizedS = svd.s.map { $0 * sScale }

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
    }

    public init(cores: [MPSCoreTensor], maxBondDim: Int = 16, midCutSingularValues: [Double]? = nil) {
        self.cores = cores
        self.maxBondDim = min(max(1, maxBondDim), Self.hardMaxBondCap)
        if let explicit = midCutSingularValues {
            self.midCutSingularValues = explicit
        } else {
            self.midCutSingularValues = Self.computeBipartiteSchmidtValues(cores: cores, cutSite: 3)
        }
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
            // Left half basis index m in 0..<64 paired with right half basis index m in 0..<64
            let globalIndex = m * 64 + m
            psi[globalIndex] = amp
        }
        return psi
    }

    /// Reconstructs the dense 4096-element state vector by sequentially contracting `cores[0..<6]`.
    public func reconstructStateVector() -> [Double] {
        guard !cores.isEmpty else { return [] }
        var tensor = cores[0].storage // [1 * d, rightBond_0]
        var leftDim = cores[0].leftBond * cores[0].physicalDim
        var bondDim = cores[0].rightBond

        for site in 1..<cores.count {
            let core = cores[site]
            let phys = core.physicalDim
            let nextBond = core.rightBond
            var contracted = [Double](repeating: 0.0, count: leftDim * phys * nextBond)

            for l in 0..<leftDim {
                for b in 0..<bondDim {
                    let tVal = tensor[l * bondDim + b]
                    guard abs(tVal) > 1e-18 else { continue }
                    for p in 0..<phys {
                        let coreBase = (b * phys + p) * nextBond
                        let outBase = (l * phys + p) * nextBond
                        for nb in 0..<nextBond {
                            contracted[outBase + nb] += tVal * core.storage[coreBase + nb]
                        }
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
        let actualMaxBond = cores.map { max($0.leftBond, $0.rightBond) }.max() ?? 1

        return MPSTelemetrySnapshot(
            siteCount: cores.count,
            maxBondDimension: actualMaxBond,
            schmidtSingularValues: sigmas,
            vonNeumannEntropyNats: metrics.vonNeumannEntropyNats,
            renyi2Purity: metrics.renyi2Purity,
            variationalEnergy: variationalEnergy
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

    private static func computeBipartiteSchmidtValues(cores: [MPSCoreTensor], cutSite: Int) -> [Double] {
        guard cores.count == defaultSiteCount, cutSite == 3 else {
            return [1.0]
        }
        // Contract left half {0, 1, 2} -> [64, bond_2] and right half {3, 4, 5} -> [bond_2, 64],
        // forming exact 64x64 bipartite matrix across cut k = 3 so Schmidt spectrum is gauge-invariant!
        var leftBlock = cores[0].storage // [4, r0]
        var lRows = 4
        var lBond = cores[0].rightBond
        for s in 1..<3 {
            let c = cores[s]
            var next = [Double](repeating: 0.0, count: lRows * 4 * c.rightBond)
            for r in 0..<lRows {
                for b in 0..<lBond {
                    let v = leftBlock[r * lBond + b]
                    guard abs(v) > 1e-18 else { continue }
                    for p in 0..<4 {
                        for nb in 0..<c.rightBond {
                            next[(r * 4 + p) * c.rightBond + nb] += v * c.storage[(b * 4 + p) * c.rightBond + nb]
                        }
                    }
                }
            }
            leftBlock = next
            lRows *= 4
            lBond = c.rightBond
        }

        var rightBlock = cores[3].storage // [lBond, 4 * r3]
        var rCols = 4
        var rBond = cores[3].rightBond
        // Reshape cores[3] as [lBond, 4, r3] -> [lBond * 4, r3]
        for s in 4..<6 {
            let c = cores[s]
            let leftDim = lBond * rCols
            var next = [Double](repeating: 0.0, count: leftDim * 4 * c.rightBond)
            for l in 0..<leftDim {
                for b in 0..<rBond {
                    let v = rightBlock[l * rBond + b]
                    guard abs(v) > 1e-18 else { continue }
                    for p in 0..<4 {
                        for nb in 0..<c.rightBond {
                            next[(l * 4 + p) * c.rightBond + nb] += v * c.storage[(b * 4 + p) * c.rightBond + nb]
                        }
                    }
                }
            }
            rightBlock = next
            rCols *= 4
            rBond = c.rightBond
        }
        // Now rightBlock has shape [lBond, 64] (since final rightBond == 1)
        var bipartite64x64 = [Double](repeating: 0.0, count: 64 * 64)
        for i in 0..<64 {
            for b in 0..<lBond {
                let lv = leftBlock[i * lBond + b]
                guard abs(lv) > 1e-18 else { continue }
                for j in 0..<64 {
                    bipartite64x64[i * 64 + j] += lv * rightBlock[b * 64 + j]
                }
            }
        }

        let svd = jacobiSVD(matrix: bipartite64x64, rows: 64, cols: 64, maxRank: hardMaxBondCap)
        return svd.s
    }

    // MARK: - Exact One-Sided Jacobi Singular Value Decomposition

    /// Computes thin SVD `A = U * diag(s) * V^T` via One-Sided Jacobi orthogonal rotations.
    /// - `matrix`: row-major `[rows x cols]`
    /// - Returns: `(u: [rows x rank], s: [rank], vt: [rank x cols], rank: Int)` with `U^T U = I` and `V V^T = I`.
    public static func jacobiSVD(
        matrix: [Double],
        rows: Int,
        cols: Int,
        maxRank: Int
    ) -> (u: [Double], s: [Double], vt: [Double], rank: Int) {
        precondition(rows > 0 && cols > 0 && matrix.count == rows * cols, "Invalid matrix dimensions for jacobiSVD")
        let targetMaxRank = max(1, min(min(rows, cols), maxRank))

        if rows < cols {
            // Wide matrix: transpose A (cols x rows), solve tall A^T = U_t * S * V_t^T => A = V_t * S * U_t^T
            var aT = [Double](repeating: 0.0, count: cols * rows)
            for r in 0..<rows {
                for c in 0..<cols {
                    aT[c * rows + r] = matrix[r * cols + c]
                }
            }
            let tall = jacobiSVDTall(matrix: aT, rows: cols, cols: rows, maxRank: targetMaxRank)
            let rank = tall.rank

            // U = (V_t)^T_transposed -> tall.vt is [rank x rows], transpose to [rows x rank]
            var uOut = [Double](repeating: 0.0, count: rows * rank)
            for k in 0..<rank {
                for r in 0..<rows {
                    uOut[r * rank + k] = tall.vt[k * rows + r]
                }
            }

            // V^T = (U_t)^T -> tall.u is [cols x rank], transpose to [rank x cols]
            var vtOut = [Double](repeating: 0.0, count: rank * cols)
            for k in 0..<rank {
                for c in 0..<cols {
                    vtOut[k * cols + c] = tall.u[c * rank + k]
                }
            }

            return (uOut, tall.s, vtOut, rank)
        } else {
            return jacobiSVDTall(matrix: matrix, rows: rows, cols: cols, maxRank: targetMaxRank)
        }
    }

    private static func jacobiSVDTall(
        matrix: [Double],
        rows: Int,
        cols: Int,
        maxRank: Int
    ) -> (u: [Double], s: [Double], vt: [Double], rank: Int) {
        // Store W and V in column-major layout (`cols` columns of length `rows` and `cols` respectively) for cache locality
        var wCols = [[Double]](repeating: [Double](repeating: 0.0, count: rows), count: cols)
        for r in 0..<rows {
            let rowBase = r * cols
            for c in 0..<cols {
                wCols[c][r] = matrix[rowBase + c]
            }
        }

        var vCols = [[Double]](repeating: [Double](repeating: 0.0, count: cols), count: cols)
        for c in 0..<cols {
            vCols[c][c] = 1.0
        }

        let maxSweeps = 45
        if cols >= 2 {
            for _ in 0..<maxSweeps {
                var maxRelativeOffDiag = 0.0

                for p in 0..<(cols - 1) {
                    for q in (p + 1)..<cols {
                        var alpha = 0.0
                        var beta = 0.0
                        var gamma = 0.0
                        for r in 0..<rows {
                            let wp = wCols[p][r]
                            let wq = wCols[q][r]
                            alpha += wp * wp
                            beta += wq * wq
                            gamma += wp * wq
                        }

                        let denomScale = sqrt(alpha * beta)
                        guard denomScale > 1e-30 else { continue }
                        let rel = abs(gamma) / denomScale
                        if rel > maxRelativeOffDiag {
                            maxRelativeOffDiag = rel
                        }

                        if rel > 1e-14 {
                            let zeta = (beta - alpha) / (2.0 * gamma)
                            let signZeta = zeta >= 0.0 ? 1.0 : -1.0
                            let t = signZeta / (abs(zeta) + sqrt(1.0 + zeta * zeta))
                            let cRot = 1.0 / sqrt(1.0 + t * t)
                            let sRot = cRot * t

                            for r in 0..<rows {
                                let wp = wCols[p][r]
                                let wq = wCols[q][r]
                                wCols[p][r] = cRot * wp - sRot * wq
                                wCols[q][r] = sRot * wp + cRot * wq
                            }
                            for r in 0..<cols {
                                let vp = vCols[p][r]
                                let vq = vCols[q][r]
                                vCols[p][r] = cRot * vp - sRot * vq
                                vCols[q][r] = sRot * vp + cRot * vq
                            }
                        }
                    }
                }

                if maxRelativeOffDiag < 1e-13 {
                    break
                }
            }
        }

        // Compute singular values ||W[:, j]||_2 and sort descending
        var colNorms = [(index: Int, sigma: Double)]()
        colNorms.reserveCapacity(cols)
        for c in 0..<cols {
            var sq = 0.0
            for r in 0..<rows {
                sq += wCols[c][r] * wCols[c][r]
            }
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

        var uBasisCols = [[Double]]()
        uBasisCols.reserveCapacity(rank)
        var sValues = [Double](repeating: 0.0, count: rank)
        var vtOut = [Double](repeating: 0.0, count: rank * cols)

        for k in 0..<rank {
            let origIdx = colNorms[k].index
            let sigma = colNorms[k].sigma
            sValues[k] = sigma

            if sigma > 1e-15 {
                let invS = 1.0 / sigma
                uBasisCols.append(wCols[origIdx].map { $0 * invS })
            } else {
                // Complete orthonormal column via Modified Gram-Schmidt if matrix is identically zero
                var candidate = [Double](repeating: 0.0, count: rows)
                candidate[k % rows] = 1.0
                for prev in uBasisCols {
                    var dot = 0.0
                    for r in 0..<rows { dot += candidate[r] * prev[r] }
                    for r in 0..<rows { candidate[r] -= dot * prev[r] }
                }
                var nSq = 0.0
                for r in 0..<rows { nSq += candidate[r] * candidate[r] }
                let inv = 1.0 / max(1e-15, sqrt(nSq))
                uBasisCols.append(candidate.map { $0 * inv })
            }

            let vtRowBase = k * cols
            for c in 0..<cols {
                vtOut[vtRowBase + c] = vCols[origIdx][c]
            }
        }

        var uOut = [Double](repeating: 0.0, count: rows * rank)
        for r in 0..<rows {
            let base = r * rank
            for k in 0..<rank {
                uOut[base + k] = uBasisCols[k][r]
            }
        }

        return (uOut, sValues, vtOut, rank)
    }
}

// MARK: - 3. 2-Site DMRG Variational Optimizer (6-Site Transverse-Field Spin-3/2 Ising/Heisenberg MPO)

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

    public func runSweeps(
        mps: inout MatrixProductStateEngine,
        sweepCount: Int = 2
    ) -> MPSTelemetrySnapshot {
        let initialVec = mps.reconstructStateVector()
        let snaps = runSweeps(
            initialState: initialVec,
            couplingJ: anisotropyDelta,
            transverseFieldH: 0.5,
            sweeps: max(1, sweepCount),
            maxBondDim: maxBondDim
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
        return evaluateMPOExpectation(cores: mps.cores, mpo: mpo)
    }

    public static func runSweeps(
        initialState: [Double],
        couplingJ: Double = 1.0,
        transverseFieldH: Double = 0.5,
        sweeps: Int = 4,
        maxBondDim: Int = 16
    ) -> [MPSTelemetrySnapshot] {
        DMRGVariationalOptimizer().runSweeps(
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
        let totalSweeps = max(1, sweeps)
        let chiMax = min(max(2, maxBondDim), MatrixProductStateEngine.hardMaxBondCap)
        let mpo = Self.buildSixSiteSpin3HalfMPO(couplingJ: couplingJ, transverseFieldH: transverseFieldH)

        var engine = MatrixProductStateEngine(stateVector: initialState, maxBondDim: chiMax)
        // Right-canonicalize sites 5..1 so bond 0 starts in exact mixed-canonical gauge
        Self.rightCanonicalizeFromRight(&engine.cores, downToSite: 1, maxBondDim: chiMax)

        // Precompute left and right MPO environments:
        // leftEnv[i] has shape [chiL, mpoBondL, chiL] before site i
        // rightEnv[i+1] has shape [chiR, mpoBondR, chiR] after site i
        var leftEnv = Array(repeating: [1.0], count: 7)
        var rightEnv = Array(repeating: [1.0], count: 7)
        for site in stride(from: 5, through: 1, by: -1) {
            rightEnv[site] = Self.contractRightStep(
                rightEnv: rightEnv[site + 1],
                core: engine.cores[site],
                mpoSite: mpo[site]
            )
        }

        var snapshots: [MPSTelemetrySnapshot] = []
        snapshots.reserveCapacity(totalSweeps)

        for sweepIdx in 0..<totalSweeps {
            // Progressive Krylov dimension ensures rapid strict variational descent across sweeps
            let krylovDim = min(14, 2 + sweepIdx * 4)

            // 1. Left-to-Right 2-site sweep: bonds (0,1), (1,2), (2,3), (3,4), (4,5)
            for site in 0..<5 {
                Self.optimizeTwoSiteBond(
                    site: site,
                    movingRight: true,
                    krylovDim: krylovDim,
                    maxBondDim: chiMax,
                    mpo: mpo,
                    cores: &engine.cores,
                    leftEnv: &leftEnv,
                    rightEnv: &rightEnv
                )
            }

            // 2. Right-to-Left 2-site sweep: bonds (4,5), (3,4), (2,3), (1,2), (0,1)
            for site in stride(from: 4, through: 0, by: -1) {
                Self.optimizeTwoSiteBond(
                    site: site,
                    movingRight: false,
                    krylovDim: krylovDim,
                    maxBondDim: chiMax,
                    mpo: mpo,
                    cores: &engine.cores,
                    leftEnv: &leftEnv,
                    rightEnv: &rightEnv
                )
            }

            let energy = Self.evaluateMPOExpectation(cores: engine.cores, mpo: mpo)
            snapshots.append(engine.evaluateEntanglement(variationalEnergy: energy))
        }

        return snapshots
    }

    // MARK: - Internal MPO Representation & 2-Site Effective Hamiltonian Contractions

    private struct MPOSiteTensor {
        let leftBond: Int
        let rightBond: Int
        /// Dense storage `[leftBond, rightBond, 4, 4]` for `(wL, wR, sOut, sIn)`
        let data: [Double]

        @inline(__always)
        func index(_ wL: Int, _ wR: Int, _ sOut: Int, _ sIn: Int) -> Int {
            (((wL * rightBond + wR) * 4 + sOut) * 4) + sIn
        }
    }

    private static func buildSixSiteSpin3HalfMPO(
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

    private static func rightCanonicalizeFromRight(
        _ cores: inout [MPSCoreTensor],
        downToSite minSite: Int,
        maxBondDim: Int
    ) {
        for site in stride(from: cores.count - 1, through: max(1, minSite), by: -1) {
            let core = cores[site]
            let rows = core.leftBond
            let cols = core.physicalDim * core.rightBond
            let svd = MatrixProductStateEngine.jacobiSVD(
                matrix: core.storage,
                rows: rows,
                cols: cols,
                maxRank: maxBondDim
            )
            var sNormSq = 0.0
            for sv in svd.s { sNormSq += sv * sv }
            let scale = sNormSq > 1e-24 ? (1.0 / sqrt(sNormSq)) : 1.0

            cores[site] = MPSCoreTensor(
                leftBond: svd.rank,
                physicalDim: 4,
                rightBond: core.rightBond,
                storage: svd.vt
            )

            // Absorb U * diag(s * scale) into right bond of cores[site - 1]
            let leftCore = cores[site - 1]
            let leftRows = leftCore.leftBond * leftCore.physicalDim
            var updatedLeft = [Double](repeating: 0.0, count: leftRows * svd.rank)
            for lr in 0..<leftRows {
                for b in 0..<rows {
                    let lv = leftCore.storage[lr * rows + b]
                    guard abs(lv) > 1e-18 else { continue }
                    for k in 0..<svd.rank {
                        updatedLeft[lr * svd.rank + k] += lv * svd.u[b * svd.rank + k] * (svd.s[k] * scale)
                    }
                }
            }
            cores[site - 1] = MPSCoreTensor(
                leftBond: leftCore.leftBond,
                physicalDim: 4,
                rightBond: svd.rank,
                storage: updatedLeft
            )
        }
    }

    /// Updates left MPO environment `L'[aOut, wR, aIn]` from `L[lOut, wL, lIn]` across `core` and `mpoSite`.
    private static func contractLeftStep(
        leftEnv: [Double],
        core: MPSCoreTensor,
        mpoSite: MPOSiteTensor
    ) -> [Double] {
        let lDim = core.leftBond
        let rDim = core.rightBond
        let wLeft = mpoSite.leftBond
        let wRight = mpoSite.rightBond

        var out = [Double](repeating: 0.0, count: rDim * wRight * rDim)
        for lOut in 0..<lDim {
            for wL in 0..<wLeft {
                for lIn in 0..<lDim {
                    let envVal = leftEnv[(lOut * wLeft + wL) * lDim + lIn]
                    guard abs(envVal) > 1e-18 else { continue }
                    for sIn in 0..<4 {
                        for aIn in 0..<rDim {
                            let ketVal = envVal * core.storage[core.index(lIn, sIn, aIn)]
                            guard abs(ketVal) > 1e-18 else { continue }
                            for wR in 0..<wRight {
                                for sOut in 0..<4 {
                                    let opVal = mpoSite.data[mpoSite.index(wL, wR, sOut, sIn)]
                                    guard abs(opVal) > 1e-18 else { continue }
                                    let prod = ketVal * opVal
                                    for aOut in 0..<rDim {
                                        let braVal = core.storage[core.index(lOut, sOut, aOut)]
                                        out[(aOut * wRight + wR) * rDim + aIn] += prod * braVal
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return out
    }

    /// Updates right MPO environment `R'[aOut, wL, aIn]` from `R[rOut, wR, rIn]` across `core` and `mpoSite`.
    private static func contractRightStep(
        rightEnv: [Double],
        core: MPSCoreTensor,
        mpoSite: MPOSiteTensor
    ) -> [Double] {
        let lDim = core.leftBond
        let rDim = core.rightBond
        let wLeft = mpoSite.leftBond
        let wRight = mpoSite.rightBond

        var out = [Double](repeating: 0.0, count: lDim * wLeft * lDim)
        for rOut in 0..<rDim {
            for wR in 0..<wRight {
                for rIn in 0..<rDim {
                    let envVal = rightEnv[(rOut * wRight + wR) * rDim + rIn]
                    guard abs(envVal) > 1e-18 else { continue }
                    for sIn in 0..<4 {
                        for aIn in 0..<lDim {
                            let ketVal = envVal * core.storage[core.index(aIn, sIn, rIn)]
                            guard abs(ketVal) > 1e-18 else { continue }
                            for wL in 0..<wLeft {
                                for sOut in 0..<4 {
                                    let opVal = mpoSite.data[mpoSite.index(wL, wR, sOut, sIn)]
                                    guard abs(opVal) > 1e-18 else { continue }
                                    let prod = ketVal * opVal
                                    for aOut in 0..<lDim {
                                        let braVal = core.storage[core.index(aOut, sOut, rOut)]
                                        out[(aOut * wLeft + wL) * lDim + aIn] += prod * braVal
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return out
    }

    private static func evaluateMPOExpectation(
        cores: [MPSCoreTensor],
        mpo: [MPOSiteTensor]
    ) -> Double {
        var env = [1.0]
        var normEnv = [1.0]
        let idMPO = MPOSiteTensor(
            leftBond: 1,
            rightBond: 1,
            data: (0..<16).map { ($0 / 4) == ($0 % 4) ? 1.0 : 0.0 }
        )

        for site in 0..<cores.count {
            env = contractLeftStep(leftEnv: env, core: cores[site], mpoSite: mpo[site])
            normEnv = contractLeftStep(leftEnv: normEnv, core: cores[site], mpoSite: idMPO)
        }
        let denom = max(1e-24, normEnv.first ?? 1.0)
        return (env.first ?? 0.0) / denom
    }

    /// Applies the 2-site effective Hamiltonian `H_eff` to two-site state `theta[aL, s1, s2, aR]`.
    private static func applyEffectiveTwoSiteHamiltonian(
        theta: [Double],
        chiL: Int,
        chiR: Int,
        leftEnv: [Double],
        w1: MPOSiteTensor,
        w2: MPOSiteTensor,
        rightEnv: [Double]
    ) -> [Double] {
        let wLCount = w1.leftBond
        let wMidCount = w1.rightBond
        let wRCount = w2.rightBond

        // Step 1: T1[aLOut, wL, s1In, s2In, aRIn] = sum_{aLIn} L[aLOut, wL, aLIn] * theta[aLIn, s1In, s2In, aRIn]
        let s12R = 16 * chiR
        var t1 = [Double](repeating: 0.0, count: chiL * wLCount * s12R)
        for aLOut in 0..<chiL {
            for wL in 0..<wLCount {
                let t1Base = (aLOut * wLCount + wL) * s12R
                for aLIn in 0..<chiL {
                    let lVal = leftEnv[(aLOut * wLCount + wL) * chiL + aLIn]
                    guard abs(lVal) > 1e-18 else { continue }
                    let thBase = aLIn * s12R
                    for idx in 0..<s12R {
                        t1[t1Base + idx] += lVal * theta[thBase + idx]
                    }
                }
            }
        }

        // Step 2: T2[aLOut, s1Out, wMid, s2In, aRIn] = sum_{wL, s1In} W1[wL, wMid, s1Out, s1In] * T1
        let s2R = 4 * chiR
        var t2 = [Double](repeating: 0.0, count: chiL * 4 * wMidCount * s2R)
        for aLOut in 0..<chiL {
            for wL in 0..<wLCount {
                for s1In in 0..<4 {
                    let t1Base = ((aLOut * wLCount + wL) * 4 + s1In) * s2R
                    for wMid in 0..<wMidCount {
                        for s1Out in 0..<4 {
                            let op1 = w1.data[w1.index(wL, wMid, s1Out, s1In)]
                            guard abs(op1) > 1e-18 else { continue }
                            let t2Base = ((aLOut * 4 + s1Out) * wMidCount + wMid) * s2R
                            for idx in 0..<s2R {
                                t2[t2Base + idx] += op1 * t1[t1Base + idx]
                            }
                        }
                    }
                }
            }
        }

        // Step 3: T3[aLOut, s1Out, s2Out, wR, aRIn] = sum_{wMid, s2In} W2[wMid, wR, s2Out, s2In] * T2
        var t3 = [Double](repeating: 0.0, count: chiL * 16 * wRCount * chiR)
        for aL1 in 0..<(chiL * 4) {
            for wMid in 0..<wMidCount {
                for s2In in 0..<4 {
                    let t2Base = ((aL1 * wMidCount + wMid) * 4 + s2In) * chiR
                    for wR in 0..<wRCount {
                        for s2Out in 0..<4 {
                            let op2 = w2.data[w2.index(wMid, wR, s2Out, s2In)]
                            guard abs(op2) > 1e-18 else { continue }
                            let t3Base = ((aL1 * 4 + s2Out) * wRCount + wR) * chiR
                            for aRIn in 0..<chiR {
                                t3[t3Base + aRIn] += op2 * t2[t2Base + aRIn]
                            }
                        }
                    }
                }
            }
        }

        // Step 4: Out[aLOut, s1Out, s2Out, aROut] = sum_{wR, aRIn} T3[...] * R[aROut, wR, aRIn]
        var out = [Double](repeating: 0.0, count: chiL * 16 * chiR)
        for aL12 in 0..<(chiL * 16) {
            let outBase = aL12 * chiR
            for wR in 0..<wRCount {
                let t3Base = (aL12 * wRCount + wR) * chiR
                for aROut in 0..<chiR {
                    let rBase = (aROut * wRCount + wR) * chiR
                    var sum = 0.0
                    for aRIn in 0..<chiR {
                        sum += t3[t3Base + aRIn] * rightEnv[rBase + aRIn]
                    }
                    out[outBase + aROut] += sum
                }
            }
        }
        return out
    }

    private static func optimizeTwoSiteBond(
        site: Int,
        movingRight: Bool,
        krylovDim: Int,
        maxBondDim: Int,
        mpo: [MPOSiteTensor],
        cores: inout [MPSCoreTensor],
        leftEnv: inout [[Double]],
        rightEnv: inout [[Double]]
    ) {
        let c1 = cores[site]
        let c2 = cores[site + 1]
        let chiL = c1.leftBond
        let midBond = c1.rightBond
        let chiR = c2.rightBond

        // Form 2-site wave-function tensor theta[aL, s1, s2, aR] of shape [chiL * 4, 4 * chiR]
        let leftRows = chiL * 4
        let rightCols = 4 * chiR
        var theta = [Double](repeating: 0.0, count: leftRows * rightCols)

        for lr in 0..<leftRows {
            for b in 0..<midBond {
                let v1 = c1.storage[lr * midBond + b]
                guard abs(v1) > 1e-18 else { continue }
                for rc in 0..<rightCols {
                    theta[lr * rightCols + rc] += v1 * c2.storage[b * rightCols + rc]
                }
            }
        }

        // Minimize <theta | H_eff | theta> / <theta | theta> via re-orthogonalized Lanczos eigensolver
        let optTheta = lanczosLowestEigenvector(
            initial: theta,
            krylovDim: krylovDim
        ) { vec in
            applyEffectiveTwoSiteHamiltonian(
                theta: vec,
                chiL: chiL,
                chiR: chiR,
                leftEnv: leftEnv[site],
                w1: mpo[site],
                w2: mpo[site + 1],
                rightEnv: rightEnv[site + 2]
            )
        }

        // Split optimized 2-site tensor via exact One-Sided Jacobi SVD with bond truncation <= maxBondDim
        let svd = MatrixProductStateEngine.jacobiSVD(
            matrix: optTheta,
            rows: leftRows,
            cols: rightCols,
            maxRank: maxBondDim
        )
        var sNormSq = 0.0
        for sv in svd.s { sNormSq += sv * sv }
        let sScale = sNormSq > 1e-24 ? (1.0 / sqrt(sNormSq)) : 1.0
        let normalizedS = svd.s.map { $0 * sScale }

        if movingRight {
            cores[site] = MPSCoreTensor(
                leftBond: chiL,
                physicalDim: 4,
                rightBond: svd.rank,
                storage: svd.u
            )
            var nextRight = [Double](repeating: 0.0, count: svd.rank * rightCols)
            for k in 0..<svd.rank {
                let sVal = normalizedS[k]
                for rc in 0..<rightCols {
                    nextRight[k * rightCols + rc] = sVal * svd.vt[k * rightCols + rc]
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
                mpoSite: mpo[site]
            )
        } else {
            var nextLeft = [Double](repeating: 0.0, count: leftRows * svd.rank)
            for lr in 0..<leftRows {
                for k in 0..<svd.rank {
                    nextLeft[lr * svd.rank + k] = svd.u[lr * svd.rank + k] * normalizedS[k]
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
                mpoSite: mpo[site + 1]
            )
        }
    }

    // MARK: - Full-Reorthogonalized Lanczos + Symmetric Jacobi Tridiagonal Ground-State Solver

    private static func lanczosLowestEigenvector(
        initial: [Double],
        krylovDim: Int,
        matVec: ([Double]) -> [Double]
    ) -> [Double] {
        let dim = initial.count
        let maxK = max(2, min(krylovDim, dim))

        func dot(_ a: [Double], _ b: [Double]) -> Double {
            var s = 0.0
            for i in 0..<dim { s += a[i] * b[i] }
            return s
        }

        let initNorm = sqrt(max(1e-30, dot(initial, initial)))
        var basis: [[Double]] = [initial.map { $0 / initNorm }]
        basis.reserveCapacity(maxK)

        var alphas: [Double] = []
        var betas: [Double] = []

        for step in 0..<maxK {
            let v = basis[step]
            var w = matVec(v)
            let alpha = dot(v, w)
            alphas.append(alpha)

            // Full Gram-Schmidt re-orthogonalization against all prior Krylov vectors
            for prev in basis {
                let proj = dot(prev, w)
                for i in 0..<dim { w[i] -= proj * prev[i] }
            }
            for prev in basis {
                let proj = dot(prev, w)
                for i in 0..<dim { w[i] -= proj * prev[i] }
            }

            let beta = sqrt(max(0.0, dot(w, w)))
            if beta < 1e-12 || step + 1 == maxK {
                break
            }
            betas.append(beta)
            let invBeta = 1.0 / beta
            basis.append(w.map { $0 * invBeta })
        }

        let m = alphas.count
        guard m >= 2 else { return basis[0] }

        // Assemble m x m symmetric tridiagonal Krylov matrix T and diagonalize via exact Jacobi rotations
        var tMat = [[Double]](repeating: [Double](repeating: 0.0, count: m), count: m)
        var eigVecs = [[Double]](repeating: [Double](repeating: 0.0, count: m), count: m)
        for i in 0..<m {
            tMat[i][i] = alphas[i]
            eigVecs[i][i] = 1.0
            if i < betas.count {
                tMat[i][i + 1] = betas[i]
                tMat[i + 1][i] = betas[i]
            }
        }

        for _ in 0..<40 {
            var maxOff = 0.0
            for p in 0..<(m - 1) {
                for q in (p + 1)..<m {
                    let aPQ = tMat[p][q]
                    if abs(aPQ) > maxOff { maxOff = abs(aPQ) }
                    guard abs(aPQ) > 1e-14 else { continue }

                    let tau = (tMat[q][q] - tMat[p][p]) / (2.0 * aPQ)
                    let signTau = tau >= 0.0 ? 1.0 : -1.0
                    let t = signTau / (abs(tau) + sqrt(1.0 + tau * tau))
                    let c = 1.0 / sqrt(1.0 + t * t)
                    let s = c * t

                    let app = tMat[p][p]
                    let aqq = tMat[q][q]
                    tMat[p][p] = app - t * aPQ
                    tMat[q][q] = aqq + t * aPQ
                    tMat[p][q] = 0.0
                    tMat[q][p] = 0.0

                    for k in 0..<m where k != p && k != q {
                        let akp = tMat[k][p]
                        let akq = tMat[k][q]
                        tMat[k][p] = c * akp - s * akq
                        tMat[p][k] = tMat[k][p]
                        tMat[k][q] = s * akp + c * akq
                        tMat[q][k] = tMat[k][q]
                    }

                    for k in 0..<m {
                        let vkp = eigVecs[k][p]
                        let vkq = eigVecs[k][q]
                        eigVecs[k][p] = c * vkp - s * vkq
                        eigVecs[k][q] = s * vkp + c * vkq
                    }
                }
            }
            if maxOff < 1e-13 { break }
        }

        var minIdx = 0
        var minEig = tMat[0][0]
        for i in 1..<m {
            if tMat[i][i] < minEig {
                minEig = tMat[i][i]
                minIdx = i
            }
        }

        var ritzGround = [Double](repeating: 0.0, count: dim)
        for k in 0..<m {
            let weight = eigVecs[k][minIdx]
            let bVec = basis[k]
            for i in 0..<dim {
                ritzGround[i] += weight * bVec[i]
            }
        }
        let ritzNorm = sqrt(max(1e-30, dot(ritzGround, ritzGround)))
        for i in 0..<dim {
            ritzGround[i] /= ritzNorm
        }
        return ritzGround
    }
}

// MARK: - 4. QR / LQ Canonicalization & Multimodal Bio-Acoustic Control Extraction

public struct OptimalBioAcousticControl: Codable, Sendable, Equatable {
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
    /// Performs thin Modified Gram-Schmidt QR factorization `A = Q * R` (`Q` is `rows x k` column-orthonormal, `R` is `k x cols` upper-triangular).
    public static func qrOrthogonalize(
        matrix: [Double],
        rows: Int,
        cols: Int
    ) -> (q: [Double], r: [Double], rank: Int) {
        let k = min(rows, cols)
        guard rows > 0, cols > 0, matrix.count == rows * cols else {
            return ([], [], 0)
        }

        var qCols = [[Double]](repeating: [Double](repeating: 0.0, count: rows), count: k)
        var rMat = [Double](repeating: 0.0, count: k * cols)

        for j in 0..<cols {
            var v = [Double](repeating: 0.0, count: rows)
            for r in 0..<rows {
                v[r] = matrix[r * cols + j]
            }

            let limit = min(j, k)
            // Two-pass Modified Gram-Schmidt for machine-precision orthogonality
            for pass in 0..<2 {
                for i in 0..<limit {
                    var dot = 0.0
                    for r in 0..<rows {
                        dot += qCols[i][r] * v[r]
                    }
                    rMat[i * cols + j] += dot
                    for r in 0..<rows {
                        v[r] -= dot * qCols[i][r]
                    }
                    _ = pass
                }
            }

            if j < k {
                var normSq = 0.0
                for r in 0..<rows { normSq += v[r] * v[r] }
                let norm = sqrt(max(0.0, normSq))
                rMat[j * cols + j] = norm
                if norm > 1e-13 {
                    let invNorm = 1.0 / norm
                    for r in 0..<rows {
                        qCols[j][r] = v[r] * invNorm
                    }
                } else {
                    qCols[j][j % rows] = 1.0
                }
            }
        }

        var qFlat = [Double](repeating: 0.0, count: rows * k)
        for r in 0..<rows {
            for c in 0..<k {
                qFlat[r * k + c] = qCols[c][r]
            }
        }
        return (qFlat, rMat, k)
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
            for c in 0..<cols {
                transposed[c * rows + r] = matrix[r * cols + c]
            }
        }
        let qr = qrOrthogonalize(matrix: transposed, rows: cols, cols: rows)
        let k = qr.rank
        var lMat = [Double](repeating: 0.0, count: rows * k)
        var qMat = [Double](repeating: 0.0, count: k * cols)
        for r in 0..<rows {
            for c in 0..<k {
                lMat[r * k + c] = qr.r[c * rows + r]
            }
        }
        for r in 0..<k {
            for c in 0..<cols {
                qMat[r * cols + c] = qr.q[c * k + r]
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
            let d = [
                v[0].isFinite ? max(0.01, Double(abs(v[0])) + 0.05) : 0.25,
                v[1].isFinite ? max(0.01, Double(abs(v[1])) + 0.05) : 0.25,
                v[2].isFinite ? max(0.01, Double(abs(v[2])) + 0.05) : 0.25,
                v[3].isFinite ? max(0.01, Double(abs(v[3])) + 0.05) : 0.25
            ]
            let norm = sqrt(d.reduce(0.0) { $0 + $1 * $1 })
            return d.map { $0 / max(1e-12, norm) }
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
                    for i3 in 0..<4 {
                        for i4 in 0..<4 {
                            for i5 in 0..<4 {
                                let acoMode = (i3 + i4 + i5) % 4
                                let idx = (((((i0 * 4 + i1) * 4 + i2) * 4 + i3) * 4 + i4) * 4) + i5
                                let prodAmp = s0[i0] * s1[i1] * s2[i2] * s3[i3] * s4[i4] * s5[i5]
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

    /// Evaluates the expectation value `<psi | H | psi>` under the 6-site bio-acoustic Hamiltonian.
    public func expectationValueNearestNeighborXXZ(anisotropyDelta: Double = 1.0) -> Double {
        DMRGVariationalOptimizer.expectationEnergy(
            stateVector: reconstructStateVector(),
            couplingJ: anisotropyDelta,
            transverseFieldH: 0.5
        )
    }
}

extension DMRGVariationalOptimizer {
    /// Extracts optimal acoustic synthesis control parameters from a DMRG-converged 6-site Matrix Product State.
    public static func extractOptimalBioAcousticControl(
        from mps: MatrixProductStateEngine
    ) -> OptimalBioAcousticControl {
        let telemetry = mps.evaluateEntanglement()
        let groundEnergy = Float(mps.expectationValueNearestNeighborXXZ(anisotropyDelta: 1.0))

        // Extract single-site reduced marginal probabilities on Acoustic Sites 3, 4, 5 (0-indexed: 3, 4, 5)
        func siteExpectation(_ siteIndex: Int) -> Float {
            guard siteIndex >= 0 && siteIndex < mps.cores.count else { return 0.5 }
            let core = mps.cores[siteIndex]
            var weighted = 0.0
            var total = 0.0
            for p in 0..<core.physicalDim {
                var pWeight = 0.0
                for l in 0..<core.leftBond {
                    for r in 0..<core.rightBond {
                        let v = core[l, p, r]
                        pWeight += v * v
                    }
                }
                weighted += Double(p) * pWeight
                total += pWeight
            }
            guard total > 1e-15 else { return 0.5 }
            return Float(min(max(weighted / (Double(max(1, core.physicalDim - 1)) * total), 0.0), 1.0))
        }

        let uBeat = siteExpectation(3)
        let uSpace = siteExpectation(4)
        let uPhase = siteExpectation(5)
        let entropyNorm = min(max(telemetry.centralEntanglementEntropy / Float(log(16.0)), 0.0), 1.0)

        let beatHz = 4.0 + (0.65 * uBeat + 0.35 * entropyNorm) * 14.0
        let carrierHz = 136.1 + (0.60 * uSpace + 0.40 * uPhase) * (432.0 - 136.1)
        let tzfmIdx = 0.35 + (0.55 * entropyNorm + 0.45 * uBeat) * 2.40
        let orbitSpeed = 0.08 + (0.50 * uSpace + 0.50 * entropyNorm) * 0.72
        let stiffness = 0.015 + 0.045 * uPhase

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
