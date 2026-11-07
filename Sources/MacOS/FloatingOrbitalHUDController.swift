// MARK: - FILE: FloatingOrbitalHUDController.swift

import Foundation
import Observation

#if os(macOS)
import AppKit
import SwiftUI

// MARK: - Observable State Model Feeding Always-on-Top 120Hz Floating Orbital HUD

@Observable
@MainActor
public final class FloatingHUDViewModel {
    public var habitTitle: String = "Systems Architecture"
    public var presetName: String = "Nebula Deep Work"
    public var formattedRemainingTime: String = "25:00"
    public var timerProgress: Double = 0.0
    public var binauralBeatHz: Float = 14.0
    public var carrierFrequencyHz: Float = 216.0
    public var accentHue: Double = 0.54
    public var isPlaying: Bool = false
    public var audioRMS: Float = 0.0
    public var spectrumBars: [Float] = [Float](repeating: 0.0, count: 64)

    public var onTogglePlayback: (() -> Void)?
    public var onCyclePreset: (() -> Void)?
    public var onTriggerBloom: (() -> Void)?
    public var onCloseRequested: (() -> Void)?

    public init() {}
}

// MARK: - Draggable 120Hz Orbital Timer + Real-Time 64-Bin FFT Visualizer HUD Content

private struct FloatingOrbitalHUDContentView: View {
    @Bindable var viewModel: FloatingHUDViewModel

    private var accentColor: Color {
        Color(hue: viewModel.accentHue, saturation: 0.76, brightness: 0.98)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 120.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let orbitAngle = t * (viewModel.isPlaying ? 1.45 : 0.42)

            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    // 120Hz Orbital Ring + Orbiting Satellite Node + Countdown
                    ZStack {
                        Circle()
                            .stroke(.white.opacity(0.14), lineWidth: 4.5)

                        Circle()
                            .trim(from: 0.0, to: max(0.03, viewModel.timerProgress))
                            .stroke(
                                AngularGradient(
                                    colors: [accentColor, .cyan, accentColor],
                                    center: .center
                                ),
                                style: StrokeStyle(lineWidth: 4.5, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))

                        Circle()
                            .fill(accentColor.opacity(Double(0.16 + viewModel.audioRMS * 0.48)))
                            .frame(width: 34, height: 34)

                        // Live 120Hz Orbiting Keplerian Pip
                        Circle()
                            .fill(Color.white)
                            .frame(width: 6.5, height: 6.5)
                            .shadow(color: accentColor, radius: 4)
                            .offset(
                                x: CGFloat(cos(orbitAngle)) * 25.0,
                                y: CGFloat(sin(orbitAngle)) * 25.0
                            )

                        Text(viewModel.formattedRemainingTime)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 56, height: 56)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(viewModel.habitTitle)
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        Text(viewModel.presetName)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(1)

                        HStack(spacing: 6) {
                            Circle()
                                .fill(viewModel.isPlaying ? Color.green : Color.orange.opacity(0.78))
                                .frame(width: 6, height: 6)
                            Text(
                                String(
                                    format: "%.1f Hz Beat · %.0f Hz Carrier",
                                    viewModel.binauralBeatHz,
                                    viewModel.carrierFrequencyHz
                                )
                            )
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(accentColor)
                        }
                    }

                    Spacer(minLength: 4)

                    HStack(spacing: 6) {
                        Button {
                            viewModel.onTogglePlayback?()
                        } label: {
                            Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 30, height: 30)
                                .background(accentColor.opacity(0.85), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Start / Pause Focus Flow (⌘⇧F)")

                        Button {
                            viewModel.onTriggerBloom?()
                        } label: {
                            Image(systemName: "sparkles")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.90))
                                .frame(width: 26, height: 26)
                                .background(.white.opacity(0.13), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Trigger Harmonic Bloom (⌘⇧B)")

                        Button {
                            viewModel.onCyclePreset?()
                        } label: {
                            Image(systemName: "waveform")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.90))
                                .frame(width: 26, height: 26)
                                .background(.white.opacity(0.13), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Cycle Audio Preset (⌘⇧])")

                        Button {
                            viewModel.onCloseRequested?()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white.opacity(0.65))
                                .frame(width: 20, height: 20)
                                .background(.white.opacity(0.08), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Hide Floating Orbital HUD (⌘⇧H)")
                    }
                }

