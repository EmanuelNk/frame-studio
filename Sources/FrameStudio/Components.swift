import SwiftUI

/// A labeled slider with a live value readout.
/// Double-clicking the slider or its label (or right-click → Reset) resets it to 0,
/// or to its default when 0 is outside the slider's range.
struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let defaultValue: Double
    var display: (Double) -> String = { "\(Int(($0 * 100).rounded()))" }

    init(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, default defaultValue: Double,
         display: @escaping (Double) -> String = { "\(Int(($0 * 100).rounded()))" }) {
        self.title = title
        self._value = value
        self.range = range
        self.defaultValue = defaultValue
        self.display = display
    }

    private var resetValue: Double { range.contains(0) ? 0 : defaultValue }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(display(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { value = resetValue }

            Slider(value: $value, in: range)
                .controlSize(.small)
                .labelsHidden()
                // Simultaneous, so the slider's own click/drag handling is untouched.
                .simultaneousGesture(TapGesture(count: 2).onEnded { value = resetValue })
        }
        .help("Double-click to reset")
        .contextMenu {
            Button("Reset \(title)") { value = resetValue }
        }
    }
}

func signedPercent(_ v: Double) -> String {
    let n = Int((v * 100).rounded())
    return n > 0 ? "+\(n)" : "\(n)"
}

/// Collapsible inspector section.
struct InspectorSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content
    @State private var expanded = true

    init(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: systemImage)
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    Text(title).font(.headline)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(expanded ? "Collapse section" : "Expand section")

            if expanded {
                VStack(alignment: .leading, spacing: 12) { content }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}
