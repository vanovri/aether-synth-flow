// MARK: - FILE: SpatialFocusControlWidget.swift

import SwiftUI
import WidgetKit
import AppIntents

@available(iOS 18.0, *)
public struct SpatialFocusControlValueProvider: ControlValueProvider {
    public init() {}

    public var previewValue: Bool {
        false
    }

    public func currentValue() async throws -> Bool {
        SharedWidgetStateStore.read().isFocusRunning
    }
}

@available(iOS 18.0, *)
public struct SpatialFocusControlWidget: ControlWidget {
    public static let kind: String = "com.aethersynth.flow.control.spatialFocus"

    public init() {}

    public var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: Self.kind,
            provider: SpatialFocusControlValueProvider()
        ) { isRunning in
            ControlWidgetToggle(
                "Spatial Focus",
                isOn: isRunning,
                action: SetSpatialFocusControlIntent()
            ) { active in
                Label(
                    active ? "Binaural Active" : "Ignite Flow",
                    systemImage: active ? "waveform.circle.fill" : "scope"
                )
            }
            .tint(.cyan)
        }
        .displayName("Aether Spatial Focus")
        .description("Toggle procedural binaural focus synthesis directly from Control Center.")
    }
}
