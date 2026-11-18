import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

final class PhotoItem: Identifiable {
    let id = UUID()
    let url: URL
    let info: ImageInfo
    let preview: CGImage
    let thumb: CGImage

    init(url: URL, info: ImageInfo, preview: CGImage, thumb: CGImage) {
        self.url = url; self.info = info; self.preview = preview; self.thumb = thumb
    }

    var name: String { url.deletingPathExtension().lastPathComponent }
}

struct BackgroundItem: Identifiable {
    let id = UUID()
    let url: URL
    let info: ImageInfo
    let preview: CGImage
}

enum PresetPrompt: Identifiable, Equatable {
    case save
    case rename(UUID)
    var id: String {
        switch self {
        case .save: return "save"
        case .rename(let id): return "rename-\(id.uuidString)"
        }
    }
}

struct Banner: Identifiable, Equatable {
    let id = UUID()
    let message: String
    var revealURLs: [URL] = []
    var isError = false
}

@MainActor
@Observable
final class AppState {
    var photos: [PhotoItem] = []
    var selection: UUID?
    var background: BackgroundItem?
    var style: Style {
        didSet {
            guard style != oldValue else { return }
            persist()
        }
    }
    var exportOptions: ExportOptions { didSet { if exportOptions != oldValue { persist() } } }
    var exportProgress: String?
    var banner: Banner?
    var loadingCount = 0
    /// Per-photo edited camera-settings text (absent = use the photo's EXIF).
    var captions: [UUID: String] = [:]
    /// Per-photo edited second-line text, kept separately for each source (absent = use the photo's metadata).
    var infoTexts: [InfoSource: [UUID: String]] = [:]

    // Presets: every setting except the background image and per-photo text edits.
    var presets: [Preset] = [] { didSet { savePresets() } }
    var activePresetID: UUID? {
        didSet { defaults.set(activePresetID?.uuidString, forKey: "presets.active") }
    }
    /// Shows the name prompt (save / rename) when set.
    var presetPrompt: PresetPrompt?
    /// Shows the delete confirmation when set.
    var presetPendingDelete: Preset?

    private let defaults = UserDefaults.standard

