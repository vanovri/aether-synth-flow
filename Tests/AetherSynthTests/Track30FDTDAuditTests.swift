// MARK: - FILE: Track30FDTDAuditTests.swift

import Testing
import Foundation
import simd

@Suite("Track 30/32 FDTD Acoustic Waveguide CFL, Dispersion & SIMD Equivalence Audit")
struct Track30FDTDAuditTests {

    @Test("CFL Courant bound S <= 1/sqrt(D) & compact stencil spectral radius across 1D/2D/3D and runtime setters")
    func verifyCFLBoundEnforcementAcrossDimensionsAndRuntimePaths() {
        for dim in [1, 2, 3] {
            let extreme = FDTDCFLParameters(
                dimension: dim,
                waveSpeed: 2_400.0,
                stiffnessKappa: 55.0,
                gridSpacingMeters: 0.008,
                timeStepSeconds: 1.0 / 48_000.0,
                sigma0: 1.5,
                sigma1: 0.015
            )
            #expect(extreme.wasClamped)
            #expect(extreme.isStable)
            let invSqrtD = 1.0 / sqrtf(Float(dim))
            #expect(extreme.courantLambda <= invSqrtD + 1.0e-6)
        }

        // Verify assigning a 1D CFL struct (with lambdaSq > 0.5) to a 2D or 3D tank re-clamps to D=2 / D=3
        let cfl1D = FDTDCFLParameters(
            dimension: 1,
            waveSpeed: 343.0,
            stiffnessKappa: 0.0,
            gridSpacingMeters: 0.01,
            timeStepSeconds: 0.01 * 0.90 / 343.0,
            sigma0: 0.0,
            sigma1: 0.0
        )
        #expect(cfl1D.lambdaSq > 0.70)

        var tank2D = FDTDWaveTankGrid2D(gridSize: 32, pmlThickness: 6)
        tank2D.cflParameters = cfl1D
        #expect(tank2D.cflParameters.dimension == 2)
        #expect(tank2D.cflParameters.isStable)
        #expect(tank2D.cflParameters.lambdaSq <= 0.50)

        var tank3D = FDTDWaveTankGrid3D(size: 12, pmlThickness: 2)
        tank3D.cflParameters = cfl1D
        #expect(tank3D.cflParameters.dimension == 3)
        #expect(tank3D.cflParameters.isStable)
        #expect(tank3D.cflParameters.lambdaSq <= (1.0 / 3.0) + 1.0e-6)

        // Verify audio-rate resonator CFL stability across 44.1 kHz, 48 kHz, and 96 kHz
        for sr in [44_100.0, 48_000.0, 96_000.0] {
            let resonator = RealtimeFDTDResonatorKernel(sampleRate: sr)
            let coeffs = resonator.resolveStableCoefficients(
                waveSpeed: 680.0,
                stiffnessKappa: 1.0,
                dampingSigma: 10.0
            )
            #expect(coeffs.baseLambdaSq <= coeffs.maxLocalLambdaSq + 1.0e-6)
            let eMax: Float = 16.0 / 3.0
            let spectralSum = 0.25 * eMax * (coeffs.maxLocalLambdaSq + eMax * coeffs.muSq + 2.0 * coeffs.viscous)
            #expect(spectralSum <= 1.0 + 1.0e-5)
        }
    }

    @Test("5,000-step 2D FDTD energy stability & cubic PML >35 dB absorption without parasitic corner oscillation")
    func verify5000StepEnergyStabilityAndPMLAttenuation() {
        var pmlTank = FDTDWaveTankGrid2D(
            gridSize: 48,
            pmlThickness: 8,
            boundaryMode: .absorbingPML,
            pmlMaxSigma: 0.36
        )
        var dirichletTank = FDTDWaveTankGrid2D(
            gridSize: 48,
            pmlThickness: 8,
            boundaryMode: .rigidDirichlet,
            pmlMaxSigma: 0.0
        )

        #expect(pmlTank.pmlDampingProfile.allSatisfy { $0 >= 0.0 && $0 <= 0.96 })

        pmlTank.injectGaussianPulse(centerX: 24, centerY: 24, sigmaCells: 2.6, amplitude: 1.0)
        dirichletTank.injectGaussianPulse(centerX: 24, centerY: 24, sigmaCells: 2.6, amplitude: 1.0)

        let initialEnergy = pmlTank.totalGridEnergy()
        #expect(initialEnergy > 1.0 && initialEnergy.isFinite)

        for step in 1...5_000 {
            pmlTank.step()
            if step <= 1_000 {
                dirichletTank.step()
            }
            if step % 500 == 0 {
                let e = pmlTank.totalGridEnergy()
                #expect(e.isFinite)
                #expect(e <= initialEnergy * 1.001)
            }
        }

        let finalPMLEnergy = pmlTank.interiorDiscreteEnergy()
        let refDirichletEnergy = dirichletTank.interiorDiscreteEnergy()
        #expect(finalPMLEnergy.isFinite && refDirichletEnergy.isFinite)
        let attenDB = 10.0 * log10(Double(max(refDirichletEnergy, 1.0e-20)) / Double(max(finalPMLEnergy, 1.0e-20)))
        #expect(attenDB > 35.0)
    }

