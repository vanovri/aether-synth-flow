// MARK: - FILE: ReverbAndFMDSP.swift

import Foundation
import simd

// MARK: - 1. 8-Channel Normalized Walsh-Hadamard FDN Reverb with Schroeder Diffusers

public struct HadamardFDNReverbKernel: Sendable {
    public static let channelCount: Int = 8
    public static let baseDelayLengths48k: [Int] = [1087, 1283, 1511, 1777, 2027, 2311, 2657, 2999]
    public static let baseInputDiffuserLengths48k: [Int] = [149, 211]
    public static let baseOutputDiffuserLengths48k: [Int] = [179, 251]

    public let sampleRate: Double
    public let delayLengths: [Int]
    public let inputDiffuserLengths: [Int]
    public let outputDiffuserLengths: [Int]

    // Flat pre-allocated contiguous buffers for zero heap allocations during audio rendering
    private var fdnBuffer: [Float]
    private let fdnOffsets: (Int, Int, Int, Int, Int, Int, Int, Int)
    private let fdnLengths: (Int, Int, Int, Int, Int, Int, Int, Int)
    private let fdnDelaySeconds: SIMD8<Float>
    private var fdnIndices: (Int, Int, Int, Int, Int, Int, Int, Int) = (0, 0, 0, 0, 0, 0, 0, 0)
    private var dampingStates: SIMD8<Float> = .zero

    // Pre-allocated stereo input & output Schroeder all-pass decorrelation diffusers
    private var diffuserBuffer: [Float]
    private let inDiffOffsetL: Int
    private let inDiffOffsetR: Int
    private let outDiffOffsetL: Int
    private let outDiffOffsetR: Int
    private let inDiffLenL: Int
    private let inDiffLenR: Int
    private let outDiffLenL: Int
    private let outDiffLenR: Int
    private var inDiffIdxL: Int = 0
    private var inDiffIdxR: Int = 0
    private var outDiffIdxL: Int = 0
    private var outDiffIdxR: Int = 0

    // Cached feedback gain state so pow() only runs when decaySeconds changes
    private var cachedDecaySeconds: Float = -1.0
    private var cachedFeedbackGains: SIMD8<Float> = .zero

