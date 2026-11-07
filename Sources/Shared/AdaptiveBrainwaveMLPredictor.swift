// MARK: - FILE: AdaptiveBrainwaveMLPredictor.swift

import Foundation
import simd
#if canImport(CoreML)
import CoreML
#endif

// MARK: - 1. 12D Normalized Brainwave Feature Vector & CoreML MultiArray Bridge

public struct BrainwaveFeatureVector: Codable, Sendable, Equatable {
    public static let featureCount: Int = 12

    public let hrBPM: Float
    public let rmssd: Float
    public let sdnn: Float
    public let lfHfRatio: Float
    public let poincareRatio: Float
    public let baevskyStress: Float
    public let respiratoryRate: Float
    public let circadianSin: Float
    public let circadianCos: Float
    public let priorFocusQuality: Float
    public let sessionProgress: Float
    public let currentBeatHz: Float

    public init(
        hrBPM: Float,
        rmssd: Float,
        sdnn: Float,
        lfHfRatio: Float,
        poincareRatio: Float,
        baevskyStress: Float,
        respiratoryRate: Float,
        circadianSin: Float,
        circadianCos: Float,
        priorFocusQuality: Float,
        sessionProgress: Float,
        currentBeatHz: Float
    ) {
        self.hrBPM = min(max(hrBPM, 0.0), 1.0)
        self.rmssd = min(max(rmssd, 0.0), 1.0)
        self.sdnn = min(max(sdnn, 0.0), 1.0)
        self.lfHfRatio = min(max(lfHfRatio, 0.0), 1.0)
        self.poincareRatio = min(max(poincareRatio, 0.0), 1.0)
        self.baevskyStress = min(max(baevskyStress, 0.0), 1.0)
        self.respiratoryRate = min(max(respiratoryRate, 0.0), 1.0)
        self.circadianSin = min(max(circadianSin, -1.0), 1.0)
        self.circadianCos = min(max(circadianCos, -1.0), 1.0)
        self.priorFocusQuality = min(max(priorFocusQuality, 0.0), 1.0)
        self.sessionProgress = min(max(sessionProgress, 0.0), 1.0)
        self.currentBeatHz = min(max(currentBeatHz, 0.0), 1.0)
    }

    public init(
        metrics: HRVAnalysisMetricsDTO,
        respiratoryRateBrPM: Double = 12.0,
        referenceDate: Date = .now,
        priorFocusQuality: Float = 0.75,
        sessionProgress: Float = 0.50,
        currentBeatHz: Float = 10.0,
        calendar: Calendar = .current
    ) {
        let comps = calendar.dateComponents([.hour, .minute], from: referenceDate)
        let fractionalHour = Double(comps.hour ?? 12) + Double(comps.minute ?? 0) / 60.0
        let angle = (2.0 * Double.pi * fractionalHour) / 24.0
        let sdRatio = metrics.poincareSD2Ms > 1e-6 ? (metrics.poincareSD1Ms / metrics.poincareSD2Ms) : 0.5

        self.init(
            hrBPM: Float((metrics.heartRateBPM - 45.0) / 95.0),
            rmssd: Float(metrics.rmssdMs / 120.0),
            sdnn: Float(metrics.sdnnMs / 140.0),
            lfHfRatio: Float(metrics.lfHfRatio / 6.0),
            poincareRatio: Float(sdRatio / 1.5),
            baevskyStress: Float(metrics.baevskyStressIndex / 600.0),
            respiratoryRate: Float((respiratoryRateBrPM - 4.0) / 20.0),
            circadianSin: Float(sin(angle)),
            circadianCos: Float(cos(angle)),
            priorFocusQuality: priorFocusQuality,
            sessionProgress: sessionProgress,
            currentBeatHz: (currentBeatHz - 1.5) / (42.0 - 1.5)
        )
    }

    public func toFloatArray() -> [Float] {
        [
            hrBPM,
            rmssd,
            sdnn,
            lfHfRatio,
            poincareRatio,
            baevskyStress,
            respiratoryRate,
            circadianSin,
            circadianCos,
            priorFocusQuality,
            sessionProgress,
            currentBeatHz
        ]
    }

    #if canImport(CoreML)
    public func toMLMultiArray() throws -> MLMultiArray {
        let multi = try MLMultiArray(shape: [1, 12], dataType: .float32)
        let values = toFloatArray()
        for col in 0..<Self.featureCount {
            multi[[0, NSNumber(value: col)]] = NSNumber(value: values[col])
        }
        return multi
    }
    #endif
}

// MARK: - 2. Bounded Acoustic Prediction Output

public struct BrainwavePredictionOutput: Codable, Sendable, Equatable {
    public static let beatHzFloatRange: ClosedRange<Float> = 1.5...42.0
    public static let carrierHzFloatRange: ClosedRange<Float> = 110.0...432.0
    public static let cutoffHzFloatRange: ClosedRange<Float> = 180.0...8_500.0
    public static let pinkNoiseFloatRange: ClosedRange<Float> = 0.05...0.65
    public static let coherenceFloatRange: ClosedRange<Float> = 0.0...1.0

    public static let beatHzRange: ClosedRange<Double> = 1.5...42.0
    public static let carrierHzRange: ClosedRange<Double> = 110.0...432.0
    public static let cutoffHzRange: ClosedRange<Double> = 180.0...8_500.0
    public static let pinkNoiseRange: ClosedRange<Double> = 0.05...0.65
    public static let coherenceRange: ClosedRange<Double> = 0.0...1.0

    public let targetBinauralBeatHz: Double
    public let targetCarrierFrequencyHz: Double
    public let targetFilterCutoffHz: Double
    public let targetPinkNoiseMix: Double
    public let predictedVagalCoherence: Double
    public let rawNormalizedOutputs: [Float]

    public var targetCarrierHz: Float {
        Float(targetCarrierFrequencyHz)
    }

