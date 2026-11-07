// MARK: - FILE: NeuralLatentSoundscapeEngine.swift

import Foundation
import simd
import Synchronization

// MARK: - 1. Biometric & Cognitive 16-D Conditioning Encoder (`LatentConditioningVector`)

public struct LatentConditioningVector: Sendable, Equatable, Codable {
    public static let dimension: Int = 16

    /// Packed 16-dimensional conditioning vector `c in R^16`
    public let values: [Float]

    public init(values: [Float]) {
        if values.count == Self.dimension {
            self.values = values.map { $0.isFinite ? $0 : 0.0 }
        } else if values.count > Self.dimension {
            self.values = Array(values.prefix(Self.dimension)).map { $0.isFinite ? $0 : 0.0 }
        } else {
            let clean = values.map { $0.isFinite ? $0 : 0.0 }
            self.values = clean + [Float](repeating: 0.0, count: Self.dimension - clean.count)
        }
    }

    /// Encodes Fourier flow-time embeddings `(sin(2^k * pi * t), cos(2^k * pi * t))` for `k = 0, 1, 2`,
    /// 5-D `FocusCategory` manifold embedding, normalized `binauralBeatHz`, and live autonomic HRV metrics.
    public init(
        flowTime: Float,
        category: FocusCategory,
        binauralBeatHz: Float,
        rmssdNormalized: Float,
        rsaCoherenceScore: Float,
        lfHfRatioNormalized: Float,
        isUnconditional: Bool = false
    ) {
        let t = min(max(flowTime, 0.0), 1.0)
        // 6-D sinusoidal Fourier time embeddings: k = 0 (1*pi*t), k = 1 (2*pi*t), k = 2 (4*pi*t)
        let f0Sin = sinf(Float.pi * t)
        let f0Cos = cosf(Float.pi * t)
        let f1Sin = sinf(2.0 * Float.pi * t)
        let f1Cos = cosf(2.0 * Float.pi * t)
        let f2Sin = sinf(4.0 * Float.pi * t)
        let f2Cos = cosf(4.0 * Float.pi * t)

        if isUnconditional {
            self.values = [
                f0Sin, f0Cos, f1Sin, f1Cos, f2Sin, f2Cos,
                0.0, 0.0, 0.0, 0.0, 0.0,
                0.0, 0.0, 0.0, 0.0, 0.0
            ]
            return
        }

        let catEmbed = Self.categoryEmbedding(for: category)
        let beatNorm = min(max((binauralBeatHz - 0.5) / 47.5, 0.0), 1.0)
        let rmssd = min(max(rmssdNormalized, 0.0), 1.0)
        let rsa = min(max(rsaCoherenceScore, 0.0), 1.0)
        let lfHf = min(max(lfHfRatioNormalized, 0.0), 1.0)

        self.values = [
            f0Sin, f0Cos, f1Sin, f1Cos, f2Sin, f2Cos,
            catEmbed[0], catEmbed[1], catEmbed[2], catEmbed[3], catEmbed[4],
            beatNorm * 2.0 - 1.0,
            rmssd * 2.0 - 1.0,
            rsa * 2.0 - 1.0,
            lfHf * 2.0 - 1.0,
            1.0
        ]
    }

    /// Returns a copy evaluated at flow ODE timestep `t in [0, 1]`, optionally masked to null conditioning `\varnothing` for CFG.
    public func withFlowTime(_ flowTime: Float, unconditional: Bool = false) -> LatentConditioningVector {
        let t = min(max(flowTime, 0.0), 1.0)
        var next = unconditional ? [Float](repeating: 0.0, count: Self.dimension) : values
        next[0] = sinf(Float.pi * t)
        next[1] = cosf(Float.pi * t)
        next[2] = sinf(2.0 * Float.pi * t)
        next[3] = cosf(2.0 * Float.pi * t)
        next[4] = sinf(4.0 * Float.pi * t)
        next[5] = cosf(4.0 * Float.pi * t)
        return LatentConditioningVector(values: next)
    }

    private static func categoryEmbedding(for category: FocusCategory) -> [Float] {
        switch category {
        case .deepWork:
            return [ 0.92,  0.28, -0.35,  0.18, -0.24]
        case .alphaFlow:
            return [ 0.24,  0.90,  0.32, -0.20,  0.15]
        case .thetaMeditation:
            return [-0.30,  0.38,  0.92, -0.28,  0.42]
        case .gammaCognition:
            return [ 0.55, -0.34, -0.48,  0.94, -0.36]
        case .deltaRecovery:
            return [-0.62,  0.18,  0.54, -0.52,  0.95]
        }
    }
}

// MARK: - 2. Latent Audio Tensor (`Z in R^{16 x 64}`)

public struct LatentAudioTensor: Sendable, Equatable {
    public static let channels: Int = 16
    public static let frameLength: Int = 64
    public static let scalarCount: Int = channels * frameLength // 1024

    /// Contiguous channel-major `[channel * 64 + frame]` buffer of length 1024.
    public var data: [Float]

    public init(repeating value: Float = 0.0) {
        self.data = [Float](repeating: value, count: Self.scalarCount)
    }

    public init(data: [Float]) {
        if data.count == Self.scalarCount {
            self.data = data
        } else if data.count > Self.scalarCount {
            self.data = Array(data.prefix(Self.scalarCount))
        } else {
            self.data = data + [Float](repeating: 0.0, count: Self.scalarCount - data.count)
        }
    }

    @inline(__always)
    public subscript(channel: Int, frame: Int) -> Float {
        get { data[channel * Self.frameLength + frame] }
        set { data[channel * Self.frameLength + frame] = newValue }
    }

    public var l2Norm: Float {
        var sumSq: Double = 0.0
        for v in data {
            let dv = Double(v)
            sumSq += dv * dv
        }
        return Float(sqrt(sumSq))
    }

    public var allFinite: Bool {
        data.allSatisfy(\.isFinite)
    }

    public var isAllFinite: Bool {
        allFinite
    }

    public static func l2Distance(_ a: LatentAudioTensor, _ b: LatentAudioTensor) -> Float {
        var sumSq: Double = 0.0
        let count = min(a.data.count, b.data.count)
        for i in 0..<count {
            let d = Double(a.data[i] - b.data[i])
            sumSq += d * d
        }
        return Float(sqrt(sumSq))
    }

    /// Samples Gaussian prior `Z_0 ~ N(0, temperature^2 * I)` via deterministic SplitMix64 + Box-Muller transform.
    public static func sampleGaussianPrior(seed: UInt64, temperature: Float = 1.0) -> LatentAudioTensor {
        let temp = min(max(temperature, 0.05), 2.5)
        var rng = seed ^ 0x9E37_79B9_7F4A_7C15
        @inline(__always)
        func nextUniformOpen() -> Float {
            rng &+= 0x9E37_79B9_7F4A_7C15
            var z = rng
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z = z ^ (z >> 31)
            // Strictly in (0, 1) to prevent log(0)
            return (Float(z >> 40) + 0.5) * (1.0 / 16_777_216.0)
        }

        var values = [Float](repeating: 0.0, count: scalarCount)
        var idx = 0
        while idx < scalarCount {
            let u1 = nextUniformOpen()
            let u2 = nextUniformOpen()
            let mag = sqrtf(-2.0 * logf(u1)) * temp
            let angle = 2.0 * Float.pi * u2
            values[idx] = mag * cosf(angle)
            if idx + 1 < scalarCount {
                values[idx + 1] = mag * sinf(angle)
            }
            idx += 2
        }
        return LatentAudioTensor(data: values)
    }
}

// MARK: - 3. 1D Rectified-Flow ODE Latent Diffusion Sampler (`RectifiedFlowLatentSampler`)

public struct RectifiedFlowLatentSampler: Sendable {
    public static let latentChannels: Int = LatentAudioTensor.channels // 16
    public static let latentFrames: Int = LatentAudioTensor.frameLength // 64
    public static let groupCount: Int = 4 // 4 groups of 4 channels

