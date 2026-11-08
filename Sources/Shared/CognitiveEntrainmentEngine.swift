// MARK: - FILE: CognitiveEntrainmentEngine.swift

import Foundation

// MARK: - 1. 2D Cognitive Focus State Kalman Estimate

public struct KalmanFocusEstimate: Codable, Sendable, Equatable {
    public let coherence: Double
    public let fatigueVelocity: Double
    public let errorCovarianceTrace: Double
    public let recommendedSessionMinutes: Int
    public var focusCapacity: Double { coherence }
    public var cognitiveFatigue: Double { min(max(0.5 + fatigueVelocity * 0.5, 0.05), 1.0) }
    public var circadianPhaseRadians: Double { coherence * Double.pi }

    public init(
        coherence: Double,
        fatigueVelocity: Double,
        errorCovarianceTrace: Double,
        recommendedSessionMinutes: Int
    ) {
        self.coherence = min(max(coherence, 0.0), 1.0)
        self.fatigueVelocity = fatigueVelocity
        self.errorCovarianceTrace = max(0.0, errorCovarianceTrace)
        self.recommendedSessionMinutes = max(5, recommendedSessionMinutes)
    }
}

// MARK: - 2. Joseph-Form 2D Focus State Kalman Filter

public struct FocusStateKalmanFilter: Sendable, Equatable {
    public static let fatigueRetentionFactor: Double = 0.92

    private var stateCoherence: Double
    private var stateFatigueVelocity: Double

    // 2x2 symmetric error covariance matrix P = [[p00, p01], [p10, p11]]
    private var p00: Double
    private var p01: Double
    private var p10: Double
    private var p11: Double

    public init(
        initialCoherence: Double = 0.75,
        initialFatigueVelocity: Double = 0.0
    ) {
        self.stateCoherence = min(max(initialCoherence, 0.0), 1.0)
        self.stateFatigueVelocity = min(max(initialFatigueVelocity, -2.0), 2.0)
        self.p00 = 0.06
        self.p01 = 0.0
        self.p10 = 0.0
        self.p11 = 0.04
    }

    public var currentEstimate: KalmanFocusEstimate {
        let clampedCoherence = min(max(stateCoherence, 0.0), 1.0)
        let trace = max(0.0, p00 + p11)
        let rawMinutes = 15.0 + 45.0 * clampedCoherence - 18.0 * stateFatigueVelocity
        let boundedMinutes = min(max(Int(rawMinutes.rounded()), 10), 75)
        return KalmanFocusEstimate(
            coherence: clampedCoherence,
            fatigueVelocity: stateFatigueVelocity,
            errorCovarianceTrace: trace,
            recommendedSessionMinutes: boundedMinutes
        )
    }

    /// Time-update step using state transition `F = [[1, -dt], [0, 0.92]]` and continuous-discrete process noise `Q`.
    public mutating func predict(deltaHours: Double) {
        let dt = max(0.0, min(deltaHours, 72.0))
        guard dt > 0.0 else { return }

        let decay = Self.fatigueRetentionFactor

        // State prediction: x_pred = F * x
        let predictedCoherence = stateCoherence - dt * stateFatigueVelocity
        let predictedFatigueVelocity = decay * stateFatigueVelocity
        stateCoherence = min(max(predictedCoherence, 0.0), 1.0)
        stateFatigueVelocity = min(max(predictedFatigueVelocity, -2.0), 2.0)

        // Covariance prediction: P_pred = F * P * F^T + Q
        // F * P = [[p00 - dt*p10, p01 - dt*p11], [decay*p10, decay*p11]]
        let fp00 = p00 - dt * p10
        let fp01 = p01 - dt * p11
        let fp10 = decay * p10
        let fp11 = decay * p11

        let q00 = 0.008 + 0.014 * dt
        let q11 = 0.008 + 0.010 * dt

        let nextP00 = fp00 - dt * fp01 + q00
        let nextP01 = fp01 * decay
        let nextP10 = fp10 - dt * fp11
        let nextP11 = fp11 * decay + q11

        let symOffDiag = 0.5 * (nextP01 + nextP10)
        p00 = max(1e-8, nextP00)
        p01 = symOffDiag
        p10 = symOffDiag
        p11 = max(1e-8, nextP11)
    }