    public init(sampleRate: Double = 48_000.0) {
        let safeRate = max(8_000.0, sampleRate)
        self.sampleRate = safeRate
        let scale = safeRate / 48_000.0

        var scaledPrimes = [Int]()
        scaledPrimes.reserveCapacity(Self.channelCount)
        var previousPrime = 2
        for base in Self.baseDelayLengths48k {
            let rawScaled = max(17, Int((Double(base) * scale).rounded()))
            let candidate = abs(safeRate - 48_000.0) < 0.5 ? base : Self.nextPrime(atLeast: max(rawScaled, previousPrime + 2))
            scaledPrimes.append(candidate)
            previousPrime = candidate
        }
        self.delayLengths = scaledPrimes

        let inL = abs(safeRate - 48_000.0) < 0.5
            ? Self.baseInputDiffuserLengths48k[0]
            : Self.nextPrime(atLeast: max(11, Int((Double(Self.baseInputDiffuserLengths48k[0]) * scale).rounded())))
        let inR = abs(safeRate - 48_000.0) < 0.5
            ? Self.baseInputDiffuserLengths48k[1]
            : Self.nextPrime(atLeast: max(inL + 2, Int((Double(Self.baseInputDiffuserLengths48k[1]) * scale).rounded())))
        let outL = abs(safeRate - 48_000.0) < 0.5
            ? Self.baseOutputDiffuserLengths48k[0]
            : Self.nextPrime(atLeast: max(13, Int((Double(Self.baseOutputDiffuserLengths48k[0]) * scale).rounded())))
        let outR = abs(safeRate - 48_000.0) < 0.5
            ? Self.baseOutputDiffuserLengths48k[1]
            : Self.nextPrime(atLeast: max(outL + 2, Int((Double(Self.baseOutputDiffuserLengths48k[1]) * scale).rounded())))

        self.inputDiffuserLengths = [inL, inR]
        self.outputDiffuserLengths = [outL, outR]

        var offsets = [Int](repeating: 0, count: Self.channelCount)
        var totalFDNSamples = 0
        for ch in 0..<Self.channelCount {
            offsets[ch] = totalFDNSamples
            totalFDNSamples += scaledPrimes[ch]
        }

        self.fdnBuffer = [Float](repeating: 0.0, count: totalFDNSamples)
        self.fdnOffsets = (
            offsets[0], offsets[1], offsets[2], offsets[3],
            offsets[4], offsets[5], offsets[6], offsets[7]
        )
        self.fdnLengths = (
            scaledPrimes[0], scaledPrimes[1], scaledPrimes[2], scaledPrimes[3],
            scaledPrimes[4], scaledPrimes[5], scaledPrimes[6], scaledPrimes[7]
        )

        let invFs = Float(1.0 / safeRate)
        self.fdnDelaySeconds = SIMD8<Float>(
            Float(scaledPrimes[0]) * invFs,
            Float(scaledPrimes[1]) * invFs,
            Float(scaledPrimes[2]) * invFs,
            Float(scaledPrimes[3]) * invFs,
            Float(scaledPrimes[4]) * invFs,
            Float(scaledPrimes[5]) * invFs,
            Float(scaledPrimes[6]) * invFs,
            Float(scaledPrimes[7]) * invFs
        )

        self.inDiffLenL = inL
        self.inDiffLenR = inR
        self.outDiffLenL = outL
        self.outDiffLenR = outR

        self.inDiffOffsetL = 0
        self.inDiffOffsetR = inL
        self.outDiffOffsetL = inL + inR
        self.outDiffOffsetR = inL + inR + outL
        self.diffuserBuffer = [Float](repeating: 0.0, count: inL + inR + outL + outR)

        updateFeedbackGainsIfNeeded(decaySeconds: 2.4)
    }

    private static func isPrime(_ n: Int) -> Bool {
        if n < 2 { return false }
        if n == 2 || n == 3 { return true }
        if n % 2 == 0 || n % 3 == 0 { return false }
        var d = 5
        while d * d <= n {
            if n % d == 0 || n % (d + 2) == 0 { return false }
            d += 6
        }
        return true
    }

    private static func nextPrime(atLeast value: Int) -> Int {
        var candidate = max(2, value)
        if candidate > 2 && candidate % 2 == 0 {
            candidate += 1
        }
        while !isPrime(candidate) {
            candidate += 2
        }
        return candidate
    }

    /// Fast recursive in-place normalized 8x8 Walsh-Hadamard orthogonal transform:
    /// `y = (H_8 / sqrt(8)) * x`, preserving Euclidean L2 norm `||y||_2 == ||x||_2`.
    @inline(__always)
    public static func applyNormalizedWalshHadamard8(_ v: inout SIMD8<Float>) {
        // Stage 1: stride-1 butterflies
        let a0 = v[0] + v[1]; let a1 = v[0] - v[1]
        let a2 = v[2] + v[3]; let a3 = v[2] - v[3]
        let a4 = v[4] + v[5]; let a5 = v[4] - v[5]
        let a6 = v[6] + v[7]; let a7 = v[6] - v[7]

        // Stage 2: stride-2 butterflies
        let b0 = a0 + a2; let b2 = a0 - a2
        let b1 = a1 + a3; let b3 = a1 - a3
        let b4 = a4 + a6; let b6 = a4 - a6
        let b5 = a5 + a7; let b7 = a5 - a7

        // Stage 3: stride-4 butterflies + orthonormal 1 / sqrt(8) scaling
        let invSqrt8: Float = 0.35355339059327379
        v = SIMD8<Float>(
            (b0 + b4) * invSqrt8,
            (b1 + b5) * invSqrt8,
            (b2 + b6) * invSqrt8,
            (b3 + b7) * invSqrt8,
            (b0 - b4) * invSqrt8,
            (b1 - b5) * invSqrt8,
            (b2 - b6) * invSqrt8,
            (b3 - b7) * invSqrt8
        )
    }

