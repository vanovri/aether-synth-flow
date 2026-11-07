// MARK: - FILE: AetherSynthTests.swift

import Testing
import Foundation
import SwiftData
@testable import AetherSynthFlow

@Suite("AetherSynth & Flow Full-Stack Concurrency, DSP, FFT & Portability Suite")
struct AetherSynthTests {

    // MARK: - 1. ModelActor Strict Concurrency & Conflict Resolution Tests

    @Test("Concurrent 32-task batch session ingestion & telemetry rollup safety")
    func verifyConcurrentDatabaseIngestionAndRollups() async throws {
        let container = try AetherPersistenceSchema.makeContainer(inMemory: true)
        let dbActor = TelemetryDatabaseActor(modelContainer: container)

        let habitID = UUID()
        let anchorDate = Date(timeIntervalSince1970: 1_762_000_000)

        _ = try await dbActor.upsertHabit(
            HabitNodeDTO(
                habitID: habitID,
                title: "Concurrency Kernel",
                symbolName: "cpu.fill",
                accentHue: 0.52,
                orbitalMass: 1.5,
                targetMinutesPerDay: 30
            )
        )

        try await withThrowingTaskGroup(of: BatchIngestReport.self) { group in
            for worker in 0..<32 {
                group.addTask {
                    let dto = FocusSessionDTO(
                        sessionID: UUID(),
                        title: "Worker-\(worker)",
                        startedAt: anchorDate.addingTimeInterval(Double(worker * 30)),
                        endedAt: anchorDate.addingTimeInterval(Double(worker * 30 + 600)),
                        plannedDurationSeconds: 600,
                        actualDurationSeconds: 600,
                        completed: true,
                        focusQualityScore: 0.90,
                        peakAmplitude: 0.75,
                        carrierFrequencyHz: 216.0,
                        beatFrequencyHz: 14.0,
                        linkedHabitID: habitID,
                        notes: "Concurrent write \(worker)",
                        updatedAt: anchorDate,
                        revision: 1
                    )
                    return try await dbActor.batchIngestSessions([dto], conflictPolicy: .higherRevisionWins)
                }
            }

            var totalInserted = 0
            for try await report in group {
                totalInserted += report.insertedSessions
            }
            #expect(totalInserted == 32)
        }

        let dayKey = DayKeyFormatter.dayKey(for: anchorDate)
        let sessionsOnDay = try await dbActor.fetchSessionsForDay(dayKey: dayKey)
        #expect(sessionsOnDay.count == 32)

        let telemetryWindow = try await dbActor.fetchTelemetryWindow(
            from: anchorDate.addingTimeInterval(-86_400),
            to: anchorDate.addingTimeInterval(86_400)
        )
        let targetTelemetry = try #require(telemetryWindow.first(where: { $0.dayKey == dayKey }))
        #expect(targetTelemetry.completedSessionCount == 32)
        #expect(abs(targetTelemetry.totalFocusSeconds - 19_200.0) < 0.01)
        #expect(targetTelemetry.intensityLevel == 4)
    }

