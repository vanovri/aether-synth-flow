// MARK: - FILE: AetherSynthAudioUnit.swift

import Foundation
import AVFoundation
import os
#if canImport(AudioToolbox) && !os(watchOS)
import AudioToolbox

// MARK: - 1. Factory Preset Definitions

public struct AetherAUFactoryPresetSpec: Sendable, Equatable, Identifiable {
    public var id: Int { number }
    public let number: Int
    public let name: String
    public let values: [AetherAUParameterAddress: AUValue]

    public static let allPresets: [AetherAUFactoryPresetSpec] = [
        AetherAUFactoryPresetSpec(
            number: 0,
            name: "Nebula Deep Work",
            values: [
                .carrierFrequencyHz: 216.0,
                .binauralBeatHz: 14.0,
                .binauralMix: 0.44,
                .pinkNoiseMix: 0.22,
                .padMix: 0.58,
                .filterCutoffHz: 1_280.0,
                .filterResonance: 0.34,
                .padDetuneCents: 9.5,
                .reverbWetMix: 0.26,
                .reverbDecaySeconds: 2.8,
                .fmModulationIndex: 1.15,
                .hrtfAzimuthDeg: 0.0,
                .hrtfElevationDeg: 8.0,
                .hrtfDistanceMeters: 1.40,
                .neuralSoundscapeMix: 0.28,
                .masterGain: 0.74
            ]
        ),
        AetherAUFactoryPresetSpec(
            number: 1,
            name: "Solaris Alpha Flow",
            values: [
                .carrierFrequencyHz: 196.0,
                .binauralBeatHz: 10.0,
                .binauralMix: 0.40,
                .pinkNoiseMix: 0.18,
                .padMix: 0.66,
                .filterCutoffHz: 2_150.0,
                .filterResonance: 0.28,
                .padDetuneCents: 12.0,
                .reverbWetMix: 0.34,
                .reverbDecaySeconds: 3.6,
                .fmModulationIndex: 1.65,
                .hrtfAzimuthDeg: -18.0,
                .hrtfElevationDeg: 14.0,
                .hrtfDistanceMeters: 1.65,
                .neuralSoundscapeMix: 0.35,
                .masterGain: 0.72
            ]
        ),
        AetherAUFactoryPresetSpec(
            number: 2,
            name: "Void Theta Drift",
            values: [
                .carrierFrequencyHz: 144.0,
                .binauralBeatHz: 5.5,
                .binauralMix: 0.50,
                .pinkNoiseMix: 0.30,
                .padMix: 0.62,
                .filterCutoffHz: 780.0,
                .filterResonance: 0.42,
                .padDetuneCents: 15.0,
                .reverbWetMix: 0.48,
                .reverbDecaySeconds: 5.8,
                .fmModulationIndex: 0.75,
                .hrtfAzimuthDeg: 24.0,
                .hrtfElevationDeg: -6.0,
                .hrtfDistanceMeters: 2.30,
                .neuralSoundscapeMix: 0.42,
                .masterGain: 0.70
            ]
        ),
        AetherAUFactoryPresetSpec(
            number: 3,
            name: "Hyperion Gamma 40Hz",
            values: [
                .carrierFrequencyHz: 256.0,
                .binauralBeatHz: 40.0,
                .binauralMix: 0.48,
                .pinkNoiseMix: 0.14,
                .padMix: 0.52,
                .filterCutoffHz: 3_600.0,
                .filterResonance: 0.46,
                .padDetuneCents: 7.0,
                .reverbWetMix: 0.20,
                .reverbDecaySeconds: 1.9,
                .fmModulationIndex: 2.40,
                .hrtfAzimuthDeg: 0.0,
                .hrtfElevationDeg: 22.0,
                .hrtfDistanceMeters: 1.10,
                .neuralSoundscapeMix: 0.50,
                .masterGain: 0.75
            ]
        ),
        AetherAUFactoryPresetSpec(
            number: 4,
            name: "KEMAR Cathedral Pad",
            values: [
                .carrierFrequencyHz: 174.0,
                .binauralBeatHz: 7.83,
                .binauralMix: 0.36,
                .pinkNoiseMix: 0.16,
                .padMix: 0.78,
                .filterCutoffHz: 2_840.0,
                .filterResonance: 0.38,
                .padDetuneCents: 18.5,
                .reverbWetMix: 0.64,
                .reverbDecaySeconds: 8.4,
                .fmModulationIndex: 1.90,
                .hrtfAzimuthDeg: -35.0,
                .hrtfElevationDeg: 28.0,
                .hrtfDistanceMeters: 3.20,
                .neuralSoundscapeMix: 0.46,
                .masterGain: 0.72
            ]
        )
    ]
}

// MARK: - 2. Helper Builder for Sample-Accurate AURenderEvent Chains

public enum AURenderEventBuilder {
    @inline(__always)
    public static func makeMIDIEvent(
        sampleTime: AUEventSampleTime,
        status: UInt8,
        data1: UInt8,
        data2: UInt8,
        next: UnsafeMutablePointer<AURenderEvent>? = nil
    ) -> AURenderEvent {
        var event = AURenderEvent()
        event.MIDI.eventSampleTime = sampleTime
        event.MIDI.eventType = .MIDI
        event.MIDI.length = 3
        event.MIDI.cable = 0
        event.MIDI.data = (status, data1, data2)
        event.MIDI.next = next
        return event
    }

    @inline(__always)
    public static func makeParameterEvent(
        sampleTime: AUEventSampleTime,
        address: AUParameterAddress,
        value: AUValue,
        rampDurationFrames: AUAudioFrameCount = 0,
        next: UnsafeMutablePointer<AURenderEvent>? = nil
    ) -> AURenderEvent {
        var event = AURenderEvent()
        event.parameter.eventSampleTime = sampleTime
        event.parameter.eventType = rampDurationFrames > 0 ? .parameterRamp : .parameter
        event.parameter.parameterAddress = address
        event.parameter.rampDurationSampleFrames = rampDurationFrames
        event.parameter.value = value
        event.parameter.next = next
        return event
    }
}

