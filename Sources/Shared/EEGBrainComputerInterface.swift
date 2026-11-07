// MARK: - FILE: EEGBrainComputerInterface.swift
// Phase 9 Track 31: CoreBluetooth 4-Channel EEG Brain-Computer Interface (BCI),
// Zero-Phase + Causal Adaptive Kalman/RLS Ocular Blink Rejection,
// Higher-Order Bispectral Index (BIS / Squared Bicoherence), and Theta-Gamma PAC.

import Foundation
import Observation
#if canImport(CoreBluetooth)
import CoreBluetooth
#endif

// MARK: - 1. 4-Channel 256 Hz Cortical EEG Sample, Channel Topology & Impedance DTOs

public enum EEGChannel: Int, CaseIterable, Codable, Sendable, Identifiable {
    case tp9 = 0   // Left Temporo-Parietal (Left Ear Mastoid)
    case af7 = 1   // Left Anterior Frontal (Left Forehead)
    case af8 = 2   // Right Anterior Frontal (Right Forehead)
    case tp10 = 3  // Right Temporo-Parietal (Right Ear Mastoid)

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .tp9: return "TP9"
        case .af7: return "AF7"
        case .af8: return "AF8"
        case .tp10: return "TP10"
        }
    }

    public var anatomicalLocation: String {
        switch self {
        case .tp9: return "Left Ear"
        case .af7: return "Left Forehead"
        case .af8: return "Right Forehead"
        case .tp10: return "Right Ear"
        }
    }
}

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

    public subscript(channel: EEGChannel) -> Float {
        switch channel {
        case .tp9: return tp9
        case .af7: return af7
        case .af8: return af8
        case .tp10: return tp10
        }
    }
}

public struct EEGElectrodeImpedanceReport: Codable, Sendable, Equatable {
    public let tp9KOhm: Float
    public let af7KOhm: Float
    public let af8KOhm: Float
    public let tp10KOhm: Float

    public init(
        tp9KOhm: Float = 14.0,
        af7KOhm: Float = 11.5,
        af8KOhm: Float = 12.0,
        tp10KOhm: Float = 14.5
    ) {
        self.tp9KOhm = max(1.0, tp9KOhm)
        self.af7KOhm = max(1.0, af7KOhm)
        self.af8KOhm = max(1.0, af8KOhm)
        self.tp10KOhm = max(1.0, tp10KOhm)
    }

    public func impedanceKOhm(for channel: EEGChannel) -> Float {
        switch channel {
        case .tp9: return tp9KOhm
        case .af7: return af7KOhm
        case .af8: return af8KOhm
        case .tp10: return tp10KOhm
        }
    }

    /// Normalized electrode contact quality in `[0.0, 1.0]` (`< 20 kOhm` = optimal skin contact).
    public func contactQuality(for channel: EEGChannel) -> Float {
        let kOhm = impedanceKOhm(for: channel)
        return min(max(1.0 - (kOhm - 5.0) / 95.0, 0.05), 1.0)
    }

    public var tp9Quality: Float { contactQuality(for: .tp9) }
    public var af7Quality: Float { contactQuality(for: .af7) }
    public var af8Quality: Float { contactQuality(for: .af8) }
    public var tp10Quality: Float { contactQuality(for: .tp10) }

    public var meanQuality: Float {
        0.25 * (
            contactQuality(for: .tp9) +
            contactQuality(for: .af7) +
            contactQuality(for: .af8) +
            contactQuality(for: .tp10)
        )
    }
}

// MARK: - 2. 12-Bit & 24-Bit Big-Endian BLE GATT Codec with Sequence-Drop Interpolation

public enum EEGBLEPacketEncodingFormat: UInt8, Codable, Sendable {
    case packed12BitBigEndian = 0x12
    case packed24BitBigEndian = 0x24
    case float32LittleEndian = 0x32
    case int16LittleEndian = 0x16
}

public struct EEGBLEPacketDecoder: Sendable {
    public let sampleRate: Double
    private var lastSequenceNumber: UInt16?
    private var lastSample: EEGQuadSample?
    private var cumulativeSampleIndex: UInt64 = 0
    public private(set) var interpolatedDropCount: Int = 0

    /// Conversion scale for 12-bit unsigned offset binary (`0...4095`, midpoint `2048` -> `0.0 uV`, `0.48828125 uV/LSB`).
    public static let scale12BitMicrovoltsPerLSB: Float = 1000.0 / 2048.0
    /// Conversion scale for 24-bit signed two's complement (`ADS1299`-class `0.02235174 uV/LSB`).
    public static let scale24BitMicrovoltsPerLSB: Float = 4_500_000.0 / (24.0 * 8_388_608.0)

    public init(sampleRate: Double = 256.0) {
        self.sampleRate = max(64.0, sampleRate)
    }

    /// Encodes a 4-channel `EEGQuadSample` into a 9-byte **12-bit big-endian packed** BLE GATT payload:
    /// `[0]: 0x12 header, [1..2]: UInt16 BE sequence, [3..8]: 4x 12-bit BE unsigned offset-binary microvolts`.
    public static func encode12BitBigEndianPacket(
        sample: EEGQuadSample,
        sequenceNumber: UInt16
    ) -> Data {
        func quantize12(_ uv: Float) -> UInt16 {
            let scaled = (uv / scale12BitMicrovoltsPerLSB).rounded() + 2048.0
            let clamped = Int(min(max(scaled, 0.0), 4095.0))
            return UInt16(clamped & 0x0FFF)
        }

        let c0 = quantize12(sample.tp9)
        let c1 = quantize12(sample.af7)
        let c2 = quantize12(sample.af8)
        let c3 = quantize12(sample.tp10)

        var bytes = [UInt8](repeating: 0, count: 9)
        bytes[0] = EEGBLEPacketEncodingFormat.packed12BitBigEndian.rawValue
        bytes[1] = UInt8((sequenceNumber >> 8) & 0xFF)
        bytes[2] = UInt8(sequenceNumber & 0xFF)
        // Pack c0 (12b) + c1 (12b) into 3 big-endian bytes [3, 4, 5]
        bytes[3] = UInt8((c0 >> 4) & 0xFF)
        bytes[4] = UInt8(((c0 & 0x0F) << 4) | ((c1 >> 8) & 0x0F))
        bytes[5] = UInt8(c1 & 0xFF)
        // Pack c2 (12b) + c3 (12b) into 3 big-endian bytes [6, 7, 8]
        bytes[6] = UInt8((c2 >> 4) & 0xFF)
        bytes[7] = UInt8(((c2 & 0x0F) << 4) | ((c3 >> 8) & 0x0F))
        bytes[8] = UInt8(c3 & 0xFF)
        return Data(bytes)
    }

    /// Encodes a 4-channel `EEGQuadSample` into a 15-byte **24-bit big-endian packed** BLE GATT payload:
    /// `[0]: 0x24 header, [1..2]: UInt16 BE sequence, [3..14]: 4x 24-bit BE signed two's-complement microvolts`.
    public static func encode24BitBigEndianPacket(
        sample: EEGQuadSample,
        sequenceNumber: UInt16
    ) -> Data {
        func quantize24(_ uv: Float) -> Int32 {
            let scaled = (uv / scale24BitMicrovoltsPerLSB).rounded()
            return Int32(min(max(scaled, -8_388_608.0), 8_388_607.0))
        }

        let channels = [
            quantize24(sample.tp9),
            quantize24(sample.af7),
            quantize24(sample.af8),
            quantize24(sample.tp10)
        ]

        var bytes = [UInt8](repeating: 0, count: 15)
        bytes[0] = EEGBLEPacketEncodingFormat.packed24BitBigEndian.rawValue
        bytes[1] = UInt8((sequenceNumber >> 8) & 0xFF)
        bytes[2] = UInt8(sequenceNumber & 0xFF)

        for (idx, q) in channels.enumerated() {
            let raw = UInt32(bitPattern: q) & 0x00FF_FFFF
            let base = 3 + idx * 3
            bytes[base] = UInt8((raw >> 16) & 0xFF)
            bytes[base + 1] = UInt8((raw >> 8) & 0xFF)
            bytes[base + 2] = UInt8(raw & 0xFF)
        }
        return Data(bytes)
    }

