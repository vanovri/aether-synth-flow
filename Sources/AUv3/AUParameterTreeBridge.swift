// MARK: - FILE: AUParameterTreeBridge.swift

#if canImport(AudioToolbox) && !os(watchOS)
import Foundation
import AudioToolbox
import Synchronization

// MARK: - 1. 16-Parameter Automatable Address Enumeration (Track 28.1)

/// Complete 16-parameter address map for the AetherSynthFlow AUv3 Instrument & Effect plug-in.
public enum AetherAUParameterAddress: AUParameterAddress, CaseIterable, Sendable {
    case carrierFrequencyHz   = 0
    case binauralBeatHz       = 1
    case binauralMix          = 2
    case pinkNoiseMix         = 3
    case padMix               = 4
    case filterCutoffHz       = 5
    case filterResonance      = 6
    case padDetuneCents       = 7
    case reverbWetMix         = 8
    case reverbDecaySeconds   = 9
    case fmModulationIndex    = 10
    case hrtfAzimuthDeg       = 11
    case hrtfElevationDeg     = 12
    case hrtfDistanceMeters   = 13
    case neuralSoundscapeMix  = 14
    case masterGain           = 15

    public static let count: Int = 16

    public var identifier: String {
        switch self {
        case .carrierFrequencyHz:  return "carrierFrequencyHz"
        case .binauralBeatHz:      return "binauralBeatHz"
        case .binauralMix:         return "binauralMix"
        case .pinkNoiseMix:        return "pinkNoiseMix"
        case .padMix:              return "padMix"
        case .filterCutoffHz:      return "filterCutoffHz"
        case .filterResonance:     return "filterResonance"
        case .padDetuneCents:      return "padDetuneCents"
        case .reverbWetMix:        return "reverbWetMix"
        case .reverbDecaySeconds:  return "reverbDecaySeconds"
        case .fmModulationIndex:   return "fmModulationIndex"
        case .hrtfAzimuthDeg:      return "hrtfAzimuthDeg"
        case .hrtfElevationDeg:    return "hrtfElevationDeg"
        case .hrtfDistanceMeters:  return "hrtfDistanceMeters"
        case .neuralSoundscapeMix: return "neuralSoundscapeMix"
        case .masterGain:          return "masterGain"
        }
    }

    public var displayName: String {
        switch self {
        case .carrierFrequencyHz:  return "Carrier Frequency"
        case .binauralBeatHz:      return "Binaural Beat"
        case .binauralMix:         return "Binaural Mix"
        case .pinkNoiseMix:        return "Pink Noise Mix"
        case .padMix:              return "Harmonic Pad Mix"
        case .filterCutoffHz:      return "SVF Cutoff"
        case .filterResonance:     return "SVF Resonance"
        case .padDetuneCents:      return "Pad Detune"
        case .reverbWetMix:        return "FDN Reverb Mix"
        case .reverbDecaySeconds:  return "Reverb Decay RT60"
        case .fmModulationIndex:   return "TZFM Index"
        case .hrtfAzimuthDeg:      return "HRTF Azimuth"
        case .hrtfElevationDeg:    return "HRTF Elevation"
        case .hrtfDistanceMeters:  return "HRTF Distance"
        case .neuralSoundscapeMix: return "Neural Texture Mix"
        case .masterGain:          return "Master Gain"
        }
    }

    public var parameterUnit: AudioUnitParameterUnit {
        switch self {
        case .carrierFrequencyHz, .binauralBeatHz, .filterCutoffHz:
            return .hertz
        case .binauralMix, .pinkNoiseMix, .padMix, .filterResonance,
             .reverbWetMix, .fmModulationIndex, .neuralSoundscapeMix, .masterGain:
            return .percent
        case .padDetuneCents:
            return .cents
        case .reverbDecaySeconds:
            return .seconds
        case .hrtfAzimuthDeg, .hrtfElevationDeg:
            return .degrees
        case .hrtfDistanceMeters:
            return .meters
        }
    }

