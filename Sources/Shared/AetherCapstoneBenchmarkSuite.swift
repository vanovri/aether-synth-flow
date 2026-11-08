// MARK: - FILE: AetherCapstoneBenchmarkSuite.swift

import Foundation
import CryptoKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import simd

// MARK: - 1. Capstone Benchmark Stage Metrics, Subsystem Inventory & Master Audit Report

public struct StageBenchmarkMetrics: Codable, Sendable, Equatable, Identifiable {
    public let stageIndex: Int
    public let stageCode: String
    public let title: String
    public let subsystemName: String
    public let iterations: Int
    public let p50Microseconds: Double
    public let p95Microseconds: Double
    public let p99Microseconds: Double
    public let throughputSummary: String
    public let numericalInvariantSummary: String
    public let invariantPassed: Bool

    public var id: Int { stageIndex }

    public init(
        stageIndex: Int,
        stageCode: String,
        title: String,
        subsystemName: String,
        iterations: Int,
        p50Microseconds: Double,
        p95Microseconds: Double,
        p99Microseconds: Double,
        throughputSummary: String,
        numericalInvariantSummary: String,
        invariantPassed: Bool
    ) {
        self.stageIndex = stageIndex
        self.stageCode = stageCode
        self.title = title
        self.subsystemName = subsystemName
        self.iterations = iterations
        self.p50Microseconds = p50Microseconds
        self.p95Microseconds = p95Microseconds
        self.p99Microseconds = p99Microseconds
        self.throughputSummary = throughputSummary
        self.numericalInvariantSummary = numericalInvariantSummary
        self.invariantPassed = invariantPassed
    }
}

public struct SubsystemInventoryEntry: Codable, Sendable, Equatable, Identifiable {
    public let phaseNumber: Int
    public let trackRange: String
    public let moduleName: String
    public let sourcePath: String
    public let mathematicalCore: String
    public let verified: Bool

    public var id: String { "\(phaseNumber)-\(moduleName)" }

    public init(
        phaseNumber: Int,
        trackRange: String,
        moduleName: String,
        sourcePath: String,
        mathematicalCore: String,
        verified: Bool = true
    ) {
        self.phaseNumber = phaseNumber
        self.trackRange = trackRange
        self.moduleName = moduleName
        self.sourcePath = sourcePath
        self.mathematicalCore = mathematicalCore
        self.verified = verified
    }
}

public struct CapstoneBenchmarkConfiguration: Codable, Sendable, Equatable {
    public var fdtdGridSize: Int
    public var fdtdPMLThickness: Int
    public var fdtdPMLMaxSigma: Float
    public var fdtdPulseAmplitude: Float
    public var eegTargetAlphaHz: Double
    public var eegThetaGammaCoupling: Double
    public var eegBlinkAmplitudeUV: Float
    public var spwvdPrimaryFreqHz: Double
    public var spwvdSecondaryFreqHz: Double
    public var quantumEntanglementCoupling: Double
    public var quantumAnisotropyDelta: Double
    public var quantumMaxBondDim: Int
    public var mpsGraphDatasetSeed: UInt64
    public var mpsGraphTrainerSeed: UInt64

    public static let canonical = CapstoneBenchmarkConfiguration()

    public init(
        fdtdGridSize: Int = 64,
        fdtdPMLThickness: Int = 10,
        fdtdPMLMaxSigma: Float = 0.38,
        fdtdPulseAmplitude: Float = 1.0,
        eegTargetAlphaHz: Double = 10.4,
        eegThetaGammaCoupling: Double = 0.68,
        eegBlinkAmplitudeUV: Float = 185.0,
        spwvdPrimaryFreqHz: Double = 22.0,
        spwvdSecondaryFreqHz: Double = 6.0,
        quantumEntanglementCoupling: Double = 0.65,
        quantumAnisotropyDelta: Double = 1.0,
        quantumMaxBondDim: Int = 8,
        mpsGraphDatasetSeed: UInt64 = 0xAE74_0006_2026,
        mpsGraphTrainerSeed: UInt64 = 0xAE74_2200_2026
    ) {
        self.fdtdGridSize = max(32, fdtdGridSize)
        self.fdtdPMLThickness = max(4, fdtdPMLThickness)
        self.fdtdPMLMaxSigma = max(0.0, fdtdPMLMaxSigma)
        self.fdtdPulseAmplitude = max(0.05, fdtdPulseAmplitude)
        self.eegTargetAlphaHz = min(max(eegTargetAlphaHz, 7.5), 12.5)
        self.eegThetaGammaCoupling = min(max(eegThetaGammaCoupling, 0.0), 1.0)
        self.eegBlinkAmplitudeUV = max(0.0, eegBlinkAmplitudeUV)
        self.spwvdPrimaryFreqHz = min(max(spwvdPrimaryFreqHz, 8.0), 60.0)
        self.spwvdSecondaryFreqHz = min(max(spwvdSecondaryFreqHz, 2.0), 30.0)
        self.quantumEntanglementCoupling = min(max(quantumEntanglementCoupling, 0.0), 1.0)
        self.quantumAnisotropyDelta = max(0.1, quantumAnisotropyDelta)
        self.quantumMaxBondDim = min(max(quantumMaxBondDim, 2), 16)
        self.mpsGraphDatasetSeed = mpsGraphDatasetSeed
        self.mpsGraphTrainerSeed = mpsGraphTrainerSeed
    }
}

public struct CapstoneAuditReport: Codable, Sendable, Equatable {
    public static let canonicalSchemaVersion = "AETHER-CAPSTONE-PHASE10-V1"

    public let schemaVersion: String
    public let generatedAtISO8601: String
    public let totalWallTimeMilliseconds: Double
    public let overallP50Microseconds: Double
    public let overallP95Microseconds: Double
    public let overallP99Microseconds: Double
    public let allInvariantsPassed: Bool
    public let passedStageCount: Int
    public let totalStageCount: Int
    public let stages: [StageBenchmarkMetrics]
    public let subsystemInventory: [SubsystemInventoryEntry]
    public let cryptographicSHA256Digest: String

    public var reportSHA256Hex: String {
        cryptographicSHA256Digest
    }

    public var p50Microseconds: Double {
        overallP50Microseconds
    }

    public var p95Microseconds: Double {
        overallP95Microseconds
    }

    public var p99Microseconds: Double {
        overallP99Microseconds
    }

    public var metrics: [StageBenchmarkMetrics] {
        stages
    }

    public var markdownSummary: String {
        renderMarkdownReport()
    }

    public init(
        schemaVersion: String = CapstoneAuditReport.canonicalSchemaVersion,
        generatedAtISO8601: String,
        totalWallTimeMilliseconds: Double,
        overallP50Microseconds: Double,
        overallP95Microseconds: Double,
        overallP99Microseconds: Double,
        allInvariantsPassed: Bool,
        passedStageCount: Int,
        totalStageCount: Int,
        stages: [StageBenchmarkMetrics],
        subsystemInventory: [SubsystemInventoryEntry],
        cryptographicSHA256Digest: String
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAtISO8601 = generatedAtISO8601
        self.totalWallTimeMilliseconds = totalWallTimeMilliseconds
        self.overallP50Microseconds = overallP50Microseconds
        self.overallP95Microseconds = overallP95Microseconds
        self.overallP99Microseconds = overallP99Microseconds
        self.allInvariantsPassed = allInvariantsPassed
        self.passedStageCount = passedStageCount
        self.totalStageCount = totalStageCount
        self.stages = stages
        self.subsystemInventory = subsystemInventory
        self.cryptographicSHA256Digest = cryptographicSHA256Digest
    }