    /// Measurement-update step using stabilized Joseph-form covariance update:
    /// `P = (I - K*H) * P * (I - K*H)^T + K * R * K^T`.
    @discardableResult
    public mutating func update(
        measuredQuality: Double,
        sessionDurationSeconds: Double,
        aborted: Bool
    ) -> KalmanFocusEstimate {
        let clampedQuality = min(max(measuredQuality, 0.0), 1.0)
        let durationHours = min(max(sessionDurationSeconds / 3600.0, 1.0 / 60.0), 6.0)

        // Effective observed coherence accounts for incomplete cortical entrainment on aborted runs
        let effectiveObservation = aborted ? (clampedQuality * 0.72) : clampedQuality

        // Observation row vector H = [1.0, -0.5 * durationHours]
        // Average session quality reflects mid-session coherence c - 0.5 * durationHours * fatigueVelocity
        let h0 = 1.0
        let h1 = -0.5 * durationHours

        // Measurement noise variance R scales inversely with observation duration and increases on aborts
        let durationConfidence = min(max(durationHours / 0.5, 0.25), 2.5)
        let rVariance = (aborted ? 0.036 : 0.016) / durationConfidence

        // Innovation y = z - H * x
        let expectedMeasurement = h0 * stateCoherence + h1 * stateFatigueVelocity
        let innovation = effectiveObservation - expectedMeasurement

        // Innovation covariance S = H * P * H^T + R
        let ph0 = p00 * h0 + p01 * h1
        let ph1 = p10 * h0 + p11 * h1
        let innovationCovariance = max(1e-9, h0 * ph0 + h1 * ph1 + rVariance)

        // Kalman gain K = P * H^T * S^-1 (2x1 column vector)
        let k0 = ph0 / innovationCovariance
        let k1 = ph1 / innovationCovariance

        // Posterior state update x_new = x + K * y (+ physiological strain impulse if aborted)
        let abortStrainImpulse = aborted ? 0.025 : 0.0
        stateCoherence = min(max(stateCoherence + k0 * innovation, 0.0), 1.0)
        stateFatigueVelocity = min(max(stateFatigueVelocity + k1 * innovation + abortStrainImpulse, -2.0), 2.0)

        // Stabilized Joseph-form 2x2 covariance update:
        // A = I - K * H
        let a00 = 1.0 - k0 * h0
        let a01 = -k0 * h1
        let a10 = -k1 * h0
        let a11 = 1.0 - k1 * h1

        // M = A * P
        let m00 = a00 * p00 + a01 * p10
        let m01 = a00 * p01 + a01 * p11
        let m10 = a10 * p00 + a11 * p10
        let m11 = a10 * p01 + a11 * p11

        // A * P * A^T + K * R * K^T
        let updatedP00 = (m00 * a00 + m01 * a01) + (k0 * rVariance * k0)
        let updatedP01 = (m00 * a10 + m01 * a11) + (k0 * rVariance * k1)
        let updatedP10 = (m10 * a00 + m11 * a01) + (k1 * rVariance * k0)
        let updatedP11 = (m10 * a10 + m11 * a11) + (k1 * rVariance * k1)

        let symOffDiag = 0.5 * (updatedP01 + updatedP10)
        p00 = max(1e-8, updatedP00)
        p01 = symOffDiag
        p10 = symOffDiag
        p11 = max(1e-8, updatedP11)

        return currentEstimate
    }