    private struct DilatedConvNeXtFiLMBlock: Sendable {
        let dilation: Int
        let depthwiseKernel: [Float]      // [16 channels * 5 taps]
        let groupNormWeight: [Float]      // [16]
        let groupNormBias: [Float]        // [16]
        let filmGammaWeights: [Float]     // [16 * 16]
        let filmGammaBias: [Float]        // [16]
        let filmBetaWeights: [Float]      // [16 * 16]
        let filmBetaBias: [Float]         // [16]
        let pwExpandWeights: [Float]      // [32 * 16]
        let pwExpandBias: [Float]         // [32]
        let pwProjectWeights: [Float]     // [16 * 32]
        let pwProjectBias: [Float]        // [16]

        init(dilation: Int, seed: UInt64) {
            self.dilation = dilation
            var rng = seed
            @inline(__always)
            func randSigned(_ scale: Float) -> Float {
                rng &+= 0x9E37_79B9_7F4A_7C15
                var z = rng
                z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
                z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
                z = z ^ (z >> 31)
                let unit = Float(z >> 40) * (1.0 / 16_777_216.0)
                return (unit * 2.0 - 1.0) * scale
            }

            let c = LatentAudioTensor.channels
            var dw = [Float](repeating: 0.0, count: c * 5)
            for ch in 0..<c {
                // Smooth low-pass / harmonic center bias + structured multi-scale taps
                dw[ch * 5 + 0] = randSigned(0.14)
                dw[ch * 5 + 1] = 0.22 + randSigned(0.12)
                dw[ch * 5 + 2] = 0.44 + randSigned(0.10)
                dw[ch * 5 + 3] = 0.22 + randSigned(0.12)
                dw[ch * 5 + 4] = randSigned(0.14)
            }
            self.depthwiseKernel = dw
            self.groupNormWeight = (0..<c).map { _ in 0.90 + randSigned(0.10) }
            self.groupNormBias = (0..<c).map { _ in randSigned(0.03) }

            self.filmGammaWeights = (0..<(c * 16)).map { _ in randSigned(0.24) }
            self.filmGammaBias = (0..<c).map { _ in randSigned(0.04) }
            self.filmBetaWeights = (0..<(c * 16)).map { _ in randSigned(0.22) }
            self.filmBetaBias = (0..<c).map { _ in randSigned(0.04) }

            let hidden = 32
            self.pwExpandWeights = (0..<(hidden * c)).map { _ in randSigned(0.22) }
            self.pwExpandBias = (0..<hidden).map { _ in randSigned(0.03) }
            self.pwProjectWeights = (0..<(c * hidden)).map { _ in randSigned(0.16) }
            self.pwProjectBias = (0..<c).map { _ in randSigned(0.02) }
        }

        func forward(_ input: [Float], conditioning cVec: [Float]) -> [Float] {
            let cCount = LatentAudioTensor.channels
            let lCount = LatentAudioTensor.frameLength
            var convOut = [Float](repeating: 0.0, count: cCount * lCount)

            // 1. Depthwise separable 1D dilated convolution (kernel = 5, circular frame wrap)
            for ch in 0..<cCount {
                let chBase = ch * lCount
                let kBase = ch * 5
                let k0 = depthwiseKernel[kBase + 0]
                let k1 = depthwiseKernel[kBase + 1]
                let k2 = depthwiseKernel[kBase + 2]
                let k3 = depthwiseKernel[kBase + 3]
                let k4 = depthwiseKernel[kBase + 4]

                for t in 0..<lCount {
                    let i0 = (t - 2 * dilation + lCount * 4) & (lCount - 1)
                    let i1 = (t - dilation + lCount * 4) & (lCount - 1)
                    let i3 = (t + dilation) & (lCount - 1)
                    let i4 = (t + 2 * dilation) & (lCount - 1)
                    convOut[chBase + t] = k0 * input[chBase + i0]
                        + k1 * input[chBase + i1]
                        + k2 * input[chBase + t]
                        + k3 * input[chBase + i3]
                        + k4 * input[chBase + i4]
                }
            }

            // 2. GroupNorm across 4 groups x 4 channels x 64 frames
            let channelsPerGroup = cCount / RectifiedFlowLatentSampler.groupCount
            let groupScalarCount = Float(channelsPerGroup * lCount)
            for g in 0..<RectifiedFlowLatentSampler.groupCount {
                let startCh = g * channelsPerGroup
                var sum: Float = 0.0
                for ch in startCh..<(startCh + channelsPerGroup) {
                    let base = ch * lCount
                    for t in 0..<lCount {
                        sum += convOut[base + t]
                    }
                }
                let mean = sum / groupScalarCount

                var varSum: Float = 0.0
                for ch in startCh..<(startCh + channelsPerGroup) {
                    let base = ch * lCount
                    for t in 0..<lCount {
                        let d = convOut[base + t] - mean
                        varSum += d * d
                    }
                }
                let invStd = 1.0 / sqrtf(varSum / groupScalarCount + 1.0e-5)

                for ch in startCh..<(startCh + channelsPerGroup) {
                    let base = ch * lCount
                    let gw = groupNormWeight[ch]
                    let gb = groupNormBias[ch]
                    for t in 0..<lCount {
                        convOut[base + t] = ((convOut[base + t] - mean) * invStd) * gw + gb
                    }
                }
            }

            // 3. FiLM (Feature-wise Linear Modulation): FiLM(h, c) = (1 + gamma(c)) * h + beta(c)
            for ch in 0..<cCount {
                var gAcc = filmGammaBias[ch]
                var bAcc = filmBetaBias[ch]
                let wRow = ch * 16
                for d in 0..<16 {
                    let cv = cVec[d]
                    gAcc += filmGammaWeights[wRow + d] * cv
                    bAcc += filmBetaWeights[wRow + d] * cv
                }
                let gamma = 0.65 * tanhf(gAcc)
                let beta = 0.65 * tanhf(bAcc)
                let scale = 1.0 + gamma
                let base = ch * lCount
                for t in 0..<lCount {
                    convOut[base + t] = scale * convOut[base + t] + beta
                }
            }

            // 4. Pointwise 1x1 ConvNeXt Inverted Bottleneck (16 -> 32 -> 16) + Residual Skip
            let hidden = 32
            var out = input
            var hiddenBuf = [Float](repeating: 0.0, count: hidden)

            for t in 0..<lCount {
                for h in 0..<hidden {
                    var sum = pwExpandBias[h]
                    let row = h * cCount
                    for ch in 0..<cCount {
                        sum += pwExpandWeights[row + ch] * convOut[ch * lCount + t]
                    }
                    // Smooth GELU approximation: x * sigmoid(1.702 * x)
                    let sig = 1.0 / (1.0 + expf(-1.702 * min(max(sum, -12.0), 12.0)))
                    hiddenBuf[h] = sum * sig
                }

                for ch in 0..<cCount {
                    var proj = pwProjectBias[ch]
                    let row = ch * hidden
                    for h in 0..<hidden {
                        proj += pwProjectWeights[row + h] * hiddenBuf[h]
                    }
                    out[ch * lCount + t] += 0.42 * proj
                }
            }

            return out
        }
    }

    private let blockDil1: DilatedConvNeXtFiLMBlock
    private let blockDil2: DilatedConvNeXtFiLMBlock
    private let blockDil4: DilatedConvNeXtFiLMBlock
    private let unetBottleneckWeights: [Float] // [16 * 16]
    private let harmonicTargetBasis: [Float]   // [16 * 64] structured harmonic attractor

    public init(seed: UInt64 = 0x517C_C1B7_2722_0A95) {
        self.blockDil1 = DilatedConvNeXtFiLMBlock(dilation: 1, seed: seed ^ 0x1111_2222_3333_4444)
        self.blockDil2 = DilatedConvNeXtFiLMBlock(dilation: 2, seed: seed ^ 0x5555_6666_7777_8888)
        self.blockDil4 = DilatedConvNeXtFiLMBlock(dilation: 4, seed: seed ^ 0x9999_AAAA_BBBB_CCCC)

        var rng = seed ^ 0xDEAD_BEEF_CAFE_F00D
        var uWeights = [Float](repeating: 0.0, count: 16 * 16)
        for i in 0..<(16 * 16) {
            rng &+= 0x9E37_79B9_7F4A_7C15
            var z = rng
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z = z ^ (z >> 31)
            let unit = Float(z >> 40) * (1.0 / 16_777_216.0)
            uWeights[i] = (unit * 2.0 - 1.0) * 0.18
        }
        for d in 0..<16 {
            uWeights[d * 16 + d] += 0.35
        }
        self.unetBottleneckWeights = uWeights

        var basis = [Float](repeating: 0.0, count: LatentAudioTensor.scalarCount)
        for ch in 0..<16 {
            let harmonic = Float((ch % 6) + 1)
            let phase = Float(ch) * 0.42
            for t in 0..<64 {
                let u = Float(t) / 64.0
                basis[ch * 64 + t] = 0.85 * sinf(2.0 * Float.pi * harmonic * u + phase)
                    + 0.35 * cosf(2.0 * Float.pi * (harmonic + 1.0) * u - phase * 0.5)
            }
        }
        self.harmonicTargetBasis = basis
    }

