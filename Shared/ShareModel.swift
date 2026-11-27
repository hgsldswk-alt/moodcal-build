import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ShareContent {
    struct Segment: Identifiable {
        let month: String
        let entries: [MoodEntry]
        var id: String { month }
    }

    var segments: [Segment]
    var milestone: Int?
    var dates = false
    var download = true
    var long = false
    var storeID = ""
    var demoQR = false

    var hashtags: String { L.t("share.hashtags") }
    var title: String { milestone.map { L.f("milestone.title", $0) } ?? L.t(long ? "share.long" : "share.cardTitle") }
    var downloadURL: URL? {
        guard download, !storeID.isEmpty, storeID.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return URL(string: "https://apps.apple.com/app/id\(storeID)")
    }
    var qr: CGImage? {
        guard download else { return nil }
        if let downloadURL { return Self.qr(for: downloadURL.absoluteString) }
        if demoQR { return Self.qr(for: "https://apps.apple.com/") }
        return nil
    }

    static func qr(for text: String) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator", parameters: ["inputMessage": Data(text.utf8), "inputCorrectionLevel": "M"]),
              let image = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        return CIContext().createCGImage(image, from: image.extent)
    }

    var count: Int { segments.reduce(0) { $0 + $1.entries.count } }
    var pixelHeight: Int { long ? 2160 : 1350 }

    func tiles(_ segment: Segment) -> [String?] {
        dates && milestone == nil ? Days.slots(segment.month) : segment.entries.map { Optional($0.dayKey) }
    }
}

enum SharePNG {
    static func encode(_ image: CGImage, height: Int) throws -> Data {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 1080, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw MoodFailure.write }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1080, height: CGFloat(height)))
        let data = NSMutableData()
        guard let raster = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { throw MoodFailure.write }
        CGImageDestinationAddImage(destination, raster, nil)
        guard CGImageDestinationFinalize(destination) else { throw MoodFailure.write }
        return data as Data
    }
}
