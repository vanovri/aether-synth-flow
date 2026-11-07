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

                orbitalAutonomicStatusStrip

                orbitalQuantumCausticsOverlayCard

                if let activeHabit = selectedHabit {
                    selectedHabitDetailStrip(activeHabit)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
    }

    @ViewBuilder
    private var centralTimerWell: some View {
        if coordinator.use3DRaymarchedCore {
            OrbitalSDFCoreView(
                title: selectedHabit?.title ?? "Free Spatial Flow",
                formattedRemainingTime: coordinator.formattedRemainingTime,
                binauralBeatHz: coordinator.synthParameters.binauralBeatHz,
                isTimerRunning: coordinator.isTimerRunning,
                focusProgress: coordinator.focusProgress,
                accentHue: coordinator.activeAccentHue,
                lowEnergy: coordinator.liveLowBandEnergy,
                midEnergy: coordinator.liveMidBandEnergy,
                highEnergy: coordinator.liveHighBandEnergy,
                diameter: 188
            )
            .contextMenu {
                Button {
                    coordinator.use3DRaymarchedCore.toggle()
                    coordinator.hapticDirector.playSegmentSnap()
                } label: {
                    Label("Switch to 2D Glass Ring", systemImage: "circle.dashed")
                }
            }
        } else {
            let hue = coordinator.activeAccentHue
            let ringAccent = Color(hue: hue, saturation: 0.72, brightness: 0.98)
            let ringSecondary = Color(hue: (hue + 0.16).truncatingRemainder(dividingBy: 1.0), saturation: 0.68, brightness: 0.95)

            ZStack {
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
            .contextMenu {
                Button {
                    coordinator.use3DRaymarchedCore.toggle()
                    coordinator.hapticDirector.playSegmentSnap()
                } label: {
                    Label("Switch to 3D Raymarched SDF Core", systemImage: "cube.transparent.fill")
                }
            }
        }
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

    private var orbitalAutonomicStatusStrip: some View {
        let accent = Color(hue: coordinator.activeAccentHue, saturation: 0.72, brightness: 0.98)
        let bpmText = coordinator.latestBiometricSnapshot.map { String(format: "%.0f BPM", $0.heartRateBPM) } ?? "Wrist Standby"
        let rmssdText = coordinator.latestHRVMetrics.map { String(format: "%.0fms RMSSD", $0.rmssdMs) } ?? "HRV Idle"
        let cohText = coordinator.latestHRVMetrics.map { "\(Int(($0.rsaCoherenceScore * 100.0).rounded()))% Coh" } ?? "--"

        return HStack(spacing: 10) {
            Image(systemName: coordinator.isWatchCounterpartReachable ? "applewatch.radiowaves.left.and.right" : "waveform.path.ecg")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(coordinator.isBioEntrainmentEnabled ? Color.green : accent)

            VStack(alignment: .leading, spacing: 2) {
                Text(coordinator.isBioEntrainmentEnabled ? "Closed-Loop Bio-Entrainment Active" : "Autonomic Watch Telemetry")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("\(bpmText) · \(rmssdText) · \(cohText)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.68))
            }

            Spacer()

            Button {
                coordinator.toggleBioEntrainmentClosedLoop(!coordinator.isBioEntrainmentEnabled)
            } label: {
                Text(coordinator.isBioEntrainmentEnabled ? "Bio-Locked" : "Engage Loop")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(
                        coordinator.isBioEntrainmentEnabled
                            ? accent.opacity(0.55)
                            : Color.white.opacity(0.12),
                        in: Capsule()
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(13)
        .aetherGlass(accentHue: coordinator.activeAccentHue, audioEnergy: coordinator.liveAudioAmplitude * 0.4, cornerRadius: 20)
    }

    private var orbitalQuantumCausticsOverlayCard: some View {
        let accent = Color(hue: coordinator.activeAccentHue, saturation: 0.76, brightness: 0.98)
        let mps = coordinator.latestMPSTelemetry
        let svn = mps?.vonNeumannEntropyNats ?? 0.0
        let purity = mps?.renyi2Purity ?? 1.0
        let spindleRatio = coordinator.latestSPWVDResult?.corticalSpindlePowerRatio ?? 0.0

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "atom")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.cyan)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Quantum MPS Entanglement Gauge & Acousto-Optic Caustics")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(
                        String(
                            format: "S_vN %.3f nats · Purity P₂ %.2f · Spindle 11–16Hz %.0f%%",
                            svn,
                            purity,
                            spindleRatio * 100.0
                        )
                    )
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.72))
                }

                Spacer()

                Toggle("Caustics", isOn: $coordinator.showOpticalCausticsMode)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.cyan)
                    .tint(accent)
                    .fixedSize()
            }

            if coordinator.showOpticalCausticsMode {
                SpectralCausticsView(
                    waveTankController: coordinator.waveTankController,
                    spectrumBars: coordinator.spectrumBars,
                    dominantSpectrumHz: Double(coordinator.synthParameters.carrierFrequencyHz),
                    liveAudioAmplitude: Double(coordinator.liveAudioAmplitude),
                    photonCount: 2_048
                )
                .frame(height: 112)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .padding(13)
        .aetherGlass(accentHue: coordinator.activeAccentHue, audioEnergy: coordinator.liveAudioAmplitude * 0.45, cornerRadius: 20)
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
                Phase3AndDSPExpansionCardView(coordinator: coordinator)
                sphericalHRTFRadarAndRoomCard
                mpsGraphNeuralTrainerCard
                bioEntrainmentInspectorCard
                rayTracedAcousticsInspectorCard
                neuralLatentDiffusionInspectorCard
                distributedOrchestraArrayCard
                fdtdAcousticWaveguideTankCard
                eegBCIBispectrumAndPACCard
                Phase9WaveguideAndCorticalEEGCardView(coordinator: coordinator)
                Phase10QuantumAndCapstoneCardView(coordinator: coordinator)
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

    // MARK: - 3D Spherical Binaural Radar, Elevation Dome & Shoebox Room Acoustics Card

    private var sphericalHRTFRadarAndRoomCard: some View {
        let accent = Color(hue: coordinator.activeAccentHue, saturation: 0.74, brightness: 0.98)
        let azDeg = coordinator.synthParameters.hrtfAzimuthDeg
        let elDeg = coordinator.synthParameters.hrtfElevationDeg
        let distM = coordinator.synthParameters.hrtfDistanceMeters
        let pose = BinauralSourcePose(azimuthDeg: azDeg, elevationDeg: elDeg, distanceMeters: distM)
        let itdMicros = KEMARHRIRSynthesizer.woodworthSchlosbergITDSeconds(
            azimuthRad: pose.azimuthRadians,
            elevationRad: pose.elevationRadians
        ) * 1_000_000.0
        let notch1Hz = KEMARHRIRSynthesizer.primaryPinnaNotchFrequencyHz(elevationRad: pose.elevationRadians)

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("3D KEMAR HRTF & Shoebox Room", systemImage: "ear.and.waveform")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Spacer()

                Toggle(
                    "",
                    isOn: Binding(
                        get: { coordinator.synthParameters.isHRTFSpatializerEnabled },
                        set: { coordinator.toggleHRTFSpatializer($0) }
                    )
                )
                .labelsHidden()
                .tint(accent)
            }

            HStack(spacing: 8) {
                bioMetricPill(title: "Azimuth θ", value: String(format: "%+.0f°", azDeg))
                bioMetricPill(title: "Elevation φ", value: String(format: "%+.0f°", elDeg))
                bioMetricPill(title: "Distance r", value: String(format: "%.2f m", distM))
                bioMetricPill(title: "ITD / Pinna", value: String(format: "%+.0fµs · %.1fk", itdMicros, notch1Hz / 1000.0))
            }

            GeometryReader { geo in
                let size = geo.size
                let center = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
                let maxRadius = min(size.width, size.height) * 0.44
                let minDist: Float = 0.15
                let maxDist: Float = 6.0
                let normalizedDist = CGFloat(min(max((distM - minDist) / (maxDist - minDist), 0.0), 1.0))
                let azRad = CGFloat(azDeg * .pi / 180.0)
                let sourcePoint = CGPoint(
                    x: center.x + sin(azRad) * normalizedDist * maxRadius,
                    y: center.y - cos(azRad) * normalizedDist * maxRadius
                )

                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.black.opacity(0.36))

                    Canvas { context, canvasSize in
                        let c = CGPoint(x: canvasSize.width * 0.5, y: canvasSize.height * 0.5)
                        let rMax = min(canvasSize.width, canvasSize.height) * 0.44

                        for ring in 1...3 {
                            let r = rMax * CGFloat(ring) / 3.0
                            let circleRect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
                            context.stroke(
                                Path(ellipseIn: circleRect),
                                with: .color(.white.opacity(ring == 3 ? 0.22 : 0.11)),
                                style: StrokeStyle(lineWidth: 0.9, dash: ring == 2 ? [4, 4] : [])
                            )
                        }

                        var crosshair = Path()
                        crosshair.move(to: CGPoint(x: c.x, y: c.y - rMax))
                        crosshair.addLine(to: CGPoint(x: c.x, y: c.y + rMax))
                        crosshair.move(to: CGPoint(x: c.x - rMax, y: c.y))
                        crosshair.addLine(to: CGPoint(x: c.x + rMax, y: c.y))
                        context.stroke(crosshair, with: .color(.white.opacity(0.12)), lineWidth: 0.8)

                        // Render 18 solved 3D image-source early reflection taps
                        for tap in coordinator.currentRoomReflectionTaps {
                            let tapAzRad = CGFloat(tap.listenerAzimuthDeg * .pi / 180.0)
                            let tapNormDist = CGFloat(min(max(tap.distanceMeters / 12.0, 0.08), 0.98))
                            let pt = CGPoint(
                                x: c.x + sin(tapAzRad) * tapNormDist * rMax,
                                y: c.y - cos(tapAzRad) * tapNormDist * rMax
                            )
                            let dotRadius: CGFloat = tap.order == 1 ? 3.4 : 2.3
                            let rect = CGRect(x: pt.x - dotRadius, y: pt.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)
                            let alpha = Double(min(max(tap.effectiveGain * 2.8, 0.16), 0.85))
                            let color = tap.order == 1 ? Color.cyan.opacity(alpha) : accent.opacity(alpha * 0.8)
                            context.fill(Path(ellipseIn: rect), with: .color(color))
                        }

                        // Render active orbiting habit satellites
                        for sat in coordinator.synthParameters.orbitalSatellites.asArray() where sat.isActive {
                            let satAzRad = CGFloat(sat.azimuthDeg * .pi / 180.0)
                            let satNormDist = CGFloat(min(max((sat.distanceMeters - minDist) / (maxDist - minDist), 0.12), 0.92))
                            let satPt = CGPoint(
                                x: c.x + sin(satAzRad) * satNormDist * rMax,
                                y: c.y - cos(satAzRad) * satNormDist * rMax
                            )
                            let satRect = CGRect(x: satPt.x - 4.0, y: satPt.y - 4.0, width: 8.0, height: 8.0)
                            context.fill(Path(ellipseIn: satRect), with: .color(.mint.opacity(0.78)))
                        }

                        // Listener KEMAR head glyph at origin
                        let headRect = CGRect(x: c.x - 7, y: c.y - 7, width: 14, height: 14)
                        context.fill(Path(ellipseIn: headRect), with: .color(.white.opacity(0.90)))
                    }

                    Circle()
                        .fill(accent)
                        .frame(width: 24, height: 24)
                        .shadow(color: accent, radius: 10)
                        .overlay {
                            Circle().strokeBorder(.white, lineWidth: 2)
                        }
                        .position(sourcePoint)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            let dx = Float(drag.location.x - center.x)
                            let dy = Float(center.y - drag.location.y)
                            let radial = sqrt(dx * dx + dy * dy) / Float(max(maxRadius, 1.0))
                            let clampedNormDist = min(max(radial, 0.0), 1.0)
                            let newDistance = minDist + clampedNormDist * (maxDist - minDist)
                            let newAzimuthDeg = atan2(dx, dy) * 180.0 / .pi

                            if coordinator.isOrbitalSourceAutoLockEnabled {
                                coordinator.isOrbitalSourceAutoLockEnabled = false
                            }
                            coordinator.updateHRTFSourcePose(
                                azimuthDeg: newAzimuthDeg,
                                elevationDeg: coordinator.synthParameters.hrtfElevationDeg,
                                distanceMeters: newDistance
                            )
                        }
                )
            }
            .frame(height: 176)

            synthSliderRow(
                title: "Elevation Dome φ (-45° Floor to +90° Zenith)",
                valueText: String(format: "%+.0f°", elDeg),
                value: Binding(
                    get: { Double(coordinator.synthParameters.hrtfElevationDeg) },
                    set: { newEl in
                        coordinator.updateHRTFSourcePose(
                            azimuthDeg: coordinator.synthParameters.hrtfAzimuthDeg,
                            elevationDeg: Float(newEl),
                            distanceMeters: coordinator.synthParameters.hrtfDistanceMeters
                        )
                    }
                ),
                range: -45.0...90.0
            )

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Orbital Trajectory Auto-Lock")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Revolve primary HRTF source with orbital phase & 6-DoF head pose")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.58))
                }
                Spacer()
                Toggle(
                    "",
                    isOn: Binding(
                        get: { coordinator.isOrbitalSourceAutoLockEnabled },
                        set: { coordinator.toggleOrbitalSourceAutoLock($0) }
                    )
                )
                .labelsHidden()
                .tint(.cyan)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ShoeboxRoomPreset.allCases) { room in
                        let selected = coordinator.activeRoomPreset == room
                        Button {
                            coordinator.selectShoeboxRoomPreset(room)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: room.symbolName)
                                    .font(.system(size: 11, weight: .semibold))
                                Text(room.displayName)
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                            }
                            .foregroundStyle(selected ? .white : .white.opacity(0.68))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 7)
                            .background(
                                selected ? accent.opacity(0.45) : Color.white.opacity(0.08),
                                in: Capsule()
                            )
                            .overlay {
                                Capsule().strokeBorder(.white.opacity(selected ? 0.55 : 0.12), lineWidth: 0.8)
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

    // MARK: - GPU MPSGraph Neural Trainer Telemetry Card

    private var mpsGraphNeuralTrainerCard: some View {
        let accent = Color(hue: coordinator.activeAccentHue, saturation: 0.74, brightness: 0.98)
        let telemetry = coordinator.neuralTelemetry
        let history = coordinator.lossConvergenceHistory
        let prediction = coordinator.latestNeuralPrediction

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("MPSGraph Autodiff Attention Trainer", systemImage: "memorychip.fill")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Spacer()

                Text(telemetry.activeBackend.displayTitle)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(telemetry.activeBackend == .mpsGraphGPU ? .green : .cyan)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.10), in: Capsule())
            }

            HStack(spacing: 8) {
                bioMetricPill(title: "Epochs", value: "\(telemetry.epochCount)")
                bioMetricPill(title: "Huber Loss", value: String(format: "%.4f", telemetry.latestLoss))
                bioMetricPill(title: "‖∇L‖₂ Norm", value: String(format: "%.3f", telemetry.gradientL2Norm))
                bioMetricPill(title: "Step Latency", value: String(format: "%.0f µs", telemetry.gpuExecutionTimeMicroseconds))
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Smooth-L1 + Coherence Loss Convergence")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.86))
                    Spacer()
                    Text(String(format: "EMA %.4f", telemetry.emaLoss))
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(accent)
                }

                Canvas { context, size in
                    let rect = CGRect(origin: .zero, size: size)
                    context.fill(Path(roundedRect: rect, cornerRadius: 12), with: .color(.black.opacity(0.34)))

                    guard history.count >= 2 else { return }
                    let minLoss = max(0.0, (history.min() ?? 0.0) * 0.92)
                    let maxLoss = max(minLoss + 0.001, (history.max() ?? 1.0) * 1.05)
                    let span = max(0.0001, maxLoss - minLoss)

                    var linePath = Path()
                    var areaPath = Path()
                    for (idx, loss) in history.enumerated() {
                        let nx = CGFloat(idx) / CGFloat(max(1, history.count - 1))
                        let ny = CGFloat((loss - minLoss) / span)
                        let px = 8 + nx * (size.width - 16)
                        let py = size.height - 8 - ny * (size.height - 16)
                        if idx == 0 {
                            linePath.move(to: CGPoint(x: px, y: py))
                            areaPath.move(to: CGPoint(x: px, y: size.height))
                            areaPath.addLine(to: CGPoint(x: px, y: py))
                        } else {
                            linePath.addLine(to: CGPoint(x: px, y: py))
                            areaPath.addLine(to: CGPoint(x: px, y: py))
                        }
                    }
                    areaPath.addLine(to: CGPoint(x: size.width - 8, y: size.height))
                    areaPath.closeSubpath()
                    context.fill(areaPath, with: .color(accent.opacity(0.20)))
                    context.stroke(linePath, with: .color(accent), lineWidth: 1.8)
                }
                .frame(height: 82)
            }

            if let prediction {
                HStack(spacing: 8) {
                    bioMetricPill(title: "Pred Beat", value: String(format: "%.1f Hz", prediction.binauralBeatHz))
                    bioMetricPill(title: "Carrier", value: String(format: "%.0f Hz", prediction.carrierHz))
                    bioMetricPill(title: "Orbit ω", value: String(format: "%.2f r/s", prediction.hrtfOrbitSpeed))
                    bioMetricPill(title: "Coherence", value: "\(Int((prediction.targetCoherence * 100.0).rounded()))%")
                }
            }

            HStack(spacing: 10) {
                Button {
                    Task { await coordinator.run32EpochGPUReplayTrainingBatch(epochs: 32) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: coordinator.isNeuralTrainingRunning ? "hourglass" : "bolt.horizontal.circle.fill")
                        Text(coordinator.isNeuralTrainingRunning
                             ? "Training 32 Epochs..."
                             : "Run 32-Epoch GPU Replay Training Batch")
                    }
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(accent.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(coordinator.isNeuralTrainingRunning)

                if prediction != nil {
                    Button {
                        coordinator.applyNeuralPredictionToSynth()
                    } label: {
                        Text("Apply Setpoint")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .aetherGlass(accentHue: coordinator.activeAccentHue, audioEnergy: coordinator.liveAudioAmplitude, cornerRadius: 24)
    }

    // MARK: - Closed-Loop Bio-Entrainment Inspector (Poincaré SD1/SD2 + Lomb-Scargle LF/HF + CoreML Readout)

    private var bioEntrainmentInspectorCard: some View {
        let accent = Color(hue: coordinator.activeAccentHue, saturation: 0.74, brightness: 0.98)
        let metrics = coordinator.latestHRVMetrics ?? .baselinePlaceholder
        let snapshot = coordinator.latestBiometricSnapshot

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("watchOS 11 HRV & CoreML Entrainment", systemImage: "heart.text.square.fill")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Spacer()

                HStack(spacing: 5) {
                    Circle()
                        .fill(coordinator.isWatchCounterpartReachable
                              ? Color.green
                              : (coordinator.isSimulateWristBiometricsEnabled ? Color.cyan : Color.white.opacity(0.35)))
                        .frame(width: 6, height: 6)
                    Text(coordinator.isWatchCounterpartReachable
                         ? "Watch Live"
                         : (coordinator.isSimulateWristBiometricsEnabled ? "Sim PPG" : "Standby"))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.82))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(.white.opacity(0.10), in: Capsule())
            }

            VStack(spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Bio-Entrainment Closed Loop")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("2s CoreML + PID slew adapting carrier, beat Hz & pink noise")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.58))
                    }
                    Spacer()
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { coordinator.isBioEntrainmentEnabled },
                            set: { coordinator.toggleBioEntrainmentClosedLoop($0) }
                        )
                    )
                    .labelsHidden()
                    .tint(accent)
                }

                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Simulate Wrist Biometrics")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("Coupled PQRST + 0.10 Hz Mayer baroreflex synthetic oscillator")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.58))
                    }
                    Spacer()
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { coordinator.isSimulateWristBiometricsEnabled },
                            set: { coordinator.toggleSimulateWristBiometrics($0) }
                        )
                    )
                    .labelsHidden()
                    .tint(.cyan)
                }
            }

            HStack(spacing: 8) {
                bioMetricPill(
                    title: "HR",
                    value: String(format: "%.0f BPM", snapshot?.heartRateBPM ?? metrics.meanHeartRateBPM)
                )
                bioMetricPill(
                    title: "RMSSD",
                    value: String(format: "%.1f ms", metrics.rmssdMs)
                )
                bioMetricPill(
                    title: "Stress SI",
                    value: String(format: "%.0f", metrics.baevskyStressIndex)
                )
                bioMetricPill(
                    title: "RSA Coh",
                    value: "\(Int((metrics.rsaCoherenceScore * 100.0).rounded()))%"
                )
            }

            HStack(spacing: 10) {
                poincarePhaseSpacePanel(snapshot: snapshot, metrics: metrics, accent: accent)
                lombScargleSpectrumPanel(metrics: metrics, accent: accent)
            }
            .frame(height: 136)

            Divider().overlay(.white.opacity(0.12))

            neuralPredictorReadoutSection(accent: accent)
        }
        .padding(16)
        .aetherGlass(accentHue: coordinator.activeAccentHue, audioEnergy: coordinator.liveAudioAmplitude, cornerRadius: 24)
    }

    private func bioMetricPill(title: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(title)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.60))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func poincarePhaseSpacePanel(
        snapshot: BiometricSnapshotDTO?,
        metrics: HRVAnalysisMetricsDTO,
        accent: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Poincaré RRₙ/RRₙ₊₁")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.88))
                Spacer()
                Text(String(format: "SD1 %.0f / SD2 %.0f", metrics.sd1Ms, metrics.sd2Ms))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(accent)
            }

            Canvas { context, size in
                let rect = CGRect(origin: .zero, size: size)
                context.fill(Path(roundedRect: rect, cornerRadius: 12), with: .color(.black.opacity(0.34)))

                var diag = Path()
                diag.move(to: CGPoint(x: 8, y: size.height - 8))
                diag.addLine(to: CGPoint(x: size.width - 8, y: 8))
                context.stroke(diag, with: .color(.white.opacity(0.14)), style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))

                let minRR = max(400.0, metrics.meanRRMs - 220.0)
                let maxRR = min(1_500.0, metrics.meanRRMs + 220.0)
                let span = max(80.0, maxRR - minRR)

                func mapPoint(_ rrX: Double, _ rrY: Double) -> CGPoint {
                    let nx = min(max((rrX - minRR) / span, 0.04), 0.96)
                    let ny = min(max((rrY - minRR) / span, 0.04), 0.96)
                    return CGPoint(x: nx * size.width, y: (1.0 - ny) * size.height)
                }

                if metrics.sd2Ms > 1.0 && metrics.sd1Ms > 1.0 {
                    var ellipsePath = Path()
                    let steps = 48
                    let cos45 = 0.70710678
                    for step in 0...steps {
                        let theta = (Double(step) / Double(steps)) * 2.0 * Double.pi
                        let uMajor = metrics.sd2Ms * cos(theta)
                        let vMinor = metrics.sd1Ms * sin(theta)
                        let rrX = metrics.meanRRMs + (uMajor * cos45 - vMinor * cos45)
                        let rrY = metrics.meanRRMs + (uMajor * cos45 + vMinor * cos45)
                        let pt = mapPoint(rrX, rrY)
                        if step == 0 {
                            ellipsePath.move(to: pt)
                        } else {
                            ellipsePath.addLine(to: pt)
                        }
                    }
                    ellipsePath.closeSubpath()
                    context.fill(ellipsePath, with: .color(accent.opacity(0.16)))
                    context.stroke(ellipsePath, with: .color(accent.opacity(0.85)), lineWidth: 1.3)
                }

                if let rr = snapshot?.rrIntervals, rr.count >= 2 {
                    let tail = max(0, rr.count - 48)
                    for idx in tail..<(rr.count - 1) {
                        let pt = mapPoint(rr[idx].durationMs, rr[idx + 1].durationMs)
                        let dot = CGRect(x: pt.x - 2.0, y: pt.y - 2.0, width: 4.0, height: 4.0)
                        let fade = 0.30 + 0.70 * (Double(idx - tail) / Double(max(1, rr.count - 1 - tail)))
                        context.fill(Path(ellipseIn: dot), with: .color(.cyan.opacity(fade)))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func lombScargleSpectrumPanel(
        metrics: HRVAnalysisMetricsDTO,
        accent: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Lomb-Scargle PSD")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.88))
                Spacer()
                Text(String(format: "LF/HF %.2f", metrics.lfHfRatio))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.cyan)
            }

            Canvas { context, size in
                let rect = CGRect(origin: .zero, size: size)
                context.fill(Path(roundedRect: rect, cornerRadius: 12), with: .color(.black.opacity(0.34)))

                let fMin = 0.04
                let fMax = 0.40
                let fSpan = fMax - fMin

                func xForFreq(_ hz: Double) -> CGFloat {
                    CGFloat(min(max((hz - fMin) / fSpan, 0.0), 1.0)) * size.width
                }

                let lfEnd = xForFreq(0.15)
                context.fill(
                    Path(CGRect(x: 0, y: 0, width: lfEnd, height: size.height)),
                    with: .color(accent.opacity(0.08))
                )

                let mayerX = xForFreq(0.10)
                var mayerLine = Path()
                mayerLine.move(to: CGPoint(x: mayerX, y: 4))
                mayerLine.addLine(to: CGPoint(x: mayerX, y: size.height - 4))
                context.stroke(mayerLine, with: .color(.green.opacity(0.55)), style: StrokeStyle(lineWidth: 1.0, dash: [3, 2]))

                let bins = metrics.spectrumBins
                if bins.count >= 2 {
                    var curve = Path()
                    var area = Path()
                    for (idx, bin) in bins.enumerated() {
                        let px = xForFreq(bin.frequencyHz)
                        let py = size.height - 6 - CGFloat(bin.normalizedPower) * (size.height - 14)
                        if idx == 0 {
                            curve.move(to: CGPoint(x: px, y: py))
                            area.move(to: CGPoint(x: px, y: size.height))
                            area.addLine(to: CGPoint(x: px, y: py))
                        } else {
                            curve.addLine(to: CGPoint(x: px, y: py))
                            area.addLine(to: CGPoint(x: px, y: py))
                        }
                    }
                    if let last = bins.last {
                        area.addLine(to: CGPoint(x: xForFreq(last.frequencyHz), y: size.height))
                        area.closeSubpath()
                    }
                    context.fill(area, with: .color(.cyan.opacity(0.22)))
                    context.stroke(curve, with: .color(.cyan), lineWidth: 1.6)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func neuralPredictorReadoutSection(accent: Color) -> some View {
        let pred = coordinator.latestBioEntrainmentPrediction
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("3-Layer SIMD MLP + Online Huber SGD", systemImage: "brain.head.profile")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.88))
                Spacer()
                Text("Epochs \(coordinator.onlineAdaptationEpochs) · Loss \(String(format: "%.4f", coordinator.lastOnlineHuberLoss))")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(accent)
            }

            if let pred {
                HStack(spacing: 8) {
                    bioMetricPill(title: "Target Beat", value: String(format: "%.1f Hz", pred.targetBinauralBeatHz))
                    bioMetricPill(title: "Carrier", value: String(format: "%.0f Hz", pred.targetCarrierFrequencyHz))
                    bioMetricPill(title: "SVF Cutoff", value: String(format: "%.0f Hz", pred.targetFilterCutoffHz))
                    bioMetricPill(title: "Pred Vagal", value: "\(Int((pred.predictedVagalCoherence * 100.0).rounded()))%")
                }
            } else {
                Text("Enable Bio-Entrainment Closed Loop to stream 12D CoreML tensor predictions into PID audio slew.")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.58))
            }
        }
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

    // MARK: - Phase 7 Card A: 3D Ray-Traced Acoustics & RT60 Octave Analyzer

    private var rayTracedAcousticsInspectorCard: some View {
        let accent = Color(hue: coordinator.activeAccentHue, saturation: 0.74, brightness: 0.98)
        let report = coordinator.latestAcousticReport
        let rt60 = report?.rayTracedRT60PerBand ?? SIMD4<Float>(1.15, 0.92, 0.74, 0.48)
        let sabine = report?.sabineRT60PerBand ?? SIMD4<Float>(1.24, 0.98, 0.79, 0.52)
        let eyring = report?.eyringRT60PerBand ?? SIMD4<Float>(1.10, 0.88, 0.70, 0.46)

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("3D Ray-Traced Acoustics & RT60 Analyzer", systemImage: "cube.transparent.fill")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Spacer()

                HStack(spacing: 5) {
                    Circle()
                        .fill(coordinator.synthParameters.rayTracedAcousticsEnabled ? Color.green : Color.white.opacity(0.35))
                        .frame(width: 6, height: 6)
                    Text((report?.usedHardwareRayTracing == true) ? "MTLAccel HW" : "SIMD SAH-BVH")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(.white.opacity(0.10), in: Capsule())

                Toggle(
                    "",
                    isOn: Binding(
                        get: { coordinator.synthParameters.rayTracedAcousticsEnabled },
                        set: { coordinator.toggleRayTracedAcoustics($0) }
                    )
                )
                .labelsHidden()
                .tint(accent)
            }

            // Chamber Geometry Selector
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(AcousticChamberPreset.allCases) { chamber in
                        let selected = coordinator.selectedChamberPreset == chamber
                        Button {
                            coordinator.selectAcousticChamber(chamber)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: chamber.symbolName)
                                    .font(.system(size: 11, weight: .semibold))
                                Text(chamber.rawValue)
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                            }
                            .foregroundStyle(selected ? .white : .white.opacity(0.68))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(
                                selected ? accent.opacity(0.45) : Color.white.opacity(0.08),
                                in: Capsule()
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Acoustic Surface Material BRDF Selector
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(AcousticSurfaceMaterialPreset.allCases) { mat in
                        let selected = coordinator.selectedSurfaceMaterialPreset == mat
                        Button {
                            coordinator.selectAcousticSurfaceMaterial(mat)
                        } label: {
                            Text(mat.rawValue)
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(selected ? .white : .white.opacity(0.68))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    selected ? Color.cyan.opacity(0.38) : Color.white.opacity(0.06),
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Live 2D/3D Isometric Ray-Path Projection & 4-Band Octave RT60 Bars
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("3D Ray Paths (NEE + QMC)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.88))
                        Spacer()
                        Text("\(report?.triangleCount ?? 64) tris · 0 leak")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(accent)
                    }

                    Canvas { context, size in
                        let rect = CGRect(origin: .zero, size: size)
                        context.fill(Path(roundedRect: rect, cornerRadius: 12), with: .color(.black.opacity(0.36)))

                        let cx = size.width * 0.5
                        let cy = size.height * 0.54
                        let scale = min(size.width, size.height) * 0.085

                        func projectIso(_ p: SIMD3<Float>) -> CGPoint {
                            let ix = CGFloat(p.x - p.z * 0.55) * scale
                            let iy = CGFloat(-p.y + (p.x + p.z) * 0.24) * scale
                            return CGPoint(x: cx + ix, y: cy + iy)
                        }

                        if let segments = report?.raySegments, !segments.isEmpty {
                            let bandColors: [Color] = [.orange, .yellow, .cyan, .purple]
                            for seg in segments.prefix(160) {
                                var path = Path()
                                path.move(to: projectIso(seg.start))
                                path.addLine(to: projectIso(seg.end))
                                let bCol = bandColors[min(max(seg.dominantBand, 0), 3)]
                                let alphaFade = max(0.18, 0.82 - Double(seg.bounceIndex) * 0.11)
                                context.stroke(
                                    path,
                                    with: .color(bCol.opacity(alphaFade)),
                                    lineWidth: seg.bounceIndex == 0 ? 1.35 : 0.85
                                )
                            }
                        } else {
                            for idx in 0..<24 {
                                let angle = Double(idx) * (Double.pi * 2.0 / 24.0)
                                var path = Path()
                                path.move(to: CGPoint(x: cx, y: cy))
                                path.addLine(to: CGPoint(
                                    x: cx + CGFloat(cos(angle)) * size.width * 0.40,
                                    y: cy + CGFloat(sin(angle)) * size.height * 0.38
                                ))
                                context.stroke(path, with: .color(accent.opacity(0.35)), lineWidth: 0.9)
                            }
                        }

                        let srcPt = projectIso(SIMD3<Float>(0.0, 0.35, 1.45))
                        let lstPt = projectIso(SIMD3<Float>(0.0, 0.0, -1.10))
                        context.fill(Path(ellipseIn: CGRect(x: srcPt.x - 3.5, y: srcPt.y - 3.5, width: 7, height: 7)), with: .color(.cyan))
                        context.fill(Path(ellipseIn: CGRect(x: lstPt.x - 3.5, y: lstPt.y - 3.5, width: 7, height: 7)), with: .color(.green))
                    }
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("Octave RT60 (s)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.88))
                        Spacer()
                        Text(String(format: "Sab %.2fs / Eyr %.2fs", sabine.y, eyring.y))
                            .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.cyan)
                    }

                    HStack(alignment: .bottom, spacing: 8) {
                        ForEach(AcousticOctaveBand.allCases) { band in
                            let val = rt60[band.rawValue]
                            let norm = CGFloat(min(max(val / 3.5, 0.06), 1.0))
                            VStack(spacing: 4) {
                                Text(String(format: "%.2f", val))
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.white)
                                GeometryReader { geo in
                                    VStack {
                                        Spacer(minLength: 0)
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .fill(
                                                LinearGradient(
                                                    colors: [.cyan, accent],
                                                    startPoint: .top,
                                                    endPoint: .bottom
                                                )
                                            )
                                            .frame(height: max(6, geo.size.height * norm))
                                    }
                                }
                                Text(band.shortLabel)
                                    .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.68))
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(8)
                    .background(.black.opacity(0.36), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .frame(maxWidth: .infinity)
            }
            .frame(height: 138)
        }
        .padding(16)
        .aetherGlass(accentHue: coordinator.activeAccentHue, audioEnergy: coordinator.liveAudioAmplitude, cornerRadius: 24)
    }

    // MARK: - Phase 7 Card B: Neural Latent Diffusion & RVQ Token Matrix Inspector

    private var neuralLatentDiffusionInspectorCard: some View {
        let accent = Color(hue: coordinator.activeAccentHue, saturation: 0.74, brightness: 0.98)
        let tele = coordinator.latestNeuralSoundscapeTelemetry
        let r4Norm = tele.stageResidualNorms.last ?? 0.0

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Neural Latent Diffusion & RVQ Vocoder", systemImage: "waveform.badge.sparkles")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Spacer()

                Button {
                    coordinator.reseedNeuralSoundscape()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "dice.fill")
                        Text("Reseed ODE")
                    }
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(accent.opacity(0.45), in: Capsule())
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                bioMetricPill(title: "Perplexity", value: String(format: "%.1f / 64", tele.codebookPerplexity))
                bioMetricPill(title: "RVQ Bitrate", value: String(format: "%.1f kbps", tele.bitrateKbps))
                bioMetricPill(title: "Commit Loss", value: String(format: "%.4f", tele.commitmentLoss))
                bioMetricPill(title: "Residual ‖r₄‖₂", value: String(format: "%.2f", r4Norm))
            }

            // 4 x 64 RVQ Codebook Token Matrix Visualizer
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("4×64 RVQ Codebook Token Matrix (C₁…C₄ × 64 Frames)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.88))
                    Spacer()
                    Text("Seq #\(tele.blockSequence) · \(String(format: "%.2f bits", tele.codebookEntropyBits))")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.cyan)
                }

                Canvas { context, size in
                    let rect = CGRect(origin: .zero, size: size)
                    context.fill(Path(roundedRect: rect, cornerRadius: 10), with: .color(.black.opacity(0.40)))

                    let stages = 4
                    let frames = 64
                    let pad: CGFloat = 4.0
                    let cellW = max(1.0, (size.width - pad * 2.0) / CGFloat(frames))
                    let cellH = max(4.0, (size.height - pad * 2.0) / CGFloat(stages))

                    let grid = tele.tokenGrid
                    for s in 0..<min(stages, grid.count) {
                        let row = grid[s]
                        for f in 0..<min(frames, row.count) {
                            let tok = Int(row[f] & 0x3F)
                            let norm = Double(tok) / 63.0
                            let hue = (coordinator.activeAccentHue + norm * 0.38).truncatingRemainder(dividingBy: 1.0)
                            let cellRect = CGRect(
                                x: pad + CGFloat(f) * cellW,
                                y: pad + CGFloat(s) * cellH,
                                width: max(1.0, cellW - 0.6),
                                height: max(2.0, cellH - 1.5)
                            )
                            let color = Color(hue: hue, saturation: 0.78, brightness: 0.35 + norm * 0.65)
                            context.fill(Path(roundedRect: cellRect, cornerRadius: 1.5), with: .color(color))
                        }
                    }
                }
                .frame(height: 62)
            }

            synthSliderRow(
                title: "Rectified-Flow CFG Guidance (w)",
                valueText: String(format: "%.2f×", coordinator.synthParameters.latentGuidanceScale),
                value: Binding(
                    get: { Double(coordinator.synthParameters.latentGuidanceScale) },
                    set: { val in
                        var p = coordinator.synthParameters
                        p.latentGuidanceScale = Float(val)
                        coordinator.pushSynthParameters(p, clearingPresetSelection: false)
                    }
                ),
                range: 1.0...4.0
            )

            synthSliderRow(
                title: "Latent Prior Entropy Temperature (τ)",
                valueText: String(format: "%.2f", coordinator.synthParameters.latentTemperature),
                value: Binding(
                    get: { Double(coordinator.synthParameters.latentTemperature) },
                    set: { val in
                        var p = coordinator.synthParameters
                        p.latentTemperature = Float(val)
                        coordinator.pushSynthParameters(p, clearingPresetSelection: false)
                    }
                ),
                range: 0.1...2.0
            )

            synthSliderRow(
                title: "Neural Vocoder Stream Mix (50% Hann OLA)",
                valueText: "\(Int((coordinator.synthParameters.neuralSoundscapeMix * 100).rounded()))%",
                value: Binding(
                    get: { Double(coordinator.synthParameters.neuralSoundscapeMix) },
                    set: { val in
                        var p = coordinator.synthParameters
                        p.neuralSoundscapeMix = Float(val)
                        coordinator.pushSynthParameters(p, clearingPresetSelection: false)
                    }
                ),
                range: 0.0...1.0
            )
        }
        .padding(16)
        .aetherGlass(accentHue: coordinator.activeAccentHue, audioEnergy: coordinator.liveAudioAmplitude * 0.6, cornerRadius: 24)
    }

    // MARK: - Phase 8 Card: Distributed Multi-Peer Spatial Orchestra & Wave-Field Array

    private var distributedOrchestraArrayCard: some View {
        let accent = Color(hue: coordinator.activeAccentHue, saturation: 0.74, brightness: 0.98)
        let snap = coordinator.orchestraSnapshot

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Distributed PTP Orchestra & Wave-Field Array", systemImage: "dot.radiowaves.left.and.right")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Spacer()

                HStack(spacing: 5) {
                    Circle()
                        .fill(snap.isPhaseLocked
                              ? Color.green
                              : (snap.isMeshSyncEnabled ? Color.cyan : Color.white.opacity(0.35)))
                        .frame(width: 6, height: 6)
                    Text(snap.isPhaseLocked
                         ? "PLL LOCKED <250µs"
                         : (snap.isMeshSyncEnabled ? "SYNCING" : "STANDBY"))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.88))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(.white.opacity(0.10), in: Capsule())
            }

            VStack(spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Conductor / Follower Mesh Sync")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("64B 4-timestamp PTP + Marzullo W=16 + 2nd-Order PI-PLL servo")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.58))
                    }
                    Spacer()
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { snap.isMeshSyncEnabled },
                            set: { coordinator.toggleOrchestraMeshSync($0) }
                        )
                    )
                    .labelsHidden()
                    .tint(accent)
                }

                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Simulate 4-Node Acoustic Array")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("2.5D Rayleigh I WFS & 3rd-order Lagrange Time-of-Flight alignment")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.58))
                    }
                    Spacer()
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { snap.isSimulatingQuadArray },
                            set: { coordinator.toggleSimulateQuadArray($0) }
                        )
                    )
                    .labelsHidden()
                    .tint(.cyan)
                }
            }

            // Live PTP + Marzullo + PI-PLL Telemetry Pills
            HStack(spacing: 8) {
                bioMetricPill(
                    title: "Marzullo PTP",
                    value: String(format: "%+.1f µs", snap.marzulloOffsetMicroseconds)
                )
                bioMetricPill(
                    title: "Allan σy(τ)",
                    value: String(format: "%.2e", snap.allanDeviation)
                )
                bioMetricPill(
                    title: "PLL Warp",
                    value: String(format: "%+.1f ppm", snap.pllFrequencyWarpPPM)
                )
                bioMetricPill(
                    title: "Outliers",
                    value: "\(snap.rejectedOutliers)/16"
                )
            }

            // Active Local Speaker Node Selector
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(snap.nodeSolutions) { sol in
                        let isSelected = sol.nodeID == snap.activeLocalNodeID
                        Button {
                            coordinator.selectOrchestraLocalNode(sol.nodeID)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: sol.nodeID == 1 ? "crown.fill" : "hifispeaker.fill")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("N\(sol.nodeID) · \(String(format: "%.2f ms", sol.tofDelaySeconds * 1000.0))")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                            }
                            .foregroundStyle(isSelected ? .white : .white.opacity(0.70))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                isSelected ? accent.opacity(0.46) : Color.white.opacity(0.08),
                                in: Capsule()
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Interactive 2D Room Sweet-Spot & Speaker Array Placement Map
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("2D Acoustic Wave-Field Sweet-Spot Map (Drag Selected Speaker Node)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.88))
                    Spacer()
                    Text(String(
                        format: "Src (%.1f, %.1f)m",
                        snap.virtualSourcePositionMeters.x,
                        snap.virtualSourcePositionMeters.z
                    ))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.cyan)
                }

                GeometryReader { geo in
                    let size = geo.size
                    let maxMeters: Double = 3.5

                    ZStack {
                        Canvas { context, canvasSize in
                            let rect = CGRect(origin: .zero, size: canvasSize)
                            context.fill(Path(roundedRect: rect, cornerRadius: 14), with: .color(.black.opacity(0.38)))

                            let cx = canvasSize.width * 0.5
                            let cy = canvasSize.height * 0.5

                            // Room grid & concentric acoustic wavefront rings around Virtual Source
                            for ring in 1...4 {
                                let r = CGFloat(ring) * min(canvasSize.width, canvasSize.height) * 0.11
                                let circleRect = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
                                context.stroke(
                                    Path(ellipseIn: circleRect),
                                    with: .color(.white.opacity(0.08)),
                                    style: StrokeStyle(lineWidth: 0.8, dash: [3, 3])
                                )
                            }

                            func mapMetersToPoint(_ pos: SIMD3<Double>) -> CGPoint {
                                let nx = (pos.x / maxMeters) * 0.44 + 0.5
                                let ny = 0.5 - (pos.z / maxMeters) * 0.44
                                return CGPoint(
                                    x: min(max(nx, 0.06), 0.94) * canvasSize.width,
                                    y: min(max(ny, 0.08), 0.92) * canvasSize.height
                                )
                            }

                            let listenerPt = mapMetersToPoint(snap.listenerPositionMeters)
                            let sourcePt = mapMetersToPoint(snap.virtualSourcePositionMeters)

                            // Acoustic wavefronts from Virtual Source
                            for w in 1...3 {
                                let radius = CGFloat(w) * 24.0
                                let waveRect = CGRect(
                                    x: sourcePt.x - radius,
                                    y: sourcePt.y - radius,
                                    width: radius * 2,
                                    height: radius * 2
                                )
                                context.stroke(
                                    Path(ellipseIn: waveRect),
                                    with: .color(.cyan.opacity(0.28 - Double(w) * 0.06)),
                                    lineWidth: 1.0
                                )
                            }

                            // Draw propagation vectors from each speaker node to Listener Sweet Spot
                            for sol in snap.nodeSolutions {
                                let nodePt = mapMetersToPoint(sol.positionMeters)
                                var ray = Path()
                                ray.move(to: nodePt)
                                ray.addLine(to: listenerPt)
                                let isLocal = sol.nodeID == snap.activeLocalNodeID
                                context.stroke(
                                    ray,
                                    with: .color(isLocal ? accent.opacity(0.85) : .white.opacity(0.26)),
                                    style: StrokeStyle(lineWidth: isLocal ? 1.6 : 1.0, dash: [4, 3])
                                )

                                let nodeRadius: CGFloat = isLocal ? 7.5 : 5.5
                                let nodeRect = CGRect(
                                    x: nodePt.x - nodeRadius,
                                    y: nodePt.y - nodeRadius,
                                    width: nodeRadius * 2,
                                    height: nodeRadius * 2
                                )
                                context.fill(
                                    Path(ellipseIn: nodeRect),
                                    with: .color(isLocal ? accent : .white.opacity(0.82))
                                )
                            }

                            // Virtual Acoustic Source marker
                            let srcRect = CGRect(x: sourcePt.x - 6, y: sourcePt.y - 6, width: 12, height: 12)
                            context.fill(Path(ellipseIn: srcRect), with: .color(.cyan))

                            // Listener Sweet Spot marker at origin
                            let lstRect = CGRect(x: listenerPt.x - 7, y: listenerPt.y - 7, width: 14, height: 14)
                            context.fill(Path(ellipseIn: lstRect), with: .color(.green))
                        }
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { drag in
                                    let nx = Double((drag.location.x / max(1.0, size.width)) - 0.5) / 0.44
                                    let nz = Double(0.5 - (drag.location.y / max(1.0, size.height))) / 0.44
                                    let xMeters = min(max(nx * maxMeters, -3.2), 3.2)
                                    let zMeters = min(max(nz * maxMeters, -3.2), 3.2)
                                    coordinator.moveOrchestraSpeakerNode(
                                        nodeID: snap.activeLocalNodeID,
                                        xMeters: xMeters,
                                        zMeters: zMeters
                                    )
                                }
                        )
                    }
                }
                .frame(height: 156)
            }

            // Per-Node Wave-Field ToF Delay (ms) & Rayleigh Driving Gain Breakdown
            VStack(spacing: 5) {
                ForEach(snap.nodeSolutions) { sol in
                    HStack {
                        Text("Node \(sol.nodeID): \(sol.label)")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(sol.nodeID == snap.activeLocalNodeID ? .white : .white.opacity(0.72))
                        Spacer()
                        Text(String(
                            format: "ToF %.2f ms · Gain %.2fx",
                            sol.tofDelaySeconds * 1000.0,
                            sol.wfsDrivingAmplitude
                        ))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(sol.nodeID == snap.activeLocalNodeID ? accent : .cyan.opacity(0.85))
                    }
                }
            }
        }
        .padding(16)
        .aetherGlass(accentHue: coordinator.activeAccentHue, audioEnergy: coordinator.liveAudioAmplitude * 0.65, cornerRadius: 24)
    }

    // MARK: - Phase 9 Track 32.1: Interactive 2D FDTD Acoustic Waveguide Tank Card

    private var fdtdAcousticWaveguideTankCard: some View {
        let tankCtrl = coordinator.waveTankController
        let tank = tankCtrl.waveTank
        let accent = Color(hue: coordinator.activeAccentHue, saturation: 0.78, brightness: 0.98)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform.path.ecg.rectangle")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(accent)
                        Text("2D/3D FDTD Acoustic Waveguide Tank")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                    Text(
                        tankCtrl.isUsingMetalCompute
                            ? "128×128 Metal Compute + 24×24 48kHz SIMD4 Resonator · Cubic PML (>35 dB)"
                            : "128×128 SIMD9 Stencil + 24×24 48kHz Resonator · Biharmonic Plate Stiffness κ"
                    )
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.65))
                }

                Spacer()

                Button {
                    coordinator.triggerFDTDWaveTankShockwave(normalizedX: 0.32, normalizedY: 0.50, amplitude: 1.35)
                } label: {
                    Label("Pulse", systemImage: "dot.radiowaves.left.and.right")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(accent.opacity(0.45), in: Capsule())
                }
                .buttonStyle(.plain)
            }

            // Scenario Presets (Anechoic, Double-Slit, Metamaterial Lens, Helmholtz)
            HStack(spacing: 6) {
                ForEach(VisualFDTDWaveTankController.TankPresetScenario.allCases) { scenario in
                    let isSelected = (tankCtrl.activeScenario == scenario)
                    Button {
                        tankCtrl.applyScenario(scenario)
                        coordinator.hapticDirector.playSegmentSnap()
                    } label: {
                        Text(scenario.rawValue)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(isSelected ? .black : .white.opacity(0.84))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(
                                isSelected ? accent : Color.white.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            // Brush Tool Selector
            HStack(spacing: 6) {
                ForEach(VisualFDTDWaveTankController.WaveTankBrushTool.allCases) { tool in
                    let isSelected = (tankCtrl.activeBrushTool == tool)
                    Button {
                        tankCtrl.activeBrushTool = tool
                        coordinator.hapticDirector.playParameterDetentTick(intensity: 0.45)
                    } label: {
                        Text(tool.rawValue)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(isSelected ? .white : .white.opacity(0.70))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(
                                isSelected ? Color.cyan.opacity(0.32) : Color.white.opacity(0.05),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            // Live 128x128 Pressure Field Canvas (+p cyan, -p magenta, obstacles gold, draggable stereo mics L/R)
            GeometryReader { geo in
                let size = geo.size
                Canvas { context, canvasSize in
                    let bgRect = CGRect(origin: .zero, size: canvasSize)
                    context.fill(Path(roundedRect: bgRect, cornerRadius: 14), with: .color(Color.black.opacity(0.55)))

                    let n = tank.gridSize
                    let downsample = 2
                    let cells = n / downsample
                    let cellW = canvasSize.width / CGFloat(cells)
                    let cellH = canvasSize.height / CGFloat(cells)

                    for cy in 0..<cells {
                        let gy = cy * downsample
                        let row = gy * n
                        for cx in 0..<cells {
                            let gx = cx * downsample
                            let idx = row + gx
                            let rect = CGRect(
                                x: CGFloat(cx) * cellW,
                                y: CGFloat(cy) * cellH,
                                width: cellW + 0.6,
                                height: cellH + 0.6
                            )
                            let code = tank.obstacleCodes[idx]
                            if code == 1 || code == 2 {
                                context.fill(Path(rect), with: .color(Color.yellow.opacity(0.85)))
                                continue
                            } else if code == 3 {
                                context.fill(Path(rect), with: .color(Color.mint.opacity(0.20)))
                            }

                            let p = tank.pressureCurr[idx] * 3.2
                            if abs(p) > 0.015 {
                                let mag = Double(min(abs(p), 1.0))
                                let cellColor = p >= 0
                                    ? Color.cyan.opacity(mag * 0.88)
                                    : Color.pink.opacity(mag * 0.88)
                                context.fill(Path(rect), with: .color(cellColor))
                            }
                        }
                    }

                    // PML Absorbing Sponge Boundary Indicator
                    let pmlFrac = CGFloat(tank.pmlThickness) / CGFloat(max(1, n))
                    let innerRect = CGRect(
                        x: canvasSize.width * pmlFrac,
                        y: canvasSize.height * pmlFrac,
                        width: canvasSize.width * (1.0 - 2.0 * pmlFrac),
                        height: canvasSize.height * (1.0 - 2.0 * pmlFrac)
                    )
                    context.stroke(
                        Path(roundedRect: innerRect, cornerRadius: 6),
                        with: .color(.white.opacity(0.18)),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                    )

                    // Virtual Stereo Microphone Probes (L & R)
                    let leftPt = CGPoint(
                        x: CGFloat(tankCtrl.micLeftNormalized.x) * canvasSize.width,
                        y: CGFloat(tankCtrl.micLeftNormalized.y) * canvasSize.height
                    )
                    let rightPt = CGPoint(
                        x: CGFloat(tankCtrl.micRightNormalized.x) * canvasSize.width,
                        y: CGFloat(tankCtrl.micRightNormalized.y) * canvasSize.height
                    )
                    let leftCircle = CGRect(x: leftPt.x - 8, y: leftPt.y - 8, width: 16, height: 16)
                    let rightCircle = CGRect(x: rightPt.x - 8, y: rightPt.y - 8, width: 16, height: 16)
                    context.fill(Path(ellipseIn: leftCircle), with: .color(.cyan))
                    context.fill(Path(ellipseIn: rightCircle), with: .color(.orange))
                    context.draw(
                        Text("L").font(.system(size: 9, weight: .black, design: .monospaced)).foregroundStyle(.black),
                        at: leftPt
                    )
                    context.draw(
                        Text("R").font(.system(size: 9, weight: .black, design: .monospaced)).foregroundStyle(.black),
                        at: rightPt
                    )
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                )
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let nx = Float(min(max(value.location.x / max(1, size.width), 0.04), 0.96))
                            let ny = Float(min(max(value.location.y / max(1, size.height), 0.04), 0.96))
                            let touch = SIMD2<Float>(nx, ny)
                            let dLeft = simd_distance(touch, tankCtrl.micLeftNormalized)
                            let dRight = simd_distance(touch, tankCtrl.micRightNormalized)
                            if dLeft < 0.09 {
                                coordinator.updateFDTDMicrophoneProbes(leftXY: touch, rightXY: tankCtrl.micRightNormalized)
                            } else if dRight < 0.09 {
                                coordinator.updateFDTDMicrophoneProbes(leftXY: tankCtrl.micLeftNormalized, rightXY: touch)
                            } else if tankCtrl.activeBrushTool == .shockwaveImpulse {
                                coordinator.triggerFDTDWaveTankShockwave(normalizedX: nx, normalizedY: ny, amplitude: 1.25)
                            } else {
                                tankCtrl.applyInteractiveBrush(normalizedX: nx, normalizedY: ny)
                            }
                        }
                )
            }
            .frame(height: 176)

            // FDTD Resonator & Waveguide Physical Parameters
            synthSliderRow(
                title: "FDTD Waveguide Mix",
                valueText: String(format: "%.0f%%", coordinator.synthParameters.fdtdWaveguideMix * 100),
                value: Binding(
                    get: { Double(coordinator.synthParameters.fdtdWaveguideMix) },
                    set: { val in
                        var next = coordinator.synthParameters
                        next.fdtdWaveguideMix = Float(val)
                        coordinator.pushSynthParameters(next, clearingPresetSelection: false)
                    }
                ),
                range: 0.0...1.0
            )

            synthSliderRow(
                title: "Wave Speed c (m/s)",
                valueText: String(format: "%.0f m/s", coordinator.synthParameters.fdtdWaveSpeed),
                value: Binding(
                    get: { Double(coordinator.synthParameters.fdtdWaveSpeed) },
                    set: { val in
                        var next = coordinator.synthParameters
                        next.fdtdWaveSpeed = Float(val)
                        coordinator.pushSynthParameters(next, clearingPresetSelection: false)
                    }
                ),
                range: 120.0...520.0
            )

            synthSliderRow(
                title: "Biharmonic Plate Stiffness κ",
                valueText: String(format: "%.2f", coordinator.synthParameters.fdtdStiffnessKappa),
                value: Binding(
                    get: { Double(coordinator.synthParameters.fdtdStiffnessKappa) },
                    set: { val in
                        var next = coordinator.synthParameters
                        next.fdtdStiffnessKappa = Float(val)
                        coordinator.pushSynthParameters(next, clearingPresetSelection: false)
                    }
                ),
                range: 0.0...0.95
            )

            synthSliderRow(
                title: "Visco-Thermal Damping σ₀",
                valueText: String(format: "%.2f s⁻¹", coordinator.synthParameters.fdtdDampingSigma),
                value: Binding(
                    get: { Double(coordinator.synthParameters.fdtdDampingSigma) },
                    set: { val in
                        var next = coordinator.synthParameters
                        next.fdtdDampingSigma = Float(val)
                        coordinator.pushSynthParameters(next, clearingPresetSelection: false)
                    }
                ),
                range: 0.1...8.0
            )
        }
        .padding(16)
        .aetherGlass(accentHue: coordinator.activeAccentHue, audioEnergy: coordinator.liveAudioAmplitude * 0.68, cornerRadius: 24)
    }

    // MARK: - Phase 9 Track 32.2: 4-Channel EEG BCI, Bicoherence Triangle & PAC Polar Rose Card

    private var eegBCIBispectrumAndPACCard: some View {
        let bci = coordinator.eegBCI
        let metrics = bci.latestMetrics
        let imp = bci.latestImpedanceReport
        let accent = Color(hue: coordinator.activeAccentHue, saturation: 0.78, brightness: 0.98)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: "brain.head.profile")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(accent)
                        Text("4-Ch EEG BCI · Bispectrum & Theta–Gamma PAC")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                    Text(
                        bci.isBLEHardwareConnected
                            ? "CoreBluetooth 256Hz GATT Stream · 4-Tap RLS (λ=0.992) + Kalman EOG Subtractor"
                            : "Jansen-Rit RK4 Cortical Column Simulator · 4-Tap RLS + Kalman Ocular Canceler"
                    )
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.65))
                }

                Spacer()

                Button {
                    bci.injectManualOcularBlink()
                    coordinator.hapticDirector.playParameterDetentTick(intensity: 0.55)
                } label: {
                    Label("Blink", systemImage: "eye.trianglebadge.exclamationmark")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(Color.orange.opacity(0.42), in: Capsule())
                }
                .buttonStyle(.plain)
            }

            // 4-Channel Electrode Contact Quality Pills (TP9, AF7, AF8, TP10)
            HStack(spacing: 6) {
                eegElectrodePill(label: "TP9", kOhm: imp.tp9KOhm, quality: imp.tp9Quality)
                eegElectrodePill(label: "AF7", kOhm: imp.af7KOhm, quality: imp.af7Quality)
                eegElectrodePill(label: "AF8", kOhm: imp.af8KOhm, quality: imp.af8Quality)
                eegElectrodePill(label: "TP10", kOhm: imp.tp10KOhm, quality: imp.tp10Quality)
            }

            // Closed-Loop Cortical IAF Lock & Golden-Ratio Subharmonic Toggles
            HStack(spacing: 10) {
                Toggle(
                    isOn: Binding(
                        get: { coordinator.isCorticalIAFLockEnabled },
                        set: { coordinator.toggleCorticalIAFLock($0) }
                    )
                ) {
                    Text("Closed-Loop Cortical IAF Lock")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.90))
                }
                .toggleStyle(.switch)
                .tint(accent)

                Toggle(
                    isOn: Binding(
                        get: { coordinator.useGoldenRatioIAFSubharmonic },
                        set: { coordinator.toggleGoldenRatioIAFSubharmonic($0) }
                    )
                ) {
                    Text("φ Subharmonic")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.82))
                }
                .toggleStyle(.switch)
                .tint(.cyan)
            }

            // Clinical Cortical Telemetry Readout Pills (BIS, IAF, FAA, PAC MI)
            HStack(spacing: 8) {
                corticalMetricBadge(
                    title: "BIS Index",
                    value: String(format: "%.1f", metrics.bispectralIndex),
                    tint: .cyan
                )
                corticalMetricBadge(
                    title: "IAF Peak",
                    value: String(format: "%.2f Hz", metrics.individualAlphaFrequencyHz),
                    tint: accent
                )
                corticalMetricBadge(
                    title: "Frontal FAA",
                    value: String(format: "%+.2f", metrics.frontalAlphaAsymmetry),
                    tint: .mint
                )
                corticalMetricBadge(
                    title: "PAC Tort MI",
                    value: String(format: "%.3f", metrics.thetaGammaPACModulationIndex),
                    tint: .orange
                )
            }

            // Pre-RLS (Raw AF7 + EOG Blink) vs Post-RLS (Cleaned Cortical AF7) Waveform Scope
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("AF7 Ocular Artifact Rejection (Raw EOG orange vs RLS+Kalman Clean cyan)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.68))
                    Spacer()
                    Text(String(format: "vEOG %.0f µV", bci.latestEOGVerticalUV))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.orange)
                }

                Canvas { context, size in
                    let rect = CGRect(origin: .zero, size: size)
                    context.fill(Path(roundedRect: rect, cornerRadius: 10), with: .color(.black.opacity(0.45)))

                    let raw = bci.rawAF7Scope
                    let clean = bci.cleanedAF7Scope
                    guard raw.count > 1, clean.count > 1 else { return }

                    let midY = size.height * 0.5
                    let scaleY = size.height / 360.0

                    var rawPath = Path()
                    for (i, sample) in raw.enumerated() {
                        let x = CGFloat(i) / CGFloat(raw.count - 1) * size.width
                        let y = midY - CGFloat(min(max(sample, -170.0), 170.0)) * scaleY
                        if i == 0 { rawPath.move(to: CGPoint(x: x, y: y)) }
                        else { rawPath.addLine(to: CGPoint(x: x, y: y)) }
                    }
                    context.stroke(rawPath, with: .color(.orange.opacity(0.65)), lineWidth: 1.2)

                    var cleanPath = Path()
                    for (i, sample) in clean.enumerated() {
                        let x = CGFloat(i) / CGFloat(clean.count - 1) * size.width
                        let y = midY - CGFloat(min(max(sample, -170.0), 170.0)) * scaleY
                        if i == 0 { cleanPath.move(to: CGPoint(x: x, y: y)) }
                        else { cleanPath.addLine(to: CGPoint(x: x, y: y)) }
                    }
                    context.stroke(cleanPath, with: .color(.cyan), lineWidth: 1.8)
                }
                .frame(height: 64)
            }

            // Side-by-Side: Squared Bicoherence b²(f1, f2) Principal Domain Triangle & 18-Bin Theta-Gamma PAC Polar Rose
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(format: "Bicoherence b²(f₁,f₂) · Max %.2f", metrics.maxBicoherence))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.75))

                    Canvas { context, size in
                        let rect = CGRect(origin: .zero, size: size)
                        context.fill(Path(roundedRect: rect, cornerRadius: 12), with: .color(.black.opacity(0.48)))

                        let tri = metrics.bicoherenceTriangle
                        let n = tri.count
                        guard n > 0 else { return }
                        let cellW = size.width / CGFloat(n)
                        let cellH = size.height / CGFloat(n)

                        for f1 in 0..<n {
                            for f2 in 0...f1 where (f1 + f2) < n {
                                let val = Double(min(max(tri[f1][f2], 0.0), 1.0))
                                let cellRect = CGRect(
                                    x: CGFloat(f1) * cellW,
                                    y: size.height - CGFloat(f2 + 1) * cellH,
                                    width: cellW + 0.5,
                                    height: cellH + 0.5
                                )
                                let color = Color(
                                    hue: 0.56 - val * 0.48,
                                    saturation: 0.85,
                                    brightness: 0.25 + val * 0.75
                                ).opacity(0.30 + val * 0.70)
                                context.fill(Path(cellRect), with: .color(color))
                            }
                        }
                    }
                    .frame(height: 118)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("θ–γ PAC Polar Rose (18 Bins)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.75))

                    Canvas { context, size in
                        let rect = CGRect(origin: .zero, size: size)
                        context.fill(Path(roundedRect: rect, cornerRadius: 12), with: .color(.black.opacity(0.48)))

                        let center = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
                        let maxR = min(size.width, size.height) * 0.44
                        let hist = metrics.pacPhaseAmplitudeHistogram
                        let bins = max(1, hist.count)
                        let maxBin = max(0.08, hist.max() ?? 0.08)

                        for ring in 1...2 {
                            let r = maxR * CGFloat(ring) / 2.0
                            let circleRect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
                            context.stroke(Path(ellipseIn: circleRect), with: .color(.white.opacity(0.12)), lineWidth: 1)
                        }

                        for idx in 0..<bins {
                            let a0 = (Double(idx) / Double(bins)) * 2.0 * Double.pi - Double.pi * 0.5
                            let a1 = (Double(idx + 1) / Double(bins)) * 2.0 * Double.pi - Double.pi * 0.5
                            let norm = CGFloat(min(max(hist[idx] / maxBin, 0.08), 1.0))
                            let r = maxR * norm

                            var wedge = Path()
                            wedge.move(to: center)
                            wedge.addArc(
                                center: center,
                                radius: r,
                                startAngle: .radians(a0),
                                endAngle: .radians(a1),
                                clockwise: false
                            )
                            wedge.closeSubpath()
                            context.fill(wedge, with: .color(accent.opacity(0.35 + Double(norm) * 0.55)))
                            context.stroke(wedge, with: .color(.cyan.opacity(0.75)), lineWidth: 0.8)
                        }
                    }
                    .frame(height: 118)
                }
            }
        }
        .padding(16)
        .aetherGlass(accentHue: coordinator.activeAccentHue, audioEnergy: coordinator.liveAudioAmplitude * 0.68, cornerRadius: 24)
    }

    private func eegElectrodePill(label: String, kOhm: Float, quality: Float) -> some View {
        let dotColor: Color = quality > 0.75 ? .green : (quality > 0.45 ? .yellow : .red)
        return HStack(spacing: 5) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
            Text(String(format: "%.0fkΩ", kOhm))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.68))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func corticalMetricBadge(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.62))
            Text(value)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
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
            .aetherInlineNavigationTitle()
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
            .aetherInlineNavigationTitle()
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
            .aetherInlineNavigationTitle()
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


private extension View {
    @ViewBuilder
    func aetherInlineNavigationTitle() -> some View {
        #if os(iOS) || os(visionOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}
