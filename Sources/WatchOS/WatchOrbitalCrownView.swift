// MARK: - FILE: WatchOrbitalCrownView.swift

import SwiftUI
import SwiftData

#if os(watchOS)
import WatchKit

// MARK: - watchOS 11 Digital Crown Binaural Scrubber & 0.10 Hz Mayer Wave Pacer

public struct WatchOrbitalCrownView: View {
    @Bindable public var engine: WatchHealthKitBiometricEngine
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @Environment(\.modelContext) private var modelContext

    @Query(
        filter: #Predicate<HabitNode> { node in node.isArchived == false },
        sort: [SortDescriptor(\HabitNode.sortOrder, order: .forward)]
    )
    private var habits: [HabitNode]

    @State private var crownFrequencyHz: Double = 10.0
    @State private var crownHabitValue: Double = 0.0
    @State private var isHabitCrownMode: Bool = false
    @State private var hapticDetentTick: Int = 20

    public init(engine: WatchHealthKitBiometricEngine) {
        self.engine = engine
    }

    private var accentColor: Color {
        Color(
            hue: engine.activeAccentHue,
            saturation: isLuminanceReduced ? 0.48 : 0.78,
            brightness: isLuminanceReduced ? 0.74 : 0.98
        )
    }

    private var brainwaveBandTag: String {
        switch engine.binauralBeatHz {
        case ..<4.0: return "DELTA"
        case 4.0..<8.0: return "THETA"
        case 8.0..<13.0: return "ALPHA"
        case 13.0..<30.0: return "BETA"
        default: return "GAMMA"
        }
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 8) {
                headerFrequencyStrip

                mayerWaveResonancePacerRing
                    .frame(height: 112)

                hrvMetricsStrip

                doubleTapPrimaryActionRow
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .focusable(true)
        .digitalCrownRotation(
            isHabitCrownMode ? $crownHabitValue : $crownFrequencyHz,
            from: isHabitCrownMode ? 0.0 : 1.5,
            through: isHabitCrownMode ? Double(max(0, habits.count - 1)) : 40.0,
            by: isHabitCrownMode ? 1.0 : 0.5,
            sensitivity: .medium,
            isContinuous: false,
            isHapticFeedbackEnabled: true
        )
        .sensoryFeedback(.selection, trigger: hapticDetentTick)
        .onAppear {
            crownFrequencyHz = engine.binauralBeatHz
            hapticDetentTick = Int((crownFrequencyHz * 2.0).rounded())
            if let firstHabit = habits.first {
                engine.activeHabitTitle = firstHabit.title
                engine.activeAccentHue = firstHabit.accentHue
                engine.currentStreakDays = firstHabit.currentStreak
            }
        }
        .onChange(of: crownFrequencyHz) { _, newValue in
            engine.updateCrownBinauralFrequency(newValue)
            let step = Int((newValue * 2.0).rounded())
            if step != hapticDetentTick {
                hapticDetentTick = step
                WKInterfaceDevice.current().play(.click)
            }
            Task {
                _ = try? await engine.bridgeActor.sendRemoteCommand(.scrubBinauralFreq(Float(newValue)))
            }
        }
        .onChange(of: crownHabitValue) { _, newIdx in
            guard !habits.isEmpty else { return }
            let clamped = min(max(Int(newIdx.rounded()), 0), habits.count - 1)
            let selected = habits[clamped]
            if engine.activeHabitTitle != selected.title {
                engine.activeHabitTitle = selected.title
                engine.activeAccentHue = selected.accentHue
                engine.currentStreakDays = selected.currentStreak
                WKInterfaceDevice.current().play(.click)
            }
        }
    }

    // MARK: - 1. Crown Binaural Frequency & Band Header

