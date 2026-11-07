// MARK: - FILE: WatchBiometricBridgeActor.swift

import Foundation
#if canImport(WatchConnectivity) && (os(iOS) || os(watchOS))
import WatchConnectivity
#endif

// MARK: - 1. Binary FNV-1a 64-Bit Checksummed Biometric Wire Codec

public enum BiometricWireCodecError: LocalizedError, Sendable, Equatable {
    case frameTooShort(Int)
    case invalidMagicHeader
    case unsupportedVersion(UInt8)
    case payloadLengthMismatch(expected: Int, actual: Int)
    case checksumMismatch(expected: UInt64, actual: UInt64)

    public var errorDescription: String? {
        switch self {
        case .frameTooShort(let n):
            return "Biometric wire frame too short (\(n) bytes)."
        case .invalidMagicHeader:
            return "Invalid ABIO binary magic header."
        case .unsupportedVersion(let v):
            return "Unsupported BiometricWireCodec version \(v)."
        case .payloadLengthMismatch(let expected, let actual):
            return "Biometric payload length mismatch (expected \(expected), got \(actual))."
        case .checksumMismatch(let expected, let actual):
            return String(format: "FNV-1a 64-bit checksum mismatch (expected %016llx, got %016llx).", expected, actual)
        }
    }
}

public enum BiometricWireCodec: Sendable {
    /// 18-byte binary header:
    /// [0..3]   Magic "ABIO" (0x41, 0x42, 0x49, 0x4F)
    /// [4]      Version (0x01)
    /// [5]      Flags (0x00)
    /// [6..9]   Big-endian UInt32 payload length
    /// [10..17] Big-endian UInt64 FNV-1a checksum over header[0..9] + payload
    public static let headerByteLength: Int = 18
    public static let protocolVersion: UInt8 = 0x01
    private static let magicBytes: [UInt8] = [0x41, 0x42, 0x49, 0x4F]
    private static let fnvOffsetBasis: UInt64 = 0xCBF2_9CE4_8422_2325
    private static let fnvPrime: UInt64 = 0x0000_0100_0000_01B3

    public static func fnv1a64(prefix: [UInt8], payload: Data) -> UInt64 {
        var hash = fnvOffsetBasis
        for b in prefix {
            hash ^= UInt64(b)
            hash &*= fnvPrime
        }
        for b in payload {
            hash ^= UInt64(b)
            hash &*= fnvPrime
        }
        return hash
    }

    public static func encode(_ snapshot: BiometricSnapshotDTO) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let payload = try encoder.encode(snapshot)
        let len = UInt32(payload.count)

        var prefix: [UInt8] = []
        prefix.reserveCapacity(10)
        prefix.append(contentsOf: magicBytes)
        prefix.append(protocolVersion)
        prefix.append(0x00)
        prefix.append(UInt8((len >> 24) & 0xFF))
        prefix.append(UInt8((len >> 16) & 0xFF))
        prefix.append(UInt8((len >> 8) & 0xFF))
        prefix.append(UInt8(len & 0xFF))

        let checksum = fnv1a64(prefix: prefix, payload: payload)

        var packet = Data()
        packet.reserveCapacity(headerByteLength + payload.count)
        packet.append(contentsOf: prefix)
        for shift in stride(from: 56, through: 0, by: -8) {
            packet.append(UInt8((checksum >> UInt64(shift)) & 0xFF))
        }
        packet.append(payload)
        return packet
    }

    public static func decode(_ data: Data) throws -> BiometricSnapshotDTO {
        guard data.count >= headerByteLength else {
            throw BiometricWireCodecError.frameTooShort(data.count)
        }

        let header = [UInt8](data.prefix(headerByteLength))
        guard header[0] == magicBytes[0],
              header[1] == magicBytes[1],
              header[2] == magicBytes[2],
              header[3] == magicBytes[3] else {
            throw BiometricWireCodecError.invalidMagicHeader
        }

        let version = header[4]
        guard version == protocolVersion else {
            throw BiometricWireCodecError.unsupportedVersion(version)
        }

        let expectedLen = Int(
            (UInt32(header[6]) << 24) |
            (UInt32(header[7]) << 16) |
            (UInt32(header[8]) << 8) |
            UInt32(header[9])
        )
        let actualLen = data.count - headerByteLength
        guard expectedLen == actualLen else {
            throw BiometricWireCodecError.payloadLengthMismatch(expected: expectedLen, actual: actualLen)
        }

        var expectedHash: UInt64 = 0
        for idx in 10..<18 {
            expectedHash = (expectedHash << 8) | UInt64(header[idx])
        }

        let prefix = Array(header[0..<10])
        let payload = data.subdata(in: headerByteLength..<data.count)
        let actualHash = fnv1a64(prefix: prefix, payload: payload)
        guard expectedHash == actualHash else {
            throw BiometricWireCodecError.checksumMismatch(expected: expectedHash, actual: actualHash)
        }

        let decoder = PropertyListDecoder()
        return try decoder.decode(BiometricSnapshotDTO.self, from: payload)
    }
}

