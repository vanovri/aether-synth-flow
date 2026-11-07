// MARK: - FILE: AetherMacApp.swift

import SwiftUI
import SwiftData
import Observation

#if os(macOS)
import AppKit
import CoreAudio
import ServiceManagement

// MARK: - macOS 15 Sequoia Studio Workspace Model

@Observable
@MainActor
public final class MacStudioWorkspaceModel {
    public var selectedDurationMinutes: Int = 25 {
        didSet {
            if !isFocusRunning && elapsedSeconds == 0 {
                remainingSeconds = Double(selectedDurationMinutes * 60)
                syncFloatingHUDState()
            }
        }
    }
    public var selectedHabitID: UUID?
    public var selectedHabitTitle: String = "Systems Architecture"
    public var selectedHabitSymbol: String = "cpu.fill"
    public var activeAccentHue: Double = 0.54

    public var isFocusRunning: Bool = false
    public var elapsedSeconds: Double = 0.0
    public var remainingSeconds: Double = 25.0 * 60.0

    public var synthParameters: SynthParameters = SynthParameters(preset: AudioPresetDTO.defaultPresets[0])
    public var selectedPresetIndex: Int = 0
    public var activePresetName: String = AudioPresetDTO.defaultPresets[0].name
    public var spectrumBars: [Float] = [Float](repeating: 0.0, count: SpectralFFTAnalyzer.outputBarCount)
    public var dominantSpectrumHz: Float = 0.0
    public var subBandEnergy: Float = 0.0
    public var lowBandEnergy: Float = 0.0
    public var highBandEnergy: Float = 0.0
    public var liveRMSAmplitude: Float = 0.0
    public var sessionPeakAmplitude: Float = 0.0

    public var launchAtLoginEnabled: Bool = false
    public var launchAtLoginStatusMessage: String = "Manual Launch"

    public let audioEngine = AudioSynthEngine()
    public let fftAnalyzer = SpectralFFTAnalyzer()
    public let dacManager = CoreAudioDeviceManager()
    public let hudController = FloatingOrbitalHUDController()
    public let shortcutController = MacGlobalShortcutController()
    public let hapticDirector = HapticDirector()
    public let databaseActor: TelemetryDatabaseActor

    private var timerTask: Task<Void, Never>?
    private var sessionStartDate: Date?

    public init(modelContainer: ModelContainer) {
        self.databaseActor = TelemetryDatabaseActor(modelContainer: modelContainer)
        self.launchAtLoginEnabled = (SMAppService.mainApp.status == .enabled)
        self.launchAtLoginStatusMessage = (SMAppService.mainApp.status == .enabled)
            ? "Registered with SMAppService"
            : "Standard Launch Mode"
        configureBridges()
        syncFloatingHUDState()
    }

    public var focusProgress: Double {
        let planned = max(1.0, Double(selectedDurationMinutes * 60))
        return min(max(elapsedSeconds / planned, 0.0), 1.0)
    }

    public var formattedRemainingTime: String {
        let clamped = max(0, Int(remainingSeconds.rounded(.up)))
        return String(format: "%02d:%02d", clamped / 60, clamped % 60)
    }

    public func bootstrapStudio() async {
        try? await databaseActor.bootstrapDefaultsIfNeeded()
        startTelemetryAndSpectrumLoop()
    }

    private func configureBridges() {
        hudController.viewModel.onTogglePlayback = { [weak self] in
            self?.toggleFocusSession()
        }
        hudController.viewModel.onCyclePreset = { [weak self] in
            self?.cycleAcousticPreset()
        }
        hudController.viewModel.onTriggerBloom = { [weak self] in
            self?.triggerHarmonicBloom()
        }

        shortcutController.registerShortcuts { [weak self] action in
            guard let self else { return }
            switch action {
            case .toggleFocusSession:
                self.toggleFocusSession()
            case .triggerHarmonicBloom:
                self.triggerHarmonicBloom()
            case .toggleFloatingHUD:
                self.hudController.toggleHUD()
                self.syncFloatingHUDState()
            case .cycleAcousticPreset:
                self.cycleAcousticPreset()
            }
        }

        dacManager.onHotPlugDevicesChanged = { [weak self] activeDAC in
            guard let self, let dac = activeDAC else { return }
            Task {
                await self.dacManager.routeEngine(self.audioEngine, toDeviceID: dac.deviceID)
            }
        }
    }

    // MARK: - Playback, Presets, Quick Habit Check-Ins & Auto-Launch

    public func toggleFocusSession() {
        if isFocusRunning {
            pauseFocusSession()
        } else {
            startFocusSession()
        }
    }

