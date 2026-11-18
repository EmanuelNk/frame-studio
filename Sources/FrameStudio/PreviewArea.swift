import Observation
import SwiftUI

/// Serial "latest request wins" preview renderer: keeps updating while sliders move,
/// and always finishes on the most recent settings.
@MainActor
@Observable
final class PreviewRenderer {
    struct Request: Equatable {
        var photoID: UUID
        var backgroundID: UUID?
        var style: Style
        var texts: [CanvasText]
        var pixelWidth: Int
        var pixelHeight: Int
    }

    var image: CGImage?
    var imageRequest: Request?

    @ObservationIgnored private var pending: (Request, CGImage, Int, Int, CGImage?)?
    @ObservationIgnored private var running = false

    func request(_ r: Request, photo: PhotoItem, background: BackgroundItem?) {
        guard r != imageRequest || running else { return }
        pending = (r, photo.preview, photo.info.width, photo.info.height,
                   r.style.backgroundMode == .image ? background?.preview : nil)
        if !running { runNext() }
    }

    private func runNext() {
        guard let (r, preview, w, h, bg) = pending else { running = false; return }
        pending = nil
        running = true
        Task.detached(priority: .userInitiated) {
            let img = Renderer.shared.renderPreview(photo: preview, photoWidth: w, photoHeight: h,
                                                    background: bg, style: r.style, texts: r.texts,
                                                    maxPixelSize: CGSize(width: r.pixelWidth, height: r.pixelHeight))
            await MainActor.run {
                if let img { self.image = img; self.imageRequest = r }
                self.runNext()
            }
        }
    }
}

struct PreviewArea: View {
    @Environment(AppState.self) private var state
    @Environment(\.displayScale) private var displayScale
    @State private var renderer = PreviewRenderer()
    @State private var dragStart: CGPoint?
    @State private var zoomStart: Double?