    private var headerFrequencyStrip: some View {
        HStack(spacing: 4) {
            Button {
                isHabitCrownMode.toggle()
                WKInterfaceDevice.current().play(.click)
            } label: {
                HStack(spacing: 3) {
                    Circle()
                        .fill(engine.isSessionActive ? Color.green : Color.white.opacity(0.35))
                        .frame(width: 6, height: 6)
                    Text(isHabitCrownMode ? "ORBIT" : brainwaveBandTag)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(accentColor.opacity(0.28), in: Capsule())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 2)

            Text(String(format: "%.1f Hz", engine.binauralBeatHz))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(accentColor)
        }
    }

    // MARK: - 2. 0.10 Hz Mayer Wave Resonance Pacer (5.0s Inhale / 5.0s Exhale)

    private var mayerWaveResonancePacerRing: some View {
        let frameInterval = isLuminanceReduced ? 1.0 : (1.0 / 60.0)

        return TimelineView(.animation(minimumInterval: frameInterval)) { timeline in
            let nowSec = timeline.date.timeIntervalSinceReferenceDate
            // Exact 0.10 Hz Mayer baroreflex wave -> 10.0s period (5.0s rising inhale, 5.0s falling exhale)
            let cyclePhase = (nowSec * 0.10).truncatingRemainder(dividingBy: 1.0)
            let radians = 2.0 * Double.pi * cyclePhase - Double.pi * 0.5
            let breathExpansion = 0.5 * (1.0 + sin(radians))
            let isInhaling = cyclePhase < 0.5
            let phaseCountdownSeconds = isInhaling
                ? max(1, Int(ceil((0.5 - cyclePhase) * 10.0)))
                : max(1, Int(ceil((1.0 - cyclePhase) * 10.0)))

            ZStack {
                Canvas { context, size in
                    let center = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
                    let outerRadius = min(size.width, size.height) * 0.47
                    let pacerRadius = outerRadius * (0.60 + 0.35 * breathExpansion)

                    // Outer Vagal Coherence Track
                    let outerRect = CGRect(
                        x: center.x - outerRadius,
                        y: center.y - outerRadius,
                        width: outerRadius * 2.0,
                        height: outerRadius * 2.0
                    )
                    context.stroke(
                        Path(ellipseIn: outerRect),
                        with: .color(.white.opacity(isLuminanceReduced ? 0.12 : 0.18)),
                        lineWidth: 3.0
                    )

                    // Live Vagal Coherence Arc
                    let coherence = min(max(engine.latestMetrics.vagalCoherenceScore, 0.03), 1.0)
                    var coherenceArc = Path()
                    coherenceArc.addArc(
                        center: center,
                        radius: outerRadius,
                        startAngle: .degrees(-90),
                        endAngle: .degrees(-90 + 360.0 * coherence),
                        clockwise: false
                    )
                    context.stroke(
                        coherenceArc,
                        with: .color(accentColor),
                        style: StrokeStyle(lineWidth: 3.6, lineCap: .round)
                    )

                    // Expanding / Contracting 0.10 Hz Mayer Wave Pacer Circle
                    let pacerRect = CGRect(
                        x: center.x - pacerRadius,
                        y: center.y - pacerRadius,
                        width: pacerRadius * 2.0,
                        height: pacerRadius * 2.0
                    )
                    if !isLuminanceReduced {
                        context.fill(
                            Path(ellipseIn: pacerRect),
                            with: .color(accentColor.opacity(0.10 + 0.16 * breathExpansion))
                        )
                    }
                    context.stroke(
                        Path(ellipseIn: pacerRect),
                        with: .color(accentColor.opacity(isLuminanceReduced ? 0.48 : 0.88)),
                        lineWidth: 1.8
                    )

                    // Poincaré RR_n vs RR_{n+1} Phase-Space Scatter Inside Ring
                    let rrList = engine.latestSnapshot.recentRRSamples
                    if rrList.count >= 4 && !isLuminanceReduced {
                        let boxSpan = outerRadius * 0.68
                        let originX = center.x - boxSpan * 0.5
                        let originY = center.y - boxSpan * 0.5
                        let startIdx = max(0, rrList.count - 22)

                        for i in startIdx..<(rrList.count - 1) {
                            let xNorm = min(max((rrList[i].rrMilliseconds - 520.0) / 660.0, 0.0), 1.0)
                            let yNorm = min(max((rrList[i + 1].rrMilliseconds - 520.0) / 660.0, 0.0), 1.0)
                            let dot = CGRect(
                                x: originX + xNorm * boxSpan - 1.3,
                                y: originY + (1.0 - yNorm) * boxSpan - 1.3,
                                width: 2.6,
                                height: 2.6
                            )
                            context.fill(Path(ellipseIn: dot), with: .color(.cyan.opacity(0.55)))
                        }
                    }
                }

                VStack(spacing: 1) {
                    Text(engine.activeHabitTitle)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                        .frame(maxWidth: 86)

                    Text("\(Int((engine.latestMetrics.vagalCoherenceScore * 100.0).rounded()))%")
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)

                    Text(
                        isLuminanceReduced
                            ? "MAYER 0.10 HZ"
                            : "\(isInhaling ? "INHALE" : "EXHALE") · \(phaseCountdownSeconds)s"
                    )
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(accentColor)
                }
            }
        }
    }

    // MARK: - 3. Live BPM, RMSSD & Baevsky Stress Readouts

    private var hrvMetricsStrip: some View {
        HStack(spacing: 4) {
            compactMetricPill(
                title: "BPM",
                value: String(format: "%.0f", engine.latestMetrics.heartRateBPM)
            )
            compactMetricPill(
                title: "RMSSD",
                value: String(format: "%.0fms", engine.latestMetrics.rmssdMs)
            )
            compactMetricPill(
                title: "STRESS",
                value: String(format: "%.0f", engine.latestMetrics.baevskyStressIndex)
            )
        }
    }

    private func compactMetricPill(title: String, value: String) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
            Text(title)
                .font(.system(size: 7, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.62))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .background(
            .white.opacity(isLuminanceReduced ? 0.04 : 0.09),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    // MARK: - 4. watchOS 11 Double-Tap Primary Action Control

    private var doubleTapPrimaryActionRow: some View {
        HStack(spacing: 6) {
            Button {
                WKInterfaceDevice.current().play(.click)
                Task {
                    let wasActive = engine.isSessionActive
                    await engine.toggleEntrainmentSession()
                    _ = try? await engine.bridgeActor.sendRemoteCommand(
                        wasActive ? .pauseFocusSession : .startFocusSession
                    )
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: engine.isSessionActive ? "pause.fill" : "play.fill")
                        .font(.system(size: 11, weight: .bold))
                    Text(engine.isSessionActive ? "Pause" : "Entrain")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    accentColor.opacity(isLuminanceReduced ? 0.32 : 0.80),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .handGestureShortcut(.primaryAction)

            Button {
                WKInterfaceDevice.current().play(.success)
                let idx = min(max(Int(crownHabitValue.rounded()), 0), max(0, habits.count - 1))
                if !habits.isEmpty {
                    let targetHabit = habits[idx]
                    targetHabit.completedMinutesToday += 15
                    engine.currentStreakDays = max(1, targetHabit.currentStreak)
                    try? modelContext.save()
                    let targetID = targetHabit.habitID
                    Task {
                        _ = try? await engine.bridgeActor.sendRemoteCommand(.logQuickHabitPulse(targetID, 15))
                    }
                }
            } label: {
                Text("+15m")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }
}
#endif