    public func startFocusSession() {
        guard !isFocusRunning else { return }
        if sessionStartDate == nil {
            sessionStartDate = .now
            sessionPeakAmplitude = 0.0
        }
        isFocusRunning = true
        hapticDirector.playTimerIgnition(starting: true)
        let params = synthParameters
        Task {
            await audioEngine.updateParameters(params)
            try? await audioEngine.start()
        }
        syncFloatingHUDState()
    }

    public func pauseFocusSession() {
        isFocusRunning = false
        hapticDirector.playTimerIgnition(starting: false)
        Task {
            await audioEngine.pause()
        }
        syncFloatingHUDState()
    }

    public func completeAndLogFocusSession() {
        let now = Date.now
        let start = sessionStartDate ?? now.addingTimeInterval(-max(60.0, elapsedSeconds))
        let actualSec = max(15.0, elapsedSeconds)
        let plannedSec = Double(selectedDurationMinutes * 60)

        isFocusRunning = false
        elapsedSeconds = 0.0
        remainingSeconds = plannedSec
        sessionStartDate = nil
        hapticDirector.playSessionCompletionSymphony()

        let sessionDTO = FocusSessionDTO(
            title: "\(selectedHabitTitle) · \(activePresetName)",
            startedAt: start,
            endedAt: now,
            plannedDurationSeconds: plannedSec,
            actualDurationSeconds: actualSec,
            completed: true,
            focusQualityScore: min(1.0, 0.78 + Double(sessionPeakAmplitude) * 0.20),
            peakAmplitude: Double(sessionPeakAmplitude),
            carrierFrequencyHz: Double(synthParameters.carrierFrequencyHz),
            beatFrequencyHz: Double(synthParameters.binauralBeatHz),
            linkedHabitID: selectedHabitID,
            notes: "Logged from AetherSynth macOS 15 Studio"
        )

        Task {
            await audioEngine.pause()
            _ = try? await databaseActor.batchIngestSessions([sessionDTO])
            IntentNotificationBridge.reloadSystemWidgetsAndControls()
        }
        syncFloatingHUDState()
    }

    public func logQuickHabitCheckIn(_ habit: HabitNode, minutes: Int = 15) {
        selectHabit(habit)
        hapticDirector.playOrbitalSnap(mass: habit.orbitalMass)
        triggerHarmonicBloom()
        let habitID = habit.habitID
        Task {
            _ = try? await databaseActor.logQuickHabitPulse(habitID: habitID, addedMinutes: minutes)
            IntentNotificationBridge.reloadSystemWidgetsAndControls()
        }
    }

    public func cycleAcousticPreset() {
        let presets = AudioPresetDTO.defaultPresets
        guard !presets.isEmpty else { return }
        selectedPresetIndex = (selectedPresetIndex + 1) % presets.count
        applyPreset(presets[selectedPresetIndex], index: selectedPresetIndex)
    }

    public func applyPreset(_ preset: AudioPresetDTO, index: Int) {
        selectedPresetIndex = index
        activePresetName = preset.name
        synthParameters = SynthParameters(preset: preset)
        hapticDirector.playSegmentSnap()
        Task {
            await audioEngine.applyPreset(preset)
        }
        syncFloatingHUDState()
    }

    public func pushCurrentSynthParameters() {
        let next = synthParameters
        Task {
            await audioEngine.updateParameters(next)
        }
        syncFloatingHUDState()
    }

    public func triggerHarmonicBloom() {
        hapticDirector.playOrbitalSnap(mass: 1.5)
        Task {
            await audioEngine.triggerHarmonicBloom(intensity: 0.90)
        }
    }

    public func selectHabit(_ habit: HabitNode) {
        selectedHabitID = habit.habitID
        selectedHabitTitle = habit.title
        selectedHabitSymbol = habit.symbolName
        activeAccentHue = habit.accentHue
        syncFloatingHUDState()
    }

