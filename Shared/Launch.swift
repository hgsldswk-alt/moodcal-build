import Foundation

enum Launch {
    static let freePeriod = false
    static let args = ProcessInfo.processInfo.arguments
    static let testing = args.contains("-ui-testing")
    static func isFree(arguments: [String]) -> Bool {
        freePeriod && !(arguments.contains("-ui-testing") && arguments.contains(where: {
            ["-paid-mode", "-paywall", "-expired"].contains($0)
        }))
    }
    static var isFree: Bool { isFree(arguments: args) }
    static func has(_ flag: String) -> Bool { testing && args.contains(flag) }
    static var now: Date {
        if has("-demo") {
            return Days.calendar(zone).date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 9, minute: 41))!
        }
        return .now
    }
    static var zone: TimeZone { has("-demo") ? TimeZone(secondsFromGMT: 0)! : .autoupdatingCurrent }
}