    /// Chronologically assimilates historical `DailyTelemetryDTO` rollups and individual `FocusSessionDTO` records.
    @discardableResult
    public mutating func assimilateHistory(
        sessions: [FocusSessionDTO],
        telemetry: [DailyTelemetryDTO]
    ) -> KalmanFocusEstimate {
        struct HistoricalObservation {
            let timestamp: Date
            let quality: Double
            let durationSeconds: Double
            let aborted: Bool
        }

        let coveredSessionDays = Set(sessions.map { DayKeyFormatter.dayKey(for: $0.startedAt) })
        var timeline: [HistoricalObservation] = []
        timeline.reserveCapacity(sessions.count + telemetry.count)

        for day in telemetry where !coveredSessionDays.contains(day.dayKey) {
            let totalCount = day.completedSessionCount + day.abortedSessionCount
            guard totalCount > 0 || day.totalFocusSeconds > 0 else { continue }
            let meanDuration = day.totalFocusSeconds / Double(max(1, totalCount))
            let middayAnchor = day.dateStartOfDay.addingTimeInterval(12.0 * 3600.0)
            let mostlyAborted = day.completedSessionCount == 0 && day.abortedSessionCount > 0
            timeline.append(
                HistoricalObservation(
                    timestamp: middayAnchor,
                    quality: day.averageQualityScore,
                    durationSeconds: max(300.0, meanDuration),
                    aborted: mostlyAborted
                )
            )
        }

        for session in sessions {
            timeline.append(
                HistoricalObservation(
                    timestamp: session.startedAt,
                    quality: session.focusQualityScore,
                    durationSeconds: max(60.0, session.actualDurationSeconds),
                    aborted: !session.completed
                )
            )
        }

        guard !timeline.isEmpty else {
            return currentEstimate
        }

        timeline.sort { $0.timestamp < $1.timestamp }

        var lastEndTimestamp: Date?
        for obs in timeline {
            if let prev = lastEndTimestamp {
                let rawGapHours = max(0.0, obs.timestamp.timeIntervalSince(prev) / 3600.0)
                let boundedGapHours = min(rawGapHours, 24.0)
                if boundedGapHours > 0.0 {
                    // Sub-step multi-hour rest intervals so exponential fatigue recovery (0.92^k) compounds smoothly
                    var remaining = boundedGapHours
                    while remaining > 1e-6 {
                        let stepHours = min(remaining, 2.0)
                        predict(deltaHours: stepHours)
                        remaining -= stepHours
                    }
                }
            }

            _ = update(
                measuredQuality: obs.quality,
                sessionDurationSeconds: obs.durationSeconds,
                aborted: obs.aborted
            )
            lastEndTimestamp = obs.timestamp.addingTimeInterval(obs.durationSeconds)
        }

        return currentEstimate
    }
}

// MARK: - 3. Entrainment Phase & C1 Cubic Hermite Spline Ramp Schedule

public enum EntrainmentPhase: String, Codable, CaseIterable, Sendable {
    case induction
    case descent
    case deepLock
    case corticalAwakening
}

public struct EntrainmentSplineSample: Codable, Sendable, Equatable {
    public let normalizedProgress: Double
    public var progress: Double { normalizedProgress }
    public let phase: EntrainmentPhase
    public let carrierFrequencyHz: Float
    public let binauralBeatHz: Float
    public let filterCutoffHz: Float

    public init(
        normalizedProgress: Double,
        phase: EntrainmentPhase,
        carrierFrequencyHz: Float,
        binauralBeatHz: Float,
        filterCutoffHz: Float
    ) {
        self.normalizedProgress = min(max(normalizedProgress, 0.0), 1.0)
        self.phase = phase
        self.carrierFrequencyHz = carrierFrequencyHz
        self.binauralBeatHz = binauralBeatHz
        self.filterCutoffHz = filterCutoffHz
    }
}

public struct EntrainmentRampSchedule: Codable, Sendable, Equatable {
    public static let knotPositions: [Double] = [0.0, 0.18, 0.42, 0.85, 1.0]

    public let category: FocusCategory
    public let circadianHour: Int

    public init(
        category: FocusCategory,
        circadianHour: Int = Calendar.current.component(.hour, from: .now)
    ) {
        self.category = category
        self.circadianHour = min(max(circadianHour, 0), 23)
    }

    public func sampleCurve(pointCount: Int = 48) -> [EntrainmentSplineSample] {
        let n = max(2, pointCount)
        return (0..<n).map { idx in
            let t = Double(idx) / Double(n - 1)
            return sample(at: t)
        }
    }