    public init(
        targetBinauralBeatHz: Double,
        targetCarrierFrequencyHz: Double,
        targetFilterCutoffHz: Double,
        targetPinkNoiseMix: Double,
        predictedVagalCoherence: Double
    ) {
        let beat = min(max(targetBinauralBeatHz, 1.5), 42.0)
        let carrier = min(max(targetCarrierFrequencyHz, 110.0), 432.0)
        let cutoff = min(max(targetFilterCutoffHz, 180.0), 8_500.0)
        let pink = min(max(targetPinkNoiseMix, 0.05), 0.65)
        let coherence = min(max(predictedVagalCoherence, 0.0), 1.0)

        self.targetBinauralBeatHz = beat
        self.targetCarrierFrequencyHz = carrier
        self.targetFilterCutoffHz = cutoff
        self.targetPinkNoiseMix = pink
        self.predictedVagalCoherence = coherence
        self.rawNormalizedOutputs = [
            Float((beat - 1.5) / (42.0 - 1.5)),
            Float((carrier - 110.0) / (432.0 - 110.0)),
            Float((cutoff - 180.0) / (8_500.0 - 180.0)),
            Float((pink - 0.05) / (0.65 - 0.05)),
            Float(coherence)
        ]
    }

    public init(
        targetBinauralBeatHz: Float,
        targetCarrierHz: Float,
        targetFilterCutoffHz: Float,
        targetPinkNoiseMix: Float,
        predictedVagalCoherence: Float
    ) {
        self.init(
            targetBinauralBeatHz: Double(targetBinauralBeatHz),
            targetCarrierFrequencyHz: Double(targetCarrierHz),
            targetFilterCutoffHz: Double(targetFilterCutoffHz),
            targetPinkNoiseMix: Double(targetPinkNoiseMix),
            predictedVagalCoherence: Double(predictedVagalCoherence)
        )
    }

    public init(normalizedOutputs: [Float]) {
        let u0 = min(max(normalizedOutputs.count > 0 ? normalizedOutputs[0] : 0.2, 0.0), 1.0)
        let u1 = min(max(normalizedOutputs.count > 1 ? normalizedOutputs[1] : 0.3, 0.0), 0.0 + 1.0)
        let u2 = min(max(normalizedOutputs.count > 2 ? normalizedOutputs[2] : 0.25, 0.0), 1.0)
        let u3 = min(max(normalizedOutputs.count > 3 ? normalizedOutputs[3] : 0.3, 0.0), 1.0)
        let u4 = min(max(normalizedOutputs.count > 4 ? normalizedOutputs[4] : 0.5, 0.0), 1.0)

        self.rawNormalizedOutputs = [u0, u1, u2, u3, u4]
        self.targetBinauralBeatHz = 1.5 + Double(u0) * (42.0 - 1.5)
        self.targetCarrierFrequencyHz = 110.0 + Double(u1) * (432.0 - 110.0)
        self.targetFilterCutoffHz = 180.0 + Double(u2) * (8_500.0 - 180.0)
        self.targetPinkNoiseMix = 0.05 + Double(u3) * (0.65 - 0.05)
        self.predictedVagalCoherence = Double(u4)
    }

    public init(unitActivations: [Double]) {
        self.init(normalizedOutputs: unitActivations.map(Float.init))
    }

    public var unitActivations: [Double] {
        rawNormalizedOutputs.map(Double.init)
    }
}

// MARK: - 3. Deterministic 3-Layer SIMD MLP (12 -> 24 -> 16 -> 5) + Analytical Huber Backprop

public struct AdaptiveBrainwaveMLP: Codable, Sendable, Equatable {
    public static let inputDim: Int = 12
    public static let hidden1Dim: Int = 24
    public static let hidden2Dim: Int = 16
    public static let outputDim: Int = 5

    public var w1: [Float]        // 24 x 12
    public var b1: [Float]        // 24
    public var lnGamma1: [Float]  // 24
    public var lnBeta1: [Float]   // 24

    public var w2: [Float]        // 16 x 24
    public var wSkip: [Float]     // 16 x 12 linear residual skip (12 -> 16)
    public var b2: [Float]        // 16

    public var w3: [Float]        // 5 x 16
    public var b3: [Float]        // 5
    public private(set) var trainedSteps: Int = 0

    public init(seed: UInt64 = 0xAE74_1600_2026) {
        var rng = seed == 0 ? 0xAE74_1600_2026 : seed

        func nextUnit() -> Double {
            rng &+= 0x9E37_79B9_7F4A_7C15
            var z = rng
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z = z ^ (z >> 31)
            return max(1e-9, min(1.0 - 1e-9, Double(z >> 11) * (1.0 / 9_007_199_254_740_992.0)))
        }

        func nextGaussian(scale: Double) -> Float {
            let u1 = nextUnit()
            let u2 = nextUnit()
            let g = sqrt(-2.0 * log(u1)) * cos(2.0 * Double.pi * u2)
            return Float(g * scale)
        }

        let s1 = sqrt(2.0 / Double(Self.inputDim + Self.hidden1Dim))
        let s2 = sqrt(2.0 / Double(Self.hidden1Dim + Self.hidden2Dim))
        let sSkip = sqrt(1.0 / Double(Self.inputDim + Self.hidden2Dim))
        let s3 = sqrt(0.25 / Double(Self.hidden2Dim + Self.outputDim))

        self.w1 = (0..<(Self.hidden1Dim * Self.inputDim)).map { _ in nextGaussian(scale: s1) }
        self.b1 = [Float](repeating: 0.0, count: Self.hidden1Dim)
        self.lnGamma1 = [Float](repeating: 1.0, count: Self.hidden1Dim)
        self.lnBeta1 = [Float](repeating: 0.0, count: Self.hidden1Dim)

        self.w2 = (0..<(Self.hidden2Dim * Self.hidden1Dim)).map { _ in nextGaussian(scale: s2) }
        self.wSkip = (0..<(Self.hidden2Dim * Self.inputDim)).map { _ in nextGaussian(scale: sSkip) }
        self.b2 = [Float](repeating: 0.0, count: Self.hidden2Dim)

        self.w3 = (0..<(Self.outputDim * Self.hidden2Dim)).map { _ in nextGaussian(scale: s3) }
        self.b3 = [-1.85, -0.85, -1.81, -0.75, 0.49]
    }

