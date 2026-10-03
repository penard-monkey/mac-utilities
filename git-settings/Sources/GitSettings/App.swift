import SwiftUI
import AppKit
import GitSettingsCore

@main
enum EntryPoint {
    static func main() {
        if ProcessInfo.processInfo.environment["GIT_SETTINGS_ASKPASS"] == "1" {
            // OpenSSH invokes this executable as its askpass helper. Its private pipe is the
            // only destination for the passphrase; the parent app never sees or stores it.
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let alert = NSAlert()
            alert.messageText = "SSH passphrase"
            alert.informativeText = CommandLine.arguments.dropFirst().joined(separator: " ") + "\nLeave empty only if you want an unencrypted key."
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Cancel")
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 26))
            field.placeholderString = "Passphrase"
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            app.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { exit(1) }
            FileHandle.standardOutput.write(Data((field.stringValue + "\n").utf8))
            field.stringValue = ""
            exit(0)
        }
        GitSettingsApp.main()
    }
}

struct GitSettingsApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("Git & SSH") {
            ContentView().environmentObject(model)
                .frame(minWidth: 880, minHeight: 650)
        }
        .defaultSize(width: 1050, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Refresh Git & SSH") { model.refresh() }.keyboardShortcut("r").disabled(model.busy)
            }
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    let paths = AppPaths.current()
    var gitService: GitService { GitService(paths: paths) }
    var sshService: SSHService { SSHService(paths: paths) }
    var transactions: TransactionStore { TransactionStore(directory: paths.state.appendingPathComponent("backups")) }
    @Published var git: GitSnapshot?
    @Published var agent: AgentSnapshot?
    @Published var keys: [PublicKey] = []
    @Published var sshConfig = SSHConfigSnapshot.parse("")
    @Published var editable: [String: String] = [:]
    @Published var backups: [BackupRecord] = []
    @Published var busy = false
    @Published var error: String?
    @Published var notice: String?
    @Published var preview: ChangePreview?
    @Published var diagnostic: CommandResult?
    @Published var diagnosticDestination: String?
    @Published var lastRefreshed: Date?

    func perform(_ work: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do { try await work() }
            catch { self.error = error.localizedDescription }
        }
    }
    func refresh() { perform { try await self.readState() } }
    func readState() async throws {
        // Each area reports a failure independently so a broken Git file doesn't hide SSH.
        var failures: [String] = []
        do {
            let snapshot = try await gitService.snapshot()
            git = snapshot; editable = snapshot.editable
        } catch { git = nil; failures.append("Git: " + error.localizedDescription) }
        do {
            let currentAgent = try await sshService.agent()
            agent = currentAgent
            keys = try await sshService.keys(agent: currentAgent)
        } catch { failures.append("SSH keys: " + error.localizedDescription) }
        do { sshConfig = try sshService.config() }
        catch { failures.append("SSH config: " + error.localizedDescription) }
        do { backups = try transactions.records() }
        catch { failures.append("Backups: " + error.localizedDescription) }
        lastRefreshed = Date()
        if !failures.isEmpty { throw AppError.message(failures.joined(separator: "\n\n")) }
    }
    func previewSettings() {
        let changed = editable.filter { $0.value != (git?.editable[$0.key] ?? "") }
        guard !changed.isEmpty else { notice = "No settings changed."; return }
        perform { self.preview = try await self.gitService.preview(changes: changed) }
    }
    func previewAlias(name: String, command: String) {
        perform { self.preview = try await self.gitService.preview(changes: ["alias." + name: command]) }
    }
    func previewHost(_ draft: HostDraft) { perform { self.preview = try self.sshService.previewHost(draft) } }
    func apply(_ preview: ChangePreview) {
        perform {
            let store = self.transactions
            _ = try await Task.detached { try store.apply(preview) }.value
            self.preview = nil
            self.notice = "Applied. A timestamped backup is available in Git Settings."
            try await self.readState()
        }
    }
    func restore(_ record: BackupRecord) {
        perform {
            let store = self.transactions
            try await Task.detached { try store.restore(record) }.value
            self.notice = "Restored \(URL(fileURLWithPath: record.path).lastPathComponent)."
            try await self.readState()
        }
    }
    var askpass: String { Bundle.main.executableURL?.path ?? CommandLine.arguments[0] }
    func generate(name: String, comment: String) {
        perform {
            try await self.sshService.generate(name: name, comment: comment, askpass: self.askpass)
            self.notice = "Created \(name). Copy its public key to your Git host before authenticating."
            try await self.readState()
        }
    }
    func load(_ key: PublicKey) {
        perform { try await self.sshService.load(key, askpass: self.askpass); try await self.readState() }
    }
    func unload(_ key: PublicKey) {
        perform { try await self.sshService.unload(key); try await self.readState() }
    }
    func diagnose(_ destination: String) {
        perform {
            self.diagnostic = nil
            self.diagnosticDestination = destination
            self.diagnostic = try await self.sshService.diagnose(destination)
        }
    }
    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        notice = "Public key copied."
    }
    func editFile(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { error = "The file does not exist yet. Apply a setting or add a host first."; return }
        NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"), configuration: .init()) { _, failure in
            if let failure { Task { @MainActor in self.error = failure.localizedDescription } }
        }
    }
}

