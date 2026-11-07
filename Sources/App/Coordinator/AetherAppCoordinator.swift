// MARK: - FILE: AetherAppCoordinator.swift

import Foundation
import SwiftUI
import SwiftData
import Observation
import WidgetKit

public enum SpatialTabSection: String, CaseIterable, Hashable, Sendable {
    case orbit
    case synthLab
    case matrix
}

@Observable
@MainActor
public final class AetherAppCoordinator {
    // Navigation & Sheet State
    public var activeSection: SpatialTabSection = .orbit
    public var isHabitEditorPresented: Bool = false
    public var editingHabitDraft: HabitNodeDTO?
    public var isSavePresetSheetPresented: Bool = false
    public var pendingCompletedSession: FocusSessionDTO?

    // Data Portability State (JSON Archive & CSV Exporter / Importer)
    public var exportJSONDocument: AetherArchiveDocument?
    public var isExportingJSON: Bool = false
    public var exportCSVDocument: AetherCSVDocument?
    public var isExportingCSV: Bool = false
    public var isImportingArchive: Bool = false
    public var statusBannerMessage: String?

    // Spatial Focus Timer State
    public var selectedDurationMinutes: Int = 25 {
        didSet {
            if !isTimerRunning && elapsedSeconds == 0 {
                remainingSeconds = Double(selectedDurationMinutes * 60)
            }
        }
    }
    public var selectedHabitID: UUID?
    public var selectedHabitTitle: String = "Systems Architecture"
    public var selectedHabitSymbol: String = "cpu.fill"
    public var activeAccentHue: Double = 0.54
    public var isTimerRunning: Bool = false
    public var elapsedSeconds: Double = 0.0
    public var remainingSeconds: Double = 25.0 * 60.0
    public var orbitalRotationAngle: Double = 0.0

    // Real-Time Synth, vDSP FFT & Head-Tracking State
    public var synthParameters: SynthParameters = SynthParameters(preset: AudioPresetDTO.defaultPresets[0])
    public var selectedPresetID: UUID? = AudioPresetDTO.defaultPresets[0].presetID
    public var activePresetName: String = AudioPresetDTO.defaultPresets[0].name
    public var isSynthPlaying: Bool = false
    public var liveAudioAmplitude: Float = 0.0
    public var liveHighBandEnergy: Float = 0.0
    public var sessionPeakAmplitude: Float = 0.0
    public var spectrumBars: [Float] = [Float](repeating: 0, count: SpectralFFTAnalyzer.outputBarCount)
    public var dominantSpectrumHz: Float = 0.0
    public var isHeadTrackingEnabled: Bool = false

    // Underlying Actors, DSP, Haptics & System Bridges
    public let hapticDirector = HapticDirector()
    public let audioEngine = AudioSynthEngine()
    public let fftAnalyzer = SpectralFFTAnalyzer()
    public let mediaAndMotion = MediaSessionAndHeadTrackingController()
    public let databaseActor: TelemetryDatabaseActor

    #if canImport(ActivityKit) && os(iOS)
    private let liveActivityController = FocusLiveActivityController()
    #endif

    private var activeLiveSessionID = UUID()
    private var timerAnchorDate: Date?
    private var accumulatedElapsedBeforePause: Double = 0.0
    private var sessionStartWallDate: Date?
    private var telemetryLoopTask: Task<Void, Never>?
    private var externalIntentObserver: NSObjectProtocol?

    public init(modelContainer: ModelContainer) {
        self.databaseActor = TelemetryDatabaseActor(modelContainer: modelContainer)
        wireMediaAndMotionCallbacks()
        wireExternalIntentNotifications()
    }

    public var focusProgress: Double {
        let total = max(1.0, Double(selectedDurationMinutes * 60))
        return min(max(elapsedSeconds / total, 0.0), 1.0)
    }

