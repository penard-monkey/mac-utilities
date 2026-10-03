import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct WorkItem: Identifiable, Equatable {
    enum State: Equatable { case queued, running, done(HistoryEntry), failed(String) }
    let id = UUID()
    let url: URL
    var state: State = .queued
}

@MainActor final class TranscribeModel: ObservableObject {
    @Published var work: [WorkItem] = []
    @Published var history: [HistoryEntry] = []
    @Published var health: EngineHealth?
    @Published var checked = false
    @Published var selection: String?
    @Published var settings: TranscribeSettings { didSet { try? settings.save(to: Paths.config) } }

    private var engine: any Transcribing
    private let store: HistoryStore
    private var running = false
    private var poller: Task<Void, Never>?

    init(engine: (any Transcribing)? = nil, store: HistoryStore = HistoryStore(dir: Paths.history)) {
        let settings = TranscribeSettings.load(from: Paths.config)
        self.settings = settings
        self.store = store
        self.engine = engine ?? EngineClient(base: URL(string: "http://127.0.0.1:\(settings.port)")!, jobsDir: Paths.jobs)
        reloadHistory()
    }

    var engineURL: String { "127.0.0.1:\(settings.port)" }

    func startPolling() {
        poller?.cancel()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let h = await self.engine.health()
                self.health = h; self.checked = true
                try? await Task.sleep(nanoseconds: (h?.warm == true ? 10 : 3) * 1_000_000_000)
            }
        }
    }

    func reloadHistory() { history = store.load() }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie, .audiovisualContent]
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func add(_ urls: [URL]) {
        // A file already waiting or in progress is not queued twice (one open
        // event can arrive by more than one route at launch).
        let busy = Set(work.filter { $0.state == .queued || $0.state == .running }.map { $0.url.standardizedFileURL.path })
        let files = urls.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .filter { !busy.contains($0.standardizedFileURL.path) }
        guard !files.isEmpty else { return }
        let items = files.map { WorkItem(url: $0) }
        work.insert(contentsOf: items.reversed(), at: 0)
        if selection == nil || work.count == items.count { selection = items.first.map { "w-\($0.id)" } }
        pump()
    }

    private func pump() {
        guard !running, let index = work.lastIndex(where: { $0.state == .queued }) else { return }
        running = true
        work[index].state = .running
        let item = work[index]
        let settings = self.settings
        Task {
            let state: WorkItem.State
            do {
                let result = try await engine.transcribe(item.url, language: settings.language.isEmpty ? nil : settings.language)
                var saved: URL?
                if settings.saveNextToSource {
                    let target = TranscriptFile.savePath(for: item.url)
                    if (try? TranscriptFile.text(result).write(to: target, atomically: true, encoding: .utf8)) != nil { saved = target }
                }
                let entry = try store.add(source: item.url, saved: saved, result: result)
                if settings.copyWhenDone { copy(entry.text) }
                state = .done(entry)
            } catch {
                state = .failed(error.localizedDescription)
            }
            if let i = work.firstIndex(where: { $0.id == item.id }) { work[i].state = state }
            reloadHistory()
            running = false
            pump()
        }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    func open(_ path: String) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }

    /// History entries not already shown as finished work items.
    var pastEntries: [HistoryEntry] {
        let fresh = Set(work.compactMap { if case .done(let e) = $0.state { return e.id } else { return nil } })
        return history.filter { !fresh.contains($0.id) }
    }

    func entry(for selection: String?) -> HistoryEntry? {
        guard let selection else { return nil }
        if selection.hasPrefix("h-") { return history.first { "h-\($0.id)" == selection } }
        if let w = work.first(where: { "w-\($0.id)" == selection }), case .done(let e) = w.state { return e }
        return nil
    }

    func workItem(for selection: String?) -> WorkItem? {
        work.first { "w-\($0.id)" == selection }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: TranscribeModel?
    private var pending: [URL] = []
    func attach(_ model: TranscribeModel) {
        self.model = model
        if !pending.isEmpty { model.add(pending); pending = [] }
    }
    // SwiftUI's lifecycle delivers Finder's Open With, Dock drops and `open -a`
    // here; openFiles is kept for older senders.
    func application(_ application: NSApplication, open urls: [URL]) {
        if let model { model.add(urls) } else { pending += urls }
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        if let model { model.add(urls) } else { pending += urls }
        sender.reply(toOpenOrPrint: .success)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main struct TranscribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = TranscribeModel()
    var body: some Scene {
        Window("Transcribe", id: "main") {
            ContentView(model: model)
                .onAppear {
                    delegate.attach(model)
                    model.startPolling()
                    NSApplication.shared.setActivationPolicy(.regular)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    // File arguments need no handling here: AppKit turns them into
                    // the same open event Finder sends (application(_:open:)).
                }
        }
        .defaultSize(width: 880, height: 560)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Transcribe Files…", action: model.openPanel).keyboardShortcut("o")
            }
        }
        Settings { SettingsView(model: model) }
    }
}