    @Test("Deterministic conflict resolution policies (higherRevisionWins, mergeAccumulate)")
    func verifyConflictResolutionPolicies() async throws {
        let container = try AetherPersistenceSchema.makeContainer(inMemory: true)
        let dbActor = TelemetryDatabaseActor(modelContainer: container)

        let sharedID = UUID()
        let baseStart = Date(timeIntervalSince1970: 1_762_500_000)

        let rev1 = FocusSessionDTO(
            sessionID: sharedID,
            title: "Initial Revision",
            startedAt: baseStart,
            endedAt: baseStart.addingTimeInterval(1200),
            plannedDurationSeconds: 1200,
            actualDurationSeconds: 1200,
            completed: true,
            focusQualityScore: 0.80,
            peakAmplitude: 0.50,
            carrierFrequencyHz: 200.0,
            beatFrequencyHz: 10.0,
            updatedAt: baseStart,
            revision: 2
        )
        let r1 = try await dbActor.batchIngestSessions([rev1], conflictPolicy: .higherRevisionWins)
        #expect(r1.insertedSessions == 1)

        let stale = FocusSessionDTO(
            sessionID: sharedID,
            title: "Stale Overwrite Attempt",
            startedAt: baseStart,
            endedAt: baseStart.addingTimeInterval(300),
            plannedDurationSeconds: 1200,
            actualDurationSeconds: 300,
            completed: false,
            focusQualityScore: 0.40,
            peakAmplitude: 0.20,
            carrierFrequencyHz: 200.0,
            beatFrequencyHz: 10.0,
            updatedAt: baseStart.addingTimeInterval(-60),
            revision: 1
        )
        let r2 = try await dbActor.batchIngestSessions([stale], conflictPolicy: .higherRevisionWins)
        #expect(r2.skippedSessions == 1)

        let delta = FocusSessionDTO(
            sessionID: sharedID,
            title: "Merged Segment",
            startedAt: baseStart,
            endedAt: baseStart.addingTimeInterval(1800),
            plannedDurationSeconds: 1800,
            actualDurationSeconds: 600,
            completed: true,
            focusQualityScore: 1.00,
            peakAmplitude: 0.92,
            carrierFrequencyHz: 200.0,
            beatFrequencyHz: 10.0,
            notes: "Appended slice",
            updatedAt: baseStart.addingTimeInterval(600),
            revision: 3
        )
        let r3 = try await dbActor.batchIngestSessions([delta], conflictPolicy: .mergeAccumulate)
        #expect(r3.updatedSessions == 1)

        let highQuality = try await dbActor.fetchHighQualitySessions(
            from: baseStart.addingTimeInterval(-3600),
            to: baseStart.addingTimeInterval(3600),
            minimumDurationSeconds: 1500,
            minimumQuality: 0.85
        )
        let merged = try #require(highQuality.first)
        #expect(abs(merged.actualDurationSeconds - 1800.0) < 0.001)
        #expect(abs(merged.focusQualityScore - 0.90) < 0.001)
        #expect(merged.notes == "Appended slice")
    }

    // MARK: - 2. Procedural Audio Buffer Math & Spectral Invariants

    @Test("Binaural stereo phase accumulation hits exact fL = fc - fb/2 and fR = fc + fb/2")
    func verifyBinauralStereoSpectralAccuracy() {
        let sampleRate = 48_000.0
        let params = SynthParameters(
            carrierFrequencyHz: 216.0,
            binauralBeatHz: 8.0,
            binauralMix: 1.0,
            pinkNoiseMix: 0.0,
            padMix: 0.0,
            filterCutoffHz: 14_000.0,
            filterResonance: 0.10,
            padDetuneCents: 0.0,
            masterGain: 0.50,
            isMuted: false
        )

        var kernel = ProceduralSynthKernel(sampleRate: sampleRate, snapInitialParameters: params)
        let frames = 48_000
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)

        let telemetry = left.withUnsafeMutableBufferPointer { lBuf in
            right.withUnsafeMutableBufferPointer { rBuf in
                kernel.renderStereoBlock(
                    leftOutput: lBuf.baseAddress!,
                    rightOutput: rBuf.baseAddress!,
                    frameCount: frames,
                    target: params
                )
            }
        }

        #expect(telemetry.isRendering)
        #expect(telemetry.rmsAmplitude > 0.10)
        #expect(telemetry.peakAmplitude <= 1.0)

        for i in 0..<frames {
            #expect(left[i].isFinite && right[i].isFinite)
            #expect(abs(left[i]) <= 1.0 && abs(right[i]) <= 1.0)
        }

        func dftMagnitude(signal: [Float], targetHz: Double) -> Double {
            var re = 0.0
            var im = 0.0
            let start = 4_000
            let count = signal.count - start
            let omega = 2.0 * Double.pi * targetHz / sampleRate
            for n in start..<signal.count {
                let sample = Double(signal[n])
                let angle = omega * Double(n)
                re += sample * cos(angle)
                im -= sample * sin(angle)
            }
            return hypot(re, im) / Double(count)
        }

        let leftAt212 = dftMagnitude(signal: left, targetHz: 212.0)
        let leftAt220 = dftMagnitude(signal: left, targetHz: 220.0)
        let rightAt220 = dftMagnitude(signal: right, targetHz: 220.0)
        let rightAt212 = dftMagnitude(signal: right, targetHz: 212.0)