    public func predictRawNormalized(_ features: [Float]) -> [Float] {
        let x = Self.sanitizeInput(features)
        return Self.forwardWithCache(x: x, model: self).outputs
    }

    public func predict(_ features: [Float]) -> BrainwavePredictionOutput {
        BrainwavePredictionOutput(normalizedOutputs: predictRawNormalized(features))
    }

    public func predict(_ featureVector: BrainwaveFeatureVector) -> BrainwavePredictionOutput {
        predict(featureVector.toFloatArray())
    }

    /// Full analytical backpropagation through output sigmoid, Layer 3, GELU + 12->16 residual skip,
    /// Layer 2, GELU, LayerNorm, and Layer 1, returning scalar Huber loss.
    @discardableResult
    public mutating func trainStep(
        features: [Float],
        normalizedTargets: [Float],
        learningRate: Float = 0.02,
        huberDelta: Float = 0.25
    ) -> Float {
        let x = Self.sanitizeInput(features)
        let t = Self.sanitizeTargets(normalizedTargets)
        let delta = max(1e-4, huberDelta)
        let lr = max(1e-6, min(learningRate, 0.25))

        let cache = Self.forwardWithCache(x: x, model: self)

        // 1. Scalar Huber Loss & Output Sigmoid Jacobian
        var loss: Float = 0.0
        var dLogit = [Float](repeating: 0.0, count: Self.outputDim)
        for k in 0..<Self.outputDim {
            let y = cache.outputs[k]
            let err = y - t[k]
            let absErr = abs(err)
            if absErr <= delta {
                loss += 0.5 * err * err
            } else {
                loss += delta * (absErr - 0.5 * delta)
            }
            let dLossDy = min(max(err, -delta), delta)
            dLogit[k] = dLossDy * y * (1.0 - y)
        }

        // 2. Layer 3 (16 -> 5) gradients
        var dW3 = [Float](repeating: 0.0, count: Self.outputDim * Self.hidden2Dim)
        let dB3 = dLogit
        var dH2 = [Float](repeating: 0.0, count: Self.hidden2Dim)

        for k in 0..<Self.outputDim {
            let g = dLogit[k]
            let row = k * Self.hidden2Dim
            for m in 0..<Self.hidden2Dim {
                dW3[row + m] = g * cache.h2[m]
                dH2[m] += w3[row + m] * g
            }
        }

        // 3. Layer 2 GELU + Linear (24 -> 16) + Linear Residual Skip (12 -> 16)
        var dU2 = [Float](repeating: 0.0, count: Self.hidden2Dim)
        for m in 0..<Self.hidden2Dim {
            dU2[m] = dH2[m] * Self.geluDerivative(cache.u2[m])
        }

        var dW2 = [Float](repeating: 0.0, count: Self.hidden2Dim * Self.hidden1Dim)
        var dWSkip = [Float](repeating: 0.0, count: Self.hidden2Dim * Self.inputDim)
        let dB2 = dU2
        var dH1 = [Float](repeating: 0.0, count: Self.hidden1Dim)

        for m in 0..<Self.hidden2Dim {
            let g = dU2[m]
            let row2 = m * Self.hidden1Dim
            for i in 0..<Self.hidden1Dim {
                dW2[row2 + i] = g * cache.h1[i]
                dH1[i] += w2[row2 + i] * g
            }
            let rowSkip = m * Self.inputDim
            for j in 0..<Self.inputDim {
                dWSkip[rowSkip + j] = g * x[j]
            }
        }

        // 4. Layer 1 GELU + LayerNorm + Linear (12 -> 24)
        var dU1 = [Float](repeating: 0.0, count: Self.hidden1Dim)
        var dGamma1 = [Float](repeating: 0.0, count: Self.hidden1Dim)
        var dBeta1 = [Float](repeating: 0.0, count: Self.hidden1Dim)
        var dZHat1 = [Float](repeating: 0.0, count: Self.hidden1Dim)

        for i in 0..<Self.hidden1Dim {
            let gu = dH1[i] * Self.geluDerivative(cache.u1[i])
            dU1[i] = gu
            dGamma1[i] = gu * cache.z1Normalized[i]
            dBeta1[i] = gu
            dZHat1[i] = gu * lnGamma1[i]
        }

        let n1 = Float(Self.hidden1Dim)
        var sumDZHat: Float = 0.0
        var sumDZHatZHat: Float = 0.0
        for i in 0..<Self.hidden1Dim {
            sumDZHat += dZHat1[i]
            sumDZHatZHat += dZHat1[i] * cache.z1Normalized[i]
        }

        var dZ1 = [Float](repeating: 0.0, count: Self.hidden1Dim)
        var dW1 = [Float](repeating: 0.0, count: Self.hidden1Dim * Self.inputDim)

        for i in 0..<Self.hidden1Dim {
            let dz = (cache.invStd1 / n1) * (n1 * dZHat1[i] - sumDZHat - cache.z1Normalized[i] * sumDZHatZHat)
            dZ1[i] = dz
            let row1 = i * Self.inputDim
            for j in 0..<Self.inputDim {
                dW1[row1 + j] = dz * x[j]
            }
        }

        // 5. Exact Gradient Descent Parameter Update
        for idx in w3.indices { w3[idx] -= lr * dW3[idx] }
        for idx in b3.indices { b3[idx] -= lr * dB3[idx] }
        for idx in w2.indices { w2[idx] -= lr * dW2[idx] }
        for idx in wSkip.indices { wSkip[idx] -= lr * dWSkip[idx] }
        for idx in b2.indices { b2[idx] -= lr * dB2[idx] }
        for idx in lnGamma1.indices { lnGamma1[idx] -= lr * dGamma1[idx] }
        for idx in lnBeta1.indices { lnBeta1[idx] -= lr * dBeta1[idx] }
        for idx in w1.indices { w1[idx] -= lr * dW1[idx] }
        for idx in b1.indices { b1[idx] -= lr * dZ1[idx] }

        trainedSteps += 1
        return loss
    }

