// MARK: - FILE: AetherSynthApp.swift

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

#if os(iOS)
@main
public struct AetherSynthApp: App {
    private let container: ModelContainer
    @State private var coordinator: AetherAppCoordinator

    public init() {
        do {
            let sharedContainer = try AetherPersistenceSchema.makeContainer(inMemory: false)
            self.container = sharedContainer
            self._coordinator = State(initialValue: AetherAppCoordinator(modelContainer: sharedContainer))
        } catch {
            fatalError("Failed to initialize SwiftData ModelContainer: \(error.localizedDescription)")
        }
    }

    public var body: some Scene {
        WindowGroup {
            RootSpatialShellView(coordinator: coordinator)
                .modelContainer(container)
                .preferredColorScheme(.dark)
        }
    }
}
#endif

public struct RootSpatialShellView: View {
    @Bindable public var coordinator: AetherAppCoordinator
    @Environment(\.scenePhase) private var scenePhase

    @Query(
        filter: #Predicate<HabitNode> { node in
            node.isArchived == false
        },
        sort: [
            SortDescriptor(\HabitNode.sortOrder, order: .forward),
            SortDescriptor(\HabitNode.createdAt, order: .forward)
        ]
    )
    private var activeHabits: [HabitNode]

    @Query(
        sort: [
            SortDescriptor(\AudioPreset.isBuiltIn, order: .reverse),
            SortDescriptor(\AudioPreset.name, order: .forward)
        ]
    )
    private var audioPresets: [AudioPreset]

    @Query(
        sort: [SortDescriptor(\DailyTelemetry.dateStartOfDay, order: .forward)]
    )
    private var telemetryHistory: [DailyTelemetry]

    private let navigationSegments: [AetherSegmentItem<SpatialTabSection>] = [
        AetherSegmentItem(id: .orbit, title: "Orbit", symbolName: "atom"),
        AetherSegmentItem(id: .synthLab, title: "Synth Lab", symbolName: "waveform.circle.fill"),
        AetherSegmentItem(id: .matrix, title: "Matrix", symbolName: "square.grid.3x3.fill")
    ]

    public init(coordinator: AetherAppCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            AetherSpatialBackdropView(
                audioAmplitude: coordinator.liveAudioAmplitude,
                highBandEnergy: coordinator.liveHighBandEnergy,
                beatFrequencyHz: coordinator.synthParameters.binauralBeatHz,
                accentHue: coordinator.activeAccentHue,
                focusProgress: coordinator.focusProgress,
                onTouchVelocityPulse: { normVel, normY in
                    coordinator.hapticDirector.playRippleTouch(normalizedVelocity: normVel, normalizedY: normY)
                }
            )
            #if os(visionOS)
            .opacity(0.62)
            #endif

            VStack(spacing: 14) {
                topSpatialHeaderBar
                    .padding(.horizontal, 16)
                    .padding(.top, 6)

                AetherSegmentedControl(
                    items: navigationSegments,
                    selection: $coordinator.activeSection,
                    accentHue: coordinator.activeAccentHue,
                    onSelect: { coordinator.hapticDirector.playSegmentSnap() }
                )
                .padding(.horizontal, 16)

                Group {
                    switch coordinator.activeSection {
                    case .orbit:
                        OrbitalFocusArenaView(coordinator: coordinator, habits: activeHabits)
                            .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    case .synthLab:
                        SynthLabPanelView(coordinator: coordinator, presets: audioPresets)
                            .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    case .matrix:
                        ContributionHeatmapView(
                            telemetryRecords: telemetryHistory,
                            accentHue: coordinator.activeAccentHue,
                            audioEnergy: coordinator.liveAudioAmplitude,
                            onScrubIntensity: { level in
                                coordinator.hapticDirector.scrubDayCell(intensityLevel: level)
                            },
                            onLoadDaySessions: { dayKey in
                                (try? await coordinator.databaseActor.fetchSessionsForDay(dayKey: dayKey)) ?? []
                            },
                            onExportJSON: {
                                Task { await coordinator.prepareJSONArchiveExport() }
                            },
                            onExportCSV: {
                                Task { await coordinator.prepareCSVLedgerExport() }
                            },
                            onImportJSON: {
                                coordinator.isImportingArchive = true
                            }
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let banner = coordinator.statusBannerMessage {
                Text(banner)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay {
                        Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.8)
                    }
                    .padding(.bottom, 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .task {
            await coordinator.startSystemPipelines()
            if coordinator.selectedHabitID == nil, let first = activeHabits.first {
                coordinator.selectedHabitID = first.habitID
                coordinator.selectedHabitTitle = first.title
                coordinator.selectedHabitSymbol = first.symbolName
                coordinator.activeAccentHue = first.accentHue
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                coordinator.hapticDirector.prepareEngineIfSupported()
            }
        }
        .sheet(isPresented: $coordinator.isHabitEditorPresented) {
            CreateOrEditHabitSheet(
                existingDraft: coordinator.editingHabitDraft,
                onSave: { draft in await coordinator.saveHabitDraft(draft) },
                onDelete: coordinator.editingHabitDraft != nil
                    ? { id in await coordinator.removeHabit(habitID: id) }
                    : nil
            )
        }
        .sheet(isPresented: $coordinator.isSavePresetSheetPresented) {
            SaveAudioPresetSheet(
                currentParameters: coordinator.synthParameters,
                onSave: { name, category in
                    await coordinator.saveCustomAudioPreset(name: name, category: category)
                }
            )
        }
        .sheet(item: $coordinator.pendingCompletedSession) { completedSession in
            SessionSummarySheet(
                session: completedSession,
                accentHue: coordinator.activeAccentHue,
                onCommit: { notes in
                    await coordinator.commitCompletedSession(completedSession, notes: notes)
                }
            )
        }
        .fileExporter(
            isPresented: $coordinator.isExportingJSON,
            document: coordinator.exportJSONDocument,
            contentType: .json,
            defaultFilename: "AetherSynth-Archive-\(DayKeyFormatter.dayKey(for: .now))"
        ) { result in
            if case .success = result {
                coordinator.presentTransientBanner("Verified JSON archive exported.")
            }
        }
        .fileExporter(
            isPresented: $coordinator.isExportingCSV,
            document: coordinator.exportCSVDocument,
            contentType: .commaSeparatedText,
            defaultFilename: "AetherSynth-Sessions-\(DayKeyFormatter.dayKey(for: .now))"
        ) { result in
            if case .success = result {
                coordinator.presentTransientBanner("CSV session ledger exported.")
            }
        }
        .fileImporter(
            isPresented: $coordinator.isImportingArchive,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let firstURL = urls.first {
                Task { await coordinator.importArchiveFromURL(firstURL) }
            }
        }
    }

    private var topSpatialHeaderBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("AETHERSYNTH & FLOW")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .tracking(1.4)
                    .foregroundStyle(.white)
                Text(coordinator.isTimerRunning ? "Spatial Lock · Live Activity Active" : "Offline Procedural Engine Ready")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.60))
            }

            Spacer()

            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 12, weight: .bold))
                    .symbolEffect(.variableColor.iterative, isActive: coordinator.isSynthPlaying)
                    .foregroundStyle(Color(hue: coordinator.activeAccentHue, saturation: 0.68, brightness: 1.0))

                Text(String(format: "%.0f%%", coordinator.liveAudioAmplitude * 100.0))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay {
                Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 0.8)
            }
        }
    }
}
