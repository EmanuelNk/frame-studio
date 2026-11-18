import CoreGraphics
import Foundation
import ImageIO

struct ImageInfo {
    /// Pixel size after applying EXIF orientation (i.e. as displayed).
    let width: Int
    let height: Int
    let orientation: Int
    let properties: [String: Any]
    /// Lightroom's camera profile from XMP (crs:CameraProfile), e.g. "Camera CLASSIC CHROME".
    var cameraProfile: String? = nil
    /// Lightroom profile applied as a look on top of the base profile (crs:Look's crs:Name),
    /// e.g. "Camera CLASSIC Neg" over a "Camera PROVIA/Standard" base on newer Fuji bodies.
    var cameraLook: String? = nil

    var shortSide: Int { min(width, height) }
    var megapixels: Double { Double(width * height) / 1_000_000 }

    /// Shutter speed, aperture, focal length and ISO from EXIF, e.g. "1/250s   f/2.8   35mm   ISO 400".
    var cameraSettings: String {
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        func num(_ k: CFString) -> Double? { (exif[k as String] as? NSNumber)?.doubleValue }
        var parts: [String] = []
        if let t = num(kCGImagePropertyExifExposureTime), t > 0 {
            if t < 0.3 {
                parts.append("1/\(Int((1 / t).rounded()))s")
            } else {
                parts.append(t == t.rounded() ? "\(Int(t))s" : String(format: "%.1fs", t))
            }
        }
        if let f = num(kCGImagePropertyExifFNumber), f > 0 {
            var s = String(format: "%.1f", f)
            if s.hasSuffix(".0") { s.removeLast(2) }
            parts.append("f/\(s)")
        }
        if let fl = num(kCGImagePropertyExifFocalLength), fl > 0 {
            parts.append("\(Int(fl.rounded()))mm")
        }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.intValue {
            parts.append("ISO \(iso)")
        }
        return parts.joined(separator: "   ")
    }

    private func dict(_ key: CFString) -> [String: Any] { properties[key as String] as? [String: Any] ?? [:] }
    private func str(_ d: [String: Any], _ key: CFString) -> String? {
        let raw: String?
        if let s = d[key as String] as? String { raw = s }
        else if let a = d[key as String] as? [String] { raw = a.first }
        else { raw = nil }
        let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (t?.isEmpty ?? true) ? nil : t
    }

    var cameraMake: String { str(dict(kCGImagePropertyTIFFDictionary), kCGImagePropertyTIFFMake) ?? "" }
    var isFujifilm: Bool { cameraMake.uppercased().contains("FUJI") }