    // MARK: - SIMD Kernels & Exact GELU / Sigmoid Primitives

    private struct ForwardCache {
        let z1Normalized: [Float]
        let invStd1: Float
        let u1: [Float]
        let h1: [Float]
        let u2: [Float]
        let h2: [Float]
        let outputs: [Float]
    }

    private static func sanitizeInput(_ raw: [Float]) -> [Float] {
        if raw.count == inputDim {
            return raw.map { $0.isFinite ? $0 : 0.0 }
        }
        var out = [Float](repeating: 0.0, count: inputDim)
        for i in 0..<min(raw.count, inputDim) {
            out[i] = raw[i].isFinite ? raw[i] : 0.0
        }
        return out
    }

    private static func sanitizeTargets(_ raw: [Float]) -> [Float] {
        var out = [Float](repeating: 0.5, count: outputDim)
        for i in 0..<min(raw.count, outputDim) {
            let v = raw[i].isFinite ? raw[i] : 0.5
            out[i] = min(max(v, 0.0), 1.0)
        }
        return out
    }

    @inline(__always)
    private static func simdDot12(_ row: UnsafePointer<Float>, _ vec: UnsafePointer<Float>) -> Float {
        let a0 = SIMD4<Float>(row[0], row[1], row[2], row[3])
        let b0 = SIMD4<Float>(vec[0], vec[1], vec[2], vec[3])
        let a1 = SIMD4<Float>(row[4], row[5], row[6], row[7])
        let b1 = SIMD4<Float>(vec[4], vec[5], vec[6], vec[7])
        let a2 = SIMD4<Float>(row[8], row[9], row[10], row[11])
        let b2 = SIMD4<Float>(vec[8], vec[9], vec[10], vec[11])
        let acc = a0 * b0 + a1 * b1 + a2 * b2
        return acc[0] + acc[1] + acc[2] + acc[3]
    }

    @inline(__always)
    private static func simdDot24(_ row: UnsafePointer<Float>, _ vec: UnsafePointer<Float>) -> Float {
        var acc = SIMD4<Float>.zero
        for base in stride(from: 0, to: 24, by: 4) {
            let r = SIMD4<Float>(row[base], row[base + 1], row[base + 2], row[base + 3])
            let v = SIMD4<Float>(vec[base], vec[base + 1], vec[base + 2], vec[base + 3])
            acc += r * v
        }
        return acc[0] + acc[1] + acc[2] + acc[3]
    }

    @inline(__always)
    private static func simdDot16(_ row: UnsafePointer<Float>, _ vec: UnsafePointer<Float>) -> Float {
        var acc = SIMD4<Float>.zero
        for base in stride(from: 0, to: 16, by: 4) {
            let r = SIMD4<Float>(row[base], row[base + 1], row[base + 2], row[base + 3])
            let v = SIMD4<Float>(vec[base], vec[base + 1], vec[base + 2], vec[base + 3])
            acc += r * v
        }
        return acc[0] + acc[1] + acc[2] + acc[3]
    }

    @inline(__always)
    private static func gelu(_ x: Float) -> Float {
        let c: Float = 0.79788456
        let inner = c * (x + 0.044715 * x * x * x)
        return 0.5 * x * (1.0 + tanh(inner))
    }

    @inline(__always)
    private static func geluDerivative(_ x: Float) -> Float {
        let c: Float = 0.79788456
        let inner = c * (x + 0.044715 * x * x * x)
        let th = tanh(inner)
        let sech2 = 1.0 - th * th
        let dInner = c * (1.0 + 3.0 * 0.044715 * x * x)
        return 0.5 * (1.0 + th) + 0.5 * x * sech2 * dInner
    }

    @inline(__always)
    private static func sigmoid(_ z: Float) -> Float {
        let clamped = min(max(z, -20.0), 20.0)
        return 1.0 / (1.0 + exp(-clamped))
    }

    private static func forwardWithCache(x: [Float], model: AdaptiveBrainwaveMLP) -> ForwardCache {
        var z1 = [Float](repeating: 0.0, count: hidden1Dim)
        model.w1.withUnsafeBufferPointer { w1Buf in
            x.withUnsafeBufferPointer { xBuf in
                guard let w1Base = w1Buf.baseAddress, let xBase = xBuf.baseAddress else { return }
                for i in 0..<hidden1Dim {
                    z1[i] = simdDot12(w1Base.advanced(by: i * 12), xBase) + model.b1[i]
                }
            }
        }

        var mean1: Float = 0.0
        for v in z1 { mean1 += v }
        mean1 /= Float(hidden1Dim)

        var var1: Float = 0.0
        for v in z1 {
            let d = v - mean1
            var1 += d * d
        }
        var1 /= Float(hidden1Dim)
        let invStd1 = 1.0 / sqrt(var1 + 1e-5)

        var z1Normalized = [Float](repeating: 0.0, count: hidden1Dim)
        var u1 = [Float](repeating: 0.0, count: hidden1Dim)
        var h1 = [Float](repeating: 0.0, count: hidden1Dim)
        for i in 0..<hidden1Dim {
            let norm = (z1[i] - mean1) * invStd1
            z1Normalized[i] = norm
            let pre = model.lnGamma1[i] * norm + model.lnBeta1[i]
            u1[i] = pre
            h1[i] = gelu(pre)
        }

        var u2 = [Float](repeating: 0.0, count: hidden2Dim)
        var h2 = [Float](repeating: 0.0, count: hidden2Dim)
        model.w2.withUnsafeBufferPointer { w2Buf in
            model.wSkip.withUnsafeBufferPointer { skipBuf in
                h1.withUnsafeBufferPointer { h1Buf in
                    x.withUnsafeBufferPointer { xBuf in
                        guard let w2Base = w2Buf.baseAddress,
                              let skipBase = skipBuf.baseAddress,
                              let h1Base = h1Buf.baseAddress,
                              let xBase = xBuf.baseAddress else { return }
                        for m in 0..<hidden2Dim {
                            let lin = simdDot24(w2Base.advanced(by: m * 24), h1Base)
                            let skip = simdDot12(skipBase.advanced(by: m * 12), xBase)
                            let pre = lin + skip + model.b2[m]
                            u2[m] = pre
                            h2[m] = gelu(pre)
                        }
                    }
                }
            }
        }

        var outputs = [Float](repeating: 0.0, count: outputDim)
        model.w3.withUnsafeBufferPointer { w3Buf in
            h2.withUnsafeBufferPointer { h2Buf in
                guard let w3Base = w3Buf.baseAddress, let h2Base = h2Buf.baseAddress else { return }
                for k in 0..<outputDim {
                    let logit = simdDot16(w3Base.advanced(by: k * 16), h2Base) + model.b3[k]
                    outputs[k] = sigmoid(logit)
                }
            }
        }

        return ForwardCache(
            z1Normalized: z1Normalized,
            invStd1: invStd1,
            u1: u1,
            h1: h1,
            u2: u2,
            h2: h2,
            outputs: outputs
        )
    }
}

