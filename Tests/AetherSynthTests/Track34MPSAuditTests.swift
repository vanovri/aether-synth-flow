// MARK: - FILE: Track34MPSAuditTests.swift

import Testing
import Foundation
import simd

@Suite("Track 34 Audit: QR-Preconditioned MPS TT-SVD, Truncation Fidelity & Cached-Environment 2-Site DMRG")
struct Track34MPSAuditTests {

    @Test("Left-canonical orthogonality (< 1e-9) across product, Bell & bio-acoustic states + rank-deficient Householder QR")
    func verifyLeftCanonicalOrthogonalityAndHouseholderQRRankDeficiency() {
        let productVec = MatrixProductStateEngine.makeSeparableProductState()
        let productMPS = MatrixProductStateEngine(stateVector: productVec, maxBondDim: 8)
        #expect(productMPS.verifyLeftCanonicalOrthogonality() < 1.0e-9)

        let bellVec = MatrixProductStateEngine.makeMaximallyEntangledBellState(schmidtRank: 8)
        let bellMPS = MatrixProductStateEngine(stateVector: bellVec, maxBondDim: 16)
        #expect(bellMPS.verifyLeftCanonicalOrthogonality() < 1.0e-9)

        let bioFloats = MatrixProductStateEngine.encodeBioAcousticStateTensor(
            eegCorticalBands4: SIMD4<Float>(0.25, 0.55, 0.48, 0.22),
            hrvVagalMetrics4: SIMD4<Float>(0.68, 0.72, 0.30, 0.85),
            spwvdEntropyState4: SIMD4<Float>(0.42, 0.60, 0.52, 0.35),
            binauralOscillatorState4: SIMD4<Float>(0.50, 0.45, 0.38, 0.62),
            hrtfFDTDWavefield4: SIMD4<Float>(0.48, 0.58, 0.44, 0.50),
            circadianKalmanPhase4: SIMD4<Float>(0.70, 0.35, 0.60, 0.40),
            entanglementCoupling: 0.65
        )
        let bioMPS = MatrixProductStateEngine(stateVector: bioFloats, maxBondDim: 12)
        #expect(bioMPS.verifyLeftCanonicalOrthogonality() < 1.0e-9)

        // Verify Householder QR preserves ||Q^T Q - I||_F < 1e-12 even on a rank-2 matrix of shape 16x8
        let rows = 16
        let cols = 8
        var rankDeficient = [Double](repeating: 0.0, count: rows * cols)
        rankDeficient[0 * cols + 0] = 3.0
        rankDeficient[2 * cols + 4] = -5.0
        rankDeficient[7 * cols + 4] = 2.0

        let qr = MatrixProductStateEngine.qrOrthogonalize(matrix: rankDeficient, rows: rows, cols: cols)
        #expect(qr.rank == cols)

        var qtqDefectSq = 0.0
        for i in 0..<qr.rank {
            for j in 0..<qr.rank {
                var dot = 0.0
                for r in 0..<rows {
                    dot += qr.q[r * qr.rank + i] * qr.q[r * qr.rank + j]
                }
                let target = (i == j) ? 1.0 : 0.0
                let diff = dot - target
                qtqDefectSq += diff * diff
            }
        }
        #expect(sqrt(qtqDefectSq) < 1.0e-12)

        var reconErrSq = 0.0
        for r in 0..<rows {
            for c in 0..<cols {
                var sum = 0.0
                for k in 0..<qr.rank {
                    sum += qr.q[r * qr.rank + k] * qr.r[k * cols + c]
                }
                let diff = rankDeficient[r * cols + c] - sum
                reconErrSq += diff * diff
            }
        }
        #expect(sqrt(reconErrSq) < 1.0e-12)
    }