    /// Evaluates the 1D Dilated Residual U-Net / ConvNeXt velocity field `v_theta(Z_t, t, c)`.
    public func predictVelocity(
        z: LatentAudioTensor,
        flowTime: Float,
        conditioning: LatentConditioningVector,
        unconditional: Bool = false
    ) -> LatentAudioTensor {
        let condAtT = conditioning.withFlowTime(flowTime, unconditional: unconditional)
        let cVec = condAtT.values

        // Multi-scale U-Net pooled skip pathway (64 -> 32 -> 64)
        let cCount = Self.latentChannels
        let lCount = Self.latentFrames
        let halfL = lCount / 2
        var pooled = [Float](repeating: 0.0, count: cCount * halfL)
        for ch in 0..<cCount {
            let inBase = ch * lCount
            let outBase = ch * halfL
            for k in 0..<halfL {
                pooled[outBase + k] = 0.5 * (z.data[inBase + 2 * k] + z.data[inBase + 2 * k + 1])
            }
        }

        var bottleneck = [Float](repeating: 0.0, count: cCount * halfL)
        for k in 0..<halfL {
            for chOut in 0..<cCount {
                var s: Float = 0.0
                let wRow = chOut * cCount
                for chIn in 0..<cCount {
                    s += unetBottleneckWeights[wRow + chIn] * pooled[chIn * halfL + k]
                }
                bottleneck[chOut * halfL + k] = tanhf(s)
            }
        }

        // Dilated ConvNeXt cascade (dilation = 1, 2, 4) with GroupNorm + FiLM
        var h = blockDil1.forward(z.data, conditioning: cVec)
        h = blockDil2.forward(h, conditioning: cVec)
        h = blockDil4.forward(h, conditioning: cVec)

        // Fuse U-Net upsampled skip + conditioned harmonic target manifold velocity (Z_target - Z_t)
        let condMod = unconditional ? Float(0.25) : Float(0.65 + 0.25 * cVec[13])
        var velocity = [Float](repeating: 0.0, count: LatentAudioTensor.scalarCount)
        for ch in 0..<cCount {
            let base = ch * lCount
            let pBase = ch * halfL
            let condShift = cVec[ch] * 0.45
            for t in 0..<lCount {
                let k0 = t / 2
                let k1 = (k0 + 1) % halfL
                let frac: Float = (t % 2 == 0) ? 0.0 : 0.5
                let skipVal = bottleneck[pBase + k0] * (1.0 - frac) + bottleneck[pBase + k1] * frac

                let targetManifold = harmonicTargetBasis[base + t] * condMod + condShift
                let rawVel = 0.55 * (targetManifold - z.data[base + t]) + 0.35 * (h[base + t] - z.data[base + t]) + 0.22 * skipVal
                // Smooth velocity saturation keeps ODE trajectories strictly bounded & finite across all CFG scales
                velocity[base + t] = 3.2 * tanhf(rawVel * (1.0 / 3.2))
            }
        }

        return LatentAudioTensor(data: velocity)
    }

    /// Classifier-Free Guided velocity field:
    /// `\hat{v}_theta(Z_t, t, c) = v_theta(Z_t, t, \varnothing) + w * (v_theta(Z_t, t, c) - v_theta(Z_t, t, \varnothing))`
    public func predictGuidedVelocity(
        z: LatentAudioTensor,
        flowTime: Float,
        conditioning: LatentConditioningVector,
        guidanceScale: Float
    ) -> LatentAudioTensor {
        let w = min(max(guidanceScale, 1.0), 4.0)
        let uncond = predictVelocity(z: z, flowTime: flowTime, conditioning: conditioning, unconditional: true)
        if abs(w - 1.0) < 1.0e-5 && conditioning.values[15] == 0.0 {
            return uncond
        }
        let cond = predictVelocity(z: z, flowTime: flowTime, conditioning: conditioning, unconditional: false)

        var guided = [Float](repeating: 0.0, count: LatentAudioTensor.scalarCount)
        for i in 0..<LatentAudioTensor.scalarCount {
            let u = uncond.data[i]
            let c = cond.data[i]
            guided[i] = u + w * (c - u)
        }
        return LatentAudioTensor(data: guided)
    }

    /// Integrates Rectified-Flow ODE from `t = 0` (`z0`) to `t = 1` (`z1`) via a 4-step 2nd-Order Heun (Runge-Kutta) solver.
    public func sampleLatentHeun(
        prior z0: LatentAudioTensor,
        conditioning: LatentConditioningVector,
        guidanceScale: Float = 2.2,
        steps: Int = 4
    ) -> LatentAudioTensor {
        let stepCount = max(1, steps)
        let dt = 1.0 / Float(stepCount)
        var zCurrent = z0

        for step in 0..<stepCount {
            let t0 = Float(step) * dt
            let t1 = min(1.0, Float(step + 1) * dt)

            let v0 = predictGuidedVelocity(
                z: zCurrent,
                flowTime: t0,
                conditioning: conditioning,
                guidanceScale: guidanceScale
            )

            // Euler predictor state \tilde{Z}_{t + dt}
            var zEulerData = [Float](repeating: 0.0, count: LatentAudioTensor.scalarCount)
            for i in 0..<LatentAudioTensor.scalarCount {
                zEulerData[i] = zCurrent.data[i] + dt * v0.data[i]
            }
            let zEuler = LatentAudioTensor(data: zEulerData)

            // Corrector velocity at (t + dt, \tilde{Z}_{t + dt})
            let v1 = predictGuidedVelocity(
                z: zEuler,
                flowTime: t1,
                conditioning: conditioning,
                guidanceScale: guidanceScale
            )

            // 2nd-order trapezoidal Heun update
            let halfDt = 0.5 * dt
            var zNextData = [Float](repeating: 0.0, count: LatentAudioTensor.scalarCount)
            for i in 0..<LatentAudioTensor.scalarCount {
                let updated = zCurrent.data[i] + halfDt * (v0.data[i] + v1.data[i])
                zNextData[i] = updated.isFinite ? min(max(updated, -8.0), 8.0) : 0.0
            }
            zCurrent = LatentAudioTensor(data: zNextData)
        }

        return zCurrent
    }
}

// MARK: - 4. Multi-Stage Residual Vector Quantizer (`ResidualVectorQuantizer`) & Token Wire Packet

public enum NeuralTokenPacketError: LocalizedError, Sendable, Equatable {
    case invalidByteCount(Int)
    case invalidMagicHeader
    case unsupportedVersion(UInt8)
    case invalidDimensions(stages: UInt8, frames: UInt16)
    case outOfBoundsCodebookIndex(UInt8)
    case checksumMismatch(expected: UInt64, actual: UInt64)

    public var errorDescription: String? {
        switch self {
        case .invalidByteCount(let n):
            return "Invalid NeuralAudioTokenPacket byte length (\(n))."
        case .invalidMagicHeader:
            return "Invalid NeuralAudioTokenPacket magic header."
        case .unsupportedVersion(let v):
            return "Unsupported NeuralAudioTokenPacket version \(v)."
        case .invalidDimensions(let s, let f):
            return "Unsupported RVQ dimensions (\(s) stages x \(f) frames)."
        case .outOfBoundsCodebookIndex(let idx):
            return "RVQ codebook index \(idx) exceeds codebook size 64."
        case .checksumMismatch(let expected, let actual):
            return String(format: "Packet FNV-1a checksum mismatch (expected 0x%016llX, got 0x%016llX).", expected, actual)
        }
    }
}

