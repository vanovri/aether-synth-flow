// MARK: - FILE: Track33SPWVDAuditTests.swift

import Testing
import Foundation

@Suite("Track 33 Audit: Zero-Allocation Realtime SPWVD, >=20 dB Cross-Term Suppression & Thomas HHT Completeness")
struct Track33SPWVDAuditTests {

    @Test("RealtimeSPWVDEngine preserves identical workspace pointer addresses across 128 real-time block & ring-buffer evaluations")
    func verifyRealtimeSPWVDZeroAllocationBufferAddressInvariance() {
        let n = SPWVDAnalyzer.canonicalBlockSize
        let bins = 64
        let fs = 256.0
        let engine = RealtimeSPWVDEngine(
            blockSize: n,
            sampleRate: fs,
            freqBins: bins,
            timeSigmaSamples: SPWVDAnalyzer.defaultTimeSigmaSamples
        )

        let initialFingerprint = engine.workspaceAddressFingerprint
        let initialTFRPtr = engine.tfrFlatBuffer.baseAddress
        let initialRidgePtr = engine.ridgeHzBuffer.baseAddress
        let initialAnalyticRePtr = engine.analyticRealBuffer.baseAddress
        let initialAnalyticImPtr = engine.analyticImagBuffer.baseAddress

        #expect(initialTFRPtr != nil)
        #expect(initialRidgePtr != nil)
        #expect(initialAnalyticRePtr != nil)
        #expect(initialAnalyticImPtr != nil)

        var block = [Float](repeating: 0.0, count: n)

        for iter in 0..<64 {
            let phaseOffset = Double(iter) * 0.15
            for i in 0..<n {
                let t = Double(i) / fs
                let f1 = 14.0 * t + phaseOffset
                let f2 = 42.0 * t
                let s = 0.65 * sin(2.0 * Double.pi * f1) + 0.35 * cos(2.0 * Double.pi * f2)
                block[i] = Float(s)
            }

            let okBlock = block.withUnsafeBufferPointer { buf in
                engine.processRealtimeBlock(buf)
            }
            #expect(okBlock)
            #expect(engine.workspaceAddressFingerprint == initialFingerprint)
            #expect(engine.tfrFlatBuffer.baseAddress == initialTFRPtr)
            #expect(engine.ridgeHzBuffer.baseAddress == initialRidgePtr)
            #expect(engine.analyticRealBuffer.baseAddress == initialAnalyticRePtr)
            #expect(engine.analyticImagBuffer.baseAddress == initialAnalyticImPtr)

            for i in 0..<n {
                engine.pushSample(block[i])
            }
            let okRing = engine.analyzeRingBufferInPlace()
            #expect(okRing)
            #expect(engine.workspaceAddressFingerprint == initialFingerprint)
            #expect(engine.tfrFlatBuffer.baseAddress == initialTFRPtr)
            #expect(engine.ridgeHzBuffer.baseAddress == initialRidgePtr)
        }

        #expect(engine.processedBlockCount == 128)
        #expect(engine.latestRenyiEntropyBits > 0.0 && engine.latestRenyiEntropyBits.isFinite)
        #expect(engine.latestCrossTermSuppressionDB > 15.0 && engine.latestCrossTermSuppressionDB.isFinite)
    }

