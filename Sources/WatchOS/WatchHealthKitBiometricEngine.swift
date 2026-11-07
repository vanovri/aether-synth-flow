// MARK: - FILE: WatchHealthKitBiometricEngine.swift

import Foundation
import Observation

#if os(watchOS)
import HealthKit
import WidgetKit

// MARK: - App-Group Watch Smart Stack Complication Payload Store

public struct WatchComplicationTelemetryPayload: Codable, Sendable, Equatable {
    public var vagalCoherenceScore: Double
    public var heartRateBPM: Double
    public var rmssdMs: Double
    public var respiratoryRateBrPM: Double
    public var streakDays: Int
    public var binauralBeatHz: Double
    public var accentHue: Double
    public var activeHabitTitle: String
    public var isEntrainmentActive: Bool
    public var updatedAt: Date

    public init(
        vagalCoherenceScore: Double = 0.78,
        heartRateBPM: Double = 64.0,
        rmssdMs: Double = 52.0,
        respiratoryRateBrPM: Double = 6.0,
        streakDays: Int = 6,
        binauralBeatHz: Double = 10.0,
        accentHue: Double = 0.54,
        activeHabitTitle: String = "Systems Architecture",
        isEntrainmentActive: Bool = false,
        updatedAt: Date = .now
    ) {
        self.vagalCoherenceScore = min(max(vagalCoherenceScore, 0.0), 1.0)
        self.heartRateBPM = max(0.0, heartRateBPM)
        self.rmssdMs = max(0.0, rmssdMs)
        self.respiratoryRateBrPM = max(0.0, respiratoryRateBrPM)
        self.streakDays = max(0, streakDays)
        self.binauralBeatHz = min(max(binauralBeatHz, 0.5), 48.0)
        self.accentHue = accentHue
        self.activeHabitTitle = activeHabitTitle
        self.isEntrainmentActive = isEntrainmentActive
        self.updatedAt = updatedAt
    }
}

public enum WatchComplicationStateStore: Sendable {
    private static let storageKey = "com.aethersynth.flow.watch.complication.v2"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: AetherPersistenceSchema.appGroupIdentifier) ?? .standard
    }

    public static func read() -> WatchComplicationTelemetryPayload {
        if let raw = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(WatchComplicationTelemetryPayload.self, from: raw) {
            return decoded
        }
        let shared = SharedWidgetStateStore.read()
        return WatchComplicationTelemetryPayload(
            vagalCoherenceScore: 0.78,
            heartRateBPM: 64.0,
            rmssdMs: 52.0,
            respiratoryRateBrPM: 6.0,
            streakDays: shared.currentStreak,
            binauralBeatHz: shared.binauralBeatHz,
            accentHue: shared.accentHue,
            activeHabitTitle: shared.activeHabitTitle,
            isEntrainmentActive: shared.isFocusRunning
        )
    }

    public static func write(_ payload: WatchComplicationTelemetryPayload) {
        guard let encoded = try? JSONEncoder().encode(payload) else { return }
        defaults.set(encoded, forKey: storageKey)
    }
}

// MARK: - Deterministic Watch Simulator Coupled-Oscillator Physiology Fallback

private struct WatchSyntheticPhysiologyGenerator: Sendable {
    private var simTimeSeconds: TimeInterval = 0.0
    private var nextBeatTimeSeconds: TimeInterval = 0.0
    private var mayerPhase: Double = 0.0
    private var respiratoryPhase: Double = 0.0
    private var rngState: UInt64 = 0x51A7_E29C_2026_7711
    private var rollingSamples: [RRIntervalSampleDTO] = []

