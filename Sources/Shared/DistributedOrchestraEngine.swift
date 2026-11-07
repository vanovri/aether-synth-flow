// MARK: - FILE: DistributedOrchestraEngine.swift

import Foundation
import simd
import Synchronization
#if canImport(Darwin)
import Darwin
#endif

// MARK: - 1. Monotonic Nanosecond Hardware Clock & 64-Byte 4-Timestamp PTP/NTP Wire Protocol

/// Monotonic hardware nanosecond clock unaffected by NTP/wall-clock jumps.
/// Uses `mach_continuous_time()` scaled via 128-bit overflow-safe `mach_timebase_info` arithmetic on Darwin.
public enum MonotonicHardwareClock: Sendable {
    #if canImport(Darwin)
    private static let timebaseNumer: UInt64 = {
        var info = mach_timebase_info_data_t(numer: 1, denom: 1)
        mach_timebase_info(&info)
        return UInt64(max(1, info.numer))
    }()

    private static let timebaseDenom: UInt64 = {
        var info = mach_timebase_info_data_t(numer: 1, denom: 1)
        mach_timebase_info(&info)
        return UInt64(max(1, info.denom))
    }()
    #else
    private static let bootAnchor: ContinuousClock.Instant = ContinuousClock.now
    #endif

    @inline(__always)
    public static func nowNanoseconds() -> UInt64 {
        #if canImport(Darwin)
        let ticks = mach_continuous_time()
        if timebaseNumer == timebaseDenom {
            return ticks
        }
        let product = ticks.multipliedFullWidth(by: timebaseNumer)
        let quotient = timebaseDenom.dividingFullWidth(product).quotient
        return quotient
        #else
        let elapsed = ContinuousClock.now - bootAnchor
        let comps = elapsed.components
        let secsNs = UInt64(max(0, comps.seconds)) &* 1_000_000_000
        let attoNs = UInt64(max(0, comps.attoseconds) / 1_000_000_000)
        return secsNs &+ attoNs
        #endif
    }

    @inline(__always)
    public static func nanosecondsToSeconds(_ nanoseconds: Double) -> Double {
        nanoseconds * 1.0e-9
    }

    @inline(__always)
    public static func secondsToNanoseconds(_ seconds: Double) -> Double {
        seconds * 1.0e9
    }
}

public enum OrchestraPTPPacketKind: UInt8, Codable, Sendable {
    case syncRequest = 0
    case delayResponse = 1
    case conductorBeacon = 2
}

public enum OrchestraWireProtocolError: LocalizedError, Sendable, Equatable {
    case invalidByteLength(expected: Int, actual: Int)
    case invalidMagicHeader(UInt16)
    case unsupportedProtocolVersion(UInt8)
    case unknownPacketKind(UInt8)
    case integrityTagMismatch(expected: UInt64, actual: UInt64)

    public var errorDescription: String? {
        switch self {
        case .invalidByteLength(let expected, let actual):
            return "PTP datagram byte length mismatch: expected \(expected), received \(actual)."
        case .invalidMagicHeader(let magic):
            return String(format: "Invalid PTP datagram magic header 0x%04X.", magic)
        case .unsupportedProtocolVersion(let version):
            return "Unsupported PTP wire protocol version \(version)."
        case .unknownPacketKind(let kind):
            return "Unknown PTP packet kind \(kind)."
        case .integrityTagMismatch(let expected, let actual):
            return String(format: "FNV-1a integrity tag mismatch (expected 0x%016llX, got 0x%016llX).", expected, actual)
        }
    }
}

/// Compact deterministic 64-byte binary PTP/NTP datagram frame protected by a 64-bit FNV-1a integrity tag.
///
/// Exact Wire Layout (64 bytes, Little-Endian IEEE-754 & integer encoding):
/// - `[0..<2]`   `magic` (`0x4145` = `"AE"`)
/// - `[2]`       `protocolVersion` (`1`)
/// - `[3]`       `packetKind` (`0 = syncRequest`, `1 = delayResponse`, `2 = conductorBeacon`)
/// - `[4..<6]`   `sequenceNumber` (`UInt16`)
/// - `[6..<8]`   `peerNodeID` (`UInt16`)
/// - `[8..<16]`  `t1OriginNs` (`UInt64` initiator egress timestamp $t_1$)
/// - `[16..<24]` `t2ResponderIngressNs` (`UInt64` responder ingress timestamp $t_2$)
/// - `[24..<32]` `t3ResponderEgressNs` (`UInt64` responder egress timestamp $t_3$)
/// - `[32..<40]` `t4InitiatorIngressNs` (`UInt64` initiator ingress timestamp $t_4$)
/// - `[40..<44]` `masterBeatPhase` (`Float` $\Phi_{\text{master}} \in [0, 1)$)
/// - `[44..<48]` `tempoBPM` (`Float`)
/// - `[48..<56]` `globalSampleCounter` (`UInt64`)
/// - `[56..<64]` `fnv1aIntegrityTag` (`UInt64` FNV-1a over `[0..<56]`)
public struct OrchestraPTPClockPacket: Sendable, Equatable {
    public static let encodedByteSize: Int = 64
    public static let payloadByteSizeWithoutTag: Int = 56
    public static let magicHeader: UInt16 = 0x4145
    public static let currentProtocolVersion: UInt8 = 1

    private static let fnv64OffsetBasis: UInt64 = 0xCBF2_9CE4_8422_2325
    private static let fnv64Prime: UInt64 = 0x0000_0100_0000_01B3

    public var packetKind: OrchestraPTPPacketKind
    public var sequenceNumber: UInt16
    public var peerNodeID: UInt16
    public var t1OriginNs: UInt64
    public var t2ResponderIngressNs: UInt64
    public var t3ResponderEgressNs: UInt64
    public var t4InitiatorIngressNs: UInt64
    public var masterBeatPhase: Float
    public var tempoBPM: Float
    public var globalSampleCounter: UInt64

    public init(
        packetKind: OrchestraPTPPacketKind = .delayResponse,
        sequenceNumber: UInt16 = 0,
        peerNodeID: UInt16 = 1,
        t1OriginNs: UInt64,
        t2ResponderIngressNs: UInt64,
        t3ResponderEgressNs: UInt64,
        t4InitiatorIngressNs: UInt64,
        masterBeatPhase: Float = 0.0,
        tempoBPM: Float = 120.0,
        globalSampleCounter: UInt64 = 0
    ) {
        self.packetKind = packetKind
        self.sequenceNumber = sequenceNumber
        self.peerNodeID = peerNodeID
        self.t1OriginNs = t1OriginNs
        self.t2ResponderIngressNs = t2ResponderIngressNs
        self.t3ResponderEgressNs = t3ResponderEgressNs
        self.t4InitiatorIngressNs = t4InitiatorIngressNs

        let wrappedPhase = masterBeatPhase.isFinite
            ? (masterBeatPhase - floor(masterBeatPhase))
            : 0.0
        self.masterBeatPhase = min(max(wrappedPhase, 0.0), 0.9999999)
        self.tempoBPM = tempoBPM.isFinite ? min(max(tempoBPM, 20.0), 320.0) : 120.0
        self.globalSampleCounter = globalSampleCounter
    }

