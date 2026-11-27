import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct PaletteSwatches: View {
    let palette: MoodPalette
    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(palette.colors.enumerated()), id: \.offset) { index, hex in
                Text(String(repeating: "·", count: index + 1)).font(.caption.bold()).foregroundStyle(Paper.contrast(hex))
                    .frame(maxWidth: .infinity, minHeight: 32).background(Paper.color(hex), in: RoundedRectangle(cornerRadius: 7))
            }
        }.accessibilityHidden(true)
    }
}

struct PalettesView: View {
    @ObservedObject var model: MoodModel
    @Environment(\.dismiss) private var dismiss
    @State private var edit: MoodPalette?
    @State private var sharing: MoodPalette?
    @State private var paywall = false

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "palette.title") { dismiss() }.padding(.horizontal, 20).padding(.top, 12)
            Form {
                Button { Task { _ = await model.setPalette(nil) } } label: {
                    VStack(alignment: .leading) {
                        Label(L.t("palette.standard"), systemImage: model.palette.id == MoodPalette.standard.id ? "checkmark.circle.fill" : "circle")
                        PaletteSwatches(palette: .standard)
                    }
                }.accessibilityIdentifier("palette.standard")
                ForEach(model.history.preferences.palettes) { palette in
                    Section {
                        Button {
                            if model.hasPro { Task { _ = await model.setPalette(palette) } } else { paywall = true }
                        } label: {
                            VStack(alignment: .leading) {
                                Label(palette.name, systemImage: model.palette.id == palette.id ? "checkmark.circle.fill" : "circle")
                                PaletteSwatches(palette: palette)
                            }
                        }.accessibilityIdentifier("palette.apply.\(palette.id.uuidString)").disabled(model.proWaiting)
                        Button(L.t("action.edit")) { if model.hasPro { edit = palette } else { paywall = true } }
                            .accessibilityIdentifier("palette.edit.\(palette.id.uuidString)").disabled(model.proWaiting)
                        Button(L.t("palette.share")) { sharing = palette }.accessibilityIdentifier("palette.share.\(palette.id.uuidString)")
                    }
                }
                Button(L.t("palette.new")) {
                    if model.hasPro { edit = MoodPalette(name: "", colors: MoodPalette.standard.colors) } else { paywall = true }
                }.accessibilityIdentifier("palette.new").disabled(model.proWaiting)
            }.scrollContentBackground(.hidden).disabled(!model.ready || model.working)
        }.background(Paper.background.ignoresSafeArea()).foregroundStyle(Paper.ink).tint(Paper.green)
            .sheet(item: $edit) { PaletteEditor(model: model, initial: $0) }
            .sheet(item: $sharing) { PaletteSharing(model: model, palette: $0) }
            .sheet(isPresented: $paywall) { Paywall(model: model) }
    }
}

struct PaletteEditor: View {
    @ObservedObject var model: MoodModel
    @State private var palette: MoodPalette
    @Environment(\.dismiss) private var dismiss

    init(model: MoodModel, initial: MoodPalette) { self.model = model; _palette = State(initialValue: initial) }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "palette.custom") { dismiss() }.padding(.horizontal, 20).padding(.top, 12)
            Form {
                TextField(L.t("palette.name"), text: $palette.name).accessibilityIdentifier("palette.name")
                    .onChange(of: palette.name) { _, value in if value.count > 40 { palette.name = String(value.prefix(40)) } }
                PaletteSwatches(palette: palette)
                ForEach(1...5, id: \.self) { level in
                    ColorPicker(L.mood(level), selection: Binding(get: { Paper.color(palette.colors[level - 1]) }, set: { color in
                        let native = UIColor(color)
                        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                        guard native.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return }
                        let values = [red, green, blue].map { Int((min(max($0, 0), 1) * 255).rounded()) }
                        palette.colors[level - 1] = String(format: "%02X%02X%02X", values[0], values[1], values[2])
                    }), supportsOpacity: false).accessibilityIdentifier("palette.color.\(level)")
                }
                if let error = model.error { Text(L.t(error)).font(.footnote) }
                Button(L.t("palette.save")) { Task { if await model.setPalette(palette) { dismiss() } } }
                    .disabled(!palette.valid || model.working || !model.hasPro).accessibilityIdentifier("palette.save")
            }.scrollContentBackground(.hidden)
        }.background(Paper.background.ignoresSafeArea()).foregroundStyle(Paper.ink).tint(Paper.green)
    }
}

