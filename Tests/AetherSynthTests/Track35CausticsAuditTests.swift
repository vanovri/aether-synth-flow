// MARK: - FILE: Track35CausticsAuditTests.swift

import Testing
import Foundation
import simd

@Suite("Track 35 Volumetric Acousto-Optic Caustics Physics, Layout & Frame-Time Governor Audit")
struct Track35CausticsAuditTests {

    @Test("Cauchy normal dispersion & Gladstone-Dale acousto-optic deflection ordering across visible spectrum")
    func verifyCauchyGladstoneDaleDispersionAndDeflection() {
        let wavelengths: [Float] = [380.0, 420.0, 470.0, 532.0, 580.0, 640.0, 700.0]
        var previousN: Float = .greatestFiniteMagnitude

        for wl in wavelengths {
            let nZeroP = AcoustoOpticCausticsEngine.refractiveIndex(wavelengthNm: wl, pressure: 0.0)
            let nPosP = AcoustoOpticCausticsEngine.refractiveIndex(wavelengthNm: wl, pressure: 0.40)
            let nNegP = AcoustoOpticCausticsEngine.refractiveIndex(wavelengthNm: wl, pressure: -0.40)

            #expect(nZeroP < previousN)
            #expect(nPosP > nZeroP)
            #expect(nNegP < nZeroP)
            #expect(nNegP > 1.0)
            previousN = nZeroP
        }

        let deflViolet = AcoustoOpticCausticsEngine.refractionDeflectionAngleRadians(
            wavelengthNm: 400.0,
            pressure: 0.35,
            pressureGradientMagnitude: 0.80
        )
        let deflGreen = AcoustoOpticCausticsEngine.refractionDeflectionAngleRadians(
            wavelengthNm: 550.0,
            pressure: 0.35,
            pressureGradientMagnitude: 0.80
        )
        let deflRed = AcoustoOpticCausticsEngine.refractionDeflectionAngleRadians(
            wavelengthNm: 700.0,
            pressure: 0.35,
            pressureGradientMagnitude: 0.80
        )
        #expect(deflViolet > deflGreen)
        #expect(deflGreen > deflRed)
    }

    @Test("Henyey-Greenstein 4*pi normalization and inverse-CDF importance sampling mean cosine E[cosTheta] == g")
    func verifyHenyeyGreensteinNormalizationAndMeanCosine() {
        let testAnisotropies: [Float] = [-0.50, 0.0, 0.50, 0.72, 0.85]
        let quadratureBins = 2_000
        let dMu: Float = 2.0 / Float(quadratureBins)
        let sampleCount = 4_096

        for g in testAnisotropies {
            var integral4Pi: Float = 0.0
            for i in 0..<quadratureBins {
                let mu = -1.0 + (Float(i) + 0.5) * dMu
                let pdf = AcoustoOpticCausticsEngine.henyeyGreensteinPhase(cosTheta: mu, anisotropyG: g)
                integral4Pi += 2.0 * Float.pi * pdf * dMu
            }
            #expect(abs(integral4Pi - 1.0) < 2.0e-3)

            var cosSum: Double = 0.0
            for s in 0..<sampleCount {
                let xi = (Float(s) + 0.5) / Float(sampleCount)
                let sampledMu = AcoustoOpticCausticsEngine.sampleHenyeyGreensteinCosTheta(
                    uniformRandom01: xi,
                    anisotropyG: g
                )
                #expect(sampledMu >= -1.0 && sampledMu <= 1.0)
                cosSum += Double(sampledMu)
            }
            let meanCos = Float(cosSum / Double(sampleCount))
            #expect(abs(meanCos - g) < 2.0e-3)
        }
    }

