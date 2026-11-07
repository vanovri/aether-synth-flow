// MARK: - FILE: AudioSynthEngine.swift

import Foundation
import AVFoundation
import simd
import os
#if os(macOS)
import CoreAudio
import AudioToolbox
#endif

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
    public var spatialPanOffset: Float         // -1.0 (left) ... +1.0 (right) from AirPods head yaw
    public var headElevationTilt: Float        // -1.0 (down) ... +1.0 (up) from AirPods head pitch
    public var hrtfAzimuthDeg: Float           // [-180.0 ... +180.0] 3D virtual source azimuth
    public var hrtfElevationDeg: Float         // [-45.0 ... +90.0] 3D virtual source elevation
    public var hrtfDistanceMeters: Float       // [0.15 ... 10.0] 3D virtual source radial distance
    public var roomPresetIndex: Int            // 0 = Anechoic, 1 = Obsidian Studio, 2 = Conservatory, 3 = Cathedral
    public var isHRTFSpatializerEnabled: Bool  // Enables KEMAR 128-tap UPOLS + 3D Shoebox ISM + Orbital spatializer
    public var headQuaternion: SIMD4<Float>    // Listener head orientation quaternion (ix, iy, iz, r)
    public var orbitalSatellites: OrbitalSatelliteBank
    public var neuralSoundscapeMix: Float      // [0.0 ... 1.0] RVQ + Snake Neural Latent Diffusion mix
    public var latentGuidanceScale: Float      // [1.0 ... 4.0] Rectified-Flow Classifier-Free Guidance scale
    public var latentTemperature: Float        // [0.1 ... 2.0] Gaussian prior latent entropy temperature
    public var rayTracedAcousticsEnabled: Bool // Enables Metal/SAH-BVH ray-traced 512-tap DRIR convolution
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
        hrtfAzimuthDeg: Float = 0.0,
        hrtfElevationDeg: Float = 12.0,
        hrtfDistanceMeters: Float = 1.4,
        roomPresetIndex: Int = ShoeboxRoomPreset.obsidianStudio.rawValue,
        isHRTFSpatializerEnabled: Bool = false,
        headQuaternion: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 1),
        orbitalSatellites: OrbitalSatelliteBank = OrbitalSatelliteBank(),
        neuralSoundscapeMix: Float = 0.0,
        latentGuidanceScale: Float = 2.2,
        latentTemperature: Float = 0.85,
        rayTracedAcousticsEnabled: Bool = false,
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
        self.hrtfAzimuthDeg = BinauralSourcePose.wrapAzimuthDegrees(hrtfAzimuthDeg)
        self.hrtfElevationDeg = min(max(hrtfElevationDeg, -45.0), 90.0)
        self.hrtfDistanceMeters = min(max(hrtfDistanceMeters, 0.15), 10.0)
        self.roomPresetIndex = min(max(roomPresetIndex, 0), ShoeboxRoomPreset.allCases.count - 1)
        self.isHRTFSpatializerEnabled = isHRTFSpatializerEnabled
        self.headQuaternion = headQuaternion
        self.orbitalSatellites = orbitalSatellites
        self.neuralSoundscapeMix = min(max(neuralSoundscapeMix, 0.0), 1.0)
        self.latentGuidanceScale = min(max(latentGuidanceScale, 1.0), 4.0)
        self.latentTemperature = min(max(latentTemperature, 0.1), 2.0)
        self.rayTracedAcousticsEnabled = rayTracedAcousticsEnabled
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
            neuralSoundscapeMix: 0.24,
            latentGuidanceScale: 2.2,
            latentTemperature: 0.85,
            rayTracedAcousticsEnabled: true,
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
    private static let spatialChunkCapacity: Int = 512

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
    private var smoothNeuralMix: Float = 0.0
    private var smoothRayTracedMix: Float = 0.0

    // Phase 6 Pre-Allocated KEMAR HRTF UPOLS Convolver, 3D Shoebox ISM + FDN & Multi-Satellite Spatializer
    private var hrtfConvolver: SpatialHRTFConvolver
    private var roomSimulator: ShoeboxRoomSimulator
    private var orbitalSpatializer: OrbitalHabitSpatializer
    private var monoSpatialExcitation: [Float]
    private var roomSendScratch: [Float]
    private var hrtfLeftScratch: [Float]
    private var hrtfRightScratch: [Float]
    private var earLockedBinauralLeft: [Float]
    private var earLockedBinauralRight: [Float]

    // Phase 7 Pre-Allocated Neural Vocoder Ring Read & Ray-Traced DRIR Convolution Scratch Buffers
    private var neuralLeftScratch: [Float]
    private var neuralRightScratch: [Float]
    private var drirMonoInputScratch: [Float]
    private var drirWetLeftScratch: [Float]
    private var drirWetRightScratch: [Float]

    public init(sampleRate: Double, snapInitialParameters: SynthParameters? = nil) {
        let safeRate = max(8_000.0, sampleRate)
        self.sampleRate = safeRate
        self.invSampleRate = 1.0 / safeRate

        let initialPose = BinauralSourcePose(
            azimuthDeg: snapInitialParameters?.hrtfAzimuthDeg ?? 0.0,
            elevationDeg: snapInitialParameters?.hrtfElevationDeg ?? 12.0,
            distanceMeters: snapInitialParameters?.hrtfDistanceMeters ?? 1.4
        )
        let initialRoom = ShoeboxRoomPreset(rawValue: snapInitialParameters?.roomPresetIndex ?? 1) ?? .obsidianStudio

        self.hrtfConvolver = SpatialHRTFConvolver(sampleRate: safeRate, initialPose: initialPose)
        self.roomSimulator = ShoeboxRoomSimulator(sampleRate: safeRate, initialPreset: initialRoom, initialPose: initialPose)
        self.orbitalSpatializer = OrbitalHabitSpatializer(sampleRate: safeRate)

        self.monoSpatialExcitation = [Float](repeating: 0, count: Self.spatialChunkCapacity)
        self.roomSendScratch = [Float](repeating: 0, count: Self.spatialChunkCapacity)
        self.hrtfLeftScratch = [Float](repeating: 0, count: Self.spatialChunkCapacity)
        self.hrtfRightScratch = [Float](repeating: 0, count: Self.spatialChunkCapacity)
        self.earLockedBinauralLeft = [Float](repeating: 0, count: Self.spatialChunkCapacity)
        self.earLockedBinauralRight = [Float](repeating: 0, count: Self.spatialChunkCapacity)

        self.neuralLeftScratch = [Float](repeating: 0, count: Self.spatialChunkCapacity)
        self.neuralRightScratch = [Float](repeating: 0, count: Self.spatialChunkCapacity)
        self.drirMonoInputScratch = [Float](repeating: 0, count: Self.spatialChunkCapacity)
        self.drirWetLeftScratch = [Float](repeating: 0, count: Self.spatialChunkCapacity)
        self.drirWetRightScratch = [Float](repeating: 0, count: Self.spatialChunkCapacity)

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
            self.smoothNeuralMix = initial.isMuted ? 0.0 : (initial.neuralSoundscapeMix * initial.masterGain)
            self.smoothRayTracedMix = (initial.rayTracedAcousticsEnabled && !initial.isMuted) ? 0.36 : 0.0
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
        target: SynthParameters,
        neuralRingBuffer: NeuralAudioRingBuffer? = nil,
        drirConvolverBridge: RayTracedDRIRConvolverBridge? = nil
    ) -> AudioTelemetrySnapshot {
        guard frameCount > 0 else {
            return AudioTelemetrySnapshot(isRendering: !target.isMuted)
        }

        let baseSnapshot: AudioTelemetrySnapshot
        if target.isHRTFSpatializerEnabled {
            baseSnapshot = renderHRTFSpatialStereoBlock(
                leftOutput: leftOutput,
                rightOutput: rightOutput,
                frameCount: frameCount,
                target: target
            )
        } else {
            baseSnapshot = renderConstantPowerStereoBlock(
                leftOutput: leftOutput,
                rightOutput: rightOutput,
                frameCount: frameCount,
                target: target
            )
        }

        let wantsNeural = neuralRingBuffer != nil && (target.neuralSoundscapeMix > 0.0001 || smoothNeuralMix > 0.0001)
        let wantsRayTraced = drirConvolverBridge != nil && (target.rayTracedAcousticsEnabled || smoothRayTracedMix > 0.0001)
        guard wantsNeural || wantsRayTraced else {
            return baseSnapshot
        }

        // Zero-allocation scratch ownership swap (prevents CoW heap allocation on AVAudioSourceNode thread)
        var localNeuralL = neuralLeftScratch
        var localNeuralR = neuralRightScratch
        var localDRIRMono = drirMonoInputScratch
        var localWetL = drirWetLeftScratch
        var localWetR = drirWetRightScratch
        neuralLeftScratch = []
        neuralRightScratch = []
        drirMonoInputScratch = []
        drirWetLeftScratch = []
        drirWetRightScratch = []

        let slewCoeff = Float(min(1.0, 35.0 * invSampleRate))
        let targetNeuralGain: Float = target.isMuted ? 0.0 : (target.neuralSoundscapeMix * target.masterGain)
        let targetRayMix: Float = (target.rayTracedAcousticsEnabled && !target.isMuted) ? 0.36 : 0.0

        var sumSquares: Float = 0.0
        var peak: Float = 0.0
        var lowAccum: Float = 0.0
        var highAccum: Float = 0.0
        var prevL: Float = 0.0

        var remaining = frameCount
        var offset = 0

        while remaining > 0 {
            let chunk = min(remaining, Self.spatialChunkCapacity)

            if let ring = neuralRingBuffer, wantsNeural {
                localNeuralL.withUnsafeMutableBufferPointer { lBuf in
                    localNeuralR.withUnsafeMutableBufferPointer { rBuf in
                        guard let lBase = lBuf.baseAddress, let rBase = rBuf.baseAddress else { return }
                        _ = ring.popStereoFrames(leftDestination: lBase, rightDestination: rBase, frameCount: chunk)
                    }
                }
            }

            for f in 0..<chunk {
                let idx = offset + f
                var mixedL = leftOutput[idx]
                var mixedR = rightOutput[idx]

                if wantsNeural {
                    smoothNeuralMix += slewCoeff * (targetNeuralGain - smoothNeuralMix)
                    mixedL += localNeuralL[f] * smoothNeuralMix
                    mixedR += localNeuralR[f] * smoothNeuralMix
                }

                leftOutput[idx] = mixedL
                rightOutput[idx] = mixedR
                localDRIRMono[f] = 0.5 * (mixedL + mixedR)
            }

            if let drir = drirConvolverBridge, wantsRayTraced {
                localDRIRMono.withUnsafeBufferPointer { mBuf in
                    localWetL.withUnsafeMutableBufferPointer { wLBuf in
                        localWetR.withUnsafeMutableBufferPointer { wRBuf in
                            guard let mBase = mBuf.baseAddress,
                                  let wLBase = wLBuf.baseAddress,
                                  let wRBase = wRBuf.baseAddress else { return }
                            drir.processRealtimeBlock(
                                monoInput: mBase,
                                wetLeftOutput: wLBase,
                                wetRightOutput: wRBase,
                                frameCount: chunk
                            )
                        }
                    }
                }
            }

            for f in 0..<chunk {
                let idx = offset + f
                var outL = leftOutput[idx]
                var outR = rightOutput[idx]

                if wantsRayTraced {
                    smoothRayTracedMix += slewCoeff * (targetRayMix - smoothRayTracedMix)
                    let dryWeight = 1.0 - 0.18 * smoothRayTracedMix
                    outL = outL * dryWeight + localWetL[f] * smoothRayTracedMix
                    outR = outR * dryWeight + localWetR[f] * smoothRayTracedMix
                }

                outL = fastSoftClip(outL)
                outR = fastSoftClip(outR)
                leftOutput[idx] = outL
                rightOutput[idx] = outR

                let monoAbs = 0.5 * (abs(outL) + abs(outR))
                sumSquares += 0.5 * (outL * outL + outR * outR)
                if monoAbs > peak { peak = monoAbs }
                lowAccum += monoAbs
                highAccum += abs(outL - prevL)
                prevL = outL
            }

            remaining -= chunk
            offset += chunk
        }

        neuralLeftScratch = localNeuralL
        neuralRightScratch = localNeuralR
        drirMonoInputScratch = localDRIRMono
        drirWetLeftScratch = localWetL
        drirWetRightScratch = localWetR

        let invCount = 1.0 / Float(frameCount)
        let rms = sqrt(sumSquares * invCount)
        return AudioTelemetrySnapshot(
            rmsAmplitude: min(max(rms, 0.0), 1.0),
            peakAmplitude: min(max(peak, 0.0), 1.0),
            lowBandEnergy: min(max(lowAccum * invCount, 0.0), 1.0),
            highBandEnergy: min(max(highAccum * invCount * 3.0, 0.0), 1.0),
            isRendering: baseSnapshot.isRendering || smoothNeuralMix > 0.001
        )
    }

    // MARK: - Legacy Constant-Power Stereo Path (Bit-Exact Backward Compatibility)

    private mutating func renderConstantPowerStereoBlock(
        leftOutput: UnsafeMutablePointer<Float>,
        rightOutput: UnsafeMutablePointer<Float>,
        frameCount: Int,
        target: SynthParameters
    ) -> AudioTelemetrySnapshot {
        let slewCoeff = Float(min(1.0, 35.0 * invSampleRate))
        let targetGain: Float = target.isMuted ? 0.0 : target.masterGain

        var sumSquares: Float = 0.0
        var peak: Float = 0.0
        var lowAccum: Float = 0.0
        var highAccum: Float = 0.0
        var previousOutL: Float = 0.0

        let r0 = 0.5, r1 = 0.75, r2 = 1.0, r3 = 1.125, r4 = 1.5

        for i in 0..<frameCount {
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

            let carrier = Double(smoothCarrierHz)
            let halfBeat = Double(smoothBeatHz) * 0.5
            let freqLeft = max(20.0, carrier - halfBeat)
            let freqRight = max(20.0, carrier + halfBeat)

            let binauralL = Float(sin(twoPi * phaseBinauralLeft))
            let binauralR = Float(sin(twoPi * phaseBinauralRight))

            advancePhase(&phaseBinauralLeft, delta: freqLeft * invSampleRate)
            advancePhase(&phaseBinauralRight, delta: freqRight * invSampleRate)
            advancePhase(&phaseSubFundamental, delta: (carrier * 0.5) * invSampleRate)

            let lfoA = Float(sin(twoPi * lfoPhasePrimary))
            let lfoB = Float(cos(twoPi * lfoPhaseSecondary))
            advancePhase(&lfoPhasePrimary, delta: 0.083 * invSampleRate)
            advancePhase(&lfoPhaseSecondary, delta: 0.137 * invSampleRate)

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

            var noiseL: Float = 0.0
            var noiseR: Float = 0.0
            if smoothPinkMix > 0.0005 {
                let pair = nextPinkNoiseStereo()
                noiseL = pair.0
                noiseR = pair.1
            }

            let panAngle = (Float.pi * 0.25) * (1.0 + min(max(smoothSpatialPan, -1.0), 1.0))
            let panGainL = cos(panAngle) * 1.41421356
            let panGainR = sin(panAngle) * 1.41421356
            let elevationFactor = 1.0 + 0.24 * min(max(smoothElevationTilt, -1.0), 1.0)

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

            let preFilterL = binauralL * smoothBinauralMix + (padL * smoothPadMix + noiseL * smoothPinkMix) * panGainL
            let preFilterR = binauralR * smoothBinauralMix + (padR * smoothPadMix + noiseR * smoothPinkMix) * panGainR

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

    // MARK: - Phase 6 KEMAR Binaural HRTF UPOLS + 3D Shoebox Room + Multi-Satellite Orbital Render Path

    private mutating func renderHRTFSpatialStereoBlock(
        leftOutput: UnsafeMutablePointer<Float>,
        rightOutput: UnsafeMutablePointer<Float>,
        frameCount: Int,
        target: SynthParameters
    ) -> AudioTelemetrySnapshot {
        let slewCoeff = Float(min(1.0, 35.0 * invSampleRate))
        let targetGain: Float = target.isMuted ? 0.0 : target.masterGain

        var sumSquares: Float = 0.0
        var peak: Float = 0.0
        var lowAccum: Float = 0.0
        var highAccum: Float = 0.0
        var previousOutL: Float = 0.0

        let r0 = 0.5, r1 = 0.75, r2 = 1.0, r3 = 1.125, r4 = 1.5

        // Head yaw/pitch offsets anchor the 3D virtual acoustic stage relative to listener head orientation
        let headYawDeg = asin(min(max(-target.spatialPanOffset, -1.0), 1.0)) * (180.0 / .pi)
        let headPitchDeg = asin(min(max(target.headElevationTilt, -1.0), 1.0)) * (180.0 / .pi) * 0.65
        let effectivePose = BinauralSourcePose(
            azimuthDeg: target.hrtfAzimuthDeg - headYawDeg,
            elevationDeg: target.hrtfElevationDeg - headPitchDeg,
            distanceMeters: target.hrtfDistanceMeters
        )
        let roomPreset = ShoeboxRoomPreset(rawValue: target.roomPresetIndex) ?? .obsidianStudio
        roomSimulator.updateParametersIfNeeded(
            preset: roomPreset,
            sourcePose: BinauralSourcePose(
                azimuthDeg: target.hrtfAzimuthDeg,
                elevationDeg: target.hrtfElevationDeg,
                distanceMeters: target.hrtfDistanceMeters
            ),
            headQuaternion: target.headQuaternion
        )

        // Exchange pre-allocated buffers out of self to mutate via UnsafePointers with zero CoW allocations
        var localMonoExcite = monoSpatialExcitation
        var localRoomSend = roomSendScratch
        var localHRTFL = hrtfLeftScratch
        var localHRTFR = hrtfRightScratch
        var localBinL = earLockedBinauralLeft
        var localBinR = earLockedBinauralRight
        monoSpatialExcitation = []
        roomSendScratch = []
        hrtfLeftScratch = []
        hrtfRightScratch = []
        earLockedBinauralLeft = []
        earLockedBinauralRight = []

        var offset = 0
        while offset < frameCount {
            let chunk = min(frameCount - offset, Self.spatialChunkCapacity)

            for i in 0..<chunk {
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

                let carrier = Double(smoothCarrierHz)
                let halfBeat = Double(smoothBeatHz) * 0.5
                let freqLeft = max(20.0, carrier - halfBeat)
                let freqRight = max(20.0, carrier + halfBeat)

                let binauralL = Float(sin(twoPi * phaseBinauralLeft))
                let binauralR = Float(sin(twoPi * phaseBinauralRight))
                advancePhase(&phaseBinauralLeft, delta: freqLeft * invSampleRate)
                advancePhase(&phaseBinauralRight, delta: freqRight * invSampleRate)
                advancePhase(&phaseSubFundamental, delta: (carrier * 0.5) * invSampleRate)

                let lfoA = Float(sin(twoPi * lfoPhasePrimary))
                let lfoB = Float(cos(twoPi * lfoPhaseSecondary))
                advancePhase(&lfoPhasePrimary, delta: 0.083 * invSampleRate)
                advancePhase(&lfoPhaseSecondary, delta: 0.137 * invSampleRate)

                var padMono: Float = 0.0
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
                    padMono = fastSoftClip((rawPadL + rawPadR) * 0.675) * 0.68

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

                var noiseMono: Float = 0.0
                if smoothPinkMix > 0.0005 {
                    let pair = nextPinkNoiseStereo()
                    noiseMono = 0.5 * (pair.0 + pair.1)
                }

                let maxSafeCutoff = Float(sampleRate * 0.44)
                let modulatedCutoff = min(
                    max(smoothCutoffHz * (1.0 + 0.08 * lfoA + 0.65 * smoothBloom), 60.0),
                    maxSafeCutoff
                )
                let g = tan(Float.pi * modulatedCutoff * Float(invSampleRate))
                let k = 2.0 - 2.0 * min(max(smoothResonance, 0.05), 0.94)
                let a1 = 1.0 / (1.0 + g * (g + k))
                let a2 = g * a1
                let a3 = g * a2

                // Filter ear-locked binaural tones in SVF R-channel & spatial pad/noise excitation in SVF L-channel
                let rawSpatialMono = padMono * smoothPadMix + noiseMono * smoothPinkMix
                let v3_1L = rawSpatialMono - svf1ic2L
                let v1_1L = a1 * svf1ic1L + a2 * v3_1L
                let v2_1L = svf1ic2L + a2 * svf1ic1L + a3 * v3_1L
                svf1ic1L = 2.0 * v1_1L - svf1ic1L
                svf1ic2L = 2.0 * v2_1L - svf1ic2L

                let v3_2L = v2_1L - svf2ic2L
                let v1_2L = a1 * svf2ic1L + a2 * v3_2L
                let v2_2L = svf2ic2L + a2 * svf2ic1L + a3 * v3_2L
                svf2ic1L = 2.0 * v1_2L - svf2ic1L
                svf2ic2L = 2.0 * v2_2L - svf2ic2L

                let cleanSpatial = v2_2L.isFinite ? v2_2L : 0.0
                localMonoExcite[i] = cleanSpatial
                localRoomSend[i] = cleanSpatial
                localBinL[i] = binauralL * smoothBinauralMix * smoothMasterGain
                localBinR[i] = binauralR * smoothBinauralMix * smoothMasterGain
                lowAccum += abs(cleanSpatial)
            }

            // 1. KEMAR 128-tap UPOLS Binaural Convolution
            localMonoExcite.withUnsafeBufferPointer { monoPtr in
                localHRTFL.withUnsafeMutableBufferPointer { lPtr in
                    localHRTFR.withUnsafeMutableBufferPointer { rPtr in
                        hrtfConvolver.processMonoToBinaural(
                            monoInput: monoPtr.baseAddress!,
                            leftOutput: lPtr.baseAddress!,
                            rightOutput: rPtr.baseAddress!,
                            frameCount: chunk,
                            pose: effectivePose
                        )
                    }
                }
            }

            // 2. Multi-Satellite Orbital Habit 3D Binaural Overtones
            localHRTFL.withUnsafeMutableBufferPointer { lPtr in
                localHRTFR.withUnsafeMutableBufferPointer { rPtr in
                    localRoomSend.withUnsafeMutableBufferPointer { sendPtr in
                        orbitalSpatializer.renderSatellites(
                            bank: target.orbitalSatellites,
                            carrierFrequencyHz: smoothCarrierHz,
                            padMix: smoothPadMix,
                            headYawRadians: headYawDeg * (.pi / 180.0),
                            headPitchRadians: headPitchDeg * (.pi / 180.0),
                            leftInOut: lPtr.baseAddress!,
                            rightInOut: rPtr.baseAddress!,
                            monoRoomSendInOut: sendPtr.baseAddress!,
                            frameCount: chunk
                        )
                    }
                }
            }

            // 3. 3D Shoebox Image-Source Early Reflections (18 Virtual Sources) + 8-Channel Hadamard FDN Reverb
            localRoomSend.withUnsafeBufferPointer { sendPtr in
                localHRTFL.withUnsafeMutableBufferPointer { lPtr in
                    localHRTFR.withUnsafeMutableBufferPointer { rPtr in
                        roomSimulator.processAndAccumulate(
                            monoSource: sendPtr.baseAddress!,
                            leftInOut: lPtr.baseAddress!,
                            rightInOut: rPtr.baseAddress!,
                            frameCount: chunk
                        )
                    }
                }
            }

            // 4. Master Sum (Ear-Locked Binaural Beat Entrainment + Spatialized Binaural Soundstage)
            for i in 0..<chunk {
                let rawL = localBinL[i] + localHRTFL[i] * smoothMasterGain
                let rawR = localBinR[i] + localHRTFR[i] * smoothMasterGain
                let finalL = fastSoftClip(rawL.isFinite ? rawL : 0.0)
                let finalR = fastSoftClip(rawR.isFinite ? rawR : 0.0)

                leftOutput[offset + i] = finalL
                rightOutput[offset + i] = finalR

                let mono = 0.5 * (finalL + finalR)
                sumSquares += mono * mono
                let absMax = max(abs(finalL), abs(finalR))
                if absMax > peak { peak = absMax }
                highAccum += abs(finalL - previousOutL)
                previousOutL = finalL
            }

            offset += chunk
        }

        monoSpatialExcitation = localMonoExcite
        roomSendScratch = localRoomSend
        hrtfLeftScratch = localHRTFL
        hrtfRightScratch = localHRTFR
        earLockedBinauralLeft = localBinL
        earLockedBinauralRight = localBinR

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
    public let neuralRingBuffer: NeuralAudioRingBuffer
    public let drirConvolverBridge: RayTracedDRIRConvolverBridge

    public init(
        sampleRate: Double,
        initialParameters: SynthParameters = SynthParameters(),
        neuralRingBuffer: NeuralAudioRingBuffer = NeuralAudioRingBuffer(),
        drirConvolverBridge: RayTracedDRIRConvolverBridge = RayTracedDRIRConvolverBridge()
    ) {
        self.sampleRate = sampleRate
        self.neuralRingBuffer = neuralRingBuffer
        self.drirConvolverBridge = drirConvolverBridge

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
                target: audioThreadCachedParameters,
                neuralRingBuffer: neuralRingBuffer,
                drirConvolverBridge: drirConvolverBridge
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
                    target: audioThreadCachedParameters,
                    neuralRingBuffer: neuralRingBuffer,
                    drirConvolverBridge: drirConvolverBridge
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
    public nonisolated let neuralRingBuffer = NeuralAudioRingBuffer()
    public nonisolated let drirConvolverBridge = RayTracedDRIRConvolverBridge()

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var bridge: RealtimeAudioBridge?
    private var currentParameters: SynthParameters = SynthParameters()
    private var isRunningEngine: Bool = false
    private var bloomDecayTask: Task<Void, Never>?

    public init() {}

    public nonisolated func pushRayTracedDRIR(leftTaps: [Float], rightTaps: [Float]) {
        drirConvolverBridge.pushStereoDRIR(leftTaps: leftTaps, rightTaps: rightTaps)
    }

    public func configureIfNeeded() throws {
        guard sourceNode == nil else { return }

        #if os(iOS) || os(visionOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        #if os(iOS)
        try session.setPreferredIOBufferDuration(0.0058)
        #endif
        try session.setActive(true)
        let hardwareRate = session.sampleRate > 0 ? session.sampleRate : 48_000.0
        #elseif os(macOS)
        let outputRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let hardwareRate = outputRate > 0 ? outputRate : 48_000.0
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

        let audioBridge = RealtimeAudioBridge(
            sampleRate: hardwareRate,
            initialParameters: currentParameters,
            neuralRingBuffer: neuralRingBuffer,
            drirConvolverBridge: drirConvolverBridge
        )
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
            #if os(iOS) || os(visionOS)
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

    public func updateHeadTrackingOffsets(
        spatialPan: Float,
        elevationTilt: Float,
        headQuaternion: SIMD4<Float>? = nil
    ) {
        currentParameters.spatialPanOffset = min(max(spatialPan, -1.0), 1.0)
        currentParameters.headElevationTilt = min(max(elevationTilt, -1.0), 1.0)
        if let headQuaternion {
            currentParameters.headQuaternion = headQuaternion
        }
        bridge?.writeParameters(currentParameters)
    }

    public func updateHRTFPose(
        azimuthDeg: Float,
        elevationDeg: Float,
        distanceMeters: Float,
        roomPresetIndex: Int? = nil,
        isSpatializerEnabled: Bool? = nil
    ) {
        currentParameters.hrtfAzimuthDeg = BinauralSourcePose.wrapAzimuthDegrees(azimuthDeg)
        currentParameters.hrtfElevationDeg = min(max(elevationDeg, -45.0), 90.0)
        currentParameters.hrtfDistanceMeters = min(max(distanceMeters, 0.15), 10.0)
        if let roomPresetIndex {
            currentParameters.roomPresetIndex = min(max(roomPresetIndex, 0), ShoeboxRoomPreset.allCases.count - 1)
        }
        if let isSpatializerEnabled {
            currentParameters.isHRTFSpatializerEnabled = isSpatializerEnabled
        }
        bridge?.writeParameters(currentParameters)
    }

    public func updateOrbitalSatellites(_ bank: OrbitalSatelliteBank) {
        currentParameters.orbitalSatellites = bank
        bridge?.writeParameters(currentParameters)
    }

    public func applyPreset(_ preset: AudioPresetDTO) {
        var next = SynthParameters(preset: preset)
        next.spatialPanOffset = currentParameters.spatialPanOffset
        next.headElevationTilt = currentParameters.headElevationTilt
        next.hrtfAzimuthDeg = currentParameters.hrtfAzimuthDeg
        next.hrtfElevationDeg = currentParameters.hrtfElevationDeg
        next.hrtfDistanceMeters = currentParameters.hrtfDistanceMeters
        next.roomPresetIndex = currentParameters.roomPresetIndex
        next.isHRTFSpatializerEnabled = currentParameters.isHRTFSpatializerEnabled
        next.headQuaternion = currentParameters.headQuaternion
        next.orbitalSatellites = currentParameters.orbitalSatellites
        next.neuralSoundscapeMix = currentParameters.neuralSoundscapeMix
        next.latentGuidanceScale = currentParameters.latentGuidanceScale
        next.latentTemperature = currentParameters.latentTemperature
        next.rayTracedAcousticsEnabled = currentParameters.rayTracedAcousticsEnabled
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

    #if os(macOS)
    public func routeOutputDevice(deviceID: AudioObjectID) throws {
        let wasRunning = engine.isRunning
        if wasRunning {
            engine.stop()
        }

        guard let audioUnit = engine.outputNode.audioUnit else {
            throw NSError(
                domain: "AetherAudioSynthEngine",
                code: -1002,
                userInfo: [NSLocalizedDescriptionKey: "AVAudioEngine outputNode AudioUnit is unavailable."]
            )
        }

        var mutableID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableID,
            UInt32(MemoryLayout<AudioObjectID>.size)
        )
        guard status == noErr else {
            throw NSError(
                domain: "AetherAudioSynthEngine",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "AudioUnitSetProperty(CurrentDevice) failed with OSStatus \(status)."]
            )
        }

        if let existingNode = sourceNode {
            engine.detach(existingNode)
            sourceNode = nil
            bridge = nil
        }

        try configureIfNeeded()
        bridge?.writeParameters(currentParameters)

        if wasRunning || isRunningEngine {
            try engine.start()
            isRunningEngine = true
        }
    }
    #endif

    public var isPlaying: Bool {
        isRunningEngine && engine.isRunning
    }
}
