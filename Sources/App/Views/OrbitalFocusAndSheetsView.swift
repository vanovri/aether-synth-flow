// MARK: - FILE: OrbitalFocusAndSheetsView.swift

import SwiftUI
import SwiftData

// MARK: - 1. Orbital Focus Arena (RadialOrbitalLayout + Spatial Timer + Habit Satellites)

public struct OrbitalFocusArenaView: View {
    @Bindable public var coordinator: AetherAppCoordinator
    public let habits: [HabitNode]

    @State private var dragOrbitDelta: Double = 0.0
    @State private var committedDragOrbit: Double = 0.0

    private let durationPresets: [Int] = [15, 25, 45, 60, 90]

    public init(coordinator: AetherAppCoordinator, habits: [HabitNode]) {
        self.coordinator = coordinator
        self.habits = habits
    }

    private var selectedHabit: HabitNode? {
        habits.first(where: { $0.habitID == coordinator.selectedHabitID }) ?? habits.first
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 18) {
                RadialOrbitalLayout(
                    rotationRadians: coordinator.orbitalRotationAngle + committedDragOrbit + dragOrbitDelta,
                    radiusScale: coordinator.isTimerRunning ? 0.96 : 1.0
                ) {
                    centralTimerWell
                        .gravitationalCore(true)

                    ForEach(habits.filter { !$0.isArchived }) { habit in
                        habitSatelliteNode(habit)
                            .orbitalMass(habit.orbitalMass)
                    }
                }
                .frame(height: 386)
                .gesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { drag in
                            dragOrbitDelta = Double(drag.translation.width) * 0.0085
                        }
                        .onEnded { _ in
                            committedDragOrbit += dragOrbitDelta
                            dragOrbitDelta = 0
                        }
                )

                timerCommandDeck

                if let activeHabit = selectedHabit {
                    selectedHabitDetailStrip(activeHabit)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
    }

    private var centralTimerWell: some View {
        let hue = coordinator.activeAccentHue
        let ringAccent = Color(hue: hue, saturation: 0.72, brightness: 0.98)
        let ringSecondary = Color(hue: (hue + 0.16).truncatingRemainder(dividingBy: 1.0), saturation: 0.68, brightness: 0.95)

        return ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .overlay {
                    Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1)
                }
                .shadow(color: ringAccent.opacity(0.28 + Double(coordinator.liveAudioAmplitude) * 0.35), radius: 22)

            Circle()
                .stroke(.white.opacity(0.10), lineWidth: 9)
                .padding(12)

