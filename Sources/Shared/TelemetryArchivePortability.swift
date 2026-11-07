// MARK: - FILE: TelemetryArchivePortability.swift

import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Zero-Dependency Verified Archive Payload (JSON + Integrity Hash)

public enum ArchivePortabilityError: LocalizedError, Sendable, Equatable {
    case unsupportedSchemaVersion(Int)
    case integrityHashMismatch(expected: String, actual: String)
    case malformedUTF8Payload

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let ver):
            return "Unsupported archive schema version \(ver)."
        case .integrityHashMismatch(let expected, let actual):
            return "Archive checksum mismatch (expected \(expected), got \(actual))."
        case .malformedUTF8Payload:
            return "Unable to decode UTF-8 archive stream."
        }
    }
}

public struct AetherTelemetryArchive: Codable, Sendable, Equatable {
    public static let currentSchemaVersion: Int = 1

    public let schemaVersion: Int
    public let exportedAt: Date
    public let habits: [HabitNodeDTO]
    public let presets: [AudioPresetDTO]
    public let sessions: [FocusSessionDTO]
    public let dailyTelemetry: [DailyTelemetryDTO]
    public let integrityHashHex: String

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        exportedAt: Date = .now,
        habits: [HabitNodeDTO],
        presets: [AudioPresetDTO],
        sessions: [FocusSessionDTO],
        dailyTelemetry: [DailyTelemetryDTO]
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.habits = habits
        self.presets = presets
        self.sessions = sessions
        self.dailyTelemetry = dailyTelemetry
        self.integrityHashHex = Self.computeIntegrityHash(
            schemaVersion: schemaVersion,
            habits: habits,
            presets: presets,
            sessions: sessions,
            dailyTelemetry: dailyTelemetry
        )
    }

    public func validateIntegrity() throws {
        guard schemaVersion <= Self.currentSchemaVersion else {
            throw ArchivePortabilityError.unsupportedSchemaVersion(schemaVersion)
        }
        let recomputed = Self.computeIntegrityHash(
            schemaVersion: schemaVersion,
            habits: habits,
            presets: presets,
            sessions: sessions,
            dailyTelemetry: dailyTelemetry
        )
        guard recomputed == integrityHashHex else {
            throw ArchivePortabilityError.integrityHashMismatch(expected: integrityHashHex, actual: recomputed)
        }
    }

    /// Deterministic 64-bit FNV-1a digest across canonical entity fields
    public static func computeIntegrityHash(
        schemaVersion: Int,
        habits: [HabitNodeDTO],
        presets: [AudioPresetDTO],
        sessions: [FocusSessionDTO],
        dailyTelemetry: [DailyTelemetryDTO]
    ) -> String {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        let prime: UInt64 = 0x0000_0100_0000_01B3

        func mix(_ text: String) {
            for byte in text.utf8 {
                hash ^= UInt64(byte)
                hash &*= prime
            }
            hash ^= 0xFF
            hash &*= prime
        }

        mix("v:\(schemaVersion)|h:\(habits.count)|p:\(presets.count)|s:\(sessions.count)|t:\(dailyTelemetry.count)")
        for h in habits.sorted(by: { $0.habitID.uuidString < $1.habitID.uuidString }) {
            mix("\(h.habitID.uuidString):\(h.title):\(h.targetMinutesPerDay):\(h.revision)")
        }
        for p in presets.sorted(by: { $0.presetID.uuidString < $1.presetID.uuidString }) {
            mix("\(p.presetID.uuidString):\(p.name):\(Int(p.binauralBeatHz * 100)):\(p.revision)")
        }
        for s in sessions.sorted(by: { $0.sessionID.uuidString < $1.sessionID.uuidString }) {
            mix("\(s.sessionID.uuidString):\(Int(s.actualDurationSeconds)):\(s.completed):\(s.revision)")
        }
        for d in dailyTelemetry.sorted(by: { $0.dayKey < $1.dayKey }) {
            mix("\(d.dayKey):\(Int(d.totalFocusSeconds)):\(d.completedSessionCount):\(d.revision)")
        }

        return String(format: "%016llx", hash)
    }

    public func encodePrettyJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decodeAndValidate(from data: Data) throws -> AetherTelemetryArchive {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AetherTelemetryArchive.self, from: data)
        try decoded.validateIntegrity()
        return decoded
    }
}

// MARK: - RFC-4180 CSV Ledger Serializer

public enum TelemetryCSVSerializer: Sendable {
    public static func makeSessionsCSV(from sessions: [FocusSessionDTO]) -> String {
        var lines: [String] = [
            "session_id,title,started_at_iso8601,ended_at_iso8601,planned_seconds,actual_seconds,completed,quality_score,carrier_hz,beat_hz,linked_habit_id,notes"
        ]
        lines.reserveCapacity(sessions.count + 1)
        let formatter = ISO8601DateFormatter()

        for s in sessions.sorted(by: { $0.startedAt < $1.startedAt }) {
            let row = [
                s.sessionID.uuidString,
                escapeCSV(s.title),
                formatter.string(from: s.startedAt),
                formatter.string(from: s.endedAt),
                String(format: "%.1f", s.plannedDurationSeconds),
                String(format: "%.1f", s.actualDurationSeconds),
                s.completed ? "true" : "false",
                String(format: "%.4f", s.focusQualityScore),
                String(format: "%.2f", s.carrierFrequencyHz),
                String(format: "%.2f", s.beatFrequencyHz),
                s.linkedHabitID?.uuidString ?? "",
                escapeCSV(s.notes)
            ].joined(separator: ",")
            lines.append(row)
        }
        return lines.joined(separator: "\r\n")
    }

    private static func escapeCSV(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
            let doubled = value.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(doubled)\""
        }
        return value
    }
}

// MARK: - SwiftUI FileDocument & Transferable Wrappers

public struct AetherArchiveDocument: FileDocument, Sendable {
    public static let readableContentTypes: [UTType] = [.json]

    public var jsonData: Data

    public init(archive: AetherTelemetryArchive) throws {
        self.jsonData = try archive.encodePrettyJSON()
    }

    public init(jsonData: Data = Data()) {
        self.jsonData = jsonData
    }

    public init(configuration: ReadConfiguration) throws {
        self.jsonData = configuration.file.regularFileContents ?? Data()
    }

    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: jsonData)
    }
}

public struct AetherCSVDocument: FileDocument, Sendable {
    public static let readableContentTypes: [UTType] = [.commaSeparatedText]

    public var csvString: String

    public init(csvString: String = "") {
        self.csvString = csvString
    }

    public init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let decoded = String(data: data, encoding: .utf8) else {
            throw ArchivePortabilityError.malformedUTF8Payload
        }
        self.csvString = decoded
    }

    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard let encoded = csvString.data(using: .utf8) else {
            throw ArchivePortabilityError.malformedUTF8Payload
        }
        return FileWrapper(regularFileWithContents: encoded)
    }
}