// MARK: - 2. Multi-Route Watch Envelope & Remote Command Payloads

public enum WatchRemoteCommand: Codable, Sendable, Equatable {
    case startFocusSession
    case pauseFocusSession
    case scrubBinauralFreq(Float)
    case logQuickHabitPulse(UUID, Int)
    case triggerHarmonicBloom

    private enum CodingKeys: String, CodingKey {
        case kind
        case frequencyHz
        case habitID
        case minutes
    }

    private enum Kind: UInt8, Codable {
        case startFocusSession = 1
        case pauseFocusSession = 2
        case scrubBinauralFreq = 3
        case logQuickHabitPulse = 4
        case triggerHarmonicBloom = 5
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .startFocusSession:
            try container.encode(Kind.startFocusSession, forKey: .kind)
        case .pauseFocusSession:
            try container.encode(Kind.pauseFocusSession, forKey: .kind)
        case .scrubBinauralFreq(let hz):
            try container.encode(Kind.scrubBinauralFreq, forKey: .kind)
            try container.encode(hz, forKey: .frequencyHz)
        case .logQuickHabitPulse(let id, let mins):
            try container.encode(Kind.logQuickHabitPulse, forKey: .kind)
            try container.encode(id, forKey: .habitID)
            try container.encode(mins, forKey: .minutes)
        case .triggerHarmonicBloom:
            try container.encode(Kind.triggerHarmonicBloom, forKey: .kind)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .startFocusSession:
            self = .startFocusSession
        case .pauseFocusSession:
            self = .pauseFocusSession
        case .scrubBinauralFreq:
            self = .scrubBinauralFreq(try container.decode(Float.self, forKey: .frequencyHz))
        case .logQuickHabitPulse:
            self = .logQuickHabitPulse(
                try container.decode(UUID.self, forKey: .habitID),
                try container.decode(Int.self, forKey: .minutes)
            )
        case .triggerHarmonicBloom:
            self = .triggerHarmonicBloom
        }
    }
}

public enum WatchBridgePayload: Codable, Sendable, Equatable {
    case biometricTelemetry(snapshot: BiometricSnapshotDTO, metrics: HRVAnalysisMetricsDTO)
    case remoteCommand(WatchRemoteCommand)
    case stateSnapshotSync(SharedWidgetSnapshot)

    public var packetTagByte: UInt8 {
        switch self {
        case .biometricTelemetry: return 0x01
        case .remoteCommand: return 0x02
        case .stateSnapshotSync: return 0x03
        }
    }
}

public struct WatchBridgeEnvelope: Codable, Sendable, Equatable {
    public let sequenceID: UInt64
    public let sentAt: Date
    public let payload: WatchBridgePayload

    public init(sequenceID: UInt64, sentAt: Date = .now, payload: WatchBridgePayload) {
        self.sequenceID = sequenceID
        self.sentAt = sentAt
        self.payload = payload
    }
}

public enum WatchBridgeCodecError: LocalizedError, Sendable, Equatable {
    case frameTooShort(Int)
    case invalidMagicHeader
    case unsupportedProtocolVersion(UInt8)
    case payloadLengthMismatch(expected: Int, actual: Int)
    case checksumMismatch(expected: UInt64, actual: UInt64)

