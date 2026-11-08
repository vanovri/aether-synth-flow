// MARK: - FILE: PersistenceModels.swift

import Foundation
import SwiftData

// MARK: - Domain Enumerations & Thread-Safe Value Helpers

public enum FocusCategory: String, Codable, CaseIterable, Sendable, Identifiable {
    case deepWork = "deep_work"
    case alphaFlow = "alpha_flow"
    case thetaMeditation = "theta_meditation"
    case gammaCognition = "gamma_cognition"
    case deltaRecovery = "delta_recovery"

    public static var creativeFlow: FocusCategory { .alphaFlow }
    public static var meditation: FocusCategory { .thetaMeditation }

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .deepWork: return "Deep Work"
        case .alphaFlow: return "Alpha Flow"
        case .thetaMeditation: return "Theta Drift"
        case .gammaCognition: return "Gamma Peak"
        case .deltaRecovery: return "Delta Rest"
        }
    }

    public var symbolName: String {
        switch self {
        case .deepWork: return "scope"
        case .alphaFlow: return "wind"
        case .thetaMeditation: return "moon.stars.fill"
        case .gammaCognition: return "bolt.ring.closed"
        case .deltaRecovery: return "leaf.fill"
        }
    }

    public var recommendedBeatHz: Double {
        switch self {
        case .deepWork: return 14.0
        case .alphaFlow: return 10.0
        case .thetaMeditation: return 5.5
        case .gammaCognition: return 40.0
        case .deltaRecovery: return 2.5
        }
    }
}

public enum ConflictResolutionPolicy: String, Codable, CaseIterable, Sendable {
    case newerTimestampWins
    case higherRevisionWins
    case mergeAccumulate
    case keepExisting
}

public struct BatchIngestReport: Sendable, Equatable {
    public let insertedSessions: Int
    public let updatedSessions: Int
    public let skippedSessions: Int
    public let affectedTelemetryDays: Int
    public let updatedHabits: Int

    public init(
        insertedSessions: Int,
        updatedSessions: Int,
        skippedSessions: Int,
        affectedTelemetryDays: Int,
        updatedHabits: Int
    ) {
        self.insertedSessions = insertedSessions
        self.updatedSessions = updatedSessions
        self.skippedSessions = skippedSessions
        self.affectedTelemetryDays = affectedTelemetryDays
        self.updatedHabits = updatedHabits
    }
}

public struct ArchiveImportSummary: Sendable, Equatable {
    public let importedHabits: Int
    public let importedPresets: Int
    public let sessionReport: BatchIngestReport
    public let upsertedTelemetryDays: Int

    public init(
        importedHabits: Int,
        importedPresets: Int,
        sessionReport: BatchIngestReport,
        upsertedTelemetryDays: Int
    ) {
        self.importedHabits = importedHabits
        self.importedPresets = importedPresets
        self.sessionReport = sessionReport
        self.upsertedTelemetryDays = upsertedTelemetryDays
    }
}

public struct DayKeyFormatter: Sendable {
    public static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        let year = comps.year ?? 1970
        let month = comps.month ?? 1
        let day = comps.day ?? 1
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    public static func startOfDay(for date: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: date)
    }

    public static func date(from dayKey: String, calendar: Calendar = .current) -> Date? {
        let parts = dayKey.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            return nil
        }
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        return calendar.date(from: comps).map { calendar.startOfDay(for: $0) }
    }

    public static func intensityBucket(forFocusSeconds seconds: Double) -> Int {
        let minutes = seconds / 60.0
        switch minutes {
        case ..<1.0: return 0
        case 1.0..<25.0: return 1
        case 25.0..<60.0: return 2
        case 60.0..<120.0: return 3
        default: return 4
        }
    }
}

// MARK: - SwiftData @Model Entities

@Model
public final class FocusSession {
    @Attribute(.unique) public var sessionID: UUID
    public var title: String
    public var startedAt: Date
    public var endedAt: Date
    public var plannedDurationSeconds: Double
    public var actualDurationSeconds: Double
    public var completed: Bool
    public var focusQualityScore: Double
    public var peakAmplitude: Double
    public var carrierFrequencyHz: Double
    public var beatFrequencyHz: Double
    public var linkedHabitID: UUID?
    public var notes: String
    public var updatedAt: Date
    public var revision: Int

