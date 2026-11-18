import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var state
    @State private var showInspector = true

    var body: some View {
        NavigationSplitView {
            PhotoSidebar()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            PreviewArea()
                .navigationTitle(state.selectedPhoto?.name ?? "Frame Studio")
                .navigationSubtitle(state.photos.count > 1 ? "\(state.photos.count) photos" : "")
                .inspector(isPresented: $showInspector) {
                    InspectorView()
                        .inspectorColumnWidth(min: 300, ideal: 330, max: 440)
                }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { state.choosePhotos() } label: {
                    Label("Add Photos", systemImage: "photo.badge.plus")
                }
                .help("Add photos (⌘O)")
                Button { state.chooseBackground() } label: {
                    Label("Background", systemImage: "photo.on.rectangle")
                }
                .help("Choose background image (⇧⌘O)")
                Button { state.exportSelected() } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .help("Export this photo (⌘E)")
                .disabled(state.selectedPhoto == nil || state.isExporting)
                Button { showInspector.toggle() } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .help("Show or hide the inspector")
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let images = urls.filter(AppState.isImage)
            state.addPhotos(images)
            return !images.isEmpty
        }
        .overlay(alignment: .bottom) { bannerView }
    }

    @ViewBuilder
    private var bannerView: some View {
        if let b = state.banner {
            HStack(spacing: 12) {
                Image(systemName: b.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(b.isError ? .orange : .green)
                Text(b.message).lineLimit(4)
                if !b.revealURLs.isEmpty {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(b.revealURLs)
                    }
                }
                Button { state.banner = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
            .padding(.bottom, 48)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: b.id) {
                try? await Task.sleep(nanoseconds: b.isError ? 12_000_000_000 : 8_000_000_000)
                if state.banner?.id == b.id { withAnimation { state.banner = nil } }
            }
        }
    }
}

struct PhotoSidebar: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        List(selection: $state.selection) {
            if !state.photos.isEmpty {
                Section("Photos") {
                    ForEach(state.photos) { p in
                        PhotoRow(item: p)
                            .tag(p.id)
                            .contextMenu {
                                Button("Use as Background") { state.setBackground(p.url) }
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([p.url]) }
                                Divider()
                                Button("Remove from List") { state.removePhoto(p.id) }
                            }
                    }
                    .onMove { state.photos.move(fromOffsets: $0, toOffset: $1) }
                }
            }
        }
        .onDeleteCommand {
            if let id = state.selection { state.removePhoto(id) }
        }
        .overlay {
            if state.photos.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "photo.stack").font(.largeTitle).foregroundStyle(.tertiary)
                    Text("No photos yet").foregroundStyle(.secondary)
                    Button("Add Photos…") { state.choosePhotos() }
                }
                .padding()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 4) {
                Button { state.choosePhotos() } label: { Image(systemName: "plus").frame(width: 22, height: 22) }
                    .help("Add photos")
                Button {
                    if let id = state.selection { state.removePhoto(id) }
                } label: { Image(systemName: "minus").frame(width: 22, height: 22) }
                    .help("Remove selected photo from the list (the file is not deleted)")
                    .disabled(state.selection == nil)
                Spacer()
                if state.loadingCount > 0 { ProgressView().controlSize(.small) }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }
}

struct PhotoRow: View {
    let item: PhotoItem

    var body: some View {
        HStack(spacing: 10) {
            Color.clear
                .frame(width: 44, height: 44)
                .overlay {
                    Image(decorative: item.thumb, scale: 2)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .allowsHitTesting(false)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.1)))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                Text("\(item.info.width) × \(item.info.height)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}