// MARK: - 3. Pre-Allocated Raw-Pointer FX Kernels (Hadamard 8x8 FDN Reverb + KEMAR 128-Tap HRTF + 24dB SVF)

/// Zero-allocation raw-pointer 8-channel Sylvester-Hadamard Feedback Delay Network (FDN) stereo reverb
/// supporting sample rates from 44.1 kHz to 192 kHz.
internal final class RawPointerHadamardFDNReverb: @unchecked Sendable {
    private static let channels: Int = 8
    private static let lineCapacity: Int = 16_384 // Power-of-two capacity supporting up to 192 kHz prime lines
    private static let lineMask: Int = 16_383
    private static let basePrimes48k: (Int, Int, Int, Int, Int, Int, Int, Int) = (
        1_087, 1_283, 1_511, 1_777, 1_999, 2_267, 2_557, 2_897
    )

    private let delayBufferPtr: UnsafeMutablePointer<Float>
    private let writeHeadsPtr: UnsafeMutablePointer<Int>
    private let delayLengthsPtr: UnsafeMutablePointer<Int>
    private let dampingStatesPtr: UnsafeMutablePointer<Float>
    private var meanDelaySeconds: Float = 0.040

    init(sampleRate: Double = 48_000.0) {
        let totalFloats = Self.channels * Self.lineCapacity
        self.delayBufferPtr = UnsafeMutablePointer<Float>.allocate(capacity: totalFloats)
        self.delayBufferPtr.initialize(repeating: 0.0, count: totalFloats)

        self.writeHeadsPtr = UnsafeMutablePointer<Int>.allocate(capacity: Self.channels)
        self.writeHeadsPtr.initialize(repeating: 0, count: Self.channels)

        self.delayLengthsPtr = UnsafeMutablePointer<Int>.allocate(capacity: Self.channels)
        self.delayLengthsPtr.initialize(repeating: 1_024, count: Self.channels)

        self.dampingStatesPtr = UnsafeMutablePointer<Float>.allocate(capacity: Self.channels)
        self.dampingStatesPtr.initialize(repeating: 0.0, count: Self.channels)

        reconfigure(sampleRate: sampleRate)
    }

    deinit {
        let totalFloats = Self.channels * Self.lineCapacity
        delayBufferPtr.deinitialize(count: totalFloats)
        delayBufferPtr.deallocate()
        writeHeadsPtr.deinitialize(count: Self.channels)
        writeHeadsPtr.deallocate()
        delayLengthsPtr.deinitialize(count: Self.channels)
        delayLengthsPtr.deallocate()
        dampingStatesPtr.deinitialize(count: Self.channels)
        dampingStatesPtr.deallocate()
    }

    func reconfigure(sampleRate: Double) {
        let safeRate = max(44_100.0, min(sampleRate, 192_000.0))
        let scale = safeRate / 48_000.0
        let primes = Self.basePrimes48k
        delayLengthsPtr[0] = min(Self.lineCapacity - 8, max(64, Int((Double(primes.0) * scale).rounded())))
        delayLengthsPtr[1] = min(Self.lineCapacity - 8, max(64, Int((Double(primes.1) * scale).rounded())))
        delayLengthsPtr[2] = min(Self.lineCapacity - 8, max(64, Int((Double(primes.2) * scale).rounded())))
        delayLengthsPtr[3] = min(Self.lineCapacity - 8, max(64, Int((Double(primes.3) * scale).rounded())))
        delayLengthsPtr[4] = min(Self.lineCapacity - 8, max(64, Int((Double(primes.4) * scale).rounded())))
        delayLengthsPtr[5] = min(Self.lineCapacity - 8, max(64, Int((Double(primes.5) * scale).rounded())))
        delayLengthsPtr[6] = min(Self.lineCapacity - 8, max(64, Int((Double(primes.6) * scale).rounded())))
        delayLengthsPtr[7] = min(Self.lineCapacity - 8, max(64, Int((Double(primes.7) * scale).rounded())))

        var sumLen = 0
        for ch in 0..<Self.channels { sumLen += delayLengthsPtr[ch] }
        meanDelaySeconds = Float(Double(sumLen) / (Double(Self.channels) * safeRate))
        reset()
    }

    @inline(__always)
    func reset() {
        let totalFloats = Self.channels * Self.lineCapacity
        for i in 0..<totalFloats { delayBufferPtr[i] = 0.0 }
        for ch in 0..<Self.channels {
            writeHeadsPtr[ch] = 0
            dampingStatesPtr[ch] = 0.0
        }
    }

