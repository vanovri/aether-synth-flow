// MARK: - FILE: MPEPolyphonicVoiceAllocator.swift

import Foundation
import os
#if canImport(AudioToolbox) && !os(watchOS)
import AudioToolbox

// MARK: - Lock-Free UI Constellation Telemetry per Voice

public struct MPEVoiceConstellationPoint: Sendable, Equatable, Identifiable {
    public var id: Int { voiceIndex }
    public let voiceIndex: Int
    public let isActive: Bool
    public let midiChannel: UInt8
    public let midiNote: UInt8
    public let currentFrequencyHz: Float
    public let pitchBendSemitones: Float
    public let timbreSlideNormalized: Float // [-1.0 ... +1.0] from CC74
    public let pressureNormalized: Float    // [0.0 ... 1.0] from Channel Pressure (0xD0)
    public let envelopeAmplitude: Float     // [0.0 ... 1.0]

    public init(
        voiceIndex: Int,
        isActive: Bool = false,
        midiChannel: UInt8 = 1,
        midiNote: UInt8 = 60,
        currentFrequencyHz: Float = 261.63,
        pitchBendSemitones: Float = 0.0,
        timbreSlideNormalized: Float = 0.0,
        pressureNormalized: Float = 0.0,
        envelopeAmplitude: Float = 0.0
    ) {
        self.voiceIndex = voiceIndex
        self.isActive = isActive
        self.midiChannel = midiChannel
        self.midiNote = midiNote
        self.currentFrequencyHz = currentFrequencyHz
        self.pitchBendSemitones = pitchBendSemitones
        self.timbreSlideNormalized = timbreSlideNormalized
        self.pressureNormalized = pressureNormalized
        self.envelopeAmplitude = envelopeAmplitude
    }
}

// MARK: - Internal Raw-Pointer Voice & MPE Channel Structures (Value Bitwise Layout)

public enum MPEEnvelopeStage: UInt8, Sendable {
    case idle = 0
    case attack = 1
    case decay = 2
    case sustain = 3
    case releasing = 4
}

public struct MPEChannelExpressionState: Sendable {
    public var pitchBendNormalized: Float = 0.0   // [-1.0 ... +1.0] from 14-bit 0xE0
    public var channelPressure: Float = 0.0       // [0.0 ... 1.0] from 0xD0
    public var slideTimbreNormalized: Float = 0.0 // [-1.0 ... +1.0] from CC74 (centered at 64)
    public var sustainPedalDown: Bool = false     // CC64 >= 64

    public init() {}
}

public struct MPEVoiceSlot: Sendable {
    public var stage: MPEEnvelopeStage = .idle
    public var midiChannel: UInt8 = 1             // 0 = Master Ch 1, 1...15 = MPE Member Ch 2...16
    public var midiNote: UInt8 = 60
    public var velocityGain: Float = 0.0
    public var sustainHeldAfterNoteOff: Bool = false

    public var noteOnOrderStamp: UInt64 = 0
    public var releaseOrderStamp: UInt64 = 0

    // Double-precision phase accumulators for click-free FM + Binaural Detuned Sub-Oscillators
    public var carrierPhase: Double = 0.0
    public var modulatorPhase: Double = 0.0
    public var stereoSpreadPhaseRight: Double = 0.0
    public var subOctavePhase: Double = 0.0

    // Slewed per-voice continuous MPE expression parameters
    public var smoothFrequencyHz: Float = 261.62558
    public var targetPitchBendSemitones: Float = 0.0
    public var smoothPitchBendSemitones: Float = 0.0
    public var smoothPressure: Float = 0.0
    public var smoothTimbreSlide: Float = 0.0
    public var envelopeLevel: Float = 0.0

    // Per-voice 2-pole Cytomic TPT SVF state for independent MPE CC74 Timbre filtering
    public var svfIc1L: Float = 0.0
    public var svfIc2L: Float = 0.0
    public var svfIc1R: Float = 0.0
    public var svfIc2R: Float = 0.0

    // 2.5ms Raised-Cosine Voice-Steal Crossfade Ghost State
    public var stealCrossfadeIndex: Int32 = 0
    public var stealCrossfadeLength: Int32 = 0
    public var ghostCarrierPhase: Double = 0.0
    public var ghostModulatorPhase: Double = 0.0
    public var ghostFrequencyHz: Float = 261.62558
    public var ghostAmplitude: Float = 0.0
    public var ghostPanLeft: Float = 0.70710678
    public var ghostPanRight: Float = 0.70710678

