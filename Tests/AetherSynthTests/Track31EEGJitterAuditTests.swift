// MARK: - FILE: Track31EEGJitterAuditTests.swift
// Phase 9 Track 31/32 Audit: 15% BLE Packet Drop, Burst Loss, Extreme Arrival Jitter,
// UInt16 Sequence Rollover, Lockstep 4-Ch Ring Buffer & Synthetic-Gated RLS/Kalman Verification.

import Testing
import Foundation

@Suite("Track 31 BLE EEG 15% Packet Drop, Extreme Jitter, UInt16 Wrap & Artifact Filter Audit")
struct Track31EEGJitterAuditTests {

    private struct SplitMix64PRNG: Sendable {
        var state: UInt64

        init(seed: UInt64) {
            self.state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
        }

        mutating func nextUInt64() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        mutating func nextUniform() -> Double {
            Double(nextUInt64() >> 11) * (1.0 / 9_007_199_254_740_992.0)
        }

        mutating func nextSymmetric() -> Double {
            nextUniform() * 2.0 - 1.0
        }
    }

    @Test("Modular UInt16 rollover, duplicate/late packet rejection, XOR checksum guard & monotone Hermite bounds")
    func verifyBLESequenceRolloverDuplicateAndChecksumRejection() {
        #expect(EEGBLEPacketDecoder.signedSequenceDelta(0, 65535) == 1)
        #expect(EEGBLEPacketDecoder.signedSequenceDelta(2, 65534) == 4)
        #expect(EEGBLEPacketDecoder.signedSequenceDelta(65534, 2) == -4)
        #expect(EEGBLEPacketDecoder.signedSequenceDelta(500, 500) == 0)

        var decoder = EEGBLEPacketDecoder(sampleRate: 256.0)
        let s0 = EEGQuadSample(tp9: -30.0, af7: 20.0, af8: -15.0, tp10: 40.0, timestamp: 0.0)
        let s1 = EEGQuadSample(tp9: -10.0, af7: 10.0, af8: -5.0, tp10: 20.0, timestamp: 0.00390625)
        let s4 = EEGQuadSample(tp9: 50.0, af7: -20.0, af8: 25.0, tp10: -40.0, timestamp: 0.015625)

        // 1. Valid packet at sequence 65534
        let pkt65534 = EEGBLEPacketDecoder.encode12BitBigEndianPacket(sequenceNumber: 65534, sample: s0)
        let out0 = decoder.decodePacketWithSequenceInterpolation(pkt65534)
        #expect(out0.count == 1)

        // 2. Duplicate packet at sequence 65534 must be rejected
        let dupOut = decoder.decodePacketWithSequenceInterpolation(pkt65534)
        #expect(dupOut.isEmpty)
        #expect(decoder.duplicateOrStaleDropCount == 1)

        // 3. Valid packet at sequence 65535
        let pkt65535 = EEGBLEPacketDecoder.encode12BitBigEndianPacket(sequenceNumber: 65535, sample: s1)
        let out1 = decoder.decodePacketWithSequenceInterpolation(pkt65535)
        #expect(out1.count == 1)

        // 4. Stale out-of-order packet (65534 arriving after 65535) must be rejected
        let staleOut = decoder.decodePacketWithSequenceInterpolation(pkt65534)
        #expect(staleOut.isEmpty)
        #expect(decoder.duplicateOrStaleDropCount == 2)

        // 5. Rollover gap: sequence 2 arriving after 65535 (missing 0 and 1 -> 2 interpolated + 1 measured = 3 samples)
        let pkt2 = EEGBLEPacketDecoder.encode24BitBigEndianPacket(sequenceNumber: 2, sample: s4)
        let outRollover = decoder.decodePacketWithSequenceInterpolation(pkt2)
        #expect(outRollover.count == 3)
        #expect(decoder.interpolatedDropCount == 2)

        // Verify monotone Hermite interpolation stays strictly within endpoint bounds [min, max]
        for k in 0..<2 {
            let interp = outRollover[k]
            #expect(interp.tp9 >= min(s1.tp9, s4.tp9) - 0.5 && interp.tp9 <= max(s1.tp9, s4.tp9) + 0.5)
            #expect(interp.af7 >= min(s1.af7, s4.af7) - 0.5 && interp.af7 <= max(s1.af7, s4.af7) + 0.5)
            #expect(interp.af8 >= min(s1.af8, s4.af8) - 0.5 && interp.af8 <= max(s1.af8, s4.af8) + 0.5)
            #expect(interp.tp10 >= min(s1.tp10, s4.tp10) - 0.5 && interp.tp10 <= max(s1.tp10, s4.tp10) + 0.5)
        }

        // 6. Corrupted XOR checksum on 10-byte and 16-byte frames must be rejected
        var corrupted12 = pkt65535
        corrupted12[4] ^= 0x55
        let badOut12 = decoder.decodePacketWithSequenceInterpolation(corrupted12)
        #expect(badOut12.isEmpty)

        var corrupted24 = pkt2
        corrupted24[7] ^= 0xAA
        let badOut24 = decoder.decodePacketWithSequenceInterpolation(corrupted24)
        #expect(badOut24.isEmpty)
        #expect(decoder.corruptedChecksumDropCount == 2)
    }