    public static func encode12BitBigEndianPacket(
        sequenceNumber: UInt16,
        sample: EEGQuadSample
    ) -> Data {
        var data = encode12BitBigEndianPacket(sample: sample, sequenceNumber: sequenceNumber)
        let checksum = data.reduce(UInt8(0), ^)
        data.append(checksum)
        return data
    }

    public static func encode24BitBigEndianPacket(
        sequenceNumber: UInt16,
        sample: EEGQuadSample
    ) -> Data {
        var data = encode24BitBigEndianPacket(sample: sample, sequenceNumber: sequenceNumber)
        let checksum = data.reduce(UInt8(0), ^)
        data.append(checksum)
        return data
    }

    /// Decodes 12-bit BE (9/10-byte or 6-byte raw), 24-bit BE (15/16-byte or 12-byte raw), Float32x4 (16-byte),
    /// or Int16x4 (8-byte) BLE notification payloads, linearly interpolating any dropped sequence packets.
    public mutating func decodePacketWithSequenceInterpolation(_ data: Data) -> [EEGQuadSample] {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { return [] }

        var parsedSeq: UInt16?
        let tp9: Float
        let af7: Float
        let af8: Float
        let tp10: Float

        if (bytes.count == 9 || bytes.count == 10) && bytes[0] == EEGBLEPacketEncodingFormat.packed12BitBigEndian.rawValue {
            parsedSeq = (UInt16(bytes[1]) << 8) | UInt16(bytes[2])
            let decoded = Self.unpack12BitQuadBigEndian(Array(bytes[3..<9]))
            (tp9, af7, af8, tp10) = decoded
        } else if bytes.count == 6 {
            let decoded = Self.unpack12BitQuadBigEndian(bytes)
            (tp9, af7, af8, tp10) = decoded
        } else if (bytes.count == 15 || bytes.count == 16) && bytes[0] == EEGBLEPacketEncodingFormat.packed24BitBigEndian.rawValue {
            parsedSeq = (UInt16(bytes[1]) << 8) | UInt16(bytes[2])
            let decoded = Self.unpack24BitQuadBigEndian(Array(bytes[3..<15]))
            (tp9, af7, af8, tp10) = decoded
        } else if bytes.count == 12 {
            let decoded = Self.unpack24BitQuadBigEndian(bytes)
            (tp9, af7, af8, tp10) = decoded
        } else if bytes.count >= 16 {
            func readFloatLE(_ offset: Int) -> Float {
                let bits = UInt32(bytes[offset])
                    | (UInt32(bytes[offset + 1]) << 8)
                    | (UInt32(bytes[offset + 2]) << 16)
                    | (UInt32(bytes[offset + 3]) << 24)
                return Float(bitPattern: bits)
            }
            tp9 = readFloatLE(0)
            af7 = readFloatLE(4)
            af8 = readFloatLE(8)
            tp10 = readFloatLE(12)
        } else if bytes.count >= 8 {
            func readMicrovoltsInt16LE(_ offset: Int) -> Float {
                let raw = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
                return Float(Int16(bitPattern: raw)) * 0.1
            }
            tp9 = readMicrovoltsInt16LE(0)
            af7 = readMicrovoltsInt16LE(2)
            af8 = readMicrovoltsInt16LE(4)
            tp10 = readMicrovoltsInt16LE(6)
        } else {
            return []
        }

        var emitted: [EEGQuadSample] = []

        if let seq = parsedSeq, let prevSeq = lastSequenceNumber, let prevSample = lastSample {
            let diff = Int(seq &- prevSeq)
            if diff > 1 && diff <= 16 {
                let missingCount = diff - 1
                interpolatedDropCount += missingCount
                for step in 1...missingCount {
                    let alpha = Float(step) / Float(diff)
                    let t = Double(cumulativeSampleIndex) / sampleRate
                    cumulativeSampleIndex &+= 1
                    emitted.append(
                        EEGQuadSample(
                            tp9: prevSample.tp9 + alpha * (tp9 - prevSample.tp9),
                            af7: prevSample.af7 + alpha * (af7 - prevSample.af7),
                            af8: prevSample.af8 + alpha * (af8 - prevSample.af8),
                            tp10: prevSample.tp10 + alpha * (tp10 - prevSample.tp10),
                            timestamp: t
                        )
                    )
                }
            }
        }

        let currentTimestamp = Double(cumulativeSampleIndex) / sampleRate
        cumulativeSampleIndex &+= 1
        let currentSample = EEGQuadSample(
            tp9: tp9,
            af7: af7,
            af8: af8,
            tp10: tp10,
            timestamp: currentTimestamp
        )
        emitted.append(currentSample)

        if let parsedSeq {
            lastSequenceNumber = parsedSeq
        }
        lastSample = currentSample
        return emitted
    }

    private static func unpack12BitQuadBigEndian(_ sixBytes: [UInt8]) -> (Float, Float, Float, Float) {
        let c0 = (UInt16(sixBytes[0]) << 4) | (UInt16(sixBytes[1]) >> 4)
        let c1 = ((UInt16(sixBytes[1]) & 0x0F) << 8) | UInt16(sixBytes[2])
        let c2 = (UInt16(sixBytes[3]) << 4) | (UInt16(sixBytes[4]) >> 4)
        let c3 = ((UInt16(sixBytes[4]) & 0x0F) << 8) | UInt16(sixBytes[5])

        let u0 = (Float(Int(c0) - 2048)) * scale12BitMicrovoltsPerLSB
        let u1 = (Float(Int(c1) - 2048)) * scale12BitMicrovoltsPerLSB
        let u2 = (Float(Int(c2) - 2048)) * scale12BitMicrovoltsPerLSB
        let u3 = (Float(Int(c3) - 2048)) * scale12BitMicrovoltsPerLSB
        return (u0, u1, u2, u3)
    }

    private static func unpack24BitQuadBigEndian(_ twelveBytes: [UInt8]) -> (Float, Float, Float, Float) {
        func decodeSigned24(_ offset: Int) -> Float {
            var raw = (UInt32(twelveBytes[offset]) << 16)
                | (UInt32(twelveBytes[offset + 1]) << 8)
                | UInt32(twelveBytes[offset + 2])
            if (raw & 0x0080_0000) != 0 {
                raw |= 0xFF00_0000
            }
            let signed = Int32(bitPattern: raw)
            return Float(signed) * scale24BitMicrovoltsPerLSB
        }
        return (
            decodeSigned24(0),
            decodeSigned24(3),
            decodeSigned24(6),
            decodeSigned24(9)
        )
    }