                // Real-Time 64-Bin FFT Spectrum Strip
                Canvas { context, size in
                    let bars = viewModel.spectrumBars
                    let count = max(1, bars.count)
                    let gap: CGFloat = 1.5
                    let barWidth = max(1.5, (size.width - CGFloat(count - 1) * gap) / CGFloat(count))

                    for i in 0..<count {
                        let idleWave = viewModel.isPlaying
                            ? 0.04
                            : (0.06 + 0.04 * sin(t * 2.2 + Double(i) * 0.22))
                        let amp = max(CGFloat(idleWave), CGFloat(min(max(bars[i], 0.0), 1.0)))
                        let h = max(2.0, amp * size.height)
                        let rect = CGRect(
                            x: CGFloat(i) * (barWidth + gap),
                            y: size.height - h,
                            width: barWidth,
                            height: h
                        )
                        let hue = (viewModel.accentHue + Double(i) * 0.0028).truncatingRemainder(dividingBy: 1.0)
                        context.fill(
                            Path(roundedRect: rect, cornerRadius: 1.2),
                            with: .color(Color(hue: hue, saturation: 0.80, brightness: 0.98))
                        )
                    }
                }
                .frame(height: 24)
                .padding(.horizontal, 4)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(width: 392, height: 112)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.black.opacity(0.46))
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                }
            )
        }
    }
}

// MARK: - Borderless Non-Activating HUD NSPanel Subclass

private final class NonActivatingOrbitalPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Always-on-Top Translucent PiP NSPanel Controller

@Observable
@MainActor
public final class FloatingOrbitalHUDController {
    public let viewModel = FloatingHUDViewModel()
    private var hudPanel: NSPanel?
    public private(set) var isHUDVisible: Bool = false

    public init() {
        viewModel.onCloseRequested = { [weak self] in
            self?.hideHUD()
        }
    }

    public func toggleHUD() {
        if isHUDVisible {
            hideHUD()
        } else {
            showHUD()
        }
    }

    public func showHUD() {
        let panel = ensurePanelCreated()
        panel.orderFrontRegardless()
        isHUDVisible = true
    }

    public func hideHUD() {
        hudPanel?.orderOut(nil)
        isHUDVisible = false
    }

    private func ensurePanelCreated() -> NSPanel {
        if let existing = hudPanel {
            return existing
        }

        let initialRect = Self.defaultTopRightFrame(width: 392, height: 112)
        let style: NSWindow.StyleMask = [
            .borderless,
            .nonactivatingPanel,
            .hudWindow
        ]

        let panel = NonActivatingOrbitalPanel(
            contentRect: initialRect,
            styleMask: style,
            backing: .buffered,
            defer: false
        )

        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        let hostingView = NSHostingView(rootView: FloatingOrbitalHUDContentView(viewModel: viewModel))
        hostingView.frame = NSRect(x: 0, y: 0, width: 392, height: 112)
        panel.contentView = hostingView

        self.hudPanel = panel
        return panel
    }

    private static func defaultTopRightFrame(width: CGFloat, height: CGFloat) -> NSRect {
        guard let visibleFrame = NSScreen.main?.visibleFrame else {
            return NSRect(x: 120, y: 680, width: width, height: height)
        }
        let originX = visibleFrame.maxX - width - 24
        let originY = visibleFrame.maxY - height - 20
        return NSRect(x: originX, y: originY, width: width, height: height)
    }
}
#endif
