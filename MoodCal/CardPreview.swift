import SwiftUI
import UIKit

struct ShareArtwork: View {
    let content: ShareContent
    let palette: MoodPalette
    let qr: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(L.f("share.count", content.count)).font(.system(size: 13, weight: .semibold))
            Text(content.title).font(.system(size: 30, weight: .medium, design: .serif)).minimumScaleFactor(0.68).lineLimit(2)
            if content.count == 0 { Text(L.t("share.empty")).font(.system(size: 14)).foregroundStyle(Paper.muted) }
            ScrollFreeSegments(content: content, palette: palette)
            Spacer(minLength: 0)
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L.t("app.name")).font(.system(size: 13, weight: .bold))
                    Text(L.t("share.tagline")).font(.system(size: 11))
                    Text(content.hashtags).font(.system(size: 10, weight: .semibold))
                        .lineLimit(1).minimumScaleFactor(0.75)
                }
                Spacer()
                if let qr {
                    Image(decorative: qr, scale: 1, orientation: .up).interpolation(.none).resizable()
                        .frame(width: 43, height: 43).padding(5).background(.white)
                } else if content.download {
                    VStack(spacing: 2) {
                        Image(systemName: "qrcode").font(.system(size: 18))
                        Text(L.t("share.codeSoon")).font(.system(size: 8)).multilineTextAlignment(.center)
                    }.frame(width: 72, height: 45).background(Paper.soft, in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }.padding(17).frame(width: 280, height: CGFloat(content.pixelHeight) * 280 / 1080)
            .foregroundStyle(Paper.ink).background(Paper.surface)
            .environment(\.dynamicTypeSize, .medium)
    }
}

private struct ScrollFreeSegments: View {
    let content: ShareContent
    let palette: MoodPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(content.segments.enumerated()), id: \.offset) { index, segment in
                let days = Dictionary(uniqueKeysWithValues: segment.entries.map { ($0.dayKey, $0) })
                let columns = content.dates ? 7 : (content.long ? 10 : 5)
                let height: CGFloat = content.long ? (content.dates ? 15 : 20) : (content.dates ? 19 : (segment.entries.count > 25 ? 18 : 24))
                if content.long || (content.dates && content.milestone == nil) {
                    Text(content.dates ? Days.format(segment.month + "-01", "yMMMM") : L.f("share.segment", index + 1))
                        .font(.system(size: 11, weight: .semibold))
                }
                if content.dates && content.milestone == nil {
                    HStack(spacing: 3) {
                        ForEach(Array(Days.weekdays.enumerated()), id: \.offset) { _, weekday in
                            Text(weekday).font(.system(size: 8)).frame(maxWidth: .infinity)
                        }
                    }
                }
                let tiles = content.tiles(segment)
                VStack(spacing: 3) {
                    ForEach(Array(stride(from: 0, to: tiles.count, by: columns)), id: \.self) { start in
                        HStack(spacing: 3) {
                            ForEach(0..<columns, id: \.self) { offset in
                                let day = start + offset < tiles.count ? tiles[start + offset] : nil
                                let color = day.flatMap { days[$0] }.map { palette.colors[$0.level - 1] }
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(color.map(Paper.color) ?? (day == nil ? .clear : Paper.empty))
                                    .frame(height: height)
                                    .overlay {
                                        if content.dates, let day {
                                            Text(content.milestone == nil ? String(day.suffix(2)) : String(day.dropFirst(5)))
                                                .font(.system(size: 9).monospacedDigit())
                                                .foregroundStyle(color.map(Paper.contrast) ?? Paper.ink)
                                        }
                                    }
                            }
                        }
                    }
                }
            }
        }
    }
}

struct CardPreview: View {
    @ObservedObject var model: MoodModel
    let month: String
    let milestone: Int?
    @State private var dates = false
    @State private var download = true
    @State private var long = false
    @State private var qr: CGImage?
    @State private var copying = false
    @State private var exporting = false
    @State private var exportError = false
    @State private var paywall = false
    @Environment(\.dismiss) private var dismiss