    @Test("Adaptive frame-time quality governor converges < 6.5 ms target and enforces < 8.0 ms hard cap")
    func verifyAdaptiveQualityGovernorConvergenceUnder8msBudget() {
        var governor = CausticsQualityGovernor(
            minPhotonCount: 1_024,
            maxPhotonCount: 16_384,
            minIntegrationSteps: 6,
            maxIntegrationSteps: 32,
            initialQualityScale: 1.0
        )

        #expect(governor.activePhotonCount == 16_384)
        #expect(governor.activeIntegrationSteps == 32)

        func simulatedGPUCostMs(for q: Float) -> Double {
            let stepFactor = Double(0.40 + 0.60 * q)
            return 1.1 + 12.4 * Double(q) * stepFactor
        }

        // Simulate 12 frames starting from an overloaded 13.5 ms GPU frame (> 8.0 ms hard cap)
        var frameTimesMs: [Double] = []
        var gpuClockSeconds: Double = 100.0
        for _ in 0..<12 {
            let costMs = simulatedGPUCostMs(for: governor.qualityScale)
            frameTimesMs.append(costMs)
            let startSec = gpuClockSeconds
            let endSec = startSec + costMs * 1.0e-3
            gpuClockSeconds = endSec + 0.001
            governor.recordGPUTimestamps(gpuStartTimeSeconds: startSec, gpuEndTimeSeconds: endSec)
        }

        // Must trigger emergency throttle on frame 0 and drop below 8.0 ms hard cap by frame 1..2
        #expect(governor.totalEmergencyThrottleCount >= 1)
        #expect(frameTimesMs[1] < CausticsQualityGovernor.hardCapFrameTimeMs)
        #expect(frameTimesMs.last! < CausticsQualityGovernor.targetFrameTimeMs)
        #expect(governor.activePhotonCount >= governor.minPhotonCount)
        #expect(governor.activePhotonCount < governor.maxPhotonCount)
        #expect((governor.activePhotonCount % 64) == 0)

        // Verify gradual recovery when GPU frame time drops well below recovery threshold (4.8 ms)
        let throttledPhotons = governor.activePhotonCount
        for _ in 0..<8 {
            governor.recordFrameTime(milliseconds: 2.5)
        }
        #expect(governor.activePhotonCount > throttledPhotons)
    }

    @Test("AcoustoOpticCausticUniforms Swift/Metal 64-byte stride & field offset invariance")
    func verifyUniformStructLayoutStrideAndAlignment() {
        #expect(MemoryLayout<AcoustoOpticCausticUniforms>.size == 64)
        #expect(MemoryLayout<AcoustoOpticCausticUniforms>.stride == AcoustoOpticCausticUniforms.expectedByteStride)
        #expect(MemoryLayout<AcoustoOpticCausticUniforms>.alignment == 8)

        let lightDirOffset = MemoryLayout<AcoustoOpticCausticUniforms>.offset(of: \.lightDirectionXY)
        let frameSeedOffset = MemoryLayout<AcoustoOpticCausticUniforms>.offset(of: \.frameSeed)
        let slabDepthOffset = MemoryLayout<AcoustoOpticCausticUniforms>.offset(of: \.slabDepthCells)
        let emaAlphaOffset = MemoryLayout<AcoustoOpticCausticUniforms>.offset(of: \.emaAlpha)
        let toneMapOffset = MemoryLayout<AcoustoOpticCausticUniforms>.offset(of: \.toneMapCompression)

        #expect(lightDirOffset == 40)
        #expect(frameSeedOffset == 48)
        #expect(slabDepthOffset == 52)
        #expect(emaAlphaOffset == 56)
        #expect(toneMapOffset == 60)
    }

    @Test("CIE 1931 XYZ to Linear Display-P3 / sRGB and optimized traceCausticsField irradiance invariance")
    func verifyCIE1931DisplayP3AndTraceCausticsField() {
        let xyzGreen = AcoustoOpticCausticsEngine.wavelengthToCIE1931XYZ(532.0)
        let p3Green = AcoustoOpticCausticsEngine.xyzToLinearDisplayP3(xyzGreen)
        let srgbGreen = AcoustoOpticCausticsEngine.xyzToLinearSRGB(xyzGreen)
        #expect(p3Green.y > 0.8 && srgbGreen.y > 0.8)
        #expect(AcoustoOpticCausticsEngine.wavelengthToCIE1931XYZ(300.0) == .zero)
        #expect(AcoustoOpticCausticsEngine.wavelengthToCIE1931XYZ(820.0) == .zero)

        let n = 16
        var syntheticPressure = [Float](repeating: 0.0, count: n * n)
        for y in 0..<n {
            for x in 0..<n {
                let fx = Float(x) / Float(n)
                let fy = Float(y) / Float(n)
                syntheticPressure[y * n + x] = 0.5 * sinf(2.0 * Float.pi * fx) * cosf(2.0 * Float.pi * fy)
            }
        }

        let irradiance = AcoustoOpticCausticsEngine.traceCausticsField(
            pressureGrid: syntheticPressure,
            gridSize: n,
            photonCount: 512,
            integrationSteps: 10
        )
        #expect(irradiance.count == n * n)
        var totalEnergy: Float = 0.0
        for cell in irradiance {
            #expect(cell.x.isFinite && cell.y.isFinite && cell.z.isFinite)
            #expect(cell.x >= 0.0 && cell.y >= 0.0 && cell.z >= 0.0)
            totalEnergy += cell.x + cell.y + cell.z
        }
        #expect(totalEnergy > 1.0)
    }
}
