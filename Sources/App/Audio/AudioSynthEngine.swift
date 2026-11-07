// MARK: - FILE: AudioSynthEngine.swift

import Foundation
import AVFoundation
import os

// MARK: - Lock-Free Real-Time Synth Parameters & Telemetry

public struct SynthParameters: Sendable, Equatable {
    public var carrierFrequencyHz: Float
    public var binauralBeatHz: Float
    public var binauralMix: Float
    public var pinkNoiseMix: Float
    public var padMix: Float
    public var filterCutoffHz: Float
    public var filterResonance: Float
    public var padDetuneCents: Float
    public var masterGain: Float
    public var bloomBoost: Float
    public var spatialPanOffset: Float     // -1.0 (left) ... +1.0 (right) from AirPods head yaw
    public var headElevationTilt: Float    // -1.0 (down) ... +1.0 (up) from AirPods head pitch
    public var isMuted: Bool

    public init(
        carrierFrequencyHz: Float = 216.0,
        binauralBeatHz: Float = 14.0,
        binauralMix: Float = 0.42,
        pinkNoiseMix: Float = 0.24,
        padMix: Float = 0.56,
        filterCutoffHz: Float = 1180.0,
        filterResonance: Float = 0.34,
        padDetuneCents: Float = 9.5,
        masterGain: Float = 0.72,
        bloomBoost: Float = 0.0,
        spatialPanOffset: Float = 0.0,
        headElevationTilt: Float = 0.0,
        isMuted: Bool = false
    ) {
        self.carrierFrequencyHz = min(max(carrierFrequencyHz, 60.0), 880.0)
        self.binauralBeatHz = min(max(binauralBeatHz, 0.5), 48.0)
        self.binauralMix = min(max(binauralMix, 0.0), 1.0)
        self.pinkNoiseMix = min(max(pinkNoiseMix, 0.0), 1.0)
        self.padMix = min(max(padMix, 0.0), 1.0)
        self.filterCutoffHz = min(max(filterCutoffHz, 80.0), 16_000.0)
        self.filterResonance = min(max(filterResonance, 0.05), 0.94)
        self.padDetuneCents = min(max(padDetuneCents, 0.0), 35.0)
        self.masterGain = min(max(masterGain, 0.0), 1.0)
        self.bloomBoost = min(max(bloomBoost, 0.0), 1.0)
        self.spatialPanOffset = min(max(spatialPanOffset, -1.0), 1.0)
        self.headElevationTilt = min(max(headElevationTilt, -1.0), 1.0)
        self.isMuted = isMuted
    }

    public init(preset: AudioPresetDTO) {
        self.init(
            carrierFrequencyHz: Float(preset.carrierFrequencyHz),
            binauralBeatHz: Float(preset.binauralBeatHz),
            binauralMix: Float(preset.binauralMix),
            pinkNoiseMix: Float(preset.pinkNoiseMix),
            padMix: Float(preset.padMix),
            filterCutoffHz: Float(preset.filterCutoffHz),
            filterResonance: Float(preset.filterResonance),
            padDetuneCents: Float(preset.padDetuneCents),
            masterGain: Float(preset.masterGain),
            bloomBoost: 0.0,
            spatialPanOffset: 0.0,
            headElevationTilt: 0.0,
            isMuted: false
        )
    }
}

public struct AudioTelemetrySnapshot: Sendable, Equatable {
    public let rmsAmplitude: Float
    public let peakAmplitude: Float
    public let lowBandEnergy: Float
    public let highBandEnergy: Float
    public let isRendering: Bool

    public init(
        rmsAmplitude: Float = 0,
        peakAmplitude: Float = 0,
        lowBandEnergy: Float = 0,
        highBandEnergy: Float = 0,
        isRendering: Bool = false
    ) {
        self.rmsAmplitude = rmsAmplitude
        self.peakAmplitude = peakAmplitude
        self.lowBandEnergy = lowBandEnergy
        self.highBandEnergy = highBandEnergy
        self.isRendering = isRendering
    }
}

// MARK: - Pure Swift Real-Time DSP Synthesizer Kernel (Testable & Allocation-Free)

public struct ProceduralSynthKernel: Sendable {
    public let sampleRate: Double
    private let invSampleRate: Double
    private let twoPi: Double = .pi * 2.0

