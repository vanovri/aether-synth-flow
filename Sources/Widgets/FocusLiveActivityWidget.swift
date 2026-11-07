// MARK: - FILE: FocusLiveActivityWidget.swift

import SwiftUI
import WidgetKit
import AppIntents
#if canImport(ActivityKit) && os(iOS)
import ActivityKit

public struct FocusLiveActivityWidget: Widget {
    public init() {}

    public var body: some WidgetConfiguration {
        ActivityConfiguration(for: FocusActivityAttributes.self) { context in
            lockScreenBanner(context: context)
                .activityBackgroundTint(Color(red: 0.04, green: 0.05, blue: 0.11).opacity(0.92))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let accent = Color(hue: context.state.accentHue, saturation: 0.72, brightness: 0.98)

            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        Image(systemName: context.state.habitSymbolName)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(context.state.sessionTitle)
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .lineLimit(1)
                            Text(String(format: "%.1f Hz · %@", context.state.binauralBeatHz, context.state.presetName))
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.68))
                                .lineLimit(1)
                        }
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    liveCountdownLabel(state: context.state, fontSize: 20)
                        .foregroundStyle(.white)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 10) {
                        Button(intent: ToggleSpatialFocusIntent()) {
                            Label(
                                context.state.isRunning ? "Pause" : "Resume",
                                systemImage: context.state.isRunning ? "pause.fill" : "play.fill"
                            )
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                        }
                        .tint(accent)

                        Button(intent: CycleAudioPresetIntent()) {
                            Label("Next Freq", systemImage: "waveform.badge.plus")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .tint(.white.opacity(0.22))
                    }
                    .padding(.top, 4)
                }
            } compactLeading: {
                Image(systemName: context.state.habitSymbolName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(accent)
            } compactTrailing: {
                liveCountdownLabel(state: context.state, fontSize: 12)
                    .foregroundStyle(accent)
                    .frame(maxWidth: 54)
            } minimal: {
                Image(systemName: "waveform")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(accent)
            }
        }
    }

    @ViewBuilder
    private func lockScreenBanner(context: ActivityViewContext<FocusActivityAttributes>) -> some View {
        let state = context.state
        let accent = Color(hue: state.accentHue, saturation: 0.72, brightness: 0.98)

        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(accent.opacity(0.22))
                    .frame(width: 44, height: 44)
                Image(systemName: state.habitSymbolName)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(accent)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(state.sessionTitle)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(String(format: "%.1f Hz · %@", state.binauralBeatHz, state.presetName))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(accent)
                    .lineLimit(1)
            }

            Spacer()

            liveCountdownLabel(state: state, fontSize: 22)
                .foregroundStyle(.white)

            Button(intent: ToggleSpatialFocusIntent()) {
                Image(systemName: state.isRunning ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(accent)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
    }

    @ViewBuilder
    private func liveCountdownLabel(state: FocusActivityAttributes.ContentState, fontSize: CGFloat) -> some View {
        if state.isRunning, state.targetEndDate > .now {
            Text(timerInterval: Date.now...state.targetEndDate, countsDown: true)
                .monospacedDigit()
                .font(.system(size: fontSize, weight: .bold, design: .monospaced))
                .multilineTextAlignment(.trailing)
        } else {
            let secs = max(0, Int((state.pausedRemainingSeconds ?? 0).rounded()))
            Text(String(format: "%02d:%02d", secs / 60, secs % 60))
                .monospacedDigit()
                .font(.system(size: fontSize, weight: .bold, design: .monospaced))
        }
    }
}
#endif