    public init() {}
}

// MARK: - Allocation-Free 8-Voice MPE Polyphonic Voice Allocator & Synthesizer

/// Real-time 8-voice MIDI / MPE polyphonic voice manager operating exclusively on pre-allocated raw pointers.
/// Supports Master Channel (Ch 1) global controls, Member Channels (Ch 2–16) per-note ±48st Pitch Bend,
/// Channel Pressure (Aftertouch -> FM index & harmonic bloom), CC74 Slide/Timbre -> per-voice TPT SVF cutoff,
/// deterministic Oldest-Released / Quietest-Envelope voice stealing, and a 2.5ms raised-cosine steal crossfade.
public final class MPEPolyphonicVoiceBank: @unchecked Sendable {
    public static let maxVoices: Int = 8
    public static let midiChannelCount: Int = 16
    public static let defaultMemberPitchBendRangeSemitones: Float = 48.0
    public static let defaultMasterPitchBendRangeSemitones: Float = 2.0
    public static let stealCrossfadeDurationSeconds: Double = 0.0025 // 2.5 ms

    private let voicesPtr: UnsafeMutablePointer<MPEVoiceSlot>
    private let channelsPtr: UnsafeMutablePointer<MPEChannelExpressionState>
    private let telemetryPtr: UnsafeMutablePointer<MPEVoiceConstellationPoint>
    private let telemetryLock: UnsafeMutablePointer<os_unfair_lock_s>

    public private(set) var sampleRate: Double
    private var invSampleRate: Double
    private var stealCrossfadeSamples: Int32
    private var eventOrderCounter: UInt64 = 1
    public var memberPitchBendRangeSemitones: Float = defaultMemberPitchBendRangeSemitones
    public var masterPitchBendRangeSemitones: Float = defaultMasterPitchBendRangeSemitones

    // ADSR per-sample coefficients recomputed on sample-rate change
    private var attackStepPerSample: Float = 0.005
    private var decayCoeffPerSample: Float = 0.9995
    private var sustainTargetLevel: Float = 0.76
    private var releaseCoeffPerSample: Float = 0.9992
    private var mpeSlewCoeff: Float = 0.015

    public private(set) var totalStolenVoiceCount: UInt64 = 0
    public private(set) var lastStolenVoiceIndex: Int = 0
    public var totalVoiceStealCount: Int { Int(totalStolenVoiceCount) }

    public init(sampleRate: Double = 48_000.0) {
        let safeRate = max(8_000.0, sampleRate)
        self.sampleRate = safeRate
        self.invSampleRate = 1.0 / safeRate
        self.stealCrossfadeSamples = Int32(max(16, Int((Self.stealCrossfadeDurationSeconds * safeRate).rounded())))

        self.voicesPtr = UnsafeMutablePointer<MPEVoiceSlot>.allocate(capacity: Self.maxVoices)
        for v in 0..<Self.maxVoices {
            self.voicesPtr.advanced(by: v).initialize(to: MPEVoiceSlot())
        }

        self.channelsPtr = UnsafeMutablePointer<MPEChannelExpressionState>.allocate(capacity: Self.midiChannelCount)
        for ch in 0..<Self.midiChannelCount {
            self.channelsPtr.advanced(by: ch).initialize(to: MPEChannelExpressionState())
        }

        self.telemetryPtr = UnsafeMutablePointer<MPEVoiceConstellationPoint>.allocate(capacity: Self.maxVoices)
        for v in 0..<Self.maxVoices {
            self.telemetryPtr.advanced(by: v).initialize(to: MPEVoiceConstellationPoint(voiceIndex: v))
        }

        self.telemetryLock = UnsafeMutablePointer<os_unfair_lock_s>.allocate(capacity: 1)
        self.telemetryLock.initialize(to: os_unfair_lock_s())

        updateEnvelopeCoefficients(sampleRate: safeRate)
    }

    deinit {
        voicesPtr.deinitialize(count: Self.maxVoices)
        voicesPtr.deallocate()
        channelsPtr.deinitialize(count: Self.midiChannelCount)
        channelsPtr.deallocate()
        telemetryPtr.deinitialize(count: Self.maxVoices)
        telemetryPtr.deallocate()
        telemetryLock.deinitialize(count: 1)
        telemetryLock.deallocate()
    }