    @inline(__always)
    func processInPlace(
        leftPtr: UnsafeMutablePointer<Float>,
        rightPtr: UnsafeMutablePointer<Float>,
        frameCount: Int,
        wetMix: Float,
        decaySeconds: Float
    ) {
        let clampedWet = min(max(wetMix, 0.0), 1.0)
        guard clampedWet > 0.0005 && frameCount > 0 else { return }

        let safeRT60 = max(0.15, decaySeconds)
        // Eyring feedback gain g = 10^(-3 * L_mean / RT60)
        let feedback = min(max(powf(10.0, (-3.0 * meanDelaySeconds) / safeRT60), 0.05), 0.965)
        let damp: Float = 0.32
        let oneMinusDamp: Float = 1.0 - damp
        let normHadamard: Float = 0.3535533906 * feedback // (1 / sqrt(8)) * feedback
        let dryMix: Float = 1.0 - clampedWet * 0.35

        @inline(__always)
        func readChannel(_ ch: Int) -> Float {
            let w = writeHeadsPtr[ch]
            let r = (w - delayLengthsPtr[ch]) & Self.lineMask
            let raw = delayBufferPtr[ch * Self.lineCapacity + r]
            let lp = oneMinusDamp * raw + damp * dampingStatesPtr[ch]
            dampingStatesPtr[ch] = lp
            return lp
        }

        @inline(__always)
        func writeChannel(_ ch: Int, _ val: Float) {
            let w = writeHeadsPtr[ch]
            delayBufferPtr[ch * Self.lineCapacity + w] = val.isFinite ? val : 0.0
            writeHeadsPtr[ch] = (w + 1) & Self.lineMask
        }

        for i in 0..<frameCount {
            let inL = leftPtr[i]
            let inR = rightPtr[i]
            let exciteL = inL * 0.22
            let exciteR = inR * 0.22

            let d0 = readChannel(0); let d1 = readChannel(1)
            let d2 = readChannel(2); let d3 = readChannel(3)
            let d4 = readChannel(4); let d5 = readChannel(5)
            let d6 = readChannel(6); let d7 = readChannel(7)

            // 8-point Fast Walsh-Hadamard orthogonal butterfly
            let a0 = d0 + d1; let a1 = d0 - d1
            let a2 = d2 + d3; let a3 = d2 - d3
            let a4 = d4 + d5; let a5 = d4 - d5
            let a6 = d6 + d7; let a7 = d6 - d7

            let b0 = a0 + a2; let b1 = a1 + a3
            let b2 = a0 - a2; let b3 = a1 - a3
            let b4 = a4 + a6; let b5 = a5 + a7
            let b6 = a4 - a6; let b7 = a5 - a7

            writeChannel(0, (b0 + b4) * normHadamard + exciteL)
            writeChannel(1, (b1 + b5) * normHadamard + exciteR)
            writeChannel(2, (b2 + b6) * normHadamard + exciteL)
            writeChannel(3, (b3 + b7) * normHadamard - exciteR)
            writeChannel(4, (b0 - b4) * normHadamard - exciteL)
            writeChannel(5, (b1 - b5) * normHadamard + exciteR)
            writeChannel(6, (b2 - b6) * normHadamard + exciteL)
            writeChannel(7, (b3 - b7) * normHadamard + exciteR)

            let wetL = (d0 + d2 + d4 + d6) * 0.38
            let wetR = (d1 + d3 + d5 + d7) * 0.38

            leftPtr[i] = inL * dryMix + wetL * clampedWet
            rightPtr[i] = inR * dryMix + wetR * clampedWet
        }
    }
}

/// Zero-allocation raw-pointer 128-tap KEMAR anthropometric binaural spatializer
/// blending zero-latency direct stereo transients with KEMAR pinna/ITD/ILD FIR reflections.
internal final class RawPointerKEMARSpatialStage: @unchecked Sendable {
    private static let tapCount: Int = StereoHRIRPair.tapCount // 128
    private static let historyCapacity: Int = 256
    private static let historyMask: Int = 255

    private let hrirLeftPtr: UnsafeMutablePointer<Float>
    private let hrirRightPtr: UnsafeMutablePointer<Float>
    private let historyRingPtr: UnsafeMutablePointer<Float>
    private var historyWriteHead: Int = 0
    private var sampleRate: Double
    private var activePose: BinauralSourcePose

    init(sampleRate: Double = 48_000.0) {
        self.sampleRate = max(44_100.0, sampleRate)
        self.activePose = BinauralSourcePose(azimuthDeg: 0.0, elevationDeg: 0.0, distanceMeters: 1.4)

        self.hrirLeftPtr = UnsafeMutablePointer<Float>.allocate(capacity: Self.tapCount)
        self.hrirLeftPtr.initialize(repeating: 0.0, count: Self.tapCount)

        self.hrirRightPtr = UnsafeMutablePointer<Float>.allocate(capacity: Self.tapCount)
        self.hrirRightPtr.initialize(repeating: 0.0, count: Self.tapCount)

        self.historyRingPtr = UnsafeMutablePointer<Float>.allocate(capacity: Self.historyCapacity)
        self.historyRingPtr.initialize(repeating: 0.0, count: Self.historyCapacity)

        _ = KEMARHRIRSynthesizer.synthesizeInto(
            pose: activePose,
            sampleRate: self.sampleRate,
            outLeft: hrirLeftPtr,
            outRight: hrirRightPtr
        )
    }

    deinit {
        hrirLeftPtr.deinitialize(count: Self.tapCount)
        hrirLeftPtr.deallocate()
        hrirRightPtr.deinitialize(count: Self.tapCount)
        hrirRightPtr.deallocate()
        historyRingPtr.deinitialize(count: Self.historyCapacity)
        historyRingPtr.deallocate()
    }

    func reconfigure(sampleRate: Double) {
        self.sampleRate = max(44_100.0, sampleRate)
        reset()
        _ = KEMARHRIRSynthesizer.synthesizeInto(
            pose: activePose,
            sampleRate: self.sampleRate,
            outLeft: hrirLeftPtr,
            outRight: hrirRightPtr
        )
    }

    @inline(__always)
    func reset() {
        for i in 0..<Self.historyCapacity { historyRingPtr[i] = 0.0 }
        historyWriteHead = 0
    }

