// MARK: - FILE: SpectralCausticsRenderer.swift

import Foundation
import SwiftUI
import simd

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
    public static let spectralWavelengthBandsNm: [Float] = [
        380.0, 425.7143, 471.4286, 517.1429,
        562.8571, 608.5714, 654.2857, 700.0
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

        let xBar = 1.056 * asymmetricGaussian(wavelengthNm, mu: 599.8, sigmaLeft: 0.0264, sigmaRight: 0.0323)
            + 0.362 * asymmetricGaussian(wavelengthNm, mu: 442.0, sigmaLeft: 0.0624, sigmaRight: 0.0374)
            - 0.065 * asymmetricGaussian(wavelengthNm, mu: 501.1, sigmaLeft: 0.0490, sigmaRight: 0.0382)

        let yBar = 0.821 * asymmetricGaussian(wavelengthNm, mu: 568.8, sigmaLeft: 0.0213, sigmaRight: 0.0247)
            + 0.286 * asymmetricGaussian(wavelengthNm, mu: 530.9, sigmaLeft: 0.0613, sigmaRight: 0.0322)

        let zBar = 1.217 * asymmetricGaussian(wavelengthNm, mu: 437.0, sigmaLeft: 0.0845, sigmaRight: 0.0278)
            + 0.681 * asymmetricGaussian(wavelengthNm, mu: 459.0, sigmaLeft: 0.0385, sigmaRight: 0.0725)

        return SIMD3<Float>(max(0.0, xBar), max(0.0, yBar), max(0.0, zBar))
    }

    /// Converts CIE 1931 `XYZ` tristimulus values into Linear Display-P3 wide-gamut RGB.
    @inline(__always)
    public static func xyzToLinearDisplayP3(_ xyz: SIMD3<Float>) -> SIMD3<Float> {
        let r =  2.4934969 * xyz.x - 0.9313836 * xyz.y - 0.4027108 * xyz.z
        let g = -0.8294890 * xyz.x + 1.7626641 * xyz.y + 0.0236247 * xyz.z
        let b =  0.0358458 * xyz.x - 0.0761724 * xyz.y + 0.9568845 * xyz.z
        return SIMD3<Float>(max(0.0, r), max(0.0, g), max(0.0, b))
    }

    /// Wyman, Sloan & Shirley (2013) CIE 1931 2-degree piecewise Gaussian color-matching functions
    /// transformed into non-negative Linear sRGB (`D65` primaries).
    @inline(__always)
    public static func wavelengthToLinearSRGB(_ wavelengthNm: Float) -> SIMD3<Float> {
        let xyz = wavelengthToCIE1931XYZ(wavelengthNm)
        let r =  3.2406 * xyz.x - 1.5372 * xyz.y - 0.4986 * xyz.z
        let g = -0.9689 * xyz.x + 1.8758 * xyz.y + 0.0415 * xyz.z
        let b =  0.0557 * xyz.x - 0.2040 * xyz.y + 1.0570 * xyz.z

        return SIMD3<Float>(max(0.0, r), max(0.0, g), max(0.0, b))
    }

    /// Normalized Henyey-Greenstein volumetric scattering phase function (`integral over 4*pi sr == 1.0`).
    @inline(__always)
    public static func henyeyGreensteinPhase(cosTheta: Float, anisotropyG: Float) -> Float {
        let g = min(max(anisotropyG, -0.98), 0.98)
        let mu = min(max(cosTheta, -1.0), 1.0)
        let gSq = g * g
        let denom = max(1.0e-5, 1.0 + gSq - 2.0 * g * mu)
        return (1.0 - gSq) / (4.0 * Float.pi * denom * sqrtf(denom))
    }

    @inline(__always)
    private static func sampleBilinear(_ grid: [Float], size: Int, x: Float, y: Float) -> Float {
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
        return top + fy * (bot - top)
    }

    @inline(__always)
    private static func sampleGradient(_ grid: [Float], size: Int, x: Float, y: Float) -> SIMD2<Float> {
        let pR = sampleBilinear(grid, size: size, x: x + 1.0, y: y)
        let pL = sampleBilinear(grid, size: size, x: x - 1.0, y: y)
        let pU = sampleBilinear(grid, size: size, x: x, y: y + 1.0)
        let pD = sampleBilinear(grid, size: size, x: x, y: y - 1.0)
        return SIMD2<Float>((pR - pL) * 0.5, (pU - pD) * 0.5)
    }

    /// Traces `photonCount` polychromatic photons (`380..700 nm`) through the 2D acoustic pressure field
    /// using Eikonal refractive bending (`d(n * s)/ds = grad(n)`), Cauchy dispersion, Henyey-Greenstein
    /// forward scattering, and bilinear Wyman CIE 1931 Linear sRGB splatting onto a `gridSize x gridSize` receiver plane.
    public static func traceCausticsField(
        pressureGrid: [Float],
        gridSize: Int,
        photonCount: Int = 4_096
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
        let n0: Float = 1.333
        let cauchyB: Float = 0.0125 // Boosted dispersive prism visibility across visible spectrum
        let kappaAO: Float = 0.085
        let anisotropyG: Float = 0.72
        let integrationSteps = 12
        let stepLength: Float = 0.85

        // Slight oblique illumination angle reveals vivid prismatic RGB separation at caustic cusps
        let initialBeamDir = simd_normalize(SIMD3<Float>(0.14, 0.09, 1.0))
        let energyPerPhoton = Float(cellCount) / Float(max(1, photonCount)) * 0.42

        for pIdx in 0..<photonCount {
            let sx = pIdx % strataSide
            let sy = (pIdx / strataSide) % strataSide

            // Deterministic Halton/Fibonacci sub-cell jitter + golden-ratio spectral sampling
            let jx = fmodf(Float(pIdx &* 73 &+ 19) * 0.00390625, 1.0)
            let jy = fmodf(Float(pIdx &* 137 &+ 53) * 0.00390625, 1.0)
            let u = min(max((Float(sx) + jx) * invStrata, 0.001), 0.999)
            let v = min(max((Float(sy) + jy) * invStrata, 0.001), 0.999)

            let specT = fmodf(Float(pIdx) * 0.61803399 + 0.13, 1.0)
            let wavelengthNm = minVisibleWavelengthNm + specT * (maxVisibleWavelengthNm - minVisibleWavelengthNm)
            let photonRGB = wavelengthToLinearSRGB(wavelengthNm) * energyPerPhoton

            var pos = SIMD2<Float>(u * maxCoord, v * maxCoord)
            var rayDir = initialBeamDir

            let lambdaUm = wavelengthNm * 1.0e-3
            let baseDispN = n0 + cauchyB / (lambdaUm * lambdaUm)

            // Surface entry Snell refraction modulated by initial local pressure
            let entryPressure = sampleBilinear(pressureGrid, size: n, x: pos.x, y: pos.y)
            let entryN = max(1.001, baseDispN * max(0.1, 1.0 + kappaAO * entryPressure))
            rayDir.x /= entryN
            rayDir.y /= entryN
            rayDir = simd_normalize(rayDir)

            for _ in 0..<integrationSteps {
                let localP = sampleBilinear(pressureGrid, size: n, x: pos.x, y: pos.y)
                let localN = max(1.001, baseDispN * max(0.1, 1.0 + kappaAO * localP))
                let gradP = sampleGradient(pressureGrid, size: n, x: pos.x, y: pos.y)
                let gradN = gradP * (baseDispN * kappaAO)

                // Eikonal ray curvature toward higher refractive index
                let bendScale: Float = (stepLength * 5.2) / localN
                rayDir.x += gradN.x * bendScale
                rayDir.y += gradN.y * bendScale
                rayDir = simd_normalize(rayDir)

                pos += SIMD2<Float>(rayDir.x, rayDir.y) * stepLength

                // Wrap toroidally inside viewport so edge photons remain bounded and continuous
                if pos.x < 0.0 { pos.x += maxCoord }
                if pos.x > maxCoord { pos.x -= maxCoord }
                if pos.y < 0.0 { pos.y += maxCoord }
                if pos.y > maxCoord { pos.y -= maxCoord }
            }

            let cosScatter = simd_dot(rayDir, initialBeamDir)
            let hgGain = 0.45 + 0.55 * min(henyeyGreensteinPhase(cosTheta: cosScatter, anisotropyG: anisotropyG), 4.0)
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
            irradiance[row0 + x0] += weightedRGB * w00
            irradiance[row0 + x0 + 1] += weightedRGB * w10
            irradiance[row1 + x0] += weightedRGB * w01
            irradiance[row1 + x0 + 1] += weightedRGB * w11
        }

        return irradiance
    }
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
                    let strideStep = max(1, fullN / renderN)

                    var sampledPressure = [Float](repeating: 0.0, count: renderN * renderN)
                    for ry in 0..<renderN {
                        let sy = min(fullN - 1, ry * strideStep)
                        for rx in 0..<renderN {
                            let sx = min(fullN - 1, rx * strideStep)
                            sampledPressure[ry * renderN + rx] = tank.pressureCurr[sy * fullN + sx] * 6.5
                        }
                    }

                    let caustics = AcoustoOpticCausticsEngine.traceCausticsField(
                        pressureGrid: sampledPressure,
                        gridSize: renderN,
                        photonCount: photonCount
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

                            // Gamma-encode linear sRGB for display
                            let srgbR = Double(powf(min(max(mapped.x, 0.0), 1.0), 1.0 / 2.2))
                            let srgbG = Double(powf(min(max(mapped.y, 0.0), 1.0), 1.0 / 2.2))
                            let srgbB = Double(powf(min(max(mapped.z, 0.0), 1.0), 1.0 / 2.2))

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
            let strideStep = max(1, fullN / renderN)

            var sampledPressure = [Float](repeating: 0.0, count: renderN * renderN)
            let gain: Float = 5.5 + min(max(audioAmplitude, 0.0), 1.0) * 3.0
            for ry in 0..<renderN {
                let sy = min(fullN - 1, ry * strideStep)
                for rx in 0..<renderN {
                    let sx = min(fullN - 1, rx * strideStep)
                    sampledPressure[ry * renderN + rx] = waveTank.pressureCurr[sy * fullN + sx] * gain
                }
            }

            let caustics = AcoustoOpticCausticsEngine.traceCausticsField(
                pressureGrid: sampledPressure,
                gridSize: renderN,
                photonCount: photonCount
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

                    let srgbR = Double(powf(min(max(mapped.x, 0.0), 1.0), 1.0 / 2.2))
                    let srgbG = Double(powf(min(max(mapped.y, 0.0), 1.0), 1.0 / 2.2))
                    let srgbB = Double(powf(min(max(mapped.z, 0.0), 1.0), 1.0 / 2.2))

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
