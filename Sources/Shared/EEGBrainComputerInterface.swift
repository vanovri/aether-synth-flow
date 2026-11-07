// MARK: - FILE: EEGBrainComputerInterface.swift

import Foundation
#if canImport(CoreBluetooth)
import CoreBluetooth
#endif

// MARK: - 1. 4-Channel 256 Hz Cortical EEG Sample DTO

public struct EEGQuadSample: Codable, Sendable, Equatable {
    public let tp9: Float
    public let af7: Float
    public let af8: Float
    public let tp10: Float
    public let timestamp: TimeInterval

    public init(
        tp9: Float,
        af7: Float,
        af8: Float,
        tp10: Float,
        timestamp: TimeInterval
    ) {
        self.tp9 = tp9
        self.af7 = af7
        self.af8 = af8
        self.tp10 = tp10
        self.timestamp = timestamp
    }
}

// MARK: - 2. RK4 Jansen-Rit Cortical Column ODE + Theta-Gamma PAC + Ocular Blink Generator

public struct SyntheticCorticalEEGGenerator: Sendable {
    public var sampleRate: Double
    public var thalamicDriveHz: Double
    public var thetaFrequencyHz: Double
    public var gammaFrequencyHz: Double
    public var thetaGammaPACStrength: Float
    public var frontalAsymmetryBias: Float

    // 6-dimensional Jansen-Rit (1995) cortical column state vector [y0, y1, y2, y3, y4, y5]
    private var jrState: [Double]
    private var sampleIndex: Int = 0
    private var rngState: UInt64

    public init(
        sampleRate: Double = 256.0,
        thalamicDriveHz: Double = 190.0,
        thetaFrequencyHz: Double = 6.0,
        gammaFrequencyHz: Double = 40.0,
        thetaGammaPACStrength: Float = 0.72,
        frontalAsymmetryBias: Float = 0.15,
        seed: UInt64 = 0xAE74_3100_2026
    ) {
        self.sampleRate = max(64.0, sampleRate)
        self.thalamicDriveHz = thalamicDriveHz
        self.thetaFrequencyHz = thetaFrequencyHz
        self.gammaFrequencyHz = gammaFrequencyHz
        self.thetaGammaPACStrength = min(max(thetaGammaPACStrength, 0.0), 1.0)
        self.frontalAsymmetryBias = frontalAsymmetryBias
        self.jrState = [0.08, 12.5, 9.2, 0.0, 0.0, 0.0]
        self.rngState = seed == 0 ? 0xAE74_3100_2026 : seed
    }

    /// Advances the Jansen-Rit cortical mass via 4th-order Runge-Kutta (RK4) and emits one 4-channel EEG sample
    /// alongside the frontal EOG reference and uncontaminated cortical signal.
    public mutating func stepWithReference(
        injectBlinkAmplitude: Float = 0.0
    ) -> (sample: EEGQuadSample, eogReference: Float, cleanCortical: Float) {
        let dt = 1.0 / sampleRate
        let t = Double(sampleIndex) * dt
        sampleIndex += 1

        // Thalamic stochastic input p(t) into excitatory interneurons
        let drive = thalamicDriveHz + 38.0 * nextSymmetricNoise()

        // Exact 4th-order Runge-Kutta (RK4) step for Jansen-Rit ODEs
        let y = jrState
        let k1 = Self.jansenRitDerivatives(y: y, pDrive: drive)
        var y2 = [Double](repeating: 0.0, count: 6)
        for i in 0..<6 { y2[i] = y[i] + 0.5 * dt * k1[i] }

        let k2 = Self.jansenRitDerivatives(y: y2, pDrive: drive)
        var y3 = [Double](repeating: 0.0, count: 6)
        for i in 0..<6 { y3[i] = y[i] + 0.5 * dt * k2[i] }

        let k3 = Self.jansenRitDerivatives(y: y3, pDrive: drive)
        var y4 = [Double](repeating: 0.0, count: 6)
        for i in 0..<6 { y4[i] = y[i] + dt * k3[i] }

        let k4 = Self.jansenRitDerivatives(y: y4, pDrive: drive)
        for i in 0..<6 {
            jrState[i] = y[i] + (dt / 6.0) * (k1[i] + 2.0 * k2[i] + 2.0 * k3[i] + k4[i])
        }

        // Pyramidal postsynaptic potential v_pyr = y1 - y2 (~10 Hz Alpha cortical rhythm, scaled to uV)
        let pyramidalPotentialUV = Float((jrState[1] - jrState[2]) * 2.4)

        // Controllable Theta-Gamma phase-amplitude coupled (PAC) cortical rhythm
        let thetaPhase = 2.0 * Double.pi * thetaFrequencyHz * t
        let gammaPhase = 2.0 * Double.pi * gammaFrequencyHz * t
        let thetaWave = Float(9.5 * cos(thetaPhase))
        let pacEnvelope = 1.0 + thetaGammaPACStrength * Float(cos(thetaPhase))
        let gammaWave = Float(4.2 * sin(gammaPhase)) * pacEnvelope

        // Subtle quadratic harmonic phase-coupled component for bispectral physiological realism
        let f1 = 2.0 * Double.pi * 8.0 * t
        let f2 = 2.0 * Double.pi * 12.0 * t
        let quadraticCoupled = Float(2.0 * cos(f1) + 2.0 * cos(f2) + 1.8 * cos(f1 + f2))

        let cleanCortical = pyramidalPotentialUV + thetaWave + gammaWave + quadraticCoupled

        // Optional synthetic EOG frontal corneal-retinal blink pulse (~200ms envelope every 1.25s when active)
        var blinkPulse: Float = 0.0
        if abs(injectBlinkAmplitude) > 1e-5 {
            let periodSec = 1.25
            let localT = t.truncatingRemainder(dividingBy: periodSec)
            let center = 0.45
            let width = 0.055
            let z = (localT - center) / width
            let biphasic = exp(-0.5 * z * z) - 0.22 * exp(-0.5 * pow((localT - (center + 0.09)) / 0.07, 2.0))
            blinkPulse = injectBlinkAmplitude * Float(biphasic)
        }

        let leftScale = 1.0 - 0.5 * frontalAsymmetryBias
        let rightScale = 1.0 + 0.5 * frontalAsymmetryBias

        let tp9 = cleanCortical * 0.92 + 0.28 * blinkPulse
        let af7 = cleanCortical * leftScale + 0.85 * blinkPulse
        let af8 = cleanCortical * rightScale + 0.82 * blinkPulse
        let tp10 = cleanCortical * 0.95 + 0.26 * blinkPulse

        let quad = EEGQuadSample(
            tp9: tp9,
            af7: af7,
            af8: af8,
            tp10: tp10,
            timestamp: t
        )
        return (quad, blinkPulse, cleanCortical)
    }