    // Binaural phase accumulators (Double precision prevents long-session drift)
    private var phaseBinauralLeft: Double = 0.0
    private var phaseBinauralRight: Double = 0.0
    private var phaseSubFundamental: Double = 0.0

    // 5-voice stereo detuned harmonic ambient pad phases + LFO phases
    private var padPhasesLeft: (Double, Double, Double, Double, Double) = (0.0, 0.17, 0.31, 0.53, 0.79)
    private var padPhasesRight: (Double, Double, Double, Double, Double) = (0.11, 0.29, 0.47, 0.61, 0.83)
    private var lfoPhasePrimary: Double = 0.0
    private var lfoPhaseSecondary: Double = 0.25

    // Paul Kellet 7-pole instrumentation-grade 1/f Pink Noise states
    private var pinkL0: Float = 0; private var pinkL1: Float = 0; private var pinkL2: Float = 0
    private var pinkL3: Float = 0; private var pinkL4: Float = 0; private var pinkL5: Float = 0
    private var pinkL6: Float = 0

    private var pinkR0: Float = 0; private var pinkR1: Float = 0; private var pinkR2: Float = 0
    private var pinkR3: Float = 0; private var pinkR4: Float = 0; private var pinkR5: Float = 0
    private var pinkR6: Float = 0

    // Deterministic SplitMix64 PRNG state
    private var rngStateLeft: UInt64 = 0x853C_49E6_748F_EA9B
    private var rngStateRight: UInt64 = 0xDA3E_39CB_94B9_5BDB

    // Cytomic TPT 4-pole (2x cascaded 2-pole SVF) Low-Pass Filter states
    private var svf1ic1L: Float = 0; private var svf1ic2L: Float = 0
    private var svf2ic1L: Float = 0; private var svf2ic2L: Float = 0
    private var svf1ic1R: Float = 0; private var svf1ic2R: Float = 0
    private var svf2ic1R: Float = 0; private var svf2ic2R: Float = 0

    // Exponentially slewed real-time parameters
    private var smoothCarrierHz: Float = 216.0
    private var smoothBeatHz: Float = 14.0
    private var smoothBinauralMix: Float = 0.42
    private var smoothPinkMix: Float = 0.24
    private var smoothPadMix: Float = 0.56
    private var smoothCutoffHz: Float = 1180.0
    private var smoothResonance: Float = 0.34
    private var smoothDetuneCents: Float = 9.5
    private var smoothMasterGain: Float = 0.0
    private var smoothBloom: Float = 0.0
    private var smoothSpatialPan: Float = 0.0
    private var smoothElevationTilt: Float = 0.0

    public init(sampleRate: Double, snapInitialParameters: SynthParameters? = nil) {
        let safeRate = max(8_000.0, sampleRate)
        self.sampleRate = safeRate
        self.invSampleRate = 1.0 / safeRate

        if let initial = snapInitialParameters {
            self.smoothCarrierHz = initial.carrierFrequencyHz
            self.smoothBeatHz = initial.binauralBeatHz
            self.smoothBinauralMix = initial.binauralMix
            self.smoothPinkMix = initial.pinkNoiseMix
            self.smoothPadMix = initial.padMix
            self.smoothCutoffHz = initial.filterCutoffHz
            self.smoothResonance = initial.filterResonance
            self.smoothDetuneCents = initial.padDetuneCents
            self.smoothMasterGain = initial.isMuted ? 0.0 : initial.masterGain
            self.smoothBloom = initial.bloomBoost
            self.smoothSpatialPan = initial.spatialPanOffset
            self.smoothElevationTilt = initial.headElevationTilt
        }
    }

    @inline(__always)
    private mutating func nextWhiteNoiseLeft() -> Float {
        rngStateLeft &+= 0x9E37_79B9_7F4A_7C15
        var z = rngStateLeft
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z = z ^ (z >> 31)
        let unit = Float(z >> 40) * (1.0 / 16_777_216.0)
        return unit * 2.0 - 1.0
    }

