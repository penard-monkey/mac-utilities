import SwiftUI
import AppKit
import WebKit
import UniformTypeIdentifiers

// All mutable state is protected by lock.
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

@MainActor final class EditorModel: ObservableObject {
    let library: LibraryModel
    init(library: LibraryModel? = nil) { self.library = library ?? LibraryModel() }
    @Published var asset: AnimationAsset?
    @Published var displayedAsset: AnimationAsset?
    @Published var cutOutSubject = false
    @Published var framing = Framing()
    @Published var result: ExportResult?
    @Published var busy = false
    @Published var message = "Open a GIF, video or image to begin."
    @Published var error: String?
    private var pending: Task<Void, Never>?
    private var revision = 0
    private var cancellation = CancellationFlag()
    private let queue = DispatchQueue(label: "gif-stickers.encoder", qos: .userInitiated)
    func openPanel() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = AnimationAsset.openableTypes; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }
    func load(_ url: URL) {
        // Videos are decoded up front, which takes a moment, so never on the main thread.
        pending?.cancel(); cancellation.cancel(); revision += 1
        let version = revision
        busy = true; result = nil; message = "Opening \(url.lastPathComponent)…"
        queue.async {
            let loaded = Result { try AnimationAsset(url: url) }
            Task { @MainActor in
                guard version == self.revision else { return }
                switch loaded {
                case .success(let asset):
                    self.asset = asset
                    self.displayedAsset = asset
                    self.cutOutSubject = false
                    self.framing = .centered(asset.size)
                    self.error = nil
                    self.update()
                case .failure(let error):
                    self.busy = false
                    self.error = error.localizedDescription
                    self.message = self.asset == nil ? "Open a GIF, video or image to begin." : "Kept the previous file."
                }
            }
        }
    }
    func update() {
        pending?.cancel(); cancellation.cancel(); cancellation = CancellationFlag(); revision += 1
        result = nil
        guard let asset else { return }
        busy = true; message = "Preparing sticker preview…"
        let frame = framing, version = revision
        let cutOut = cutOutSubject
        let cancellation = cancellation
        pending = Task {
            do { try await Task.sleep(nanoseconds: 350_000_000) } catch { return }
            queue.async {
                var effectiveAsset = asset
                var cutoutError: String?
                if cutOut {
                    do { effectiveAsset = try asset.cuttingOutSubject() }
                    catch { cutoutError = error.localizedDescription }
                }
                let preparedAsset = effectiveAsset, failure = cutoutError
                let output = Result { try Encoder.export(asset: preparedAsset, framing: frame, cancelled: { cancellation.cancelled }) }
                Task { @MainActor in
                    guard version == self.revision else { return }
                    self.busy = false
                    self.displayedAsset = preparedAsset
                    if let failure {
                        self.cutOutSubject = false
                        self.error = failure
                    }
                    switch output {
                    case .success(let result): self.result = result; self.message = result.summary
                    case .failure(let error): self.error = error.localizedDescription; self.message = "Preview failed."
                    }
                }
            }
        }
    }
    func save() {
        guard let result, let asset else { return }
        guard !busy else { return }
        do {
            let url = try library.store.save(result.data, name: asset.url.lastPathComponent)
            library.selectedURL = url
            library.refresh()
            message = "Added '\(url.deletingPathExtension().lastPathComponent)' to the library"
            library.message = message
        } catch { self.error = error.localizedDescription }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: EditorModel?
    private var pendingURL: URL?
    func attach(_ model: EditorModel) {
        self.model = model
        if let pendingURL { model.load(pendingURL); self.pendingURL = nil }
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        if let path = filenames.first {
            let url = URL(fileURLWithPath: path)
            if let model { model.load(url) } else { pendingURL = url }
        }
        sender.reply(toOpenOrPrint: .success)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main struct GIFStickersApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = EditorModel()
    var body: some Scene {
        Window("GIF Stickers", id: "editor") {
            WorkspaceView(model: model)
                .onAppear {
                    delegate.attach(model)
                    NSApplication.shared.setActivationPolicy(.regular)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    if let path = ProcessInfo.processInfo.arguments.dropFirst().first, !path.hasPrefix("-") {
                        model.load(URL(fileURLWithPath: path))
                    }
                }
        }.defaultSize(width: 1130, height: 850)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open GIF, Video or Image…", action: model.openPanel).keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Add to Library", action: model.save).keyboardShortcut("s")
                    .disabled(model.result == nil || model.busy)
            }
        }
    }
}

struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(nsColor: .controlBackgroundColor)))
            for row in 0...Int(size.height/16) {
                for col in 0...Int(size.width/16) where (row+col)%2 == 0 {
                    context.fill(Path(CGRect(x: col*16, y: row*16, width: 16, height: 16)), with: .color(.gray.opacity(0.18)))
                }
            }
        }
    }
}

struct GIFCanvas: View {
    let asset: AnimationAsset
    @Binding var framing: Framing
    @State private var dragStart: Framing?
    @State private var resizeStart: Framing?
    @State private var epoch = Date()
    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width/asset.size.width, geometry.size.height/asset.size.height)
            let size = CGSize(width: asset.size.width*scale, height: asset.size.height*scale)
            ZStack(alignment: .topLeading) {
                Checkerboard()
                TimelineView(.animation(minimumInterval: 1/30)) { timeline in
                    let time = timeline.date.timeIntervalSince(epoch).truncatingRemainder(dividingBy: asset.duration)
                    if let image = asset.image(at: asset.frame(at: time)) {
                        Image(decorative: image, scale: 1).resizable().frame(width: size.width, height: size.height)
                    }
                }
                if !framing.fit {
                    Path { path in
                        path.addRect(CGRect(origin: .zero, size: size))
                        path.addRect(CGRect(x: framing.x*scale, y: framing.y*scale,
                                            width: framing.side*scale, height: framing.side*scale))
                    }.fill(.black.opacity(0.45), style: FillStyle(eoFill: true)).allowsHitTesting(false)
                    Rectangle().stroke(.white, lineWidth: 2)
                        .background(.white.opacity(0.001))
                        .frame(width: framing.side*scale, height: framing.side*scale)
                        .offset(x: framing.x*scale, y: framing.y*scale)
                        .gesture(DragGesture().onChanged { value in
                            if dragStart == nil { dragStart = framing }
                            var next = dragStart!
                            next.x += value.translation.width/scale; next.y += value.translation.height/scale
                            next.clamp(to: asset.size); framing = next
                        }.onEnded { _ in dragStart = nil })
                    RoundedRectangle(cornerRadius: 3).fill(.white).frame(width: 16, height: 16)
                        .offset(x: (framing.x+framing.side)*scale-8, y: (framing.y+framing.side)*scale-8)
                        .gesture(DragGesture().onChanged { value in
                            if resizeStart == nil { resizeStart = framing }
                            var next = resizeStart!
                            next.side += max(value.translation.width, value.translation.height)/scale
                            next.clamp(to: asset.size); framing = next
                        }.onEnded { _ in resizeStart = nil })
                }
            }.frame(width: size.width, height: size.height)
                .overlay(ScrollCapture { delta in
                    guard !framing.fit else { return }
                    var next = framing
                    let old = next.side
                    next.side *= exp(delta*0.01)
                    next.clamp(to: asset.size)
                    next.x += (old-next.side)/2; next.y += (old-next.side)/2
                    next.clamp(to: asset.size); framing = next
                }.allowsHitTesting(false))
                .position(x: geometry.size.width/2, y: geometry.size.height/2)
        }
    }
}