    public func reconfigure(sampleRate: Double) {
        let safeRate = max(8_000.0, sampleRate)
        self.sampleRate = safeRate
        self.invSampleRate = 1.0 / safeRate
        self.stealCrossfadeSamples = Int32(max(16, Int((Self.stealCrossfadeDurationSeconds * safeRate).rounded())))
        updateEnvelopeCoefficients(sampleRate: safeRate)
        resetAllVoices()
    }

    private func updateEnvelopeCoefficients(sampleRate: Double) {
        // Fast 3.5ms linear attack guarantees immediate phase-coherent sample onset without clicks
        self.attackStepPerSample = Float(1.0 / max(8.0, 0.0035 * sampleRate))
        // ~180ms decay toward sustain plateau, ~240ms musical release
        self.decayCoeffPerSample = Float(exp(-1.0 / max(16.0, 0.180 * sampleRate)))
        self.releaseCoeffPerSample = Float(exp(-1.0 / max(16.0, 0.240 * sampleRate)))
        // ~1.8ms expression slew eliminates 14-bit pitch-bend / 7-bit aftertouch zipper noise
        self.mpeSlewCoeff = Float(min(1.0, 1.0 / max(2.0, 0.0018 * sampleRate)))
    }

    @inline(__always)
    public func resetAllVoices() {
        for v in 0..<Self.maxVoices {
            voicesPtr[v] = MPEVoiceSlot()
        }
        for ch in 0..<Self.midiChannelCount {
            channelsPtr[ch] = MPEChannelExpressionState()
        }
        totalStolenVoiceCount = 0
        lastStolenVoiceIndex = 0
        eventOrderCounter = 1
    }

    @inline(__always)
    public func handleMIDIMessage(status: UInt8, data1: UInt8, data2: UInt8) {
        handleMIDIPacket(status: status, data1: data1, data2: data2)
    }

    @inline(__always)
    public func renderAndAccumulate(
        leftOutput: UnsafeMutablePointer<Float>,
        rightOutput: UnsafeMutablePointer<Float>,
        frameCount: Int,
        baseCutoffHz: Float,
        resonance: Float,
        masterGain: Float
    ) {
        let bank = RealtimeParameterBank()
        bank.setHostValue(baseCutoffHz, for: .filterCutoffHz)
        bank.setHostValue(resonance, for: .filterResonance)
        bank.setHostValue(masterGain, for: .masterGain)
        bank.resetRenderStateFromAtomics()
        renderSubBlock(
            leftOut: leftOutput,
            rightOut: rightOutput,
            frameCount: frameCount,
            parameterBank: bank,
            accumulate: true
        )
    }

    @inline(__always)
    public var activeVoiceCount: Int {
        var active = 0
        for v in 0..<Self.maxVoices {
            if voicesPtr[v].stage != .idle || voicesPtr[v].stealCrossfadeIndex < voicesPtr[v].stealCrossfadeLength {
                active += 1
            }
        }
        return active
    }

    // MARK: - Real-Time 3-Byte MIDI / MPE Event Dispatcher (Zero Allocations)

    @inline(__always)
    public func handleMIDIPacket(status: UInt8, data1: UInt8, data2: UInt8) {
        let command = status & 0xF0
        let channel = status & 0x0F // 0 = Master Ch 1, 1...15 = Member Ch 2...16

        switch command {
        case 0x80: // Note Off
            handleNoteOff(channel: channel, note: data1 & 0x7F)

        case 0x90: // Note On (velocity == 0 treated per MIDI 1.0 spec as Note Off)
            let vel = data2 & 0x7F
            if vel == 0 {
                handleNoteOff(channel: channel, note: data1 & 0x7F)
            } else {
                handleNoteOn(channel: channel, note: data1 & 0x7F, velocity: vel)
            }

        case 0xB0: // Control Change (CC74 Slide/Timbre, CC64 Sustain, CC120/123 All Notes Off)
            handleControlChange(channel: channel, controller: data1 & 0x7F, value: data2 & 0x7F)

        case 0xD0: // Channel Pressure (Aftertouch: data1 carries 0...127 pressure)
            let normPressure = Float(data1 & 0x7F) * (1.0 / 127.0)
            channelsPtr[Int(channel)].channelPressure = normPressure

        case 0xE0: // 14-bit Pitch Bend (LSB = data1, MSB = data2, center = 8192)
            let raw14 = Int(data1 & 0x7F) | (Int(data2 & 0x7F) << 7)
            let centered = Float(raw14 - 8192)
            let normalized = centered >= 0.0 ? (centered / 8191.0) : (centered / 8192.0)
            channelsPtr[Int(channel)].pitchBendNormalized = min(max(normalized, -1.0), 1.0)

        default:
            break
        }
    }

