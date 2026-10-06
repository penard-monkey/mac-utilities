import AppKit
import Foundation

/// The Quick Look extension's registration as reported by pluginkit, plus the
/// few actions the window offers. All commands are system tools called by
/// absolute path.
@MainActor
final class ExtensionStatus: ObservableObject {
    enum State: Equatable {
        case checking, on, off, notRegistered
        case otherCopy(String)
    }

    @Published private(set) var state: State = .checking
    @Published private(set) var message = ""

    let extensionID = (Bundle.main.bundleIdentifier ?? "com.mac-utilities.video-preview") + ".quicklook"
    var extensionURL: URL? {
        Bundle.main.builtInPlugInsURL?.appendingPathComponent("VideoPreviewQuickLook.appex")
    }

    init() {
        Task { await registerAndCheck() }
    }

    /// Launching the app registers its extension, so a fresh install works
    /// after one launch even without the manager.
    func registerAndCheck() async {
        if let path = extensionURL?.path {
            _ = await Self.run("/usr/bin/pluginkit", ["-a", path])
        }
        await check()
    }

    func check() async {
        let output = await Self.run("/usr/bin/pluginkit", ["-m", "-v", "-i", extensionID])
        state = Self.parse(output, id: extensionID, expectedPath: extensionURL?.path)
    }

    func setEnabled(_ enabled: Bool) async {
        _ = await Self.run("/usr/bin/pluginkit", ["-e", enabled ? "use" : "ignore", "-i", extensionID])
        await refreshQuickLook(quiet: true)
        await check()
        message = enabled ? "Turned on. Previews use Video Preview." : "Turned off. Finder goes back to its own previews."
    }

    func refreshQuickLook(quiet: Bool = false) async {
        _ = await Self.run("/usr/bin/qlmanage", ["-r"])
        _ = await Self.run("/usr/bin/qlmanage", ["-r", "cache"])
        if !quiet { message = "Quick Look refreshed." }
    }

    /// pluginkit -m -v prints one line per match: an election flag
    /// ("+" use, "-" ignore, " " default), the id and version, then tab
    /// separated uuid, date and path.
    nonisolated static func parse(_ output: String, id: String, expectedPath: String?) -> State {
        guard let line = output.split(separator: "\n").first(where: { $0.contains(id + "(") }) else {
            return .notRegistered
        }
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        let flag = line.first(where: { $0 != " " && $0 != "\t" })
        if let expectedPath, let path = line.split(separator: "\t").last.map(String.init),
           path.hasPrefix("/"), URL(fileURLWithPath: path).standardized.path != URL(fileURLWithPath: expectedPath).standardized.path {
            return .otherCopy(path)
        }
        if flag == "-" || trimmed.hasPrefix("-") { return .off }
        return .on
    }

    nonisolated static func run(_ tool: String, _ arguments: [String]) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: tool)
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: String(decoding: data, as: UTF8.self))
                } catch {
                    continuation.resume(returning: "")
                }
            }
        }
    }
}