struct ContentView: View {
    @ObservedObject var model: TranscribeModel
    @State private var targeted = false

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                if !model.work.isEmpty {
                    Section("This session") {
                        ForEach(model.work) { item in WorkRow(item: item).tag("w-\(item.id)") }
                    }
                }
                Section("Recent") {
                    if model.pastEntries.isEmpty {
                        Text("Nothing yet").foregroundStyle(.secondary)
                    }
                    ForEach(model.pastEntries) { e in HistoryRow(entry: e).tag("h-\(e.id)") }
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 280)
            .safeAreaInset(edge: .bottom) { EngineBadge(model: model).padding(10) }
        } detail: {
            Group {
                if let entry = model.entry(for: model.selection) {
                    TranscriptView(model: model, entry: entry)
                } else if let item = model.workItem(for: model.selection) {
                    WorkDetail(item: item)
                } else {
                    DropZone(targeted: targeted, open: model.openPanel)
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItem {
                Button { model.openPanel() } label: { Label("Transcribe Files…", systemImage: "plus") }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in model.add([url]) } }
                }
            }
            return true
        }
    }
}

struct DropZone: View {
    var targeted: Bool
    var open: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.badge.mic").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Drop audio or video here").font(.title3.weight(.medium))
            Text("Voice notes, recordings, videos. The transcript is saved next to the file.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Choose Files…", action: open).keyboardShortcut(.defaultAction)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 14)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7]))
            .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.35))
            .padding(24))
    }
}

struct WorkRow: View {
    var item: WorkItem
    var body: some View {
        HStack(spacing: 8) {
            switch item.state {
            case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
            case .running: ProgressView().controlSize(.small)
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.url.lastPathComponent).lineLimit(1)
                Group {
                    switch item.state {
                    case .queued: Text("Waiting")
                    case .running: Text("Transcribing…")
                    case .done(let e): Text(e.text).lineLimit(1)
                    case .failed(let why): Text(why).lineLimit(1)
                    }
                }.font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct HistoryRow: View {
    var entry: HistoryEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(entry.sourceName).lineLimit(1)
                Spacer()
                Text(entry.createdDate, format: .relative(presentation: .numeric)).font(.caption2).foregroundStyle(.tertiary)
            }
            Text(entry.text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

struct WorkDetail: View {
    var item: WorkItem
    var body: some View {
        VStack(spacing: 12) {
            switch item.state {
            case .queued:
                Image(systemName: "clock").font(.largeTitle).foregroundStyle(.secondary)
                Text("Waiting for the file ahead of it")
            case .running:
                ProgressView()
                Text("Transcribing \(item.url.lastPathComponent)…")
            case .failed(let why):
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                Text(item.url.lastPathComponent).font(.headline)
                Text(why).foregroundStyle(.secondary).multilineTextAlignment(.center).textSelection(.enabled)
            case .done: EmptyView()
            }
        }.padding(32)
    }
}

struct TranscriptView: View {
    @ObservedObject var model: TranscribeModel
    var entry: HistoryEntry
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.sourceName).font(.headline).lineLimit(1)
                    Text(meta).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    model.copy(entry.text); copied = true
                    Task { try? await Task.sleep(nanoseconds: 1_200_000_000); copied = false }
                }.keyboardShortcut("c", modifiers: [.command, .shift])
                if let saved = entry.saved, FileManager.default.fileExists(atPath: saved) {
                    Button("Show Transcript") { model.reveal(saved) }
                }
                if FileManager.default.fileExists(atPath: entry.source) {
                    Button("Open Original") { model.open(entry.source) }
                }
            }
            ScrollView {
                Text(entry.text.isEmpty ? "(no speech found)" : entry.text)
                    .font(.body).lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(14)
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.2)))
        }
        .padding(20)
        .onChange(of: entry.id) { _, _ in copied = false }
    }

    private var meta: String {
        var parts = [entry.createdDate.formatted(date: .abbreviated, time: .shortened)]
        if let d = entry.duration { parts.append(Duration.seconds(d).formatted(.time(pattern: d >= 3600 ? .hourMinuteSecond : .minuteSecond))) }
        if let l = entry.language { parts.append(l.uppercased()) }
        parts.append(entry.saved == nil ? "not saved" : "saved next to the original")
        return parts.joined(separator: " · ")
    }
}

struct EngineBadge: View {
    @ObservedObject var model: TranscribeModel
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Spacer()
        }
        .help(model.health?.model ?? "transcribe server start")
    }
    private var color: Color {
        guard let h = model.health else { return model.checked ? .red : .gray }
        return h.warm ? .green : .yellow
    }
    private var label: String {
        guard let h = model.health else { return model.checked ? "Engine not running · transcribe server start" : "Checking engine…" }
        return h.warm ? "Engine ready" : "Engine loading the model…"
    }
}

struct SettingsView: View {
    @ObservedObject var model: TranscribeModel
    var body: some View {
        Form {
            Toggle("Save the transcript next to the original file", isOn: $model.settings.saveNextToSource)
            Toggle("Copy the transcript when it finishes", isOn: $model.settings.copyWhenDone)
            Picker("Language", selection: $model.settings.language) {
                Text("Detect automatically").tag("")
                Text("Spanish").tag("es")
                Text("English").tag("en")
            }
            LabeledContent("Engine", value: model.engineURL)
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .padding(.vertical, 8)
    }
}