    @inline(__always)
    public func handleNoteOn(channel: UInt8, note: UInt8, velocity: UInt8) {
        let chIdx = Int(channel & 0x0F)
        let targetSlotIndex = selectVoiceSlotForAllocation(channel: channel, note: note)
        var slot = voicesPtr[targetSlotIndex]

        // Capture outgoing voice into 2.5ms raised-cosine crossfade ghost if slot was sounding
        if slot.stage != .idle && slot.envelopeLevel > 1.0e-5 {
            slot.ghostCarrierPhase = slot.carrierPhase
            slot.ghostModulatorPhase = slot.modulatorPhase
            slot.ghostFrequencyHz = slot.smoothFrequencyHz
            slot.ghostAmplitude = slot.envelopeLevel * slot.velocityGain
            let ghostNotePan = min(max((Float(Int(slot.midiNote) - 60) / 36.0) * 0.45, -0.65), 0.65)
            let ghostAngle = (Float.pi * 0.25) * (1.0 + ghostNotePan)
            slot.ghostPanLeft = cos(ghostAngle)
            slot.ghostPanRight = sin(ghostAngle)
            slot.stealCrossfadeIndex = 0
            slot.stealCrossfadeLength = stealCrossfadeSamples
            totalStolenVoiceCount &+= 1
            lastStolenVoiceIndex = targetSlotIndex
        } else {
            slot.stealCrossfadeIndex = 0
            slot.stealCrossfadeLength = 0
            slot.svfIc1L = 0.0; slot.svfIc2L = 0.0
            slot.svfIc1R = 0.0; slot.svfIc2R = 0.0
        }

        eventOrderCounter &+= 1
        slot.stage = .attack
        slot.midiChannel = channel & 0x0F
        slot.midiNote = note
        slot.sustainHeldAfterNoteOff = false
        slot.noteOnOrderStamp = eventOrderCounter
        slot.releaseOrderStamp = 0

        // Perceptually curved velocity gain in [0.12 ... 1.0]
        let normVel = Float(max(1, min(127, Int(velocity)))) / 127.0
        slot.velocityGain = 0.12 + 0.88 * sqrt(normVel)

        // Phase-coherent zero-crossing start on exact Note-On frame
        slot.carrierPhase = 0.0
        slot.modulatorPhase = 0.0
        slot.stereoSpreadPhaseRight = 0.08
        slot.subOctavePhase = 0.0
        slot.envelopeLevel = 0.0

        // Inherit pre-note MPE Member Channel + Master Channel expression states immediately
        let masterExpr = channelsPtr[0]
        let memberExpr = channelsPtr[chIdx]
        let initialSemitoneBend: Float
        if chIdx == 0 {
            initialSemitoneBend = masterExpr.pitchBendNormalized * masterPitchBendRangeSemitones
        } else {
            initialSemitoneBend = masterExpr.pitchBendNormalized * masterPitchBendRangeSemitones
                + memberExpr.pitchBendNormalized * memberPitchBendRangeSemitones
        }

        slot.targetPitchBendSemitones = initialSemitoneBend
        slot.smoothPitchBendSemitones = initialSemitoneBend
        slot.smoothPressure = chIdx == 0 ? masterExpr.channelPressure : max(masterExpr.channelPressure, memberExpr.channelPressure)
        slot.smoothTimbreSlide = chIdx == 0 ? masterExpr.slideTimbreNormalized : (masterExpr.slideTimbreNormalized + memberExpr.slideTimbreNormalized)
        slot.smoothFrequencyHz = Self.midiNoteToHz(note: Float(note) + initialSemitoneBend)

        voicesPtr[targetSlotIndex] = slot
    }

    @inline(__always)
    public func handleNoteOff(channel: UInt8, note: UInt8) {
        let ch = channel & 0x0F
        let pedalHeld = channelsPtr[0].sustainPedalDown || channelsPtr[Int(ch)].sustainPedalDown

        for v in 0..<Self.maxVoices {
            let slot = voicesPtr[v]
            if slot.stage != .idle && slot.stage != .releasing && slot.midiNote == note {
                // Match exact MPE member channel, or allow Master Ch 0 global release
                if slot.midiChannel == ch || ch == 0 {
                    if pedalHeld {
                        voicesPtr[v].sustainHeldAfterNoteOff = true
                    } else {
                        eventOrderCounter &+= 1
                        voicesPtr[v].stage = .releasing
                        voicesPtr[v].releaseOrderStamp = eventOrderCounter
                    }
                    if ch != 0 { return }
                }
            }
        }
    }