    public var valueRange: ClosedRange<AUValue> {
        switch self {
        case .carrierFrequencyHz:  return 40.0...900.0
        case .binauralBeatHz:      return 0.5...45.0
        case .binauralMix:         return 0.0...1.0
        case .pinkNoiseMix:        return 0.0...1.0
        case .padMix:              return 0.0...1.0
        case .filterCutoffHz:      return 80.0...16000.0
        case .filterResonance:     return 0.05...0.95
        case .padDetuneCents:      return 0.0...50.0
        case .reverbWetMix:        return 0.0...1.0
        case .reverbDecaySeconds:  return 0.2...12.0
        case .fmModulationIndex:   return 0.0...1.0
        case .hrtfAzimuthDeg:      return -180.0...180.0
        case .hrtfElevationDeg:    return -45.0...90.0
        case .hrtfDistanceMeters:  return 0.25...8.0
        case .neuralSoundscapeMix: return 0.0...1.0
        case .masterGain:          return 0.0...1.0
        }
    }

    public var defaultValue: AUValue {
        switch self {
        case .carrierFrequencyHz:  return 216.0
        case .binauralBeatHz:      return 10.0
        case .binauralMix:         return 0.42
        case .pinkNoiseMix:        return 0.14
        case .padMix:              return 0.54
        case .filterCutoffHz:      return 2100.0
        case .filterResonance:     return 0.24
        case .padDetuneCents:      return 11.5
        case .reverbWetMix:        return 0.34
        case .reverbDecaySeconds:  return 3.4
        case .fmModulationIndex:   return 0.22
        case .hrtfAzimuthDeg:      return 0.0
        case .hrtfElevationDeg:    return 8.0
        case .hrtfDistanceMeters:  return 1.35
        case .neuralSoundscapeMix: return 0.25
        case .masterGain:          return 0.72
        }
    }

    public var flags: AudioUnitParameterOptions {
        var opts: AudioUnitParameterOptions = [
            .flag_IsReadable,
            .flag_IsWritable,
            .flag_CanRamp
        ]
        if self == .carrierFrequencyHz || self == .filterCutoffHz {
            opts.insert(.flag_DisplayLogarithmic)
        }
        if self == .masterGain {
            opts.insert(.flag_IsHighResolution)
        }
        return opts
    }

    @inline(__always)
    public func clamp(_ raw: AUValue) -> AUValue {
        guard raw.isFinite else { return defaultValue }
        let bounds = valueRange
        return min(max(raw, bounds.lowerBound), bounds.upperBound)
    }

    public func formatValue(_ raw: AUValue) -> String {
        let v = clamp(raw)
        switch self {
        case .carrierFrequencyHz, .filterCutoffHz:
            return String(format: "%.1f Hz", v)
        case .binauralBeatHz:
            return String(format: "%.2f Hz", v)
        case .binauralMix, .pinkNoiseMix, .padMix, .filterResonance,
             .reverbWetMix, .fmModulationIndex, .neuralSoundscapeMix, .masterGain:
            return String(format: "%.0f %%", v * 100.0)
        case .padDetuneCents:
            return String(format: "%.1f ct", v)
        case .reverbDecaySeconds:
            return String(format: "%.2f s", v)
        case .hrtfAzimuthDeg, .hrtfElevationDeg:
            return String(format: "%+.1f deg", v)
        case .hrtfDistanceMeters:
            return String(format: "%.2f m", v)
        }
    }

    public func parseString(_ string: String) -> AUValue {
        let trimmed = string
            .replacingOccurrences(of: "Hz", with: "")
            .replacingOccurrences(of: "%", with: "")
            .replacingOccurrences(of: "ct", with: "")
            .replacingOccurrences(of: "deg", with: "")
            .replacingOccurrences(of: "s", with: "")
            .replacingOccurrences(of: "m", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Float(trimmed) else { return defaultValue }
        if parameterUnit == .percent && parsed > 1.0001 {
            return clamp(parsed * 0.01)
        }
        return clamp(parsed)
    }
}

// MARK: - 2. Lock-Free Atomic & Raw-Pointer Parameter Bank

/// Lock-free parameter bank shared between the `AUParameterTree` host observer/implementor blocks
/// and the real-time C-style `AUInternalRenderBlock`.
///
/// Real-Time Audio Thread Law:
/// - Zero heap allocations, zero locks, and zero Objective-C dispatch inside `internalRenderBlock`.
/// - Host parameter tree reads/writes operate on 16 lock-free `Synchronization.Atomic<UInt32>` slots
///   (storing IEEE-754 `Float.bitPattern`).
/// - Sample-accurate parameter ramps (`AURenderEventParameter` / `AURenderEventParameterRamp`) operate on
///   pre-allocated contiguous `UnsafeMutablePointer<Float>` render arrays owned exclusively by the render thread.
public final class RealtimeParameterBank: @unchecked Sendable {
    public static let slotCount: Int = AetherAUParameterAddress.count

