// MARK: - FILE: BimanualHandTrackingActor.swift

import Foundation
import Observation
import simd
import os
#if os(visionOS)
import ARKit
import QuartzCore
#endif

// MARK: - Lock-Free Shared Spatial & 64-Bin FFT Telemetry Bridge for 90Hz Compositor Thread

public struct VisionCompositorTelemetrySnapshot: Sendable {
    public let sample: BimanualHandPoseSample
    public let modulation: SpatialPoseModulationOutput
    public let carrierHz: Float
    public let audioRMS: Float
    public let subBandEnergy: Float
    public let lowBandEnergy: Float
    public let highBandEnergy: Float
    public let fftBinsPacked16: [SIMD4<Float>]
    public let isSimulated: Bool
}

public final class VisionSpatialSharedState: @unchecked Sendable {
    private let lock: UnsafeMutablePointer<os_unfair_lock_s>
    private var latestSampleStorage: BimanualHandPoseSample
    private var latestModulationStorage: SpatialPoseModulationOutput
    private var carrierFrequencyHzStorage: Float = 216.0
    private var audioRMSAmplitudeStorage: Float = 0.0
    private var subBandEnergyStorage: Float = 0.0
    private var lowBandEnergyStorage: Float = 0.0
    private var highBandEnergyStorage: Float = 0.0
    private var fftBinsPacked16Storage: [SIMD4<Float>] = [SIMD4<Float>](repeating: .zero, count: 16)
    private var isUsingSimulatorStorage: Bool = false

