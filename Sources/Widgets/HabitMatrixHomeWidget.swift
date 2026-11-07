// MARK: - FILE: HabitMatrixHomeWidget.swift

import SwiftUI
import WidgetKit
import AppIntents

public struct HabitMatrixWidgetEntry: TimelineEntry, Sendable {
    public let date: Date
    public let snapshot: SharedWidgetSnapshot

    public init(date: Date, snapshot: SharedWidgetSnapshot) {
        self.date = date
        self.snapshot = snapshot
    }
}

public struct HabitMatrixTimelineProvider: TimelineProvider {
    public init() {}

    public func placeholder(in context: Context) -> HabitMatrixWidgetEntry {
        HabitMatrixWidgetEntry(date: .now, snapshot: SharedWidgetSnapshot())
    }

    public func getSnapshot(in context: Context, completion: @escaping (HabitMatrixWidgetEntry) -> Void) {
        let entry = HabitMatrixWidgetEntry(date: .now, snapshot: SharedWidgetStateStore.read())
        completion(entry)
    }

    public func getTimeline(in context: Context, completion: @escaping (Timeline<HabitMatrixWidgetEntry>) -> Void) {
        let current = HabitMatrixWidgetEntry(date: .now, snapshot: SharedWidgetStateStore.read())
        let refreshDate = Calendar.current.date(byAdding: .minute, value: 20, to: .now) ?? .now.addingTimeInterval(1200)
        completion(Timeline(entries: [current], policy: .after(refreshDate)))
    }
}

public struct HabitMatrixHomeWidget: Widget {
    public static let kind: String = "com.aethersynth.flow.widget.habitMatrix"

    public init() {}

    public var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: HabitMatrixTimelineProvider()) { entry in
            HabitMatrixWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    LinearGradient(
                        colors: [
                            Color(red: 0.03, green: 0.04, blue: 0.09),
                            Color(hue: entry.snapshot.accentHue, saturation: 0.65, brightness: 0.25)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
        }
        .configurationDisplayName("Spatial Habit Matrix")
        .description("Track your orbital habit streak, 7-day flow heatmap, and log instant +15m pulses.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct HabitMatrixWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: HabitMatrixWidgetEntry

    var body: some View {
        let snap = entry.snapshot
        let accent = Color(hue: snap.accentHue, saturation: 0.72, brightness: 0.98)
        let ratio = min(1.0, Double(snap.completedMinutesToday) / Double(max(1, snap.targetMinutesToday)))

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .stroke(.white.opacity(0.15), lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: max(0.05, ratio))
                        .stroke(accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: snap.activeHabitSymbol)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 1) {
                    Text(snap.activeHabitTitle)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("\(snap.completedMinutesToday)/\(snap.targetMinutesToday)m · \(snap.currentStreak)d streak")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.68))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }

            // 7-Day Mini Heatmap Strip
            HStack(spacing: 5) {
                ForEach(Array(snap.recentSevenDayBuckets.enumerated()), id: \.offset) { _, level in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(bucketColor(level: level, hue: snap.accentHue))
                        .frame(maxWidth: .infinity)
                        .frame(height: family == .systemMedium ? 22 : 16)
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Button(intent: LogHabitPulseIntent(habitIDString: snap.activeHabitIDString, minutes: 15)) {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 10, weight: .bold))
                        Text("+15m Pulse")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(accent.opacity(0.45), in: Capsule())
                }
                .buttonStyle(.plain)

                if family == .systemMedium {
                    Button(intent: ToggleSpatialFocusIntent()) {
                        HStack(spacing: 4) {
                            Image(systemName: snap.isFocusRunning ? "pause.fill" : "play.fill")
                                .font(.system(size: 10, weight: .bold))
                            Text(snap.isFocusRunning ? "Pause Flow" : "Ignite \(Int(snap.binauralBeatHz))Hz")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(.white.opacity(0.14), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func bucketColor(level: Int, hue: Double) -> Color {
        switch level {
        case 0: return .white.opacity(0.09)
        case 1: return Color(hue: hue, saturation: 0.55, brightness: 0.58, opacity: 0.55)
        case 2: return Color(hue: hue, saturation: 0.65, brightness: 0.75, opacity: 0.78)
        case 3: return Color(hue: hue, saturation: 0.75, brightness: 0.90, opacity: 0.92)
        default: return Color(hue: hue, saturation: 0.68, brightness: 1.0, opacity: 1.0)
        }
    }
}
