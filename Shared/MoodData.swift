import Foundation

enum MoodFailure: String, Error {
    case invalid = "error.invalid"
    case version = "error.version"
    case size = "error.size"
    case write = "error.write"
}

enum Days {
    static func calendar(_ zone: TimeZone = Launch.zone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        calendar.firstWeekday = 2
        return calendar
    }

    static func key(_ date: Date, zone: TimeZone = Launch.zone) -> String {
        let parts = calendar(zone).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    static func date(_ key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...9999).contains(parts[0]), (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        let zone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar(zone).date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)),
              self.key(date, zone: zone) == key else { return nil }
        return date
    }

    static func month(_ key: String) -> String { String(key.prefix(7)) }

    static func shift(_ month: String, _ amount: Int) -> String {
        let zone = TimeZone(secondsFromGMT: 0)!
        guard let date = date(month + "-01"), let shifted = calendar(zone).date(byAdding: .month, value: amount, to: date) else { return month }
        return self.month(key(shifted, zone: zone))
    }

    static func slots(_ month: String) -> [String?] {
        let zone = TimeZone(secondsFromGMT: 0)!
        let calendar = calendar(zone)
        guard let first = date(month + "-01"), let range = calendar.range(of: .day, in: .month, for: first) else { return [] }
        return Array(repeating: nil, count: (calendar.component(.weekday, from: first) + 5) % 7)
            + range.map { month + String(format: "-%02d", $0) }
    }

    static func format(_ key: String, _ template: String) -> String {
        guard let date = date(key) else { return key }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)!
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    static func clock(_ minute: Int) -> String { String(format: "%02d:%02d", minute / 60, minute % 60) }

    static var weekdays: [String] {
        let symbols = DateFormatter().veryShortStandaloneWeekdaySymbols ?? []
        return Array(symbols.dropFirst()) + Array(symbols.prefix(1))
    }
}

struct MoodEntry: Codable, Equatable, Identifiable {
    var id = UUID()
    var dayKey: String
    var minuteOfDay: Int
    var timeZone: String
    var level: Int
    var note: String?
    var createdAt: Date
    var updatedAt: Date

    init(dayKey: String, level: Int, now: Date, zone: TimeZone = Launch.zone) {
        self.dayKey = dayKey
        let clock = Days.calendar(zone).dateComponents([.hour, .minute], from: now)
        minuteOfDay = clock.hour! * 60 + clock.minute!
        timeZone = zone.identifier
        self.level = level
        createdAt = now
        updatedAt = now
    }

    var valid: Bool {
        Days.date(dayKey) != nil && (0..<1440).contains(minuteOfDay) && (1...5).contains(level)
            && (note?.count ?? 0) <= 280 && TimeZone(identifier: timeZone) != nil
            && createdAt.timeIntervalSince1970.isFinite && updatedAt.timeIntervalSince1970.isFinite
    }

    static func earlier(_ lhs: Self, _ rhs: Self) -> Bool {
        (lhs.minuteOfDay, lhs.createdAt, lhs.id.uuidString) < (rhs.minuteOfDay, rhs.createdAt, rhs.id.uuidString)
    }
}

struct MoodPalette: Codable, Equatable, Identifiable {
    static let standard = MoodPalette(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                                     name: "", colors: ["E0ECDF", "BED6C3", "94B9A1", "477962", "205743"])
    var id = UUID()
    var name: String
    var colors: [String]
    var version = 1

    var valid: Bool {
        id != Self.standard.id && version == 1 && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && name.count <= 40 && colors.count == 5 && colors.allSatisfy {
                $0.utf8.count == 6 && $0.utf8.allSatisfy { "0123456789ABCDEFabcdef".utf8.contains($0) }
            }
    }

    static func lightText(on hex: String) -> Bool {
        let number = Int(hex, radix: 16) ?? 0
        let components = [16, 8, 0].map { shift -> Double in
            let value = Double((number >> shift) & 255) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * components[0] + 0.7152 * components[1] + 0.0722 * components[2]
        return 1.05 / (luminance + 0.05) > (luminance + 0.05) / 0.05
    }
}

struct Preferences: Codable, Equatable {
    var palettes = [MoodPalette]()
    var active: UUID?
    var milestones = Set<Int>()
    var ratedVersion: String?
    var ratedAt: Date?
    var reminder = false
    var reminderMinute = 21 * 60
    var palette: MoodPalette { palettes.first { $0.id == active } ?? .standard }
    var valid: Bool {
        (0..<1440).contains(reminderMinute) && milestones.isSubset(of: [7, 30])
            && palettes.allSatisfy(\.valid) && Set(palettes.map(\.id)).count == palettes.count
            && (active == nil || palettes.contains { $0.id == active })
    }

    func canRequestRating(now: Date, version: String) -> Bool {
        ratedVersion != version && now.timeIntervalSince(ratedAt ?? .distantPast) >= 90 * 86_400
    }
}

struct MoodHistory: Equatable {
    var entries = [MoodEntry]()
    var preferences = Preferences()

    var latest: [String: MoodEntry] {
        Dictionary(entries.map { ($0.dayKey, $0) }, uniquingKeysWith: { MoodEntry.earlier($0, $1) ? $1 : $0 })
    }

    var dayCounts: [String: Int] { entries.reduce(into: [:]) { $0[$1.dayKey, default: 0] += 1 } }

    func days(in month: String) -> [MoodEntry] {
        latest.values.filter { Days.month($0.dayKey) == month }.sorted { $0.dayKey < $1.dayKey }
    }

    func nextMilestones() -> [Int] {
        let count = latest.count
        return [7, 30].filter { count >= $0 && !preferences.milestones.contains($0) }
    }

    func shouldRate(now: Date, version: String, priorDays: Int) -> Bool {
        priorDays >= 7 && latest.count >= 7 && preferences.canRequestRating(now: now, version: version)
    }

    func preview(_ backup: MoodBackup) -> (new: Int, conflicts: Int) {
        let local = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        return (backup.entries.filter { local[$0.id] == nil }.count,
                backup.entries.filter { local[$0.id] != nil && local[$0.id] != $0 }.count)
    }

    mutating func merge(_ backup: MoodBackup) {
        let local = Set(entries.map(\.id))
        let knownPalettes = Set(preferences.palettes.map(\.id))
        if preferences == Preferences() { preferences = backup.preferences }
        else { preferences.palettes += backup.preferences.palettes.filter { !knownPalettes.contains($0.id) } }
        entries += backup.entries.filter { !local.contains($0.id) }
        preferences.milestones.formUnion(backup.preferences.milestones)
        if let incoming = backup.preferences.ratedAt, incoming > (preferences.ratedAt ?? .distantPast) {
            preferences.ratedAt = incoming
            preferences.ratedVersion = backup.preferences.ratedVersion
        }
        preferences.milestones.formUnion(nextMilestones())
    }
}

struct MoodIndex {
    let latest: [String: MoodEntry]
    let byDay: [String: [MoodEntry]]
    let byMonth: [String: [MoodEntry]]
    let counts: [String: Int]

    init(_ history: MoodHistory = MoodHistory()) {
        let daily = history.latest
        let grouped = Dictionary(grouping: history.entries, by: \.dayKey).mapValues { $0.sorted { MoodEntry.earlier($1, $0) } }
        latest = daily
        byDay = grouped
        byMonth = Dictionary(grouping: daily.values) { Days.month($0.dayKey) }.mapValues { $0.sorted { $0.dayKey < $1.dayKey } }
        counts = grouped.mapValues(\.count)
    }
}