    mutating func step(dtSeconds: Double, coherenceDrive: Double) -> ([RRIntervalSampleDTO], Double) {
        let clampedDrive = min(max(coherenceDrive, 0.05), 1.0)
        let respHz = 0.10 + (1.0 - clampedDrive) * 0.12 // Converges toward 0.10 Hz (6.0 BrPM) Mayer resonance
        let targetEnd = simTimeSeconds + max(0.1, dtSeconds)

        while nextBeatTimeSeconds <= targetEnd {
            let rsaAmplitudeMs = 18.0 + 54.0 * clampedDrive
            let mayerAmplitudeMs = 10.0 + 30.0 * clampedDrive
            let jitterMs = nextSymmetricNoise() * (14.0 * (1.0 - 0.75 * clampedDrive))

            let baseRRMs = 740.0 + 205.0 * clampedDrive
            let rrModulation = rsaAmplitudeMs * sin(2.0 * Double.pi * respiratoryPhase)
                + mayerAmplitudeMs * sin(2.0 * Double.pi * mayerPhase)
            let rrMs = min(max(baseRRMs + rrModulation + jitterMs, 420.0), 1_450.0)

            rollingSamples.append(
                RRIntervalSampleDTO(
                    timestamp: nextBeatTimeSeconds,
                    rrMilliseconds: rrMs
                )
            )

            let stepSec = rrMs / 1_000.0
            respiratoryPhase = (respiratoryPhase + respHz * stepSec).truncatingRemainder(dividingBy: 1.0)
            mayerPhase = (mayerPhase + 0.10 * stepSec).truncatingRemainder(dividingBy: 1.0)
            nextBeatTimeSeconds += stepSec
        }

        simTimeSeconds = targetEnd
        let cutoff = max(0.0, simTimeSeconds - 64.0)
        if rollingSamples.count > 12 {
            rollingSamples.removeAll { $0.timestamp < cutoff }
        }

        return (rollingSamples, respHz * 60.0)
    }

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

// MARK: - watchOS 11 HealthKit Live PPG RR-Interval & Mindful Session Engine

@Observable
@MainActor
public final class WatchHealthKitBiometricEngine {
    public private(set) var isHealthKitAuthorized: Bool = false
    public private(set) var isSessionActive: Bool = false
    public private(set) var isUsingSimulatorFallback: Bool = false

    public var binauralBeatHz: Double = 10.0
    public var activeHabitTitle: String = "Systems Architecture"
    public var activeAccentHue: Double = 0.54
    public var currentStreakDays: Int = 6
    public var elapsedSessionSeconds: Double = 0.0
    public var statusLine: String = "Mayer 0.10 Hz Ready"

    // Live Biometric Readouts (Synchronized with BiometricSnapshotDTO & HRVAnalysisMetricsDTO)
    public private(set) var latestSnapshot: BiometricSnapshotDTO
    public var latestMetrics: HRVAnalysisMetricsDTO { latestSnapshot.metrics }

    public let bridgeActor = WatchBiometricBridgeActor()

    private let healthStore: HKHealthStore? = HKHealthStore.isHealthDataAvailable() ? HKHealthStore() : nil
    private var workoutSession: HKWorkoutSession?
    private var liveWorkoutBuilder: HKLiveWorkoutBuilder?
    private var workoutDelegateRelay: WatchWorkoutDelegateRelay?
    private var activeQueries: [HKQuery] = []

    private var rollingHardwareRRSamples: [RRIntervalSampleDTO] = []
    private var latestRespiratoryRateBrPM: Double = 6.0
    private var lastHardwareSampleReceivedAt: Date?
    private var sessionStartDate: Date?
    private var evaluationLoopTask: Task<Void, Never>?
    private var syntheticGenerator = WatchSyntheticPhysiologyGenerator()

    public init() {
        let initialComplication = WatchComplicationStateStore.read()
        self.binauralBeatHz = initialComplication.binauralBeatHz
        self.activeHabitTitle = initialComplication.activeHabitTitle
        self.activeAccentHue = initialComplication.accentHue
        self.currentStreakDays = initialComplication.streakDays

        var seedGen = WatchSyntheticPhysiologyGenerator()
        let (seedSamples, seedResp) = seedGen.step(dtSeconds: 32.0, coherenceDrive: 0.72)
        let seedMetrics = HRVBiometricAnalyzer.analyze(samples: seedSamples, freqBinCount: 48)
        self.latestSnapshot = BiometricSnapshotDTO(
            timestamp: .now,
            recentRRSamples: seedSamples,
            metrics: seedMetrics,
            respiratoryRateBrPM: seedResp
        )
        self.syntheticGenerator = seedGen
    }

    // MARK: - Pipeline Bootstrap & HealthKit Authorization

    public func activatePipelines() async {
        await bridgeActor.activateBridge()
    }