    // 16 explicit lock-free atomic UInt32 bit-pattern slots for host <-> audio synchronization
    private let slot0  = Atomic<UInt32>(AetherAUParameterAddress.carrierFrequencyHz.defaultValue.bitPattern)
    private let slot1  = Atomic<UInt32>(AetherAUParameterAddress.binauralBeatHz.defaultValue.bitPattern)
    private let slot2  = Atomic<UInt32>(AetherAUParameterAddress.binauralMix.defaultValue.bitPattern)
    private let slot3  = Atomic<UInt32>(AetherAUParameterAddress.pinkNoiseMix.defaultValue.bitPattern)
    private let slot4  = Atomic<UInt32>(AetherAUParameterAddress.padMix.defaultValue.bitPattern)
    private let slot5  = Atomic<UInt32>(AetherAUParameterAddress.filterCutoffHz.defaultValue.bitPattern)
    private let slot6  = Atomic<UInt32>(AetherAUParameterAddress.filterResonance.defaultValue.bitPattern)
    private let slot7  = Atomic<UInt32>(AetherAUParameterAddress.padDetuneCents.defaultValue.bitPattern)
    private let slot8  = Atomic<UInt32>(AetherAUParameterAddress.reverbWetMix.defaultValue.bitPattern)
    private let slot9  = Atomic<UInt32>(AetherAUParameterAddress.reverbDecaySeconds.defaultValue.bitPattern)
    private let slot10 = Atomic<UInt32>(AetherAUParameterAddress.fmModulationIndex.defaultValue.bitPattern)
    private let slot11 = Atomic<UInt32>(AetherAUParameterAddress.hrtfAzimuthDeg.defaultValue.bitPattern)
    private let slot12 = Atomic<UInt32>(AetherAUParameterAddress.hrtfElevationDeg.defaultValue.bitPattern)
    private let slot13 = Atomic<UInt32>(AetherAUParameterAddress.hrtfDistanceMeters.defaultValue.bitPattern)
    private let slot14 = Atomic<UInt32>(AetherAUParameterAddress.neuralSoundscapeMix.defaultValue.bitPattern)
    private let slot15 = Atomic<UInt32>(AetherAUParameterAddress.masterGain.defaultValue.bitPattern)

    private let hostDirtyMask = Atomic<UInt32>(0)

    /// Pre-allocated raw pointers used exclusively inside `AUInternalRenderBlock` for sample-accurate ramping.
    public let renderCurrentValues: UnsafeMutablePointer<Float>
    public let renderTargetValues: UnsafeMutablePointer<Float>
    public let renderStepPerSample: UnsafeMutablePointer<Float>
    public let renderRemainingFrames: UnsafeMutablePointer<UInt32>

    public init() {
        renderCurrentValues = .allocate(capacity: Self.slotCount)
        renderTargetValues = .allocate(capacity: Self.slotCount)
        renderStepPerSample = .allocate(capacity: Self.slotCount)
        renderRemainingFrames = .allocate(capacity: Self.slotCount)

        for addr in AetherAUParameterAddress.allCases {
            let idx = Int(addr.rawValue)
            let def = addr.defaultValue
            renderCurrentValues[idx] = def
            renderTargetValues[idx] = def
            renderStepPerSample[idx] = 0.0
            renderRemainingFrames[idx] = 0
        }
    }

    deinit {
        renderCurrentValues.deallocate()
        renderTargetValues.deallocate()
        renderStepPerSample.deallocate()
        renderRemainingFrames.deallocate()
    }

    // MARK: - Lock-Free Atomic Load / Store Primitives