        #expect(leftAt212 > 0.12)
        #expect(leftAt212 > leftAt220 * 20.0)
        #expect(rightAt220 > 0.12)
        #expect(rightAt220 > rightAt212 * 20.0)
    }

    @Test("Cascaded 4-pole Cytomic TPT SVF attenuates stopband > 24 dB and remains stable at high Q")
    func verifyLowPassFilterAttenuationAndStability() {
        let sampleRate = 48_000.0
        let frames = 16_384

        let openFilterParams = SynthParameters(
            carrierFrequencyHz: 880.0,
            binauralBeatHz: 4.0,
            binauralMix: 1.0,
            pinkNoiseMix: 0.0,
            padMix: 0.0,
            filterCutoffHz: 12_000.0,
            filterResonance: 0.88,
            masterGain: 0.60
        )

        let closedFilterParams = SynthParameters(
            carrierFrequencyHz: 880.0,
            binauralBeatHz: 4.0,
            binauralMix: 1.0,
            pinkNoiseMix: 0.0,
            padMix: 0.0,
            filterCutoffHz: 140.0,
            filterResonance: 0.88,
            masterGain: 0.60
        )

        var openKernel = ProceduralSynthKernel(sampleRate: sampleRate, snapInitialParameters: openFilterParams)
        var closedKernel = ProceduralSynthKernel(sampleRate: sampleRate, snapInitialParameters: closedFilterParams)

        var bufL = [Float](repeating: 0, count: frames)
        var bufR = [Float](repeating: 0, count: frames)

        let openSnap = bufL.withUnsafeMutableBufferPointer { l in
            bufR.withUnsafeMutableBufferPointer { r in
                openKernel.renderStereoBlock(leftOutput: l.baseAddress!, rightOutput: r.baseAddress!, frameCount: frames, target: openFilterParams)
            }
        }

        let closedSnap = bufL.withUnsafeMutableBufferPointer { l in
            bufR.withUnsafeMutableBufferPointer { r in
                closedKernel.renderStereoBlock(leftOutput: l.baseAddress!, rightOutput: r.baseAddress!, frameCount: frames, target: closedFilterParams)
            }
        }

        #expect(openSnap.rmsAmplitude > 0.15)
        #expect(closedSnap.rmsAmplitude < openSnap.rmsAmplitude * 0.06)
    }

    // MARK: - 3. vDSP 64-Bin FFT & AirPods Spatial Pan Projection Verification

    @Test("vDSP 256-point Hann DFT accurately isolates synthetic 1500 Hz tone and maps 64 perceptual bars")
    func verifyAccelerateSpectralFFTAnalyzer() {
        let sampleRate = 48_000.0
        let targetToneHz = 1_500.0 // Bin k = 1500 / (48000/256) = 1500 / 187.5 = exact bin 8
        let n = SpectralFFTAnalyzer.fftLength

        var sineWindow = [Float](repeating: 0, count: n)
        for i in 0..<n {
            sineWindow[i] = Float(sin(2.0 * Double.pi * targetToneHz * Double(i) / sampleRate)) * 0.8
        }

        let analyzer = SpectralFFTAnalyzer()
        let frame = analyzer.analyze(samples: sineWindow, sampleRate: sampleRate)

        #expect(frame.bars.count == 64)
        #expect(abs(frame.dominantFrequencyHz - 1_500.0) < 1.0)
        #expect(frame.bars.max() ?? 0 > 0.50)
    }

    @Test("AirPods head-tracking yaw and pitch map asymmetrically and clamp within [-1, 1]")
    func verifyHeadphoneAttitudeSpatialMapping() {
        let centered = MediaSessionAndHeadTrackingController.mapHeadAttitudeToSpatialControls(
            deltaYawRadians: 0,
            pitchRadians: 0
        )
        #expect(abs(centered.pan) < 0.0001)
        #expect(abs(centered.elevation) < 0.0001)

        let turnedLeft = MediaSessionAndHeadTrackingController.mapHeadAttitudeToSpatialControls(
            deltaYawRadians: .pi / 3.0,
            pitchRadians: .pi / 6.0
        )
        #expect(turnedLeft.pan < -0.5)
        #expect(turnedLeft.elevation > 0.4)
        #expect(abs(turnedLeft.pan) <= 1.0 && abs(turnedLeft.elevation) <= 1.0)

        // Verify constant-power pan shifts ambient pad energy toward right channel when pan = +1.0
        let pannedParams = SynthParameters(
            carrierFrequencyHz: 220.0,
            binauralBeatHz: 8.0,
            binauralMix: 0.0,
            pinkNoiseMix: 0.0,
            padMix: 1.0,
            filterCutoffHz: 8_000.0,
            filterResonance: 0.2,
            masterGain: 0.8,
            spatialPanOffset: 1.0,
            isMuted: false
        )
        var kernel = ProceduralSynthKernel(sampleRate: 48_000.0, snapInitialParameters: pannedParams)
        let count = 4_096
        var left = [Float](repeating: 0, count: count)
        var right = [Float](repeating: 0, count: count)
        _ = left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                kernel.renderStereoBlock(leftOutput: l.baseAddress!, rightOutput: r.baseAddress!, frameCount: count, target: pannedParams)
            }
        }
        let rmsL = sqrt(left.reduce(0) { $0 + $1 * $1 } / Float(count))
        let rmsR = sqrt(right.reduce(0) { $0 + $1 * $1 } / Float(count))
        #expect(rmsR > 0.10)
        #expect(rmsL < 0.001)
    }

    // MARK: - 4. Verified JSON Checksum Archive & RFC-4180 CSV Round-Trip

    @Test("Full ledger JSON archive round-trips across containers and rejects tampered checksums")
    func verifyArchivePortabilityAndChecksumIntegrity() async throws {
        let sourceContainer = try AetherPersistenceSchema.makeContainer(inMemory: true)
        let sourceActor = TelemetryDatabaseActor(modelContainer: sourceContainer)
        try await sourceActor.bootstrapDefaultsIfNeeded()

        let customSession = FocusSessionDTO(
            title: "Deep Kernel Profiling, \"Phase 2\"",
            startedAt: Date(timeIntervalSince1970: 1_763_000_000),
            endedAt: Date(timeIntervalSince1970: 1_763_002_700),
            plannedDurationSeconds: 2700,
            actualDurationSeconds: 2700,
            completed: true,
            focusQualityScore: 0.96,
            peakAmplitude: 0.81,
            carrierFrequencyHz: 216.0,
            beatFrequencyHz: 14.0,
            notes: "Comma, quote \"test\", newline\nverified"
        )
        _ = try await sourceActor.batchIngestSessions([customSession])

        // Verify CSV RFC-4180 escaping
        let csv = try await sourceActor.exportSessionsCSV()
        #expect(csv.contains("\"Deep Kernel Profiling, \"\"Phase 2\"\"\""))
        #expect(csv.contains("\"Comma, quote \"\"test\"\", newline\nverified\""))

        // Export JSON archive and restore into clean destination container
        let archive = try await sourceActor.exportFullArchive()
        let jsonData = try archive.encodePrettyJSON()
        let decodedArchive = try AetherTelemetryArchive.decodeAndValidate(from: jsonData)
        #expect(decodedArchive == archive)

        let destContainer = try AetherPersistenceSchema.makeContainer(inMemory: true)
        let destActor = TelemetryDatabaseActor(modelContainer: destContainer)
        let importSummary = try await destActor.importFullArchive(decodedArchive, conflictPolicy: .higherRevisionWins)

        #expect(importSummary.importedHabits == archive.habits.count)
        #expect(importSummary.sessionReport.insertedSessions == 1)

        // Corrupt payload and confirm checksum mismatch throws ArchivePortabilityError
        var jsonString = try #require(String(data: jsonData, encoding: .utf8))
        jsonString = jsonString.replacingOccurrences(of: "2700", with: "1800")
        let tamperedData = try #require(jsonString.data(using: .utf8))
        #expect(throws: ArchivePortabilityError.self) {
            _ = try AetherTelemetryArchive.decodeAndValidate(from: tamperedData)
        }
    }

    @Test("Real-time synthesis throughput renders 10s of 48kHz full-polyphony audio within real-time budget")
    func verifyRealtimeDSPThroughput() {
        var kernel = ProceduralSynthKernel(sampleRate: 48_000.0)
        let params = SynthParameters(preset: AudioPresetDTO.defaultPresets[0])
        let blockSize = 512
        let totalBlocks = (48_000 * 10) / blockSize

        var left = [Float](repeating: 0, count: blockSize)
        var right = [Float](repeating: 0, count: blockSize)

        let clock = ContinuousClock()
        let elapsed = clock.measure {
            left.withUnsafeMutableBufferPointer { lPtr in
                right.withUnsafeMutableBufferPointer { rPtr in
                    for _ in 0..<totalBlocks {
                        _ = kernel.renderStereoBlock(
                            leftOutput: lPtr.baseAddress!,
                            rightOutput: rPtr.baseAddress!,
                            frameCount: blockSize,
                            target: params
                        )
                    }
                }
            }
        }

        #expect(elapsed < .milliseconds(1500))
    }
}