    init() {
        style = defaults.data(forKey: "style.v1").flatMap(Style.decodeLenient) ?? Style()
        exportOptions = defaults.data(forKey: "export.v1").flatMap { Lenient.decode($0, onto: ExportOptions()) } ?? ExportOptions()
        if let data = defaults.data(forKey: "presets.v1"),
           let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
            presets = list.compactMap(Preset.init(jsonObject:))
        }
        activePresetID = defaults.string(forKey: "presets.active").flatMap(UUID.init(uuidString:))
        if let id = activePresetID, !presets.contains(where: { $0.id == id }) { activePresetID = nil }
        if let path = defaults.string(forKey: "background.path"), FileManager.default.fileExists(atPath: path) {
            setBackground(URL(fileURLWithPath: path), resetPosition: false)
        }
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(style) { defaults.set(d, forKey: "style.v1") }
        if let d = try? JSONEncoder().encode(exportOptions) { defaults.set(d, forKey: "export.v1") }
    }

    // MARK: Presets

    private func savePresets() {
        if let data = try? JSONSerialization.data(withJSONObject: presets.map(\.jsonObject)) {
            defaults.set(data, forKey: "presets.v1")
        }
    }

    var activePreset: Preset? { presets.first { $0.id == activePresetID } }

    /// True when the current settings differ from the active preset.
    var activePresetIsModified: Bool {
        guard let p = activePreset else { return false }
        return p.style != style || p.export != exportOptions
    }

    func applyPreset(_ preset: Preset) {
        style = preset.style
        exportOptions = preset.export
        activePresetID = preset.id
    }

    func saveCurrentAsPreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let preset = Preset(name: trimmed.isEmpty ? nextPresetName() : trimmed, style: style, export: exportOptions)
        presets.append(preset)
        activePresetID = preset.id
    }

    func updateActivePreset() {
        guard let i = presets.firstIndex(where: { $0.id == activePresetID }) else { return }
        presets[i].style = style
        presets[i].export = exportOptions
    }

    func renamePreset(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[i].name = trimmed
    }

    func deletePreset(_ id: UUID) {
        presets.removeAll { $0.id == id }
        if activePresetID == id { activePresetID = nil }
    }

    func resetAllSettings() {
        style = Style()
        exportOptions = ExportOptions()
        activePresetID = nil
    }

    func nextPresetName() -> String {
        var n = presets.count + 1
        while presets.contains(where: { $0.name == "Preset \(n)" }) { n += 1 }
        return "Preset \(n)"
    }

    func exportPreset(_ preset: Preset) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = preset.name + ".json"
        panel.message = "Save “\(preset.name)” to a file you can import later or on another Mac"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var object = preset.jsonObject
        object["app"] = "Frame Studio"
        object["kind"] = "preset"
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            banner = Banner(message: "Exported preset “\(preset.name)”", revealURLs: [url])
        } catch {
            banner = Banner(message: "Couldn’t save the preset: \(error.localizedDescription)", isError: true)
        }
    }

    func importPresets() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = true
        panel.message = "Choose preset files exported from Frame Studio"
        panel.prompt = "Import"
        guard panel.runModal() == .OK else { return }
        var added: [String] = [], failed: [String] = []
        for url in panel.urls {
            if let data = try? Data(contentsOf: url),
               let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               var preset = Preset(jsonObject: object) {
                preset.id = UUID() // never collide with an existing preset
                if presets.contains(where: { $0.name == preset.name }) { preset.name += " (imported)" }
                presets.append(preset)
                added.append(preset.name)
            } else {
                failed.append(url.lastPathComponent)
            }
        }
        if !failed.isEmpty {
            banner = Banner(message: "Couldn’t read \(failed.joined(separator: ", ")) as a preset", isError: true)
        } else if !added.isEmpty {
            banner = Banner(message: added.count == 1 ? "Imported preset “\(added[0])”" : "Imported \(added.count) presets")
        }
    }

    var selectedPhoto: PhotoItem? {
        photos.first { $0.id == selection } ?? photos.first
    }

    func caption(for photo: PhotoItem) -> String {
        captions[photo.id] ?? photo.info.cameraSettings
    }

    /// The current source's edited text for a photo, if any.
    func infoOverride(for photo: PhotoItem) -> String? {
        infoTexts[style.infoSource]?[photo.id]
    }

    func setInfoOverride(_ text: String?, for photo: PhotoItem) {
        infoTexts[style.infoSource, default: [:]][photo.id] = text
    }

    func infoText(for photo: PhotoItem) -> String {
        infoOverride(for: photo) ?? photo.info.infoDefault(style)
    }

    /// The text lines drawn for a photo with the current settings.
    func canvasTexts(for photo: PhotoItem) -> [CanvasText] {
        CanvasText.lines(style: style, info: photo.info, cameraText: captions[photo.id], infoText: infoOverride(for: photo))
    }

    func layout(for photo: PhotoItem) -> CanvasLayout {
        CanvasLayout.make(photoWidth: photo.info.width, photoHeight: photo.info.height, style: style)
    }

    // MARK: Importing

    static func isImage(_ url: URL) -> Bool {
        guard let t = UTType(filenameExtension: url.pathExtension) else { return false }
        return t.conforms(to: .image)
    }

    func choosePhotos() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.message = "Choose one or more photos to frame"
        panel.prompt = "Add"
        if panel.runModal() == .OK { addPhotos(panel.urls) }
    }

    func addPhotos(_ urls: [URL]) {
        let urls = urls.filter(Self.isImage)
        guard !urls.isEmpty else { return }
        loadingCount += 1
        Task.detached(priority: .userInitiated) {
            var items: [PhotoItem] = []
            var failed: [String] = []
            for u in urls {
                do {
                    let info = try ImageIOHelper.info(u)
                    let preview = try ImageIOHelper.thumbnail(u, maxPixel: 2048)
                    let thumb = try ImageIOHelper.thumbnail(u, maxPixel: 160)
                    items.append(PhotoItem(url: u, info: info, preview: preview, thumb: thumb))
                } catch {
                    failed.append(u.lastPathComponent)
                }
            }
            await MainActor.run { [items, failed] in
                self.photos.append(contentsOf: items)
                if let first = items.first { self.selection = first.id }
                self.loadingCount -= 1
                if !failed.isEmpty {
                    self.banner = Banner(message: "Couldn’t open \(failed.joined(separator: ", "))", isError: true)
                }
            }
        }
    }

    func removePhoto(_ id: UUID) {
        guard let i = photos.firstIndex(where: { $0.id == id }) else { return }
        photos.remove(at: i)
        if selection == id {
            selection = photos.isEmpty ? nil : photos[min(i, photos.count - 1)].id
        }
    }

    func chooseBackground() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.message = "Choose a background image"
        panel.prompt = "Use as Background"
        if panel.runModal() == .OK, let u = panel.url { setBackground(u) }
    }

    func setBackground(_ url: URL, resetPosition: Bool = true) {
        guard Self.isImage(url) else { return }
        loadingCount += 1
        Task.detached(priority: .userInitiated) {
            let result = Result { (try ImageIOHelper.info(url), try ImageIOHelper.thumbnail(url, maxPixel: 2048)) }
            await MainActor.run {
                self.loadingCount -= 1
                switch result {
                case .success(let (info, preview)):
                    self.background = BackgroundItem(url: url, info: info, preview: preview)
                    self.defaults.set(url.path, forKey: "background.path")
                    if resetPosition {
                        self.style.bgPanX = 0
                        self.style.bgPanY = 0
                        self.style.backgroundMode = .image
                    }
                case .failure(let e):
                    self.banner = Banner(message: e.localizedDescription, isError: true)
                }
            }
        }
    }

    func removeBackground() {
        background = nil
        defaults.removeObject(forKey: "background.path")
    }

    func resetBackgroundAdjustments() {
        let d = Style()
        style.bgBlur = d.bgBlur
        style.bgGrain = d.bgGrain
        style.bgGrainSize = d.bgGrainSize
        style.bgBrightness = d.bgBrightness
        style.bgZoom = d.bgZoom
        style.bgPanX = d.bgPanX
        style.bgPanY = d.bgPanY
    }

    // MARK: Exporting

    var isExporting: Bool { exportProgress != nil }

    func exportSelected() {
        guard let p = selectedPhoto, !isExporting else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [exportOptions.format.utType]
        panel.nameFieldStringValue = p.name + exportOptions.suffix + "." + exportOptions.format.fileExtension
        panel.directoryURL = p.url.deletingLastPathComponent()
        panel.canCreateDirectories = true
        panel.message = "Export the framed photo"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if url.standardizedFileURL.path == p.url.standardizedFileURL.path {
            banner = Banner(message: "That would overwrite the original photo. Choose a different name.", isError: true)
            return
        }
        run([(p, url)])
    }

    func exportAll() {
        guard !photos.isEmpty, !isExporting else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose a folder for \(photos.count) framed photo\(photos.count == 1 ? "" : "s"). Existing files are never overwritten."
        panel.directoryURL = photos.first?.url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        var reserved = Set<String>()
        let ext = exportOptions.format.fileExtension
        let jobs = photos.map { p in
            (p, Self.uniqueURL(in: dir, base: p.name + exportOptions.suffix, ext: ext, reserved: &reserved))
        }
        run(jobs)
    }

    static func uniqueURL(in dir: URL, base: String, ext: String, reserved: inout Set<String>) -> URL {
        var n = 1
        while true {
            let name = n == 1 ? "\(base).\(ext)" : "\(base) \(n).\(ext)"
            let u = dir.appendingPathComponent(name)
            if !reserved.contains(name.lowercased()), !FileManager.default.fileExists(atPath: u.path) {
                reserved.insert(name.lowercased())
                return u
            }
            n += 1
        }
    }

    private func run(_ jobs: [(PhotoItem, URL)]) {
        let style = self.style
        let options = self.exportOptions
        let bgURL = background?.url
        let total = jobs.count
        let jobTexts = jobs.map { canvasTexts(for: $0.0) }
        exportProgress = total > 1 ? "Exporting 1 of \(total)…" : "Exporting…"
        Task.detached(priority: .userInitiated) {
            var done: [URL] = []
            var errors: [String] = []
            for (i, job) in jobs.enumerated() {
                if total > 1 { await MainActor.run { self.exportProgress = "Exporting \(i + 1) of \(total)…" } }
                do {
                    try autoreleasepool {
                        _ = try Renderer.shared.export(photoURL: job.0.url, backgroundURL: bgURL, style: style,
                                                       texts: jobTexts[i], options: options, to: job.1)
                    }
                    done.append(job.1)
                } catch {
                    errors.append("\(job.0.name): \(error.localizedDescription)")
                }
            }
            await MainActor.run { [done, errors] in
                self.exportProgress = nil
                if errors.isEmpty {
                    let what = done.count == 1 ? "“\(done[0].lastPathComponent)”" : "\(done.count) photos"
                    self.banner = Banner(message: "Exported \(what)", revealURLs: done)
                } else {
                    self.banner = Banner(message: errors.joined(separator: "\n"), revealURLs: done, isError: true)
                }
            }
        }
    }
}