    public mutating func nextSample(injectBlinkAmplitude: Float = 0.0) -> EEGQuadSample {
        stepWithReference(injectBlinkAmplitude: injectBlinkAmplitude).sample
    }

    public mutating func generateSamples(
        count: Int,
        injectBlinkAmplitude: Float = 0.0
    ) -> [EEGQuadSample] {
        guard count > 0 else { return [] }
        var out: [EEGQuadSample] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            out.append(nextSample(injectBlinkAmplitude: injectBlinkAmplitude))
        }
        return out
    }

    /// Canonical Jansen-Rit (1995) neural mass cortical column differential equations.
    private static func jansenRitDerivatives(y: [Double], pDrive: Double) -> [Double] {
        let A = 3.25
        let B = 22.0
        let a = 100.0
        let b = 50.0
        let C = 135.0
        let c1 = C
        let c2 = 0.8 * C
        let c3 = 0.25 * C
        let c4 = 0.25 * C

        @inline(__always)
        func sigmoidFiring(_ v: Double) -> Double {
            let e0 = 2.5
            let v0 = 6.0
            let r = 0.56
            let arg = min(max(r * (v0 - v), -40.0), 40.0)
            return (2.0 * e0) / (1.0 + exp(arg))
        }

        let dy0 = y[3]
        let dy1 = y[4]
        let dy2 = y[5]
        let dy3 = A * a * sigmoidFiring(y[1] - y[2]) - 2.0 * a * y[3] - a * a * y[0]
        let dy4 = A * a * (pDrive + c2 * sigmoidFiring(c1 * y[0])) - 2.0 * a * y[4] - a * a * y[1]
        let dy5 = B * b * (c4 * sigmoidFiring(c3 * y[0])) - 2.0 * b * y[5] - b * b * y[2]
        return [dy0, dy1, dy2, dy3, dy4, dy5]
    }

    @inline(__always)
    private mutating func nextSymmetricNoise() -> Double {
        rngState &+= 0x9E37_79B9_7F4A_7C15
        var z = rngState
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z = z ^ (z >> 31)
        return Double(z >> 11) * (1.0 / 9_007_199_254_740_992.0) * 2.0 - 1.0
    }
}

// MARK: - 3. 0.5 Hz Butterworth HPF + 50 Hz Notch + 4-Tap RLS Adaptive Ocular Blink Canceler

public struct EEGArtifactFilterBank: Sendable {
    public static let tapCount: Int = 4

    public let sampleRate: Double
    public let forgettingFactorLambda: Float

    private struct BiquadSection: Sendable {
        let b0: Double
        let b1: Double
        let b2: Double
        let a1: Double
        let a2: Double
        var z1: Double = 0.0
        var z2: Double = 0.0

        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }

        static func butterworthHighPass(cutoffHz: Double, sampleRate: Double) -> BiquadSection {
            let w0 = 2.0 * Double.pi * cutoffHz / sampleRate
            let cosW0 = cos(w0)
            let alpha = sin(w0) / sqrt(2.0)
            let a0 = 1.0 + alpha
            return BiquadSection(
                b0: ((1.0 + cosW0) * 0.5) / a0,
                b1: -(1.0 + cosW0) / a0,
                b2: ((1.0 + cosW0) * 0.5) / a0,
                a1: (-2.0 * cosW0) / a0,
                a2: (1.0 - alpha) / a0
            )
        }