// MARK: - 4. Anti-Windup PID Controller Smoothing Acoustic Transitions

public struct ScalarPIDAxisState: Codable, Sendable, Equatable {
    public let kp: Double
    public let ki: Double
    public let kd: Double
    public let integralClamp: Double
    public let maxSlewPerSecond: Double

    private var integralAccum: Double = 0.0
    private var previousError: Double?
    private var smoothedDerivative: Double = 0.0

    public init(
        kp: Double,
        ki: Double,
        kd: Double,
        integralClamp: Double,
        maxSlewPerSecond: Double = 500.0
    ) {
        self.kp = kp
        self.ki = ki
        self.kd = kd
        self.integralClamp = max(0.001, integralClamp)
        self.maxSlewPerSecond = max(0.001, maxSlewPerSecond)
    }

    public mutating func reset() {
        integralAccum = 0.0
        previousError = nil
        smoothedDerivative = 0.0
    }

    public mutating func step(
        current: Double,
        target: Double,
        dtSeconds: Double,
        validRange: ClosedRange<Double>
    ) -> Double {
        let dt = max(1e-3, min(dtSeconds, 10.0))
        let error = target - current

        integralAccum = min(max(integralAccum + error * dt, -integralClamp), integralClamp)

        let rawDerivative: Double
        if let prev = previousError {
            rawDerivative = (error - prev) / dt
        } else {
            rawDerivative = 0.0
        }
        previousError = error
        smoothedDerivative = 0.60 * smoothedDerivative + 0.40 * rawDerivative

        let pidDelta = kp * error + ki * integralAccum + kd * smoothedDerivative
        let maxDelta = maxSlewPerSecond * dt
        let clampedDelta = min(max(pidDelta, -maxDelta), maxDelta)

        return min(max(current + clampedDelta, validRange.lowerBound), validRange.upperBound)
    }
}

public struct EntrainmentPIDController: Codable, Sendable, Equatable {
    public let kp: Float
    public let ki: Float
    public let kd: Float
    public let integralClamp: Float

    public var beatAxis: ScalarPIDAxisState
    public var carrierAxis: ScalarPIDAxisState
    public var cutoffAxis: ScalarPIDAxisState
    public var pinkNoiseAxis: ScalarPIDAxisState
    public var coherenceAxis: ScalarPIDAxisState

    public init(
        kp: Float,
        ki: Float,
        kd: Float,
        integralClamp: Float = 10.0
    ) {
        self.kp = kp
        self.ki = ki
        self.kd = kd
        self.integralClamp = max(0.01, integralClamp)

        let p = Double(kp)
        let i = Double(ki)
        let d = Double(kd)
        let clamp = Double(max(0.01, integralClamp))

        self.beatAxis = ScalarPIDAxisState(kp: p, ki: i, kd: d, integralClamp: clamp, maxSlewPerSecond: 12.0)
        self.carrierAxis = ScalarPIDAxisState(kp: p, ki: i, kd: d, integralClamp: clamp * 6.0, maxSlewPerSecond: 80.0)
        self.cutoffAxis = ScalarPIDAxisState(kp: p, ki: i, kd: d, integralClamp: clamp * 80.0, maxSlewPerSecond: 1_200.0)
        self.pinkNoiseAxis = ScalarPIDAxisState(kp: p, ki: i, kd: d, integralClamp: min(clamp, 0.5), maxSlewPerSecond: 0.25)
        self.coherenceAxis = ScalarPIDAxisState(kp: p, ki: i, kd: d, integralClamp: min(clamp, 0.5), maxSlewPerSecond: 0.35)
    }

    public init(
        beatAxis: ScalarPIDAxisState = ScalarPIDAxisState(
            kp: 0.42,
            ki: 0.06,
            kd: 0.08,
            integralClamp: 12.0,
            maxSlewPerSecond: 2.2
        ),
        carrierAxis: ScalarPIDAxisState = ScalarPIDAxisState(
            kp: 0.38,
            ki: 0.05,
            kd: 0.06,
            integralClamp: 60.0,
            maxSlewPerSecond: 18.0
        ),
        cutoffAxis: ScalarPIDAxisState = ScalarPIDAxisState(
            kp: 0.35,
            ki: 0.04,
            kd: 0.05,
            integralClamp: 800.0,
            maxSlewPerSecond: 320.0
        ),
        pinkNoiseAxis: ScalarPIDAxisState = ScalarPIDAxisState(
            kp: 0.40,
            ki: 0.05,
            kd: 0.05,
            integralClamp: 0.25,
            maxSlewPerSecond: 0.06
        )
    ) {
        self.kp = Float(beatAxis.kp)
        self.ki = Float(beatAxis.ki)
        self.kd = Float(beatAxis.kd)
        self.integralClamp = Float(beatAxis.integralClamp)
        self.beatAxis = beatAxis
        self.carrierAxis = carrierAxis
        self.cutoffAxis = cutoffAxis
        self.pinkNoiseAxis = pinkNoiseAxis
        self.coherenceAxis = ScalarPIDAxisState(
            kp: 0.40,
            ki: 0.05,
            kd: 0.05,
            integralClamp: 0.30,
            maxSlewPerSecond: 0.20
        )
    }

