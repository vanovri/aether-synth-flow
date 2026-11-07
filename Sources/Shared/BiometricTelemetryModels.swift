// MARK: - FILE: BiometricTelemetryModels.swift

import Foundation

// MARK: - 1. Beat-to-Beat RR Interval DTO & Time-Comparison Bridge

@inlinable
public func < (lhs: TimeInterval, rhs: Date) -> Bool {
    lhs < rhs.timeIntervalSince1970
}

@inlinable
public func < (lhs: Date, rhs: TimeInterval) -> Bool {
    lhs.timeIntervalSince1970 < rhs
}

public struct RRIntervalSampleDTO: Codable, Sendable, Equatable, Identifiable {
    public static let minPhysiologicalDurationMs: Double = 300.0
    public static let maxPhysiologicalDurationMs: Double = 2_000.0
    public static let validDurationRangeMs: ClosedRange<Double> = 300.0...2_000.0

    public let timestamp: TimeInterval
    public let rrMilliseconds: Double

    public var id: String {
        "\(timestamp.bitPattern)-\(rrMilliseconds.bitPattern)"
    }

    public init(timestamp: TimeInterval, rrMilliseconds: Double) {
        self.timestamp = timestamp
        self.rrMilliseconds = rrMilliseconds
    }

    public init(
        sampleID: UUID = UUID(),
        timestamp: Date,
        durationMs: Double,
        isEctopicFiltered: Bool = true
    ) {
        _ = sampleID
        _ = isEctopicFiltered
        self.timestamp = timestamp.timeIntervalSince1970
        self.rrMilliseconds = durationMs
    }

    public var durationMs: Double {
        rrMilliseconds
    }

    public var isEctopicFiltered: Bool {
        true
    }

    public var isWithinPhysiologicalBounds: Bool {
        rrMilliseconds.isFinite && Self.validDurationRangeMs.contains(rrMilliseconds)
    }

    public var instantaneousBPM: Double {
        guard rrMilliseconds > 0.0 else { return 0.0 }
        return 60_000.0 / rrMilliseconds
    }

    /// Removes non-physiological RR intervals (< 300 ms or > 2000 ms) and sharp ectopic beats
    /// deviating beyond `maxRelativeDeviation` from the local 5-beat median.
    public static func filterEctopicSamples(
        _ rawSamples: [RRIntervalSampleDTO],
        maxRelativeDeviation: Double = 0.28
    ) -> [RRIntervalSampleDTO] {
        let bounded = rawSamples.filter(\.isWithinPhysiologicalBounds)
        guard bounded.count >= 5 else { return bounded }

        var cleaned: [RRIntervalSampleDTO] = []
        cleaned.reserveCapacity(bounded.count)

        for idx in bounded.indices {
            let winStart = max(0, idx - 2)
            let winEnd = min(bounded.count - 1, idx + 2)
            var neighborhood: [Double] = []
            neighborhood.reserveCapacity(winEnd - winStart + 1)
            for k in winStart...winEnd {
                neighborhood.append(bounded[k].rrMilliseconds)
            }
            neighborhood.sort()
            let localMedian = neighborhood[neighborhood.count / 2]
            let relativeDiff = abs(bounded[idx].rrMilliseconds - localMedian) / max(1.0, localMedian)
            if relativeDiff <= maxRelativeDeviation {
                cleaned.append(bounded[idx])
            }
        }

        return cleaned.isEmpty ? bounded : cleaned
    }
}

// MARK: - 2. Lomb-Scargle Bin & HRV Analysis Metrics DTO

public struct LombScargleBinDTO: Codable, Sendable, Equatable {
    public let frequencyHz: Double
    public let powerMs2PerHz: Double
    public let normalizedPower: Double

    public init(frequencyHz: Double, powerMs2PerHz: Double, normalizedPower: Double) {
        self.frequencyHz = frequencyHz
        self.powerMs2PerHz = max(0.0, powerMs2PerHz)
        self.normalizedPower = min(max(normalizedPower, 0.0), 1.0)
    }
}