    @inline(__always)
    private mutating func updateFeedbackGainsIfNeeded(decaySeconds: Float) {
        let safeDecay = max(0.15, decaySeconds)
        guard abs(safeDecay - cachedDecaySeconds) > 1.0e-5 else { return }
        cachedDecaySeconds = safeDecay
        let exponentScale = -3.0 / safeDecay
        cachedFeedbackGains = SIMD8<Float>(
            powf(10.0, exponentScale * fdnDelaySeconds[0]),
            powf(10.0, exponentScale * fdnDelaySeconds[1]),
            powf(10.0, exponentScale * fdnDelaySeconds[2]),
            powf(10.0, exponentScale * fdnDelaySeconds[3]),
            powf(10.0, exponentScale * fdnDelaySeconds[4]),
            powf(10.0, exponentScale * fdnDelaySeconds[5]),
            powf(10.0, exponentScale * fdnDelaySeconds[6]),
            powf(10.0, exponentScale * fdnDelaySeconds[7])
        )
    }

    @inline(__always)
    private mutating func stepSchroederAllPass(
        input: Float,
        gain: Float,
        offset: Int,
        length: Int,
        index: inout Int
    ) -> Float {
        let bufPos = offset + index
        let delayed = diffuserBuffer[bufPos]
        let state = input + gain * delayed
        let output = delayed - gain * state
        diffuserBuffer[bufPos] = state
        index += 1
        if index >= length { index = 0 }
        return output
    }

    public mutating func reset() {
        for i in 0..<fdnBuffer.count {
            fdnBuffer[i] = 0.0
        }
        for i in 0..<diffuserBuffer.count {
            diffuserBuffer[i] = 0.0
        }
        fdnIndices = (0, 0, 0, 0, 0, 0, 0, 0)
        dampingStates = .zero
        inDiffIdxL = 0
        inDiffIdxR = 0
        outDiffIdxL = 0
        outDiffIdxR = 0
    }