    /// Round-trip network propagation delay $\delta = (t_4 - t_1) - (t_3 - t_2)$ in nanoseconds.
    @inline(__always)
    public var roundTripDelayNanoseconds: Double {
        let d41 = Double(t4InitiatorIngressNs) - Double(t1OriginNs)
        let d32 = Double(t3ResponderEgressNs) - Double(t2ResponderIngressNs)
        return max(0.0, d41 - d32)
    }

    /// Round-trip network propagation delay $\delta$ in seconds.
    @inline(__always)
    public var roundTripDelaySeconds: Double {
        roundTripDelayNanoseconds * 1.0e-9
    }

    /// Local-to-master clock offset $\theta = \frac{(t_2 - t_1) + (t_3 - t_4)}{2}$ in nanoseconds.
    /// Positive $\theta > 0$ means Master clock is ahead of Local clock ($T_{\text{master}} = T_{\text{local}} + \theta$).
    @inline(__always)
    public var clockOffsetNanoseconds: Double {
        let legForward = Double(t2ResponderIngressNs) - Double(t1OriginNs)
        let legReverse = Double(t3ResponderEgressNs) - Double(t4InitiatorIngressNs)
        return 0.5 * (legForward + legReverse)
    }

    /// Local-to-master clock offset $\theta$ in seconds.
    @inline(__always)
    public var clockOffsetSeconds: Double {
        clockOffsetNanoseconds * 1.0e-9
    }

    /// Confidence interval $[\theta - \delta/2, \theta + \delta/2]$ in seconds.
    @inline(__always)
    public var confidenceIntervalSeconds: (low: Double, high: Double) {
        let theta = clockOffsetSeconds
        let halfDelta = 0.5 * roundTripDelaySeconds
        return (theta - halfDelta, theta + halfDelta)
    }

    @inline(__always)
    public static func computeFNV1a64(_ bytes: UnsafeRawBufferPointer, count: Int) -> UInt64 {
        var hash = fnv64OffsetBasis
        let safeCount = min(count, bytes.count)
        for i in 0..<safeCount {
            hash ^= UInt64(bytes[i])
            hash &*= fnv64Prime
        }
        return hash
    }

    /// Encodes the packet into an exact 64-byte raw buffer with zero heap allocations.
    @inline(__always)
    public func encodeInto(_ buffer: UnsafeMutableRawBufferPointer) {
        precondition(buffer.count >= Self.encodedByteSize, "PTP buffer must be at least 64 bytes.")

        @inline(__always)
        func storeU16(_ offset: Int, _ v: UInt16) {
            let le = v.littleEndian
            withUnsafeBytes(of: le) { src in
                buffer[offset] = src[0]
                buffer[offset + 1] = src[1]
            }
        }

        @inline(__always)
        func storeU32(_ offset: Int, _ v: UInt32) {
            let le = v.littleEndian
            withUnsafeBytes(of: le) { src in
                for k in 0..<4 { buffer[offset + k] = src[k] }
            }
        }

        @inline(__always)
        func storeU64(_ offset: Int, _ v: UInt64) {
            let le = v.littleEndian
            withUnsafeBytes(of: le) { src in
                for k in 0..<8 { buffer[offset + k] = src[k] }
            }
        }

        storeU16(0, Self.magicHeader)
        buffer[2] = Self.currentProtocolVersion
        buffer[3] = packetKind.rawValue
        storeU16(4, sequenceNumber)
        storeU16(6, peerNodeID)
        storeU64(8, t1OriginNs)
        storeU64(16, t2ResponderIngressNs)
        storeU64(24, t3ResponderEgressNs)
        storeU64(32, t4InitiatorIngressNs)
        storeU32(40, masterBeatPhase.bitPattern)
        storeU32(44, tempoBPM.bitPattern)
        storeU64(48, globalSampleCounter)

        let rawRead = UnsafeRawBufferPointer(buffer)
        let tag = Self.computeFNV1a64(rawRead, count: Self.payloadByteSizeWithoutTag)
        storeU64(56, tag)
    }

    /// Encodes into a 64-byte Foundation `Data` payload for UDP / Network.framework transmission.
    public func encode() -> Data {
        var data = Data(count: Self.encodedByteSize)
        data.withUnsafeMutableBytes { rawBuf in
            encodeInto(rawBuf)
        }
        return data
    }

    /// Decodes and validates a 64-byte binary datagram including its 64-bit FNV-1a integrity tag.
    public static func decode(from data: Data) throws -> OrchestraPTPClockPacket {
        try data.withUnsafeBytes { rawBuf in
            try decode(from: rawBuf)
        }
    }

    public static func decode(from buffer: UnsafeRawBufferPointer) throws -> OrchestraPTPClockPacket {
        guard buffer.count == encodedByteSize else {
            throw OrchestraWireProtocolError.invalidByteLength(expected: encodedByteSize, actual: buffer.count)
        }

        @inline(__always)
        func loadU16(_ offset: Int) -> UInt16 {
            UInt16(buffer[offset]) | (UInt16(buffer[offset + 1]) << 8)
        }

        @inline(__always)
        func loadU32(_ offset: Int) -> UInt32 {
            var acc: UInt32 = 0
            for k in 0..<4 {
                acc |= UInt32(buffer[offset + k]) << (k * 8)
            }
            return acc
        }

        @inline(__always)
        func loadU64(_ offset: Int) -> UInt64 {
            var acc: UInt64 = 0
            for k in 0..<8 {
                acc |= UInt64(buffer[offset + k]) << (k * 8)
            }
            return acc
        }

        let magic = loadU16(0)
        guard magic == magicHeader else {
            throw OrchestraWireProtocolError.invalidMagicHeader(magic)
        }

        let version = buffer[2]
        guard version == currentProtocolVersion else {
            throw OrchestraWireProtocolError.unsupportedProtocolVersion(version)
        }

        let rawKind = buffer[3]
        guard let kind = OrchestraPTPPacketKind(rawValue: rawKind) else {
            throw OrchestraWireProtocolError.unknownPacketKind(rawKind)
        }

        let expectedTag = computeFNV1a64(buffer, count: payloadByteSizeWithoutTag)
        let actualTag = loadU64(56)
        guard expectedTag == actualTag else {
            throw OrchestraWireProtocolError.integrityTagMismatch(expected: expectedTag, actual: actualTag)
        }

        return OrchestraPTPClockPacket(
            packetKind: kind,
            sequenceNumber: loadU16(4),
            peerNodeID: loadU16(6),
            t1OriginNs: loadU64(8),
            t2ResponderIngressNs: loadU64(16),
            t3ResponderEgressNs: loadU64(24),
            t4InitiatorIngressNs: loadU64(32),
            masterBeatPhase: Float(bitPattern: loadU32(40)),
            tempoBPM: Float(bitPattern: loadU32(44)),
            globalSampleCounter: loadU64(48)
        )
    }
}

// MARK: - 2. Marzullo's Fault-Tolerant Interval Intersection & Minimum-Delay Filter

public struct PTPExchangeMeasurement: Sendable, Equatable {
    public let offsetSeconds: Double
    public let roundTripDelaySeconds: Double
    public let sampleIntervalTauSeconds: Double