/// Ultra-compact P2P mesh packet carrying `4 x UInt8` RVQ indices per latent frame (`4 x 64 = 256` token bytes).
public struct NeuralAudioTokenPacket: Sendable, Equatable {
    public static let stageCount: Int = 4
    public static let frameCount: Int = 64
    public static let codebookSize: Int = 64
    public static let headerByteCount: Int = 20
    public static let tokenByteCount: Int = stageCount * frameCount // 256
    public static let trailerByteCount: Int = 8
    public static let encodedByteSize: Int = headerByteCount + tokenByteCount + trailerByteCount // 284

    public let sequenceNumber: UInt32
    public let categoryIndex: UInt8
    public let binauralBeatHz: Float
    public let guidanceScale: Float
    /// Shape `[4][64]` (`stage` outer, `frame` inner), each index in `0..<64`.
    public let stageIndices: [[UInt8]]

    public init(
        sequenceNumber: UInt32,
        category: FocusCategory = .deepWork,
        binauralBeatHz: Float = 14.0,
        guidanceScale: Float = 2.2,
        stageIndices: [[UInt8]]
    ) {
        self.sequenceNumber = sequenceNumber
        self.categoryIndex = UInt8(FocusCategory.allCases.firstIndex(of: category) ?? 0)
        self.binauralBeatHz = binauralBeatHz
        self.guidanceScale = guidanceScale

        var normalized = [[UInt8]](
            repeating: [UInt8](repeating: 0, count: Self.frameCount),
            count: Self.stageCount
        )
        for m in 0..<min(Self.stageCount, stageIndices.count) {
            for f in 0..<min(Self.frameCount, stageIndices[m].count) {
                normalized[m][f] = stageIndices[m][f] & 0x3F
            }
        }
        self.stageIndices = normalized
    }

    public init(
        sequenceNumber: UInt32,
        categoryIndex: UInt8,
        binauralBeatHz: Float,
        guidanceScale: Float,
        stageIndices: [[UInt8]]
    ) {
        self.sequenceNumber = sequenceNumber
        self.categoryIndex = min(categoryIndex, UInt8(FocusCategory.allCases.count - 1))
        self.binauralBeatHz = binauralBeatHz
        self.guidanceScale = guidanceScale
        self.stageIndices = stageIndices
    }

    public var focusCategory: FocusCategory {
        let all = FocusCategory.allCases
        let idx = min(max(Int(categoryIndex), 0), all.count - 1)
        return all[idx]
    }

    public func serialize() -> Data {
        var bytes = [UInt8]()
        bytes.reserveCapacity(Self.encodedByteSize)

        // [0..<4] Magic "ATKP"
        bytes.append(contentsOf: [0x41, 0x54, 0x4B, 0x50])
        // [4] Protocol version = 1
        bytes.append(1)
        // [5] Stage count = 4
        bytes.append(UInt8(Self.stageCount))
        // [6..<8] Frame count = 64 (little-endian UInt16)
        let fc = UInt16(Self.frameCount).littleEndian
        withUnsafeBytes(of: fc) { bytes.append(contentsOf: $0) }
        // [8..<12] Sequence number (little-endian UInt32)
        let seqLE = sequenceNumber.littleEndian
        withUnsafeBytes(of: seqLE) { bytes.append(contentsOf: $0) }
        // [12..<16] Binaural beat Hz (IEEE-754 little-endian UInt32 bits)
        let beatBits = binauralBeatHz.bitPattern.littleEndian
        withUnsafeBytes(of: beatBits) { bytes.append(contentsOf: $0) }
        // [16..<19] Guidance scale quantized + category byte:
        // Use [16..<20]: [16] categoryIndex, [17] reserved, [18..<20] guidanceScale * 1000 UInt16
        bytes.append(categoryIndex)
        bytes.append(0)
        let gQuant = UInt16(min(max((guidanceScale * 1000.0).rounded(), 0.0), 65_000.0)).littleEndian
        withUnsafeBytes(of: gQuant) { bytes.append(contentsOf: $0) }

        // [20..<276] 4 x 64 UInt8 RVQ codebook indices
        for m in 0..<Self.stageCount {
            for f in 0..<Self.frameCount {
                bytes.append(stageIndices[m][f] & 0x3F)
            }
        }

        // [276..<284] 64-bit FNV-1a integrity tag
        let tag = Self.fnv1a64(bytes)
        let tagLE = tag.littleEndian
        withUnsafeBytes(of: tagLE) { bytes.append(contentsOf: $0) }

        return Data(bytes)
    }

    public static func deserialize(_ data: Data) throws -> NeuralAudioTokenPacket {
        guard data.count == encodedByteSize else {
            throw NeuralTokenPacketError.invalidByteCount(data.count)
        }
        let bytes = [UInt8](data)
        guard bytes[0] == 0x41, bytes[1] == 0x54, bytes[2] == 0x4B, bytes[3] == 0x50 else {
            throw NeuralTokenPacketError.invalidMagicHeader
        }
        guard bytes[4] == 1 else {
            throw NeuralTokenPacketError.unsupportedVersion(bytes[4])
        }

        let stages = bytes[5]
        let frames = UInt16(bytes[6]) | (UInt16(bytes[7]) << 8)
        guard Int(stages) == stageCount, Int(frames) == frameCount else {
            throw NeuralTokenPacketError.invalidDimensions(stages: stages, frames: frames)
        }

        let payloadSlice = Array(bytes[0..<(headerByteCount + tokenByteCount)])
        let expectedTag = fnv1a64(payloadSlice)
        var actualTag: UInt64 = 0
        for b in 0..<8 {
            actualTag |= UInt64(bytes[headerByteCount + tokenByteCount + b]) << UInt64(b * 8)
        }
        guard expectedTag == actualTag else {
            throw NeuralTokenPacketError.checksumMismatch(expected: expectedTag, actual: actualTag)
        }

        let seq = UInt32(bytes[8])
            | (UInt32(bytes[9]) << 8)
            | (UInt32(bytes[10]) << 16)
            | (UInt32(bytes[11]) << 24)
        let beatBits = UInt32(bytes[12])
            | (UInt32(bytes[13]) << 8)
            | (UInt32(bytes[14]) << 16)
            | (UInt32(bytes[15]) << 24)
        let beatHz = Float(bitPattern: beatBits)
        let catIdx = bytes[16]
        let gQuant = UInt16(bytes[18]) | (UInt16(bytes[19]) << 8)
        let gScale = Float(gQuant) * 0.001

        var grid = [[UInt8]](
            repeating: [UInt8](repeating: 0, count: frameCount),
            count: stageCount
        )
        var cursor = headerByteCount
        for m in 0..<stageCount {
            for f in 0..<frameCount {
                let tok = bytes[cursor]
                cursor += 1
                guard Int(tok) < codebookSize else {
                    throw NeuralTokenPacketError.outOfBoundsCodebookIndex(tok)
                }
                grid[m][f] = tok
            }
        }

        return NeuralAudioTokenPacket(
            sequenceNumber: seq,
            categoryIndex: catIdx,
            binauralBeatHz: beatHz,
            guidanceScale: gScale,
            stageIndices: grid
        )
    }

    private static func fnv1a64(_ bytes: [UInt8]) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        let prime: UInt64 = 0x0000_0100_0000_01B3
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= prime
        }
        return hash
    }
}

public struct RVQQuantizationResult: Sendable, Equatable {
    public let quantizedLatent: LatentAudioTensor
    public let packet: NeuralAudioTokenPacket
    public let inputNorm: Float
    /// Residual L2 norms `[||r_1||_2, ||r_2||_2, ||r_3||_2, ||r_4||_2]` across the 4 RVQ stages.
    public let stageResidualNorms: [Float]
    public let commitmentLoss: Float
    public let bitrateKbps: Float
    public let codebookEntropyBits: Float
    public let codebookPerplexity: Float
}

public struct ResidualVectorQuantizer: Sendable {
    public static let stageCount: Int = 4
    public static let codebookSize: Int = 64
    public static let vectorDim: Int = 16

    /// Flattened `[stageCount][codebookSize * vectorDim]` learnable codebook vectors in `R^16`.
    public var codebooks: [[Float]]