    public init() {
        self.lock = UnsafeMutablePointer<os_unfair_lock_s>.allocate(capacity: 1)
        self.lock.initialize(to: os_unfair_lock_s())

        let initialSample = BimanualHandPoseSample(
            leftThumbTip: SIMD3<Float>(-0.22, 1.22, -0.42),
            leftIndexTip: SIMD3<Float>(-0.22, 1.28, -0.43),
            leftMiddleTip: SIMD3<Float>(-0.24, 1.29, -0.43),
            leftWrist: SIMD3<Float>(-0.20, 1.15, -0.34),
            leftForearmArm: SIMD3<Float>(-0.20, 1.10, -0.20),
            leftPalm: SIMD3<Float>(-0.20, 1.20, -0.40),
            rightThumbTip: SIMD3<Float>(0.22, 1.22, -0.42),
            rightIndexTip: SIMD3<Float>(0.22, 1.28, -0.43),
            rightMiddleTip: SIMD3<Float>(0.24, 1.29, -0.43),
            rightWrist: SIMD3<Float>(0.20, 1.15, -0.34),
            rightForearmArm: SIMD3<Float>(0.20, 1.10, -0.20),
            rightPalm: SIMD3<Float>(0.20, 1.20, -0.40),
            rightWristOrientation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
            timestamp: 0.0
        )
        var initialTelemeter = SpatialPoseTelemeter()
        let initialModulation = initialTelemeter.evaluate(pose: initialSample)

        self.latestSampleStorage = initialSample
        self.latestModulationStorage = initialModulation
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    public func publishHandTelemetry(
        sample: BimanualHandPoseSample,
        modulation: SpatialPoseModulationOutput,
        isSimulated: Bool
    ) {
        os_unfair_lock_lock(lock)
        latestSampleStorage = sample
        latestModulationStorage = modulation
        isUsingSimulatorStorage = isSimulated
        os_unfair_lock_unlock(lock)
    }

    public func publishAudioSpectrum(
        carrierHz: Float,
        rmsAmplitude: Float,
        subBandEnergy: Float,
        lowBandEnergy: Float,
        highBandEnergy: Float,
        spectrumBars: [Float]
    ) {
        var packed = [SIMD4<Float>](repeating: .zero, count: 16)
        for group in 0..<16 {
            let base = group * 4
            let b0 = base < spectrumBars.count ? spectrumBars[base] : 0.0
            let b1 = (base + 1) < spectrumBars.count ? spectrumBars[base + 1] : 0.0
            let b2 = (base + 2) < spectrumBars.count ? spectrumBars[base + 2] : 0.0
            let b3 = (base + 3) < spectrumBars.count ? spectrumBars[base + 3] : 0.0
            packed[group] = SIMD4<Float>(b0, b1, b2, b3)
        }

        os_unfair_lock_lock(lock)
        carrierFrequencyHzStorage = carrierHz
        audioRMSAmplitudeStorage = rmsAmplitude
        subBandEnergyStorage = subBandEnergy
        lowBandEnergyStorage = lowBandEnergy
        highBandEnergyStorage = highBandEnergy
        fftBinsPacked16Storage = packed
        os_unfair_lock_unlock(lock)
    }

    public func publishHeadTransform(_ headTransform: simd_float4x4) {
        os_unfair_lock_lock(lock)
        let s = latestSampleStorage
        latestSampleStorage = BimanualHandPoseSample(
            headTransform: headTransform,
            leftThumbTip: s.leftThumbTip,
            leftIndexTip: s.leftIndexTip,
            leftMiddleTip: s.leftMiddleTip,
            leftWrist: s.leftWrist,
            leftForearmArm: s.leftForearmArm,
            leftPalm: s.leftPalm,
            rightThumbTip: s.rightThumbTip,
            rightIndexTip: s.rightIndexTip,
            rightMiddleTip: s.rightMiddleTip,
            rightWrist: s.rightWrist,
            rightForearmArm: s.rightForearmArm,
            rightPalm: s.rightPalm,
            rightWristOrientation: s.rightWristOrientation,
            timestamp: s.timestamp
        )
        os_unfair_lock_unlock(lock)
    }

    public func snapshot() -> VisionCompositorTelemetrySnapshot {
        os_unfair_lock_lock(lock)
        let snap = VisionCompositorTelemetrySnapshot(
            sample: latestSampleStorage,
            modulation: latestModulationStorage,
            carrierHz: carrierFrequencyHzStorage,
            audioRMS: audioRMSAmplitudeStorage,
            subBandEnergy: subBandEnergyStorage,
            lowBandEnergy: lowBandEnergyStorage,
            highBandEnergy: highBandEnergyStorage,
            fftBinsPacked16: fftBinsPacked16Storage,
            isSimulated: isUsingSimulatorStorage
        )
        os_unfair_lock_unlock(lock)
        return snap
    }
}

#if os(visionOS)

// MARK: - Single-Chirality Skeletal Joint Snapshot

private struct ChiralitySkeletalJoints: Sendable {
    var thumbTip: SIMD3<Float>
    var indexFingerTip: SIMD3<Float>
    var middleFingerTip: SIMD3<Float>
    var wrist: SIMD3<Float>
    var forearmArm: SIMD3<Float>
    var palmPosition: SIMD3<Float>
    var wristOrientation: simd_quatf
    var lastUpdatedTimestamp: TimeInterval
}

// MARK: - 90Hz @Observable @MainActor ARKit HandTrackingProvider + Lissajous Simulator Controller

@Observable
@MainActor
public final class BimanualHandTrackingActor {
    public private(set) var isTrackingActive: Bool = false
    public private(set) var isUsingSimulatorMode: Bool = false
    public var isDSPModulationCoupled: Bool = true

    public private(set) var latestSample: BimanualHandPoseSample
    public private(set) var latestModulation: SpatialPoseModulationOutput
    public private(set) var trackingStatusDescription: String = "Idle"

    public let sharedState: VisionSpatialSharedState

    private let arSession = ARKitSession()
    private var handTrackingProvider: HandTrackingProvider?
    private var telemeter = SpatialPoseTelemeter()

    private var anchorStreamingTask: Task<Void, Never>?
    private var simulatorLoopTask: Task<Void, Never>?
    private var spectrumSyncTask: Task<Void, Never>?
    private weak var boundCoordinator: AetherAppCoordinator?

    private var leftHandJoints = ChiralitySkeletalJoints(
        thumbTip: SIMD3<Float>(-0.23, 1.23, -0.43),
        indexFingerTip: SIMD3<Float>(-0.23, 1.29, -0.44),
        middleFingerTip: SIMD3<Float>(-0.25, 1.30, -0.44),
        wrist: SIMD3<Float>(-0.21, 1.16, -0.35),
        forearmArm: SIMD3<Float>(-0.21, 1.10, -0.20),
        palmPosition: SIMD3<Float>(-0.21, 1.20, -0.40),
        wristOrientation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
        lastUpdatedTimestamp: 0.0
    )