enum Pane: String, CaseIterable, Identifiable {
    case overview = "Overview", settings = "Git Settings", keys = "SSH Keys", hosts = "SSH Hosts", diagnostics = "Diagnostics"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .settings: return "slider.horizontal.3"
        case .keys: return "key.horizontal"
        case .hosts: return "network"
        case .diagnostics: return "stethoscope"
        }
    }
    var subtitle: String {
        switch self {
        case .overview: return "Your machine’s commit settings and authentication tools."
        case .settings: return "Edit global defaults with a preview and a backup."
        case .keys: return "Public identities on this Mac and keys in the current agent."
        case .hosts: return "Inspect your SSH configuration and add a host safely."
        case .diagnostics: return "Test SSH authentication when you choose."
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: Pane? = .overview
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "point.3.connected.trianglepath.dotted").font(.title).foregroundStyle(.tint)
                    VStack(alignment: .leading) { Text("Git & SSH").font(.headline); Text("Machine settings").font(.caption).foregroundStyle(.secondary) }
                }.padding(20)
                List(Pane.allCases, selection: $selection) { pane in Label(pane.rawValue, systemImage: pane.icon).tag(pane) }
                VStack(alignment: .leading, spacing: 6) {
                    Label("Local configuration", systemImage: "desktopcomputer").font(.caption)
                    Text("Network tests run only on demand.").font(.caption2).foregroundStyle(.secondary)
                }.padding(20)
            }.navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } detail: {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text((selection ?? .overview).rawValue).font(.largeTitle.bold())
                        Text((selection ?? .overview).subtitle).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.busy { ProgressView().controlSize(.small) }
                    Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh configuration and agent state").disabled(model.busy)
                }.padding(26)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if let notice = model.notice {
                            HStack { Label(notice, systemImage: "checkmark.circle").foregroundStyle(.green); Spacer(); Button { model.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
                                .font(.callout).padding(12).background(.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                        }
                        switch selection ?? .overview {
                        case .overview: OverviewView()
                        case .settings: SettingsView()
                        case .keys: KeysView()
                        case .hosts: HostsView()
                        case .diagnostics: DiagnosticsView()
                        }
                    }.padding(26).frame(maxWidth: 1100, alignment: .leading)
                }
                if let refreshed = model.lastRefreshed {
                    Divider()
                    HStack { Text("Updated \(refreshed.formatted(date: .omitted, time: .shortened))"); Spacer(); Text("Global defaults · repository overrides may apply") }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 26).padding(.vertical, 9)
                }
            }.background(Color(nsColor: .windowBackgroundColor))
        }
        .task { if model.lastRefreshed == nil { model.refresh() } }
        .alert("Action couldn’t finish", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        .sheet(item: $model.preview) { preview in PreviewView(preview: preview).environmentObject(model) }
    }
}

struct Card<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Label(title, systemImage: icon).font(.headline)
            content
        }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.07)))
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .top) { Text(label).foregroundStyle(.secondary).frame(width: 110, alignment: .leading); Text(value).textSelection(.enabled); Spacer(minLength: 0) }.font(.callout)
    }
}