    public var formattedRemainingTime: String {
        let clamped = max(0, Int(remainingSeconds.rounded(.up)))
        let mins = clamped / 60
        let secs = clamped % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    // MARK: - Wiring System Surfaces (Lock Screen, AirPods, LiveActivity/Widget Intents)

    private func wireMediaAndMotionCallbacks() {
        mediaAndMotion.onPlayRequested = { [weak self] in
            guard let self else { return }
            if !self.isTimerRunning && !self.isSynthPlaying {
                self.startFocusTimer()
            }
        }
        mediaAndMotion.onPauseRequested = { [weak self] in
            guard let self else { return }
            if self.isTimerRunning {
                self.pauseFocusTimer()
            } else if self.isSynthPlaying {
                self.toggleStandaloneSynth()
            }
        }
        mediaAndMotion.onToggleRequested = { [weak self] in
            guard let self else { return }
            if self.isTimerRunning {
                self.pauseFocusTimer()
            } else if self.elapsedSeconds > 0 {
                self.startFocusTimer()
            } else {
                self.toggleStandaloneSynth()
            }
        }
        mediaAndMotion.onNextPresetRequested = { [weak self] in
            Task { await self?.cyclePreset(step: 1) }
        }
        mediaAndMotion.onPreviousPresetRequested = { [weak self] in
            Task { await self?.cyclePreset(step: -1) }
        }
        mediaAndMotion.onAudioInterruptedPause = { [weak self] in
            guard let self else { return }
            if self.isTimerRunning {
                self.pauseFocusTimer()
            } else if self.isSynthPlaying {
                self.isSynthPlaying = false
                Task { await self.audioEngine.pause() }
                self.syncSystemSurfaces()
            }
        }
        mediaAndMotion.onAudioInterruptionShouldResume = { [weak self] in
            guard let self else { return }
            if self.elapsedSeconds > 0 && !self.isTimerRunning {
                self.startFocusTimer()
            }
        }
        mediaAndMotion.onHeadOrientationChanged = { [weak self] pan, elevation in
            guard let self else { return }
            self.synthParameters.spatialPanOffset = pan
            self.synthParameters.headElevationTilt = elevation
            Task {
                await self.audioEngine.updateHeadTrackingOffsets(spatialPan: pan, elevationTilt: elevation)
            }
        }
    }

    private func wireExternalIntentNotifications() {
        externalIntentObserver = NotificationCenter.default.addObserver(
            forName: .aetherExternalIntentCommand,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let raw = notification.userInfo?[IntentNotificationBridge.actionUserInfoKey] as? String
            Task { @MainActor [weak self] in
                guard let self, let raw, let action = ExternalIntentAction(rawValue: raw) else { return }
                switch action {
                case .toggleFocus:
                    if self.isTimerRunning { self.pauseFocusTimer() } else { self.startFocusTimer() }
                case .setFocusOn:
                    if !self.isTimerRunning { self.startFocusTimer() }
                case .setFocusOff:
                    if self.isTimerRunning { self.pauseFocusTimer() }
                case .cycleNextPreset:
                    await self.cyclePreset(step: 1)
                case .habitPulseLogged:
                    self.hapticDirector.playOrbitalSnap(mass: 1.4)
                    await self.refreshSharedWidgetSnapshotFromDB()
                }
            }
        }
    }

    // MARK: - Lifecycle

    public func startSystemPipelines() async {
        try? await databaseActor.bootstrapDefaultsIfNeeded()
        mediaAndMotion.activateMediaIntegration()
        await audioEngine.updateParameters(synthParameters)
        await refreshSharedWidgetSnapshotFromDB()
        startTelemetryPollingLoop()
    }

    private func startTelemetryPollingLoop() {
        telemetryLoopTask?.cancel()
        telemetryLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard let self else { return }
                await self.tickFrameUpdate()
            }
        }
    }

    private func tickFrameUpdate() async {
        let snap = await audioEngine.snapshotTelemetry()
        let smoothedAmp = liveAudioAmplitude * 0.65 + snap.rmsAmplitude * 2.1 * 0.35
        liveAudioAmplitude = min(max(smoothedAmp, 0.0), 1.0)
        liveHighBandEnergy = min(max(snap.highBandEnergy, 0.0), 1.0)
        if snap.peakAmplitude > sessionPeakAmplitude {
            sessionPeakAmplitude = snap.peakAmplitude
        }

        if isSynthPlaying || isTimerRunning {
            let scope = await audioEngine.snapshotScopeWindow()
            let fftFrame = fftAnalyzer.analyze(samples: scope.samples, sampleRate: scope.sampleRate)
            spectrumBars = fftFrame.bars
            dominantSpectrumHz = fftFrame.dominantFrequencyHz
            orbitalRotationAngle += 0.0022 + Double(liveAudioAmplitude) * 0.006
        } else if dominantSpectrumHz > 0 {
            fftAnalyzer.reset()
            spectrumBars = [Float](repeating: 0, count: SpectralFFTAnalyzer.outputBarCount)
            dominantSpectrumHz = 0
        }

        guard isTimerRunning, let anchor = timerAnchorDate else { return }
        let totalPlanned = Double(selectedDurationMinutes * 60)
        let currentElapsed = accumulatedElapsedBeforePause + Date.now.timeIntervalSince(anchor)

        if currentElapsed >= totalPlanned {
            elapsedSeconds = totalPlanned
            remainingSeconds = 0
            completeFocusSession(completedNaturally: true)
        } else {
            elapsedSeconds = currentElapsed
            remainingSeconds = max(0, totalPlanned - currentElapsed)
        }
    }

    // MARK: - Focus Timer Controls

    public func toggleFocusTimer(linkedHabitTitle: String?) {
        if let linkedHabitTitle {
            selectedHabitTitle = linkedHabitTitle
        }
        if isTimerRunning {
            pauseFocusTimer()
        } else {
            startFocusTimer()
        }
    }

    public func startFocusTimer() {
        if sessionStartWallDate == nil {
            sessionStartWallDate = .now
            activeLiveSessionID = UUID()
            sessionPeakAmplitude = 0
        }
        timerAnchorDate = .now
        isTimerRunning = true
        isSynthPlaying = true
        hapticDirector.playTimerIgnition(starting: true)

        Task {
            try? await audioEngine.start()
            await audioEngine.updateParameters(synthParameters)
            await audioEngine.triggerHarmonicBloom(intensity: 0.75)
        }
        syncSystemSurfaces()
    }

    public func pauseFocusTimer() {
        if let anchor = timerAnchorDate {
            accumulatedElapsedBeforePause += Date.now.timeIntervalSince(anchor)
        }
        timerAnchorDate = nil
        isTimerRunning = false
        isSynthPlaying = false
        hapticDirector.playTimerIgnition(starting: false)

        Task {
            await audioEngine.pause()
        }
        syncSystemSurfaces()
    }

    public func finishEarlyOrResetFocusTimer(activeHabitTitle: String?) {
        if elapsedSeconds >= 30.0 {
            completeFocusSession(completedNaturally: false, fallbackTitle: activeHabitTitle)
        } else {
            resetTimerStateOnly()
        }
    }

    private func resetTimerStateOnly() {
        isTimerRunning = false
        isSynthPlaying = false
        timerAnchorDate = nil
        accumulatedElapsedBeforePause = 0
        sessionStartWallDate = nil
        elapsedSeconds = 0
        remainingSeconds = Double(selectedDurationMinutes * 60)
        Task { await audioEngine.pause() }
        #if canImport(ActivityKit) && os(iOS)
        liveActivityController.endAll()
        #endif
        syncSystemSurfaces(liveActivityActive: false)
    }

    private func completeFocusSession(completedNaturally: Bool, fallbackTitle: String? = nil) {
        isTimerRunning = false
        isSynthPlaying = false
        timerAnchorDate = nil

        let totalPlanned = Double(selectedDurationMinutes * 60)
        let actual = max(1.0, min(elapsedSeconds, totalPlanned))
        let ratio = min(1.0, actual / max(1.0, totalPlanned))
        let quality = completedNaturally ? min(1.0, 0.88 + Double(sessionPeakAmplitude) * 0.12) : (0.55 + ratio * 0.35)
        let started = sessionStartWallDate ?? Date.now.addingTimeInterval(-actual)

        if completedNaturally {
            hapticDirector.playSessionCompletionSymphony()
            Task { await audioEngine.triggerHarmonicBloom(intensity: 1.0) }
        } else {
            hapticDirector.playTimerIgnition(starting: false)
        }

        let dto = FocusSessionDTO(
            title: fallbackTitle ?? selectedHabitTitle,
            startedAt: started,
            endedAt: .now,
            plannedDurationSeconds: totalPlanned,
            actualDurationSeconds: actual,
            completed: completedNaturally || ratio >= 0.75,
            focusQualityScore: quality,
            peakAmplitude: Double(sessionPeakAmplitude),
            carrierFrequencyHz: Double(synthParameters.carrierFrequencyHz),
            beatFrequencyHz: Double(synthParameters.binauralBeatHz),
            linkedHabitID: selectedHabitID,
            notes: "",
            updatedAt: .now,
            revision: 1
        )

        accumulatedElapsedBeforePause = 0
        sessionStartWallDate = nil
        elapsedSeconds = 0
        remainingSeconds = Double(selectedDurationMinutes * 60)

        Task { await audioEngine.pause() }
        #if canImport(ActivityKit) && os(iOS)
        liveActivityController.endAll()
        #endif
        syncSystemSurfaces(liveActivityActive: false)

        pendingCompletedSession = dto
    }

    public func commitCompletedSession(_ session: FocusSessionDTO, notes: String) async {
        let enriched = FocusSessionDTO(
            sessionID: session.sessionID,
            title: session.title,
            startedAt: session.startedAt,
            endedAt: session.endedAt,
            plannedDurationSeconds: session.plannedDurationSeconds,
            actualDurationSeconds: session.actualDurationSeconds,
            completed: session.completed,
            focusQualityScore: session.focusQualityScore,
            peakAmplitude: session.peakAmplitude,
            carrierFrequencyHz: session.carrierFrequencyHz,
            beatFrequencyHz: session.beatFrequencyHz,
            linkedHabitID: session.linkedHabitID,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            updatedAt: .now,
            revision: 1
        )
        _ = try? await databaseActor.batchIngestSessions([enriched], conflictPolicy: .higherRevisionWins)
        pendingCompletedSession = nil
        await refreshSharedWidgetSnapshotFromDB()
    }

    // MARK: - Synth, Head-Tracking & Preset Controls

    public func toggleStandaloneSynth() {
        if isSynthPlaying {
            isSynthPlaying = false
            hapticDirector.playSegmentSnap()
            Task { await audioEngine.pause() }
        } else {
            isSynthPlaying = true
            hapticDirector.playTimerIgnition(starting: true)
            Task {
                try? await audioEngine.start()
                await audioEngine.updateParameters(synthParameters)
            }
        }
        syncSystemSurfaces(liveActivityActive: isTimerRunning)
    }

    public func toggleHeadTracking(_ enabled: Bool) {
        isHeadTrackingEnabled = enabled
        mediaAndMotion.setHeadTrackingEnabled(enabled)
        hapticDirector.playSegmentSnap()
    }

    public func pushSynthParameters(_ updated: SynthParameters, clearingPresetSelection: Bool = true) {
        synthParameters = updated
        if clearingPresetSelection {
            selectedPresetID = nil
            activePresetName = "Custom Patch"
        }
        Task { await audioEngine.updateParameters(updated) }
    }

    public func selectAudioPreset(_ preset: AudioPresetDTO) {
        selectedPresetID = preset.presetID
        activePresetName = preset.name
        var next = SynthParameters(preset: preset)
        next.spatialPanOffset = synthParameters.spatialPanOffset
        next.headElevationTilt = synthParameters.headElevationTilt
        synthParameters = next
        hapticDirector.playSegmentSnap()
        Task {
            await audioEngine.applyPreset(preset)
            if isSynthPlaying {
                await audioEngine.triggerHarmonicBloom(intensity: 0.55)
            }
        }
        syncSystemSurfaces(liveActivityActive: isTimerRunning || elapsedSeconds > 0)
    }

    public func cyclePreset(step: Int) async {
        guard let allPresets = try? await databaseActor.fetchAllAudioPresets(), !allPresets.isEmpty else { return }
        let currentIndex = allPresets.firstIndex(where: { $0.presetID == selectedPresetID }) ?? 0
        let nextIndex = (currentIndex + step + allPresets.count) % allPresets.count
        selectAudioPreset(allPresets[nextIndex])
    }

    public func saveCustomAudioPreset(name: String, category: FocusCategory) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let dto = AudioPresetDTO(
            name: trimmed,
            category: category,
            carrierFrequencyHz: Double(synthParameters.carrierFrequencyHz),
            binauralBeatHz: Double(synthParameters.binauralBeatHz),
            binauralMix: Double(synthParameters.binauralMix),
            pinkNoiseMix: Double(synthParameters.pinkNoiseMix),
            padMix: Double(synthParameters.padMix),
            filterCutoffHz: Double(synthParameters.filterCutoffHz),
            filterResonance: Double(synthParameters.filterResonance),
            padDetuneCents: Double(synthParameters.padDetuneCents),
            masterGain: Double(synthParameters.masterGain),
            isBuiltIn: false
        )
        if let saved = try? await databaseActor.upsertAudioPreset(dto) {
            selectedPresetID = saved.presetID
            activePresetName = saved.name
            hapticDirector.playOrbitalSnap(mass: 1.5)
        }
    }

    // MARK: - Habit Node Actions

    public func selectHabitSatellite(_ habit: HabitNode) {
        selectedHabitID = habit.habitID
        selectedHabitTitle = habit.title
        selectedHabitSymbol = habit.symbolName
        withAnimation(.spring(response: 0.40, dampingFraction: 0.78)) {
            activeAccentHue = habit.accentHue
        }
        hapticDirector.playOrbitalSnap(mass: habit.orbitalMass)
        Task { await refreshSharedWidgetSnapshotFromDB() }
    }

    public func logQuickHabitIncrement(_ habit: HabitNode, minutes: Int = 15) async {
        hapticDirector.playOrbitalSnap(mass: habit.orbitalMass)
        _ = try? await databaseActor.logQuickHabitIncrementHelper(habitID: habit.habitID, minutes: minutes)
        await refreshSharedWidgetSnapshotFromDB()
    }

    public func saveHabitDraft(_ dto: HabitNodeDTO) async {
        if let saved = try? await databaseActor.upsertHabit(dto) {
            selectedHabitID = saved.habitID
            selectedHabitTitle = saved.title
            selectedHabitSymbol = saved.symbolName
            activeAccentHue = saved.accentHue
            hapticDirector.playOrbitalSnap(mass: saved.orbitalMass)
        }
        editingHabitDraft = nil
        isHabitEditorPresented = false
        await refreshSharedWidgetSnapshotFromDB()
    }

    public func removeHabit(habitID: UUID) async {
        try? await databaseActor.deleteHabit(habitID: habitID)
        if selectedHabitID == habitID {
            selectedHabitID = nil
        }
        editingHabitDraft = nil
        isHabitEditorPresented = false
        await refreshSharedWidgetSnapshotFromDB()
    }

    // MARK: - Archive Portability Actions (JSON & CSV Export / Import)

    public func prepareJSONArchiveExport() async {
        do {
            let archive = try await databaseActor.exportFullArchive()
            exportJSONDocument = try AetherArchiveDocument(archive: archive)
            isExportingJSON = true
        } catch {
            presentTransientBanner("Export failed: \(error.localizedDescription)")
        }
    }

    public func prepareCSVLedgerExport() async {
        do {
            let csv = try await databaseActor.exportSessionsCSV()
            exportCSVDocument = AetherCSVDocument(csvString: csv)
            isExportingCSV = true
        } catch {
            presentTransientBanner("CSV export failed: \(error.localizedDescription)")
        }
    }

    public func importArchiveFromURL(_ url: URL) async {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }

        do {
            let data = try Data(contentsOf: url)
            let archive = try AetherTelemetryArchive.decodeAndValidate(from: data)
            let summary = try await databaseActor.importFullArchive(
                archive,
                conflictPolicy: .higherRevisionWins
            )
            hapticDirector.playSessionCompletionSymphony()
            await refreshSharedWidgetSnapshotFromDB()
            presentTransientBanner(
                "Imported \(summary.importedHabits) habits, \(summary.sessionReport.insertedSessions + summary.sessionReport.updatedSessions) sessions."
            )
        } catch {
            presentTransientBanner("Import error: \(error.localizedDescription)")
        }
    }

    public func presentTransientBanner(_ message: String) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            statusBannerMessage = message
        }
        Task {
            try? await Task.sleep(for: .seconds(3.5))
            if statusBannerMessage == message {
                withAnimation { statusBannerMessage = nil }
            }
        }
    }

    // MARK: - System Surface Sync (Live Activity, Lock Screen Media, Widgets, Control Center)

    private func syncSystemSurfaces(liveActivityActive: Bool = true) {
        let totalPlanned = Double(selectedDurationMinutes * 60)

        mediaAndMotion.updateNowPlayingMetadata(
            title: selectedHabitTitle,
            presetName: activePresetName,
            beatFrequencyHz: synthParameters.binauralBeatHz,
            accentHue: activeAccentHue,
            elapsedSeconds: elapsedSeconds,
            plannedDurationSeconds: totalPlanned,
            isPlaying: isSynthPlaying || isTimerRunning
        )

        #if canImport(ActivityKit) && os(iOS)
        if liveActivityActive && (isTimerRunning || elapsedSeconds > 0) {
            let endDate = Date.now.addingTimeInterval(remainingSeconds)
            let state = FocusActivityAttributes.ContentState(
                sessionTitle: selectedHabitTitle,
                habitSymbolName: selectedHabitSymbol,
                accentHue: activeAccentHue,
                targetEndDate: endDate,
                plannedDurationSeconds: totalPlanned,
                pausedRemainingSeconds: isTimerRunning ? nil : remainingSeconds,
                binauralBeatHz: Double(synthParameters.binauralBeatHz),
                presetName: activePresetName,
                isRunning: isTimerRunning
            )
            liveActivityController.startOrUpdate(
                sessionID: activeLiveSessionID,
                categoryName: activePresetName,
                state: state
            )
        }
        #endif

        var widgetSnap = SharedWidgetStateStore.read()
        widgetSnap.isFocusRunning = isTimerRunning
        widgetSnap.binauralBeatHz = Double(synthParameters.binauralBeatHz)
        widgetSnap.activePresetName = activePresetName
        widgetSnap.accentHue = activeAccentHue
        widgetSnap.updatedAt = .now
        SharedWidgetStateStore.write(widgetSnap)

        WidgetCenter.shared.reloadAllTimelines()
        if #available(iOS 18.0, *) {
            ControlCenter.shared.reloadAllControls()
        }
    }

    public func refreshSharedWidgetSnapshotFromDB() async {
        let habits = (try? await databaseActor.fetchActiveHabits()) ?? []
        let primary = habits.first(where: { $0.habitID == selectedHabitID }) ?? habits.first

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let weekAgo = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        let recentTelemetry = (try? await databaseActor.fetchTelemetryWindow(from: weekAgo, to: today)) ?? []
        var bucketMap: [String: Int] = [:]
        for t in recentTelemetry {
            bucketMap[t.dayKey] = t.intensityLevel
        }

        var buckets: [Int] = []
        for offset in stride(from: -6, through: 0, by: 1) {
            let d = calendar.date(byAdding: .day, value: offset, to: today) ?? today
            let k = DayKeyFormatter.dayKey(for: d, calendar: calendar)
            buckets.append(bucketMap[k] ?? 0)
        }

        let snap = SharedWidgetSnapshot(
            isFocusRunning: isTimerRunning,
            activeHabitIDString: primary?.habitID.uuidString,
            activeHabitTitle: primary?.title ?? selectedHabitTitle,
            activeHabitSymbol: primary?.symbolName ?? selectedHabitSymbol,
            accentHue: primary?.accentHue ?? activeAccentHue,
            completedMinutesToday: primary?.completedMinutesToday ?? 0,
            targetMinutesToday: primary?.targetMinutesPerDay ?? 45,
            currentStreak: primary?.currentStreak ?? 0,
            binauralBeatHz: Double(synthParameters.binauralBeatHz),
            activePresetName: activePresetName,
            recentSevenDayBuckets: buckets,
            updatedAt: .now
        )
        SharedWidgetStateStore.write(snap)
        WidgetCenter.shared.reloadAllTimelines()
    }
}

private extension TelemetryDatabaseActor {
    func logQuickHabitIncrementHelper(habitID: UUID, minutes: Int) throws -> HabitNodeDTO? {
        try logQuickHabitPulse(habitID: habitID, addedMinutes: minutes)
    }
}