    public var errorDescription: String? {
        switch self {
        case .frameTooShort(let count):
            return "Binary bridge frame too short (\(count) bytes)."
        case .invalidMagicHeader:
            return "Invalid ASWB binary frame magic header."
        case .unsupportedProtocolVersion(let version):
            return "Unsupported WatchBridge wire protocol version \(version)."
        case .payloadLengthMismatch(let expected, let actual):
            return "Payload length mismatch (expected \(expected), got \(actual))."
        case .checksumMismatch(let expected, let actual):
            return String(format: "FNV-1a 64-bit checksum mismatch (expected %016llx, got %016llx).", expected, actual)
        }
    }
}

public enum WatchBridgeWireCodec: Sendable {
    public static let headerByteLength: Int = 18
    public static let protocolVersion: UInt8 = 0x01
    private static let magicBytes: [UInt8] = [0x41, 0x53, 0x57, 0x42]

    public static func computeFNV1a64(headerPrefix: [UInt8], payload: Data) -> UInt64 {
        BiometricWireCodec.fnv1a64(prefix: headerPrefix, payload: payload)
    }

    public static func encodeFrame(_ envelope: WatchBridgeEnvelope) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let payloadData = try encoder.encode(envelope)
        let lengthUInt32 = UInt32(payloadData.count)

        var prefix: [UInt8] = []
        prefix.reserveCapacity(10)
        prefix.append(contentsOf: magicBytes)
        prefix.append(protocolVersion)
        prefix.append(envelope.payload.packetTagByte)
        prefix.append(UInt8((lengthUInt32 >> 24) & 0xFF))
        prefix.append(UInt8((lengthUInt32 >> 16) & 0xFF))
        prefix.append(UInt8((lengthUInt32 >> 8) & 0xFF))
        prefix.append(UInt8(lengthUInt32 & 0xFF))

        let checksum = computeFNV1a64(headerPrefix: prefix, payload: payloadData)

        var frame = Data()
        frame.reserveCapacity(headerByteLength + payloadData.count)
        frame.append(contentsOf: prefix)
        for shift in stride(from: 56, through: 0, by: -8) {
            frame.append(UInt8((checksum >> UInt64(shift)) & 0xFF))
        }
        frame.append(payloadData)
        return frame
    }

    public static func decodeFrame(_ frameData: Data) throws -> WatchBridgeEnvelope {
        guard frameData.count >= headerByteLength else {
            throw WatchBridgeCodecError.frameTooShort(frameData.count)
        }

        let bytes = [UInt8](frameData.prefix(headerByteLength))
        guard bytes[0] == magicBytes[0],
              bytes[1] == magicBytes[1],
              bytes[2] == magicBytes[2],
              bytes[3] == magicBytes[3] else {
            throw WatchBridgeCodecError.invalidMagicHeader
        }

        let version = bytes[4]
        guard version == protocolVersion else {
            throw WatchBridgeCodecError.unsupportedProtocolVersion(version)
        }

        let expectedLength = Int(
            (UInt32(bytes[6]) << 24) |
            (UInt32(bytes[7]) << 16) |
            (UInt32(bytes[8]) << 8) |
            UInt32(bytes[9])
        )
        let actualPayloadLength = frameData.count - headerByteLength
        guard expectedLength == actualPayloadLength else {
            throw WatchBridgeCodecError.payloadLengthMismatch(expected: expectedLength, actual: actualPayloadLength)
        }

        var expectedChecksum: UInt64 = 0
        for idx in 10..<18 {
            expectedChecksum = (expectedChecksum << 8) | UInt64(bytes[idx])
        }

        let prefix = Array(bytes[0..<10])
        let payloadSlice = frameData.subdata(in: headerByteLength..<frameData.count)
        let actualChecksum = computeFNV1a64(headerPrefix: prefix, payload: payloadSlice)

        guard expectedChecksum == actualChecksum else {
            throw WatchBridgeCodecError.checksumMismatch(expected: expectedChecksum, actual: actualChecksum)
        }

        let decoder = PropertyListDecoder()
        return try decoder.decode(WatchBridgeEnvelope.self, from: payloadSlice)
    }
}

// MARK: - 3. Coupled-Oscillator Synthetic Physiology Simulator