    public mutating func reset() {
        beatAxis.reset()
        carrierAxis.reset()
        cutoffAxis.reset()
        pinkNoiseAxis.reset()
        coherenceAxis.reset()
    }

    public mutating func step(
        current: BrainwavePredictionOutput,
        target: BrainwavePredictionOutput,
        dt: Float = 1.0
    ) -> BrainwavePredictionOutput {
        let dtSec = Double(max(1e-3, dt))
        let nextBeat = beatAxis.step(
            current: Double(current.targetBinauralBeatHz),
            target: Double(target.targetBinauralBeatHz),
            dtSeconds: dtSec,
            validRange: BrainwavePredictionOutput.beatHzRange
        )
        let nextCarrier = carrierAxis.step(
            current: Double(current.targetCarrierHz),
            target: Double(target.targetCarrierHz),
            dtSeconds: dtSec,
            validRange: BrainwavePredictionOutput.carrierHzRange
        )
        let nextCutoff = cutoffAxis.step(
            current: Double(current.targetFilterCutoffHz),
            target: Double(target.targetFilterCutoffHz),
            dtSeconds: dtSec,
            validRange: BrainwavePredictionOutput.cutoffHzRange
        )
        let nextPink = pinkNoiseAxis.step(
            current: Double(current.targetPinkNoiseMix),
            target: Double(target.targetPinkNoiseMix),
            dtSeconds: dtSec,
            validRange: BrainwavePredictionOutput.pinkNoiseRange
        )
        let nextCoherence = coherenceAxis.step(
            current: Double(current.predictedVagalCoherence),
            target: Double(target.predictedVagalCoherence),
            dtSeconds: dtSec,
            validRange: BrainwavePredictionOutput.coherenceRange
        )

        return BrainwavePredictionOutput(
            targetBinauralBeatHz: Float(nextBeat),
            targetCarrierHz: Float(nextCarrier),
            targetFilterCutoffHz: Float(nextCutoff),
            targetPinkNoiseMix: Float(nextPink),
            predictedVagalCoherence: Float(nextCoherence)
        )
    }

    public mutating func stepBeatFrequency(currentHz: Double, targetHz: Double, dtSeconds: Double) -> Double {
        beatAxis.step(
            current: currentHz,
            target: targetHz,
            dtSeconds: dtSeconds,
            validRange: BrainwavePredictionOutput.beatHzRange
        )
    }

    public mutating func stepAcousticTargets(
        currentBeatHz: Float,
        currentCarrierHz: Float,
        currentCutoffHz: Float,
        currentPinkNoiseMix: Float,
        prediction: BrainwavePredictionOutput,
        dtSeconds: Double
    ) -> (beatHz: Float, carrierHz: Float, cutoffHz: Float, pinkNoiseMix: Float) {
        let nextBeat = beatAxis.step(
            current: Double(currentBeatHz),
            target: Double(prediction.targetBinauralBeatHz),
            dtSeconds: dtSeconds,
            validRange: BrainwavePredictionOutput.beatHzRange
        )
        let nextCarrier = carrierAxis.step(
            current: Double(currentCarrierHz),
            target: Double(prediction.targetCarrierHz),
            dtSeconds: dtSeconds,
            validRange: BrainwavePredictionOutput.carrierHzRange
        )
        let nextCutoff = cutoffAxis.step(
            current: Double(currentCutoffHz),
            target: Double(prediction.targetFilterCutoffHz),
            dtSeconds: dtSeconds,
            validRange: BrainwavePredictionOutput.cutoffHzRange
        )
        let nextPink = pinkNoiseAxis.step(
            current: Double(currentPinkNoiseMix),
            target: Double(prediction.targetPinkNoiseMix),
            dtSeconds: dtSeconds,
            validRange: BrainwavePredictionOutput.pinkNoiseRange
        )

        return (Float(nextBeat), Float(nextCarrier), Float(nextCutoff), Float(nextPink))
    }
}

// MARK: - 5. Coordinator Actor Bridge & 12D CoreML Double Tensor Interop

public struct BiometricFeatureVector: Codable, Sendable, Equatable {
    public static let dimension: Int = 12

    public let hrNormalized: Double
    public let rmssdNormalized: Double
    public let sdnnNormalized: Double
    public let pnn50Normalized: Double
    public let baevskyStressNormalized: Double
    public let lfHfRatioNormalized: Double
    public let rsaCoherenceScore: Double
    public let respiratoryRateNormalized: Double
    public let circadianPhaseSin: Double
    public let circadianPhaseCos: Double
    public let currentBeatHzNormalized: Double
    public let sessionProgressRatio: Double

    public init(
        hrNormalized: Double,
        rmssdNormalized: Double,
        sdnnNormalized: Double,
        pnn50Normalized: Double,
        baevskyStressNormalized: Double,
        lfHfRatioNormalized: Double,
        rsaCoherenceScore: Double,
        respiratoryRateNormalized: Double,
        circadianPhaseSin: Double,
        circadianPhaseCos: Double,
        currentBeatHzNormalized: Double,
        sessionProgressRatio: Double
    ) {
        self.hrNormalized = min(max(hrNormalized, 0.0), 1.0)
        self.rmssdNormalized = min(max(rmssdNormalized, 0.0), 1.0)
        self.sdnnNormalized = min(max(sdnnNormalized, 0.0), 1.0)
        self.pnn50Normalized = min(max(pnn50Normalized, 0.0), 1.0)
        self.baevskyStressNormalized = min(max(baevskyStressNormalized, 0.0), 1.0)
        self.lfHfRatioNormalized = min(max(lfHfRatioNormalized, 0.0), 1.0)
        self.rsaCoherenceScore = min(max(rsaCoherenceScore, 0.0), 1.0)
        self.respiratoryRateNormalized = min(max(respiratoryRateNormalized, 0.0), 1.0)
        self.circadianPhaseSin = min(max(circadianPhaseSin, -1.0), 1.0)
        self.circadianPhaseCos = min(max(circadianPhaseCos, -1.0), 1.0)
        self.currentBeatHzNormalized = min(max(currentBeatHzNormalized, 0.0), 1.0)
        self.sessionProgressRatio = min(max(sessionProgressRatio, 0.0), 1.0)
    }