public struct HRVAnalysisMetricsDTO: Codable, Sendable, Equatable {
    public let validBeatCount: Int
    public let meanRRMs: Double
    public let heartRateBPM: Double
    public let sdnnMs: Double
    public let rmssdMs: Double
    public let pNN50Percent: Double
    public var pnn50Percent: Double { pNN50Percent }
    public let baevskyStressIndex: Double
    public let poincareSD1Ms: Double
    public let poincareSD2Ms: Double
    public let lfPower: Double
    public let hfPower: Double
    public let lfHfRatio: Double
    public let peakMayerFrequencyHz: Double
    public let vagalCoherenceScore: Double
    public let lombScargleFrequenciesHz: [Double]
    public let lombScarglePowers: [Double]

    public init(
        validBeatCount: Int = 0,
        meanRRMs: Double,
        heartRateBPM: Double,
        sdnnMs: Double,
        rmssdMs: Double,
        pnn50Percent: Double,
        baevskyStressIndex: Double,
        poincareSD1Ms: Double,
        poincareSD2Ms: Double,
        lfPower: Double,
        hfPower: Double,
        lfHfRatio: Double,
        peakMayerFrequencyHz: Double,
        vagalCoherenceScore: Double,
        lombScargleFrequenciesHz: [Double],
        lombScarglePowers: [Double]
    ) {
        self.validBeatCount = max(0, validBeatCount)
        self.meanRRMs = max(0.0, meanRRMs)
        self.heartRateBPM = max(0.0, heartRateBPM)
        self.sdnnMs = max(0.0, sdnnMs)
        self.rmssdMs = max(0.0, rmssdMs)
        self.pNN50Percent = min(max(pnn50Percent, 0.0), 100.0)
        self.baevskyStressIndex = max(0.0, baevskyStressIndex)
        self.poincareSD1Ms = max(0.0, poincareSD1Ms)
        self.poincareSD2Ms = max(0.0, poincareSD2Ms)
        self.lfPower = max(0.0, lfPower)
        self.hfPower = max(0.0, hfPower)
        self.lfHfRatio = max(0.0, lfHfRatio)
        self.peakMayerFrequencyHz = max(0.0, peakMayerFrequencyHz)
        self.vagalCoherenceScore = min(max(vagalCoherenceScore, 0.0), 1.0)
        self.lombScargleFrequenciesHz = lombScargleFrequenciesHz
        self.lombScarglePowers = lombScarglePowers
    }

    public init(
        computedAt: Date = .now,
        validBeatCount: Int,
        meanRRMs: Double,
        meanHeartRateBPM: Double,
        sdnnMs: Double,
        rmssdMs: Double,
        pnn50Percent: Double,
        baevskyStressIndex: Double,
        lfPowerMs2: Double,
        hfPowerMs2: Double,
        lfHfRatio: Double,
        dominantFrequencyHz: Double,
        rsaCoherenceScore: Double,
        sd1Ms: Double,
        sd2Ms: Double,
        spectrumBins: [LombScargleBinDTO] = []
    ) {
        _ = computedAt
        self.init(
            validBeatCount: validBeatCount,
            meanRRMs: meanRRMs,
            heartRateBPM: meanHeartRateBPM,
            sdnnMs: sdnnMs,
            rmssdMs: rmssdMs,
            pnn50Percent: pnn50Percent,
            baevskyStressIndex: baevskyStressIndex,
            poincareSD1Ms: sd1Ms,
            poincareSD2Ms: sd2Ms,
            lfPower: lfPowerMs2,
            hfPower: hfPowerMs2,
            lfHfRatio: lfHfRatio,
            peakMayerFrequencyHz: dominantFrequencyHz,
            vagalCoherenceScore: rsaCoherenceScore,
            lombScargleFrequenciesHz: spectrumBins.map(\.frequencyHz),
            lombScarglePowers: spectrumBins.map(\.powerMs2PerHz)
        )
    }