    public var habitNode: HabitNode?

    public init(
        sessionID: UUID = UUID(),
        title: String,
        startedAt: Date,
        endedAt: Date,
        plannedDurationSeconds: Double,
        actualDurationSeconds: Double,
        completed: Bool,
        focusQualityScore: Double,
        peakAmplitude: Double,
        carrierFrequencyHz: Double,
        beatFrequencyHz: Double,
        linkedHabitID: UUID? = nil,
        notes: String = "",
        updatedAt: Date = .now,
        revision: Int = 1,
        habitNode: HabitNode? = nil
    ) {
        self.sessionID = sessionID
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.plannedDurationSeconds = plannedDurationSeconds
        self.actualDurationSeconds = actualDurationSeconds
        self.completed = completed
        self.focusQualityScore = focusQualityScore
        self.peakAmplitude = peakAmplitude
        self.carrierFrequencyHz = carrierFrequencyHz
        self.beatFrequencyHz = beatFrequencyHz
        self.linkedHabitID = linkedHabitID
        self.notes = notes
        self.updatedAt = updatedAt
        self.revision = revision
        self.habitNode = habitNode
    }
}

@Model
public final class HabitNode {
    @Attribute(.unique) public var habitID: UUID
    public var title: String
    public var symbolName: String
    public var accentHue: Double
    public var orbitalMass: Double
    public var targetMinutesPerDay: Int
    public var completedMinutesToday: Int
    public var currentStreak: Int
    public var longestStreak: Int
    public var lastCompletedDayKey: String?
    public var sortOrder: Int
    public var isArchived: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var revision: Int

    @Relationship(deleteRule: .nullify, inverse: \FocusSession.habitNode)
    public var sessions: [FocusSession]

    public init(
        habitID: UUID = UUID(),
        title: String,
        symbolName: String,
        accentHue: Double,
        orbitalMass: Double = 1.0,
        targetMinutesPerDay: Int = 45,
        completedMinutesToday: Int = 0,
        currentStreak: Int = 0,
        longestStreak: Int = 0,
        lastCompletedDayKey: String? = nil,
        sortOrder: Int = 0,
        isArchived: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        revision: Int = 1,
        sessions: [FocusSession] = []
    ) {
        self.habitID = habitID
        self.title = title
        self.symbolName = symbolName
        self.accentHue = accentHue
        self.orbitalMass = min(max(orbitalMass, 0.5), 2.5)
        self.targetMinutesPerDay = max(5, targetMinutesPerDay)
        self.completedMinutesToday = max(0, completedMinutesToday)
        self.currentStreak = max(0, currentStreak)
        self.longestStreak = max(0, longestStreak)
        self.lastCompletedDayKey = lastCompletedDayKey
        self.sortOrder = sortOrder
        self.isArchived = isArchived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.revision = revision
        self.sessions = sessions
    }

    public var dailyCompletionRatio: Double {
        guard targetMinutesPerDay > 0 else { return 0 }
        return min(Double(completedMinutesToday) / Double(targetMinutesPerDay), 1.5)
    }
}

@Model
public final class AudioPreset {
    @Attribute(.unique) public var presetID: UUID
    public var name: String
    public var categoryRawValue: String
    public var carrierFrequencyHz: Double
    public var binauralBeatHz: Double
    public var binauralMix: Double
    public var pinkNoiseMix: Double
    public var padMix: Double
    public var filterCutoffHz: Double
    public var filterResonance: Double
    public var padDetuneCents: Double
    public var masterGain: Double
    public var isBuiltIn: Bool
    public var updatedAt: Date
    public var revision: Int

