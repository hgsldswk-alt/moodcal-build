import SwiftUI

enum Paper {
    static let background = color("F6F6EE")
    static let surface = color("FFFDF7")
    static let ink = color("152F28")
    static let muted = color("526760")
    static let green = color("205743")
    static let soft = color("E4EDE3")
    static let border = color("CBD9CB")
    static let empty = color("ECEFE5")

    static func color(_ hex: String) -> Color {
        let value = Int(hex, radix: 16) ?? 0
        return Color(red: Double(value >> 16 & 255) / 255, green: Double(value >> 8 & 255) / 255, blue: Double(value & 255) / 255)
    }

    static func contrast(_ hex: String) -> Color { MoodPalette.lightText(on: hex) ? .white : .black }
}

struct SheetHeader: View {
    let title: String
    let close: () -> Void

    var body: some View {
        HStack {
            Text(L.t(title)).font(.system(.title, design: .serif).weight(.semibold)).accessibilityAddTraits(.isHeader)
            Spacer()
            IconButton(symbol: "xmark", title: "action.close", id: "sheet.close", action: close)
        }
    }
}

struct IconButton: View {
    let symbol: String
    let title: String
    let id: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.body.weight(.semibold)).frame(width: 44, height: 44)
                .background(Paper.soft, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(L.t(title)))
        .accessibilityIdentifier(id)
    }
}

struct MoodButtons: View {
    let palette: MoodPalette
    let selected: Int?
    let prefix: String
    let action: (Int) -> Void
    @Environment(\.dynamicTypeSize) private var size

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: size.isAccessibilitySize ? 2 : 5), spacing: 8) {
            ForEach(1...5, id: \.self) { level in
                let hex = palette.colors[level - 1]
                Button { action(level) } label: {
                    VStack(spacing: 4) {
                        Text(String(repeating: "·", count: level)).font(.subheadline.bold())
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundStyle(Paper.contrast(hex)).background(Paper.color(hex), in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected == level ? Paper.ink : .clear, lineWidth: 2).padding(-2))
                        Text(L.mood(level)).font(.caption2.weight(.semibold)).multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L.mood(level)))
                .accessibilityAddTraits(selected == level ? .isSelected : [])
                .accessibilityIdentifier("\(prefix).\(level)")
            }
        }
    }
}

struct MonthGrid: View {
    let month: String
    let today: String
    let selected: String?
    let latest: [String: MoodEntry]
    let counts: [String: Int]
    let palette: MoodPalette
    let prefix: String
    let action: (String) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            grid.frame(minWidth: 326)
            ScrollView(.horizontal) { grid.frame(minWidth: 326) }
        }
    }

    private var grid: some View {
        VStack(spacing: 5) {
            HStack(spacing: 3) {
                ForEach(Array(Days.weekdays.enumerated()), id: \.offset) { _, word in
                    Text(word).font(.caption2).frame(maxWidth: .infinity)
                }
            }.accessibilityHidden(true)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 3), count: 7), spacing: 3) {
                ForEach(Array(Days.slots(month).enumerated()), id: \.offset) { _, day in
                    if let day {
                        let entry = latest[day]
                        let hex = entry.map { palette.colors[$0.level - 1] }
                        Button { action(day) } label: {
                            VStack(spacing: 0) {
                                Text(String(day.suffix(2).drop(while: { $0 == "0" }))).font(.subheadline.monospacedDigit().weight(.semibold))
                                if let entry { Text(String(repeating: "·", count: entry.level)).font(.caption2.bold()) }
                            }
                            .lineLimit(1).minimumScaleFactor(0.55)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundStyle(hex.map(Paper.contrast) ?? (day > today ? Paper.muted : Paper.ink))
                            .background(hex.map(Paper.color) ?? Paper.empty, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(
                                day == selected || day == today ? Paper.green : Color.clear,
                                style: StrokeStyle(lineWidth: day == selected ? 2 : 1, dash: day == today && day != selected ? [2, 2] : [])))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).disabled(day > today)
                        .accessibilityLabel(Text(Days.format(day, "yMMMMEEEEd")))
                        .accessibilityValue(Text(entry.map { L.f("calendar.summary", L.mood($0.level), counts[day] ?? 1) } ?? L.t("calendar.empty")))
                        .accessibilityAddTraits(day == selected ? .isSelected : [])
                        .accessibilityIdentifier("\(prefix).\(day)")
                    } else { Color.clear.frame(height: 44).accessibilityHidden(true) }
                }
            }
        }
    }
}

struct ShareFeedback: View {
    @ObservedObject var model: MoodModel

    var body: some View {
        if model.shareRequested {
            Text(L.t("share.ready")).font(.footnote).accessibilityIdentifier("share.requested")
        }
    }
}