    @inline(__always)
    private func loadAtomicBits(at index: Int) -> UInt32 {
        switch index {
        case 0:  return slot0.load(ordering: .acquiring)
        case 1:  return slot1.load(ordering: .acquiring)
        case 2:  return slot2.load(ordering: .acquiring)
        case 3:  return slot3.load(ordering: .acquiring)
        case 4:  return slot4.load(ordering: .acquiring)
        case 5:  return slot5.load(ordering: .acquiring)
        case 6:  return slot6.load(ordering: .acquiring)
        case 7:  return slot7.load(ordering: .acquiring)
        case 8:  return slot8.load(ordering: .acquiring)
        case 9:  return slot9.load(ordering: .acquiring)
        case 10: return slot10.load(ordering: .acquiring)
        case 11: return slot11.load(ordering: .acquiring)
        case 12: return slot12.load(ordering: .acquiring)
        case 13: return slot13.load(ordering: .acquiring)
        case 14: return slot14.load(ordering: .acquiring)
        case 15: return slot15.load(ordering: .acquiring)
        default: return 0
        }
    }

    @inline(__always)
    private func storeAtomicBits(_ bits: UInt32, at index: Int) {
        switch index {
        case 0:  slot0.store(bits, ordering: .releasing)
        case 1:  slot1.store(bits, ordering: .releasing)
        case 2:  slot2.store(bits, ordering: .releasing)
        case 3:  slot3.store(bits, ordering: .releasing)
        case 4:  slot4.store(bits, ordering: .releasing)
        case 5:  slot5.store(bits, ordering: .releasing)
        case 6:  slot6.store(bits, ordering: .releasing)
        case 7:  slot7.store(bits, ordering: .releasing)
        case 8:  slot8.store(bits, ordering: .releasing)
        case 9:  slot9.store(bits, ordering: .releasing)
        case 10: slot10.store(bits, ordering: .releasing)
        case 11: slot11.store(bits, ordering: .releasing)
        case 12: slot12.store(bits, ordering: .releasing)
        case 13: slot13.store(bits, ordering: .releasing)
        case 14: slot14.store(bits, ordering: .releasing)
        case 15: slot15.store(bits, ordering: .releasing)
        default: break
        }
    }

    // MARK: - Host / UI Accessors

    @inline(__always)
    public func setHostValue(_ rawValue: AUValue, for address: AetherAUParameterAddress) {
        let clamped = address.clamp(rawValue)
        let idx = Int(address.rawValue)
        storeAtomicBits(clamped.bitPattern, at: idx)
        let bit = UInt32(1) << UInt32(idx)
        _ = hostDirtyMask.bitwiseOr(bit, ordering: .acquiringAndReleasing)
    }

    @inline(__always)
    public func getHostValue(for address: AetherAUParameterAddress) -> AUValue {
        let bits = loadAtomicBits(at: Int(address.rawValue))
        return Float(bitPattern: bits)
    }

    // MARK: - Real-Time Audio Render Thread Primitives (Zero Locks / Zero Allocations)

    /// Pulls any host/UI atomic parameter writes into the render-thread state at the start of a render block.
    @inline(__always)
    public func pullHostUpdatesOnAudioThread() {
        let mask = hostDirtyMask.exchange(0, ordering: .acquiringAndReleasing)
        guard mask != 0 else { return }
        for idx in 0..<Self.slotCount {
            if (mask & (UInt32(1) << UInt32(idx))) != 0 {
                let value = Float(bitPattern: loadAtomicBits(at: idx))
                renderCurrentValues[idx] = value
                renderTargetValues[idx] = value
                renderStepPerSample[idx] = 0.0
                renderRemainingFrames[idx] = 0
            }
        }
    }

    /// Resets all render-thread values from the lock-free atomic slots (called on `allocateRenderResources`).
    @inline(__always)
    public func resetRenderStateFromAtomics() {
        _ = hostDirtyMask.exchange(0, ordering: .acquiringAndReleasing)
        for idx in 0..<Self.slotCount {
            let value = Float(bitPattern: loadAtomicBits(at: idx))
            renderCurrentValues[idx] = value
            renderTargetValues[idx] = value
            renderStepPerSample[idx] = 0.0
            renderRemainingFrames[idx] = 0
        }
    }