    @inline(__always)
    public mutating func processStereoSample(
        leftIn: Float,
        rightIn: Float,
        wetMix: Float,
        decaySeconds: Float,
        damping: Float
    ) -> (Float, Float) {
        updateFeedbackGainsIfNeeded(decaySeconds: decaySeconds)

        let clampedWet = min(max(wetMix, 0.0), 1.0)
        let clampedDamp = min(max(damping, 0.0), 0.985)
        let oneMinusDamp = 1.0 - clampedDamp

        // 1. Stereo input Schroeder all-pass decorrelation ([149, 211] @ 48 kHz)
        let diffInL = stepSchroederAllPass(
            input: leftIn,
            gain: 0.61803399,
            offset: inDiffOffsetL,
            length: inDiffLenL,
            index: &inDiffIdxL
        )
        let diffInR = stepSchroederAllPass(
            input: rightIn,
            gain: 0.61803399,
            offset: inDiffOffsetR,
            length: inDiffLenR,
            index: &inDiffIdxR
        )

        // 2. Read 8 mutually prime delay lines
        let p0 = fdnOffsets.0 + fdnIndices.0
        let p1 = fdnOffsets.1 + fdnIndices.1
        let p2 = fdnOffsets.2 + fdnIndices.2
        let p3 = fdnOffsets.3 + fdnIndices.3
        let p4 = fdnOffsets.4 + fdnIndices.4
        let p5 = fdnOffsets.5 + fdnIndices.5
        let p6 = fdnOffsets.6 + fdnIndices.6
        let p7 = fdnOffsets.7 + fdnIndices.7

        let raw = SIMD8<Float>(
            fdnBuffer[p0], fdnBuffer[p1], fdnBuffer[p2], fdnBuffer[p3],
            fdnBuffer[p4], fdnBuffer[p5], fdnBuffer[p6], fdnBuffer[p7]
        )

        // 3. Per-channel one-pole HF damping filter: lp_i = (1 - damping) * raw_i + damping * lp_i
        dampingStates = raw * oneMinusDamp + dampingStates * clampedDamp

        // 4. Per-channel RT60 feedback scaling + normalized 8x8 Walsh-Hadamard mixing
        var feedbackVec = dampingStates * cachedFeedbackGains
        Self.applyNormalizedWalshHadamard8(&feedbackVec)

        // 5. Balanced stereo injection into the 8 FDN lines (1/2 energy normalization per stereo leg)
        let inScale: Float = 0.5
        let injL = diffInL * inScale
        let injR = diffInR * inScale

        fdnBuffer[p0] = feedbackVec[0] + injL
        fdnBuffer[p1] = feedbackVec[1] + injR
        fdnBuffer[p2] = feedbackVec[2] - injL
        fdnBuffer[p3] = feedbackVec[3] - injR
        fdnBuffer[p4] = feedbackVec[4] + injL
        fdnBuffer[p5] = feedbackVec[5] + injR
        fdnBuffer[p6] = feedbackVec[6] - injL
        fdnBuffer[p7] = feedbackVec[7] - injR

        fdnIndices.0 += 1; if fdnIndices.0 >= fdnLengths.0 { fdnIndices.0 = 0 }
        fdnIndices.1 += 1; if fdnIndices.1 >= fdnLengths.1 { fdnIndices.1 = 0 }
        fdnIndices.2 += 1; if fdnIndices.2 >= fdnLengths.2 { fdnIndices.2 = 0 }
        fdnIndices.3 += 1; if fdnIndices.3 >= fdnLengths.3 { fdnIndices.3 = 0 }
        fdnIndices.4 += 1; if fdnIndices.4 >= fdnLengths.4 { fdnIndices.4 = 0 }
        fdnIndices.5 += 1; if fdnIndices.5 >= fdnLengths.5 { fdnIndices.5 = 0 }
        fdnIndices.6 += 1; if fdnIndices.6 >= fdnLengths.6 { fdnIndices.6 = 0 }
        fdnIndices.7 += 1; if fdnIndices.7 >= fdnLengths.7 { fdnIndices.7 = 0 }

        // 6. Orthogonal stereo tap readout + output Schroeder all-pass diffusers ([179, 251] @ 48 kHz)
        let tapScale: Float = 0.5
        let rawWetL = (dampingStates[0] - dampingStates[2] + dampingStates[4] - dampingStates[6] + dampingStates[1] * 0.25) * tapScale
        let rawWetR = (dampingStates[1] - dampingStates[3] + dampingStates[5] - dampingStates[7] - dampingStates[0] * 0.25) * tapScale

        let wetL = stepSchroederAllPass(
            input: rawWetL,
            gain: -0.58,
            offset: outDiffOffsetL,
            length: outDiffLenL,
            index: &outDiffIdxL
        )
        let wetR = stepSchroederAllPass(
            input: rawWetR,
            gain: -0.58,
            offset: outDiffOffsetR,
            length: outDiffLenR,
            index: &outDiffIdxR
        )

        let dryGain = 1.0 - clampedWet
        let outL = leftIn * dryGain + wetL * clampedWet
        let outR = rightIn * dryGain + wetR * clampedWet
        return (outL.isFinite ? outL : 0.0, outR.isFinite ? outR : 0.0)
    }