    public func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                launchAtLoginEnabled = true
                launchAtLoginStatusMessage = "Auto-Launch Enabled via SMAppService"
            } else {
                try SMAppService.mainApp.unregister()
                launchAtLoginEnabled = false
                launchAtLoginStatusMessage = "Auto-Launch Disabled"
            }
        } catch {
            launchAtLoginEnabled = (SMAppService.mainApp.status == .enabled)
            launchAtLoginStatusMessage = "SMAppService: \(error.localizedDescription)"
        }
    }

    // MARK: - 30Hz Spectrum & Timer Tick Loop

    private func startTelemetryAndSpectrumLoop() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            let dt = 1.0 / 30.0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard let self else { break }

                if self.isFocusRunning {
                    self.elapsedSeconds += dt
                    self.remainingSeconds = max(0.0, Double(self.selectedDurationMinutes * 60) - self.elapsedSeconds)
                    if self.remainingSeconds <= 0.0 {
                        self.completeAndLogFocusSession()
                    }
                }

                let telemetry = await self.audioEngine.snapshotTelemetry()
                self.liveRMSAmplitude = telemetry.rmsAmplitude
                if telemetry.peakAmplitude > self.sessionPeakAmplitude {
                    self.sessionPeakAmplitude = telemetry.peakAmplitude
                }

                if telemetry.isRendering {
                    let window = await self.audioEngine.snapshotScopeWindow()
                    let frame = self.fftAnalyzer.analyze(samples: window.samples, sampleRate: window.sampleRate)
                    self.spectrumBars = frame.bars
                    self.dominantSpectrumHz = frame.dominantFrequencyHz
                    self.subBandEnergy = frame.subBandEnergy
                    self.lowBandEnergy = frame.lowBandEnergy
                    self.highBandEnergy = frame.highBandEnergy
                } else if self.dominantSpectrumHz > 0 {
                    self.fftAnalyzer.reset()
                    self.spectrumBars = [Float](repeating: 0.0, count: SpectralFFTAnalyzer.outputBarCount)
                    self.dominantSpectrumHz = 0.0
                    self.subBandEnergy = 0.0
                    self.lowBandEnergy = 0.0
                    self.highBandEnergy = 0.0
                }

                self.syncFloatingHUDState()
            }
        }
    }

    private func syncFloatingHUDState() {
        let vm = hudController.viewModel
        vm.habitTitle = selectedHabitTitle
        vm.presetName = activePresetName
        vm.formattedRemainingTime = formattedRemainingTime
        vm.timerProgress = focusProgress
        vm.binauralBeatHz = synthParameters.binauralBeatHz
        vm.carrierFrequencyHz = synthParameters.carrierFrequencyHz
        vm.accentHue = activeAccentHue
        vm.isPlaying = isFocusRunning
        vm.audioRMS = liveRMSAmplitude
        vm.spectrumBars = spectrumBars
    }
}

// MARK: - 3-Column macOS 15 Sequoia Studio Workspace View

public struct MacStudioThreeColumnWorkspaceView: View {
    @Bindable public var model: MacStudioWorkspaceModel

    @Query(
        filter: #Predicate<HabitNode> { node in node.isArchived == false },
        sort: [SortDescriptor(\HabitNode.sortOrder, order: .forward)]
    )
    private var habits: [HabitNode]

    @Query(
        sort: [SortDescriptor(\FocusSession.startedAt, order: .reverse)]
    )
    private var sessions: [FocusSession]

    @Query(
        sort: [SortDescriptor(\DailyTelemetry.dateStartOfDay, order: .reverse)]
    )
    private var telemetryDays: [DailyTelemetry]

    public init(model: MacStudioWorkspaceModel) {
        self.model = model
    }

    private var accentColor: Color {
        Color(hue: model.activeAccentHue, saturation: 0.75, brightness: 0.96)
    }

