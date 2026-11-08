// MARK: - FILE: WignerVilleHilbertHuangAnalyzer.swift

import Foundation

// MARK: - 1. Smoothed Pseudo Wigner-Ville Distribution (SPWVD) Result, Realtime Workspace & Analyzer

public struct SPWVDResult: Sendable, Equatable {
    public let timeSteps: Int
    public let freqBins: Int
    public let tfrMatrix: [[Float]]
    public let instantaneousFreqRidgeHz: [Float]
    public let renyiEntropyBits: Float
    public let corticalSpindlePowerRatio: Float
    public let crossTermSuppressionDB: Float

    public var scalogram: [[Float]] {
        tfrMatrix
    }

    public var dominantRidgeHz: [Float] {
        instantaneousFreqRidgeHz
    }

    public init(
        timeSteps: Int,
        freqBins: Int,
        tfrMatrix: [[Float]],
        instantaneousFreqRidgeHz: [Float],
        renyiEntropyBits: Float,
        corticalSpindlePowerRatio: Float = 0.0,
        crossTermSuppressionDB: Float = 0.0
    ) {
        self.timeSteps = timeSteps
        self.freqBins = freqBins
        self.tfrMatrix = tfrMatrix
        self.instantaneousFreqRidgeHz = instantaneousFreqRidgeHz
        self.renyiEntropyBits = renyiEntropyBits
        let clampedSpindle = min(max(corticalSpindlePowerRatio, 0.0), 1.0)
        self.corticalSpindlePowerRatio = corticalSpindlePowerRatio.isFinite ? clampedSpindle : 0.0
        self.crossTermSuppressionDB = crossTermSuppressionDB.isFinite ? max(0.0, crossTermSuppressionDB) : 0.0
    }
}

public typealias SPWVDRealtimeWorkspace = RealtimeSPWVDEngine

/// Preallocated, zero-allocation real-time Smoothed Pseudo Wigner-Ville Distribution (SPWVD) processor.
/// All scratch storage, FFT bit-reversal/twiddle tables, Marple Hilbert spectral mask, separable Gaussian
/// Doppler-time smoothing window `g[u]`, and boundary-adaptive Hann lag window table `h[L_t, tau]` are
/// allocated once in `init` and released in `deinit`. Audio/BCI render callbacks invoke
/// `pushSample(_:)` / `analyzeRingBufferInPlace()` or `processRealtimeBlock(_:count:)` without heap allocations,
/// Array Copy-on-Write, locks, or trigonometric calls on the real-time thread.
public final class RealtimeSPWVDEngine: @unchecked Sendable {

    public struct WorkspaceAddressFingerprint: Sendable, Equatable {
        public let ringBufferAddress: UInt
        public let linearizedInputAddress: UInt
        public let fftRealAddress: UInt
        public let fftImagAddress: UInt
        public let analyticRealAddress: UInt
        public let analyticImagAddress: UInt
        public let gKernelAddress: UInt
        public let lagWindowTableAddress: UInt
        public let cosTableAddress: UInt
        public let sinTableAddress: UInt
        public let rSmoothRealAddress: UInt
        public let rSmoothImagAddress: UInt
        public let sliceBufferAddress: UInt
        public let tfrOutputAddress: UInt
        public let ridgeOutputAddress: UInt
    }

    /// Gaussian truncation radius in standard deviations (`2.5 * sigma` captures >98.7% of Gaussian mass).
    public static let gaussianTruncationStds: Double = 2.5
    /// Minimum positive Gaussian sigma in samples when time smoothing is enabled.
    public static let minimumPositiveSigmaSamples: Double = 0.35
    /// Maximum reported cross-term negativity suppression in decibels (60 dB = 10^6 power ratio floor).
    public static let maximumSuppressionDB: Double = 60.0
    /// Lower bound of thalamic sleep/cortical spindle frequency band in Hz (sigma band: 11–16 Hz).
    public static let spindleBandLowHz: Double = 11.0
    /// Upper bound of thalamic sleep/cortical spindle frequency band in Hz (sigma band: 11–16 Hz).
    public static let spindleBandHighHz: Double = 16.0

    public let blockSize: Int
    public let freqBins: Int
    public let sampleRate: Double
    public let timeSigmaSamples: Double
    public let maxLagSamples: Int
    public let halfTimeWindowSamples: Int
    public let fftLength: Int
    public let useRectangularLagWindow: Bool

    private let lagStride: Int
    private let gKernelCount: Int

    private let ringBufferPtr: UnsafeMutablePointer<Float>
    private let linearizedInputPtr: UnsafeMutablePointer<Float>
    private let fftRealPtr: UnsafeMutablePointer<Double>
    private let fftImagPtr: UnsafeMutablePointer<Double>
    private let fftBitRevPtr: UnsafeMutablePointer<Int>
    private let fftTwiddleRePtr: UnsafeMutablePointer<Double>
    private let fftTwiddleImPtr: UnsafeMutablePointer<Double>
    private let hilbertGainPtr: UnsafeMutablePointer<Double>
    private let analyticRePtr: UnsafeMutablePointer<Double>
    private let analyticImPtr: UnsafeMutablePointer<Double>
    private let gKernelPtr: UnsafeMutablePointer<Double>
    private let lagWindowTablePtr: UnsafeMutablePointer<Double>
    private let cosTablePtr: UnsafeMutablePointer<Double>
    private let sinTablePtr: UnsafeMutablePointer<Double>
    private let rSmoothRePtr: UnsafeMutablePointer<Double>
    private let rSmoothImPtr: UnsafeMutablePointer<Double>
    private let rRawRePtr: UnsafeMutablePointer<Double>
    private let rRawImPtr: UnsafeMutablePointer<Double>
    private let sliceBufferPtr: UnsafeMutablePointer<Double>
    private let tfrBufferPtr: UnsafeMutablePointer<Float>
    private let ridgeBufferPtr: UnsafeMutablePointer<Float>

    private var ringWriteIndex: Int = 0
    private var ingestedSampleCount: Int = 0

    public private(set) var latestRenyiEntropyBits: Float = 0.0
    public private(set) var latestCorticalSpindlePowerRatio: Float = 0.0
    public private(set) var latestCrossTermSuppressionDB: Float = 0.0
    public private(set) var processedBlockCount: UInt64 = 0