    // Cross-module compatibility aliases
    public var meanHeartRateBPM: Double { heartRateBPM }
    public var sd1Ms: Double { poincareSD1Ms }
    public var sd2Ms: Double { poincareSD2Ms }
    public var lfPowerMs2: Double { lfPower }
    public var hfPowerMs2: Double { hfPower }
    public var dominantFrequencyHz: Double { peakMayerFrequencyHz }
    public var rsaCoherenceScore: Double { vagalCoherenceScore }

    public var sd1ToSd2Ratio: Double {
        guard poincareSD2Ms > 1e-6 else { return 0.0 }
        return poincareSD1Ms / poincareSD2Ms
    }

    public var spectrumBins: [LombScargleBinDTO] {
        let count = min(lombScargleFrequenciesHz.count, lombScarglePowers.count)
        guard count > 0 else { return [] }
        let maxP = max(lombScarglePowers.prefix(count).max() ?? 0.0, 1e-12)
        var bins: [LombScargleBinDTO] = []
        bins.reserveCapacity(count)
        for i in 0..<count {
            let p = max(0.0, lombScarglePowers[i])
            bins.append(
                LombScargleBinDTO(
                    frequencyHz: lombScargleFrequenciesHz[i],
                    powerMs2PerHz: p,
                    normalizedPower: min(max(p / maxP, 0.0), 1.0)
                )
            )
        }
        return bins
    }

    public static var baselinePlaceholder: HRVAnalysisMetricsDTO {
        HRVAnalysisMetricsDTO(
            meanRRMs: 860.0,
            heartRateBPM: 69.8,
            sdnnMs: 48.0,
            rmssdMs: 44.0,
            pnn50Percent: 24.0,
            baevskyStressIndex: 92.0,
            poincareSD1Ms: 31.1,
            poincareSD2Ms: 60.5,
            lfPower: 680.0,
            hfPower: 520.0,
            lfHfRatio: 1.31,
            peakMayerFrequencyHz: 0.10,
            vagalCoherenceScore: 0.72,
            lombScargleFrequenciesHz: [],
            lombScarglePowers: []
        )
    }
}

// MARK: - 3. Biometric Snapshot DTO

public struct BiometricSnapshotDTO: Codable, Sendable, Equatable, Identifiable {
    public let timestamp: Date
    public let recentRRSamples: [RRIntervalSampleDTO]
    public let metrics: HRVAnalysisMetricsDTO
    public let respiratoryRateBrPM: Double
    public let wristTemperatureDeltaCelsius: Double
    public let activeEnergyBurnedKilocalories: Double
    private let explicitHeartRateBPM: Double?

    public var id: String {
        "\(timestamp.timeIntervalSince1970.bitPattern)-\(recentRRSamples.count)"
    }

    public init(
        timestamp: Date = .now,
        recentRRSamples: [RRIntervalSampleDTO],
        metrics: HRVAnalysisMetricsDTO,
        respiratoryRateBrPM: Double
    ) {
        self.timestamp = timestamp
        self.recentRRSamples = recentRRSamples
        self.metrics = metrics
        self.respiratoryRateBrPM = max(0.0, respiratoryRateBrPM)
        self.wristTemperatureDeltaCelsius = 0.0
        self.activeEnergyBurnedKilocalories = 0.0
        self.explicitHeartRateBPM = nil
    }

