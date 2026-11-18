import AppKit
import CoreGraphics
import Foundation
import ImageIO

/// Hidden command-line mode used for headless testing and for generating the app icon.
///   FrameStudio --cli render --photo P [--bg B] [--style JSON] --out O [--format jpeg|png|tiff|heic] [--quality 1] [--preview PX]
///   FrameStudio --cli verify --photo P --out O [--style JSON]
///   FrameStudio --cli icon --out icon.png
enum CLI {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--cli"), i + 1 < args.count else { return }
        let cmd = args[i + 1]
        var opts: [String: String] = [:]
        var k = i + 2
        while k < args.count {
            if args[k].hasPrefix("--"), k + 1 < args.count { opts[String(args[k].dropFirst(2))] = args[k + 1]; k += 2 } else { k += 1 }
        }
        do {
            switch cmd {
            case "render": try render(opts)
            case "verify": try verify(opts)
            case "icon": try icon(opts)
            case "orient": try orientCheck(opts)
            default: print("unknown command \(cmd)"); exit(2)
            }
            exit(0)
        } catch {
            FileHandle.standardError.write("error: \(error.localizedDescription)\n".data(using: .utf8)!)
            exit(1)
        }
    }

    static func style(_ json: String?) throws -> Style {
        guard let json, !json.isEmpty else { return Style() }
        var base = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Style())) as! [String: Any]
        let patch = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        for (key, v) in patch { base[key] = v }
        return try JSONDecoder().decode(Style.self, from: JSONSerialization.data(withJSONObject: base))
    }

    static func render(_ o: [String: String]) throws {
        let photo = URL(fileURLWithPath: o["photo"]!)
        let bg = o["bg"].map { URL(fileURLWithPath: $0) }
        let out = URL(fileURLWithPath: o["out"]!)
        let st = try style(o["style"])
        var ex = ExportOptions()
        if let f = o["format"], let fmt = ExportFormat(rawValue: f) { ex.format = fmt }
        if let q = o["quality"], let qv = Double(q) { ex.quality = qv }

        if let p = o["preview"], let px = Double(p) {
            let info = try ImageIOHelper.info(photo)
            let thumb = try ImageIOHelper.thumbnail(photo, maxPixel: 2048)
            let bgThumb = try bg.map { try ImageIOHelper.thumbnail($0, maxPixel: 2048) }
            var img: CGImage?
            for n in 0..<(Int(o["repeat"] ?? "1") ?? 1) {
                var s2 = st
                s2.bgBlur = st.bgBlur + Double(n) * 0.01 // defeat any caching
                let t0 = Date()
                img = Renderer.shared.renderPreview(photo: thumb, photoWidth: info.width, photoHeight: info.height,
                                                    background: bgThumb, style: s2, caption: o["caption"] ?? info.cameraSettings,
                                                    maxPixelSize: CGSize(width: px, height: px))
                print(String(format: "preview %dx%d in %.0f ms", img?.width ?? 0, img?.height ?? 0, Date().timeIntervalSince(t0) * 1000))
            }
            guard let img else { throw ImageError.renderFailed("preview") }
            try Renderer.shared.write(img, to: out, options: ex, sourceProperties: [:])
            return
        }

        let t0 = Date()
        let r = try Renderer.shared.export(photoURL: photo, backgroundURL: bg, style: st,
                                           caption: o["caption"] ?? (try ImageIOHelper.info(photo)).cameraSettings,
                                           options: ex, to: out)
        print(String(format: "export %dx%d (photo rect %@) in %.2f s", r.width, r.height,
                     NSStringFromRect(r.photoRect), Date().timeIntervalSince(t0)))
    }

    static func verify(_ o: [String: String]) throws {
        let photoURL = URL(fileURLWithPath: o["photo"]!)
        let outURL = URL(fileURLWithPath: o["out"]!)
        let st = try style(o["style"])
        let (src, _) = try ImageIOHelper.fullImage(photoURL)
        let layout = CanvasLayout.make(photoWidth: src.width, photoHeight: src.height, style: st)
        let outSrc = try ImageIOHelper.source(outURL)
        guard let out = CGImageSourceCreateImageAtIndex(outSrc, 0, nil) else { throw ImageError.decodeFailed(outURL) }
        print("output size: \(out.width)x\(out.height)  expected: \(layout.canvasWidth)x\(layout.canvasHeight)")
        print("source profile: \(src.colorSpace?.name as String? ?? "?")  output profile: \(out.colorSpace?.name as String? ?? "?")")
        print("source bpc: \(src.bitsPerComponent)  output bpc: \(out.bitsPerComponent)")

        let r = CGRect(x: layout.photo.minX, y: CGFloat(out.height) - layout.photo.maxY,
                       width: layout.photo.width, height: layout.photo.height)
        guard let crop = out.cropping(to: r) else { throw ImageError.renderFailed("crop") }
        let cs = ImageIOHelper.workingColorSpace(for: src)
        func pixels(_ img: CGImage) -> [UInt8] {
            let w = img.width, h = img.height
            var buf = [UInt8](repeating: 0, count: w * h * 4)
            buf.withUnsafeMutableBytes { p in
                let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                    space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
                ctx.interpolationQuality = .none
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            return buf
        }
        let a = pixels(src), b = pixels(crop)
        var diffPx = 0, maxDiff = 0
        var se = 0.0
        for p in stride(from: 0, to: a.count, by: 4) {
            var d = 0
            for c in 0..<3 {
                let dd = abs(Int(a[p + c]) - Int(b[p + c]))
                d = max(d, dd); se += Double(dd * dd)
            }
            if d > 0 { diffPx += 1 }
            maxDiff = max(maxDiff, d)
        }
        let mse = se / Double(a.count / 4 * 3)
        let psnr = mse == 0 ? Double.infinity : 10 * log10(255 * 255 / mse)
        print(String(format: "photo region %dx%d: differing pixels %d (%.4f%%), max channel diff %d, PSNR %@",
                     src.width, src.height, diffPx, Double(diffPx) / Double(a.count / 4) * 100, maxDiff,
                     psnr.isInfinite ? "∞ (identical)" : String(format: "%.1f dB", psnr)))
    }

    /// Compares our exact reorientation against ImageIO's own transform (downsampled to 256 px).
    static func orientCheck(_ o: [String: String]) throws {
        let url = URL(fileURLWithPath: o["photo"]!)
        let (mine, info) = try ImageIOHelper.fullImage(url)
        let ref = try ImageIOHelper.thumbnail(url, maxPixel: 256)
        func small(_ img: CGImage) -> [UInt8] {
            let w = ref.width, h = ref.height
            var buf = [UInt8](repeating: 0, count: w * h * 4)
            buf.withUnsafeMutableBytes { p in
                let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                    space: ImageIOHelper.sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
                ctx.interpolationQuality = .high
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            return buf
        }
        let a = small(mine), b = small(ref)
        var sum = 0
        for i in 0..<a.count where i % 4 != 3 { sum += abs(Int(a[i]) - Int(b[i])) }
        let mean = Double(sum) / Double(a.count / 4 * 3)
        print(String(format: "orientation %d: oriented %dx%d, ref %dx%d, mean abs diff %.2f → %@",
                     info.orientation, mine.width, mine.height, ref.width, ref.height, mean, mean < 6 ? "OK" : "MISMATCH"))
    }

    // MARK: Icon

    static func icon(_ o: [String: String]) throws {
        let out = URL(fileURLWithPath: o["out"]!)
        let S: CGFloat = 1024
        let cs = ImageIOHelper.sRGB
        guard let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        func c(_ hex: String, _ a: CGFloat = 1) -> CGColor { RGBA(hex: hex)!.cgColor.copy(alpha: a)! }

        // Squircle background
        let bgRect = CGRect(x: 100, y: 100, width: 824, height: 824)
        let squircle = CGPath(roundedRect: bgRect, cornerWidth: 186, cornerHeight: 186, transform: nil)
        ctx.saveGState()
        ctx.addPath(squircle); ctx.clip()
        let bgGrad = CGGradient(colorsSpace: cs, colors: [c("#3A2E2A"), c("#14161C")] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(bgGrad, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
        // Soft "blurred city lights"
        let lights: [(CGFloat, CGFloat, CGFloat, String, CGFloat)] = [
            (230, 760, 150, "#F2A541", 0.35), (820, 300, 190, "#E86A33", 0.30),
            (760, 820, 120, "#F6D186", 0.25), (220, 260, 140, "#8FA3BF", 0.22),
        ]
        for (x, y, r, col, a) in lights {
            let g = CGGradient(colorsSpace: cs, colors: [c(col, a), c(col, 0)] as CFArray, locations: [0, 1])!
            ctx.drawRadialGradient(g, startCenter: CGPoint(x: x, y: y), startRadius: 0,
                                   endCenter: CGPoint(x: x, y: y), endRadius: r, options: [])
        }
        ctx.restoreGState()

        // Framed photo with shadow
        let frame = CGRect(x: 512 - 215, y: 512 - 275, width: 430, height: 550)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: c("#000000", 0.55))
        ctx.setFillColor(c("#FFFFFF"))
        ctx.fill(frame)
        ctx.restoreGState()
        let photo = frame.insetBy(dx: 24, dy: 24)
        ctx.saveGState()
        ctx.clip(to: photo)
        let sky = CGGradient(colorsSpace: cs, colors: [c("#2C3E66"), c("#C46A4B"), c("#F4B66A")] as CFArray,
                             locations: [0, 0.6, 1])!
        ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: photo.maxY), end: CGPoint(x: 0, y: photo.minY + 120), options: [.drawsAfterEndLocation])
        ctx.setFillColor(c("#FFE2A8"))
        ctx.fillEllipse(in: CGRect(x: photo.midX + 10, y: photo.minY + 170, width: 110, height: 110))
        ctx.setFillColor(c("#1B1E26"))
        let m = CGMutablePath()
        m.move(to: CGPoint(x: photo.minX, y: photo.minY))
        m.addLine(to: CGPoint(x: photo.minX, y: photo.minY + 170))
        m.addLine(to: CGPoint(x: photo.minX + 120, y: photo.minY + 260))
        m.addLine(to: CGPoint(x: photo.minX + 210, y: photo.minY + 175))
        m.addLine(to: CGPoint(x: photo.minX + 290, y: photo.minY + 235))
        m.addLine(to: CGPoint(x: photo.maxX, y: photo.minY + 140))
        m.addLine(to: CGPoint(x: photo.maxX, y: photo.minY))
        m.closeSubpath()
        ctx.addPath(m); ctx.fillPath()
        ctx.restoreGState()

        guard let img = ctx.makeImage() else { return }
        var ex = ExportOptions(); ex.format = .png
        try Renderer.shared.write(img, to: out, options: ex, sourceProperties: [:])
        print("icon written to \(out.path)")
    }
}