    public init(
        offsetSeconds: Double,
        roundTripDelaySeconds: Double,
        sampleIntervalTauSeconds: Double = 0.10
    ) {
        self.offsetSeconds = offsetSeconds
        self.roundTripDelaySeconds = max(1.0e-9, roundTripDelaySeconds)
        self.sampleIntervalTauSeconds = max(1.0e-4, sampleIntervalTauSeconds)
    }

    public init(packet: OrchestraPTPClockPacket, sampleIntervalTauSeconds: Double = 0.10) {
        self.init(
            offsetSeconds: packet.clockOffsetSeconds,
            roundTripDelaySeconds: packet.roundTripDelaySeconds,
            sampleIntervalTauSeconds: sampleIntervalTauSeconds
        )
    }

    @inline(__always)
    public var lowerBoundSeconds: Double {
        offsetSeconds - 0.5 * roundTripDelaySeconds
    }

    @inline(__always)
    public var upperBoundSeconds: Double {
        offsetSeconds + 0.5 * roundTripDelaySeconds
    }
}

public struct MarzulloConsensusEstimate: Sendable, Equatable {
    public let consensusOffsetSeconds: Double
    public let bestLowSeconds: Double
    public let bestHighSeconds: Double
    public let confidenceRadiusSeconds: Double
    public let minimumDelayOffsetSeconds: Double
    public let minimumRoundTripDelaySeconds: Double
    public let allanDeviation: Double
    public let intersectingCliqueSize: Int
    public let totalWindowSamples: Int
    public let rejectedOutlierCount: Int

    public init(
        consensusOffsetSeconds: Double = 0,
        bestLowSeconds: Double = 0,
        bestHighSeconds: Double = 0,
        confidenceRadiusSeconds: Double = 0,
        minimumDelayOffsetSeconds: Double = 0,
        minimumRoundTripDelaySeconds: Double = 0,
        allanDeviation: Double = 0,
        intersectingCliqueSize: Int = 0,
        totalWindowSamples: Int = 0,
        rejectedOutlierCount: Int = 0
    ) {
        self.consensusOffsetSeconds = consensusOffsetSeconds
        self.bestLowSeconds = bestLowSeconds
        self.bestHighSeconds = bestHighSeconds
        self.confidenceRadiusSeconds = confidenceRadiusSeconds
        self.minimumDelayOffsetSeconds = minimumDelayOffsetSeconds
        self.minimumRoundTripDelaySeconds = minimumRoundTripDelaySeconds
        self.allanDeviation = allanDeviation
        self.intersectingCliqueSize = intersectingCliqueSize
        self.totalWindowSamples = totalWindowSamples
        self.rejectedOutlierCount = rejectedOutlierCount
    }
}

/// Sliding-window ($W = 16$) Marzullo fault-tolerant interval intersection filter with
/// minimum-delay survivor weighting and IEEE Std 1139 overlapping Allan deviation $\sigma_y(\tau)$.
public struct MarzulloClockFilter: Sendable {
    public static let defaultWindowCapacity: Int = 16

    private struct BoundaryEndpoint {
        var bound: Double
        var type: Int // -1 = interval lower bound (enter), +1 = interval upper bound (exit)
    }

    public let windowCapacity: Int
    private var ringBuffer: [PTPExchangeMeasurement]
    private var writeIndex: Int = 0
    private var count: Int = 0
    private var consensusHistory: [Double]
    private var historyWriteIndex: Int = 0
    private var historyCount: Int = 0

    public init(windowCapacity: Int = defaultWindowCapacity) {
        let safeCap = max(2, windowCapacity)
        self.windowCapacity = safeCap
        self.ringBuffer = [PTPExchangeMeasurement](
            repeating: PTPExchangeMeasurement(offsetSeconds: 0, roundTripDelaySeconds: 1.0e-3),
            count: safeCap
        )
        self.consensusHistory = [Double](repeating: 0, count: safeCap)
    }

    public mutating func reset() {
        writeIndex = 0
        count = 0
        historyWriteIndex = 0
        historyCount = 0
    }

    public var sampleCount: Int { count }

    /// Ingests a 4-timestamp PTP packet and returns the updated Marzullo consensus estimate.
    @discardableResult
    public mutating func ingestPacket(
        _ packet: OrchestraPTPClockPacket,
        sampleIntervalTauSeconds: Double = 0.10
    ) -> MarzulloConsensusEstimate {
        ingestMeasurement(
            PTPExchangeMeasurement(
                packet: packet,
                sampleIntervalTauSeconds: sampleIntervalTauSeconds
            )
        )
    }

    /// Ingests a direct $(\theta_i, \delta_i)$ PTP exchange and executes Marzullo's $2W$-endpoint sweep.
    @discardableResult
    public mutating func ingestMeasurement(
        _ measurement: PTPExchangeMeasurement
    ) -> MarzulloConsensusEstimate {
        ringBuffer[writeIndex] = measurement
        writeIndex = (writeIndex + 1) % windowCapacity
        if count < windowCapacity {
            count += 1
        }

        let estimate = computeCurrentConsensus(latestTauSeconds: measurement.sampleIntervalTauSeconds)

        consensusHistory[historyWriteIndex] = estimate.consensusOffsetSeconds
        historyWriteIndex = (historyWriteIndex + 1) % windowCapacity
        if historyCount < windowCapacity {
            historyCount += 1
        }

        if historyCount >= 3 {
            let sigmaY = computeAllanDeviation(tauSeconds: measurement.sampleIntervalTauSeconds)
            return MarzulloConsensusEstimate(
                consensusOffsetSeconds: estimate.consensusOffsetSeconds,
                bestLowSeconds: estimate.bestLowSeconds,
                bestHighSeconds: estimate.bestHighSeconds,
                confidenceRadiusSeconds: estimate.confidenceRadiusSeconds,
                minimumDelayOffsetSeconds: estimate.minimumDelayOffsetSeconds,
                minimumRoundTripDelaySeconds: estimate.minimumRoundTripDelaySeconds,
                allanDeviation: sigmaY,
                intersectingCliqueSize: estimate.intersectingCliqueSize,
                totalWindowSamples: estimate.totalWindowSamples,
                rejectedOutlierCount: estimate.rejectedOutlierCount
            )
        }

        return estimate
    }

    public func currentEstimate(defaultTauSeconds: Double = 0.10) -> MarzulloConsensusEstimate {
        guard count > 0 else { return MarzulloConsensusEstimate() }
        let base = computeCurrentConsensus(latestTauSeconds: defaultTauSeconds)
        let sigmaY = historyCount >= 3 ? computeAllanDeviation(tauSeconds: defaultTauSeconds) : 0.0
        return MarzulloConsensusEstimate(
            consensusOffsetSeconds: base.consensusOffsetSeconds,
            bestLowSeconds: base.bestLowSeconds,
            bestHighSeconds: base.bestHighSeconds,
            confidenceRadiusSeconds: base.confidenceRadiusSeconds,
            minimumDelayOffsetSeconds: base.minimumDelayOffsetSeconds,
            minimumRoundTripDelaySeconds: base.minimumRoundTripDelaySeconds,
            allanDeviation: sigmaY,
            intersectingCliqueSize: base.intersectingCliqueSize,
            totalWindowSamples: base.totalWindowSamples,
            rejectedOutlierCount: base.rejectedOutlierCount
        )
    }