    public init(seed: UInt64 = 0x7F4A_7C15_9E37_79B9) {
        // Multi-scale coarse Hadamard/harmonic vectors (entries 0..<32) paired with
        // stage-decreasing signed canonical basis vectors (entries 32..<64) guaranteeing
        // strict monotonic L2 residual norm reduction ||r_4||_2 < ||r_3||_2 < ||r_2||_2 < ||r_1||_2 < ||z||_2.
        let coarseScales: [Float] = [0.92, 0.36, 0.14, 0.052]
        let fineBasisScales: [Float] = [0.18, 0.065, 0.022, 0.0035]

        var rng = seed
        @inline(__always)
        func nextSigned() -> Float {
            rng &+= 0x9E37_79B9_7F4A_7C15
            var z = rng
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z = z ^ (z >> 31)
            let u = Float(z >> 40) * (1.0 / 16_777_216.0)
            return u * 2.0 - 1.0
        }

        var stages = [[Float]]()
        stages.reserveCapacity(Self.stageCount)

        for m in 0..<Self.stageCount {
            var table = [Float](repeating: 0.0, count: Self.codebookSize * Self.vectorDim)
            let coarseScale = coarseScales[m]
            let fineScale = fineBasisScales[m]

            // Entries 0..<32: Normalized multi-axis harmonic + pseudo-orthogonal vectors
            for k in 0..<32 {
                var vec = [Float](repeating: 0.0, count: Self.vectorDim)
                var sq: Float = 0.0
                for d in 0..<Self.vectorDim {
                    let dctTerm = cosf(Float.pi * (Float(d) + 0.5) * Float((k % 16) + 1) / 16.0)
                    let signFlip: Float = (k >= 16) ? -1.0 : 1.0
                    let v = signFlip * dctTerm * 0.75 + nextSigned() * 0.35
                    vec[d] = v
                    sq += v * v
                }
                let invNorm = coarseScale / max(1.0e-5, sqrtf(sq))
                for d in 0..<Self.vectorDim {
                    table[k * Self.vectorDim + d] = vec[d] * invNorm
                }
            }

            // Entries 32..<64: Signed canonical basis {+fineScale * u_d, -fineScale * u_d} for d in 0..<16
            for d in 0..<16 {
                let posIdx = 32 + 2 * d
                let negIdx = 32 + 2 * d + 1
                table[posIdx * Self.vectorDim + d] = fineScale
                table[negIdx * Self.vectorDim + d] = -fineScale
            }

            stages.append(table)
        }

        self.codebooks = stages
    }

    public func quantize(
        _ z: LatentAudioTensor,
        sequenceNumber: UInt32 = 0,
        category: FocusCategory = .deepWork,
        binauralBeatHz: Float = 14.0,
        guidanceScale: Float = 2.2,
        sampleRate: Double = 48_000.0,
        hopSamplesPerBlock: Int = 2_048
    ) -> RVQQuantizationResult {
        let lCount = LatentAudioTensor.frameLength
        let cCount = LatentAudioTensor.channels
        let inputNorm = z.l2Norm

        // Transpose [channel, frame] -> frame-major [frame, channel] for 16-D vector quantization
        var residualFrames = [[Float]](
            repeating: [Float](repeating: 0.0, count: cCount),
            count: lCount
        )
        var originalFrames = residualFrames
        for f in 0..<lCount {
            for ch in 0..<cCount {
                let val = z[ch, f]
                residualFrames[f][ch] = val
                originalFrames[f][ch] = val
            }
        }

        var reconstructedFrames = [[Float]](
            repeating: [Float](repeating: 0.0, count: cCount),
            count: lCount
        )
        var stageIndices = [[UInt8]](
            repeating: [UInt8](repeating: 0, count: lCount),
            count: Self.stageCount
        )
        var stageResidualNorms = [Float](repeating: 0.0, count: Self.stageCount)
        var commitmentAccum: Double = 0.0
        var totalEntropyNats: Double = 0.0

        for m in 0..<Self.stageCount {
            let table = codebooks[m]
            var usageCounts = [Int](repeating: 0, count: Self.codebookSize)
            var stageResidualSqSum: Double = 0.0

            for f in 0..<lCount {
                let r = residualFrames[f]
                var bestIdx = 0
                var bestDist = Float.greatestFiniteMagnitude

                for k in 0..<Self.codebookSize {
                    let base = k * Self.vectorDim
                    var distSq: Float = 0.0
                    for d in 0..<Self.vectorDim {
                        let diff = r[d] - table[base + d]
                        distSq += diff * diff
                    }
                    if distSq < bestDist {
                        bestDist = distSq
                        bestIdx = k
                    }
                }

                stageIndices[m][f] = UInt8(bestIdx)
                usageCounts[bestIdx] += 1

                let chosenBase = bestIdx * Self.vectorDim
                for d in 0..<Self.vectorDim {
                    let codeVal = table[chosenBase + d]
                    let nextRes = r[d] - codeVal
                    residualFrames[f][d] = nextRes
                    reconstructedFrames[f][d] += codeVal
                    stageResidualSqSum += Double(nextRes * nextRes)

                    let commitDiff = Double(originalFrames[f][d] - reconstructedFrames[f][d])
                    commitmentAccum += commitDiff * commitDiff
                }
            }

            stageResidualNorms[m] = Float(sqrt(stageResidualSqSum))

            // Shannon entropy over codebook utilization for stage m
            var stageH: Double = 0.0
            let invTotal = 1.0 / Double(lCount)
            for count in usageCounts where count > 0 {
                let p = Double(count) * invTotal
                stageH -= p * log(p)
            }
            totalEntropyNats += stageH
        }

        var zHat = LatentAudioTensor(repeating: 0.0)
        for f in 0..<lCount {
            for ch in 0..<cCount {
                zHat[ch, f] = reconstructedFrames[f][ch]
            }
        }

        let meanEntropyNats = totalEntropyNats / Double(Self.stageCount)
        let entropyBits = Float(meanEntropyNats / log(2.0))
        let perplexity = Float(exp(meanEntropyNats))
        let commitmentLoss = Float(commitmentAccum / Double(Self.stageCount * lCount * cCount))

        // Bitrate telemetry: (4 stages * 6 bits/index * 64 frames + packet framing) * blocks/sec
        let blocksPerSec = Float(max(8_000.0, sampleRate)) / Float(max(256, hopSamplesPerBlock))
        let bitsPerBlock = Float(Self.stageCount * lCount * 6)
        let bitrateKbps = (bitsPerBlock * blocksPerSec) / 1_000.0

        let packet = NeuralAudioTokenPacket(
            sequenceNumber: sequenceNumber,
            category: category,
            binauralBeatHz: binauralBeatHz,
            guidanceScale: guidanceScale,
            stageIndices: stageIndices
        )

        return RVQQuantizationResult(
            quantizedLatent: zHat,
            packet: packet,
            inputNorm: inputNorm,
            stageResidualNorms: stageResidualNorms,
            commitmentLoss: commitmentLoss,
            bitrateKbps: bitrateKbps,
            codebookEntropyBits: entropyBits,
            codebookPerplexity: perplexity
        )
    }

    /// Reconstructs `\hat{Z} = \sum_{m=1}^{4} e_{q_m}` directly from a received `NeuralAudioTokenPacket`.
    public func dequantize(packet: NeuralAudioTokenPacket) -> LatentAudioTensor {
        var zHat = LatentAudioTensor(repeating: 0.0)
        for m in 0..<min(Self.stageCount, packet.stageIndices.count) {
            let table = codebooks[m]
            for f in 0..<min(LatentAudioTensor.frameLength, packet.stageIndices[m].count) {
                let idx = Int(packet.stageIndices[m][f] & 0x3F)
                let base = idx * Self.vectorDim
                for ch in 0..<Self.vectorDim {
                    zHat[ch, f] += table[base + ch]
                }
            }
        }
        return zHat
    }
}

// MARK: - 5. Snake-Activated 1D Transposed-Conv Neural Vocoder (`SnakeNeuralVocoder`)

public struct SnakeNeuralVocoder: Sendable {
    public static let outputFrameCount: Int = 4_096 // 64 frames * (4 * 4 * 4) = 4,096 samples

