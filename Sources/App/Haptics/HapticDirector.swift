// MARK: - FILE: HapticDirector.swift

import Foundation
import CoreHaptics

@MainActor
public final class HapticDirector {
    private var engine: CHHapticEngine?
    private let supportsHaptics: Bool
    private var isEngineRunning: Bool = false
    private var lastScrubTimestamp: TimeInterval = 0

    public init() {
        self.supportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
        prepareEngineIfSupported()
    }

    public func prepareEngineIfSupported() {
        guard supportsHaptics, engine == nil else { return }
        do {
            let created = try CHHapticEngine()
            created.playsHapticsOnly = true
            created.isAutoShutdownEnabled = true

            created.stoppedHandler = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.isEngineRunning = false
                }
            }

            created.resetHandler = { [weak self] in
                Task { @MainActor [weak self] in
                    self?.restartEngine()
                }
            }

            self.engine = created
            try created.start()
            self.isEngineRunning = true
        } catch {
            self.engine = nil
            self.isEngineRunning = false
        }
    }

    private func restartEngine() {
        guard supportsHaptics, let engine else { return }
        do {
            try engine.start()
            isEngineRunning = true
        } catch {
            isEngineRunning = false
        }
    }

    private func ensureRunning() -> CHHapticEngine? {
        guard supportsHaptics else { return nil }
        if engine == nil {
            prepareEngineIfSupported()
        }
        guard let engine else { return nil }
        if !isEngineRunning {
            try? engine.start()
            isEngineRunning = true
        }
        return engine
    }

    // MARK: - Tactile Vocabulary

    public func playSegmentSnap() {
        guard let engine = ensureRunning() else { return }
        let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.58)
        let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.82)
        let event = CHHapticEvent(eventType: .hapticTransient, parameters: [intensity, sharpness], relativeTime: 0)
        playEvents([event], curves: [], on: engine)
    }

    public func playOrbitalSnap(mass: Double) {
        guard let engine = ensureRunning() else { return }
        let normalizedMass = Float(min(max((mass - 0.5) / 2.0, 0.0), 1.0))
        let intensityValue = 0.45 + normalizedMass * 0.45
        let sharpnessValue = 0.85 - normalizedMass * 0.40

        let transient = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensityValue),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpnessValue)
            ],
            relativeTime: 0
        )
        let tail = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensityValue * 0.45),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.25)
            ],
            relativeTime: 0.01,
            duration: 0.11
        )
        let fadeCurve = CHHapticParameterCurve(
            parameterID: .hapticIntensityControl,
            controlPoints: [
                CHHapticParameterCurve.ControlPoint(relativeTime: 0.01, value: 1.0),
                CHHapticParameterCurve.ControlPoint(relativeTime: 0.12, value: 0.0)
            ],
            relativeTime: 0
        )
        playEvents([transient, tail], curves: [fadeCurve], on: engine)
    }

    public func playRippleTouch(normalizedVelocity: Float, normalizedY: Float) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastScrubTimestamp >= 0.045 else { return }
        lastScrubTimestamp = now

        guard let engine = ensureRunning() else { return }
        let v = min(max(normalizedVelocity, 0.08), 1.0)
        let sharpness = min(max(1.0 - normalizedY, 0.15), 0.90)

        let swell = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.22 + v * 0.52),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
            ],
            relativeTime: 0,
            duration: 0.09
        )

        let envelope = CHHapticParameterCurve(
            parameterID: .hapticIntensityControl,
            controlPoints: [
                CHHapticParameterCurve.ControlPoint(relativeTime: 0.0, value: 0.35),
                CHHapticParameterCurve.ControlPoint(relativeTime: 0.025, value: 1.0),
                CHHapticParameterCurve.ControlPoint(relativeTime: 0.09, value: 0.05)
            ],
            relativeTime: 0
        )
        playEvents([swell], curves: [envelope], on: engine)
    }

    public func scrubDayCell(intensityLevel: Int) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastScrubTimestamp >= 0.032 else { return }
        lastScrubTimestamp = now

        guard let engine = ensureRunning() else { return }
        let clamped = Float(min(max(intensityLevel, 0), 4)) / 4.0
        let event = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.28 + clamped * 0.52),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.45 + clamped * 0.45)
            ],
            relativeTime: 0
        )
        playEvents([event], curves: [], on: engine)
    }

    public func playTimerIgnition(starting: Bool) {
        guard let engine = ensureRunning() else { return }
        let duration: TimeInterval = 0.28
        let continuous = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.72),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: starting ? 0.35 : 0.65)
            ],
            relativeTime: 0,
            duration: duration
        )
        let anchorTap = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.88),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: starting ? 0.78 : 0.40)
            ],
            relativeTime: starting ? duration * 0.82 : 0.0
        )

        let intensityCurve = CHHapticParameterCurve(
            parameterID: .hapticIntensityControl,
            controlPoints: starting
                ? [
                    .init(relativeTime: 0.0, value: 0.15),
                    .init(relativeTime: 0.22, value: 1.0),
                    .init(relativeTime: 0.28, value: 0.0)
                ]
                : [
                    .init(relativeTime: 0.0, value: 1.0),
                    .init(relativeTime: 0.28, value: 0.05)
                ],
            relativeTime: 0
        )

        playEvents([continuous, anchorTap], curves: [intensityCurve], on: engine)
    }

    public func playSessionCompletionSymphony() {
        guard let engine = ensureRunning() else { return }

        let pulseOffsets: [(TimeInterval, Float, Float)] = [
            (0.00, 0.65, 0.45),
            (0.11, 0.78, 0.62),
            (0.23, 0.90, 0.78),
            (0.38, 1.00, 0.92)
        ]

        var events: [CHHapticEvent] = pulseOffsets.map { time, intensity, sharpness in
            CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
                ],
                relativeTime: time
            )
        }

        let harmonicBloom = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.82),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.38)
            ],
            relativeTime: 0.36,
            duration: 0.68
        )
        events.append(harmonicBloom)

        let bloomIntensityCurve = CHHapticParameterCurve(
            parameterID: .hapticIntensityControl,
            controlPoints: [
                .init(relativeTime: 0.36, value: 0.30),
                .init(relativeTime: 0.54, value: 1.00),
                .init(relativeTime: 0.80, value: 0.48),
                .init(relativeTime: 1.04, value: 0.00)
            ],
            relativeTime: 0
        )

        let bloomSharpnessCurve = CHHapticParameterCurve(
            parameterID: .hapticSharpnessControl,
            controlPoints: [
                .init(relativeTime: 0.36, value: 0.75),
                .init(relativeTime: 0.70, value: 0.25),
                .init(relativeTime: 1.04, value: 0.05)
            ],
            relativeTime: 0
        )

        playEvents(events, curves: [bloomIntensityCurve, bloomSharpnessCurve], on: engine)
    }

    private func playEvents(
        _ events: [CHHapticEvent],
        curves: [CHHapticParameterCurve],
        on engine: CHHapticEngine
    ) {
        do {
            let pattern = try CHHapticPattern(events: events, parameterCurves: curves)
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            isEngineRunning = false
        }
    }
}