    /// Evaluates the C1-continuous Cubic Hermite Spline (`h00, h10, h01, h11`) across 5 phase knots
    /// (`0.0, 0.18, 0.42, 0.85, 1.0`) with circadian carrier & filter cutoff adaptation.
    public func sample(at normalizedProgress: Double) -> EntrainmentSplineSample {
        let t = min(max(normalizedProgress, 0.0), 1.0)
        let knots = Self.knotPositions
        let profile = circadianAdjustedKnots()

        let phase: EntrainmentPhase
        let segmentIndex: Int
        if t < knots[1] {
            phase = .induction
            segmentIndex = 0
        } else if t < knots[2] {
            phase = .descent
            segmentIndex = 1
        } else if t < knots[3] {
            phase = .deepLock
            segmentIndex = 2
        } else {
            phase = .corticalAwakening
            segmentIndex = 3
        }

        let carrier = Self.evaluateHermiteChannel(
            at: t,
            segment: segmentIndex,
            knots: knots,
            values: profile.carriers,
            tangents: profile.carrierTangents
        )
        let beat = Self.evaluateHermiteChannel(
            at: t,
            segment: segmentIndex,
            knots: knots,
            values: profile.beats,
            tangents: profile.beatTangents
        )
        let cutoff = Self.evaluateHermiteChannel(
            at: t,
            segment: segmentIndex,
            knots: knots,
            values: profile.cutoffs,
            tangents: profile.cutoffTangents
        )

        return EntrainmentSplineSample(
            normalizedProgress: t,
            phase: phase,
            carrierFrequencyHz: Float(min(max(carrier, 90.0), 528.0)),
            binauralBeatHz: Float(min(max(beat, 1.2), 45.0)),
            filterCutoffHz: Float(min(max(cutoff, 140.0), 10_000.0))
        )
    }

    public func generateCurvePreview(steps: Int = 32) -> [EntrainmentSplineSample] {
        guard steps > 0 else { return [] }
        if steps == 1 {
            return [sample(at: 0.0)]
        }
        var samples: [EntrainmentSplineSample] = []
        samples.reserveCapacity(steps)
        let denom = Double(steps - 1)
        for idx in 0..<steps {
            let progress = Double(idx) / denom
            samples.append(sample(at: progress))
        }
        return samples
    }

    // MARK: - Internal Cubic Hermite Basis & Circadian Knot Shaping

    private struct ChannelKnotProfile {
        let carriers: [Double]
        let beats: [Double]
        let cutoffs: [Double]
        let carrierTangents: [Double]
        let beatTangents: [Double]
        let cutoffTangents: [Double]
    }

    private func circadianAdjustedKnots() -> ChannelKnotProfile {
        // Circadian phase wave: peaks mid-morning (~10:30) for cortical alertness,
        // troughs late evening/night (~22:30) to protect melatonin synthesis.
        let phaseRadians = (Double(circadianHour) - 4.5) * (2.0 * Double.pi / 24.0)
        let circadianWave = sin(phaseRadians)

        let carrierScale = 1.0 + 0.12 * circadianWave
        let cutoffScale = 1.0 + 0.26 * circadianWave
        let eveningGentleBeatScale = circadianWave < 0.0 ? (1.0 + 0.05 * circadianWave) : 1.0

        let rawCarriers: [Double]
        let rawBeats: [Double]
        let rawCutoffs: [Double]

        switch category {
        case .deepWork:
            rawCarriers = [224.0, 220.0, 216.0, 216.0, 228.0]
            rawBeats = [16.5, 15.0, 14.0, 14.0, 15.8]
            rawCutoffs = [1420.0, 1260.0, 1180.0, 1180.0, 1540.0]

        case .alphaFlow:
            rawCarriers = [208.0, 200.0, 196.0, 196.0, 210.0]
            rawBeats = [13.5, 11.4, 10.0, 10.0, 12.2]
            rawCutoffs = [1820.0, 1710.0, 1650.0, 1650.0, 1920.0]

        case .thetaMeditation:
            rawCarriers = [164.0, 152.0, 144.0, 144.0, 160.0]
            rawBeats = [10.5, 7.4, 5.5, 5.5, 8.8]
            rawCutoffs = [960.0, 780.0, 680.0, 680.0, 920.0]

        case .gammaCognition:
            rawCarriers = [242.0, 250.0, 256.0, 256.0, 246.0]
            rawBeats = [18.0, 30.0, 40.0, 40.0, 22.0]
            rawCutoffs = [1950.0, 2240.0, 2450.0, 2450.0, 2100.0]

        case .deltaRecovery:
            rawCarriers = [148.0, 136.0, 128.0, 128.0, 142.0]
            rawBeats = [8.0, 4.4, 2.5, 2.5, 5.2]
            rawCutoffs = [720.0, 540.0, 460.0, 460.0, 660.0]
        }

        let carriers = rawCarriers.map { $0 * carrierScale }
        let beats = [
            rawBeats[0] * eveningGentleBeatScale,
            rawBeats[1] * eveningGentleBeatScale,
            rawBeats[2],
            rawBeats[3],
            rawBeats[4] * eveningGentleBeatScale
        ]
        let cutoffs = rawCutoffs.map { $0 * cutoffScale }

        let knots = Self.knotPositions
        return ChannelKnotProfile(
            carriers: carriers,
            beats: beats,
            cutoffs: cutoffs,
            carrierTangents: Self.computeMonotoneHermiteSlopes(knots: knots, values: carriers),
            beatTangents: Self.computeMonotoneHermiteSlopes(knots: knots, values: beats),
            cutoffTangents: Self.computeMonotoneHermiteSlopes(knots: knots, values: cutoffs)
        )
    }

