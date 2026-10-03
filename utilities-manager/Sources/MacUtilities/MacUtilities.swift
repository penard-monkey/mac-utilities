import AppKit
import Foundation
import SwiftUI

struct Utility: Decodable, Identifiable {
    let id: String
    let name: String
    let description: String
    let available: Bool
    let source: String?
    let installed: Bool
    let healthy: Bool
    let issue: String?
    let version: String?
    let availableVersion: String?
    let presentation: String
    let visible: Bool
    let app: String?
    let privileged: Bool
    let commands: [String: String]
    let systemDetected: Bool
    let legacyPlugin: Bool
    let externalApp: String?
    let missingDependencies: [String]

    enum CodingKeys: String, CodingKey {
        case id, name, description, available, source, installed, healthy, issue, version
        case availableVersion = "available_version"
        case presentation, visible, app, privileged, commands
        case systemDetected = "system_detected"
        case legacyPlugin = "legacy_plugin"
        case externalApp = "external_app"
        case missingDependencies = "missing_dependencies"
    }
    var icon: String {
        switch id {
        case "memory": return "memorychip"
        case "travel-router": return "network"
        case "gif-stickers": return "photo.stack"
        case "git-settings": return "point.3.connected.trianglepath.dotted"
        default: return "square.grid.2x2"
        }
    }
}
struct CatalogSource: Decodable, Identifiable {
    let path: String
    let primary: Bool
    let available: Bool
    var id: String { path }
}
struct Catalog: Decodable { let utilities: [Utility] }
struct SourceCatalog: Decodable { let sources: [CatalogSource] }
struct BackendFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
final class ManagerModel: ObservableObject {
    @Published var utilities: [Utility] = []
    @Published var sources: [CatalogSource] = []
    @Published var source: String
    @Published var busy = false
    @Published var message: String?
    @Published var error: String?
    private let backend: String
    private let home: String
    private let isolated: Bool
    private let settings: URL

    init() {
        let environment = ProcessInfo.processInfo.environment
        home = environment["MAC_UTILITIES_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        isolated = environment["MAC_UTILITIES_NO_SYSTEM_EFFECTS"] == "1"
        settings = URL(fileURLWithPath: home).appendingPathComponent(".config/mac-utilities/utilities-manager.json")
        let saved = (try? Data(contentsOf: settings)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: String]
        backend = Bundle.main.resourceURL?.appendingPathComponent("Backend/lifecycle.py").path
            ?? ""
        source = environment["MAC_UTILITIES_SOURCE"]
            ?? saved?["source"]
            ?? Bundle.main.resourceURL?.appendingPathComponent("Catalog").path ?? ""
    }

    func chooseSource() {
        let panel = NSOpenPanel()
        panel.title = "Choose a mac-utilities checkout"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            source = url.path
            saveSource()
            Task { await refresh() }
        }
    }

    func bundledSource() {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Catalog") else { return }
        source = url.path
        saveSource()
        Task { await refresh() }
    }

    func addSource() {
        let panel = NSOpenPanel()
        panel.title = "Add a utility repository"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            Task { await changeSource("add", path: url.path) }
        }
    }

    func changeSource(_ action: String, path: String) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            _ = try await invoke("source", id: action, extra: path)
            try await loadCatalog()
            message = action == "add" ? "Catalog source added." : "Catalog source removed. Installed tools are kept."
        } catch { self.error = error.localizedDescription }
    }

    private func loadCatalog() async throws {
        // Sources remain editable even when a utility id clashes or a folder vanishes.
        sources = try JSONDecoder().decode(SourceCatalog.self, from: await invoke("source", id: "list")).sources
        utilities = []
        utilities = try JSONDecoder().decode(Catalog.self, from: await invoke("list")).utilities
    }

    private func saveSource() {
        do {
            try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: ["source": source], options: [.prettyPrinted])
            try data.write(to: settings, options: .atomic)
        } catch { self.error = error.localizedDescription }
    }

    private func invoke(_ action: String, id: String? = nil, extra: String? = nil) async throws -> Data {
        let executable = backend
        var arguments = [executable, "--repo", source, "--home", home]
        if isolated { arguments.append("--no-system-effects") }
        arguments.append(action)
        if let id { arguments.append(id) }
        if let extra { arguments.append(extra) }
        let commandArguments = arguments
        return try await Task.detached(priority: .userInitiated) {
            guard FileManager.default.fileExists(atPath: executable) else {
                throw BackendFailure(message: "The bundled installer is missing. Reinstall Mac Utilities.app.")
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = commandArguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            // Drain before waitUntilExit so hook build logs cannot fill a pipe.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                throw BackendFailure(message: object?["error"] as? String ?? String(decoding: data, as: UTF8.self))
            }
            return data
        }.value
    }

    func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await loadCatalog()
        } catch { self.error = error.localizedDescription }
    }

    func perform(_ action: String, utility: Utility, extra: String? = nil) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let data = try await invoke(action, id: utility.id, extra: extra)
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            message = object?["message"] as? String
            try await loadCatalog()
        } catch { self.error = error.localizedDescription }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        message = "Command copied. Run it in Terminal and review its output."
    }
}

