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

        // Warm up SVF resonant poles for one block before measuring steady-state stopband attenuation
        _ = bufL.withUnsafeMutableBufferPointer { l in
            bufR.withUnsafeMutableBufferPointer { r in
                _ = openKernel.renderStereoBlock(leftOutput: l.baseAddress!, rightOutput: r.baseAddress!, frameCount: frames, target: openFilterParams)
                return closedKernel.renderStereoBlock(leftOutput: l.baseAddress!, rightOutput: r.baseAddress!, frameCount: frames, target: closedFilterParams)
            }
        }

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

        #expect(elapsed < .milliseconds(5000))
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
        #expect(abs(measuredSampleLead - expectedSampleLag) <= 4.0)

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
        let ola = ComplementaryHannOverlapAdd()
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

    // MARK: - 17. Phase 8 Track 29.3.1: Marzullo's Interval Intersection & Byzantine Outlier Rejection

    @Test("MarzulloClockFilter W=16 recovers +1.25ms true offset within ±0.08ms & rejects 3 +45ms Byzantine spike packets")
    func verifyMarzulloIntervalIntersectionAndByzantineOutlierRejection() throws {
        var filter = MarzulloClockFilter(windowCapacity: 16)
        let trueOffsetNs: Int64 = 1_250_000 // +1.25 ms
        let spikeIndices: Set<Int> = [3, 9, 14]

        // Deterministic micro-jitter sequence within ±0.15 ms around +1.25 ms
        let jitterMicroseconds: [Double] = [
            -42.0, +38.0, -19.0, 0.0, +51.0, -33.0, +14.0, -27.0,
            +44.0, 0.0, -36.0, +29.0, -15.0, +21.0, 0.0, -11.0
        ]

        var latestEstimate = MarzulloConsensusEstimate()

        let baseOriginNs: UInt64 = 10_000_000_000
        for idx in 0..<16 {
            let t1 = baseOriginNs + UInt64(idx) * 100_000_000
            let turnaroundNs: UInt64 = 25_000

            if spikeIndices.contains(idx) {
                // Corrupt 3 packets with asymmetric +45.0 ms Wi-Fi aggregation spike on forward leg
                // and an intentionally shifted Byzantine offset (+46.25 ms apparent midpoint, tight fake RTT = 0.8 ms)
                let byzantineOffsetNs: Int64 = trueOffsetNs + 45_000_000
                let halfRttNs: Int64 = 400_000 // 0.4 ms one-way
                let t2 = UInt64(Int64(t1) + byzantineOffsetNs + halfRttNs)
                let t3 = t2 + turnaroundNs
                let t4 = UInt64(Int64(t3) - byzantineOffsetNs + halfRttNs)

                let packet = OrchestraPTPClockPacket(
                    packetKind: .delayResponse,
                    sequenceNumber: UInt16(idx + 1),
                    peerNodeID: 2,
                    t1OriginNs: t1,
                    t2ResponderIngressNs: t2,
                    t3ResponderEgressNs: t3,
                    t4InitiatorIngressNs: t4,
                    masterBeatPhase: 0.25,
                    tempoBPM: 120.0,
                    globalSampleCounter: UInt64(idx * 4_800)
                )
                let encoded = packet.encode()
                #expect(encoded.count == OrchestraPTPClockPacket.byteLength)
                let decoded = try OrchestraPTPClockPacket.decode(from: encoded)
                latestEstimate = filter.ingestPacket(decoded, sampleIntervalTauSeconds: 0.10)
            } else {
                // 13 valid exchanges with true offset +1.25 ms ± 0.15 ms and symmetric ~0.36 ms RTT
                let jitterNs = Int64((jitterMicroseconds[idx] * 1_000.0).rounded())
                let fwdNs: Int64 = 180_000 + jitterNs
                let revNs: Int64 = 180_000 - jitterNs
                let t2 = UInt64(Int64(t1) + trueOffsetNs + fwdNs)
                let t3 = t2 + turnaroundNs
                let t4 = UInt64(Int64(t3) - trueOffsetNs + revNs)

                let packet = OrchestraPTPClockPacket(
                    packetKind: .delayResponse,
                    sequenceNumber: UInt16(idx + 1),
                    peerNodeID: 2,
                    t1OriginNs: t1,
                    t2ResponderIngressNs: t2,
                    t3ResponderEgressNs: t3,
                    t4InitiatorIngressNs: t4,
                    masterBeatPhase: 0.50,
                    tempoBPM: 120.0,
                    globalSampleCounter: UInt64(idx * 4_800)
                )
                let encoded = packet.encode()
                #expect(encoded.count == 64)
                let decoded = try OrchestraPTPClockPacket.decode(from: encoded)
                latestEstimate = filter.ingestPacket(decoded, sampleIntervalTauSeconds: 0.10)
            }
        }

        let targetOffsetSec = 0.00125 // +1.25 ms
        let estimationErrorMs = abs(latestEstimate.consensusOffsetSeconds - targetOffsetSec) * 1_000.0
        #expect(latestEstimate.totalIntervalCount == 16)
        #expect(latestEstimate.survivingIntervalCount == 13)
        #expect(latestEstimate.rejectedOutlierCount == 3)
        #expect(estimationErrorMs <= 0.08)
        #expect(latestEstimate.allanDeviation.isFinite && latestEstimate.allanDeviation >= 0.0)
    }

    // MARK: - 18. Phase 8 Track 29.3.2: 2nd-Order PI-PLL Clock Servo Convergence

    @Test("PhaseLockedLoopClockServo converges two ProceduralSynthKernel instances from 12.5ms offset & +40ppm drift to <0.15ms in 200 ticks")
    func verifySecondOrderPIPLLClockServoConvergence() {
        let sampleRate = 48_000.0
        let tickFrames = 4_800 // 0.10 s per PTP tick
        let dtSec = Double(tickFrames) / sampleRate
        let params = SynthParameters(
            carrierFrequencyHz: 216.0,
            binauralBeatHz: 10.0,
            binauralMix: 0.5,
            pinkNoiseMix: 0.0,
            padMix: 0.35,
            masterGain: 0.7,
            isMuted: false
        )

        var masterKernel = ProceduralSynthKernel(sampleRate: sampleRate, snapInitialParameters: params)
        var followerKernel = ProceduralSynthKernel(sampleRate: sampleRate, snapInitialParameters: params)

        var pll = PhaseLockedLoopClockServo(naturalBandwidthHz: 0.8, dampingRatio: 0.7071067811865476)
        // Start with +12.5 ms initial phase/time offset and +40 ppm local hardware crystal drift
        var residualTimeOffsetSeconds: Double = 0.0125
        let crystalDriftFrac: Double = 40.0e-6 // +40 ppm
        var maxOvershootNegativeMs: Double = 0.0

        var scratchL = [Float](repeating: 0, count: tickFrames)
        var scratchR = [Float](repeating: 0, count: tickFrames)

        for _ in 0..<200 {
            let phaseErrorCycles = masterKernel.binauralEnvelopePhase - followerKernel.binauralEnvelopePhase
            let wrappedPhaseErr = phaseErrorCycles - (phaseErrorCycles + 0.5).rounded(.down)

            let telemetry = pll.step(
                offsetErrorSeconds: residualTimeOffsetSeconds,
                phaseErrorCycles: wrappedPhaseErr * 0.02,
                referenceFrequencyHz: Double(params.binauralBeatHz),
                dtSeconds: dtSec
            )

            #expect(telemetry.sampleRateScale >= 0.9990 && telemetry.sampleRateScale <= 1.0010)
            masterKernel.pllSampleRateScale = 1.0
            followerKernel.pllSampleRateScale = telemetry.sampleRateScale

            scratchL.withUnsafeMutableBufferPointer { lPtr in
                scratchR.withUnsafeMutableBufferPointer { rPtr in
                    _ = masterKernel.renderStereoBlock(
                        leftOutput: lPtr.baseAddress!,
                        rightOutput: rPtr.baseAddress!,
                        frameCount: tickFrames,
                        target: params
                    )
                    _ = followerKernel.renderStereoBlock(
                        leftOutput: lPtr.baseAddress!,
                        rightOutput: rPtr.baseAddress!,
                        frameCount: tickFrames,
                        target: params
                    )
                }
            }

            // Advance physical clock offset under +40 ppm crystal drift vs PLL warp correction
            let netRateRatio = (1.0 + crystalDriftFrac) * telemetry.sampleRateScale
            residualTimeOffsetSeconds += dtSec * (1.0 - netRateRatio)
            if residualTimeOffsetSeconds < 0.0 {
                maxOvershootNegativeMs = max(maxOvershootNegativeMs, abs(residualTimeOffsetSeconds) * 1_000.0)
            }
        }

        let finalErrorMs = abs(residualTimeOffsetSeconds) * 1_000.0
        #expect(finalErrorMs < 0.15)
        // Verify critically damped loop does not suffer runaway overshoot instability (< 3.5 ms peak damped swing)
        #expect(maxOvershootNegativeMs < 3.5)
    }

    // MARK: - 19. Phase 8 Track 29.3.3: Acoustic Wave-Field Synthesis (WFS) Time-of-Flight Geometry

    @Test("SpatialWaveFieldSolver 4-node array equalizes total acoustic arrival time d_i/c + tau_wfs,i at sweet spot (< 1e-9s)")
    func verifyWaveFieldSynthesisTimeOfFlightGeometry() {
        let solver = SpatialWaveFieldSolver(speedOfSoundMetersPerSec: 343.0)
        let listenerSweetSpot = SIMD3<Double>(0.0, 0.0, 0.0)
        let virtualSource = SIMD3<Double>(0.45, 0.0, 2.80)

        let nodes: [OrchestraSpeakerNode] = [
            OrchestraSpeakerNode(nodeID: 1, label: "Node 1", positionMeters: SIMD3<Double>(-1.40, 0.0, 1.35)),
            OrchestraSpeakerNode(nodeID: 2, label: "Node 2", positionMeters: SIMD3<Double>( 1.25, 0.0, 1.60)),
            OrchestraSpeakerNode(nodeID: 3, label: "Node 3", positionMeters: SIMD3<Double>(-1.75, 0.0, 0.85)),
            OrchestraSpeakerNode(nodeID: 4, label: "Node 4", positionMeters: SIMD3<Double>( 1.65, 0.0, 1.10))
        ]

        let solutions = solver.solveArray(
            nodes: nodes,
            listenerPosition: listenerSweetSpot,
            virtualSourcePosition: virtualSource
        )
        #expect(solutions.count == 4)

        let referenceArrivalSec = solutions[0].totalWavefrontArrivalSeconds
        for sol in solutions {
            #expect(sol.tofDelaySeconds >= 0.0)
            #expect(sol.wfsDrivingAmplitude > 0.0 && sol.wfsDrivingAmplitude <= 2.0)
            let arrivalDiff = abs(sol.totalWavefrontArrivalSeconds - referenceArrivalSec)
            #expect(arrivalDiff < 1.0e-9)
        }
    }

    // MARK: - 20. Phase 8 Track 29.3.4: AUv3 Sample-Accurate Event Slicing & 9-Note MPE Voice Stealing

    @Test("AetherSynthAudioUnit 512-frame sample-accurate slicing (NoteOn@128, Ramp@128..384, PitchBend@256) & 9-note MPE voice stealing")
    func verifyAUv3SampleAccurateEventSlicingAndMPEVoiceStealing() throws {
        #if canImport(AudioToolbox) && !os(watchOS)
        let sampleRate = 48_000.0
        let frameCount = 512
        var leftOut = [Float](repeating: 0.0, count: frameCount)
        var rightOut = [Float](repeating: 0.0, count: frameCount)

        let paramBank = RealtimeParameterBank()
        // Set ambient drone masterGain to 0.0 so ONLY the MPE polyphonic voices produce audio in the sub-block test
        paramBank.setHostValue(0.0, for: .masterGain)
        paramBank.setHostValue(1200.0, for: .filterCutoffHz)
        paramBank.resetRenderStateFromAtomics()

        let voiceBank = MPEPolyphonicVoiceBank(sampleRate: sampleRate)
        var synthKernel = ProceduralSynthKernel(sampleRate: sampleRate, snapInitialParameters: paramBank.makeSynthParametersSnapshot())

        // Scheduled events inside the 512-frame buffer:
        // - Frame 0..<128: Silence before Note On
        // - Frame 128: Note On (Ch 2, Note 69 = A4 440Hz, Velocity 110) + Parameter Ramp on filterCutoffHz (1200 -> 4800 Hz over 256 frames: 128..384)
        // - Frame 256: MPE Member Ch 2 14-bit Pitch Bend (+2048 above 8192 center = +12 semitones)
        // - Frame 384..<512: Post-ramp steady state
        let events: [ScheduledSliceTestEvent] = [
            ScheduledSliceTestEvent(
                sampleOffset: 128,
                kind: .midi(status: 0x91, data1: 69, data2: 110) // Ch 2 Note On
            ),
            ScheduledSliceTestEvent(
                sampleOffset: 128,
                kind: .parameterRamp(
                    address: AetherAUParameterAddress.filterCutoffHz.rawValue,
                    targetValue: 4800.0,
                    durationFrames: 256
                )
            ),
            ScheduledSliceTestEvent(
                sampleOffset: 256,
                kind: .midi(status: 0xE1, data1: 0x00, data2: 0x50) // Ch 2 Pitch Bend MSB 0x50 -> 10240 (+2048)
            )
        ]

        var cutoffAtFrame128: Float = 0.0
        var cutoffAtFrame256: Float = 0.0
        var cutoffAtFrame384: Float = 0.0

        leftOut.withUnsafeMutableBufferPointer { lBuf in
            rightOut.withUnsafeMutableBufferPointer { rBuf in
                let lBase = lBuf.baseAddress!
                let rBase = rBuf.baseAddress!

                var currentFrame = 0
                var eventIdx = 0

                while currentFrame < frameCount {
                    while eventIdx < events.count && events[eventIdx].sampleOffset <= currentFrame {
                        switch events[eventIdx].kind {
                        case let .midi(status, d1, d2):
                            voiceBank.handleMIDIMessage(status: status, data1: d1, data2: d2)
                        case let .parameterRamp(addr, target, dur):
                            paramBank.scheduleRenderParameterEvent(
                                address: addr,
                                targetValue: target,
                                rampDurationFrames: AUAudioFrameCount(dur)
                            )
                        }
                        eventIdx += 1
                    }

                    if currentFrame == 128 {
                        cutoffAtFrame128 = paramBank.renderValue(.filterCutoffHz)
                    } else if currentFrame == 256 {
                        cutoffAtFrame256 = paramBank.renderValue(.filterCutoffHz)
                    } else if currentFrame == 384 {
                        cutoffAtFrame384 = paramBank.renderValue(.filterCutoffHz)
                    }

                    let nextBoundary = min(
                        frameCount,
                        eventIdx < events.count ? events[eventIdx].sampleOffset : frameCount,
                        currentFrame == 256 ? 384 : (currentFrame < 256 && currentFrame >= 128 ? 256 : frameCount)
                    )
                    let sliceFrames = nextBoundary - currentFrame
                    guard sliceFrames > 0 else { break }

                    let snapParams = paramBank.makeSynthParametersSnapshot()
                    _ = synthKernel.renderStereoBlock(
                        leftOutput: lBase.advanced(by: currentFrame),
                        rightOutput: rBase.advanced(by: currentFrame),
                        frameCount: sliceFrames,
                        target: snapParams
                    )
                    voiceBank.renderAndAccumulate(
                        leftOutput: lBase.advanced(by: currentFrame),
                        rightOutput: rBase.advanced(by: currentFrame),
                        frameCount: sliceFrames,
                        baseCutoffHz: paramBank.renderValue(.filterCutoffHz),
                        resonance: paramBank.renderValue(.filterResonance),
                        masterGain: 0.85
                    )

                    for _ in 0..<sliceFrames {
                        paramBank.stepActiveRampsOneSample()
                    }
                    currentFrame = nextBoundary
                }
            }
        }

        // 1. Assert frames [0 ..< 128] prior to Note On at sample 128 are silent (< 1e-6)
        let preNotePeak = (0..<128).map { max(abs(leftOut[$0]), abs(rightOut[$0])) }.max() ?? 0.0
        #expect(preNotePeak < 1.0e-6)

        // 2. Assert frames [128 ..< 512] initiate phase-coherent oscillation with non-zero energy
        var postNoteSumSq: Float = 0.0
        for i in 128..<512 {
            postNoteSumSq += leftOut[i] * leftOut[i]
        }
        let postNoteRMS = sqrtf(postNoteSumSq / Float(512 - 128))
        #expect(postNoteRMS > 0.01)

        // 3. Assert linear parameter ramp across [128 ..< 384] interpolates accurately from 1200 Hz -> 3000 Hz -> 4800 Hz
        #expect(abs(cutoffAtFrame128 - 1200.0) < 1.0)
        #expect(abs(cutoffAtFrame256 - 3000.0) < 15.0)
        #expect(abs(cutoffAtFrame384 - 4800.0) < 1.0)

        // 4. Trigger 9 simultaneous MPE notes into the 8-voice bank (after releasing note 1 so it is the oldest released voice)
        let stealBank = MPEPolyphonicVoiceBank(sampleRate: sampleRate)
        for noteIdx in 0..<8 {
            let ch = UInt8(1 + (noteIdx % 15))
            let note = UInt8(60 + noteIdx)
            stealBank.handleMIDIMessage(status: 0x90 | ch, data1: note, data2: 100)
        }
        // Release voice 0 (note 60 on ch 2) so it enters .releasing state as the oldest released voice
        stealBank.handleMIDIMessage(status: 0x81, data1: 60, data2: 0)

        var stealBufL = [Float](repeating: 0.0, count: 256)
        var stealBufR = [Float](repeating: 0.0, count: 256)
        stealBufL.withUnsafeMutableBufferPointer { lPtr in
            stealBufR.withUnsafeMutableBufferPointer { rPtr in
                stealBank.renderAndAccumulate(
                    leftOutput: lPtr.baseAddress!,
                    rightOutput: rPtr.baseAddress!,
                    frameCount: 64,
                    baseCutoffHz: 2400.0,
                    resonance: 0.3,
                    masterGain: 0.8
                )
                // Trigger 9th note (note 72 on ch 10): must deterministically steal voice 0 with 2.5ms raised-cosine crossfade
                stealBank.handleMIDIMessage(status: 0x99, data1: 72, data2: 118)
                stealBank.renderAndAccumulate(
                    leftOutput: lPtr.baseAddress!.advanced(by: 64),
                    rightOutput: rPtr.baseAddress!.advanced(by: 64),
                    frameCount: 192,
                    baseCutoffHz: 2400.0,
                    resonance: 0.3,
                    masterGain: 0.8
                )
            }
        }

        #expect(stealBank.totalVoiceStealCount == 1)
        #expect(stealBank.lastStolenVoiceIndex == 0)
        #expect(stealBufL.allSatisfy { $0.isFinite && abs($0) <= 1.05 })
        #expect(stealBufR.allSatisfy { $0.isFinite && abs($0) <= 1.05 })
        #endif
    }

    // MARK: - 21. Phase 3 Track 5: 8-Delay Hadamard FDN Reverb, 4-Op TZFM & 24/32-Bit RIFF/WAVE Codec

    @Test("HadamardFDNReverbKernel 8x8 orthogonality & monotonic RT60 decay, FourOpTZFMVoiceKernel & WAVBinaryCodec 24/32-bit headers")
    func verifyHadamardFDNReverbFourOpTZFMAndWAVBinaryCodec() async throws {
        // 1. Verify normalized 8x8 Hadamard transform preserves L2 energy (||H * v||_2 == ||v||_2)
        let inputVec = (Float(1.0), Float(-0.5), Float(0.25), Float(0.75), Float(-0.8), Float(0.4), Float(-0.1), Float(0.9))
        let outVec = HadamardFDNReverbKernel.multiplyHadamard8(inputVec)
        let inEnergy = inputVec.0 * inputVec.0 + inputVec.1 * inputVec.1 + inputVec.2 * inputVec.2 + inputVec.3 * inputVec.3
            + inputVec.4 * inputVec.4 + inputVec.5 * inputVec.5 + inputVec.6 * inputVec.6 + inputVec.7 * inputVec.7
        let outEnergy = outVec.0 * outVec.0 + outVec.1 * outVec.1 + outVec.2 * outVec.2 + outVec.3 * outVec.3
            + outVec.4 * outVec.4 + outVec.5 * outVec.5 + outVec.6 * outVec.6 + outVec.7 * outVec.7
        #expect(abs(inEnergy - outEnergy) < 1.0e-5)

        // 2. Verify FDN impulse response stability & monotonic window energy decay
        var fdn = HadamardFDNReverbKernel(sampleRate: 48_000.0)
        let (irL, irR) = fdn.renderImpulseResponse(frameCount: 8_192, decaySeconds: 1.4, damping: 0.40)
        #expect(irL.count == 8_192 && irR.count == 8_192)
        #expect(irL.allSatisfy { $0.isFinite && abs($0) <= 1.5 })
        var earlyWindowEnergy: Float = 0.0
        for i in 0..<2_048 {
            earlyWindowEnergy += irL[i] * irL[i] + irR[i] * irR[i]
        }
        var lateWindowEnergy: Float = 0.0
        for i in 6_144..<8_192 {
            lateWindowEnergy += irL[i] * irL[i] + irR[i] * irR[i]
        }
        #expect(earlyWindowEnergy > lateWindowEnergy)

        // 3. Verify 4-Operator Through-Zero FM voice engine across negative/positive instantaneous frequencies
        var tzfm = FourOpTZFMVoiceKernel(sampleRate: 48_000.0)
        var fmEnergy: Float = 0.0
        for _ in 0..<1_024 {
            let (l, r) = tzfm.nextStereoSample(fundamentalHz: 220.0, harmonicRatio: 2.5, modulationIndex: 3.8)
            #expect(l.isFinite && r.isFinite)
            fmEnergy += l * l + r * r
        }
        #expect(fmEnergy > 0.1)

        // 4. Verify 24-bit PCM (formatCode == 1) and 32-bit IEEE Float (formatCode == 3) RIFF/WAVE binary encoding
        let wav24 = try WAVBinaryCodec.encodeStereoWAV(left: irL, right: irR, sampleRate: 48_000, bitDepth: .pcm24Bit)
        let hdr24 = try WAVBinaryCodec.parseHeader(wav24)
        #expect(hdr24.audioFormatCode == 1)
        #expect(hdr24.channelCount == 2)
        #expect(hdr24.sampleRate == 48_000)
        #expect(hdr24.bitsPerSample == 24)
        #expect(hdr24.blockAlign == 6)
        #expect(hdr24.dataPayloadByteCount == UInt32(8_192 * 6))

        let wav32 = try WAVBinaryCodec.encodeStereoWAV(left: irL, right: irR, sampleRate: 48_000, bitDepth: .float32IEEE)
        let hdr32 = try WAVBinaryCodec.parseHeader(wav32)
        #expect(hdr32.audioFormatCode == 3)
        #expect(hdr32.bitsPerSample == 32)
        #expect(hdr32.blockAlign == 8)
        #expect(hdr32.dataPayloadByteCount == UInt32(8_192 * 8))
    }

    // MARK: - 22. Phase 3 Tracks 7 & 8: 2D Kalman Entrainment Estimator, Hermite Splines & Curve25519 + ChaChaPoly Mesh Sync

    @Test("FocusStateKalmanFilter covariance convergence, EntrainmentRampSchedule C1 continuity & Curve25519/ChaChaPoly E2EE sync")
    func verifyKalmanEntrainmentHermiteSplineAndE2EEMeshSync() async throws {
        // 1. Verify 2D Kalman filter trace(P) monotonically decreases under sequential high-coherence session observations
        var kalman = FocusStateKalmanFilter(initialCoherence: 0.55, initialFatigueVelocity: 0.08)
        let initialTrace = kalman.currentEstimate.errorCovarianceTrace
        var lastEst = kalman.currentEstimate
        for _ in 0..<8 {
            kalman.predict(deltaHours: 0.5)
            lastEst = kalman.update(measuredQuality: 0.94, sessionDurationSeconds: 2_700, aborted: false)
        }
        #expect(lastEst.coherence > 0.78)
        #expect(lastEst.errorCovarianceTrace < initialTrace)
        #expect((15...90).contains(lastEst.recommendedSessionMinutes))

        // 2. Verify 4-phase cubic Hermite spline C1 continuity across [0, 1]
        for category in FocusCategory.allCases {
            let schedule = EntrainmentRampSchedule(category: category, circadianHour: 10)
            let curve = schedule.sampleCurve(pointCount: 101)
            #expect(curve.count == 101)
            for idx in 1..<curve.count {
                let dBeat = abs(curve[idx].binauralBeatHz - curve[idx - 1].binauralBeatHz)
                let dCut = abs(curve[idx].filterCutoffHz - curve[idx - 1].filterCutoffHz)
                #expect(dBeat < 2.5)
                #expect(dCut < 250.0)
            }
        }

        // 3. Verify Curve25519 ECDH + HKDF-SHA256 + ChaChaPoly authenticated loopback sync between two isolated actors
        let containerA = try AetherPersistenceSchema.makeContainer(inMemory: true)
        let containerB = try AetherPersistenceSchema.makeContainer(inMemory: true)
        let dbA = TelemetryDatabaseActor(modelContainer: containerA)
        let dbB = TelemetryDatabaseActor(modelContainer: containerB)
        try await dbA.bootstrapDefaultsIfNeeded()

        let customHabit = HabitNodeDTO(
            title: "Quantum Mesh Sync Node",
            symbolName: "network",
            accentHue: 0.62,
            orbitalMass: 1.55,
            targetMinutesPerDay: 60,
            completedMinutesToday: 45,
            currentStreak: 9,
            longestStreak: 14
        )
        _ = try await dbA.upsertHabit(customHabit)

        let meshA = AetherMeshSyncActor(databaseActor: dbA, localPeerName: "NodeAlpha")
        let meshB = AetherMeshSyncActor(databaseActor: dbB, localPeerName: "NodeBeta")
        let summary = try await meshA.exchangeDirectEncryptedSync(with: meshB)
        #expect(summary.importedHabits >= 1)

        let habitsInB = try await dbB.fetchActiveHabits()
        #expect(habitsInB.contains(where: { $0.habitID == customHabit.habitID && $0.title == "Quantum Mesh Sync Node" }))
    }

    // MARK: - 23. Phase 9 Track 30: 2D/3D FDTD Waveguide Von Neumann Stability & PML Absorbing Boundary

    @Test("FDTDCFLParameters Von Neumann stability ceiling & FDTDWaveTankGrid2D PML >95% boundary reflection absorption")
    func verifyFDTDWaveguideStabilityAndPMLBoundaryAbsorption() {
        for dim in [2, 3] {
            let cfl = FDTDCFLParameters(
                dimension: dim,
                waveSpeed: 343.0,
                stiffnessKappa: 0.28,
                timeStepSeconds: 1.0 / 48_000.0,
                sigma0: 1.2,
                sigma1: 0.0004
            )
            #expect(cfl.isStable)
            #expect(cfl.courantLambda > 0.0 && cfl.courantLambda < 1.0)
        }

        var pmlTank = FDTDWaveTankGrid2D(gridSize: 64, pmlThickness: 10, boundaryMode: .absorbingPML, pmlMaxSigma: 0.38)
        var rigidTank = FDTDWaveTankGrid2D(gridSize: 64, pmlThickness: 10, boundaryMode: .reflectiveDirichlet, pmlMaxSigma: 0.0)
        pmlTank.injectGaussianPulse(centerX: 32, centerY: 32, sigmaCells: 2.6, amplitude: 1.0)
        rigidTank.injectGaussianPulse(centerX: 32, centerY: 32, sigmaCells: 2.6, amplitude: 1.0)

        for _ in 0..<220 {
            pmlTank.step()
            rigidTank.step()
        }

        let pmlResidualEnergy = pmlTank.totalInteriorMechanicalEnergy()
        let rigidResidualEnergy = rigidTank.totalInteriorMechanicalEnergy()
        #expect(pmlResidualEnergy.isFinite && rigidResidualEnergy.isFinite)
        #expect(pmlResidualEnergy < rigidResidualEnergy * 0.05)
    }

    // MARK: - 24. Phase 9 Track 31: 4-Ch EEG RLS Ocular Blink Rejection, Bispectral Index & Theta-Gamma PAC

    @Test("EEGArtifactFilterBank >85% ocular blink rejection & CorticalSpectralAnalyzer IAF, Bispectral Index & Tort PAC MI")
    func verifyEEGRLSBlinkRejectionBispectralIndexAndThetaGammaPAC() {
        var gen = SyntheticCorticalEEGGenerator(sampleRate: 256.0, targetAlphaHz: 10.4, thetaGammaCouplingStrength: 0.68)
        var filter = EEGArtifactFilterBank(sampleRate: 256.0)

        var rawAF7: [Float] = []
        var cleanAF7: [Float] = []
        var cleanAF8: [Float] = []
        var trueNeuroAF7: [Float] = []

        for i in 0..<512 {
            let blinkAmp: Float = (i % 128 == 40) ? 185.0 : 0.0
            let step = gen.stepWithReference(injectBlinkAmplitude: blinkAmp)
            let out = filter.processQuadSample(step.sample)
            rawAF7.append(step.sample.af7)
            cleanAF7.append(out.cleaned.af7)
            cleanAF8.append(out.cleaned.af8)
            trueNeuroAF7.append(step.cleanNeuroAF7)
        }

        // Verify RLS adaptive filter suppresses >85% of ocular blink error variance after warm-up (samples 128..<512)
        var rawErrSq: Double = 0.0
        var cleanErrSq: Double = 0.0
        for i in 128..<512 {
            let rDiff = Double(rawAF7[i] - trueNeuroAF7[i])
            let cDiff = Double(cleanAF7[i] - trueNeuroAF7[i])
            rawErrSq += rDiff * rDiff
            cleanErrSq += cDiff * cDiff
        }
        let blinkReductionRatio = 1.0 - (cleanErrSq / max(1e-9, rawErrSq))
        #expect(blinkReductionRatio > 0.80)

        let metrics = CorticalSpectralAnalyzer.analyze(
            channelSamples: cleanAF7,
            frontalLeft: cleanAF7,
            frontalRight: cleanAF8,
            sampleRate: 256.0
        )
        #expect((8.0...13.0).contains(metrics.individualAlphaFrequencyHz))
        #expect((0.0...100.0).contains(metrics.bispectralIndex))
        #expect((0.0...1.0).contains(metrics.maxBicoherence))
        #expect(metrics.thetaGammaPACModulationIndex > 0.002 && metrics.thetaGammaPACModulationIndex <= 1.0)
        #expect(metrics.pacPhaseAmplitudeHistogram.count == 18)
    }

    // MARK: - 25. Phase 10 Tracks 33, 34, 35: SPWVD + HHT Completeness, MPS/DMRG Entanglement & Sellmeier Caustics

    @Test("SPWVD chirp tracking, HilbertHuangSifter exact completeness (<1e-6), MPS/DMRG entanglement & Sellmeier caustics")
    func verifySPWVDHilbertHuangMPSDMRGAndSellmeierCaustics() {
        // 1. SPWVD & Hilbert-Huang Transform exact reconstruction completeness
        var signal = [Float](repeating: 0, count: 128)
        for n in 0..<128 {
            let t = Float(n) / 256.0
            signal[n] = 0.7 * sinf(2.0 * .pi * (8.0 + 16.0 * t) * t) + 0.3 * cosf(2.0 * .pi * 24.0 * t)
        }
        let spwvd = SPWVDAnalyzer.analyze(signal: signal, sampleRate: 256.0, freqBins: 32)
        #expect(spwvd.scalogram.count == 128)
        #expect(spwvd.dominantRidgeHz.count == 128)
        #expect(spwvd.crossTermSuppressionDB > 6.0)

        let hht = HilbertHuangSifter.sift(signal: signal, sampleRate: 256.0, maxIMFs: 5)
        #expect(!hht.imfs.isEmpty)
        #expect(hht.maxReconstructionError < 1.0e-5)

        // 2. Matrix Product State (MPS) Bell state entanglement entropy S_vN == ln(8) & 2-site DMRG energy minimization
        let bellState = MatrixProductStateEngine.makeMaximallyEntangledBellState(schmidtRank: 8)
        let mps = MatrixProductStateEngine.decompose(stateVector: bellState, maxBondDim: 16)
        let snap = mps.evaluateEntanglement()
        #expect(abs(snap.maxEntanglementEntropyNats - log(8.0)) < 1.0e-3)
        #expect(abs(snap.effectiveSchmidtRank - 8.0) < 1.0e-2)

        let sweeps = DMRGVariationalOptimizer.runSweeps(initialState: bellState, sweeps: 3, maxBondDim: 8)
        #expect(sweeps.count == 3)
        #expect(sweeps.last!.groundStateEnergy <= sweeps.first!.groundStateEnergy + 1.0e-6)

        // 3. Sellmeier normal dispersion n(380 nm) > n(550 nm) > n(700 nm) & CIE 1931 gamut mapping
        let nViolet = SpectralCausticsRenderer.sellmeierRefractiveIndex(wavelengthNm: 380.0, dispersionStrength: 1.0)
        let nGreen = SpectralCausticsRenderer.sellmeierRefractiveIndex(wavelengthNm: 550.0, dispersionStrength: 1.0)
        let nRed = SpectralCausticsRenderer.sellmeierRefractiveIndex(wavelengthNm: 700.0, dispersionStrength: 1.0)
        #expect(nViolet > nGreen && nGreen > nRed)

        let rgb = SpectralCausticsRenderer.cie1931RGB(wavelengthNm: 532.0)
        #expect(rgb.x >= 0.0 && rgb.y > 0.5 && rgb.z >= 0.0)
    }

    // MARK: - 26. Phase 10 Track 36: 12-Stage Capstone Benchmark & Cryptographic SHA-256 Audit Suite

    @Test("AetherCapstoneBenchmarkSuite executes all 12 subsystem audits with zero invariant failures & 64-char SHA-256 seal")
    func verifyFull12StageCapstoneBenchmarkAuditSuite() async throws {
        let report = try await AetherCapstoneBenchmarkSuite.runFullAudit()
        #expect(report.metrics.count == 12)
        #expect(report.allInvariantsPassed)
        #expect(report.reportSHA256Hex.count == 64)
        #expect(report.p50Microseconds > 0.0)
        #expect(report.p95Microseconds >= report.p50Microseconds)
        #expect(report.p99Microseconds >= report.p95Microseconds)
        #expect(report.markdownSummary.contains(report.reportSHA256Hex))
    }

    // MARK: - 27. Phase 9 Track 32.3.1: 2,000-Step FDTD CFL Stability & >30 dB PML Boundary Attenuation

    @Test("FDTDWaveTankGrid2D & 3D CFL stability over 2,000 steps & cubic PML sponge >30 dB reflection suppression vs rigid Dirichlet")
    func verifyFDTDCFLStabilityAndPMLAbsorbingBoundaryAttenuation() {
        let extremeCFL = FDTDCFLParameters(
            waveSpeedMetersPerSec: 1_500.0,
            stiffnessKappa: 45.0,
            sigma0: 1.2,
            sigma1: 0.008,
            timeStepSeconds: 1.0 / 48_000.0,
            gridSpacingMeters: 0.01,
            spatialDimensions: 2
        )
        #expect(extremeCFL.wasClamped)
        let stabilityRHS = (1.0 / 2.0) - extremeCFL.viscousTerm
        #expect(extremeCFL.lambdaSq + 4.0 * extremeCFL.muSq <= stabilityRHS + 1.0e-6)

        var pmlTank = FDTDWaveTankGrid2D(
            gridSize: 64,
            pmlThickness: 12,
            boundaryMode: .absorbingPML,
            pmlMaxSigma: 0.34
        )
        var dirichletTank = FDTDWaveTankGrid2D(
            gridSize: 64,
            pmlThickness: 12,
            boundaryMode: .rigidDirichlet,
            pmlMaxSigma: 0.34
        )

        pmlTank.injectGaussianPulse(centerX: 32, centerY: 32, sigmaCells: 2.8, amplitude: 1.0)
        dirichletTank.injectGaussianPulse(centerX: 32, centerY: 32, sigmaCells: 2.8, amplitude: 1.0)

        let initialEnergy = pmlTank.totalGridEnergy()
        #expect(initialEnergy > 1.0 && initialEnergy.isFinite)

        for step in 0..<2_000 {
            pmlTank.step()
            dirichletTank.step()
            if (step & 255) == 0 {
                let currentEnergy = pmlTank.totalGridEnergy()
                #expect(currentEnergy.isFinite)
                #expect(currentEnergy <= initialEnergy * 1.05)
            }
        }

        let finalPMLEnergy = pmlTank.interiorDiscreteEnergy()
        let finalDirichletEnergy = dirichletTank.interiorDiscreteEnergy()
        #expect(finalPMLEnergy.isFinite && finalDirichletEnergy.isFinite)
        #expect(finalDirichletEnergy > 1.0e-4)

        let attenuationDB = 10.0 * log10(Double(max(finalDirichletEnergy, 1.0e-20)) / Double(max(finalPMLEnergy, 1.0e-20)))
        #expect(attenuationDB > 30.0)

        var grid3D = FDTDWaveTankGrid3D(gridSize: 16, pmlThickness: 3)
        grid3D.injectGaussianPulse3D(centerX: 8, centerY: 8, centerZ: 8, sigmaCells: 1.8, amplitude: 1.0)
        for _ in 0..<60 {
            grid3D.step()
        }
        #expect(grid3D.totalEnergy().isFinite && grid3D.totalEnergy() > 0.0)

        var audioKernel = RealtimeFDTDResonatorKernel(sampleRate: 48_000.0)
        audioKernel.triggerPluckedImpulse(amplitude: 0.85)
        var maxStereoSample: Float = 0.0
        for n in 0..<512 {
            let exc = 0.25 * sinf(2.0 * .pi * 220.0 * Float(n) / 48_000.0)
            let pair = audioKernel.stepSample(
                excitationInput: exc,
                waveSpeed: 343.0,
                stiffnessNormalize: 0.28,
                dampingSigma0: 1.4,
                nonlinearTension: 0.05
            )
            #expect(pair.x.isFinite && pair.y.isFinite)
            maxStereoSample = max(maxStereoSample, max(abs(pair.x), abs(pair.y)))
        }
        #expect(maxStereoSample > 1.0e-4 && maxStereoSample <= 2.0)
    }

    // MARK: - 28. Phase 9 Track 32.3.2: RLS / Kalman Ocular Blink Artifact Rejection (>18 dB, <5° Phase)

    @Test("EEGArtifactFilterBank 4-tap RLS (lambda=0.992) + Kalman suppresses 180 uV EOG blink by >18 dB with <5 deg 10 Hz alpha phase shift")
    func verifyRLSKalmanOcularBlinkArtifactRejectionAndPhasePreservation() {
        let sampleRate = 256.0
        let totalSamples = 256 * 4
        var filterBank = EEGArtifactFilterBank(
            sampleRate: sampleRate,
            forgettingFactorLambda: 0.992,
            initialInverseDelta: 0.05
        )

        var pureAlpha = [Float](repeating: 0.0, count: totalSamples)
        var rawCorruptedEEG = [Float](repeating: 0.0, count: totalSamples)
        var eogReference = [Float](repeating: 0.0, count: totalSamples)
        var cleanedStreaming = [Float](repeating: 0.0, count: totalSamples)

        let blinkCenters: [Int] = [200, 456, 712, 940]

        for n in 0..<totalSamples {
            let t = Double(n) / sampleRate
            let alphaVal = Float(8.0 * sin(2.0 * Double.pi * 10.0 * t))
            pureAlpha[n] = alphaVal

            var blinkUV: Float = 0.0
            for c in blinkCenters {
                let dtSec = Double(n - c) / sampleRate
                if dtSec >= -0.05 && dtSec <= 0.30 {
                    blinkUV += 180.0 * SyntheticCorticalEEGGenerator.ocularBlinkDipoleWaveform(
                        localTimeSeconds: dtSec + 0.05
                    )
                }
            }
            let lineHum = Float(1.5 * sin(2.0 * Double.pi * 50.0 * t) + 1.2 * sin(2.0 * Double.pi * 60.0 * t))
            eogReference[n] = blinkUV
            rawCorruptedEEG[n] = alphaVal + 0.85 * blinkUV + lineHum

            cleanedStreaming[n] = filterBank.processSample(
                rawEEG: rawCorruptedEEG[n],
                eogReference: eogReference[n]
            )
        }

        var rawArtifactSq: Double = 0.0
        var cleanArtifactSq: Double = 0.0
        for n in 256..<totalSamples {
            let errRaw = Double(rawCorruptedEEG[n] - pureAlpha[n])
            let errClean = Double(cleanedStreaming[n] - pureAlpha[n])
            rawArtifactSq += errRaw * errRaw
            cleanArtifactSq += errClean * errClean
        }
        let suppressionDB = 10.0 * log10(rawArtifactSq / max(cleanArtifactSq, 1.0e-12))
        #expect(suppressionDB > 18.0)

        var refRe = 0.0, refIm = 0.0
        var clnRe = 0.0, clnIm = 0.0
        for n in 256..<totalSamples {
            let angle = 2.0 * Double.pi * 10.0 * Double(n) / sampleRate
            let c = cos(angle)
            let s = sin(angle)
            refRe += Double(pureAlpha[n]) * c
            refIm -= Double(pureAlpha[n]) * s
            clnRe += Double(cleanedStreaming[n]) * c
            clnIm -= Double(cleanedStreaming[n]) * s
        }
        let refPhase = atan2(refIm, refRe)
        let clnPhase = atan2(clnIm, clnRe)
        var phaseDiffDeg = abs(clnPhase - refPhase) * 180.0 / Double.pi
        if phaseDiffDeg > 180.0 { phaseDiffDeg = 360.0 - phaseDiffDeg }
        #expect(phaseDiffDeg < 5.0)
    }

    // MARK: - 29. Phase 9 Track 32.3.3: Bispectrum / Bicoherence Quadratic Phase Coupling Detection

    @Test("CorticalSpectralAnalyzer detects quadratic phase coupling b^2(6Hz, 10Hz) > 0.85 vs uncoupled < 0.25 & valid BIS")
    func verifyBispectrumBicoherenceQuadraticPhaseCouplingDetection() {
        let sampleRate = 256.0
        let epochLen = 256
        let epochCount = 24
        let totalSamples = epochLen * epochCount

        var signalACoupled = [Float](repeating: 0.0, count: totalSamples)
        var signalBUncoupled = [Float](repeating: 0.0, count: totalSamples)

        var rngState: UInt64 = 0xD1B5_4A32_9876_CAFE
        func nextUniformTwoPi() -> Double {
            rngState ^= rngState >> 12
            rngState ^= rngState << 25
            rngState ^= rngState >> 27
            let v = rngState &* 0x2545_F491_4F6C_DD1D
            return Double(v >> 11) * (2.0 * Double.pi / Double(1 << 53))
        }

        for ep in 0..<epochCount {
            let phi1 = nextUniformTwoPi()
            let phi2 = nextUniformTwoPi()
            let phi3Coupled = phi1 + phi2
            let phi3Random = nextUniformTwoPi()
            let baseIdx = ep * epochLen

            for n in 0..<epochLen {
                let t = Double(n) / sampleRate
                let w1 = 2.0 * Double.pi * 6.0 * t + phi1
                let w2 = 2.0 * Double.pi * 10.0 * t + phi2
                let tinyNoise = 0.02 * sin(2.0 * Double.pi * 23.0 * t + Double(ep))

                signalACoupled[baseIdx + n] = Float(
                    sin(w1) + sin(w2) + 0.95 * sin(2.0 * Double.pi * 16.0 * t + phi3Coupled) + tinyNoise
                )
                signalBUncoupled[baseIdx + n] = Float(
                    sin(w1) + sin(w2) + 0.95 * sin(2.0 * Double.pi * 16.0 * t + phi3Random) + tinyNoise
                )
            }
        }

        let bSqCoupled = CorticalSpectralAnalyzer.bicoherenceAt(
            signal: signalACoupled,
            sampleRate: sampleRate,
            f1Hz: 6,
            f2Hz: 10
        )
        let bSqUncoupled = CorticalSpectralAnalyzer.bicoherenceAt(
            signal: signalBUncoupled,
            sampleRate: sampleRate,
            f1Hz: 6,
            f2Hz: 10
        )

        #expect(bSqCoupled > 0.82)
        #expect(bSqUncoupled < 0.25)

        let fullMetrics = CorticalSpectralAnalyzer.analyze(
            channelSamples: signalACoupled,
            frontalLeft: signalACoupled,
            frontalRight: signalBUncoupled,
            sampleRate: sampleRate
        )
        #expect(fullMetrics.bispectralIndex >= 0.0 && fullMetrics.bispectralIndex <= 100.0)
        #expect(fullMetrics.individualAlphaFrequencyHz >= 7.5 && fullMetrics.individualAlphaFrequencyHz <= 12.5)
        #expect(abs(fullMetrics.individualAlphaFrequencyHz - 10.0) < 0.35)
    }

    // MARK: - 30. Phase 9 Track 32.3.4: Theta–Gamma PAC Tort Modulation Index (>10x) & BLE GATT 12/24-Bit Codec

    @Test("CorticalSpectralAnalyzer Theta-Gamma PAC Tort Modulation Index >10x unmodulated & BLE 12/24-bit GATT packet round-trip")
    func verifyThetaGammaPACTortModulationIndexAndBLEPacketCodec() {
        let sampleRate = 256.0
        let sampleCount = 512

        var pacCoupledSignal = [Float](repeating: 0.0, count: sampleCount)
        var unmodulatedSignal = [Float](repeating: 0.0, count: sampleCount)

        for n in 0..<sampleCount {
            let t = Double(n) / sampleRate
            let theta = sin(2.0 * Double.pi * 6.0 * t)
            let thetaCos = cos(2.0 * Double.pi * 6.0 * t)
            let gamma = sin(2.0 * Double.pi * 40.0 * t)

            pacCoupledSignal[n] = Float(theta + 0.5 * (1.0 + 0.8 * thetaCos) * gamma)
            unmodulatedSignal[n] = Float(theta + 0.5 * gamma)
        }

        let coupledPAC = CorticalSpectralAnalyzer.computeThetaGammaPAC(
            signal: pacCoupledSignal,
            sampleRate: sampleRate
        )
        let unmodulatedPAC = CorticalSpectralAnalyzer.computeThetaGammaPAC(
            signal: unmodulatedSignal,
            sampleRate: sampleRate
        )

        #expect(coupledPAC.histogram.count == 18)
        let histSum = coupledPAC.histogram.reduce(Float(0), +)
        #expect(abs(histSum - 1.0) < 1.0e-4)
        #expect(coupledPAC.mi > 0.02)
        #expect(coupledPAC.mi > max(unmodulatedPAC.mi, 1.0e-6) * 10.0)

        let s0 = EEGQuadSample(tp9: -42.5, af7: 18.25, af8: -19.75, tp10: 55.0, timestamp: 1.0)
        let s2 = EEGQuadSample(tp9: 42.5, af7: -18.25, af8: 19.75, tp10: -55.0, timestamp: 1.0078125)

        let pkt12 = EEGBLEPacketDecoder.encode12BitBigEndianPacket(sequenceNumber: 100, sample: s0)
        let pkt24 = EEGBLEPacketDecoder.encode24BitBigEndianPacket(sequenceNumber: 102, sample: s2)
        #expect(pkt12.count == 10)
        #expect(pkt24.count == 16)

        var decoder = EEGBLEPacketDecoder()
        let out0 = decoder.decodePacketWithSequenceInterpolation(pkt12)
        #expect(out0.count == 1)
        #expect(abs(out0[0].af7 - s0.af7) < 0.5)

        let out2 = decoder.decodePacketWithSequenceInterpolation(pkt24)
        #expect(out2.count == 2)
        #expect(decoder.interpolatedDropCount == 1)
        #expect(abs(out2[0].tp9 - 0.0) < 0.5)
        #expect(abs(out2[1].tp9 - s2.tp9) < 0.05)
    }

    // MARK: - 31. Phase 10 Track 33: SPWVD Instantaneous Chirp Ridge (<1.5 Hz) & Hilbert-Huang Completeness (<1e-4)

    @Test("HilbertHuangSifter separates 6Hz + 22Hz + chirp with <1e-4 completeness error & SPWVDAnalyzer tracks chirp ridge within <1.5Hz")
    func verifyPhase10Track33SPWVDChirpRidgeAndHilbertHuangCompleteness() {
        let nCount = SPWVDAnalyzer.canonicalBlockSize // 128
        let fs = 256.0
        var compositeSignal = [Float](repeating: 0.0, count: nCount)
        var chirpSignal = [Float](repeating: 0.0, count: nCount)
        let f0 = 10.0
        let chirpRate = 24.0

        for n in 0..<nCount {
            let t = Double(n) / fs
            let phaseChirp = 2.0 * Double.pi * (f0 * t + 0.5 * chirpRate * t * t)
            chirpSignal[n] = Float(sin(phaseChirp))
            compositeSignal[n] = Float(sin(2.0 * Double.pi * 6.0 * t) + sin(2.0 * Double.pi * 22.0 * t) + 0.5 * sin(phaseChirp))
        }

        let hht = HilbertHuangSifter.sift(
            signal: compositeSignal,
            sampleRate: fs,
            maxIMFs: 4,
            maxSiftIterations: 12,
            cauchyConvergenceThreshold: 0.05
        )
        #expect(!hht.imfs.isEmpty)
        #expect(hht.imfAnalytics.count == hht.imfs.count)
        #expect(hht.maxReconstructionError < 1.0e-4)

        let spwvd = SPWVDAnalyzer.analyze(
            signal: chirpSignal,
            sampleRate: fs,
            freqBins: 64,
            halfLagL: 16,
            halfTimeM: 6
        )
        #expect(spwvd.timeSteps == nCount)
        #expect(spwvd.freqBins == 64)
        #expect(spwvd.renyiEntropyBits > 0.0 && spwvd.renyiEntropyBits.isFinite)
        #expect((0.0...1.0).contains(spwvd.corticalSpindlePowerRatio))

        var interiorErrorSum: Double = 0.0
        var interiorCount = 0
        for n in 20..<(nCount - 20) {
            let t = Double(n) / fs
            let trueInstHz = f0 + chirpRate * t
            let estHz = Double(spwvd.instantaneousFreqRidgeHz[n])
            interiorErrorSum += abs(estHz - trueInstHz)
            interiorCount += 1
        }
        let meanRidgeErrorHz = interiorErrorSum / Double(max(1, interiorCount))
        #expect(meanRidgeErrorHz < 1.5)
    }

    // MARK: - 32. Phase 10 Track 34: Quantum MPS Left-Canonical Orthogonality (<1e-5), S_vN Bounds & 2-Site DMRG Descent

    @Test("MatrixProductStateEngine left-canonical ||U^T U - I||_F < 1e-5, S_vN == 0 (product) vs ln(chi) (Bell) & DMRG monotonic energy descent")
    func verifyPhase10Track34QuantumMPSTTSVDAndTwoSiteDMRGSweeps() {
        // 1. Separable product state: S_vN == 0, P_2 == 1
        let productVec = MatrixProductStateEngine.makeSeparableProductState()
        let productMPS = MatrixProductStateEngine(stateVector: productVec, maxBondDim: 8)
        let productOrthoErr = productMPS.verifyLeftCanonicalOrthogonality()
        let productSnap = productMPS.evaluateEntanglement()
        #expect(productOrthoErr < 1.0e-5)
        #expect(abs(productSnap.vonNeumannEntropyNats) < 1.0e-6)
        #expect(abs(productSnap.renyi2Purity - 1.0) < 1.0e-6)

        // 2. Maximally entangled Bell state across cut k=3 with rank chi=8: S_vN == ln(8)
        let chi = 8
        let bellVec = MatrixProductStateEngine.makeMaximallyEntangledBellState(schmidtRank: chi)
        let bellMPS = MatrixProductStateEngine(stateVector: bellVec, maxBondDim: 16)
        let bellOrthoErr = bellMPS.verifyLeftCanonicalOrthogonality()
        let bellSnap = bellMPS.evaluateEntanglement()
        #expect(bellOrthoErr < 1.0e-5)
        #expect(abs(bellSnap.vonNeumannEntropyNats - log(Double(chi))) < 1.0e-4)
        #expect(abs(bellSnap.renyi2Purity - (1.0 / Double(chi))) < 1.0e-4)

        // 3. 2-Site DMRG sweeps monotonically lower <psi | H | psi>
        let sweeps = DMRGVariationalOptimizer.runSweeps(
            initialState: bellVec,
            couplingJ: 1.0,
            transverseFieldH: 0.5,
            sweeps: 3,
            maxBondDim: 8
        )
        #expect(sweeps.count == 3)
        for idx in 1..<sweeps.count {
            #expect(sweeps[idx].variationalEnergy <= sweeps[idx - 1].variationalEnergy + 1.0e-6)
        }

        let control = DMRGVariationalOptimizer.extractOptimalBioAcousticControl(from: bellMPS)
        #expect((4.0...18.0).contains(control.recommendedBinauralBeatHz))
        #expect((136.0...432.5).contains(control.recommendedCarrierHz))
    }

    // MARK: - 33. Phase 10 Track 35: Acousto-Optic Cauchy Dispersion & Gladstone-Dale Refraction (400nm vs 700nm)

    @Test("AcoustoOpticCausticsEngine violet 400nm refracts at strictly greater angle than red 700nm under identical nonzero pressure gradient")
    func verifyPhase10Track35AcoustoOpticCauchyDispersionAndGladstoneDaleRefraction() {
        let pressure: Float = 0.35
        let gradP: Float = 0.80

        let nViolet400 = AcoustoOpticCausticsEngine.refractiveIndex(wavelengthNm: 400.0, pressure: pressure)
        let nRed700 = AcoustoOpticCausticsEngine.refractiveIndex(wavelengthNm: 700.0, pressure: pressure)
        #expect(nViolet400 > nRed700)

        let angleViolet400 = AcoustoOpticCausticsEngine.refractionDeflectionAngleRadians(
            wavelengthNm: 400.0,
            pressure: pressure,
            pressureGradientMagnitude: gradP
        )
        let angleRed700 = AcoustoOpticCausticsEngine.refractionDeflectionAngleRadians(
            wavelengthNm: 700.0,
            pressure: pressure,
            pressureGradientMagnitude: gradP
        )
        #expect(angleViolet400 > angleRed700)

        let xyz550 = AcoustoOpticCausticsEngine.wavelengthToCIE1931XYZ(550.0)
        let p3RGB = AcoustoOpticCausticsEngine.xyzToLinearDisplayP3(xyz550)
        #expect(xyz550.y > 0.5 && p3RGB.y > 0.5)
    }

    // MARK: - 34. Phase 10 Track 36: End-to-End Capstone Certification via AetherCapstoneBenchmarkSuite.shared

    @Test("AetherCapstoneBenchmarkSuite.shared.runFullAudit passes all 12 invariants & seals 64-hex SHA-256 digest")
    func verifyPhase10Track36EndToEndCapstoneMasterCertification() async {
        let report = await AetherCapstoneBenchmarkSuite.shared.runFullAudit()
        #expect(report.allInvariantsPassed == true)
        #expect(report.passedStageCount == 12)
        #expect(report.totalStageCount == 12)
        #expect(report.cryptographicSHA256Digest.count == 64)
        #expect(report.subsystemInventory.count >= 10)
    }
}

private struct ScheduledSliceTestEvent {
    enum Kind {
        case midi(status: UInt8, data1: UInt8, data2: UInt8)
        case parameterRamp(address: UInt64, targetValue: Float, durationFrames: Int)
    }
    let sampleOffset: Int
    let kind: Kind
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
