import AppKit
import CoreGraphics
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Color

/// An sRGB color with components in 0...1.
struct RGBA: Codable, Equatable, Hashable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double = 1

    static let white = RGBA(r: 1, g: 1, b: 1)
    static let black = RGBA(r: 0, g: 0, b: 0)

    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var swiftUIColor: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }

    var hex: String {
        func c(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", c(r), c(g), c(b))
    }

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        r = Double((v >> 16) & 0xFF) / 255
        g = Double((v >> 8) & 0xFF) / 255
        b = Double(v & 0xFF) / 255
        a = 1
    }

    init?(nsColor: NSColor) {
        guard let c = nsColor.usingColorSpace(.sRGB) else { return nil }
        r = Double(c.redComponent); g = Double(c.greenComponent); b = Double(c.blueComponent); a = 1
    }

    func isClose(to o: RGBA) -> Bool {
        abs(r - o.r) < 0.001 && abs(g - o.g) < 0.001 && abs(b - o.b) < 0.001
    }
}

// MARK: - Fill (solid or gradient)

enum FillKind: String, Codable, CaseIterable, Identifiable {
    case solid, gradient
    var id: Self { self }
    var title: String { self == .solid ? "Solid" : "Gradient" }
}

struct Fill: Codable, Equatable {
    var kind: FillKind = .solid
    var color: RGBA = .white
    var color2: RGBA = RGBA(r: 0.80, g: 0.80, b: 0.80)
    /// Gradient direction in degrees: 0 = left→right, 90 = top→bottom.
    var angle: Double = 90
}

// MARK: - Style

enum BackgroundMode: String, Codable, CaseIterable, Identifiable {
    case none, color, image
    var id: Self { self }
    var title: String {
        switch self {
        case .none: return "None"
        case .color: return "Color"
        case .image: return "Image"
        }
    }
}

enum CanvasAspect: String, Codable, CaseIterable, Identifiable {
    case story = "9:16"
    case portrait45 = "4:5"
    case portrait34 = "3:4"
    case portrait23 = "2:3"
    case square = "1:1"
    case landscape32 = "3:2"
    case landscape43 = "4:3"
    case landscape169 = "16:9"

    var id: Self { self }

    /// width / height
    var ratio: Double {
        let p = rawValue.split(separator: ":").compactMap { Double($0) }
        return p[0] / p[1]
    }

    var title: String {
        switch self {
        case .story: return "9:16  Story / Reel"
        case .portrait45: return "4:5  Portrait post"
        case .portrait34: return "3:4"
        case .portrait23: return "2:3"
        case .square: return "1:1  Square"
        case .landscape32: return "3:2"
        case .landscape43: return "4:3"
        case .landscape169: return "16:9  Landscape"
        }
    }
}

struct Style: Codable, Equatable {
    // Border
    /// Border thickness as a fraction of the photo's shorter side.
    var borderWidth: Double = 0.025
    var borderFill = Fill()

    // Background
    var backgroundMode: BackgroundMode = .image
    var backgroundFill = Fill(kind: .solid,
                              color: RGBA(r: 0.12, g: 0.12, b: 0.13),
                              color2: RGBA(r: 0.30, g: 0.30, b: 0.33),
                              angle: 90)
    var aspect: CanvasAspect = .story
    var bgBlur: Double = 0.20        // 0...1
    var bgGrain: Double = 0.0        // 0...1
    var bgGrainSize: Double = 0.35   // 0...1
    var bgBrightness: Double = -0.20 // -1...1
    var bgZoom: Double = 1.0         // 1...4
    var bgPanX: Double = 0           // -1...1
    var bgPanY: Double = 0           // -1...1

    // Photo
    /// Size of the framed photo relative to the canvas (fit), 0.5...1.
    var photoSize: Double = 0.80

    // Shadow under the framed photo (needs a canvas)
    var shadowEnabled = false
    var shadowOpacity: Double = 0.5   // 0...1
    var shadowSoftness: Double = 0.4  // 0...1
    var shadowDistance: Double = 0.3  // 0...1

    // Camera settings text (needs a canvas)
    var captionEnabled = false
    var captionFontFamily = "Helvetica Neue"
    var captionFontName = "HelveticaNeue"
    /// Font size as a fraction of the canvas' shorter side.
    var captionSize: Double = 0.022
    /// Letter spacing in ems.
    var captionSpacing: Double = 0.08
    var captionColor: RGBA = .white
    var captionPosition: CaptionPosition = .below
    var captionAlign: CaptionAlign = .center
    /// Offsets as a fraction of half the canvas width / height. +Y moves down.
    var captionOffsetX: Double = 0
    var captionOffsetY: Double = 0

    static let photoSizeRange: ClosedRange<Double> = 0.5...1.0

    /// Decodes saved settings, filling in defaults for any keys added in newer versions.
    static func decodeLenient(_ data: Data) -> Style? {
        guard var base = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(Style()))) as? [String: Any],
              let saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        for (k, v) in saved where base[k] != nil { base[k] = v }
        guard let merged = try? JSONSerialization.data(withJSONObject: base) else { return nil }
        return try? JSONDecoder().decode(Style.self, from: merged)
    }
}

enum CaptionPosition: String, Codable, CaseIterable, Identifiable {
    case above, below
    var id: Self { self }
    var title: String { self == .above ? "Above Photo" : "Below Photo" }
}

enum CaptionAlign: String, Codable, CaseIterable, Identifiable {
    case left, center, right
    var id: Self { self }
    var symbol: String {
        switch self {
        case .left: return "text.alignleft"
        case .center: return "text.aligncenter"
        case .right: return "text.alignright"
        }
    }
}

// MARK: - Export options

enum ExportFormat: String, Codable, CaseIterable, Identifiable {
    case jpeg, png, tiff, heic
    var id: Self { self }

    var title: String {
        switch self {
        case .jpeg: return "JPEG"
        case .png: return "PNG (lossless)"
        case .tiff: return "TIFF (lossless)"
        case .heic: return "HEIC"
        }
    }

    var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .png: return "png"
        case .tiff: return "tif"
        case .heic: return "heic"
        }
    }

    var utType: UTType {
        switch self {
        case .jpeg: return .jpeg
        case .png: return .png
        case .tiff: return .tiff
        case .heic: return .heic
        }
    }

    var isLossy: Bool { self == .jpeg || self == .heic }
}

struct ExportOptions: Codable, Equatable {
    var format: ExportFormat = .jpeg
    var quality: Double = 1.0
    var keepMetadata = true
    var suffix = "-framed"
}