struct UtilityRow: View {
    @ObservedObject var model: ManagerModel
    let utility: Utility
    @State private var confirmRemoval = false
    @State private var confirmForget = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: utility.icon).font(.title2).frame(width: 32).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(utility.name).font(.headline)
                        Spacer()
                        Text(utility.installed ? (utility.privileged ? "Staged" : "Installed") : ((utility.legacyPlugin || utility.systemDetected || utility.externalApp != nil) ? "Existing installation" : "Not installed"))
                            .font(.caption).foregroundStyle(utility.installed ? .green : .secondary)
                    }
                    Text(utility.description).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let source = utility.source {
                        Text("Source: \(source)").font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if let version = utility.version {
                        Text("Installed version \(version)").font(.caption).foregroundStyle(.secondary)
                    }
                    if utility.legacyPlugin {
                        Text("Existing repository menu link detected. Install migrates it to a stable copy.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let externalApp = utility.externalApp {
                        Text("An app already exists at \(externalApp). It is not owned by this manager; move it aside to install a managed copy.")
                            .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    }
                    if utility.systemDetected {
                        Text("Existing system files detected. System setup has not been verified.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    ForEach(utility.missingDependencies, id: \.self) { dependency in
                        Label(dependency, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    }
                    if let issue = utility.issue {
                        Label(issue, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                }
            }
            HStack(spacing: 10) {
                if utility.installed {
                    if utility.app != nil {
                        Button("Open app") { Task { await model.perform("open", utility: utility) } }
                            .disabled(!utility.healthy)
                    }
                    Button("Update") { Task { await model.perform("update", utility: utility) } }
                        .disabled(!utility.available || !utility.healthy)
                        .help("Reinstall from the selected source, retaining settings and menu visibility")
                    if utility.privileged {
                        Button("System commands") { model.message = "Copy the setup or removal command below and run it in Terminal. Administrator access is required." }
                    } else {
                        Button("Uninstall", role: .destructive) { confirmRemoval = true }.disabled(!utility.healthy)
                    }
                    Spacer()
                    Toggle("Show in menu bar", isOn: Binding(get: { utility.visible }, set: { value in
                        Task { await model.perform("menu", utility: utility, extra: value ? "show" : "hide") }
                    })).toggleStyle(.switch).disabled(!utility.healthy)
                        .help(utility.app != nil ? "Show this app in the Tools launcher" : "Show this SwiftBar plugin")
                } else {
                    Button(utility.privileged ? "Install menu & stage setup" : "Install") {
                        Task { await model.perform("install", utility: utility) }
                    }.buttonStyle(.borderedProminent).disabled(!utility.available || utility.externalApp != nil)
                    if !utility.available {
                        Text("Choose a complete source checkout to install.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            if utility.privileged && utility.installed {
                VStack(alignment: .leading, spacing: 8) {
                    Text("System setup is managed separately in Terminal. Installing or updating here stages files and the menu plugin.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(["install", "uninstall"], id: \.self) { action in
                        if let command = utility.commands[action] {
                            HStack(alignment: .top) {
                                Text(action == "install" ? "Set up:" : "Remove:").font(.caption).frame(width: 58, alignment: .leading)
                                Text(command).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Button("Copy") { model.copy(command) }
                                Button("Run in Terminal") {
                                    Task { await model.perform("run-terminal", utility: utility, extra: action) }
                                }
                            }
                        }
                    }
                    Button("Remove staged files after system uninstall…", role: .destructive) { confirmForget = true }
                }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
        .disabled(model.busy)
        .confirmationDialog("Uninstall \(utility.name)?", isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button("Uninstall", role: .destructive) { Task { await model.perform("uninstall", utility: utility) } }
        } message: { Text("Only files owned by Mac Utilities will be removed. Preferences, Git configuration, and SSH keys are retained.") }
        .confirmationDialog("Have you completed the system uninstall in Terminal?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("System uninstall completed — remove staged files", role: .destructive) {
                Task { await model.perform("forget-system", utility: utility) }
            }
        } message: { Text("Run the supplied system removal command first. Removing these staged files does not remove system services or change networking.") }
    }
}

struct ManagerView: View {
    @StateObject private var model = ManagerModel()
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Mac Utilities").font(.largeTitle.bold())
                    Text("Install the tools you use. Choose which ones appear in your menu bar.").foregroundStyle(.secondary)
                }
                Spacer()
                if model.busy { ProgressView().controlSize(.small).padding(.top, 8) }
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh installation status").disabled(model.busy)
            }.padding(24)
            Divider()
            ScrollView {
                VStack(spacing: 14) {
                    if let message = model.message {
                        HStack {
                            Text(message).font(.callout).textSelection(.enabled)
                            Spacer()
                            Button { model.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                        }.padding(14).background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    }
                    ForEach(model.utilities) { utility in UtilityRow(model: model, utility: utility) }
                    Text("Menu plugins need SwiftBar. App menu entries appear in the Tools launcher. Preferences are kept when a tool is removed.")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }.padding(24)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Catalog sources").font(.caption.bold())
                    Spacer()
                    Button("Bundled source") { model.bundledSource() }.disabled(model.busy)
                    Button("Choose folder…") { model.chooseSource() }.disabled(model.busy)
                    Button("Add source…") { model.addSource() }.disabled(model.busy)
                }
                ForEach(model.sources) { source in
                    HStack {
                        Text(source.primary ? "Primary" : "Extra").font(.caption).frame(width: 48, alignment: .leading)
                        Text(source.path).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        if !source.available { Text("Unavailable").font(.caption).foregroundStyle(.orange) }
                        Spacer()
                        if !source.primary {
                            Button("Remove") { Task { await model.changeSource("remove", path: source.path) } }
                                .disabled(model.busy).help("Remove this source; keep installed tools")
                        }
                    }
                }
            }.padding(16)
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 620, idealHeight: 840)
        .task { await model.refresh() }
        .alert("Couldn’t complete the action", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

@main
struct MacUtilitiesApp: App {
    var body: some Scene {
        Window("Mac Utilities", id: "manager") { ManagerView() }
            .defaultSize(width: 820, height: 840)
            .commands { CommandGroup(replacing: .newItem) {} }
    }
}
