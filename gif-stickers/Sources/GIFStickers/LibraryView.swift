import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor final class LibraryModel: ObservableObject {
    let store: StickerLibrary
    @Published private(set) var stickers: [LibrarySticker] = []
    @Published private(set) var folder: URL
    @Published var message = "Added stickers are saved here. Drop 512 × 512 WebP stickers to import them."
    @Published var selectedURL: URL?
    @Published var error: String?
    @Published private(set) var loading = false
    private let queue = DispatchQueue(label: "gif-stickers.library", qos: .userInitiated)
    private var revision = 0

    init(store: StickerLibrary = StickerLibrary()) {
        self.store = store; folder = (try? store.folder()) ?? store.defaultFolder
    }
    func refresh() {
        revision += 1
        let version = revision, store = store
        loading = true
        queue.async {
            let output = Result { try store.contents() }
            Task { @MainActor in
                guard version == self.revision else { return }
                self.loading = false
                switch output {
                case .success(let contents):
                    self.stickers = contents.stickers; self.folder = contents.folder
                    if contents.skipped > 0 {
                        self.message = "\(contents.skipped) invalid WebP file(s) skipped. Library files must meet sticker limits."
                    }
                case .failure(let error): self.error = error.localizedDescription
                }
            }
        }
    }
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        panel.directoryURL = folder; panel.prompt = "Use Library Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.chooseFolder(url)
            message = "Library folder changed. Existing stickers remain in their original folder."
            refresh()
        } catch { self.error = error.localizedDescription }
    }
    func importFiles(_ urls: [URL]) {
        let store = store
        queue.async {
            var imported = 0, failures: [String] = []
            for url in urls {
                do { try store.importFile(url); imported += 1 }
                catch { failures.append(error.localizedDescription) }
            }
            let importCount = imported, importFailures = failures
            Task { @MainActor in
                self.message = "Imported \(importCount) sticker(s)."
                if !importFailures.isEmpty { self.error = "\(importFailures.count) file(s) could not be imported. " + importFailures[0] }
                self.refresh()
            }
        }
    }
    func rename(_ sticker: LibrarySticker, to name: String) throws {
        let url = try store.rename(sticker, to: name)
        selectedURL = url
        message = "Renamed sticker to '\(name)'."
        refresh()
    }
    func copy(_ sticker: LibrarySticker) {
        do {
            let data = try store.read(sticker.url)
            copySticker(data, url: sticker.url)
            message = "Copied \(sticker.name)."
        } catch { self.error = error.localizedDescription }
    }
    func delete(_ sticker: LibrarySticker) {
        do {
            try store.moveToTrash(sticker)
            message = "Moved sticker to Trash."
            refresh()
        } catch { self.error = error.localizedDescription }
    }
}

@MainActor func copySticker(_ data: Data, url: URL) {
    let clipboard = NSPasteboard.general
    clipboard.clearContents()
    let item = NSPasteboardItem()
    item.setData(data, forType: NSPasteboard.PasteboardType("org.webmproject.webp"))
    item.setString(url.absoluteString, forType: .fileURL)
    clipboard.writeObjects([item])
}