    @Test("SPWVD suppresses two-tone midpoint cross-term artifacts by >=20 dB vs PWVD and satisfies discrete time-marginal identity")
    func verifySPWVDCrossTermSuppressionExceeds20dBAndPreservesMarginal() {
        let n = 128
        let bins = 64
        let fs = 256.0
        let f1Hz = 20.0
        let f2Hz = 68.0
        let midHz = 0.5 * (f1Hz + f2Hz) // 44.0 Hz bilinear cross-term locus

        var twoTone = [Float](repeating: 0.0, count: n)
        var amSignal = [Float](repeating: 0.0, count: n)
        for i in 0..<n {
            let t = Double(i) / fs
            let c1 = sin(2.0 * Double.pi * f1Hz * t)
            let c2 = sin(2.0 * Double.pi * f2Hz * t)
            twoTone[i] = Float(c1 + c2)

            let carrier = sin(2.0 * Double.pi * 30.0 * t)
            let mod = 1.0 + 0.5 * sin(2.0 * Double.pi * 3.0 * t)
            amSignal[i] = Float(carrier * mod)
        }

        let pwvd = SPWVDAnalyzer.analyze(
            signal: twoTone,
            sampleRate: fs,
            freqBins: bins,
            timeSigmaSamples: 0.0,
            useRectangularLagWindow: true
        )
        let spwvd = SPWVDAnalyzer.analyze(
            signal: twoTone,
            sampleRate: fs,
            freqBins: bins,
            timeSigmaSamples: SPWVDAnalyzer.defaultTimeSigmaSamples,
            useRectangularLagWindow: false
        )

        #expect(pwvd.crossTermSuppressionDB == 0.0)
        #expect(spwvd.crossTermSuppressionDB >= 20.0)

        func bandEnergySq(_ result: SPWVDResult, centerHz: Double, halfBandHz: Double) -> Double {
            var acc: Double = 0.0
            let freqScale = fs / Double(2 * bins)
            for tIdx in 24..<(n - 24) {
                let row = result.tfrMatrix[tIdx]
                for k in 0..<bins {
                    let fk = Double(k) * freqScale
                    if abs(fk - centerHz) <= halfBandHz {
                        let v = Double(row[k])
                        acc += v * v
                    }
                }
            }
            return acc
        }

        let pwvdAuto = 0.5 * (bandEnergySq(pwvd, centerHz: f1Hz, halfBandHz: 3.0) + bandEnergySq(pwvd, centerHz: f2Hz, halfBandHz: 3.0))
        let pwvdCross = bandEnergySq(pwvd, centerHz: midHz, halfBandHz: 3.0)
        let pwvdRatioDB = 10.0 * log10(max(pwvdCross, 1.0e-30) / max(pwvdAuto, 1.0e-30))

        let spwvdAuto = 0.5 * (bandEnergySq(spwvd, centerHz: f1Hz, halfBandHz: 3.0) + bandEnergySq(spwvd, centerHz: f2Hz, halfBandHz: 3.0))
        let spwvdCross = bandEnergySq(spwvd, centerHz: midHz, halfBandHz: 3.0)
        let spwvdRatioDB = 10.0 * log10(max(spwvdCross, 1.0e-30) / max(spwvdAuto, 1.0e-30))

        let midpointAttenuationDB = pwvdRatioDB - spwvdRatioDB
        #expect(pwvdRatioDB > 0.0)
        #expect(spwvdRatioDB < -20.0)
        #expect(midpointAttenuationDB >= 20.0)

        // Verify discrete time-marginal identity: sum_{k=0..<K} W_z[n, k] == |z[n]|^2 when sigma=0, rectLag=true
        let marginalEngine = RealtimeSPWVDEngine(
            blockSize: n,
            sampleRate: fs,
            freqBins: bins,
            timeSigmaSamples: 0.0,
            useRectangularLagWindow: true
        )
        amSignal.withUnsafeBufferPointer { buf in
            _ = marginalEngine.processRealtimeBlock(buf)
        }
        var maxMarginalError: Double = 0.0
        for tIdx in 0..<n {
            var freqSum: Double = 0.0
            for k in 0..<bins {
                freqSum += Double(marginalEngine.tfrValue(timeIndex: tIdx, freqBin: k))
            }
            let zRe = marginalEngine.analyticRealBuffer[tIdx]
            let zIm = marginalEngine.analyticImagBuffer[tIdx]
            let instPower = zRe * zRe + zIm * zIm
            let err = abs(freqSum - instPower)
            if err > maxMarginalError {
                maxMarginalError = err
            }
        }
        #expect(maxMarginalError < 1.0e-5)
    }