    @inline(__always)
    private func handleControlChange(channel: UInt8, controller: UInt8, value: UInt8) {
        let chIdx = Int(channel & 0x0F)
        switch controller {
        case 74: // MPE Y-Axis Slide / Timbre (0..127 -> -1.0..+1.0, neutral at 64)
            let centered = Float(Int(value) - 64)
            let norm = centered >= 0.0 ? (centered / 63.0) : (centered / 64.0)
            channelsPtr[chIdx].slideTimbreNormalized = min(max(norm, -1.0), 1.0)

        case 64: // Sustain Pedal
            let down = value >= 64
            channelsPtr[chIdx].sustainPedalDown = down
            if !down {
                for v in 0..<Self.maxVoices {
                    if voicesPtr[v].sustainHeldAfterNoteOff &&
                        (chIdx == 0 || Int(voicesPtr[v].midiChannel) == chIdx) {
                        eventOrderCounter &+= 1
                        voicesPtr[v].sustainHeldAfterNoteOff = false
                        voicesPtr[v].stage = .releasing
                        voicesPtr[v].releaseOrderStamp = eventOrderCounter
                    }
                }
            }

        case 120: // All Sound Off (hard panic reset with crossfade protection)
            for v in 0..<Self.maxVoices {
                if chIdx == 0 || Int(voicesPtr[v].midiChannel) == chIdx {
                    voicesPtr[v].stage = .idle
                    voicesPtr[v].envelopeLevel = 0.0
                    voicesPtr[v].stealCrossfadeIndex = 0
                    voicesPtr[v].stealCrossfadeLength = 0
                }
            }

        case 123: // All Notes Off (enter smooth release on active voices)
            for v in 0..<Self.maxVoices {
                if voicesPtr[v].stage != .idle && voicesPtr[v].stage != .releasing &&
                    (chIdx == 0 || Int(voicesPtr[v].midiChannel) == chIdx) {
                    eventOrderCounter &+= 1
                    voicesPtr[v].sustainHeldAfterNoteOff = false
                    voicesPtr[v].stage = .releasing
                    voicesPtr[v].releaseOrderStamp = eventOrderCounter
                }
            }

        default:
            break
        }
    }

    /// Deterministic Voice Allocation Policy:
    /// 1. Same MPE Member Channel + same MIDI note retrigger
    /// 2. First completely `.idle` voice slot
    /// 3. Oldest-Released voice (`.releasing` with smallest `releaseOrderStamp`, tie-broken by quietest envelope)
    /// 4. Quietest-Envelope active voice (smallest `envelopeLevel`, tie-broken by oldest `noteOnOrderStamp`)
    @inline(__always)
    private func selectVoiceSlotForAllocation(channel: UInt8, note: UInt8) -> Int {
        let ch = channel & 0x0F

        // 1. Retrigger check on identical channel & note
        if ch > 0 {
            for v in 0..<Self.maxVoices {
                let s = voicesPtr[v]
                if s.stage != .idle && s.midiChannel == ch && s.midiNote == note {
                    return v
                }
            }
        }

        // 2. Completely idle slot (no active envelope and no active steal crossfade)
        for v in 0..<Self.maxVoices {
            let s = voicesPtr[v]
            if s.stage == .idle && s.stealCrossfadeIndex >= s.stealCrossfadeLength {
                return v
            }
        }

        // 3. Oldest-Released voice stealing
        var oldestReleasedIndex = -1
        var oldestReleaseStamp = UInt64.max
        var oldestReleaseEnv = Float.greatestFiniteMagnitude

        for v in 0..<Self.maxVoices {
            let s = voicesPtr[v]
            if s.stage == .releasing {
                if s.releaseOrderStamp < oldestReleaseStamp ||
                    (s.releaseOrderStamp == oldestReleaseStamp && s.envelopeLevel < oldestReleaseEnv) {
                    oldestReleaseStamp = s.releaseOrderStamp
                    oldestReleaseEnv = s.envelopeLevel
                    oldestReleasedIndex = v
                }
            }
        }
        if oldestReleasedIndex >= 0 {
            return oldestReleasedIndex
        }

        // 4. Quietest-Envelope active voice stealing
        var quietestIndex = 0
        var quietestLevel = Float.greatestFiniteMagnitude
        var quietestNoteStamp = UInt64.max

        for v in 0..<Self.maxVoices {
            let s = voicesPtr[v]
            let effectiveLevel = s.envelopeLevel * s.velocityGain
            if effectiveLevel < quietestLevel - 1.0e-6 ||
                (abs(effectiveLevel - quietestLevel) <= 1.0e-6 && s.noteOnOrderStamp < quietestNoteStamp) {
                quietestLevel = effectiveLevel
                quietestNoteStamp = s.noteOnOrderStamp
                quietestIndex = v
            }
        }
        return quietestIndex
    }