    public init(
        blockSize: Int = SPWVDAnalyzer.canonicalBlockSize,
        sampleRate: Double = 256.0,
        freqBins: Int = 64,
        timeSigmaSamples: Double = SPWVDAnalyzer.defaultTimeSigmaSamples,
        maxLagSamples: Int? = nil,
        useRectangularLagWindow: Bool = false
    ) {
        let resolvedN = max(4, blockSize)
        let resolvedBins = max(8, freqBins)
        let resolvedFs = max(1.0, sampleRate)

        let resolvedSigma: Double
        let resolvedHalfTimeWin: Int
        if timeSigmaSamples <= 0.0 {
            resolvedSigma = 0.0
            resolvedHalfTimeWin = 0
        } else {
            let clampedSigma = max(Self.minimumPositiveSigmaSamples, timeSigmaSamples)
            resolvedSigma = clampedSigma
            let rawHalfWin = Int(ceil(Self.gaussianTruncationStds * clampedSigma))
            let maxAllowedHalfWin = max(1, resolvedN / 4)
            resolvedHalfTimeWin = min(max(1, rawHalfWin), maxAllowedHalfWin)
        }

        let defaultLag = min(max(4, resolvedN / 4), resolvedBins - 1)
        let requestedLag = maxLagSamples ?? defaultLag
        let maxLagUpper = min(max(2, resolvedN / 2 - 1), resolvedBins - 1)
        let resolvedMaxLag = min(max(2, requestedLag), maxLagUpper)

        let resolvedFFTLength = Self.nextPowerOfTwo(max(8, 2 * resolvedN))
        let resolvedLagStride = resolvedMaxLag + 1
        let resolvedGCount = 2 * resolvedHalfTimeWin + 1

        self.blockSize = resolvedN
        self.freqBins = resolvedBins
        self.sampleRate = resolvedFs
        self.timeSigmaSamples = resolvedSigma
        self.maxLagSamples = resolvedMaxLag
        self.halfTimeWindowSamples = resolvedHalfTimeWin
        self.fftLength = resolvedFFTLength
        self.useRectangularLagWindow = useRectangularLagWindow
        self.lagStride = resolvedLagStride
        self.gKernelCount = resolvedGCount

        self.ringBufferPtr = UnsafeMutablePointer<Float>.allocate(capacity: resolvedN)
        self.ringBufferPtr.initialize(repeating: 0.0, count: resolvedN)

        self.linearizedInputPtr = UnsafeMutablePointer<Float>.allocate(capacity: resolvedN)
        self.linearizedInputPtr.initialize(repeating: 0.0, count: resolvedN)

        self.fftRealPtr = UnsafeMutablePointer<Double>.allocate(capacity: resolvedFFTLength)
        self.fftRealPtr.initialize(repeating: 0.0, count: resolvedFFTLength)

        self.fftImagPtr = UnsafeMutablePointer<Double>.allocate(capacity: resolvedFFTLength)
        self.fftImagPtr.initialize(repeating: 0.0, count: resolvedFFTLength)

        self.fftBitRevPtr = UnsafeMutablePointer<Int>.allocate(capacity: resolvedFFTLength)
        self.fftBitRevPtr.initialize(repeating: 0, count: resolvedFFTLength)

        self.fftTwiddleRePtr = UnsafeMutablePointer<Double>.allocate(capacity: resolvedFFTLength)
        self.fftTwiddleRePtr.initialize(repeating: 0.0, count: resolvedFFTLength)

        self.fftTwiddleImPtr = UnsafeMutablePointer<Double>.allocate(capacity: resolvedFFTLength)
        self.fftTwiddleImPtr.initialize(repeating: 0.0, count: resolvedFFTLength)

        self.hilbertGainPtr = UnsafeMutablePointer<Double>.allocate(capacity: resolvedFFTLength)
        self.hilbertGainPtr.initialize(repeating: 0.0, count: resolvedFFTLength)

        self.analyticRePtr = UnsafeMutablePointer<Double>.allocate(capacity: resolvedN)
        self.analyticRePtr.initialize(repeating: 0.0, count: resolvedN)

        self.analyticImPtr = UnsafeMutablePointer<Double>.allocate(capacity: resolvedN)
        self.analyticImPtr.initialize(repeating: 0.0, count: resolvedN)

        self.gKernelPtr = UnsafeMutablePointer<Double>.allocate(capacity: resolvedGCount)
        self.gKernelPtr.initialize(repeating: 0.0, count: resolvedGCount)

        let lagTableCap = resolvedLagStride * resolvedLagStride
        self.lagWindowTablePtr = UnsafeMutablePointer<Double>.allocate(capacity: lagTableCap)
        self.lagWindowTablePtr.initialize(repeating: 0.0, count: lagTableCap)

        let trigTableCap = resolvedBins * resolvedLagStride
        self.cosTablePtr = UnsafeMutablePointer<Double>.allocate(capacity: trigTableCap)
        self.cosTablePtr.initialize(repeating: 0.0, count: trigTableCap)

        self.sinTablePtr = UnsafeMutablePointer<Double>.allocate(capacity: trigTableCap)
        self.sinTablePtr.initialize(repeating: 0.0, count: trigTableCap)

        self.rSmoothRePtr = UnsafeMutablePointer<Double>.allocate(capacity: resolvedLagStride)
        self.rSmoothRePtr.initialize(repeating: 0.0, count: resolvedLagStride)

        self.rSmoothImPtr = UnsafeMutablePointer<Double>.allocate(capacity: resolvedLagStride)
        self.rSmoothImPtr.initialize(repeating: 0.0, count: resolvedLagStride)

        self.rRawRePtr = UnsafeMutablePointer<Double>.allocate(capacity: resolvedLagStride)
        self.rRawRePtr.initialize(repeating: 0.0, count: resolvedLagStride)

        self.rRawImPtr = UnsafeMutablePointer<Double>.allocate(capacity: resolvedLagStride)
        self.rRawImPtr.initialize(repeating: 0.0, count: resolvedLagStride)

        self.sliceBufferPtr = UnsafeMutablePointer<Double>.allocate(capacity: resolvedBins)
        self.sliceBufferPtr.initialize(repeating: 0.0, count: resolvedBins)

        let tfrCap = resolvedN * resolvedBins
        self.tfrBufferPtr = UnsafeMutablePointer<Float>.allocate(capacity: tfrCap)
        self.tfrBufferPtr.initialize(repeating: 0.0, count: tfrCap)

        self.ridgeBufferPtr = UnsafeMutablePointer<Float>.allocate(capacity: resolvedN)
        self.ridgeBufferPtr.initialize(repeating: 0.0, count: resolvedN)

        Self.precomputeFFTTables(
            fftLength: resolvedFFTLength,
            bitRevPtr: self.fftBitRevPtr,
            twiddleRePtr: self.fftTwiddleRePtr,
            twiddleImPtr: self.fftTwiddleImPtr,
            hilbertGainPtr: self.hilbertGainPtr
        )
        Self.precomputeSmoothingAndBasisTables(
            freqBins: resolvedBins,
            halfTimeWin: resolvedHalfTimeWin,
            sigma: resolvedSigma,
            maxLag: resolvedMaxLag,
            lagStride: resolvedLagStride,
            useRectangularLag: useRectangularLagWindow,
            gKernelPtr: self.gKernelPtr,
            lagWindowTablePtr: self.lagWindowTablePtr,
            cosTablePtr: self.cosTablePtr,
            sinTablePtr: self.sinTablePtr
        )
    }

    deinit {
        let lagTableCap = lagStride * lagStride
        let trigTableCap = freqBins * lagStride
        let tfrCap = blockSize * freqBins

        ringBufferPtr.deinitialize(count: blockSize)
        ringBufferPtr.deallocate()

        linearizedInputPtr.deinitialize(count: blockSize)
        linearizedInputPtr.deallocate()

        fftRealPtr.deinitialize(count: fftLength)
        fftRealPtr.deallocate()

        fftImagPtr.deinitialize(count: fftLength)
        fftImagPtr.deallocate()

        fftBitRevPtr.deinitialize(count: fftLength)
        fftBitRevPtr.deallocate()

        fftTwiddleRePtr.deinitialize(count: fftLength)
        fftTwiddleRePtr.deallocate()

        fftTwiddleImPtr.deinitialize(count: fftLength)
        fftTwiddleImPtr.deallocate()

        hilbertGainPtr.deinitialize(count: fftLength)
        hilbertGainPtr.deallocate()

        analyticRePtr.deinitialize(count: blockSize)
        analyticRePtr.deallocate()

        analyticImPtr.deinitialize(count: blockSize)
        analyticImPtr.deallocate()

        gKernelPtr.deinitialize(count: gKernelCount)
        gKernelPtr.deallocate()

        lagWindowTablePtr.deinitialize(count: lagTableCap)
        lagWindowTablePtr.deallocate()

        cosTablePtr.deinitialize(count: trigTableCap)
        cosTablePtr.deallocate()

        sinTablePtr.deinitialize(count: trigTableCap)
        sinTablePtr.deallocate()

        rSmoothRePtr.deinitialize(count: lagStride)
        rSmoothRePtr.deallocate()

        rSmoothImPtr.deinitialize(count: lagStride)
        rSmoothImPtr.deallocate()

        rRawRePtr.deinitialize(count: lagStride)
        rRawRePtr.deallocate()

        rRawImPtr.deinitialize(count: lagStride)
        rRawImPtr.deallocate()

        sliceBufferPtr.deinitialize(count: freqBins)
        sliceBufferPtr.deallocate()

        tfrBufferPtr.deinitialize(count: tfrCap)
        tfrBufferPtr.deallocate()

        ridgeBufferPtr.deinitialize(count: blockSize)
        ridgeBufferPtr.deallocate()
    }