    public init(
        snapshotID: UUID = UUID(),
        capturedAt: Date = .now,
        heartRateBPM: Double,
        respiratoryRateBrPM: Double,
        wristTemperatureDeltaCelsius: Double = 0.0,
        activeEnergyBurnedKilocalories: Double = 0.0,
        rrIntervals: [RRIntervalSampleDTO]
    ) {
        _ = snapshotID
        let computedMetrics: HRVAnalysisMetricsDTO
        if rrIntervals.count >= 2 {
            computedMetrics = HRVBiometricAnalyzer.analyze(samples: rrIntervals)
        } else {
            let safeBPM = max(30.0, heartRateBPM)
            computedMetrics = HRVAnalysisMetricsDTO(
                meanRRMs: 60_000.0 / safeBPM,
                heartRateBPM: safeBPM,
                sdnnMs: 0.0,
                rmssdMs: 0.0,
                pnn50Percent: 0.0,
                baevskyStressIndex: 0.0,
                poincareSD1Ms: 0.0,
                poincareSD2Ms: 0.0,
                lfPower: 0.0,
                hfPower: 0.0,
                lfHfRatio: 1.0,
                peakMayerFrequencyHz: 0.10,
                vagalCoherenceScore: 0.0,
                lombScargleFrequenciesHz: [],
                lombScarglePowers: []
            )
        }
        self.timestamp = capturedAt
        self.recentRRSamples = rrIntervals
        self.metrics = computedMetrics
        self.respiratoryRateBrPM = max(0.0, respiratoryRateBrPM)
        self.wristTemperatureDeltaCelsius = wristTemperatureDeltaCelsius
        self.activeEnergyBurnedKilocalories = max(0.0, activeEnergyBurnedKilocalories)
        self.explicitHeartRateBPM = max(0.0, heartRateBPM)
    }

    public var capturedAt: Date { timestamp }
    public var rrIntervals: [RRIntervalSampleDTO] { recentRRSamples }
    public var heartRateBPM: Double { explicitHeartRateBPM ?? metrics.heartRateBPM }
}

// MARK: - 4. Exact Time-Domain, Poincaré, Baevsky & Scargle/Townsend Lomb-Scargle Analyzer

public enum HRVBiometricAnalyzer: Sendable {
    public static let minFrequencyHz: Double = 0.04
    public static let maxFrequencyHz: Double = 0.40
    public static let lfBandRangeHz: ClosedRange<Double> = 0.04...0.15
    public static let hfBandRangeHz: ClosedRange<Double> = 0.15...0.40
    public static let mayerSearchRangeHz: ClosedRange<Double> = 0.06...0.14
    public static let mayerResonanceHz: Double = 0.10
    public static let histogramBinWidthMs: Double = 50.0

