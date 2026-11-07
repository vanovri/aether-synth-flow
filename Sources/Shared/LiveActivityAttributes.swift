// MARK: - FILE: LiveActivityAttributes.swift

import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

// MARK: - Shared App Group Snapshot for Instant Widget & Control Center Reads

public struct SharedWidgetSnapshot: Codable, Sendable, Equatable {
    public var isFocusRunning: Bool
    public var activeHabitIDString: String?
    public var activeHabitTitle: String
    public var activeHabitSymbol: String
    public var accentHue: Double
    public var completedMinutesToday: Int
    public var targetMinutesToday: Int
    public var currentStreak: Int
    public var binauralBeatHz: Double
    public var activePresetName: String
    public var recentSevenDayBuckets: [Int] // 7 elements: oldest -> today (0...4)
    public var latestAutonomicCoherence: Double
    public var latestHeartRateBPM: Double
    public var latestRMSSDMs: Double
    public var isBioEntrainmentActive: Bool
    public var updatedAt: Date

    public init(
        isFocusRunning: Bool = false,
        activeHabitIDString: String? = nil,
        activeHabitTitle: String = "Systems Architecture",
        activeHabitSymbol: String = "cpu.fill",
        accentHue: Double = 0.54,
        completedMinutesToday: Int = 25,
        targetMinutesToday: Int = 60,
        currentStreak: Int = 6,
        binauralBeatHz: Double = 14.0,
        activePresetName: String = "Nebula Deep Work",
        recentSevenDayBuckets: [Int] = [2, 3, 1, 4, 2, 3, 2],
        latestAutonomicCoherence: Double = 0.78,
        latestHeartRateBPM: Double = 64.0,
        latestRMSSDMs: Double = 52.0,
        isBioEntrainmentActive: Bool = false,
        updatedAt: Date = .now
    ) {
        self.isFocusRunning = isFocusRunning
        self.activeHabitIDString = activeHabitIDString
        self.activeHabitTitle = activeHabitTitle
        self.activeHabitSymbol = activeHabitSymbol
        self.accentHue = accentHue
        self.completedMinutesToday = completedMinutesToday
        self.targetMinutesToday = targetMinutesToday
        self.currentStreak = currentStreak
        self.binauralBeatHz = binauralBeatHz
        self.activePresetName = activePresetName
        self.recentSevenDayBuckets = recentSevenDayBuckets
        self.latestAutonomicCoherence = min(max(latestAutonomicCoherence, 0.0), 1.0)
        self.latestHeartRateBPM = max(0.0, latestHeartRateBPM)
        self.latestRMSSDMs = max(0.0, latestRMSSDMs)
        self.isBioEntrainmentActive = isBioEntrainmentActive
        self.updatedAt = updatedAt
    }
}

public enum SharedWidgetStateStore: Sendable {
    private static let storageKey = "com.aethersynth.flow.widgetSnapshot.v1"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: AetherPersistenceSchema.appGroupIdentifier) ?? .standard
    }

    public static func read() -> SharedWidgetSnapshot {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(SharedWidgetSnapshot.self, from: data) else {
            return SharedWidgetSnapshot()
        }
        return decoded
    }

    public static func write(_ snapshot: SharedWidgetSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

// MARK: - ActivityKit Live Activity Attributes & Controller

#if canImport(ActivityKit) && os(iOS)
public struct FocusActivityAttributes: ActivityAttributes, Sendable {
    public struct ContentState: Codable, Hashable, Sendable {
        public var sessionTitle: String
        public var habitSymbolName: String
        public var accentHue: Double
        public var targetEndDate: Date
        public var plannedDurationSeconds: Double
        public var pausedRemainingSeconds: Double?
        public var binauralBeatHz: Double
        public var presetName: String
        public var isRunning: Bool

        public init(
            sessionTitle: String,
            habitSymbolName: String,
            accentHue: Double,
            targetEndDate: Date,
            plannedDurationSeconds: Double,
            pausedRemainingSeconds: Double?,
            binauralBeatHz: Double,
            presetName: String,
            isRunning: Bool
        ) {
            self.sessionTitle = sessionTitle
            self.habitSymbolName = habitSymbolName
            self.accentHue = accentHue
            self.targetEndDate = targetEndDate
            self.plannedDurationSeconds = plannedDurationSeconds
            self.pausedRemainingSeconds = pausedRemainingSeconds
            self.binauralBeatHz = binauralBeatHz
            self.presetName = presetName
            self.isRunning = isRunning
        }
    }

    public var sessionID: UUID
    public var categoryName: String

    public init(sessionID: UUID, categoryName: String) {
        self.sessionID = sessionID
        self.categoryName = categoryName
    }
}

@MainActor
public final class FocusLiveActivityController {
    private var activeActivity: Activity<FocusActivityAttributes>?

    public init() {}

    public func startOrUpdate(
        sessionID: UUID,
        categoryName: String,
        state: FocusActivityAttributes.ContentState
    ) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let stale = state.isRunning ? state.targetEndDate.addingTimeInterval(120) : nil
        let content = ActivityContent(state: state, staleDate: stale)

        if let existing = activeActivity {
            Task {
                await existing.update(content)
            }
        } else {
            let attributes = FocusActivityAttributes(sessionID: sessionID, categoryName: categoryName)
            do {
                activeActivity = try Activity.request(
                    attributes: attributes,
                    content: content,
                    pushType: nil
                )
            } catch {
                activeActivity = nil
            }
        }
    }

    public func endAll(finalState: FocusActivityAttributes.ContentState? = nil) {
        let current = activeActivity
        activeActivity = nil

        Task {
            if let current {
                if let finalState {
                    let content = ActivityContent(state: finalState, staleDate: nil)
                    await current.end(content, dismissalPolicy: .immediate)
                } else {
                    await current.end(nil, dismissalPolicy: .immediate)
                }
            }
            for stray in Activity<FocusActivityAttributes>.activities {
                await stray.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
#endif