    public var workspaceAddressFingerprint: WorkspaceAddressFingerprint {
        WorkspaceAddressFingerprint(
            ringBufferAddress: UInt(bitPattern: ringBufferPtr),
            linearizedInputAddress: UInt(bitPattern: linearizedInputPtr),
            fftRealAddress: UInt(bitPattern: fftRealPtr),
            fftImagAddress: UInt(bitPattern: fftImagPtr),
            analyticRealAddress: UInt(bitPattern: analyticRePtr),
            analyticImagAddress: UInt(bitPattern: analyticImPtr),
            gKernelAddress: UInt(bitPattern: gKernelPtr),
            lagWindowTableAddress: UInt(bitPattern: lagWindowTablePtr),
            cosTableAddress: UInt(bitPattern: cosTablePtr),
            sinTableAddress: UInt(bitPattern: sinTablePtr),
            rSmoothRealAddress: UInt(bitPattern: rSmoothRePtr),
            rSmoothImagAddress: UInt(bitPattern: rSmoothImPtr),
            sliceBufferAddress: UInt(bitPattern: sliceBufferPtr),
            tfrOutputAddress: UInt(bitPattern: tfrBufferPtr),
            ridgeOutputAddress: UInt(bitPattern: ridgeBufferPtr)
        )
    }

    public var tfrFlatBuffer: UnsafeBufferPointer<Float> {
        UnsafeBufferPointer(start: tfrBufferPtr, count: blockSize * freqBins)
    }

    public var ridgeHzBuffer: UnsafeBufferPointer<Float> {
        UnsafeBufferPointer(start: ridgeBufferPtr, count: blockSize)
    }

    public var analyticRealBuffer: UnsafeBufferPointer<Double> {
        UnsafeBufferPointer(start: analyticRePtr, count: blockSize)
    }

    public var analyticImagBuffer: UnsafeBufferPointer<Double> {
        UnsafeBufferPointer(start: analyticImPtr, count: blockSize)
    }

    @inline(__always)
    public func tfrValue(timeIndex: Int, freqBin: Int) -> Float {
        guard timeIndex >= 0 && timeIndex < blockSize && freqBin >= 0 && freqBin < freqBins else {
            return 0.0
        }
        return tfrBufferPtr[timeIndex * freqBins + freqBin]
    }

    /// Real-time safe single-sample ring-buffer ingestion (`O(1)`, zero heap allocation).
    @inline(__always)
    public func pushSample(_ sample: Float) {
        let sanitized: Float = sample.isFinite ? sample : 0.0
        ringBufferPtr[ringWriteIndex] = sanitized
        ringWriteIndex += 1
        if ringWriteIndex >= blockSize {
            ringWriteIndex = 0
        }
        if ingestedSampleCount < blockSize {
            ingestedSampleCount += 1
        }
    }

    /// Real-time safe chunk ingestion into the preallocated ring buffer (`O(count)`, zero heap allocation).
    @inline(__always)
    public func pushSamples(_ samples: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        for idx in 0..<count {
            pushSample(samples[idx])
        }
    }

    /// Unrolls the internal circular sample history in chronological order and runs the zero-allocation SPWVD kernel.
    @discardableResult
    public func analyzeRingBufferInPlace() -> Bool {
        let n = blockSize
        var readIdx = ringWriteIndex
        for idx in 0..<n {
            linearizedInputPtr[idx] = ringBufferPtr[readIdx]
            readIdx += 1
            if readIdx >= n {
                readIdx = 0
            }
        }
        return processRealtimeBlock(linearizedInputPtr, count: n)
    }

    /// Convenience wrapper for `UnsafeBufferPointer<Float>` on the real-time path (zero heap allocation).
    @discardableResult
    @inline(__always)
    public func processRealtimeBlock(_ samples: UnsafeBufferPointer<Float>) -> Bool {
        guard let base = samples.baseAddress else { return false }
        return processRealtimeBlock(base, count: samples.count)
    }