    public func requestHealthKitAuthorization() async -> Bool {
        guard let healthStore else {
            isHealthKitAuthorized = false
            isUsingSimulatorFallback = true
            statusLine = "Simulator Biometrics"
            return false
        }

        let heartRateType = HKQuantityType(.heartRate)
        let hrvSDNNType = HKQuantityType(.heartRateVariabilitySDNN)
        let respiratoryType = HKQuantityType(.respiratoryRate)
        let activeEnergyType = HKQuantityType(.activeEnergyBurned)
        let heartbeatSeriesType = HKSeriesType.heartbeat()
        let mindfulCategoryType = HKCategoryType(.mindfulSession)
        let workoutType = HKObjectType.workoutType()

        let shareTypes: Set<HKSampleType> = [mindfulCategoryType, workoutType]
        let readTypes: Set<HKObjectType> = [
            heartRateType,
            hrvSDNNType,
            respiratoryType,
            activeEnergyType,
            heartbeatSeriesType,
            mindfulCategoryType
        ]

        do {
            try await healthStore.requestAuthorization(toShare: shareTypes, read: readTypes)
            isHealthKitAuthorized = true
            statusLine = "PPG Optical Ready"
            return true
        } catch {
            isHealthKitAuthorized = false
            isUsingSimulatorFallback = true
            statusLine = "Simulator Biometrics"
            return false
        }
    }

    // MARK: - Start / Stop Mind & Body Workout + Beat-to-Beat Streaming

    public func toggleEntrainmentSession() async {
        if isSessionActive {
            await stopEntrainmentSession(writeMindfulSample: true)
        } else {
            await startEntrainmentSession()
        }
    }

    public func startEntrainmentSession() async {
        guard !isSessionActive else { return }

        if !isHealthKitAuthorized {
            _ = await requestHealthKitAuthorization()
        }

        let start = Date.now
        sessionStartDate = start
        elapsedSessionSeconds = 0.0
        rollingHardwareRRSamples.removeAll(keepingCapacity: true)
        lastHardwareSampleReceivedAt = nil
        isSessionActive = true

        if let healthStore {
            startAnchoredBiometricQueries(healthStore: healthStore, startDate: start)
            await startMindAndBodyWorkoutSession(healthStore: healthStore, startDate: start)
        } else {
            isUsingSimulatorFallback = true
        }

        statusLine = "Streaming Live HRV"
        startPeriodicEvaluationLoop()
        persistComplicationState()
    }

    public func stopEntrainmentSession(writeMindfulSample: Bool = true) async {
        guard isSessionActive else { return }
        isSessionActive = false
        evaluationLoopTask?.cancel()
        evaluationLoopTask = nil

        let end = Date.now
        let start = sessionStartDate ?? end.addingTimeInterval(-max(1.0, elapsedSessionSeconds))
        sessionStartDate = nil

        if let healthStore {
            stopAnchoredQueries(healthStore: healthStore)
            await endMindAndBodyWorkoutSession(endDate: end)
            if writeMindfulSample && end.timeIntervalSince(start) >= 5.0 {
                await writeMindfulSessionSample(healthStore: healthStore, startDate: start, endDate: end)
            }
        }

        statusLine = "Mindful Session Saved"
        persistComplicationState()
    }

    public func updateCrownBinauralFrequency(_ newHz: Double) {
        binauralBeatHz = min(max(newHz, 1.5), 40.0)
        persistComplicationState()
    }

    // MARK: - Rolling 1Hz HRV Analysis & Bridge Transmission