    var body: some View {
        GeometryReader { geo in
            let avail = CGSize(width: max(geo.size.width - 56, 60), height: max(geo.size.height - 56, 60))
            ZStack {
                if let photo = state.selectedPhoto {
                    let layout = state.layout(for: photo)
                    let fit = Self.fit(CGSize(width: layout.canvasWidth, height: layout.canvasHeight), in: avail)
                    canvas(photo: photo, layout: layout, fit: fit)
                } else {
                    emptyState
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .safeAreaInset(edge: .bottom, spacing: 0) { infoBar }
        .overlay {
            if let progress = state.exportProgress {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text(progress).font(.headline)
                    Text("Rendering at full resolution").font(.caption).foregroundStyle(.secondary)
                }
                .padding(28)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    static func fit(_ size: CGSize, in box: CGSize) -> CGSize {
        let s = min(box.width / size.width, box.height / size.height)
        return CGSize(width: (size.width * s).rounded(), height: (size.height * s).rounded())
    }

    @ViewBuilder
    private func canvas(photo: PhotoItem, layout: CanvasLayout, fit: CGSize) -> some View {
        let pxW = min(Int(fit.width * displayScale), 3000)
        let pxH = min(Int(fit.height * displayScale), 3000)
        let req = PreviewRenderer.Request(photoID: photo.id,
                                          backgroundID: state.style.backgroundMode == .image ? state.background?.id : nil,
                                          style: state.style, texts: state.canvasTexts(for: photo),
                                          pixelWidth: pxW, pixelHeight: pxH)
        // Background move/zoom is handled by a native AppKit view instead of SwiftUI gestures:
        // SwiftUI gestures on a view that re-renders every frame cancel slider drags in the inspector.
        RenderedCanvasImage(renderer: renderer, displayScale: displayScale)
            .frame(width: fit.width, height: fit.height)
            .overlay {
                CanvasInteraction(
                    enabled: canAdjustBackground,
                    onDrag: { t in panBackground(by: t, layout: layout, fit: fit) },
                    onDragEnd: { dragStart = nil },
                    onMagnify: { m in zoomBackground(by: m) },
                    onMagnifyEnd: { zoomStart = nil }
                )
            }
            .shadow(color: .black.opacity(0.28), radius: 16, y: 6)
            .onChange(of: req, initial: true) { _, r in
                renderer.request(r, photo: photo, background: state.background)
            }
    }

    // MARK: Moving / zooming the background directly on the canvas

    private var canAdjustBackground: Bool {
        state.style.backgroundMode == .image && state.background != nil
    }

    /// Half of the background's overflow beyond the canvas, in view points (x, y).
    private func halfOverflow(layout: CanvasLayout, fit: CGSize) -> CGSize {
        guard let bg = state.background else { return .zero }
        let CW = Double(layout.canvasWidth), CH = Double(layout.canvasHeight)
        let bw = Double(bg.info.width), bh = Double(bg.info.height)
        let cover = max(CW / bw, CH / bh) * max(state.style.bgZoom, 1)
        let k = Double(fit.width) / CW
        return CGSize(width: (bw * cover - CW) / 2 * k, height: (bh * cover - CH) / 2 * k)
    }

    /// `t` is the drag translation in points since mouse-down (y grows downward).
    private func panBackground(by t: CGSize, layout: CanvasLayout, fit: CGSize) {
        guard canAdjustBackground else { return }
        if dragStart == nil { dragStart = CGPoint(x: state.style.bgPanX, y: state.style.bgPanY) }
        guard let start = dragStart else { return }
        let o = halfOverflow(layout: layout, fit: fit)
        var s = state.style
        if o.width > 0.5 { s.bgPanX = min(max(start.x + t.width / o.width, -1), 1) }
        if o.height > 0.5 { s.bgPanY = min(max(start.y - t.height / o.height, -1), 1) }
        state.style = s
    }

    /// `m` is the cumulative pinch magnification since the gesture began.
    private func zoomBackground(by m: CGFloat) {
        guard canAdjustBackground else { return }
        if zoomStart == nil { zoomStart = state.style.bgZoom }
        state.style.bgZoom = min(max((zoomStart ?? 1) * Double(m), 1), 4)
    }

    // MARK: Chrome

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("Drop photos here").font(.title3.weight(.semibold))
            Text("Add one or a few photos to frame. Settings apply to all of them.")
                .foregroundStyle(.secondary)
            Button("Add Photos…") { state.choosePhotos() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(40)
    }

    private var infoBar: some View {
        HStack(spacing: 16) {
            if let p = state.selectedPhoto {
                let l = state.layout(for: p)
                Label("\(l.canvasWidth) × \(l.canvasHeight) px  ·  \(String(format: "%.1f", l.megapixels)) MP",
                      systemImage: "aspectratio")
                Label("Photo at full resolution (\(p.info.width) × \(p.info.height))", systemImage: "checkmark.seal")
                    .foregroundStyle(.secondary)
                if l.isTooLarge {
                    Label("Too large to export: increase Photo Size", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                } else if l.megapixels > 150 {
                    Label("Very large output", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            if canAdjustBackground {
                Text("Drag to move the background · pinch to zoom")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.caption)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// Displays the latest preview frame. Only this view observes `renderer.image`.
private struct RenderedCanvasImage: View {
    let renderer: PreviewRenderer
    let displayScale: CGFloat

    var body: some View {
        if let img = renderer.image {
            Image(decorative: img, scale: displayScale)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            Rectangle().fill(.quaternary)
        }
    }
}

/// Native mouse handling for the canvas: drag to move the background, pinch to zoom it.
private struct CanvasInteraction: NSViewRepresentable {
    var enabled: Bool
    var onDrag: (CGSize) -> Void
    var onDragEnd: () -> Void
    var onMagnify: (CGFloat) -> Void
    var onMagnifyEnd: () -> Void

    func makeNSView(context: Context) -> InteractionView {
        let v = InteractionView()
        v.config = self
        return v
    }

    func updateNSView(_ v: InteractionView, context: Context) {
        let changed = v.config?.enabled != enabled
        v.config = self
        if changed { v.window?.invalidateCursorRects(for: v) }
    }

    final class InteractionView: NSView {
        var config: CanvasInteraction?
        private var dragOrigin: NSPoint?
        private var magnification: CGFloat = 1

        private var enabled: Bool { config?.enabled ?? false }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { enabled ? super.hitTest(point) : nil }
        override func resetCursorRects() {
            if enabled { addCursorRect(bounds, cursor: .openHand) }
        }

        override func mouseDown(with event: NSEvent) {
            guard enabled else { return super.mouseDown(with: event) }
            dragOrigin = convert(event.locationInWindow, from: nil)
            NSCursor.closedHand.push()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let o = dragOrigin else { return }
            let p = convert(event.locationInWindow, from: nil)
            let dy = isFlipped ? p.y - o.y : o.y - p.y
            config?.onDrag(CGSize(width: p.x - o.x, height: dy))
        }

        override func mouseUp(with event: NSEvent) {
            guard dragOrigin != nil else { return }
            dragOrigin = nil
            NSCursor.pop()
            config?.onDragEnd()
        }

        override func magnify(with event: NSEvent) {
            guard enabled else { return super.magnify(with: event) }
            if event.phase == .began { magnification = 1 }
            magnification *= 1 + event.magnification
            config?.onMagnify(magnification)
            if event.phase == .ended || event.phase == .cancelled {
                magnification = 1
                config?.onMagnifyEnd()
            }
        }
    }
}