    /// Zero-allocation real-time SPWVD evaluation on `samples[0..<count]`.
    /// Populates `tfrFlatBuffer`, `ridgeHzBuffer`, `latestRenyiEntropyBits`, `latestCorticalSpindlePowerRatio`,
    /// and `latestCrossTermSuppressionDB` completely in-place.
    @discardableResult
    public func processRealtimeBlock(_ samples: UnsafePointer<Float>, count: Int) -> Bool {
        let n = blockSize
        guard count >= n else { return false }

        let baseOffset = count - n
        var sumSample: Double = 0.0
        for idx in 0..<n {
            let raw = samples[baseOffset + idx]
            let clean: Double = raw.isFinite ? Double(raw) : 0.0
            fftRealPtr[idx] = clean
            sumSample += clean
        }

        // Remove DC mean prior to zero-padded analytic projection to prevent 0 Hz cross-terms
        let meanVal = sumSample / Double(n)
        for idx in 0..<n {
            fftRealPtr[idx] -= meanVal
            fftImagPtr[idx] = 0.0
        }
        for idx in n..<fftLength {
            fftRealPtr[idx] = 0.0
            fftImagPtr[idx] = 0.0
        }

        // Zero-padded Marple FFT analytic signal projection (no circular wrap-around)
        computeAnalyticSignalFromPreloadedFFTBuffer()

        let bins = freqBins
        let invBins = 1.0 / Double(bins)
        let fs = sampleRate
        let halfFs = 0.5 * fs
        let freqScaleHz = fs / Double(2 * bins)
        let maxLag = maxLagSamples
        let halfU = halfTimeWindowSamples
        let gCount = gKernelCount
        let strideLag = lagStride

        var sumSignedP: Double = 0.0
        var sumSignedP3: Double = 0.0
        var sumPositiveP: Double = 0.0
        var sumPositiveP3: Double = 0.0
        var spindleBandEnergy: Double = 0.0

        var rawTotalEnergySq: Double = 0.0
        var rawNegativeEnergySq: Double = 0.0
        var smoothTotalEnergySq: Double = 0.0
        var smoothNegativeEnergySq: Double = 0.0

        for timeIdx in 0..<n {
            let distFromEnd = n - 1 - timeIdx
            let edgeBound = timeIdx < distFromEnd ? timeIdx : distFromEnd
            let localMaxLag = maxLag < edgeBound ? maxLag : edgeBound
            let lagRowBase = localMaxLag * strideLag

            for tau in 0...localMaxLag {
                // Unsmoothed pseudo-WVD reference autocorrelation at u = 0
                let centerPlus = timeIdx + tau
                let centerMinus = timeIdx - tau
                let zpRe = analyticRePtr[centerPlus]
                let zpIm = analyticImPtr[centerPlus]
                let zmRe = analyticRePtr[centerMinus]
                let zmIm = analyticImPtr[centerMinus]
                rRawRePtr[tau] = zpRe * zmRe + zpIm * zmIm
                rRawImPtr[tau] = zpIm * zmRe - zpRe * zmIm

                // Separable Doppler-time smoothed autocorrelation across u in -halfU...halfU
                var accRe: Double = 0.0
                var accIm: Double = 0.0
                var weightNorm: Double = 0.0

                for gIdx in 0..<gCount {
                    let u = gIdx - halfU
                    let m = timeIdx - u
                    let iPlus = m + tau
                    let iMinus = m - tau
                    if iPlus >= 0 && iPlus < n && iMinus >= 0 && iMinus < n {
                        let gw = gKernelPtr[gIdx]
                        let aRe = analyticRePtr[iPlus]
                        let aIm = analyticImPtr[iPlus]
                        let bRe = analyticRePtr[iMinus]
                        let bIm = analyticImPtr[iMinus]
                        let prodRe = aRe * bRe + aIm * bIm
                        let prodIm = aIm * bRe - aRe * bIm
                        accRe += gw * prodRe
                        accIm += gw * prodIm
                        weightNorm += gw
                    }
                }

                if weightNorm > 1e-12 {
                    let hWeight = lagWindowTablePtr[lagRowBase + tau]
                    let scale = hWeight / weightNorm
                    rSmoothRePtr[tau] = accRe * scale
                    rSmoothImPtr[tau] = accIm * scale
                } else {
                    rSmoothRePtr[tau] = 0.0
                    rSmoothImPtr[tau] = 0.0
                }
            }

            var peakBin: Int = 0
            var peakVal: Double = -Double.greatestFiniteMagnitude
            let tfrRowBase = timeIdx * bins

            for k in 0..<bins {
                var valSmooth = rSmoothRePtr[0]
                var valRaw = rRawRePtr[0]
                let trigRowBase = k * strideLag

                if localMaxLag >= 1 {
                    for tau in 1...localMaxLag {
                        let cVal = cosTablePtr[trigRowBase + tau]
                        let sVal = sinTablePtr[trigRowBase + tau]
                        let smoothTerm = rSmoothRePtr[tau] * cVal + rSmoothImPtr[tau] * sVal
                        let rawTerm = rRawRePtr[tau] * cVal + rRawImPtr[tau] * sVal
                        valSmooth += 2.0 * smoothTerm
                        valRaw += 2.0 * rawTerm
                    }
                }

                // Normalize by 1 / freqBins so discrete time marginal sum_k W[n, k] == R_smooth[n, 0]
                let scaledSmooth = valSmooth * invBins
                let scaledRaw = valRaw * invBins

                sliceBufferPtr[k] = scaledSmooth
                tfrBufferPtr[tfrRowBase + k] = Float(scaledSmooth)

                if scaledSmooth > peakVal {
                    peakVal = scaledSmooth
                    peakBin = k
                }

                sumSignedP += scaledSmooth
                let scaledSmoothSq = scaledSmooth * scaledSmooth
                sumSignedP3 += scaledSmoothSq * scaledSmooth

                let posP = scaledSmooth > 0.0 ? scaledSmooth : 0.0
                sumPositiveP += posP
                sumPositiveP3 += posP * posP * posP

                let binFreqHz = Double(k) * freqScaleHz
                if binFreqHz >= Self.spindleBandLowHz && binFreqHz <= Self.spindleBandHighHz {
                    spindleBandEnergy += posP
                }

                smoothTotalEnergySq += scaledSmoothSq
                if scaledSmooth < 0.0 {
                    smoothNegativeEnergySq += scaledSmoothSq
                }

                let scaledRawSq = scaledRaw * scaledRaw
                rawTotalEnergySq += scaledRawSq
                if scaledRaw < 0.0 {
                    rawNegativeEnergySq += scaledRawSq
                }
            }

            // Sub-bin parabolic ridge interpolation
            var refinedBin = Double(peakBin)
            if peakBin > 0 && peakBin + 1 < bins {
                let yL = sliceBufferPtr[peakBin - 1]
                let yC = sliceBufferPtr[peakBin]
                let yR = sliceBufferPtr[peakBin + 1]
                let denom = yL - 2.0 * yC + yR
                if abs(denom) > 1e-12 && yC >= yL && yC >= yR {
                    let rawDelta = 0.5 * (yL - yR) / denom
                    let clampedDelta = min(max(rawDelta, -0.5), 0.5)
                    refinedBin += clampedDelta
                }
            }
            let rawFreqHz = refinedBin * freqScaleHz
            let clampedFreqHz = min(max(rawFreqHz, 0.0), halfFs)
            ridgeBufferPtr[timeIdx] = Float(clampedFreqHz)
        }

        // Normalized Order-3 Rényi entropy R_3 = -0.5 * log2( sum(P^3) / (sum(P))^3 )
        // Uses signed quasi-probability integral when valid, with positive-part fallback for degenerate blocks.
        let renyiBits: Float
        let signedDenom = sumSignedP * sumSignedP * sumSignedP
        let signedRatio = signedDenom > 1e-30 ? (sumSignedP3 / signedDenom) : 0.0
        if sumSignedP > 1e-15 && signedRatio > 1e-30 && signedRatio <= 1.0 && signedRatio.isFinite {
            renyiBits = Float(max(0.0, -0.5 * log2(signedRatio)))
        } else if sumPositiveP > 1e-15 && sumPositiveP3 > 1e-30 {
            let posDenom = sumPositiveP * sumPositiveP * sumPositiveP
            let posRatio = min(max(sumPositiveP3 / posDenom, 1e-30), 1.0)
            renyiBits = Float(max(0.0, -0.5 * log2(posRatio)))
        } else {
            renyiBits = 0.0
        }

        let spindleRatio: Float
        if sumPositiveP > 1e-15 {
            let rawRatio = spindleBandEnergy / sumPositiveP
            spindleRatio = Float(min(max(rawRatio, 0.0), 1.0))
        } else {
            spindleRatio = 0.0
        }

        // Cross-term oscillatory negativity suppression (dB) relative to unsmoothed pseudo-WVD
        let suppressionDB: Float
        let isUnsmoothedMode = useRectangularLagWindow && timeSigmaSamples <= 0.0
        let rawNegRatio = rawTotalEnergySq > 1e-30 ? (rawNegativeEnergySq / rawTotalEnergySq) : 0.0
        let smoothNegRatio = smoothTotalEnergySq > 1e-30 ? (smoothNegativeEnergySq / smoothTotalEnergySq) : 0.0
        if isUnsmoothedMode || rawNegRatio <= 1e-12 {
            suppressionDB = 0.0
        } else if smoothNegRatio <= rawNegRatio * 1e-6 {
            suppressionDB = Float(Self.maximumSuppressionDB)
        } else {
            let dbVal = 10.0 * log10(rawNegRatio / smoothNegRatio)
            let clampedDB = min(Self.maximumSuppressionDB, max(0.0, dbVal))
            suppressionDB = Float(clampedDB)
        }

        latestRenyiEntropyBits = renyiBits
        latestCorticalSpindlePowerRatio = spindleRatio
        latestCrossTermSuppressionDB = suppressionDB
        processedBlockCount &+= 1
        return true
    }

    /// Materializes a Sendable `SPWVDResult` copy from the current workspace state (for UI / non-RT callers).
    public func snapshotResult() -> SPWVDResult {
        var matrix: [[Float]] = []
        matrix.reserveCapacity(blockSize)
        for timeIdx in 0..<blockSize {
            let rowStart = tfrBufferPtr.advanced(by: timeIdx * freqBins)
            let rowArray = Array(UnsafeBufferPointer(start: rowStart, count: freqBins))
            matrix.append(rowArray)
        }
        let ridgeArray = Array(UnsafeBufferPointer(start: ridgeBufferPtr, count: blockSize))
        return SPWVDResult(
            timeSteps: blockSize,
            freqBins: freqBins,
            tfrMatrix: matrix,
            instantaneousFreqRidgeHz: ridgeArray,
            renyiEntropyBits: latestRenyiEntropyBits,
            corticalSpindlePowerRatio: latestCorticalSpindlePowerRatio,
            crossTermSuppressionDB: latestCrossTermSuppressionDB
        )
    }

