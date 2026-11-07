// MARK: - FILE: SharedAppIntents.swift

import Foundation
import AppIntents
import WidgetKit
#if canImport(ActivityKit)
import ActivityKit
#endif

// MARK: - Cross-Surface Intent Command Bus

public enum ExternalIntentAction: String, Codable, Sendable {
    case toggleFocus
    case setFocusOn
    case setFocusOff
    case cycleNextPreset
    case habitPulseLogged
}

public extension Notification.Name {
    static let aetherExternalIntentCommand = Notification.Name("com.aethersynth.flow.externalIntentCommand")
}

public enum IntentNotificationBridge {
    public static let actionUserInfoKey = "action"

    @MainActor
    public static func post(_ action: ExternalIntentAction) {
        NotificationCenter.default.post(
            name: .aetherExternalIntentCommand,
            object: nil,
            userInfo: [actionUserInfoKey: action.rawValue]
        )
    }
}

// MARK: - 1. Interactive Home Screen Widget +15m Habit Pulse Intent

public struct LogHabitPulseIntent: AppIntent {
    public static let title: LocalizedStringResource = "Log +15m Spatial Habit Pulse"
    public static let description = IntentDescription(
        "Records a 15-minute focus check-in on your active habit node and updates your 365-day matrix."
    )
    public static let openAppWhenRun: Bool = false

    @Parameter(title: "Habit Identifier")
    public var habitIDString: String?

    @Parameter(title: "Minutes", default: 15)
    public var minutes: Int

    public init() {
        self.habitIDString = nil
        self.minutes = 15
    }

    public init(habitIDString: String?, minutes: Int = 15) {
        self.habitIDString = habitIDString
        self.minutes = minutes
    }

    public func perform() async throws -> some IntentResult {
        let container = try AetherPersistenceSchema.makeContainer(inMemory: false)
        let dbActor = TelemetryDatabaseActor(modelContainer: container)
        let targetUUID = habitIDString.flatMap(UUID.init(uuidString:))

        if let updatedHabit = try await dbActor.logQuickHabitPulse(habitID: targetUUID, addedMinutes: max(5, minutes)) {
            var snap = SharedWidgetStateStore.read()
            snap.activeHabitIDString = updatedHabit.habitID.uuidString
            snap.activeHabitTitle = updatedHabit.title
            snap.activeHabitSymbol = updatedHabit.symbolName
            snap.accentHue = updatedHabit.accentHue
            snap.completedMinutesToday = updatedHabit.completedMinutesToday
            snap.targetMinutesToday = updatedHabit.targetMinutesPerDay
            snap.currentStreak = updatedHabit.currentStreak
            snap.updatedAt = .now
            SharedWidgetStateStore.write(snap)
        }

        await IntentNotificationBridge.post(.habitPulseLogged)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

// MARK: - 2. Live Activity & Dynamic Island Play/Pause Intent

public struct ToggleSpatialFocusIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "Toggle Spatial Focus Session"
    public static let description = IntentDescription("Pauses or resumes the active AetherSynth focus session.")
    public static let openAppWhenRun: Bool = false

    public init() {}

    public func perform() async throws -> some IntentResult {
        var snap = SharedWidgetStateStore.read()
        snap.isFocusRunning.toggle()
        snap.updatedAt = .now
        SharedWidgetStateStore.write(snap)

        await IntentNotificationBridge.post(.toggleFocus)
        WidgetCenter.shared.reloadAllTimelines()
        if #available(iOS 18.0, *) {
            ControlCenter.shared.reloadAllControls()
        }
        return .result()
    }
}

// MARK: - 3. iOS 18 Control Center SetValueIntent Toggle

@available(iOS 18.0, *)
public struct SetSpatialFocusControlIntent: SetValueIntent, LiveActivityIntent {
    public static let title: LocalizedStringResource = "Set Spatial Focus State"
    public static let description = IntentDescription("Starts or pauses AetherSynth binaural focus from Control Center.")
    public static let openAppWhenRun: Bool = false

    @Parameter(title: "Focus Active")
    public var value: Bool

    public init() {
        self.value = false
    }

    public init(value: Bool) {
        self.value = value
    }

    public func perform() async throws -> some IntentResult {
        var snap = SharedWidgetStateStore.read()
        snap.isFocusRunning = value
        snap.updatedAt = .now
        SharedWidgetStateStore.write(snap)

        await IntentNotificationBridge.post(value ? .setFocusOn : .setFocusOff)
        WidgetCenter.shared.reloadAllTimelines()
        ControlCenter.shared.reloadAllControls()
        return .result()
    }
}

// MARK: - 4. Dynamic Island & Lock Screen Preset Cycler Intent

public struct CycleAudioPresetIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "Cycle Binaural Synth Preset"
    public static let description = IntentDescription("Advances to the next procedural binaural preset.")
    public static let openAppWhenRun: Bool = false

    public init() {}

    public func perform() async throws -> some IntentResult {
        await IntentNotificationBridge.post(.cycleNextPreset)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