    @inline(__always)
    public static func midiNoteToHz(note: Float) -> Float {
        let clamped = min(max(note, 0.0), 136.0)
        return 440.0 * powf(2.0, (clamped - 69.0) * (1.0 / 12.0))
    }

    @inline(__always)
    private static func advanceNormalizedPhase(_ phase: inout Double, delta: Double) {
        phase += delta
        if phase >= 1.0 || phase < 0.0 {
            phase -= floor(phase)
        }
    }

    // MARK: - Real-Time Sub-Block Polyphonic Rendering (Zero Heap Allocations)

    /// Renders `frameCount` stereo frames of MPE 8-voice FM + Binaural Detuned Sub synthesis
    /// accumulatively (`accumulate == true`) or overwriting (`accumulate == false`) into `leftOut` / `rightOut`.
    @inline(__always)
    public func renderSubBlock(
        leftOut: UnsafeMutablePointer<Float>,
        rightOut: UnsafeMutablePointer<Float>,
        frameCount: Int,
        parameterBank: RealtimeParameterBank,
        accumulate: Bool
    ) {
        guard frameCount > 0 else { return }

        if !accumulate {
            for i in 0..<frameCount {
                leftOut[i] = 0.0
                rightOut[i] = 0.0
            }
        }

        let twoPi = Double.pi * 2.0
        let maxSafeCutoff = Float(sampleRate * 0.44)
        let hasRamps = parameterBank.hasActiveRamps
        let masterExpr = channelsPtr[0]
        let masterBendSemi = masterExpr.pitchBendNormalized * masterPitchBendRangeSemitones

        for frame in 0..<frameCount {
            if hasRamps {
                parameterBank.stepActiveRampsOneSample()
            }

            let baseBeatHz = Double(parameterBank.renderValue(.binauralBeatHz))
            let binauralBlend = parameterBank.renderValue(.binauralMix)
            let padBlend = parameterBank.renderValue(.padMix)
            let detuneCents = parameterBank.renderValue(.padDetuneCents)
            let baseCutoff = parameterBank.renderValue(.filterCutoffHz)
            let baseResonance = parameterBank.renderValue(.filterResonance)
            let baseFMIndex = parameterBank.renderValue(.fmModulationIndex)
            let neuralMix = parameterBank.renderValue(.neuralSoundscapeMix)
            let masterGain = parameterBank.renderValue(.masterGain)

            let detuneRatio = Double(powf(2.0, detuneCents / 1200.0))
            let svfK = 2.0 - 2.0 * min(max(baseResonance, 0.05), 0.94)

            var mixL: Float = 0.0
            var mixR: Float = 0.0

            for v in 0..<Self.maxVoices {
                var slot = voicesPtr[v]
                let hasGhost = slot.stealCrossfadeIndex < slot.stealCrossfadeLength
                if slot.stage == .idle && !hasGhost {
                    continue
                }

                // 1. Advance ADSR Envelope
                var voiceOutL: Float = 0.0
                var voiceOutR: Float = 0.0

                if slot.stage != .idle {
                    switch slot.stage {
                    case .attack:
                        slot.envelopeLevel += attackStepPerSample
                        if slot.envelopeLevel >= 1.0 {
                            slot.envelopeLevel = 1.0
                            slot.stage = .decay
                        }
                    case .decay:
                        slot.envelopeLevel = sustainTargetLevel + (slot.envelopeLevel - sustainTargetLevel) * decayCoeffPerSample
                        if abs(slot.envelopeLevel - sustainTargetLevel) < 0.0008 {
                            slot.envelopeLevel = sustainTargetLevel
                            slot.stage = .sustain
                        }
                    case .sustain:
                        slot.envelopeLevel = sustainTargetLevel
                    case .releasing:
                        slot.envelopeLevel *= releaseCoeffPerSample
                        if slot.envelopeLevel < 1.0e-5 {
                            slot.envelopeLevel = 0.0
                            slot.stage = .idle
                        }
                    case .idle:
                        break
                    }

                    // 2. Smooth MPE Member + Master Channel Pitch Bend, Aftertouch, and CC74 Timbre
                    let chIdx = Int(slot.midiChannel & 0x0F)
                    let chExpr = channelsPtr[chIdx]
                    let targetBend = chIdx == 0
                        ? masterBendSemi
                        : (masterBendSemi + chExpr.pitchBendNormalized * memberPitchBendRangeSemitones)
                    let targetPressure = chIdx == 0
                        ? masterExpr.channelPressure
                        : max(masterExpr.channelPressure, chExpr.channelPressure)
                    let targetSlide = chIdx == 0
                        ? masterExpr.slideTimbreNormalized
                        : min(max(masterExpr.slideTimbreNormalized + chExpr.slideTimbreNormalized, -1.0), 1.0)

                    slot.targetPitchBendSemitones = targetBend
                    slot.smoothPitchBendSemitones += mpeSlewCoeff * (targetBend - slot.smoothPitchBendSemitones)
                    slot.smoothPressure += mpeSlewCoeff * (targetPressure - slot.smoothPressure)
                    slot.smoothTimbreSlide += mpeSlewCoeff * (targetSlide - slot.smoothTimbreSlide)

                    let voiceFreq = Self.midiNoteToHz(note: Float(slot.midiNote) + slot.smoothPitchBendSemitones)
                    slot.smoothFrequencyHz = voiceFreq
                    let freqD = Double(voiceFreq)

                    // 3. Advance phase BEFORE sin() so frame 0 of Note-On produces immediate smooth non-zero onset
                    let halfBeat = baseBeatHz * 0.5 * Double(binauralBlend)
                    let freqLeft = max(20.0, freqD - halfBeat)
                    let freqRight = max(20.0, (freqD + halfBeat) * detuneRatio)

                    Self.advanceNormalizedPhase(&slot.modulatorPhase, delta: (freqD * 2.0) * invSampleRate)
                    Self.advanceNormalizedPhase(&slot.carrierPhase, delta: freqLeft * invSampleRate)
                    Self.advanceNormalizedPhase(&slot.stereoSpreadPhaseRight, delta: freqRight * invSampleRate)
                    Self.advanceNormalizedPhase(&slot.subOctavePhase, delta: (freqD * 0.5) * invSampleRate)

                    // Aftertouch drives continuous FM index & harmonic bloom
                    let effectiveBeta = Double(baseFMIndex + slot.smoothPressure * 3.4 + neuralMix * 0.85)
                    let modSignal = sin(twoPi * slot.modulatorPhase) * effectiveBeta
                    let fmLeft = Float(sin(twoPi * slot.carrierPhase + modSignal))
                    let fmRight = Float(sin(twoPi * slot.stereoSpreadPhaseRight + modSignal * 0.96))
                    let subWarmth = Float(sin(twoPi * slot.subOctavePhase)) * (0.24 + 0.30 * padBlend + 0.25 * slot.smoothPressure)

                    let notePan = min(max((Float(Int(slot.midiNote) - 60) / 36.0) * 0.45, -0.65), 0.65)
                    let panAngle = (Float.pi * 0.25) * (1.0 + notePan)
                    let panL = cos(panAngle) * 1.15
                    let panR = sin(panAngle) * 1.15

                    let amp = slot.envelopeLevel * slot.velocityGain * (1.0 + 0.28 * slot.smoothPressure)
                    let rawL = (fmLeft * 0.68 + subWarmth) * amp * panL
                    let rawR = (fmRight * 0.68 + subWarmth) * amp * panR

                    // 4. Per-Voice CC74 Timbre Cytomic 2-Pole TPT SVF Low-Pass Filter
                    let slideOctaves = slot.smoothTimbreSlide * 2.2 + slot.smoothPressure * 0.85
                    let voiceCutoff = min(max(baseCutoff * powf(2.0, slideOctaves), 60.0), maxSafeCutoff)
                    let g = tanf(Float.pi * voiceCutoff * Float(invSampleRate))
                    let a1 = 1.0 / (1.0 + g * (g + svfK))
                    let a2 = g * a1
                    let a3 = g * a2

                    let v3L = rawL - slot.svfIc2L
                    let v1L = a1 * slot.svfIc1L + a2 * v3L
                    let v2L = slot.svfIc2L + a2 * slot.svfIc1L + a3 * v3L
                    slot.svfIc1L = 2.0 * v1L - slot.svfIc1L
                    slot.svfIc2L = 2.0 * v2L - slot.svfIc2L

                    let v3R = rawR - slot.svfIc2R
                    let v1R = a1 * slot.svfIc1R + a2 * v3R
                    let v2R = slot.svfIc2R + a2 * slot.svfIc1R + a3 * v3R
                    slot.svfIc1R = 2.0 * v1R - slot.svfIc1R
                    slot.svfIc2R = 2.0 * v2R - slot.svfIc2R

                    voiceOutL = v2L.isFinite ? v2L : 0.0
                    voiceOutR = v2R.isFinite ? v2R : 0.0
                }

                // 5. 2.5ms Raised-Cosine Voice-Steal Crossfade Blending
                if hasGhost {
                    let phaseRatio = Float(slot.stealCrossfadeIndex) / Float(max(1, slot.stealCrossfadeLength))
                    let wOut = 0.5 * (1.0 + cosf(Float.pi * phaseRatio))
                    let wIn = 1.0 - wOut

                    let ghostFreqD = Double(slot.ghostFrequencyHz)
                    Self.advanceNormalizedPhase(&slot.ghostModulatorPhase, delta: (ghostFreqD * 2.0) * invSampleRate)
                    Self.advanceNormalizedPhase(&slot.ghostCarrierPhase, delta: ghostFreqD * invSampleRate)
                    let ghostOsc = Float(sin(twoPi * slot.ghostCarrierPhase + sin(twoPi * slot.ghostModulatorPhase) * Double(baseFMIndex)))
                    let ghostSample = ghostOsc * slot.ghostAmplitude * 0.68

                    voiceOutL = voiceOutL * wIn + ghostSample * slot.ghostPanLeft * wOut
                    voiceOutR = voiceOutR * wIn + ghostSample * slot.ghostPanRight * wOut
                    slot.stealCrossfadeIndex += 1
                }

                voicesPtr[v] = slot
                mixL += voiceOutL
                mixR += voiceOutR
            }

            // Polyphonic headroom scaling + smooth rational soft-clipper
            let scaledL = mixL * masterGain * 0.55
            let scaledR = mixR * masterGain * 0.55
            leftOut[frame] += Self.softClip(scaledL)
            rightOut[frame] += Self.softClip(scaledR)
        }

        // Non-blocking trylock telemetry snapshot for 60fps UI Constellation Radar
        if os_unfair_lock_trylock(telemetryLock) {
            for v in 0..<Self.maxVoices {
                let s = voicesPtr[v]
                telemetryPtr[v] = MPEVoiceConstellationPoint(
                    voiceIndex: v,
                    isActive: s.stage != .idle && s.envelopeLevel > 0.001,
                    midiChannel: s.midiChannel + 1,
                    midiNote: s.midiNote,
                    currentFrequencyHz: s.smoothFrequencyHz,
                    pitchBendSemitones: s.smoothPitchBendSemitones,
                    timbreSlideNormalized: s.smoothTimbreSlide,
                    pressureNormalized: s.smoothPressure,
                    envelopeAmplitude: s.envelopeLevel * s.velocityGain
                )
            }
            os_unfair_lock_unlock(telemetryLock)
        }
    }

    @inline(__always)
    private static func softClip(_ x: Float) -> Float {
        guard x.isFinite else { return 0.0 }
        let clamped = min(max(x, -3.0), 3.0)
        let x2 = clamped * clamped
        return clamped * (27.0 + x2) / (27.0 + 9.0 * x2)
    }

    /// Thread-safe UI read of the 8-voice MPE Pitch/Timbre/Pressure constellation state.
    public func snapshotVoiceConstellation() -> [MPEVoiceConstellationPoint] {
        var points = [MPEVoiceConstellationPoint]()
        points.reserveCapacity(Self.maxVoices)
        os_unfair_lock_lock(telemetryLock)
        for v in 0..<Self.maxVoices {
            points.append(telemetryPtr[v])
        }
        os_unfair_lock_unlock(telemetryLock)
        return points
    }
}
#endif
