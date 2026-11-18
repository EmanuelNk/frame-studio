import AppKit
import SwiftUI

@main
struct FrameStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var state: AppState

    init() {
        CLI.runIfRequested()
        _state = State(initialValue: AppState())
    }

    var body: some Scene {
        Window("Frame Studio", id: "main") {
            ContentView()
                .environment(state)
                .frame(minWidth: 980, minHeight: 640)
                .onAppear { appDelegate.attach(state) }
        }
        .defaultSize(width: 1360, height: 880)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Photos…") { state.choosePhotos() }
                    .keyboardShortcut("o")
                Button("Choose Background Image…") { state.chooseBackground() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .saveItem) {
                Button("Export…") { state.exportSelected() }
                    .keyboardShortcut("e")
                    .disabled(state.selectedPhoto == nil || state.isExporting)
                Button("Export All…") { state.exportAll() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(state.photos.isEmpty || state.isExporting)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Files opened via Finder "Open With", the Dock icon, or `open -a`.
    private var pending: [URL] = []
    private var handler: (([URL]) -> Void)?

    @MainActor func attach(_ state: AppState) {
        handler = { urls in state.addPhotos(urls) }
        if !pending.isEmpty { handler?(pending); pending = [] }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let handler { handler(urls) } else { pending += urls }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Development aid: FRAMESTUDIO_SNAPSHOT=/path/prefix writes PNG snapshots of the window
        // every FRAMESTUDIO_SNAPSHOT_INTERVAL seconds (default 3), up to 20 times.
        let env = ProcessInfo.processInfo.environment
        guard let prefix = env["FRAMESTUDIO_SNAPSHOT"] else { return }
        let interval = Double(env["FRAMESTUDIO_SNAPSHOT_INTERVAL"] ?? "3") ?? 3
        for i in 1...20 {
            DispatchQueue.main.asyncAfter(deadline: .now() + interval * Double(i)) {
                guard let win = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                      let view = win.contentView?.superview ?? win.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(prefix)-\(i).png"))
            }
        }
    }
}