    /// Publishes the latest sample-accurate ramped values back to the atomic slots at the end of a render slice.
    @inline(__always)
    public func publishRenderValuesToAtomics() {
        for idx in 0..<Self.slotCount {
            storeAtomicBits(renderCurrentValues[idx].bitPattern, at: idx)
        }
    }

    /// Schedules an immediate parameter step (`rampDurationFrames == 0`) or a linear per-sample parameter ramp
    /// (`AURenderEventParameter` / `AURenderEventParameterRamp`) inside `internalRenderBlock`.
    @inline(__always)
    public func scheduleRenderParameterEvent(
        address: AUParameterAddress,
        targetValue: AUValue,
        rampDurationFrames: AUAudioFrameCount
    ) {
        guard let paramAddr = AetherAUParameterAddress(rawValue: address) else { return }
        let idx = Int(address)
        let clamped = paramAddr.clamp(targetValue)

        if rampDurationFrames <= 1 {
            renderCurrentValues[idx] = clamped
            renderTargetValues[idx] = clamped
            renderStepPerSample[idx] = 0.0
            renderRemainingFrames[idx] = 0
            storeAtomicBits(clamped.bitPattern, at: idx)
        } else {
            let current = renderCurrentValues[idx]
            let slope = (clamped - current) / Float(rampDurationFrames)
            renderTargetValues[idx] = clamped
            renderStepPerSample[idx] = slope
            renderRemainingFrames[idx] = UInt32(rampDurationFrames)
        }
    }

    /// Advances all active parameter ramps by 1 sample frame.
    @inline(__always)
    public func stepActiveRampsOneSample() {
        for idx in 0..<Self.slotCount {
            let rem = renderRemainingFrames[idx]
            if rem > 0 {
                if rem == 1 {
                    renderCurrentValues[idx] = renderTargetValues[idx]
                    renderStepPerSample[idx] = 0.0
                    renderRemainingFrames[idx] = 0
                } else {
                    renderCurrentValues[idx] += renderStepPerSample[idx]
                    renderRemainingFrames[idx] = rem - 1
                }
            }
        }
    }

    /// Returns `true` if any parameter slot currently has an active sample-accurate ramp in progress.
    @inline(__always)
    public var hasActiveRamps: Bool {
        for idx in 0..<Self.slotCount {
            if renderRemainingFrames[idx] > 0 {
                return true
            }
        }
        return false
    }

    @inline(__always)
    public func renderValue(_ address: AetherAUParameterAddress) -> Float {
        renderCurrentValues[Int(address.rawValue)]
    }

    /// Builds a value-type `SynthParameters` snapshot on the audio thread from the current render values.
    @inline(__always)
    public func makeSynthParametersSnapshot() -> SynthParameters {
        let hrtfAz = renderValue(.hrtfAzimuthDeg)
        let hrtfEl = renderValue(.hrtfElevationDeg)
        let hrtfDist = renderValue(.hrtfDistanceMeters)
        let enableHRTF = abs(hrtfAz) > 0.01 || abs(hrtfEl - 8.0) > 0.01 || abs(hrtfDist - 1.35) > 0.01

        return SynthParameters(
            carrierFrequencyHz: renderValue(.carrierFrequencyHz),
            binauralBeatHz: renderValue(.binauralBeatHz),
            binauralMix: renderValue(.binauralMix),
            pinkNoiseMix: renderValue(.pinkNoiseMix),
            padMix: renderValue(.padMix),
            filterCutoffHz: renderValue(.filterCutoffHz),
            filterResonance: renderValue(.filterResonance),
            padDetuneCents: renderValue(.padDetuneCents),
            masterGain: renderValue(.masterGain),
            bloomBoost: renderValue(.fmModulationIndex) * 0.5,
            spatialPanOffset: 0.0,
            headElevationTilt: 0.0,
            hrtfAzimuthDeg: hrtfAz,
            hrtfElevationDeg: hrtfEl,
            hrtfDistanceMeters: hrtfDist,
            roomPresetIndex: ShoeboxRoomPreset.obsidianStudio.rawValue,
            isHRTFSpatializerEnabled: enableHRTF,
            neuralSoundscapeMix: renderValue(.neuralSoundscapeMix),
            rayTracedAcousticsEnabled: false,
            isMuted: false
        )
    }

