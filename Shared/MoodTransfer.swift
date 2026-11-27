import Foundation

struct MoodBackup: Codable, Equatable {
    var version = 1
    var entries: [MoodEntry]
    var preferences: Preferences

    init(_ history: MoodHistory) {
        entries = history.entries
        preferences = history.preferences
    }

    static func read(_ data: Data) throws -> Self {
        try Transfer.validateSize(data, max: Transfer.backupLimit)
        guard let header = try? JSONDecoder().decode(Transfer.Header.self, from: data) else { throw MoodFailure.invalid }
        guard header.version == 1 else { throw MoodFailure.version }
        guard let backup = try? JSONDecoder().decode(Self.self, from: data), backup.entries.count <= 100_000,
              backup.preferences.valid, backup.entries.allSatisfy(\.valid),
              Set(backup.entries.map(\.id)).count == backup.entries.count else { throw MoodFailure.invalid }
        return backup
    }
}

enum Transfer {
    static let backupLimit = 48 * 1024 * 1024
    static let paletteLimit = 4096
    struct Header: Decodable { let version: Int }

    private struct PalettePayload: Codable {
        var version = 1
        let name: String
        let colors: [String]
    }

    static func validateSize(_ data: Data, max: Int) throws {
        guard data.count <= max else { throw MoodFailure.size }
    }

    static func paletteData(_ palette: MoodPalette) throws -> Data {
        guard palette.valid else { throw MoodFailure.invalid }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(PalettePayload(name: palette.name, colors: palette.colors))
    }

    static func readPalette(_ data: Data) throws -> MoodPalette {
        try validateSize(data, max: paletteLimit)
        guard let payload = try? JSONDecoder().decode(PalettePayload.self, from: data) else { throw MoodFailure.invalid }
        guard payload.version == 1 else { throw MoodFailure.version }
        let palette = MoodPalette(name: payload.name, colors: payload.colors.map { $0.uppercased() })
        guard palette.valid else { throw MoodFailure.invalid }
        return palette
    }

    static func code(_ data: Data) -> String {
        "MC1-" + data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func readCode(_ text: String) throws -> MoodPalette {
        guard text.utf8.count <= paletteLimit * 3 else { throw MoodFailure.size }
        let code = text.split(whereSeparator: \.isWhitespace).first { $0.hasPrefix("MC1-") }
        guard let code else { throw MoodFailure.invalid }
        guard code.utf8.count <= paletteLimit * 2 else { throw MoodFailure.size }
        var base64 = code.dropFirst(4).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.utf8.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { throw MoodFailure.invalid }
        return try readPalette(data)
    }

    static func csv(_ entries: [MoodEntry]) -> String {
        let rows = entries.sorted { $0.dayKey == $1.dayKey ? MoodEntry.earlier($0, $1) : $0.dayKey < $1.dayKey }.map { entry in
            let note = entry.note ?? ""
            let first = note.unicodeScalars.first { !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) }
            let formula = first.map { "=+-@＝＋－＠".unicodeScalars.contains($0) } ?? false
            let safe = formula || note.hasPrefix("\t") || note.hasPrefix("\r") || note.hasPrefix("\n") ? "'" + note : note
            return [entry.id.uuidString, entry.dayKey, Days.clock(entry.minuteOfDay), String(entry.level),
                    "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""].joined(separator: ",")
        }
        return (["UUID,Date,Time,Level,Note"] + rows).joined(separator: "\r\n") + "\r\n"
    }

    static func file(_ url: URL, max: Int) throws -> Data {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<Data, Error> = .failure(MoodFailure.invalid)
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { local in
            result = Result {
                let handle = try FileHandle(forReadingFrom: local)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: max + 1) ?? Data()
                try validateSize(data, max: max)
                return data
            }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    static func output(_ files: [(String, Data)]) throws -> [URL] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mood-export-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.complete])
        do {
            return try files.map { name, data in
                let url = folder.appendingPathComponent(name)
                try data.write(to: url, options: [.atomic, .completeFileProtection])
                return url
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    static func historyFiles(_ history: MoodHistory) throws -> [URL] {
        let backup = try JSONEncoder().encode(MoodBackup(history))
        try validateSize(backup, max: backupLimit)
        return try output([("MoodCal.csv", Data(csv(history.entries).utf8)), ("MoodCal.moodbackup", backup)])
    }
}