    @inline(__always)
    func processInPlace(
        leftPtr: UnsafeMutablePointer<Float>,
        rightPtr: UnsafeMutablePointer<Float>,
        frameCount: Int,
        azimuthDeg: Float,
        elevationDeg: Float,
        distanceMeters: Float,
        spatialBlend: Float
    ) {
        guard frameCount > 0 else { return }

        let targetPose = BinauralSourcePose(
            azimuthDeg: azimuthDeg,
            elevationDeg: elevationDeg,
            distanceMeters: distanceMeters
        )

        if targetPose.angularSeparationDegrees(from: activePose) > 2.0 ||
            abs(targetPose.distanceMeters - activePose.distanceMeters) > 0.08 {
            _ = KEMARHRIRSynthesizer.synthesizeInto(
                pose: targetPose,
                sampleRate: sampleRate,
                outLeft: hrirLeftPtr,
                outRight: hrirRightPtr
            )
            activePose = targetPose
        }

        let wet = min(max(spatialBlend, 0.0), 0.75)
        let dry = 1.0 - wet * 0.45

        for i in 0..<frameCount {
            let inL = leftPtr[i]
            let inR = rightPtr[i]
            let mono = 0.5 * (inL + inR)

            historyRingPtr[historyWriteHead] = mono

            var convL: Float = 0.0
            var convR: Float = 0.0
            if wet > 0.001 {
                var readIdx = historyWriteHead
                for tap in 0..<Self.tapCount {
                    let x = historyRingPtr[readIdx]
                    convL += x * hrirLeftPtr[tap]
                    convR += x * hrirRightPtr[tap]
                    readIdx = (readIdx - 1) & Self.historyMask
                }
            }

            historyWriteHead = (historyWriteHead + 1) & Self.historyMask

            // Direct stereo transient stays at exact 0-sample latency while KEMAR spatial field wraps 3D image
            leftPtr[i] = inL * dry + convL * wet
            rightPtr[i] = inR * dry + convR * wet
        }
    }
}

// MARK: - 4. Lock-Free Real-Time AUv3 Render Context (Zero Obj-C / Zero Heap Allocations)

public final class AUv3RealtimeRenderKernel: @unchecked Sendable {
    public static let scopeWindowLength: Int = 256

    public let parameterBank: RealtimeParameterBank
    public let voiceBank: MPEPolyphonicVoiceBank
    private let fdnReverb: RawPointerHadamardFDNReverb
    private let kemarStage: RawPointerKEMARSpatialStage
    private var droneKernel: ProceduralSynthKernel

    // Pre-allocated input pull & scratch raw buffers
    private var maxAllocatedFrames: Int = 4_096
    private var pullBufferList: UnsafeMutableAudioBufferListPointer
    private var inputScratchLeft: UnsafeMutablePointer<Float>
    private var inputScratchRight: UnsafeMutablePointer<Float>
    private var droneScratchLeft: UnsafeMutablePointer<Float>
    private var droneScratchRight: UnsafeMutablePointer<Float>

    // External Input Bus 24dB 4-Pole Cascaded Cytomic TPT SVF state
    private var inSvf1Ic1L: Float = 0.0; private var inSvf1Ic2L: Float = 0.0
    private var inSvf2Ic1L: Float = 0.0; private var inSvf2Ic2L: Float = 0.0
    private var inSvf1Ic1R: Float = 0.0; private var inSvf1Ic2R: Float = 0.0
    private var inSvf2Ic1R: Float = 0.0; private var inSvf2Ic2R: Float = 0.0

    // Host Musical Context & Transport Blocks (captured during allocateRenderResources)
    public var hostMusicalContextBlock: AUHostMusicalContextBlock?
    public var hostTransportStateBlock: AUHostTransportStateBlock?
    public var autonomousDroneEnabled: Bool = false

    // Live DAW transport telemetry
    public private(set) var lastHostTempoBPM: Double = 120.0
    public private(set) var lastHostBeatPosition: Double = 0.0
    public private(set) var isHostTransportMoving: Bool = false

    // 256-sample UI FFT scope ring buffer protected by non-blocking trylock
    private let scopeLock: UnsafeMutablePointer<os_unfair_lock_s>
    private let scopeRingPtr: UnsafeMutablePointer<Float>
    private var scopeWriteHead: Int = 0
    public private(set) var sampleRate: Double = 48_000.0