    private var rightHandJoints = ChiralitySkeletalJoints(
        thumbTip: SIMD3<Float>(0.23, 1.23, -0.43),
        indexFingerTip: SIMD3<Float>(0.23, 1.29, -0.44),
        middleFingerTip: SIMD3<Float>(0.25, 1.30, -0.44),
        wrist: SIMD3<Float>(0.21, 1.16, -0.35),
        forearmArm: SIMD3<Float>(0.21, 1.10, -0.20),
        palmPosition: SIMD3<Float>(0.21, 1.20, -0.40),
        wristOrientation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
        lastUpdatedTimestamp: 0.0
    )

    public init(sharedState: VisionSpatialSharedState = VisionSpatialSharedState()) {
        self.sharedState = sharedState
        let initial = sharedState.snapshot()
        self.latestSample = initial.sample
        self.latestModulation = initial.modulation
    }

    public func startTracking(
        coordinator: AetherAppCoordinator,
        forceSimulator: Bool = false
    ) async {
        self.boundCoordinator = coordinator
        stopTracking()
        isTrackingActive = true
        startAudioSpectrumBridgeLoop()

        if forceSimulator || !HandTrackingProvider.isSupported {
            engageLissajousSimulator(reason: forceSimulator ? "Lissajous Bimanual Simulator (Manual)" : "Lissajous 90Hz Simulator (No Camera Hardware)")
            return
        }

        let authorizations = await arSession.requestAuthorization(for: [.handTracking])
        guard authorizations[.handTracking] == .allowed else {
            engageLissajousSimulator(reason: "Lissajous 90Hz Simulator (Permission Fallback)")
            return
        }

        let provider = HandTrackingProvider()
        self.handTrackingProvider = provider

        do {
            try await arSession.run([provider])
            isUsingSimulatorMode = false
            trackingStatusDescription = "90Hz ARKit HandTrackingProvider Active"
            startHardwareAnchorStream(provider: provider)
        } catch {
            engageLissajousSimulator(reason: "Lissajous 90Hz Simulator (ARKit Fallback)")
        }
    }

    public func toggleSimulatorMode() {
        guard let coordinator = boundCoordinator else { return }
        let targetSim = !isUsingSimulatorMode
        Task {
            await startTracking(coordinator: coordinator, forceSimulator: targetSim)
        }
    }

    public func stopTracking() {
        isTrackingActive = false
        anchorStreamingTask?.cancel()
        anchorStreamingTask = nil
        simulatorLoopTask?.cancel()
        simulatorLoopTask = nil
        spectrumSyncTask?.cancel()
        spectrumSyncTask = nil
        arSession.stop()
        handTrackingProvider = nil
        trackingStatusDescription = "Stopped"
    }

    // MARK: - 90Hz Hardware HandTrackingProvider.anchorUpdates Processing

    private func startHardwareAnchorStream(provider: HandTrackingProvider) {
        anchorStreamingTask?.cancel()
        anchorStreamingTask = Task { [weak self] in
            for await update in provider.anchorUpdates {
                if Task.isCancelled { break }
                guard let self else { break }
                self.consumeHandAnchor(update.anchor)
            }
        }
    }