    @Test("Untruncated TT-SVD state reconstruction fidelity (> 1 - 1e-10) & exact discarded truncation weight tracking")
    func verifyUntruncatedStateReconstructionAndTruncationWeightFidelity() {
        // 1. Construct a non-trivial 6-site state with exact bond dimensions [1, 4, 16, 16, 16, 4, 1]
        let bondDims = [1, 4, 16, 16, 16, 4, 1]
        var synthCores: [MPSCoreTensor] = []
        var seed: UInt64 = 0xCAFE_BABE_1234_5678
        func nextSignedUnit() -> Double {
            seed ^= seed >> 12
            seed ^= seed << 25
            seed ^= seed >> 27
            let v = seed &* 0x2545_F491_4F6C_DD1D
            let unit = Double(v >> 11) / Double(1 << 53)
            return unit * 2.0 - 1.0
        }

        for s in 0..<6 {
            let lDim = bondDims[s]
            let rDim = bondDims[s + 1]
            let count = lDim * 4 * rDim
            var data = [Double](repeating: 0.0, count: count)
            for i in 0..<count {
                data[i] = nextSignedUnit()
            }
            synthCores.append(MPSCoreTensor(leftBond: lDim, physicalDim: 4, rightBond: rDim, storage: data))
        }

        let synthEngine = MatrixProductStateEngine(cores: synthCores, maxBondDim: 16)
        var exactPsi = synthEngine.reconstructStateVector()
        var normSq = 0.0
        for v in exactPsi { normSq += v * v }
        let invNorm = 1.0 / sqrt(normSq)
        for i in 0..<exactPsi.count { exactPsi[i] *= invNorm }

        let decomposed = MatrixProductStateEngine(stateVector: exactPsi, maxBondDim: 16)
        #expect(decomposed.verifyLeftCanonicalOrthogonality() < 1.0e-9)
        let reconstructed = decomposed.reconstructStateVector()

        var overlap = 0.0
        for i in 0..<exactPsi.count {
            overlap += exactPsi[i] * reconstructed[i]
        }
        let fidelity = overlap * overlap
        #expect(fidelity > 1.0 - 1.0e-10)
        #expect(decomposed.evaluateEntanglement().totalTruncationError < 1.0e-12)

        // 2. Truncate a rank-16 maximally entangled Bell state to maxBondDim = 8:
        //    8 of 16 equal Schmidt weights (1/16 each) are discarded -> discardedWeight == 0.50
        let bell16 = MatrixProductStateEngine.makeMaximallyEntangledBellState(schmidtRank: 16)
        let truncated8 = MatrixProductStateEngine(stateVector: bell16, maxBondDim: 8)
        let truncSnap = truncated8.evaluateEntanglement()
        #expect(abs(truncSnap.totalTruncationError - 0.5) < 1.0e-9)

        let truncRecon = truncated8.reconstructStateVector()
        var truncOverlap = 0.0
        for i in 0..<bell16.count {
            truncOverlap += bell16[i] * truncRecon[i]
        }
        let truncFidelity = truncOverlap * truncOverlap
        #expect(abs((1.0 - truncFidelity) - truncSnap.totalTruncationError) < 1.0e-9)
    }

    @Test("2-site DMRG monotonic variational energy descent, exact 4096D ground energy agreement & in-place inout MPS update")
    func verifyMonotonicDMRGEnergyDescentAndInPlaceMPSMutation() {
        let bell8 = MatrixProductStateEngine.makeMaximallyEntangledBellState(schmidtRank: 8)
        let initialEnergy = DMRGVariationalOptimizer.expectationEnergy(
            stateVector: bell8,
            couplingJ: 1.0,
            transverseFieldH: 0.5
        )
        #expect(abs(initialEnergy - (-3.0)) < 1.0e-9)

        let sweeps = DMRGVariationalOptimizer.runSweeps(
            initialState: bell8,
            couplingJ: 1.0,
            transverseFieldH: 0.5,
            sweeps: 4,
            maxBondDim: 8
        )
        #expect(sweeps.count == 4)
        #expect(sweeps[0].variationalEnergy < initialEnergy - 8.0)

        for idx in 1..<sweeps.count {
            #expect(sweeps[idx].variationalEnergy <= sweeps[idx - 1].variationalEnergy + 1.0e-9)
        }

        // Exact 4096D Spin-3/2 TFIM ground state energy for N=6, J=1.0, h=0.5 is -11.7475261749
        let exactGroundEnergy4096 = -11.7475261749
        let finalEnergy = sweeps.last!.variationalEnergy
        #expect(abs(finalEnergy - exactGroundEnergy4096) < 1.0e-5)

        // Verify inout mps overload mutates mps in-place and preserves left-canonical orthogonality
        var mps = MatrixProductStateEngine(stateVector: bell8, maxBondDim: 8)
        let energyBefore = mps.expectationValueNearestNeighborXXZ(anisotropyDelta: 1.0)
        let dmrg = DMRGVariationalOptimizer(anisotropyDelta: 1.0, maxBondDim: 8, lanczosIterations: 8)
        let snapAfter = dmrg.runSweeps(mps: &mps, sweepCount: 2)
        let energyAfter = mps.expectationValueNearestNeighborXXZ(anisotropyDelta: 1.0)

        #expect(energyAfter < energyBefore - 8.0)
        #expect(abs(energyAfter - snapAfter.variationalEnergy) < 1.0e-8)
        #expect(mps.verifyLeftCanonicalOrthogonality() < 1.0e-9)

        let control = DMRGVariationalOptimizer.extractOptimalBioAcousticControl(from: mps)
        #expect(abs(Double(control.groundStateEnergy) - energyAfter) < 1.0e-4)
        #expect((4.0...18.0).contains(control.recommendedBinauralBeatHz))
        #expect((136.0...432.5).contains(control.recommendedCarrierHz))
    }