    private func computeAnalyticSignalFromPreloadedFFTBuffer() {
        runPrecomputedRadix2FFTInPlace(inverse: false)
        for k in 0..<fftLength {
            let gain = hilbertGainPtr[k]
            fftRealPtr[k] *= gain
            fftImagPtr[k] *= gain
        }
        runPrecomputedRadix2FFTInPlace(inverse: true)
        for idx in 0..<blockSize {
            analyticRePtr[idx] = fftRealPtr[idx]
            analyticImPtr[idx] = fftImagPtr[idx]
        }
    }

    private func runPrecomputedRadix2FFTInPlace(inverse: Bool) {
        let m = fftLength
        for i in 0..<m {
            let rev = fftBitRevPtr[i]
            if i < rev {
                let tmpRe = fftRealPtr[i]
                let tmpIm = fftImagPtr[i]
                fftRealPtr[i] = fftRealPtr[rev]
                fftImagPtr[i] = fftImagPtr[rev]
                fftRealPtr[rev] = tmpRe
                fftImagPtr[rev] = tmpIm
            }
        }

        let imagSign: Double = inverse ? -1.0 : 1.0
        var half = 1
        while half < m {
            let step = half << 1
            var start = 0
            while start < m {
                for k in 0..<half {
                    let twIdx = half + k
                    let wRe = fftTwiddleRePtr[twIdx]
                    let wIm = imagSign * fftTwiddleImPtr[twIdx]
                    let i0 = start + k
                    let i1 = i0 + half
                    let uRe = fftRealPtr[i0]
                    let uIm = fftImagPtr[i0]
                    let x1Re = fftRealPtr[i1]
                    let x1Im = fftImagPtr[i1]
                    let vRe = x1Re * wRe - x1Im * wIm
                    let vIm = x1Re * wIm + x1Im * wRe
                    fftRealPtr[i0] = uRe + vRe
                    fftImagPtr[i0] = uIm + vIm
                    fftRealPtr[i1] = uRe - vRe
                    fftImagPtr[i1] = uIm - vIm
                }
                start += step
            }
            half <<= 1
        }
    }

    internal static func nextPowerOfTwo(_ value: Int) -> Int {
        var p = 1
        while p < value {
            p <<= 1
        }
        return p
    }

    private static func precomputeFFTTables(
        fftLength: Int,
        bitRevPtr: UnsafeMutablePointer<Int>,
        twiddleRePtr: UnsafeMutablePointer<Double>,
        twiddleImPtr: UnsafeMutablePointer<Double>,
        hilbertGainPtr: UnsafeMutablePointer<Double>
    ) {
        bitRevPtr[0] = 0
        var j = 0
        for i in 1..<fftLength {
            var bit = fftLength >> 1
            while (j & bit) != 0 {
                j ^= bit
                bit >>= 1
            }
            j ^= bit
            bitRevPtr[i] = j
        }

        var half = 1
        while half < fftLength {
            let step = half << 1
            let angleScale = -2.0 * Double.pi / Double(step)
            for k in 0..<half {
                let angle = angleScale * Double(k)
                twiddleRePtr[half + k] = cos(angle)
                twiddleImPtr[half + k] = sin(angle)
            }
            half <<= 1
        }

        let invM = 1.0 / Double(fftLength)
        let halfM = fftLength / 2
        hilbertGainPtr[0] = invM
        for k in 1..<halfM {
            hilbertGainPtr[k] = 2.0 * invM
        }
        hilbertGainPtr[halfM] = invM
        for k in (halfM + 1)..<fftLength {
            hilbertGainPtr[k] = 0.0
        }
    }

    private static func precomputeSmoothingAndBasisTables(
        freqBins: Int,
        halfTimeWin: Int,
        sigma: Double,
        maxLag: Int,
        lagStride: Int,
        useRectangularLag: Bool,
        gKernelPtr: UnsafeMutablePointer<Double>,
        lagWindowTablePtr: UnsafeMutablePointer<Double>,
        cosTablePtr: UnsafeMutablePointer<Double>,
        sinTablePtr: UnsafeMutablePointer<Double>
    ) {
        let gCount = 2 * halfTimeWin + 1
        if halfTimeWin == 0 || sigma <= 0.0 {
            gKernelPtr[0] = 1.0
        } else {
            var gSum: Double = 0.0
            let invTwoSigmaSq = 0.5 / (sigma * sigma)
            for idx in 0..<gCount {
                let u = Double(idx - halfTimeWin)
                let w = exp(-(u * u) * invTwoSigmaSq)
                gKernelPtr[idx] = w
                gSum += w
            }
            let norm = max(1e-12, gSum)
            for idx in 0..<gCount {
                gKernelPtr[idx] /= norm
            }
        }

        for localMaxLag in 0...maxLag {
            let rowBase = localMaxLag * lagStride
            let denom = Double(localMaxLag + 1)
            for tau in 0...localMaxLag {
                if useRectangularLag {
                    lagWindowTablePtr[rowBase + tau] = 1.0
                } else {
                    let phase = Double.pi * Double(tau) / denom
                    lagWindowTablePtr[rowBase + tau] = 0.5 * (1.0 + cos(phase))
                }
            }
        }

        let twoPiOverBins = 2.0 * Double.pi / Double(freqBins)
        for k in 0..<freqBins {
            let rowBase = k * lagStride
            for tau in 0...maxLag {
                let angle = twoPiOverBins * Double(k * tau)
                cosTablePtr[rowBase + tau] = cos(angle)
                sinTablePtr[rowBase + tau] = sin(angle)
            }
        }
    }
}

public enum SPWVDAnalyzer: Sendable {
    public static let canonicalBlockSize: Int = 128
    /// Default Gaussian time-smoothing standard deviation in samples (`sigma = 6.0` yields >=20 dB cross-term suppression).
    public static let defaultTimeSigmaSamples: Double = 6.0

    public struct ComplexSample: Sendable, Equatable {
        public var real: Double
        public var imag: Double

        public init(real: Double, imag: Double) {
            self.real = real
            self.imag = imag
        }

        @inline(__always)
        public var conjugate: ComplexSample {
            ComplexSample(real: real, imag: -imag)
        }

        @inline(__always)
        public static func + (lhs: ComplexSample, rhs: ComplexSample) -> ComplexSample {
            ComplexSample(real: lhs.real + rhs.real, imag: lhs.imag + rhs.imag)
        }

        @inline(__always)
        public static func - (lhs: ComplexSample, rhs: ComplexSample) -> ComplexSample {
            ComplexSample(real: lhs.real - rhs.real, imag: lhs.imag - rhs.imag)
        }

        @inline(__always)
        public static func * (lhs: ComplexSample, rhs: ComplexSample) -> ComplexSample {
            ComplexSample(
                real: lhs.real * rhs.real - lhs.imag * rhs.imag,
                imag: lhs.real * rhs.imag + lhs.imag * rhs.real
            )
        }
    }