public struct SyntheticPhysiologySimulator: Sendable {
    public var baselineHeartRateBPM: Double
    public var amplitudeMs: Double
    public var respiratoryHz: Double
    public var rsaAmplitudeMs: Double

    public private(set) var simulationTimeSeconds: Double = 0.0
    public private(set) var vagalParasympatheticTone: Double
    public private(set) var sympatheticArousal: Double
    public private(set) var wristTemperatureDeltaCelsius: Double = 0.04
    public private(set) var activeEnergyKilocalories: Double = 0.0

    private var respiratoryPhase: Double = 0.0
    private var mayerBaroreflexPhase: Double = 0.0
    private var nextBeatAccumulatedTime: Double = 0.0
    private var rngState: UInt64
    private var rollingRRSamples: [RRIntervalSampleDTO] = []
    private let anchorDate: Date

    public init(
        baselineHeartRateBPM: Double = 68.0,
        amplitudeMs: Double = 34.0,
        respiratoryHz: Double = 0.22,
        rsaAmplitudeMs: Double = 26.0,
        seed: UInt64 = 0xCAFE_BEEF_2026_1107
    ) {
        self.baselineHeartRateBPM = min(max(baselineHeartRateBPM, 42.0), 150.0)
        self.amplitudeMs = max(0.0, amplitudeMs)
        self.respiratoryHz = min(max(respiratoryHz, 0.06), 0.45)
        self.rsaAmplitudeMs = max(0.0, rsaAmplitudeMs)
        self.vagalParasympatheticTone = 0.65
        self.sympatheticArousal = 0.32
        self.rngState = seed == 0 ? 0xCAFE_BEEF_2026_1107 : seed
        self.anchorDate = Date(timeIntervalSince1970: 1_762_500_000)
    }

    public init(
        initialStressLevel: Double,
        seed: UInt64 = 0xCAFE_BEEF_2026_1107,
        anchorDate: Date = Date(timeIntervalSince1970: 1_762_500_000)
    ) {
        let clampedStress = min(max(initialStressLevel, 0.05), 0.95)
        let vagal = min(max(1.0 - clampedStress * 0.82, 0.12), 0.92)
        self.sympatheticArousal = clampedStress
        self.vagalParasympatheticTone = vagal
        self.respiratoryHz = 0.10 + clampedStress * 0.14
        self.baselineHeartRateBPM = 62.0 + clampedStress * 26.0
        self.amplitudeMs = 10.0 + 34.0 * vagal
        self.rsaAmplitudeMs = 14.0 + 52.0 * vagal
        self.rngState = seed == 0 ? 0xCAFE_BEEF_2026_1107 : seed
        self.anchorDate = anchorDate
    }

    public var respiratoryFrequencyHz: Double {
        respiratoryHz
    }

    /// Generates a physiological beat-to-beat RR tachogram window combining baseline HR,
    /// 0.10 Hz Mayer baroreflex wave (`amplitudeMs`), and respiratory sinus arrhythmia (`respiratoryHz`, `rsaAmplitudeMs`).
    public mutating func generateWindow(
        durationSeconds: Double,
        startTimestamp: TimeInterval = 0.0
    ) -> [RRIntervalSampleDTO] {
        let span = max(2.0, durationSeconds)
        let baseRRMs = 60_000.0 / max(40.0, baselineHeartRateBPM)
        let endTime = startTimestamp + span

        var currentT = startTimestamp
        var samples: [RRIntervalSampleDTO] = []
        samples.reserveCapacity(Int(span * 1.6) + 4)

        while currentT < endTime {
            let mayerMod = amplitudeMs * sin(2.0 * Double.pi * 0.10 * currentT + mayerBaroreflexPhase)
            let rsaMod = rsaAmplitudeMs * sin(2.0 * Double.pi * respiratoryHz * currentT + respiratoryPhase)
            let jitterMs = nextSymmetricNoise() * 3.5

            let rrMs = min(max(baseRRMs + mayerMod + rsaMod + jitterMs, 340.0), 1_850.0)
            let stepSec = rrMs / 1_000.0
            currentT += stepSec

            samples.append(
                RRIntervalSampleDTO(
                    timestamp: currentT,
                    rrMilliseconds: rrMs
                )
            )
        }

        mayerBaroreflexPhase = (mayerBaroreflexPhase + 0.10 * span).truncatingRemainder(dividingBy: 1.0)
        respiratoryPhase = (respiratoryPhase + respiratoryHz * span).truncatingRemainder(dividingBy: 1.0)
        simulationTimeSeconds += span
        return samples
    }