    private func computeCurrentConsensus(latestTauSeconds: Double) -> MarzulloConsensusEstimate {
        guard count > 0 else { return MarzulloConsensusEstimate() }

        // 1. Construct 2W interval boundary tuples: (low, -1) and (high, +1)
        var endpoints = [BoundaryEndpoint]()
        endpoints.reserveCapacity(count * 2)

        let oldestIndex = count == windowCapacity ? writeIndex : 0
        for idx in 0..<count {
            let m = ringBuffer[(oldestIndex + idx) % windowCapacity]
            endpoints.append(BoundaryEndpoint(bound: m.lowerBoundSeconds, type: -1))
            endpoints.append(BoundaryEndpoint(bound: m.upperBoundSeconds, type: +1))
        }

        // 2. Sort ascending by bound; for identical bounds, enter (-1) precedes exit (+1) for closed intervals
        endpoints.sort { lhs, rhs in
            if lhs.bound != rhs.bound {
                return lhs.bound < rhs.bound
            }
            return lhs.type < rhs.type
        }

        // 3. Sweep across sorted boundaries to locate the largest mutually intersecting clique [bestLow, bestHigh]
        var activeOverlap = 0
        var bestCliqueSize = 0
        var bestLow = endpoints[0].bound
        var bestHigh = endpoints[endpoints.count - 1].bound

        for i in 0..<(endpoints.count - 1) {
            // Subtracting type increments on lower bound (-1) and decrements on upper bound (+1)
            activeOverlap -= endpoints[i].type
            let candLow = endpoints[i].bound
            let candHigh = endpoints[i + 1].bound

            if activeOverlap > bestCliqueSize {
                bestCliqueSize = activeOverlap
                bestLow = candLow
                bestHigh = candHigh
            } else if activeOverlap == bestCliqueSize && activeOverlap > 0 {
                let candWidth = candHigh - candLow
                let currentWidth = bestHigh - bestLow
                if candWidth > 0 && candWidth < currentWidth {
                    bestLow = candLow
                    bestHigh = candHigh
                }
            }
        }

        let marzulloMidpoint = 0.5 * (bestLow + bestHigh)
        let confidenceRadius = max(0.0, 0.5 * (bestHigh - bestLow))

        // 4. Minimum-delay survivor filter over inliers whose intervals intersect [bestLow, bestHigh]
        var minDelay = Double.greatestFiniteMagnitude
        var minDelayOffset = marzulloMidpoint
        for idx in 0..<count {
            let m = ringBuffer[(oldestIndex + idx) % windowCapacity]
            if m.lowerBoundSeconds <= bestHigh + 1.0e-12 && m.upperBoundSeconds >= bestLow - 1.0e-12 {
                if m.roundTripDelaySeconds < minDelay {
                    minDelay = m.roundTripDelaySeconds
                    minDelayOffset = min(max(m.offsetSeconds, bestLow), bestHigh)
                }
            }
        }
        if !minDelay.isFinite {
            minDelay = 2.0 * confidenceRadius
        }

        let rejected = max(0, count - bestCliqueSize)
        _ = latestTauSeconds

        return MarzulloConsensusEstimate(
            consensusOffsetSeconds: marzulloMidpoint,
            bestLowSeconds: bestLow,
            bestHighSeconds: bestHigh,
            confidenceRadiusSeconds: confidenceRadius,
            minimumDelayOffsetSeconds: minDelayOffset,
            minimumRoundTripDelaySeconds: minDelay,
            allanDeviation: 0.0,
            intersectingCliqueSize: bestCliqueSize,
            totalWindowSamples: count,
            rejectedOutlierCount: rejected
        )
    }

    /// Computes IEEE Std 1139 Allan deviation $\sigma_y(\tau_0) = \sqrt{\frac{1}{2(N-2)\tau_0^2} \sum (x_{i+2} - 2x_{i+1} + x_i)^2}$.
    private func computeAllanDeviation(tauSeconds: Double) -> Double {
        guard historyCount >= 3 else { return 0.0 }
        let safeTau = max(1.0e-4, tauSeconds)
        let start = historyCount == windowCapacity ? historyWriteIndex : 0

        var sumSecondDiffSq = 0.0
        let terms = historyCount - 2
        for i in 0..<terms {
            let x0 = consensusHistory[(start + i) % windowCapacity]
            let x1 = consensusHistory[(start + i + 1) % windowCapacity]
            let x2 = consensusHistory[(start + i + 2) % windowCapacity]
            let secondDiff = x2 - 2.0 * x1 + x0
            sumSecondDiffSq += secondDiff * secondDiff
        }

        let variance = sumSecondDiffSq / (2.0 * Double(terms) * safeTau * safeTau)
        return sqrt(max(0.0, variance))
    }
}

// MARK: - 3. 2nd-Order Proportional-Integral Phase-Locked Loop (PI-PLL Clock Servo)

public struct PLLClockServoTelemetry: Sendable, Equatable {
    public let sampleRateScale: Double       // \alpha_{pll} in [0.9990, 1.0010]
    public let frequencyWarpPPM: Double      // (\alpha_{pll} - 1.0) * 1e6
    public let filteredOffsetSeconds: Double // e[k]
    public let integratorTerm: Double        // \sum K_i * e[j] * dt
    public let isLocked: Bool                // |e[k]| < 250 microseconds

    public init(
        sampleRateScale: Double = 1.0,
        frequencyWarpPPM: Double = 0.0,
        filteredOffsetSeconds: Double = 0.0,
        integratorTerm: Double = 0.0,
        isLocked: Bool = false
    ) {
        self.sampleRateScale = sampleRateScale
        self.frequencyWarpPPM = frequencyWarpPPM
        self.filteredOffsetSeconds = filteredOffsetSeconds
        self.integratorTerm = integratorTerm
        self.isLocked = isLocked
    }
}

/// Critically-damped Butterworth 2nd-Order PI-PLL ($\zeta = \frac{\sqrt{2}}{2}$, $\omega_n = 2\pi \cdot 0.8\text{ Hz}$)
/// converting consensus clock offset $e[k] = \hat{\theta}[k]$ and phase error $e_\phi$ into a smooth,
/// click-free fractional sample-rate warp ratio $\alpha_{\text{pll}} \in [0.9990, 1.0010]$.
public struct PhaseLockedLoopClockServo: Sendable {
    public static let minSampleRateScale: Double = 0.9990
    public static let maxSampleRateScale: Double = 1.0010
    public static let maxFractionalPull: Double = 0.0010
    public static let lockThresholdSeconds: Double = 0.000250 // 250 microseconds

    public let dampingRatio: Double
    public let naturalBandwidthHz: Double
    public let omegaN: Double
    public let kp: Double
    public let ki: Double
    public let phaseAssistWeight: Double

    public private(set) var integralAccumulator: Double = 0.0
    public private(set) var currentSampleRateScale: Double = 1.0
    public private(set) var lastErrorSeconds: Double = 0.0

    public init(
        dampingRatio: Double = 0.5 * sqrt(2.0),
        naturalBandwidthHz: Double = 0.8,
        phaseAssistWeight: Double = 0.15
    ) {
        let safeZeta = max(0.1, dampingRatio)
        let safeBwHz = max(0.05, naturalBandwidthHz)
        let wn = 2.0 * .pi * safeBwHz

        self.dampingRatio = safeZeta
        self.naturalBandwidthHz = safeBwHz
        self.omegaN = wn
        self.kp = 2.0 * safeZeta * wn
        self.ki = wn * wn
        self.phaseAssistWeight = min(max(phaseAssistWeight, 0.0), 1.0)
    }