struct ScrollCapture: NSViewRepresentable {
    var scroll: (Double) -> Void
    class Capture: NSView {
        var callback: ((Double) -> Void)?
        var monitor: Any?
        override func viewDidMoveToWindow() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === self.window,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
                self.callback?(event.scrollingDeltaY)
                return nil
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
    func makeNSView(context: Context) -> Capture { let view = Capture(); view.callback = scroll; return view }
    func updateNSView(_ view: Capture, context: Context) { view.callback = scroll }
}

// WebKit plays the encoded WebP itself, including tuned timing and compression.
struct WebPPreview: NSViewRepresentable {
    let data: Data
    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView(); view.setValue(false, forKey: "drawsBackground"); return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.data != data else { return }
        context.coordinator.data = data
        view.loadHTMLString("""
        <html><meta name="viewport" content="width=device-width, initial-scale=1"><style>
        html,body{margin:0;width:100%;height:100%;overflow:hidden;background:transparent}img{width:100%;height:100%;object-fit:contain;display:block}
        </style><img src="data:image/webp;base64,\(data.base64EncodedString())"></html>
        """, baseURL: nil)
    }
    final class Coordinator { var data: Data? }
    func makeCoordinator() -> Coordinator { Coordinator() }
}

struct EditorView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var sender: SendModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading) {
                    Text("GIF Stickers").font(.largeTitle.bold())
                    Text(model.asset?.url.lastPathComponent ?? "Turn a GIF, video or image into a WhatsApp sticker.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open…", action: model.openPanel)
            }
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Frame your sticker").font(.headline)
                        Spacer()
                        if model.asset != nil {
                            Button("Choose another file…", action: model.openPanel).controlSize(.small)
                        }
                    }
                    ZStack {
                        RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.06))
                        if let asset = model.displayedAsset {
                            GIFCanvas(asset: asset, framing: $model.framing).padding(14)
                        } else {
                            Button(action: model.openPanel) {
                                Text("Click or drop a GIF, video or image here\n(PNG, JPEG, HEIC, TIFF, WebP, MP4, M4V, MOV)")
                                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .keyboardShortcut(.defaultAction)
                                .accessibilityLabel("Open GIF, video or image")
                                .accessibilityHint("Choose a GIF, video or still image to frame.")
                        }
                    }.frame(minWidth: 360, maxWidth: .infinity).frame(height: 512)
                    Text("Drag the square to pan · drag its corner or scroll to zoom").font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text("Sticker preview").font(.headline); Spacer(); Text("512 × 512").foregroundStyle(.secondary) }
                    ZStack {
                        Checkerboard()
                        if let result = model.result { WebPPreview(data: result.data) }
                        else if model.busy { ProgressView("Encoding preview…") }
                        else { Text("Your sticker appears here").foregroundStyle(.secondary) }
                    }.frame(width: 512, height: 512).clipShape(RoundedRectangle(cornerRadius: 10))
                    Text("Transparency shown as checks · preview plays the exported WebP").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Picker("Framing", selection: $model.framing.fit) {
                    Text("Crop").tag(false); Text("Fit with transparent padding").tag(true)
                }.pickerStyle(.segmented).frame(width: 300).disabled(model.asset == nil)
                if let asset = model.asset {
                    Button("Reset") { model.framing = .centered(asset.size) }
                }
                if model.asset?.isStillImage == true {
                    Toggle("Cut out subject", isOn: $model.cutOutSubject)
                        .toggleStyle(.checkbox)
                        .help("Remove the background on this Mac, keeping all detected subjects.")
                }
                Spacer()
                Button("Send to my WhatsApp") {
                    if let result = model.result { sender.prepare(result.data) }
                }.disabled(model.result == nil || model.busy || sender.busy || !sender.availability.ready)
                    .help(sender.availability.explanation)
                Button("Add to Library", action: model.save).buttonStyle(.borderedProminent)
                    .disabled(model.result == nil || model.busy)
            }
            Text(model.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
        }.padding(24).frame(minWidth: 1060, minHeight: 700)
            .onChange(of: model.cutOutSubject) { _, _ in model.update() }
            .onChange(of: model.framing) { _, _ in model.update() }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in model.load(url) } }
                }
                return true
            }
            .alert("GIF Stickers", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("OK") { model.error = nil }
            } message: { Text(model.error ?? "") }
    }
}
