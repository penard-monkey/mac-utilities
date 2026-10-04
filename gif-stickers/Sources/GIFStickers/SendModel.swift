import SwiftUI

@MainActor final class SendModel: ObservableObject {
    @Published private(set) var availability = SendAvailability.checking
    @Published private(set) var busy = false
    @Published var confirming = false
    @Published private(set) var status: String?
    private var pending: Data?
    private let client: SayWhatClient
    private var checking = false

    init(client: SayWhatClient = SayWhatClient()) { self.client = client }
    func refresh() async {
        guard !checking else { return }
        checking = true
        availability = await client.availability()
        checking = false
    }
    func prepare(_ data: Data) {
        guard availability.ready, !busy else { return }
        do {
            _ = try StickerValidation.check(data)
            pending = data; confirming = true
        } catch { status = error.localizedDescription }
    }
    func cancel() { pending = nil; confirming = false }
    func confirm() {
        guard let data = pending, !busy else { return }
        pending = nil; confirming = false; busy = true; status = "Sending sticker through SayWhat…"
        Task {
            do {
                try await client.send(data)
                status = "Sent to your own WhatsApp chat. Open it on your phone and add the sticker to Favourites."
            } catch { status = error.localizedDescription }
            busy = false
            await refresh()
        }
    }
}

@MainActor struct WorkspaceView: View {
    @ObservedObject var model: EditorModel
    @StateObject private var sender: SendModel
    @State private var libraryVisible = false
    init(model: EditorModel, sender: SendModel? = nil) {
        self.model = model
        _sender = StateObject(wrappedValue: sender ?? SendModel())
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("View", selection: $libraryVisible) {
                    Text("Create Sticker").tag(false)
                    Text("Library").tag(true)
                }.pickerStyle(.segmented).frame(width: 270)
                Spacer()
            }.padding(.horizontal, 24).padding(.top, 16)
            if libraryVisible { LibraryView(model: model.library, sender: sender) }
            else { EditorView(model: model, sender: sender) }
            HStack {
                if sender.busy { ProgressView().controlSize(.small) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(sender.availability.explanation)
                    if let status = sender.status { Text(status).textSelection(.enabled) }
                }.font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Refresh SayWhat") { Task { await sender.refresh() } }.disabled(sender.busy)
            }.padding(.horizontal, 24).padding(.bottom, 16)
        }.alert("Send this sticker to your own WhatsApp chat?", isPresented: $sender.confirming) {
            Button("Cancel", role: .cancel, action: sender.cancel)
            Button("Send", action: sender.confirm)
        } message: { Text("SayWhat will send this exact WebP as a sticker. You can add it to Favourites on your phone.") }
            .task {
                while !Task.isCancelled {
                    await sender.refresh()
                    do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { break }
                }
            }
    }
}