    @inline(__always)
    private mutating func nextWhiteNoiseRight() -> Float {
        rngStateRight &+= 0x9E37_79B9_7F4A_7C15
        var z = rngStateRight
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z = z ^ (z >> 31)
        let unit = Float(z >> 40) * (1.0 / 16_777_216.0)
        return unit * 2.0 - 1.0
    }

    @inline(__always)
    private mutating func nextPinkNoiseStereo() -> (Float, Float) {
        let whiteL = nextWhiteNoiseLeft()
        pinkL0 = 0.99886 * pinkL0 + whiteL * 0.0555179
        pinkL1 = 0.99332 * pinkL1 + whiteL * 0.0750759
        pinkL2 = 0.96900 * pinkL2 + whiteL * 0.1538520
        pinkL3 = 0.86650 * pinkL3 + whiteL * 0.3104856
        pinkL4 = 0.55000 * pinkL4 + whiteL * 0.5329522
        pinkL5 = -0.7616 * pinkL5 - whiteL * 0.0168980
        let outL = (pinkL0 + pinkL1 + pinkL2 + pinkL3 + pinkL4 + pinkL5 + pinkL6 + whiteL * 0.5362) * 0.11
        pinkL6 = whiteL * 0.115926

        let whiteR = nextWhiteNoiseRight()
        pinkR0 = 0.99886 * pinkR0 + whiteR * 0.0555179
        pinkR1 = 0.99332 * pinkR1 + whiteR * 0.0750759
        pinkR2 = 0.96900 * pinkR2 + whiteR * 0.1538520
        pinkR3 = 0.86650 * pinkR3 + whiteR * 0.3104856
        pinkR4 = 0.55000 * pinkR4 + whiteR * 0.5329522
        pinkR5 = -0.7616 * pinkR5 - whiteR * 0.0168980
        let outR = (pinkR0 + pinkR1 + pinkR2 + pinkR3 + pinkR4 + pinkR5 + pinkR6 + whiteR * 0.5362) * 0.11
        pinkR6 = whiteR * 0.115926

        return (outL, outR)
    }

    @inline(__always)
    private func fastSoftClip(_ x: Float) -> Float {
        let clamped = min(max(x, -3.0), 3.0)
        let x2 = clamped * clamped
        return clamped * (27.0 + x2) / (27.0 + 9.0 * x2)
    }

    @inline(__always)
    private func advancePhase(_ phase: inout Double, delta: Double) {
        phase += delta
        if phase >= 1.0 {
            phase -= phase.rounded(.down)
        } else if phase < 0.0 {
            phase -= phase.rounded(.down)
        }
    }