    /// Computes the discrete analytic signal `z[n] = x[n] + j * Hilbert(x[n])` via zero-padded Radix-2 FFT
    /// (preventing circular convolution wrap-around at block boundaries) or exact circular DFT when `zeroPadded == false`.
    public static func computeAnalyticSignal(
        _ signal: [Float],
        zeroPadded: Bool = true
    ) -> [ComplexSample] {
        let n = signal.count
        guard n > 0 else { return [] }
        guard n >= 2 else {
            let s0 = signal[0].isFinite ? Double(signal[0]) : 0.0
            return [ComplexSample(real: s0, imag: 0.0)]
        }

        let x = signal.map { $0.isFinite ? Double($0) : 0.0 }

        if zeroPadded {
            let m = RealtimeSPWVDEngine.nextPowerOfTwo(max(4, 2 * n))
            var spectrum = [ComplexSample](repeating: ComplexSample(real: 0.0, imag: 0.0), count: m)
            for idx in 0..<n {
                spectrum[idx].real = x[idx]
            }
            radix2FFT(&spectrum, inverse: false)
            applyHilbertFrequencyMask(&spectrum)
            radix2FFT(&spectrum, inverse: true)
            return Array(spectrum.prefix(n))
        }

        // Unpadded circular Hilbert transform path
        if (n & (n - 1)) == 0 {
            var spectrum = x.map { ComplexSample(real: $0, imag: 0.0) }
            radix2FFT(&spectrum, inverse: false)
            applyHilbertFrequencyMask(&spectrum)
            radix2FFT(&spectrum, inverse: true)
            return spectrum
        } else {
            var spectrum = [ComplexSample](repeating: ComplexSample(real: 0.0, imag: 0.0), count: n)
            let twoPiOverN = 2.0 * Double.pi / Double(n)
            for k in 0..<n {
                var re = 0.0
                var im = 0.0
                for m in 0..<n {
                    let angle = twoPiOverN * Double(k * m)
                    re += x[m] * cos(angle)
                    im -= x[m] * sin(angle)
                }
                spectrum[k] = ComplexSample(real: re, imag: im)
            }

            applyHilbertFrequencyMask(&spectrum)

            var analytic = [ComplexSample](repeating: ComplexSample(real: 0.0, imag: 0.0), count: n)
            let invN = 1.0 / Double(n)
            for m in 0..<n {
                var re = 0.0
                var im = 0.0
                for k in 0..<n {
                    let angle = twoPiOverN * Double(k * m)
                    let c = cos(angle)
                    let s = sin(angle)
                    re += spectrum[k].real * c - spectrum[k].imag * s
                    im += spectrum[k].real * s + spectrum[k].imag * c
                }
                analytic[m] = ComplexSample(real: re * invN, imag: im * invN)
            }
            return analytic
        }
    }

    /// Evaluates the Smoothed Pseudo Wigner-Ville Distribution `W_z[n, k]` with Gaussian time-smoothing
    /// and Hann lag-windowing, extracts the instantaneous frequency ridge in Hz, and computes Order-3 Rényi entropy.
    public static func analyze(
        signal: [Float],
        sampleRate: Double = 256.0,
        freqBins: Int = 64,
        halfLagL: Int,
        halfTimeM: Int
    ) -> SPWVDResult {
        analyze(
            signal: signal,
            sampleRate: sampleRate,
            freqBins: freqBins,
            timeSigmaSamples: Double(max(1, halfTimeM)) * 0.5,
            maxLagSamples: halfLagL
        )
    }

    public static func analyze(
        signal: [Float],
        sampleRate: Double = 256.0,
        freqBins: Int = 64,
        timeSigmaSamples: Double = defaultTimeSigmaSamples,
        maxLagSamples: Int? = nil,
        useRectangularLagWindow: Bool = false
    ) -> SPWVDResult {
        let n = signal.count
        let bins = max(8, freqBins)
        let fs = max(1.0, sampleRate)

        guard n >= 4 else {
            let emptyMatrix = [[Float]](repeating: [Float](repeating: 0.0, count: bins), count: max(0, n))
            return SPWVDResult(
                timeSteps: n,
                freqBins: bins,
                tfrMatrix: emptyMatrix,
                instantaneousFreqRidgeHz: [Float](repeating: 0.0, count: max(0, n)),
                renyiEntropyBits: 0.0,
                corticalSpindlePowerRatio: 0.0,
                crossTermSuppressionDB: 0.0
            )
        }

        let engine = RealtimeSPWVDEngine(
            blockSize: n,
            sampleRate: fs,
            freqBins: bins,
            timeSigmaSamples: timeSigmaSamples,
            maxLagSamples: maxLagSamples,
            useRectangularLagWindow: useRectangularLagWindow
        )
        signal.withUnsafeBufferPointer { buf in
            _ = engine.processRealtimeBlock(buf)
        }
        return engine.snapshotResult()
    }

    private static func applyHilbertFrequencyMask(_ spectrum: inout [ComplexSample]) {
        let n = spectrum.count
        guard n >= 2 else { return }
        if n % 2 == 0 {
            let half = n / 2
            for k in 1..<half {
                spectrum[k].real *= 2.0
                spectrum[k].imag *= 2.0
            }
            for k in (half + 1)..<n {
                spectrum[k] = ComplexSample(real: 0.0, imag: 0.0)
            }
        } else {
            let lastPos = (n - 1) / 2
            for k in 1...lastPos {
                spectrum[k].real *= 2.0
                spectrum[k].imag *= 2.0
            }
            for k in (lastPos + 1)..<n {
                spectrum[k] = ComplexSample(real: 0.0, imag: 0.0)
            }
        }
    }

    private static func radix2FFT(_ buffer: inout [ComplexSample], inverse: Bool) {
        let n = buffer.count
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
                buffer.swapAt(i, j)
            }
        }

        var len = 2
        let sign = inverse ? 1.0 : -1.0
        while len <= n {
            let half = len >> 1
            let angle = sign * 2.0 * Double.pi / Double(len)
            let wStep = ComplexSample(real: cos(angle), imag: sin(angle))
            for start in stride(from: 0, to: n, by: len) {
                var w = ComplexSample(real: 1.0, imag: 0.0)
                for k in 0..<half {
                    let u = buffer[start + k]
                    let v = buffer[start + k + half] * w
                    buffer[start + k] = u + v
                    buffer[start + k + half] = u - v
                    w = w * wStep
                }
            }
            len <<= 1
        }

        if inverse {
            let invN = 1.0 / Double(n)
            for idx in 0..<n {
                buffer[idx].real *= invN
                buffer[idx].imag *= invN
            }
        }
    }
}

// MARK: - 2. Hilbert-Huang Empirical Mode Decomposition (Thomas O(N) Natural Cubic Spline Sifter)

public struct IMFAnalytics: Sendable, Equatable {
    public let imfIndex: Int
    public let samples: [Float]
    public let instantaneousPhaseRad: [Float]
    public let instantaneousFrequencyHz: [Float]
    public let instantaneousEnergy: [Float]
    public let meanFrequencyHz: Float
    public let totalEnergy: Float

    public init(
        imfIndex: Int,
        samples: [Float],
        instantaneousPhaseRad: [Float],
        instantaneousFrequencyHz: [Float],
        instantaneousEnergy: [Float],
        meanFrequencyHz: Float,
        totalEnergy: Float
    ) {
        self.imfIndex = imfIndex
        self.samples = samples
        self.instantaneousPhaseRad = instantaneousPhaseRad
        self.instantaneousFrequencyHz = instantaneousFrequencyHz
        self.instantaneousEnergy = instantaneousEnergy
        self.meanFrequencyHz = meanFrequencyHz
        self.totalEnergy = totalEnergy
    }
}

public struct HilbertHuangResult: Sendable, Equatable {
    public let imfs: [[Float]]
    public let residual: [Float]
    public let maxReconstructionError: Float
    public let imfAnalytics: [IMFAnalytics]
    public let orthogonalityIndex: Float