    public var body: some View {
        NavigationSplitView {
            sidebarHabitOrbitAndPresetsColumn
                .navigationSplitViewColumnWidth(min: 245, ideal: 275, max: 320)
        } content: {
            central120HzCanvasAndXYPadColumn
                .navigationSplitViewColumnWidth(min: 420, ideal: 500)
        } detail: {
            trailing365MatrixAndFFTInspectorColumn
                .navigationSplitViewColumnWidth(min: 360, ideal: 420)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.toggleFocusSession()
                } label: {
                    Label(
                        model.isFocusRunning ? "Pause (⌘⇧F)" : "Start Flow (⌘⇧F)",
                        systemImage: model.isFocusRunning ? "pause.fill" : "play.fill"
                    )
                }

                Button {
                    model.triggerHarmonicBloom()
                } label: {
                    Label("Bloom (⌘⇧B)", systemImage: "sparkles")
                }

                Button {
                    model.cycleAcousticPreset()
                } label: {
                    Label("Next Preset (⌘⇧])", systemImage: "waveform.badge.magnifyingglass")
                }

                Button {
                    model.hudController.toggleHUD()
                } label: {
                    Label("Floating HUD (⌘⇧H)", systemImage: "pip.enter")
                }
            }
        }
    }

    // MARK: - Column 1: Sidebar Habit Orbit & Presets (+15m Check-In)

    private var sidebarHabitOrbitAndPresetsColumn: some View {
        List {
            Section("Habit Satellites (+15m Check-In)") {
                ForEach(habits) { habit in
                    HStack(spacing: 8) {
                        Button {
                            model.selectHabit(habit)
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: habit.symbolName)
                                    .foregroundStyle(Color(hue: habit.accentHue, saturation: 0.76, brightness: 0.96))
                                    .frame(width: 18)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(habit.title)
                                        .font(.system(size: 13, weight: .semibold))
                                        .lineLimit(1)
                                    Text("\(habit.completedMinutesToday)/\(habit.targetMinutesPerDay)m · \(habit.currentStreak)d streak")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        Button("+15m") {
                            model.logQuickHabitCheckIn(habit, minutes: 15)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .tint(Color(hue: habit.accentHue, saturation: 0.75, brightness: 0.95))
                    }
                    .padding(.vertical, 3)
                }
            }

            Section("Acoustic Entrainment Presets") {
                ForEach(Array(AudioPresetDTO.defaultPresets.enumerated()), id: \.element.presetID) { idx, preset in
                    Button {
                        model.applyPreset(preset, index: idx)
                    } label: {
                        HStack {
                            Image(systemName: preset.category.symbolName)
                                .frame(width: 18)
                                .foregroundStyle(idx == model.selectedPresetIndex ? accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(preset.name)
                                    .font(.system(size: 12, weight: .semibold))
                                Text(String(format: "%.0f Hz Carrier · %.1f Hz Beat", preset.carrierFrequencyHz, preset.binauralBeatHz))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if idx == model.selectedPresetIndex {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(accentColor)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Column 2: Central 120Hz Spatial Canvas, XY Filter Pad & Procedural Synth Mixer

    private var central120HzCanvasAndXYPadColumn: some View {
        ScrollView {
            VStack(spacing: 18) {
                spatial120HzOrbitalCanvasCard
                cytomicXYFilterPadCard
                proceduralSynthMixerCard
            }
            .padding(20)
        }
        .navigationTitle("AetherSynth Studio")
    }

    private var spatial120HzOrbitalCanvasCard: some View {
        ZStack {
            SpatialBackdropCanvasView(
                audioAmplitude: model.liveRMSAmplitude,
                highBandEnergy: model.highBandEnergy,
                accentHue: model.activeAccentHue,
                isActive: model.isFocusRunning
            )
            .frame(height: 268)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

            TimelineView(.animation(minimumInterval: 1.0 / 120.0)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let baseAngle = t * (model.isFocusRunning ? 0.85 : 0.25)

                VStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .stroke(.white.opacity(0.16), lineWidth: 8)
                            .frame(width: 156, height: 156)

                        Circle()
                            .trim(from: 0.0, to: max(0.02, model.focusProgress))
                            .stroke(
                                AngularGradient(colors: [accentColor, .cyan, accentColor], center: .center),
                                style: StrokeStyle(lineWidth: 8, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                            .frame(width: 156, height: 156)

                        ForEach(Array(habits.prefix(6).enumerated()), id: \.element.habitID) { idx, habit in
                            let angle = baseAngle + (Double(idx) / Double(max(1, min(6, habits.count)))) * Double.pi * 2.0
                            Circle()
                                .fill(Color(hue: habit.accentHue, saturation: 0.82, brightness: 0.98))
                                .frame(width: habit.habitID == model.selectedHabitID ? 12 : 8, height: habit.habitID == model.selectedHabitID ? 12 : 8)
                                .shadow(color: Color(hue: habit.accentHue, saturation: 0.8, brightness: 1.0), radius: 5)
                                .offset(x: CGFloat(cos(angle)) * 78.0, y: CGFloat(sin(angle)) * 78.0)
                        }

                        VStack(spacing: 3) {
                            Text(model.selectedHabitTitle)
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.80))
                                .lineLimit(1)
                            Text(model.formattedRemainingTime)
                                .font(.system(size: 34, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white)
                            Text(String(format: "%.1f Hz Beat", model.synthParameters.binauralBeatHz))
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(accentColor)
                        }
                    }

                    HStack(spacing: 10) {
                        Picker("Duration", selection: $model.selectedDurationMinutes) {
                            Text("15m").tag(15)
                            Text("25m").tag(25)
                            Text("45m").tag(45)
                            Text("60m").tag(60)
                            Text("90m").tag(90)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 260)

                        Button {
                            model.toggleFocusSession()
                        } label: {
                            Label(
                                model.isFocusRunning ? "Pause" : "Start Flow",
                                systemImage: model.isFocusRunning ? "pause.fill" : "play.fill"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(accentColor)

                        if model.elapsedSeconds >= 10 {
                            Button("Log") {
                                model.completeAndLogFocusSession()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                .padding(16)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        )
    }

    private var cytomicXYFilterPadCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Cytomic 4-Pole TPT SVF XY Morph Pad", systemImage: "slider.horizontal.below.square.and.square.filled")
                    .font(.headline)
                Spacer()
                Text(
                    String(
                        format: "Cutoff %.0f Hz · Q %.2f",
                        model.synthParameters.filterCutoffHz,
                        model.synthParameters.filterResonance
                    )
                )
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(accentColor)
            }

            GeometryReader { geo in
                let width = max(1.0, geo.size.width)
                let height = max(1.0, geo.size.height)
                let normX = CGFloat(
                    min(
                        max(
                            logf(max(model.synthParameters.filterCutoffHz, 120.0) / 120.0) / logf(12_000.0 / 120.0),
                            0.0
                        ),
                        1.0
                    )
                )
                let normY = CGFloat(
                    1.0 - min(max((model.synthParameters.filterResonance - 0.08) / (0.92 - 0.08), 0.0), 1.0)
                )

                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.black.opacity(0.58),
                                    accentColor.opacity(0.22)
                                ],
                                startPoint: .bottomLeading,
                                endPoint: .topTrailing
                            )
                        )

                    // Logarithmic grid lines
                    Path { path in
                        for step in 1..<4 {
                            let gx = width * CGFloat(step) / 4.0
                            let gy = height * CGFloat(step) / 4.0
                            path.move(to: CGPoint(x: gx, y: 0))
                            path.addLine(to: CGPoint(x: gx, y: height))
                            path.move(to: CGPoint(x: 0, y: gy))
                            path.addLine(to: CGPoint(x: width, y: gy))
                        }
                    }
                    .stroke(.white.opacity(0.10), lineWidth: 1)

                    // Crosshair & Harmonic Reticle
                    Path { path in
                        let px = normX * width
                        let py = normY * height
                        path.move(to: CGPoint(x: px, y: 0))
                        path.addLine(to: CGPoint(x: px, y: height))
                        path.move(to: CGPoint(x: 0, y: py))
                        path.addLine(to: CGPoint(x: width, y: py))
                    }
                    .stroke(accentColor.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

                    Circle()
                        .fill(accentColor)
                        .frame(width: 18, height: 18)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                        .shadow(color: accentColor, radius: 8)
                        .position(x: normX * width, y: normY * height)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            let tx = Float(min(max(drag.location.x / width, 0.0), 1.0))
                            let ty = Float(1.0 - min(max(drag.location.y / height, 0.0), 1.0))
                            model.synthParameters.filterCutoffHz = 120.0 * powf(12_000.0 / 120.0, tx)
                            model.synthParameters.filterResonance = 0.08 + ty * (0.92 - 0.08)
                            model.pushCurrentSynthParameters()
                        }
                )
            }
            .frame(height: 152)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var proceduralSynthMixerCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("Procedural Binaural + 5-Voice Pad + Kellet Pink Noise Mixer")
                .font(.headline)

            mixerSlider(
                title: "Carrier Frequency",
                formatted: String(format: "%.0f Hz", model.synthParameters.carrierFrequencyHz),
                value: Binding(
                    get: { Double(model.synthParameters.carrierFrequencyHz) },
                    set: { model.synthParameters.carrierFrequencyHz = Float($0); model.pushCurrentSynthParameters() }
                ),
                range: 60.0...640.0
            )
            mixerSlider(
                title: "Binaural Beat Offset",
                formatted: String(format: "%.1f Hz", model.synthParameters.binauralBeatHz),
                value: Binding(
                    get: { Double(model.synthParameters.binauralBeatHz) },
                    set: { model.synthParameters.binauralBeatHz = Float($0); model.pushCurrentSynthParameters() }
                ),
                range: 1.5...40.0
            )
            mixerSlider(
                title: "Binaural Mix",
                formatted: String(format: "%.0f%%", model.synthParameters.binauralMix * 100.0),
                value: Binding(
                    get: { Double(model.synthParameters.binauralMix) },
                    set: { model.synthParameters.binauralMix = Float($0); model.pushCurrentSynthParameters() }
                ),
                range: 0.0...1.0
            )
            mixerSlider(
                title: "5-Voice Harmonic Pad Mix",
                formatted: String(format: "%.0f%%", model.synthParameters.padMix * 100.0),
                value: Binding(
                    get: { Double(model.synthParameters.padMix) },
                    set: { model.synthParameters.padMix = Float($0); model.pushCurrentSynthParameters() }
                ),
                range: 0.0...1.0
            )
            mixerSlider(
                title: "Paul Kellet 1/f Pink Noise",
                formatted: String(format: "%.0f%%", model.synthParameters.pinkNoiseMix * 100.0),
                value: Binding(
                    get: { Double(model.synthParameters.pinkNoiseMix) },
                    set: { model.synthParameters.pinkNoiseMix = Float($0); model.pushCurrentSynthParameters() }
                ),
                range: 0.0...1.0
            )
            mixerSlider(
                title: "Master Output Gain",
                formatted: String(format: "%.0f%%", model.synthParameters.masterGain * 100.0),
                value: Binding(
                    get: { Double(model.synthParameters.masterGain) },
                    set: { model.synthParameters.masterGain = Float($0); model.pushCurrentSynthParameters() }
                ),
                range: 0.0...1.0
            )
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func mixerSlider(
        title: String,
        formatted: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text(formatted)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(accentColor)
            }
            Slider(value: value, in: range)
        }
    }

    // MARK: - Column 3: Trailing 365-Day Matrix, 64-Bin FFT & CoreAudio HAL Inspector

    private var trailing365MatrixAndFFTInspectorColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                spectrumAnalyzer64BinCard
                matrix365DayHeatmapCard
                coreAudioDACRouterCard
                recentSessionLedgerCard
            }
            .padding(20)
        }
    }

    private var spectrumAnalyzer64BinCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("64-Bin vDSP Hann FFT Telemetry", systemImage: "waveform.path.ecg.rectangle")
                    .font(.headline)
                Spacer()
                Text(String(format: "Peak %.0f Hz", model.dominantSpectrumHz))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(accentColor)
            }

            Canvas { context, size in
                let bars = model.spectrumBars
                let count = max(1, bars.count)
                let spacing: CGFloat = 2.0
                let barWidth = max(1.5, (size.width - CGFloat(count - 1) * spacing) / CGFloat(count))

                for idx in 0..<count {
                    let level = CGFloat(min(max(bars[idx], 0.03), 1.0))
                    let barHeight = level * size.height
                    let rect = CGRect(
                        x: CGFloat(idx) * (barWidth + spacing),
                        y: size.height - barHeight,
                        width: barWidth,
                        height: barHeight
                    )
                    let hueShift = (model.activeAccentHue + Double(idx) * 0.003).truncatingRemainder(dividingBy: 1.0)
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: 1.5),
                        with: .color(Color(hue: hueShift, saturation: 0.78, brightness: 0.96))
                    )
                }
            }
            .frame(height: 110)
            .padding(8)
            .background(Color.black.opacity(0.30), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack {
                Text(String(format: "Sub %.0f%%", model.subBandEnergy * 100.0))
                Spacer()
                Text(String(format: "Low %.0f%%", model.lowBandEnergy * 100.0))
                Spacer()
                Text(String(format: "High %.0f%%", model.highBandEnergy * 100.0))
            }
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var matrix365DayHeatmapCard: some View {
        let dayBucketLookup: [String: Int] = Dictionary(
            uniqueKeysWithValues: telemetryDays.map { ($0.dayKey, $0.intensityLevel) }
        )
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("365-Day Focus Matrix", systemImage: "square.grid.3x3.fill")
                    .font(.headline)
                Spacer()
                Text("\(telemetryDays.filter { $0.intensityLevel > 0 }.count) active days")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                Canvas { context, _ in
                    let weeks = 53
                    let daysPerWeek = 7
                    let cell: CGFloat = 8.5
                    let gap: CGFloat = 2.0

                    for col in 0..<weeks {
                        for row in 0..<daysPerWeek {
                            let daysAgo = (weeks - 1 - col) * 7 + (daysPerWeek - 1 - row)
                            guard daysAgo <= 364,
                                  let date = calendar.date(byAdding: .day, value: -daysAgo, to: today) else {
                                continue
                            }
                            let key = DayKeyFormatter.dayKey(for: date, calendar: calendar)
                            let level = dayBucketLookup[key] ?? 0
                            let rect = CGRect(
                                x: CGFloat(col) * (cell + gap),
                                y: CGFloat(row) * (cell + gap),
                                width: cell,
                                height: cell
                            )
                            let color: Color = level == 0
                                ? Color.primary.opacity(0.08)
                                : accentColor.opacity(0.22 + Double(min(level, 4)) * 0.195)
                            context.fill(Path(roundedRect: rect, cornerRadius: 2.0), with: .color(color))
                        }
                    }
                }
                .frame(width: 53 * 10.5, height: 7 * 10.5)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var coreAudioDACRouterCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("CoreAudio HAL Output Router", systemImage: "hifispeaker.2.fill")
                    .font(.headline)
                Spacer()
                Button {
                    model.dacManager.refreshOutputDevices()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Rescan CoreAudio HAL Devices")
            }

            Picker(
                "Output DAC",
                selection: Binding(
                    get: { model.dacManager.selectedOutputDeviceID },
                    set: { newDeviceID in
                        Task {
                            await model.dacManager.routeEngine(model.audioEngine, toDeviceID: newDeviceID)
                        }
                    }
                )
            ) {
                ForEach(model.dacManager.outputDevices) { dac in
                    Text("\(dac.name) (\(dac.outputChannelCount)ch · \(dac.transportName))")
                        .tag(dac.deviceID)
                }
            }

            if let selectedDAC = model.dacManager.selectedDevice {
                HStack(spacing: 6) {
                    Text("Rate:")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    ForEach(selectedDAC.availableSampleRates.prefix(4), id: \.self) { rate in
                        Button(String(format: "%.1fk", rate / 1_000.0)) {
                            _ = model.dacManager.setNominalSampleRate(rate, onDeviceID: selectedDAC.deviceID)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(abs(selectedDAC.nominalSampleRate - rate) < 10 ? accentColor : .secondary)
                    }
                }
            }

            Text(model.dacManager.lastRoutingStatus)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var recentSessionLedgerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Recent Focus Ledger", systemImage: "clock.badge.checkmark")
                .font(.headline)

            if sessions.isEmpty {
                Text("Complete a focus session to populate ledger records.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sessions.prefix(5)) { session in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.title)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                            Text(
                                String(
                                    format: "%.0fm · %.1f Hz Beat · Q %.0f%%",
                                    session.actualDurationSeconds / 60.0,
                                    session.beatFrequencyHz,
                                    session.focusQualityScore * 100.0
                                )
                            )
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(session.startedAt, style: .date)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - MenuBarExtra Window Popover View (+15m Habit Check-Ins, Presets & HUD Launcher)

private struct MacMenuBarQuickControlView: View {
    @Bindable var model: MacStudioWorkspaceModel

    @Query(
        filter: #Predicate<HabitNode> { node in node.isArchived == false },
        sort: [SortDescriptor(\HabitNode.sortOrder, order: .forward)]
    )
    private var habits: [HabitNode]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.selectedHabitTitle)
                        .font(.system(size: 13, weight: .bold))
                        .lineLimit(1)
                    Text("\(model.activePresetName) · \(String(format: "%.1f Hz Beat", model.synthParameters.binauralBeatHz))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(model.formattedRemainingTime)
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
            }

            ProgressView(value: model.focusProgress)

            HStack(spacing: 8) {
                Button {
                    model.toggleFocusSession()
                } label: {
                    Label(
                        model.isFocusRunning ? "Pause" : "Start Flow",
                        systemImage: model.isFocusRunning ? "pause.fill" : "play.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    model.triggerHarmonicBloom()
                } label: {
                    Image(systemName: "sparkles")
                }
                .buttonStyle(.bordered)
                .help("Trigger Harmonic Bloom (⌘⇧B)")

                Button {
                    model.hudController.toggleHUD()
                } label: {
                    Label("HUD", systemImage: "pip.enter")
                }
                .buttonStyle(.bordered)
                .help("Launch Floating Orbital HUD (⌘⇧H)")
            }

            Divider()

            // Quick Preset Switcher
            Text("Quick Audio Preset")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            Picker(
                "Preset",
                selection: Binding(
                    get: { model.selectedPresetIndex },
                    set: { newIdx in
                        let presets = AudioPresetDTO.defaultPresets
                        if newIdx >= 0 && newIdx < presets.count {
                            model.applyPreset(presets[newIdx], index: newIdx)
                        }
                    }
                )
            ) {
                ForEach(Array(AudioPresetDTO.defaultPresets.enumerated()), id: \.offset) { idx, preset in
                    Text(preset.name).tag(idx)
                }
            }
            .labelsHidden()

            // +15m Quick Habit Check-In Buttons
            if !habits.isEmpty {
                Divider()
                Text("Quick +15m Habit Check-In")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                ForEach(habits.prefix(4)) { habit in
                    HStack {
                        Image(systemName: habit.symbolName)
                            .foregroundStyle(Color(hue: habit.accentHue, saturation: 0.78, brightness: 0.96))
                            .frame(width: 16)
                        Text(habit.title)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Spacer()
                        Button("+15m") {
                            model.logQuickHabitCheckIn(habit, minutes: 15)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            if let activeDAC = model.dacManager.selectedDevice {
                Divider()
                Text("DAC: \(activeDAC.name) (\(Int(activeDAC.nominalSampleRate / 1_000.0)) kHz)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(14)
        .frame(width: 318)
    }
}

// MARK: - macOS Settings Scene (Global Shortcuts, CoreAudio HAL Routing & Auto-Launch)

private struct MacStudioSettingsView: View {
    @Bindable var model: MacStudioWorkspaceModel

    var body: some View {
        TabView {
            Form {
                Section("Global & Local Keyboard Shortcuts") {
                    Toggle("Enable Global Hotkeys", isOn: $model.shortcutController.isShortcutsEnabled)

                    ForEach(MacGlobalShortcutController.ShortcutAction.allCases) { shortcut in
                        LabeledContent(shortcut.displayLabel) {
                            Text(shortcut.keyComboBadge)
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }
            .tabItem {
                Label("Shortcuts", systemImage: "command")
            }
            .padding(20)

            Form {
                Section("CoreAudio HAL Output Device") {
                    Picker(
                        "Active Output DAC",
                        selection: Binding(
                            get: { model.dacManager.selectedOutputDeviceID },
                            set: { newID in
                                Task {
                                    await model.dacManager.routeEngine(model.audioEngine, toDeviceID: newID)
                                }
                            }
                        )
                    ) {
                        ForEach(model.dacManager.outputDevices) { dac in
                            Text("\(dac.name) · \(Int(dac.nominalSampleRate)) Hz · \(dac.transportName)")
                                .tag(dac.deviceID)
                        }
                    }

                    LabeledContent("Routing Status", value: model.dacManager.lastRoutingStatus)

                    Button("Rescan Hardware Audio Buses") {
                        model.dacManager.refreshOutputDevices()
                    }
                }
            }
            .tabItem {
                Label("CoreAudio", systemImage: "hifispeaker.2.fill")
            }
            .padding(20)

            Form {
                Section("macOS Session & Startup") {
                    Toggle(
                        "Auto-Launch AetherSynth Studio at Login",
                        isOn: Binding(
                            get: { model.launchAtLoginEnabled },
                            set: { model.setLaunchAtLogin($0) }
                        )
                    )
                    LabeledContent("SMAppService Status", value: model.launchAtLoginStatusMessage)
                }
            }
            .tabItem {
                Label("General", systemImage: "gearshape.fill")
            }
            .padding(20)
        }
        .frame(width: 480, height: 280)
    }
}

// MARK: - Native macOS 15 Sequoia Application Entry Point

@main
public struct AetherMacApp: App {
    private let modelContainer: ModelContainer
    @State private var studioModel: MacStudioWorkspaceModel

    public init() {
        let container: ModelContainer
        do {
            container = try AetherPersistenceSchema.makeContainer(inMemory: false)
        } catch {
            fatalError("Failed to initialize macOS SwiftData ModelContainer: \(error.localizedDescription)")
        }
        self.modelContainer = container
        self._studioModel = State(initialValue: MacStudioWorkspaceModel(modelContainer: container))
    }

    public var body: some Scene {
        // 1. Main Desktop Studio 3-Column Window
        WindowGroup("AetherSynth Studio", id: "mac-studio") {
            MacStudioThreeColumnWorkspaceView(model: studioModel)
                .modelContainer(modelContainer)
                .frame(minWidth: 1020, minHeight: 660)
                .task {
                    await studioModel.bootstrapStudio()
                }
        }
        .defaultSize(width: 1220, height: 780)

        // 2. MenuBarExtra showing Live Countdown Digits + Animated Waveform Icon
        MenuBarExtra {
            MacMenuBarQuickControlView(model: studioModel)
                .modelContainer(modelContainer)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: studioModel.isFocusRunning ? "waveform.circle.fill" : "waveform")
                    .symbolEffect(.variableColor.iterative, isActive: studioModel.isFocusRunning)
                Text(studioModel.formattedRemainingTime)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
            }
        }
        .menuBarExtraStyle(.window)

        // 3. Native macOS Settings Scene
        Settings {
            MacStudioSettingsView(model: studioModel)
        }
    }
}
#endif