    public mutating func renderStereoBlock(
        leftOutput: UnsafeMutablePointer<Float>,
        rightOutput: UnsafeMutablePointer<Float>,
        frameCount: Int,
        target: SynthParameters
    ) -> AudioTelemetrySnapshot {
        guard frameCount > 0 else {
            return AudioTelemetrySnapshot(isRendering: !target.isMuted)
        }

        let slewCoeff = Float(min(1.0, 35.0 * invSampleRate))
        let targetGain: Float = target.isMuted ? 0.0 : target.masterGain

        var sumSquares: Float = 0.0
        var peak: Float = 0.0
        var lowAccum: Float = 0.0
        var highAccum: Float = 0.0
        var previousOutL: Float = 0.0

        let r0 = 0.5
        let r1 = 0.75
        let r2 = 1.0
        let r3 = 1.125
        let r4 = 1.5

        for i in 0..<frameCount {
            // 1. Exponential parameter slewing
            smoothCarrierHz += slewCoeff * (target.carrierFrequencyHz - smoothCarrierHz)
            smoothBeatHz += slewCoeff * (target.binauralBeatHz - smoothBeatHz)
            smoothBinauralMix += slewCoeff * (target.binauralMix - smoothBinauralMix)
            smoothPinkMix += slewCoeff * (target.pinkNoiseMix - smoothPinkMix)
            smoothPadMix += slewCoeff * (target.padMix - smoothPadMix)
            smoothCutoffHz += slewCoeff * (target.filterCutoffHz - smoothCutoffHz)
            smoothResonance += slewCoeff * (target.filterResonance - smoothResonance)
            smoothDetuneCents += slewCoeff * (target.padDetuneCents - smoothDetuneCents)
            smoothMasterGain += slewCoeff * (targetGain - smoothMasterGain)
            smoothBloom += slewCoeff * (target.bloomBoost - smoothBloom)
            smoothSpatialPan += slewCoeff * (target.spatialPanOffset - smoothSpatialPan)
            smoothElevationTilt += slewCoeff * (target.headElevationTilt - smoothElevationTilt)

            // 2. Binaural Beat Synthesis (Left = fc - fb/2, Right = fc + fb/2)
            let carrier = Double(smoothCarrierHz)
            let halfBeat = Double(smoothBeatHz) * 0.5
            let freqLeft = max(20.0, carrier - halfBeat)
            let freqRight = max(20.0, carrier + halfBeat)

            let binauralL = Float(sin(twoPi * phaseBinauralLeft))
            let binauralR = Float(sin(twoPi * phaseBinauralRight))

            advancePhase(&phaseBinauralLeft, delta: freqLeft * invSampleRate)
            advancePhase(&phaseBinauralRight, delta: freqRight * invSampleRate)
            advancePhase(&phaseSubFundamental, delta: (carrier * 0.5) * invSampleRate)

            // 3. Slow Quadrature LFOs
            let lfoA = Float(sin(twoPi * lfoPhasePrimary))
            let lfoB = Float(cos(twoPi * lfoPhaseSecondary))
            advancePhase(&lfoPhasePrimary, delta: 0.083 * invSampleRate)
            advancePhase(&lfoPhaseSecondary, delta: 0.137 * invSampleRate)

            // 4. 5-Voice Detuned Harmonic Ambient Pad
            var padL: Float = 0.0
            var padR: Float = 0.0
            if smoothPadMix > 0.0005 {
                let detuneRatioUp = pow(2.0, Double(smoothDetuneCents) / 1200.0)
                let detuneRatioDown = 1.0 / detuneRatioUp
                let subWarmth = Float(sin(twoPi * phaseSubFundamental)) * 0.22

                let v0L = Float(sin(twoPi * padPhasesLeft.0))
                let v1L = Float(sin(twoPi * padPhasesLeft.1 + Double(lfoA) * 0.18))
                let v2L = Float(sin(twoPi * padPhasesLeft.2))
                let v3L = Float(sin(twoPi * padPhasesLeft.3 + Double(lfoB) * 0.22))
                let v4L = Float(sin(twoPi * padPhasesLeft.4))

                let v0R = Float(sin(twoPi * padPhasesRight.0))
                let v1R = Float(sin(twoPi * padPhasesRight.1 - Double(lfoB) * 0.18))
                let v2R = Float(sin(twoPi * padPhasesRight.2))
                let v3R = Float(sin(twoPi * padPhasesRight.3 - Double(lfoA) * 0.22))
                let v4R = Float(sin(twoPi * padPhasesRight.4))

                let bloomGain = 1.0 + smoothBloom * 0.55
                let rawPadL = (v0L * 0.34 + v1L * 0.26 + v2L * 0.22 + v3L * (0.16 + 0.06 * lfoA) + v4L * (0.12 + 0.05 * lfoB) + subWarmth) * bloomGain
                let rawPadR = (v0R * 0.34 + v1R * 0.26 + v2R * 0.22 + v3R * (0.16 + 0.06 * lfoB) + v4R * (0.12 + 0.05 * lfoA) + subWarmth) * bloomGain

                padL = fastSoftClip(rawPadL * 1.35) * 0.68
                padR = fastSoftClip(rawPadR * 1.35) * 0.68

                advancePhase(&padPhasesLeft.0, delta: carrier * r0 * detuneRatioDown * invSampleRate)
                advancePhase(&padPhasesLeft.1, delta: carrier * r1 * detuneRatioUp * invSampleRate)
                advancePhase(&padPhasesLeft.2, delta: carrier * r2 * detuneRatioDown * invSampleRate)
                advancePhase(&padPhasesLeft.3, delta: carrier * r3 * detuneRatioUp * invSampleRate)
                advancePhase(&padPhasesLeft.4, delta: carrier * r4 * detuneRatioDown * invSampleRate)

                advancePhase(&padPhasesRight.0, delta: carrier * r0 * detuneRatioUp * invSampleRate)
                advancePhase(&padPhasesRight.1, delta: carrier * r1 * detuneRatioDown * invSampleRate)
                advancePhase(&padPhasesRight.2, delta: carrier * r2 * detuneRatioUp * invSampleRate)
                advancePhase(&padPhasesRight.3, delta: carrier * r3 * detuneRatioDown * invSampleRate)
                advancePhase(&padPhasesRight.4, delta: carrier * r4 * detuneRatioUp * invSampleRate)
            }

            // 5. Procedural 1/f Pink Noise
            var noiseL: Float = 0.0
            var noiseR: Float = 0.0
            if smoothPinkMix > 0.0005 {
                let pair = nextPinkNoiseStereo()
                noiseL = pair.0
                noiseR = pair.1
            }

            // 6. AirPods Constant-Power Spatial Panning + Head-Pitch Spectral Tilt
            // Normalized pan angle theta in [0, pi/2]; at pan=0, cos(pi/4)=sin(pi/4)=0.7071 -> normalized by sqrt(2)=1.4142135
            let panAngle = (Float.pi * 0.25) * (1.0 + min(max(smoothSpatialPan, -1.0), 1.0))
            let panGainL = cos(panAngle) * 1.41421356
            let panGainR = sin(panAngle) * 1.41421356
            let elevationFactor = 1.0 + 0.24 * min(max(smoothElevationTilt, -1.0), 1.0)

            // 7. 4-Pole Cascaded Cytomic TPT SVF Low-Pass Filter
            let maxSafeCutoff = Float(sampleRate * 0.44)
            let modulatedCutoff = min(
                max(smoothCutoffHz * elevationFactor * (1.0 + 0.08 * lfoA + 0.65 * smoothBloom), 60.0),
                maxSafeCutoff
            )
            let g = tan(Float.pi * modulatedCutoff * Float(invSampleRate))
            let k = 2.0 - 2.0 * min(max(smoothResonance, 0.05), 0.94)
            let a1 = 1.0 / (1.0 + g * (g + k))
            let a2 = g * a1
            let a3 = g * a2

            // Binaural tones remain ear-locked for phase coherence while ambient field pans spatially
            let preFilterL = binauralL * smoothBinauralMix + (padL * smoothPadMix + noiseL * smoothPinkMix) * panGainL
            let preFilterR = binauralR * smoothBinauralMix + (padR * smoothPadMix + noiseR * smoothPinkMix) * panGainR

            // Stage 1 Stereo SVF
            let v3_1L = preFilterL - svf1ic2L
            let v1_1L = a1 * svf1ic1L + a2 * v3_1L
            let v2_1L = svf1ic2L + a2 * svf1ic1L + a3 * v3_1L
            svf1ic1L = 2.0 * v1_1L - svf1ic1L
            svf1ic2L = 2.0 * v2_1L - svf1ic2L

            let v3_1R = preFilterR - svf1ic2R
            let v1_1R = a1 * svf1ic1R + a2 * v3_1R
            let v2_1R = svf1ic2R + a2 * svf1ic1R + a3 * v3_1R
            svf1ic1R = 2.0 * v1_1R - svf1ic1R
            svf1ic2R = 2.0 * v2_1R - svf1ic2R

            // Stage 2 Stereo SVF
            let v3_2L = v2_1L - svf2ic2L
            let v1_2L = a1 * svf2ic1L + a2 * v3_2L
            let v2_2L = svf2ic2L + a2 * svf2ic1L + a3 * v3_2L
            svf2ic1L = 2.0 * v1_2L - svf2ic1L
            svf2ic2L = 2.0 * v2_2L - svf2ic2L

            let v3_2R = v2_1R - svf2ic2R
            let v1_2R = a1 * svf2ic1R + a2 * v3_2R
            let v2_2R = svf2ic2R + a2 * svf2ic1R + a3 * v3_2R
            svf2ic1R = 2.0 * v1_2R - svf2ic1R
            svf2ic2R = 2.0 * v2_2R - svf2ic2R

            let cleanL = v2_2L.isFinite ? v2_2L : 0.0
            let cleanR = v2_2R.isFinite ? v2_2R : 0.0

            let finalL = fastSoftClip(cleanL * smoothMasterGain)
            let finalR = fastSoftClip(cleanR * smoothMasterGain)

            leftOutput[i] = finalL
            rightOutput[i] = finalR

            let mono = 0.5 * (finalL + finalR)
            sumSquares += mono * mono
            let absMax = max(abs(finalL), abs(finalR))
            if absMax > peak { peak = absMax }

            lowAccum += abs(v2_2L)
            highAccum += abs(finalL - previousOutL)
            previousOutL = finalL
        }

        let invCount = 1.0 / Float(frameCount)
        let rms = sqrt(sumSquares * invCount)
        return AudioTelemetrySnapshot(
            rmsAmplitude: min(max(rms, 0.0), 1.0),
            peakAmplitude: min(max(peak, 0.0), 1.0),
            lowBandEnergy: min(max(lowAccum * invCount, 0.0), 1.0),
            highBandEnergy: min(max(highAccum * invCount * 3.0, 0.0), 1.0),
            isRendering: smoothMasterGain > 0.001
        )
    }
}