        static func mainsNotch(notchHz: Double, qFactor: Double, sampleRate: Double) -> BiquadSection {
            let w0 = 2.0 * Double.pi * notchHz / sampleRate
            let cosW0 = cos(w0)
            let alpha = sin(w0) / (2.0 * qFactor)
            let a0 = 1.0 + alpha
            return BiquadSection(
                b0: 1.0 / a0,
                b1: (-2.0 * cosW0) / a0,
                b2: 1.0 / a0,
                a1: (-2.0 * cosW0) / a0,
                a2: (1.0 - alpha) / a0
            )
        }
    }

    private var eegHighPass: BiquadSection
    private var eegNotch50: BiquadSection
    private var refHighPass: BiquadSection
    private var refNotch50: BiquadSection

    // 4-tap RLS state
    public private(set) var rlsWeights: [Double]
    private var rlsDelayLine: [Double]
    private var rlsCovarianceP: [[Double]]

    public init(
        sampleRate: Double = 256.0,
        lambda: Float = 0.992,
        initialInverseDelta: Double = 25.0
    ) {
        let fs = max(128.0, sampleRate)
        self.sampleRate = fs
        self.forgettingFactorLambda = min(max(lambda, 0.90), 0.9999)

        self.eegHighPass = .butterworthHighPass(cutoffHz: 0.5, sampleRate: fs)
        self.eegNotch50 = .mainsNotch(notchHz: 50.0, qFactor: 30.0, sampleRate: fs)
        self.refHighPass = .butterworthHighPass(cutoffHz: 0.5, sampleRate: fs)
        self.refNotch50 = .mainsNotch(notchHz: 50.0, qFactor: 30.0, sampleRate: fs)

        self.rlsWeights = [Double](repeating: 0.0, count: Self.tapCount)
        self.rlsDelayLine = [Double](repeating: 0.0, count: Self.tapCount)
        self.rlsCovarianceP = (0..<Self.tapCount).map { r in
            (0..<Self.tapCount).map { c in r == c ? initialInverseDelta : 0.0 }
        }
    }

    /// Processes a single cortical EEG sample through matched 0.5 Hz Butterworth HPF + 50 Hz Notch
    /// and 4-tap RLS adaptive ocular interference cancellation (`> 18 dB` blink suppression).
    public mutating func processSample(rawEEG: Float, eogReference: Float) -> Float {
        let dFiltered = eegNotch50.process(eegHighPass.process(Double(rawEEG)))
        let rFiltered = refNotch50.process(refHighPass.process(Double(eogReference)))

        // Shift 4-tap reference delay line
        for k in stride(from: Self.tapCount - 1, through: 1, by: -1) {
            rlsDelayLine[k] = rlsDelayLine[k - 1]
        }
        rlsDelayLine[0] = rFiltered

        let lam = Double(forgettingFactorLambda)

        // pi = P * u
        var piVec = [Double](repeating: 0.0, count: Self.tapCount)
        for i in 0..<Self.tapCount {
            var acc = 0.0
            for j in 0..<Self.tapCount {
                acc += rlsCovarianceP[i][j] * rlsDelayLine[j]
            }
            piVec[i] = acc
        }

        // Gain vector k = pi / (lambda + u^T * pi)
        var uDotPi = 0.0
        for i in 0..<Self.tapCount {
            uDotPi += rlsDelayLine[i] * piVec[i]
        }
        let denom = max(1e-12, lam + uDotPi)
        var gainK = [Double](repeating: 0.0, count: Self.tapCount)
        for i in 0..<Self.tapCount {
            gainK[i] = piVec[i] / denom
        }

        // A priori error & RLS weight update
        var priorPred = 0.0
        for i in 0..<Self.tapCount {
            priorPred += rlsWeights[i] * rlsDelayLine[i]
        }
        let priorError = dFiltered - priorPred

        for i in 0..<Self.tapCount {
            rlsWeights[i] += gainK[i] * priorError
        }

        // Symmetrized Riccati covariance update: P <- (P - k * pi^T) / lambda
        let invLam = 1.0 / lam
        var nextP = rlsCovarianceP
        for i in 0..<Self.tapCount {
            for j in 0..<Self.tapCount {
                nextP[i][j] = (rlsCovarianceP[i][j] - gainK[i] * piVec[j]) * invLam
            }
        }
        for i in 0..<Self.tapCount {
            for j in (i + 1)..<Self.tapCount {
                let sym = 0.5 * (nextP[i][j] + nextP[j][i])
                nextP[i][j] = sym
                nextP[j][i] = sym
            }
        }
        rlsCovarianceP = nextP

        // A posteriori cleaned cortical EEG output
        var postPred = 0.0
        for i in 0..<Self.tapCount {
            postPred += rlsWeights[i] * rlsDelayLine[i]
        }
        return Float(dFiltered - postPred)
    }
}

// MARK: - 4. Cortical Spectral, Bispectral & Phase-Amplitude Coupling Metrics