    public static func analyze(
        samples: [RRIntervalSampleDTO],
        freqBinCount: Int = 48
    ) -> HRVAnalysisMetricsDTO {
        let binCount = max(8, freqBinCount)
        let sorted = samples
            .filter { $0.rrMilliseconds.isFinite && $0.rrMilliseconds > 0.0 && $0.timestamp.isFinite }
            .sorted { $0.timestamp < $1.timestamp }

        let validSamples: [RRIntervalSampleDTO]
        let bounded = sorted.filter(\.isWithinPhysiologicalBounds)
        validSamples = bounded.isEmpty ? sorted : bounded

        let freqs = makeFrequencyGrid(count: binCount, fMin: minFrequencyHz, fMax: maxFrequencyHz)
        let n = validSamples.count

        guard n >= 2 else {
            let rr = validSamples.first?.rrMilliseconds ?? 850.0
            let bpm = rr > 0.0 ? (60_000.0 / rr) : 70.0
            return HRVAnalysisMetricsDTO(
                meanRRMs: rr,
                heartRateBPM: bpm,
                sdnnMs: 0.0,
                rmssdMs: 0.0,
                pnn50Percent: 0.0,
                baevskyStressIndex: 0.0,
                poincareSD1Ms: 0.0,
                poincareSD2Ms: 0.0,
                lfPower: 0.0,
                hfPower: 0.0,
                lfHfRatio: 1.0,
                peakMayerFrequencyHz: mayerResonanceHz,
                vagalCoherenceScore: 0.0,
                lombScargleFrequenciesHz: freqs,
                lombScarglePowers: [Double](repeating: 0.0, count: binCount)
            )
        }

        let rrValues = validSamples.map(\.rrMilliseconds)
        let meanRR = rrValues.reduce(0.0, +) / Double(n)
        let heartRateBPM = meanRR > 0.0 ? (60_000.0 / meanRR) : 0.0

        // 1. Sample SDNN (ms)
        var sumSqCentered = 0.0
        for rr in rrValues {
            let d = rr - meanRR
            sumSqCentered += d * d
        }
        let varianceRR = sumSqCentered / Double(n - 1)
        let sdnnMs = sqrt(max(0.0, varianceRR))

        // 2. Successive Differences -> RMSSD & pNN50
        let diffCount = n - 1
        var diffRR = [Double]()
        diffRR.reserveCapacity(diffCount)
        var sumSqDiff = 0.0
        var countOver50 = 0

        for i in 0..<diffCount {
            let delta = rrValues[i + 1] - rrValues[i]
            diffRR.append(delta)
            sumSqDiff += delta * delta
            if abs(delta) > 50.0 {
                countOver50 += 1
            }
        }

        let rmssdMs = sqrt(sumSqDiff / Double(diffCount))
        let pnn50Percent = (Double(countOver50) / Double(diffCount)) * 100.0

        // 3. Poincaré Geometry:
        // SD1 = sqrt(0.5 * Var(diffRR))
        // SD2 = sqrt(max(0, 2 * SDNN^2 - 0.5 * SD1^2))
        let varDiffRR: Double
        if diffCount >= 2 {
            let meanDiff = diffRR.reduce(0.0, +) / Double(diffCount)
            var sq = 0.0
            for d in diffRR {
                let c = d - meanDiff
                sq += c * c
            }
            varDiffRR = sq / Double(diffCount - 1)
        } else {
            varDiffRR = sumSqDiff
        }
        let poincareSD1Ms = sqrt(max(0.0, 0.5 * varDiffRR))
        let poincareSD2Ms = sqrt(max(0.0, 2.0 * sdnnMs * sdnnMs - 0.5 * poincareSD1Ms * poincareSD1Ms))

        // 4. Baevsky Stress Index: AMoPercent / (2 * MoSeconds * MxDMnSeconds) via 50ms histogram mode
        let baevskySI = computeBaevskyStressIndex(rrMilliseconds: rrValues)

        // 5. Scargle / Townsend Lomb-Scargle Periodogram on uneven RR timestamps (0.04 ... 0.40 Hz)
        let powers = computeLombScarglePowers(
            samples: validSamples,
            meanRRMs: meanRR,
            varianceRRMs2: varianceRR,
            frequenciesHz: freqs
        )

        // Trapezoidal band integration across LF (0.04...0.15 Hz) & HF (0.15...0.40 Hz)
        var lfPower = 0.0
        var hfPower = 0.0
        var totalPower = 0.0
        for i in 0..<(freqs.count - 1) {
            let f0 = freqs[i]
            let f1 = freqs[i + 1]
            let df = f1 - f0
            let area = 0.5 * (powers[i] + powers[i + 1]) * df
            totalPower += area
            let mid = 0.5 * (f0 + f1)
            if mid >= lfBandRangeHz.lowerBound && mid <= lfBandRangeHz.upperBound {
                lfPower += area
            } else if mid > hfBandRangeHz.lowerBound && mid <= hfBandRangeHz.upperBound {
                hfPower += area
            }
        }

        let lfHfRatio = lfPower / max(1e-9, hfPower)

        // Peak Mayer frequency within 0.06...0.14 Hz
        var mayerPeakIdx: Int?
        var mayerPeakPower = -1.0
        for idx in freqs.indices where mayerSearchRangeHz.contains(freqs[idx]) {
            if powers[idx] > mayerPeakPower {
                mayerPeakPower = powers[idx]
                mayerPeakIdx = idx
            }
        }
        let peakMayerFrequencyHz = mayerPeakIdx.map { freqs[$0] } ?? mayerResonanceHz

        // Vagal coherence score (0.0...1.0): spectral concentration around cardiorespiratory / Mayer peak + vagal RMSSD tone
        var globalPeakIdx = 0
        var globalPeakVal = -1.0
        for idx in freqs.indices where freqs[idx] >= 0.06 && freqs[idx] <= 0.32 {
            if powers[idx] > globalPeakVal {
                globalPeakVal = powers[idx]
                globalPeakIdx = idx
            }
        }
        let resonanceCenterHz = freqs[globalPeakIdx]
        var narrowWindowPower = 0.0
        for i in 0..<(freqs.count - 1) {
            let mid = 0.5 * (freqs[i] + freqs[i + 1])
            if abs(mid - resonanceCenterHz) <= 0.022 {
                narrowWindowPower += 0.5 * (powers[i] + powers[i + 1]) * (freqs[i + 1] - freqs[i])
            }
        }

        let spectralConcentration = totalPower > 1e-12
            ? min(1.0, (narrowWindowPower / totalPower) * 2.1)
            : 0.0
        let mayerProximity = exp(-pow((resonanceCenterHz - mayerResonanceHz) / 0.095, 2.0))
        let vagalRMSSDScore = min(1.0, rmssdMs / 45.0)
        let vagalCoherenceScore = totalPower > 1e-12
            ? min(max(0.58 * spectralConcentration + 0.24 * mayerProximity + 0.18 * vagalRMSSDScore, 0.0), 1.0)
            : 0.0

        return HRVAnalysisMetricsDTO(
            validBeatCount: n,
            meanRRMs: meanRR,
            heartRateBPM: heartRateBPM,
            sdnnMs: sdnnMs,
            rmssdMs: rmssdMs,
            pnn50Percent: pnn50Percent,
            baevskyStressIndex: baevskySI,
            poincareSD1Ms: poincareSD1Ms,
            poincareSD2Ms: poincareSD2Ms,
            lfPower: lfPower,
            hfPower: hfPower,
            lfHfRatio: lfHfRatio,
            peakMayerFrequencyHz: peakMayerFrequencyHz,
            vagalCoherenceScore: vagalCoherenceScore,
            lombScargleFrequenciesHz: freqs,
            lombScarglePowers: powers
        )
    }