    private func startPeriodicEvaluationLoop() {
        evaluationLoopTask?.cancel()
        evaluationLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.0))
                guard let self, self.isSessionActive else { break }
                await self.evaluateAndTransmitTick()
            }
        }
    }

    private func evaluateAndTransmitTick() async {
        let now = Date.now
        if let start = sessionStartDate {
            elapsedSessionSeconds = now.timeIntervalSince(start)
        }

        let secondsSinceHardware = lastHardwareSampleReceivedAt.map { now.timeIntervalSince($0) } ?? 999.0

        // Alpha-Theta entrainment bands (5...12 Hz) drive higher vagal cardiorespiratory coherence
        let alphaThetaAlignment = exp(-pow((binauralBeatHz - 8.5) / 6.0, 2.0))
        let coherenceDrive = min(max(0.32 + 0.64 * alphaThetaAlignment, 0.15), 0.98)

        let snapshot: BiometricSnapshotDTO
        if !isUsingSimulatorFallback && secondsSinceHardware <= 3.5 && rollingHardwareRRSamples.count >= 4 {
            pruneHardwareWindow(referenceTimestamp: now.timeIntervalSinceReferenceDate)
            let metrics = HRVBiometricAnalyzer.analyze(samples: rollingHardwareRRSamples, freqBinCount: 48)
            snapshot = BiometricSnapshotDTO(
                timestamp: now,
                recentRRSamples: rollingHardwareRRSamples,
                metrics: metrics,
                respiratoryRateBrPM: latestRespiratoryRateBrPM
            )
        } else {
            isUsingSimulatorFallback = true
            let bridgedSim = await bridgeActor.sampleSimulatedOrLiveSnapshot(coherenceDrive: coherenceDrive)
            if bridgedSim.recentRRSamples.count >= 4 {
                snapshot = bridgedSim
            } else {
                let (simRR, simResp) = syntheticGenerator.step(dtSeconds: 1.0, coherenceDrive: coherenceDrive)
                let simMetrics = HRVBiometricAnalyzer.analyze(samples: simRR, freqBinCount: 48)
                snapshot = BiometricSnapshotDTO(
                    timestamp: now,
                    recentRRSamples: simRR,
                    metrics: simMetrics,
                    respiratoryRateBrPM: simResp
                )
            }
        }

        self.latestSnapshot = snapshot
        try? await bridgeActor.sendSnapshot(snapshot)
        persistComplicationState()
    }

    fileprivate func ingestHardwareBeatBatch(_ incoming: [RRIntervalSampleDTO]) {
        guard !incoming.isEmpty else { return }
        isUsingSimulatorFallback = false
        lastHardwareSampleReceivedAt = .now
        rollingHardwareRRSamples.append(contentsOf: incoming)
        pruneHardwareWindow(referenceTimestamp: Date.now.timeIntervalSinceReferenceDate)

        guard rollingHardwareRRSamples.count >= 4 else { return }
        let now = Date.now
        let metrics = HRVBiometricAnalyzer.analyze(samples: rollingHardwareRRSamples, freqBinCount: 48)
        let snapshot = BiometricSnapshotDTO(
            timestamp: now,
            recentRRSamples: rollingHardwareRRSamples,
            metrics: metrics,
            respiratoryRateBrPM: latestRespiratoryRateBrPM
        )
        self.latestSnapshot = snapshot

        Task {
            try? await bridgeActor.sendSnapshot(snapshot)
        }
        persistComplicationState()
    }

    fileprivate func ingestLiveQuantitySample(heartRateBPM: Double?, respiratoryBrPM: Double?, timestamp: Date) {
        if let resp = respiratoryBrPM, resp > 2.0 {
            latestRespiratoryRateBrPM = resp
        }
        if let bpm = heartRateBPM, bpm > 25.0, bpm < 220.0 {
            let gap = lastHardwareSampleReceivedAt.map { timestamp.timeIntervalSince($0) } ?? 999.0
            if gap > 1.4 {
                let derivedRRMs = 60_000.0 / bpm
                let sample = RRIntervalSampleDTO(
                    timestamp: timestamp.timeIntervalSinceReferenceDate,
                    rrMilliseconds: derivedRRMs
                )
                lastHardwareSampleReceivedAt = timestamp
                isUsingSimulatorFallback = false
                rollingHardwareRRSamples.append(sample)
                pruneHardwareWindow(referenceTimestamp: timestamp.timeIntervalSinceReferenceDate)
            }
        }
    }

    private func pruneHardwareWindow(referenceTimestamp: TimeInterval) {
        let cutoff = referenceTimestamp - 64.0
        rollingHardwareRRSamples.removeAll { $0.timestamp < cutoff }
    }

    private func persistComplicationState() {
        let payload = WatchComplicationTelemetryPayload(
            vagalCoherenceScore: latestMetrics.vagalCoherenceScore,
            heartRateBPM: latestMetrics.heartRateBPM,
            rmssdMs: latestMetrics.rmssdMs,
            respiratoryRateBrPM: latestSnapshot.respiratoryRateBrPM,
            streakDays: currentStreakDays,
            binauralBeatHz: binauralBeatHz,
            accentHue: activeAccentHue,
            activeHabitTitle: activeHabitTitle,
            isEntrainmentActive: isSessionActive,
            updatedAt: .now
        )
        WatchComplicationStateStore.write(payload)
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - HealthKit Workout Session, Heartbeat Series & Mindful Sample Persistence

    private func startMindAndBodyWorkoutSession(healthStore: HKHealthStore, startDate: Date) async {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .mindAndBody
        configuration.locationType = .indoor

        do {
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(
                healthStore: healthStore,
                workoutConfiguration: configuration
            )

            let relay = WatchWorkoutDelegateRelay(owner: self)
            session.delegate = relay
            builder.delegate = relay

            self.workoutDelegateRelay = relay
            self.workoutSession = session
            self.liveWorkoutBuilder = builder

            session.startActivity(with: startDate)
            try await builder.beginCollection(at: startDate)
        } catch {
            isUsingSimulatorFallback = true
        }
    }

    private func endMindAndBodyWorkoutSession(endDate: Date) async {
        workoutSession?.end()
        if let builder = liveWorkoutBuilder {
            try? await builder.endCollection(at: endDate)
            _ = try? await builder.finishWorkout()
        }
        workoutSession = nil
        liveWorkoutBuilder = nil
        workoutDelegateRelay = nil
    }

    private func startAnchoredBiometricQueries(healthStore: HKHealthStore, startDate: Date) {
        stopAnchoredQueries(healthStore: healthStore)
        let queries = Self.makeAnchoredQueries(
            healthStore: healthStore,
            startDate: startDate,
            owner: self
        )
        for query in queries {
            healthStore.execute(query)
        }
        activeQueries = queries
    }

    private func stopAnchoredQueries(healthStore: HKHealthStore) {
        for query in activeQueries {
            healthStore.stop(query)
        }
        activeQueries.removeAll()
    }

    nonisolated private static func makeAnchoredQueries(
        healthStore: HKHealthStore,
        startDate: Date,
        owner: WatchHealthKitBiometricEngine
    ) -> [HKQuery] {
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: nil, options: .strictStartDate)

        // 1. Beat-to-Beat HKHeartbeatSeriesSample + HKHeartbeatSeriesQuery
        let seriesType = HKSeriesType.heartbeat()
        let seriesAnchoredQuery = HKAnchoredObjectQuery(
            type: seriesType,
            predicate: predicate,
            anchor: nil,
            limit: HKObjectQueryNoLimit
        ) { [weak owner] _, samples, _, _, _ in
            Self.enumerateHeartbeatSeries(samples, healthStore: healthStore, owner: owner)
        }
        seriesAnchoredQuery.updateHandler = { [weak owner] _, samples, _, _, _ in
            Self.enumerateHeartbeatSeries(samples, healthStore: healthStore, owner: owner)
        }

        // 2. Live Respiratory Rate Anchored Query
        let respType = HKQuantityType(.respiratoryRate)
        let respQuery = HKAnchoredObjectQuery(
            type: respType,
            predicate: predicate,
            anchor: nil,
            limit: HKObjectQueryNoLimit
        ) { [weak owner] _, samples, _, _, _ in
            Self.forwardRespiratorySamples(samples, owner: owner)
        }
        respQuery.updateHandler = { [weak owner] _, samples, _, _, _ in
            Self.forwardRespiratorySamples(samples, owner: owner)
        }

        return [seriesAnchoredQuery, respQuery]
    }

    nonisolated private static func enumerateHeartbeatSeries(
        _ samples: [HKSample]?,
        healthStore: HKHealthStore,
        owner: WatchHealthKitBiometricEngine?
    ) {
        guard let owner, let seriesList = samples as? [HKHeartbeatSeriesSample], !seriesList.isEmpty else {
            return
        }

        for series in seriesList {
            let accumulator = HeartbeatIntervalAccumulator(seriesStartReferenceTime: series.startDate.timeIntervalSinceReferenceDate)
            let beatQuery = HKHeartbeatSeriesQuery(heartbeatSeries: series) { _, timeSinceSeriesStart, precededByGap, done, _ in
                accumulator.appendBeat(timeSinceStart: timeSinceSeriesStart, precededByGap: precededByGap)
                if done {
                    let collected = accumulator.drain()
                    Task { @MainActor in
                        owner.ingestHardwareBeatBatch(collected)
                    }
                }
            }
            healthStore.execute(beatQuery)
        }
    }

    nonisolated private static func forwardRespiratorySamples(
        _ samples: [HKSample]?,
        owner: WatchHealthKitBiometricEngine?
    ) {
        guard let owner,
              let quantitySamples = samples as? [HKQuantitySample],
              let latest = quantitySamples.last else {
            return
        }
        let unit = HKUnit.count().unitDivided(by: .minute())
        let brpm = latest.quantity.doubleValue(for: unit)
        let ts = latest.endDate
        Task { @MainActor in
            owner.ingestLiveQuantitySample(heartRateBPM: nil, respiratoryBrPM: brpm, timestamp: ts)
        }
    }

    private func writeMindfulSessionSample(healthStore: HKHealthStore, startDate: Date, endDate: Date) async {
        let mindfulType = HKCategoryType(.mindfulSession)
        let metsUnit = HKUnit.kilocalorie()
            .unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .hour()))
        let averageMETs = HKQuantity(unit: metsUnit, doubleValue: 1.25)
        let metadata: [String: Any] = [
            HKMetadataKeyAverageMETs: averageMETs,
            "com.aethersynth.flow.vagalCoherence": latestMetrics.vagalCoherenceScore,
            "com.aethersynth.flow.rmssdMs": latestMetrics.rmssdMs,
            "com.aethersynth.flow.sdnnMs": latestMetrics.sdnnMs,
            "com.aethersynth.flow.binauralBeatHz": binauralBeatHz
        ]
        let sample = HKCategorySample(
            type: mindfulType,
            value: HKCategoryValue.notApplicable.rawValue,
            start: startDate,
            end: endDate,
            metadata: metadata
        )
        try? await healthStore.save(sample)
    }
}