// MARK: - Wait-Free Real-Time Audio Bridge with 256-Sample FFT Scope Tap

public final class RealtimeAudioBridge: @unchecked Sendable {
    public static let scopeWindowLength: Int = 256

    private let paramLock: UnsafeMutablePointer<os_unfair_lock_s>
    private let telemetryLock: UnsafeMutablePointer<os_unfair_lock_s>
    private var sharedParameters: SynthParameters
    private var sharedTelemetry: AudioTelemetrySnapshot

    private let scopeRingBuffer: UnsafeMutablePointer<Float>
    private var scopeWriteHead: Int = 0

    private var audioThreadCachedParameters: SynthParameters
    private var dspKernel: ProceduralSynthKernel
    private let scratchLeft: UnsafeMutablePointer<Float>
    private let scratchRight: UnsafeMutablePointer<Float>
    private let maxScratchFrames: Int = 4096

    public let sampleRate: Double

    public init(sampleRate: Double, initialParameters: SynthParameters = SynthParameters()) {
        self.sampleRate = sampleRate

        self.paramLock = UnsafeMutablePointer<os_unfair_lock_s>.allocate(capacity: 1)
        self.paramLock.initialize(to: os_unfair_lock_s())

        self.telemetryLock = UnsafeMutablePointer<os_unfair_lock_s>.allocate(capacity: 1)
        self.telemetryLock.initialize(to: os_unfair_lock_s())

        self.scopeRingBuffer = UnsafeMutablePointer<Float>.allocate(capacity: Self.scopeWindowLength)
        self.scopeRingBuffer.initialize(repeating: 0, count: Self.scopeWindowLength)

        self.sharedParameters = initialParameters
        self.sharedTelemetry = AudioTelemetrySnapshot()
        self.audioThreadCachedParameters = initialParameters
        self.dspKernel = ProceduralSynthKernel(sampleRate: sampleRate, snapInitialParameters: nil)

        self.scratchLeft = UnsafeMutablePointer<Float>.allocate(capacity: maxScratchFrames)
        self.scratchLeft.initialize(repeating: 0, count: maxScratchFrames)
        self.scratchRight = UnsafeMutablePointer<Float>.allocate(capacity: maxScratchFrames)
        self.scratchRight.initialize(repeating: 0, count: maxScratchFrames)
    }