public struct CorticalSpectralMetrics: Codable, Sendable, Equatable {
    public let deltaPower: Float
    public let thetaPower: Float
    public let alphaPower: Float
    public let betaPower: Float
    public let gammaPower: Float
    public let frontalAlphaAsymmetry: Float
    public let individualAlphaFrequencyHz: Float
    public let bispectralIndex: Float
    public let maxBicoherence: Float
    public let bicoherenceTriangle: [[Float]]
    public let thetaGammaPACModulationIndex: Float
    public let pacPhaseAmplitudeHistogram: [Float]

    public init(
        deltaPower: Float,
        thetaPower: Float,
        alphaPower: Float,
        betaPower: Float,
        gammaPower: Float,
        frontalAlphaAsymmetry: Float,
        individualAlphaFrequencyHz: Float,
        bispectralIndex: Float,
        maxBicoherence: Float,
        bicoherenceTriangle: [[Float]],
        thetaGammaPACModulationIndex: Float,
        pacPhaseAmplitudeHistogram: [Float]
    ) {
        self.deltaPower = max(0.0, deltaPower)
        self.thetaPower = max(0.0, thetaPower)
        self.alphaPower = max(0.0, alphaPower)
        self.betaPower = max(0.0, betaPower)
        self.gammaPower = max(0.0, gammaPower)
        self.frontalAlphaAsymmetry = frontalAlphaAsymmetry
        self.individualAlphaFrequencyHz = individualAlphaFrequencyHz
        self.bispectralIndex = min(max(bispectralIndex, 0.0), 100.0)
        self.maxBicoherence = min(max(maxBicoherence, 0.0), 1.0)
        self.bicoherenceTriangle = bicoherenceTriangle
        self.thetaGammaPACModulationIndex = max(0.0, thetaGammaPACModulationIndex)
        self.pacPhaseAmplitudeHistogram = pacPhaseAmplitudeHistogram
    }
}

// MARK: - 5. Welch Band-Power, IAF, Squared Bicoherence, BIS & Tort Theta-Gamma PAC Analyzer

public enum CorticalSpectralAnalyzer: Sendable {
    public static let bicoherenceGridSize: Int = 16
    public static let pacPhaseBinCount: Int = 18

    public static func analyze(
        channelSamples: [Float],
        frontalLeft: [Float]? = nil,
        frontalRight: [Float]? = nil,
        sampleRate: Double = 256.0
    ) -> CorticalSpectralMetrics {
        let fs = max(64.0, sampleRate)
        let cleaned = channelSamples.map { $0.isFinite ? Double($0) : 0.0 }

        guard cleaned.count >= 32 else {
            let uniformHist = [Float](repeating: 1.0 / Float(pacPhaseBinCount), count: pacPhaseBinCount)
            let zeroGrid = [[Float]](repeating: [Float](repeating: 0.0, count: bicoherenceGridSize), count: bicoherenceGridSize)
            return CorticalSpectralMetrics(
                deltaPower: 0,
                thetaPower: 0,
                alphaPower: 0,
                betaPower: 0,
                gammaPower: 0,
                frontalAlphaAsymmetry: 0,
                individualAlphaFrequencyHz: 10.0,
                bispectralIndex: 85.0,
                maxBicoherence: 0.0,
                bicoherenceTriangle: zeroGrid,
                thetaGammaPACModulationIndex: 0.0,
                pacPhaseAmplitudeHistogram: uniformHist
            )
        }

        // 1. Welch Hann-windowed PSD & Canonical EEG Band Powers
        let psd = computeWelchPSD(signal: cleaned, sampleRate: fs)
        let delta = Float(integrateBand(psd: psd, fLow: 0.5, fHigh: 4.0))
        let theta = Float(integrateBand(psd: psd, fLow: 4.0, fHigh: 8.0))
        let alpha = Float(integrateBand(psd: psd, fLow: 8.0, fHigh: 13.0))
        let beta = Float(integrateBand(psd: psd, fLow: 13.0, fHigh: 30.0))
        let gamma = Float(integrateBand(psd: psd, fLow: 30.0, fHigh: min(48.0, fs * 0.48)))

        // 2. Frontal Alpha Asymmetry: FAA = ln(Alpha_Right) - ln(Alpha_Left)
        let faa: Float
        if let left = frontalLeft, let right = frontalRight, left.count >= 32, right.count >= 32 {
            let psdL = computeWelchPSD(signal: left.map(Double.init), sampleRate: fs)
            let psdR = computeWelchPSD(signal: right.map(Double.init), sampleRate: fs)
            let alphaL = max(1e-9, integrateBand(psd: psdL, fLow: 8.0, fHigh: 13.0))
            let alphaR = max(1e-9, integrateBand(psd: psdR, fLow: 8.0, fHigh: 13.0))
            faa = Float(log(alphaR) - log(alphaL))
        } else {
            faa = 0.0
        }

        // 3. Parabolic-Peak Individual Alpha Frequency (7.5 ... 13.0 Hz)
        let iafHz = Float(estimateParabolicIAF(psd: psd, minHz: 7.5, maxHz: 13.0))

        // 4. Multi-segment Kim & Powers Squared Bicoherence (16x16 grid) + Bispectral Index (0...100)
        let bicoherenceResult = computeSquaredBicoherenceAndBIS(signal: cleaned, psd: psd, sampleRate: fs)

        // 5. Hilbert Bandpass Theta (4-8 Hz) Phase vs Gamma (35-45 Hz) Envelope Tort Modulation Index
        let pacResult = computeTortThetaGammaPAC(signal: cleaned, sampleRate: fs)

        return CorticalSpectralMetrics(
            deltaPower: delta,
            thetaPower: theta,
            alphaPower: alpha,
            betaPower: beta,
            gammaPower: gamma,
            frontalAlphaAsymmetry: faa,
            individualAlphaFrequencyHz: iafHz,
            bispectralIndex: bicoherenceResult.bis,
            maxBicoherence: bicoherenceResult.maxBicoherence,
            bicoherenceTriangle: bicoherenceResult.grid,
            thetaGammaPACModulationIndex: pacResult.modulationIndex,
            pacPhaseAmplitudeHistogram: pacResult.histogram
        )
    }