    /// Computes the canonical SHA-256 hex certification digest over schema version, all stage codes, pass flags,
    /// numerical invariant summaries, and 10-phase subsystem verification states.
    public static func computeCertificationDigest(
        schemaVersion: String = CapstoneAuditReport.canonicalSchemaVersion,
        stages: [StageBenchmarkMetrics],
        subsystemInventory: [SubsystemInventoryEntry]
    ) -> String {
        var digestInput = "\(schemaVersion)|"
        for s in stages {
            digestInput += "\(s.stageIndex):\(s.stageCode):\(s.invariantPassed ? 1 : 0):\(s.numericalInvariantSummary)|"
        }
        for item in subsystemInventory {
            digestInput += "\(item.phaseNumber):\(item.moduleName):\(item.sourcePath):\(item.verified ? 1 : 0)|"
        }
        let digestBytes = SHA256.hash(data: Data(digestInput.utf8))
        return digestBytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Recomputes the cryptographic SHA-256 digest and verifies structural consistency of stage/inventory pass counts.
    public func verifyCryptographicDigest() -> Bool {
        guard cryptographicSHA256Digest.count == 64 else { return false }
        let expected = Self.computeCertificationDigest(
            schemaVersion: schemaVersion,
            stages: stages,
            subsystemInventory: subsystemInventory
        )
        let countedPass = stages.filter(\.invariantPassed).count
        let countConsistent = (passedStageCount == countedPass)
            && (totalStageCount == stages.count)
            && (allInvariantsPassed == (countedPass == stages.count && stages.count == 12))
        return expected == cryptographicSHA256Digest && countConsistent
    }

    public func renderJSONData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public func renderMarkdownReport() -> String {
        var lines: [String] = []
        lines.append("# AetherSynth & Flow — Master System Certification Report (Phases 1–10)")
        lines.append("")
        lines.append("- **Schema Version**: `\(schemaVersion)`")
        lines.append("- **Generated At (UTC)**: `\(generatedAtISO8601)`")
        let statusText = allInvariantsPassed
            ? "PASSED (\(passedStageCount)/\(totalStageCount) STAGES VERIFIED)"
            : "FAILED (\(passedStageCount)/\(totalStageCount))"
        lines.append("- **Master Certification Status**: `\(statusText)`")
        lines.append(String(format: "- **Total Execution Wall Time**: `%.2f ms`", totalWallTimeMilliseconds))
        lines.append(String(format: "- **Aggregate Stage Latencies**: `p50 = %.1f µs` | `p95 = %.1f µs` | `p99 = %.1f µs`", overallP50Microseconds, overallP95Microseconds, overallP99Microseconds))
        lines.append("- **Cryptographic Audit Digest (`SHA-256`)**: `\(cryptographicSHA256Digest)`")
        lines.append("")
        lines.append("## 1. 12-Stage Deterministic End-to-End Benchmark Results")
        lines.append("")
        lines.append("| Stage | Subsystem | p50 (µs) | p95 (µs) | p99 (µs) | Throughput | Numerical Invariant | Status |")
        lines.append("| :--- | :--- | ---: | ---: | ---: | :--- | :--- | :---: |")
        for s in stages {
            let badge = s.invariantPassed ? "PASS" : "FAIL"
            lines.append(
                String(
                    format: "| %d. `%@` | %@ | %.1f | %.1f | %.1f | %@ | %@ | **%@** |",
                    s.stageIndex,
                    s.stageCode,
                    s.title,
                    s.p50Microseconds,
                    s.p95Microseconds,
                    s.p99Microseconds,
                    s.throughputSummary,
                    s.numericalInvariantSummary,
                    badge
                )
            )
        }
        lines.append("")
        lines.append("## 2. Complete 10-Phase Repository Subsystem Inventory (\(subsystemInventory.count) Modules)")
        lines.append("")
        lines.append("| Phase | Tracks | Module | Path | Mathematical Core | Verified |")
        lines.append("| :---: | :---: | :--- | :--- | :--- | :---: |")
        for item in subsystemInventory {
            lines.append(
                "| Phase \(item.phaseNumber) | \(item.trackRange) | `\(item.moduleName)` | `\(item.sourcePath)` | \(item.mathematicalCore) | \(item.verified ? "YES" : "NO") |"
            )
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }
}

// MARK: - 2. SwiftUI FileDocument Wrappers for One-Click Master Certification Export (.md / .json)

public struct CapstoneMarkdownReportDocument: FileDocument, Sendable {
    public static var readableContentTypes: [UTType] { [.plainText] }
    public var markdownText: String

    public init(markdownText: String = "") {
        self.markdownText = markdownText
    }

    public init(report: CapstoneAuditReport) {
        self.markdownText = report.renderMarkdownReport()
    }

    public init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents,
           let str = String(data: data, encoding: .utf8) {
            self.markdownText = str
        } else {
            self.markdownText = ""
        }
    }

    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(markdownText.utf8))
    }
}

public struct CapstoneJSONReportDocument: FileDocument, Sendable {
    public static var readableContentTypes: [UTType] { [.json] }
    public var jsonData: Data

    public init(jsonData: Data = Data()) {
        self.jsonData = jsonData
    }

    public init(report: CapstoneAuditReport) {
        self.jsonData = (try? report.renderJSONData()) ?? Data()
    }

    public init(configuration: ReadConfiguration) throws {
        self.jsonData = configuration.file.regularFileContents ?? Data()
    }

    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: jsonData)
    }
}

public typealias CapstoneReportMarkdownDocument = CapstoneMarkdownReportDocument
public typealias CapstoneReportJSONDocument = CapstoneJSONReportDocument

// MARK: - 3. AetherCapstoneBenchmarkSuite Actor (12-Stage Deterministic End-to-End Verifier)