    @Test("Von Neumann numerical dispersion cutoff frequency f_max & excitation source band-limiting")
    func verifyVonNeumannDispersionCutoffAndSourceBandLimiting() {
        let tank = FDTDWaveTankGrid2D(gridSize: 64, pmlThickness: 10)
        let cfl = tank.cflParameters

        // At high PPW (32 cells/wavelength), phase velocity ratio must be within 0.2% of unity
        let ratioHighPPW = FDTDCFLParameters.phaseVelocityRatio(
            pointsPerWavelength: 32.0,
            courantLambda: cfl.courantLambda,
            dimension: 2,
            propagationAngleRadians: 0.0
        )
        #expect(abs(ratioHighPPW - 1.0) < 0.002)

        let minPPW2Pct = cfl.minimumPointsPerWavelength(maxPhaseVelocityError: 0.02)
        let minPPW1Pct = cfl.minimumPointsPerWavelength(maxPhaseVelocityError: 0.01)
        #expect(minPPW2Pct > 5.0 && minPPW2Pct < 10.0)
        #expect(minPPW1Pct > minPPW2Pct)

        let errAtCutoff = FDTDCFLParameters.worstDirectionalDispersionError(
            pointsPerWavelength: minPPW2Pct,
            courantLambda: cfl.courantLambda,
            dimension: 2
        )
        #expect(errAtCutoff <= 0.0205)

        let fMax = tank.dispersionLimitedMaxFrequency
        #expect(fMax > 2_000.0 && fMax < 4_000.0)
        #expect(abs(tank.recommendedSourceBandwidth - fMax) < 1.0e-4)

        // Sub-grid pulse sigmaCells = 0.25 must be automatically widened to >= minimumGaussianSigmaCells()
        var subgridTank = FDTDWaveTankGrid2D(gridSize: 32, pmlThickness: 6)
        subgridTank.injectGaussianPulse(centerX: 16, centerY: 16, sigmaCells: 0.25, amplitude: 1.0)
        let centerP = subgridTank.pressureCurr[16 * 32 + 16]
        let neighborP = subgridTank.pressureCurr[16 * 32 + 17]
        #expect(centerP > 0.99)
        #expect(neighborP > 0.55)

        // Audio-rate resonator low-pass filter must pass 220 Hz and attenuate 18 kHz dispersive excitation
        var resLow = RealtimeFDTDResonatorKernel(sampleRate: 48_000.0)
        var resHigh = RealtimeFDTDResonatorKernel(sampleRate: 48_000.0)
        var energyLow: Float = 0.0
        var energyHigh: Float = 0.0
        for n in 0..<512 {
            let t = Float(n) / 48_000.0
            let outLow = resLow.stepSample(excitation: 0.5 * sinf(2.0 * .pi * 220.0 * t))
            let outHigh = resHigh.stepSample(excitation: 0.5 * sinf(2.0 * .pi * 18_000.0 * t))
            energyLow += outLow.0 * outLow.0 + outLow.1 * outLow.1
            energyHigh += outHigh.0 * outHigh.0 + outHigh.1 * outHigh.1
        }
        #expect(energyLow > 1.0e-3)
        #expect(energyHigh < energyLow * 0.15)
    }

