import SwiftUI

struct InspectorView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                InspectorSection("Presets", systemImage: "square.stack.3d.up") {
                    PresetControls()
                }
                Divider()

                InspectorSection("Border", systemImage: "square") {
                    SliderRow("Thickness", value: $state.style.borderWidth, in: 0...0.15, default: 0.025) { v in
                        let pct = String(format: "%.1f%%", v * 100)
                        if let p = state.selectedPhoto {
                            return pct + "  ·  \(Int((Double(p.info.shortSide) * v).rounded())) px"
                        }
                        return pct
                    }
                    FillEditor(fill: $state.style.borderFill)
                }
                Divider()

                InspectorSection("Shadow", systemImage: "shadow") {
                    Toggle("Drop shadow under the photo", isOn: $state.style.shadowEnabled)
                    if state.style.shadowEnabled {
                        if state.style.backgroundMode == .none { NeedsCanvasNote() }
                        let d = Style()
                        SliderRow("Opacity", value: $state.style.shadowOpacity, in: 0...1, default: d.shadowOpacity)
                        SliderRow("Softness", value: $state.style.shadowSoftness, in: 0...1, default: d.shadowSoftness)
                        SliderRow("Distance", value: $state.style.shadowDistance, in: 0...1, default: d.shadowDistance)
                    }
                }
                Divider()

                InspectorSection("Canvas", systemImage: "rectangle.portrait") {
                    Picker("Background", selection: $state.style.backgroundMode) {
                        ForEach(BackgroundMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    if state.style.backgroundMode == .none {
                        Text("Exports just the photo with its border.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Ratio", selection: $state.style.aspect) {
                            ForEach(CanvasAspect.allCases) { Text($0.title).tag($0) }
                        }
                        SliderRow("Photo Size", value: $state.style.photoSize, in: Style.photoSizeRange, default: 0.8) {
                            "\(Int(($0 * 100).rounded()))%"
                        }
                    }
                }
                Divider()

                InspectorSection("Text", systemImage: "textformat") {
                    CameraInfoControls()
                }
                Divider()

                if state.style.backgroundMode == .image {
                    InspectorSection("Background Image", systemImage: "photo") {
                        BackgroundImageControls()
                    }
                    Divider()
                } else if state.style.backgroundMode == .color {
                    InspectorSection("Background Color", systemImage: "paintpalette") {
                        FillEditor(fill: $state.style.backgroundFill)
                    }
                    Divider()
                }

                InspectorSection("Export", systemImage: "square.and.arrow.up") {
                    ExportControls()
                }
            }
        }
    }
}