    private func consumeHandAnchor(_ anchor: HandAnchor) {
        guard isTrackingActive, anchor.isTracked, let skeleton = anchor.handSkeleton else {
            return
        }

        let thumbJoint = skeleton.joint(.thumbTip)
        let indexJoint = skeleton.joint(.indexFingerTip)
        let middleTipJoint = skeleton.joint(.middleFingerTip)
        let wristJoint = skeleton.joint(.wrist)
        let forearmArmJoint = skeleton.joint(.forearmArm)

        guard thumbJoint.isTracked, indexJoint.isTracked else {
            return
        }

        let originFromAnchor = anchor.originFromAnchorTransform
        let thumbWorld = simd_mul(originFromAnchor, thumbJoint.anchorFromJointTransform)
        let indexWorld = simd_mul(originFromAnchor, indexJoint.anchorFromJointTransform)
        let middleTipWorld = simd_mul(originFromAnchor, middleTipJoint.anchorFromJointTransform)
        let wristWorld = simd_mul(originFromAnchor, wristJoint.anchorFromJointTransform)
        let forearmArmWorld = simd_mul(originFromAnchor, forearmArmJoint.anchorFromJointTransform)

        let thumbPos = Self.extractPosition(from: thumbWorld)
        let indexPos = Self.extractPosition(from: indexWorld)
        let middlePos = Self.extractPosition(from: middleTipWorld)
        let wristPos = Self.extractPosition(from: wristWorld)
        let forearmPos = forearmArmJoint.isTracked
            ? Self.extractPosition(from: forearmArmWorld)
            : (wristPos + SIMD3<Float>(0.0, -0.05, 0.14))

        // Estimate anatomical palm center along wrist -> middleFingerTip vector
        let palmPos = wristPos + 0.46 * (middlePos - wristPos)
        let wristQuat = Self.extractNormalizedQuaternion(from: wristWorld)
        let nowTimestamp = CACurrentMediaTime()

        let updatedJoints = ChiralitySkeletalJoints(
            thumbTip: thumbPos,
            indexFingerTip: indexPos,
            middleFingerTip: middlePos,
            wrist: wristPos,
            forearmArm: forearmPos,
            palmPosition: palmPos,
            wristOrientation: wristQuat,
            lastUpdatedTimestamp: nowTimestamp
        )

        switch anchor.chirality {
        case .left:
            leftHandJoints = updatedJoints
        case .right:
            rightHandJoints = updatedJoints
        @unknown default:
            return
        }

        let currentHeadTransform = sharedState.snapshot().sample.headTransform
        let poseSample = BimanualHandPoseSample(
            headTransform: currentHeadTransform,
            leftThumbTip: leftHandJoints.thumbTip,
            leftIndexTip: leftHandJoints.indexFingerTip,
            leftMiddleTip: leftHandJoints.middleFingerTip,
            leftWrist: leftHandJoints.wrist,
            leftForearmArm: leftHandJoints.forearmArm,
            leftPalm: leftHandJoints.palmPosition,
            rightThumbTip: rightHandJoints.thumbTip,
            rightIndexTip: rightHandJoints.indexFingerTip,
            rightMiddleTip: rightHandJoints.middleFingerTip,
            rightWrist: rightHandJoints.wrist,
            rightForearmArm: rightHandJoints.forearmArm,
            rightPalm: rightHandJoints.palmPosition,
            rightWristOrientation: rightHandJoints.wristOrientation,
            timestamp: nowTimestamp
        )

        publishEvaluatedPose(poseSample, isSimulated: false)
    }

    // MARK: - Deterministic 90Hz Lissajous Bimanual Gesture Simulator

    private func engageLissajousSimulator(reason: String) {
        isUsingSimulatorMode = true
        trackingStatusDescription = reason
        simulatorLoopTask?.cancel()

        simulatorLoopTask = Task { [weak self] in
            let startMediaTime = CACurrentMediaTime()
            while !Task.isCancelled {
                guard let self, self.isTrackingActive else { break }
                let now = CACurrentMediaTime()
                let elapsed = now - startMediaTime
                let headTransform = self.sharedState.snapshot().sample.headTransform
                let sample = Self.synthesizeLissajousBimanualSample(
                    elapsedSeconds: elapsed,
                    timestamp: now,
                    headTransform: headTransform
                )
                self.publishEvaluatedPose(sample, isSimulated: true)
                try? await Task.sleep(for: .nanoseconds(11_111_111)) // 90Hz cadence
            }
        }
    }

    private func publishEvaluatedPose(_ sample: BimanualHandPoseSample, isSimulated: Bool) {
        let modulation = telemeter.evaluate(pose: sample)
        self.latestSample = sample
        self.latestModulation = modulation

        sharedState.publishHandTelemetry(
            sample: sample,
            modulation: modulation,
            isSimulated: isSimulated
        )

        boundCoordinator?.applySpatialPoseModulation(
            modulation,
            coupleToDSP: isDSPModulationCoupled,
            isSimulated: isSimulated
        )
    }

