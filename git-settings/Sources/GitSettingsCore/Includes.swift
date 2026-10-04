import Foundation

public struct IncludeRule: Identifiable, Sendable {
    public let id: Int
    public let condition: String?
    public let path: String
    public let target: URL?
    public let exists: Bool
    public let overrides: [ConfigValue]
    public let editIssue: String?
    let source: FileState
    public var title: String { condition ?? "Always include" }
}

public struct IncludeDraft: Sendable {
    public var condition: String?
    public var path: String
    public init(condition: String? = nil, path: String) { self.condition = condition; self.path = path }
}

public struct EffectiveIdentity: Sendable {
    public let folder: URL
    public let values: [IdentityValue]
}

public struct IdentityValue: Identifiable, Sendable {
    public let key: String
    public let value: String
    public let origin: String
    public let scope: String
    public var id: String { key }
}

/// A profile preview is valid only while its authorizing config is unchanged.
/// Persisting this guard also makes restoration fail closed after rule changes.
public struct GitAuthorization: Codable, Sendable {
    let home: URL
    let root: URL
    let state: FileState
    func validate(_ target: URL) throws {
        try Self.checkPath(target, home: home)
        guard try FileState.read(root) == state else {
            throw AppError.message("Include rules changed since this profile preview or backup. Refresh and preview again; use the backup for manual recovery.")
        }
    }
    static func checkPath(_ target: URL, home: URL) throws {
        let base = home.standardizedFileURL.resolvingSymlinksInPath()
        let normalized = target.standardizedFileURL
        let resolved = normalized.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(base.path + "/"), resolved != base else {
            throw AppError.message("Only included profile files inside your home folder can be edited.")
        }
        // Permit an OS-level alias in the home prefix (e.g. /var -> /private/var),
        // but refuse symlinks anywhere between that home and the target.
        let lexicalHome = home.standardizedFileURL.path
        guard normalized.path.hasPrefix(lexicalHome + "/") else {
            throw AppError.message("The profile path must be inside your home folder.")
        }
        var current = home.standardizedFileURL
        for component in normalized.path.dropFirst(lexicalHome.count + 1).split(separator: "/") {
            current.appendPathComponent(String(component))
            if (try? current.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                throw AppError.message("Profile paths containing symlinks cannot be edited.")
            }
        }
        _ = try FileState.read(normalized)
    }
}

/// Finds assignment spans, leaving all other bytes alone. Git remains the parser
/// of record: canonical keys/values come from `git config --null --list`.
struct IncludeSpans {
    struct Entry { let range: Range<String.Index>; let header: String }
    static func entries(_ text: String) throws -> [Entry] {
        var i = text.startIndex, header = "", includeSection = false
        var entries: [Entry] = []
        func advance() { i = text.index(after: i) }
        while i < text.endIndex {
            let c = text[i]
            if c.isWhitespace { advance(); continue }
            if c == "#" || c == ";" {
                while i < text.endIndex && !text[i].isNewline { advance() }
                continue
            }
            if c == "[" {
                let start = i
                var quoted = false
                advance()
                while i < text.endIndex {
                    if text[i] == "\\" { advance(); if i < text.endIndex { advance() }; continue }
                    if text[i] == "\"" { quoted.toggle() }
                    if text[i] == "]" && !quoted { advance(); break }
                    advance()
                }
                header = String(text[start..<i])
                includeSection = header.range(of: #"^\[include\s*\]$|^\[includeif(?:\.|\s+")"#, options: [.regularExpression, .caseInsensitive]) != nil
                continue
            }
            let start = i
            while i < text.endIndex && (text[i].isLetter || text[i].isNumber || text[i] == "-") { advance() }
            guard i != start else { throw AppError.message("Cannot safely locate config entries. Edit this file with your own editor.") }
            let name = text[start..<i].lowercased()
            var quoted = false
            while i < text.endIndex {
                if text[i] == "\\" { advance(); if i < text.endIndex { advance() }; continue }
                if text[i] == "\"" { quoted.toggle() }
                if !quoted && (text[i].isNewline || text[i] == "#" || text[i] == ";") { break }
                advance()
            }
            var end = i
            while end > start && (text[text.index(before: end)] == " " || text[text.index(before: end)] == "\t") { end = text.index(before: end) }
            if includeSection && name == "path" { entries.append(Entry(range: start..<end, header: header)) }
        }
        return entries
    }
}

extension GitService {
    private func directEntries(_ target: URL) async throws -> [(String, String)] {
        guard FileManager.default.fileExists(atPath: target.path) else { return [] }
        let result = try await runner.run(paths.git, ["config", "--file", target.path, "--no-includes", "--null", "--list"], environment: paths.environment).checked()
        guard result.output.utf8.count < 262_144 else { throw AppError.message("Config output is too large to inspect safely.") }
        return result.output.split(separator: "\0").map { item in
            let pair = item.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            return (String(pair[0]), pair.count > 1 ? String(pair[1]) : "")
        }
    }