struct BackgroundImageControls: View {
    @Environment(AppState.self) private var state
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 12) {
            well
            if state.background != nil {
                let d = Style()
                SliderRow("Blur", value: $state.style.bgBlur, in: 0...1, default: d.bgBlur)
                SliderRow("Grain", value: $state.style.bgGrain, in: 0...1, default: d.bgGrain)
                SliderRow("Grain Size", value: $state.style.bgGrainSize, in: 0...1, default: d.bgGrainSize)
                    .disabled(state.style.bgGrain == 0)
                    .opacity(state.style.bgGrain == 0 ? 0.5 : 1)
                SliderRow("Brightness", value: $state.style.bgBrightness, in: -1...1, default: d.bgBrightness,
                          display: signedPercent)
                SliderRow("Zoom", value: $state.style.bgZoom, in: 1...4, default: d.bgZoom) {
                    String(format: "%.2f×", $0)
                }
                SliderRow("Move Horizontally", value: $state.style.bgPanX, in: -1...1, default: 0, display: signedPercent)
                SliderRow("Move Vertically", value: $state.style.bgPanY, in: -1...1, default: 0, display: signedPercent)
                Button("Reset Adjustments") { state.resetBackgroundAdjustments() }
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var well: some View {
        if let bg = state.background {
            VStack(alignment: .leading, spacing: 8) {
                // Note: a .fill image overflows its frame invisibly; it must not take mouse input,
                // or a portrait background swallows clicks on the controls above it.
                Color.clear
                    .frame(height: 110)
                    .frame(maxWidth: .infinity)
                    .overlay {
                        Image(decorative: bg.preview, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .allowsHitTesting(false)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(dropTargeted ? Color.accentColor : .primary.opacity(0.12), lineWidth: dropTargeted ? 2 : 1))
                HStack {
                    Text(bg.url.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Replace…") { state.chooseBackground() }
                    Button { state.removeBackground() } label: { Image(systemName: "trash") }
                        .help("Remove background image")
                }
                .controlSize(.small)
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let u = urls.first(where: AppState.isImage) else { return false }
                state.setBackground(u); return true
            } isTargeted: { dropTargeted = $0 }
        } else {
            Button { state.chooseBackground() } label: {
                VStack(spacing: 6) {
                    Image(systemName: "photo.badge.plus").font(.title2)
                    Text("Choose Background Image…").font(.callout.weight(.medium))
                    Text("or drop an image here").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 110)
                .background(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(style: StrokeStyle(lineWidth: dropTargeted ? 2 : 1.2, dash: [5, 4]))
                    .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.6)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .dropDestination(for: URL.self) { urls, _ in
                guard let u = urls.first(where: AppState.isImage) else { return false }
                state.setBackground(u); return true
            } isTargeted: { dropTargeted = $0 }
            Text("Until you choose an image, the background color is used.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct ExportControls: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 12) {
            Picker("Format", selection: $state.exportOptions.format) {
                ForEach(ExportFormat.allCases) { Text($0.title).tag($0) }
            }
            if state.exportOptions.format.isLossy {
                SliderRow("Quality", value: $state.exportOptions.quality, in: 0.6...1, default: 1)
            }
            Toggle("Keep camera metadata (EXIF)", isOn: $state.exportOptions.keepMetadata)

            Text(state.exportOptions.format.isLossy
                 ? "Your photo keeps its full resolution and color profile; the canvas is built around it. For a bit-exact copy of the photo’s pixels, choose PNG or TIFF."
                 : "Lossless: the photo’s pixels are copied exactly at full resolution, with its color profile.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Export…") { state.exportSelected() }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.selectedPhoto == nil || state.isExporting)
                Button(state.photos.count > 1 ? "Export All \(state.photos.count)…" : "Export All…") { state.exportAll() }
                    .disabled(state.photos.isEmpty || state.isExporting)
            }
            .controlSize(.large)
        }
    }
}

struct NeedsCanvasNote: View {
    var body: some View {
        Label("Needs a canvas: set Canvas to Color or Image.", systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.orange)
    }
}

struct CameraInfoControls: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        let st = state.style
        VStack(alignment: .leading, spacing: 12) {
            if (st.captionEnabled || st.infoEnabled) && st.backgroundMode == .none { NeedsCanvasNote() }

            // Line 1: camera settings
            Toggle("Camera settings", isOn: $state.style.captionEnabled)
            if st.captionEnabled {
                if let p = state.selectedPhoto {
                    PerPhotoTextField(
                        placeholder: "Shutter · aperture · focal length · ISO",
                        text: Binding(get: { state.caption(for: p) }, set: { state.captions[p.id] = $0 }),
                        fromPhoto: p.info.cameraSettings,
                        emptyNote: "No camera settings in this photo",
                        isEdited: state.captions[p.id] != nil,
                        reset: { state.captions[p.id] = nil })
                }
                Picker("Position", selection: $state.style.captionPosition) {
                    ForEach(CaptionPosition.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Picker("Alignment", selection: $state.style.captionAlign) {
                    ForEach(CaptionAlign.allCases) { Image(systemName: $0.symbol).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                SliderRow("Offset X", value: $state.style.captionOffsetX, in: -1...1, default: 0, display: signedPercent)
                SliderRow("Offset Y", value: $state.style.captionOffsetY, in: -1...1, default: 0, display: signedPercent)
            }

            Divider()

            // Line 2: camera model, copyright, location or custom text
            Toggle("Second line", isOn: $state.style.infoEnabled)
            if st.infoEnabled {
                Picker("Show", selection: $state.style.infoSource) {
                    ForEach(InfoSource.allCases) { Text($0.title).tag($0) }
                }
                if st.infoSource == .custom {
                    TextField("Your text, e.g. a title or handle", text: $state.style.infoCustomText)
                        .textFieldStyle(.roundedBorder)
                    Text("The same text is used on every photo.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let p = state.selectedPhoto {
                    PerPhotoTextField(
                        placeholder: st.infoSource.title,
                        text: Binding(get: { state.infoText(for: p) }, set: { state.setInfoOverride($0, for: p) }),
                        fromPhoto: p.info.metadataText(st.infoSource),
                        emptyNote: emptyNote(st, photo: p),
                        isEdited: state.infoOverride(for: p) != nil,
                        reset: { state.setInfoOverride(nil, for: p) })
                    if st.infoSource == .filmSimulation {
                        // Per-photo choice, for photos that don't record one (or to correct one).
                        Menu("Choose for this photo") {
                            ForEach(FilmSimulation.all, id: \.self) { name in
                                Button(name) { state.setInfoOverride(name, for: p) }
                            }
                            Divider()
                            Button("Use the photo's own value") { state.setInfoOverride(nil, for: p) }
                        }
                        .fixedSize()
                        Picker("Default for Fuji photos without one", selection: $state.style.infoFilmFallback) {
                            Text("None").tag("")
                            Divider()
                            ForEach(FilmSimulation.all, id: \.self) { Text($0).tag($0) }
                        }
                        .help("Used for Fujifilm photos whose metadata doesn't record a film simulation and that you haven't set by hand")
                    }
                }
                Picker("Position", selection: $state.style.infoPosition) {
                    ForEach(InfoPlacement.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Picker("Alignment", selection: $state.style.infoAlign) {
                    Text("Auto").tag(InfoAlignment.auto)
                    Image(systemName: CaptionAlign.left.symbol).tag(InfoAlignment.left)
                    Image(systemName: CaptionAlign.center.symbol).tag(InfoAlignment.center)
                    Image(systemName: CaptionAlign.right.symbol).tag(InfoAlignment.right)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(placementNote(st))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SliderRow("Offset X", value: $state.style.infoOffsetX, in: -1...1, default: 0, display: signedPercent)
                SliderRow("Offset Y", value: $state.style.infoOffsetY, in: -1...1, default: 0, display: signedPercent)
            }

            if st.captionEnabled || st.infoEnabled {
                Divider()
                Text("Style for both lines").font(.callout.weight(.semibold))
                FontPicker(family: st.captionFontFamily, fontName: st.captionFontName) { family, name in
                    state.style.captionFontFamily = family
                    state.style.captionFontName = name
                }
                .equatable()

                let d = Style()
                SliderRow("Size", value: $state.style.captionSize, in: 0.008...0.06, default: d.captionSize) {
                    String(format: "%.1f", $0 * 100)
                }
                SliderRow("Letter Spacing", value: $state.style.captionSpacing, in: 0...0.5, default: d.captionSpacing)
                Text("Text Color").font(.callout)
                ColorWheel(color: $state.style.captionColor, showsWheel: false)
            }
        }
    }

    private func emptyNote(_ st: Style, photo p: PhotoItem) -> String {
        let edited = state.infoOverride(for: p) != nil
        guard st.infoSource == .filmSimulation else {
            return edited ? "No \(st.infoSource.title.lowercased()) in this photo; set by hand"
                          : "No \(st.infoSource.title.lowercased()) in this photo; type your own"
        }
        if edited { return "Not in this photo; set by hand" }
        if !p.info.isFujifilm { return "Not a Fujifilm photo; choose one below or type it" }
        return st.infoFilmFallback.isEmpty ? "Not in this photo; choose one below or type it"
                                           : "Not in this photo; using the default (\(st.infoFilmFallback))"
    }

    private func placementNote(_ st: Style) -> String {
        func name(_ a: CaptionAlign) -> String {
            switch a {
            case .left: return "left"
            case .center: return "centered"
            case .right: return "right"
            }
        }
        let now = "\(st.resolvedInfoPosition.title.lowercased()), \(name(st.resolvedInfoAlign))"
        let shared = st.captionEnabled && st.resolvedInfoPosition == st.captionPosition && st.resolvedInfoAlign == st.captionAlign
        if shared { return "Now: \(now), as a new line under the camera settings. It moves with them; its offsets nudge it from there." }
        if st.captionEnabled && st.resolvedInfoPosition == st.captionPosition {
            return "Now: \(now), on the camera settings' side; it moves up and down with them and drops to its own line if they would touch."
        }
        let auto = st.infoPosition == .auto || st.infoAlign == .auto
        return auto ? "Now: \(now). Auto is opposite the camera settings; pick their spot to stack both lines."
                    : "Now: \(now). Pick the camera settings' spot to stack both lines."
    }
}

/// Per-photo editable text with the photo's own value shown underneath.
struct PerPhotoTextField: View {
    let placeholder: String
    @Binding var text: String
    let fromPhoto: String
    let emptyNote: String
    let isEdited: Bool
    let reset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
            HStack(alignment: .firstTextBaseline) {
                Text(fromPhoto.isEmpty ? emptyNote : "From photo: \(fromPhoto)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(fromPhoto.isEmpty ? emptyNote : fromPhoto)
                Spacer()
                if isEdited {
                    Button("Reset", action: reset)
                        .controlSize(.small)
                        .help("Go back to the text from the photo")
                }
            }
        }
    }
}

/// Font family + style pickers over all fonts installed on this Mac.
struct FontPicker: View, Equatable {
    let family: String
    let fontName: String
    let onChange: (String, String) -> Void

    static func == (a: FontPicker, b: FontPicker) -> Bool { a.family == b.family && a.fontName == b.fontName }

    static let families: [String] = NSFontManager.shared.availableFontFamilies
        .filter { !$0.hasPrefix(".") }
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

    struct Member: Hashable { let name: String; let style: String }

    static func members(of family: String) -> [Member] {
        (NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []).compactMap { m in
            guard m.count > 1, let n = m[0] as? String, let st = m[1] as? String else { return nil }
            return Member(name: n, style: st)
        }
    }

    var body: some View {
        let members = Self.members(of: family)
        VStack(alignment: .leading, spacing: 8) {
            Picker("Font", selection: Binding(get: { family }, set: { f in
                let ms = Self.members(of: f)
                let pick = ms.first { $0.style == "Regular" } ?? ms.first { $0.style == "Roman" } ?? ms.first
                onChange(f, pick?.name ?? f)
            })) {
                if !Self.families.contains(family) { Text(family).tag(family) }
                ForEach(Self.families, id: \.self) { Text($0).tag($0) }
            }
            Picker("Style", selection: Binding(get: { fontName }, set: { onChange(family, $0) })) {
                if !members.contains(where: { $0.name == fontName }) { Text(fontName).tag(fontName) }
                ForEach(members, id: \.self) { Text($0.style).tag($0.name) }
            }
        }
    }
}

/// Choose, save, update, rename, delete, import and export presets.
struct PresetControls: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Menu {
                if state.presets.isEmpty {
                    Text("No presets yet")
                }
                ForEach(state.presets) { p in
                    Button {
                        state.applyPreset(p)
                    } label: {
                        if p.id == state.activePresetID { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                    }
                }
                Divider()
                Button("Reset All Settings to Defaults") { state.resetAllSettings() }
            } label: {
                Text(menuTitle)
            }
            .help("Apply a preset. The background image and per-photo text stay as they are.")

            HStack(spacing: 8) {
                Button("Save as New…") { state.presetPrompt = .save }
                Button("Update") { state.updateActivePreset() }
                    .disabled(state.activePreset == nil || !state.activePresetIsModified)
                    .help(state.activePreset.map { "Save the current settings into “\($0.name)”" } ?? "Apply or save a preset first")
                Spacer()
                Menu {
                    Button("Rename…") {
                        if let id = state.activePresetID { state.presetPrompt = .rename(id) }
                    }
                    .disabled(state.activePreset == nil)
                    Button("Delete…") { state.presetPendingDelete = state.activePreset }
                        .disabled(state.activePreset == nil)
                    Divider()
                    Button("Export Preset…") { if let p = state.activePreset { state.exportPreset(p) } }
                        .disabled(state.activePreset == nil)
                    Button("Import Presets…") { state.importPresets() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("More preset actions")
            }
            .controlSize(.small)

            Text("A preset keeps every setting and slider. It doesn’t change the background image or any per-photo text.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var menuTitle: String {
        guard let p = state.activePreset else { return "No preset" }
        return state.activePresetIsModified ? "\(p.name) (edited)" : p.name
    }
}