    /// Fritsch-Carlson C1 monotone tangent estimator over non-uniform knots `t_0 < ... < t_4`.
    private static func computeMonotoneHermiteSlopes(knots: [Double], values: [Double]) -> [Double] {
        let n = values.count
        var secants = [Double](repeating: 0.0, count: n - 1)
        var widths = [Double](repeating: 1.0, count: n - 1)

        for k in 0..<(n - 1) {
            let h = max(1e-9, knots[k + 1] - knots[k])
            widths[k] = h
            secants[k] = (values[k + 1] - values[k]) / h
        }

        var slopes = [Double](repeating: 0.0, count: n)
        slopes[0] = secants[0]
        slopes[n - 1] = secants[n - 2]

        for k in 1..<(n - 1) {
            let sPrev = secants[k - 1]
            let sNext = secants[k]
            if sPrev * sNext <= 0.0 {
                slopes[k] = 0.0
            } else {
                let hPrev = widths[k - 1]
                let hNext = widths[k]
                let w1 = 2.0 * hNext + hPrev
                let w2 = hNext + 2.0 * hPrev
                slopes[k] = (w1 + w2) / ((w1 / sPrev) + (w2 / sNext))
            }
        }

        for k in 0..<(n - 1) {
            let s = secants[k]
            if abs(s) < 1e-12 {
                slopes[k] = 0.0
                slopes[k + 1] = 0.0
            } else {
                let alpha = slopes[k] / s
                let beta = slopes[k + 1] / s
                let hypotSq = alpha * alpha + beta * beta
                if hypotSq > 9.0 {
                    let tau = 3.0 / sqrt(hypotSq)
                    slopes[k] = tau * alpha * s
                    slopes[k + 1] = tau * beta * s
                }
            }
        }

        return slopes
    }

    @inline(__always)
    private static func evaluateHermiteChannel(
        at t: Double,
        segment k: Int,
        knots: [Double],
        values: [Double],
        tangents: [Double]
    ) -> Double {
        let t0 = knots[k]
        let t1 = knots[k + 1]
        let span = max(1e-9, t1 - t0)
        let u = min(max((t - t0) / span, 0.0), 1.0)
        let u2 = u * u
        let u3 = u2 * u

        // Cubic Hermite basis functions (h00, h10, h01, h11)
        let h00 = 2.0 * u3 - 3.0 * u2 + 1.0
        let h10 = u3 - 2.0 * u2 + u
        let h01 = -2.0 * u3 + 3.0 * u2
        let h11 = u3 - u2

        return h00 * values[k]
             + h10 * (span * tangents[k])
             + h01 * values[k + 1]
             + h11 * (span * tangents[k + 1])
    }
}