struct OverviewView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Card(title: "Commit identity", icon: "person.crop.circle") {
            InfoRow(label: "Name", value: model.git?.value("user.name") ?? "Unavailable")
            InfoRow(label: "Email", value: model.git?.value("user.email") ?? "Unavailable")
            Text("This labels commits. SSH keys and HTTPS credentials authenticate to a remote host. Changing one does not change the others.").font(.callout).foregroundStyle(.secondary)
        }
        HStack(alignment: .top, spacing: 16) {
            Card(title: "Git installation", icon: "terminal") {
                Text(model.git?.version ?? "Git unavailable").font(.title3.weight(.medium))
                Text(model.git?.binary ?? model.paths.git).font(.caption.monospaced()).textSelection(.enabled)
                InfoRow(label: "Sign commits", value: model.git?.value("commit.gpgSign") ?? "Unavailable")
                InfoRow(label: "Format", value: model.git?.value("gpg.format") ?? "Unavailable")
            }
            Card(title: "SSH agent", icon: "key.horizontal") {
                Text(model.agent?.description ?? "Checking agent…").font(.title3.weight(.medium))
                Text(model.agent?.socket ?? "No SSH_AUTH_SOCK supplied to this app.").font(.caption.monospaced()).textSelection(.enabled)
                Text("Uses your existing agent. Keys loaded here are not automatically persisted to Keychain.").font(.callout).foregroundStyle(.secondary)
            }
        }
        Card(title: "HTTPS authentication", icon: "lock.shield") {
            if let helpers = model.git?.helper, !helpers.isEmpty {
                ForEach(Array(helpers.enumerated()), id: \.offset) { _, helper in
                    InfoRow(label: "Helper", value: ["osxkeychain", "manager", "manager-core", "cache", "store"].contains(helper.value) ? helper.value : (helper.value.isEmpty ? "Helper reset" : "Custom helper configured"))
                    Text(helper.origin).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
            } else { Text("No global credential helper configured.") }
            Text("A configured helper is not proof that you are signed in. Credentials are managed by the helper; this app does not read them.").font(.callout).foregroundStyle(.secondary)
        }
        Card(title: "Scope matters", icon: "info.circle") {
            Text("These are global values, including unconditional includes. Repository and system settings, conditional includes, and environment overrides can change what a Git command uses. Signing also requires the corresponding signing tool and key.").foregroundStyle(.secondary)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var aliasName = ""
    @State private var aliasCommand = ""
    @State private var restoring: BackupRecord?
    var body: some View {
        Card(title: "Global defaults", icon: "slider.horizontal.3") {
            Text(model.git?.target.path ?? model.paths.gitConfig.path).font(.caption.monospaced()).textSelection(.enabled)
            Text("Fields show values stored directly in this file. Empty removes a value from this file; included values may still apply.").font(.callout).foregroundStyle(.secondary)
            ForEach(GitField.all) { field in
                HStack(alignment: .top, spacing: 16) {
                    Text(field.title).frame(width: 135, alignment: .leading).padding(.top, 5)
                    VStack(alignment: .leading, spacing: 4) {
                        TextField(field.hint, text: Binding(get: { model.editable[field.key] ?? "" }, set: { model.editable[field.key] = $0 })).textFieldStyle(.roundedBorder)
                        Text(field.hint).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Button("Preview changes") { model.previewSettings() }.buttonStyle(.borderedProminent).disabled(model.busy || model.git == nil)
                Button("Open config in TextEdit") { model.editFile(model.paths.gitConfig) }
            }
        }
        Card(title: "Global values and sources", icon: "doc.text.magnifyingglass") {
            if let values = model.git?.values, !values.isEmpty {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack { Text(value.key).font(.caption.monospaced()).frame(width: 145, alignment: .leading); Text(value.value).textSelection(.enabled) }
                        Text(value.origin).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            } else { Text("No supported global settings found.").foregroundStyle(.secondary) }
        }
        Card(title: "Git alias", icon: "text.badge.plus") {
            Text("Add or replace a global alias. An empty command removes it. Git executes aliases beginning with ! as shell commands when you later invoke them.").font(.callout).foregroundStyle(.secondary)
            HStack { TextField("Alias, e.g. st", text: $aliasName).frame(width: 150); TextField("Command, e.g. status --short", text: $aliasCommand) }.textFieldStyle(.roundedBorder)
            Button("Preview alias") { model.previewAlias(name: aliasName, command: aliasCommand) }.disabled(model.busy || aliasName.isEmpty || model.git == nil)
        }
        Card(title: "Config backups", icon: "clock.arrow.circlepath") {
            Text("Restore is allowed only while the file exactly matches the applied version. Later edits require manual recovery.").font(.callout).foregroundStyle(.secondary)
            if model.backups.isEmpty { Text("Backups appear after your first change.").foregroundStyle(.secondary) }
            ForEach(model.backups) { backup in
                HStack {
                    VStack(alignment: .leading) { Text(backup.summary).lineLimit(2); Text(backup.date.formatted()).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Restore…") { restoring = backup }.disabled(model.busy)
                }
            }
            Button("Reveal backup folder") { NSWorkspace.shared.activateFileViewerSelecting([model.transactions.directory]) }.disabled(model.backups.isEmpty)
        }
        .confirmationDialog("Restore this backup?", isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } }), titleVisibility: .visible) {
            if let backup = restoring { Button("Restore \(URL(fileURLWithPath: backup.path).lastPathComponent)") { model.restore(backup); restoring = nil } }
        } message: { Text("The entire file returns to its saved state. Restore will refuse if any later edits are present.") }
    }
}

struct KeysView: View {
    @EnvironmentObject var model: AppModel
    @State private var keyName = "id_ed25519_git"
    @State private var comment = ""
    var body: some View {
        Card(title: "Public key inventory", icon: "key.horizontal") {
            Text("Only .pub files directly in ~/.ssh are inventoried. Private-key contents are never opened by this app. Public keys in other paths and agent-only identities may not appear here.").font(.callout).foregroundStyle(.secondary)
            if model.keys.isEmpty { ContentUnavailableView("No public keys found", systemImage: "key", description: Text("Generate a key below, or place its public .pub file in ~/.ssh.")) }
            ForEach(model.keys) { key in
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text(key.name).font(.headline); Spacer(); Label(key.loaded ? "In agent" : "Not loaded", systemImage: key.loaded ? "checkmark.circle.fill" : "circle").font(.caption).foregroundStyle(key.loaded ? .green : .secondary) }
                    Text(key.fingerprint).font(.callout.monospaced()).textSelection(.enabled)
                    Text(key.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    HStack {
                        Button("Copy public key") { model.copy(key.text) }
                        Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([key.url]) }
                        if key.loaded { Button("Unload from agent") { model.unload(key) }.disabled(model.busy || model.agent?.available != true) }
                        else { Button("Load into agent…") { model.load(key) }.disabled(model.busy || !key.hasPrivateFile || model.agent?.available != true) }
                    }
                    if !key.hasPrivateFile { Text("Matching private-key file is absent; loading is unavailable.").font(.caption).foregroundStyle(.secondary) }
                }.padding(.vertical, 9)
                Divider()
            }
            Text(model.agent?.description ?? "Agent unavailable").font(.callout).foregroundStyle(.secondary)
        }
        Card(title: "Generate an Ed25519 key", icon: "plus.circle") {
            Text("You’ll enter and confirm a passphrase in secure OpenSSH prompts. New files are created without overwriting existing keys. This does not upload your public key or load it into the agent.").font(.callout).foregroundStyle(.secondary)
            TextField("File name", text: $keyName).textFieldStyle(.roundedBorder)
            TextField("Public comment, e.g. your email", text: $comment).textFieldStyle(.roundedBorder)
            Text("Destination: \(model.paths.ssh.path)/\(keyName)").font(.caption.monospaced()).foregroundStyle(.secondary)
            Button("Generate key…") { model.generate(name: keyName, comment: comment) }.buttonStyle(.borderedProminent).disabled(model.busy || keyName.isEmpty)
        }
    }
}