    @Test("SPWVD parabolic ridge interpolation tracks linear chirp within <0.25 Hz mean error (<1.5 Hz bound)")
    func verifySPWVDParabolicChirpRidgeSubBinAccuracyAndRenyiEntropy() {
        let n = 128
        let fs = 256.0
        let f0 = 10.0
        let chirpRate = 24.0

        var chirp = [Float](repeating: 0.0, count: n)
        for i in 0..<n {
            let t = Double(i) / fs
            let phase = 2.0 * Double.pi * (f0 * t + 0.5 * chirpRate * t * t)
            chirp[i] = Float(sin(phase))
        }

        let res = SPWVDAnalyzer.analyze(
            signal: chirp,
            sampleRate: fs,
            freqBins: 64,
            halfLagL: 16,
            halfTimeM: 6
        )

        var errSum: Double = 0.0
        var maxErr: Double = 0.0
        var count = 0
        for i in 20..<(n - 20) {
            let t = Double(i) / fs
            let expectedHz = f0 + chirpRate * t
            let actualHz = Double(res.instantaneousFreqRidgeHz[i])
            let diff = abs(actualHz - expectedHz)
            errSum += diff
            if diff > maxErr {
                maxErr = diff
            }
            count += 1
        }
        let meanErr = errSum / Double(max(1, count))
        #expect(meanErr < 0.25)
        #expect(maxErr < 0.50)
        #expect(res.renyiEntropyBits > 1.0 && res.renyiEntropyBits.isFinite)
        #expect(res.crossTermSuppressionDB > 15.0)
    }

    @Test("HilbertHuangSifter Thomas O(N) natural cubic spline interpolates knots exactly and achieves <1e-4 reconstruction completeness")
    func verifyHilbertHuangThomasCubicSplineCompletenessAndOrthogonality() {
        let knotX: [Double] = [0.0, 15.0, 38.0, 63.0, 91.0, 127.0]
        let knotY: [Double] = [0.2, 1.4, -0.8, 0.9, -1.1, 0.3]
        let evaluated = HilbertHuangSifter.evaluateNaturalCubicSpline(
            knotX: knotX,
            knotY: knotY,
            sampleCount: 128
        )
        #expect(evaluated.count == 128)
        for idx in 0..<knotX.count {
            let samplePos = Int(knotX[idx])
            let knotErr = abs(evaluated[samplePos] - knotY[idx])
            #expect(knotErr < 1.0e-11)
        }

        let n = 128
        let fs = 256.0
        var composite = [Float](repeating: 0.0, count: n)
        for i in 0..<n {
            let t = Double(i) / fs
            let cLow = 0.75 * sin(2.0 * Double.pi * 6.0 * t)
            let cHigh = sin(2.0 * Double.pi * 22.0 * t)
            let chirp = 0.5 * sin(2.0 * Double.pi * (10.0 * t + 12.0 * t * t))
            composite[i] = Float(cLow + cHigh + chirp)
        }

        let hht = HilbertHuangSifter.sift(
            signal: composite,
            sampleRate: fs,
            maxIMFs: 4,
            maxSiftIterations: 12,
            cauchyConvergenceThreshold: 0.05
        )
        #expect(hht.imfs.count >= 2)
        #expect(hht.imfAnalytics.count == hht.imfs.count)
        #expect(hht.maxReconstructionError < 1.0e-4)
        #expect(hht.orthogonalityIndex >= 0.0 && hht.orthogonalityIndex.isFinite)
    }

    @Test("RealtimeSPWVDEngine block and ring-buffer paths match SPWVDAnalyzer.analyze convenience API identically")
    func verifyRealtimeEngineAndConvenienceAnalyzerBitwiseEquivalence() {
        let n = 128
        let bins = 32
        let fs = 256.0
        var signal = [Float](repeating: 0.0, count: n)
        for i in 0..<n {
            let t = Double(i) / fs
            let s1 = 0.8 * sin(2.0 * Double.pi * 13.5 * t)
            let s2 = 0.4 * cos(2.0 * Double.pi * 36.0 * t)
            signal[i] = Float(s1 + s2)
        }

        let convenience = SPWVDAnalyzer.analyze(
            signal: signal,
            sampleRate: fs,
            freqBins: bins
        )

        let rtEngine = RealtimeSPWVDEngine(
            blockSize: n,
            sampleRate: fs,
            freqBins: bins
        )
        signal.withUnsafeBufferPointer { buf in
            _ = rtEngine.processRealtimeBlock(buf)
        }
        let fromBlock = rtEngine.snapshotResult()

        for sample in signal {
            rtEngine.pushSample(sample)
        }
        _ = rtEngine.analyzeRingBufferInPlace()
        let fromRing = rtEngine.snapshotResult()

        #expect(convenience == fromBlock)
        #expect(convenience == fromRing)
        #expect(convenience.corticalSpindlePowerRatio > 0.25)
    }
}
