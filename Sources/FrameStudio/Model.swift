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

    // Second text line: camera model, copyright, location or custom text.
    // Uses the same font, size, spacing and color as the camera settings text.
    var infoEnabled = false
    var infoSource: InfoSource = .camera
    /// Used when `infoSource == .custom`; the same text on every photo.
    var infoCustomText = ""
    /// Film simulation for photos whose metadata doesn't record one ("" = none).
    var infoFilmFallback = ""
    /// `.auto` = opposite of the camera settings text.
    var infoPosition: InfoPlacement = .auto
    var infoAlign: InfoAlignment = .auto
    var infoOffsetX: Double = 0
    var infoOffsetY: Double = 0

    var resolvedInfoPosition: CaptionPosition {
        switch infoPosition {
        case .auto: return captionPosition == .below ? .above : .below
        case .above: return .above
        case .below: return .below
        }
    }

    var resolvedInfoAlign: CaptionAlign {
        switch infoAlign {
        case .auto:
            switch captionAlign {
            case .left: return .right
            case .right: return .left
            case .center: return .center
            }
        case .left: return .left
        case .center: return .center
        case .right: return .right
        }
    }

    static let photoSizeRange: ClosedRange<Double> = 0.5...1.0

    /// Decodes saved settings, filling in defaults for any keys added in newer versions.
    static func decodeLenient(_ data: Data) -> Style? {
        Lenient.decode(data, onto: Style())
    }
}

enum CaptionPosition: String, Codable, CaseIterable, Identifiable {
    case above, below
    var id: Self { self }
    var title: String { self == .above ? "Above" : "Below" }
}

enum InfoSource: String, Codable, CaseIterable, Identifiable {
    case camera, filmSimulation, copyright, location, custom
    var id: Self { self }
    var title: String {
        switch self {
        case .camera: return "Camera model"
        case .filmSimulation: return "Film simulation"
        case .copyright: return "Copyright"
        case .location: return "Location"
        case .custom: return "Custom text"
        }
    }
}

enum FilmSimulation {
    /// Fujifilm film simulations, for the dropdown used when a photo doesn't record one.
    static let all = [
        "Provia", "Velvia", "Astia", "Classic Chrome", "Reala Ace", "Pro Neg. Hi", "Pro Neg. Std",
        "Classic Neg.", "Nostalgic Neg.", "Eterna", "Eterna Bleach Bypass",
        "Acros", "Acros + Ye", "Acros + R", "Acros + G",
        "Monochrome", "Monochrome + Ye", "Monochrome + R", "Monochrome + G", "Sepia",
    ]

    /// Maps a Lightroom camera-matching profile name (e.g. "Camera CLASSIC CHROME",
    /// "Camera PROVIA/Standard", "Camera ACROS+R FILTER") to a film simulation name, or nil.
    static func fromCameraProfile(_ profile: String) -> String? {
        let key = profile.uppercased().filter { $0.isLetter || $0 == "+" }
        guard key.hasPrefix("CAMERA") else { return nil }
        let k = String(key.dropFirst("CAMERA".count))
        func filter(_ base: String) -> String {
            if k.contains("+YE") { return base + " + Ye" }
            if k.contains("+R") { return base + " + R" }
            if k.contains("+G") { return base + " + G" }
            return base
        }
        if k.hasPrefix("PROVIA") { return "Provia" }
        if k.hasPrefix("VELVIA") { return "Velvia" }
        if k.hasPrefix("ASTIA") { return "Astia" }
        if k.hasPrefix("CLASSICCHROME") { return "Classic Chrome" }
        if k.hasPrefix("REALA") { return "Reala Ace" }
        if k.hasPrefix("PRONEGHI") { return "Pro Neg. Hi" }
        if k.hasPrefix("PRONEGSTD") { return "Pro Neg. Std" }
        if k.hasPrefix("CLASSICNEG") { return "Classic Neg." }
        if k.hasPrefix("NOSTALGIC") { return "Nostalgic Neg." }
        if k.hasPrefix("ETERNABLEACH") { return "Eterna Bleach Bypass" }
        if k.hasPrefix("ETERNA") { return "Eterna" }
        if k.hasPrefix("ACROS") { return filter("Acros") }
        if k.hasPrefix("MONOCHROME") { return filter("Monochrome") }
        if k.hasPrefix("SEPIA") { return "Sepia" }
        return nil
    }
}