    private func startAudioSpectrumBridgeLoop() {
        spectrumSyncTask?.cancel()
        spectrumSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                guard let self, let coordinator = self.boundCoordinator else { continue }
                self.sharedState.publishAudioSpectrum(
                    carrierHz: coordinator.synthParameters.carrierFrequencyHz,
                    rmsAmplitude: coordinator.liveAudioAmplitude,
                    subBandEnergy: coordinator.liveSubBandEnergy,
                    lowBandEnergy: coordinator.liveLowBandEnergy,
                    highBandEnergy: coordinator.liveHighBandEnergy,
                    spectrumBars: coordinator.spectrumBars
                )
            }
        }
    }

    // MARK: - Pure SIMD Lissajous Kinematics & Matrix Extraction

    nonisolated public static func synthesizeLissajousBimanualSample(
        elapsedSeconds: Double,
        timestamp: TimeInterval,
        headTransform: simd_float4x4 = matrix_identity_float4x4
    ) -> BimanualHandPoseSample {
        let t = Float(elapsedSeconds)

        // Ergonomic bimanual Lissajous figure-8 trajectories spanning [0.14m ... 0.80m] inter-palm span
        let halfSpan = 0.15 + 0.23 * (0.5 + 0.5 * sinf(t * 0.53))
        let leftPalm = SIMD3<Float>(
            -halfSpan + 0.035 * cosf(t * 1.13),
            1.18 + 0.065 * sinf(t * 0.89),
            -0.42 + 0.045 * sinf(t * 0.71)
        )
        let rightPalm = SIMD3<Float>(
            halfSpan + 0.035 * sinf(t * 1.07),
            1.18 + 0.065 * cosf(t * 0.83),
            -0.42 + 0.045 * cosf(t * 0.67)
        )

        // Pinch apertures sweeping smoothly across Schmitt-trigger hysteresis thresholds [0.006m ... 0.112m]
        let leftAperture = 0.006 + 0.104 * (0.5 + 0.5 * sinf(t * 1.31))
        let rightAperture = 0.006 + 0.104 * (0.5 + 0.5 * cosf(t * 1.09 + 0.55))

        let leftThumb = leftPalm + SIMD3<Float>(0.024, 0.020, -0.055)
        let leftIndex = leftThumb + SIMD3<Float>(0.0, leftAperture, -0.008)
        let leftMiddle = leftIndex + SIMD3<Float>(-0.016, 0.006, -0.006)
        let leftWrist = leftPalm + SIMD3<Float>(0.010, -0.045, 0.065)
        let leftForearm = leftWrist + SIMD3<Float>(0.020, -0.055, 0.155)

        let rightThumb = rightPalm + SIMD3<Float>(-0.024, 0.020, -0.055)
        let rightIndex = rightThumb + SIMD3<Float>(0.0, rightAperture, -0.008)
        let rightMiddle = rightIndex + SIMD3<Float>(0.016, 0.006, -0.006)
        let rightWrist = rightPalm + SIMD3<Float>(-0.010, -0.045, 0.065)
        let rightForearm = rightWrist + SIMD3<Float>(-0.020, -0.055, 0.155)

        let forearmAxis = simd_normalize(rightWrist - rightForearm)
        let wristRollAngle = 1.25 * sinf(t * 0.91)
        let rightWristQuat = simd_quatf(angle: wristRollAngle, axis: forearmAxis)

        return BimanualHandPoseSample(
            headTransform: headTransform,
            leftThumbTip: leftThumb,
            leftIndexTip: leftIndex,
            leftMiddleTip: leftMiddle,
            leftWrist: leftWrist,
            leftForearmArm: leftForearm,
            leftPalm: leftPalm,
            rightThumbTip: rightThumb,
            rightIndexTip: rightIndex,
            rightMiddleTip: rightMiddle,
            rightWrist: rightWrist,
            rightForearmArm: rightForearm,
            rightPalm: rightPalm,
            rightWristOrientation: rightWristQuat,
            timestamp: timestamp
        )
    }

    @inline(__always)
    nonisolated private static func extractPosition(from matrix: simd_float4x4) -> SIMD3<Float> {
        SIMD3<Float>(matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z)
    }

    nonisolated private static func extractNormalizedQuaternion(from matrix: simd_float4x4) -> simd_quatf {
        let c0 = SIMD3<Float>(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z)
        let c1 = SIMD3<Float>(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z)
        let c2 = SIMD3<Float>(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z)

        let l0 = simd_length(c0)
        let l1 = simd_length(c1)
        let l2 = simd_length(c2)
        guard l0 > 1.0e-6, l1 > 1.0e-6, l2 > 1.0e-6 else {
            return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }

        let rot3x3 = simd_float3x3(columns: (c0 / l0, c1 / l1, c2 / l2))
        let q = simd_quatf(rot3x3)
        let qLen = simd_length(q.vector)
        return qLen > 1.0e-6 ? simd_quatf(vector: q.vector / qLen) : simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    }
}

#endif