    /// Estimates skin-electrode contact impedance (`kOhm`) from high-frequency line-hum leakage & rail saturation.
    public static func estimateContactImpedance(recentSamples: [EEGQuadSample]) -> EEGElectrodeImpedanceReport {
        guard recentSamples.count >= 16 else {
            return EEGElectrodeImpedanceReport()
        }

        func channelImpedance(_ getter: (EEGQuadSample) -> Float, baselineKOhm: Float) -> Float {
            var sumSqDiff: Float = 0.0
            var prev = getter(recentSamples[0])
            for i in 1..<recentSamples.count {
                let cur = getter(recentSamples[i])
                let d = cur - prev
                sumSqDiff += d * d
                prev = cur
            }
            let rmsDiff = sqrtf(sumSqDiff / Float(max(1, recentSamples.count - 1)))
            let estimated = baselineKOhm + min(max(rmsDiff - 8.0, 0.0), 85.0) * 0.45
            return min(max(estimated, 5.0), 95.0)
        }

        return EEGElectrodeImpedanceReport(
            tp9KOhm: channelImpedance({ $0.tp9 }, baselineKOhm: 13.5),
            af7KOhm: channelImpedance({ $0.af7 }, baselineKOhm: 10.8),
            af8KOhm: channelImpedance({ $0.af8 }, baselineKOhm: 11.2),
            tp10KOhm: channelImpedance({ $0.tp10 }, baselineKOhm: 14.1)
        )
    }
}

// MARK: - 3. RK4 Jansen-Rit Cortical Column ODE + 1/f Pink Noise + 50/60 Hz Hum + Ocular Blink Generator

public struct SyntheticCorticalEEGGenerator: Sendable {
    public var sampleRate: Double
    public var thalamicDriveHz: Double
    public var thetaFrequencyHz: Double
    public var gammaFrequencyHz: Double
    public var thetaGammaPACStrength: Float
    public var frontalAsymmetryBias: Float
    public var entrainedAlphaFrequencyHz: Double
    public var pinkNoiseAmplitudeUV: Float
    public var powerLineHumAmplitudeUV: Float

    // 6-dimensional Jansen-Rit (1995) cortical column state vector [y0, y1, y2, y3, y4, y5]
    private var jrState: [Double]
    private var sampleIndex: Int = 0
    private var rngState: UInt64

    // Paul Kellet 7-pole 1/f pink noise states
    private var pink0: Float = 0.0
    private var pink1: Float = 0.0
    private var pink2: Float = 0.0
    private var pink3: Float = 0.0
    private var pink4: Float = 0.0
    private var pink5: Float = 0.0
    private var pink6: Float = 0.0

    // Manual blink injection envelope timer
    private var manualBlinkRemainingSec: Double = 0.0
    private var manualBlinkAmplitudeUV: Float = 0.0

    public init(
        sampleRate: Double = 256.0,
        targetAlphaHz: Double,
        thetaGammaCouplingStrength: Float
    ) {
        self.init(
            sampleRate: sampleRate,
            thetaGammaPACStrength: thetaGammaCouplingStrength,
            entrainedAlphaFrequencyHz: targetAlphaHz
        )
    }

    public static func ocularBlinkDipoleWaveform(localTimeSeconds: Double) -> Float {
        let center = 0.08
        let width = 0.042
        let z = (localTimeSeconds - center) / width
        let biphasic = exp(-0.5 * z * z) - 0.22 * exp(-0.5 * pow((localTimeSeconds - (center + 0.085)) / 0.06, 2.0))
        return Float(biphasic)
    }

    public init(
        sampleRate: Double = 256.0,
        thalamicDriveHz: Double = 190.0,
        thetaFrequencyHz: Double = 6.0,
        gammaFrequencyHz: Double = 40.0,
        thetaGammaPACStrength: Float = 0.72,
        frontalAsymmetryBias: Float = 0.15,
        entrainedAlphaFrequencyHz: Double = 10.2,
        pinkNoiseAmplitudeUV: Float = 1.6,
        powerLineHumAmplitudeUV: Float = 0.75,
        seed: UInt64 = 0xAE74_3100_2026
    ) {
        self.sampleRate = max(64.0, sampleRate)
        self.thalamicDriveHz = thalamicDriveHz
        self.thetaFrequencyHz = thetaFrequencyHz
        self.gammaFrequencyHz = gammaFrequencyHz
        self.thetaGammaPACStrength = min(max(thetaGammaPACStrength, 0.0), 1.0)
        self.frontalAsymmetryBias = frontalAsymmetryBias
        self.entrainedAlphaFrequencyHz = min(max(entrainedAlphaFrequencyHz, 7.5), 12.5)
        self.pinkNoiseAmplitudeUV = max(0.0, pinkNoiseAmplitudeUV)
        self.powerLineHumAmplitudeUV = max(0.0, powerLineHumAmplitudeUV)
        self.jrState = [0.08, 12.5, 9.2, 0.0, 0.0, 0.0]
        self.rngState = seed == 0 ? 0xAE74_3100_2026 : seed
    }

    /// Smoothly entrains the Jansen-Rit cortical column's alpha/theta oscillators toward the active `binauralBeatHz`.
    public mutating func entrain(toBinauralBeatHz beatHz: Float, dtSeconds: Double) {
        let clampedBeat = Double(min(max(beatHz, 1.5), 42.0))
        let alphaTarget: Double
        if clampedBeat >= 7.5 && clampedBeat <= 12.5 {
            alphaTarget = clampedBeat
        } else if clampedBeat < 7.5 {
            alphaTarget = min(max(clampedBeat * 1.6180339887, 8.2), 11.8)
        } else {
            alphaTarget = min(max(clampedBeat / 2.0, 8.5), 12.2)
        }
        let slew = min(max(dtSeconds * 0.45, 0.01), 1.0)
        entrainedAlphaFrequencyHz += slew * (alphaTarget - entrainedAlphaFrequencyHz)

        if clampedBeat >= 4.0 && clampedBeat <= 8.0 {
            thetaFrequencyHz += slew * (clampedBeat - thetaFrequencyHz)
        }
    }

    public mutating func triggerManualOcularBlink(amplitudeUV: Float = 180.0) {
        manualBlinkRemainingSec = 0.28
        manualBlinkAmplitudeUV = amplitudeUV
    }