    public static func synthesizePQRSTMillivolts(cardiacPhase rawPhase: Double) -> Double {
        let phase = rawPhase - floor(rawPhase)
        func gaussian(_ center: Double, _ width: Double, _ amp: Double) -> Double {
            let d = (phase - center) / width
            return amp * exp(-0.5 * d * d)
        }
        return gaussian(0.18, 0.028, 0.16)
            + gaussian(0.30, 0.010, -0.14)
            + gaussian(0.33, 0.012, 1.22)
            + gaussian(0.36, 0.012, -0.26)
            + gaussian(0.58, 0.045, 0.30)
    }

    public mutating func advance(
        dtSeconds: Double,
        activeBinauralBeatHz: Float
    ) -> (snapshot: BiometricSnapshotDTO, metrics: HRVAnalysisMetricsDTO) {
        let dt = max(0.05, min(dtSeconds, 15.0))
        let beatHz = Double(activeBinauralBeatHz)

        let alphaThetaResonance = exp(-pow((beatHz - 8.2) / 5.8, 2.0))
        let highBetaDrive = beatHz > 20.0 ? min(1.0, (beatHz - 20.0) / 20.0) : 0.0

        let targetVagal = min(max(0.24 + 0.72 * alphaThetaResonance - 0.18 * highBetaDrive, 0.12), 0.96)
        let targetSympathetic = min(max(0.72 - 0.62 * alphaThetaResonance + 0.22 * highBetaDrive, 0.06), 0.90)
        let targetRespHz = 0.10 + (1.0 - alphaThetaResonance) * 0.13

        let relaxAlpha = 1.0 - exp(-dt / 9.5)
        vagalParasympatheticTone += (targetVagal - vagalParasympatheticTone) * relaxAlpha
        sympatheticArousal += (targetSympathetic - sympatheticArousal) * relaxAlpha
        respiratoryHz += (targetRespHz - respiratoryHz) * relaxAlpha
        amplitudeMs = 8.0 + 34.0 * vagalParasympatheticTone
        rsaAmplitudeMs = 14.0 + 56.0 * vagalParasympatheticTone

        let endSimTime = simulationTimeSeconds + dt
        while nextBeatAccumulatedTime <= endSimTime {
            let t = nextBeatAccumulatedTime
            let rsaMod = rsaAmplitudeMs * sin(2.0 * Double.pi * respiratoryPhase)
            let mayerMod = amplitudeMs * sin(2.0 * Double.pi * mayerBaroreflexPhase)
            let jitterMs = (nextSymmetricNoise() * 14.0) * sympatheticArousal
            let baselineRRMs = 945.0 - 255.0 * sympatheticArousal + 35.0 * vagalParasympatheticTone
            let rrMs = min(max(baselineRRMs + rsaMod + mayerMod + jitterMs, 420.0), 1_450.0)

            let beatEpoch = anchorDate.addingTimeInterval(t).timeIntervalSince1970
            rollingRRSamples.append(RRIntervalSampleDTO(timestamp: beatEpoch, rrMilliseconds: rrMs))

            let stepSec = rrMs / 1_000.0
            respiratoryPhase = (respiratoryPhase + respiratoryHz * stepSec).truncatingRemainder(dividingBy: 1.0)
            mayerBaroreflexPhase = (mayerBaroreflexPhase + 0.10 * stepSec).truncatingRemainder(dividingBy: 1.0)
            nextBeatAccumulatedTime += stepSec
        }

        simulationTimeSeconds = endSimTime
        wristTemperatureDeltaCelsius = 0.02 + 0.28 * vagalParasympatheticTone - 0.10 * sympatheticArousal
        activeEnergyKilocalories += (dt / 60.0) * (1.15 + 0.65 * sympatheticArousal)

        let cutoffEpoch = anchorDate.addingTimeInterval(max(0.0, simulationTimeSeconds - 65.0)).timeIntervalSince1970
        if rollingRRSamples.count > 12 {
            rollingRRSamples.removeAll { $0.timestamp < cutoffEpoch }
        }

        let currentDate = anchorDate.addingTimeInterval(simulationTimeSeconds)
        let metrics = HRVBiometricAnalyzer.analyze(samples: rollingRRSamples)
        let instantBPM = rollingRRSamples.last?.instantaneousBPM ?? metrics.heartRateBPM

        let snapshot = BiometricSnapshotDTO(
            capturedAt: currentDate,
            heartRateBPM: instantBPM,
            respiratoryRateBrPM: respiratoryHz * 60.0,
            wristTemperatureDeltaCelsius: wristTemperatureDeltaCelsius,
            activeEnergyBurnedKilocalories: activeEnergyKilocalories,
            rrIntervals: rollingRRSamples
        )
        return (snapshot, metrics)
    }