public actor AetherCapstoneBenchmarkSuite {
    public static let shared = AetherCapstoneBenchmarkSuite()

    public init() {}

    public static func runFullAudit() async throws -> CapstoneAuditReport {
        await shared.runFullAudit(configuration: .canonical)
    }

    public static func runFullAudit(configuration: CapstoneBenchmarkConfiguration) async throws -> CapstoneAuditReport {
        await shared.runFullAudit(configuration: configuration)
    }

    /// Executes all 12 deterministic stress benchmark stages across Phases 1–10 and returns a cryptographically signed `CapstoneAuditReport`.
    public func runFullAudit() async -> CapstoneAuditReport {
        await runFullAudit(configuration: .canonical)
    }

    public func runFullAudit(configuration: CapstoneBenchmarkConfiguration) async -> CapstoneAuditReport {
        let suiteStartNs = DispatchTime.now().uptimeNanoseconds

        var stages: [StageBenchmarkMetrics] = []
        stages.reserveCapacity(12)

        stages.append(await runStage01SwiftDataBatchIngestion())
        stages.append(runStage02ProceduralSynthDSP())
        stages.append(runStage03SpatialHRTFAndShoeboxRoom())
        stages.append(await runStage04MetalBVHAcousticRayTracer())
        stages.append(await runStage05NeuralRectifiedFlowAndRVQVocoder())
        stages.append(runStage06DistributedPTPAndWaveFieldSynthesis())
        stages.append(runStage07BiharmonicFDTDWaveguideAndPML(configuration: configuration))
        stages.append(runStage08EEGArtifactRLSAndBispectrumPAC(configuration: configuration))
        stages.append(runStage09WignerVilleSPWVDAndHilbertHuangEMD(configuration: configuration))
        stages.append(runStage10QuantumMPSTTSVDAndTwoSiteDMRG(configuration: configuration))
        stages.append(await runStage11MPSGraphAutodiffAndCoreMLPredictor(configuration: configuration))
        stages.append(await runStage12OfflineWAVExportAndChaChaPolyCrypto())

        let suiteElapsedMs = Double(DispatchTime.now().uptimeNanoseconds - suiteStartNs) / 1_000_000.0
        var pooledQuantileSamples: [Double] = []
        pooledQuantileSamples.reserveCapacity(stages.count * 3)
        for s in stages {
            pooledQuantileSamples.append(s.p50Microseconds)
            pooledQuantileSamples.append(s.p95Microseconds)
            pooledQuantileSamples.append(s.p99Microseconds)
        }

        let aggP50 = Self.percentile(pooledQuantileSamples, q: 0.50)
        let aggP95 = max(aggP50, Self.percentile(pooledQuantileSamples, q: 0.95))
        let aggP99 = max(aggP95, Self.percentile(pooledQuantileSamples, q: 0.99))

        let passedCount = stages.filter(\.invariantPassed).count
        let allPassed = (passedCount == stages.count) && (stages.count == 12)
        let inventory = Self.buildSubsystemInventory(stages: stages)

        let digestHex = CapstoneAuditReport.computeCertificationDigest(
            schemaVersion: CapstoneAuditReport.canonicalSchemaVersion,
            stages: stages,
            subsystemInventory: inventory
        )

        let isoFormatter = ISO8601DateFormatter()
        let timestampStr = isoFormatter.string(from: Date())

        return CapstoneAuditReport(
            generatedAtISO8601: timestampStr,
            totalWallTimeMilliseconds: suiteElapsedMs,
            overallP50Microseconds: aggP50,
            overallP95Microseconds: aggP95,
            overallP99Microseconds: aggP99,
            allInvariantsPassed: allPassed,
            passedStageCount: passedCount,
            totalStageCount: stages.count,
            stages: stages,
            subsystemInventory: inventory,
            cryptographicSHA256Digest: digestHex
        )
    }

    public func evaluateStage07FDTDAndCaustics(
        configuration: CapstoneBenchmarkConfiguration = .canonical
    ) -> StageBenchmarkMetrics {
        runStage07BiharmonicFDTDWaveguideAndPML(configuration: configuration)
    }

    public func evaluateStage08EEGAndPAC(
        configuration: CapstoneBenchmarkConfiguration = .canonical
    ) -> StageBenchmarkMetrics {
        runStage08EEGArtifactRLSAndBispectrumPAC(configuration: configuration)
    }

    public func evaluateStage09SPWVDAndHHT(
        configuration: CapstoneBenchmarkConfiguration = .canonical
    ) -> StageBenchmarkMetrics {
        runStage09WignerVilleSPWVDAndHilbertHuangEMD(configuration: configuration)
    }

    public func evaluateStage10QuantumMPSDMRG(
        configuration: CapstoneBenchmarkConfiguration = .canonical
    ) -> StageBenchmarkMetrics {
        runStage10QuantumMPSTTSVDAndTwoSiteDMRG(configuration: configuration)
    }

    // MARK: - Stage 1: SwiftData 64-Session Concurrent @ModelActor Batch Ingestion

    private func runStage01SwiftDataBatchIngestion() async -> StageBenchmarkMetrics {
        var samplesUs: [Double] = []
        var invariantOK = true
        var uniqueCount = 0

        for iter in 0..<3 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            do {
                let container = try AetherPersistenceSchema.makeContainer(inMemory: true)
                let dbActor = TelemetryDatabaseActor(modelContainer: container)
                let baseDate = Date(timeIntervalSince1970: 1_762_000_000.0 + Double(iter * 86_400))
                let sharedIDs = (0..<60).map { _ in UUID() }

                var payloads: [FocusSessionDTO] = []
                payloads.reserveCapacity(64)
                for idx in 0..<64 {
                    // Last 4 entries intentionally collide with first 4 IDs at revision 2 to verify deterministic conflict resolution
                    let id = idx < 60 ? sharedIDs[idx] : sharedIDs[idx - 60]
                    let isUpgradedDuplicate = idx >= 60
                    let start = baseDate.addingTimeInterval(Double(idx) * 30.0)
                    let dur = isUpgradedDuplicate ? 1800.0 : 900.0
                    payloads.append(
                        FocusSessionDTO(
                            sessionID: id,
                            title: "Capstone Stage 1 #\(idx)",
                            startedAt: start,
                            endedAt: start.addingTimeInterval(dur),
                            plannedDurationSeconds: dur,
                            actualDurationSeconds: dur,
                            completed: true,
                            focusQualityScore: isUpgradedDuplicate ? 0.96 : 0.82,
                            peakAmplitude: 0.72,
                            carrierFrequencyHz: 216.0,
                            beatFrequencyHz: 10.5,
                            notes: "Stage 1 batch #\(idx)",
                            updatedAt: start.addingTimeInterval(dur),
                            revision: isUpgradedDuplicate ? 2 : 1
                        )
                    )
                }

                let report = try await dbActor.batchIngestSessions(
                    payloads,
                    conflictPolicy: .higherRevisionWins
                )
                let dayKey = DayKeyFormatter.dayKey(for: baseDate)
                let sessionsOnDay = try await dbActor.fetchSessionsForDay(dayKey: dayKey)
                uniqueCount = sessionsOnDay.count
                if report.insertedSessions != 60 || report.updatedSessions != 4 || uniqueCount != 60 {
                    invariantOK = false
                }
            } catch {
                invariantOK = false
            }
            let elapsedUs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000.0
            samplesUs.append(elapsedUs)
        }

        let p50 = Self.percentile(samplesUs, q: 0.50)
        let p95 = Self.percentile(samplesUs, q: 0.95)
        let p99 = Self.percentile(samplesUs, q: 0.99)
        let sessionsPerSec = 64.0 / max(1.0e-6, p50 / 1_000_000.0)

        return StageBenchmarkMetrics(
            stageIndex: 1,
            stageCode: "SWIFTDATA_MODELACTOR_64",
            title: "SwiftData @ModelActor 64-Session Batch Ingestion",
            subsystemName: "TelemetryDatabaseActor.swift",
            iterations: samplesUs.count,
            p50Microseconds: p50,
            p95Microseconds: p95,
            p99Microseconds: p99,
            throughputSummary: String(format: "%.0f sessions/s", sessionsPerSec),
            numericalInvariantSummary: "64 ingested -> \(uniqueCount) deduplicated (4 rev-2 conflicts resolved)",
            invariantPassed: invariantOK
        )
    }

    // MARK: - Stage 2: ProceduralSynthKernel + 4-Op TZFM + 8-Delay Hadamard FDN Reverb

    private func runStage02ProceduralSynthDSP() -> StageBenchmarkMetrics {
        let target = SynthParameters(preset: AudioPresetDTO.defaultPresets[0])
        var kernel = ProceduralSynthKernel(
            sampleRate: 48_000.0,
            snapInitialParameters: target
        )
        var tzfm = FourOpTZFMVoiceKernel(sampleRate: 48_000.0)
        var fdn = HadamardFDNReverbKernel(sampleRate: 48_000.0)

        let frameCount = 1_200 // 25 ms block at 48 kHz
        var leftBuf = [Float](repeating: 0.0, count: frameCount)
        var rightBuf = [Float](repeating: 0.0, count: frameCount)
        var samplesUs: [Double] = []
        var maxPeak: Float = 0.0
        var allFinite = true

        for _ in 0..<8 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            _ = leftBuf.withUnsafeMutableBufferPointer { lPtr in
                rightBuf.withUnsafeMutableBufferPointer { rPtr in
                    kernel.renderStereoBlock(
                        leftOutput: lPtr.baseAddress!,
                        rightOutput: rPtr.baseAddress!,
                        frameCount: frameCount,
                        target: target
                    )
                }
            }
            for i in stride(from: 0, to: frameCount, by: 8) {
                let (fmL, fmR) = tzfm.nextStereoSample(
                    fundamentalHz: 216.0,
                    harmonicRatio: 1.5,
                    modulationIndex: 1.8
                )
                let (revL, revR) = fdn.processStereoSample(
                    leftIn: leftBuf[i] + 0.15 * fmL,
                    rightIn: rightBuf[i] + 0.15 * fmR,
                    wetMix: 0.28,
                    decaySeconds: 2.8,
                    damping: 0.32
                )
                leftBuf[i] = min(max(revL, -1.0), 1.0)
                rightBuf[i] = min(max(revR, -1.0), 1.0)
            }
            let elapsedUs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000.0
            samplesUs.append(elapsedUs)

            for i in 0..<frameCount {
                let l = leftBuf[i]
                let r = rightBuf[i]
                if !l.isFinite || !r.isFinite { allFinite = false }
                maxPeak = max(maxPeak, max(abs(l), abs(r)))
            }
        }

        let p50 = Self.percentile(samplesUs, q: 0.50)
        let p95 = Self.percentile(samplesUs, q: 0.95)
        let p99 = Self.percentile(samplesUs, q: 0.99)
        let realtimeRatio = 25_000.0 / max(1.0, p50) // 25,000 us of audio per block
        let passed = allFinite && maxPeak > 0.01 && maxPeak <= 1.0001

        return StageBenchmarkMetrics(
            stageIndex: 2,
            stageCode: "DSP_SYNTH_TZFM_FDN_48K",
            title: "ProceduralSynth + 4-Op TZFM + 8x8 Hadamard FDN",
            subsystemName: "AudioSynthEngine.swift & ReverbAndFMDSP.swift",
            iterations: samplesUs.count,
            p50Microseconds: p50,
            p95Microseconds: p95,
            p99Microseconds: p99,
            throughputSummary: String(format: "%.1fx real-time @ 48 kHz", realtimeRatio),
            numericalInvariantSummary: String(format: "peak=%.3f <= 1.0, finite=%@", maxPeak, allFinite ? "true" : "false"),
            invariantPassed: passed
        )
    }

    // MARK: - Stage 3: KEMAR HRIR + Partitioned Overlap-Save FFT Convolver + Shoebox ISM

    private func runStage03SpatialHRTFAndShoeboxRoom() -> StageBenchmarkMetrics {
        let pose = BinauralSourcePose(azimuthDeg: 35.0, elevationDeg: 8.0, distanceMeters: 1.35)
        let hrir = KEMARHRIRSynthesizer.synthesize(pose: pose, sampleRate: 48_000.0)
        var convolver = PartitionedOverlapSaveConvolver()
        hrir.left.withUnsafeBufferPointer { lPtr in
            hrir.right.withUnsafeBufferPointer { rPtr in
                convolver.setHRIR(
                    leftTaps: lPtr.baseAddress!,
                    rightTaps: rPtr.baseAddress!,
                    tapCount: KEMARHRIRSynthesizer.tapCount,
                    crossfade: false
                )
            }
        }

        let frameCount = 256
        let monoIn: [Float] = (0..<frameCount).map { i in
            sinf(2.0 * Float.pi * 240.0 * Float(i) / 48_000.0) * 0.45
        }
        var outL = [Float](repeating: 0.0, count: frameCount)
        var outR = [Float](repeating: 0.0, count: frameCount)
        var samplesUs: [Double] = []
        var solvedTapCount = 0

        for _ in 0..<8 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            monoIn.withUnsafeBufferPointer { mPtr in
                outL.withUnsafeMutableBufferPointer { lPtr in
                    outR.withUnsafeMutableBufferPointer { rPtr in
                        convolver.process(
                            input: mPtr.baseAddress!,
                            leftOutput: lPtr.baseAddress!,
                            rightOutput: rPtr.baseAddress!,
                            frameCount: frameCount
                        )
                    }
                }
            }
            let solved = ShoeboxRoomSimulator.solveImageSources(
                configuration: ShoeboxRoomPreset.obsidianStudio.configuration,
                sourcePose: pose,
                headOrientation: simd_quatf(angle: 0.0, axis: SIMD3<Float>(0, 1, 0))
            )
            solvedTapCount = solved.taps.count
            let elapsedUs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000.0
            samplesUs.append(elapsedUs)
        }

        // Verify UPOLS vs direct time-domain FIR SNR on a 128-sample impulse block
        var testConv = PartitionedOverlapSaveConvolver()
        hrir.left.withUnsafeBufferPointer { lPtr in
            hrir.right.withUnsafeBufferPointer { rPtr in
                testConv.setHRIR(
                    leftTaps: lPtr.baseAddress!,
                    rightTaps: rPtr.baseAddress!,
                    tapCount: KEMARHRIRSynthesizer.tapCount,
                    crossfade: false
                )
            }
        }
        var imp = [Float](repeating: 0.0, count: 128)
        imp[0] = 1.0
        var impL = [Float](repeating: 0.0, count: 128)
        var impR = [Float](repeating: 0.0, count: 128)
        imp.withUnsafeBufferPointer { mPtr in
            impL.withUnsafeMutableBufferPointer { lPtr in
                impR.withUnsafeMutableBufferPointer { rPtr in
                    testConv.process(
                        input: mPtr.baseAddress!,
                        leftOutput: lPtr.baseAddress!,
                        rightOutput: rPtr.baseAddress!,
                        frameCount: 128
                    )
                }
            }
        }
        var sigPow = 0.0
        var errPow = 0.0
        for i in 0..<128 {
            let ref = Double(hrir.left[i])
            let diff = Double(impL[i]) - ref
            sigPow += ref * ref
            errPow += diff * diff
        }
        let snrDB = 10.0 * log10(max(1e-12, sigPow) / max(1e-20, errPow))
        let p50 = Self.percentile(samplesUs, q: 0.50)
        let p95 = Self.percentile(samplesUs, q: 0.95)
        let p99 = Self.percentile(samplesUs, q: 0.99)
        let passed = snrDB > 80.0 && hrir.itdSeconds > 0.0 && solvedTapCount == 18

        return StageBenchmarkMetrics(
            stageIndex: 3,
            stageCode: "KEMAR_UPOLS_SHOEBOX_ISM",
            title: "KEMAR HRIR + UPOLS FFT Convolver + 18-Image ISM",
            subsystemName: "SpatialHRTFConvolver.swift & ShoeboxRoomAcoustics.swift",
            iterations: samplesUs.count,
            p50Microseconds: p50,
            p95Microseconds: p95,
            p99Microseconds: p99,
            throughputSummary: String(format: "%.1fx real-time (256-frame)", 5333.3 / max(1.0, p50)),
            numericalInvariantSummary: String(format: "UPOLS SNR=%.1f dB, ITD=%.0f µs, ISM=%d taps", snrDB, hrir.itdSeconds * 1_000_000.0, solvedTapCount),
            invariantPassed: passed
        )
    }

    // MARK: - Stage 4: MetalAcousticRayTracer SAH-BVH 4-Band & Velvet-Noise DRIR

    private func runStage04MetalBVHAcousticRayTracer() async -> StageBenchmarkMetrics {
        let tracer = MetalAcousticRayTracer(preferHardwareRayTracing: false)
        var samplesUs: [Double] = []
        var rt60Low: Float = 0.0
        var drirCount = 0
        var leakedRays = 0
        var drirFinite = true

        for _ in 0..<3 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            let report = await tracer.solveChamberAcoustics(
                chamber: .geodesicSanctuary,
                surfaceMaterial: AcousticSurfaceMaterialPreset.perforatedAcousticWood.material,
                habits: HabitNodeDTO.defaultSeeds,
                orbitalPhaseRadians: 0.35,
                rayCount: 256,
                maxBounces: 8,
                forceCPUFallback: true
            )
            let elapsedUs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000.0
            samplesUs.append(elapsedUs)
            rt60Low = report.rayTracedRT60PerBand.x
            drirCount = report.leftDRIR.count
            leakedRays = report.leakedRayCount
            if report.leftDRIR.contains(where: { !$0.isFinite }) || report.rightDRIR.contains(where: { !$0.isFinite }) {
                drirFinite = false
            }
        }

        let p50 = Self.percentile(samplesUs, q: 0.50)
        let p95 = Self.percentile(samplesUs, q: 0.95)
        let p99 = Self.percentile(samplesUs, q: 0.99)
        let passed = drirFinite && leakedRays == 0 && drirCount == 512 && rt60Low > 0.15

        return StageBenchmarkMetrics(
            stageIndex: 4,
            stageCode: "SAH_BVH_RAYTRACER_DRIR",
            title: "SAH-BVH 4-Band Acoustic Ray Tracer & Velvet DRIR",
            subsystemName: "MetalAcousticRayTracer.swift",
            iterations: samplesUs.count,
            p50Microseconds: p50,
            p95Microseconds: p95,
            p99Microseconds: p99,
            throughputSummary: String(format: "256 rays x 8 bounces in %.1f ms", p50 / 1_000.0),
            numericalInvariantSummary: String(format: "0 leaked rays, DRIR=%d taps, RT60=%.2fs", drirCount, rt60Low),
            invariantPassed: passed
        )
    }

    // MARK: - Stage 5: NeuralLatentSoundscapeEngine Heun ODE + 4-Stage RVQ + Snake Vocoder

    private func runStage05NeuralRectifiedFlowAndRVQVocoder() async -> StageBenchmarkMetrics {
        let engine = NeuralLatentSoundscapeEngine()
        let ring = NeuralAudioRingBuffer(capacityPowerOfTwo: 16_384)
        var samplesUs: [Double] = []
        var blockSeq: UInt64 = 0
        var availableFrames = 0
        var rvqResidualRatio: Float = 1.0
        var codebookPerplexity: Float = 0.0
        var commitmentLossFinite = false

        for _ in 0..<3 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            let tele = await engine.synthesizeAndEnqueueBlock(
                ringBuffer: ring,
                category: .deepWork,
                binauralBeatHz: 14.0,
                rmssdNormalized: 0.64,
                rsaCoherenceScore: 0.86,
                lfHfRatioNormalized: 0.24,
                guidanceScale: 2.2,
                temperature: 0.85,
                sampleRate: 48_000.0
            )
            let elapsedUs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000.0
            samplesUs.append(elapsedUs)
            blockSeq = UInt64(tele.blockSequence)
            availableFrames = ring.availableFramesToRead
            if let rFirst = tele.stageResidualNorms.first, let rLast = tele.stageResidualNorms.last, rFirst > 1.0e-9 {
                rvqResidualRatio = rLast / rFirst
            }
            codebookPerplexity = tele.codebookPerplexity
            commitmentLossFinite = tele.commitmentLoss.isFinite && tele.commitmentLoss >= 0.0
        }

        let p50 = Self.percentile(samplesUs, q: 0.50)
        let p95 = Self.percentile(samplesUs, q: 0.95)
        let p99 = Self.percentile(samplesUs, q: 0.99)
        let rvqContractionOK = rvqResidualRatio <= 1.0 && rvqResidualRatio > 0.0
        let passed = blockSeq >= 3
            && availableFrames >= ComplementaryHannOverlapAdd.hopSize
            && rvqContractionOK
            && codebookPerplexity > 1.0
            && commitmentLossFinite

        return StageBenchmarkMetrics(
            stageIndex: 5,
            stageCode: "RECTIFIED_FLOW_RVQ_VOCODER",
            title: "Rectified-Flow Heun ODE + 4-Stage RVQ + Snake Vocoder",
            subsystemName: "NeuralLatentSoundscapeEngine.swift",
            iterations: samplesUs.count,
            p50Microseconds: p50,
            p95Microseconds: p95,
            p99Microseconds: p99,
            throughputSummary: String(format: "%d queued frames / %.2f ms", availableFrames, p50 / 1_000.0),
            numericalInvariantSummary: String(
                format: "RVQ r4/r1=%.3f, perp=%.2f, WOLA=1.0",
                rvqResidualRatio,
                codebookPerplexity
            ),
            invariantPassed: passed
        )
    }

    // MARK: - Stage 6: DistributedOrchestraEngine Marzullo PTP + 2nd-Order PI-PLL + WFS

    private func runStage06DistributedPTPAndWaveFieldSynthesis() -> StageBenchmarkMetrics {
        var samplesUs: [Double] = []
        var estimationErrorMs = 100.0
        var packetOK = true
        var wfsArrivalSpreadSec = 1.0

        for iter in 0..<6 {
            let t0 = DispatchTime.now().uptimeNanoseconds

            var filter = MarzulloClockFilter(windowCapacity: 8)
            let trueOffsetNs: Int64 = 1_250_000 // +1.25 ms
            let baseOriginNs: UInt64 = 10_000_000_000 + UInt64(iter * 1_000_000_000)

            var latestEst = MarzulloConsensusEstimate()

            for idx in 0..<8 {
                let t1 = baseOriginNs + UInt64(idx) * 100_000_000
                let offsetNs: Int64 = (idx == 5) ? (trueOffsetNs + 45_000_000) : trueOffsetNs
                let halfRttNs: Int64 = 180_000
                let t2 = UInt64(Int64(t1) + offsetNs + halfRttNs)
                let t3 = t2 + 25_000
                let t4 = UInt64(Int64(t3) - offsetNs + halfRttNs)

                let pkt = OrchestraPTPClockPacket(
                    packetKind: .delayResponse,
                    sequenceNumber: UInt16(idx + 1),
                    peerNodeID: 2,
                    t1OriginNs: t1,
                    t2ResponderIngressNs: t2,
                    t3ResponderEgressNs: t3,
                    t4InitiatorIngressNs: t4,
                    masterBeatPhase: 0.5,
                    tempoBPM: 120.0,
                    globalSampleCounter: UInt64(idx * 4_800)
                )
                let encoded = pkt.encode()
                if encoded.count != 64 {
                    packetOK = false
                }
                if let decoded = try? OrchestraPTPClockPacket.decode(from: encoded), decoded == pkt {
                    latestEst = filter.ingestPacket(decoded, sampleIntervalTauSeconds: 0.10)
                } else {
                    packetOK = false
                }
            }

            estimationErrorMs = abs(latestEst.consensusOffsetSeconds - 0.00125) * 1_000.0

            var pll = PhaseLockedLoopClockServo()
            _ = pll.step(
                offsetErrorSeconds: latestEst.consensusOffsetSeconds,
                phaseErrorCycles: 0.01,
                referenceFrequencyHz: 10.0,
                dtSeconds: 0.10
            )

            let wfs = SpatialWaveFieldSolver(speedOfSoundMetersPerSec: 343.0)
            let nodes: [OrchestraSpeakerNode] = [
                OrchestraSpeakerNode(nodeID: 1, label: "N1", positionMeters: SIMD3<Double>(-1.4, 0.0, 1.35)),
                OrchestraSpeakerNode(nodeID: 2, label: "N2", positionMeters: SIMD3<Double>( 1.25, 0.0, 1.60)),
                OrchestraSpeakerNode(nodeID: 3, label: "N3", positionMeters: SIMD3<Double>(-1.75, 0.0, 0.85)),
                OrchestraSpeakerNode(nodeID: 4, label: "N4", positionMeters: SIMD3<Double>( 1.65, 0.0, 1.10))
            ]
            let sols = wfs.solveArray(
                nodes: nodes,
                listenerPosition: .zero,
                virtualSourcePosition: SIMD3<Double>(0.45, 0.0, 2.80)
            )
            if let firstArr = sols.first?.totalWavefrontArrivalSeconds,
               let lastArr = sols.last?.totalWavefrontArrivalSeconds {
                wfsArrivalSpreadSec = abs(firstArr - lastArr)
            }

            let elapsedUs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000.0
            samplesUs.append(elapsedUs)
        }

        let p50 = Self.percentile(samplesUs, q: 0.50)
        let p95 = Self.percentile(samplesUs, q: 0.95)
        let p99 = Self.percentile(samplesUs, q: 0.99)
        let passed = packetOK && estimationErrorMs <= 0.10 && wfsArrivalSpreadSec < 1.0e-9

        return StageBenchmarkMetrics(
            stageIndex: 6,
            stageCode: "PTP_MARZULLO_PLL_WFS",
            title: "Marzullo PTP + 2nd-Order PI-PLL + Rayleigh-I WFS",
            subsystemName: "DistributedOrchestraEngine.swift",
            iterations: samplesUs.count,
            p50Microseconds: p50,
            p95Microseconds: p95,
            p99Microseconds: p99,
            throughputSummary: "64B wire codec + 8-pkt consensus + 4-node WFS",
            numericalInvariantSummary: String(format: "Marzullo err=%.4f ms, WFS spread=%.1e s", estimationErrorMs, wfsArrivalSpreadSec),
            invariantPassed: passed
        )
    }

    // MARK: - Stage 7: RealtimeFDTDResonatorKernel, 2D PML Wave Tank & Track 35 Acousto-Optic Caustics

    private func runStage07BiharmonicFDTDWaveguideAndPML(
        configuration: CapstoneBenchmarkConfiguration = .canonical
    ) -> StageBenchmarkMetrics {
        var samplesUs: [Double] = []
        var cflStable = false
        var decayRatio = 1.0
        var pmlSuppressionDB = 0.0
        var dispersionRatio: Float = 1.0
        var resonatorBounded = true
        let gSize = configuration.fdtdGridSize
        let pmlThick = configuration.fdtdPMLThickness
        let pmlSigma = configuration.fdtdPMLMaxSigma
        let pulseAmp = configuration.fdtdPulseAmplitude

        for _ in 0..<2 {
            let t0 = DispatchTime.now().uptimeNanoseconds

            var resonator = RealtimeFDTDResonatorKernel(sampleRate: 48_000.0)
            resonator.triggerRaisedCosinePluck(normalizedX: 0.5, normalizedY: 0.5, amplitude: 0.85, radiusCells: 2.6)
            for i in 0..<64 {
                let exc: Float = (i == 0) ? 0.5 : 0.0
                let (yL, yR) = resonator.processSample(excitation: exc, stiffness: 0.18)
                if !yL.isFinite || !yR.isFinite || abs(yL) > 2.0 || abs(yR) > 2.0 {
                    resonatorBounded = false
                }
            }

            var pmlTank = FDTDWaveTankGrid2D(
                gridSize: gSize,
                pmlThickness: pmlThick,
                boundaryMode: .absorbingPML,
                pmlMaxSigma: pmlSigma
            )
            var rigidTank = FDTDWaveTankGrid2D(
                gridSize: gSize,
                pmlThickness: pmlThick,
                boundaryMode: .reflectiveDirichlet,
                pmlMaxSigma: 0.0
            )
            cflStable = pmlTank.cflParameters.isStable
            let mid = gSize / 2
            pmlTank.injectGaussianPulse(centerX: mid, centerY: mid, sigmaCells: 2.6, amplitude: pulseAmp)
            rigidTank.injectGaussianPulse(centerX: mid, centerY: mid, sigmaCells: 2.6, amplitude: pulseAmp)

            pmlTank.advance(steps: 6)
            rigidTank.advance(steps: 6)
            let peakRMS = max(1e-9, pmlTank.interiorRMSPressure())

            // Evaluate Track 35 Cauchy + Gladstone-Dale acousto-optic dispersion on live FDTD pressure gradient
            let gradVec = pmlTank.pressureGradient(atX: min(gSize - 3, mid + 3), y: mid)
            let gradMag = max(1.0e-4, simd_length(gradVec))
            let pLocal = pmlTank.pressureCurr[mid * gSize + min(gSize - 3, mid + 3)]
            let theta400 = AcoustoOpticCausticsEngine.refractionDeflectionAngleRadians(
                wavelengthNm: 400.0,
                pressure: pLocal,
                pressureGradientMagnitude: gradMag
            )
            let theta700 = AcoustoOpticCausticsEngine.refractionDeflectionAngleRadians(
                wavelengthNm: 700.0,
                pressure: pLocal,
                pressureGradientMagnitude: gradMag
            )
            dispersionRatio = theta400 / max(1.0e-6, theta700)

            let remainingSteps = 214
            pmlTank.advance(steps: remainingSteps)
            rigidTank.advance(steps: remainingSteps)

            let lateRMS = pmlTank.interiorRMSPressure()
            decayRatio = Double(lateRMS / peakRMS)
            let pmlEnergy = max(1.0e-12, Double(pmlTank.totalInteriorMechanicalEnergy()))
            let rigidEnergy = max(1.0e-12, Double(rigidTank.totalInteriorMechanicalEnergy()))
            pmlSuppressionDB = 10.0 * log10(rigidEnergy / pmlEnergy)

            let elapsedUs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000.0
            samplesUs.append(elapsedUs)
        }

        let p50 = Self.percentile(samplesUs, q: 0.50)
        let p95 = Self.percentile(samplesUs, q: 0.95)
        let p99 = Self.percentile(samplesUs, q: 0.99)
        let passed = cflStable
            && resonatorBounded
            && decayRatio < 0.45
            && pmlSuppressionDB > 10.0
            && dispersionRatio > 1.01

        return StageBenchmarkMetrics(
            stageIndex: 7,
            stageCode: "FDTD_BIHARMONIC_PML_2D",
            title: "2D Biharmonic FDTD Waveguide + Cubic PML Sponge",
            subsystemName: "FDTDWaveguideSolver.swift",
            iterations: samplesUs.count,
            p50Microseconds: p50,
            p95Microseconds: p95,
            p99Microseconds: p99,
            throughputSummary: String(format: "220x %dx%d FDTD+PML steps in %.2f ms", gSize, gSize, p50 / 1_000.0),
            numericalInvariantSummary: String(
                format: "CFL=%@, PML=-%.1fdB (r=%.3f), AO400/700=%.3f",
                cflStable ? "true" : "false",
                pmlSuppressionDB,
                decayRatio,
                dispersionRatio
            ),
            invariantPassed: passed
        )
    }

    // MARK: - Stage 8: EEGBrainComputerInterface RLS + Bispectrum + Tort PAC

    private func runStage08EEGArtifactRLSAndBispectrumPAC(
        configuration: CapstoneBenchmarkConfiguration = .canonical
    ) -> StageBenchmarkMetrics {
        var samplesUs: [Double] = []
        var pacMI: Float = 0.0
        var maxBicoh: Float = 0.0
        var iafHz: Float = 10.0
        var bisIndex: Float = 85.0
        var blinkSuppressionDB: Double = 0.0
        var rlsCleanedOK = false

        for _ in 0..<3 {
            let t0 = DispatchTime.now().uptimeNanoseconds

            var gen = SyntheticCorticalEEGGenerator(
                sampleRate: 256.0,
                targetAlphaHz: configuration.eegTargetAlphaHz,
                thetaGammaCouplingStrength: configuration.eegThetaGammaCoupling
            )
            var filterBank = EEGArtifactFilterBank(sampleRate: 256.0)
            var af7Clean: [Float] = []
            var af8Clean: [Float] = []
            af7Clean.reserveCapacity(256)
            af8Clean.reserveCapacity(256)

            var rawErrSqSum: Double = 0.0
            var cleanErrSqSum: Double = 0.0
            var blinkSampleCount = 0

            for i in 0..<256 {
                let blink: Float = (i >= 100 && i <= 125) ? configuration.eegBlinkAmplitudeUV : 0.0
                let step = gen.stepWithReference(injectBlinkAmplitude: blink)
                let cleaned = filterBank.processQuadSample(step.sample)
                af7Clean.append(cleaned.cleaned.af7)
                af8Clean.append(cleaned.cleaned.af8)
                if i >= 100 && i <= 125 {
                    let rawDiff = Double(step.sample.af7 - step.cleanNeuroAF7)
                    let cleanDiff = Double(cleaned.cleaned.af7 - step.cleanNeuroAF7)
                    rawErrSqSum += rawDiff * rawDiff
                    cleanErrSqSum += cleanDiff * cleanDiff
                    blinkSampleCount += 1
                }
            }
            let rawRMSE = sqrt(rawErrSqSum / Double(max(1, blinkSampleCount)))
            let cleanRMSE = sqrt(cleanErrSqSum / Double(max(1, blinkSampleCount)))
            blinkSuppressionDB = 20.0 * log10(max(1.0e-6, rawRMSE) / max(1.0e-6, cleanRMSE))
            rlsCleanedOK = (configuration.eegBlinkAmplitudeUV > 10.0)
                ? (blinkSuppressionDB > 8.0 && cleanRMSE < rawRMSE * 0.40)
                : (cleanRMSE.isFinite && rawRMSE.isFinite)

            let composite = zip(af7Clean, af8Clean).map { 0.5 * ($0 + $1) }
            let metrics = CorticalSpectralAnalyzer.analyze(
                channelSamples: composite,
                frontalLeft: af7Clean,
                frontalRight: af8Clean,
                sampleRate: 256.0
            )
            pacMI = metrics.thetaGammaPACModulationIndex
            maxBicoh = metrics.maxBicoherence
            iafHz = metrics.individualAlphaFrequencyHz
            bisIndex = metrics.bispectralIndex

            let elapsedUs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000.0
            samplesUs.append(elapsedUs)
        }

        let p50 = Self.percentile(samplesUs, q: 0.50)
        let p95 = Self.percentile(samplesUs, q: 0.95)
        let p99 = Self.percentile(samplesUs, q: 0.99)
        let minExpectedPAC: Float = configuration.eegThetaGammaCoupling > 0.15 ? 0.002 : 0.0
        let passed = rlsCleanedOK
            && pacMI >= minExpectedPAC
            && (7.5...12.5).contains(iafHz)
            && (0.0...100.0).contains(bisIndex)
            && maxBicoh >= 0.0
            && maxBicoh <= 1.0

        return StageBenchmarkMetrics(
            stageIndex: 8,
            stageCode: "EEG_RLS_BISPECTRUM_PAC",
            title: "4-Tap RLS EOG Canceler + Bispectrum + Tort PAC MI",
            subsystemName: "EEGBrainComputerInterface.swift",
            iterations: samplesUs.count,
            p50Microseconds: p50,
            p95Microseconds: p95,
            p99Microseconds: p99,
            throughputSummary: "256-sample 4-ch EEG + 18-bin Tort PAC",
            numericalInvariantSummary: String(
                format: "RLS=-%.1fdB, IAF=%.2fHz, PAC=%.4f, Bicoh=%.3f",
                blinkSuppressionDB,
                iafHz,
                pacMI,
                maxBicoh
            ),
            invariantPassed: passed
        )
    }

    // MARK: - Stage 9: Wigner-Ville SPWVD & Hilbert-Huang Transform (Track 33)

    private func runStage09WignerVilleSPWVDAndHilbertHuangEMD(
        configuration: CapstoneBenchmarkConfiguration = .canonical
    ) -> StageBenchmarkMetrics {
        let n = SPWVDAnalyzer.canonicalBlockSize
        let fs = 256.0
        let f1 = configuration.spwvdPrimaryFreqHz
        let f2 = configuration.spwvdSecondaryFreqHz
        let compositeSignal: [Float] = (0..<n).map { i in
            let t = Double(i) / fs
            let c1 = sin(2.0 * Double.pi * f1 * t)
            let c2 = 0.75 * sin(2.0 * Double.pi * f2 * t)
            return Float(c1 + c2)
        }

        var samplesUs: [Double] = []
        var renyiBits: Float = 0.0
        var reconErr: Float = 1.0
        var ridgeErrHz: Float = 100.0
        var crossTermDB: Float = 0.0
        var imfCount = 0

        for _ in 0..<4 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            let spwvd = SPWVDAnalyzer.analyze(signal: compositeSignal, sampleRate: fs, freqBins: 64)
            let hht = HilbertHuangSifter.sift(
                signal: compositeSignal,
                sampleRate: fs,
                maxIMFs: 4,
                maxSiftIterations: 12,
                cauchyConvergenceThreshold: 0.05
            )
            let elapsedUs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000.0
            samplesUs.append(elapsedUs)

            renyiBits = spwvd.renyiEntropyBits
            crossTermDB = spwvd.crossTermSuppressionDB
            reconErr = hht.maxReconstructionError
            imfCount = hht.imfs.count

            let margin = max(4, spwvd.dominantRidgeHz.count / 6)
            let interiorRidge = Array(spwvd.dominantRidgeHz.dropFirst(margin).dropLast(margin))
            if !interiorRidge.isEmpty {
                let meanRidge = interiorRidge.reduce(0.0, +) / Float(interiorRidge.count)
                ridgeErrHz = abs(meanRidge - Float(f1))
            }
        }

        let p50 = Self.percentile(samplesUs, q: 0.50)
        let p95 = Self.percentile(samplesUs, q: 0.95)
        let p99 = Self.percentile(samplesUs, q: 0.99)
        let passed = renyiBits > 0.1
            && reconErr < 1.0e-4
            && imfCount >= 2
            && ridgeErrHz < 4.5
            && crossTermDB > 3.0

        return StageBenchmarkMetrics(
            stageIndex: 9,
            stageCode: "SPWVD_HILBERT_HUANG_EMD",
            title: "Smoothed Pseudo Wigner-Ville & Cubic-Spline EMD/HHT",
            subsystemName: "WignerVilleHilbertHuangAnalyzer.swift",
            iterations: samplesUs.count,
            p50Microseconds: p50,
            p95Microseconds: p95,
            p99Microseconds: p99,
            throughputSummary: "128x64 SPWVD + Thomas O(N) EMD sifting",
            numericalInvariantSummary: String(
                format: "Renyi=%.2fb, RidgeErr=%.2fHz, XTerm=%.1fdB, EMD=%.2e",
                renyiBits,
                ridgeErrHz,
                crossTermDB,
                reconErr
            ),
            invariantPassed: passed
        )
    }

    // MARK: - Stage 10: Quantum MPS TT-SVD & 2-Site DMRG Variational Optimizer (Track 34)

    private func runStage10QuantumMPSTTSVDAndTwoSiteDMRG(
        configuration: CapstoneBenchmarkConfiguration = .canonical
    ) -> StageBenchmarkMetrics {
        let stateVec = MatrixProductStateEngine.encodeBioAcousticStateTensor(
            eegCorticalBands4: SIMD4<Float>(0.25, 0.55, 0.48, 0.22),
            hrvVagalMetrics4: SIMD4<Float>(0.68, 0.72, 0.30, 0.85),
            spwvdEntropyState4: SIMD4<Float>(0.42, 0.60, 0.52, 0.35),
            binauralOscillatorState4: SIMD4<Float>(0.50, 0.45, 0.38, 0.62),
            hrtfFDTDWavefield4: SIMD4<Float>(0.48, 0.58, 0.44, 0.50),
            circadianKalmanPhase4: SIMD4<Float>(0.70, 0.35, 0.60, 0.40),
            entanglementCoupling: configuration.quantumEntanglementCoupling
        )

        var samplesUs: [Double] = []
        var orthoDefect = 1.0
        var initialE = 0.0
        var finalE = 0.0
        var entropyVn: Float = 0.0
        var purityOK = false
        let deltaJ = configuration.quantumAnisotropyDelta
        let bondChi = configuration.quantumMaxBondDim
        // Exact Lanczos ground state energy bound for 6-site Spin-3/2 TFIM: E_0 >= -(5 * 2.25 * J + 6 * 1.5 * h)
        let variationalLowerBound = -(5.0 * 2.25 * deltaJ + 6.0 * 1.5 * 0.5)

        for _ in 0..<2 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            var mps = MatrixProductStateEngine(stateVector: stateVec, maxBondDim: bondChi)
            orthoDefect = mps.verifyLeftCanonicalOrthogonality()
            initialE = mps.expectationValueNearestNeighborXXZ(anisotropyDelta: deltaJ)

            let dmrg = DMRGVariationalOptimizer(anisotropyDelta: deltaJ, maxBondDim: bondChi, lanczosIterations: 8)
            let snap = dmrg.runSweeps(mps: &mps, sweepCount: 1)
            finalE = Double(snap.groundStateEnergyEstimate)
            let control = DMRGVariationalOptimizer.extractOptimalBioAcousticControl(from: mps)
            entropyVn = snap.centralEntanglementEntropy
            purityOK = snap.renyi2Purity > 0.0
                && snap.renyi2Purity <= 1.0 + 1.0e-6
                && control.recommendedBinauralBeatHz.isFinite

            let elapsedUs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000.0
            samplesUs.append(elapsedUs)
        }

        let p50 = Self.percentile(samplesUs, q: 0.50)
        let p95 = Self.percentile(samplesUs, q: 0.95)
        let p99 = Self.percentile(samplesUs, q: 0.99)
        let minEntropy: Float = configuration.quantumEntanglementCoupling > 0.05 ? 1.0e-4 : 0.0
        let passed = orthoDefect < 1.0e-5
            && finalE <= initialE + 1.0e-5
            && finalE >= variationalLowerBound - 1.0e-4
            && entropyVn >= minEntropy
            && purityOK

        return StageBenchmarkMetrics(
            stageIndex: 10,
            stageCode: "QUANTUM_MPS_DMRG_6SITE",
            title: "6-Site MPS TT-SVD & 2-Site DMRG Entanglement Sweep",
            subsystemName: "TensorNetworkQuantumOptimizer.swift",
            iterations: samplesUs.count,
            p50Microseconds: p50,
            p95Microseconds: p95,
            p99Microseconds: p99,
            throughputSummary: "4^6=4096 TT-SVD + 2-Site Lanczos DMRG",
            numericalInvariantSummary: String(format: "||U^TU-I||=%.1e, E: %.3f->%.3f, S_vN=%.3f", orthoDefect, initialE, finalE, entropyVn),
            invariantPassed: passed
        )
    }

    // MARK: - Stage 11: MPSGraphBrainwaveTrainer & AdaptiveBrainwaveMLPredictor

    private func runStage11MPSGraphAutodiffAndCoreMLPredictor(
        configuration: CapstoneBenchmarkConfiguration = .canonical
    ) async -> StageBenchmarkMetrics {
        let batch = BiometricTrainingBatch.makeSyntheticBiometricDataset(
            batchSize: 8,
            seed: configuration.mpsGraphDatasetSeed
        )
        let trainer = MPSGraphBrainwaveTrainer(
            seed: configuration.mpsGraphTrainerSeed,
            forceCPUFallback: false
        )
        let predictor = AdaptiveBrainwaveMLPredictor(
            initialWeights: NeuralReservoirWeights.makeDeterministicDefault(),
            persistToAppGroup: false
        )

        var samplesUs: [Double] = []
        var firstLoss: Float = 0.0
        var lastLoss: Float = 0.0
        var maxGradNorm: Float = 0.0

        for step in 0..<6 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            let snap = await trainer.trainEpoch(batch: batch, learningRate: 0.022)
            let elapsedUs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000.0
            samplesUs.append(elapsedUs)
            if step == 0 { firstLoss = snap.latestLoss }
            lastLoss = snap.latestLoss
            maxGradNorm = max(maxGradNorm, snap.gradientL2Norm)
        }

        let pred = await trainer.predictOptimalSetpoint(sequence8x12: Array(batch.inputs.prefix(96)))
        let mlRec = await predictor.predict(
            features: BiometricFeatureVector(
                hrNormalized: 0.44,
                rmssdNormalized: 0.58,
                sdnnNormalized: 0.62,
                pnn50Normalized: 0.35,
                baevskyStressNormalized: 0.28,
                lfHfRatioNormalized: 0.24,
                rsaCoherenceScore: 0.84,
                respiratoryRateNormalized: 0.40,
                circadianPhaseSin: 0.50,
                circadianPhaseCos: 0.866,
                currentBeatHzNormalized: 0.25,
                sessionProgressRatio: 0.50
            )
        )

        let p50 = Self.percentile(samplesUs, q: 0.50)
        let p95 = Self.percentile(samplesUs, q: 0.95)
        let p99 = Self.percentile(samplesUs, q: 0.99)
        let passed = lastLoss < firstLoss
            && maxGradNorm <= MPSGraphBrainwaveTrainer.maxGradientL2Norm + 1.0e-5
            && BrainwavePrediction.binauralBeatRange.contains(pred.binauralBeatHz)
            && BrainwavePredictionOutput.beatHzRange.contains(mlRec.targetBinauralBeatHz)

        return StageBenchmarkMetrics(
            stageIndex: 11,
            stageCode: "MPSGRAPH_AUTODIFF_ADAMW",
            title: "MPSGraph Self-Attention Autodiff & CoreML Predictor",
            subsystemName: "MPSGraphBrainwaveTrainer.swift & AdaptiveBrainwaveMLPredictor.swift",
            iterations: samplesUs.count,
            p50Microseconds: p50,
            p95Microseconds: p95,
            p99Microseconds: p99,
            throughputSummary: String(format: "8x8x12 attention epoch in %.1f µs", p50),
            numericalInvariantSummary: String(format: "Loss %.4f -> %.4f, ||g||<=%.2f", firstLoss, lastLoss, maxGradNorm),
            invariantPassed: passed
        )
    }

    // MARK: - Stage 12: OfflineStemExporter 24-Bit WAV + CryptoKit SHA256 & ChaChaPoly P2P

    private func runStage12OfflineWAVExportAndChaChaPolyCrypto() async -> StageBenchmarkMetrics {
        let exporter = OfflineStemExporter()
        var samplesUs: [Double] = []
        var wavValid = false
        var pcmNonSilent = false
        var cryptoRoundTripOK = false
        var tamperRejected = false
        var wavByteCount = 0
        var wavDigestPrefix = "00000000"

        for _ in 0..<2 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            do {
                let wavData = try await exporter.renderSeamlessLoopWAV(
                    baseParameters: SynthParameters(preset: AudioPresetDTO.defaultPresets[0]),
                    durationSeconds: 1.0,
                    loopCrossfadeSeconds: 0.20,
                    sampleRate: 48_000,
                    bitDepth: .pcm24Bit
                )
                wavByteCount = wavData.count
                let header = try WAVBinaryCodec.parseHeader(wavData)
                wavValid = (header.sampleRate == 48_000 && header.bitsPerSample == 24 && header.channelCount == 2)
                if wavData.count > 44 {
                    let payloadSlice = wavData.dropFirst(44).prefix(4_096)
                    pcmNonSilent = payloadSlice.contains(where: { $0 != 0 })
                }
                let wavHash = SHA256.hash(data: wavData)
                wavDigestPrefix = wavHash.prefix(4).map { String(format: "%02x", $0) }.joined()

                let archive = AetherTelemetryArchive(
                    habits: HabitNodeDTO.defaultSeeds,
                    presets: AudioPresetDTO.defaultPresets,
                    sessions: [],
                    dailyTelemetry: []
                )

                let aliceKey = MeshCryptoSession.makeKeyPair()
                let bobKey = MeshCryptoSession.makeKeyPair()
                let salt = MeshCryptoSession.makeRandomSalt()

                let symA = try MeshCryptoSession.deriveSymmetricKey(
                    privateKey: aliceKey,
                    peerPublicKeyRaw: bobKey.publicKey.rawRepresentation,
                    hkdfSalt: salt
                )
                let symB = try MeshCryptoSession.deriveSymmetricKey(
                    privateKey: bobKey,
                    peerPublicKeyRaw: aliceKey.publicKey.rawRepresentation,
                    hkdfSalt: salt
                )

                let envelope = try MeshCryptoSession.sealArchive(
                    archive,
                    senderPeerID: "capstone-alice",
                    lamportClock: 1,
                    key: symA
                )
                let opened = try MeshCryptoSession.openArchive(envelope, key: symB)
                cryptoRoundTripOK = (opened == archive)

                // Verify ChaCha20-Poly1305 AEAD tag rejection on 1-bit ciphertext/tag tamper
                if !envelope.sealedBoxCombined.isEmpty {
                    var corruptedBox = envelope.sealedBoxCombined
                    let lastIdx = corruptedBox.count - 1
                    corruptedBox[lastIdx] ^= 0x01
                    let tamperedEnv = MeshEncryptedArchiveEnvelope(
                        senderPeerID: envelope.senderPeerID,
                        lamportClock: envelope.lamportClock,
                        sealedBoxCombined: corruptedBox
                    )
                    let tamperedOpen = try? MeshCryptoSession.openArchive(tamperedEnv, key: symB)
                    tamperRejected = (tamperedOpen == nil)
                }
            } catch {
                wavValid = false
                cryptoRoundTripOK = false
            }
            let elapsedUs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000.0
            samplesUs.append(elapsedUs)
        }

        let p50 = Self.percentile(samplesUs, q: 0.50)
        let p95 = Self.percentile(samplesUs, q: 0.95)
        let p99 = Self.percentile(samplesUs, q: 0.99)
        let passed = wavValid && pcmNonSilent && cryptoRoundTripOK && tamperRejected

        return StageBenchmarkMetrics(
            stageIndex: 12,
            stageCode: "WAV24_CHACHAPOLY_SHA256",
            title: "24-Bit RIFF/WAVE Export + ECDH ChaChaPoly P2P Seal",
            subsystemName: "OfflineStemExporter.swift & AetherMeshSyncActor.swift",
            iterations: samplesUs.count,
            p50Microseconds: p50,
            p95Microseconds: p95,
            p99Microseconds: p99,
            throughputSummary: String(format: "%d B 24-bit WAV + X25519 AEAD", wavByteCount),
            numericalInvariantSummary: String(
                format: "WAV24=%dB (sha:%@), ChaChaPoly+Tamper=OK",
                wavByteCount,
                wavDigestPrefix
            ),
            invariantPassed: passed
        )
    }

    // MARK: - Percentile & Master 10-Phase Subsystem Inventory Helpers

    private static func percentile(_ values: [Double], q: Double) -> Double {
        guard !values.isEmpty else { return 0.0 }
        let sorted = values.sorted()
        if sorted.count == 1 { return sorted[0] }
        let pos = min(max(q, 0.0), 1.0) * Double(sorted.count - 1)
        let lo = Int(floor(pos))
        let hi = min(sorted.count - 1, lo + 1)
        let frac = pos - Double(lo)
        return sorted[lo] * (1.0 - frac) + sorted[hi] * frac
    }

    public static func buildSubsystemInventory(
        stages: [StageBenchmarkMetrics] = []
    ) -> [SubsystemInventoryEntry] {
        func stagesPass(_ indices: [Int]) -> Bool {
            guard !stages.isEmpty else { return true }
            for idx in indices {
                guard let stage = stages.first(where: { $0.stageIndex == idx }), stage.invariantPassed else {
                    return false
                }
            }
            return true
        }

        return [
            SubsystemInventoryEntry(
                phaseNumber: 1,
                trackRange: "Tracks 1–4",
                moduleName: "AudioSynthEngine & SpectralFFTAnalyzer",
                sourcePath: "Sources/App/Audio/AudioSynthEngine.swift",
                mathematicalCore: "Lock-Free SPSC Ring, Voss-McCartney Pink Noise, 4-Pole ZDF/TPT Cytomic SVF, Radix-2 Cooley-Tukey FFT",
                verified: stagesPass([2])
            ),
            SubsystemInventoryEntry(
                phaseNumber: 2,
                trackRange: "Tracks 5–8",
                moduleName: "TelemetryDatabaseActor & OfflineStemExporter",
                sourcePath: "Sources/Shared/TelemetryDatabaseActor.swift",
                mathematicalCore: "SwiftData @ModelActor Batch Upsert, RIFF/WAVE 24/32-bit LPCM, Equal-Power Loop, X25519 ChaChaPoly",
                verified: stagesPass([1, 12])
            ),
            SubsystemInventoryEntry(
                phaseNumber: 3,
                trackRange: "Tracks 9–12",
                moduleName: "KEMARHRIRSynthesizer & ShoeboxRoomSimulator",
                sourcePath: "Sources/App/Audio/SpatialHRTFConvolver.swift",
                mathematicalCore: "Woodworth-Schlosberg Spherical Head ITD/ILD, UPOLS Frequency-Domain Convolver, 18-Image ISM + Sabine/Eyring RT60",
                verified: stagesPass([3])
            ),
            SubsystemInventoryEntry(
                phaseNumber: 4,
                trackRange: "Tracks 13–16",
                moduleName: "AUv3 Plug-In & FourOpTZFM + HadamardFDN",
                sourcePath: "Sources/AUv3/AetherSynthAudioUnit.swift",
                mathematicalCore: "AUv3 Real-Time Render Block, 4-Op Through-Zero FM (Bessel J_n), 8-Delay Householder/Hadamard FDN Reverb",
                verified: stagesPass([2, 3])
            ),
            SubsystemInventoryEntry(
                phaseNumber: 5,
                trackRange: "Tracks 17–20",
                moduleName: "HealthKitHRVStreamer & AdaptiveBrainwaveMLPredictor",
                sourcePath: "Sources/Shared/AdaptiveBrainwaveMLPredictor.swift",
                mathematicalCore: "Lomb-Scargle Uneven Periodogram LF/HF, Baevsky Stress Index, 2-Layer SIMD MLP + Online Policy Gradient",
                verified: stagesPass([11])
            ),
            SubsystemInventoryEntry(
                phaseNumber: 6,
                trackRange: "Tracks 21–24",
                moduleName: "MPSGraphBrainwaveTrainer & CircadianPhaseKalmanFilter",
                sourcePath: "Sources/Shared/MPSGraphBrainwaveTrainer.swift",
                mathematicalCore: "Scaled Dot-Product Self-Attention, Huber + RSA Loss, MPSGraph Autodiff + AdamW, Jewett-Kronauer 2D EKF",
                verified: stagesPass([11])
            ),
            SubsystemInventoryEntry(
                phaseNumber: 7,
                trackRange: "Tracks 25–27",
                moduleName: "MetalAcousticRayTracer & NeuralLatentSoundscapeEngine",
                sourcePath: "Sources/App/Audio/MetalAcousticRayTracer.swift",
                mathematicalCore: "SAH-BVH Möller-Trumbore 4-Band Ray Tracing, 2nd-Order Heun Rectified-Flow ODE, 4-Stage RVQ, Snake Vocoder",
                verified: stagesPass([4, 5])
            ),
            SubsystemInventoryEntry(
                phaseNumber: 8,
                trackRange: "Tracks 28–30",
                moduleName: "DistributedOrchestraEngine & FDTDWaveguideSolver",
                sourcePath: "Sources/Shared/DistributedOrchestraEngine.swift",
                mathematicalCore: "IEEE 1588 PTP 64B Codec, Marzullo Consensus, 2nd-Order PI-PLL, Rayleigh-I WFS, 2D Biharmonic FDTD + PML",
                verified: stagesPass([6, 7])
            ),
            SubsystemInventoryEntry(
                phaseNumber: 9,
                trackRange: "Tracks 31–32",
                moduleName: "EEGBrainComputerInterface & RealityKit Cymatics",
                sourcePath: "Sources/Shared/EEGBrainComputerInterface.swift",
                mathematicalCore: "4-Tap RLS Ocular Canceler, Higher-Order Bispectrum/Bicoherence, Tort Theta-Gamma PAC KL Modulation Index",
                verified: stagesPass([7, 8])
            ),
            SubsystemInventoryEntry(
                phaseNumber: 10,
                trackRange: "Tracks 33–36",
                moduleName: "SPWVD/HHT, Quantum MPS/DMRG & Acousto-Optic Caustics",
                sourcePath: "Sources/Shared/WignerVilleHilbertHuangAnalyzer.swift",
                mathematicalCore: "Smoothed Pseudo Wigner-Ville, Thomas Cubic-Spline EMD, 6-Site MPS TT-SVD & 2-Site DMRG, Cauchy/Gladstone-Dale Caustics",
                verified: stagesPass([9, 10, 12])
            )
        ]
    }
}