            Circle()
                .trim(from: 0, to: max(0.015, coordinator.focusProgress))
                .stroke(
                    AngularGradient(
                        colors: [ringAccent, ringSecondary, .white, ringAccent],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 9, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .padding(12)
                .animation(.linear(duration: 0.15), value: coordinator.focusProgress)

            VStack(spacing: 4) {
                Text(selectedHabit?.title ?? "Free Spatial Flow")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(1)
                    .frame(maxWidth: 122)

                Text(coordinator.formattedRemainingTime)
                    .font(.system(size: 34, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())

                HStack(spacing: 5) {
                    Circle()
                        .fill(coordinator.isTimerRunning ? Color.green : Color.white.opacity(0.35))
                        .frame(width: 6, height: 6)
                    Text(String(format: "%.1f Hz", coordinator.synthParameters.binauralBeatHz))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(ringAccent)
                }
            }
        }
        .frame(width: 184, height: 184)
    }

    private func habitSatelliteNode(_ habit: HabitNode) -> some View {
        let isSelected = (selectedHabit?.habitID == habit.habitID)
        let diameter = CGFloat(54.0 + (habit.orbitalMass - 0.5) * 14.0)
        let nodeColor = Color(hue: habit.accentHue, saturation: 0.72, brightness: 0.96)
        let ratio = min(1.0, habit.dailyCompletionRatio)

        return Button {
            coordinator.selectHabitSatellite(habit)
        } label: {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay {
                        Circle().fill(nodeColor.opacity(isSelected ? 0.30 : 0.12))
                    }

                Circle()
                    .trim(from: 0, to: max(0.04, ratio))
                    .stroke(
                        nodeColor,
                        style: StrokeStyle(lineWidth: isSelected ? 3.5 : 2.4, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .padding(3)

                VStack(spacing: 2) {
                    Image(systemName: habit.symbolName)
                        .font(.system(size: diameter * 0.30, weight: .semibold))
                        .foregroundStyle(.white)

                    if habit.currentStreak > 0 {
                        Text("\(habit.currentStreak)d")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.82))
                    }
                }
            }
            .frame(width: diameter, height: diameter)
            .scaleEffect(isSelected ? 1.10 : 1.0)
            .shadow(color: nodeColor.opacity(isSelected ? 0.55 : 0.20), radius: isSelected ? 14 : 6)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                Task { await coordinator.logQuickHabitIncrement(habit, minutes: 15) }
            } label: {
                Label("Log +15m Quick Pulse", systemImage: "bolt.badge.clock.fill")
            }

            Button {
                coordinator.editingHabitDraft = HabitNodeDTO(model: habit)
                coordinator.isHabitEditorPresented = true
            } label: {
                Label("Configure Orbit Node", systemImage: "slider.horizontal.3")
            }
        }
    }

    private var timerCommandDeck: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                ForEach(durationPresets, id: \.self) { mins in
                    let active = coordinator.selectedDurationMinutes == mins
                    Button {
                        guard !coordinator.isTimerRunning else { return }
                        coordinator.selectedDurationMinutes = mins
                        coordinator.hapticDirector.playSegmentSnap()
                    } label: {
                        Text("\(mins)m")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(active ? .white : .white.opacity(0.60))
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity)
                            .background(
                                active
                                    ? Color(hue: coordinator.activeAccentHue, saturation: 0.68, brightness: 0.88).opacity(0.45)
                                    : Color.white.opacity(0.06),
                                in: Capsule()
                            )
                            .overlay {
                                Capsule()
                                    .strokeBorder(.white.opacity(active ? 0.45 : 0.10), lineWidth: 0.8)
                            }
                    }
                    .buttonStyle(.plain)
                    .opacity(coordinator.isTimerRunning && !active ? 0.45 : 1.0)
                }
            }

            HStack(spacing: 12) {
                Button {
                    coordinator.toggleFocusTimer(linkedHabitTitle: selectedHabit?.title)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: coordinator.isTimerRunning ? "pause.fill" : "play.fill")
                            .font(.system(size: 15, weight: .bold))
                        Text(coordinator.isTimerRunning
                             ? "Pause Flow"
                             : (coordinator.elapsedSeconds > 0 ? "Resume Flow" : "Ignite Spatial Focus"))
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        LinearGradient(
                            colors: [
                                Color(hue: coordinator.activeAccentHue, saturation: 0.72, brightness: 0.92),
                                Color(hue: (coordinator.activeAccentHue + 0.12).truncatingRemainder(dividingBy: 1.0), saturation: 0.78, brightness: 0.76)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(.white.opacity(0.35), lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)

                if coordinator.elapsedSeconds > 0 || coordinator.isTimerRunning {
                    Button {
                        coordinator.finishEarlyOrResetFocusTimer(activeHabitTitle: selectedHabit?.title)
                    } label: {
                        Image(systemName: coordinator.elapsedSeconds >= 30 ? "checkmark.seal.fill" : "arrow.counterclockwise")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 50, height: 48)
                            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    coordinator.editingHabitDraft = nil
                    coordinator.isHabitEditorPresented = true
                    coordinator.hapticDirector.playSegmentSnap()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 50, height: 48)
                        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .aetherGlass(accentHue: coordinator.activeAccentHue, audioEnergy: coordinator.liveAudioAmplitude, cornerRadius: 24)
    }

    private func selectedHabitDetailStrip(_ habit: HabitNode) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color(hue: habit.accentHue, saturation: 0.72, brightness: 0.90).opacity(0.28))
                    .frame(width: 44, height: 44)
                Image(systemName: habit.symbolName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(habit.title)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("\(habit.completedMinutesToday)/\(habit.targetMinutesPerDay)m today · Streak \(habit.currentStreak)d (Best \(habit.longestStreak)d)")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.68))
            }

            Spacer()

            Button {
                Task { await coordinator.logQuickHabitIncrement(habit, minutes: 15) }
            } label: {
                Text("+15m")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(
                        Color(hue: habit.accentHue, saturation: 0.70, brightness: 0.88).opacity(0.45),
                        in: Capsule()
                    )
            }
            .buttonStyle(.plain)

            Button {
                coordinator.editingHabitDraft = HabitNodeDTO(model: habit)
                coordinator.isHabitEditorPresented = true
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .aetherGlass(accentHue: habit.accentHue, audioEnergy: coordinator.liveAudioAmplitude * 0.5, cornerRadius: 20)
    }
}