    public init(brainwaveFeatures: BrainwaveFeatureVector) {
        self.init(
            hrNormalized: Double(brainwaveFeatures.hrBPM),
            rmssdNormalized: Double(brainwaveFeatures.rmssd),
            sdnnNormalized: Double(brainwaveFeatures.sdnn),
            pnn50Normalized: Double(brainwaveFeatures.poincareRatio),
            baevskyStressNormalized: Double(brainwaveFeatures.baevskyStress),
            lfHfRatioNormalized: Double(brainwaveFeatures.lfHfRatio),
            rsaCoherenceScore: Double(brainwaveFeatures.priorFocusQuality),
            respiratoryRateNormalized: Double(brainwaveFeatures.respiratoryRate),
            circadianPhaseSin: Double(brainwaveFeatures.circadianSin),
            circadianPhaseCos: Double(brainwaveFeatures.circadianCos),
            currentBeatHzNormalized: Double(brainwaveFeatures.currentBeatHz),
            sessionProgressRatio: Double(brainwaveFeatures.sessionProgress)
        )
    }

    public init(
        snapshot: BiometricSnapshotDTO?,
        metrics: HRVAnalysisMetricsDTO,
        currentBeatHz: Double,
        sessionProgressRatio: Double,
        referenceDate: Date = .now,
        calendar: Calendar = .current
    ) {
        let comps = calendar.dateComponents([.hour, .minute], from: referenceDate)
        let fractionalHour = Double(comps.hour ?? 12) + Double(comps.minute ?? 0) / 60.0
        let angle = (2.0 * Double.pi * fractionalHour) / 24.0
        let hr = snapshot?.heartRateBPM ?? metrics.heartRateBPM
        let resp = snapshot?.respiratoryRateBrPM ?? 10.0

        self.init(
            hrNormalized: (hr - 45.0) / 95.0,
            rmssdNormalized: metrics.rmssdMs / 120.0,
            sdnnNormalized: metrics.sdnnMs / 140.0,
            pnn50Normalized: metrics.pnn50Percent / 100.0,
            baevskyStressNormalized: metrics.baevskyStressIndex / 600.0,
            lfHfRatioNormalized: metrics.lfHfRatio / 6.0,
            rsaCoherenceScore: metrics.rsaCoherenceScore,
            respiratoryRateNormalized: (resp - 4.0) / 20.0,
            circadianPhaseSin: sin(angle),
            circadianPhaseCos: cos(angle),
            currentBeatHzNormalized: (currentBeatHz - 1.5) / (42.0 - 1.5),
            sessionProgressRatio: sessionProgressRatio
        )
    }

    public func asArray() -> [Double] {
        [
            hrNormalized,
            rmssdNormalized,
            sdnnNormalized,
            pnn50Normalized,
            baevskyStressNormalized,
            lfHfRatioNormalized,
            rsaCoherenceScore,
            respiratoryRateNormalized,
            circadianPhaseSin,
            circadianPhaseCos,
            currentBeatHzNormalized,
            sessionProgressRatio
        ]
    }

    public func asFloatArray() -> [Float] {
        asArray().map(Float.init)
    }

    #if canImport(CoreML)
    public func makeMLMultiArray() throws -> MLMultiArray {
        let multi = try MLMultiArray(shape: [1, 12], dataType: .double)
        let values = asArray()
        for col in 0..<Self.dimension {
            multi[[0, NSNumber(value: col)]] = NSNumber(value: values[col])
        }
        return multi
    }
    #endif
}

#if canImport(CoreML)
public final class BiometricFeatureProvider: MLFeatureProvider, @unchecked Sendable {
    public static let tensorFeatureName = "biometric_features"

    public let featureTensor: MLMultiArray
    public let sourceVector: BiometricFeatureVector

    public var featureNames: Set<String> {
        [Self.tensorFeatureName]
    }

    public init(features: BiometricFeatureVector) throws {
        self.sourceVector = features
        self.featureTensor = try features.makeMLMultiArray()
    }

    public func featureValue(for featureName: String) -> MLFeatureValue? {
        guard featureName == Self.tensorFeatureName else { return nil }
        return MLFeatureValue(multiArray: featureTensor)
    }
}
#endif

public struct OnlinePlasticityReport: Codable, Sendable, Equatable {
    public let huberLoss: Double
    public let rewardSignal: Double
    public let gradientL2Norm: Double
    public let updatedEpochCount: Int

    public init(huberLoss: Double, rewardSignal: Double, gradientL2Norm: Double, updatedEpochCount: Int) {
        self.huberLoss = huberLoss
        self.rewardSignal = rewardSignal
        self.gradientL2Norm = gradientL2Norm
        self.updatedEpochCount = updatedEpochCount
    }
}

public struct NeuralReservoirWeights: Codable, Sendable, Equatable {
    public var mlp: AdaptiveBrainwaveMLP
    public var trainedEpochCount: Int

    public init(mlp: AdaptiveBrainwaveMLP = AdaptiveBrainwaveMLP(), trainedEpochCount: Int = 0) {
        self.mlp = mlp
        self.trainedEpochCount = trainedEpochCount
    }

    public static func makeDeterministicDefault(seed: UInt64 = 0xAE74_1600_2026) -> NeuralReservoirWeights {
        NeuralReservoirWeights(mlp: AdaptiveBrainwaveMLP(seed: seed), trainedEpochCount: 0)
    }
}