    public init(parameterBank: RealtimeParameterBank, initialSampleRate: Double = 48_000.0) {
        let safeRate = max(44_100.0, min(initialSampleRate, 192_000.0))
        self.sampleRate = safeRate
        self.parameterBank = parameterBank
        self.voiceBank = MPEPolyphonicVoiceBank(sampleRate: safeRate)
        self.fdnReverb = RawPointerHadamardFDNReverb(sampleRate: safeRate)
        self.kemarStage = RawPointerKEMARSpatialStage(sampleRate: safeRate)
        self.droneKernel = ProceduralSynthKernel(sampleRate: safeRate)

        let cap = maxAllocatedFrames
        self.inputScratchLeft = UnsafeMutablePointer<Float>.allocate(capacity: cap)
        self.inputScratchLeft.initialize(repeating: 0.0, count: cap)
        self.inputScratchRight = UnsafeMutablePointer<Float>.allocate(capacity: cap)
        self.inputScratchRight.initialize(repeating: 0.0, count: cap)

        self.droneScratchLeft = UnsafeMutablePointer<Float>.allocate(capacity: cap)
        self.droneScratchLeft.initialize(repeating: 0.0, count: cap)
        self.droneScratchRight = UnsafeMutablePointer<Float>.allocate(capacity: cap)
        self.droneScratchRight.initialize(repeating: 0.0, count: cap)

        self.pullBufferList = AudioBufferList.allocate(maximumBuffers: 2)
        self.pullBufferList.count = 2
        self.pullBufferList[0] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(cap * MemoryLayout<Float>.size),
            mData: UnsafeMutableRawPointer(self.inputScratchLeft)
        )
        self.pullBufferList[1] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(cap * MemoryLayout<Float>.size),
            mData: UnsafeMutableRawPointer(self.inputScratchRight)
        )

        self.scopeLock = UnsafeMutablePointer<os_unfair_lock_s>.allocate(capacity: 1)
        self.scopeLock.initialize(to: os_unfair_lock_s())
        self.scopeRingPtr = UnsafeMutablePointer<Float>.allocate(capacity: Self.scopeWindowLength)
        self.scopeRingPtr.initialize(repeating: 0.0, count: Self.scopeWindowLength)
    }

    deinit {
        freeScratchBuffers()
        free(pullBufferList.unsafeMutablePointer)
        scopeLock.deinitialize(count: 1)
        scopeLock.deallocate()
        scopeRingPtr.deinitialize(count: Self.scopeWindowLength)
        scopeRingPtr.deallocate()
    }

    private func freeScratchBuffers() {
        inputScratchLeft.deinitialize(count: maxAllocatedFrames)
        inputScratchLeft.deallocate()
        inputScratchRight.deinitialize(count: maxAllocatedFrames)
        inputScratchRight.deallocate()
        droneScratchLeft.deinitialize(count: maxAllocatedFrames)
        droneScratchLeft.deallocate()
        droneScratchRight.deinitialize(count: maxAllocatedFrames)
        droneScratchRight.deallocate()
    }

    public func allocateResources(sampleRate: Double, maxFrames: Int) {
        let safeRate = max(44_100.0, min(sampleRate, 192_000.0))
        let requiredFrames = max(512, maxFrames)

        if requiredFrames > maxAllocatedFrames {
            freeScratchBuffers()
            maxAllocatedFrames = requiredFrames
            inputScratchLeft = UnsafeMutablePointer<Float>.allocate(capacity: requiredFrames)
            inputScratchLeft.initialize(repeating: 0.0, count: requiredFrames)
            inputScratchRight = UnsafeMutablePointer<Float>.allocate(capacity: requiredFrames)
            inputScratchRight.initialize(repeating: 0.0, count: requiredFrames)
            droneScratchLeft = UnsafeMutablePointer<Float>.allocate(capacity: requiredFrames)
            droneScratchLeft.initialize(repeating: 0.0, count: requiredFrames)
            droneScratchRight = UnsafeMutablePointer<Float>.allocate(capacity: requiredFrames)
            droneScratchRight.initialize(repeating: 0.0, count: requiredFrames)
        }

        self.sampleRate = safeRate
        self.parameterBank.resetRenderStateFromAtomics()
        self.voiceBank.reconfigure(sampleRate: safeRate)
        self.fdnReverb.reconfigure(sampleRate: safeRate)
        self.kemarStage.reconfigure(sampleRate: safeRate)
        self.droneKernel = ProceduralSynthKernel(
            sampleRate: safeRate,
            snapInitialParameters: parameterBank.makeSynthParametersSnapshot()
        )
        resetInputFilterState()
    }

    public func deallocateResources() {
        voiceBank.resetAllVoices()
        fdnReverb.reset()
        kemarStage.reset()
        resetInputFilterState()
        hostMusicalContextBlock = nil
        hostTransportStateBlock = nil
    }

    @inline(__always)
    private func resetInputFilterState() {
        inSvf1Ic1L = 0.0; inSvf1Ic2L = 0.0
        inSvf2Ic1L = 0.0; inSvf2Ic2L = 0.0
        inSvf1Ic1R = 0.0; inSvf1Ic2R = 0.0
        inSvf2Ic1R = 0.0; inSvf2Ic2R = 0.0
    }

    public func copyRecentScopeSamples() -> [Float] {
        var out = [Float](repeating: 0.0, count: Self.scopeWindowLength)
        os_unfair_lock_lock(scopeLock)
        let head = scopeWriteHead
        for i in 0..<Self.scopeWindowLength {
            out[i] = scopeRingPtr[(head + i) & (Self.scopeWindowLength - 1)]
        }
        os_unfair_lock_unlock(scopeLock)
        return out
    }

    // MARK: Sample-Accurate Real-Time Render Entry Point (ZERO Allocations / ZERO Locks)

    @inline(__always)
    public func render(
        actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        frameCount: AUAudioFrameCount,
        outputBusNumber: Int,
        outputData: UnsafeMutablePointer<AudioBufferList>,
        realtimeEventListHead: UnsafePointer<AURenderEvent>?,
        pullInputBlock: AURenderPullInputBlock?
    ) -> AUAudioUnitStatus {
        _ = outputBusNumber
        let totalFrames = min(Int(frameCount), maxAllocatedFrames)
        guard totalFrames > 0 else { return noErr }

        // 1. Sync non-ramping atomic parameter edits from UI/Host
        parameterBank.pullHostUpdatesOnAudioThread()

        // 2. Query DAW Musical Context & Transport State using stack scalars only
        if let musicalBlock = hostMusicalContextBlock {
            var tempo: Double = 120.0
            var sigNum: Double = 4.0
            var sigDenom: Int = 4
            var beatPos: Double = 0.0
            var nextBeatOffset: Int = 0
            var downbeatPos: Double = 0.0
            if musicalBlock(&tempo, &sigNum, &sigDenom, &beatPos, &nextBeatOffset, &downbeatPos) {
                lastHostTempoBPM = max(20.0, min(tempo, 320.0))
                lastHostBeatPosition = beatPos
            }
        }

        if let transportBlock = hostTransportStateBlock {
            var flags = AUHostTransportStateFlags(rawValue: 0)
            var samplePos: Double = 0.0
            var cycleStart: Double = 0.0
            var cycleEnd: Double = 0.0
            if transportBlock(&flags, &samplePos, &cycleStart, &cycleEnd) {
                let moving = flags.contains(.moving)
                if flags.contains(.changed) && !moving {
                    fdnReverb.reset()
                }
                isHostTransportMoving = moving
            }
        }

        // 3. Pull Optional External Stereo Input Bus for FX Processing
        var hasExternalAudio = false
        if let pullBlock = pullInputBlock {
            let byteSize = UInt32(totalFrames * MemoryLayout<Float>.size)
            pullBufferList.count = 2
            pullBufferList[0] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: byteSize,
                mData: UnsafeMutableRawPointer(inputScratchLeft)
            )
            pullBufferList[1] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: byteSize,
                mData: UnsafeMutableRawPointer(inputScratchRight)
            )
            var pullFlags = AudioUnitRenderActionFlags(rawValue: 0)
            let pullStatus = pullBlock(&pullFlags, timestamp, AUAudioFrameCount(totalFrames), 0, pullBufferList.unsafeMutablePointer)
            if pullStatus == noErr && !pullFlags.contains(.unitRenderAction_OutputIsSilence) {
                hasExternalAudio = true
            }
        }

        // 4. Resolve Output Stereo Buffer Pointers (allocating host buffer pointers if mData is nil)
        let outABL = UnsafeMutableAudioBufferListPointer(outputData)
        guard !outABL.isEmpty else { return noErr }

        if outABL[0].mData == nil {
            outABL[0].mData = UnsafeMutableRawPointer(droneScratchLeft)
        }
        if outABL.count >= 2 && outABL[1].mData == nil {
            outABL[1].mData = UnsafeMutableRawPointer(droneScratchRight)
        }

        guard let outLeftBase = outABL[0].mData?.assumingMemoryBound(to: Float.self) else {
            return noErr
        }
        let outRightBase: UnsafeMutablePointer<Float>
        if outABL.count >= 2, let rPtr = outABL[1].mData?.assumingMemoryBound(to: Float.self) {
            outRightBase = rPtr
        } else {
            outRightBase = outLeftBase
        }

        // 5. Partition `totalFrames` into Sample-Accurate Sub-Blocks at Every `eventSampleTime` Boundary
        let bufferStartSampleTime = AUEventSampleTime(timestamp.pointee.mSampleTime.rounded())
        var currentOffset: Int = 0
        var eventCursor: UnsafePointer<AURenderEvent>? = realtimeEventListHead

        while currentOffset < totalFrames {
            // Consume all scheduled events occurring at or before `currentOffset`
            while let evPtr = eventCursor {
                let evSampleTime = evPtr.pointee.head.eventSampleTime
                let relFrame = Int(evSampleTime - bufferStartSampleTime)
                if relFrame > currentOffset {
                    break
                }

                switch evPtr.pointee.head.eventType {
                case .parameter:
                    let p = evPtr.pointee.parameter
                    parameterBank.scheduleRenderParameterEvent(
                        address: p.parameterAddress,
                        targetValue: p.value,
                        rampDurationFrames: 0
                    )
                case .parameterRamp:
                    let p = evPtr.pointee.parameter
                    parameterBank.scheduleRenderParameterEvent(
                        address: p.parameterAddress,
                        targetValue: p.value,
                        rampDurationFrames: p.rampDurationSampleFrames
                    )
                case .MIDI:
                    let m = evPtr.pointee.MIDI
                    if m.length >= 1 {
                        voiceBank.handleMIDIPacket(
                            status: m.data.0,
                            data1: m.data.1,
                            data2: m.data.2
                        )
                    }
                default:
                    break
                }

                eventCursor = evPtr.pointee.head.next.map { UnsafePointer($0) }
            }

            // Compute exact boundary of next event within [currentOffset + 1 ... totalFrames]
            let nextBoundary: Int
            if let nextEvPtr = eventCursor {
                let rel = Int(nextEvPtr.pointee.head.eventSampleTime - bufferStartSampleTime)
                nextBoundary = min(totalFrames, max(currentOffset + 1, rel))
            } else {
                nextBoundary = totalFrames
            }

            let sliceFrames = nextBoundary - currentOffset
            let sliceOutL = outLeftBase.advanced(by: currentOffset)
            let sliceOutR = outRightBase.advanced(by: currentOffset)

            // 5a. Render MPE 8-Voice Polyphonic Synthesizer + Step Linear Parameter Ramps
            voiceBank.renderSubBlock(
                leftOut: sliceOutL,
                rightOut: sliceOutR,
                frameCount: sliceFrames,
                parameterBank: parameterBank,
                accumulate: false
            )

            // 5b. Optional Autonomous Procedural Binaural Drone Layer
            if autonomousDroneEnabled {
                if isHostTransportMoving {
                    let fracBeat = lastHostBeatPosition - floor(lastHostBeatPosition)
                    droneKernel.masterPhaseSyncTarget = fracBeat
                }
                let snapParams = parameterBank.makeSynthParametersSnapshot()
                _ = droneKernel.renderStereoBlock(
                    leftOutput: droneScratchLeft,
                    rightOutput: droneScratchRight,
                    frameCount: sliceFrames,
                    target: snapParams
                )
                for f in 0..<sliceFrames {
                    sliceOutL[f] += droneScratchLeft[f] * 0.65
                    sliceOutR[f] += droneScratchRight[f] * 0.65
                }
            }

            // 5c. External Stereo Input Bus -> 24dB 4-Pole Cascaded Cytomic TPT SVF Pass
            if hasExternalAudio {
                let sliceInL = inputScratchLeft.advanced(by: currentOffset)
                let sliceInR = inputScratchRight.advanced(by: currentOffset)
                processExternalInputSVF(
                    inLeft: sliceInL,
                    inRight: sliceInR,
                    outLeft: sliceOutL,
                    outRight: sliceOutR,
                    frameCount: sliceFrames
                )
            }

            // 5d. KEMAR Anthropometric HRTF Spatial Stage + 8x8 Sylvester-Hadamard FDN Reverb
            if voiceBank.activeVoiceCount > 0 || autonomousDroneEnabled || hasExternalAudio {
                let spatialAmt = min(0.65, parameterBank.renderValue(.neuralSoundscapeMix) * 0.70 + 0.12)
                kemarStage.processInPlace(
                    leftPtr: sliceOutL,
                    rightPtr: sliceOutR,
                    frameCount: sliceFrames,
                    azimuthDeg: parameterBank.renderValue(.hrtfAzimuthDeg),
                    elevationDeg: parameterBank.renderValue(.hrtfElevationDeg),
                    distanceMeters: parameterBank.renderValue(.hrtfDistanceMeters),
                    spatialBlend: spatialAmt
                )

                fdnReverb.processInPlace(
                    leftPtr: sliceOutL,
                    rightPtr: sliceOutR,
                    frameCount: sliceFrames,
                    wetMix: parameterBank.renderValue(.reverbWetMix),
                    decaySeconds: parameterBank.renderValue(.reverbDecaySeconds)
                )

                // Final safety clamp preventing NaN or > 0 dBFS spikes
                for f in 0..<sliceFrames {
                    let l = sliceOutL[f]
                    let r = sliceOutR[f]
                    sliceOutL[f] = l.isFinite ? min(max(l, -1.0), 1.0) : 0.0
                    sliceOutR[f] = r.isFinite ? min(max(r, -1.0), 1.0) : 0.0
                }
            }

            currentOffset = nextBoundary
        }

        // 6. Publish ramped parameter endpoints & 256-sample FFT scope tap
        parameterBank.publishRenderValuesToAtomics()

        if os_unfair_lock_trylock(scopeLock) {
            let mask = Self.scopeWindowLength - 1
            let startIdx = max(0, totalFrames - Self.scopeWindowLength)
            var head = scopeWriteHead
            for i in startIdx..<totalFrames {
                scopeRingPtr[head] = 0.5 * (outLeftBase[i] + outRightBase[i])
                head = (head + 1) & mask
            }
            scopeWriteHead = head
            os_unfair_lock_unlock(scopeLock)
        }

        _ = actionFlags
        return noErr
    }

    @inline(__always)
    private func processExternalInputSVF(
        inLeft: UnsafePointer<Float>,
        inRight: UnsafePointer<Float>,
        outLeft: UnsafeMutablePointer<Float>,
        outRight: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        let maxSafeCut = Float(sampleRate * 0.44)
        let cutoff = min(max(parameterBank.renderValue(.filterCutoffHz), 60.0), maxSafeCut)
        let resonance = min(max(parameterBank.renderValue(.filterResonance), 0.05), 0.94)
        let gain = parameterBank.renderValue(.masterGain)

        let g = tanf(Float.pi * cutoff / Float(sampleRate))
        let k = 2.0 - 2.0 * resonance
        let a1 = 1.0 / (1.0 + g * (g + k))
        let a2 = g * a1
        let a3 = g * a2

        for i in 0..<frameCount {
            let xL = inLeft[i]
            let xR = inRight[i]

            let v3_1L = xL - inSvf1Ic2L
            let v1_1L = a1 * inSvf1Ic1L + a2 * v3_1L
            let v2_1L = inSvf1Ic2L + a2 * inSvf1Ic1L + a3 * v3_1L
            inSvf1Ic1L = 2.0 * v1_1L - inSvf1Ic1L
            inSvf1Ic2L = 2.0 * v2_1L - inSvf1Ic2L

            let v3_2L = v2_1L - inSvf2Ic2L
            let v1_2L = a1 * inSvf2Ic1L + a2 * v3_2L
            let v2_2L = inSvf2Ic2L + a2 * inSvf2Ic1L + a3 * v3_2L
            inSvf2Ic1L = 2.0 * v1_2L - inSvf2Ic1L
            inSvf2Ic2L = 2.0 * v2_2L - inSvf2Ic2L

            let v3_1R = xR - inSvf1Ic2R
            let v1_1R = a1 * inSvf1Ic1R + a2 * v3_1R
            let v2_1R = inSvf1Ic2R + a2 * inSvf1Ic1R + a3 * v3_1R
            inSvf1Ic1R = 2.0 * v1_1R - inSvf1Ic1R
            inSvf1Ic2R = 2.0 * v2_1R - inSvf1Ic2R

            let v3_2R = v2_1R - inSvf2Ic2R
            let v1_2R = a1 * inSvf2Ic1R + a2 * v3_2R
            let v2_2R = inSvf2Ic2R + a2 * inSvf2Ic1R + a3 * v3_2R
            inSvf2Ic1R = 2.0 * v1_2R - inSvf2Ic1R
            inSvf2Ic2R = 2.0 * v2_2R - inSvf2Ic2R

            outLeft[i] += (v2_2L.isFinite ? v2_2L : 0.0) * gain
            outRight[i] += (v2_2R.isFinite ? v2_2R : 0.0) * gain
        }
    }
}

