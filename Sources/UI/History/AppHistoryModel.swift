import AppKit

/// Columns of the App History outline. Raw values are the table column keys; `cpu` is the sort target the UI tests use.
enum AppHistoryColumn: String, CaseIterable {
    case application
    case cpu
    case diskRead = "disk-read"
    case diskWrite = "disk-write"
    case networkReceive = "network-receive"
    case networkTransmit = "network-transmit"
    case coverage

    var title: String {
        switch self {
        case .application: return "Application"
        case .cpu: return "CPU time"
        case .diskRead: return "Disk read"
        case .diskWrite: return "Disk write"
        case .networkReceive: return "Network received"
        case .networkTransmit: return "Network sent"
        case .coverage: return "Samples / gaps / resets"
        }
    }

    var width: CGFloat {
        switch self {
        case .application: return 230
        case .cpu, .diskRead, .diskWrite: return 112
        case .networkReceive, .networkTransmit: return 128
        case .coverage: return 160
        }
    }

    var isNumeric: Bool { self != .application }

    /// Coverage counts are diagnostic, so they start hidden. The header menu shows them again.
    var isHiddenByDefault: Bool { self == .coverage }

    /// Position in `AppHistoryRow.values` and `AppHistoryRow.numbers`.
    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    /// Font the cell label draws with: monospaced digits for numeric columns.
    var cellFont: NSFont {
        isNumeric ? .monospacedDigitSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 12)
    }

    /// Space the cell keeps around its label (see `AppHistoryCellView`).
    static let cellLeadingInset: CGFloat = 4
    static let cellTrailingInset: CGFloat = 8
}

/// Visible text for one cell, with the explanation kept out of the visible string.
struct AppHistoryCellText: Equatable {
    /// Compact text shown in the cell. Partial values lead with "≥" so the number stays readable in a narrow column.
    let display: String
    /// Tooltip and accessibility text explaining `display`, or nil when `display` says everything.
    let detail: String?
}

/// One outline row: an application total or one day of an application.
struct AppHistoryRow: Equatable {
    /// `history.total.<slug>`, `history.day.<day>.<slug>` or `history.gap.<day>.<slug>`, with a `.application.<id>` suffix when slugs collide.
    /// `<day>` is the local calendar date as `yyyy-MM-dd`.
    let id: String
    /// Display text per column, indexed by `AppHistoryColumn.index`. Index 0 is the application or day title.
    let values: [String]
    /// Tooltip and accessibility text per column, index-aligned with `values`. Nil entries mean no extra detail.
    let details: [String?]
    /// Numeric sort value per column (nil = unavailable, sorts last). Index 0 is unused.
    let numbers: [Double?]
    /// Local midnight of a day row; nil for an application total. Day rows sort by this date, not by their label.
    let dayStart: Date?

    init(id: String, values: [String], details: [String?] = [], numbers: [Double?], dayStart: Date? = nil) {
        self.id = id
        self.values = values
        self.details = details
        self.numbers = numbers
        self.dayStart = dayStart
    }

    var title: String { values[0] }

    func detail(_ column: AppHistoryColumn) -> String? {
        details.indices.contains(column.index) ? details[column.index] : nil
    }
}

/// One application: its total row and per-day rows, newest day first.
struct AppHistoryGroup: Equatable {
    let total: AppHistoryRow
    let executablePath: String?
    let days: [AppHistoryRow]

    var id: String { total.id }
}

/// Column sort order chosen from the header. Unavailable values always sort last.
struct AppHistorySortOrder: Equatable {
    let column: AppHistoryColumn
    let ascending: Bool

    init?(descriptor: NSSortDescriptor?) {
        guard let key = descriptor?.key, let column = AppHistoryColumn(rawValue: key) else { return nil }
        self.column = column
        self.ascending = descriptor?.ascending ?? true
    }

    init(column: AppHistoryColumn, ascending: Bool) {
        self.column = column
        self.ascending = ascending
    }
}

/// Builds the App History outline from the aggregate history of the last 30 local days.
@MainActor
enum AppHistoryBuilder {
    static let windowDays = 30