    private func includeEntries(_ target: URL) async throws -> [(String?, String)] {
        try await directEntries(target).compactMap { key, value in
            if key == "include.path" { return (nil, value) }
            if key.hasPrefix("includeif."), key.hasSuffix(".path"), key != "includeif.path" { return (String(key.dropFirst(10).dropLast(5)), value) }
            return nil
        }
    }

    public func resolveInclude(_ path: String, relativeTo config: URL? = nil) throws -> URL {
        guard !path.isEmpty, path.count <= 4096, !path.contains(where: { $0.isNewline || $0 == "\0" }) else {
            throw AppError.message("Enter a nonempty, single-line profile path.")
        }
        if path.hasPrefix("~/") { return paths.home.appendingPathComponent(String(path.dropFirst(2))).standardizedFileURL }
        guard !path.hasPrefix("~") else { throw AppError.message("Use ~/ for your home folder; other users’ home paths are not supported.") }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
        return (config ?? paths.gitConfig).deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL
    }

    public static func validateCondition(_ condition: String?) throws {
        guard let condition else { return }
        guard condition.count <= 4096, !condition.contains(where: { $0.isNewline || $0 == "\0" || $0.isASCII && $0.asciiValue! < 32 }) else {
            throw AppError.message("Enter a single-line include condition.")
        }
        let prefixes = ["gitdir:", "gitdir/i:", "onbranch:", "hasconfig:remote.*.url:"]
        guard let prefix = prefixes.first(where: { condition.hasPrefix($0) }), !condition.dropFirst(prefix.count).isEmpty else {
            throw AppError.message("Use gitdir:, gitdir/i:, onbranch:, or hasconfig:remote.*.url: followed by a pattern.")
        }
    }

    public func includeRules() async throws -> [IncludeRule] {
        let source = try FileState.read(paths.gitConfig)
        var rules: [IncludeRule] = []
        for (index, entry) in try await includeEntries(paths.gitConfig).enumerated() {
            let (condition, path) = entry
            let target = try? resolveInclude(path)
            var issue: String?, overrides: [ConfigValue] = []
            if let target {
                do {
                    overrides = try await directEntries(target).compactMap { key, value in
                        guard GitField.all.contains(where: { $0.key.lowercased() == key }) || key.hasPrefix("alias.") else { return nil }
                        return ConfigValue(key: key, value: value, origin: "file:" + target.path)
                    }
                } catch { issue = "Unable to inspect overrides: " + error.localizedDescription }
                do { try GitAuthorization.checkPath(target, home: paths.home) }
                catch { issue = error.localizedDescription }
            } else { issue = "This profile path cannot be resolved." }
            rules.append(IncludeRule(id: index, condition: condition, path: path, target: target,
                exists: target.map { FileManager.default.fileExists(atPath: $0.path) } ?? false,
                overrides: overrides, editIssue: issue, source: source))
        }
        guard try FileState.read(paths.gitConfig) == source else { throw AppError.message("Git config changed during inspection. Refresh again.") }
        return rules
    }

    func authorization(for target: URL) async throws -> GitAuthorization {
        try GitAuthorization.checkPath(target, home: paths.home)
        let root = try FileState.read(paths.gitConfig)
        let referenced = try await includeEntries(paths.gitConfig).contains { entry in
            (try? resolveInclude(entry.1)) == target.standardizedFileURL
        }
        guard referenced else { throw AppError.message("Only profiles referenced directly from the main Git config may be edited.") }
        guard try FileState.read(paths.gitConfig) == root else { throw AppError.message("Include rules changed. Refresh and preview again.") }
        return GitAuthorization(home: paths.home, root: paths.gitConfig, state: root)
    }

    public func profileValues(_ target: URL) async throws -> [String: String] {
        let permission = try await authorization(for: target)
        var values: [String: String] = [:]
        for (key, value) in try await directEntries(target) {
            if let field = GitField.all.first(where: { $0.key.lowercased() == key }) { values[field.key] = value }
        }
        try permission.validate(target)
        return values
    }