// MARK: - 5. AetherSynthAudioUnit (Audio Unit v3 Instrument & Stereo FX Subclass)

public final class AetherSynthAudioUnit: AUAudioUnit, @unchecked Sendable {
    public static let componentType: FourCharCode = kAudioUnitType_MusicEffect // 'aumu'
    public static let componentSubType: FourCharCode = 0x6165_7468             // 'aeth'
    public static let componentManufacturer: FourCharCode = 0x4145_5448        // 'AETH'
    public static let componentVersion: UInt32 = 0x0001_0000                   // 65536 (1.0.0)

    public static let defaultComponentDescription = AudioComponentDescription(
        componentType: componentType,
        componentSubType: componentSubType,
        componentManufacturer: componentManufacturer,
        componentFlags: 0,
        componentFlagsMask: 0
    )

    public let parameterBank: RealtimeParameterBank
    public let renderKernel: AUv3RealtimeRenderKernel

    private let _parameterTree: AUParameterTree
    private let _inputBus: AUAudioUnitBus
    private let _outputBus: AUAudioUnitBus
    private var _inputBusArray: AUAudioUnitBusArray!
    private var _outputBusArray: AUAudioUnitBusArray!
    private let _factoryPresets: [AUAudioUnitPreset]
    private var _currentPreset: AUAudioUnitPreset?

