import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import Foundation
import ImageIO

/// Geometry of the output, in export pixels (CoreGraphics y-up coordinates).
/// The photo is always placed at its native pixel size, so the canvas is derived from it.
struct CanvasLayout: Equatable {
    var canvasWidth: Int
    var canvasHeight: Int
    var frame: CGRect
    var photo: CGRect
    var borderPx: Int

    var megapixels: Double { Double(canvasWidth) * Double(canvasHeight) / 1_000_000 }

    static func make(photoWidth pw: Int, photoHeight ph: Int, style: Style) -> CanvasLayout {
        let b = max(0, Int((Double(min(pw, ph)) * style.borderWidth).rounded()))
        let fw = pw + 2 * b, fh = ph + 2 * b

        if style.backgroundMode == .none {
            return CanvasLayout(canvasWidth: fw, canvasHeight: fh,
                                frame: CGRect(x: 0, y: 0, width: fw, height: fh),
                                photo: CGRect(x: b, y: b, width: pw, height: ph),
                                borderPx: b)
        }

        // The framed photo "fits" inside the canvas at `photoSize` of the available space.
        let a = style.aspect.ratio
        let s = min(max(style.photoSize, 0.05), 1)
        let ch = max(Double(fw) / a, Double(fh)) / s
        let CH = max(Int(ch.rounded()), fh)
        let CW = max(Int((ch * a).rounded()), fw)
        let fx = (CW - fw) / 2, fy = (CH - fh) / 2
        return CanvasLayout(canvasWidth: CW, canvasHeight: CH,
                            frame: CGRect(x: fx, y: fy, width: fw, height: fh),
                            photo: CGRect(x: fx + b, y: fy + b, width: pw, height: ph),
                            borderPx: b)
    }

    static let maxSide = 60_000
    static let maxMegapixels = 400.0
    var isTooLarge: Bool {
        canvasWidth > Self.maxSide || canvasHeight > Self.maxSide || megapixels > Self.maxMegapixels
    }
}

struct ExportResult {
    let url: URL
    let width: Int
    let height: Int
    let photoRect: CGRect
}

final class Renderer: @unchecked Sendable {
    static let shared = Renderer()

    let ci = CIContext(options: [.cacheIntermediates: false])

    // MARK: Background