    @inline(__always)
    private mutating func nextSymmetricNoise() -> Double {
        rngState &+= 0x9E37_79B9_7F4A_7C15
        var z = rngState
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z = z ^ (z >> 31)
        let unit = Double(z >> 11) * (1.0 / 9_007_199_254_740_992.0)
        return unit * 2.0 - 1.0
    }
}

// MARK: - 4. WatchConnectivity Low-Latency Bridge Actor

public enum WatchTransportRoute: String, Sendable, Equatable {
    case liveMessageData
    case applicationContextFallback
    case userInfoQueueFallback
    case localLoopbackOnly
}

public actor WatchBiometricBridgeActor {
    public static let contextFrameKey = "aether_latest_frame_v1"
    public static let contextSnapshotKey = "aether_latest_biometric_snapshot_v1"
    public static let ackPayload = Data([0x41, 0x43, 0x4B, 0x01])

    private var nextSequenceID: UInt64 = 1
    private var isActivatedFlag: Bool = false
    private var isReachableFlag: Bool = false
    private var receivedPacketCount: Int = 0
    private var cachedLatestSnapshot: BiometricSnapshotDTO?
    private var hasReceivedLiveSnapshot: Bool = false
    private var fallbackSimulator = SyntheticPhysiologySimulator()

    private var onTelemetryReceived: (@Sendable (BiometricSnapshotDTO, HRVAnalysisMetricsDTO) async -> Void)?
    private var onRemoteCommandReceived: (@Sendable (WatchRemoteCommand) async -> Void)?
    private var onStateSyncReceived: (@Sendable (SharedWidgetSnapshot) async -> Void)?
    private var onReachabilityChanged: (@Sendable (Bool) async -> Void)?

    #if canImport(WatchConnectivity) && (os(iOS) || os(watchOS))
    private var sessionRelay: WCSessionDelegateRelay?
    #endif

    public init() {}

    public func activateBridge() {
        #if canImport(WatchConnectivity) && (os(iOS) || os(watchOS))
        guard WCSession.isSupported() else { return }
        if sessionRelay == nil {
            let relay = WCSessionDelegateRelay(owner: self)
            sessionRelay = relay
            let session = WCSession.default
            session.delegate = relay
            session.activate()
            isActivatedFlag = true
            isReachableFlag = session.isReachable
        }
        #else
        isActivatedFlag = true
        #endif
    }

    public func activateSessionIfSupported() {
        activateBridge()
    }

    public func latestSnapshot() -> BiometricSnapshotDTO? {
        cachedLatestSnapshot
    }

    public func sendSnapshot(_ snapshot: BiometricSnapshotDTO) throws {
        let encoded = try BiometricWireCodec.encode(snapshot)
        cachedLatestSnapshot = snapshot
        #if canImport(WatchConnectivity) && (os(iOS) || os(watchOS))
        _ = Self.dispatchRawDataOverWCSession(
            data: encoded,
            contextKey: Self.contextSnapshotKey,
            guaranteeDeliveryQueue: false
        )
        #else
        _ = encoded
        #endif
    }

    public func sampleSimulatedOrLiveSnapshot(coherenceDrive: Double) -> BiometricSnapshotDTO {
        if hasReceivedLiveSnapshot, let live = cachedLatestSnapshot {
            return live
        }

        let clampedDrive = min(max(coherenceDrive, 0.0), 1.0)
        fallbackSimulator.baselineHeartRateBPM = 76.0 - 14.0 * clampedDrive
        fallbackSimulator.amplitudeMs = 12.0 + 42.0 * clampedDrive
        fallbackSimulator.respiratoryHz = 0.24 - 0.14 * clampedDrive
        fallbackSimulator.rsaAmplitudeMs = 14.0 + 36.0 * clampedDrive

        let startT = fallbackSimulator.simulationTimeSeconds
        let window = fallbackSimulator.generateWindow(durationSeconds: 64.0, startTimestamp: startT)
        let metrics = HRVBiometricAnalyzer.analyze(samples: window)
        let snapshot = BiometricSnapshotDTO(
            timestamp: .now,
            recentRRSamples: window,
            metrics: metrics,
            respiratoryRateBrPM: fallbackSimulator.respiratoryHz * 60.0
        )
        cachedLatestSnapshot = snapshot
        return snapshot
    }

    public func setHandlers(
        onTelemetry: (@Sendable (BiometricSnapshotDTO, HRVAnalysisMetricsDTO) async -> Void)? = nil,
        onCommand: (@Sendable (WatchRemoteCommand) async -> Void)? = nil,
        onStateSync: (@Sendable (SharedWidgetSnapshot) async -> Void)? = nil,
        onReachability: (@Sendable (Bool) async -> Void)? = nil
    ) {
        self.onTelemetryReceived = onTelemetry
        self.onRemoteCommandReceived = onCommand
        self.onStateSyncReceived = onStateSync
        self.onReachabilityChanged = onReachability
    }

    public var isCounterpartReachable: Bool {
        isReachableFlag
    }

    public var totalReceivedPackets: Int {
        receivedPacketCount
    }

    @discardableResult
    public func sendBiometricTelemetry(
        snapshot: BiometricSnapshotDTO,
        metrics: HRVAnalysisMetricsDTO
    ) throws -> WatchTransportRoute {
        cachedLatestSnapshot = snapshot
        return try transmitPayload(.biometricTelemetry(snapshot: snapshot, metrics: metrics), guaranteeDeliveryQueue: false)
    }

    @discardableResult
    public func sendRemoteCommand(_ command: WatchRemoteCommand) throws -> WatchTransportRoute {
        try transmitPayload(.remoteCommand(command), guaranteeDeliveryQueue: true)
    }

    @discardableResult
    public func sendStateSnapshotSync(_ state: SharedWidgetSnapshot) throws -> WatchTransportRoute {
        try transmitPayload(.stateSnapshotSync(state), guaranteeDeliveryQueue: false)
    }

    private func transmitPayload(
        _ payload: WatchBridgePayload,
        guaranteeDeliveryQueue: Bool
    ) throws -> WatchTransportRoute {
        let seq = nextSequenceID
        nextSequenceID &+= 1
        let envelope = WatchBridgeEnvelope(sequenceID: seq, sentAt: .now, payload: payload)
        let frameData = try WatchBridgeWireCodec.encodeFrame(envelope)

        #if canImport(WatchConnectivity) && (os(iOS) || os(watchOS))
        return Self.dispatchRawDataOverWCSession(
            data: frameData,
            contextKey: Self.contextFrameKey,
            guaranteeDeliveryQueue: guaranteeDeliveryQueue
        )
        #else
        _ = frameData
        _ = guaranteeDeliveryQueue
        return .localLoopbackOnly
        #endif
    }

    #if canImport(WatchConnectivity) && (os(iOS) || os(watchOS))
    nonisolated private static func dispatchRawDataOverWCSession(
        data: Data,
        contextKey: String,
        guaranteeDeliveryQueue: Bool
    ) -> WatchTransportRoute {
        guard WCSession.isSupported() else {
            return .localLoopbackOnly
        }
        let session = WCSession.default
        guard session.activationState == .activated else {
            return .localLoopbackOnly
        }

        if session.isReachable {
            session.sendMessageData(
                data,
                replyHandler: nil,
                errorHandler: { _ in
                    let fallback = WCSession.default
                    try? fallback.updateApplicationContext([contextKey: data])
                    if guaranteeDeliveryQueue {
                        fallback.transferUserInfo([contextKey: data])
                    }
                }
            )
            return .liveMessageData
        } else {
            try? session.updateApplicationContext([contextKey: data])
            if guaranteeDeliveryQueue {
                session.transferUserInfo([contextKey: data])
                return .userInfoQueueFallback
            }
            return .applicationContextFallback
        }
    }
    #endif

    public func ingestIncomingFrameData(_ frameData: Data) async throws {
        if frameData.count >= 4 {
            let magic = [UInt8](frameData.prefix(4))
            if magic == [0x41, 0x42, 0x49, 0x4F] {
                let snapshot = try BiometricWireCodec.decode(frameData)
                receivedPacketCount += 1
                cachedLatestSnapshot = snapshot
                hasReceivedLiveSnapshot = true
                await onTelemetryReceived?(snapshot, snapshot.metrics)
                return
            }
        }

        let envelope = try WatchBridgeWireCodec.decodeFrame(frameData)
        receivedPacketCount += 1

        switch envelope.payload {
        case .biometricTelemetry(let snapshot, let metrics):
            cachedLatestSnapshot = snapshot
            hasReceivedLiveSnapshot = true
            await onTelemetryReceived?(snapshot, metrics)
        case .remoteCommand(let command):
            await onRemoteCommandReceived?(command)
        case .stateSnapshotSync(let state):
            await onStateSyncReceived?(state)
        }
    }

    fileprivate func updateActivationAndReachability(activated: Bool, reachable: Bool) async {
        self.isActivatedFlag = activated
        let changed = (self.isReachableFlag != reachable)
        self.isReachableFlag = reachable
        if changed {
            await onReachabilityChanged?(reachable)
        }
    }
}