struct HostsView: View {
    @EnvironmentObject var model: AppModel
    @State private var alias = ""
    @State private var hostname = "github.com"
    @State private var user = "git"
    @State private var port = "22"
    @State private var identity = ""
    var body: some View {
        Card(title: "Host declarations", icon: "network") {
            Text(model.paths.sshConfig.path).font(.caption.monospaced()).textSelection(.enabled)
            if model.sshConfig.hosts.isEmpty { Text("No Host declarations in the main config.").foregroundStyle(.secondary) }
            ForEach(model.sshConfig.hosts) { host in InfoRow(label: "Line \(host.line)", value: host.patterns) }
            if model.sshConfig.hasIncludes { Label("Includes are preserved. Included files are not inventoried here.", systemImage: "doc.on.doc").font(.callout).foregroundStyle(.secondary) }
            if model.sshConfig.hasMatch { Label("Match rules are preserved and not evaluated here.", systemImage: "line.3.horizontal.decrease").font(.callout).foregroundStyle(.secondary) }
            Button("Edit existing config in TextEdit") { model.editFile(model.paths.sshConfig) }
        }
        Card(title: "Add a host alias", icon: "plus.circle") {
            Text("A literal host block is inserted after global directives and before existing Host/Match blocks. Existing global defaults and Includes can take precedence. Existing or complex blocks are edited in your own editor.").font(.callout).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                GridRow { Text("Alias"); TextField("work-github", text: $alias) }
                GridRow { Text("Hostname"); TextField("github.com", text: $hostname) }
                GridRow { Text("User"); TextField("git", text: $user) }
                GridRow { Text("Port"); TextField("22", text: $port) }
                GridRow { Text("Identity file"); TextField("Optional: ~/.ssh/id_ed25519_git", text: $identity) }
            }.textFieldStyle(.roundedBorder)
            Button("Preview host") { model.previewHost(.init(alias: alias, hostname: hostname, user: user, port: port, identity: identity)) }.buttonStyle(.borderedProminent).disabled(model.busy || alias.isEmpty)
        }
        DisclosureGroup("Main SSH config") {
            Text(model.sshConfig.text.isEmpty ? "No config file yet." : model.sshConfig.text).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
        }
    }
}