struct PaletteImport: View {
    @ObservedObject var model: MoodModel
    @Environment(\.dismiss) private var dismiss
    @State private var preview: MoodPalette?
    @State private var filePicker = false
    @State private var paywall = false
    @State private var status: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SheetHeader(title: "palette.import") { dismiss() }
                Text(L.t("palette.importTip"))
                if Launch.has("-fixture-import"), let text = ProcessInfo.processInfo.environment["MOOD_PALETTE"] {
                    Button(L.t("palette.paste")) { paste(text) }.accessibilityIdentifier("palette.paste")
                } else {
                    PasteButton(payloadType: String.self) { values in if let value = values.first { paste(value) } }
                        .accessibilityLabel(Text(L.t("palette.paste"))).accessibilityIdentifier("palette.paste")
                }
                Button { filePicker = true } label: {
                    Text(L.t("palette.openFile")).frame(minHeight: 44).contentShape(Rectangle())
                }.accessibilityIdentifier("palette.openFile")
                if let preview {
                    Text(preview.name).font(.headline).accessibilityIdentifier("palette.preview")
                    PaletteSwatches(palette: preview)
                    Button(L.t("palette.apply")) {
                        guard model.hasPro else { paywall = true; return }
                        Task { if await model.setPalette(preview) { dismiss() } }
                    }.buttonStyle(.borderedProminent).accessibilityIdentifier("palette.apply").disabled(model.working || model.proWaiting)
                }
                if let status = status ?? model.error { Text(L.t(status)).font(.footnote).foregroundStyle(.red) }
            }.padding(20)
        }.background(Paper.background.ignoresSafeArea()).foregroundStyle(Paper.ink).tint(Paper.green)
            .fileImporter(isPresented: $filePicker, allowedContentTypes: [.moodPalette, .data]) { result in
                preview = nil
                status = nil
                if case .success(let url) = result {
                    Task {
                        do { preview = try await Task.detached { try Transfer.readPalette(Transfer.file(url, max: Transfer.paletteLimit)) }.value }
                        catch { status = (error as? MoodFailure)?.rawValue ?? "error.invalid" }
                    }
                }
            }
            .sheet(isPresented: $paywall) { Paywall(model: model) }
    }

    private func paste(_ text: String) {
        preview = nil
        status = nil
        do { preview = try Transfer.readCode(text) }
        catch { status = (error as? MoodFailure)?.rawValue ?? "error.invalid" }
    }
}

struct PaletteSharing: View {
    @ObservedObject var model: MoodModel
    let palette: MoodPalette
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var failed = false
    @State private var exporting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SheetHeader(title: "palette.share") { dismiss() }
                Text(palette.name).font(.headline)
                PaletteSwatches(palette: palette)
                Text(L.t("palette.caption"))
                Button(L.t(copied ? "action.copied" : "palette.copy")) {
                    if let data = try? Transfer.paletteData(palette) {
                        UIPasteboard.general.string = L.t("palette.caption") + "\n" + Transfer.code(data)
                        copied = true
                    }
                }.accessibilityIdentifier("palette.copy")
                Button(L.t("palette.file")) { Task { await shareFile() } }.accessibilityIdentifier("palette.file").disabled(exporting)
                ShareFeedback(model: model)
                if failed { Text(L.t("share.failed")).font(.footnote) }
            }.padding(20)
        }.background(Paper.background.ignoresSafeArea()).foregroundStyle(Paper.ink).tint(Paper.green)
            .onAppear { model.shareRequested = false }
            .activitySheet(model: model, route: .palette)
    }

    private func shareFile() async {
        exporting = true
        failed = false
        defer { exporting = false }
        let snapshot = palette
        do { model.requestShare(try await Task.detached { try Transfer.output([("MoodCal.moodpalette", Transfer.paletteData(snapshot))]) }.value, route: .palette) }
        catch { failed = true }
    }
}