    public init(
        imfs: [[Float]],
        residual: [Float],
        maxReconstructionError: Float,
        imfAnalytics: [IMFAnalytics] = [],
        orthogonalityIndex: Float = 0.0
    ) {
        self.imfs = imfs
        self.residual = residual
        self.maxReconstructionError = maxReconstructionError
        self.imfAnalytics = imfAnalytics
        self.orthogonalityIndex = orthogonalityIndex
    }
}

public enum HilbertHuangSifter: Sendable {
    /// Decomposes an arbitrary non-stationary signal into Intrinsic Mode Functions (`imfs`) and a monotonic/slow
    /// `residual` via Empirical Mode Decomposition with Thomas-algorithm O(N) natural cubic spline envelopes.
    /// Guarantees `sum(imfs) + residual == signal` within `< 1e-5` floating-point precision, and evaluates
    /// per-IMF Hilbert instantaneous phase `phi_k[n]`, unwrapped frequency `omega_k[n]`, and energy `A_k^2[n]`.
    /// Note: Variable-knot EMD sifting is an offline/background telemetry transform; use `RealtimeSPWVDEngine` on real-time audio threads.
    public static func sift(
        signal: [Float],
        sampleRate: Double = 256.0,
        maxIMFs: Int = 4,
        maxSiftIterations: Int = 12,
        cauchyConvergenceThreshold: Double = 0.05
    ) -> HilbertHuangResult {
        let n = signal.count
        let sanitized = signal.map { $0.isFinite ? $0 : 0.0 }
        guard n >= 4, maxIMFs > 0 else {
            return HilbertHuangResult(
                imfs: [],
                residual: sanitized,
                maxReconstructionError: 0.0,
                imfAnalytics: [],
                orthogonalityIndex: 0.0
            )
        }

        let siftLimit = max(1, maxSiftIterations)
        let cauchyTol = min(max(1e-6, cauchyConvergenceThreshold), 0.5)
        var runningResidual = sanitized.map(Double.init)
        var extractedIMFs: [[Float]] = []
        extractedIMFs.reserveCapacity(maxIMFs)

        for _ in 0..<maxIMFs {
            let initialExtrema = detectLocalExtrema(in: runningResidual)
            // Stop sifting once residual has fewer than 2 interior maxima or minima (monotonic/trend)
            if initialExtrema.maxIndices.count < 2 || initialExtrema.minIndices.count < 2 {
                break
            }

            var protoIMF = runningResidual
            for _ in 0..<siftLimit {
                let extrema = detectLocalExtrema(in: protoIMF)
                if extrema.maxIndices.count < 1 || extrema.minIndices.count < 1 {
                    break
                }

                let upperKnots = buildBoundaryAnchoredKnots(
                    signal: protoIMF,
                    extremaIndices: extrema.maxIndices,
                    isUpper: true
                )
                let lowerKnots = buildBoundaryAnchoredKnots(
                    signal: protoIMF,
                    extremaIndices: extrema.minIndices,
                    isUpper: false
                )

                let upperEnv = evaluateNaturalCubicSpline(
                    knotX: upperKnots.xs,
                    knotY: upperKnots.ys,
                    sampleCount: n
                )
                let lowerEnv = evaluateNaturalCubicSpline(
                    knotX: lowerKnots.xs,
                    knotY: lowerKnots.ys,
                    sampleCount: n
                )

                var nextProto = [Double](repeating: 0.0, count: n)
                var diffSq = 0.0
                var prevSq = 0.0

                for i in 0..<n {
                    let meanEnv = 0.5 * (upperEnv[i] + lowerEnv[i])
                    let updated = protoIMF[i] - meanEnv
                    let d = protoIMF[i] - updated
                    diffSq += d * d
                    prevSq += protoIMF[i] * protoIMF[i]
                    nextProto[i] = updated
                }

                protoIMF = nextProto
                let cauchySD = diffSq / max(1e-15, prevSq)
                if cauchySD < cauchyTol && satisfiesIMFZeroCrossingCondition(protoIMF) {
                    break
                }
            }

            let imfFloat = protoIMF.map(Float.init)
            extractedIMFs.append(imfFloat)

            // Subtract exact Float32 IMF representation so Float32 sum(imfs) + residual matches signal to ~1e-7
            for i in 0..<n {
                runningResidual[i] -= Double(imfFloat[i])
            }
        }

        let residualFloat = runningResidual.map(Float.init)
        var maxError: Float = 0.0
        for i in 0..<n {
            var sumSample = residualFloat[i]
            for imf in extractedIMFs {
                sumSample += imf[i]
            }
            let err = abs(sumSample - sanitized[i])
            if err > maxError {
                maxError = err
            }
        }

        let fs = max(1.0, sampleRate)
        let analytics = extractedIMFs.enumerated().map { idx, imf in
            computeIMFAnalytics(imfIndex: idx, imf: imf, sampleRate: fs)
        }
        let orthoIdx = computeOrthogonalityIndex(imfs: extractedIMFs, signal: sanitized)

        return HilbertHuangResult(
            imfs: extractedIMFs,
            residual: residualFloat,
            maxReconstructionError: maxError,
            imfAnalytics: analytics,
            orthogonalityIndex: orthoIdx
        )
    }

    private static func computeIMFAnalytics(
        imfIndex: Int,
        imf: [Float],
        sampleRate: Double
    ) -> IMFAnalytics {
        let n = imf.count
        let analytic = SPWVDAnalyzer.computeAnalyticSignal(imf)
        var phases = [Float](repeating: 0.0, count: n)
        var freqs = [Float](repeating: 0.0, count: n)
        var energies = [Float](repeating: 0.0, count: n)

        let scaleHz = sampleRate / (2.0 * Double.pi)
        let nyquist = 0.5 * sampleRate
        var prevPhase = 0.0
        var weightedFreqSum = 0.0
        var totalEnergy = 0.0

        for i in 0..<n {
            let z = analytic[i]
            let phase = atan2(z.imag, z.real)
            let energy = z.real * z.real + z.imag * z.imag
            phases[i] = Float(phase)
            energies[i] = Float(energy)
            totalEnergy += energy

            if i > 0 {
                let dPhi = atan2(sin(phase - prevPhase), cos(phase - prevPhase))
                let instHz = min(max(abs(dPhi * scaleHz), 0.0), nyquist)
                freqs[i] = Float(instHz)
                weightedFreqSum += instHz * energy
            }
            prevPhase = phase
        }
        if n > 1 {
            freqs[0] = freqs[1]
            weightedFreqSum += Double(freqs[0]) * Double(energies[0])
        }

        let meanFreq = totalEnergy > 1e-12 ? Float(weightedFreqSum / totalEnergy) : 0.0
        return IMFAnalytics(
            imfIndex: imfIndex,
            samples: imf,
            instantaneousPhaseRad: phases,
            instantaneousFrequencyHz: freqs,
            instantaneousEnergy: energies,
            meanFrequencyHz: meanFreq,
            totalEnergy: Float(totalEnergy)
        )
    }

    private static func computeOrthogonalityIndex(imfs: [[Float]], signal: [Float]) -> Float {
        guard imfs.count >= 2 else { return 0.0 }
        let n = signal.count
        var sigEnergy = 0.0
        for s in signal {
            sigEnergy += Double(s) * Double(s)
        }
        guard sigEnergy > 1e-12 else { return 0.0 }

        var crossSum = 0.0
        for j in 0..<imfs.count {
            for k in (j + 1)..<imfs.count {
                var dot = 0.0
                for i in 0..<n {
                    dot += Double(imfs[j][i]) * Double(imfs[k][i])
                }
                crossSum += abs(dot)
            }
        }
        return Float(crossSum / sigEnergy)
    }

