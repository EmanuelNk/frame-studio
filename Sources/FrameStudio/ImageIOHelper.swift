import CoreGraphics
import Foundation
import ImageIO

struct ImageInfo {
    /// Pixel size after applying EXIF orientation (i.e. as displayed).
    let width: Int
    let height: Int
    let orientation: Int
    let properties: [String: Any]

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
        return ImageInfo(width: swap ? h : w, height: swap ? w : h, orientation: o, properties: props)
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