    public init(
        presetID: UUID = UUID(),
        name: String,
        category: FocusCategory,
        carrierFrequencyHz: Double,
        binauralBeatHz: Double,
        binauralMix: Double,
        pinkNoiseMix: Double,
        padMix: Double,
        filterCutoffHz: Double,
        filterResonance: Double,
        padDetuneCents: Double,
        masterGain: Double,
        isBuiltIn: Bool = false,
        updatedAt: Date = .now,
        revision: Int = 1
    ) {
        self.presetID = presetID
        self.name = name
        self.categoryRawValue = category.rawValue
        self.carrierFrequencyHz = carrierFrequencyHz
        self.binauralBeatHz = binauralBeatHz
        self.binauralMix = binauralMix
        self.pinkNoiseMix = pinkNoiseMix
        self.padMix = padMix
        self.filterCutoffHz = filterCutoffHz
        self.filterResonance = filterResonance
        self.padDetuneCents = padDetuneCents
        self.masterGain = masterGain
        self.isBuiltIn = isBuiltIn
        self.updatedAt = updatedAt
        self.revision = revision
    }

    public var category: FocusCategory {
        get { FocusCategory(rawValue: categoryRawValue) ?? .deepWork }
        set { categoryRawValue = newValue.rawValue }
    }
}

@Model
public final class DailyTelemetry {
    @Attribute(.unique) public var dayKey: String
    public var dateStartOfDay: Date
    public var totalFocusSeconds: Double
    public var completedSessionCount: Int
    public var abortedSessionCount: Int
    public var habitsCompletedCount: Int
    public var averageQualityScore: Double
    public var intensityLevel: Int
    public var dominantBeatHz: Double
    public var updatedAt: Date
    public var revision: Int

    public init(
        dayKey: String,
        dateStartOfDay: Date,
        totalFocusSeconds: Double = 0,
        completedSessionCount: Int = 0,
        abortedSessionCount: Int = 0,
        habitsCompletedCount: Int = 0,
        averageQualityScore: Double = 0,
        intensityLevel: Int = 0,
        dominantBeatHz: Double = 10.0,
        updatedAt: Date = .now,
        revision: Int = 1
    ) {
        self.dayKey = dayKey
        self.dateStartOfDay = dateStartOfDay
        self.totalFocusSeconds = totalFocusSeconds
        self.completedSessionCount = completedSessionCount
        self.abortedSessionCount = abortedSessionCount
        self.habitsCompletedCount = habitsCompletedCount
        self.averageQualityScore = averageQualityScore
        self.intensityLevel = intensityLevel
        self.dominantBeatHz = dominantBeatHz
        self.updatedAt = updatedAt
        self.revision = revision
    }
}

// MARK: - Sendable Cross-Actor & Codable Archive DTOs

public struct FocusSessionDTO: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID { sessionID }
    public let sessionID: UUID
    public let title: String
    public let startedAt: Date
    public let endedAt: Date
    public let plannedDurationSeconds: Double
    public let actualDurationSeconds: Double
    public let completed: Bool
    public let focusQualityScore: Double
    public let peakAmplitude: Double
    public let carrierFrequencyHz: Double
    public let beatFrequencyHz: Double
    public let linkedHabitID: UUID?
    public let notes: String
    public let updatedAt: Date
    public let revision: Int

    public init(
        sessionID: UUID = UUID(),
        title: String,
        startedAt: Date,
        endedAt: Date,
        plannedDurationSeconds: Double,
        actualDurationSeconds: Double,
        completed: Bool,
        focusQualityScore: Double,
        peakAmplitude: Double,
        carrierFrequencyHz: Double,
        beatFrequencyHz: Double,
        linkedHabitID: UUID? = nil,
        notes: String = "",
        updatedAt: Date = .now,
        revision: Int = 1
    ) {
        self.sessionID = sessionID
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.plannedDurationSeconds = plannedDurationSeconds
        self.actualDurationSeconds = actualDurationSeconds
        self.completed = completed
        self.focusQualityScore = focusQualityScore
        self.peakAmplitude = peakAmplitude
        self.carrierFrequencyHz = carrierFrequencyHz
        self.beatFrequencyHz = beatFrequencyHz
        self.linkedHabitID = linkedHabitID
        self.notes = notes
        self.updatedAt = updatedAt
        self.revision = revision
    }

    public init(model: FocusSession) {
        self.sessionID = model.sessionID
        self.title = model.title
        self.startedAt = model.startedAt
        self.endedAt = model.endedAt
        self.plannedDurationSeconds = model.plannedDurationSeconds
        self.actualDurationSeconds = model.actualDurationSeconds
        self.completed = model.completed
        self.focusQualityScore = model.focusQualityScore
        self.peakAmplitude = model.peakAmplitude
        self.carrierFrequencyHz = model.carrierFrequencyHz
        self.beatFrequencyHz = model.beatFrequencyHz
        self.linkedHabitID = model.linkedHabitID
        self.notes = model.notes
        self.updatedAt = model.updatedAt
        self.revision = model.revision
    }
}

