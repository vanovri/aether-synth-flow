// MARK: - FILE: TelemetryDatabaseActor.swift

import Foundation
import SwiftData

@ModelActor
public actor TelemetryDatabaseActor {

    // MARK: - Bootstrap & Default Seeding

    public func bootstrapDefaultsIfNeeded(referenceDate: Date = .now) throws {
        modelContext.autosaveEnabled = false

        let presetCount = try modelContext.fetchCount(FetchDescriptor<AudioPreset>())
        if presetCount == 0 {
            for dto in AudioPresetDTO.defaultPresets {
                let model = AudioPreset(
                    presetID: dto.presetID,
                    name: dto.name,
                    category: dto.category,
                    carrierFrequencyHz: dto.carrierFrequencyHz,
                    binauralBeatHz: dto.binauralBeatHz,
                    binauralMix: dto.binauralMix,
                    pinkNoiseMix: dto.pinkNoiseMix,
                    padMix: dto.padMix,
                    filterCutoffHz: dto.filterCutoffHz,
                    filterResonance: dto.filterResonance,
                    padDetuneCents: dto.padDetuneCents,
                    masterGain: dto.masterGain,
                    isBuiltIn: true,
                    updatedAt: referenceDate,
                    revision: 1
                )
                modelContext.insert(model)
            }
        }

        let habitCount = try modelContext.fetchCount(FetchDescriptor<HabitNode>())
        if habitCount == 0 {
            let starterHabits: [HabitNode] = [
                HabitNode(
                    title: "Systems Architecture",
                    symbolName: "cpu.fill",
                    accentHue: 0.54,
                    orbitalMass: 1.85,
                    targetMinutesPerDay: 60,
                    completedMinutesToday: 25,
                    currentStreak: 6,
                    longestStreak: 14,
                    sortOrder: 0
                ),
                HabitNode(
                    title: "Shader & Math Study",
                    symbolName: "sparkles.rectangle.stack.fill",
                    accentHue: 0.78,
                    orbitalMass: 1.45,
                    targetMinutesPerDay: 45,
                    completedMinutesToday: 15,
                    currentStreak: 4,
                    longestStreak: 11,
                    sortOrder: 1
                ),
                HabitNode(
                    title: "Breathwork & Stillness",
                    symbolName: "wind.circle.fill",
                    accentHue: 0.42,
                    orbitalMass: 1.10,
                    targetMinutesPerDay: 20,
                    completedMinutesToday: 20,
                    currentStreak: 12,
                    longestStreak: 21,
                    sortOrder: 2
                ),
                HabitNode(
                    title: "Deep Reading",
                    symbolName: "book.closed.fill",
                    accentHue: 0.09,
                    orbitalMass: 1.25,
                    targetMinutesPerDay: 30,
                    completedMinutesToday: 0,
                    currentStreak: 3,
                    longestStreak: 9,
                    sortOrder: 3
                ),
                HabitNode(
                    title: "Acoustic Synthesis",
                    symbolName: "waveform.path.ecg",
                    accentHue: 0.90,
                    orbitalMass: 1.60,
                    targetMinutesPerDay: 40,
                    completedMinutesToday: 10,
                    currentStreak: 5,
                    longestStreak: 8,
                    sortOrder: 4
                )
            ]
            for habit in starterHabits {
                modelContext.insert(habit)
            }
        }

        let telemetryCount = try modelContext.fetchCount(FetchDescriptor<DailyTelemetry>())
        if telemetryCount == 0 {
            try seedBaselineYearTelemetry(endingAt: referenceDate)
        }

        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    private func seedBaselineYearTelemetry(endingAt referenceDate: Date) throws {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: referenceDate)
        var rngState: UInt64 = 0xA37F_9E12_4BC0_88D1

        for offset in stride(from: -180, through: -1, by: 1) {
            guard let dayDate = calendar.date(byAdding: .day, value: offset, to: todayStart) else { continue }
            rngState &+= 0x9E37_79B9_7F4A_7C15
            var z = rngState
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z = z ^ (z >> 31)

            let normalized = Double(z % 1000) / 1000.0
            let weekday = calendar.component(.weekday, from: dayDate)
            let weekendFactor = (weekday == 1 || weekday == 7) ? 0.62 : 1.0
            let activeProbability = 0.72 * weekendFactor

            guard normalized < activeProbability else { continue }

            let focusMinutes = floor((18.0 + pow(normalized / activeProbability, 1.45) * 125.0) * weekendFactor)
            let focusSeconds = focusMinutes * 60.0
            let sessions = max(1, Int((focusMinutes / 32.0).rounded()))
            let habitsHit = min(5, max(1, Int((focusMinutes / 25.0).rounded())))
            let quality = min(0.98, 0.70 + (normalized * 0.28))
            let key = DayKeyFormatter.dayKey(for: dayDate, calendar: calendar)
            let bucket = DayKeyFormatter.intensityBucket(forFocusSeconds: focusSeconds)

            let record = DailyTelemetry(
                dayKey: key,
                dateStartOfDay: dayDate,
                totalFocusSeconds: focusSeconds,
                completedSessionCount: sessions,
                abortedSessionCount: normalized > 0.58 ? 1 : 0,
                habitsCompletedCount: habitsHit,
                averageQualityScore: quality,
                intensityLevel: bucket,
                dominantBeatHz: (offset % 3 == 0) ? 14.0 : 10.0,
                updatedAt: dayDate,
                revision: 1
            )
            modelContext.insert(record)
        }
    }

    // MARK: - Batch Session Ingestion with Conflict Resolution

    public func batchIngestSessions(
        _ incomingBatch: [FocusSessionDTO],
        conflictPolicy: ConflictResolutionPolicy = .higherRevisionWins,
        chunkSize: Int = 64
    ) throws -> BatchIngestReport {
        modelContext.autosaveEnabled = false
        guard !incomingBatch.isEmpty else {
            return BatchIngestReport(
                insertedSessions: 0,
                updatedSessions: 0,
                skippedSessions: 0,
                affectedTelemetryDays: 0,
                updatedHabits: 0
            )
        }

        var inserted = 0
        var updated = 0
        var skipped = 0
        var dirtyDayKeys = Set<String>()
        var dirtyHabitIDs = Set<UUID>()
        let safeChunk = max(1, chunkSize)

        var startIndex = 0
        while startIndex < incomingBatch.count {
            let endIndex = min(startIndex + safeChunk, incomingBatch.count)
            let slice = incomingBatch[startIndex..<endIndex]

            for dto in slice {
                let targetID = dto.sessionID
                let existingDescriptor = FetchDescriptor<FocusSession>(
                    predicate: #Predicate<FocusSession> { session in
                        session.sessionID == targetID
                    }
                )
                let existing = try modelContext.fetch(existingDescriptor).first
                let linkedHabit = try fetchHabitModel(by: dto.linkedHabitID)

                if let existing {
                    let shouldApply = shouldOverwriteSession(
                        existing: existing,
                        incoming: dto,
                        policy: conflictPolicy
                    )

                    if shouldApply {
                        let oldDayKey = DayKeyFormatter.dayKey(for: existing.startedAt)
                        dirtyDayKeys.insert(oldDayKey)

                        if conflictPolicy == .mergeAccumulate {
                            existing.actualDurationSeconds += dto.actualDurationSeconds
                            existing.plannedDurationSeconds = max(existing.plannedDurationSeconds, dto.plannedDurationSeconds)
                            existing.completed = existing.completed || dto.completed
                            existing.focusQualityScore = (existing.focusQualityScore + dto.focusQualityScore) * 0.5
                            existing.peakAmplitude = max(existing.peakAmplitude, dto.peakAmplitude)
                            existing.endedAt = max(existing.endedAt, dto.endedAt)
                            existing.updatedAt = max(existing.updatedAt, dto.updatedAt)
                            existing.revision = max(existing.revision, dto.revision) + 1
                            if !dto.notes.isEmpty && existing.notes != dto.notes {
                                existing.notes = existing.notes.isEmpty ? dto.notes : "\(existing.notes)\n\(dto.notes)"
                            }
                        } else {
                            existing.title = dto.title
                            existing.startedAt = dto.startedAt
                            existing.endedAt = dto.endedAt
                            existing.plannedDurationSeconds = dto.plannedDurationSeconds
                            existing.actualDurationSeconds = dto.actualDurationSeconds
                            existing.completed = dto.completed
                            existing.focusQualityScore = dto.focusQualityScore
                            existing.peakAmplitude = dto.peakAmplitude
                            existing.carrierFrequencyHz = dto.carrierFrequencyHz
                            existing.beatFrequencyHz = dto.beatFrequencyHz
                            existing.linkedHabitID = dto.linkedHabitID
                            existing.notes = dto.notes
                            existing.updatedAt = dto.updatedAt
                            existing.revision = max(existing.revision + 1, dto.revision)
                        }

                        existing.habitNode = linkedHabit
                        updated += 1
                        dirtyDayKeys.insert(DayKeyFormatter.dayKey(for: existing.startedAt))
                        if let hid = existing.linkedHabitID {
                            dirtyHabitIDs.insert(hid)
                        }
                    } else {
                        skipped += 1
                    }
                } else {
                    let model = FocusSession(
                        sessionID: dto.sessionID,
                        title: dto.title,
                        startedAt: dto.startedAt,
                        endedAt: dto.endedAt,
                        plannedDurationSeconds: dto.plannedDurationSeconds,
                        actualDurationSeconds: dto.actualDurationSeconds,
                        completed: dto.completed,
                        focusQualityScore: dto.focusQualityScore,
                        peakAmplitude: dto.peakAmplitude,
                        carrierFrequencyHz: dto.carrierFrequencyHz,
                        beatFrequencyHz: dto.beatFrequencyHz,
                        linkedHabitID: dto.linkedHabitID,
                        notes: dto.notes,
                        updatedAt: dto.updatedAt,
                        revision: dto.revision,
                        habitNode: linkedHabit
                    )
                    modelContext.insert(model)
                    inserted += 1
                    dirtyDayKeys.insert(DayKeyFormatter.dayKey(for: dto.startedAt))
                    if let hid = dto.linkedHabitID {
                        dirtyHabitIDs.insert(hid)
                    }
                }
            }

            try modelContext.save()
            startIndex = endIndex
        }

        for habitID in dirtyHabitIDs {
            try recalculateHabitProgressAndStreak(habitID: habitID, referenceDate: .now)
        }

        for dayKey in dirtyDayKeys {
            try rebuildDailyTelemetry(forDayKey: dayKey)
        }

        if modelContext.hasChanges {
            try modelContext.save()
        }

        return BatchIngestReport(
            insertedSessions: inserted,
            updatedSessions: updated,
            skippedSessions: skipped,
            affectedTelemetryDays: dirtyDayKeys.count,
            updatedHabits: dirtyHabitIDs.count
        )
    }

    private func shouldOverwriteSession(
        existing: FocusSession,
        incoming: FocusSessionDTO,
        policy: ConflictResolutionPolicy
    ) -> Bool {
        switch policy {
        case .keepExisting:
            return false
        case .newerTimestampWins:
            return incoming.updatedAt >= existing.updatedAt
        case .higherRevisionWins:
            if incoming.revision != existing.revision {
                return incoming.revision > existing.revision
            }
            return incoming.updatedAt >= existing.updatedAt
        case .mergeAccumulate:
            return true
        }
    }

    // MARK: - Direct Telemetry Upsert with Conflict Resolution

    public func batchUpsertTelemetry(
        _ records: [DailyTelemetryDTO],
        policy: ConflictResolutionPolicy = .mergeAccumulate
    ) throws -> Int {
        modelContext.autosaveEnabled = false
        var mutatedCount = 0

        for dto in records {
            let key = dto.dayKey
            let descriptor = FetchDescriptor<DailyTelemetry>(
                predicate: #Predicate<DailyTelemetry> { item in
                    item.dayKey == key
                }
            )

            if let existing = try modelContext.fetch(descriptor).first {
                switch policy {
                case .keepExisting:
                    continue
                case .newerTimestampWins:
                    guard dto.updatedAt >= existing.updatedAt else { continue }
                    applyTelemetryOverwrite(existing: existing, from: dto)
                    mutatedCount += 1
                case .higherRevisionWins:
                    guard dto.revision > existing.revision ||
                          (dto.revision == existing.revision && dto.updatedAt >= existing.updatedAt) else { continue }
                    applyTelemetryOverwrite(existing: existing, from: dto)
                    mutatedCount += 1
                case .mergeAccumulate:
                    let totalSessionsBefore = Double(max(1, existing.completedSessionCount + existing.abortedSessionCount))
                    let totalSessionsIncoming = Double(max(1, dto.completedSessionCount + dto.abortedSessionCount))
                    let combinedWeight = totalSessionsBefore + totalSessionsIncoming

                    existing.totalFocusSeconds += dto.totalFocusSeconds
                    existing.completedSessionCount += dto.completedSessionCount
                    existing.abortedSessionCount += dto.abortedSessionCount
                    existing.habitsCompletedCount = max(existing.habitsCompletedCount, dto.habitsCompletedCount)
                    existing.averageQualityScore = (
                        existing.averageQualityScore * totalSessionsBefore +
                        dto.averageQualityScore * totalSessionsIncoming
                    ) / combinedWeight
                    existing.intensityLevel = DayKeyFormatter.intensityBucket(
                        forFocusSeconds: existing.totalFocusSeconds
                    )
                    existing.dominantBeatHz = dto.dominantBeatHz
                    existing.updatedAt = max(existing.updatedAt, dto.updatedAt)
                    existing.revision += 1
                    mutatedCount += 1
                }
            } else {
                let model = DailyTelemetry(
                    dayKey: dto.dayKey,
                    dateStartOfDay: dto.dateStartOfDay,
                    totalFocusSeconds: dto.totalFocusSeconds,
                    completedSessionCount: dto.completedSessionCount,
                    abortedSessionCount: dto.abortedSessionCount,
                    habitsCompletedCount: dto.habitsCompletedCount,
                    averageQualityScore: dto.averageQualityScore,
                    intensityLevel: DayKeyFormatter.intensityBucket(forFocusSeconds: dto.totalFocusSeconds),
                    dominantBeatHz: dto.dominantBeatHz,
                    updatedAt: dto.updatedAt,
                    revision: dto.revision
                )
                modelContext.insert(model)
                mutatedCount += 1
            }
        }

        if modelContext.hasChanges {
            try modelContext.save()
        }
        return mutatedCount
    }

    private func applyTelemetryOverwrite(existing: DailyTelemetry, from dto: DailyTelemetryDTO) {
        existing.dateStartOfDay = dto.dateStartOfDay
        existing.totalFocusSeconds = dto.totalFocusSeconds
        existing.completedSessionCount = dto.completedSessionCount
        existing.abortedSessionCount = dto.abortedSessionCount
        existing.habitsCompletedCount = dto.habitsCompletedCount
        existing.averageQualityScore = dto.averageQualityScore
        existing.intensityLevel = DayKeyFormatter.intensityBucket(forFocusSeconds: dto.totalFocusSeconds)
        existing.dominantBeatHz = dto.dominantBeatHz
        existing.updatedAt = dto.updatedAt
        existing.revision = max(existing.revision + 1, dto.revision)
    }

    // MARK: - Habit CRUD & Streak Mechanics

    public func upsertHabit(_ dto: HabitNodeDTO) throws -> HabitNodeDTO {
        modelContext.autosaveEnabled = false
        let targetID = dto.habitID
        let descriptor = FetchDescriptor<HabitNode>(
            predicate: #Predicate<HabitNode> { node in
                node.habitID == targetID
            }
        )

        let model: HabitNode
        if let existing = try modelContext.fetch(descriptor).first {
            existing.title = dto.title
            existing.symbolName = dto.symbolName
            existing.accentHue = dto.accentHue
            existing.orbitalMass = min(max(dto.orbitalMass, 0.5), 2.5)
            existing.targetMinutesPerDay = max(5, dto.targetMinutesPerDay)
            existing.completedMinutesToday = max(0, dto.completedMinutesToday)
            existing.currentStreak = max(0, dto.currentStreak)
            existing.longestStreak = max(existing.longestStreak, dto.longestStreak)
            existing.lastCompletedDayKey = dto.lastCompletedDayKey
            existing.sortOrder = dto.sortOrder
            existing.isArchived = dto.isArchived
            existing.updatedAt = .now
            existing.revision += 1
            model = existing
        } else {
            let created = HabitNode(
                habitID: dto.habitID,
                title: dto.title,
                symbolName: dto.symbolName,
                accentHue: dto.accentHue,
                orbitalMass: dto.orbitalMass,
                targetMinutesPerDay: dto.targetMinutesPerDay,
                completedMinutesToday: dto.completedMinutesToday,
                currentStreak: dto.currentStreak,
                longestStreak: dto.longestStreak,
                lastCompletedDayKey: dto.lastCompletedDayKey,
                sortOrder: dto.sortOrder,
                isArchived: dto.isArchived,
                updatedAt: .now,
                revision: dto.revision
            )
            modelContext.insert(created)
            model = created
        }

        try modelContext.save()
        return HabitNodeDTO(model: model)
    }

    public func logQuickHabitPulse(habitID: UUID?, addedMinutes: Int, timestamp: Date = .now) throws -> HabitNodeDTO? {
        modelContext.autosaveEnabled = false
        let resolvedHabit: HabitNode?
        if let habitID {
            resolvedHabit = try fetchHabitModel(by: habitID)
        } else {
            let firstDescriptor = FetchDescriptor<HabitNode>(
                predicate: #Predicate<HabitNode> { h in h.isArchived == false },
                sortBy: [SortDescriptor(\HabitNode.sortOrder, order: .forward)]
            )
            resolvedHabit = try modelContext.fetch(firstDescriptor).first
        }
        guard let habit = resolvedHabit else { return nil }

        let todayKey = DayKeyFormatter.dayKey(for: timestamp)
        let yesterdayDate = Calendar.current.date(byAdding: .day, value: -1, to: timestamp) ?? timestamp
        let yesterdayKey = DayKeyFormatter.dayKey(for: yesterdayDate)

        habit.completedMinutesToday = max(0, habit.completedMinutesToday + addedMinutes)
        if habit.completedMinutesToday >= habit.targetMinutesPerDay && habit.lastCompletedDayKey != todayKey {
            if habit.lastCompletedDayKey == yesterdayKey {
                habit.currentStreak += 1
            } else if habit.lastCompletedDayKey == nil {
                habit.currentStreak = max(1, habit.currentStreak + 1)
            } else {
                habit.currentStreak = 1
            }
            habit.longestStreak = max(habit.longestStreak, habit.currentStreak)
            habit.lastCompletedDayKey = todayKey
        }
        habit.updatedAt = timestamp
        habit.revision += 1

        let session = FocusSession(
            title: "\(habit.title) Pulse",
            startedAt: timestamp.addingTimeInterval(-Double(addedMinutes * 60)),
            endedAt: timestamp,
            plannedDurationSeconds: Double(addedMinutes * 60),
            actualDurationSeconds: Double(addedMinutes * 60),
            completed: true,
            focusQualityScore: 0.92,
            peakAmplitude: 0.65,
            carrierFrequencyHz: 216.0,
            beatFrequencyHz: 12.0,
            linkedHabitID: habit.habitID,
            notes: "Quick orbital check-in",
            updatedAt: timestamp,
            revision: 1,
            habitNode: habit
        )
        modelContext.insert(session)

        try rebuildDailyTelemetry(forDayKey: todayKey)
        try modelContext.save()
        return HabitNodeDTO(model: habit)
    }

    public func deleteHabit(habitID: UUID) throws {
        modelContext.autosaveEnabled = false
        guard let habit = try fetchHabitModel(by: habitID) else { return }
        modelContext.delete(habit)
        try modelContext.save()
    }

    // MARK: - Audio Preset CRUD

    public func upsertAudioPreset(_ dto: AudioPresetDTO) throws -> AudioPresetDTO {
        modelContext.autosaveEnabled = false
        let targetID = dto.presetID
        let descriptor = FetchDescriptor<AudioPreset>(
            predicate: #Predicate<AudioPreset> { p in
                p.presetID == targetID
            }
        )

        let model: AudioPreset
        if let existing = try modelContext.fetch(descriptor).first {
            existing.name = dto.name
            existing.category = dto.category
            existing.carrierFrequencyHz = dto.carrierFrequencyHz
            existing.binauralBeatHz = dto.binauralBeatHz
            existing.binauralMix = dto.binauralMix
            existing.pinkNoiseMix = dto.pinkNoiseMix
            existing.padMix = dto.padMix
            existing.filterCutoffHz = dto.filterCutoffHz
            existing.filterResonance = dto.filterResonance
            existing.padDetuneCents = dto.padDetuneCents
            existing.masterGain = dto.masterGain
            existing.updatedAt = .now
            existing.revision += 1
            model = existing
        } else {
            let created = AudioPreset(
                presetID: dto.presetID,
                name: dto.name,
                category: dto.category,
                carrierFrequencyHz: dto.carrierFrequencyHz,
                binauralBeatHz: dto.binauralBeatHz,
                binauralMix: dto.binauralMix,
                pinkNoiseMix: dto.pinkNoiseMix,
                padMix: dto.padMix,
                filterCutoffHz: dto.filterCutoffHz,
                filterResonance: dto.filterResonance,
                padDetuneCents: dto.padDetuneCents,
                masterGain: dto.masterGain,
                isBuiltIn: dto.isBuiltIn,
                updatedAt: .now,
                revision: dto.revision
            )
            modelContext.insert(created)
            model = created
        }

        try modelContext.save()
        return AudioPresetDTO(model: model)
    }

    public func fetchAllAudioPresets() throws -> [AudioPresetDTO] {
        let descriptor = FetchDescriptor<AudioPreset>(
            sortBy: [
                SortDescriptor(\AudioPreset.name, order: .forward)
            ]
        )
        return try modelContext.fetch(descriptor)
            .map(AudioPresetDTO.init(model:))
            .sorted { lhs, rhs in
                if lhs.isBuiltIn != rhs.isBuiltIn {
                    return lhs.isBuiltIn && !rhs.isBuiltIn
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    public func fetchActiveHabits() throws -> [HabitNodeDTO] {
        let descriptor = FetchDescriptor<HabitNode>(
            predicate: #Predicate<HabitNode> { node in node.isArchived == false },
            sortBy: [SortDescriptor(\HabitNode.sortOrder, order: .forward)]
        )
        return try modelContext.fetch(descriptor).map(HabitNodeDTO.init(model:))
    }

    public func fetchAllSessions() throws -> [FocusSessionDTO] {
        let descriptor = FetchDescriptor<FocusSession>(
            sortBy: [SortDescriptor(\FocusSession.startedAt, order: .forward)]
        )
        return try modelContext.fetch(descriptor).map(FocusSessionDTO.init(model:))
    }

    public func fetchAllTelemetry() throws -> [DailyTelemetryDTO] {
        let descriptor = FetchDescriptor<DailyTelemetry>(
            sortBy: [SortDescriptor(\DailyTelemetry.dayKey, order: .forward)]
        )
        return try modelContext.fetch(descriptor).map(DailyTelemetryDTO.init(model:))
    }

    // MARK: - Full Ledger Archive Export / Import & CSV Portability

    public func exportFullArchive(exportedAt: Date = .now) throws -> AetherTelemetryArchive {
        let habits = try modelContext.fetch(
            FetchDescriptor<HabitNode>(sortBy: [SortDescriptor(\HabitNode.sortOrder, order: .forward)])
        ).map(HabitNodeDTO.init(model:))

        let presets = try modelContext.fetch(
            FetchDescriptor<AudioPreset>(sortBy: [SortDescriptor(\AudioPreset.name, order: .forward)])
        ).map(AudioPresetDTO.init(model:))

        let sessions = try modelContext.fetch(
            FetchDescriptor<FocusSession>(sortBy: [SortDescriptor(\FocusSession.startedAt, order: .forward)])
        ).map(FocusSessionDTO.init(model:))

        let telemetry = try modelContext.fetch(
            FetchDescriptor<DailyTelemetry>(sortBy: [SortDescriptor(\DailyTelemetry.dayKey, order: .forward)])
        ).map(DailyTelemetryDTO.init(model:))

        return AetherTelemetryArchive(
            exportedAt: exportedAt,
            habits: habits,
            presets: presets,
            sessions: sessions,
            dailyTelemetry: telemetry
        )
    }

    public func exportSessionsCSV() throws -> String {
        let sessions = try modelContext.fetch(
            FetchDescriptor<FocusSession>(sortBy: [SortDescriptor(\FocusSession.startedAt, order: .forward)])
        ).map(FocusSessionDTO.init(model:))
        return TelemetryCSVSerializer.makeSessionsCSV(from: sessions)
    }

    public func importFullArchive(
        _ archive: AetherTelemetryArchive,
        conflictPolicy: ConflictResolutionPolicy = .higherRevisionWins
    ) throws -> ArchiveImportSummary {
        try archive.validateIntegrity()
        modelContext.autosaveEnabled = false

        var habitCount = 0
        for h in archive.habits {
            _ = try upsertHabit(h)
            habitCount += 1
        }

        var presetCount = 0
        for p in archive.presets {
            _ = try upsertAudioPreset(p)
            presetCount += 1
        }

        let sessionReport = try batchIngestSessions(archive.sessions, conflictPolicy: conflictPolicy)

        // Import standalone historical telemetry days that have no individual session rows
        let sessionDayKeys = Set(archive.sessions.map { DayKeyFormatter.dayKey(for: $0.startedAt) })
        let standaloneTelemetry = archive.dailyTelemetry.filter { !sessionDayKeys.contains($0.dayKey) }
        let telemetryUpserted = try batchUpsertTelemetry(standaloneTelemetry, policy: conflictPolicy)

        return ArchiveImportSummary(
            importedHabits: habitCount,
            importedPresets: presetCount,
            sessionReport: sessionReport,
            upsertedTelemetryDays: telemetryUpserted + sessionReport.affectedTelemetryDays
        )
    }

    // MARK: - Complex Predicate Queries

    public func fetchHighQualitySessions(
        from startDate: Date,
        to endDate: Date,
        minimumDurationSeconds: Double,
        minimumQuality: Double
    ) throws -> [FocusSessionDTO] {
        let descriptor = FetchDescriptor<FocusSession>(
            predicate: #Predicate<FocusSession> { session in
                session.completed == true &&
                session.startedAt >= startDate &&
                session.startedAt <= endDate &&
                session.actualDurationSeconds >= minimumDurationSeconds &&
                session.focusQualityScore >= minimumQuality
            },
            sortBy: [
                SortDescriptor(\FocusSession.focusQualityScore, order: .reverse),
                SortDescriptor(\FocusSession.startedAt, order: .reverse)
            ]
        )
        return try modelContext.fetch(descriptor).map(FocusSessionDTO.init(model:))
    }

    public func fetchTelemetryWindow(from startDate: Date, to endDate: Date) throws -> [DailyTelemetryDTO] {
        let lower = DayKeyFormatter.startOfDay(for: startDate)
        let upper = DayKeyFormatter.startOfDay(for: endDate)
        let descriptor = FetchDescriptor<DailyTelemetry>(
            predicate: #Predicate<DailyTelemetry> { entry in
                entry.dateStartOfDay >= lower && entry.dateStartOfDay <= upper
            },
            sortBy: [SortDescriptor(\DailyTelemetry.dateStartOfDay, order: .forward)]
        )
        return try modelContext.fetch(descriptor).map(DailyTelemetryDTO.init(model:))
    }

    public func fetchSessionsForDay(dayKey: String) throws -> [FocusSessionDTO] {
        guard let dayStart = DayKeyFormatter.date(from: dayKey),
              let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) else {
            return []
        }
        let descriptor = FetchDescriptor<FocusSession>(
            predicate: #Predicate<FocusSession> { session in
                session.startedAt >= dayStart && session.startedAt < dayEnd
            },
            sortBy: [SortDescriptor(\FocusSession.startedAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor).map(FocusSessionDTO.init(model:))
    }

    // MARK: - Internal Rollup Calculators

    private func fetchHabitModel(by id: UUID?) throws -> HabitNode? {
        guard let id else { return nil }
        let descriptor = FetchDescriptor<HabitNode>(
            predicate: #Predicate<HabitNode> { node in
                node.habitID == id
            }
        )
        return try modelContext.fetch(descriptor).first
    }

    private func recalculateHabitProgressAndStreak(habitID: UUID, referenceDate: Date) throws {
        guard let habit = try fetchHabitModel(by: habitID) else { return }
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: referenceDate)
        guard let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: todayStart) else { return }

        let targetHabitID: UUID? = habitID
        let allHabitSessionsDescriptor = FetchDescriptor<FocusSession>(
            predicate: #Predicate<FocusSession> { session in
                session.linkedHabitID == targetHabitID && session.completed == true
            },
            sortBy: [SortDescriptor(\FocusSession.startedAt, order: .forward)]
        )
        let sessions = try modelContext.fetch(allHabitSessionsDescriptor)

        var secondsByDay: [String: Double] = [:]
        var todaySeconds: Double = 0

        for s in sessions {
            let key = DayKeyFormatter.dayKey(for: s.startedAt, calendar: calendar)
            secondsByDay[key, default: 0] += s.actualDurationSeconds
            if s.startedAt >= todayStart && s.startedAt < tomorrowStart {
                todaySeconds += s.actualDurationSeconds
            }
        }

        habit.completedMinutesToday = Int((todaySeconds / 60.0).rounded())

        let targetSeconds = Double(habit.targetMinutesPerDay) * 60.0
        let qualifyingDays = secondsByDay
            .filter { $0.value >= targetSeconds }
            .keys
            .sorted()

        if let latestKey = qualifyingDays.last {
            habit.lastCompletedDayKey = latestKey
        }

        var longest = 0
        var running = 0
        var previousDate: Date?

        for key in qualifyingDays {
            guard let date = DayKeyFormatter.date(from: key, calendar: calendar) else { continue }
            if let prev = previousDate,
               let expectedNext = calendar.date(byAdding: .day, value: 1, to: prev),
               calendar.isDate(expectedNext, inSameDayAs: date) {
                running += 1
            } else {
                running = 1
            }
            longest = max(longest, running)
            previousDate = date
        }

        let todayKey = DayKeyFormatter.dayKey(for: todayStart, calendar: calendar)
        let yesterdayDate = calendar.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart
        let yesterdayKey = DayKeyFormatter.dayKey(for: yesterdayDate, calendar: calendar)

        if qualifyingDays.contains(todayKey) || qualifyingDays.contains(yesterdayKey) {
            var cursor = qualifyingDays.contains(todayKey) ? todayStart : yesterdayDate
            var activeStreak = 0
            let qualifyingSet = Set(qualifyingDays)
            while qualifyingSet.contains(DayKeyFormatter.dayKey(for: cursor, calendar: calendar)) {
                activeStreak += 1
                guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
                cursor = prev
            }
            habit.currentStreak = activeStreak
        } else {
            habit.currentStreak = 0
        }

        habit.longestStreak = max(habit.longestStreak, longest)
        habit.updatedAt = referenceDate
        habit.revision += 1
    }

    private func rebuildDailyTelemetry(forDayKey dayKey: String) throws {
        let calendar = Calendar.current
        guard let dayStart = DayKeyFormatter.date(from: dayKey, calendar: calendar),
              let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            return
        }

        let sessionDescriptor = FetchDescriptor<FocusSession>(
            predicate: #Predicate<FocusSession> { session in
                session.startedAt >= dayStart && session.startedAt < dayEnd
            }
        )
        let daySessions = try modelContext.fetch(sessionDescriptor)

        var totalSeconds: Double = 0
        var completedCount = 0
        var abortedCount = 0
        var qualitySum: Double = 0
        var beatWeightedSum: Double = 0
        var distinctCompletedHabits = Set<UUID>()

        for s in daySessions {
            totalSeconds += s.actualDurationSeconds
            qualitySum += s.focusQualityScore
            beatWeightedSum += s.beatFrequencyHz * max(1.0, s.actualDurationSeconds)
            if s.completed {
                completedCount += 1
                if let hid = s.linkedHabitID {
                    distinctCompletedHabits.insert(hid)
                }
            } else {
                abortedCount += 1
            }
        }

        let avgQuality = daySessions.isEmpty ? 0.0 : (qualitySum / Double(daySessions.count))
        let dominantBeat = totalSeconds > 0 ? (beatWeightedSum / totalSeconds) : 10.0
        let bucket = DayKeyFormatter.intensityBucket(forFocusSeconds: totalSeconds)

        let existingDescriptor = FetchDescriptor<DailyTelemetry>(
            predicate: #Predicate<DailyTelemetry> { item in
                item.dayKey == dayKey
            }
        )

        if let existing = try modelContext.fetch(existingDescriptor).first {
            existing.totalFocusSeconds = totalSeconds
            existing.completedSessionCount = completedCount
            existing.abortedSessionCount = abortedCount
            existing.habitsCompletedCount = max(existing.habitsCompletedCount, distinctCompletedHabits.count)
            existing.averageQualityScore = avgQuality
            existing.intensityLevel = bucket
            existing.dominantBeatHz = dominantBeat
            existing.updatedAt = .now
            existing.revision += 1
        } else {
            let created = DailyTelemetry(
                dayKey: dayKey,
                dateStartOfDay: dayStart,
                totalFocusSeconds: totalSeconds,
                completedSessionCount: completedCount,
                abortedSessionCount: abortedCount,
                habitsCompletedCount: distinctCompletedHabits.count,
                averageQualityScore: avgQuality,
                intensityLevel: bucket,
                dominantBeatHz: dominantBeat,
                updatedAt: .now,
                revision: 1
            )
            modelContext.insert(created)
        }
    }
}