    /// Groups in the window, with totals and day rows formatted, plus window-wide counters for the status banner.
    struct Summary: Equatable {
        let groups: [AppHistoryGroup]
        /// Gaps and counter resets across the shown groups only, so the banner describes what the user sees.
        let gaps: Int
        let counterResets: Int
        /// Applications in the window that the background filter hid.
        let hiddenBackgroundCount: Int
    }

    /// True for applications the user launched. Background daemons and XPC services are `.standalone` or `.parentProcess`.
    static func isApplicationBundle(_ application: ApplicationHistoryIdentity) -> Bool {
        application.association == .applicationBundle
    }

    /// Groups for the last `windowDays` local days, ending on the local day of `timestamp`.
    /// Background entries are included only when `showsBackgroundProcesses` is true.
    static func summarize(_ summaries: [ApplicationDailyHistorySummary], through timestamp: Date,
                          showsBackgroundProcesses: Bool) -> Summary {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: timestamp)
        let cutoff = calendar.date(byAdding: .day, value: -(windowDays - 1), to: today) ?? today
        let window = summaries.filter { $0.dayStart >= cutoff && $0.dayStart <= today }
        let recordsByApplication = Dictionary(grouping: window, by: { $0.application.id })
        let allApplications = recordsByApplication.values.compactMap { $0.first?.application }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let shownApplications = allApplications.filter { showsBackgroundProcesses || isApplicationBundle($0) }
        // Collision suffixes come from every application in the window, so a row's id does not change when the filter does.
        let slugCounts = Dictionary(grouping: allApplications, by: { slug($0.name) }).mapValues(\.count)
        let shownIDs = Set(shownApplications.map(\.id))
        let shownWindow = window.filter { shownIDs.contains($0.application.id) }