    public mutating func reset() {
        integralAccumulator = 0.0
        currentSampleRateScale = 1.0
        lastErrorSeconds = 0.0
    }

    /// Advances one discrete PI-PLL control step.
    /// - Parameters:
    ///   - offsetErrorSeconds: Filtered local-to-master clock offset $e[k] = \hat{\theta}[k]$ in seconds.
    ///   - phaseErrorCycles: Optional wrapped beat/carrier phase error $e_\phi \in [-0.5, +0.5]$ cycles.
    ///   - referenceFrequencyHz: Reference frequency converting `phaseErrorCycles` into equivalent time error.
    ///   - dtSeconds: Control interval $\Delta t$ in seconds.
    @discardableResult
    public mutating func step(
        offsetErrorSeconds: Double,
        phaseErrorCycles: Double = 0.0,
        referenceFrequencyHz: Double = 14.0,
        dtSeconds: Double
    ) -> PLLClockServoTelemetry {
        let safeDt = min(max(dtSeconds, 1.0e-4), 2.0)

        var compositeError = offsetErrorSeconds
        // Blend fine sub-cycle phase error only when time offset is already within a quarter cycle
        let refHz = max(0.5, referenceFrequencyHz)
        let phaseTimeError = (min(max(phaseErrorCycles, -0.5), 0.5)) / refHz
        if abs(offsetErrorSeconds) < (0.25 / refHz) && phaseErrorCycles != 0.0 {
            compositeError = (1.0 - phaseAssistWeight) * offsetErrorSeconds + phaseAssistWeight * phaseTimeError
        }

        let candidateIntegral = integralAccumulator + ki * compositeError * safeDt
        let rawControl = kp * compositeError + candidateIntegral
        let clampedControl = min(max(rawControl, -Self.maxFractionalPull), Self.maxFractionalPull)

        // Conditional anti-windup: accumulate integral when unsaturated or when error unwinds saturation
        if abs(rawControl) <= Self.maxFractionalPull || (rawControl * compositeError < 0.0) {
            integralAccumulator = min(max(candidateIntegral, -Self.maxFractionalPull), Self.maxFractionalPull)
        }

        let alpha = min(max(1.0 + clampedControl, Self.minSampleRateScale), Self.maxSampleRateScale)
        currentSampleRateScale = alpha
        lastErrorSeconds = offsetErrorSeconds

        return PLLClockServoTelemetry(
            sampleRateScale: alpha,
            frequencyWarpPPM: (alpha - 1.0) * 1.0e6,
            filteredOffsetSeconds: offsetErrorSeconds,
            integratorTerm: integralAccumulator,
            isLocked: abs(offsetErrorSeconds) < Self.lockThresholdSeconds
        )
    }
}

// MARK: - 4. Acoustic Wave-Field Synthesis (WFS) & Time-of-Flight Delay Compensation

public struct OrchestraSpeakerNode: Sendable, Equatable, Identifiable {
    public var id: Int { nodeID }
    public var nodeID: Int
    public var label: String
    public var positionMeters: SIMD3<Double>
    public var customNormal: SIMD3<Double>?

    public init(
        nodeID: Int,
        label: String,
        positionMeters: SIMD3<Double>,
        customNormal: SIMD3<Double>? = nil
    ) {
        self.nodeID = nodeID
        self.label = label
        self.positionMeters = positionMeters
        self.customNormal = customNormal
    }
}

public struct WaveFieldNodeSolution: Sendable, Equatable, Identifiable {
    public var id: Int { nodeID }
    public let nodeID: Int
    public let label: String
    public let positionMeters: SIMD3<Double>
    public let sourceToNodeDistanceMeters: Double     // ||p_i - p_S||
    public let nodeToListenerDistanceMeters: Double   // ||p_L - p_i||
    public let rawWFSDelaySeconds: Double             // (||p_i - p_S|| - ||p_L - p_S||) / c
    public let compensatedWFSDelaySeconds: Double     // Causal sweet-spot / WFS compensation delay >= 0
    public let acousticTravelToListenerSeconds: Double // ||p_L - p_i|| / c
    public let totalArrivalAtSweetSpotSeconds: Double // acousticTravelToListenerSeconds + compensatedWFSDelaySeconds
    public let wfsDrivingAmplitude: Float             // 2.5D Rayleigh I stationary-phase gain g_{wfs, i}
    public let cosIncidenceAngle: Double              // cos(\psi_i)

    @inline(__always)
    public var tofDelaySeconds: Double { compensatedWFSDelaySeconds }

    @inline(__always)
    public var totalWavefrontArrivalSeconds: Double { totalArrivalAtSweetSpotSeconds }

    @inline(__always)
    public func delayInSamples(sampleRate: Double) -> Double {
        max(0.0, compensatedWFSDelaySeconds * max(8_000.0, sampleRate))
    }
}

/// Solves 2.5D Rayleigh I Wave-Field Synthesis driving amplitudes $g_{\text{wfs}, i}$ and
/// acoustic Time-of-Flight (ToF) compensation delays $\tau_{\text{wfs}, i}$ ($c = 343.0\text{ m/s}$).
public struct SpatialWaveFieldSolver: Sendable {
    public static let speedOfSoundMetersPerSecond: Double = 343.0
    public static let minimumAcousticDistanceMeters: Double = 0.08

    public let speedOfSound: Double

    public init(speedOfSound: Double = speedOfSoundMetersPerSecond) {
        self.speedOfSound = max(100.0, speedOfSound)
    }

    public init(speedOfSoundMetersPerSec: Double) {
        self.speedOfSound = max(100.0, speedOfSoundMetersPerSec)
    }

    /// Exact raw 2.5D WFS relative delay $\tau_{\text{wfs}, i} = \frac{\|\vec{p}_i - \vec{p}_S\| - \|\vec{p}_L - \vec{p}_S\|}{c}$.
    @inline(__always)
    public func rawRayleighWFSDelaySeconds(
        nodePosition: SIMD3<Double>,
        listenerPosition: SIMD3<Double>,
        virtualSourcePosition: SIMD3<Double>
    ) -> Double {
        let distNodeSource = simd_length(nodePosition - virtualSourcePosition)
        let distListenerSource = simd_length(listenerPosition - virtualSourcePosition)
        return (distNodeSource - distListenerSource) / speedOfSound
    }