    deinit {
        paramLock.deinitialize(count: 1)
        paramLock.deallocate()
        telemetryLock.deinitialize(count: 1)
        telemetryLock.deallocate()
        scopeRingBuffer.deinitialize(count: Self.scopeWindowLength)
        scopeRingBuffer.deallocate()
        scratchLeft.deinitialize(count: maxScratchFrames)
        scratchLeft.deallocate()
        scratchRight.deinitialize(count: maxScratchFrames)
        scratchRight.deallocate()
    }

    public func writeParameters(_ newParameters: SynthParameters) {
        os_unfair_lock_lock(paramLock)
        sharedParameters = newParameters
        os_unfair_lock_unlock(paramLock)
    }

    public func readTelemetry() -> AudioTelemetrySnapshot {
        os_unfair_lock_lock(telemetryLock)
        let copy = sharedTelemetry
        os_unfair_lock_unlock(telemetryLock)
        return copy
    }

    public func copyRecentMonoWindow() -> [Float] {
        var result = [Float](repeating: 0, count: Self.scopeWindowLength)
        os_unfair_lock_lock(telemetryLock)
        let head = scopeWriteHead
        for i in 0..<Self.scopeWindowLength {
            let ringIdx = (head + i) & (Self.scopeWindowLength - 1)
            result[i] = scopeRingBuffer[ringIdx]
        }
        os_unfair_lock_unlock(telemetryLock)
        return result
    }