    // MARK: - Internal Radix-2 Complex FFT & Spectral Kernels

    private struct Complex64 {
        var re: Double
        var im: Double

        @inline(__always)
        var magSq: Double { re * re + im * im }

        @inline(__always)
        var conj: Complex64 { Complex64(re: re, im: -im) }

        @inline(__always)
        static func + (lhs: Complex64, rhs: Complex64) -> Complex64 {
            Complex64(re: lhs.re + rhs.re, im: lhs.im + rhs.im)
        }

        @inline(__always)
        static func - (lhs: Complex64, rhs: Complex64) -> Complex64 {
            Complex64(re: lhs.re - rhs.re, im: lhs.im - rhs.im)
        }

        @inline(__always)
        static func * (lhs: Complex64, rhs: Complex64) -> Complex64 {
            Complex64(
                re: lhs.re * rhs.re - lhs.im * rhs.im,
                im: lhs.re * rhs.im + lhs.im * rhs.re
            )
        }
    }

    private static func nextPowerOfTwo(_ n: Int) -> Int {
        var p = 2
        while p < n { p <<= 1 }
        return p
    }

    private static func radix2FFT(_ buf: inout [Complex64], inverse: Bool) {
        let n = buf.count
        guard n >= 2 && (n & (n - 1)) == 0 else { return }

        var j = 0
        for i in 1..<n {
            var bit = n >> 1
            while (j & bit) != 0 {
                j ^= bit
                bit >>= 1
            }
            j ^= bit
            if i < j {
                buf.swapAt(i, j)
            }
        }

        var len = 2
        let sign = inverse ? 1.0 : -1.0
        while len <= n {
            let half = len >> 1
            let theta = sign * 2.0 * Double.pi / Double(len)
            let wStep = Complex64(re: cos(theta), im: sin(theta))
            for start in stride(from: 0, to: n, by: len) {
                var w = Complex64(re: 1.0, im: 0.0)
                for k in 0..<half {
                    let u = buf[start + k]
                    let v = buf[start + k + half] * w
                    buf[start + k] = u + v
                    buf[start + k + half] = u - v
                    w = w * wStep
                }
            }
            len <<= 1
        }

        if inverse {
            let invN = 1.0 / Double(n)
            for idx in 0..<n {
                buf[idx].re *= invN
                buf[idx].im *= invN
            }
        }
    }

    private struct WelchPSD {
        let freqsHz: [Double]
        let powers: [Double]
    }

    private static func computeWelchPSD(signal: [Double], sampleRate: Double) -> WelchPSD {
        let totalN = signal.count
        let segLen = min(256, nextPowerOfTwo(max(64, totalN / 2)))
        let fftN = max(256, nextPowerOfTwo(segLen))
        let actualSeg = min(totalN, segLen)
        let hop = max(8, actualSeg / 2)

        let mean = signal.reduce(0.0, +) / Double(totalN)
        let centered = signal.map { $0 - mean }

        var window = [Double](repeating: 0.0, count: actualSeg)
        var winEnergy = 0.0
        for i in 0..<actualSeg {
            let w = 0.5 * (1.0 - cos(2.0 * Double.pi * Double(i) / Double(max(1, actualSeg - 1))))
            window[i] = w
            winEnergy += w * w
        }

        let halfBins = fftN / 2 + 1
        var accumPower = [Double](repeating: 0.0, count: halfBins)
        var segCount = 0

        var offset = 0
        while offset + actualSeg <= totalN || segCount == 0 {
            let safeOffset = min(offset, max(0, totalN - actualSeg))
            var fftBuf = [Complex64](repeating: Complex64(re: 0, im: 0), count: fftN)
            for i in 0..<actualSeg {
                fftBuf[i].re = centered[safeOffset + i] * window[i]
            }
            radix2FFT(&fftBuf, inverse: false)

            let norm = 1.0 / max(1e-12, sampleRate * winEnergy)
            for k in 0..<halfBins {
                let scale = (k == 0 || k == fftN / 2) ? 1.0 : 2.0
                accumPower[k] += scale * fftBuf[k].magSq * norm
            }
            segCount += 1
            if offset + actualSeg >= totalN { break }
            offset += hop
        }

        let invSeg = 1.0 / Double(max(1, segCount))
        let df = sampleRate / Double(fftN)
        let freqs = (0..<halfBins).map { Double($0) * df }
        let powers = accumPower.map { $0 * invSeg }
        return WelchPSD(freqsHz: freqs, powers: powers)
    }