struct DiagnosticsView: View {
    @EnvironmentObject var model: AppModel
    @State private var destination = "git@github.com"
    var body: some View {
        Card(title: "SSH authentication test", icon: "stethoscope") {
            Text("Connects once using your SSH config and current agent. No password prompts, no forwarding, and no known-hosts updates. The host must already be trusted in known_hosts. A test is limited to 15 seconds.").font(.callout).foregroundStyle(.secondary)
            Text("Existing ProxyCommand, ProxyJump or Match exec rules in your SSH config may run as part of this test.").font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Host alias or user@hostname", text: $destination).textFieldStyle(.roundedBorder).onSubmit { if !model.busy { model.diagnose(destination) } }
                Button("Test authentication") { model.diagnose(destination) }.buttonStyle(.borderedProminent).disabled(model.busy || destination.isEmpty)
            }
        }
        if let result = model.diagnostic {
            Card(title: "Result: \(model.diagnosticDestination ?? "SSH")", icon: result.timedOut ? "clock" : "text.alignleft") {
                Text(result.timedOut ? "Timed out" : "SSH exit status \(result.status)").font(.headline)
                Text(result.output + result.error).font(.callout.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        Card(title: "Reading the result", icon: "info.circle") {
            Text("Git hosts often report successful authentication and then exit with status 1 because they don’t provide a shell. Read the host’s message as well as the exit status. Permission denied usually means no accepted key; host-key verification failure means trust must first be established outside this app.").font(.callout).foregroundStyle(.secondary)
            Text("SSH success does not verify HTTPS credentials, commit identity, commit signing, or access to any particular repository.").font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct PreviewView: View {
    @EnvironmentObject var model: AppModel
    let preview: ChangePreview
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review changes").font(.title2.bold())
            Text(preview.summary).foregroundStyle(.secondary)
            Text("A timestamped backup is saved before applying. If the file changes while this preview is open, apply will refuse.").font(.callout)
            ScrollView([.horizontal, .vertical]) { Text(preview.diff).font(.callout.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(16) }
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Spacer()
                Button("Cancel") { model.preview = nil }.keyboardShortcut(.cancelAction).disabled(model.busy)
                Button("Apply changes") { model.apply(preview) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(model.busy || preview.before == preview.after)
            }
        }.padding(24).frame(width: 720, height: 520)
    }
}
