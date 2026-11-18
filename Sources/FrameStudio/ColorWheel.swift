import AppKit
import SwiftUI

struct HSB: Equatable {
    var h: Double // 0...1
    var s: Double // 0...1
    var b: Double // 0...1

    init(h: Double, s: Double, b: Double) { self.h = h; self.s = s; self.b = b }

    init(rgb c: RGBA) {
        let mx = max(c.r, c.g, c.b), mn = min(c.r, c.g, c.b)
        let d = mx - mn
        b = mx
        s = mx == 0 ? 0 : d / mx
        var hue = 0.0
        if d > 0 {
            if mx == c.r { hue = (c.g - c.b) / d + (c.g < c.b ? 6 : 0) }
            else if mx == c.g { hue = (c.b - c.r) / d + 2 }
            else { hue = (c.r - c.g) / d + 4 }
            hue /= 6
        }
        h = hue
    }

    var rgb: RGBA {
        let i = floor(h * 6), f = h * 6 - i
        let p = b * (1 - s), q = b * (1 - f * s), t = b * (1 - (1 - f) * s)
        switch Int(i) % 6 {
        case 0: return RGBA(r: b, g: t, b: p)
        case 1: return RGBA(r: q, g: b, b: p)
        case 2: return RGBA(r: p, g: b, b: t)
        case 3: return RGBA(r: p, g: q, b: b)
        case 4: return RGBA(r: t, g: p, b: b)
        default: return RGBA(r: b, g: p, b: q)
        }
    }
}

/// Hue/saturation wheel + brightness bar, hex entry, swatches, eyedropper and the system color panel.
struct ColorWheel: View {
    @Binding var color: RGBA
    var diameter: CGFloat = 176
    /// false = compact: hex, eyedropper, system picker and swatches only.
    var showsWheel = true

    @State private var hsb = HSB(h: 0, s: 0, b: 1)
    @State private var hexText = ""