    /// The camera's brand from the EXIF make, without company suffixes:
    /// "NIKON CORPORATION" → "NIKON", "OLYMPUS OPTICAL CO.,LTD" → "OLYMPUS", "OM Digital Solutions" → "OM SYSTEM".
    var cameraBrand: String {
        var words = cameraMake.components(separatedBy: CharacterSet(charactersIn: " ,"))
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty }
        // 1. Legal-entity suffixes.
        let company: Set<String> = ["CORPORATION", "CORP", "CO", "LTD", "LIMITED", "INC", "COMPANY", "AG", "GMBH", "KK", "LLC", "SA"]
        while words.count > 1, let last = words.last, company.contains(last.uppercased()) { words.removeLast() }
        // 2. Well-known makers whose name is more than the brand.
        let known: [String: String] = [
            "FUJI PHOTO FILM": "FUJIFILM", "OM DIGITAL SOLUTIONS": "OM SYSTEM", "EASTMAN KODAK": "KODAK",
            "SAMSUNG TECHWIN": "SAMSUNG", "KONICA MINOLTA CAMERA": "Konica Minolta",
            "KONICA MINOLTA PHOTO IMAGING": "Konica Minolta", "SEIKO EPSON": "EPSON", "LG ELECTRONICS": "LG",
            "CASIO COMPUTER": "CASIO", "SANYO ELECTRIC": "SANYO",
        ]
        if let k = known[words.joined(separator: " ").uppercased()] { return k }
        // 3. Descriptive words after the brand ("LEICA CAMERA", "RICOH IMAGING", "OLYMPUS OPTICAL").
        let descriptive: Set<String> = ["IMAGING", "CAMERA", "CAMERAS", "OPTICAL", "DIGITAL", "SOLUTIONS",
                                        "ELECTRIC", "ELECTRONICS", "COMPUTER", "PHOTO"]
        while words.count > 1, let last = words.last, descriptive.contains(last.uppercased()) { words.removeLast() }
        return words.joined(separator: " ")
    }

    /// e.g. "FUJIFILM X-E5", "NIKON Z 6_2", "Canon EOS R5", "Phase One IQ4 150MP". The brand is shown once.
    var cameraModel: String {
        let brand = cameraBrand
        let model = str(dict(kCGImagePropertyTIFFDictionary), kCGImagePropertyTIFFModel) ?? ""
        if model.isEmpty { return brand }
        if brand.isEmpty { return model }
        let m = model.uppercased(), b = brand.uppercased()
        // The model already names the brand: "Canon EOS R5", "KODAK EASYSHARE M550", "OM-1".
        if m.contains(b) { return model }
        if let first = b.split(separator: " ").first, m.hasPrefix(first),
           m.dropFirst(first.count).first.map({ !$0.isLetter }) ?? true {
            return model
        }
        // Models that carry their own brand, e.g. Ricoh's "PENTAX K-3 Mark III".
        let firstWord = m.split(separator: " ").first.map(String.init) ?? ""
        if ["PENTAX", "HASSELBLAD", "LEICA", "NIKON", "OLYMPUS", "SIGMA", "PANASONIC", "LUMIX"].contains(firstWord) {
            return model
        }
        return "\(brand) \(model)"
    }

    /// Copyright notice; falls back to "© <year> <artist>".
    var copyright: String {
        let tiff = dict(kCGImagePropertyTIFFDictionary)
        let iptc = dict(kCGImagePropertyIPTCDictionary)
        if let c = str(tiff, kCGImagePropertyTIFFCopyright) ?? str(iptc, kCGImagePropertyIPTCCopyrightNotice) {
            return c
        }
        if let artist = str(tiff, kCGImagePropertyTIFFArtist) ?? str(iptc, kCGImagePropertyIPTCByline) {
            let date = str(dict(kCGImagePropertyExifDictionary), kCGImagePropertyExifDateTimeOriginal) ?? ""
            let year = date.count >= 4 ? String(date.prefix(4)) : ""
            return year.isEmpty ? "© \(artist)" : "© \(year) \(artist)"
        }
        return ""
    }

    /// Place name from IPTC (e.g. "Lisbon, Lisboa, Portugal"); falls back to GPS coordinates.
    var location: String {
        let iptc = dict(kCGImagePropertyIPTCDictionary)
        let place = [kCGImagePropertyIPTCCity, kCGImagePropertyIPTCProvinceState, kCGImagePropertyIPTCCountryPrimaryLocationName]
            .compactMap { str(iptc, $0) }
        if !place.isEmpty { return place.joined(separator: ", ") }
        let gps = dict(kCGImagePropertyGPSDictionary)
        if let lat = (gps[kCGImagePropertyGPSLatitude as String] as? NSNumber)?.doubleValue,
           let lon = (gps[kCGImagePropertyGPSLongitude as String] as? NSNumber)?.doubleValue {
            let ns = str(gps, kCGImagePropertyGPSLatitudeRef) ?? "N"
            let ew = str(gps, kCGImagePropertyGPSLongitudeRef) ?? "E"
            return String(format: "%.4f° %@, %.4f° %@", lat, ns, lon, ew)
        }
        return ""
    }

    /// Film simulation from Lightroom's Fujifilm camera-matching profile, or "".
    /// The look (what the user picked) wins over the base profile underneath it.
    var filmSimulation: String {
        // Other makers ship look-alike profile names (e.g. Canon/Nikon "Camera Monochrome"); only Fujifilm
        // has film simulations.
        guard isFujifilm else { return "" }
        return cameraLook.flatMap(FilmSimulation.fromCameraProfile)
            ?? cameraProfile.flatMap(FilmSimulation.fromCameraProfile)
            ?? ""
    }

    func metadataText(_ source: InfoSource) -> String {
        switch source {
        case .camera: return cameraModel
        case .filmSimulation: return filmSimulation
        case .copyright: return copyright
        case .location: return location
        case .custom: return ""
        }
    }

    /// Default second-line text: the photo's metadata. For film simulation on a Fujifilm photo that
    /// doesn't record one, the chosen default; other cameras have no film simulations, so they get none.
    func infoDefault(_ style: Style) -> String {
        let t = metadataText(style.infoSource)
        if t.isEmpty, style.infoSource == .filmSimulation, isFujifilm { return style.infoFilmFallback }
        return t
    }
}