    public static func computeBaevskyStressIndex(rrMilliseconds: [Double]) -> Double {
        guard rrMilliseconds.count >= 2,
              let minRR = rrMilliseconds.min(),
              let maxRR = rrMilliseconds.max() else {
            return 0.0
        }

        var histogram: [Int: Int] = [:]
        for rr in rrMilliseconds {
            let bin = Int(floor(rr / histogramBinWidthMs))
            histogram[bin, default: 0] += 1
        }

        var modeBin = Int(floor(rrMilliseconds[0] / histogramBinWidthMs))
        var modeCount = 0
        for (bin, count) in histogram {
            if count > modeCount || (count == modeCount && bin < modeBin) {
                modeCount = count
                modeBin = bin
            }
        }

        let amoPercent = (Double(modeCount) / Double(rrMilliseconds.count)) * 100.0
        let moSeconds = max(0.25, ((Double(modeBin) + 0.5) * histogramBinWidthMs) / 1_000.0)
        let mxDMnSeconds = max(0.010, (maxRR - minRR) / 1_000.0)
        return amoPercent / (2.0 * moSeconds * mxDMnSeconds)
    }

    private static func makeFrequencyGrid(count: Int, fMin: Double, fMax: Double) -> [Double] {
        guard count > 1 else { return [fMin] }
        let step = (fMax - fMin) / Double(count - 1)
        return (0..<count).map { fMin + Double($0) * step }
    }