    static let swatches: [RGBA] = [
        .white, RGBA(hex: "#F3EEE4")!, RGBA(hex: "#E6E1D8")!, RGBA(hex: "#C9C9C9")!,
        RGBA(hex: "#7A7A7A")!, RGBA(hex: "#2A2A2A")!, .black,
        RGBA(hex: "#C8A27A")!, RGBA(hex: "#8E3B2F")!, RGBA(hex: "#2F4A3A")!, RGBA(hex: "#24324A")!,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsWheel {
                HStack {
                    Spacer()
                    wheel
                    Spacer()
                }
                brightnessBar
            }
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(color.swiftUIColor)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(0.2)))
                    .frame(width: 26, height: 22)
                TextField("Hex", text: $hexText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
                    .frame(width: 86)
                    .onSubmit { if let c = RGBA(hex: hexText) { color = c } else { hexText = color.hex } }
                Spacer()
                Button {
                    NSColorSampler().show { picked in
                        DispatchQueue.main.async {
                            if let picked, let c = RGBA(nsColor: picked) { color = c }
                        }
                    }
                } label: {
                    Image(systemName: "eyedropper")
                }
                .help("Pick a color from anywhere on screen")
                ColorPicker("", selection: Binding(
                    get: { color.swiftUIColor },
                    set: { if let c = RGBA(nsColor: NSColor($0)) { color = c } }
                ), supportsOpacity: false)
                .labelsHidden()
                .help("System color picker (wheel, spectrum, sliders, palettes)")
            }
            swatchRow
        }
        .onAppear { sync(from: color, force: true) }
        .onChange(of: color) { _, new in sync(from: new, force: false) }
    }

    private func sync(from c: RGBA, force: Bool) {
        if force || !hsb.rgb.isClose(to: c) {
            var n = HSB(rgb: c)
            // Keep hue/saturation when they are undefined (grays, black) so the knob doesn't jump.
            if n.s < 0.0001 { n.h = hsb.h }
            if n.b < 0.0001 { n.s = hsb.s; n.h = hsb.h }
            hsb = n
        }
        hexText = c.hex
    }

    private func commit() {
        let c = hsb.rgb
        if !c.isClose(to: color) { color = c }
        hexText = c.hex
    }

    private var wheel: some View {
        let r = diameter / 2
        let hues = stride(from: 0.0, through: 1.0, by: 1.0 / 12).map { Color(hue: $0, saturation: 1, brightness: 1) }
        let angle = hsb.h * 2 * .pi
        let knob = CGPoint(x: r + cos(angle) * hsb.s * r, y: r + sin(angle) * hsb.s * r)
        return ZStack {
            Circle().fill(AngularGradient(colors: hues, center: .center))
            Circle().fill(RadialGradient(colors: [.white, .white.opacity(0)], center: .center, startRadius: 0, endRadius: r))
            Circle().fill(Color.black.opacity(1 - hsb.b))
            Circle().strokeBorder(.primary.opacity(0.15), lineWidth: 1)
            Circle()
                .fill(hsb.rgb.swiftUIColor)
                .frame(width: 18, height: 18)
                .overlay(Circle().strokeBorder(.white, lineWidth: 2.5))
                .shadow(color: .black.opacity(0.45), radius: 2)
                .position(knob)
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
            let dx = v.location.x - r, dy = v.location.y - r
            var a = atan2(dy, dx)
            if a < 0 { a += 2 * .pi }
            hsb.h = a / (2 * .pi)
            hsb.s = min(1, sqrt(dx * dx + dy * dy) / r)
            if hsb.b < 0.05 { hsb.b = 1 } // picking a hue on a black wheel should show it
            commit()
        })
    }

    private var brightnessBar: some View {
        GeometryReader { g in
            let knob: CGFloat = 16
            let x = CGFloat(hsb.b) * (g.size.width - knob)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(colors: [.black, HSB(h: hsb.h, s: hsb.s, b: 1).rgb.swiftUIColor],
                                         startPoint: .leading, endPoint: .trailing))
                    .overlay(Capsule().strokeBorder(.primary.opacity(0.15)))
                    .frame(height: 10)
                Circle()
                    .fill(hsb.rgb.swiftUIColor)
                    .frame(width: knob, height: knob)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 2.5))
                    .shadow(color: .black.opacity(0.4), radius: 1.5)
                    .offset(x: x)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                hsb.b = Double(min(max((v.location.x - knob / 2) / (g.size.width - knob), 0), 1))
                commit()
            })
        }
        .frame(height: 18)
        .help("Brightness")
    }

    private var swatchRow: some View {
        HStack(spacing: 6) {
            ForEach(Array(Self.swatches.enumerated()), id: \.offset) { _, s in
                Button { color = s } label: {
                    Circle()
                        .fill(s.swiftUIColor)
                        .frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(.primary.opacity(s.isClose(to: color) ? 0.9 : 0.2),
                                                       lineWidth: s.isClose(to: color) ? 2 : 1))
                }
                .buttonStyle(.plain)
                .help(s.hex)
            }
        }
    }
}

/// Solid color or two-stop linear gradient editor.
struct FillEditor: View {
    @Binding var fill: Fill
    @State private var editingEnd = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Fill", selection: $fill.kind) {
                ForEach(FillKind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if fill.kind == .gradient {
                HStack(spacing: 8) {
                    stopButton("Start", color: fill.color, selected: !editingEnd) { editingEnd = false }
                    RoundedRectangle(cornerRadius: 5)
                        .fill(LinearGradient(colors: [fill.color.swiftUIColor, fill.color2.swiftUIColor],
                                             startPoint: .leading, endPoint: .trailing))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(0.2)))
                        .frame(height: 22)
                    stopButton("End", color: fill.color2, selected: editingEnd) { editingEnd = true }
                    Button {
                        let c = fill.color; fill.color = fill.color2; fill.color2 = c
                    } label: { Image(systemName: "arrow.left.arrow.right") }
                        .buttonStyle(.borderless)
                        .help("Swap colors")
                }
                SliderRow("Angle", value: $fill.angle, in: 0...360, default: 90) { "\(Int($0.rounded()))°" }
            }

            ColorWheel(color: (fill.kind == .gradient && editingEnd) ? $fill.color2 : $fill.color)
        }
    }

    private func stopButton(_ title: String, color: RGBA, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(color.swiftUIColor)
                    .frame(width: 30, height: 22)
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(selected ? Color.accentColor : .primary.opacity(0.2), lineWidth: selected ? 2.5 : 1))
                Text(title).font(.caption2).foregroundStyle(selected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
    }
}
