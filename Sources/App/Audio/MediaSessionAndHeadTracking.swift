// MARK: - FILE: MediaSessionAndHeadTracking.swift

import Foundation
import AVFoundation
import MediaPlayer
import simd
#if os(iOS) || os(visionOS)
import UIKit
#endif
#if os(iOS)
import CoreMotion
#endif
#if os(macOS)
import AppKit
#endif

@MainActor
public final class MediaSessionAndHeadTrackingController {
    public var onPlayRequested: (() -> Void)?
    public var onPauseRequested: (() -> Void)?
    public var onToggleRequested: (() -> Void)?
    public var onNextPresetRequested: (() -> Void)?
    public var onPreviousPresetRequested: (() -> Void)?
    public var onHeadOrientationChanged: ((Float, Float) -> Void)?
    public var onHeadQuaternionChanged: ((SIMD4<Float>, Float, Float) -> Void)?
    public var onAudioInterruptedPause: (() -> Void)?
    public var onAudioInterruptionShouldResume: (() -> Void)?

    public private(set) var isHeadTrackingAvailable: Bool = false
    public private(set) var isHeadTrackingActive: Bool = false
    public private(set) var currentYawDegrees: Double = 0.0
    public private(set) var currentPitchDegrees: Double = 0.0
    public private(set) var currentHeadQuaternion: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 1)

    private var referenceYawRadians: Double?
    private var wasPlayingBeforeInterruption: Bool = false
    private var commandsRegistered: Bool = false
    private var cachedArtworkHue: Double = -1.0

    private var cachedArtwork: MPMediaItemArtwork?

    #if os(iOS) || os(visionOS)
    private var notificationTokens: [NSObjectProtocol] = []
    #endif

    #if os(iOS)
    private let headphoneMotionManager = CMHeadphoneMotionManager()
    private let motionQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.aethersynth.flow.headphoneMotion"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInteractive
        return q
    }()
    #endif

    public init() {
        #if os(iOS)
        self.isHeadTrackingAvailable = headphoneMotionManager.isDeviceMotionAvailable
        #elseif os(visionOS)
        self.isHeadTrackingAvailable = true
        #endif
    }

    // MARK: - Remote Command Center & Audio Session Observers

    public func activateMediaIntegration() {
        guard !commandsRegistered else { return }
        commandsRegistered = true

        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.onPlayRequested?()
            }
            return .success
        }

        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.onPauseRequested?()
            }
            return .success
        }

        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.onToggleRequested?()
            }
            return .success
        }

        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.onNextPresetRequested?()
            }
            return .success
        }

        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.onPreviousPresetRequested?()
            }
            return .success
        }

        #if os(iOS) || os(visionOS)
        registerAudioSessionObservers()
        #endif
    }

    #if os(iOS) || os(visionOS)
    private func registerAudioSessionObservers() {
        let center = NotificationCenter.default

        let interruptionToken = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] notification in
            let typeRaw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsRaw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0

            Task { @MainActor [weak self] in
                guard let self, let typeRaw,
                      let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }

                switch type {
                case .began:
                    self.wasPlayingBeforeInterruption = true
                    self.onAudioInterruptedPause?()
                case .ended:
                    let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
                    if self.wasPlayingBeforeInterruption && options.contains(.shouldResume) {
                        self.wasPlayingBeforeInterruption = false
                        self.onAudioInterruptionShouldResume?()
                    }
                @unknown default:
                    break
                }
            }
        }

        let routeToken = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] notification in
            let reasonRaw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor [weak self] in
                guard let self, let reasonRaw,
                      let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw) else { return }
                if reason == .oldDeviceUnavailable {
                    self.onAudioInterruptedPause?()
                }
            }
        }

        notificationTokens = [interruptionToken, routeToken]
    }
    #endif

    // MARK: - Lock Screen Now Playing Info & Procedural Artwork

    public func updateNowPlayingMetadata(
        title: String,
        presetName: String,
        beatFrequencyHz: Float,
        accentHue: Double,
        elapsedSeconds: Double,
        plannedDurationSeconds: Double,
        isPlaying: Bool
    ) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: "\(presetName) · \(String(format: "%.1f Hz", beatFrequencyHz)) Binaural",
            MPMediaItemPropertyAlbumTitle: "AetherSynth & Flow",
            MPMediaItemPropertyPlaybackDuration: max(1.0, plannedDurationSeconds),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0.0, elapsedSeconds),
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0
        ]

        #if os(iOS) || os(visionOS)
        if abs(cachedArtworkHue - accentHue) > 0.02 || cachedArtwork == nil {
            cachedArtworkHue = accentHue
            let capturedHue = accentHue
            cachedArtwork = MPMediaItemArtwork(boundsSize: CGSize(width: 512, height: 512)) { requestedSize in
                Self.renderProceduralLockScreenArtwork(hue: capturedHue, size: requestedSize)
            }
        }
        if let artwork = cachedArtwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        #elseif os(macOS)
        if abs(cachedArtworkHue - accentHue) > 0.02 || cachedArtwork == nil {
            cachedArtworkHue = accentHue
            let capturedHue = accentHue
            cachedArtwork = MPMediaItemArtwork(boundsSize: CGSize(width: 512, height: 512)) { requestedSize in
                Self.renderProceduralMacNowPlayingArtwork(hue: capturedHue, size: requestedSize)
            }
        }
        if let artwork = cachedArtwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        #endif

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    #if os(iOS) || os(visionOS)
    nonisolated private static func renderProceduralLockScreenArtwork(hue: Double, size: CGSize) -> UIImage {
        let safeSize = CGSize(width: max(64, size.width), height: max(64, size.height))
        let renderer = UIGraphicsImageRenderer(size: safeSize)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            let rect = CGRect(origin: .zero, size: safeSize)
            cg.setFillColor(UIColor(red: 0.03, green: 0.04, blue: 0.08, alpha: 1.0).cgColor)
            cg.fill(rect)

            let primary = UIColor(hue: CGFloat(hue), saturation: 0.78, brightness: 0.95, alpha: 0.85)
            let secondary = UIColor(
                hue: CGFloat((hue + 0.18).truncatingRemainder(dividingBy: 1.0)),
                saturation: 0.72,
                brightness: 0.85,
                alpha: 0.35
            )
            let clear = UIColor.clear

            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [primary.cgColor, secondary.cgColor, clear.cgColor] as CFArray,
                locations: [0.0, 0.48, 1.0]
            ) {
                let center = CGPoint(x: safeSize.width * 0.5, y: safeSize.height * 0.5)
                cg.drawRadialGradient(
                    gradient,
                    startCenter: center,
                    startRadius: 8,
                    endCenter: center,
                    endRadius: min(safeSize.width, safeSize.height) * 0.48,
                    options: [.drawsAfterEndLocation]
                )
            }

            let center = CGPoint(x: safeSize.width * 0.5, y: safeSize.height * 0.5)
            for ring in 1...3 {
                let radius = min(safeSize.width, safeSize.height) * (0.16 + CGFloat(ring) * 0.085)
                let ringRect = CGRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
                cg.setStrokeColor(UIColor.white.withAlphaComponent(0.28 - CGFloat(ring) * 0.06).cgColor)
                cg.setLineWidth(2.0)
                cg.strokeEllipse(in: ringRect)
            }
        }
    }
    #elseif os(macOS)
    nonisolated private static func renderProceduralMacNowPlayingArtwork(hue: Double, size: CGSize) -> NSImage {
        let safeSize = NSSize(width: max(64, size.width), height: max(64, size.height))
        let image = NSImage(size: safeSize)
        image.lockFocus()
        defer { image.unlockFocus() }

        if let cg = NSGraphicsContext.current?.cgContext {
            let rect = CGRect(origin: .zero, size: safeSize)
            cg.setFillColor(NSColor(calibratedRed: 0.03, green: 0.04, blue: 0.08, alpha: 1.0).cgColor)
            cg.fill(rect)

            let primary = NSColor(calibratedHue: CGFloat(hue), saturation: 0.78, brightness: 0.95, alpha: 0.85)
            let secondary = NSColor(
                calibratedHue: CGFloat((hue + 0.18).truncatingRemainder(dividingBy: 1.0)),
                saturation: 0.72,
                brightness: 0.85,
                alpha: 0.35
            )
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [primary.cgColor, secondary.cgColor, NSColor.clear.cgColor] as CFArray,
                locations: [0.0, 0.48, 1.0]
            ) {
                let center = CGPoint(x: safeSize.width * 0.5, y: safeSize.height * 0.5)
                cg.drawRadialGradient(
                    gradient,
                    startCenter: center,
                    startRadius: 8,
                    endCenter: center,
                    endRadius: min(safeSize.width, safeSize.height) * 0.48,
                    options: [.drawsAfterEndLocation]
                )
            }
        }
        return image
    }
    #endif

    // MARK: - AirPods Pro / Max & visionOS 6-DoF Spatial Head-Tracking

    public func setHeadTrackingEnabled(_ enabled: Bool) {
        #if os(iOS)
        isHeadTrackingAvailable = headphoneMotionManager.isDeviceMotionAvailable
        guard enabled, isHeadTrackingAvailable else {
            stopHeadTracking()
            return
        }
        guard !headphoneMotionManager.isDeviceMotionActive else { return }

        referenceYawRadians = nil
        isHeadTrackingActive = true

        headphoneMotionManager.startDeviceMotionUpdates(to: motionQueue) { [weak self] motion, _ in
            guard let motion else { return }
            let rawYaw = motion.attitude.yaw
            let rawPitch = motion.attitude.pitch
            let q = motion.attitude.quaternion
            let quatVec = SIMD4<Float>(Float(q.x), Float(q.y), Float(q.z), Float(q.w))

            Task { @MainActor [weak self] in
                self?.consumeHeadMotionSample(rawYaw: rawYaw, rawPitch: rawPitch, quaternion: quatVec)
            }
        }
        #elseif os(visionOS)
        isHeadTrackingActive = enabled
        if !enabled {
            recenterHeadReference()
        }
        #else
        isHeadTrackingActive = false
        #endif
    }

    public func consumeVision6DoFHeadPose(yawRadians: Double, pitchRadians: Double, quaternion: SIMD4<Float>) {
        guard isHeadTrackingActive else { return }
        consumeHeadMotionSample(rawYaw: yawRadians, rawPitch: pitchRadians, quaternion: quaternion)
    }

    public func recenterHeadReference() {
        referenceYawRadians = nil
        currentYawDegrees = 0
        currentPitchDegrees = 0
        currentHeadQuaternion = SIMD4<Float>(0, 0, 0, 1)
        onHeadOrientationChanged?(0, 0)
        onHeadQuaternionChanged?(currentHeadQuaternion, 0, 0)
    }

    public func stopHeadTracking() {
        #if os(iOS)
        if headphoneMotionManager.isDeviceMotionActive {
            headphoneMotionManager.stopDeviceMotionUpdates()
        }
        #endif
        isHeadTrackingActive = false
        referenceYawRadians = nil
        currentYawDegrees = 0
        currentPitchDegrees = 0
        currentHeadQuaternion = SIMD4<Float>(0, 0, 0, 1)
        onHeadOrientationChanged?(0, 0)
        onHeadQuaternionChanged?(currentHeadQuaternion, 0, 0)
    }

    private func consumeHeadMotionSample(rawYaw: Double, rawPitch: Double, quaternion: SIMD4<Float>) {
        if referenceYawRadians == nil {
            referenceYawRadians = rawYaw
        }
        let anchor = referenceYawRadians ?? 0
        var deltaYaw = rawYaw - anchor
        while deltaYaw > .pi { deltaYaw -= 2.0 * .pi }
        while deltaYaw < -.pi { deltaYaw += 2.0 * .pi }

        currentYawDegrees = deltaYaw * (180.0 / .pi)
        currentPitchDegrees = rawPitch * (180.0 / .pi)
        currentHeadQuaternion = quaternion

        let mappedPan = Self.mapHeadAttitudeToSpatialControls(deltaYawRadians: deltaYaw, pitchRadians: rawPitch)
        onHeadOrientationChanged?(mappedPan.pan, mappedPan.elevation)
        onHeadQuaternionChanged?(quaternion, mappedPan.pan, mappedPan.elevation)
    }

    /// Pure mathematical projection from head attitude radians into normalized synth pan & elevation [-1, 1]
    nonisolated public static func mapHeadAttitudeToSpatialControls(
        deltaYawRadians: Double,
        pitchRadians: Double
    ) -> (pan: Float, elevation: Float) {
        let pan = Float(min(max(-sin(deltaYawRadians) * 0.85, -1.0), 1.0))
        let elevation = Float(min(max(sin(pitchRadians) * 1.15, -1.0), 1.0))
        return (pan, elevation)
    }
}
