// MARK: - FILE: AUParameterTreeBridge.swift

import Foundation
import AudioToolbox

// MARK: - 16-Slot Real-Time AUv3 Parameter Address Map

public enum AetherAUParameterAddress: AUParameterAddress, CaseIterable, Sendable {
    case carrierFrequencyHz = 0
    case binauralBeatHz = 1
    case binauralMix = 2
    case tzfmIndex = 3
    case tzfmRatio = 4
    case padDetuneCents = 5
    case pinkNoiseMix = 6
    case filterCutoffHz = 7
    case filterResonance = 8
    case ampAttackSeconds = 9
    case ampDecaySeconds = 10
    case ampSustainLevel = 11
    case ampReleaseSeconds = 12
    case mpePitchBendRangeSemitones = 13
    case stereoWidth = 14
    case masterGain = 15

    public var identifier: String {
        switch self {
        case .carrierFrequencyHz: return "carrierFrequencyHz"
        case .binauralBeatHz: return "binauralBeatHz"
        case .binauralMix: return "binauralMix"
        case .tzfmIndex: return "tzfmIndex"
        case .tzfmRatio: return "tzfmRatio"
        case .padDetuneCents: return "padDetuneCents"
        case .pinkNoiseMix: return "pinkNoiseMix"
        case .filterCutoffHz: return "filterCutoffHz"
        case .filterResonance: return "filterResonance"
        case .ampAttackSeconds: return "ampAttackSeconds"
        case .ampDecaySeconds: return "ampDecaySeconds"
        case .ampSustainLevel: return "ampSustainLevel"
        case .ampReleaseSeconds: return "ampReleaseSeconds"
        case .mpePitchBendRangeSemitones: return "mpePitchBendRangeSemitones"
        case .stereoWidth: return "stereoWidth"
        case .masterGain: return "masterGain"
        }
    }

    public var displayName: String {
        switch self {
        case .carrierFrequencyHz: return "Carrier Tuning"
        case .binauralBeatHz: return "Binaural Beat"
        case .binauralMix: return "Binaural Mix"
        case .tzfmIndex: return "TZFM Index"
        case .tzfmRatio: return "TZFM Ratio"
        case .padDetuneCents: return "Harmonic Detune"
        case .pinkNoiseMix: return "1/f Pink Noise"
        case .filterCutoffHz: return "SVF Cutoff"
        case .filterResonance: return "SVF Resonance"
        case .ampAttackSeconds: return "Amp Attack"
        case .ampDecaySeconds: return "Amp Decay"
        case .ampSustainLevel: return "Amp Sustain"
        case .ampReleaseSeconds: return "Amp Release"
        case .mpePitchBendRangeSemitones: return "MPE Bend Range"
        case .stereoWidth: return "Stereo Width"
        case .masterGain: return "Master Gain"
        }
    }

    public var valueRange: ClosedRange<Float> {
        switch self {
        case .carrierFrequencyHz: return 60.0...880.0
        case .binauralBeatHz: return 0.5...48.0
        case .binauralMix: return 0.0...1.0
        case .tzfmIndex: return 0.0...8.0
        case .tzfmRatio: return 0.25...8.0
        case .padDetuneCents: return 0.0...35.0
        case .pinkNoiseMix: return 0.0...1.0
        case .filterCutoffHz: return 80.0...16_000.0
        case .filterResonance: return 0.05...0.94
        case .ampAttackSeconds: return 0.002...4.0
        case .ampDecaySeconds: return 0.010...6.0
        case .ampSustainLevel: return 0.0...1.0
        case .ampReleaseSeconds: return 0.015...8.0
        case .mpePitchBendRangeSemitones: return 1.0...96.0
        case .stereoWidth: return 0.0...1.0
        case .masterGain: return 0.0...1.0
        }
    }