    public mutating func renderImpulseResponse(
        frameCount: Int,
        decaySeconds: Float,
        damping: Float
    ) -> ([Float], [Float]) {
        let count = max(0, frameCount)
        guard count > 0 else { return ([], []) }

        reset()
        var irLeft = [Float](repeating: 0.0, count: count)
        var irRight = [Float](repeating: 0.0, count: count)

        for frame in 0..<count {
            let impulse: Float = (frame == 0) ? 1.0 : 0.0
            let (l, r) = processStereoSample(
                leftIn: impulse,
                rightIn: impulse,
                wetMix: 1.0,
                decaySeconds: decaySeconds,
                damping: damping
            )
            irLeft[frame] = l
            irRight[frame] = r
        }

        return (irLeft, irRight)
    }
}

// MARK: - 2. 4-Operator Through-Zero Frequency Modulation (TZFM) & Harmonic Morphing Voice Kernel

public struct FourOpTZFMVoiceKernel: Sendable {
    public let sampleRate: Double
    private let invSampleRate: Double
    private let twoPi: Double = .pi * 2.0

    // Left & Right 4-operator phase accumulators in [0.0, 1.0)
    private var phaseOp4L: Double = 0.0
    private var phaseOp3L: Double = 0.0
    private var phaseOp2L: Double = 0.0
    private var phaseOp1L: Double = 0.0

    private var phaseOp4R: Double = 0.0
    private var phaseOp3R: Double = 0.0
    private var phaseOp2R: Double = 0.0
    private var phaseOp1R: Double = 0.08333333

    // Operator 4 self-feedback memory for warm harmonic edge
    private var prevOp4L: Double = 0.0
    private var prevOp4R: Double = 0.0

    // Continuous smooth looping breath & harmonic morphing LFO accumulators
    private var breathPhasePrimary: Double = 0.0
    private var breathPhaseSecondary: Double = 0.25

    public init(sampleRate: Double = 48_000.0) {
        let safeRate = max(8_000.0, sampleRate)
        self.sampleRate = safeRate
        self.invSampleRate = 1.0 / safeRate
    }

    public mutating func reset() {
        phaseOp4L = 0.0
        phaseOp3L = 0.0
        phaseOp2L = 0.0
        phaseOp1L = 0.0
        phaseOp4R = 0.0
        phaseOp3R = 0.0
        phaseOp2R = 0.0
        phaseOp1R = 0.08333333
        prevOp4L = 0.0
        prevOp4R = 0.0
        breathPhasePrimary = 0.0
        breathPhaseSecondary = 0.25
    }

    /// True Through-Zero phase advance supporting instantaneous negative phase increments
    /// (`delta < 0` when linear FM pushes instantaneous frequency below 0 Hz) without foldback glitches.
    @inline(__always)
    private static func advanceThroughZeroPhase(_ phase: inout Double, delta: Double) {
        phase += delta
        phase -= floor(phase)
    }

    @inline(__always)
    private static func rationalSoftClip(_ x: Double) -> Float {
        let clamped = min(max(x, -3.0), 3.0)
        let x2 = clamped * clamped
        return Float(clamped * (27.0 + x2) / (27.0 + 9.0 * x2))
    }