public actor AdaptiveBrainwaveMLPredictor {
    public static let weightsFilename = "AdaptiveBrainwaveWeights.v2.json"

    private var weights: NeuralReservoirWeights
    private let persistToDisk: Bool
    private let customStorageURL: URL?

    public init(
        initialWeights: NeuralReservoirWeights? = nil,
        persistToAppGroup: Bool = true,
        customStorageURL: URL? = nil
    ) {
        self.persistToDisk = persistToAppGroup
        self.customStorageURL = customStorageURL
        if let explicit = initialWeights {
            self.weights = explicit
        } else if let loaded = Self.loadWeightsFromDisk(customURL: customStorageURL, useAppGroup: persistToAppGroup) {
            self.weights = loaded
        } else {
            self.weights = NeuralReservoirWeights.makeDeterministicDefault()
        }
    }

    public func currentWeightsSnapshot() -> NeuralReservoirWeights {
        weights
    }

    public func resetToDefaultWeights() {
        weights = NeuralReservoirWeights.makeDeterministicDefault()
        if persistToDisk {
            Self.saveWeightsToDisk(weights, customURL: customStorageURL)
        }
    }

    public func predict(features: BiometricFeatureVector) -> BrainwavePredictionOutput {
        weights.mlp.predict(features.asFloatArray())
    }

    public func predict(features: BrainwaveFeatureVector) -> BrainwavePredictionOutput {
        weights.mlp.predict(features)
    }

    #if canImport(CoreML)
    public func predictWithCoreMLInterop(
        features: BiometricFeatureVector,
        compiledModel: MLModel? = nil
    ) throws -> (BiometricFeatureProvider, BrainwavePredictionOutput) {
        let provider = try BiometricFeatureProvider(features: features)
        if let compiledModel,
           let modelOut = try? compiledModel.prediction(from: provider),
           let firstName = modelOut.featureNames.first,
           let multi = modelOut.featureValue(for: firstName)?.multiArrayValue,
           multi.count >= 5 {
            var acts: [Double] = []
            acts.reserveCapacity(5)
            for idx in 0..<5 {
                acts.append(multi[idx].doubleValue)
            }
            return (provider, BrainwavePredictionOutput(unitActivations: acts))
        }
        var extracted: [Float] = []
        extracted.reserveCapacity(BiometricFeatureVector.dimension)
        for col in 0..<BiometricFeatureVector.dimension {
            extracted.append(Float(provider.featureTensor[[0, NSNumber(value: col)]].doubleValue))
        }
        return (provider, weights.mlp.predict(extracted))
    }
    #endif

    @discardableResult
    public func updateWeightsWithObservedReward(
        previousFeatures: BiometricFeatureVector,
        predictedOutput: BrainwavePredictionOutput,
        observedRMSSDDelta: Double,
        observedCoherenceDelta: Double,
        learningRate: Double = 0.02
    ) -> OnlinePlasticityReport {
        _ = predictedOutput
        let reward = tanh(0.08 * observedRMSSDDelta + 2.2 * observedCoherenceDelta)
        let x = previousFeatures.asFloatArray()
        let currentBeatNorm = x[10]
        let stressNorm = x[4]
        let cohNorm = x[6]

        let calmAnchor: Float = 0.165
        let rFloat = Float(reward)
        let targetBeat = rFloat >= 0
            ? min(max(0.5 * currentBeatNorm + 0.5 * calmAnchor, 0.08), 0.85)
            : min(max(0.3 * currentBeatNorm + 0.7 * 0.15, 0.06), 0.45)
        let targetCarrier = min(max(0.30 + 0.15 * (1.0 - stressNorm) + 0.08 * rFloat, 0.10), 0.80)
        let targetCutoff = min(max(0.18 + 0.22 * cohNorm - 0.08 * stressNorm, 0.06), 0.70)
        let targetPink = min(max(0.25 + 0.25 * stressNorm - 0.05 * rFloat, 0.08), 0.75)
        let targetCoherence = min(max(cohNorm + 0.18 * rFloat, 0.08), 0.96)

        let loss = weights.mlp.trainStep(
            features: x,
            normalizedTargets: [targetBeat, targetCarrier, targetCutoff, targetPink, targetCoherence],
            learningRate: Float(learningRate),
            huberDelta: 0.25
        )
        weights.trainedEpochCount += 1

        if persistToDisk {
            Self.saveWeightsToDisk(weights, customURL: customStorageURL)
        }

        return OnlinePlasticityReport(
            huberLoss: Double(loss),
            rewardSignal: reward,
            gradientL2Norm: Double(sqrt(max(0.0, loss))),
            updatedEpochCount: weights.trainedEpochCount
        )
    }

    private static func resolveStorageURL(customURL: URL?, useAppGroup: Bool) -> URL? {
        if let customURL { return customURL }
        guard useAppGroup else { return nil }
        if let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AetherPersistenceSchema.appGroupIdentifier
        ) {
            let dir = groupURL.appendingPathComponent("Library/Application Support", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appendingPathComponent(weightsFilename)
        }
        let fallbackDir = FileManager.default.temporaryDirectory.appendingPathComponent("AetherSynthML", isDirectory: true)
        try? FileManager.default.createDirectory(at: fallbackDir, withIntermediateDirectories: true)
        return fallbackDir.appendingPathComponent(weightsFilename)
    }

    private static func loadWeightsFromDisk(customURL: URL?, useAppGroup: Bool) -> NeuralReservoirWeights? {
        guard let url = resolveStorageURL(customURL: customURL, useAppGroup: useAppGroup),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(NeuralReservoirWeights.self, from: data) else {
            return nil
        }
        return decoded
    }

    private static func saveWeightsToDisk(_ weights: NeuralReservoirWeights, customURL: URL?) {
        guard let url = resolveStorageURL(customURL: customURL, useAppGroup: true),
              let data = try? JSONEncoder().encode(weights) else {
            return
        }
        try? data.write(to: url, options: .atomic)
    }
}