    @Test("SIMD8 / SIMD4 vs scalar reference numerical equivalence across 2D obstacles/lenses, 3D grid & 24x24 resonator")
    func verifySIMDVersusScalarEquivalence2D3DAndResonator() {
        // 1. 2D Wave Tank (SIMD8 vs scalar) with double-slit Neumann walls, Dirichlet absorber, refractive lens & biharmonic stiffness
        var simdTank = FDTDWaveTankGrid2D(gridSize: 48, pmlThickness: 8, boundaryMode: .absorbingPML, pmlMaxSigma: 0.34)
        let stiffCFL = FDTDCFLParameters(
            dimension: 2,
            waveSpeed: 343.0,
            stiffnessKappa: 0.12,
            gridSpacingMeters: 0.015,
            timeStepSeconds: 0.015 * 0.46 / 343.0,
            sigma0: 0.4,
            sigma1: 0.00002
        )
        simdTank.cflParameters = stiffCFL
        simdTank.configureDoubleSlitBarrier(barrierX: 24, slitWidthCells: 4, slitSeparationCells: 12)
        simdTank.setObstacle(x: 18, y: 20, isSolid: true, isNeumannRigid: false)
        simdTank.addRefractiveAcousticLens(centerX: 30, centerY: 24, radiusCells: 6.0, relativeWaveSpeed: 0.65)
        simdTank.injectGaussianPulse(centerX: 14, centerY: 24, sigmaCells: 2.6, amplitude: 1.2)

        var scalarTank = simdTank
        for _ in 0..<120 {
            simdTank.step()
            scalarTank.stepScalarReference()
        }

        var maxDiff2D: Float = 0.0
        for i in 0..<simdTank.pressureCurr.count {
            let diff = abs(simdTank.pressureCurr[i] - scalarTank.pressureCurr[i])
            if diff > maxDiff2D { maxDiff2D = diff }
        }
        #expect(maxDiff2D < 1.0e-5)

        // 2. 3D Wave Tank (SIMD4 vs scalar) over 40 steps
        var simd3D = FDTDWaveTankGrid3D(size: 14, pmlThickness: 3)
        simd3D.injectCenteredGaussianPulse(sigmaCells: 1.8, amplitude: 1.0)
        var scalar3D = simd3D

        for _ in 0..<40 {
            simd3D.step()
            scalar3D.stepScalarReference()
        }

        var maxDiff3D: Float = 0.0
        for i in 0..<simd3D.pressureCurr.count {
            let diff = abs(simd3D.pressureCurr[i] - scalar3D.pressureCurr[i])
            if diff > maxDiff3D { maxDiff3D = diff }
        }
        #expect(maxDiff3D < 1.0e-5)

        // 3. 24x24 RealtimeFDTDResonatorKernel (SIMD4 vs scalar) over 512 samples + custom mic coordinates
        var simdRes = RealtimeFDTDResonatorKernel(sampleRate: 48_000.0)
        var scalarRes = RealtimeFDTDResonatorKernel(sampleRate: 48_000.0)
        simdRes.leftMicNormalized = SIMD2<Float>(0.26, 0.38)
        simdRes.rightMicNormalized = SIMD2<Float>(0.74, 0.62)
        scalarRes.leftMicNormalized = SIMD2<Float>(0.26, 0.38)
        scalarRes.rightMicNormalized = SIMD2<Float>(0.74, 0.62)

        simdRes.obstacleMaskPointer[10 * 24 + 10] = 1
        scalarRes.obstacleMaskPointer[10 * 24 + 10] = 1

        simdRes.triggerRaisedCosinePluck(normalizedX: 0.45, normalizedY: 0.55, amplitude: 0.80, radiusCells: 2.6)
        scalarRes.triggerRaisedCosinePluck(normalizedX: 0.45, normalizedY: 0.55, amplitude: 0.80, radiusCells: 2.6)

        var maxDiffRes: Float = 0.0
        for n in 0..<512 {
            let exc = 0.30 * sinf(2.0 * .pi * 310.0 * Float(n) / 48_000.0)
            let pairSIMD = simdRes.stepSample(
                excitation: exc,
                waveSpeed: 380.0,
                stiffnessKappa: 0.24,
                dampingSigma: 1.6,
                nonlinearGamma: 0.09
            )
            let pairScalar = scalarRes.stepSampleScalarReference(
                excitation: exc,
                waveSpeed: 380.0,
                stiffnessKappa: 0.24,
                dampingSigma: 1.6,
                nonlinearGamma: 0.09
            )
            maxDiffRes = max(maxDiffRes, max(abs(pairSIMD.0 - pairScalar.0), abs(pairSIMD.1 - pairScalar.1)))
        }
        #expect(maxDiffRes < 1.0e-5)
    }
}
