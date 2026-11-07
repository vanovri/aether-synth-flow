// MARK: - FILE: AetherSynthTests.swift

import Testing
import Foundation
import SwiftData
import simd
#if canImport(CoreML)
import CoreML
#endif
#if canImport(AudioToolbox)
import AudioToolbox
#endif
#if os(macOS)
@testable import AetherSynthMac
#elseif os(visionOS)
@testable import AetherSynthVision
#else
@testable import AetherSynthFlow
#endif

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

    // MARK: - 5. HRV Time/Frequency Math & Lomb-Scargle 0.10 Hz Spectral Verification

    @Test("HRV analyzer computes exact SDNN, RMSSD, pNN50, SD1/SD2, Baevsky SI & 0.10 Hz Lomb-Scargle peak")
    func verifyHRVTimeDomainBaevskyPoincareAndLombScargle() {
        let baseDate = Date(timeIntervalSince1970: 1_764_000_000)
        var cumulativeSec = 0.0
        var cleanSeries: [RRIntervalSampleDTO] = []

        // 110 beats (~93 seconds) modulated at the 0.10 Hz Mayer-wave resonance
        for _ in 0..<110 {
            let rrMs = 850.0 + 115.0 * sin(2.0 * Double.pi * 0.10 * cumulativeSec)
            cumulativeSec += rrMs / 1_000.0
            cleanSeries.append(
                RRIntervalSampleDTO(
                    timestamp: baseDate.addingTimeInterval(cumulativeSec),
                    durationMs: rrMs
                )
            )
        }

        // Verify ectopic rejection strips non-physiological (<300ms / >2000ms) artifacts
        var seriesWithArtifacts = cleanSeries
        seriesWithArtifacts.insert(
            RRIntervalSampleDTO(timestamp: baseDate.addingTimeInterval(12.2), durationMs: 180.0),
            at: 14
        )
        seriesWithArtifacts.insert(
            RRIntervalSampleDTO(timestamp: baseDate.addingTimeInterval(35.8), durationMs: 2_450.0),
            at: 42
        )
        let filtered = RRIntervalSampleDTO.filterEctopicSamples(seriesWithArtifacts)
        #expect(filtered.count == cleanSeries.count)

        let metrics = HRVSignalProcessor.analyze(
            samples: cleanSeries,
            computedAt: baseDate.addingTimeInterval(cumulativeSec),
            applyEctopicFilter: false
        )

        // Independent exact reference calculation
        let durations = cleanSeries.map(\.durationMs)
        let n = Double(durations.count)
        let expectedMean = durations.reduce(0.0, +) / n
        let expectedVar = durations.reduce(0.0) { $0 + pow($1 - expectedMean, 2.0) } / (n - 1.0)
        let expectedSDNN = sqrt(expectedVar)

        var diffs: [Double] = []
        for i in 0..<(durations.count - 1) {
            diffs.append(durations[i + 1] - durations[i])
        }
        let expectedRMSSD = sqrt(diffs.reduce(0.0) { $0 + $1 * $1 } / Double(diffs.count))
        let expectedPNN50 = 100.0 * Double(diffs.filter { abs($0) > 50.0 }.count) / Double(diffs.count)
        let meanDiff = diffs.reduce(0.0, +) / Double(diffs.count)
        let varDiff = diffs.reduce(0.0) { $0 + pow($1 - meanDiff, 2.0) } / Double(diffs.count - 1)
        let expectedSD1 = sqrt(0.5 * varDiff)
        let expectedSD2 = sqrt(2.0 * expectedSDNN * expectedSDNN - 0.5 * expectedSD1 * expectedSD1)

        #expect(metrics.validBeatCount == 110)
        #expect(abs(metrics.sdnnMs - expectedSDNN) < 1e-6)
        #expect(abs(metrics.rmssdMs - expectedRMSSD) < 1e-6)
        #expect(abs(metrics.pnn50Percent - expectedPNN50) < 1e-6)
        #expect(metrics.pnn50Percent > 10.0)
        #expect(abs(metrics.sd1Ms - expectedSD1) < 1e-6)
        #expect(abs(metrics.sd2Ms - expectedSD2) < 1e-6)
        #expect(metrics.baevskyStressIndex > 5.0 && metrics.baevskyStressIndex < 500.0)

        // Verify Lomb-Scargle accurately isolates the 0.10 Hz Mayer-wave resonance in the LF band
        #expect(abs(metrics.dominantFrequencyHz - 0.10) <= 0.006)
        #expect(metrics.lfPowerMs2 > metrics.hfPowerMs2 * 10.0)
        #expect(metrics.lfHfRatio > 10.0)
        #expect(metrics.rsaCoherenceScore > 0.85)
    }

    // MARK: - 6. CoreML [1, 12] Tensor Interop, PID Slew & 40-Epoch Monotonic Huber SGD

    @Test("CoreML MLMultiArray [1, 12] packing, output bounds, PID step response & 40-epoch monotonic Huber SGD")
    func verifyCoreMLTensorInteropPIDAndMonotonicOnlineSGD() async throws {
        let tempWeightsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TestAdaptiveWeights-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempWeightsURL) }

        let predictor = AdaptiveBrainwaveMLPredictor(
            initialWeights: NeuralReservoirWeights.makeDeterministicDefault(),
            persistToAppGroup: true,
            customStorageURL: tempWeightsURL
        )

        let features = BiometricFeatureVector(
            hrNormalized: 0.44,
            rmssdNormalized: 0.30,
            sdnnNormalized: 0.34,
            pnn50Normalized: 0.18,
            baevskyStressNormalized: 0.52,
            lfHfRatioNormalized: 0.36,
            rsaCoherenceScore: 0.38,
            respiratoryRateNormalized: 0.46,
            circadianPhaseSin: 0.50,
            circadianPhaseCos: -0.866,
            currentBeatHzNormalized: 0.65,
            sessionProgressRatio: 0.25
        )

        #if canImport(CoreML)
        let (provider, coreMLPrediction) = try await predictor.predictWithCoreMLInterop(features: features)
        #expect(provider.featureTensor.shape == [1, 12])
        #expect(provider.featureTensor.dataType == .double)
        let rawVector = features.asArray()
        for col in 0..<12 {
            let tensorVal = provider.featureTensor[[0, NSNumber(value: col)]].doubleValue
            #expect(abs(tensorVal - rawVector[col]) < 1e-12)
        }
        #expect(BrainwavePredictionOutput.beatHzRange.contains(coreMLPrediction.targetBinauralBeatHz))
        #expect(BrainwavePredictionOutput.carrierHzRange.contains(coreMLPrediction.targetCarrierFrequencyHz))
        #expect(BrainwavePredictionOutput.cutoffHzRange.contains(coreMLPrediction.targetFilterCutoffHz))
        #expect(BrainwavePredictionOutput.pinkNoiseRange.contains(coreMLPrediction.targetPinkNoiseMix))
        #expect(BrainwavePredictionOutput.coherenceRange.contains(coreMLPrediction.predictedVagalCoherence))
        #endif

        let initialPred = await predictor.predict(features: features)
        #expect(BrainwavePredictionOutput.beatHzRange.contains(initialPred.targetBinauralBeatHz))
        #expect(BrainwavePredictionOutput.carrierHzRange.contains(initialPred.targetCarrierFrequencyHz))
        #expect(BrainwavePredictionOutput.cutoffHzRange.contains(initialPred.targetFilterCutoffHz))
        #expect(BrainwavePredictionOutput.pinkNoiseRange.contains(initialPred.targetPinkNoiseMix))
        #expect(BrainwavePredictionOutput.coherenceRange.contains(initialPred.predictedVagalCoherence))

        // Verify PID damping controller smoothly slews from 28.0 Hz toward 8.5 Hz without abrupt jumps
        var pid = EntrainmentPIDController()
        var currentHz = 28.0
        let targetHz = 8.5
        for _ in 0..<12 {
            let nextHz = pid.stepBeatFrequency(currentHz: currentHz, targetHz: targetHz, dtSeconds: 1.0)
            #expect(abs(nextHz - currentHz) <= 2.25) // Bounded by maxSlewPerSecond = 2.2 Hz/s
            #expect(nextHz < currentHz)
            #expect(nextHz >= targetHz - 0.5)
            currentHz = nextHz
        }
        #expect(abs(currentHz - targetHz) < 2.5)

        // Verify strictly monotonic Huber-loss reduction across 40 epochs of online SGD weight updates
        var epochLosses: [Double] = []
        epochLosses.reserveCapacity(40)

        for _ in 0..<40 {
            let pred = await predictor.predict(features: features)
            let report = await predictor.updateWeightsWithObservedReward(
                previousFeatures: features,
                predictedOutput: pred,
                observedRMSSDDelta: -6.5,
                observedCoherenceDelta: -0.14,
                learningRate: 0.08
            )
            #expect(report.huberLoss.isFinite && report.huberLoss >= 0.0)
            epochLosses.append(report.huberLoss)
        }

        for idx in 1..<epochLosses.count {
            #expect(epochLosses[idx] < epochLosses[idx - 1])
        }
        #expect(epochLosses.last! < epochLosses.first! * 0.65)

        // Verify serialized weights round-trip from disk
        let reloadedPredictor = AdaptiveBrainwaveMLPredictor(
            persistToAppGroup: true,
            customStorageURL: tempWeightsURL
        )
        let reloadedWeights = await reloadedPredictor.currentWeightsSnapshot()
        #expect(reloadedWeights.trainedEpochCount == 40)
    }

    // MARK: - 7. WatchConnectivity Binary Checksum Framing & Closed-Loop Coherence Convergence

    @Test("WatchConnectivity FNV-1a binary framing round-trips and closed-loop bio-entrainment exceeds 0.80 coherence")
    func verifyWatchBridgeFNV1aFramingAndClosedLoopCoherence() async throws {
        var simulator = SyntheticPhysiologySimulator(initialStressLevel: 0.72, seed: 0x1234_5678_9ABC_DEF0)

        // Verify PQRST cardiac morphology exhibits sharp R-peak depolarization at phase 0.33
        let rPeakMV = SyntheticPhysiologySimulator.synthesizePQRSTMillivolts(cardiacPhase: 0.33)
        let baselineMV = SyntheticPhysiologySimulator.synthesizePQRSTMillivolts(cardiacPhase: 0.85)
        #expect(rPeakMV > 1.0)
        #expect(abs(baselineMV) < 0.05)

        let initialSim = simulator.advance(dtSeconds: 12.0, activeBinauralBeatHz: 28.0)

        // Round-trip biometric telemetry envelope via 64-bit FNV-1a binary wire frame
        let telemetryEnvelope = WatchBridgeEnvelope(
            sequenceID: 42,
            sentAt: Date(timeIntervalSince1970: 1_764_100_000),
            payload: .biometricTelemetry(snapshot: initialSim.snapshot, metrics: initialSim.metrics)
        )
        let encodedFrame = try WatchBridgeWireCodec.encodeFrame(telemetryEnvelope)
        let decodedEnvelope = try WatchBridgeWireCodec.decodeFrame(encodedFrame)
        #expect(decodedEnvelope == telemetryEnvelope)

        // Round-trip remote command packets through WatchBiometricBridgeActor
        let habitUUID = UUID()
        let commands: [WatchRemoteCommand] = [
            .startFocusSession,
            .pauseFocusSession,
            .scrubBinauralFreq(9.5),
            .logQuickHabitPulse(habitUUID, 15),
            .triggerHarmonicBloom
        ]

        let receiverBridge = WatchBiometricBridgeActor()
        let commandCollector = LockedCommandBox()
        await receiverBridge.setHandlers(
            onCommand: { cmd in
                commandCollector.append(cmd)
            }
        )

        for (idx, cmd) in commands.enumerated() {
            let env = WatchBridgeEnvelope(
                sequenceID: UInt64(100 + idx),
                sentAt: Date(timeIntervalSince1970: 1_764_100_010),
                payload: .remoteCommand(cmd)
            )
            let frame = try WatchBridgeWireCodec.encodeFrame(env)
            try await receiverBridge.ingestIncomingFrameData(frame)
        }
        #expect(commandCollector.snapshot() == commands)

        // Tamper a single payload byte and verify FNV-1a checksum rejection
        var corruptedFrame = encodedFrame
        let corruptIdx = corruptedFrame.count - 3
        corruptedFrame[corruptIdx] ^= 0x5A
        #expect(throws: WatchBridgeCodecError.self) {
            _ = try WatchBridgeWireCodec.decodeFrame(corruptedFrame)
        }

        // Closed-loop bio-entrainment simulation:
        // Start stressed at high-Beta 28.0 Hz and let AdaptiveBrainwaveMLPredictor + EntrainmentPIDController
        // steer binauralBeatHz into Alpha-Theta parasympathetic resonance until RSA coherence > 0.80.
        let closedLoopPredictor = AdaptiveBrainwaveMLPredictor(
            initialWeights: NeuralReservoirWeights.makeDeterministicDefault(),
            persistToAppGroup: false
        )
        var pid = EntrainmentPIDController()
        var currentParams = SynthParameters(
            carrierFrequencyHz: 260.0,
            binauralBeatHz: 28.0,
            pinkNoiseMix: 0.12,
            filterCutoffHz: 3_200.0
        )

        var previousMetrics = initialSim.metrics
        var peakCoherenceAchieved = initialSim.metrics.rsaCoherenceScore

        for step in 0..<45 {
            let simStep = simulator.advance(
                dtSeconds: 2.0,
                activeBinauralBeatHz: currentParams.binauralBeatHz
            )
            let progress = Double(step + 1) / 45.0
            let features = BiometricFeatureVector(
                snapshot: simStep.snapshot,
                metrics: simStep.metrics,
                currentBeatHz: Double(currentParams.binauralBeatHz),
                sessionProgressRatio: progress,
                referenceDate: simStep.snapshot.capturedAt
            )

            let prediction = await closedLoopPredictor.predict(features: features)
            let rmssdDelta = simStep.metrics.rmssdMs - previousMetrics.rmssdMs
            let cohDelta = simStep.metrics.rsaCoherenceScore - previousMetrics.rsaCoherenceScore

            if rmssdDelta > 0 || cohDelta > 0 {
                _ = await closedLoopPredictor.updateWeightsWithObservedReward(
                    previousFeatures: features,
                    predictedOutput: prediction,
                    observedRMSSDDelta: rmssdDelta,
                    observedCoherenceDelta: cohDelta,
                    learningRate: 0.025
                )
            }

            let slewed = pid.stepAcousticTargets(
                currentBeatHz: currentParams.binauralBeatHz,
                currentCarrierHz: currentParams.carrierFrequencyHz,
                currentCutoffHz: currentParams.filterCutoffHz,
                currentPinkNoiseMix: currentParams.pinkNoiseMix,
                prediction: prediction,
                dtSeconds: 2.0
            )
            currentParams.binauralBeatHz = slewed.beatHz
            currentParams.carrierFrequencyHz = slewed.carrierHz
            currentParams.filterCutoffHz = slewed.cutoffHz
            currentParams.pinkNoiseMix = slewed.pinkNoiseMix

            previousMetrics = simStep.metrics
            if simStep.metrics.rsaCoherenceScore > peakCoherenceAchieved {
                peakCoherenceAchieved = simStep.metrics.rsaCoherenceScore
            }
        }

        #expect(currentParams.binauralBeatHz < 13.5)
        #expect(peakCoherenceAchieved > 0.80)
        #expect(previousMetrics.rsaCoherenceScore > 0.80)
    }

    // MARK: - 8. 6-DoF SpatialPoseTelemeter Logarithmic Pinch, Schmitt Hysteresis & Quaternion Roll

    @Test("SpatialPoseTelemeter bimanual logarithmic pinch sweeps, Schmitt-trigger hysteresis & swing-twist wrist roll")
    func verifySpatialPoseTelemeterMathAndHysteresis() {
        var telemeter = SpatialPoseTelemeter(engageThresholdMeters: 0.018, releaseThresholdMeters: 0.028)
        let rightForearm = SIMD3<Float>(0.20, 1.10, -0.20)
        let rightWrist = SIMD3<Float>(0.20, 1.15, -0.35)
        let forearmAxis = simd_normalize(rightWrist - rightForearm)

        func makePose(
            leftAperture: Float,
            rightAperture: Float,
            palmSpan: Float,
            wristRollRad: Float
        ) -> BimanualHandPoseSample {
            let halfSpan = palmSpan * 0.5
            let leftPalm = SIMD3<Float>(-halfSpan, 1.20, -0.40)
            let rightPalm = SIMD3<Float>(halfSpan, 1.20, -0.40)
            let leftThumb = leftPalm + SIMD3<Float>(0.02, 0.02, -0.05)
            let rightThumb = rightPalm + SIMD3<Float>(-0.02, 0.02, -0.05)

            return BimanualHandPoseSample(
                leftThumbTip: leftThumb,
                leftIndexTip: leftThumb + SIMD3<Float>(0.0, leftAperture, 0.0),
                leftWrist: leftPalm + SIMD3<Float>(0.0, -0.05, 0.05),
                leftForearmArm: leftPalm + SIMD3<Float>(0.0, -0.10, 0.20),
                leftPalm: leftPalm,
                rightThumbTip: rightThumb,
                rightIndexTip: rightThumb + SIMD3<Float>(0.0, rightAperture, 0.0),
                rightWrist: rightWrist,
                rightForearmArm: rightForearm,
                rightPalm: rightPalm,
                rightWristOrientation: simd_quatf(angle: wristRollRad, axis: forearmAxis),
                timestamp: 1.0
            )
        }

        // 1. Exact logarithmic endpoints & geometric midpoint (0.0625m -> sqrt(fMin * fMax))
        let closedOut = telemeter.evaluate(
            pose: makePose(leftAperture: 0.005, rightAperture: 0.005, palmSpan: 0.10, wristRollRad: -.pi * 0.5)
        )
        #expect(abs(closedOut.binauralBeatHz - 1.5) < 1e-4)
        #expect(abs(closedOut.filterCutoffHz - 120.0) < 1e-2)
        #expect(abs(closedOut.filterResonance - 0.08) < 1e-3)
        #expect(abs(closedOut.padDetuneCents - 2.0) < 1e-3)
        #expect(abs(closedOut.bloomBoost - 0.0) < 1e-4)
        #expect(closedOut.leftPinchEngaged && closedOut.rightPinchEngaged)

        // 2. Hysteresis deadband: opening from 0.005m to 0.023m (< 0.028m release) MUST keep pinch latched
        let deadbandLatched = telemeter.evaluate(
            pose: makePose(leftAperture: 0.023, rightAperture: 0.023, palmSpan: 0.475, wristRollRad: 0.0)
        )
        #expect(deadbandLatched.leftPinchEngaged)
        #expect(deadbandLatched.rightPinchEngaged)
        #expect(abs(deadbandLatched.filterResonance - 0.50) < 1e-2)
        #expect(abs(deadbandLatched.bloomBoost - 0.50) < 1e-2)

        // 3. Geometric midpoint aperture 0.0625m releases Schmitt trigger and hits exact geometric mean frequencies
        let midpointOut = telemeter.evaluate(
            pose: makePose(leftAperture: 0.0625, rightAperture: 0.0625, palmSpan: 0.475, wristRollRad: 0.0)
        )
        #expect(!midpointOut.leftPinchEngaged && !midpointOut.rightPinchEngaged)
        let expectedMidBeat = sqrtf(1.5 * 40.0)        // ~7.7459667 Hz
        let expectedMidCutoff = sqrtf(120.0 * 12_000.0) // 1200.0 Hz
        #expect(abs(midpointOut.binauralBeatHz - expectedMidBeat) < 1e-3)
        #expect(abs(midpointOut.filterCutoffHz - expectedMidCutoff) < 0.5)

        // 4. Re-entering deadband from open (0.023m > 0.018m engage) MUST remain unengaged
        let deadbandOpen = telemeter.evaluate(
            pose: makePose(leftAperture: 0.023, rightAperture: 0.023, palmSpan: 0.475, wristRollRad: 0.0)
        )
        #expect(!deadbandOpen.leftPinchEngaged && !deadbandOpen.rightPinchEngaged)

        // 5. Maximum open aperture (0.120m) & +pi/2 wrist roll -> 40 Hz, 12,000 Hz, Q = 0.92, full span
        let maxOut = telemeter.evaluate(
            pose: makePose(leftAperture: 0.120, rightAperture: 0.120, palmSpan: 0.85, wristRollRad: .pi * 0.5)
        )
        #expect(abs(maxOut.binauralBeatHz - 40.0) < 1e-3)
        #expect(abs(maxOut.filterCutoffHz - 12_000.0) < 1.0)
        #expect(abs(maxOut.filterResonance - 0.92) < 1e-3)
        #expect(abs(maxOut.bloomBoost - 1.0) < 1e-4)
        #expect(maxOut.orbitalRadiusScale > 1.35)
    }

    // MARK: - 9. ProceduralMeshGenerator Geodesic Icosahedron & Torus-Knot Topological Invariants

    @Test("ProceduralMeshGenerator geodesic icosahedron & Keplerian torus-knot closed manifold invariants")
    func verifyProceduralMeshTopologyNormalsAndSurfaceArea() {
        // 1. Geodesic icosahedron at subdivisions s = 2: V = 10*4^2 + 2 = 162, F = 20*4^2 = 320, E = 480, chi = 2
        let radius: Float = 0.25
        let ico = ProceduralMeshGenerator.generateGeodesicIcosahedron(radius: radius, subdivisions: 2)
        #expect(ico.vertexCount == 162)
        #expect(ico.triangleCount == 320)
        #expect(ico.normals.count == ico.vertexCount)
        #expect(ico.uvs.count == ico.vertexCount)

        for idx in 0..<ico.vertexCount {
            let posLen = simd_length(ico.positions[idx])
            let normLen = simd_length(ico.normals[idx])
            #expect(abs(posLen - radius) < 1e-5)
            #expect(abs(normLen - 1.0) < 1e-5)
            #expect(simd_dot(simd_normalize(ico.positions[idx]), ico.normals[idx]) > 0.9999)
            #expect(ico.uvs[idx].x >= 0.0 && ico.uvs[idx].x <= 1.0)
            #expect(ico.uvs[idx].y >= 0.0 && ico.uvs[idx].y <= 1.0)
        }

        var icoUndirectedEdges: [UInt64: Int] = [:]
        for t in 0..<ico.triangleCount {
            let a = ico.indices[t * 3]
            let b = ico.indices[t * 3 + 1]
            let c = ico.indices[t * 3 + 2]
            #expect(Int(a) < ico.vertexCount && Int(b) < ico.vertexCount && Int(c) < ico.vertexCount)
            #expect(a != b && b != c && c != a)

            for (u, v) in [(a, b), (b, c), (c, a)] {
                let key = (UInt64(min(u, v)) << 32) | UInt64(max(u, v))
                icoUndirectedEdges[key, default: 0] += 1
            }
        }
        #expect(icoUndirectedEdges.count == 480)
        #expect(icoUndirectedEdges.values.allSatisfy { $0 == 2 })
        let eulerIco = ico.vertexCount - icoUndirectedEdges.count + ico.triangleCount
        #expect(eulerIco == 2)

        let analyticSphereArea = 4.0 * Float.pi * radius * radius
        let meshArea = ico.totalSurfaceArea()
        #expect(meshArea > analyticSphereArea * 0.96 && meshArea <= analyticSphereArea * 1.001)

        // 2. Keplerian (2, 3) torus knot: closed genus-1 manifold (Euler characteristic V - E + F = 0)
        let knot = ProceduralMeshGenerator.generateKeplerianTorusKnot(
            p: 2,
            q: 3,
            majorRadius: 0.18,
            tubeRadius: 0.022,
            tubularSegments: 64,
            radialSegments: 12
        )
        #expect(knot.vertexCount == 64 * 12)
        #expect(knot.triangleCount == 64 * 12 * 2)

        for n in knot.normals {
            #expect(abs(simd_length(n) - 1.0) < 1e-4)
        }

        var knotUndirectedEdges: [UInt64: Int] = [:]
        for t in 0..<knot.triangleCount {
            let a = knot.indices[t * 3]
            let b = knot.indices[t * 3 + 1]
            let c = knot.indices[t * 3 + 2]
            #expect(Int(a) < knot.vertexCount && Int(b) < knot.vertexCount && Int(c) < knot.vertexCount)
            for (u, v) in [(a, b), (b, c), (c, a)] {
                let key = (UInt64(min(u, v)) << 32) | UInt64(max(u, v))
                knotUndirectedEdges[key, default: 0] += 1
            }
        }
        #expect(knotUndirectedEdges.values.allSatisfy { $0 == 2 })
        let eulerKnot = knot.vertexCount - knotUndirectedEdges.count + knot.triangleCount
        #expect(eulerKnot == 0)
        #expect(knot.totalSurfaceArea() > 0.05)
    }

    // MARK: - 10. Multi-Sample-Rate Cross-Platform DSP & FFT Determinism (44.1 kHz, 48 kHz, 96 kHz)

    @Test("ProceduralSynthKernel & SpectralFFTAnalyzer remain deterministic across 44.1 kHz, 48 kHz & 96 kHz")
    func verifyMultiSampleRateCrossPlatformDeterminism() {
        let sampleRates: [Double] = [44_100.0, 48_000.0, 96_000.0]
        let params = SynthParameters(
            carrierFrequencyHz: 375.0,
            binauralBeatHz: 10.0,
            binauralMix: 0.85,
            pinkNoiseMix: 0.10,
            padMix: 0.35,
            filterCutoffHz: 4_800.0,
            filterResonance: 0.32,
            padDetuneCents: 10.0,
            masterGain: 0.65,
            isMuted: false
        )

        for sr in sampleRates {
            var kernelA = ProceduralSynthKernel(sampleRate: sr, snapInitialParameters: params)
            var kernelB = ProceduralSynthKernel(sampleRate: sr, snapInitialParameters: params)

            let frames = 2_048
            var leftA = [Float](repeating: 0, count: frames)
            var rightA = [Float](repeating: 0, count: frames)
            var leftB = [Float](repeating: 0, count: frames)
            var rightB = [Float](repeating: 0, count: frames)

            let snapA = leftA.withUnsafeMutableBufferPointer { l in
                rightA.withUnsafeMutableBufferPointer { r in
                    kernelA.renderStereoBlock(leftOutput: l.baseAddress!, rightOutput: r.baseAddress!, frameCount: frames, target: params)
                }
            }
            let snapB = leftB.withUnsafeMutableBufferPointer { l in
                rightB.withUnsafeMutableBufferPointer { r in
                    kernelB.renderStereoBlock(leftOutput: l.baseAddress!, rightOutput: r.baseAddress!, frameCount: frames, target: params)
                }
            }

            // Exact bit-for-bit determinism across twin kernel instances
            #expect(leftA == leftB)
            #expect(rightA == rightB)
            #expect(snapA.rmsAmplitude == snapB.rmsAmplitude)
            #expect(snapA.rmsAmplitude > 0.05 && snapA.peakAmplitude <= 1.0)

            // Verify SpectralFFTAnalyzer bin resolution and sub/low/high band energies at each sample rate
            let n = SpectralFFTAnalyzer.fftLength
            let exactBin8Hz = 8.0 * (sr / Double(n))
            var syntheticSine = [Float](repeating: 0, count: n)
            for i in 0..<n {
                syntheticSine[i] = Float(sin(2.0 * Double.pi * exactBin8Hz * Double(i) / sr)) * 0.85
            }

            let analyzer = SpectralFFTAnalyzer()
            let fftFrame = analyzer.analyze(samples: syntheticSine, sampleRate: sr)
            #expect(fftFrame.bars.count == 64)
            #expect(abs(Double(fftFrame.dominantFrequencyHz) - exactBin8Hz) < 1.5)
            #expect(fftFrame.subBandEnergy >= 0.0 && fftFrame.subBandEnergy <= 1.0)
            #expect(fftFrame.lowBandEnergy >= 0.0 && fftFrame.lowBandEnergy <= 1.0)
            #expect(fftFrame.highBandEnergy >= 0.0 && fftFrame.highBandEnergy <= 1.0)
        }
    }

    // MARK: - 11. Parametric KEMAR HRTF Physical Invariants (ITD, Contralateral Head Shadow & Pinna Notch)

    @Test("KEMARHRIRSynthesizer median-plane symmetry, lateralized Woodworth-Schlosberg ITD, >6 dB head shadow & pinna notch shift")
    func verifyKEMARHRTFPhysicalInvariants() {
        let sampleRate: Double = 48_000.0

        // 1. Median-plane symmetry: ITD(0°, φ) == 0 and ||h_L - h_R||_2 < 1e-6 across elevations
        let elevations: [Float] = [-30.0, 0.0, 30.0, 60.0]
        for el in elevations {
            let itdSec = KEMARHRIRSynthesizer.woodworthSchlosbergITDSeconds(
                azimuthDeg: 0.0,
                elevationDeg: el
            )
            #expect(abs(itdSec) < 1e-9)

            let pair = KEMARHRIRSynthesizer.synthesize(
                pose: BinauralSourcePose(azimuthDeg: 0.0, elevationDeg: el, distanceMeters: 1.4),
                sampleRate: sampleRate
            )
            #expect(pair.left.count == KEMARHRIRSynthesizer.tapCount)
            #expect(pair.right.count == KEMARHRIRSynthesizer.tapCount)
            #expect(abs(pair.itdSeconds) < 1e-9)

            var l2DiffSquared: Float = 0.0
            for i in 0..<KEMARHRIRSynthesizer.tapCount {
                let d = pair.left[i] - pair.right[i]
                l2DiffSquared += d * d
            }
            let l2NormDiff = sqrtf(l2DiffSquared)
            #expect(l2NormDiff < 1e-6)
        }

        // 2. Lateralized Woodworth-Schlosberg ITD at θ = +90°, φ = 0°:
        //    Right ear leads left ear by (a / c) * (1 + π/2) ≈ 0.0006557s (≈ 31.47 samples at 48 kHz)
        let lateralPose = BinauralSourcePose(azimuthDeg: 90.0, elevationDeg: 0.0, distanceMeters: 1.4)
        let lateralPair = KEMARHRIRSynthesizer.synthesize(pose: lateralPose, sampleRate: sampleRate)

        let expectedITDSec: Float = (0.0875 / 343.0) * (1.0 + .pi * 0.5)
        #expect(abs(lateralPair.itdSeconds - expectedITDSec) < 1e-6)
        #expect(abs(lateralPair.itdSeconds * 1_000.0 - 0.6557) < 0.005)
        let expectedSampleLag = expectedITDSec * Float(sampleRate)
        #expect(abs(expectedSampleLag - 31.47) < 0.15)

        // Verify empirical impulse peak index in right ear leads left ear by ~31.5 samples
        let rightPeakIdx = lateralPair.right.enumerated().max(by: { abs($0.element) < abs($1.element) })?.offset ?? 0
        let leftPeakIdx = lateralPair.left.enumerated().max(by: { abs($0.element) < abs($1.element) })?.offset ?? 0
        let measuredSampleLead = Float(leftPeakIdx - rightPeakIdx)
        #expect(rightPeakIdx < leftPeakIdx)
        #expect(abs(measuredSampleLead - expectedSampleLag) <= 2.0)

        // Verify high-frequency contralateral (left-ear) head-shadow attenuation exceeds 6.0 dB above 5 kHz
        func averageBandPowerDB(ir: [Float], fLow: Double, fHigh: Double) -> Float {
            let freqs = stride(from: fLow, through: fHigh, by: 250.0)
            var totalPower: Double = 0.0
            var count = 0
            for f in freqs {
                let omega = 2.0 * Double.pi * f / sampleRate
                var re = 0.0
                var im = 0.0
                for (n, h) in ir.enumerated() {
                    let angle = omega * Double(n)
                    re += Double(h) * cos(angle)
                    im -= Double(h) * sin(angle)
                }
                totalPower += (re * re + im * im)
                count += 1
            }
            let meanPower = max(totalPower / Double(max(1, count)), 1e-12)
            return Float(10.0 * log10(meanPower))
        }

        let rightHFdB = averageBandPowerDB(ir: lateralPair.right, fLow: 5_000.0, fHigh: 16_000.0)
        let leftHFdB = averageBandPowerDB(ir: lateralPair.left, fLow: 5_000.0, fHigh: 16_000.0)
        let contralateralAttenuationDB = rightHFdB - leftHFdB
        #expect(contralateralAttenuationDB > 6.0)

        // 3. Verify Pinna primary spectral notch shifts monotonically upward as elevation φ increases from -30° to +60°
        let sweepElevations: [Float] = [-30.0, -10.0, 10.0, 30.0, 60.0]
        var previousAnalyticalNotchHz: Float = 0.0
        var previousMeasuredNotchHz: Double = 0.0

        for (idx, elDeg) in sweepElevations.enumerated() {
            let elRad = elDeg * .pi / 180.0
            let analyticalNotchHz = KEMARHRIRSynthesizer.primaryPinnaNotchFrequencyHz(elevationRad: elRad)
            let pair = KEMARHRIRSynthesizer.synthesize(
                pose: BinauralSourcePose(azimuthDeg: 0.0, elevationDeg: elDeg, distanceMeters: 1.5),
                sampleRate: sampleRate
            )

            // Search fine DFT magnitude minimum in the primary pinna notch band [3,800 Hz ... 10,000 Hz]
            var minMagSq = Double.greatestFiniteMagnitude
            var measuredNotchHz = Double(analyticalNotchHz)
            var f = 3_800.0
            while f <= 10_000.0 {
                let omega = 2.0 * Double.pi * f / sampleRate
                var re = 0.0
                var im = 0.0
                for (n, h) in pair.left.enumerated() {
                    let angle = omega * Double(n)
                    re += Double(h) * cos(angle)
                    im -= Double(h) * sin(angle)
                }
                let magSq = re * re + im * im
                if magSq < minMagSq {
                    minMagSq = magSq
                    measuredNotchHz = f
                }
                f += 25.0
            }

            if idx > 0 {
                #expect(analyticalNotchHz > previousAnalyticalNotchHz)
                #expect(measuredNotchHz > previousMeasuredNotchHz)
            }
            previousAnalyticalNotchHz = analyticalNotchHz
            previousMeasuredNotchHz = measuredNotchHz
        }
    }

    // MARK: - 12. UPOLS FFT Convolver Mathematical Equivalence & Dual-Path Crossfade

    @Test("PartitionedOverlapSaveConvolver matches direct time-domain O(N*M) linear convolution (< 1e-4 max error)")
    func verifyUPOLSConvolverEquivalenceAndCrossfade() {
        let sampleCount = 4_096
        let hrirPair = KEMARHRIRSynthesizer.synthesize(
            pose: BinauralSourcePose(azimuthDeg: 38.0, elevationDeg: 18.0, distanceMeters: 1.25),
            sampleRate: 48_000.0
        )

        var inputSignal = [Float](repeating: 0.0, count: sampleCount)
        for n in 0..<sampleCount {
            let t = Float(n) / 48_000.0
            inputSignal[n] = 0.45 * sinf(2.0 * .pi * 220.0 * t)
                + 0.30 * cosf(2.0 * .pi * 1_240.0 * t + 0.4)
                + 0.20 * sinf(2.0 * .pi * 4_800.0 * t * (1.0 + 0.15 * t))
        }

        // Direct time-domain O(N * M) reference linear convolution
        var refLeft = [Float](repeating: 0.0, count: sampleCount)
        var refRight = [Float](repeating: 0.0, count: sampleCount)
        let tapCount = KEMARHRIRSynthesizer.tapCount
        for n in 0..<sampleCount {
            var sumL: Float = 0.0
            var sumR: Float = 0.0
            let maxK = min(n, tapCount - 1)
            for k in 0...maxK {
                let x = inputSignal[n - k]
                sumL += x * hrirPair.left[k]
                sumR += x * hrirPair.right[k]
            }
            refLeft[n] = sumL
            refRight[n] = sumR
        }

        var convolver = PartitionedOverlapSaveConvolver()
        hrirPair.left.withUnsafeBufferPointer { lPtr in
            hrirPair.right.withUnsafeBufferPointer { rPtr in
                convolver.setHRIR(
                    leftTaps: lPtr.baseAddress!,
                    rightTaps: rPtr.baseAddress!,
                    tapCount: tapCount,
                    crossfade: false
                )
            }
        }

        var upolsLeft = [Float](repeating: 0.0, count: sampleCount)
        var upolsRight = [Float](repeating: 0.0, count: sampleCount)
        inputSignal.withUnsafeBufferPointer { inPtr in
            upolsLeft.withUnsafeMutableBufferPointer { outL in
                upolsRight.withUnsafeMutableBufferPointer { outR in
                    convolver.process(
                        input: inPtr.baseAddress!,
                        leftOutput: outL.baseAddress!,
                        rightOutput: outR.baseAddress!,
                        frameCount: sampleCount
                    )
                }
            }
        }

        var maxAbsError: Float = 0.0
        for n in 0..<sampleCount {
            let errL = abs(upolsLeft[n] - refLeft[n])
            let errR = abs(upolsRight[n] - refRight[n])
            maxAbsError = max(maxAbsError, max(errL, errR))
        }
        #expect(maxAbsError < 1e-4)

        // Verify dual-path raised-cosine crossfaded HRIR switching across large azimuth jump remains finite & click-free
        var spatialConvolver = SpatialHRTFConvolver(sampleRate: 48_000.0)
        var blockLeft = [Float](repeating: 0.0, count: 256)
        var blockRight = [Float](repeating: 0.0, count: 256)
        inputSignal.withUnsafeBufferPointer { inPtr in
            blockLeft.withUnsafeMutableBufferPointer { outL in
                blockRight.withUnsafeMutableBufferPointer { outR in
                    spatialConvolver.processMonoToBinaural(
                        monoInput: inPtr.baseAddress!,
                        leftOutput: outL.baseAddress!,
                        rightOutput: outR.baseAddress!,
                        frameCount: 128,
                        targetPose: BinauralSourcePose(azimuthDeg: -65.0, elevationDeg: -10.0, distanceMeters: 1.2)
                    )
                    spatialConvolver.processMonoToBinaural(
                        monoInput: inPtr.baseAddress!.advanced(by: 128),
                        leftOutput: outL.baseAddress!.advanced(by: 128),
                        rightOutput: outR.baseAddress!.advanced(by: 128),
                        frameCount: 128,
                        targetPose: BinauralSourcePose(azimuthDeg: 75.0, elevationDeg: 35.0, distanceMeters: 1.2)
                    )
                }
            }
        }
        #expect(spatialConvolver.crossfadeCount >= 1)
        #expect(blockLeft.allSatisfy { $0.isFinite && abs($0) <= 2.0 })
        #expect(blockRight.allSatisfy { $0.isFinite && abs($0) <= 2.0 })
    }

    // MARK: - 13. 3D Shoebox Image-Source Early Reflections & Monotonic Preset Energy

    @Test("ShoeboxRoomSimulator solves 18 (6 first-order + 12 second-order) reflections & monotonic preset energy")
    func verifyShoeboxImageSourceReflectionsAndPresets() {
        let sourcePose = BinauralSourcePose(azimuthDeg: 28.0, elevationDeg: 12.0, distanceMeters: 1.65)
        let headQuat = simd_quatf(angle: 0.15, axis: SIMD3<Float>(0.0, 1.0, 0.0))

        var presetEnergies: [Float] = []
        for preset in ShoeboxRoomPreset.allCases {
            let solved = ShoeboxRoomSimulator.solveImageSources(
                configuration: preset.configuration,
                sourcePose: sourcePose,
                headOrientation: headQuat
            )

            // Exactly 6 first-order + 12 second-order edge = 18 virtual image sources
            #expect(solved.taps.count == 18)
            let firstOrderCount = solved.taps.filter { $0.order == 1 }.count
            let secondOrderCount = solved.taps.filter { $0.order == 2 }.count
            #expect(firstOrderCount == 6)
            #expect(secondOrderCount == 12)
            #expect(solved.directDelaySeconds > 0.0)

            for tap in solved.taps {
                #expect(tap.delaySeconds > solved.directDelaySeconds)
                #expect(tap.distanceMeters > solved.directDistanceMeters)
                #expect(tap.effectiveGain > 0.0)
                #expect(tap.effectiveGain <= (1.0 / tap.distanceMeters) + 1e-6)
                #expect(tap.airAbsorptionLP >= 0.05 && tap.airAbsorptionLP <= 0.995)
                #expect(tap.listenerAzimuthDeg >= -180.0 && tap.listenerAzimuthDeg <= 180.0)
                #expect(tap.listenerElevationDeg >= -90.0 && tap.listenerElevationDeg <= 90.0)
            }

            presetEnergies.append(solved.totalReflectionEnergy)
        }

        // Verify strictly monotonic reflection energy across presets:
        // Anechoic Chamber < Obsidian Studio < Glass Conservatory < Cathedral Vault
        #expect(presetEnergies.count == 4)
        for idx in 1..<presetEnergies.count {
            #expect(presetEnergies[idx] > presetEnergies[idx - 1])
        }
    }

    // MARK: - 14. MPSGraph GPU / SIMD Autodiff Neural Training Convergence (>65% Loss Reduction)

    @Test("MPSGraphBrainwaveTrainer 50-epoch training reduces loss by >65%, clips ||∇L||₂ <= 1.0 & round-trips checkpoints")
    func verifyMPSGraphAndSIMDAutodiffTrainingConvergence() async throws {
        let dataset = BiometricTrainingBatch.makeSyntheticBiometricDataset(batchSize: 8, seed: 0xA37E_5F01_99CC_1234)
        #expect(dataset.batchSize == 8)
        #expect(dataset.inputs.count == 8 * MPSGraphBrainwaveTrainer.sequenceLength * MPSGraphBrainwaveTrainer.featureDim)
        #expect(dataset.targets.count == 8 * MPSGraphBrainwaveTrainer.outputDim)

        let tempCheckpointURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TestMPSGraphBrainwaveTrainer-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempCheckpointURL) }

        // 1. Train 50 epochs on primary trainer (uses MPSGraph GPU when available, or deterministic SIMD fallback)
        let primaryTrainer = MPSGraphBrainwaveTrainer(
            learningRate: 0.032,
            weightDecay: 1e-4,
            gradientClipNorm: 1.0,
            checkpointURL: tempCheckpointURL
        )

        let initialEvalLoss = await primaryTrainer.evaluateLoss(batch: dataset)
        #expect(initialEvalLoss.isFinite && initialEvalLoss > 0.01)

        let history = await primaryTrainer.trainEpochs(batch: dataset, epochs: 50)
        #expect(history.count == 50)

        for snap in history {
            #expect(snap.latestLoss.isFinite && snap.latestLoss >= 0.0)
            #expect(snap.emaLoss.isFinite && snap.emaLoss >= 0.0)
            #expect(snap.gradientL2Norm.isFinite && snap.gradientL2Norm >= 0.0)
            #expect(snap.gradientL2Norm <= 1.0 + 1e-4)
        }

        let finalEvalLoss = await primaryTrainer.evaluateLoss(batch: dataset)
        let firstEpochLoss = history.first!.latestLoss
        let lastEpochLoss = history.last!.latestLoss
        // Verify training loss decreases by > 65% (residual loss < 0.35 * initial loss)
        #expect(lastEpochLoss < firstEpochLoss * 0.35)
        #expect(finalEvalLoss < initialEvalLoss * 0.35)

        // 2. Verify physical setpoint prediction bounds
        let firstWindow = Array(dataset.inputs.prefix(MPSGraphBrainwaveTrainer.sequenceLength * MPSGraphBrainwaveTrainer.featureDim))
        let pred = await primaryTrainer.predictOptimalSetpoint(sequence8x12: firstWindow)
        #expect((1.5...40.0).contains(pred.binauralBeatHz))
        #expect((96.0...432.0).contains(pred.carrierHz))
        #expect((180.0...6_400.0).contains(pred.filterCutoffHz))
        #expect((0.05...1.60).contains(pred.hrtfOrbitSpeed))
        #expect((0.0...1.0).contains(pred.targetCoherence))

        // 3. Verify checkpoint persistence round-trip
        let savedWeights = await primaryTrainer.snapshotWeights()
        let savedURL = try await primaryTrainer.saveCheckpoint()
        #expect(FileManager.default.fileExists(atPath: savedURL.path))

        let reloadedTrainer = MPSGraphBrainwaveTrainer(
            forceCPUFallback: true,
            checkpointURL: tempCheckpointURL
        )
        let loadedSnap = try await reloadedTrainer.loadCheckpoint()
        let reloadedWeights = await reloadedTrainer.snapshotWeights()
        #expect(loadedSnap.epochCount == 50)
        #expect(reloadedWeights == savedWeights)

        // 4. Explicitly verify CPU SIMD Autodiff fallback converges identically > 65%
        let simdTrainer = MPSGraphBrainwaveTrainer(
            forceCPUFallback: true,
            learningRate: 0.032,
            weightDecay: 1e-4,
            gradientClipNorm: 1.0,
            checkpointURL: tempCheckpointURL
        )
        let simdHistory = await simdTrainer.trainEpochs(batch: dataset, epochs: 50)
        #expect(simdHistory.last!.activeBackend == .cpuSIMDFallback)
        #expect(simdHistory.last!.latestLoss < simdHistory.first!.latestLoss * 0.35)
        #expect(simdHistory.allSatisfy { $0.gradientL2Norm.isFinite && $0.gradientL2Norm <= 1.0 + 1e-4 })
    }

    // MARK: - 15. Phase 7 Track 24: GPU/SAH-BVH 3D Acoustic Ray-Tracer, Möller–Trumbore & RT60 Invariants

    @Test("Acoustic SAH-BVH Möller–Trumbore analytical plane intersection & watertight zero-leak closed room invariant")
    func verifyAcousticSAHBVHMollerTrumboreAndWatertightChambers() async {
        let halfExtents = SIMD3<Float>(4.0, 2.5, 5.0)
        let boxRoom = ProceduralMeshGenerator.makeClosedBoxRoom(halfExtents: halfExtents, materialIndex: 0)
        let bvh = AcousticSAHBVH(triangles: boxRoom.triangles)

        // 1. Verify exact analytical plane intersection distances from origin along all 6 cardinal directions
        let cardinalTests: [(dir: SIMD3<Float>, expectedDist: Float, expectedNormal: SIMD3<Float>)] = [
            (SIMD3<Float>(1, 0, 0), 4.0, SIMD3<Float>(-1, 0, 0)),
            (SIMD3<Float>(-1, 0, 0), 4.0, SIMD3<Float>(1, 0, 0)),
            (SIMD3<Float>(0, 1, 0), 2.5, SIMD3<Float>(0, -1, 0)),
            (SIMD3<Float>(0, -1, 0), 2.5, SIMD3<Float>(0, 1, 0)),
            (SIMD3<Float>(0, 0, 1), 5.0, SIMD3<Float>(0, 0, -1)),
            (SIMD3<Float>(0, 0, -1), 5.0, SIMD3<Float>(0, 0, 1))
        ]

        for testCase in cardinalTests {
            let hit = bvh.traceClosestHit(origin: .zero, direction: testCase.dir)
            #expect(hit != nil)
            if let hit {
                #expect(abs(hit.distance - testCase.expectedDist) < 1.0e-4)
                #expect(simd_distance(hit.point, testCase.dir * testCase.expectedDist) < 1.0e-4)
                #expect(simd_dot(hit.normal, testCase.expectedNormal) > 0.999)
            }
        }

        // Verify oblique ray intersection against analytical slab distance min(4/|dx|, 2.5/|dy|, 5/|dz|)
        let obliqueDir = simd_normalize(SIMD3<Float>(0.6, 0.7, -0.38729833))
        let analyticalObliqueDist = min(
            halfExtents.x / abs(obliqueDir.x),
            min(halfExtents.y / abs(obliqueDir.y), halfExtents.z / abs(obliqueDir.z))
        )
        let obliqueHit = bvh.traceClosestHit(origin: .zero, direction: obliqueDir)
        #expect(obliqueHit != nil)
        if let obliqueHit {
            #expect(abs(obliqueHit.distance - analyticalObliqueDist) < 1.0e-4)
        }

        // 2. Verify zero leaked rays across 4,096 rays inside closed box & all 3 architectural chambers + satellites
        let tracer = MetalAcousticRayTracer(preferHardwareRayTracing: false)
        let boxReport = await tracer.solveCustomGeometry(
            chamberLabel: .geodesicSanctuary,
            chamberGeometry: boxRoom,
            materials: [AcousticSurfaceMaterialPreset.obsidianMarble.material],
            sourcePosition: SIMD3<Float>(0.4, 0.2, 0.8),
            listenerPose: ListenerHeadPose3D(position: SIMD3<Float>(-0.5, -0.1, -1.0)),
            rayCount: 4_096,
            maxBounces: 16,
            forceCPUFallback: true
        )
        #expect(boxReport.leakedRayCount == 0)
        #expect(boxReport.leftDRIR.count == 512)
        #expect(boxReport.rightDRIR.count == 512)

        let habits = HabitNodeDTO.defaultSeeds
        for chamber in AcousticChamberPreset.allCases {
            let report = await tracer.solveChamberAcoustics(
                chamber: chamber,
                surfaceMaterial: AcousticSurfaceMaterialPreset.perforatedAcousticWood.material,
                habits: habits,
                orbitalPhaseRadians: 0.45,
                rayCount: 1_024,
                maxBounces: 16,
                forceCPUFallback: true
            )
            #expect(report.leakedRayCount == 0)
            #expect(report.leftDRIR.allSatisfy { $0.isFinite })
            #expect(report.rightDRIR.allSatisfy { $0.isFinite })
        }
    }

    @Test("Acoustic 16-bounce energy conservation, monotonic bounce decay & 4-band RT60 absorption monotonicity")
    func verifyAcousticBounceDecayAndRT60AbsorptionMonotonicity() async {
        let tracer = MetalAcousticRayTracer(preferHardwareRayTracing: false)
        let boxRoom = ProceduralMeshGenerator.makeClosedBoxRoom(
            halfExtents: SIMD3<Float>(4.5, 3.0, 5.5),
            materialIndex: 0
        )

        let lowAlphaMaterial = AcousticSurfaceMaterial(
            name: "Low Absorption Reference",
            absorption: SIMD4<Float>(repeating: 0.10),
            scattering: SIMD4<Float>(repeating: 0.35)
        )
        let highAlphaMaterial = AcousticSurfaceMaterial(
            name: "High Absorption Reference",
            absorption: SIMD4<Float>(repeating: 0.80),
            scattering: SIMD4<Float>(repeating: 0.35)
        )

        let bridge = RayTracedDRIRConvolverBridge()
        let lowReport = await tracer.solveCustomGeometry(
            chamberGeometry: boxRoom,
            materials: [lowAlphaMaterial],
            sourcePosition: SIMD3<Float>(0.0, 0.3, 1.4),
            listenerPose: ListenerHeadPose3D(position: SIMD3<Float>(0.0, 0.0, -1.2)),
            rayCount: 2_048,
            maxBounces: 16,
            forceCPUFallback: true,
            convolverBridge: bridge
        )
        let highReport = await tracer.solveCustomGeometry(
            chamberGeometry: boxRoom,
            materials: [highAlphaMaterial],
            sourcePosition: SIMD3<Float>(0.0, 0.3, 1.4),
            listenerPose: ListenerHeadPose3D(position: SIMD3<Float>(0.0, 0.0, -1.2)),
            rayCount: 2_048,
            maxBounces: 16,
            forceCPUFallback: true,
            convolverBridge: bridge
        )

        // 1. Verify monotonic energy decay across bounces
        #expect(lowReport.bounceMeanEnergyEnvelope.count == 16)
        for b in 1..<lowReport.bounceMeanEnergyEnvelope.count {
            let prev = lowReport.bounceMeanEnergyEnvelope[b - 1]
            let curr = lowReport.bounceMeanEnergyEnvelope[b]
            if curr.x > 0 && prev.x > 0 {
                #expect(curr.x < prev.x)
                #expect(curr.y < prev.y)
                #expect(curr.z < prev.z)
                #expect(curr.w < prev.w)
            }
        }

        // 2. Verify Sabine, Eyring & Ray-Traced Schroeder RT60 decrease strictly across all 4 octave bands when alpha increases 0.10 -> 0.80
        for band in 0..<4 {
            #expect(highReport.sabineRT60PerBand[band] < lowReport.sabineRT60PerBand[band])
            #expect(highReport.eyringRT60PerBand[band] < lowReport.eyringRT60PerBand[band])
            #expect(highReport.rayTracedRT60PerBand[band] < lowReport.rayTracedRT60PerBand[band])
        }

        // 3. Verify wait-free RayTracedDRIRConvolverBridge dual-slot crossfaded real-time block processing
        let blockLen = 256
        var excitation = [Float](repeating: 0.0, count: blockLen)
        excitation[0] = 0.9
        excitation[64] = -0.5
        var wetL = [Float](repeating: 0.0, count: blockLen)
        var wetR = [Float](repeating: 0.0, count: blockLen)
        excitation.withUnsafeBufferPointer { inBuf in
            wetL.withUnsafeMutableBufferPointer { lBuf in
                wetR.withUnsafeMutableBufferPointer { rBuf in
                    bridge.processRealtimeBlock(
                        monoInput: inBuf.baseAddress!,
                        wetLeftOutput: lBuf.baseAddress!,
                        wetRightOutput: rBuf.baseAddress!,
                        frameCount: blockLen
                    )
                }
            }
        }
        #expect(wetL.allSatisfy { $0.isFinite })
        #expect(wetR.allSatisfy { $0.isFinite })
        let wetEnergy = wetL.reduce(Float(0)) { $0 + $1 * $1 } + wetR.reduce(Float(0)) { $0 + $1 * $1 }
        #expect(wetEnergy > 1.0e-5)
    }

    // MARK: - 16. Phase 7 Track 25: RVQ Monotonic Error Reduction, Snake Vocoder & Rectified-Flow ODE Invariants

    @Test("Residual Vector Quantizer (RVQ) 4-stage monotonic L2 residual reduction & NeuralAudioTokenPacket round-trip")
    func verifyRVQMonotonicResidualReductionAndTokenSerialization() throws {
        let conditioning = LatentConditioningVector(
            flowTime: 0.5,
            category: .deepWork,
            binauralBeatHz: 14.0,
            rmssdNormalized: 0.62,
            rsaCoherenceScore: 0.84,
            lfHfRatioNormalized: 0.28
        )
        let prior = LatentAudioTensor.sampleGaussianPrior(seed: 0x1234_5678_9ABC_DEF0, temperature: 0.85)
        let sampler = RectifiedFlowLatentSampler()
        let z1 = sampler.sampleLatentHeun(prior: prior, conditioning: conditioning, guidanceScale: 2.2, steps: 4)

        let rvq = ResidualVectorQuantizer()
        let quant = rvq.quantize(
            z1,
            sequenceNumber: 42,
            category: .deepWork,
            binauralBeatHz: 14.0,
            guidanceScale: 2.2
        )

        // 1. Strict inequality ||r_4||_2 < ||r_3||_2 < ||r_2||_2 < ||r_1||_2 < ||z||_2
        #expect(quant.stageResidualNorms.count == 4)
        let r1 = quant.stageResidualNorms[0]
        let r2 = quant.stageResidualNorms[1]
        let r3 = quant.stageResidualNorms[2]
        let r4 = quant.stageResidualNorms[3]
        #expect(r1 < quant.inputNorm)
        #expect(r2 < r1)
        #expect(r3 < r2)
        #expect(r4 < r3)
        #expect(quant.commitmentLoss > 0.0 && quant.commitmentLoss.isFinite)
        #expect(quant.bitrateKbps > 20.0 && quant.bitrateKbps < 60.0)
        #expect(quant.codebookPerplexity > 1.0 && quant.codebookPerplexity <= 64.0)

        // 2. Bit-exact NeuralAudioTokenPacket binary serialization & FNV-1a integrity verification
        let binaryData = quant.packet.serialize()
        #expect(binaryData.count == NeuralAudioTokenPacket.encodedByteSize)
        let decodedPacket = try NeuralAudioTokenPacket.deserialize(binaryData)
        #expect(decodedPacket == quant.packet)
        #expect(decodedPacket.sequenceNumber == 42)
        #expect(decodedPacket.focusCategory == .deepWork)

        let dequantized = rvq.dequantize(packet: decodedPacket)
        #expect(LatentAudioTensor.l2Distance(quant.quantizedLatent, dequantized) < 1.0e-5)

        // Verify tampered byte triggers checksumMismatch error
        var corrupted = binaryData
        corrupted[24] ^= 0x3F
        #expect(throws: NeuralTokenPacketError.self) {
            _ = try NeuralAudioTokenPacket.deserialize(corrupted)
        }
    }

    @Test("Snake activation non-negative derivative monotonicity, 4-step Heun Rectified-Flow ODE & 50% Hann WOLA unity-gain")
    func verifySnakeActivationHeunODESamplerAndHannOverlapAdd() async {
        // 1. Snake_alpha(x) = x + (1/alpha) * sin^2(alpha * x) analytical derivative 1 + sin(2*alpha*x) >= 0
        let alphas: [Float] = [0.65, 1.40, 2.85, 4.20]
        let eps: Float = 1.0e-3
        for alpha in alphas {
            var prevVal = SnakeNeuralVocoder.snake(x: -8.0, alpha: alpha)
            for step in -799...800 {
                let x = Float(step) * 0.01
                let y = SnakeNeuralVocoder.snake(x: x, alpha: alpha)
                #expect(y.isFinite)
                #expect(y + 1.0e-5 >= prevVal) // Monotonically non-decreasing
                prevVal = y

                let analyticDeriv = SnakeNeuralVocoder.snakeDerivative(x: x, alpha: alpha)
                #expect(analyticDeriv >= -1.0e-6 && analyticDeriv <= 2.00001)
                let numericDeriv = (SnakeNeuralVocoder.snake(x: x + eps, alpha: alpha) - SnakeNeuralVocoder.snake(x: x - eps, alpha: alpha)) / (2.0 * eps)
                #expect(abs(analyticDeriv - numericDeriv) < 2.5e-3)
            }
        }

        // 2. 4-step 2nd-Order Heun ODE integration across Classifier-Free Guidance scales w in [1.0, 2.5, 4.0]
        let sampler = RectifiedFlowLatentSampler()
        let prior = LatentAudioTensor.sampleGaussianPrior(seed: 0xCAFE_F00D_8888_1111, temperature: 1.0)
        let cond = LatentConditioningVector(
            flowTime: 0.0,
            category: .creativeFlow,
            binauralBeatHz: 7.5,
            rmssdNormalized: 0.70,
            rsaCoherenceScore: 0.88,
            lfHfRatioNormalized: 0.22
        )
        for cfg in [Float(1.0), Float(2.5), Float(4.0)] {
            let zOut = sampler.sampleLatentHeun(prior: prior, conditioning: cond, guidanceScale: cfg, steps: 4)
            #expect(zOut.data.count == LatentAudioTensor.scalarCount)
            #expect(zOut.isAllFinite)
            #expect(zOut.l2Norm > 0.5 && zOut.l2Norm < 100.0)
        }

        // 3. 50% Complementary Hann Overlap-Add unity-gain & WOLA reconstruction error < 1e-5
        var ola = ComplementaryHannOverlapAdd()
        #expect(ola.maxUnityGainRipple() < 1.0e-5)

        let signalLen = ComplementaryHannOverlapAdd.blockSize * 3
        var testSignal = [Float](repeating: 0.0, count: signalLen)
        for i in 0..<signalLen {
            testSignal[i] = sinf(Float(i) * 0.031) * 0.65 + cosf(Float(i) * 0.007) * 0.25
        }
        let reconstructed = ola.reconstructWOLA(signal: testSignal)
        let hop = ComplementaryHannOverlapAdd.hopSize
        var maxInteriorError: Float = 0.0
        for i in hop..<(signalLen - hop) {
            maxInteriorError = max(maxInteriorError, abs(reconstructed[i] - testSignal[i]))
        }
        #expect(maxInteriorError < 1.0e-5)

        // 4. End-to-end NeuralLatentSoundscapeEngine -> NeuralAudioRingBuffer -> ProceduralSynthKernel real-time render
        let engine = NeuralLatentSoundscapeEngine()
        let ring = NeuralAudioRingBuffer(capacityPowerOfTwo: 16_384)
        let tele1 = await engine.synthesizeAndEnqueueBlock(
            ringBuffer: ring,
            category: .meditation,
            binauralBeatHz: 6.0,
            rmssdNormalized: 0.75,
            rsaCoherenceScore: 0.90,
            lfHfRatioNormalized: 0.18,
            guidanceScale: 2.4,
            temperature: 0.80
        )
        let tele2 = await engine.synthesizeAndEnqueueBlock(
            ringBuffer: ring,
            category: .meditation,
            binauralBeatHz: 6.0,
            rmssdNormalized: 0.75,
            rsaCoherenceScore: 0.90,
            lfHfRatioNormalized: 0.18,
            guidanceScale: 2.4,
            temperature: 0.80
        )
        #expect(tele1.blockSequence == 1)
        #expect(tele2.blockSequence == 2)
        #expect(ring.availableFramesToRead == ComplementaryHannOverlapAdd.hopSize * 2)

        var synthParams = SynthParameters(
            neuralSoundscapeMix: 0.65,
            latentGuidanceScale: 2.4,
            latentTemperature: 0.80,
            rayTracedAcousticsEnabled: true,
            isMuted: false
        )
        synthParams.masterGain = 0.80
        let drirBridge = RayTracedDRIRConvolverBridge()
        var kernel = ProceduralSynthKernel(sampleRate: 48_000.0, snapInitialParameters: synthParams)

        let renderFrames = 1_024
        var outL = [Float](repeating: 0.0, count: renderFrames)
        var outR = [Float](repeating: 0.0, count: renderFrames)
        let renderSnap = outL.withUnsafeMutableBufferPointer { lBuf in
            outR.withUnsafeMutableBufferPointer { rBuf in
                kernel.renderStereoBlock(
                    leftOutput: lBuf.baseAddress!,
                    rightOutput: rBuf.baseAddress!,
                    frameCount: renderFrames,
                    target: synthParams,
                    neuralRingBuffer: ring,
                    drirConvolverBridge: drirBridge
                )
            }
        }
        #expect(outL.allSatisfy { $0.isFinite && abs($0) <= 1.001 })
        #expect(outR.allSatisfy { $0.isFinite && abs($0) <= 1.001 })
        #expect(renderSnap.rmsAmplitude > 0.01)
        #expect(ring.availableFramesToRead == ComplementaryHannOverlapAdd.hopSize * 2 - renderFrames)
    }
}

private final class LockedCommandBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [WatchRemoteCommand] = []

    func append(_ command: WatchRemoteCommand) {
        lock.lock()
        items.append(command)
        lock.unlock()
    }

    func snapshot() -> [WatchRemoteCommand] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}