    private func validateProfileTree(_ target: URL, forbidsRemotes: Bool, ancestors: Set<URL> = []) async throws {
        guard ancestors.count < 10, !ancestors.contains(target.resolvingSymlinksInPath()) else {
            throw AppError.message("The profile has recursive or excessively deep includes.")
        }
        let entries = try await directEntries(target)
        if forbidsRemotes && entries.contains(where: { $0.0.hasPrefix("remote.") && $0.0.hasSuffix(".url") }) {
            throw AppError.message("Profiles used by hasconfig:remote.*.url: rules cannot contain remote URLs, including in nested profiles.")
        }
        var visited = ancestors
        visited.insert(target.resolvingSymlinksInPath())
        for (key, path) in entries where key == "include.path" || (key.hasPrefix("includeif.") && key.hasSuffix(".path") && key != "includeif.path") {
            let nested = try resolveInclude(path, relativeTo: target)
            guard nested != paths.gitConfig.standardizedFileURL else { throw AppError.message("A profile cannot include the main config recursively.") }
            try await validateProfileTree(nested, forbidsRemotes: forbidsRemotes || key.hasPrefix("includeif.hasconfig:remote.*.url:"), ancestors: visited)
        }
    }

    private static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\t", with: "\\t") + "\""
    }
    private static func header(_ condition: String?) -> String {
        condition.map { "[includeIf \(quote($0))]" } ?? "[include]"
    }

    /// nil rule adds; nil draft removes. Changes keep the selected occurrence's position.
    public func previewRule(_ rule: IncludeRule? = nil, draft: IncludeDraft?) async throws -> ChangePreview {
        let target = paths.gitConfig
        let before = try FileState.read(target)
        if let rule, rule.source != before { throw AppError.message("Include rules changed since inspection. Refresh and preview again.") }
        if let draft {
            try Self.validateCondition(draft.condition)
            let profile = try resolveInclude(draft.path)
            try GitAuthorization.checkPath(profile, home: paths.home)
            guard profile != target.standardizedFileURL else { throw AppError.message("A config cannot include itself.") }
            try await validateProfileTree(profile, forbidsRemotes: draft.condition?.hasPrefix("hasconfig:remote.*.url:") == true)
        }
        guard let decoded = String(data: before.contents ?? Data(), encoding: .utf8) else {
            throw AppError.message("Rule editing requires UTF-8 config text so unrelated bytes can be preserved.")
        }
        var text = decoded
        if let rule {
            let spans = try IncludeSpans.entries(text)
            let entries = try await includeEntries(target)
            guard spans.count == entries.count, spans.indices.contains(rule.id) else { throw AppError.message("Cannot safely locate this include rule.") }
            let span = spans[rule.id]
            let replacement: String
            if let draft {
                let assignment = "path = " + Self.quote(draft.path)
                replacement = draft.condition == rule.condition ? assignment :
                    Self.header(draft.condition) + "\n\t" + assignment + "\n" + span.header + "\n"
            } else { replacement = "" }
            text.replaceSubrange(span.range, with: replacement)
        } else if let draft {
            text += (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + Self.header(draft.condition) + "\n\tpath = " + Self.quote(draft.path) + "\n"
        } else { throw AppError.message("Choose a rule to remove.") }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("git-settings-rule-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let staged = temporary.appendingPathComponent("config")
        try Data(text.utf8).write(to: staged)
        _ = try await directEntries(staged)
        return ChangePreview(target: target, before: before, after: FileState(contents: Data(text.utf8)), summary: draft == nil ? "Remove include rule (keep profile file)" : "Save include rule")
    }

    public func effectiveIdentity(in folder: URL) async throws -> EffectiveIdentity {
        var values: [IdentityValue] = []
        for key in ["user.name", "user.email", "user.signingKey", "commit.gpgSign", "gpg.format"] {
            let result = try await runner.run(paths.git, ["-C", folder.path, "config", "--includes", "--null", "--show-origin", "--show-scope", "--get", key], environment: paths.environment)
            if result.status != 0 && result.status != 1 { _ = try result.checked() }
            let parts = result.output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            if result.status == 0, parts.count >= 3 { values.append(IdentityValue(key: key, value: parts[2], origin: parts[1], scope: parts[0])) }
        }
        return EffectiveIdentity(folder: folder, values: values)
    }
}