#if canImport(WatchConnectivity) && (os(iOS) || os(watchOS))
private final class WCSessionDelegateRelay: NSObject, WCSessionDelegate, @unchecked Sendable {
    private let owner: WatchBiometricBridgeActor

    init(owner: WatchBiometricBridgeActor) {
        self.owner = owner
        super.init()
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        _ = error
        let isActivated = (activationState == .activated)
        let reachable = isActivated ? session.isReachable : false
        let contextFrame = session.receivedApplicationContext[WatchBiometricBridgeActor.contextFrameKey] as? Data
        let contextSnap = session.receivedApplicationContext[WatchBiometricBridgeActor.contextSnapshotKey] as? Data
        Task {
            await owner.updateActivationAndReachability(activated: isActivated, reachable: reachable)
            if let contextSnap {
                try? await owner.ingestIncomingFrameData(contextSnap)
            }
            if let contextFrame {
                try? await owner.ingestIncomingFrameData(contextFrame)
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let activated = (session.activationState == .activated)
        let reachable = session.isReachable
        Task {
            await owner.updateActivationAndReachability(activated: activated, reachable: reachable)
        }
    }

    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
    #endif

    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        Task {
            try? await owner.ingestIncomingFrameData(messageData)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessageData messageData: Data,
        replyHandler: @escaping (Data) -> Void
    ) {
        replyHandler(WatchBiometricBridgeActor.ackPayload)
        Task {
            try? await owner.ingestIncomingFrameData(messageData)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let snapData = applicationContext[WatchBiometricBridgeActor.contextSnapshotKey] as? Data
        let frameData = applicationContext[WatchBiometricBridgeActor.contextFrameKey] as? Data
        Task {
            if let snapData {
                try? await owner.ingestIncomingFrameData(snapData)
            }
            if let frameData {
                try? await owner.ingestIncomingFrameData(frameData)
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        let snapData = userInfo[WatchBiometricBridgeActor.contextSnapshotKey] as? Data
        let frameData = userInfo[WatchBiometricBridgeActor.contextFrameKey] as? Data
        Task {
            if let snapData {
                try? await owner.ingestIncomingFrameData(snapData)
            }
            if let frameData {
                try? await owner.ingestIncomingFrameData(frameData)
            }
        }
    }
}
#endif