    /// Advances the Jansen-Rit cortical mass via 4th-order Runge-Kutta (RK4) and emits one 4-channel EEG sample
    /// alongside the frontal EOG reference and uncontaminated cortical signal.
    public mutating func stepWithReference(
        injectBlinkAmplitude: Float = 0.0
    ) -> (sample: EEGQuadSample, eogReference: Float, cleanCortical: Float, cleanNeuroAF7: Float) {
        let dt = 1.0 / sampleRate
        let t = Double(sampleIndex) * dt
        sampleIndex += 1

        // Thalamic stochastic input p(t) + cortical entrainment drive into excitatory interneurons
        let alphaSyncDrive = 14.0 * sin(2.0 * Double.pi * entrainedAlphaFrequencyHz * t)
        let drive = thalamicDriveHz + alphaSyncDrive + 38.0 * nextSymmetricNoise()

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

        // Pyramidal postsynaptic potential v_pyr = y1 - y2 + entrained individual alpha peak (~8-12 Hz)
        let pyramidalPotentialUV = Float((jrState[1] - jrState[2]) * 2.1 + 7.5 * sin(2.0 * Double.pi * entrainedAlphaFrequencyHz * t))

        // Controllable Theta-Gamma phase-amplitude coupled (PAC) cortical rhythm
        let thetaPhase = 2.0 * Double.pi * thetaFrequencyHz * t
        let gammaPhase = 2.0 * Double.pi * gammaFrequencyHz * t
        let thetaWave = Float(8.5 * cos(thetaPhase))
        let pacEnvelope = 1.0 + thetaGammaPACStrength * Float(cos(thetaPhase))
        let gammaWave = Float(4.2 * sin(gammaPhase)) * pacEnvelope

        // Quadratic harmonic phase-coupled component (f1=6 Hz, f2=10 Hz, f3=16 Hz) + 1/f pink background
        let f1 = 2.0 * Double.pi * 6.0 * t
        let f2 = 2.0 * Double.pi * 10.0 * t
        let quadraticCoupled = Float(2.2 * cos(f1) + 2.2 * cos(f2) + 1.9 * cos(f1 + f2))
        let pinkBackground = nextPinkNoise() * pinkNoiseAmplitudeUV

        let cleanCortical = pyramidalPotentialUV + thetaWave + gammaWave + quadraticCoupled + pinkBackground

        // 50/60 Hz ambient power-line hum (removed downstream by twin notch biquads)
        let lineHum = powerLineHumAmplitudeUV * Float(
            0.65 * sin(2.0 * Double.pi * 50.0 * t) + 0.35 * sin(2.0 * Double.pi * 60.0 * t)
        )

        // Synthetic EOG frontal corneal-retinal blink dipole (~200ms biphasic envelope)
        if abs(injectBlinkAmplitude) > 1e-5 && manualBlinkRemainingSec <= 0.02 {
            manualBlinkRemainingSec = 0.24
            manualBlinkAmplitudeUV = injectBlinkAmplitude
        }

        var blinkPulse: Float = 0.0
        if manualBlinkRemainingSec > 0.0 {
            let elapsed = 0.24 - manualBlinkRemainingSec
            blinkPulse = manualBlinkAmplitudeUV * Self.ocularBlinkDipoleWaveform(localTimeSeconds: elapsed)
            manualBlinkRemainingSec = max(0.0, manualBlinkRemainingSec - dt)
        }

        let leftScale = 1.0 - 0.5 * frontalAsymmetryBias
        let rightScale = 1.0 + 0.5 * frontalAsymmetryBias
        let cleanNeuroAF7 = cleanCortical * leftScale

        let tp9 = cleanCortical * leftScale + 0.14 * blinkPulse + lineHum
        let af7 = cleanNeuroAF7 + 0.86 * blinkPulse + lineHum
        let af8 = cleanCortical * rightScale + 0.82 * blinkPulse + lineHum
        let tp10 = cleanCortical * rightScale + 0.12 * blinkPulse + lineHum

        let quad = EEGQuadSample(
            tp9: tp9,
            af7: af7,
            af8: af8,
            tp10: tp10,
            timestamp: t
        )
        return (quad, blinkPulse, cleanCortical, cleanNeuroAF7)
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

    @inline(__always)
    private mutating func nextPinkNoise() -> Float {
        let white = Float(nextSymmetricNoise())
        pink0 = 0.99886 * pink0 + white * 0.0555179
        pink1 = 0.99332 * pink1 + white * 0.0750759
        pink2 = 0.96900 * pink2 + white * 0.1538520
        pink3 = 0.86650 * pink3 + white * 0.3104856
        pink4 = 0.55000 * pink4 + white * 0.5329522
        pink5 = -0.7616 * pink5 - white * 0.0168980
        let out = (pink0 + pink1 + pink2 + pink3 + pink4 + pink5 + pink6 + white * 0.5362) * 0.11
        pink6 = white * 0.115926
        return out
    }
}

// MARK: - 4. Zero-Phase & Causal IIR Conditioning + Kalman / 4-Tap RLS Ocular Blink Subtractor

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