    public var defaultValue: Float {
        switch self {
        case .carrierFrequencyHz: return 220.0
        case .binauralBeatHz: return 10.0
        case .binauralMix: return 0.34
        case .tzfmIndex: return 1.45
        case .tzfmRatio: return 2.0
        case .padDetuneCents: return 9.5
        case .pinkNoiseMix: return 0.12
        case .filterCutoffHz: return 2_200.0
        case .filterResonance: return 0.32
        case .ampAttackSeconds: return 0.035
        case .ampDecaySeconds: return 0.55
        case .ampSustainLevel: return 0.78
        case .ampReleaseSeconds: return 0.85
        case .mpePitchBendRangeSemitones: return 48.0
        case .stereoWidth: return 0.85
        case .masterGain: return 0.72
        }
    }

    public var parameterUnit: AudioUnitParameterUnit {
        switch self {
        case .carrierFrequencyHz, .binauralBeatHz, .filterCutoffHz:
            return .hertz
        case .tzfmRatio:
            return .ratio
        case .padDetuneCents:
            return .cents
        case .ampAttackSeconds, .ampDecaySeconds, .ampReleaseSeconds:
            return .seconds
        case .mpePitchBendRangeSemitones:
            return .relativeSemiTones
        case .masterGain:
            return .linearGain
        default:
            return .generic
        }
    }
}

// MARK: - Lock-Free Heap-Allocated 16-Slot Parameter Bank

public final class RealtimeParameterBank: @unchecked Sendable {
    public static let slotCount: Int = 16

    public let valuesPointer: UnsafeMutablePointer<Float>

    public init() {
        let ptr = UnsafeMutablePointer<Float>.allocate(capacity: Self.slotCount)
        ptr.initialize(repeating: 0.0, count: Self.slotCount)
        for addressCase in AetherAUParameterAddress.allCases {
            ptr[Int(addressCase.rawValue)] = addressCase.defaultValue
        }
        self.valuesPointer = ptr
    }

    deinit {
        valuesPointer.deinitialize(count: Self.slotCount)
        valuesPointer.deallocate()
    }

    @inline(__always)
    public func setValue(_ rawValue: Float, for address: AUParameterAddress) {
        let idx = Int(address)
        guard idx >= 0, idx < Self.slotCount else { return }
        if let known = AetherAUParameterAddress(rawValue: address) {
            let bounds = known.valueRange
            let finite = rawValue.isFinite ? rawValue : known.defaultValue
            valuesPointer[idx] = min(max(finite, bounds.lowerBound), bounds.upperBound)
        } else {
            valuesPointer[idx] = rawValue.isFinite ? rawValue : 0.0
        }
    }

    @inline(__always)
    public func value(for address: AUParameterAddress) -> Float {
        let idx = Int(address)
        guard idx >= 0, idx < Self.slotCount else { return 0.0 }
        return valuesPointer[idx]
    }

    @inline(__always)
    public subscript(parameter: AetherAUParameterAddress) -> Float {
        get { valuesPointer[Int(parameter.rawValue)] }
        set { setValue(newValue, for: parameter.rawValue) }
    }

    public func snapshotAllValues() -> [Float] {
        var copy = [Float](repeating: 0.0, count: Self.slotCount)
        for i in 0..<Self.slotCount {
            copy[i] = valuesPointer[i]
        }
        return copy
    }

    public func applyFactoryPreset(number: Int) {
        // [carrier, beat, binMix, tzfmIdx, tzfmRat, detune, pink, cutoff, res, atk, dec, sus, rel, bend, width, gain]
        let table: [[Float]] = [
            [216.0, 14.0, 0.36, 1.35, 2.00,  9.5, 0.14, 1_950.0, 0.34, 0.040, 0.60, 0.78, 0.95, 48.0, 0.84, 0.72],
            [196.0, 10.0, 0.32, 2.15, 3.00, 12.0, 0.10, 2_850.0, 0.28, 0.025, 0.48, 0.80, 1.15, 48.0, 0.88, 0.70],
            [144.0,  5.5, 0.44, 0.85, 1.50, 15.0, 0.16,   920.0, 0.46, 0.180, 1.20, 0.86, 2.40, 48.0, 0.92, 0.68],
            [256.0, 40.0, 0.38, 3.40, 4.00,  6.5, 0.08, 4_600.0, 0.30, 0.008, 0.35, 0.62, 0.70, 48.0, 0.80, 0.66],
            [128.0,  2.5, 0.30, 1.80, 1.00, 18.0, 0.20, 1_320.0, 0.52, 0.090, 0.90, 0.84, 1.85, 48.0, 0.95, 0.70]
        ]
        let clampedIdx = min(max(number, 0), table.count - 1)
        let row = table[clampedIdx]
        for slot in 0..<min(Self.slotCount, row.count) {
            setValue(row[slot], for: AUParameterAddress(slot))
        }
    }
}