    private static func integrateBand(psd: WelchPSD, fLow: Double, fHigh: Double) -> Double {
        guard psd.freqsHz.count >= 2, fHigh > fLow else { return 0.0 }
        var area = 0.0
        for i in 0..<(psd.freqsHz.count - 1) {
            let f0 = psd.freqsHz[i]
            let f1 = psd.freqsHz[i + 1]
            let mid = 0.5 * (f0 + f1)
            if mid >= fLow && mid <= fHigh {
                area += 0.5 * (psd.powers[i] + psd.powers[i + 1]) * (f1 - f0)
            }
        }
        return max(0.0, area)
    }

    private static func estimateParabolicIAF(psd: WelchPSD, minHz: Double, maxHz: Double) -> Double {
        var bestIdx: Int?
        var bestPower = -1.0
        for i in psd.freqsHz.indices where psd.freqsHz[i] >= minHz && psd.freqsHz[i] <= maxHz {
            if psd.powers[i] > bestPower {
                bestPower = psd.powers[i]
                bestIdx = i
            }
        }
        guard let idx = bestIdx else { return 10.0 }
        guard idx > 0 && idx + 1 < psd.freqsHz.count else {
            return psd.freqsHz[idx]
        }

        let yL = log(max(1e-12, psd.powers[idx - 1]))
        let yC = log(max(1e-12, psd.powers[idx]))
        let yR = log(max(1e-12, psd.powers[idx + 1]))
        let denom = yL - 2.0 * yC + yR
        let df = psd.freqsHz[idx + 1] - psd.freqsHz[idx]
        if abs(denom) > 1e-9 {
            let deltaBin = min(max(0.5 * (yL - yR) / denom, -0.5), 0.5)
            return min(max(psd.freqsHz[idx] + deltaBin * df, minHz), maxHz)
        }
        return psd.freqsHz[idx]
    }

    private static func computeSquaredBicoherenceAndBIS(
        signal: [Double],
        psd: WelchPSD,
        sampleRate: Double
    ) -> (grid: [[Float]], maxBicoherence: Float, bis: Float) {
        let G = bicoherenceGridSize
        let fftN = 64
        let segLen = min(signal.count, 64)
        let hop = max(4, segLen / 4)

        let mean = signal.reduce(0.0, +) / Double(signal.count)
        let centered = signal.map { $0 - mean }

        let hann = (0..<segLen).map { i in
            0.5 * (1.0 - cos(2.0 * Double.pi * Double(i) / Double(max(1, segLen - 1))))
        }

        var segmentSpectra: [[Complex64]] = []
        var offset = 0
        while offset + segLen <= centered.count || segmentSpectra.isEmpty {
            let safeOffset = min(offset, max(0, centered.count - segLen))
            var buf = [Complex64](repeating: Complex64(re: 0, im: 0), count: fftN)
            for i in 0..<segLen {
                buf[i].re = centered[safeOffset + i] * hann[i]
            }
            radix2FFT(&buf, inverse: false)
            segmentSpectra.append(buf)
            if offset + segLen >= centered.count { break }
            offset += hop
        }

        // If very short signal produced < 4 windows, synthesize circularly shifted phase-preserving windows
        while segmentSpectra.count < 6 {
            let shift = (segmentSpectra.count * 7) % max(1, segLen)
            var buf = [Complex64](repeating: Complex64(re: 0, im: 0), count: fftN)
            for i in 0..<segLen {
                buf[i].re = centered[(i + shift) % centered.count] * hann[i]
            }
            radix2FFT(&buf, inverse: false)
            segmentSpectra.append(buf)
        }

        var grid = [[Float]](repeating: [Float](repeating: 0.0, count: G), count: G)
        var maxBic: Float = 0.0
        var highFreqBispecSum = 0.0
        var allFreqBispecSum = 0.0
        let df = sampleRate / Double(fftN)

        for r in 0..<G {
            let k1 = r + 1
            for c in 0...r {
                let k2 = c + 1
                let k3 = k1 + k2
                guard k3 <= fftN / 2 else { continue }

                var bispecAccum = Complex64(re: 0.0, im: 0.0)
                var prodMagSqAccum = 0.0
                var sumFreqMagSqAccum = 0.0

                for spec in segmentSpectra {
                    let x12 = spec[k1] * spec[k2]
                    let x3 = spec[k3]
                    bispecAccum = bispecAccum + (x12 * x3.conj)
                    prodMagSqAccum += x12.magSq
                    sumFreqMagSqAccum += x3.magSq
                }

                let denom = prodMagSqAccum * sumFreqMagSqAccum
                let bicSq = denom > 1e-20 ? min(max(bispecAccum.magSq / denom, 0.0), 1.0) : 0.0
                let bicFloat = Float(bicSq)
                grid[r][c] = bicFloat
                grid[c][r] = bicFloat
                if bicFloat > maxBic {
                    maxBic = bicFloat
                }

                let bispecMag = sqrt(bispecAccum.magSq)
                let fSumHz = Double(k3) * df
                allFreqBispecSum += bispecMag
                if fSumHz >= 36.0 {
                    highFreqBispecSum += bispecMag
                }
            }
        }

        // Clinical Bispectral Index (BIS 0...100) combining BetaRatio & SynchFastSlow
        let pHigh = max(1e-9, integrateBand(psd: psd, fLow: 30.0, fHigh: min(47.0, sampleRate * 0.48)))
        let pMid = max(1e-9, integrateBand(psd: psd, fLow: 11.0, fHigh: 20.0))
        let pDeltaTheta = max(1e-9, integrateBand(psd: psd, fLow: 0.5, fHigh: 8.0))
        let betaRatio = log10(pHigh / pMid)
        let synchFastSlow = log10(max(1e-9, highFreqBispecSum) / max(1e-9, allFreqBispecSum))
        let slowDominance = pDeltaTheta / max(1e-9, pDeltaTheta + pMid + pHigh)

        let rawBIS = 88.0 + 14.0 * betaRatio + 8.0 * synchFastSlow - 42.0 * slowDominance
        let clampedBIS = Float(min(max(rawBIS, 0.0), 100.0))

        return (grid, maxBic, clampedBIS)
    }