enum ImageError: LocalizedError {
    case unreadable(URL)
    case decodeFailed(URL)
    case renderFailed(String)
    case writeFailed(URL)
    case tooLarge(Int, Int)

    var errorDescription: String? {
        switch self {
        case .unreadable(let u): return "“\(u.lastPathComponent)” isn’t an image this app can read."
        case .decodeFailed(let u): return "Couldn’t decode “\(u.lastPathComponent)”."
        case .renderFailed(let s): return "Rendering failed: \(s)"
        case .writeFailed(let u): return "Couldn’t write “\(u.lastPathComponent)”."
        case .tooLarge(let w, let h):
            return "The output would be \(w) × \(h) px, which is too large. Increase Photo Size or reduce the border."
        }
    }
}

enum ImageIOHelper {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    static func source(_ url: URL) throws -> CGImageSource {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0
        else { throw ImageError.unreadable(url) }
        return src
    }

    static func info(_ url: URL) throws -> ImageInfo {
        let src = try source(url)
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
              let w = (props[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue
        else { throw ImageError.unreadable(url) }
        let o = (props[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1
        let swap = (5...8).contains(o)
        var profile: String?, look: String?
        if let meta = CGImageSourceCopyMetadataAtIndex(src, 0, nil) {
            profile = CGImageMetadataCopyStringValueWithPath(meta, nil, "crs:CameraProfile" as CFString) as String?
            look = CGImageMetadataCopyStringValueWithPath(meta, nil, "crs:Look.crs:Name" as CFString) as String?
        }
        return ImageInfo(width: swap ? h : w, height: swap ? w : h, orientation: o, properties: props,
                         cameraProfile: profile, cameraLook: look)
    }

    /// A downsampled, orientation-corrected image for previews and thumbnails.
    static func thumbnail(_ url: URL, maxPixel: Int) throws -> CGImage {
        let src = try source(url)
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            throw ImageError.decodeFailed(url)
        }
        return img
    }

    /// The full-resolution image with EXIF orientation applied by exact pixel moves (no resampling).
    static func fullImage(_ url: URL) throws -> (CGImage, ImageInfo) {
        let src = try source(url)
        let info = try info(url)
        guard let raw = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw ImageError.decodeFailed(url)
        }
        if info.orientation == 1 { return (raw, info) }
        guard let oriented = reorient(raw, orientation: info.orientation) else { throw ImageError.decodeFailed(url) }
        return (oriented, info)
    }

    /// Color space used to composite a given image without converting its pixels.
    static func workingColorSpace(for image: CGImage) -> CGColorSpace {
        if let cs = image.colorSpace, cs.model == .rgb { return cs }
        return sRGB
    }

    static func bitsPerComponent(for image: CGImage) -> Int {
        image.bitsPerComponent >= 16 ? 16 : 8
    }

    static func makeContext(width: Int, height: Int, bitsPerComponent: Int, colorSpace: CGColorSpace, opaque: Bool) -> CGContext? {
        let alpha: CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
        return CGContext(data: nil, width: width, height: height,
                         bitsPerComponent: bitsPerComponent, bytesPerRow: 0,
                         space: colorSpace, bitmapInfo: alpha.rawValue)
    }

    /// Applies EXIF orientation 2...8 using 90° rotations / mirrors only.
    static func reorient(_ img: CGImage, orientation o: Int) -> CGImage? {
        let w = CGFloat(img.width), h = CGFloat(img.height)
        let swap = (5...8).contains(o)
        let W = swap ? h : w, H = swap ? w : h
        let t: CGAffineTransform
        switch o {
        case 2: t = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: W, ty: 0)
        case 3: t = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: W, ty: H)
        case 4: t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: H)
        case 5: t = CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: W, ty: H)
        case 6: t = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: H)
        case 7: t = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case 8: t = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: W, ty: 0)
        default: return img
        }
        let cs = workingColorSpace(for: img)
        guard let ctx = makeContext(width: Int(W), height: Int(H),
                                    bitsPerComponent: bitsPerComponent(for: img),
                                    colorSpace: cs, opaque: false) else { return nil }
        ctx.interpolationQuality = .none
        ctx.concatenate(t)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