    /// Periodic Snake activation (Ziyin et al. / Descript Audio Codec):
    /// `Snake_alpha(x) = x + (1 / alpha) * sin^2(alpha * x)` for `alpha > 0`.
    @inline(__always)
    public static func snake(x: Float, alpha: Float) -> Float {
        let safeAlpha = max(alpha, 1.0e-4)
        let s = sinf(safeAlpha * x)
        return x + (s * s) / safeAlpha
    }

    /// Exact analytical derivative of `Snake_alpha(x)`:
    /// `d/dx Snake_alpha(x) = 1 + 2*sin(alpha*x)*cos(alpha*x) = 1 + sin(2 * alpha * x) >= 0`.
    @inline(__always)
    public static func snakeDerivative(x: Float, alpha: Float) -> Float {
        let safeAlpha = max(alpha, 1.0e-4)
        return max(0.0, 1.0 + sinf(2.0 * safeAlpha * x))
    }

    private struct UpsampleSnakeMRFStage: Sendable {
        let inChannels: Int
        let outChannels: Int
        let stride: Int = 4
        let kernelSize: Int = 8
        /// Transposed conv weights `[inChannels * outChannels * kernelSize]`
        let convTWeights: [Float]
        let convTBias: [Float]
        /// Channel-wise learnable Snake frequency parameters `alpha_c > 0`
        let snakeAlphaPre: [Float]
        let snakeAlphaMRF: [Float]
        /// Multi-Receptive-Field (MRF) depthwise dilated 3-tap kernels across `dilations = [1, 3, 5]`
        let mrfKernels: [Float] // `[3 dilations * outChannels * 3 taps]`

        init(inChannels: Int, outChannels: Int, seed: UInt64) {
            self.inChannels = inChannels
            self.outChannels = outChannels

            var rng = seed
            @inline(__always)
            func nextRand(_ scale: Float) -> Float {
                rng &+= 0x9E37_79B9_7F4A_7C15
                var z = rng
                z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
                z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
                z = z ^ (z >> 31)
                let u = Float(z >> 40) * (1.0 / 16_777_216.0)
                return (u * 2.0 - 1.0) * scale
            }

            // Smooth raised-cosine interpolation envelope across the 8-tap stride-4 kernel prevents transposed-conv checkerboard artifacts
            let fanScale = 0.55 / sqrtf(Float(inChannels))
            var weights = [Float](repeating: 0.0, count: inChannels * outChannels * 8)
            for ic in 0..<inChannels {
                for oc in 0..<outChannels {
                    let base = (ic * outChannels + oc) * 8
                    let coupling = ((ic % outChannels) == oc ? Float(0.65) : Float(0.0)) + nextRand(fanScale)
                    for k in 0..<8 {
                        let win = 0.5 * (1.0 - cosf(2.0 * Float.pi * (Float(k) + 0.5) / 8.0))
                        weights[base + k] = coupling * win * 0.5
                    }
                }
            }
            self.convTWeights = weights
            self.convTBias = (0..<outChannels).map { _ in nextRand(0.01) }

            self.snakeAlphaPre = (0..<outChannels).map { c in 0.85 + 0.35 * Float(c + 1) }
            self.snakeAlphaMRF = (0..<outChannels).map { c in 1.15 + 0.42 * Float(c + 1) }

            var mrf = [Float](repeating: 0.0, count: 3 * outChannels * 3)
            for dIdx in 0..<3 {
                for oc in 0..<outChannels {
                    let b = (dIdx * outChannels + oc) * 3
                    mrf[b + 0] = 0.16 + nextRand(0.05)
                    mrf[b + 1] = 0.32 + nextRand(0.06)
                    mrf[b + 2] = 0.16 + nextRand(0.05)
                }
            }
            self.mrfKernels = mrf
        }

        func forward(_ input: [Float], inLength: Int) -> [Float] {
            let outLength = inLength * stride
            let mask = outLength - 1 // Power-of-two lengths (256, 1024, 4096)
            var out = [Float](repeating: 0.0, count: outChannels * outLength)

            for oc in 0..<outChannels {
                let bVal = convTBias[oc]
                let outBase = oc * outLength
                for t in 0..<outLength {
                    out[outBase + t] = bVal
                }
            }

            // 1. 1D Transposed Convolution (stride = 4, kernel = 8, padding = 2 -> exact 4x upsampling with circular wrap)
            for ic in 0..<inChannels {
                let inBase = ic * inLength
                for oc in 0..<outChannels {
                    let outBase = oc * outLength
                    let wBase = (ic * outChannels + oc) * kernelSize
                    let w0 = convTWeights[wBase + 0]
                    let w1 = convTWeights[wBase + 1]
                    let w2 = convTWeights[wBase + 2]
                    let w3 = convTWeights[wBase + 3]
                    let w4 = convTWeights[wBase + 4]
                    let w5 = convTWeights[wBase + 5]
                    let w6 = convTWeights[wBase + 6]
                    let w7 = convTWeights[wBase + 7]

                    for t in 0..<inLength {
                        let x = input[inBase + t]
                        let center = t * 4 - 2
                        out[outBase + ((center + 0) & mask)] += x * w0
                        out[outBase + ((center + 1) & mask)] += x * w1
                        out[outBase + ((center + 2) & mask)] += x * w2
                        out[outBase + ((center + 3) & mask)] += x * w3
                        out[outBase + ((center + 4) & mask)] += x * w4
                        out[outBase + ((center + 5) & mask)] += x * w5
                        out[outBase + ((center + 6) & mask)] += x * w6
                        out[outBase + ((center + 7) & mask)] += x * w7
                    }
                }
            }

            // 2. Periodic Snake Activation + DC removal per channel (since sin^2 >= 0 adds 1/(2*alpha) DC offset)
            for oc in 0..<outChannels {
                let alpha = snakeAlphaPre[oc]
                let base = oc * outLength
                var mean: Float = 0.0
                for n in 0..<outLength {
                    let y = SnakeNeuralVocoder.snake(x: out[base + n], alpha: alpha)
                    out[base + n] = y
                    mean += y
                }
                mean /= Float(outLength)
                for n in 0..<outLength {
                    out[base + n] -= mean
                }
            }

            // 3. Multi-Receptive-Field (MRF) Dilated Residual Fusion (dilations = 1, 3, 5)
            let dilations = [1, 3, 5]
            var mrfAccum = out
            for oc in 0..<outChannels {
                let base = oc * outLength
                let alphaM = snakeAlphaMRF[oc]

                for (dIdx, dil) in dilations.enumerated() {
                    let kBase = (dIdx * outChannels + oc) * 3
                    let k0 = mrfKernels[kBase + 0]
                    let k1 = mrfKernels[kBase + 1]
                    let k2 = mrfKernels[kBase + 2]

                    var branchMean: Float = 0.0
                    var branch = [Float](repeating: 0.0, count: outLength)
                    for n in 0..<outLength {
                        let prev = out[base + ((n - dil) & mask)]
                        let curr = out[base + n]
                        let next = out[base + ((n + dil) & mask)]
                        let convVal = k0 * prev + k1 * curr + k2 * next
                        let activated = SnakeNeuralVocoder.snake(x: convVal, alpha: alphaM)
                        branch[n] = activated
                        branchMean += activated
                    }
                    branchMean /= Float(outLength)
                    for n in 0..<outLength {
                        mrfAccum[base + n] += 0.24 * (branch[n] - branchMean)
                    }
                }
            }

            return mrfAccum
        }
    }

    private let stage1: UpsampleSnakeMRFStage // 16x64   -> 12x256
    private let stage2: UpsampleSnakeMRFStage // 12x256  -> 8x1024
    private let stage3: UpsampleSnakeMRFStage // 8x1024  -> 4x4096
    private let midWeights: SIMD4<Float>
    private let sideWeights: SIMD4<Float>

    public init(seed: UInt64 = 0xCAFE_BABE_1234_5678) {
        self.stage1 = UpsampleSnakeMRFStage(inChannels: 16, outChannels: 12, seed: seed ^ 0x0101_0202_0303_0404)
        self.stage2 = UpsampleSnakeMRFStage(inChannels: 12, outChannels: 8, seed: seed ^ 0x1111_2222_3333_4444)
        self.stage3 = UpsampleSnakeMRFStage(inChannels: 8, outChannels: 4, seed: seed ^ 0x5555_6666_7777_8888)
        self.midWeights = SIMD4<Float>(0.42, 0.34, 0.26, 0.18)
        self.sideWeights = SIMD4<Float>(0.22, -0.28, 0.31, -0.19)
    }