public struct HabitNodeDTO: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID { habitID }
    public let habitID: UUID
    public let title: String
    public let symbolName: String
    public let accentHue: Double
    public let orbitalMass: Double
    public let targetMinutesPerDay: Int
    public let completedMinutesToday: Int
    public let currentStreak: Int
    public let longestStreak: Int
    public let lastCompletedDayKey: String?
    public let sortOrder: Int
    public let isArchived: Bool
    public let updatedAt: Date
    public let revision: Int

    public init(
        habitID: UUID = UUID(),
        title: String,
        symbolName: String,
        accentHue: Double,
        orbitalMass: Double = 1.0,
        targetMinutesPerDay: Int = 45,
        completedMinutesToday: Int = 0,
        currentStreak: Int = 0,
        longestStreak: Int = 0,
        lastCompletedDayKey: String? = nil,
        sortOrder: Int = 0,
        isArchived: Bool = false,
        updatedAt: Date = .now,
        revision: Int = 1
    ) {
        self.habitID = habitID
        self.title = title
        self.symbolName = symbolName
        self.accentHue = accentHue
        self.orbitalMass = orbitalMass
        self.targetMinutesPerDay = targetMinutesPerDay
        self.completedMinutesToday = completedMinutesToday
        self.currentStreak = currentStreak
        self.longestStreak = longestStreak
        self.lastCompletedDayKey = lastCompletedDayKey
        self.sortOrder = sortOrder
        self.isArchived = isArchived
        self.updatedAt = updatedAt
        self.revision = revision
    }

    public init(model: HabitNode) {
        self.habitID = model.habitID
        self.title = model.title
        self.symbolName = model.symbolName
        self.accentHue = model.accentHue
        self.orbitalMass = model.orbitalMass
        self.targetMinutesPerDay = model.targetMinutesPerDay
        self.completedMinutesToday = model.completedMinutesToday
        self.currentStreak = model.currentStreak
        self.longestStreak = model.longestStreak
        self.lastCompletedDayKey = model.lastCompletedDayKey
        self.sortOrder = model.sortOrder
        self.isArchived = model.isArchived
        self.updatedAt = model.updatedAt
        self.revision = model.revision
    }

    public static var defaultSeeds: [HabitNodeDTO] {
        [
            HabitNodeDTO(
                habitID: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
                title: "Deep Systems Architecture",
                symbolName: "cpu.fill",
                accentHue: 0.54,
                orbitalMass: 1.35,
                targetMinutesPerDay: 60,
                sortOrder: 0
            ),
            HabitNodeDTO(
                habitID: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
                title: "Mathematical DSP & Audio",
                symbolName: "waveform.path.ecg",
                accentHue: 0.76,
                orbitalMass: 1.20,
                targetMinutesPerDay: 45,
                sortOrder: 1
            ),
            HabitNodeDTO(
                habitID: UUID(uuidString: "20000000-0000-0000-0000-000000000003")!,
                title: "Spatial Graphics & Shaders",
                symbolName: "sparkles",
                accentHue: 0.12,
                orbitalMass: 1.10,
                targetMinutesPerDay: 45,
                sortOrder: 2
            )
        ]
    }
}

