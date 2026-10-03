import Foundation

public struct GitField: Identifiable, Sendable {
    public let key: String
    public let title: String
    public let hint: String
    public var id: String { key }
    public static let all: [GitField] = [
        .init(key: "user.name", title: "Commit name", hint: "Your name on new commits"),
        .init(key: "user.email", title: "Commit email", hint: "Your email on new commits"),
        .init(key: "core.editor", title: "Editor", hint: "For example: code --wait or nano"),
        .init(key: "init.defaultBranch", title: "Default branch", hint: "For new repositories only"),
        .init(key: "commit.gpgSign", title: "Sign commits", hint: "true, false, or empty to inherit"),
        .init(key: "gpg.format", title: "Signing format", hint: "openpgp, ssh, x509, or empty"),
        .init(key: "user.signingKey", title: "Signing key", hint: "Key ID or public-key path; never paste a private key"),
        .init(key: "core.excludesFile", title: "Global ignore file", hint: "Absolute path or ~/path; file contents are left intact")
    ]
}

public struct ConfigValue: Identifiable, Sendable {
    public let key: String
    public let value: String
    public let origin: String
    public var id: String { key + origin + value }
}

public struct GitSnapshot: Sendable {
    public let version: String
    public let binary: String
    public let target: URL
    public let editable: [String: String]
    public let values: [ConfigValue]
    public let helper: [ConfigValue]
    public func value(_ key: String) -> String { values.last(where: { $0.key.lowercased() == key.lowercased() })?.value ?? "Not configured" }
}

public struct GitService: Sendable {
    public let paths: AppPaths
    public let runner = ProcessRunner()
    public init(paths: AppPaths) { self.paths = paths }

    public static func parseValues(_ text: String, key: String) -> [ConfigValue] {
        let parts = text.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var values: [ConfigValue] = []
        var i = 0
        while i + 1 < parts.count {
            values.append(ConfigValue(key: key, value: parts[i + 1], origin: parts[i]))
            i += 2
        }
        return values
    }

    public func snapshot() async throws -> GitSnapshot {
        let version = try await runner.run(paths.git, ["--version"], environment: paths.environment).checked().output.trimmingCharacters(in: .whitespacesAndNewlines)
        var values: [ConfigValue] = [], editable: [String: String] = [:]
        for field in GitField.all {
            let result = try await runner.run(paths.git, ["config", "--global", "--includes", "--null", "--show-origin", "--get-all", field.key], environment: paths.environment)
            if result.status != 0 && result.status != 1 { _ = try result.checked() }
            values += Self.parseValues(result.output, key: field.key)
            if FileManager.default.fileExists(atPath: paths.gitConfig.path) {
                let direct = try await runner.run(paths.git, ["config", "--file", paths.gitConfig.path, "--no-includes", "--null", "--get-all", field.key], environment: paths.environment)
                if direct.status != 0 && direct.status != 1 { _ = try direct.checked() }
                editable[field.key] = direct.output.split(separator: "\0", omittingEmptySubsequences: false).dropLast().last.map(String.init) ?? ""
            }
        }
        let helper = try await runner.run(paths.git, ["config", "--global", "--includes", "--null", "--show-origin", "--get-all", "credential.helper"], environment: paths.environment)
        if helper.status != 0 && helper.status != 1 { _ = try helper.checked() }
        return GitSnapshot(version: version, binary: paths.git, target: paths.gitConfig, editable: editable, values: values, helper: Self.parseValues(helper.output, key: "credential.helper"))
    }

    public static func validate(key: String, value: String) throws {
        let known = GitField.all.contains { $0.key == key }
        let alias = key.hasPrefix("alias.") && key.dropFirst(6).range(of: "^[A-Za-z][A-Za-z0-9-]*$", options: .regularExpression) != nil
        guard known || alias else { throw AppError.message("This config key is not supported.") }
        guard value.count <= 4096, !value.contains(where: { $0.isNewline || $0 == "\0" }), !value.contains("PRIVATE KEY") else { throw AppError.message("Enter a single-line value without private-key material.") }
        if key == "commit.gpgSign", !["", "true", "false"].contains(value) { throw AppError.message("Sign commits must be true, false, or empty.") }
        if key == "gpg.format", !["", "openpgp", "ssh", "x509"].contains(value) { throw AppError.message("Choose openpgp, ssh, x509, or leave it empty.") }
        if key == "user.email", !value.isEmpty, (!value.contains("@") || value.contains(" ")) { throw AppError.message("Enter an email address, or leave it empty to remove the value.") }
        if key == "core.excludesFile", !value.isEmpty, !value.hasPrefix("/") && !value.hasPrefix("~/") { throw AppError.message("Use an absolute path or a path beginning with ~/ for the ignore file.") }
    }

    public func preview(changes: [String: String]) async throws -> ChangePreview {
        let target = paths.gitConfig
        let before = try FileState.read(target)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("git-settings-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let staged = temporary.appendingPathComponent("config")
        try (before.contents ?? Data()).write(to: staged)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
        for (key, value) in changes.sorted(by: { $0.key < $1.key }) {
            try Self.validate(key: key, value: value)
            if key == "init.defaultBranch", !value.isEmpty {
                _ = try await runner.run(paths.git, ["check-ref-format", "--branch", value], environment: paths.environment).checked()
            }
            let args = value.isEmpty ? ["config", "--file", staged.path, "--unset-all", key] : ["config", "--file", staged.path, "--replace-all", key, value]
            let result = try await runner.run(paths.git, args, environment: paths.environment)
            if !(value.isEmpty && result.status == 5) { _ = try result.checked() }
        }
        _ = try await runner.run(paths.git, ["config", "--file", staged.path, "--no-includes", "--list"], environment: paths.environment).checked()
        let after = try FileState.read(staged)
        return ChangePreview(target: target, before: before, after: after, summary: "Git settings: " + changes.keys.sorted().joined(separator: ", "))
    }
}