    public func resetTelemetry() {
        os_unfair_lock_lock(telemetryLock)
        sharedTelemetry = AudioTelemetrySnapshot(isRendering: false)
        for i in 0..<Self.scopeWindowLength {
            scopeRingBuffer[i] = 0
        }
        scopeWriteHead = 0
        os_unfair_lock_unlock(telemetryLock)
    }

    fileprivate func renderOnAudioThread(
        frameCount: Int,
        outputData: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        if os_unfair_lock_trylock(paramLock) {
            audioThreadCachedParameters = sharedParameters
            os_unfair_lock_unlock(paramLock)
        }

        let abl = UnsafeMutableAudioBufferListPointer(outputData)
        guard !abl.isEmpty, frameCount > 0 else { return noErr }

        var latestSnapshot = AudioTelemetrySnapshot()
        var tapL: UnsafePointer<Float>?
        var tapR: UnsafePointer<Float>?
        var tapCount = 0

        if abl.count >= 2,
           let outL = abl[0].mData?.assumingMemoryBound(to: Float.self),
           let outR = abl[1].mData?.assumingMemoryBound(to: Float.self) {
            latestSnapshot = dspKernel.renderStereoBlock(
                leftOutput: outL,
                rightOutput: outR,
                frameCount: frameCount,
                target: audioThreadCachedParameters
            )
            tapL = UnsafePointer(outL)
            tapR = UnsafePointer(outR)
            tapCount = frameCount
        } else if abl.count == 1,
                  let interleaved = abl[0].mData?.assumingMemoryBound(to: Float.self) {
            let channels = Int(abl[0].mNumberChannels)
            var remaining = frameCount
            var offset = 0

            while remaining > 0 {
                let chunk = min(remaining, maxScratchFrames)
                latestSnapshot = dspKernel.renderStereoBlock(
                    leftOutput: scratchLeft,
                    rightOutput: scratchRight,
                    frameCount: chunk,
                    target: audioThreadCachedParameters
                )

                if channels >= 2 {
                    for f in 0..<chunk {
                        let base = (offset + f) * channels
                        interleaved[base] = scratchLeft[f]
                        interleaved[base + 1] = scratchRight[f]
                    }
                } else {
                    for f in 0..<chunk {
                        interleaved[offset + f] = 0.5 * (scratchLeft[f] + scratchRight[f])
                    }
                }
                tapL = UnsafePointer(scratchLeft)
                tapR = UnsafePointer(scratchRight)
                tapCount = chunk
                remaining -= chunk
                offset += chunk
            }
        }

        if os_unfair_lock_trylock(telemetryLock) {
            sharedTelemetry = latestSnapshot
            if let lPtr = tapL, let rPtr = tapR, tapCount > 0 {
                let mask = Self.scopeWindowLength - 1
                let startSample = max(0, tapCount - Self.scopeWindowLength)
                var head = scopeWriteHead
                for idx in startSample..<tapCount {
                    scopeRingBuffer[head] = 0.5 * (lPtr[idx] + rPtr[idx])
                    head = (head + 1) & mask
                }
                scopeWriteHead = head
            }
            os_unfair_lock_unlock(telemetryLock)
        }

        return noErr
    }

    nonisolated static func makeRenderBlock(bridge: RealtimeAudioBridge) -> AVAudioSourceNodeRenderBlock {
        return { isSilence, _, frameCount, outputData -> OSStatus in
            isSilence.pointee = false
            return bridge.renderOnAudioThread(frameCount: Int(frameCount), outputData: outputData)
        }
    }
}

// MARK: - Thread-Safe Actor Managing AVAudioEngine & Procedural Source Node