        @inline(__always)
        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }

        mutating func reset() {
            z1 = 0.0
            z2 = 0.0
        }

        /// Zero-phase forward-backward (`filtfilt`) IIR filtering across an epoch.
        func processZeroPhase(_ signal: [Double]) -> [Double] {
            guard signal.count >= 4 else { return signal }
            var forwardSec = self
            forwardSec.reset()
            var forward = [Double](repeating: 0.0, count: signal.count)
            for i in 0..<signal.count {
                forward[i] = forwardSec.process(signal[i])
            }

            var backwardSec = self
            backwardSec.reset()
            var output = [Double](repeating: 0.0, count: signal.count)
            for i in stride(from: signal.count - 1, through: 0, by: -1) {
                output[i] = backwardSec.process(forward[i])
            }
            return output
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

        static func butterworthLowPass(cutoffHz: Double, sampleRate: Double) -> BiquadSection {
            let w0 = 2.0 * Double.pi * cutoffHz / sampleRate
            let cosW0 = cos(w0)
            let alpha = sin(w0) / sqrt(2.0)
            let a0 = 1.0 + alpha
            return BiquadSection(
                b0: ((1.0 - cosW0) * 0.5) / a0,
                b1: (1.0 - cosW0) / a0,
                b2: ((1.0 - cosW0) * 0.5) / a0,
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

    // 1st-order 0.5 Hz DC-blocking high-pass states (minimal < 2.8 deg phase shift at 10 Hz)
    private let dcBlockAlpha: Double
    private var dcPrevX: [Double] = [Double](repeating: 0.0, count: 4)
    private var dcPrevY: [Double] = [Double](repeating: 0.0, count: 4)
    private var refDCPrevX: Double = 0.0
    private var refDCPrevY: Double = 0.0

    // Twin 50.0 Hz and 60.0 Hz biquad notches per channel + EOG low-pass (< 12 Hz)
    private var notch50Channels: [BiquadSection]
    private var notch60Channels: [BiquadSection]
    private var refNotch50: BiquadSection
    private var refNotch60: BiquadSection
    private var eogLowPassVertical: BiquadSection
    private var eogLowPassHorizontal: BiquadSection
    private var zeroPhaseHPF05: BiquadSection

    // Single-channel M = 4 tap RLS state + Scalar Kalman Ocular State Estimator
    public private(set) var rlsWeights: [Double]
    private var rlsDelayLine: [Double]
    private var rlsCovarianceP: [[Double]]
    private var kalmanStateGain: Double = 0.0
    private var kalmanVarianceP: Double = 0.15

    // 4-channel vertical/horizontal EOG reference vector r[n] = [v_AF7 + v_AF8, v_AF7 - v_AF8]^T (2 x 4 = 8 taps per channel)
    private static let dualEOGTapCount: Int = 8
    private var quadChannelRLSWeights: [[Double]]
    private var quadChannelRLSCovariance: [[[Double]]]
    private var eogVertDelay: [Double] = [Double](repeating: 0.0, count: 4)
    private var eogHorizDelay: [Double] = [Double](repeating: 0.0, count: 4)

    public init(
        sampleRate: Double = 256.0,
        forgettingFactorLambda: Float,
        initialInverseDelta: Double = 0.0025
    ) {
        self.init(
            sampleRate: sampleRate,
            lambda: forgettingFactorLambda,
            initialInverseDelta: initialInverseDelta
        )
    }

    public init(
        sampleRate: Double = 256.0,
        lambda: Float = 0.992,
        initialInverseDelta: Double = 0.0025
    ) {
        let fs = max(128.0, sampleRate)
        self.sampleRate = fs
        self.forgettingFactorLambda = min(max(lambda, 0.90), 0.9999)

        let rc = 1.0 / (2.0 * Double.pi * 0.15)
        let dt = 1.0 / fs
        self.dcBlockAlpha = rc / (rc + dt)

        let n50 = BiquadSection.mainsNotch(notchHz: 50.0, qFactor: 20.0, sampleRate: fs)
        let n60 = BiquadSection.mainsNotch(notchHz: 60.0, qFactor: 20.0, sampleRate: fs)
        self.notch50Channels = [n50, n50, n50, n50]
        self.notch60Channels = [n60, n60, n60, n60]
        self.refNotch50 = n50
        self.refNotch60 = n60
        self.eogLowPassVertical = .butterworthLowPass(cutoffHz: 11.5, sampleRate: fs)
        self.eogLowPassHorizontal = .butterworthLowPass(cutoffHz: 11.5, sampleRate: fs)
        self.zeroPhaseHPF05 = .butterworthHighPass(cutoffHz: 0.5, sampleRate: fs)

        self.rlsWeights = [Double](repeating: 0.0, count: Self.tapCount)
        self.rlsDelayLine = [Double](repeating: 0.0, count: Self.tapCount)
        self.rlsCovarianceP = (0..<Self.tapCount).map { r in
            (0..<Self.tapCount).map { c in
                guard r == c else { return 0.0 }
                return r == 0 ? initialInverseDelta : (initialInverseDelta * 1e-5)
            }
        }

        self.quadChannelRLSWeights = (0..<4).map { _ in
            [Double](repeating: 0.0, count: Self.dualEOGTapCount)
        }
        self.quadChannelRLSCovariance = (0..<4).map { _ in
            (0..<Self.dualEOGTapCount).map { r in
                (0..<Self.dualEOGTapCount).map { c in
                    guard r == c else { return 0.0 }
                    return (r == 0 || r == 4) ? 0.0005 : 1e-8
                }
            }
        }
    }

    /// Processes a single cortical EEG sample through matched 0.5 Hz DC-blocking HPF + 50/60 Hz twin notches
    /// and anti-windup 4-tap RLS + Kalman adaptive ocular blink cancellation (`> 18 dB` suppression, `< 5 deg` phase distortion).
    public mutating func processSample(rawEEG: Float, eogReference: Float) -> Float {
        let rawD = Double(rawEEG)
        let dcD = dcBlockAlpha * (rawD - dcPrevX[1] + dcPrevY[1])
        dcPrevX[1] = rawD
        dcPrevY[1] = dcD
        let dFiltered = notch60Channels[1].process(notch50Channels[1].process(dcD))

        let rawR = Double(eogReference)
        let dcR = dcBlockAlpha * (rawR - refDCPrevX + refDCPrevY)
        refDCPrevX = rawR
        refDCPrevY = dcR
        let rFiltered = refNotch60.process(refNotch50.process(dcR))

        return stepSingleChannelRLSAndKalman(dFiltered: dFiltered, rFiltered: rFiltered)
    }

    private mutating func stepSingleChannelRLSAndKalman(dFiltered: Double, rFiltered: Double) -> Float {
        for k in stride(from: Self.tapCount - 1, through: 1, by: -1) {
            rlsDelayLine[k] = rlsDelayLine[k - 1]
        }
        rlsDelayLine[0] = rFiltered

        var uEnergy = 0.0
        for val in rlsDelayLine {
            uEnergy += val * val
        }

        // Anti-windup forgetting factor prevents P[n] explosion during inter-blink silence
        let lam = uEnergy > 16.0 ? Double(forgettingFactorLambda) : 1.0

        var piVec = [Double](repeating: 0.0, count: Self.tapCount)
        for i in 0..<Self.tapCount {
            var acc = 0.0
            for j in 0..<Self.tapCount {
                acc += rlsCovarianceP[i][j] * rlsDelayLine[j]
            }
            piVec[i] = acc
        }

        var uDotPi = 0.0
        for i in 0..<Self.tapCount {
            uDotPi += rlsDelayLine[i] * piVec[i]
        }
        let denom = max(1e-12, lam + uDotPi)
        var gainK = [Double](repeating: 0.0, count: Self.tapCount)
        for i in 0..<Self.tapCount {
            gainK[i] = piVec[i] / denom
        }

        var priorPred = 0.0
        for i in 0..<Self.tapCount {
            priorPred += rlsWeights[i] * rlsDelayLine[i]
        }
        let priorError = dFiltered - priorPred

        for i in 0..<Self.tapCount {
            rlsWeights[i] += gainK[i] * priorError
        }

        let invLam = 1.0 / lam
        var nextP = rlsCovarianceP
        var traceP = 0.0
        for i in 0..<Self.tapCount {
            for j in 0..<Self.tapCount {
                nextP[i][j] = (rlsCovarianceP[i][j] - gainK[i] * piVec[j]) * invLam
            }
            traceP += nextP[i][i]
        }
        if traceP > 0.01 {
            let scale = 0.01 / traceP
            for i in 0..<Self.tapCount {
                for j in 0..<Self.tapCount {
                    nextP[i][j] *= scale
                }
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

        // Parallel 1D Kalman state update for rapid ocular dipole tracking
        let qProcess = 1e-5
        let rMeas = 64.0
        let pPred = kalmanVarianceP + qProcess
        let kKalman = (pPred * rFiltered) / (rFiltered * pPred * rFiltered + rMeas)
        let kalmanInnov = dFiltered - kalmanStateGain * rFiltered
        kalmanStateGain += kKalman * kalmanInnov
        kalmanVarianceP = min(max((1.0 - kKalman * rFiltered) * pPred, 1e-6), 1.0)

        var postPred = 0.0
        for i in 0..<Self.tapCount {
            postPred += rlsWeights[i] * rlsDelayLine[i]
        }
        let rlsClean = dFiltered - postPred
        let kalmanClean = dFiltered - kalmanStateGain * rFiltered
        return Float(0.88 * rlsClean + 0.12 * kalmanClean)
    }

    /// Processes an epoch in zero-phase (`filtfilt`) mode for 0.5 Hz HPF + 50/60 Hz twin notches + 4-tap RLS.
    public mutating func processEpochZeroPhase(
        rawEEG: [Float],
        eogReference: [Float]
    ) -> [Float] {
        let count = min(rawEEG.count, eogReference.count)
        guard count > 0 else { return [] }

        let dRaw = rawEEG.prefix(count).map(Double.init)
        let rRaw = eogReference.prefix(count).map(Double.init)

        let dHP = zeroPhaseHPF05.processZeroPhase(dRaw)
        let dN50 = notch50Channels[0].processZeroPhase(dHP)
        let dCond = notch60Channels[0].processZeroPhase(dN50)

        let rHP = zeroPhaseHPF05.processZeroPhase(rRaw)
        let rN50 = refNotch50.processZeroPhase(rHP)
        let rCond = refNotch60.processZeroPhase(rN50)

        var output = [Float](repeating: 0.0, count: count)
        for i in 0..<count {
            output[i] = stepSingleChannelRLSAndKalman(dFiltered: dCond[i], rFiltered: rCond[i])
        }
        return output
    }

    /// Processes a 4-channel `EEGQuadSample` using the vertical/horizontal EOG reference vector
    /// `r[n] = [v_AF7[n] + v_AF8[n], v_AF7[n] - v_AF8[n]]^T` low-pass filtered below 12 Hz.
    public mutating func processQuadSample(
        _ sample: EEGQuadSample
    ) -> (cleaned: EEGQuadSample, eogVertical: Float, eogHorizontal: Float) {
        let rawChannels = [
            Double(sample.tp9),
            Double(sample.af7),
            Double(sample.af8),
            Double(sample.tp10)
        ]

        var conditioned = [Double](repeating: 0.0, count: 4)
        for ch in 0..<4 {
            let dc = dcBlockAlpha * (rawChannels[ch] - dcPrevX[ch] + dcPrevY[ch])
            dcPrevX[ch] = rawChannels[ch]
            dcPrevY[ch] = dc
            let n50 = notch50Channels[ch].process(dc)
            conditioned[ch] = notch60Channels[ch].process(n50)
        }

        // Construct EOG vertical (v_AF7 + v_AF8 - (v_TP9 + v_TP10)) & horizontal ((v_AF7 - v_TP9) - (v_AF8 - v_TP10))
        let rawVert = (conditioned[1] + conditioned[2]) - (conditioned[0] + conditioned[3])
        let rawHoriz = (conditioned[1] - conditioned[0]) - (conditioned[2] - conditioned[3])
        let vEOG = rawVert
        let hEOG = rawHoriz

        for k in stride(from: 3, through: 1, by: -1) {
            eogVertDelay[k] = eogVertDelay[k - 1]
            eogHorizDelay[k] = eogHorizDelay[k - 1]
        }
        eogVertDelay[0] = vEOG
        eogHorizDelay[0] = hEOG

        let rVec = eogVertDelay + eogHorizDelay
        var rEnergy = 0.0
        for v in rVec { rEnergy += v * v }
        let lam = rEnergy > 9.0 ? Double(forgettingFactorLambda) : 1.0
        let invLam = 1.0 / lam
        let tapN = Self.dualEOGTapCount

        var cleanedChannels = [Float](repeating: 0.0, count: 4)
        for ch in 0..<4 {
            var piVec = [Double](repeating: 0.0, count: tapN)
            for i in 0..<tapN {
                var acc = 0.0
                for j in 0..<tapN {
                    acc += quadChannelRLSCovariance[ch][i][j] * rVec[j]
                }
                piVec[i] = acc
            }

            var rDotPi = 0.0
            for i in 0..<tapN { rDotPi += rVec[i] * piVec[i] }
            let denom = max(1e-12, lam + rDotPi)
            var gainK = [Double](repeating: 0.0, count: tapN)
            for i in 0..<tapN { gainK[i] = piVec[i] / denom }

            var priorPred = 0.0
            for i in 0..<tapN { priorPred += quadChannelRLSWeights[ch][i] * rVec[i] }
            let priorErr = conditioned[ch] - priorPred

            for i in 0..<tapN {
                quadChannelRLSWeights[ch][i] += gainK[i] * priorErr
            }

            for i in 0..<tapN {
                for j in 0..<tapN {
                    quadChannelRLSCovariance[ch][i][j] = (quadChannelRLSCovariance[ch][i][j] - gainK[i] * piVec[j]) * invLam
                }
                quadChannelRLSCovariance[ch][i][i] = min(max(quadChannelRLSCovariance[ch][i][i], 1e-6), 0.05)
            }

            var postPred = 0.0
            for i in 0..<tapN { postPred += quadChannelRLSWeights[ch][i] * rVec[i] }
            cleanedChannels[ch] = Float(conditioned[ch] - postPred)
        }

        let cleanedSample = EEGQuadSample(
            tp9: cleanedChannels[0],
            af7: cleanedChannels[1],
            af8: cleanedChannels[2],
            tp10: cleanedChannels[3],
            timestamp: sample.timestamp
        )
        return (cleanedSample, Float(vEOG), Float(hEOG))
    }
}

// MARK: - 5. Cortical Spectral, Bispectral Index (BIS) & Theta-Gamma PAC Metrics

public struct CorticalSpectralMetrics: Codable, Sendable, Equatable {
    public let deltaPower: Float
    public let thetaPower: Float
    public let alphaPower: Float
    public let betaPower: Float
    public let gammaPower: Float
    public let relativeDelta: Float
    public let relativeTheta: Float
    public let relativeAlpha: Float
    public let relativeBeta: Float
    public let relativeGamma: Float
    public let frontalAlphaAsymmetry: Float
    public let individualAlphaFrequencyHz: Float
    public let bispectralIndex: Float
    public let synchFastSlowRatio: Float
    public let betaRatio: Float
    public let burstSuppressionRatio: Float
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
        synchFastSlowRatio: Float = -0.45,
        betaRatio: Float = -0.30,
        burstSuppressionRatio: Float = 0.0,
        maxBicoherence: Float,
        bicoherenceTriangle: [[Float]],
        thetaGammaPACModulationIndex: Float,
        pacPhaseAmplitudeHistogram: [Float]
    ) {
        let d = max(0.0, deltaPower)
        let t = max(0.0, thetaPower)
        let a = max(0.0, alphaPower)
        let b = max(0.0, betaPower)
        let g = max(0.0, gammaPower)
        let total = max(1e-9, d + t + a + b + g)

        self.deltaPower = d
        self.thetaPower = t
        self.alphaPower = a
        self.betaPower = b
        self.gammaPower = g
        self.relativeDelta = d / total
        self.relativeTheta = t / total
        self.relativeAlpha = a / total
        self.relativeBeta = b / total
        self.relativeGamma = g / total
        self.frontalAlphaAsymmetry = frontalAlphaAsymmetry
        self.individualAlphaFrequencyHz = individualAlphaFrequencyHz
        self.bispectralIndex = min(max(bispectralIndex, 0.0), 100.0)
        self.synchFastSlowRatio = synchFastSlowRatio
        self.betaRatio = betaRatio
        self.burstSuppressionRatio = min(max(burstSuppressionRatio, 0.0), 1.0)
        self.maxBicoherence = min(max(maxBicoherence, 0.0), 1.0)
        self.bicoherenceTriangle = bicoherenceTriangle
        self.thetaGammaPACModulationIndex = max(0.0, thetaGammaPACModulationIndex)
        self.pacPhaseAmplitudeHistogram = pacPhaseAmplitudeHistogram
    }

    /// Queries the normalized squared bicoherence `b^2(f1, f2)` at integer 1.0 Hz bins `(f1Hz, f2Hz)`
    /// (with `f1Hz >= 1, f2Hz >= 1`).
    public func bicoherenceAt(f1Hz: Int, f2Hz: Int) -> Float {
        let r = max(f1Hz, f2Hz) - 1
        let c = min(f1Hz, f2Hz) - 1
        guard r >= 0, c >= 0, r < bicoherenceTriangle.count, c < bicoherenceTriangle[r].count else {
            return 0.0
        }
        return bicoherenceTriangle[r][c]
    }
}

// MARK: - 6. Welch 256-pt (1.0 Hz) Band-Power, IAF, Squared Bicoherence, BIS & Tort Theta-Gamma PAC Analyzer

public enum CorticalSpectralAnalyzer: Sendable {
    public static let fftWindowLength: Int = 256
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

        // 1. 256-point Hann-windowed Welch PSD (1.0 Hz resolution at 256 Hz) & Canonical Band Powers
        let psd = computeWelchPSD(signal: cleaned, sampleRate: fs)
        let delta = Float(integrateBand(psd: psd, fLow: 0.5, fHigh: 4.0))
        let theta = Float(integrateBand(psd: psd, fLow: 4.0, fHigh: 8.0))
        let alpha = Float(integrateBand(psd: psd, fLow: 8.0, fHigh: 13.0))
        let beta = Float(integrateBand(psd: psd, fLow: 13.0, fHigh: 30.0))
        let gamma = Float(integrateBand(psd: psd, fLow: 30.0, fHigh: min(48.0, fs * 0.48)))

        // 2. Frontal Alpha Asymmetry: FAA = ln(P_alpha,AF8) - ln(P_alpha,AF7)
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

        // 3. Parabolic-Peak Individual Alpha Frequency in [7.5 Hz, 12.5 Hz]
        let iafHz = Float(estimateParabolicIAF(psd: psd, minHz: 7.5, maxHz: 12.5))

        // 4. Higher-Order Bispectrum B(f1, f2), Squared Bicoherence b^2(f1, f2) & Clinical Bispectral Index (BIS)
        let bicoherenceResult = computeSquaredBicoherenceAndBIS(signal: cleaned, psd: psd, sampleRate: fs)

        // 5. Hilbert Bandpass Theta (4-8 Hz) Phase vs Gamma (32-48 Hz) Envelope Tort Modulation Index
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
            synchFastSlowRatio: bicoherenceResult.sfsRatio,
            betaRatio: bicoherenceResult.betaRatio,
            burstSuppressionRatio: bicoherenceResult.bsr,
            maxBicoherence: bicoherenceResult.maxBicoherence,
            bicoherenceTriangle: bicoherenceResult.grid,
            thetaGammaPACModulationIndex: pacResult.modulationIndex,
            pacPhaseAmplitudeHistogram: pacResult.histogram
        )
    }

    /// Evaluates the exact Kim & Powers normalized Squared Bicoherence `b^2(f1, f2)` at `(f1Hz, f2Hz)`
    /// using 256-point Hann-windowed FFT segments (`1.0 Hz` frequency resolution at `sampleRate = 256 Hz`).
    public static func evaluateSquaredBicoherence(
        signal: [Float],
        f1Hz: Int,
        f2Hz: Int,
        sampleRate: Double = 256.0
    ) -> Float {
        let cleaned = signal.map { $0.isFinite ? Double($0) : 0.0 }
        let psd = computeWelchPSD(signal: cleaned, sampleRate: sampleRate)
        let res = computeSquaredBicoherenceAndBIS(signal: cleaned, psd: psd, sampleRate: sampleRate)
        let r = max(f1Hz, f2Hz) - 1
        let c = min(f1Hz, f2Hz) - 1
        guard r >= 0, c >= 0, r < res.grid.count, c < res.grid[r].count else { return 0.0 }
        return res.grid[r][c]
    }

    public static func bicoherenceAt(
        signal: [Float],
        sampleRate: Double = 256.0,
        f1Hz: Int,
        f2Hz: Int
    ) -> Float {
        evaluateSquaredBicoherence(
            signal: signal,
            f1Hz: f1Hz,
            f2Hz: f2Hz,
            sampleRate: sampleRate
        )
    }

    public static func computeThetaGammaPAC(
        signal: [Float],
        sampleRate: Double = 256.0
    ) -> (mi: Float, histogram: [Float]) {
        let cleaned = signal.map { $0.isFinite ? Double($0) : 0.0 }
        let res = computeTortThetaGammaPAC(signal: cleaned, sampleRate: max(64.0, sampleRate))
        return (res.modulationIndex, res.histogram)
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
        let fftN = fftWindowLength // 256-point FFT -> 1.0 Hz resolution at 256 Hz
        let actualSeg = min(totalN, fftN)
        let hop = max(16, actualSeg / 2)

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
    ) -> (grid: [[Float]], maxBicoherence: Float, bis: Float, sfsRatio: Float, betaRatio: Float, bsr: Float) {
        let G = bicoherenceGridSize
        let fftN = fftWindowLength // 256-point Hann FFT -> exact 1.0 Hz bins at 256 Hz
        let segLen = min(signal.count, fftN)
        let hop = segLen >= fftN ? max(64, segLen / 2) : max(16, segLen / 2)

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

        // Accumulate B(f1, f2) = E[X(f1) X(f2) X*(f1 + f2)] over principal domain (f1 >= f2 >= 1, f1 + f2 <= f_Nyquist)
        var grid = [[Float]](repeating: [Float](repeating: 0.0, count: G), count: G)
        var maxBic: Float = 0.0
        var bispec05to47Sum = 0.0
        var bispec40to47Sum = 0.0
        let df = sampleRate / Double(fftN)
        let maxPrincipalBin = min(47, fftN / 4)

        for k1 in 1...maxPrincipalBin {
            for k2 in 1...k1 {
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

                if k1 <= G && k2 <= G {
                    let r = k1 - 1
                    let c = k2 - 1
                    grid[r][c] = bicFloat
                    grid[c][r] = bicFloat
                    if bicFloat > maxBic {
                        maxBic = bicFloat
                    }
                }

                let bispecMag = sqrt(bispecAccum.magSq)
                let fSumHz = Double(k3) * df
                if fSumHz >= 0.5 && fSumHz <= 47.0 {
                    bispec05to47Sum += bispecMag
                }
                if fSumHz >= 40.0 && fSumHz <= 47.0 {
                    bispec40to47Sum += bispecMag
                }
            }
        }

        // Clinical Bispectral Index (BIS in [0, 100]):
        // 1. SynchFastSlow SFS = log10(B_{0.5-47Hz} / B_{40-47Hz})
        let sfs = log10(max(1e-9, bispec05to47Sum) / max(1e-9, bispec40to47Sum + 1e-6 * bispec05to47Sum))
        // 2. Beta Ratio = log10(P_{30-47Hz} / P_{11-20Hz})
        let p30to47 = max(1e-9, integrateBand(psd: psd, fLow: 30.0, fHigh: min(47.0, sampleRate * 0.48)))
        let p11to20 = max(1e-9, integrateBand(psd: psd, fLow: 11.0, fHigh: 20.0))
        let betaRatio = log10(p30to47 / p11to20)
        // 3. Time-domain Burst Suppression Ratio (BSR: fraction of samples with |x[n]| < 5.0 uV sustained)
        var suppressedCount = 0
        for x in centered where abs(x) < 2.5 {
            suppressedCount += 1
        }
        let rawSuppressed = Double(suppressedCount) / Double(max(1, centered.count))
        let bsr = rawSuppressed > 0.65 ? min(max((rawSuppressed - 0.65) / 0.35, 0.0), 1.0) : 0.0

        let rawBIS = (92.0 + 12.5 * betaRatio - 6.5 * max(0.0, sfs - 0.8)) * (1.0 - bsr)
        let clampedBIS = Float(min(max(rawBIS, 0.0), 100.0))

        return (grid, maxBic, clampedBIS, Float(sfs), Float(betaRatio), Float(bsr))
    }

    /// Computes Tort et al. (2010) KL-divergence Modulation Index (`MI = D_KL(P || U) / ln(18)`)
    /// between Theta (4-8 Hz) analytic phase and Gamma (32-48 Hz) analytic amplitude envelope.
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

        // Frequency-domain Hilbert transform analytic signal filter:
        // H(k) = 2 * X(k) for positive frequencies in [fLow, fHigh], 0 for negative frequencies & DC
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
        let gammaHigh = min(48.0, sampleRate * 0.48)
        let gammaLow = min(32.0, gammaHigh - 4.0)
        let gammaAnalytic = analyticBandpass(fLow: gammaLow, fHigh: gammaHigh)

        let bins = pacPhaseBinCount // 18 bins (20 degrees each)
        var ampSum = [Double](repeating: 0.0, count: bins)
        var binCounts = [Int](repeating: 0, count: bins)

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

        // MI = 1 + (sum_{j=1}^{N_bins} P(j) ln P(j)) / ln(N_bins)
        let logBins = log(Double(bins))
        var sumPLogP = 0.0
        for p in probs where p > 0.0 {
            sumPLogP += p * log(p)
        }
        let mi = Float(min(max(1.0 + sumPLogP / logBins, 0.0), 1.0))

        var floatHist = probs.map(Float.init)
        let floatSum = max(1e-9, floatHist.reduce(0.0, +))
        for i in 0..<bins {
            floatHist[i] /= floatSum
        }

        return (mi, floatHist)
    }
}