    /// Computes full per-node WFS driving amplitudes and causal sweet-spot Time-of-Flight compensation delays
    /// such that physical wavefronts emitted by all peer Apple devices arrive coherently in phase at $\vec{p}_L$.
    public func solveArray(
        nodes: [OrchestraSpeakerNode],
        listenerPosition: SIMD3<Double>,
        virtualSourcePosition: SIMD3<Double>,
        enforceOmnidirectionalSweetSpotLock: Bool = true
    ) -> [WaveFieldNodeSolution] {
        guard !nodes.isEmpty else { return [] }

        let distListenerSource = max(
            Self.minimumAcousticDistanceMeters,
            simd_length(listenerPosition - virtualSourcePosition)
        )

        // Reference arrival distance guarantees causal (>= 0) electronic delay across every node in the array
        var maxListenerDistance = distListenerSource
        var minRawWFSDelay = Double.greatestFiniteMagnitude

        for node in nodes {
            let dNodeListener = max(Self.minimumAcousticDistanceMeters, simd_length(listenerPosition - node.positionMeters))
            if dNodeListener > maxListenerDistance {
                maxListenerDistance = dNodeListener
            }
            let rawDelay = rawRayleighWFSDelaySeconds(
                nodePosition: node.positionMeters,
                listenerPosition: listenerPosition,
                virtualSourcePosition: virtualSourcePosition
            )
            if rawDelay < minRawWFSDelay {
                minRawWFSDelay = rawDelay
            }
        }

        var rawSolutions = [(
            node: OrchestraSpeakerNode,
            dNodeSource: Double,
            dNodeListener: Double,
            rawWFSDelay: Double,
            compDelay: Double,
            cosPsi: Double,
            unnormalizedGain: Double
        )]()
        rawSolutions.reserveCapacity(nodes.count)

        var maxGain = 0.0

        for node in nodes {
            let vecSourceToNode = node.positionMeters - virtualSourcePosition
            let vecNodeToListener = listenerPosition - node.positionMeters

            let dNodeSource = max(Self.minimumAcousticDistanceMeters, simd_length(vecSourceToNode))
            let dNodeListener = max(Self.minimumAcousticDistanceMeters, simd_length(vecNodeToListener))

            let rawWFS = (dNodeSource - distListenerSource) / speedOfSound

            // Compensated delay ensures (dNodeListener / c) + compDelay == maxListenerDistance / c for all nodes
            // Note: when p_i lies on the collinear stationary-phase ray between p_S and p_L,
            // dNodeSource + dNodeListener == distListenerSource, matching causal Rayleigh WFS identically!
            let compDelay: Double
            if enforceOmnidirectionalSweetSpotLock {
                compDelay = max(0.0, (maxListenerDistance - dNodeListener) / speedOfSound)
            } else {
                compDelay = max(0.0, rawWFS - minRawWFSDelay)
            }

            let inwardNormal: SIMD3<Double>
            if let custom = node.customNormal, simd_length(custom) > 1.0e-6 {
                inwardNormal = simd_normalize(custom)
            } else if simd_length(vecNodeToListener) > 1.0e-6 {
                inwardNormal = simd_normalize(vecNodeToListener)
            } else {
                inwardNormal = SIMD3<Double>(0, 0, 1)
            }

            let unitRay = vecSourceToNode / dNodeSource
            let cosPsi = min(max(simd_dot(unitRay, inwardNormal), -1.0), 1.0)

            // 2.5D Rayleigh I stationary-phase secondary-source driving amplitude:
            // g_{wfs, i} = sqrt(||p_L - p_i|| / (||p_i - p_S|| + ||p_L - p_i||)) * cos(\psi_i) / sqrt(||p_i - p_S||)
            let effectiveCos: Double
            if enforceOmnidirectionalSweetSpotLock {
                // Smooth cardioid spatial shading (0.35 + 0.65 * max(0, cosPsi)) keeps surround nodes audible while preserving directional wavefront
                effectiveCos = max(0.20, 0.35 + 0.65 * max(0.0, cosPsi))
            } else {
                effectiveCos = max(0.0, cosPsi)
            }

            let geometricFactor = sqrt(dNodeListener / max(Self.minimumAcousticDistanceMeters, dNodeSource + dNodeListener))
            let gain = geometricFactor * (effectiveCos / sqrt(dNodeSource))
            if gain > maxGain {
                maxGain = gain
            }

            rawSolutions.append((
                node: node,
                dNodeSource: dNodeSource,
                dNodeListener: dNodeListener,
                rawWFSDelay: rawWFS,
                compDelay: compDelay,
                cosPsi: cosPsi,
                unnormalizedGain: gain
            ))
        }

        let normScale = maxGain > 1.0e-6 ? min(1.0 / maxGain, 2.0) : 1.0

        return rawSolutions.map { item in
            let airTime = item.dNodeListener / speedOfSound
            let normalizedGain = Float(min(max(item.unnormalizedGain * normScale, 0.0), 1.0))
            return WaveFieldNodeSolution(
                nodeID: item.node.nodeID,
                label: item.node.label,
                positionMeters: item.node.positionMeters,
                sourceToNodeDistanceMeters: item.dNodeSource,
                nodeToListenerDistanceMeters: item.dNodeListener,
                rawWFSDelaySeconds: item.rawWFSDelay,
                compensatedWFSDelaySeconds: item.compDelay,
                acousticTravelToListenerSeconds: airTime,
                totalArrivalAtSweetSpotSeconds: airTime + item.compDelay,
                wfsDrivingAmplitude: normalizedGain,
                cosIncidenceAngle: item.cosPsi
            )
        }
    }

    public static func defaultQuadSpeakerArray() -> [OrchestraSpeakerNode] {
        [
            OrchestraSpeakerNode(nodeID: 0, label: "iPhone Pro (FL)", positionMeters: SIMD3<Double>(-1.10, 0.0, -1.25)),
            OrchestraSpeakerNode(nodeID: 1, label: "iPad Pro (FR)", positionMeters: SIMD3<Double>(1.15, 0.0, -1.20)),
            OrchestraSpeakerNode(nodeID: 2, label: "MacBook Pro (RL)", positionMeters: SIMD3<Double>(-1.35, 0.0, 1.05)),
            OrchestraSpeakerNode(nodeID: 3, label: "Vision Pro (RR)", positionMeters: SIMD3<Double>(1.30, 0.0, 1.15))
        ]
    }
}

// MARK: - 5. Lock-Free Real-Time Orchestra Control State & Interactive Mesh Simulator

public struct RealtimeOrchestraSyncControl: Sendable, Equatable {
    public var isEnabled: Bool
    public var pllSampleRateScale: Double
    public var wfsDelaySamples: Double
    public var wfsGainScale: Float
    public var masterPhaseSyncTarget: Double?

    public var isMeshSyncActive: Bool {
        get { isEnabled }
        set { isEnabled = newValue }
    }

    public init(
        isEnabled: Bool = false,
        pllSampleRateScale: Double = 1.0,
        wfsDelaySamples: Double = 0.0,
        wfsGainScale: Float = 1.0,
        masterPhaseSyncTarget: Double? = nil
    ) {
        self.isEnabled = isEnabled
        self.pllSampleRateScale = min(
            max(pllSampleRateScale, PhaseLockedLoopClockServo.minSampleRateScale),
            PhaseLockedLoopClockServo.maxSampleRateScale
        )
        self.wfsDelaySamples = max(0.0, wfsDelaySamples)
        self.wfsGainScale = min(max(wfsGainScale, 0.0), 1.5)
        self.masterPhaseSyncTarget = masterPhaseSyncTarget
    }
}

