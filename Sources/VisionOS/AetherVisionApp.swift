// MARK: - FILE: AetherVisionApp.swift

import SwiftUI
import SwiftData
import Observation

#if os(visionOS)
import CompositorServices

// MARK: - visionOS 2.0 Glass Control Deck Shell Wrapping RootSpatialShellView

public struct VisionGlassControlDeckHostView: View {
    @Bindable public var coordinator: AetherAppCoordinator
    @Bindable public var handTracker: BimanualHandTrackingActor
    @Binding public var isImmersiveSpaceOpen: Bool
    @Binding public var selectedImmersionStyle: ImmersionStyle

    @Environment(\.openWindow) private var openWindow
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    public init(
        coordinator: AetherAppCoordinator,
        handTracker: BimanualHandTrackingActor,
        isImmersiveSpaceOpen: Binding<Bool>,
        selectedImmersionStyle: Binding<ImmersionStyle>
    ) {
        self.coordinator = coordinator
        self.handTracker = handTracker
        self._isImmersiveSpaceOpen = isImmersiveSpaceOpen
        self._selectedImmersionStyle = selectedImmersionStyle
    }

    public var body: some View {
        RootSpatialShellView(coordinator: coordinator)
            .glassBackgroundEffect()
            .ornament(attachmentAnchor: .scene(.bottom)) {
                spatialStageOrnamentBar
            }
            .ornament(attachmentAnchor: .scene(.trailing)) {
                bimanualTelemetryInspectorOrnament
            }
    }

    private var spatialStageOrnamentBar: some View {
        HStack(spacing: 14) {
            Button {
                openWindow(id: "aether-orbital-volume")
            } label: {
                Label("3D Orbital Volume (0.85m³)", systemImage: "cube.transparent.fill")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            .buttonStyle(.bordered)

            Button {
                Task {
                    if isImmersiveSpaceOpen {
                        await dismissImmersiveSpace()
                        isImmersiveSpaceOpen = false
                    } else {
                        let result = await openImmersiveSpace(id: "aether-compositor-space")
                        if case .opened = result {
                            isImmersiveSpaceOpen = true
                        }
                    }
                }
            } label: {
                Label(
                    isImmersiveSpaceOpen ? "Exit Compositor Aurora" : "Enter 16K Compositor Space",
                    systemImage: "sparkles"
                )
                .font(.system(size: 13, weight: .bold, design: .rounded))
            }
            .buttonStyle(.borderedProminent)

            Button {
                handTracker.toggleSimulatorMode()
            } label: {
                Label(
                    handTracker.isUsingSimulatorMode ? "Sim Hands (90Hz)" : "ARKit Hands (90Hz)",
                    systemImage: "hand.raised.fingers.spread.fill"
                )
                .font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            .buttonStyle(.bordered)

            Toggle("Couple Pose → Synth", isOn: $handTracker.isDSPModulationCoupled)
                .toggleStyle(.button)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .glassBackgroundEffect()
    }

    private var bimanualTelemetryInspectorOrnament: some View {
        let mod = handTracker.latestModulation
        return VStack(alignment: .leading, spacing: 8) {
            Text("6-DoF Hand Telemetry")
                .font(.system(size: 12, weight: .bold, design: .rounded))

            Text(handTracker.trackingStatusDescription)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Divider()

            telemetryLine(
                "L Pinch",
                String(
                    format: "%.0fmm %@ → %.1f Hz",
                    mod.leftPinchDistanceMeters * 1000.0,
                    mod.leftPinchEngaged ? "[ON]" : "[--]",
                    mod.binauralBeatHz
                )
            )
            telemetryLine(
                "R Pinch",
                String(
                    format: "%.0fmm %@ → %.0f Hz",
                    mod.rightPinchDistanceMeters * 1000.0,
                    mod.rightPinchEngaged ? "[ON]" : "[--]",
                    mod.filterCutoffHz
                )
            )
            telemetryLine(
                "Wrist Q",
                String(format: "%+.0f° → Q %.2f", mod.rightWristRollRadians * 180.0 / .pi, mod.filterResonance)
            )
            telemetryLine(
                "Palm Span",
                String(
                    format: "%.2fm → %.1fct · %.2fx",
                    mod.interPalmSpanMeters,
                    mod.padDetuneCents,
                    mod.orbitalRadiusScale
                )
            )
        }
        .padding(14)
        .frame(width: 248, alignment: .leading)
        .glassBackgroundEffect()
    }

    private func telemetryLine(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
        }
    }
}

// MARK: - Native visionOS 2.0 Application Entry Point

@main
public struct AetherVisionApp: App {
    private let modelContainer: ModelContainer
    private let sharedSpatialState: VisionSpatialSharedState
    @State private var coordinator: AetherAppCoordinator
    @State private var handTracker: BimanualHandTrackingActor
    @State private var isImmersiveSpaceOpen: Bool = false
    @State private var immersionStyle: ImmersionStyle = .full

    public init() {
        let container: ModelContainer
        do {
            container = try AetherPersistenceSchema.makeContainer(inMemory: false)
        } catch {
            fatalError("Failed to create visionOS SwiftData ModelContainer: \(error.localizedDescription)")
        }
        let bridge = VisionSpatialSharedState()
        self.modelContainer = container
        self.sharedSpatialState = bridge
        self._coordinator = State(initialValue: AetherAppCoordinator(modelContainer: container))
        self._handTracker = State(initialValue: BimanualHandTrackingActor(sharedState: bridge))
    }

    public var body: some Scene {
        // 1. Main 2D Glass Control Window hosting RootSpatialShellView
        WindowGroup(id: "aether-control-deck") {
            VisionGlassControlDeckHostView(
                coordinator: coordinator,
                handTracker: handTracker,
                isImmersiveSpaceOpen: $isImmersiveSpaceOpen,
                selectedImmersionStyle: $immersionStyle
            )
            .modelContainer(modelContainer)
            .task {
                await coordinator.startSystemPipelines()
                await handTracker.startTracking(coordinator: coordinator)
            }
        }
        .defaultSize(width: 1080, height: 760)

        // 2. 3D Volumetric Orbital Window (0.85m x 0.85m x 0.85m)
        WindowGroup(id: "aether-orbital-volume") {
            VolumetricOrbitalRealityView(
                coordinator: coordinator,
                handTracker: handTracker
            )
            .modelContainer(modelContainer)
        }
        .windowStyle(.volumetric)
        .defaultSize(width: 0.85, height: 0.85, depth: 0.85, in: .meters)

        // 3. Full Stereoscopic CompositorServices Metal Compute & Render Space
        ImmersiveSpace(id: "aether-compositor-space") {
            CompositorLayer(configuration: AetherCompositorLayerConfiguration()) { layerRenderer in
                if let renderer = AetherCompositorRenderer(
                    layerRenderer: layerRenderer,
                    sharedState: sharedSpatialState
                ) {
                    renderer.startRenderLoop()
                }
            }
        }
        .immersionStyle(selection: $immersionStyle, in: .progressive, .full)
    }
}
#endif
