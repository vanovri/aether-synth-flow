// MARK: - FILE: WatchSmartStackWidget.swift

import SwiftUI
import WidgetKit
import AppIntents

#if os(watchOS)

// MARK: - Smart Stack Timeline Entry & Provider

public struct WatchSmartStackEntry: TimelineEntry, Sendable {
    public let date: Date
    public let telemetry: WatchComplicationTelemetryPayload

    public init(date: Date, telemetry: WatchComplicationTelemetryPayload) {
        self.date = date
        self.telemetry = telemetry
    }
}

public struct WatchSmartStackTimelineProvider: TimelineProvider {
    public init() {}

    public func placeholder(in context: Context) -> WatchSmartStackEntry {
        WatchSmartStackEntry(date: .now, telemetry: WatchComplicationTelemetryPayload())
    }

    public func getSnapshot(in context: Context, completion: @escaping (WatchSmartStackEntry) -> Void) {
        completion(WatchSmartStackEntry(date: .now, telemetry: WatchComplicationStateStore.read()))
    }

    public func getTimeline(in context: Context, completion: @escaping (Timeline<WatchSmartStackEntry>) -> Void) {
        let currentEntry = WatchSmartStackEntry(date: .now, telemetry: WatchComplicationStateStore.read())
        let refreshDate = Calendar.current.date(byAdding: .minute, value: 10, to: .now)
            ?? Date.now.addingTimeInterval(600)
        completion(Timeline(entries: [currentEntry], policy: .after(refreshDate)))
    }
}

// MARK: - watchOS 11 Smart Stack Complication Widget (AccessoryRectangular & AccessoryCircular)

public struct WatchSmartStackWidget: Widget {
    public static let kind: String = "com.aethersynth.flow.watch.smartstack"

    public init() {}

    public var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: WatchSmartStackTimelineProvider()) { entry in
            WatchSmartStackEntryView(entry: entry)
                .containerBackground(for: .widget) {
                    Color.black.opacity(0.86)
                }
        }
        .configurationDisplayName("Vagal Coherence & Streak")
        .description("Live HRV vagal coherence percentage, Mayer resonance status, and daily habit streak.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline
        ])
    }
}

public struct WatchSmartStackEntryView: View {
    @Environment(\.widgetFamily) private var widgetFamily
    public let entry: WatchSmartStackEntry

    public init(entry: WatchSmartStackEntry) {
        self.entry = entry
    }

    public var body: some View {
        let data = entry.telemetry
        let coherence = min(max(data.vagalCoherenceScore, 0.0), 1.0)
        let coherencePercent = Int((coherence * 100.0).rounded())
        let accent = Color(hue: data.accentHue, saturation: 0.74, brightness: 0.98)

        switch widgetFamily {
        case .accessoryInline:
            Text("Coh \(coherencePercent)% · \(data.streakDays)d · \(Int(data.binauralBeatHz.rounded()))Hz")

        case .accessoryCircular:
            Gauge(value: coherence, in: 0.0...1.0) {
                Image(systemName: "waveform.path.ecg")
            } currentValueLabel: {
                Text("\(coherencePercent)%")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
            } minimumValueLabel: {
                Text("\(data.streakDays)d")
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
            } maximumValueLabel: {
                Text("100")
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
            }
            .gaugeStyle(.accessoryCircular)
            .tint(accent)

        default:
            // .accessoryRectangular Smart Stack Card with direct AppIntent launch button
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(accent)
                    Text("Vagal \(coherencePercent)%")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                    Spacer(minLength: 2)
                    Button(intent: LaunchBioEntrainmentSessionIntent()) {
                        HStack(spacing: 2) {
                            Image(systemName: data.isEntrainmentActive ? "bolt.heart.fill" : "play.fill")
                                .font(.system(size: 8, weight: .bold))
                            Text("\(data.streakDays)d")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(accent.opacity(0.28), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Gauge(value: coherence, in: 0.0...1.0) {
                    EmptyView()
                }
                .gaugeStyle(.accessoryLinear)
                .tint(accent)

                HStack(spacing: 6) {
                    Text(String(format: "%.0f BPM · %.0f ms RMSSD", data.heartRateBPM, data.rmssdMs))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Text(String(format: "%.1fHz", data.binauralBeatHz))
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(accent)
                }
            }
        }
    }
}

#endif