    /// Computes Tort et al. (2010) KL-divergence Modulation Index (`D_KL(P || U) / ln(18)`)
    /// between Theta (4-8 Hz) analytic phase and Gamma (35-45 Hz) analytic amplitude envelope.
    private static func computeTortThetaGammaPAC(
        signal: [Double],
        sampleRate: Double
    ) -> (modulationIndex: Float, histogram: [Float]) {
        let n = signal.count
        let fftN = nextPowerOfTwo(max(64, n))
        let mean = signal.reduce(0.0, +) / Double(n)

        var spectrum = [Complex64](repeating: Complex64(re: 0, im: 0), count: fftN)
        for i in 0..<n {
            spectrum[i].re = signal[i] - mean
        }
        radix2FFT(&spectrum, inverse: false)

        // Analytic Hilbert bandpass helper: retains positive frequencies in [fLow, fHigh] * 2.0, zeros negative & DC
        func analyticBandpass(fLow: Double, fHigh: Double) -> [Complex64] {
            var band = [Complex64](repeating: Complex64(re: 0, im: 0), count: fftN)
            let df = sampleRate / Double(fftN)
            let half = fftN / 2
            for k in 1..<half {
                let f = Double(k) * df
                if f >= fLow && f <= fHigh {
                    band[k] = Complex64(re: spectrum[k].re * 2.0, im: spectrum[k].im * 2.0)
                }
            }
            radix2FFT(&band, inverse: true)
            return band
        }

        let thetaAnalytic = analyticBandpass(fLow: 4.0, fHigh: 8.0)
        let gammaHigh = min(45.0, sampleRate * 0.48)
        let gammaLow = min(35.0, gammaHigh - 4.0)
        let gammaAnalytic = analyticBandpass(fLow: gammaLow, fHigh: gammaHigh)

        let bins = pacPhaseBinCount
        var ampSum = [Double](repeating: 0.0, count: bins)
        var binCounts = [Int](repeating: 0, count: bins)

        // Trim 5% edge transients from analytic circular convolution
        let margin = max(1, n / 20)
        let startIdx = min(margin, n - 1)
        let endIdx = max(startIdx + 1, n - margin)

        for i in startIdx..<endIdx {
            let phase = atan2(thetaAnalytic[i].im, thetaAnalytic[i].re) // [-pi, pi]
            let amp = hypot(gammaAnalytic[i].re, gammaAnalytic[i].im)
            let normalized = (phase + Double.pi) / (2.0 * Double.pi)
            let bin = min(max(Int(floor(normalized * Double(bins))), 0), bins - 1)
            ampSum[bin] += amp
            binCounts[bin] += 1
        }

        let overallMeanAmp = max(1e-9, ampSum.reduce(0.0, +) / Double(max(1, endIdx - startIdx)))
        var meanPerBin = [Double](repeating: 0.0, count: bins)
        for b in 0..<bins {
            meanPerBin[b] = binCounts[b] > 0 ? (ampSum[b] / Double(binCounts[b])) : (overallMeanAmp * 0.1)
            meanPerBin[b] = max(1e-12, meanPerBin[b])
        }

        let totalMeanAmp = meanPerBin.reduce(0.0, +)
        let probs = meanPerBin.map { $0 / totalMeanAmp }

        // Shannon entropy H(P) = -sum p_j ln(p_j), D_KL(P || U) = ln(18) - H(P), MI = D_KL / ln(18)
        var shannonH = 0.0
        for p in probs where p > 0.0 {
            shannonH -= p * log(p)
        }
        let logBins = log(Double(bins))
        let klDiv = max(0.0, logBins - shannonH)
        let mi = Float(min(max(klDiv / logBins, 0.0), 1.0))

        // Normalize Float histogram strictly to sum == 1.0
        var floatHist = probs.map(Float.init)
        let floatSum = max(1e-9, floatHist.reduce(0.0, +))
        for i in 0..<bins {
            floatHist[i] /= floatSum
        }

        return (mi, floatHist)
    }
}