struct LibraryView: View {
    @ObservedObject var model: LibraryModel
    @ObservedObject var sender: SendModel
    @State private var deleting: LibrarySticker?
    @State private var targeted = false
    @State private var renaming: LibrarySticker?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Sticker Library").font(.largeTitle.bold())
                Spacer()
                if model.loading { ProgressView().controlSize(.small) }
                Button("Refresh") { model.refresh(); Task { await sender.refresh() } }
                Button("Choose Folder…", action: model.chooseFolder)
            }
            Text(model.folder.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            ScrollViewReader { proxy in
                ScrollView {
                    if model.stickers.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "square.grid.2x2").font(.system(size: 40)).foregroundStyle(.secondary)
                            Text("Your saved stickers appear here").font(.headline)
                            Text("Add a sticker from the editor, or drop existing 512 × 512 WebP files here.").foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, minHeight: 320)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], spacing: 16) {
                            ForEach(model.stickers) { sticker in
                                LibraryTile(sticker: sticker, model: model, sender: sender,
                                    delete: { deleting = sticker }, rename: { renaming = sticker })
                                    .id(sticker.url)
                            }
                        }.padding(4)
                    }
                }.background(targeted ? Color.accentColor.opacity(0.1) : .clear)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(targeted ? Color.accentColor : .clear, lineWidth: 2))
                    .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                        guard !providers.isEmpty else { return false }
                        for provider in providers {
                            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                                if let url { Task { @MainActor in model.importFiles([url]) } }
                            }
                        }
                        return true
                    }
                    .onChange(of: model.stickers.map(\.url)) { _, urls in
                        if let selected = model.selectedURL, urls.contains(selected) {
                            proxy.scrollTo(selected, anchor: .center)
                        }
                    }
                    .onAppear {
                        if let selected = model.selectedURL { proxy.scrollTo(selected, anchor: .center) }
                    }
                    .onChange(of: model.selectedURL) { _, selected in
                        if let selected { proxy.scrollTo(selected, anchor: .center) }
                    }
            }
            Text(model.message).font(.callout).foregroundStyle(.secondary)
        }.padding(24).frame(minWidth: 1060, minHeight: 700)
            .onAppear { model.refresh() }
            .sheet(item: $renaming) { sticker in
                RenameStickerSheet(sticker: sticker, model: model)
            }
            .alert("Move sticker to Trash?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("Cancel", role: .cancel) { deleting = nil }
                Button("Move to Trash", role: .destructive) {
                    if let sticker = deleting { model.delete(sticker) }
                    deleting = nil
                }
            } message: { Text("You can restore it from Trash in Finder.") }
            .alert("Sticker Library", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("OK") { model.error = nil }
            } message: { Text(model.error ?? "") }
    }
}

private struct LibraryTile: View {
    let sticker: LibrarySticker
    @ObservedObject var model: LibraryModel
    @ObservedObject var sender: SendModel
    var delete: () -> Void
    var rename: () -> Void
    @State private var data: Data?
    @State private var failed = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Checkerboard()
                if let data { WebPPreview(data: data) }
                else if failed { Text("Preview unavailable").foregroundStyle(.secondary) }
                else { ProgressView() }
            }.frame(height: 190).clipShape(RoundedRectangle(cornerRadius: 8))
            Text(sticker.name).font(.headline).lineLimit(1).help(sticker.name)
            Text("\(Double(sticker.byteCount) / 1000, specifier: "%.1f") KB · \(sticker.frameCount) \(sticker.frameCount == 1 ? "frame" : "frames")")
                .font(.caption).foregroundStyle(.secondary)
            Button("Send to my WhatsApp") {
                do { sender.prepare(try model.store.read(sticker.url)) }
                catch { model.error = error.localizedDescription }
            }.disabled(!sender.availability.ready || sender.busy || data == nil)
                .help(sender.availability.explanation)
            HStack {
                Button("Copy") { model.copy(sticker) }
                Button("Rename…", action: rename)
                Menu("More") {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([sticker.url]) }
                    Button("Delete…", role: .destructive, action: delete)
                }
            }
        }.padding(12).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke(model.selectedURL == sticker.url ? Color.accentColor : .clear, lineWidth: 2))
            .onTapGesture { model.selectedURL = sticker.url }
            .contextMenu {
                Button("Rename…", action: rename)
                Button("Copy") { model.copy(sticker) }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([sticker.url]) }
                Button("Delete…", role: .destructive, action: delete)
            }
            .task(id: sticker.modified) {
                let store = model.store, url = sticker.url
                let output = await Task.detached { try? store.read(url) }.value
                guard !Task.isCancelled else { return }
                data = output; failed = output == nil
            }
    }
}

private struct RenameStickerSheet: View {
    let sticker: LibrarySticker
    @ObservedObject var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var error: String?
    @FocusState private var focused: Bool

    init(sticker: LibrarySticker, model: LibraryModel) {
        self.sticker = sticker
        self.model = model
        _name = State(initialValue: sticker.name)
    }
    private func commit() {
        do {
            try model.rename(sticker, to: name)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename sticker").font(.headline)
            HStack {
                TextField("Sticker name", text: $name).focused($focused).onSubmit(commit)
                Text(".webp").foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename", action: commit).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 420).onAppear { focused = true }
    }
}