public struct AudioPresetDTO: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID { presetID }
    public let presetID: UUID
    public let name: String
    public let category: FocusCategory
    public let carrierFrequencyHz: Double
    public let binauralBeatHz: Double
    public let binauralMix: Double
    public let pinkNoiseMix: Double
    public let padMix: Double
    public let filterCutoffHz: Double
    public let filterResonance: Double
    public let padDetuneCents: Double
    public let masterGain: Double
    public let isBuiltIn: Bool
    public let updatedAt: Date
    public let revision: Int

    public init(
        presetID: UUID = UUID(),
        name: String,
        category: FocusCategory,
        carrierFrequencyHz: Double,
        binauralBeatHz: Double,
        binauralMix: Double,
        pinkNoiseMix: Double,
        padMix: Double,
        filterCutoffHz: Double,
        filterResonance: Double,
        padDetuneCents: Double,
        masterGain: Double,
        isBuiltIn: Bool = false,
        updatedAt: Date = .now,
        revision: Int = 1
    ) {
        self.presetID = presetID
        self.name = name
        self.category = category
        self.carrierFrequencyHz = carrierFrequencyHz
        self.binauralBeatHz = binauralBeatHz
        self.binauralMix = binauralMix
        self.pinkNoiseMix = pinkNoiseMix
        self.padMix = padMix
        self.filterCutoffHz = filterCutoffHz
        self.filterResonance = filterResonance
        self.padDetuneCents = padDetuneCents
        self.masterGain = masterGain
        self.isBuiltIn = isBuiltIn
        self.updatedAt = updatedAt
        self.revision = revision
    }

    public init(model: AudioPreset) {
        self.presetID = model.presetID
        self.name = model.name
        self.category = model.category
        self.carrierFrequencyHz = model.carrierFrequencyHz
        self.binauralBeatHz = model.binauralBeatHz
        self.binauralMix = model.binauralMix
        self.pinkNoiseMix = model.pinkNoiseMix
        self.padMix = model.padMix
        self.filterCutoffHz = model.filterCutoffHz
        self.filterResonance = model.filterResonance
        self.padDetuneCents = model.padDetuneCents
        self.masterGain = model.masterGain
        self.isBuiltIn = model.isBuiltIn
        self.updatedAt = model.updatedAt
        self.revision = model.revision
    }

    public static var defaultPresets: [AudioPresetDTO] {
        [
            AudioPresetDTO(
                presetID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
                name: "Nebula Deep Work",
                category: .deepWork,
                carrierFrequencyHz: 216.0,
                binauralBeatHz: 14.0,
                binauralMix: 0.42,
                pinkNoiseMix: 0.24,
                padMix: 0.56,
                filterCutoffHz: 1180.0,
                filterResonance: 0.34,
                padDetuneCents: 9.5,
                masterGain: 0.72,
                isBuiltIn: true
            ),
            AudioPresetDTO(
                presetID: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
                name: "Solaris Alpha Flow",
                category: .alphaFlow,
                carrierFrequencyHz: 196.0,
                binauralBeatHz: 10.0,
                binauralMix: 0.38,
                pinkNoiseMix: 0.18,
                padMix: 0.65,
                filterCutoffHz: 1650.0,
                filterResonance: 0.28,
                padDetuneCents: 12.0,
                masterGain: 0.70,
                isBuiltIn: true
            ),
            AudioPresetDTO(
                presetID: UUID(uuidString: "10000000-0000-0000-0000-000000000003")!,
                name: "Void Theta Drift",
                category: .thetaMeditation,
                carrierFrequencyHz: 144.0,
                binauralBeatHz: 5.5,
                binauralMix: 0.48,
                pinkNoiseMix: 0.15,
                padMix: 0.72,
                filterCutoffHz: 680.0,
                filterResonance: 0.45,
                padDetuneCents: 14.5,
                masterGain: 0.68,
                isBuiltIn: true
            ),
            AudioPresetDTO(
                presetID: UUID(uuidString: "10000000-0000-0000-0000-000000000004")!,
                name: "Hyperion Gamma 40Hz",
                category: .gammaCognition,
                carrierFrequencyHz: 256.0,
                binauralBeatHz: 40.0,
                binauralMix: 0.45,
                pinkNoiseMix: 0.28,
                padMix: 0.44,
                filterCutoffHz: 2450.0,
                filterResonance: 0.30,
                padDetuneCents: 7.0,
                masterGain: 0.66,
                isBuiltIn: true
            ),
            AudioPresetDTO(
                presetID: UUID(uuidString: "10000000-0000-0000-0000-000000000005")!,
                name: "Cryo Delta Horizon",
                category: .deltaRecovery,
                carrierFrequencyHz: 128.0,
                binauralBeatHz: 2.5,
                binauralMix: 0.36,
                pinkNoiseMix: 0.32,
                padMix: 0.62,
                filterCutoffHz: 460.0,
                filterResonance: 0.40,
                padDetuneCents: 16.0,
                masterGain: 0.65,
                isBuiltIn: true
            )
        ]
    }
}