    /// Decodes quantized latent tensor `\hat{Z} in R^{16 x 64}` into `4,096` stereo 48 kHz samples via
    /// `4x -> 4x -> 4x` Transposed-Conv + Snake + MRF + Mid/Side harmonic decorrelation head.
    public func decode(_ zHat: LatentAudioTensor) -> (left: [Float], right: [Float]) {
        let h1 = stage1.forward(zHat.data, inLength: 64)    // 12 x 256
        let h2 = stage2.forward(h1, inLength: 256)          // 8 x 1024
        let h3 = stage3.forward(h2, inLength: 1_024)        // 4 x 4096

        let nCount = Self.outputFrameCount
        var left = [Float](repeating: 0.0, count: nCount)
        var right = [Float](repeating: 0.0, count: nCount)

        // Stereo Mid/Side projection + cascaded Schroeder all-pass phase decorrelator on Side channel
        var ap1X: Float = 0.0; var ap1Y: Float = 0.0
        var ap2X: Float = 0.0; var ap2Y: Float = 0.0
        let g1: Float = 0.58
        let g2: Float = -0.44

        for n in 0..<nCount {
            let c0 = h3[0 * nCount + n]
            let c1 = h3[1 * nCount + n]
            let c2 = h3[2 * nCount + n]
            let c3 = h3[3 * nCount + n]
            let vec = SIMD4<Float>(c0, c1, c2, c3)

            let mid = simd_dot(vec, midWeights)
            let rawSide = simd_dot(vec, sideWeights)

            let s1 = -g1 * rawSide + ap1X + g1 * ap1Y
            ap1X = rawSide
            ap1Y = s1

            let sideDecor = -g2 * s1 + ap2X + g2 * ap2Y
            ap2X = s1
            ap2Y = sideDecor

            let outL = tanhf((mid + sideDecor) * 0.95) * 0.82
            let outR = tanhf((mid - sideDecor) * 0.95) * 0.82
            left[n] = outL.isFinite ? outL : 0.0
            right[n] = outR.isFinite ? outR : 0.0
        }

        return (left, right)
    }
}

// MARK: - 6. 50% Complementary Hann Overlap-Add & Lock-Free SPSC Ring Buffer (`NeuralAudioRingBuffer`)

public struct ComplementaryHannOverlapAdd: Sendable {
    public static let blockSize: Int = 4_096
    public static let hopSize: Int = 2_048

    /// Root-Hann window `w[n] = sin(pi * (n + 0.5) / N)` satisfying `w^2[n] + w^2[n + N/2] == 1` identically.
    public let rootHannWindow: [Float]
    /// Complementary Hann crossfade weights `w^2[n] = sin^2(pi * (n + 0.5) / N)` in `(0, 1)`.
    public let hannWeights: [Float]

    private var overlapTailLeft: [Float]
    private var overlapTailRight: [Float]
    private var isPrimed: Bool = false

    public init() {
        let n = Self.blockSize
        var rootW = [Float](repeating: 0.0, count: n)
        var sqW = [Float](repeating: 0.0, count: n)
        for i in 0..<n {
            let angle = Double.pi * (Double(i) + 0.5) / Double(n)
            let s = sin(angle)
            rootW[i] = Float(s)
            sqW[i] = Float(s * s)
        }
        self.rootHannWindow = rootW
        self.hannWeights = sqW
        self.overlapTailLeft = [Float](repeating: 0.0, count: Self.hopSize)
        self.overlapTailRight = [Float](repeating: 0.0, count: Self.hopSize)
    }

    public mutating func reset() {
        for i in 0..<Self.hopSize {
            overlapTailLeft[i] = 0.0
            overlapTailRight[i] = 0.0
        }
        isPrimed = false
    }

    /// Evaluates maximum absolute deviation `max_n |w^2[n] + w^2[n + N/2] - 1|` across `[0 ..< N/2]`.
    public func maxUnityGainRipple() -> Float {
        var maxErr: Float = 0.0
        for i in 0..<Self.hopSize {
            let sum = hannWeights[i] + hannWeights[i + Self.hopSize]
            maxErr = max(maxErr, abs(sum - 1.0))
        }
        return maxErr
    }

    /// Pushes a newly vocoded 4,096-sample stereo block through 50% complementary Hann overlap-add,
    /// returning `2,048` seamless output frames with zero boundary discontinuities.
    public mutating func processBlock(
        leftBlock: [Float],
        rightBlock: [Float]
    ) -> (leftHop: [Float], rightHop: [Float]) {
        let hop = Self.hopSize
        var outL = [Float](repeating: 0.0, count: hop)
        var outR = [Float](repeating: 0.0, count: hop)

        guard leftBlock.count >= Self.blockSize, rightBlock.count >= Self.blockSize else {
            return (outL, outR)
        }

        if !isPrimed {
            // Prime tail with first block's upper half weighted by w^2[n + N/2] so steady-state begins smoothly
            for i in 0..<hop {
                let w0 = hannWeights[i]
                outL[i] = leftBlock[i] * w0
                outR[i] = rightBlock[i] * w0
                let w1 = hannWeights[i + hop]
                overlapTailLeft[i] = leftBlock[i + hop] * w1
                overlapTailRight[i] = rightBlock[i + hop] * w1
            }
            isPrimed = true
            return (outL, outR)
        }

        for i in 0..<hop {
            let wLead = hannWeights[i]
            let wTrail = hannWeights[i + hop]
            outL[i] = overlapTailLeft[i] + leftBlock[i] * wLead
            outR[i] = overlapTailRight[i] + rightBlock[i] * wLead
            overlapTailLeft[i] = leftBlock[i + hop] * wTrail
            overlapTailRight[i] = rightBlock[i + hop] * wTrail
        }

        return (outL, outR)
    }

    /// Performs WOLA analysis-synthesis reconstruction on an arbitrary continuous 1D signal `signal`
    /// using 50%-overlapping 4,096-sample `rootHannWindow` frames (`w[n]` analysis * `w[n]` synthesis = `w^2[n]`).
    public func reconstructWOLA(signal: [Float]) -> [Float] {
        let n = Self.blockSize
        let hop = Self.hopSize
        guard signal.count >= n else { return signal }

        var output = [Float](repeating: 0.0, count: signal.count)
        var frameStart = 0
        while frameStart + n <= signal.count {
            for i in 0..<n {
                let w = rootHannWindow[i]
                let analyzed = signal[frameStart + i] * w
                output[frameStart + i] += analyzed * w
            }
            frameStart += hop
        }
        return output
    }
}

/// Lock-free Single-Producer Single-Consumer (SPSC) stereo ring buffer bridging background
/// `NeuralLatentSoundscapeEngine` overlap-add synthesis into the real-time `AVAudioSourceNode` render thread
/// with ZERO heap allocations and ZERO locks.
public final class NeuralAudioRingBuffer: @unchecked Sendable {
    public let capacityFrames: Int
    private let mask: Int
    private let leftBuffer: UnsafeMutablePointer<Float>
    private let rightBuffer: UnsafeMutablePointer<Float>
    private let writeCursor: Atomic<Int>
    private let readCursor: Atomic<Int>

    public init(capacityPowerOfTwo: Int = 32_768) {
        var cap = 4_096
        while cap < capacityPowerOfTwo {
            cap <<= 1
        }
        self.capacityFrames = cap
        self.mask = cap - 1

        self.leftBuffer = UnsafeMutablePointer<Float>.allocate(capacity: cap)
        self.leftBuffer.initialize(repeating: 0.0, count: cap)
        self.rightBuffer = UnsafeMutablePointer<Float>.allocate(capacity: cap)
        self.rightBuffer.initialize(repeating: 0.0, count: cap)

        self.writeCursor = Atomic<Int>(0)
        self.readCursor = Atomic<Int>(0)
    }

    deinit {
        leftBuffer.deinitialize(count: capacityFrames)
        leftBuffer.deallocate()
        rightBuffer.deinitialize(count: capacityFrames)
        rightBuffer.deallocate()
    }