        let groups = shownApplications.map { application -> AppHistoryGroup in
            let records = (recordsByApplication[application.id] ?? []).sorted { $0.dayStart > $1.dayStart }
            return group(for: application, records: records, slugCounts: slugCounts, today: timestamp, calendar: calendar)
        }
        return Summary(
            groups: groups,
            gaps: shownWindow.reduce(0) { $0 + $1.gaps },
            counterResets: shownWindow.reduce(0) { $0 + $1.counterResets },
            hiddenBackgroundCount: allApplications.count - shownApplications.count
        )
    }

    private static func group(for application: ApplicationHistoryIdentity, records: [ApplicationDailyHistorySummary],
                              slugCounts: [String: Int], today: Date, calendar: Calendar) -> AppHistoryGroup {
        let applicationSlug = slug(application.name)
        let suffix = (slugCounts[applicationSlug] ?? 0) > 1 ? ".application.\(application.id)" : ""
        let gaps = records.reduce(0) { $0 + $1.gaps }
        let resets = records.reduce(0) { $0 + $1.counterResets }
        let samples = records.reduce(0) { $0 + $1.sampleCount }
        let totals: [AppHistoryCellText] = [
            totalText(records.map(\.cpuSeconds), unit: .seconds, gapCount: gaps),
            totalText(records.map { $0.diskReadBytes.map(Double.init) }, unit: .bytes, gapCount: gaps),
            totalText(records.map { $0.diskWriteBytes.map(Double.init) }, unit: .bytes, gapCount: gaps),
            totalText(records.map { $0.networkReceiveBytes.map(Double.init) }, unit: .bytes, gapCount: gaps),
            totalText(records.map { $0.networkTransmitBytes.map(Double.init) }, unit: .bytes, gapCount: gaps)
        ]
        let total = AppHistoryRow(
            id: "history.total.\(applicationSlug)\(suffix)",
            values: [application.name] + totals.map(\.display) + ["\(samples) / \(gaps) / \(resets)"],
            details: [nil] + totals.map(\.detail) + [nil],
            numbers: [
                nil,
                sumOfMeasured(records.map(\.cpuSeconds)),
                sumOfMeasured(records.map { $0.diskReadBytes.map(Double.init) }),
                sumOfMeasured(records.map { $0.diskWriteBytes.map(Double.init) }),
                sumOfMeasured(records.map { $0.networkReceiveBytes.map(Double.init) }),
                sumOfMeasured(records.map { $0.networkTransmitBytes.map(Double.init) }),
                Double(samples)
            ]
        )
        let days = records.map { record -> AppHistoryRow in
            let day = dayIDFormatter.string(from: record.dayStart)
            let id = record.gaps > 0
                ? "history.gap.\(day).\(applicationSlug)\(suffix)"
                : "history.day.\(day).\(applicationSlug)\(suffix)"
            let read = record.diskReadBytes.map(Double.init)
            let write = record.diskWriteBytes.map(Double.init)
            let receive = record.networkReceiveBytes.map(Double.init)
            let transmit = record.networkTransmitBytes.map(Double.init)
            let texts: [AppHistoryCellText] = [
                dailyText(record.cpuSeconds, unit: .seconds, gaps: record.gaps),
                dailyText(read, unit: .bytes, gaps: record.gaps),
                dailyText(write, unit: .bytes, gaps: record.gaps),
                dailyText(receive, unit: .bytes, gaps: record.gaps),
                dailyText(transmit, unit: .bytes, gaps: record.gaps)
            ]
            return AppHistoryRow(
                id: id,
                values: [dayTitle(record.dayStart, today: today, calendar: calendar)]
                    + texts.map(\.display) + ["\(record.sampleCount) / \(record.gaps) / \(record.counterResets)"],
                details: [nil] + texts.map(\.detail) + [nil],
                numbers: [
                    nil,
                    record.cpuSeconds,
                    read,
                    write,
                    receive,
                    transmit,
                    Double(record.sampleCount)
                ],
                dayStart: record.dayStart
            )
        }
        return AppHistoryGroup(total: total, executablePath: application.executablePath, days: days)
    }

    /// "Today", "Yesterday", or a localized medium date. Judged on the local calendar, relative to `today`.
    static func dayTitle(_ dayStart: Date, today: Date, calendar: Calendar) -> String {
        if calendar.isDate(dayStart, inSameDayAs: today) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
           calendar.isDate(dayStart, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        return dayTitleFormatter.string(from: dayStart)
    }

    /// Total for an application across days. Missing days or gaps make the total a partial lower bound: the
    /// number leads with "≥" and the reasons go to `detail`. All-missing stays "Unavailable", never zero.
    static func totalText(_ values: [Double?], unit: MetricUnit, gapCount: Int) -> AppHistoryCellText {
        let present = values.compactMap { $0 }.filter { $0.isFinite }
        guard !present.isEmpty else {
            return AppHistoryCellText(display: "Unavailable",
                                      detail: gapCount > 0 ? "No measured value; \(gapCount) gap(s)" : nil)
        }
        let formatted = UIFormat.metric(MetricReading(value: present.reduce(0, +), unit: unit, timestamp: .distantPast))
        let missingDays = values.filter { $0 == nil }.count
        guard missingDays > 0 || gapCount > 0 else {
            return AppHistoryCellText(display: formatted, detail: nil)
        }
        var reasons: [String] = []
        if missingDays > 0 { reasons.append("\(missingDays) day(s) not measured") }
        if gapCount > 0 { reasons.append("\(gapCount) gap(s)") }
        return AppHistoryCellText(
            display: "≥ \(formatted)",
            detail: "Measured \(formatted); partial — \(reasons.joined(separator: ", ")); actual total may be higher"
        )
    }

    /// One day of an application. Gaps on the day make the value a partial lower bound, shown with "≥".
    static func dailyText(_ value: Double?, unit: MetricUnit, gaps: Int) -> AppHistoryCellText {
        guard let value, value.isFinite else {
            return AppHistoryCellText(display: gaps > 0 ? "Missing" : "Unavailable",
                                      detail: gaps > 0 ? "No measured value; \(gaps) gap(s)" : nil)
        }
        let formatted = UIFormat.metric(MetricReading(value: value, unit: unit, timestamp: .distantPast))
        guard gaps > 0 else { return AppHistoryCellText(display: formatted, detail: nil) }
        return AppHistoryCellText(
            display: "≥ \(formatted)",
            detail: "Measured \(formatted); partial — \(gaps) gap(s) on this day; actual value may be higher"
        )
    }

    /// Sum of the finite measured values, or nil when none were measured.
    static func sumOfMeasured(_ values: [Double?]) -> Double? {
        let measured = values.compactMap { $0 }.filter(\.isFinite)
        return measured.isEmpty ? nil : measured.reduce(0, +)
    }

    static func slug(_ value: String) -> String {
        UIText.slug(value)
    }

    /// Stable `yyyy-MM-dd` for row identifiers. Uses the current time zone, like the history store's day keys.
    private static let dayIDFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Localized medium date for day titles other than today and yesterday.
    private static let dayTitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

/// Ordering for outline rows. Ties keep the input order; unavailable values sort last in both directions.
enum AppHistorySort {
    static func ordered<Item>(_ items: [Item], row: (Item) -> AppHistoryRow, by order: AppHistorySortOrder?) -> [Item] {
        guard let order else { return items }
        return items.enumerated().sorted { left, right in
            let leftKey = sortKey(row(left.element), order.column)
            let rightKey = sortKey(row(right.element), order.column)
            if case .none = leftKey, case .none = rightKey { return left.offset < right.offset }
            if case .none = leftKey { return false }
            if case .none = rightKey { return true }
            let comparison = leftKey.compare(to: rightKey)
            if comparison == .orderedSame { return left.offset < right.offset }
            return order.ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }.map(\.element)
    }

    static func sortKey(_ row: AppHistoryRow, _ column: AppHistoryColumn) -> ComparableSortKey {
        if column == .application {
            if let dayStart = row.dayStart { return .number(dayStart.timeIntervalSince1970) }
            return .text(row.title)
        }
        return .numeric(row.numbers[column.index])
    }
}

/// Banner and empty-state copy for the App History page.
@MainActor
enum AppHistoryStatus {
    struct Banner: Equatable {
        let text: String
        let style: StatusBannerView.Style
    }

    /// Failures are errors. Gaps and counter resets are information: the affected values are already marked partial.
    static func banner(availability: MetricAvailability?, applicationCount: Int, hiddenBackgroundCount: Int = 0,
                       gaps: Int, counterResets: Int, timestamp: Date) -> Banner {
        if let availability, !availability.available {
            return Banner(text: "App history is unavailable · "
                            + UIFormat.unavailable(availability.reason, detail: availability.detail),
                          style: .error)
        }
        if gaps > 0 || counterResets > 0 {
            var problems: [String] = []
            if gaps > 0 { problems.append("\(gaps) gap(s)") }
            if counterResets > 0 { problems.append("\(counterResets) counter reset(s)") }
            return Banner(text: "Some values are partial: \(problems.joined(separator: " and ")) in the last \(AppHistoryBuilder.windowDays) days. Affected values are marked ≥.",
                          style: .info)
        }
        guard applicationCount > 0 else {
            if hiddenBackgroundCount > 0 {
                return Banner(text: "No applications in history. \(hiddenBackgroundCount) background \(hiddenBackgroundCount == 1 ? "process" : "processes") hidden.",
                              style: .info)
            }
            return Banner(text: "No application history recorded yet.", style: .info)
        }
        var text = "\(applicationCount) applications"
        if hiddenBackgroundCount > 0 {
            text += " · \(hiddenBackgroundCount) background \(hiddenBackgroundCount == 1 ? "process" : "processes") hidden"
        }
        return Banner(text: text + " · updated \(UIFormat.time(timestamp))", style: .info)
    }

    static func emptyState(availability: MetricAvailability?, hiddenBackgroundCount: Int = 0) -> (title: String, caption: String) {
        if let availability, !availability.available {
            return ("App history is unavailable",
                    UIFormat.unavailable(availability.reason, detail: availability.detail))
        }
        if hiddenBackgroundCount > 0 {
            return ("No application history shown",
                    "Only background processes have history. Turn on Show Background Processes to list them.")
        }
        return ("No app history yet",
                "Totals appear after Microgravity records its first samples. History is kept for \(AppHistoryBuilder.windowDays) days.")
    }
}