public struct DailyTelemetryDTO: Codable, Sendable, Identifiable, Equatable {
    public var id: String { dayKey }
    public let dayKey: String
    public let dateStartOfDay: Date
    public let totalFocusSeconds: Double
    public let completedSessionCount: Int
    public let abortedSessionCount: Int
    public let habitsCompletedCount: Int
    public let averageQualityScore: Double
    public let intensityLevel: Int
    public let dominantBeatHz: Double
    public let updatedAt: Date
    public let revision: Int

    public init(
        dayKey: String,
        dateStartOfDay: Date,
        totalFocusSeconds: Double,
        completedSessionCount: Int,
        abortedSessionCount: Int,
        habitsCompletedCount: Int,
        averageQualityScore: Double,
        intensityLevel: Int,
        dominantBeatHz: Double,
        updatedAt: Date = .now,
        revision: Int = 1
    ) {
        self.dayKey = dayKey
        self.dateStartOfDay = dateStartOfDay
        self.totalFocusSeconds = totalFocusSeconds
        self.completedSessionCount = completedSessionCount
        self.abortedSessionCount = abortedSessionCount
        self.habitsCompletedCount = habitsCompletedCount
        self.averageQualityScore = averageQualityScore
        self.intensityLevel = intensityLevel
        self.dominantBeatHz = dominantBeatHz
        self.updatedAt = updatedAt
        self.revision = revision
    }

    public init(model: DailyTelemetry) {
        self.dayKey = model.dayKey
        self.dateStartOfDay = model.dateStartOfDay
        self.totalFocusSeconds = model.totalFocusSeconds
        self.completedSessionCount = model.completedSessionCount
        self.abortedSessionCount = model.abortedSessionCount
        self.habitsCompletedCount = model.habitsCompletedCount
        self.averageQualityScore = model.averageQualityScore
        self.intensityLevel = model.intensityLevel
        self.dominantBeatHz = model.dominantBeatHz
        self.updatedAt = model.updatedAt
        self.revision = model.revision
    }
}

// MARK: - App Group Aware Persistence Schema Factory

public enum AetherPersistenceSchema {
    public static let appGroupIdentifier = "group.com.aethersynth.flow"

    public static var schema: Schema {
        Schema([
            FocusSession.self,
            HabitNode.self,
            AudioPreset.self,
            DailyTelemetry.self
        ])
    }

    public static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let config: ModelConfiguration
        if inMemory {
            config = ModelConfiguration(
                "AetherSynthStore-\(UUID().uuidString)",
                schema: schema,
                isStoredInMemoryOnly: true,
                allowsSave: true
            )
        } else if let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) {
            let storeDir = groupURL.appendingPathComponent("Library/Application Support", isDirectory: true)
            try? FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
            let storeURL = storeDir.appendingPathComponent("AetherSynthStore.store")
            config = ModelConfiguration(
                "AetherSynthStore",
                schema: schema,
                url: storeURL,
                allowsSave: true
            )
        } else {
            config = ModelConfiguration(
                "AetherSynthStore",
                schema: schema,
                isStoredInMemoryOnly: false,
                allowsSave: true
            )
        }
        return try ModelContainer(for: schema, configurations: [config])
    }
}