    /// Renders the background image (cover-fit, zoom, pan, brightness, blur, grain) at W×H pixels.
    /// All effects are proportional to the canvas size so previews match the export.
    func backgroundImage(_ bg: CGImage, width W: Int, height H: Int, style: Style,
                         colorSpace: CGColorSpace, bitsPerComponent: Int) -> CGImage? {
        let rect = CGRect(x: 0, y: 0, width: W, height: H)
        let bw = CGFloat(bg.width), bh = CGFloat(bg.height)
        let cover = max(CGFloat(W) / bw, CGFloat(H) / bh) * CGFloat(max(style.bgZoom, 1))
        let ox = (bw * cover - CGFloat(W)) / 2
        let oy = (bh * cover - CGFloat(H)) / 2
        let tx = -ox + CGFloat(style.bgPanX) * ox
        let ty = -oy + CGFloat(style.bgPanY) * oy

        var img = CIImage(cgImage: bg)
        if cover < 1 {
            img = img.applyingFilter("CILanczosScaleTransform",
                                     parameters: [kCIInputScaleKey: cover, kCIInputAspectRatioKey: 1.0])
        } else {
            img = img.transformed(by: CGAffineTransform(scaleX: cover, y: cover))
        }
        img = img.transformed(by: CGAffineTransform(translationX: tx, y: ty))
        img = img.clampedToExtent()

        if abs(style.bgBrightness) > 0.001 {
            img = img.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: style.bgBrightness * 2.0])
        }

        let short = Double(min(W, H))
        let radius = style.bgBlur * 0.06 * short
        if radius > 0.25 {
            img = img.applyingGaussianBlur(sigma: radius)
        }
        img = img.cropped(to: rect)

        if style.bgGrain > 0.001, let random = CIFilter.randomGenerator().outputImage {
            let rel = 1.0 / 3000 + style.bgGrainSize * (1.0 / 300 - 1.0 / 3000)
            let cell = max(1.0, rel * short)
            let amt = style.bgGrain * 0.5
            let bias = 0.5 - amt / 2
            // Monochrome noise with a triangular distribution ((r+g)/2), centered on 0.5 (neutral for overlay).
            // Alpha is forced to 1 first: CIColorMatrix un-premultiplies, and the generator's alpha is random.
            let src = CGRect(x: 0, y: 0, width: (Double(W) / cell).rounded(.up) + 2,
                             height: (Double(H) / cell).rounded(.up) + 2)
            let noise = random
                .cropped(to: src)
                .settingAlphaOne(in: src)
                .transformed(by: CGAffineTransform(scaleX: cell, y: cell))
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: amt / 2, y: amt / 2, z: 0, w: 0),
                    "inputGVector": CIVector(x: amt / 2, y: amt / 2, z: 0, w: 0),
                    "inputBVector": CIVector(x: amt / 2, y: amt / 2, z: 0, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 1),
                ])
                .cropped(to: rect)
            // Blend in gamma-encoded space so grain is perceptually even, like film.
            img = noise
                .applyingFilter("CIOverlayBlendMode",
                                parameters: [kCIInputBackgroundImageKey: img.applyingFilter("CILinearToSRGBToneCurve")])
                .applyingFilter("CISRGBToneCurveToLinear")
        }

        let format: CIFormat = bitsPerComponent == 16 ? .RGBA16 : .RGBA8
        return ci.createCGImage(img, from: rect, format: format, colorSpace: colorSpace)
    }

    // MARK: Fills

    static func drawFill(_ fill: Fill, in rect: CGRect, context ctx: CGContext) {
        switch fill.kind {
        case .solid:
            ctx.setFillColor(fill.color.cgColor)
            ctx.fill(rect)
        case .gradient:
            guard let g = CGGradient(colorsSpace: ImageIOHelper.sRGB,
                                     colors: [fill.color.cgColor, fill.color2.cgColor] as CFArray,
                                     locations: [0, 1]) else { return }
            let t = fill.angle * .pi / 180
            let dx = CGFloat(cos(t)), dy = CGFloat(-sin(t)) // y-up: 90° points down the image
            let half = abs(rect.width / 2 * dx) + abs(rect.height / 2 * dy)
            let c = CGPoint(x: rect.midX, y: rect.midY)
            let start = CGPoint(x: c.x - dx * half, y: c.y - dy * half)
            let end = CGPoint(x: c.x + dx * half, y: c.y + dy * half)
            ctx.saveGState()
            ctx.clip(to: rect)
            ctx.drawLinearGradient(g, start: start, end: end,
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            ctx.restoreGState()
        }
    }

    // MARK: Composition

    /// Composes background, border and photo.
    /// - exact: export mode. The canvas is rendered at layout size and the photo is copied pixel-for-pixel.
    /// - scale: preview mode scale factor (ignored when exact).
    func compose(layout: CanvasLayout, exact: Bool, scale: CGFloat = 1,
                 photo: CGImage, background: CGImage?, style: Style, texts: [CanvasText],
                 colorSpace: CGColorSpace, bitsPerComponent: Int) -> CGImage? {
        let W = exact ? layout.canvasWidth : max(1, Int((CGFloat(layout.canvasWidth) * scale).rounded()))
        let H = exact ? layout.canvasHeight : max(1, Int((CGFloat(layout.canvasHeight) * scale).rounded()))
        guard let ctx = ImageIOHelper.makeContext(width: W, height: H, bitsPerComponent: bitsPerComponent,
                                                  colorSpace: colorSpace, opaque: true) else { return nil }
        let full = CGRect(x: 0, y: 0, width: W, height: H)

        switch style.backgroundMode {
        case .none:
            break
        case .color:
            Self.drawFill(style.backgroundFill, in: full, context: ctx)
        case .image:
            if let background,
               let bg = backgroundImage(background, width: W, height: H, style: style,
                                        colorSpace: colorSpace, bitsPerComponent: bitsPerComponent) {
                ctx.interpolationQuality = .none
                ctx.draw(bg, in: full)
            } else {
                Self.drawFill(style.backgroundFill, in: full, context: ctx)
            }
        }

        let sx = CGFloat(W) / CGFloat(layout.canvasWidth)
        let sy = CGFloat(H) / CGFloat(layout.canvasHeight)
        func snap(_ r: CGRect) -> CGRect {
            if exact { return r }
            let x0 = (r.minX * sx).rounded(), y0 = (r.minY * sy).rounded()
            let x1 = (r.maxX * sx).rounded(), y1 = (r.maxY * sy).rounded()
            return CGRect(x: x0, y: y0, width: max(1, x1 - x0), height: max(1, y1 - y0))
        }
        let frameRect = snap(layout.frame)
        let photoRect = snap(layout.photo)
        let hasCanvas = style.backgroundMode != .none

        if hasCanvas, style.shadowEnabled, style.shadowOpacity > 0.001,
           let (shadow, rect) = shadowLayer(frame: frameRect, width: W, height: H, style: style,
                                            colorSpace: colorSpace) {
            ctx.interpolationQuality = .none
            ctx.draw(shadow, in: rect)
        }

        // Border fill sits behind the whole framed area (also shows through transparent photos).
        if layout.borderPx > 0 || style.backgroundMode == .none {
            Self.drawFill(style.borderFill, in: frameRect, context: ctx)
        }

        ctx.interpolationQuality = exact ? .none : .high
        ctx.draw(photo, in: photoRect)

        if hasCanvas, !texts.isEmpty {
            Self.drawTexts(texts, style: style, frame: frameRect, width: W, height: H, context: ctx)
        }
        return ctx.makeImage()
    }

    /// Soft drop shadow under the framed photo, rendered with Core Image so its softness scales with the canvas.
    func shadowLayer(frame: CGRect, width W: Int, height H: Int, style: Style,
                     colorSpace: CGColorSpace) -> (CGImage, CGRect)? {
        let short = Double(min(W, H))
        let sigma = style.shadowSoftness * 0.05 * short
        let dist = style.shadowDistance * 0.03 * short
        let rect = frame.offsetBy(dx: 0, dy: -dist)
        let pad = sigma * 3 + 2
        let bounds = rect.insetBy(dx: -pad, dy: -pad).integral
            .intersection(CGRect(x: 0, y: 0, width: W, height: H))
        guard !bounds.isEmpty else { return nil }
        var img = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: style.shadowOpacity)).cropped(to: rect)
        if sigma > 0.3 { img = img.applyingGaussianBlur(sigma: sigma) }
        guard let cg = ci.createCGImage(img.cropped(to: bounds), from: bounds, format: .RGBA8, colorSpace: colorSpace)
        else { return nil }
        return (cg, bounds)
    }

    /// Draws text lines above or below the framed photo. Offsets arrive already resolved (see CanvasText.lines).
    /// - Lines in the same spot (position + alignment) stack as consecutive lines in the given order.
    /// - Lines on the same side with different alignments share a row unless they would collide (after their
    ///   horizontal offsets), in which case the later one drops to the next row.
    static func drawTexts(_ items: [CanvasText], style: Style, frame: CGRect, width W: Int, height H: Int,
                          context ctx: CGContext) {
        let size = CGFloat(style.captionSize) * CGFloat(min(W, H))
        guard size >= 1 else { return }
        let font = CTFontCreateWithName(style.captionFontName as CFString, size, nil)
        let kern = CGFloat(style.captionSpacing) * size
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): style.captionColor.cgColor,
            NSAttributedString.Key(kCTKernAttributeName as String): kern,
        ]
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        let lineHeight = (ascent + descent) * 1.25
        let gap = size * 0.9          // between the frame and the nearest row
        let minSpace = size * 1.0     // horizontal clearance between lines sharing a row
        let unitX = CGFloat(W) * 0.5, unitY = CGFloat(H) * 0.5

        struct Placed { let line: CTLine; let x: CGFloat; let row: Int; let dx: CGFloat; let dy: CGFloat }

        ctx.saveGState()
        ctx.setShouldAntialias(true)
        ctx.setShouldSmoothFonts(false)
        ctx.textMatrix = .identity

        for position in [CaptionPosition.below, .above] {
            var rows: [[ClosedRange<CGFloat>]] = []
            var lastRow: [CaptionAlign: Int] = [:]
            var placed: [Placed] = []

            for item in items where item.position == position && !item.text.isEmpty {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: item.text, attributes: attrs))
                // Drop the trailing letter-spacing so centered/right-aligned text lines up with the frame.
                let width = max(0, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) - kern)
                let x: CGFloat
                switch item.align {
                case .left: x = frame.minX
                case .center: x = frame.midX - width / 2
                case .right: x = frame.maxX - width
                }
                let dx = CGFloat(item.offsetX) * unitX, dy = CGFloat(item.offsetY) * unitY
                let span = (x + dx - minSpace / 2)...(x + dx + width + minSpace / 2)
                var row = lastRow[item.align].map { $0 + 1 } ?? 0
                while row < rows.count, rows[row].contains(where: { $0.overlaps(span) }) { row += 1 }
                while rows.count <= row { rows.append([]) }
                rows[row].append(span)
                lastRow[item.align] = row
                placed.append(Placed(line: line, x: x, row: row, dx: dx, dy: dy))
            }

            let rowCount = rows.count
            for p in placed {
                // Reading order is top to bottom on both sides of the photo.
                var baseline: CGFloat
                switch position {
                case .below: baseline = frame.minY - gap - ascent - CGFloat(p.row) * lineHeight
                case .above: baseline = frame.maxY + gap + descent + CGFloat(rowCount - 1 - p.row) * lineHeight
                }
                baseline -= p.dy
                ctx.textPosition = CGPoint(x: p.x + p.dx, y: baseline)
                CTLineDraw(p.line, ctx)
            }
        }
        ctx.restoreGState()
    }

    func renderPreview(photo: CGImage, photoWidth: Int, photoHeight: Int,
                       background: CGImage?, style: Style, texts: [CanvasText], maxPixelSize: CGSize) -> CGImage? {
        let layout = CanvasLayout.make(photoWidth: photoWidth, photoHeight: photoHeight, style: style)
        let scale = min(maxPixelSize.width / CGFloat(layout.canvasWidth),
                        maxPixelSize.height / CGFloat(layout.canvasHeight))
        return compose(layout: layout, exact: false, scale: max(scale, 0.01),
                       photo: photo, background: background, style: style, texts: texts,
                       colorSpace: ImageIOHelper.workingColorSpace(for: photo), bitsPerComponent: 8)
    }

    // MARK: Export

    func export(photoURL: URL, backgroundURL: URL?, style: Style, texts: [CanvasText],
                options: ExportOptions, to outURL: URL) throws -> ExportResult {
        let (photo, info) = try ImageIOHelper.fullImage(photoURL)
        let layout = CanvasLayout.make(photoWidth: photo.width, photoHeight: photo.height, style: style)
        if layout.isTooLarge { throw ImageError.tooLarge(layout.canvasWidth, layout.canvasHeight) }

        let cs = ImageIOHelper.workingColorSpace(for: photo)
        let bpc = ImageIOHelper.bitsPerComponent(for: photo)
        var bg: CGImage?
        if style.backgroundMode == .image, let backgroundURL {
            bg = try ImageIOHelper.fullImage(backgroundURL).0
        }
        guard let out = compose(layout: layout, exact: true, photo: photo, background: bg, style: style,
                                texts: texts, colorSpace: cs, bitsPerComponent: bpc)
        else { throw ImageError.renderFailed("couldn’t create a \(layout.canvasWidth) × \(layout.canvasHeight) canvas") }

        try write(out, to: outURL, options: options, sourceProperties: info.properties)
        return ExportResult(url: outURL, width: out.width, height: out.height, photoRect: layout.photo)
    }

    func write(_ image: CGImage, to url: URL, options: ExportOptions, sourceProperties: [String: Any]) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, options.format.utType.identifier as CFString, 1, nil)
        else { throw ImageError.writeFailed(url) }

        var props: [CFString: Any] = [kCGImagePropertyOrientation: 1]
        if options.format.isLossy {
            props[kCGImageDestinationLossyCompressionQuality] = options.quality
        }
        if let v = sourceProperties[kCGImagePropertyDPIWidth as String] { props[kCGImagePropertyDPIWidth] = v }
        if let v = sourceProperties[kCGImagePropertyDPIHeight as String] { props[kCGImagePropertyDPIHeight] = v }

        if options.keepMetadata {
            if var exif = sourceProperties[kCGImagePropertyExifDictionary as String] as? [String: Any] {
                exif[kCGImagePropertyExifPixelXDimension as String] = image.width
                exif[kCGImagePropertyExifPixelYDimension as String] = image.height
                props[kCGImagePropertyExifDictionary] = exif
            }
            if var tiff = sourceProperties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
                tiff[kCGImagePropertyTIFFOrientation as String] = 1
                props[kCGImagePropertyTIFFDictionary] = tiff
            }
            if let iptc = sourceProperties[kCGImagePropertyIPTCDictionary as String] {
                props[kCGImagePropertyIPTCDictionary] = iptc
            }
        }
        if options.format == .tiff {
            var tiff = (props[kCGImagePropertyTIFFDictionary] as? [String: Any]) ?? [:]
            tiff[kCGImagePropertyTIFFCompression as String] = 5 // LZW, lossless
            props[kCGImagePropertyTIFFDictionary] = tiff
        }

        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ImageError.writeFailed(url) }
    }
}