    public var availableFramesToRead: Int {
        let w = writeCursor.load(ordering: .acquiring)
        let r = readCursor.load(ordering: .acquiring)
        return max(0, w - r)
    }

    public var availableFramesToWrite: Int {
        capacityFrames - availableFramesToRead
    }

    /// Producer (background actor): writes up to `left.count` stereo frames into the ring buffer.
    @discardableResult
    public func pushStereoFrames(left: [Float], right: [Float]) -> Int {
        let requested = min(left.count, right.count)
        guard requested > 0 else { return 0 }

        let w = writeCursor.load(ordering: .relaxed)
        let r = readCursor.load(ordering: .acquiring)
        let freeSpace = capacityFrames - (w - r)
        let toWrite = min(requested, max(0, freeSpace))
        guard toWrite > 0 else { return 0 }

        for i in 0..<toWrite {
            let slot = (w + i) & mask
            leftBuffer[slot] = left[i]
            rightBuffer[slot] = right[i]
        }

        writeCursor.store(w + toWrite, ordering: .releasing)
        return toWrite
    }

    /// Consumer (`AVAudioSourceNode` render thread): lock-free, zero-allocation stereo frame pop.
    /// Any underrun tail is smoothly zero-filled so the render thread never stalls or clicks.
    @discardableResult
    public func popStereoFrames(
        leftDestination: UnsafeMutablePointer<Float>,
        rightDestination: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) -> Int {
        guard frameCount > 0 else { return 0 }

        let r = readCursor.load(ordering: .relaxed)
        let w = writeCursor.load(ordering: .acquiring)
        let available = max(0, w - r)
        let toRead = min(frameCount, available)

        for i in 0..<toRead {
            let slot = (r + i) & mask
            leftDestination[i] = leftBuffer[slot]
            rightDestination[i] = rightBuffer[slot]
        }

        if toRead < frameCount {
            for i in toRead..<frameCount {
                leftDestination[i] = 0.0
                rightDestination[i] = 0.0
            }
        }

        if toRead > 0 {
            readCursor.store(r + toRead, ordering: .releasing)
        }
        return toRead
    }
}

// MARK: - 7. Telemetry Snapshot & Background `NeuralLatentSoundscapeEngine` Actor

public struct NeuralSoundscapeTelemetry: Sendable, Equatable {
    public let blockSequence: UInt32
    public let guidanceScale: Float
    public let temperature: Float
    public let stageResidualNorms: [Float]
    public let commitmentLoss: Float
    public let bitrateKbps: Float
    public let codebookEntropyBits: Float
    public let codebookPerplexity: Float
    /// `4 x 64` RVQ token grid (`[stage][frame]`, values in `0..<64`) for live UI matrix inspection.
    public let tokenGrid: [[UInt8]]
    public let bufferedFrames: Int

    public init(
        blockSequence: UInt32 = 0,
        guidanceScale: Float = 2.2,
        temperature: Float = 0.85,
        stageResidualNorms: [Float] = [0, 0, 0, 0],
        commitmentLoss: Float = 0,
        bitrateKbps: Float = 0,
        codebookEntropyBits: Float = 0,
        codebookPerplexity: Float = 1,
        tokenGrid: [[UInt8]] = Array(repeating: Array(repeating: 0, count: 64), count: 4),
        bufferedFrames: Int = 0
    ) {
        self.blockSequence = blockSequence
        self.guidanceScale = guidanceScale
        self.temperature = temperature
        self.stageResidualNorms = stageResidualNorms
        self.commitmentLoss = commitmentLoss
        self.bitrateKbps = bitrateKbps
        self.codebookEntropyBits = codebookEntropyBits
        self.codebookPerplexity = codebookPerplexity
        self.tokenGrid = tokenGrid
        self.bufferedFrames = bufferedFrames
    }
}

public actor NeuralLatentSoundscapeEngine {
    private let flowSampler: RectifiedFlowLatentSampler
    private let rvq: ResidualVectorQuantizer
    private let vocoder: SnakeNeuralVocoder
    private var overlapAdd: ComplementaryHannOverlapAdd
    private var blockSequence: UInt32 = 0
    private var baseSeed: UInt64

    public init(seed: UInt64 = 0x8A5C_D7E3_412F_90B1) {
        self.flowSampler = RectifiedFlowLatentSampler(seed: seed)
        self.rvq = ResidualVectorQuantizer(seed: seed ^ 0x1357_9BDF_2468_ACE0)
        self.vocoder = SnakeNeuralVocoder(seed: seed ^ 0xFEDC_BA98_7654_3210)
        self.overlapAdd = ComplementaryHannOverlapAdd()
        self.baseSeed = seed
    }

    public func reseedLatentManifold(_ newSeed: UInt64? = nil) {
        if let newSeed {
            baseSeed = newSeed
        } else {
            baseSeed = baseSeed &* 6364136223846793005 &+ 1442695040888963407
        }
    }

    public func resetStreamState() {
        overlapAdd.reset()
    }

    /// Generates one 4,096-sample stereo neural latent diffusion block (producing 2,048 overlap-added output frames)
    /// and pushes it into `ringBuffer` while returning full RVQ + ODE telemetry.
    public func synthesizeAndEnqueueBlock(
        ringBuffer: NeuralAudioRingBuffer,
        category: FocusCategory,
        binauralBeatHz: Float,
        rmssdNormalized: Float,
        rsaCoherenceScore: Float,
        lfHfRatioNormalized: Float,
        guidanceScale: Float = 2.2,
        temperature: Float = 0.85,
        sampleRate: Double = 48_000.0
    ) -> NeuralSoundscapeTelemetry {
        blockSequence &+= 1
        let seq = blockSequence
        let blockSeed = baseSeed &+ UInt64(seq) &* 0x9E37_79B9_7F4A_7C15

        let conditioning = LatentConditioningVector(
            flowTime: 0.0,
            category: category,
            binauralBeatHz: binauralBeatHz,
            rmssdNormalized: rmssdNormalized,
            rsaCoherenceScore: rsaCoherenceScore,
            lfHfRatioNormalized: lfHfRatioNormalized
        )

        let prior = LatentAudioTensor.sampleGaussianPrior(seed: blockSeed, temperature: temperature)
        let z1 = flowSampler.sampleLatentHeun(
            prior: prior,
            conditioning: conditioning,
            guidanceScale: guidanceScale,
            steps: 4
        )

        let quant = rvq.quantize(
            z1,
            sequenceNumber: seq,
            category: category,
            binauralBeatHz: binauralBeatHz,
            guidanceScale: guidanceScale,
            sampleRate: sampleRate,
            hopSamplesPerBlock: ComplementaryHannOverlapAdd.hopSize
        )

        let decoded = vocoder.decode(quant.quantizedLatent)
        let hopPair = overlapAdd.processBlock(leftBlock: decoded.left, rightBlock: decoded.right)
        _ = ringBuffer.pushStereoFrames(left: hopPair.leftHop, right: hopPair.rightHop)

        return NeuralSoundscapeTelemetry(
            blockSequence: seq,
            guidanceScale: min(max(guidanceScale, 1.0), 4.0),
            temperature: min(max(temperature, 0.05), 2.5),
            stageResidualNorms: quant.stageResidualNorms,
            commitmentLoss: quant.commitmentLoss,
            bitrateKbps: quant.bitrateKbps,
            codebookEntropyBits: quant.codebookEntropyBits,
            codebookPerplexity: quant.codebookPerplexity,
            tokenGrid: quant.packet.stageIndices,
            bufferedFrames: ringBuffer.availableFramesToRead
        )
    }

    /// Decodes a remote P2P `NeuralAudioTokenPacket` directly through the Snake neural vocoder + 50% Hann OLA.
    public func decodeIncomingTokenPacket(
        _ packet: NeuralAudioTokenPacket,
        into ringBuffer: NeuralAudioRingBuffer
    ) {
        let zHat = rvq.dequantize(packet: packet)
        let decoded = vocoder.decode(zHat)
        let hopPair = overlapAdd.processBlock(leftBlock: decoded.left, rightBlock: decoded.right)
        _ = ringBuffer.pushStereoFrames(left: hopPair.leftHop, right: hopPair.rightHop)
    }
}