enum InfoPlacement: String, Codable, CaseIterable, Identifiable {
    case auto, above, below
    var id: Self { self }
    var title: String {
        switch self {
        case .auto: return "Auto"
        case .above: return "Above"
        case .below: return "Below"
        }
    }
}

enum InfoAlignment: String, Codable, CaseIterable, Identifiable {
    case auto, left, center, right
    var id: Self { self }
}

/// One line of text drawn above or below the framed photo.
struct CanvasText: Equatable {
    var text: String
    var position: CaptionPosition
    var align: CaptionAlign
    var offsetX: Double
    var offsetY: Double

    /// The text lines for a photo: camera settings first, then the second line.
    static func lines(style: Style, info: ImageInfo, cameraText: String?, infoText: String?) -> [CanvasText] {
        var out: [CanvasText] = []
        if style.captionEnabled {
            let t = (cameraText ?? info.cameraSettings).trimmingCharacters(in: .whitespaces)
            if !t.isEmpty {
                out.append(CanvasText(text: t, position: style.captionPosition, align: style.captionAlign,
                                      offsetX: style.captionOffsetX, offsetY: style.captionOffsetY))
            }
        }
        if style.infoEnabled {
            let base = style.infoSource == .custom ? style.infoCustomText : (infoText ?? info.infoDefault(style))
            let t = base.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty {
                // On the camera settings' side the second line moves up/down with them, and in their exact
                // spot also left/right; its own offsets then nudge it from there. This uses the style, not
                // the camera line, so photos without camera data place it the same way as the rest of a batch.
                let pos = style.resolvedInfoPosition, align = style.resolvedInfoAlign
                let sameSide = style.captionEnabled && pos == style.captionPosition
                let sameSpot = sameSide && align == style.captionAlign
                out.append(CanvasText(text: t, position: pos, align: align,
                                      offsetX: style.infoOffsetX + (sameSpot ? style.captionOffsetX : 0),
                                      offsetY: style.infoOffsetY + (sameSide ? style.captionOffsetY : 0)))
            }
        }
        return out
    }
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

// MARK: - Lenient decoding

enum Lenient {
    /// Decodes a top-level JSON object onto `fallback`'s values: keys missing from the saved data (added in
    /// newer versions) keep their defaults, and unknown keys are ignored. Returns nil if the result still
    /// doesn't decode (e.g. an unknown enum value).
    static func decode<T: Codable>(_ object: [String: Any], onto fallback: T) -> T? {
        guard var base = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(fallback))) as? [String: Any]
        else { return nil }
        for (k, v) in object where base[k] != nil { base[k] = v }
        guard let merged = try? JSONSerialization.data(withJSONObject: base) else { return nil }
        return try? JSONDecoder().decode(T.self, from: merged)
    }

    static func decode<T: Codable>(_ data: Data, onto fallback: T) -> T? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return decode(object, onto: fallback)
    }

    static func object<T: Encodable>(_ value: T) -> [String: Any] {
        ((try? JSONSerialization.jsonObject(with: JSONEncoder().encode(value))) as? [String: Any]) ?? [:]
    }
}

// MARK: - Presets

/// A named snapshot of every setting and slider: style and export options.
/// It does not include which background image is loaded, or per-photo text edits.
struct Preset: Identifiable, Equatable {
    var id = UUID()
    var name: String
    var style: Style
    var export: ExportOptions

    var jsonObject: [String: Any] {
        ["id": id.uuidString, "name": name, "style": Lenient.object(style), "export": Lenient.object(export)]
    }

    init(id: UUID = UUID(), name: String, style: Style, export: ExportOptions) {
        self.id = id; self.name = name; self.style = style; self.export = export
    }

    /// Reads a preset saved by this or an older version of the app.
    init?(jsonObject o: [String: Any]) {
        guard let name = o["name"] as? String, let styleObject = o["style"] as? [String: Any],
              let style = Lenient.decode(styleObject, onto: Style()) else { return nil }
        self.id = (o["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
        self.name = name
        self.style = style
        self.export = (o["export"] as? [String: Any]).flatMap { Lenient.decode($0, onto: ExportOptions()) } ?? ExportOptions()
    }
}