    private static func computeLombScarglePowers(
        samples: [RRIntervalSampleDTO],
        meanRRMs: Double,
        varianceRRMs2: Double,
        frequenciesHz: [Double]
    ) -> [Double] {
        let n = samples.count
        guard n >= 4, varianceRRMs2 > 1e-12 else {
            return [Double](repeating: 0.0, count: frequenciesHz.count)
        }

        // Monotonic beat timestamps in seconds relative to first beat
        var timesSec = [Double](repeating: 0.0, count: n)
        let t0 = samples[0].timestamp
        var cumulativeSec = 0.0
        for i in 1..<n {
            let delta = samples[i].timestamp - t0
            cumulativeSec += samples[i].rrMilliseconds / 1_000.0
            if delta > timesSec[i - 1] + 1e-5 {
                timesSec[i] = delta
            } else {
                timesSec[i] = cumulativeSec
            }
        }

        let centered = samples.map { $0.rrMilliseconds - meanRRMs }
        let spanSec = max(1.0, timesSec[n - 1] - timesSec[0])
        let psdScale = (2.0 * varianceRRMs2 * spanSec) / Double(n)
        let twoPi = 2.0 * Double.pi

        var powers = [Double]()
        powers.reserveCapacity(frequenciesHz.count)

        for freq in frequenciesHz {
            let omega = twoPi * freq
            let twoOmega = 2.0 * omega

            var sin2Sum = 0.0
            var cos2Sum = 0.0
            for t in timesSec {
                let angle = twoOmega * t
                sin2Sum += sin(angle)
                cos2Sum += cos(angle)
            }

            // Exact Scargle/Townsend phase offset tau = atan2(sum sin(2*w*t), sum cos(2*w*t)) / (2*w)
            let tau = atan2(sin2Sum, cos2Sum) / twoOmega

            var ycSum = 0.0
            var ysSum = 0.0
            var ccSum = 0.0
            var ssSum = 0.0

            for j in 0..<n {
                let phase = omega * (timesSec[j] - tau)
                let c = cos(phase)
                let s = sin(phase)
                let y = centered[j]
                ycSum += y * c
                ysSum += y * s
                ccSum += c * c
                ssSum += s * s
            }

            let cosTerm = ccSum > 1e-12 ? (ycSum * ycSum) / ccSum : 0.0
            let sinTerm = ssSum > 1e-12 ? (ysSum * ysSum) / ssSum : 0.0
            let normalizedScargle = (0.5 / varianceRRMs2) * (cosTerm + sinTerm)
            powers.append(max(0.0, normalizedScargle * psdScale))
        }

        return powers
    }
}

// MARK: - 5. Legacy Signal Processor Facade for WatchOS & Dashboard Consumers

public enum HRVSignalProcessor: Sendable {
    public static let lfBandRangeHz: ClosedRange<Double> = HRVBiometricAnalyzer.lfBandRangeHz
    public static let hfBandRangeHz: ClosedRange<Double> = HRVBiometricAnalyzer.hfBandRangeHz
    public static let mayerResonanceHz: Double = HRVBiometricAnalyzer.mayerResonanceHz
    public static let histogramBinWidthMs: Double = HRVBiometricAnalyzer.histogramBinWidthMs

    public static func analyze(
        samples rawSamples: [RRIntervalSampleDTO],
        computedAt: Date = .now,
        applyEctopicFilter: Bool = true
    ) -> HRVAnalysisMetricsDTO {
        _ = computedAt
        let sorted = rawSamples.sorted { $0.timestamp < $1.timestamp }
        let filtered = applyEctopicFilter
            ? RRIntervalSampleDTO.filterEctopicSamples(sorted)
            : sorted.filter(\.isWithinPhysiologicalBounds)
        return HRVBiometricAnalyzer.analyze(samples: filtered, freqBinCount: 73)
    }

    public static func computeBaevskyStressIndex(durationsMs: [Double]) -> Double {
        HRVBiometricAnalyzer.computeBaevskyStressIndex(rrMilliseconds: durationsMs)
    }

    public static func evaluateLombScarglePeriodogram(
        samples: [RRIntervalSampleDTO],
        minFrequencyHz: Double = 0.04,
        maxFrequencyHz: Double = 0.40,
        frequencyStepHz: Double = 0.005
    ) -> [LombScargleBinDTO] {
        let count = max(8, Int(((maxFrequencyHz - minFrequencyHz) / max(1e-4, frequencyStepHz)).rounded()) + 1)
        return HRVBiometricAnalyzer.analyze(samples: samples, freqBinCount: count).spectrumBins
    }
}