    @inline(__always)
    public mutating func nextStereoSample(
        fundamentalHz: Double,
        harmonicRatio: Float,
        modulationIndex: Float
    ) -> (Float, Float) {
        let nyquistSafeMax = sampleRate * 0.44
        let f0 = min(max(fundamentalHz, 20.0), nyquistSafeMax)
        let ratio = Double(min(max(harmonicRatio, 0.25), 16.0))
        let modIdx = Double(min(max(modulationIndex, 0.0), 12.0))

        // Smooth looping raised-cosine breath & spectral morphing envelopes
        let breathPrimary = 0.5 - 0.5 * cos(twoPi * breathPhasePrimary)
        let breathSecondary = 0.5 + 0.5 * sin(twoPi * breathPhaseSecondary)
        Self.advanceThroughZeroPhase(&breathPhasePrimary, delta: 0.21 * invSampleRate)
        Self.advanceThroughZeroPhase(&breathPhaseSecondary, delta: 0.34 * invSampleRate)

        let ampBreath = 0.62 + 0.38 * breathPrimary
        let indexEnvelope = 0.58 + 0.42 * (0.65 * breathPrimary + 0.35 * breathSecondary)
        let effectiveIndex = modIdx * indexEnvelope

        // Harmonic morphing ratios across 4 operators (Op4 -> Op3 -> Op2 -> Op1 + parallel Op2/Op3 carrier blend)
        let r4 = min(ratio * 2.0, nyquistSafeMax / f0)
        let r3 = min(ratio * (1.0 + 0.5 * breathSecondary), nyquistSafeMax / f0)
        let r2 = min(ratio, nyquistSafeMax / f0)
        let stereoDetune = 1.0009

        // Operator 4 (top modulator with subtle self-phase feedback)
        let feedbackGain = 0.18 * min(effectiveIndex, 2.5)
        let op4L = sin(twoPi * phaseOp4L + feedbackGain * prevOp4L)
        let op4R = sin(twoPi * phaseOp4R + feedbackGain * prevOp4R)
        prevOp4L = op4L
        prevOp4R = op4R

        Self.advanceThroughZeroPhase(&phaseOp4L, delta: (f0 * r4) * invSampleRate)
        Self.advanceThroughZeroPhase(&phaseOp4R, delta: (f0 * r4 * stereoDetune) * invSampleRate)

        // Operator 3 driven through-zero by Operator 4
        let op3L = sin(twoPi * phaseOp3L)
        let op3R = sin(twoPi * phaseOp3R)
        let instFreq3L = f0 * r3 * (1.0 + effectiveIndex * 0.55 * op4L)
        let instFreq3R = f0 * r3 * stereoDetune * (1.0 + effectiveIndex * 0.55 * op4R)
        Self.advanceThroughZeroPhase(&phaseOp3L, delta: instFreq3L * invSampleRate)
        Self.advanceThroughZeroPhase(&phaseOp3R, delta: instFreq3R * invSampleRate)

        // Operator 2 driven through-zero by Operator 3
        let op2L = sin(twoPi * phaseOp2L)
        let op2R = sin(twoPi * phaseOp2R)
        let instFreq2L = f0 * r2 * (1.0 + effectiveIndex * 0.80 * op3L)
        let instFreq2R = f0 * r2 * stereoDetune * (1.0 + effectiveIndex * 0.80 * op3R)
        Self.advanceThroughZeroPhase(&phaseOp2L, delta: instFreq2L * invSampleRate)
        Self.advanceThroughZeroPhase(&phaseOp2R, delta: instFreq2R * invSampleRate)

        // Operator 1 (primary carrier) driven through-zero by Operator 2 (passes cleanly through 0 Hz when effectiveIndex * op2 < -1)
        let op1L = sin(twoPi * phaseOp1L)
        let op1R = sin(twoPi * phaseOp1R)
        let instFreq1L = f0 * (1.0 + effectiveIndex * op2L)
        let instFreq1R = (f0 * stereoDetune) * (1.0 + effectiveIndex * op2R)
        Self.advanceThroughZeroPhase(&phaseOp1L, delta: instFreq1L * invSampleRate)
        Self.advanceThroughZeroPhase(&phaseOp1R, delta: instFreq1R * invSampleRate)

        // Parallel carrier harmonic morph blend (cascade Op1 + parallel Op2 & Op3 body)
        let parallelMix = 0.22 + 0.16 * breathSecondary
        let rawL = ((1.0 - parallelMix) * op1L + parallelMix * (0.72 * op2L + 0.28 * op3L)) * ampBreath * 0.88
        let rawR = ((1.0 - parallelMix) * op1R + parallelMix * (0.72 * op2R + 0.28 * op3R)) * ampBreath * 0.88

        return (Self.rationalSoftClip(rawL), Self.rationalSoftClip(rawR))
    }
}