    private static let stateParametersKey = "aetherParameters"
    private static let statePresetNumberKey = "aetherPresetNumber"
    private static let stateDroneEnabledKey = "aetherAutonomousDrone"

    public override init(
        componentDescription: AudioComponentDescription,
        options: AudioComponentInstantiationOptions = []
    ) throws {
        let bank = RealtimeParameterBank()
        let tree = AUParameterTreeBridge.buildParameterTree(bank: bank)
        let kernel = AUv3RealtimeRenderKernel(parameterBank: bank, initialSampleRate: 48_000.0)

        guard let defaultStereoFormat = AVAudioFormat(
            standardFormatWithSampleRate: 48_000.0,
            channels: 2
        ) else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(kAudioUnitErr_FormatNotSupported),
                userInfo: [NSLocalizedDescriptionKey: "Failed to initialize default 48 kHz stereo AVAudioFormat."]
            )
        }

        let inBus = try AUAudioUnitBus(format: defaultStereoFormat)
        inBus.maximumChannelCount = 2
        let outBus = try AUAudioUnitBus(format: defaultStereoFormat)
        outBus.maximumChannelCount = 2

        let builtPresets: [AUAudioUnitPreset] = AetherAUFactoryPresetSpec.allPresets.map { spec in
            let p = AUAudioUnitPreset()
            p.number = spec.number
            p.name = spec.name
            return p
        }

        self.parameterBank = bank
        self._parameterTree = tree
        self.renderKernel = kernel
        self._inputBus = inBus
        self._outputBus = outBus
        self._factoryPresets = builtPresets
        self._currentPreset = builtPresets.first

        try super.init(componentDescription: componentDescription, options: options)

        self._inputBusArray = AUAudioUnitBusArray(
            audioUnit: self,
            busType: .input,
            busses: [inBus]
        )
        self._outputBusArray = AUAudioUnitBusArray(
            audioUnit: self,
            busType: .output,
            busses: [outBus]
        )

        self.maximumFramesToRender = 4_096
        if let initialSpec = AetherAUFactoryPresetSpec.allPresets.first {
            applyFactoryPresetSpec(initialSpec)
        }
    }

    // MARK: Bus & Capability Overrides

    public override var inputBusses: AUAudioUnitBusArray {
        _inputBusArray
    }

    public override var outputBusses: AUAudioUnitBusArray {
        _outputBusArray
    }

    public override var channelCapabilities: [NSNumber]? {
        // Supports [0-in, 2-out] pure MIDI/MPE instrument AND [2-in, 2-out] stereo audio FX
        [0, 2, 2, 2]
    }

    public override var parameterTree: AUParameterTree? {
        get { _parameterTree }
        set { _ = newValue }
    }

    public override var canProcessInPlace: Bool {
        false
    }

    public override var supportsMPE: Bool {
        true
    }

    // MARK: Render Resource Lifecycle (44.1 kHz ... 192 kHz)

    public override func allocateRenderResources() throws {
        let outFormat = _outputBus.format
        guard outFormat.channelCount == 2,
              outFormat.sampleRate >= 44_100.0 && outFormat.sampleRate <= 192_000.0 else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(kAudioUnitErr_FormatNotSupported),
                userInfo: [
                    NSLocalizedDescriptionKey: "AetherSynthAUv3 requires stereo output between 44.1 kHz and 192 kHz."
                ]
            )
        }

        try super.allocateRenderResources()

        renderKernel.hostMusicalContextBlock = self.musicalContextBlock
        renderKernel.hostTransportStateBlock = self.transportStateBlock
        renderKernel.allocateResources(
            sampleRate: outFormat.sampleRate,
            maxFrames: Int(max(maximumFramesToRender, 512))
        )
    }

    public override func deallocateRenderResources() {
        renderKernel.deallocateResources()
        super.deallocateRenderResources()
    }

    // MARK: State Persistence & Factory Presets

    public override var factoryPresets: [AUAudioUnitPreset]? {
        _factoryPresets
    }

    public override var currentPreset: AUAudioUnitPreset? {
        get { _currentPreset }
        set {
            guard let preset = newValue else {
                _currentPreset = nil
                return
            }
            if preset.number >= 0,
               let spec = AetherAUFactoryPresetSpec.allPresets.first(where: { $0.number == preset.number }) {
                _currentPreset = _factoryPresets.first(where: { $0.number == preset.number }) ?? preset
                applyFactoryPresetSpec(spec)
            } else {
                _currentPreset = preset
            }
        }
    }

    private func applyFactoryPresetSpec(_ spec: AetherAUFactoryPresetSpec) {
        for (addr, val) in spec.values {
            let clamped = addr.clamp(val)
            parameterBank.setHostValue(clamped, for: addr)
            _parameterTree.parameter(withAddress: addr.rawValue)?.value = clamped
        }
    }

    public override var fullState: [String: Any]? {
        get {
            var dict = super.fullState ?? [:]
            dict[Self.stateParametersKey] = parameterBank.exportDictionary()
            if let presetNum = _currentPreset?.number {
                dict[Self.statePresetNumberKey] = presetNum
            }
            dict[Self.stateDroneEnabledKey] = renderKernel.autonomousDroneEnabled
            return dict
        }
        set {
            super.fullState = newValue
            guard let dict = newValue else { return }
            if let paramDict = dict[Self.stateParametersKey] as? [String: Any] {
                parameterBank.importDictionary(paramDict)
                for param in AetherAUParameterAddress.allCases {
                    let v = parameterBank.getHostValue(for: param)
                    _parameterTree.parameter(withAddress: param.rawValue)?.value = v
                }
            }
            if let presetNum = dict[Self.statePresetNumberKey] as? Int {
                _currentPreset = _factoryPresets.first(where: { $0.number == presetNum })
            }
            if let drone = dict[Self.stateDroneEnabledKey] as? Bool {
                renderKernel.autonomousDroneEnabled = drone
            }
        }
    }

    public override var fullStateForDocument: [String: Any]? {
        get { fullState }
        set { fullState = newValue }
    }

    // MARK: Sample-Accurate C-Style Real-Time Render Callback (Zero Obj-C / Zero Allocations)

    public override var internalRenderBlock: AUInternalRenderBlock {
        let kernel = self.renderKernel
        return { actionFlags, timestamp, frameCount, outputBusNumber, outputData, realtimeEventListHead, pullInputBlock in
            kernel.render(
                actionFlags: actionFlags,
                timestamp: timestamp,
                frameCount: frameCount,
                outputBusNumber: outputBusNumber,
                outputData: outputData,
                realtimeEventListHead: realtimeEventListHead,
                pullInputBlock: pullInputBlock
            )
        }
    }
}
#endif