public struct OrchestraMeshStatusSnapshot: Sendable, Equatable {
    public var isMeshSyncEnabled: Bool
    public var isSimulatingQuadArray: Bool
    public var activeLocalNodeID: Int
    public var listenerPositionMeters: SIMD3<Double>
    public var virtualSourcePositionMeters: SIMD3<Double>
    public var marzulloOffsetMicroseconds: Double
    public var confidenceRadiusMicroseconds: Double
    public var allanDeviation: Double
    public var pllFrequencyWarpPPM: Double
    public var pllSampleRateScale: Double
    public var isPhaseLocked: Bool
    public var rejectedOutliers: Int
    public var nodeSolutions: [WaveFieldNodeSolution]

    public init(
        isMeshSyncEnabled: Bool = false,
        isSimulatingQuadArray: Bool = false,
        activeLocalNodeID: Int = 0,
        listenerPositionMeters: SIMD3<Double> = .zero,
        virtualSourcePositionMeters: SIMD3<Double> = SIMD3<Double>(0.0, 0.0, -2.4),
        marzulloOffsetMicroseconds: Double = 0.0,
        confidenceRadiusMicroseconds: Double = 0.0,
        allanDeviation: Double = 0.0,
        pllFrequencyWarpPPM: Double = 0.0,
        pllSampleRateScale: Double = 1.0,
        isPhaseLocked: Bool = false,
        rejectedOutliers: Int = 0,
        nodeSolutions: [WaveFieldNodeSolution] = []
    ) {
        self.isMeshSyncEnabled = isMeshSyncEnabled
        self.isSimulatingQuadArray = isSimulatingQuadArray
        self.activeLocalNodeID = activeLocalNodeID
        self.listenerPositionMeters = listenerPositionMeters
        self.virtualSourcePositionMeters = virtualSourcePositionMeters
        self.marzulloOffsetMicroseconds = marzulloOffsetMicroseconds
        self.confidenceRadiusMicroseconds = confidenceRadiusMicroseconds
        self.allanDeviation = allanDeviation
        self.pllFrequencyWarpPPM = pllFrequencyWarpPPM
        self.pllSampleRateScale = pllSampleRateScale
        self.isPhaseLocked = isPhaseLocked
        self.rejectedOutliers = rejectedOutliers
        self.nodeSolutions = nodeSolutions
    }
}

/// Coordinates live/simulated 4-node PTP exchanges, Marzullo outlier filtering, 2nd-order PI-PLL servoing,
/// and 2.5D Wave-Field Synthesis delay/gain updates across the spatial mesh.
public final class DistributedOrchestraEngine: Sendable {
    private struct MutableMeshState {
        var isMeshSyncEnabled: Bool = false
        var isSimulatingQuadArray: Bool = false
        var activeLocalNodeID: Int = 0
        var nodes: [OrchestraSpeakerNode] = SpatialWaveFieldSolver.defaultQuadSpeakerArray()
        var listenerPosition: SIMD3<Double> = .zero
        var virtualSourcePosition: SIMD3<Double> = SIMD3<Double>(0.0, 0.0, -2.4)
        var marzulloFilter = MarzulloClockFilter(windowCapacity: 16)
        var pllServo = PhaseLockedLoopClockServo()
        var wfsSolver = SpatialWaveFieldSolver()
        var simulatedMasterOffsetSec: Double = 0.0042 // Initial +4.2 ms Wi-Fi peer offset
        var simulatedCrystalDriftFrac: Double = -28.0e-6 // -28 ppm quartz crystal mismatch
        var sequenceCounter: UInt16 = 0
        var prngState: UInt64 = 0xA3F1_9B2C_4D7E_8015
        var masterBeatPhaseAccum: Double = 0.0
        var globalSampleAccum: UInt64 = 0
        var lastSnapshot = OrchestraMeshStatusSnapshot()
    }

    private let stateMutex: Mutex<MutableMeshState>

    public init() {
        var initial = MutableMeshState()
        let initialSolutions = initial.wfsSolver.solveArray(
            nodes: initial.nodes,
            listenerPosition: initial.listenerPosition,
            virtualSourcePosition: initial.virtualSourcePosition
        )
        initial.lastSnapshot = OrchestraMeshStatusSnapshot(
            isMeshSyncEnabled: false,
            isSimulatingQuadArray: false,
            activeLocalNodeID: 0,
            listenerPositionMeters: initial.listenerPosition,
            virtualSourcePositionMeters: initial.virtualSourcePosition,
            nodeSolutions: initialSolutions
        )
        self.stateMutex = Mutex(initial)
    }

    public func setMeshSyncEnabled(_ enabled: Bool) {
        stateMutex.withLock { state in
            state.isMeshSyncEnabled = enabled
            if enabled {
                state.marzulloFilter.reset()
                state.pllServo.reset()
                state.simulatedMasterOffsetSec = 0.0042
            } else {
                state.pllServo.reset()
            }
            refreshSnapshotLocked(&state)
        }
    }

    public func setSimulateQuadArray(_ enabled: Bool) {
        stateMutex.withLock { state in
            state.isSimulatingQuadArray = enabled
            if enabled && !state.isMeshSyncEnabled {
                state.isMeshSyncEnabled = true
                state.marzulloFilter.reset()
                state.pllServo.reset()
                state.simulatedMasterOffsetSec = 0.0042
            }
            refreshSnapshotLocked(&state)
        }
    }

    public func setActiveLocalNode(nodeID: Int) {
        stateMutex.withLock { state in
            if state.nodes.contains(where: { $0.nodeID == nodeID }) {
                state.activeLocalNodeID = nodeID
                refreshSnapshotLocked(&state)
            }
        }
    }

    public func updateNodePosition(nodeID: Int, xMeters: Double, zMeters: Double) {
        stateMutex.withLock { state in
            let clampedX = min(max(xMeters, -3.5), 3.5)
            let clampedZ = min(max(zMeters, -3.5), 3.5)
            if let idx = state.nodes.firstIndex(where: { $0.nodeID == nodeID }) {
                state.nodes[idx].positionMeters = SIMD3<Double>(clampedX, 0.0, clampedZ)
                refreshSnapshotLocked(&state)
            }
        }
    }

    public func updateVirtualSourcePosition(xMeters: Double, zMeters: Double) {
        stateMutex.withLock { state in
            let clampedX = min(max(xMeters, -4.0), 4.0)
            let clampedZ = min(max(zMeters, -4.0), 4.0)
            state.virtualSourcePosition = SIMD3<Double>(clampedX, 0.0, clampedZ)
            refreshSnapshotLocked(&state)
        }
    }

    public func nodes() -> [OrchestraSpeakerNode] {
        stateMutex.withLock { $0.nodes }
    }

    public func snapshot() -> OrchestraMeshStatusSnapshot {
        stateMutex.withLock { $0.lastSnapshot }
    }