// MARK: - 6. CoreBluetooth 4-Channel 256 Hz GATT Hardware Subscriber

#if canImport(CoreBluetooth)
public final class EEGBLEHardwareClient: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    public static let eegServiceUUID = CBUUID(string: "0000FE8D-0000-1000-8000-00805F9B34FB")
    public static let quadStreamCharacteristicUUID = CBUUID(string: "273E0003-4C4D-454D-96BE-F03BAC821358")

    private let lock = NSLock()
    private var centralManager: CBCentralManager?
    private var connectedPeripheral: CBPeripheral?
    private var onSampleHandler: (@Sendable (EEGQuadSample) -> Void)?
    private var sampleCounter: UInt64 = 0
    public private(set) var isConnected: Bool = false

    public init(onSample: (@Sendable (EEGQuadSample) -> Void)? = nil) {
        self.onSampleHandler = onSample
        super.init()
    }

    public func setSampleCallback(_ handler: (@Sendable (EEGQuadSample) -> Void)?) {
        lock.lock()
        onSampleHandler = handler
        lock.unlock()
    }

    public func startScanning() {
        lock.lock()
        defer { lock.unlock() }
        if centralManager == nil {
            centralManager = CBCentralManager(delegate: self, queue: nil)
        } else if centralManager?.state == .poweredOn {
            centralManager?.scanForPeripherals(withServices: [Self.eegServiceUUID], options: nil)
        }
    }

    public func stop() {
        lock.lock()
        let manager = centralManager
        let peripheral = connectedPeripheral
        connectedPeripheral = nil
        isConnected = false
        lock.unlock()

        manager?.stopScan()
        if let peripheral {
            manager?.cancelPeripheralConnection(peripheral)
        }
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            central.scanForPeripherals(withServices: [Self.eegServiceUUID], options: nil)
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        _ = advertisementData
        _ = RSSI
        lock.lock()
        connectedPeripheral = peripheral
        lock.unlock()
        peripheral.delegate = self
        central.stopScan()
        central.connect(peripheral, options: nil)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        _ = central
        lock.lock()
        isConnected = true
        lock.unlock()
        peripheral.discoverServices([Self.eegServiceUUID])
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: (any Error)?
    ) {
        _ = peripheral
        _ = error
        lock.lock()
        isConnected = false
        connectedPeripheral = nil
        lock.unlock()
        if central.state == .poweredOn {
            central.scanForPeripherals(withServices: [Self.eegServiceUUID], options: nil)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        guard error == nil, let services = peripheral.services else { return }
        for service in services where service.uuid == Self.eegServiceUUID {
            peripheral.discoverCharacteristics([Self.quadStreamCharacteristicUUID], for: service)
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: (any Error)?
    ) {
        guard error == nil, let characteristics = service.characteristics else { return }
        for characteristic in characteristics where characteristic.uuid == Self.quadStreamCharacteristicUUID {
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        _ = peripheral
        guard error == nil, let payload = characteristic.value else { return }
        guard let decoded = parseGATTQuadPayload(payload) else { return }

        lock.lock()
        let callback = onSampleHandler
        lock.unlock()
        callback?(decoded)
    }

    /// Decodes either 16-byte IEEE-754 Float32x4 `[tp9, af7, af8, tp10]` or 8-byte Int16x4 microvolt BLE GATT packets.
    public func parseGATTQuadPayload(_ data: Data) -> EEGQuadSample? {
        lock.lock()
        let idx = sampleCounter
        sampleCounter &+= 1
        lock.unlock()
        let timestamp = Double(idx) / 256.0

        if data.count >= 16 {
            let bytes = [UInt8](data.prefix(16))
            func readFloatLE(_ offset: Int) -> Float {
                let bits = UInt32(bytes[offset])
                    | (UInt32(bytes[offset + 1]) << 8)
                    | (UInt32(bytes[offset + 2]) << 16)
                    | (UInt32(bytes[offset + 3]) << 24)
                return Float(bitPattern: bits)
            }
            return EEGQuadSample(
                tp9: readFloatLE(0),
                af7: readFloatLE(4),
                af8: readFloatLE(8),
                tp10: readFloatLE(12),
                timestamp: timestamp
            )
        } else if data.count >= 8 {
            let bytes = [UInt8](data.prefix(8))
            func readMicrovoltsInt16LE(_ offset: Int) -> Float {
                let raw = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
                let signed = Int16(bitPattern: raw)
                return Float(signed) * 0.1
            }
            return EEGQuadSample(
                tp9: readMicrovoltsInt16LE(0),
                af7: readMicrovoltsInt16LE(2),
                af8: readMicrovoltsInt16LE(4),
                tp10: readMicrovoltsInt16LE(6),
                timestamp: timestamp
            )
        }
        return nil
    }
}
#endif