// MARK: - Lock-Free AUParameterTree Builder

public enum AUParameterTreeBridge {
    public static func createParameterTree(bank: RealtimeParameterBank) -> AUParameterTree {
        let rwRampFlags: AudioUnitParameterOptions = [
            .flag_IsReadable,
            .flag_IsWritable,
            .flag_CanRamp
        ]

        func makeParam(_ spec: AetherAUParameterAddress) -> AUParameter {
            let param = AUParameterTree.createParameter(
                withIdentifier: spec.identifier,
                name: spec.displayName,
                address: spec.rawValue,
                min: spec.valueRange.lowerBound,
                max: spec.valueRange.upperBound,
                unit: spec.parameterUnit,
                unitName: nil,
                flags: rwRampFlags,
                valueStrings: nil,
                dependentParameters: nil
            )
            param.value = bank[spec]
            return param
        }

        let oscGroup = AUParameterTree.createGroup(
            withIdentifier: "oscillatorTZFM",
            name: "TZFM & Binaural Oscillators",
            children: [
                makeParam(.carrierFrequencyHz),
                makeParam(.binauralBeatHz),
                makeParam(.binauralMix),
                makeParam(.tzfmIndex),
                makeParam(.tzfmRatio),
                makeParam(.padDetuneCents),
                makeParam(.pinkNoiseMix)
            ]
        )

        let filterGroup = AUParameterTree.createGroup(
            withIdentifier: "cytomicFilter",
            name: "Cytomic TPT SVF Filter",
            children: [
                makeParam(.filterCutoffHz),
                makeParam(.filterResonance)
            ]
        )

        let envGroup = AUParameterTree.createGroup(
            withIdentifier: "ampEnvelope",
            name: "ADSR Envelope",
            children: [
                makeParam(.ampAttackSeconds),
                makeParam(.ampDecaySeconds),
                makeParam(.ampSustainLevel),
                makeParam(.ampReleaseSeconds)
            ]
        )

        let masterGroup = AUParameterTree.createGroup(
            withIdentifier: "mpeMaster",
            name: "MPE & Spatial Output",
            children: [
                makeParam(.mpePitchBendRangeSemitones),
                makeParam(.stereoWidth),
                makeParam(.masterGain)
            ]
        )

        let tree = AUParameterTree.createTree(withChildren: [
            oscGroup,
            filterGroup,
            envGroup,
            masterGroup
        ])

        // Lock-free observer & provider touching ONLY RealtimeParameterBank raw float slots
        tree.implementorValueObserver = { param, newValue in
            bank.setValue(newValue, for: param.address)
        }

        tree.implementorValueProvider = { param in
            bank.value(for: param.address)
        }

        tree.implementorStringFromValueCallback = { param, valuePtr in
            let v = valuePtr?.pointee ?? bank.value(for: param.address)
            guard let spec = AetherAUParameterAddress(rawValue: param.address) else {
                return String(format: "%.2f", v)
            }
            switch spec {
            case .carrierFrequencyHz, .filterCutoffHz:
                return String(format: "%.0f Hz", v)
            case .binauralBeatHz:
                return String(format: "%.1f Hz", v)
            case .tzfmIndex, .tzfmRatio, .filterResonance:
                return String(format: "%.2f", v)
            case .padDetuneCents:
                return String(format: "%.1f ct", v)
            case .ampAttackSeconds, .ampDecaySeconds, .ampReleaseSeconds:
                return v < 0.1 ? String(format: "%.0f ms", v * 1_000.0) : String(format: "%.2f s", v)
            case .mpePitchBendRangeSemitones:
                return String(format: "±%.0f st", v)
            default:
                return String(format: "%.0f%%", v * 100.0)
            }
        }

        return tree
    }
}
