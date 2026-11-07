// MARK: - FILE: ContributionHeatmapView.swift

import SwiftUI

public struct HeatmapCellSlot: Identifiable, Equatable, Sendable {
    public var id: String { dayKey }
    public let dayKey: String
    public let date: Date
    public let weekColumn: Int
    public let weekdayRow: Int
    public let isFuture: Bool
}

public struct ContributionHeatmapView: View {
    public let telemetryRecords: [DailyTelemetry]
    public let accentHue: Double
    public let audioEnergy: Float
    public let onScrubIntensity: (Int) -> Void
    public let onLoadDaySessions: (String) async -> [FocusSessionDTO]
    public let onExportJSON: () -> Void
    public let onExportCSV: () -> Void
    public let onImportJSON: () -> Void

    @State private var zoomScale: CGFloat = 1.0
    @State private var committedZoomScale: CGFloat = 1.0
    @State private var panOffset: CGSize = .zero
    @State private var committedPanOffset: CGSize = .zero

    @State private var selectedDayKey: String?
    @State private var selectedDaySessions: [FocusSessionDTO] = []
    @State private var isLoadingSessions: Bool = false

    private let totalWeeks: Int = 53
    private let daysPerWeek: Int = 7
    private let baseCellSize: CGFloat = 13.0
    private let baseCellSpacing: CGFloat = 3.5

    public init(
        telemetryRecords: [DailyTelemetry],
        accentHue: Double,
        audioEnergy: Float,
        onScrubIntensity: @escaping (Int) -> Void,
        onLoadDaySessions: @escaping (String) async -> [FocusSessionDTO],
        onExportJSON: @escaping () -> Void,
        onExportCSV: @escaping () -> Void,
        onImportJSON: @escaping () -> Void
    ) {
        self.telemetryRecords = telemetryRecords
        self.accentHue = accentHue
        self.audioEnergy = audioEnergy
        self.onScrubIntensity = onScrubIntensity
        self.onLoadDaySessions = onLoadDaySessions
        self.onExportJSON = onExportJSON
        self.onExportCSV = onExportCSV
        self.onImportJSON = onImportJSON
    }

    private var telemetryByKey: [String: DailyTelemetry] {
        var dict: [String: DailyTelemetry] = [:]
        dict.reserveCapacity(telemetryRecords.count)
        for item in telemetryRecords {
            dict[item.dayKey] = item
        }
        return dict
    }

    private var calendarGrid: (slots: [HeatmapCellSlot], monthMarkers: [(week: Int, label: String)]) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2

        let today = calendar.startOfDay(for: .now)
        let weekdayComponent = calendar.component(.weekday, from: today)
        let mondayZeroIndex = (weekdayComponent + 5) % 7
        let currentWeekMonday = calendar.date(byAdding: .day, value: -mondayZeroIndex, to: today) ?? today
        let gridStartMonday = calendar.date(byAdding: .weekOfYear, value: -(totalWeeks - 1), to: currentWeekMonday) ?? today

        var slots: [HeatmapCellSlot] = []
        slots.reserveCapacity(totalWeeks * daysPerWeek)

        var monthMarkers: [(week: Int, label: String)] = []
        var lastMonth = -1
        let shortMonths = calendar.shortMonthSymbols

        for week in 0..<totalWeeks {
            for row in 0..<daysPerWeek {
                let offsetDays = week * 7 + row
                guard let cellDate = calendar.date(byAdding: .day, value: offsetDays, to: gridStartMonday) else {
                    continue
                }
                let key = DayKeyFormatter.dayKey(for: cellDate, calendar: calendar)
                let isFuture = cellDate > today

                if row == 0 {
                    let m = calendar.component(.month, from: cellDate)
                    if m != lastMonth && m >= 1 && m <= shortMonths.count {
                        monthMarkers.append((week, shortMonths[m - 1]))
                        lastMonth = m
                    }
                }

                slots.append(
                    HeatmapCellSlot(
                        dayKey: key,
                        date: cellDate,
                        weekColumn: week,
                        weekdayRow: row,
                        isFuture: isFuture
                    )
                )
            }
        }