// MARK: - Thread-Safe Beat Series Collector & Workout Delegate Relay

private final class HeartbeatIntervalAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private let seriesStartReferenceTime: TimeInterval
    private var previousBeatOffset: TimeInterval?
    private var collectedSamples: [RRIntervalSampleDTO] = []

    init(seriesStartReferenceTime: TimeInterval) {
        self.seriesStartReferenceTime = seriesStartReferenceTime
    }

    func appendBeat(timeSinceStart: TimeInterval, precededByGap: Bool) {
        lock.lock()
        defer { lock.unlock() }

        if !precededByGap, let prev = previousBeatOffset {
            let rrMs = (timeSinceStart - prev) * 1_000.0
            if rrMs >= 300.0 && rrMs <= 2_000.0 {
                collectedSamples.append(
                    RRIntervalSampleDTO(
                        timestamp: seriesStartReferenceTime + timeSinceStart,
                        rrMilliseconds: rrMs
                    )
                )
            }
        }
        previousBeatOffset = timeSinceStart
    }

    func drain() -> [RRIntervalSampleDTO] {
        lock.lock()
        defer { lock.unlock() }
        return collectedSamples
    }
}

private final class WatchWorkoutDelegateRelay: NSObject, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate, @unchecked Sendable {
    private weak var owner: WatchHealthKitBiometricEngine?

    init(owner: WatchHealthKitBiometricEngine) {
        self.owner = owner
        super.init()
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {}

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: any Error) {}

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(
        _ workoutBuilder: HKLiveWorkoutBuilder,
        didCollectDataOf collectedTypes: Set<HKSampleType>
    ) {
        let hrType = HKQuantityType(.heartRate)
        guard collectedTypes.contains(hrType),
              let stats = workoutBuilder.statistics(for: hrType),
              let recent = stats.mostRecentQuantity() else {
            return
        }
        let bpm = recent.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        let ts = Date.now
        Task { @MainActor [weak owner] in
            owner?.ingestLiveQuantitySample(heartRateBPM: bpm, respiratoryBrPM: nil, timestamp: ts)
        }
    }
}
#endif