    /// Advances one mesh synchronization cycle (`dtSeconds`), synthesizing a realistic 64-byte PTP exchange
    /// (complete with occasional Wi-Fi aggregation jitter spikes rejected by Marzullo's algorithm),
    /// stepping the 2nd-order PI-PLL servo, and returning real-time DSP control scalars for `ProceduralSynthKernel`.
    public func tickMeshSynchronization(
        dtSeconds: Double,
        sampleRate: Double,
        tempoBPM: Float = 120.0,
        binauralBeatHz: Double = 14.0
    ) -> (snapshot: OrchestraMeshStatusSnapshot, dspControl: RealtimeOrchestraSyncControl) {
        stateMutex.withLock { state in
            let safeDt = min(max(dtSeconds, 0.005), 0.5)
            let safeRate = max(8_000.0, sampleRate)

            let solutions = state.wfsSolver.solveArray(
                nodes: state.nodes,
                listenerPosition: state.listenerPosition,
                virtualSourcePosition: state.virtualSourcePosition
            )

            guard state.isMeshSyncEnabled else {
                refreshSnapshotLocked(&state, precomputedSolutions: solutions)
                return (state.lastSnapshot, RealtimeOrchestraSyncControl(isEnabled: false))
            }

            // Advance master beat phase & sample counter
            let beatsPerSec = Double(tempoBPM) / 60.0
            state.masterBeatPhaseAccum += beatsPerSec * safeDt
            state.masterBeatPhaseAccum -= floor(state.masterBeatPhaseAccum)
            state.globalSampleAccum &+= UInt64((safeDt * safeRate).rounded())

            // Evolve local-to-master clock offset under hardware crystal drift vs current PLL compensation
            let effectiveLocalRate = (1.0 + state.simulatedCrystalDriftFrac) * state.pllServo.currentSampleRateScale
            state.simulatedMasterOffsetSec += safeDt * (1.0 - effectiveLocalRate)

            // Deterministic SplitMix64 PRNG for realistic Wi-Fi RTT jitter + occasional asymmetric aggregation spike
            state.prngState &+= 0x9E37_79B9_7F4A_7C15
            var z = state.prngState
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= (z >> 31)
            let u01 = Double(z >> 40) / 16_777_216.0

            let baseOneWaySec = 0.00042 + 0.00018 * u01 // ~0.42..0.60 ms Wi-Fi peer leg
            let isSpikePacket = (state.sequenceCounter % 11 == 7)
            let forwardDelaySec = isSpikePacket ? (baseOneWaySec + 0.0185) : baseOneWaySec
            let reverseDelaySec = baseOneWaySec * (0.94 + 0.12 * u01)

            let t1Ns = MonotonicHardwareClock.nowNanoseconds()
            let trueOffsetNs = Int64((state.simulatedMasterOffsetSec * 1.0e9).rounded())
            let fwdNs = Int64((forwardDelaySec * 1.0e9).rounded())
            let revNs = Int64((reverseDelaySec * 1.0e9).rounded())
            let turnaroundNs: Int64 = 35_000 // 35 us responder kernel turnaround

            let t2Ns = UInt64(max(0, Int64(t1Ns) + trueOffsetNs + fwdNs))
            let t3Ns = UInt64(max(0, Int64(t2Ns) + turnaroundNs))
            let t4Ns = UInt64(max(0, Int64(t3Ns) - trueOffsetNs + revNs))

            state.sequenceCounter &+= 1
            let wirePacket = OrchestraPTPClockPacket(
                packetKind: .delayResponse,
                sequenceNumber: state.sequenceCounter,
                peerNodeID: UInt16(clamping: state.activeLocalNodeID),
                t1OriginNs: t1Ns,
                t2ResponderIngressNs: t2Ns,
                t3ResponderEgressNs: t3Ns,
                t4InitiatorIngressNs: t4Ns,
                masterBeatPhase: Float(state.masterBeatPhaseAccum),
                tempoBPM: tempoBPM,
                globalSampleCounter: state.globalSampleAccum
            )

            // Full wire encode -> decode round-trip integrity check
            let consensus: MarzulloConsensusEstimate
            if let verified = try? OrchestraPTPClockPacket.decode(from: wirePacket.encode()) {
                consensus = state.marzulloFilter.ingestPacket(verified, sampleIntervalTauSeconds: safeDt)
            } else {
                consensus = state.marzulloFilter.ingestPacket(wirePacket, sampleIntervalTauSeconds: safeDt)
            }

            let pllTelemetry = state.pllServo.step(
                offsetErrorSeconds: consensus.consensusOffsetSeconds,
                phaseErrorCycles: 0.0,
                referenceFrequencyHz: binauralBeatHz,
                dtSeconds: safeDt
            )

            let localSolution = solutions.first(where: { $0.nodeID == state.activeLocalNodeID }) ?? solutions.first
            let wfsDelaySamples = state.isSimulatingQuadArray
                ? (localSolution?.delayInSamples(sampleRate: safeRate) ?? 0.0)
                : 0.0
            let wfsGain: Float = state.isSimulatingQuadArray
                ? (localSolution?.wfsDrivingAmplitude ?? 1.0)
                : 1.0

            state.lastSnapshot = OrchestraMeshStatusSnapshot(
                isMeshSyncEnabled: state.isMeshSyncEnabled,
                isSimulatingQuadArray: state.isSimulatingQuadArray,
                activeLocalNodeID: state.activeLocalNodeID,
                listenerPositionMeters: state.listenerPosition,
                virtualSourcePositionMeters: state.virtualSourcePosition,
                marzulloOffsetMicroseconds: consensus.consensusOffsetSeconds * 1.0e6,
                confidenceRadiusMicroseconds: consensus.confidenceRadiusSeconds * 1.0e6,
                allanDeviation: consensus.allanDeviation,
                pllFrequencyWarpPPM: pllTelemetry.frequencyWarpPPM,
                pllSampleRateScale: pllTelemetry.sampleRateScale,
                isPhaseLocked: pllTelemetry.isLocked,
                rejectedOutliers: consensus.rejectedOutlierCount,
                nodeSolutions: solutions
            )

            let control = RealtimeOrchestraSyncControl(
                isEnabled: true,
                pllSampleRateScale: pllTelemetry.sampleRateScale,
                wfsDelaySamples: wfsDelaySamples,
                wfsGainScale: wfsGain,
                masterPhaseSyncTarget: state.masterBeatPhaseAccum
            )
            return (state.lastSnapshot, control)
        }
    }

    private func refreshSnapshotLocked(
        _ state: inout MutableMeshState,
        precomputedSolutions: [WaveFieldNodeSolution]? = nil
    ) {
        let solutions = precomputedSolutions ?? state.wfsSolver.solveArray(
            nodes: state.nodes,
            listenerPosition: state.listenerPosition,
            virtualSourcePosition: state.virtualSourcePosition
        )
        let estimate = state.marzulloFilter.currentEstimate()
        state.lastSnapshot = OrchestraMeshStatusSnapshot(
            isMeshSyncEnabled: state.isMeshSyncEnabled,
            isSimulatingQuadArray: state.isSimulatingQuadArray,
            activeLocalNodeID: state.activeLocalNodeID,
            listenerPositionMeters: state.listenerPosition,
            virtualSourcePositionMeters: state.virtualSourcePosition,
            marzulloOffsetMicroseconds: estimate.consensusOffsetSeconds * 1.0e6,
            confidenceRadiusMicroseconds: estimate.confidenceRadiusSeconds * 1.0e6,
            allanDeviation: estimate.allanDeviation,
            pllFrequencyWarpPPM: (state.pllServo.currentSampleRateScale - 1.0) * 1.0e6,
            pllSampleRateScale: state.pllServo.currentSampleRateScale,
            isPhaseLocked: state.isMeshSyncEnabled && abs(estimate.consensusOffsetSeconds) < PhaseLockedLoopClockServo.lockThresholdSeconds,
            rejectedOutliers: estimate.rejectedOutlierCount,
            nodeSolutions: solutions
        )
    }
}