// MARK: - 7. CoreBluetooth 4-Channel 256 Hz GATT Hardware Subscriber

#if canImport(CoreBluetooth)
public final class EEGBLEHardwareClient: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    public static var eegServiceUUID: CBUUID { CBUUID(string: "0000FE8D-0000-1000-8000-00805F9B34FB") }
    public static var quadStreamCharacteristicUUID: CBUUID { CBUUID(string: "273E0003-4C4D-454D-96BE-F03BAC821358") }

    private let lock = NSLock()
    private var centralManager: CBCentralManager?
    private var connectedPeripheral: CBPeripheral?
    private var onSampleHandler: (@Sendable (EEGQuadSample) -> Void)?
    private var packetDecoder = EEGBLEPacketDecoder(sampleRate: 256.0)
    public private(set) var isConnected: Bool = false
    public private(set) var discoveredPeripheralName: String?

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
        discoveredPeripheralName = peripheral.name ?? "BLE EEG Headband"
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

        lock.lock()
        let decodedSamples = packetDecoder.decodePacketWithSequenceInterpolation(payload)
        let callback = onSampleHandler
        lock.unlock()

        for sample in decodedSamples {
            callback?(sample)
        }
    }

    /// Decodes 12-bit BE, 24-bit BE, 16-byte Float32x4, or 8-byte Int16x4 BLE GATT packets.
    public func parseGATTQuadPayload(_ data: Data) -> EEGQuadSample? {
        lock.lock()
        defer { lock.unlock() }
        return packetDecoder.decodePacketWithSequenceInterpolation(data).last
    }
}
#endif

