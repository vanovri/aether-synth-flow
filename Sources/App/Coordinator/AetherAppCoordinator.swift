// MARK: - FILE: AetherAppCoordinator.swift

import Foundation
import SwiftUI
import SwiftData
import Observation
#if canImport(WidgetKit) && !os(visionOS)
import WidgetKit
#endif
#if canImport(CoreML)
import CoreML
#endif
import simd

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

    // Real-Time Synth, KEMAR HRTF, Shoebox Room Acoustics & Head-Tracking State
    public var synthParameters: SynthParameters = {
        var initial = SynthParameters(preset: AudioPresetDTO.defaultPresets[0])
        initial.isHRTFSpatializerEnabled = true
        initial.roomPresetIndex = ShoeboxRoomPreset.obsidianStudio.rawValue
        initial.hrtfAzimuthDeg = 18.0
        initial.hrtfElevationDeg = 14.0
        initial.hrtfDistanceMeters = 1.45
        return initial
    }()
    public var selectedPresetID: UUID? = AudioPresetDTO.defaultPresets[0].presetID
    public var activePresetName: String = AudioPresetDTO.defaultPresets[0].name
    public var isSynthPlaying: Bool = false
    public var liveAudioAmplitude: Float = 0.0
    public var liveSubBandEnergy: Float = 0.0
    public var liveLowBandEnergy: Float = 0.0
    public var liveMidBandEnergy: Float = 0.0
    public var liveHighBandEnergy: Float = 0.0
    public var orbitalRadiusScale: Double = 1.0
    public var latestSpatialModulation: SpatialPoseModulationOutput?
    public var sessionPeakAmplitude: Float = 0.0
    public var spectrumBars: [Float] = [Float](repeating: 0, count: SpectralFFTAnalyzer.outputBarCount)
    public var dominantSpectrumHz: Float = 0.0
    public var isHeadTrackingEnabled: Bool = false
    public var isOrbitalSourceAutoLockEnabled: Bool = false
    public var hrtfOrbitalSpeedRadPerSec: Float = 0.32
    public var currentRoomReflectionTaps: [ImageSourceReflectionTap] = []

    // GPU MPSGraph Neural Trainer Telemetry State
    public var neuralTelemetry: TrainingTelemetrySnapshot = TrainingTelemetrySnapshot()
    public var lossConvergenceHistory: [Float] = []
    public var latestNeuralPrediction: BrainwavePrediction?
    public var isNeuralTrainingRunning: Bool = false

    // watchOS 11 Biometric Streaming & Closed-Loop CoreML Entrainment State
    public var isBioEntrainmentEnabled: Bool = false
    public var isSimulateWristBiometricsEnabled: Bool = false
    public var isWatchCounterpartReachable: Bool = false
    public var latestBiometricSnapshot: BiometricSnapshotDTO?
    public var latestHRVMetrics: HRVAnalysisMetricsDTO?
    public var latestBioEntrainmentPrediction: BrainwavePredictionOutput?
    public var onlineAdaptationEpochs: Int = 0
    public var lastOnlineHuberLoss: Double = 0.0

    // Phase 7: GPU Metal Ray-Traced 3D Acoustics & Neural Latent Soundscape State
    public var selectedChamberPreset: AcousticChamberPreset = .geodesicSanctuary
    public var selectedSurfaceMaterialPreset: AcousticSurfaceMaterialPreset = .perforatedAcousticWood
    public var latestAcousticReport: AcousticTraceReport?
    public var latestNeuralSoundscapeTelemetry: NeuralSoundscapeTelemetry = NeuralSoundscapeTelemetry()
    public var activeFocusCategory: FocusCategory = .deepWork

    // Phase 8: Distributed Multi-Peer Spatial Orchestra & Wave-Field Array State
    public var orchestraSnapshot: OrchestraMeshStatusSnapshot = OrchestraMeshStatusSnapshot()

    // Phase 3: WAV Stem Export, 3D SDF Core, Kalman Entrainment & P2P E2EE Mesh Sync State (Tracks 5, 6, 7, 8)
    public var exportWAVDocument: WAVStemDocument?
    public var isExportingWAV: Bool = false
    public var selectedWAVBitDepth: WAVBitDepth = .pcm24Bit
    public var use3DRaymarchedCore: Bool = true
    public var isEntrainmentCurveEnabled: Bool = true
    public var kalmanFilter = FocusStateKalmanFilter()
    public var latestKalmanEstimate: KalmanFocusEstimate = FocusStateKalmanFilter().currentEstimate
    public var isMeshSyncSheetPresented: Bool = false
    public var isMeshBonjourActive: Bool = false
    public var meshPeers: [MeshPeerSummary] = []
    public var meshLamportClock: UInt64 = 1

    // Phases 9 & 10: 2D FDTD Wave Tank, Chromatic Caustics, 4-Ch EEG BCI, SPWVD/HHT, Quantum MPS/DMRG & Capstone Audit (Tracks 30–36)
    public let waveTankController = VisualFDTDWaveTankController()
    public let eegBCI = EEGBrainComputerInterface()
    public var showOpticalCausticsMode: Bool = false
    public var latestEEGMetrics: CorticalSpectralMetrics?
    public var isClosedLoopIAFLockEnabled: Bool = false
    public var isCorticalIAFLockEnabled: Bool = false
    public var useGoldenRatioIAFSubharmonic: Bool = false
    public var latestSPWVDResult: SPWVDResult?
    public var latestHHTResult: HilbertHuangResult?
    public var latestMPSTelemetry: MPSTelemetrySnapshot?
    public var latestOptimalBioAcousticControl: OptimalBioAcousticControl?
    public var dmrgSweepSnapshots: [MPSTelemetrySnapshot] = []
    public var selectedMPSBondDimension: Int = 8
    public var latestCapstoneReport: CapstoneAuditReport?
    public var isRunningCapstoneAudit: Bool = false
    public var isCapstoneAuditSheetPresented: Bool = false
    public var exportCapstoneMarkdownDocument: CapstoneReportMarkdownDocument?
    public var isExportingCapstoneMarkdown: Bool = false
    public var exportCapstoneJSONDocument: CapstoneReportJSONDocument?
    public var isExportingCapstoneJSON: Bool = false

    // Underlying Actors, DSP, Haptics & System Bridges
    public let hapticDirector = HapticDirector()
    public let audioEngine = AudioSynthEngine()
    public let stemExporter = OfflineStemExporter()
    public let fftAnalyzer = SpectralFFTAnalyzer()
    public let mediaAndMotion = MediaSessionAndHeadTrackingController()
    public let neuralTrainer = MPSGraphBrainwaveTrainer()
    public let mlPredictor = AdaptiveBrainwaveMLPredictor()
    public let watchBridge = WatchBiometricBridgeActor()
    public let acousticRayTracer = MetalAcousticRayTracer()
    public let neuralSoundscapeEngine = NeuralLatentSoundscapeEngine()
    public let orchestraEngine = DistributedOrchestraEngine()
    public let databaseActor: TelemetryDatabaseActor
    public let meshSyncActor: AetherMeshSyncActor

    #if canImport(ActivityKit) && os(iOS)
    private let liveActivityController = FocusLiveActivityController()
    #endif

    private var eegGenerator = SyntheticCorticalEEGGenerator()
    private var eegFilterBank = EEGArtifactFilterBank()
    private var pidController = EntrainmentPIDController()
    private var physiologySimulator = SyntheticPhysiologySimulator(initialStressLevel: 0.58)
    private var lastBioEntrainmentTickDate: Date = .distantPast
    private var lastOrchestraTickDate: Date = .distantPast
    private var previousEvaluatedMetrics: HRVAnalysisMetricsDTO?
    private var previousEvaluatedFeatures: BiometricFeatureVector?
    private var previousPredictionOutput: BrainwavePredictionOutput?
    private var acousticSolveTask: Task<Void, Never>?
    private var isNeuralBlockGenerating: Bool = false

    private var activeLiveSessionID = UUID()
    private var timerAnchorDate: Date?
    private var accumulatedElapsedBeforePause: Double = 0.0
    private var sessionStartWallDate: Date?
    private var telemetryLoopTask: Task<Void, Never>?
    private var externalIntentObserver: NSObjectProtocol?
    private var cachedOrbitHabits: [HabitNodeDTO] = []
    private var frameCounter: Int = 0

    public init(modelContainer: ModelContainer) {
        let db = TelemetryDatabaseActor(modelContainer: modelContainer)
        self.databaseActor = db
        self.meshSyncActor = AetherMeshSyncActor(databaseActor: db)
        refreshRoomReflectionPreview()
        wireMediaAndMotionCallbacks()
        wireExternalIntentNotifications()
    }

    public var currentEntrainmentSchedule: EntrainmentRampSchedule {
        EntrainmentRampSchedule(category: activeFocusCategory)
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

    public var activeRoomPreset: ShoeboxRoomPreset {
        ShoeboxRoomPreset(rawValue: synthParameters.roomPresetIndex) ?? .obsidianStudio
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
        mediaAndMotion.onHeadQuaternionChanged = { [weak self] quat, pan, elevation in
            guard let self else { return }
            self.synthParameters.spatialPanOffset = pan
            self.synthParameters.headElevationTilt = elevation
            self.synthParameters.headQuaternion = quat
            self.refreshRoomReflectionPreview()
            Task {
                await self.audioEngine.updateHeadTrackingOffsets(
                    spatialPan: pan,
                    elevationTilt: elevation,
                    headQuaternion: quat
                )
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
                case .launchBioEntrainment:
                    self.toggleBioEntrainmentClosedLoop(true)
                    if !self.isTimerRunning { self.startFocusTimer() }
                }
            }
        }
    }

    // MARK: - Lifecycle

    public func startSystemPipelines() async {
        try? await databaseActor.bootstrapDefaultsIfNeeded()
        mediaAndMotion.activateMediaIntegration()

        let activeHabits = (try? await databaseActor.fetchActiveHabits()) ?? []
        cachedOrbitHabits = activeHabits
        synthParameters.orbitalSatellites = OrbitalSatelliteBank.build(
            from: activeHabits,
            rotationRadians: orbitalRotationAngle,
            orbitalSpeedRadPerSec: hrtfOrbitalSpeedRadPerSec
        )
        await audioEngine.updateParameters(synthParameters)

        // Restore saved neural checkpoint if available, otherwise snapshot initialized GPU/SIMD model
        if let restored = try? await neuralTrainer.loadCheckpoint() {
            neuralTelemetry = restored
        } else {
            neuralTelemetry = await neuralTrainer.snapshotTelemetry()
        }
        let sampleBatch = BiometricTrainingBatch.makeSyntheticBiometricDataset(batchSize: 2)
        let firstWindow = Array(sampleBatch.inputs.prefix(MPSGraphBrainwaveTrainer.sequenceLength * MPSGraphBrainwaveTrainer.featureDim))
        latestNeuralPrediction = await neuralTrainer.predictOptimalSetpoint(sequence8x12: firstWindow)

        let storedWeights = await mlPredictor.currentWeightsSnapshot()
        onlineAdaptationEpochs = storedWeights.trainedEpochCount
        await wireWatchBiometricBridge()

        await refreshRayTracedAcoustics()
        await pumpNeuralSoundscapeRingBufferIfNeeded(forceInitialBlock: true)
        orchestraSnapshot = orchestraEngine.snapshot()
        await assimilateKalmanHistoryFromDB()
        await refreshCorticalEEGAndTFR()
        await refreshQuantumMPSAndDMRG()

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
        frameCounter &+= 1
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
            liveSubBandEnergy = fftFrame.subBandEnergy
            liveLowBandEnergy = fftFrame.lowBandEnergy
            liveMidBandEnergy = fftFrame.midBandEnergy
            liveHighBandEnergy = max(liveHighBandEnergy, fftFrame.highBandEnergy)

            let angularStep = Double(hrtfOrbitalSpeedRadPerSec) * 0.033 + Double(liveAudioAmplitude) * 0.004
            orbitalRotationAngle += angularStep

            if isOrbitalSourceAutoLockEnabled {
                let lockedAz = Float((orbitalRotationAngle * 180.0 / .pi).truncatingRemainder(dividingBy: 360.0))
                let lockedEl = 16.0 * Float(sin(orbitalRotationAngle * 0.75))
                synthParameters.hrtfAzimuthDeg = BinauralSourcePose.wrapAzimuthDegrees(lockedAz)
                synthParameters.hrtfElevationDeg = lockedEl
                if (frameCounter & 3) == 0 {
                    refreshRoomReflectionPreview()
                }
            }

            if (frameCounter & 7) == 0 {
                let bank = OrbitalSatelliteBank.build(
                    from: cachedOrbitHabits,
                    rotationRadians: orbitalRotationAngle,
                    orbitalSpeedRadPerSec: hrtfOrbitalSpeedRadPerSec
                )
                synthParameters.orbitalSatellites = bank
                await audioEngine.updateParameters(synthParameters)
            }

            if synthParameters.neuralSoundscapeMix > 0.001,
               audioEngine.neuralRingBuffer.availableFramesToRead < 12_288,
               !isNeuralBlockGenerating {
                Task { [weak self] in
                    await self?.pumpNeuralSoundscapeRingBufferIfNeeded(forceInitialBlock: false)
                }
            }
        } else if dominantSpectrumHz > 0 {
            fftAnalyzer.reset()
            spectrumBars = [Float](repeating: 0, count: SpectralFFTAnalyzer.outputBarCount)
            dominantSpectrumHz = 0
            liveSubBandEnergy = 0
            liveLowBandEnergy = 0
            liveMidBandEnergy = 0
        }

        let nowWall = Date.now
        let bioDt = nowWall.timeIntervalSince(lastBioEntrainmentTickDate)
        if bioDt >= 2.0 {
            let clampedDt = min(max(bioDt, 0.5), 4.0)
            lastBioEntrainmentTickDate = nowWall
            await tickClosedLoopBioEntrainment(dtSeconds: clampedDt)
        }

        if orchestraSnapshot.isMeshSyncEnabled {
            let orchDt = nowWall.timeIntervalSince(lastOrchestraTickDate)
            if orchDt >= 0.095 {
                let clampedOrchDt = min(max(orchDt, 0.05), 0.25)
                lastOrchestraTickDate = nowWall
                let stepResult = orchestraEngine.tickMeshSynchronization(
                    dtSeconds: clampedOrchDt,
                    sampleRate: 48_000.0,
                    tempoBPM: 120.0,
                    binauralBeatHz: Double(synthParameters.binauralBeatHz)
                )
                orchestraSnapshot = stepResult.snapshot
                await audioEngine.updateOrchestraSync(stepResult.dspControl)
            }
        }

        // Phase 9: Step 128x128 Visual FDTD Waveguide Tank & 4-Channel Cortical EEG BCI
        eegBCI.stepRealtimeFrame(dtSeconds: 0.033, activeBinauralBeatHz: synthParameters.binauralBeatHz)
        if isSynthPlaying || isTimerRunning || synthParameters.fdtdResonatorMix > 0.001 {
            waveTankController.stepVisualFrame(substeps: 2)
        }
        if isCorticalIAFLockEnabled {
            let iaf = eegBCI.latestMetrics.individualAlphaFrequencyHz
            let targetBeat = useGoldenRatioIAFSubharmonic ? (iaf / 1.6180339887) : iaf
            let clampedTargetBeat = min(max(targetBeat, 0.5), 40.0)
            let nextBeat = synthParameters.binauralBeatHz + 0.15 * (clampedTargetBeat - synthParameters.binauralBeatHz)
            let pacMI = eegBCI.latestMetrics.thetaGammaPACModulationIndex
            let targetKappa = min(max(0.14 + pacMI * 2.4, 0.05), 0.92)
            let nextKappa = synthParameters.fdtdStiffness + 0.18 * (targetKappa - synthParameters.fdtdStiffness)

            if abs(nextBeat - synthParameters.binauralBeatHz) > 0.015 || abs(nextKappa - synthParameters.fdtdStiffness) > 0.004 {
                synthParameters.binauralBeatHz = nextBeat
                synthParameters.fdtdStiffness = nextKappa
                await audioEngine.updateParameters(synthParameters)
            }
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
            if isEntrainmentCurveEnabled && !isBioEntrainmentEnabled && (frameCounter & 15) == 0 {
                let splinePoint = currentEntrainmentSchedule.sample(at: focusProgress)
                var next = synthParameters
                next.carrierFrequencyHz = splinePoint.carrierFrequencyHz
                next.binauralBeatHz = splinePoint.binauralBeatHz
                next.filterCutoffHz = splinePoint.filterCutoffHz
                synthParameters = next
                await audioEngine.updateParameters(next)
            }
        }
    }

    // MARK: - 3D KEMAR HRTF, Shoebox Room & Orbital Spatializer Controls

    public func refreshRoomReflectionPreview() {
        let pose = BinauralSourcePose(
            azimuthDeg: synthParameters.hrtfAzimuthDeg,
            elevationDeg: synthParameters.hrtfElevationDeg,
            distanceMeters: synthParameters.hrtfDistanceMeters
        )
        let solved = ShoeboxRoomSimulator.solveImageSources(
            configuration: activeRoomPreset.configuration,
            sourcePose: pose,
            headOrientation: simd_quatf(vector: synthParameters.headQuaternion)
        )
        currentRoomReflectionTaps = solved.taps
    }

    public func updateHRTFSourcePose(
        azimuthDeg: Float,
        elevationDeg: Float,
        distanceMeters: Float
    ) {
        synthParameters.hrtfAzimuthDeg = BinauralSourcePose.wrapAzimuthDegrees(azimuthDeg)
        synthParameters.hrtfElevationDeg = min(max(elevationDeg, -45.0), 90.0)
        synthParameters.hrtfDistanceMeters = min(max(distanceMeters, 0.15), 10.0)
        refreshRoomReflectionPreview()
        Task {
            await audioEngine.updateHRTFPose(
                azimuthDeg: synthParameters.hrtfAzimuthDeg,
                elevationDeg: synthParameters.hrtfElevationDeg,
                distanceMeters: synthParameters.hrtfDistanceMeters
            )
        }
    }

    public func selectShoeboxRoomPreset(_ preset: ShoeboxRoomPreset) {
        synthParameters.roomPresetIndex = preset.rawValue
        refreshRoomReflectionPreview()
        hapticDirector.playSegmentSnap()
        Task {
            await audioEngine.updateHRTFPose(
                azimuthDeg: synthParameters.hrtfAzimuthDeg,
                elevationDeg: synthParameters.hrtfElevationDeg,
                distanceMeters: synthParameters.hrtfDistanceMeters,
                roomPresetIndex: preset.rawValue
            )
        }
    }

    public func toggleHRTFSpatializer(_ enabled: Bool) {
        synthParameters.isHRTFSpatializerEnabled = enabled
        hapticDirector.playSegmentSnap()
        Task {
            await audioEngine.updateHRTFPose(
                azimuthDeg: synthParameters.hrtfAzimuthDeg,
                elevationDeg: synthParameters.hrtfElevationDeg,
                distanceMeters: synthParameters.hrtfDistanceMeters,
                isSpatializerEnabled: enabled
            )
        }
    }

    public func toggleOrbitalSourceAutoLock(_ enabled: Bool) {
        isOrbitalSourceAutoLockEnabled = enabled
        hapticDirector.playSegmentSnap()
    }

    // MARK: - 6-DoF VisionOS Bimanual Pose Modulation & Manual Bloom

    public func applySpatialPoseModulation(
        _ modulation: SpatialPoseModulationOutput,
        coupleToDSP: Bool = true,
        isSimulated: Bool = false
    ) {
        latestSpatialModulation = modulation
        orbitalRadiusScale = Double(modulation.orbitalRadiusScale)

        guard coupleToDSP else { return }

        var next = synthParameters
        if modulation.leftPinchEngaged || isSimulated {
            next.binauralBeatHz = modulation.binauralBeatHz
        }
        if modulation.rightPinchEngaged || isSimulated {
            next.filterCutoffHz = modulation.filterCutoffHz
        }
        next.filterResonance = modulation.filterResonance
        next.padDetuneCents = modulation.padDetuneCents
        next.bloomBoost = modulation.bloomBoost
        next.spatialPanOffset = modulation.spatialPanOffset
        next.headElevationTilt = modulation.headElevationTilt
        next.headQuaternion = modulation.headQuaternion

        synthParameters = next
        if isSynthPlaying || isTimerRunning {
            Task {
                await audioEngine.updateParameters(next)
            }
        }
    }

    public func triggerManualHarmonicBloom(intensity: Float = 0.88) {
        hapticDirector.playOrbitalSnap(mass: 1.55)
        Task {
            await audioEngine.triggerHarmonicBloom(intensity: intensity)
        }
    }

    // MARK: - GPU MPSGraph Neural Replay Training Controls

    public func run32EpochGPUReplayTrainingBatch(epochs: Int = 32) async {
        guard !isNeuralTrainingRunning else { return }
        isNeuralTrainingRunning = true
        hapticDirector.playTimerIgnition(starting: true)

        let seed = UInt64(max(1, neuralTelemetry.epochCount + 1)) &* 0x9E37_79B9_7F4A_7C15
        let replayBatch = BiometricTrainingBatch.makeSyntheticBiometricDataset(batchSize: 8, seed: seed)

        let snapshots = await neuralTrainer.trainEpochs(batch: replayBatch, epochs: epochs)
        for snap in snapshots {
            lossConvergenceHistory.append(snap.latestLoss)
        }
        if lossConvergenceHistory.count > 96 {
            lossConvergenceHistory.removeFirst(lossConvergenceHistory.count - 96)
        }
        if let finalSnap = snapshots.last {
            neuralTelemetry = finalSnap
        }

        let evalWindow = Array(replayBatch.inputs.prefix(MPSGraphBrainwaveTrainer.sequenceLength * MPSGraphBrainwaveTrainer.featureDim))
        let prediction = await neuralTrainer.predictOptimalSetpoint(sequence8x12: evalWindow)
        latestNeuralPrediction = prediction

        _ = try? await neuralTrainer.saveCheckpoint()
        isNeuralTrainingRunning = false
        hapticDirector.playOrbitalSnap(mass: 1.45)
        presentTransientBanner(
            String(
                format: "%@ trained %d epochs · Loss %.4f",
                neuralTelemetry.activeBackend.displayTitle,
                epochs,
                neuralTelemetry.latestLoss
            )
        )
    }

    public func applyNeuralPredictionToSynth() {
        guard let pred = latestNeuralPrediction else { return }
        var updated = synthParameters
        updated.binauralBeatHz = pred.binauralBeatHz
        updated.carrierFrequencyHz = pred.carrierHz
        updated.filterCutoffHz = pred.filterCutoffHz
        hrtfOrbitalSpeedRadPerSec = pred.hrtfOrbitSpeed
        updated.orbitalSatellites = OrbitalSatelliteBank.build(
            from: cachedOrbitHabits,
            rotationRadians: orbitalRotationAngle,
            orbitalSpeedRadPerSec: pred.hrtfOrbitSpeed
        )
        pushSynthParameters(updated)
        hapticDirector.playOrbitalSnap(mass: 1.6)
        presentTransientBanner(
            String(format: "Applied Neural Setpoint · %.1f Hz Beat · %.0f%% Coherence", pred.binauralBeatHz, pred.targetCoherence * 100.0)
        )
    }

    // MARK: - watchOS 11 Biometric Bridge & 2s Closed-Loop CoreML + PID Entrainment

    private func wireWatchBiometricBridge() async {
        await watchBridge.setHandlers(
            onTelemetry: { [weak self] snapshot, metrics in
                await MainActor.run {
                    guard let self else { return }
                    self.latestBiometricSnapshot = snapshot
                    self.latestHRVMetrics = metrics
                    self.isWatchCounterpartReachable = true
                }
            },
            onCommand: { [weak self] command in
                await MainActor.run {
                    self?.handleIncomingWatchCommand(command)
                }
            },
            onStateSync: { [weak self] state in
                await MainActor.run {
                    guard let self else { return }
                    SharedWidgetStateStore.write(state)
                    if state.isBioEntrainmentActive && !self.isBioEntrainmentEnabled {
                        self.isBioEntrainmentEnabled = true
                    }
                }
            },
            onReachability: { [weak self] reachable in
                await MainActor.run {
                    self?.isWatchCounterpartReachable = reachable
                }
            }
        )
        await watchBridge.activateBridge()
        isWatchCounterpartReachable = await watchBridge.isCounterpartReachable
    }

    private func handleIncomingWatchCommand(_ command: WatchRemoteCommand) {
        switch command {
        case .startFocusSession:
            if !isTimerRunning { startFocusTimer() }
        case .pauseFocusSession:
            if isTimerRunning { pauseFocusTimer() }
        case .scrubBinauralFreq(let hz):
            var updated = synthParameters
            updated.binauralBeatHz = min(max(hz, 1.5), 42.0)
            pushSynthParameters(updated, clearingPresetSelection: false)
        case .logQuickHabitPulse(let habitID, let minutes):
            hapticDirector.playOrbitalSnap(mass: 1.4)
            Task {
                _ = try? await databaseActor.logQuickHabitIncrementHelper(habitID: habitID, minutes: minutes)
                await refreshSharedWidgetSnapshotFromDB()
            }
        case .triggerHarmonicBloom:
            triggerManualHarmonicBloom(intensity: 0.90)
        }
    }

    public func toggleBioEntrainmentClosedLoop(_ enabled: Bool) {
        isBioEntrainmentEnabled = enabled
        pidController.reset()
        previousEvaluatedMetrics = nil
        previousEvaluatedFeatures = nil
        previousPredictionOutput = nil
        hapticDirector.playSegmentSnap()

        if enabled && !isWatchCounterpartReachable && latestBiometricSnapshot == nil {
            isSimulateWristBiometricsEnabled = true
        }
        if enabled {
            lastBioEntrainmentTickDate = .distantPast
        }
        syncSystemSurfaces(liveActivityActive: isTimerRunning)
    }

    public func toggleSimulateWristBiometrics(_ enabled: Bool) {
        isSimulateWristBiometricsEnabled = enabled
        hapticDirector.playSegmentSnap()
        if enabled {
            let seeded = physiologySimulator.advance(
                dtSeconds: 12.0,
                activeBinauralBeatHz: synthParameters.binauralBeatHz
            )
            latestBiometricSnapshot = seeded.snapshot
            latestHRVMetrics = seeded.metrics
            lastBioEntrainmentTickDate = .distantPast
        }
    }

    private func tickClosedLoopBioEntrainment(dtSeconds: Double) async {
        if isSimulateWristBiometricsEnabled || (isBioEntrainmentEnabled && !isWatchCounterpartReachable) {
            let simStep = physiologySimulator.advance(
                dtSeconds: dtSeconds,
                activeBinauralBeatHz: synthParameters.binauralBeatHz
            )
            latestBiometricSnapshot = simStep.snapshot
            latestHRVMetrics = simStep.metrics
        }

        guard isBioEntrainmentEnabled, let metrics = latestHRVMetrics else { return }

        if let prevMetrics = previousEvaluatedMetrics,
           let prevFeatures = previousEvaluatedFeatures,
           let prevPred = previousPredictionOutput {
            let rmssdDelta = metrics.rmssdMs - prevMetrics.rmssdMs
            let cohDelta = metrics.rsaCoherenceScore - prevMetrics.rsaCoherenceScore
            if rmssdDelta > 0.0 || cohDelta > 0.0 {
                let report = await mlPredictor.updateWeightsWithObservedReward(
                    previousFeatures: prevFeatures,
                    predictedOutput: prevPred,
                    observedRMSSDDelta: rmssdDelta,
                    observedCoherenceDelta: cohDelta,
                    learningRate: 0.025
                )
                onlineAdaptationEpochs = report.updatedEpochCount
                lastOnlineHuberLoss = report.huberLoss
            }
        }

        let featureVec = BiometricFeatureVector(
            snapshot: latestBiometricSnapshot,
            metrics: metrics,
            currentBeatHz: Double(synthParameters.binauralBeatHz),
            sessionProgressRatio: focusProgress
        )

        let prediction: BrainwavePredictionOutput
        #if canImport(CoreML)
        if let interop = try? await mlPredictor.predictWithCoreMLInterop(features: featureVec) {
            prediction = interop.1
        } else {
            prediction = await mlPredictor.predict(features: featureVec)
        }
        #else
        prediction = await mlPredictor.predict(features: featureVec)
        #endif

        latestBioEntrainmentPrediction = prediction
        previousEvaluatedMetrics = metrics
        previousEvaluatedFeatures = featureVec
        previousPredictionOutput = prediction

        let slewed = pidController.stepAcousticTargets(
            currentBeatHz: synthParameters.binauralBeatHz,
            currentCarrierHz: synthParameters.carrierFrequencyHz,
            currentCutoffHz: synthParameters.filterCutoffHz,
            currentPinkNoiseMix: synthParameters.pinkNoiseMix,
            prediction: prediction,
            dtSeconds: dtSeconds
        )

        var updated = synthParameters
        updated.binauralBeatHz = slewed.beatHz
        updated.carrierFrequencyHz = slewed.carrierHz
        updated.filterCutoffHz = slewed.cutoffHz
        updated.pinkNoiseMix = slewed.pinkNoiseMix
        synthParameters = updated
        activePresetName = "Bio-Entrainment Loop"

        if isSynthPlaying || isTimerRunning {
            await audioEngine.updateParameters(updated)
        }
        syncSystemSurfaces(liveActivityActive: isTimerRunning)
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

        latestKalmanEstimate = kalmanFilter.update(
            measuredQuality: quality,
            sessionDurationSeconds: actual,
            aborted: !completedNaturally && ratio < 0.75
        )
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
        activeFocusCategory = preset.category
        var next = SynthParameters(preset: preset)
        next.spatialPanOffset = synthParameters.spatialPanOffset
        next.headElevationTilt = synthParameters.headElevationTilt
        next.hrtfAzimuthDeg = synthParameters.hrtfAzimuthDeg
        next.hrtfElevationDeg = synthParameters.hrtfElevationDeg
        next.hrtfDistanceMeters = synthParameters.hrtfDistanceMeters
        next.roomPresetIndex = synthParameters.roomPresetIndex
        next.isHRTFSpatializerEnabled = synthParameters.isHRTFSpatializerEnabled
        next.headQuaternion = synthParameters.headQuaternion
        next.orbitalSatellites = synthParameters.orbitalSatellites
        next.neuralSoundscapeMix = synthParameters.neuralSoundscapeMix
        next.latentGuidanceScale = synthParameters.latentGuidanceScale
        next.latentTemperature = synthParameters.latentTemperature
        next.rayTracedAcousticsEnabled = synthParameters.rayTracedAcousticsEnabled
        synthParameters = next
        hapticDirector.playSegmentSnap()
        Task {
            await audioEngine.applyPreset(preset)
            if isSynthPlaying {
                await audioEngine.triggerHarmonicBloom(intensity: 0.55)
            }
            await pumpNeuralSoundscapeRingBufferIfNeeded(forceInitialBlock: true)
        }
        syncSystemSurfaces(liveActivityActive: isTimerRunning || elapsedSeconds > 0)
    }

    // MARK: - Phase 7: GPU Metal Ray-Traced 3D Acoustics & Neural Latent Diffusion Controls

    public func refreshRayTracedAcoustics() async {
        let chamber = selectedChamberPreset
        let surfaceMat = selectedSurfaceMaterialPreset.material
        let habits = cachedOrbitHabits
        let orbitPhase = Float(orbitalRotationAngle)
        let azRad = synthParameters.hrtfAzimuthDeg * Float.pi / 180.0
        let elRad = synthParameters.hrtfElevationDeg * Float.pi / 180.0
        let dist = max(0.35, min(synthParameters.hrtfDistanceMeters, 2.6))
        let srcPos = SIMD3<Float>(
            dist * cosf(elRad) * sinf(azRad),
            0.25 + dist * sinf(elRad) * 0.45,
            dist * cosf(elRad) * cosf(azRad)
        )
        let headPose = ListenerHeadPose3D(
            position: SIMD3<Float>(0.0, 0.0, -1.10),
            orientation: simd_quatf(vector: synthParameters.headQuaternion)
        )

        let report = await acousticRayTracer.solveChamberAcoustics(
            chamber: chamber,
            surfaceMaterial: surfaceMat,
            habits: habits,
            orbitalPhaseRadians: orbitPhase,
            sourcePosition: srcPos,
            listenerPose: headPose,
            rayCount: 1_024,
            maxBounces: 16,
            sampleRate: 48_000.0,
            convolverBridge: audioEngine.drirConvolverBridge
        )
        latestAcousticReport = report
    }

    public func selectAcousticChamber(_ chamber: AcousticChamberPreset) {
        selectedChamberPreset = chamber
        hapticDirector.playSegmentSnap()
        acousticSolveTask?.cancel()
        acousticSolveTask = Task { [weak self] in
            await self?.refreshRayTracedAcoustics()
        }
    }

    public func selectAcousticSurfaceMaterial(_ materialPreset: AcousticSurfaceMaterialPreset) {
        selectedSurfaceMaterialPreset = materialPreset
        hapticDirector.playSegmentSnap()
        acousticSolveTask?.cancel()
        acousticSolveTask = Task { [weak self] in
            await self?.refreshRayTracedAcoustics()
        }
    }

    public func toggleRayTracedAcoustics(_ enabled: Bool) {
        var next = synthParameters
        next.rayTracedAcousticsEnabled = enabled
        pushSynthParameters(next, clearingPresetSelection: false)
        hapticDirector.playSegmentSnap()
        if enabled {
            acousticSolveTask?.cancel()
            acousticSolveTask = Task { [weak self] in
                await self?.refreshRayTracedAcoustics()
            }
        }
    }

    public func reseedNeuralSoundscape() {
        hapticDirector.playOrbitalSnap(mass: 1.35)
        Task { [weak self] in
            guard let self else { return }
            await self.neuralSoundscapeEngine.reseedLatentManifold()
            await self.pumpNeuralSoundscapeRingBufferIfNeeded(forceInitialBlock: true)
        }
    }

    private func pumpNeuralSoundscapeRingBufferIfNeeded(forceInitialBlock: Bool) async {
        guard !isNeuralBlockGenerating else { return }
        isNeuralBlockGenerating = true
        defer { isNeuralBlockGenerating = false }

        let metrics = latestHRVMetrics ?? .baselinePlaceholder
        let rmssdNorm = Float(min(max(metrics.rmssdMs / 120.0, 0.0), 1.0))
        let rsaCoh = Float(min(max(metrics.rsaCoherenceScore, 0.0), 1.0))
        let lfHfNorm = Float(min(max(metrics.lfHfRatio / 6.0, 0.0), 1.0))
        let category = activeFocusCategory
        let beatHz = synthParameters.binauralBeatHz
        let cfgScale = synthParameters.latentGuidanceScale
        let temp = synthParameters.latentTemperature
        let ring = audioEngine.neuralRingBuffer

        let blocksToGenerate = forceInitialBlock ? 2 : 1
        var latestSnap = latestNeuralSoundscapeTelemetry
        for _ in 0..<blocksToGenerate {
            latestSnap = await neuralSoundscapeEngine.synthesizeAndEnqueueBlock(
                ringBuffer: ring,
                category: category,
                binauralBeatHz: beatHz,
                rmssdNormalized: rmssdNorm,
                rsaCoherenceScore: rsaCoh,
                lfHfRatioNormalized: lfHfNorm,
                guidanceScale: cfgScale,
                temperature: temp,
                sampleRate: 48_000.0
            )
        }
        latestNeuralSoundscapeTelemetry = latestSnap
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

    // MARK: - Distributed Multi-Peer Spatial Orchestra & Wave-Field Array Controls

    public func toggleOrchestraMeshSync(_ enabled: Bool) {
        orchestraEngine.setMeshSyncEnabled(enabled)
        lastOrchestraTickDate = .now
        if enabled {
            let result = orchestraEngine.tickMeshSynchronization(
                dtSeconds: 0.10,
                sampleRate: 48_000.0,
                tempoBPM: 120.0,
                binauralBeatHz: Double(synthParameters.binauralBeatHz)
            )
            orchestraSnapshot = result.snapshot
            Task { await audioEngine.updateOrchestraSync(result.dspControl) }
        } else {
            orchestraSnapshot = orchestraEngine.snapshot()
            Task { await audioEngine.updateOrchestraSync(RealtimeOrchestraSyncControl(isEnabled: false)) }
        }
        hapticDirector.playSegmentSnap()
    }

    public func toggleSimulateQuadArray(_ enabled: Bool) {
        orchestraEngine.setSimulateQuadArray(enabled)
        lastOrchestraTickDate = .now
        let result = orchestraEngine.tickMeshSynchronization(
            dtSeconds: 0.10,
            sampleRate: 48_000.0,
            tempoBPM: 120.0,
            binauralBeatHz: Double(synthParameters.binauralBeatHz)
        )
        orchestraSnapshot = result.snapshot
        Task { await audioEngine.updateOrchestraSync(result.dspControl) }
        hapticDirector.playSegmentSnap()
    }

    public func selectOrchestraLocalNode(_ nodeID: Int) {
        orchestraEngine.setActiveLocalNode(nodeID: nodeID)
        let result = orchestraEngine.tickMeshSynchronization(
            dtSeconds: 0.05,
            sampleRate: 48_000.0,
            tempoBPM: 120.0,
            binauralBeatHz: Double(synthParameters.binauralBeatHz)
        )
        orchestraSnapshot = result.snapshot
        Task { await audioEngine.updateOrchestraSync(result.dspControl) }
        hapticDirector.playParameterDetentTick(intensity: 0.65)
    }

    public func moveOrchestraSpeakerNode(nodeID: Int, xMeters: Double, zMeters: Double) {
        orchestraEngine.updateNodePosition(nodeID: nodeID, xMeters: xMeters, zMeters: zMeters)
        orchestraSnapshot = orchestraEngine.snapshot()
        if orchestraSnapshot.isMeshSyncEnabled {
            let localSol = orchestraSnapshot.nodeSolutions.first(where: { $0.nodeID == orchestraSnapshot.activeLocalNodeID })
            let control = RealtimeOrchestraSyncControl(
                isEnabled: true,
                pllSampleRateScale: orchestraSnapshot.pllSampleRateScale,
                wfsDelaySamples: orchestraSnapshot.isSimulatingQuadArray ? (localSol?.delayInSamples(sampleRate: 48_000.0) ?? 0.0) : 0.0,
                wfsGainScale: orchestraSnapshot.isSimulatingQuadArray ? (localSol?.wfsDrivingAmplitude ?? 1.0) : 1.0,
                masterPhaseSyncTarget: nil
            )
            Task { await audioEngine.updateOrchestraSync(control) }
        }
    }

    public func moveOrchestraVirtualSource(xMeters: Double, zMeters: Double) {
        orchestraEngine.updateVirtualSourcePosition(xMeters: xMeters, zMeters: zMeters)
        orchestraSnapshot = orchestraEngine.snapshot()
        if orchestraSnapshot.isMeshSyncEnabled {
            let localSol = orchestraSnapshot.nodeSolutions.first(where: { $0.nodeID == orchestraSnapshot.activeLocalNodeID })
            let control = RealtimeOrchestraSyncControl(
                isEnabled: true,
                pllSampleRateScale: orchestraSnapshot.pllSampleRateScale,
                wfsDelaySamples: orchestraSnapshot.isSimulatingQuadArray ? (localSol?.delayInSamples(sampleRate: 48_000.0) ?? 0.0) : 0.0,
                wfsGainScale: orchestraSnapshot.isSimulatingQuadArray ? (localSol?.wfsDrivingAmplitude ?? 1.0) : 1.0,
                masterPhaseSyncTarget: nil
            )
            Task { await audioEngine.updateOrchestraSync(control) }
        }
    }

    // MARK: - Phase 9: 2D/3D FDTD Waveguide Tank & Closed-Loop Cortical EEG BCI Controls

    public func toggleCorticalIAFLock(_ enabled: Bool) {
        isCorticalIAFLockEnabled = enabled
        isClosedLoopIAFLockEnabled = enabled
        hapticDirector.playSegmentSnap()
        if enabled {
            let iaf = eegBCI.latestMetrics.individualAlphaFrequencyHz
            let targetBeat = useGoldenRatioIAFSubharmonic ? (iaf / 1.6180339887) : iaf
            synthParameters.binauralBeatHz = min(max(targetBeat, 0.5), 40.0)
            let pacMI = eegBCI.latestMetrics.thetaGammaPACModulationIndex
            synthParameters.fdtdStiffness = min(max(0.14 + pacMI * 2.4, 0.05), 0.92)
            Task { await audioEngine.updateParameters(synthParameters) }
            presentTransientBanner(String(
                format: "Cortical IAF Lock active · Target %.2f Hz · PAC MI %.3f",
                synthParameters.binauralBeatHz,
                pacMI
            ))
        } else {
            presentTransientBanner("Cortical IAF Lock disengaged")
        }
    }

    public func toggleGoldenRatioIAFSubharmonic(_ enabled: Bool) {
        useGoldenRatioIAFSubharmonic = enabled
        hapticDirector.playParameterDetentTick(intensity: 0.45)
        if isCorticalIAFLockEnabled {
            let iaf = eegBCI.latestMetrics.individualAlphaFrequencyHz
            let targetBeat = enabled ? (iaf / 1.6180339887) : iaf
            synthParameters.binauralBeatHz = min(max(targetBeat, 0.5), 40.0)
            Task { await audioEngine.updateParameters(synthParameters) }
        }
    }

    public func updateFDTDMicrophoneProbes(leftXY: SIMD2<Float>, rightXY: SIMD2<Float>) {
        let clampedLeft = SIMD2<Float>(min(max(leftXY.x, 0.08), 0.92), min(max(leftXY.y, 0.08), 0.92))
        let clampedRight = SIMD2<Float>(min(max(rightXY.x, 0.08), 0.92), min(max(rightXY.y, 0.08), 0.92))
        synthParameters.fdtdMicLeftXY = clampedLeft
        synthParameters.fdtdMicRightXY = clampedRight
        waveTankController.micLeftNormalized = clampedLeft
        waveTankController.micRightNormalized = clampedRight
        Task { await audioEngine.updateParameters(synthParameters) }
    }

    public func triggerFDTDWaveTankShockwave(normalizedX: Float, normalizedY: Float, amplitude: Float = 1.25) {
        waveTankController.triggerTouchPulse(normalizedX: normalizedX, normalizedY: normalizedY, amplitude: amplitude)
        Task { await audioEngine.triggerHarmonicBloom(intensity: min(max(amplitude * 0.75, 0.2), 1.0)) }
        hapticDirector.playParameterDetentTick(intensity: 0.62)
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

    // MARK: - Phase 3 & Phases 9–10 Actions (WAV Stem Export, Kalman, P2P Mesh, EEG/TFR, MPS/DMRG & Capstone Audit)

    public func prepareWAVStemExport() async {
        do {
            let req = StemRenderRequest(
                title: activePresetName,
                parameters: synthParameters,
                category: activeFocusCategory,
                durationSeconds: 12.0,
                crossfadeSeconds: 1.5,
                sampleRate: 48_000,
                bitDepth: selectedWAVBitDepth,
                applyEntrainmentEnvelope: isEntrainmentCurveEnabled
            )
            exportWAVDocument = try await stemExporter.renderStemDocument(request: req)
            isExportingWAV = true
            hapticDirector.playOrbitalSnap(mass: 1.45)
        } catch {
            presentTransientBanner("WAV stem export failed: \(error.localizedDescription)")
        }
    }

    public func assimilateKalmanHistoryFromDB() async {
        let sessions = (try? await databaseActor.fetchAllSessions()) ?? []
        let telemetry = (try? await databaseActor.fetchAllTelemetry()) ?? []
        latestKalmanEstimate = kalmanFilter.assimilateHistory(sessions: sessions, telemetry: telemetry)
    }

    public func toggleBonjourMesh(_ active: Bool) async {
        if active {
            await meshSyncActor.startBonjourMesh()
        } else {
            await meshSyncActor.stopBonjourMesh()
        }
        await refreshMeshStatus()
        hapticDirector.playSegmentSnap()
    }

    public func refreshMeshStatus() async {
        let status = await meshSyncActor.snapshotMeshStatus()
        isMeshBonjourActive = status.isListening
        meshLamportClock = status.lamportClock
        meshPeers = status.peers
    }

    public func triggerMeshBroadcastSync() async {
        let sentCount = await meshSyncActor.broadcastEncryptedArchiveToAllPeers()
        await refreshMeshStatus()
        hapticDirector.playOrbitalSnap(mass: 1.4)
        presentTransientBanner("Broadcasted E2EE archive to \(sentCount) peer(s) · Lamport #\(meshLamportClock)")
    }

    public func triggerManualEEGBlink() {
        eegGenerator.triggerManualOcularBlink(amplitudeUV: 175.0)
        eegBCI.injectManualOcularBlink()
        Task { await refreshCorticalEEGAndTFR() }
    }

    public func refreshCorticalEEGAndTFR() async {
        var cleanedAF7: [Float] = []
        var cleanedAF8: [Float] = []
        cleanedAF7.reserveCapacity(128)
        cleanedAF8.reserveCapacity(128)
        eegGenerator.entrain(toBinauralBeatHz: synthParameters.binauralBeatHz, dtSeconds: 0.5)
        for i in 0..<128 {
            let raw = eegGenerator.nextSample(injectBlinkAmplitude: i == 32 ? 120.0 : 0.0)
            let filtered = eegFilterBank.processQuadSample(raw)
            cleanedAF7.append(filtered.cleaned.af7)
            cleanedAF8.append(filtered.cleaned.af8)
        }
        let metrics = CorticalSpectralAnalyzer.analyze(
            channelSamples: cleanedAF7,
            frontalLeft: cleanedAF7,
            frontalRight: cleanedAF8,
            sampleRate: 256.0
        )
        latestEEGMetrics = metrics
        if isClosedLoopIAFLockEnabled {
            var updated = synthParameters
            updated.binauralBeatHz = metrics.individualAlphaFrequencyHz
            pushSynthParameters(updated, clearingPresetSelection: false)
        }
        let subWindow = Array(cleanedAF7.suffix(64))
        latestSPWVDResult = SPWVDAnalyzer.analyze(signal: subWindow, sampleRate: 256.0, freqBins: 32)
        latestHHTResult = HilbertHuangSifter.sift(signal: subWindow, sampleRate: 256.0, maxIMFs: 4)
    }

    public func refreshQuantumMPSAndDMRG(bondDim: Int? = nil) async {
        if let bondDim {
            selectedMPSBondDimension = min(max(bondDim, 2), 16)
        }
        let bell = MatrixProductStateEngine.makeMaximallyEntangledBellState(schmidtRank: 8)
        let sweeps = DMRGVariationalOptimizer.runSweeps(
            initialState: bell,
            sweeps: 4,
            maxBondDim: selectedMPSBondDimension
        )
        dmrgSweepSnapshots = sweeps
        latestMPSTelemetry = sweeps.last
        let mpsEngine = MatrixProductStateEngine(stateVector: bell, maxBondDim: selectedMPSBondDimension)
        latestOptimalBioAcousticControl = DMRGVariationalOptimizer.extractOptimalBioAcousticControl(from: mpsEngine)
        if let last = sweeps.last {
            var updated = synthParameters
            updated.padDetuneCents = last.mappedHarmonicTension * 24.0
            updated.fmHarmonicRatio = last.mappedSpectralInharmonicity
            synthParameters = updated
            if isSynthPlaying || isTimerRunning {
                await audioEngine.updateParameters(updated)
            }
        }
    }

    public func runFullCapstoneAudit() async {
        guard !isRunningCapstoneAudit else { return }
        isRunningCapstoneAudit = true
        hapticDirector.playTimerIgnition(starting: true)
        do {
            let report = try await AetherCapstoneBenchmarkSuite.runFullAudit()
            latestCapstoneReport = report
            exportCapstoneMarkdownDocument = CapstoneReportMarkdownDocument(report: report)
            exportCapstoneJSONDocument = CapstoneReportJSONDocument(report: report)
            hapticDirector.playSessionCompletionSymphony()
            presentTransientBanner(
                "12-Stage Capstone Audit Passed · SHA-256 \(report.reportSHA256Hex.prefix(12))…"
            )
        } catch {
            presentTransientBanner("Capstone audit error: \(error.localizedDescription)")
        }
        isRunningCapstoneAudit = false
    }

    public func prepareCapstoneMarkdownExport() async {
        if latestCapstoneReport == nil {
            await runFullCapstoneAudit()
        }
        guard let report = latestCapstoneReport else { return }
        exportCapstoneMarkdownDocument = CapstoneReportMarkdownDocument(report: report)
        isExportingCapstoneMarkdown = true
    }

    public func prepareCapstoneJSONExport() async {
        if latestCapstoneReport == nil {
            await runFullCapstoneAudit()
        }
        guard let report = latestCapstoneReport else { return }
        exportCapstoneJSONDocument = CapstoneReportJSONDocument(report: report)
        isExportingCapstoneJSON = true
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
        if let metrics = latestHRVMetrics {
            widgetSnap.latestAutonomicCoherence = metrics.rsaCoherenceScore
            widgetSnap.latestHeartRateBPM = latestBiometricSnapshot?.heartRateBPM ?? metrics.heartRateBPM
            widgetSnap.latestRMSSDMs = metrics.rmssdMs
        }
        widgetSnap.isBioEntrainmentActive = isBioEntrainmentEnabled
        widgetSnap.updatedAt = .now
        SharedWidgetStateStore.write(widgetSnap)
        IntentNotificationBridge.reloadSystemWidgetsAndControls()
        let syncCopy = widgetSnap
        Task {
            _ = try? await watchBridge.sendStateSnapshotSync(syncCopy)
        }
    }

    public func refreshSharedWidgetSnapshotFromDB() async {
        let habits = (try? await databaseActor.fetchActiveHabits()) ?? []
        cachedOrbitHabits = habits
        synthParameters.orbitalSatellites = OrbitalSatelliteBank.build(
            from: habits,
            rotationRadians: orbitalRotationAngle,
            orbitalSpeedRadPerSec: hrtfOrbitalSpeedRadPerSec
        )
        await audioEngine.updateOrbitalSatellites(synthParameters.orbitalSatellites)

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
            latestAutonomicCoherence: latestHRVMetrics?.rsaCoherenceScore ?? 0.78,
            latestHeartRateBPM: latestBiometricSnapshot?.heartRateBPM ?? latestHRVMetrics?.heartRateBPM ?? 64.0,
            latestRMSSDMs: latestHRVMetrics?.rmssdMs ?? 52.0,
            isBioEntrainmentActive: isBioEntrainmentEnabled,
            updatedAt: .now
        )
        SharedWidgetStateStore.write(snap)
        IntentNotificationBridge.reloadSystemWidgetsAndControls()
    }
}

private extension TelemetryDatabaseActor {
    func logQuickHabitIncrementHelper(habitID: UUID, minutes: Int) throws -> HabitNodeDTO? {
        try logQuickHabitPulse(habitID: habitID, addedMinutes: minutes)
    }
}
