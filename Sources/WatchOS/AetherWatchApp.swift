// MARK: - FILE: AetherWatchApp.swift

import SwiftUI
import SwiftData

#if os(watchOS)

@main
public struct AetherWatchApp: App {
    private let modelContainer: ModelContainer
    @State private var biometricEngine = WatchHealthKitBiometricEngine()

    public init() {
        do {
            self.modelContainer = try AetherPersistenceSchema.makeContainer(inMemory: false)
        } catch {
            fatalError("Failed to initialize watchOS SwiftData ModelContainer: \(error.localizedDescription)")
        }
    }

    public var body: some Scene {
        WindowGroup {
            NavigationStack {
                WatchOrbitalCrownView(engine: biometricEngine)
            }
            .modelContainer(modelContainer)
            .task {
                let databaseActor = TelemetryDatabaseActor(modelContainer: modelContainer)
                try? await databaseActor.bootstrapDefaultsIfNeeded()
                await biometricEngine.activatePipelines()
            }
        }
    }
}

#endif