    @Test("15% BLE packet drop, burst loss, heavy-tailed arrival jitter & UInt16 wrap maintain lockstep 4-ch sync and zero false spikes")
    func verify15PercentPacketDropExtremeJitterAndRolloverPipelineSynchronization() {
        let sampleRate = 256.0
        let dt = 1.0 / sampleRate
        let totalPackets = 2560 // 10.0 seconds at 256 Hz
        let startSeq: UInt16 = 65000 // Rolls over 65535 -> 0 at packet index 536

        var prng = SplitMix64PRNG(seed: 0x2026_0331_B1EE_CAFE)

        // Ground-truth ocular blink onsets placed outside the two deep burst-drop windows
        let blinkOnsets: [Int] = [180, 640, 1080, 1780, 2220]
        let burstWindowA = 420..<442   // 22-sample burst dropout (85.9 ms)
        let burstWindowB = 1480..<1510 // 30-sample burst dropout (117.2 ms)
        let blinkLen = Int(0.24 * sampleRate)

        let dcOffsets: (Float, Float, Float, Float) = (-180.0, 140.0, 125.0, -160.0)
        var rawPackets: [Data] = []
        rawPackets.reserveCapacity(totalPackets)
        var quantizedTruth: [EEGQuadSample] = []
        quantizedTruth.reserveCapacity(totalPackets)

        var idealFilterBank = EEGArtifactFilterBank(sampleRate: sampleRate)
        var idealCleanedAF7: [Float] = []
        idealCleanedAF7.reserveCapacity(totalPackets)

        for idx in 0..<totalPackets {
            let t = Double(idx) * dt
            let alpha = 12.0 * sin(2.0 * Double.pi * 10.2 * t)
            let theta = 6.5 * cos(2.0 * Double.pi * 6.0 * t)
            let pacEnv = 1.0 + 0.68 * cos(2.0 * Double.pi * 6.0 * t)
            let gamma = 3.2 * pacEnv * sin(2.0 * Double.pi * 40.0 * t)
            let cortical = Float(alpha + theta + gamma)

            var blinkPulse: Float = 0.0
            for onset in blinkOnsets {
                let offset = idx - onset
                if offset >= 0 && offset < blinkLen {
                    let localT = Double(offset) * dt
                    blinkPulse += 185.0 * SyntheticCorticalEEGGenerator.ocularBlinkDipoleWaveform(localTimeSeconds: localT)
                }
            }

            let hum50 = 0.65 * sin(2.0 * Double.pi * 50.0 * t)
            let hum60 = 0.35 * sin(2.0 * Double.pi * 60.0 * t)
            let hum = Float(1.2 * (hum50 + hum60))

            let n0 = Float(prng.nextSymmetric() * 1.2)
            let n1 = Float(prng.nextSymmetric() * 1.2)
            let n2 = Float(prng.nextSymmetric() * 1.2)
            let n3 = Float(prng.nextSymmetric() * 1.2)

            let tp9 = cortical * 0.92 + n0 + dcOffsets.0 + 0.14 * blinkPulse + hum
            let af7 = cortical * 0.95 + n1 + dcOffsets.1 + 0.86 * blinkPulse + hum
            let af8 = cortical * 1.05 + n2 + dcOffsets.2 + 0.82 * blinkPulse + hum
            let tp10 = cortical * 1.08 + n3 + dcOffsets.3 + 0.12 * blinkPulse + hum

            let seq = startSeq &+ UInt16(idx)
            let rawSample = EEGQuadSample(tp9: tp9, af7: af7, af8: af8, tp10: tp10, timestamp: t)
            let pkt = EEGBLEPacketDecoder.encode12BitBigEndianPacket(sequenceNumber: seq, sample: rawSample)
            rawPackets.append(pkt)

            // Decode single packet for exact 12-bit quantized reference
            var singleDec = EEGBLEPacketDecoder(sampleRate: sampleRate)
            let qSample = singleDec.decodePacketWithSequenceInterpolation(pkt)[0]
            quantizedTruth.append(qSample)

            let idealStep = idealFilterBank.processQuadSample(qSample)
            idealCleanedAF7.append(idealStep.cleaned.af7)
        }

        // Simulate 15% total packet drop (2 burst drops + random Bernoulli drops) + extreme arrival jitter + duplicates
        struct ArrivalEvent {
            let arrivalTime: TimeInterval
            let packet: Data
            let originalIndex: Int
        }

        var arrivals: [ArrivalEvent] = []
        arrivals.reserveCapacity(totalPackets)
        var droppedCount = 0

        for idx in 0..<totalPackets {
            let inBurst = burstWindowA.contains(idx) || burstWindowB.contains(idx)
            // Guard a 5-sample core at the peak of each blink so ground-truth blinks aren't completely erased
            var inBlinkPeakCore = false
            for onset in blinkOnsets {
                if idx >= onset + 18 && idx <= onset + 23 {
                    inBlinkPeakCore = true
                    break
                }
            }

            let randomDropProb = 0.133
            let isRandomDrop = !inBlinkPeakCore && (prng.nextUniform() < randomDropProb)
            if inBurst || isRandomDrop {
                droppedCount += 1
                continue
            }

            let sendTime = Double(idx) * dt
            let uJitter = prng.nextUniform()
            let delaySec: Double
            if uJitter < 0.75 {
                delaySec = prng.nextUniform() * 0.015
            } else {
                // Heavy-tailed jitter up to 95 ms (24 packets reorder depth at 256 Hz)
                let tailU = max(0.001, prng.nextUniform())
                let pareto = pow(tailU, -1.0 / 2.2) * 0.012
                delaySec = min(pareto, 0.095)
            }
            let arrTime = sendTime + delaySec
            arrivals.append(ArrivalEvent(arrivalTime: arrTime, packet: rawPackets[idx], originalIndex: idx))

            // 1.5% duplicate BLE notification retry
            if prng.nextUniform() < 0.015 {
                let dupDelay = delaySec + 0.003 + prng.nextUniform() * 0.014
                arrivals.append(ArrivalEvent(arrivalTime: sendTime + dupDelay, packet: rawPackets[idx], originalIndex: idx))
            }
        }

        let realizedDropRate = Double(droppedCount) / Double(totalPackets)
        #expect(realizedDropRate >= 0.135 && realizedDropRate <= 0.168)

        arrivals.sort { $0.arrivalTime < $1.arrivalTime }

        var synchronizer = EEGBLEStreamSynchronizer(
            sampleRate: sampleRate,
            jitterBufferCapacity: 64,
            maxHoldSeconds: 0.105,
            maxInterpolatedGapSamples: 16
        )
        var filterBank = EEGArtifactFilterBank(sampleRate: sampleRate)
        var detector = EEGOcularBlinkAndSpikeDetector()
        var ringBuffer = EEGQuadLockstepRingBuffer(capacity: 2560)

        var synchronizedStream: [EEGBLESynchronizedSample] = []
        synchronizedStream.reserveCapacity(totalPackets)

        for event in arrivals {
            let ready = synchronizer.ingestBLEPacket(event.packet, arrivalTimestamp: event.arrivalTime)
            synchronizedStream.append(contentsOf: ready)
        }
        synchronizedStream.append(contentsOf: synchronizer.flush())

        #expect(synchronizer.reorderedRecoveredCount > 100)
        #expect(synchronizer.duplicateOrLateDropCount > 0)
        #expect(synchronizer.largeGapDiscontinuityCount >= 2)
        #expect(synchronizer.interpolatedSampleCount > 150)

        var prevSampleIndex: UInt64?
        var hardenedCleanedAF7: [Float] = []
        hardenedCleanedAF7.reserveCapacity(synchronizedStream.count)

        for syncItem in synchronizedStream {
            if let prevIdx = prevSampleIndex {
                #expect(syncItem.sampleIndex > prevIdx)
            }
            prevSampleIndex = syncItem.sampleIndex

            // Verify measured samples match transmitted quantized truth exactly across all 4 channels (zero channel skew)
            if !syncItem.isSynthetic {
                let trueIdx = Int(syncItem.sampleIndex)
                if trueIdx >= 0 && trueIdx < quantizedTruth.count {
                    let expected = quantizedTruth[trueIdx]
                    #expect(abs(syncItem.sample.tp9 - expected.tp9) < 1e-4)
                    #expect(abs(syncItem.sample.af7 - expected.af7) < 1e-4)
                    #expect(abs(syncItem.sample.af8 - expected.af8) < 1e-4)
                    #expect(abs(syncItem.sample.tp10 - expected.tp10) < 1e-4)
                }
            }

            let out = filterBank.processSynchronizedSample(syncItem)
            detector.observe(
                sampleIndex: syncItem.sampleIndex,
                cleanedSample: out.cleaned,
                eogVerticalUV: out.eogVertical,
                isSynthetic: syncItem.isSynthetic,
                isInWarmup: out.isInWarmup
            )
            ringBuffer.push(
                raw: syncItem.sample,
                cleaned: out.cleaned,
                sampleIndex: syncItem.sampleIndex,
                isSynthetic: syncItem.isSynthetic,
                isPostDiscontinuity: syncItem.isPostDiscontinuity
            )
            hardenedCleanedAF7.append(out.cleaned.af7)

            #expect(out.cleaned.tp9.isFinite && abs(out.cleaned.tp9) < 250.0)
            #expect(out.cleaned.af7.isFinite && abs(out.cleaned.af7) < 250.0)
            #expect(out.cleaned.af8.isFinite && abs(out.cleaned.af8) < 250.0)
            #expect(out.cleaned.tp10.isFinite && abs(out.cleaned.tp10) < 250.0)
        }

        // Verify lockstep 4-channel ring buffer synchronization
        #expect(ringBuffer.channelSkewSamples == 0)
        let chTP9 = ringBuffer.chronologicalChannelSamples(.tp9, cleaned: true)
        let chAF7 = ringBuffer.chronologicalChannelSamples(.af7, cleaned: true)
        let chAF8 = ringBuffer.chronologicalChannelSamples(.af8, cleaned: true)
        let chTP10 = ringBuffer.chronologicalChannelSamples(.tp10, cleaned: true)
        #expect(chTP9.count == synchronizedStream.count)
        #expect(chAF7.count == synchronizedStream.count)
        #expect(chAF8.count == synchronizedStream.count)
        #expect(chTP10.count == synchronizedStream.count)

        // Verify zero false slew spikes & zero false blinks in burst/drop regions, and 100% recall on ground-truth blinks
        #expect(detector.falseSpikeCount == 0)

        var matchedOnsets = Set<Int>()
        var falseBlinkCount = 0
        let maxBlinkDetectionLag = Int(0.25 * sampleRate)
        for detectedIdx in detector.detectedBlinkSampleIndices {
            let det = Int(detectedIdx)
            var matched = false
            for onset in blinkOnsets {
                if det >= onset - 10 && det <= onset + maxBlinkDetectionLag {
                    matchedOnsets.insert(onset)
                    matched = true
                    break
                }
            }
            if !matched {
                falseBlinkCount += 1
            }
        }
        #expect(falseBlinkCount == 0)
        #expect(matchedOnsets.count == blinkOnsets.count)

        // Verify 8-13 Hz alpha band power & IAF preservation after warmup (samples >= 256)
        let idealTail = Array(idealCleanedAF7.dropFirst(256))
        let hardenedTail = Array(hardenedCleanedAF7.dropFirst(256))
        let idealMetrics = CorticalSpectralAnalyzer.analyze(channelSamples: idealTail, sampleRate: sampleRate)
        let hardenedMetrics = CorticalSpectralAnalyzer.analyze(channelSamples: hardenedTail, sampleRate: sampleRate)

        let alphaRelError = abs(hardenedMetrics.alphaPower - idealMetrics.alphaPower) / max(1e-6, idealMetrics.alphaPower)
        #expect(alphaRelError < 0.15)
        #expect(abs(hardenedMetrics.individualAlphaFrequencyHz - 10.2) < 0.45)
    }