        return (slots, monthMarkers)
    }

    private var summaryStats: (yearHours: Double, activeDays: Int, peakMinutes: Int) {
        var totalSeconds: Double = 0
        var active = 0
        var maxSeconds: Double = 0
        for rec in telemetryRecords where rec.totalFocusSeconds >= 60 {
            totalSeconds += rec.totalFocusSeconds
            active += 1
            maxSeconds = max(maxSeconds, rec.totalFocusSeconds)
        }
        return (
            totalSeconds / 3600.0,
            active,
            Int((maxSeconds / 60.0).rounded())
        )
    }

    public var body: some View {
        let lookup = telemetryByKey
        let gridData = calendarGrid
        let stats = summaryStats

        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                headerMetricsRow(stats: stats)

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("365-Day Spatial Focus Matrix", systemImage: "square.grid.3x3.topleft.filled")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.92))

                        Spacer()

                        HStack(spacing: 8) {
                            Text(String(format: "%.1fx", zoomScale))
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.75))

                            if zoomScale > 1.02 || panOffset != .zero {
                                Button("Reset") {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.80)) {
                                        zoomScale = 1.0
                                        committedZoomScale = 1.0
                                        panOffset = .zero
                                        committedPanOffset = .zero
                                    }
                                }
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color(hue: accentHue, saturation: 0.55, brightness: 1.0))
                            }
                        }
                    }

                    heatmapInteractiveViewport(gridData: gridData, lookup: lookup)

                    intensityLegendRow
                }
                .padding(16)
                .aetherGlass(accentHue: accentHue, audioEnergy: audioEnergy, cornerRadius: 24)

                if let key = selectedDayKey {
                    selectedDayInspectorCard(dayKey: key, telemetry: lookup[key])
                        .id(key)
                        .transition(.aetherMatrixPortal)
                }

                portabilityDeckCard
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
    }

    private func headerMetricsRow(stats: (yearHours: Double, activeDays: Int, peakMinutes: Int)) -> some View {
        HStack(spacing: 10) {
            metricTile(
                title: "Annual Flow",
                value: String(format: "%.1fh", stats.yearHours),
                symbol: "hourglass.circle.fill"
            )
            metricTile(
                title: "Active Days",
                value: "\(stats.activeDays)",
                symbol: "flame.fill"
            )
            metricTile(
                title: "Peak Day",
                value: "\(stats.peakMinutes)m",
                symbol: "waveform.badge.magnifyingglass"
            )
        }
    }

    private func metricTile(title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(hue: accentHue, saturation: 0.65, brightness: 0.98))
                Text(title)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.65))
            }
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .aetherGlass(accentHue: accentHue, audioEnergy: audioEnergy * 0.5, cornerRadius: 18)
    }

    private func heatmapInteractiveViewport(
        gridData: (slots: [HeatmapCellSlot], monthMarkers: [(week: Int, label: String)]),
        lookup: [String: DailyTelemetry]
    ) -> some View {
        let step = (baseCellSize + baseCellSpacing) * zoomScale
        let scaledCell = baseCellSize * zoomScale
        let leadingAxisWidth: CGFloat = 28
        let topAxisHeight: CGFloat = 18
        let contentWidth = leadingAxisWidth + CGFloat(totalWeeks) * step + 8
        let contentHeight = topAxisHeight + CGFloat(daysPerWeek) * step + 6

        return GeometryReader { geo in
            let viewport = geo.size
            let clampedOffset = clampPan(
                proposed: panOffset,
                contentSize: CGSize(width: contentWidth, height: contentHeight),
                viewportSize: viewport
            )

            Canvas { context, _ in
                let originX = leadingAxisWidth + clampedOffset.width
                let originY = topAxisHeight + clampedOffset.height

                for marker in gridData.monthMarkers {
                    let x = originX + CGFloat(marker.week) * step
                    if x > -30 && x < viewport.width + 20 {
                        let text = Text(marker.label)
                            .font(.system(size: min(12, 9.5 * sqrt(zoomScale)), weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.55))
                        context.draw(text, at: CGPoint(x: x + 12, y: 8), anchor: .center)
                    }
                }

                let weekdayLabels = [(0, "M"), (2, "W"), (4, "F"), (6, "S")]
                for (row, label) in weekdayLabels {
                    let y = originY + CGFloat(row) * step + scaledCell * 0.5
                    if y > topAxisHeight - 4 && y < viewport.height {
                        let text = Text(label)
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.45))
                        context.draw(text, at: CGPoint(x: 10, y: y), anchor: .center)
                    }
                }

                let corner = max(2.5, 3.2 * zoomScale)
                for slot in gridData.slots where !slot.isFuture {
                    let x = originX + CGFloat(slot.weekColumn) * step
                    let y = originY + CGFloat(slot.weekdayRow) * step

                    guard x + scaledCell >= leadingAxisWidth - 4,
                          x <= viewport.width + 4,
                          y + scaledCell >= topAxisHeight - 4,
                          y <= viewport.height + 4 else {
                        continue
                    }

                    let level = lookup[slot.dayKey]?.intensityLevel ?? 0
                    let rect = CGRect(x: x, y: y, width: scaledCell, height: scaledCell)
                    let path = Path(roundedRect: rect, cornerRadius: corner)

                    context.fill(path, with: .color(cellColor(for: level)))

                    if selectedDayKey == slot.dayKey {
                        context.stroke(
                            path,
                            with: .color(.white),
                            lineWidth: max(1.6, 1.8 * sqrt(zoomScale))
                        )
                    } else if level > 0 {
                        context.stroke(
                            path,
                            with: .color(.white.opacity(0.14)),
                            lineWidth: 0.5
                        )
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture()
                    .onEnded { tap in
                        selectCell(
                            at: tap.location,
                            clampedOffset: clampedOffset,
                            step: step,
                            leadingAxisWidth: leadingAxisWidth,
                            topAxisHeight: topAxisHeight,
                            slots: gridData.slots,
                            lookup: lookup
                        )
                    }
            )
            .gesture(
                SimultaneousGesture(
                    MagnifyGesture()
                        .onChanged { value in
                            zoomScale = min(max(committedZoomScale * value.magnification, 0.85), 2.8)
                        }
                        .onEnded { _ in
                            committedZoomScale = zoomScale
                            panOffset = clampPan(
                                proposed: panOffset,
                                contentSize: CGSize(width: contentWidth, height: contentHeight),
                                viewportSize: viewport
                            )
                            committedPanOffset = panOffset
                        },
                    DragGesture(minimumDistance: 4)
                        .onChanged { drag in
                            let candidate = CGSize(
                                width: committedPanOffset.width + drag.translation.width,
                                height: committedPanOffset.height + drag.translation.height
                            )
                            panOffset = clampPan(
                                proposed: candidate,
                                contentSize: CGSize(width: contentWidth, height: contentHeight),
                                viewportSize: viewport
                            )
                        }
                        .onEnded { _ in
                            committedPanOffset = panOffset
                        }
                )
            )
            .onAppear {
                let trailingPan = min(0, viewport.width - contentWidth)
                panOffset = CGSize(width: trailingPan, height: 0)
                committedPanOffset = panOffset
                if selectedDayKey == nil {
                    let todayKey = DayKeyFormatter.dayKey(for: .now)
                    selectDayKey(todayKey, intensity: lookup[todayKey]?.intensityLevel ?? 0, playHaptic: false)
                }
            }
        }
        .frame(height: max(148, 18 + CGFloat(daysPerWeek) * ((baseCellSize + baseCellSpacing) * min(zoomScale, 1.85)) + 12))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var intensityLegendRow: some View {
        HStack(spacing: 6) {
            Text("Pinch zoom · Drag pan · Tap inspect")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.48))
                .lineLimit(1)

            Spacer()

            Text("Less")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.48))

            ForEach(0...4, id: \.self) { lvl in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(cellColor(for: lvl))
                    .frame(width: 11, height: 11)
            }

            Text("More")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.48))
        }
    }

    private func selectedDayInspectorCard(dayKey: String, telemetry: DailyTelemetry?) -> some View {
        let minutes = Int(((telemetry?.totalFocusSeconds ?? 0) / 60.0).rounded())
        let sessionsCount = telemetry?.completedSessionCount ?? 0
        let qualityPct = Int(((telemetry?.averageQualityScore ?? 0) * 100.0).rounded())
        let beatHz = telemetry?.dominantBeatHz ?? 0

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(formattedInspectorTitle(for: dayKey))
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(minutes > 0
                         ? "\(minutes) focus min · \(sessionsCount) completed · \(qualityPct)% coherence"
                         : "Zero recorded sessions on this cycle")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.68))
                }
                Spacer()
                if minutes > 0 {
                    Text(String(format: "%.1f Hz", beatHz))
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(hue: accentHue, saturation: 0.55, brightness: 1.0))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.white.opacity(0.10), in: Capsule())
                }
            }

            if isLoadingSessions {
                ProgressView()
                    .tint(.white)
            } else if !selectedDaySessions.isEmpty {
                Divider().overlay(.white.opacity(0.14))
                ForEach(selectedDaySessions.prefix(5)) { session in
                    HStack {
                        Circle()
                            .fill(Color(hue: accentHue, saturation: 0.72, brightness: 0.95))
                            .frame(width: 7, height: 7)
                        Text(session.title)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.92))
                        Spacer()
                        Text("\(max(1, Int((session.actualDurationSeconds / 60.0).rounded())))m")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.70))
                    }
                }
            }
        }
        .padding(16)
        .aetherGlass(accentHue: accentHue, audioEnergy: audioEnergy, cornerRadius: 22)
    }

    private var portabilityDeckCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Offline Ledger Portability & Checksum Archive", systemImage: "externaldrive.fill.badge.checkmark")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.90))

            HStack(spacing: 8) {
                portabilityButton(title: "JSON Backup", symbol: "arrow.up.doc.fill", action: onExportJSON)
                portabilityButton(title: "CSV Sessions", symbol: "tablecells.fill", action: onExportCSV)
                portabilityButton(title: "Restore JSON", symbol: "arrow.down.doc.fill", action: onImportJSON)
            }
        }
        .padding(16)
        .aetherGlass(accentHue: accentHue, audioEnergy: audioEnergy * 0.4, cornerRadius: 22)
    }

    private func portabilityButton(title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.16), lineWidth: 0.8)
            }
        }
        .buttonStyle(.plain)
    }

    private func cellColor(for level: Int) -> Color {
        switch level {
        case 0:
            return Color.white.opacity(0.07)
        case 1:
            return Color(hue: accentHue, saturation: 0.52, brightness: 0.55, opacity: 0.52)
        case 2:
            return Color(hue: accentHue, saturation: 0.65, brightness: 0.74, opacity: 0.75)
        case 3:
            return Color(hue: accentHue, saturation: 0.74, brightness: 0.88, opacity: 0.90)
        default:
            return Color(hue: (accentHue + 0.04).truncatingRemainder(dividingBy: 1.0), saturation: 0.62, brightness: 1.0, opacity: 1.0)
        }
    }

    private func clampPan(proposed: CGSize, contentSize: CGSize, viewportSize: CGSize) -> CGSize {
        let minX = min(0, viewportSize.width - contentSize.width)
        let minY = min(0, viewportSize.height - contentSize.height)
        return CGSize(
            width: min(max(proposed.width, minX), 0),
            height: min(max(proposed.height, minY), 0)
        )
    }

    private func selectCell(
        at location: CGPoint,
        clampedOffset: CGSize,
        step: CGFloat,
        leadingAxisWidth: CGFloat,
        topAxisHeight: CGFloat,
        slots: [HeatmapCellSlot],
        lookup: [String: DailyTelemetry]
    ) {
        let localX = location.x - leadingAxisWidth - clampedOffset.width
        let localY = location.y - topAxisHeight - clampedOffset.height
        guard localX >= 0, localY >= 0, step > 1 else { return }

        let col = Int(floor(localX / step))
        let row = Int(floor(localY / step))
        guard col >= 0, col < totalWeeks, row >= 0, row < daysPerWeek else { return }

        if let hit = slots.first(where: { $0.weekColumn == col && $0.weekdayRow == row && !$0.isFuture }) {
            let level = lookup[hit.dayKey]?.intensityLevel ?? 0
            selectDayKey(hit.dayKey, intensity: level, playHaptic: true)
        }
    }

    private func selectDayKey(_ key: String, intensity: Int, playHaptic: Bool) {
        if playHaptic {
            onScrubIntensity(intensity)
        }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
            selectedDayKey = key
        }
        isLoadingSessions = true
        Task {
            let loaded = await onLoadDaySessions(key)
            await MainActor.run {
                if selectedDayKey == key {
                    selectedDaySessions = loaded
                    isLoadingSessions = false
                }
            }
        }
    }

    private func formattedInspectorTitle(for dayKey: String) -> String {
        guard let date = DayKeyFormatter.date(from: dayKey) else { return dayKey }
        return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().year())
    }
}
