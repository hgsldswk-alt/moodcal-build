import Foundation

final class MoodResources: NSObject {}

enum L {
    static func t(_ key: String) -> String {
        NSLocalizedString(key, bundle: Bundle(for: MoodResources.self), comment: "")
    }
    static func f(_ key: String, _ args: CVarArg...) -> String {
        String(format: t(key), locale: .current, arguments: args)
    }
    static func mood(_ level: Int) -> String { t(["mood.1", "mood.2", "mood.3", "mood.4", "mood.5"][level - 1]) }
}
