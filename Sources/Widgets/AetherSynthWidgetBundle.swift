// MARK: - FILE: AetherSynthWidgetBundle.swift

import SwiftUI
import WidgetKit

@main
struct AetherSynthWidgetBundle: WidgetBundle {
    var body: some Widget {
        HabitMatrixHomeWidget()
        #if canImport(ActivityKit) && os(iOS)
        FocusLiveActivityWidget()
        #endif
        SpatialFocusControlWidget()
    }
}