    /// Exact O(N) Thomas-algorithm tridiagonal solver & evaluator for natural cubic spline (`S''(x_0) = S''(x_{K-1}) = 0`).
    public static func evaluateNaturalCubicSpline(
        knotX: [Double],
        knotY: [Double],
        sampleCount: Int
    ) -> [Double] {
        guard sampleCount > 0 else { return [] }
        let kCount = min(knotX.count, knotY.count)
        guard kCount >= 2 else {
            let fill = knotY.first ?? 0.0
            return [Double](repeating: fill, count: sampleCount)
        }

        if kCount == 2 {
            let x0 = knotX[0]
            let x1 = knotX[1]
            let span = max(1e-9, x1 - x0)
            let slope = (knotY[1] - knotY[0]) / span
            return (0..<sampleCount).map { i in
                knotY[0] + slope * (Double(i) - x0)
            }
        }

        let segCount = kCount - 1
        var h = [Double](repeating: 1.0, count: segCount)
        for i in 0..<segCount {
            h[i] = max(1e-9, knotX[i + 1] - knotX[i])
        }

        // Natural spline boundary conditions: second derivatives m[0] = 0, m[kCount - 1] = 0.
        // Interior unknowns m[1 ... kCount - 2] (count = mLen = kCount - 2):
        let mLen = kCount - 2
        var secondDeriv = [Double](repeating: 0.0, count: kCount)

        if mLen == 1 {
            let diag = 2.0 * (h[0] + h[1])
            let rhs = 6.0 * ((knotY[2] - knotY[1]) / h[1] - (knotY[1] - knotY[0]) / h[0])
            secondDeriv[1] = rhs / max(1e-12, diag)
        } else {
            var subDiag = [Double](repeating: 0.0, count: mLen)
            var mainDiag = [Double](repeating: 0.0, count: mLen)
            var supDiag = [Double](repeating: 0.0, count: mLen)
            var rhs = [Double](repeating: 0.0, count: mLen)

            for idx in 0..<mLen {
                let knotIdx = idx + 1
                let hPrev = h[knotIdx - 1]
                let hNext = h[knotIdx]
                subDiag[idx] = idx > 0 ? hPrev : 0.0
                mainDiag[idx] = 2.0 * (hPrev + hNext)
                supDiag[idx] = idx + 1 < mLen ? hNext : 0.0
                rhs[idx] = 6.0 * (
                    (knotY[knotIdx + 1] - knotY[knotIdx]) / hNext
                    - (knotY[knotIdx] - knotY[knotIdx - 1]) / hPrev
                )
            }

            // Thomas O(K) forward elimination
            for idx in 1..<mLen {
                let factor = subDiag[idx] / mainDiag[idx - 1]
                mainDiag[idx] -= factor * supDiag[idx - 1]
                rhs[idx] -= factor * rhs[idx - 1]
            }

            // Thomas O(K) back substitution
            secondDeriv[mLen] = rhs[mLen - 1] / mainDiag[mLen - 1]
            for idx in stride(from: mLen - 2, through: 0, by: -1) {
                secondDeriv[idx + 1] = (rhs[idx] - supDiag[idx] * secondDeriv[idx + 2]) / mainDiag[idx]
            }
        }

        // Evaluate piecewise cubic polynomial across integer sample indices 0 ..< sampleCount
        var output = [Double](repeating: 0.0, count: sampleCount)
        var seg = 0
        for sampleIdx in 0..<sampleCount {
            let x = Double(sampleIdx)
            while seg + 1 < segCount && x > knotX[seg + 1] {
                seg += 1
            }
            let xL = knotX[seg]
            let xR = knotX[seg + 1]
            let hi = h[seg]
            let a = (xR - x) / hi
            let b = (x - xL) / hi
            let cubicTermL = (a * a * a - a) * (hi * hi) / 6.0
            let cubicTermR = (b * b * b - b) * (hi * hi) / 6.0
            output[sampleIdx] = a * knotY[seg] + b * knotY[seg + 1]
                + cubicTermL * secondDeriv[seg] + cubicTermR * secondDeriv[seg + 1]
        }

        return output
    }

    private static func detectLocalExtrema(in signal: [Double]) -> (maxIndices: [Int], minIndices: [Int]) {
        let n = signal.count
        guard n >= 3 else { return ([], []) }

        var maxIndices: [Int] = []
        var minIndices: [Int] = []

        for i in 1..<(n - 1) {
            let prev = signal[i - 1]
            let curr = signal[i]
            let next = signal[i + 1]
            if curr > prev && curr >= next {
                maxIndices.append(i)
            } else if curr < prev && curr <= next {
                minIndices.append(i)
            }
        }
        return (maxIndices, minIndices)
    }

    private static func buildBoundaryAnchoredKnots(
        signal: [Double],
        extremaIndices: [Int],
        isUpper: Bool
    ) -> (xs: [Double], ys: [Double]) {
        let lastIdx = signal.count - 1
        var xs: [Double] = []
        var ys: [Double] = []
        xs.reserveCapacity(extremaIndices.count + 2)
        ys.reserveCapacity(extremaIndices.count + 2)

        // Left boundary anchor at x = 0
        let leftAnchorY: Double
        if extremaIndices.count >= 2 {
            let x1 = Double(extremaIndices[0])
            let x2 = Double(extremaIndices[1])
            let y1 = signal[extremaIndices[0]]
            let y2 = signal[extremaIndices[1]]
            let extrap = y1 - x1 * (y2 - y1) / max(1.0, x2 - x1)
            leftAnchorY = isUpper ? max(signal[0], min(extrap, max(y1, y2))) : min(signal[0], max(extrap, min(y1, y2)))
        } else if let only = extremaIndices.first {
            leftAnchorY = isUpper ? max(signal[0], signal[only]) : min(signal[0], signal[only])
        } else {
            leftAnchorY = signal[0]
        }

        xs.append(0.0)
        ys.append(leftAnchorY)

        for idx in extremaIndices where idx > 0 && idx < lastIdx {
            xs.append(Double(idx))
            ys.append(signal[idx])
        }

        // Right boundary anchor at x = N - 1
        let rightAnchorY: Double
        if extremaIndices.count >= 2 {
            let k = extremaIndices.count
            let x1 = Double(extremaIndices[k - 2])
            let x2 = Double(extremaIndices[k - 1])
            let y1 = signal[extremaIndices[k - 2]]
            let y2 = signal[extremaIndices[k - 1]]
            let extrap = y2 + (Double(lastIdx) - x2) * (y2 - y1) / max(1.0, x2 - x1)
            rightAnchorY = isUpper
                ? max(signal[lastIdx], min(extrap, max(y1, y2)))
                : min(signal[lastIdx], max(extrap, min(y1, y2)))
        } else if let only = extremaIndices.last {
            rightAnchorY = isUpper ? max(signal[lastIdx], signal[only]) : min(signal[lastIdx], signal[only])
        } else {
            rightAnchorY = signal[lastIdx]
        }

        xs.append(Double(lastIdx))
        ys.append(rightAnchorY)

        return (xs, ys)
    }

    private static func satisfiesIMFZeroCrossingCondition(_ x: [Double]) -> Bool {
        let extrema = detectLocalExtrema(in: x)
        let totalExtrema = extrema.maxIndices.count + extrema.minIndices.count
        var zeroCrossings = 0
        for i in 0..<(x.count - 1) {
            if (x[i] <= 0.0 && x[i + 1] > 0.0) || (x[i] >= 0.0 && x[i + 1] < 0.0) {
                zeroCrossings += 1
            }
        }
        return abs(totalExtrema - zeroCrossings) <= 1
    }
}