    private var content: ShareContent {
        let months = long ? Array(model.recordedMonths.suffix(3)) : [month]
        let segments: [ShareContent.Segment]
        if let milestone {
            let days = model.recordedMonths.lazy.flatMap { model.entries(in: $0) }.prefix(milestone)
            segments = [ShareContent.Segment(month: month, entries: Array(days))]
        } else {
            segments = months.map { ShareContent.Segment(month: $0, entries: model.entries(in: $0)) }
        }
        return ShareContent(segments: segments, milestone: milestone,
                            dates: dates, download: download, long: long,
                            storeID: Bundle.main.object(forInfoDictionaryKey: "APP_STORE_ID") as? String ?? "",
                            demoQR: Launch.has("-demo-store"))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                SheetHeader(title: "share.preview") { dismiss() }.disabled(exporting)
                VStack {
                    ShareArtwork(content: content, palette: model.palette, qr: download ? qr : nil)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Paper.border))
                        .shadow(color: Paper.green.opacity(0.12), radius: 10, y: 4)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(content.title))
                        .accessibilityValue(Text(L.f("share.count", content.count)))
                        .accessibilityIdentifier(long ? "share.artwork.long" : (download && qr != nil ? "share.artwork.qr" : "share.artwork"))
                }.frame(maxWidth: .infinity).padding(.vertical, 10).background(Paper.soft, in: RoundedRectangle(cornerRadius: 22))
                Toggle(L.t("share.dates"), isOn: $dates).accessibilityIdentifier("share.dates")
                Divider()
                Toggle(L.t("share.download"), isOn: $download).accessibilityIdentifier("share.download")
                Divider()
                Text(L.t("share.caption")).font(.footnote).foregroundStyle(Paper.muted)
                ShareFeedback(model: model)
                if exportError {
                    Text(L.t("share.failed")).font(.footnote).accessibilityIdentifier("share.failed")
                }
                HStack {
                    Button(L.t(copying ? "action.copied" : "share.copy")) { UIPasteboard.general.string = L.t("share.caption"); copying = true }
                        .buttonStyle(.bordered).accessibilityIdentifier("share.copy")
                    Button(L.t("action.share")) { Task { await export() } }.buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("share.send").disabled(exporting)
                }.controlSize(.large)
                if milestone == nil {
                    Button(L.t(long ? "share.basic" : "share.long")) {
                        if model.hasPro { long.toggle() } else { paywall = true }
                    }.accessibilityIdentifier("share.template").disabled(model.proWaiting)
                }
            }.padding(.horizontal, 16).padding(.vertical, 10)
        }.background(Paper.background.ignoresSafeArea()).foregroundStyle(Paper.ink).tint(Paper.green)
            .task(id: download) {
                qr = nil
                let snapshot = content
                if snapshot.download { qr = await Task.detached { snapshot.qr }.value }
            }
            .onChange(of: model.hasPro) { _, pro in if !pro { long = false } }
            .sheet(isPresented: $paywall) { Paywall(model: model) }
            .activitySheet(model: model, route: .card)
            .interactiveDismissDisabled(exporting)
    }

    @MainActor private func export() async {
        exporting = true
        exportError = false
        model.shareRequested = false
        defer { exporting = false }
        let snapshot = content
        let image = await Task.detached { snapshot.qr }.value
        let renderer = ImageRenderer(content: ShareArtwork(content: snapshot, palette: model.palette, qr: image)
            .environment(\.colorScheme, .light))
        renderer.scale = 1080 / 280
        guard let rendered = renderer.cgImage else { exportError = true; return }
        do {
            let files = try await Task.detached {
                let data = try SharePNG.encode(rendered, height: snapshot.pixelHeight)
                return try Transfer.output([("MoodCal.png", data)])
            }.value
            model.requestShare(files, route: .card)
        } catch { exportError = true }
    }
}

private struct ActivityController: UIViewControllerRepresentable {
    let files: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: files, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct ActivitySheet: ViewModifier {
    @ObservedObject var model: MoodModel
    let route: ShareRoute
    @State private var presented = false
    @State private var files = [URL]()

    func body(content: Content) -> some View {
        content.onChange(of: model.shareRequest) { _, request in
            if let request, request.route == route { files = request.files; presented = true }
        }.sheet(isPresented: $presented, onDismiss: {
            let folders = Set(files.map { $0.deletingLastPathComponent() })
            model.shareRequest = nil
            files = []
            Task.detached { for folder in folders { try? FileManager.default.removeItem(at: folder) } }
        }) { ActivityController(files: files) }
    }
}

extension View {
    func activitySheet(model: MoodModel, route: ShareRoute) -> some View { modifier(ActivitySheet(model: model, route: route)) }
}