    public func exportDictionary() -> [String: Any] {
        var dict: [String: Any] = [:]
        dict.reserveCapacity(Self.slotCount)
        for addr in AetherAUParameterAddress.allCases {
            dict[addr.identifier] = Double(getHostValue(for: addr))
        }
        return dict
    }

    public func importDictionary(_ dict: [String: Any]) {
        for addr in AetherAUParameterAddress.allCases {
            if let num = dict[addr.identifier] as? NSNumber {
                setHostValue(num.floatValue, for: addr)
            } else if let dbl = dict[addr.identifier] as? Double {
                setHostValue(Float(dbl), for: addr)
            } else if let flt = dict[addr.identifier] as? Float {
                setHostValue(flt, for: addr)
            }
        }
    }
}

// MARK: - 3. Hierarchical 4-Group AUParameterTree Builder

public enum AUParameterTreeBridge {
    private static func makeParameter(_ address: AetherAUParameterAddress) -> AUParameter {
        let bounds = address.valueRange
        let param = AUParameterTree.createParameter(
            withIdentifier: address.identifier,
            name: address.displayName,
            address: address.rawValue,
            min: bounds.lowerBound,
            max: bounds.upperBound,
            unit: address.parameterUnit,
            unitName: nil,
            flags: address.flags,
            valueStrings: nil,
            dependentParameters: nil
        )
        param.value = address.defaultValue
        return param
    }

    /// Constructs the 4-group hierarchical `AUParameterTree` wired to the lock-free `RealtimeParameterBank`.
    public static func buildParameterTree(bank: RealtimeParameterBank) -> AUParameterTree {
        let groupOscillators = AUParameterTree.createGroup(
            withIdentifier: "group.oscillators_binaural",
            name: "Oscillators & Binaural",
            children: [
                makeParameter(.carrierFrequencyHz),
                makeParameter(.binauralBeatHz),
                makeParameter(.binauralMix),
                makeParameter(.pinkNoiseMix),
                makeParameter(.padMix),
                makeParameter(.padDetuneCents),
                makeParameter(.fmModulationIndex)
            ]
        )

        let groupFilter = AUParameterTree.createGroup(
            withIdentifier: "group.tpt_svf_filter",
            name: "TPT SVF Filter",
            children: [
                makeParameter(.filterCutoffHz),
                makeParameter(.filterResonance)
            ]
        )

        let groupSpatial = AUParameterTree.createGroup(
            withIdentifier: "group.spatial_hrtf_fdn",
            name: "Spatial HRTF & FDN Reverb",
            children: [
                makeParameter(.reverbWetMix),
                makeParameter(.reverbDecaySeconds),
                makeParameter(.hrtfAzimuthDeg),
                makeParameter(.hrtfElevationDeg),
                makeParameter(.hrtfDistanceMeters)
            ]
        )

        let groupNeuralMaster = AUParameterTree.createGroup(
            withIdentifier: "group.neural_master",
            name: "Neural & Master",
            children: [
                makeParameter(.neuralSoundscapeMix),
                makeParameter(.masterGain)
            ]
        )

        let tree = AUParameterTree.createTree(withChildren: [
            groupOscillators,
            groupFilter,
            groupSpatial,
            groupNeuralMaster
        ])

        tree.implementorValueObserver = { param, value in
            guard let address = AetherAUParameterAddress(rawValue: param.address) else { return }
            bank.setHostValue(value, for: address)
        }

        tree.implementorValueProvider = { param in
            guard let address = AetherAUParameterAddress(rawValue: param.address) else { return 0.0 }
            return bank.getHostValue(for: address)
        }

        tree.implementorStringFromValueCallback = { param, valuePtr in
            guard let address = AetherAUParameterAddress(rawValue: param.address) else { return "" }
            let val = valuePtr?.pointee ?? param.value
            return address.formatValue(val)
        }

        tree.implementorValueFromStringCallback = { param, str in
            guard let address = AetherAUParameterAddress(rawValue: param.address) else { return 0.0 }
            return address.parseString(str)
        }

        return tree
    }
}
#endif