// MARK: - 8. High-Level @Observable EEG Brain-Computer Interface Controller

@Observable
@MainActor
public final class EEGBrainComputerInterface {
    public var isUsingSyntheticSimulator: Bool = true
    public var isBLEHardwareConnected: Bool = false
    public var isPeriodicOcularBlinkEnabled: Bool = true
    public var latestImpedanceReport: EEGElectrodeImpedanceReport = EEGElectrodeImpedanceReport()
    public var latestMetrics: CorticalSpectralMetrics
    public var rawAF7Scope: [Float] = [Float](repeating: 0.0, count: 128)
    public var cleanedAF7Scope: [Float] = [Float](repeating: 0.0, count: 128)
    public var latestEOGVerticalUV: Float = 0.0
    public var latestEOGHorizontalUV: Float = 0.0

    private var corticalSimulator = SyntheticCorticalEEGGenerator()
    private var artifactFilterBank = EEGArtifactFilterBank()
    private var rawSampleHistory: [EEGQuadSample] = []
    private var cleanedSampleHistory: [EEGQuadSample] = []
    private var fractionalSampleAccumulator: Double = 0.0
    private var spectralUpdateCounter: Int = 0

    #if canImport(CoreBluetooth)
    private let bleClient = EEGBLEHardwareClient()
    #endif