    @Test("Von Neumann entanglement entropy bounds 0 <= S_vN <= ln(chi), Rényi-2 purity & gauge-invariant site marginals")
    func verifyEntanglementEntropyBoundsAndGaugeInvariantMarginals() {
        for rank in [1, 2, 4, 8, 16] {
            let state = MatrixProductStateEngine.makeMaximallyEntangledBellState(schmidtRank: rank)
            let mps = MatrixProductStateEngine(stateVector: state, maxBondDim: 16)
            let snap = mps.evaluateEntanglement()

            let expectedEntropy = log(Double(rank))
            let expectedPurity = 1.0 / Double(rank)
            #expect(abs(snap.vonNeumannEntropyNats - expectedEntropy) < 1.0e-9)
            #expect(abs(snap.renyi2Purity - expectedPurity) < 1.0e-9)
            #expect(abs(snap.effectiveSchmidtRank - Double(rank)) < 1.0e-7)
            #expect(snap.vonNeumannEntropyNats >= 0.0)
            #expect(snap.vonNeumannEntropyNats <= log(Double(snap.maxBondDimension)) + 1.0e-9)
        }

        // Verify gauge-invariant single-site marginals match exact 4096D state-vector marginals
        let bioFloats = MatrixProductStateEngine.encodeBioAcousticStateTensor(
            eegCorticalBands4: SIMD4<Float>(0.80, 0.20, 0.15, 0.10),
            hrvVagalMetrics4: SIMD4<Float>(0.10, 0.75, 0.25, 0.30),
            spwvdEntropyState4: SIMD4<Float>(0.20, 0.30, 0.85, 0.15),
            binauralOscillatorState4: SIMD4<Float>(0.15, 0.25, 0.20, 0.90),
            hrtfFDTDWavefield4: SIMD4<Float>(0.65, 0.45, 0.25, 0.15),
            circadianKalmanPhase4: SIMD4<Float>(0.25, 0.60, 0.55, 0.35),
            entanglementCoupling: 0.45
        )
        let bioMPS = MatrixProductStateEngine(stateVector: bioFloats, maxBondDim: 16)
        let mpsMarginals = bioMPS.computeSingleSiteNormalizedExpectations()
        let densePsi = bioMPS.reconstructStateVector()

        var siteProbs = [[Double]](repeating: [Double](repeating: 0.0, count: 4), count: 6)
        for idx in 0..<4096 {
            let p2 = densePsi[idx] * densePsi[idx]
            var tmp = idx
            for s in stride(from: 5, through: 0, by: -1) {
                let phys = tmp & 3
                tmp >>= 2
                siteProbs[s][phys] += p2
            }
        }

        for s in 0..<6 {
            var expected = 0.0
            for p in 0..<4 {
                expected += Double(p) * siteProbs[s][p]
            }
            expected /= 3.0
            #expect(abs(Double(mpsMarginals[s]) - expected) < 1.0e-6)
        }
    }
}