// MARK: - 2. Real-Time Synth Lab View (vDSP 64-Bar FFT + AirPods Head-Tracking + XY Pad + Mixer)

public struct SynthLabPanelView: View {
    @Bindable public var coordinator: AetherAppCoordinator
    public let presets: [AudioPreset]

    public init(coordinator: AetherAppCoordinator, presets: [AudioPreset]) {
        self.coordinator = coordinator
        self.presets = presets
    }

    private var brainwaveBandLabel: String {
        let hz = coordinator.synthParameters.binauralBeatHz
        switch hz {
        case ..<4.0: return "DELTA · Deep Restorative"
        case 4.0..<8.0: return "THETA · Meditative Flow"
        case 8.0..<13.0: return "ALPHA · Calm Immersion"
        case 13.0..<30.0: return "BETA · Analytical Focus"
        default: return "GAMMA · Peak Binding"
        }
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                presetHeaderCard
                realtimeSpectrumAndSpatialCard
                filterXYPadCard
                oscillatorAndMixerCard
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
    }

    private var presetHeaderCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Procedural Acoustic Engine")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(brainwaveBandLabel)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(hue: coordinator.activeAccentHue, saturation: 0.60, brightness: 1.0))
                }

                Spacer()

                Button {
                    coordinator.isSavePresetSheetPresented = true
                    coordinator.hapticDirector.playSegmentSnap()
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(.white.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    coordinator.toggleStandaloneSynth()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: coordinator.isSynthPlaying ? "speaker.wave.3.fill" : "speaker.slash.fill")
                        Text(coordinator.isSynthPlaying ? "Live" : "Audition")
                    }
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        coordinator.isSynthPlaying
                            ? Color(hue: coordinator.activeAccentHue, saturation: 0.72, brightness: 0.90).opacity(0.65)
                            : Color.white.opacity(0.12),
                        in: Capsule()
                    )
                }
                .buttonStyle(.plain)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(presets) { preset in
                        let dto = AudioPresetDTO(model: preset)
                        let selected = coordinator.selectedPresetID == preset.presetID
                        Button {
                            coordinator.selectAudioPreset(dto)
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: dto.category.symbolName)
                                    .font(.system(size: 12, weight: .semibold))
                                Text(dto.name)
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                            }
                            .foregroundStyle(selected ? .white : .white.opacity(0.68))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 9)
                            .background(
                                selected
                                    ? Color(hue: coordinator.activeAccentHue, saturation: 0.70, brightness: 0.88).opacity(0.45)
                                    : Color.white.opacity(0.07),
                                in: Capsule()
                            )
                            .overlay {
                                Capsule()
                                    .strokeBorder(.white.opacity(selected ? 0.50 : 0.12), lineWidth: 0.8)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(16)
        .aetherGlass(accentHue: coordinator.activeAccentHue, audioEnergy: coordinator.liveAudioAmplitude, cornerRadius: 24)
    }

    private var realtimeSpectrumAndSpatialCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("64-Bin vDSP Hann Spectrum", systemImage: "waveform.path")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.90))
                Spacer()
                Text(coordinator.dominantSpectrumHz > 0
                     ? String(format: "Peak %.0f Hz", coordinator.dominantSpectrumHz)
                     : "Idle")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.72))
            }

            Canvas { context, size in
                let bars = coordinator.spectrumBars
                guard !bars.isEmpty else { return }
                let count = bars.count
                let spacing: CGFloat = 2.0
                let barWidth = max(1.5, (size.width - CGFloat(count - 1) * spacing) / CGFloat(count))

                for idx in 0..<count {
                    let level = CGFloat(min(max(bars[idx], 0.03), 1.0))
                    let barHeight = max(3.0, level * size.height)
                    let x = CGFloat(idx) * (barWidth + spacing)
                    let y = size.height - barHeight
                    let rect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
                    let hueShift = (coordinator.activeAccentHue + Double(idx) * 0.003).truncatingRemainder(dividingBy: 1.0)
                    let color = Color(hue: hueShift, saturation: 0.72, brightness: 0.98, opacity: 0.45 + Double(level) * 0.55)
                    context.fill(Path(roundedRect: rect, cornerRadius: barWidth * 0.5), with: .color(color))
                }
            }
            .frame(height: 68)
            .padding(.vertical, 4)

            Divider().overlay(.white.opacity(0.12))

            // AirPods Pro / Max Spatial Head-Tracking Control Row
            HStack(spacing: 10) {
                Image(systemName: "airpodspro")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color(hue: coordinator.activeAccentHue, saturation: 0.65, brightness: 1.0))

                VStack(alignment: .leading, spacing: 2) {
                    Text("AirPods Spatial Head-Tracking")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(coordinator.mediaAndMotion.isHeadTrackingActive
                         ? String(format: "Yaw %+.0f° · Pitch %+.0f° · Pan %+.2f",
                                  coordinator.mediaAndMotion.currentYawDegrees,
                                  coordinator.mediaAndMotion.currentPitchDegrees,
                                  coordinator.synthParameters.spatialPanOffset)
                         : (coordinator.mediaAndMotion.isHeadTrackingAvailable
                            ? "Ready to anchor soundstage"
                            : "Connect supported AirPods for IMU pan"))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.60))
                }

                Spacer()

                if coordinator.mediaAndMotion.isHeadTrackingActive {
                    Button("Center") {
                        coordinator.mediaAndMotion.recenterHeadReference()
                        coordinator.hapticDirector.playSegmentSnap()
                    }
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.white.opacity(0.12), in: Capsule())
                    .buttonStyle(.plain)
                }

                Toggle(
                    "",
                    isOn: Binding(
                        get: { coordinator.isHeadTrackingEnabled },
                        set: { coordinator.toggleHeadTracking($0) }
                    )
                )
                .labelsHidden()
                .tint(Color(hue: coordinator.activeAccentHue, saturation: 0.72, brightness: 0.92))
            }
        }
        .padding(16)
        .aetherGlass(accentHue: coordinator.activeAccentHue, audioEnergy: coordinator.liveAudioAmplitude, cornerRadius: 24)
    }

    private var filterXYPadCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("24dB TPT Resonant Low-Pass Pad", systemImage: "dial.medium.fill")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.90))
                Spacer()
                Text(String(format: "%.0f Hz · Q %.2f", coordinator.synthParameters.filterCutoffHz, coordinator.synthParameters.filterResonance))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
            }

            GeometryReader { geo in
                let size = geo.size
                let minLog = log(Float(100.0))
                let maxLog = log(Float(8000.0))
                let clampedCut = min(max(coordinator.synthParameters.filterCutoffHz, 100.0), 8000.0)
                let normX = CGFloat((log(clampedCut) - minLog) / (maxLog - minLog))
                let normY = CGFloat(1.0 - (coordinator.synthParameters.filterResonance - 0.05) / 0.88)

                let puckPoint = CGPoint(
                    x: min(max(normX * size.width, 14), size.width - 14),
                    y: min(max(normY * size.height, 14), size.height - 14)
                )

                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.black.opacity(0.32))

                    Path { p in
                        for idx in 1...3 {
                            let fx = size.width * CGFloat(idx) / 4.0
                            let fy = size.height * CGFloat(idx) / 4.0
                            p.move(to: CGPoint(x: fx, y: 0))
                            p.addLine(to: CGPoint(x: fx, y: size.height))
                            p.move(to: CGPoint(x: 0, y: fy))
                            p.addLine(to: CGPoint(x: size.width, y: fy))
                        }
                        p.move(to: CGPoint(x: puckPoint.x, y: 0))
                        p.addLine(to: CGPoint(x: puckPoint.x, y: size.height))
                        p.move(to: CGPoint(x: 0, y: puckPoint.y))
                        p.addLine(to: CGPoint(x: size.width, y: puckPoint.y))
                    }
                    .stroke(.white.opacity(0.10), lineWidth: 0.8)

                    Circle()
                        .fill(Color(hue: coordinator.activeAccentHue, saturation: 0.78, brightness: 1.0))
                        .frame(width: 24, height: 24)
                        .shadow(color: Color(hue: coordinator.activeAccentHue, saturation: 0.8, brightness: 1.0), radius: 12)
                        .overlay {
                            Circle().strokeBorder(.white, lineWidth: 2)
                        }
                        .position(puckPoint)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            let xRatio = Float(min(max(drag.location.x / max(size.width, 1), 0), 1))
                            let yRatio = Float(min(max(drag.location.y / max(size.height, 1), 0), 1))

                            let newCutoff = exp(minLog + xRatio * (maxLog - minLog))
                            let newResonance = 0.05 + (1.0 - yRatio) * 0.88

                            var next = coordinator.synthParameters
                            next.filterCutoffHz = newCutoff
                            next.filterResonance = newResonance
                            coordinator.pushSynthParameters(next)
                            coordinator.hapticDirector.playRippleTouch(normalizedVelocity: 0.35, normalizedY: yRatio)
                        }
                )
            }
            .frame(height: 148)
        }
        .padding(16)
        .aetherGlass(accentHue: coordinator.activeAccentHue, audioEnergy: coordinator.liveAudioAmplitude, cornerRadius: 24)
    }

    private var oscillatorAndMixerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            synthSliderRow(
                title: "Carrier Fundamental",
                valueText: String(format: "%.0f Hz", coordinator.synthParameters.carrierFrequencyHz),
                value: Binding(
                    get: { Double(coordinator.synthParameters.carrierFrequencyHz) },
                    set: { val in
                        var p = coordinator.synthParameters
                        p.carrierFrequencyHz = Float(val)
                        coordinator.pushSynthParameters(p)
                    }
                ),
                range: 96...432
            )

            synthSliderRow(
                title: "Binaural Beat Offset",
                valueText: String(format: "%.1f Hz", coordinator.synthParameters.binauralBeatHz),
                value: Binding(
                    get: { Double(coordinator.synthParameters.binauralBeatHz) },
                    set: { val in
                        var p = coordinator.synthParameters
                        p.binauralBeatHz = Float(val)
                        coordinator.pushSynthParameters(p)
                    }
                ),
                range: 1.0...44.0
            )

            Divider().overlay(.white.opacity(0.12))

            synthSliderRow(
                title: "Binaural Sine Pair",
                valueText: "\(Int((coordinator.synthParameters.binauralMix * 100).rounded()))%",
                value: Binding(
                    get: { Double(coordinator.synthParameters.binauralMix) },
                    set: { val in
                        var p = coordinator.synthParameters
                        p.binauralMix = Float(val)
                        coordinator.pushSynthParameters(p)
                    }
                ),
                range: 0...1
            )

            synthSliderRow(
                title: "Harmonic Ambient Pad",
                valueText: "\(Int((coordinator.synthParameters.padMix * 100).rounded()))%",
                value: Binding(
                    get: { Double(coordinator.synthParameters.padMix) },
                    set: { val in
                        var p = coordinator.synthParameters
                        p.padMix = Float(val)
                        coordinator.pushSynthParameters(p)
                    }
                ),
                range: 0...1
            )

            synthSliderRow(
                title: "1/f Pink Noise Floor",
                valueText: "\(Int((coordinator.synthParameters.pinkNoiseMix * 100).rounded()))%",
                value: Binding(
                    get: { Double(coordinator.synthParameters.pinkNoiseMix) },
                    set: { val in
                        var p = coordinator.synthParameters
                        p.pinkNoiseMix = Float(val)
                        coordinator.pushSynthParameters(p)
                    }
                ),
                range: 0...1
            )

            synthSliderRow(
                title: "Unison Pad Detune",
                valueText: String(format: "%.1f ct", coordinator.synthParameters.padDetuneCents),
                value: Binding(
                    get: { Double(coordinator.synthParameters.padDetuneCents) },
                    set: { val in
                        var p = coordinator.synthParameters
                        p.padDetuneCents = Float(val)
                        coordinator.pushSynthParameters(p)
                    }
                ),
                range: 0...30
            )

            synthSliderRow(
                title: "Master Output Gain",
                valueText: "\(Int((coordinator.synthParameters.masterGain * 100).rounded()))%",
                value: Binding(
                    get: { Double(coordinator.synthParameters.masterGain) },
                    set: { val in
                        var p = coordinator.synthParameters
                        p.masterGain = Float(val)
                        coordinator.pushSynthParameters(p, clearingPresetSelection: false)
                    }
                ),
                range: 0.05...1.0
            )
        }
        .padding(16)
        .aetherGlass(accentHue: coordinator.activeAccentHue, audioEnergy: coordinator.liveAudioAmplitude * 0.5, cornerRadius: 24)
    }

    private func synthSliderRow(
        title: String,
        valueText: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        VStack(spacing: 5) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.84))
                Spacer()
                Text(valueText)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color(hue: coordinator.activeAccentHue, saturation: 0.55, brightness: 1.0))
            }
            Slider(value: value, in: range)
                .tint(Color(hue: coordinator.activeAccentHue, saturation: 0.72, brightness: 0.96))
        }
    }
}