    @Test("Filter bank gates RLS/Kalman adaptation on synthetic samples and soft-reprimes across burst discontinuities")
    func verifySyntheticSampleGatingAndSingleChannelKalmanDiscontinuityResilience() {
        var filterBank = EEGArtifactFilterBank(sampleRate: 256.0)
        let baseline = EEGQuadSample(tp9: -120.0, af7: 145.0, af8: 130.0, tp10: -110.0, timestamp: 0.0)

        // Train on 128 measured samples with an active blink so RLS weights become non-zero
        for i in 0..<128 {
            let t = Double(i) / 256.0
            let blink: Float = (i >= 30 && i < 80) ? 160.0 * SyntheticCorticalEEGGenerator.ocularBlinkDipoleWaveform(localTimeSeconds: Double(i - 30) / 256.0) : 0.0
            let s = EEGQuadSample(
                tp9: baseline.tp9 + Float(8.0 * sin(2.0 * Double.pi * 10.0 * t)) + 0.14 * blink,
                af7: baseline.af7 + Float(8.0 * sin(2.0 * Double.pi * 10.0 * t)) + 0.86 * blink,
                af8: baseline.af8 + Float(8.0 * sin(2.0 * Double.pi * 10.0 * t)) + 0.82 * blink,
                tp10: baseline.tp10 + Float(8.0 * sin(2.0 * Double.pi * 10.0 * t)) + 0.12 * blink,
                timestamp: t
            )
            _ = filterBank.processQuadSample(s, isSynthetic: false, isPostDiscontinuity: false)
            _ = filterBank.processSample(rawEEG: s.af7, eogReference: blink, isSynthetic: false, isPostDiscontinuity: false)
        }

        let weightsBeforeSynthetic = filterBank.rlsWeights
        let synthCountBefore = filterBank.syntheticPredictOnlyStepCount

        // Feed 8 synthetic interpolated samples: RLS weights must remain frozen
        for k in 0..<8 {
            let t = Double(128 + k) / 256.0
            let synthSample = EEGQuadSample(tp9: baseline.tp9, af7: baseline.af7, af8: baseline.af8, tp10: baseline.tp10, timestamp: t)
            let quadOut = filterBank.processQuadSample(synthSample, isSynthetic: true, isPostDiscontinuity: false)
            let singleOut = filterBank.processSample(rawEEG: synthSample.af7, eogReference: 50.0, isSynthetic: true, isPostDiscontinuity: false)
            #expect(quadOut.cleaned.af7.isFinite)
            #expect(singleOut.isFinite)
        }

        #expect(filterBank.rlsWeights == weightsBeforeSynthetic)
        #expect(filterBank.syntheticPredictOnlyStepCount == synthCountBefore + 16)

        // Feed a post-discontinuity sample with a +200 uV DC baseline shift (simulating electrode settle after burst drop)
        let shiftedSample = EEGQuadSample(
            tp9: baseline.tp9 + 200.0,
            af7: baseline.af7 + 200.0,
            af8: baseline.af8 + 200.0,
            tp10: baseline.tp10 + 200.0,
            timestamp: 1.0
        )
        let discontOut = filterBank.processQuadSample(shiftedSample, isSynthetic: false, isPostDiscontinuity: true)
        #expect(filterBank.discontinuityReprimeCount == 1)
        #expect(filterBank.warmupSuppressionRemainingSamples == EEGArtifactFilterBank.defaultWarmupSuppressionSamples - 1)
        // Soft DC re-priming prevents the +200 uV step from leaking into the cleaned output
        #expect(abs(discontOut.cleaned.af7) < 5.0)
        #expect(abs(discontOut.eogVertical) < 5.0)
    }
}