public actor AudioSynthEngine {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var bridge: RealtimeAudioBridge?
    private var currentParameters: SynthParameters = SynthParameters()
    private var isRunningEngine: Bool = false
    private var bloomDecayTask: Task<Void, Never>?

    public init() {}

    public func configureIfNeeded() throws {
        guard sourceNode == nil else { return }

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setPreferredIOBufferDuration(0.0058)
        try session.setActive(true)
        let hardwareRate = session.sampleRate > 0 ? session.sampleRate : 48_000.0
        #else
        let hardwareRate = 48_000.0
        #endif

        guard let stereoFormat = AVAudioFormat(
            standardFormatWithSampleRate: hardwareRate,
            channels: 2
        ) else {
            throw NSError(
                domain: "AetherAudioSynthEngine",
                code: -1001,
                userInfo: [NSLocalizedDescriptionKey: "Unable to create 2-channel standard float AVAudioFormat."]
            )
        }

        let audioBridge = RealtimeAudioBridge(sampleRate: hardwareRate, initialParameters: currentParameters)
        let renderBlock = RealtimeAudioBridge.makeRenderBlock(bridge: audioBridge)
        let node = AVAudioSourceNode(format: stereoFormat, renderBlock: renderBlock)

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: stereoFormat)
        engine.mainMixerNode.outputVolume = 1.0
        engine.prepare()

        self.bridge = audioBridge
        self.sourceNode = node
    }

    public func start() throws {
        try configureIfNeeded()
        currentParameters.isMuted = false
        bridge?.writeParameters(currentParameters)

        if !engine.isRunning {
            #if os(iOS)
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            try engine.start()
        }
        isRunningEngine = true
    }

    public func pause() {
        currentParameters.isMuted = true
        bridge?.writeParameters(currentParameters)
        isRunningEngine = false
    }

    public func stopCompletely() {
        bloomDecayTask?.cancel()
        currentParameters.isMuted = true
        bridge?.writeParameters(currentParameters)
        if engine.isRunning {
            engine.stop()
        }
        bridge?.resetTelemetry()
        isRunningEngine = false
    }

    public func updateParameters(_ parameters: SynthParameters) {
        var next = parameters
        if !isRunningEngine {
            next.isMuted = true
        }
        currentParameters = next
        bridge?.writeParameters(next)
    }

    public func updateHeadTrackingOffsets(spatialPan: Float, elevationTilt: Float) {
        currentParameters.spatialPanOffset = min(max(spatialPan, -1.0), 1.0)
        currentParameters.headElevationTilt = min(max(elevationTilt, -1.0), 1.0)
        bridge?.writeParameters(currentParameters)
    }

    public func applyPreset(_ preset: AudioPresetDTO) {
        var next = SynthParameters(preset: preset)
        next.spatialPanOffset = currentParameters.spatialPanOffset
        next.headElevationTilt = currentParameters.headElevationTilt
        next.isMuted = !isRunningEngine
        currentParameters = next
        bridge?.writeParameters(next)
    }

    public func triggerHarmonicBloom(intensity: Float = 0.85) {
        bloomDecayTask?.cancel()
        currentParameters.bloomBoost = min(max(intensity, 0.0), 1.0)
        bridge?.writeParameters(currentParameters)

        bloomDecayTask = Task {
            let steps = 16
            for step in 1...steps {
                try? await Task.sleep(for: .milliseconds(45))
                if Task.isCancelled { return }
                let remaining = Float(steps - step) / Float(steps)
                self.decayBloomStep(to: intensity * remaining * remaining)
            }
        }
    }

    private func decayBloomStep(to value: Float) {
        currentParameters.bloomBoost = value
        bridge?.writeParameters(currentParameters)
    }

    public func snapshotTelemetry() -> AudioTelemetrySnapshot {
        guard isRunningEngine, let bridge else {
            return AudioTelemetrySnapshot(isRendering: false)
        }
        return bridge.readTelemetry()
    }

    public func snapshotScopeWindow() -> (samples: [Float], sampleRate: Double) {
        guard isRunningEngine, let bridge else {
            return ([Float](repeating: 0, count: RealtimeAudioBridge.scopeWindowLength), 48_000.0)
        }
        return (bridge.copyRecentMonoWindow(), bridge.sampleRate)
    }

    public var isPlaying: Bool {
        isRunningEngine && engine.isRunning
    }
}