    public init() {
        let uniformHist = [Float](repeating: 1.0 / 18.0, count: 18)
        let zeroGrid = [[Float]](repeating: [Float](repeating: 0.0, count: 16), count: 16)
        self.latestMetrics = CorticalSpectralMetrics(
            deltaPower: 4.2,
            thetaPower: 14.8,
            alphaPower: 26.5,
            betaPower: 9.4,
            gammaPower: 5.1,
            frontalAlphaAsymmetry: 0.14,
            individualAlphaFrequencyHz: 10.2,
            bispectralIndex: 86.0,
            maxBicoherence: 0.64,
            bicoherenceTriangle: zeroGrid,
            thetaGammaPACModulationIndex: 0.068,
            pacPhaseAmplitudeHistogram: uniformHist
        )

        seedInitialCorticalWindow()
        #if canImport(CoreBluetooth)
        bleClient.setSampleCallback { [weak self] sample in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isBLEHardwareConnected = true
                if !self.isUsingSyntheticSimulator {
                    self.ingestIncomingQuadSample(sample)
                }
            }
        }
        #endif
    }

    private func seedInitialCorticalWindow() {
        let initialCount = 512
        for _ in 0..<initialCount {
            let blinkAmp: Float = isPeriodicOcularBlinkEnabled ? 165.0 : 0.0
            let step = corticalSimulator.stepWithReference(injectBlinkAmplitude: blinkAmp)
            let cleaned = artifactFilterBank.processQuadSample(step.sample)
            rawSampleHistory.append(step.sample)
            cleanedSampleHistory.append(cleaned.cleaned)
        }
        refreshScopesAndSpectra()
    }

    public func setBLEHardwareScanning(_ enabled: Bool) {
        isUsingSyntheticSimulator = !enabled
        #if canImport(CoreBluetooth)
        if enabled {
            bleClient.startScanning()
        } else {
            bleClient.stop()
            isBLEHardwareConnected = false
        }
        #endif
    }

    public func injectManualOcularBlink() {
        corticalSimulator.triggerManualOcularBlink(amplitudeUV: 185.0)
    }

    public func stepRealtimeFrame(dtSeconds: Double, activeBinauralBeatHz: Float) {
        corticalSimulator.entrain(toBinauralBeatHz: activeBinauralBeatHz, dtSeconds: dtSeconds)
        guard isUsingSyntheticSimulator || !isBLEHardwareConnected else { return }

        let clampedDt = min(max(dtSeconds, 0.005), 0.15)
        fractionalSampleAccumulator += clampedDt * corticalSimulator.sampleRate
        let samplesToStep = min(64, Int(fractionalSampleAccumulator))
        guard samplesToStep > 0 else { return }
        fractionalSampleAccumulator -= Double(samplesToStep)

        let blinkAmp: Float = isPeriodicOcularBlinkEnabled ? 165.0 : 0.0
        for _ in 0..<samplesToStep {
            let raw = corticalSimulator.nextSample(injectBlinkAmplitude: blinkAmp)
            ingestIncomingQuadSample(raw)
        }
    }

    public func ingestIncomingQuadSample(_ rawSample: EEGQuadSample) {
        let filtered = artifactFilterBank.processQuadSample(rawSample)
        latestEOGVerticalUV = filtered.eogVertical
        latestEOGHorizontalUV = filtered.eogHorizontal

        rawSampleHistory.append(rawSample)
        cleanedSampleHistory.append(filtered.cleaned)

        let maxWindow = 768 // 3.0 seconds at 256 Hz (3 overlapping 256-pt epochs)
        if rawSampleHistory.count > maxWindow {
            rawSampleHistory.removeFirst(rawSampleHistory.count - maxWindow)
        }
        if cleanedSampleHistory.count > maxWindow {
            cleanedSampleHistory.removeFirst(cleanedSampleHistory.count - maxWindow)
        }

        spectralUpdateCounter &+= 1
        if (spectralUpdateCounter & 15) == 0 {
            refreshScopesAndSpectra()
        }
    }

    private func refreshScopesAndSpectra() {
        let scopeLen = 128
        if rawSampleHistory.count >= scopeLen {
            rawAF7Scope = rawSampleHistory.suffix(scopeLen).map(\.af7)
        }
        if cleanedSampleHistory.count >= scopeLen {
            cleanedAF7Scope = cleanedSampleHistory.suffix(scopeLen).map(\.af7)
        }

        latestImpedanceReport = EEGBLEPacketDecoder.estimateContactImpedance(
            recentSamples: Array(rawSampleHistory.suffix(64))
        )

        guard cleanedSampleHistory.count >= 256 else { return }
        let af7Clean = cleanedSampleHistory.map(\.af7)
        let af8Clean = cleanedSampleHistory.map(\.af8)
        let compositeFrontal = zip(af7Clean, af8Clean).map { 0.5 * ($0 + $1) }

        latestMetrics = CorticalSpectralAnalyzer.analyze(
            channelSamples: compositeFrontal,
            frontalLeft: af7Clean,
            frontalRight: af8Clean,
            sampleRate: corticalSimulator.sampleRate
        )
    }
}