// MARK: - 3. Interactive Sheet Flows

public struct CreateOrEditHabitSheet: View {
    public let existingDraft: HabitNodeDTO?
    public let onSave: (HabitNodeDTO) async -> Void
    public let onDelete: ((UUID) async -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var symbolName: String
    @State private var accentHue: Double
    @State private var orbitalMass: Double
    @State private var targetMinutes: Int

    private let curatedSymbols: [String] = [
        "cpu.fill", "sparkles.rectangle.stack.fill", "wind.circle.fill", "book.closed.fill",
        "waveform.path.ecg", "brain.head.profile", "paintbrush.pointed.fill", "figure.mind.and.body",
        "terminal.fill", "function", "atom", "pianokeys.inverse"
    ]

    public init(
        existingDraft: HabitNodeDTO?,
        onSave: @escaping (HabitNodeDTO) async -> Void,
        onDelete: ((UUID) async -> Void)? = nil
    ) {
        self.existingDraft = existingDraft
        self.onSave = onSave
        self.onDelete = onDelete
        self._title = State(initialValue: existingDraft?.title ?? "")
        self._symbolName = State(initialValue: existingDraft?.symbolName ?? "cpu.fill")
        self._accentHue = State(initialValue: existingDraft?.accentHue ?? 0.56)
        self._orbitalMass = State(initialValue: existingDraft?.orbitalMass ?? 1.25)
        self._targetMinutes = State(initialValue: existingDraft?.targetMinutesPerDay ?? 45)
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Habit Identity") {
                    TextField("Node Title (e.g. Compiler Design)", text: $title)
                    Stepper("Daily Target: \(targetMinutes) min", value: $targetMinutes, in: 5...240, step: 5)
                }

                Section("Gravitational Mass & Spectral Hue") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Orbital Mass")
                            Spacer()
                            Text(String(format: "%.2f M☉", orbitalMass))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $orbitalMass, in: 0.5...2.4)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Spectral Hue")
                            Spacer()
                            Circle()
                                .fill(Color(hue: accentHue, saturation: 0.75, brightness: 0.95))
                                .frame(width: 18, height: 18)
                        }
                        Slider(value: $accentHue, in: 0.0...0.98)
                            .tint(Color(hue: accentHue, saturation: 0.75, brightness: 0.95))
                    }
                }

                Section("Orbital Glyph") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(curatedSymbols, id: \.self) { sym in
                            let selected = (symbolName == sym)
                            Button {
                                symbolName = sym
                            } label: {
                                Image(systemName: sym)
                                    .font(.system(size: 18, weight: .semibold))
                                    .frame(width: 40, height: 40)
                                    .foregroundStyle(selected ? .white : .primary)
                                    .background(
                                        selected
                                            ? Color(hue: accentHue, saturation: 0.75, brightness: 0.90)
                                            : Color.secondary.opacity(0.14),
                                        in: Circle()
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }

                if let existingDraft, let onDelete {
                    Section {
                        Button(role: .destructive) {
                            Task {
                                await onDelete(existingDraft.habitID)
                                dismiss()
                            }
                        } label: {
                            Label("Decommission Habit Node", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle(existingDraft == nil ? "New Habit Satellite" : "Edit Habit Satellite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        let dto = HabitNodeDTO(
                            habitID: existingDraft?.habitID ?? UUID(),
                            title: cleanTitle.isEmpty ? "Spatial Habit" : cleanTitle,
                            symbolName: symbolName,
                            accentHue: accentHue,
                            orbitalMass: orbitalMass,
                            targetMinutesPerDay: targetMinutes,
                            completedMinutesToday: existingDraft?.completedMinutesToday ?? 0,
                            currentStreak: existingDraft?.currentStreak ?? 0,
                            longestStreak: existingDraft?.longestStreak ?? 0,
                            lastCompletedDayKey: existingDraft?.lastCompletedDayKey,
                            sortOrder: existingDraft?.sortOrder ?? 0,
                            isArchived: false,
                            updatedAt: .now,
                            revision: (existingDraft?.revision ?? 0) + 1
                        )
                        Task {
                            await onSave(dto)
                            dismiss()
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

public struct SaveAudioPresetSheet: View {
    public let currentParameters: SynthParameters
    public let onSave: (String, FocusCategory) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var presetName: String = ""
    @State private var category: FocusCategory = .deepWork

    public init(
        currentParameters: SynthParameters,
        onSave: @escaping (String, FocusCategory) async -> Void
    ) {
        self.currentParameters = currentParameters
        self.onSave = onSave
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Preset Metadata") {
                    TextField("Preset Name (e.g. Midnight Cortex)", text: $presetName)
                    Picker("Cognitive Mode", selection: $category) {
                        ForEach(FocusCategory.allCases) { cat in
                            Label(cat.displayName, systemImage: cat.symbolName).tag(cat)
                        }
                    }
                }

                Section("Captured DSP Snapshot") {
                    LabeledContent("Carrier / Binaural", value: String(format: "%.0f Hz / %.1f Hz", currentParameters.carrierFrequencyHz, currentParameters.binauralBeatHz))
                    LabeledContent("TPT SVF Cutoff", value: String(format: "%.0f Hz (Q %.2f)", currentParameters.filterCutoffHz, currentParameters.filterResonance))
                    LabeledContent("Layer Mix (Bin/Pad/Pink)", value: "\(Int(currentParameters.binauralMix * 100))% / \(Int(currentParameters.padMix * 100))% / \(Int(currentParameters.pinkNoiseMix * 100))%")
                }
            }
            .navigationTitle("Save Synth Preset")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let fallback = presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "\(category.displayName) \(Int(currentParameters.binauralBeatHz))Hz"
                            : presetName
                        Task {
                            await onSave(fallback, category)
                            dismiss()
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

public struct SessionSummarySheet: View {
    public let session: FocusSessionDTO
    public let accentHue: Double
    public let onCommit: (String) async -> Void

    @State private var reflectionNotes: String = ""

    public init(
        session: FocusSessionDTO,
        accentHue: Double,
        onCommit: @escaping (String) async -> Void
    ) {
        self.session = session
        self.accentHue = accentHue
        self.onCommit = onCommit
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: session.completed ? "sparkles" : "checkmark.circle.fill")
                    .font(.system(size: 42, weight: .bold))
                    .foregroundStyle(Color(hue: accentHue, saturation: 0.72, brightness: 0.95))
                    .padding(.top, 12)

                VStack(spacing: 4) {
                    Text(session.completed ? "Cycle Complete" : "Partial Cycle Logged")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    Text(session.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    summaryStat(
                        label: "Duration",
                        value: "\(max(1, Int((session.actualDurationSeconds / 60.0).rounded())))m"
                    )
                    summaryStat(
                        label: "Coherence",
                        value: "\(Int((session.focusQualityScore * 100.0).rounded()))%"
                    )
                    summaryStat(
                        label: "Beat Freq",
                        value: String(format: "%.1fHz", session.beatFrequencyHz)
                    )
                }

                TextField("Session telemetry notes...", text: $reflectionNotes, axis: .vertical)
                    .lineLimit(3...5)
                    .textFieldStyle(.roundedBorder)

                Button {
                    Task { await onCommit(reflectionNotes) }
                } label: {
                    Text("Commit to Telemetry Ledger")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            Color(hue: accentHue, saturation: 0.72, brightness: 0.90),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)
            }
            .padding(20)
            .navigationTitle("Focus Telemetry")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled()
    }

    private func summaryStat(label: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .monospaced))
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
