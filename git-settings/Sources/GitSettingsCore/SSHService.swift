import Foundation

public struct PublicKey: Identifiable, Sendable {
    public let url: URL
    public let text: String
    public let fingerprint: String
    public let hasPrivateFile: Bool
    public let loaded: Bool
    public var id: String { url.path }
    public var name: String { url.deletingPathExtension().lastPathComponent }
}

public struct AgentSnapshot: Sendable {
    public let socket: String?
    public let description: String
    public let fingerprints: Set<String>
    public let available: Bool
}

public struct SSHHost: Identifiable, Sendable {
    public let patterns: String
    public let line: Int
    public var id: String { "\(line):\(patterns)" }
}

public struct SSHConfigSnapshot: Sendable {
    public let text: String
    public let hosts: [SSHHost]
    public let hasIncludes: Bool
    public let hasMatch: Bool
    public static func parse(_ text: String) -> SSHConfigSnapshot {
        var hosts: [SSHHost] = [], includes = false, match = false
        for (offset, line) in text.components(separatedBy: .newlines).enumerated() {
            let parts = line.trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0.isWhitespace || $0 == "=" })
            guard let first = parts.first else { continue }
            switch first.lowercased() {
            case "host": hosts.append(SSHHost(patterns: parts.dropFirst().joined(separator: " "), line: offset + 1))
            case "include": includes = true
            case "match": match = true
            default: break
            }
        }
        return SSHConfigSnapshot(text: text, hosts: hosts, hasIncludes: includes, hasMatch: match)
    }
}

public struct HostDraft: Sendable {
    public var alias: String
    public var hostname: String
    public var user: String
    public var port: String
    public var identity: String
    public init(alias: String, hostname: String, user: String, port: String = "22", identity: String = "") {
        self.alias = alias; self.hostname = hostname; self.user = user; self.port = port; self.identity = identity
    }
    public func block() throws -> String {
        func valid(_ value: String, pattern: String) -> Bool { value.range(of: pattern, options: .regularExpression) != nil }
        guard valid(alias, pattern: "^[A-Za-z0-9][A-Za-z0-9._-]*$"), !alias.hasPrefix("-") else { throw AppError.message("Use a literal host alias with letters, numbers, dots, dashes or underscores.") }
        guard valid(hostname, pattern: "^[A-Za-z0-9][A-Za-z0-9.:-]*$"), !hostname.contains("..") else { throw AppError.message("Enter a hostname or IP address without whitespace.") }
        guard valid(user, pattern: "^[A-Za-z_][A-Za-z0-9._-]*$") else { throw AppError.message("Enter a valid SSH username.") }
        guard let number = Int(port), (1...65535).contains(number) else { throw AppError.message("Port must be between 1 and 65535.") }
        guard identity.isEmpty || ((identity.hasPrefix("/") || identity.hasPrefix("~/")) && !identity.contains(where: { $0.isNewline || $0 == "\0" || $0 == "\"" || $0 == "\\" || $0 == "%" || $0 == "$" })) else { throw AppError.message("Identity path must be absolute or start with ~/, without quotes or expansions.") }
        var block = "# Added by Git & SSH\nHost \(alias)\n    HostName \(hostname)\n    User \(user)\n    Port \(number)\n"
        if !identity.isEmpty { block += "    IdentityFile \"\(identity)\"\n    IdentitiesOnly yes\n" }
        return block + "\n"
    }
}

public struct SSHService: Sendable {
    public let paths: AppPaths
    public let runner = ProcessRunner()
    public init(paths: AppPaths) { self.paths = paths }

    public func agent() async throws -> AgentSnapshot {
        let socket = paths.environment["SSH_AUTH_SOCK"]
        let result = try await runner.run("/usr/bin/ssh-add", ["-l", "-E", "sha256"], environment: paths.environment, timeout: 5)
        let fingerprints = Set(result.output.components(separatedBy: .newlines).compactMap { line in line.split(separator: " ").first(where: { $0.hasPrefix("SHA256:") }).map(String.init) })
        return AgentSnapshot(socket: socket, description: result.status == 0 ? "\(fingerprints.count) loaded key(s)" : (result.status == 1 ? "Agent reachable · no identities" : "Agent unavailable"), fingerprints: fingerprints, available: result.status == 0 || result.status == 1)
    }

    public func keys(agent: AgentSnapshot) async throws -> [PublicKey] {
        guard FileManager.default.fileExists(atPath: paths.ssh.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: paths.ssh, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]).filter { $0.pathExtension == "pub" }.sorted { $0.path < $1.path }
        var keys: [PublicKey] = []
        for file in files {
            guard let state = try? FileState.read(file) else { continue }
            let text = state.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let tokens = text.split(whereSeparator: { $0.isWhitespace })
            guard tokens.count >= 2, (tokens[0].hasPrefix("ssh-") || tokens[0].hasPrefix("ecdsa-") || tokens[0].hasPrefix("sk-")), Data(base64Encoded: String(tokens[1])) != nil else { continue }
            let result = try await runner.run("/usr/bin/ssh-keygen", ["-l", "-E", "sha256", "-f", file.path], environment: paths.environment)
            guard result.status == 0, let fingerprint = result.output.split(whereSeparator: { $0.isWhitespace }).first(where: { $0.hasPrefix("SHA256:") }) else { continue }
            keys.append(PublicKey(url: file, text: text, fingerprint: String(fingerprint), hasPrivateFile: FileManager.default.fileExists(atPath: file.deletingPathExtension().path), loaded: agent.fingerprints.contains(String(fingerprint))))
        }
        return keys
    }

    public func config() throws -> SSHConfigSnapshot {
        // SSH config is displayed verbatim; private key files are never opened.
        if !FileManager.default.fileExists(atPath: paths.sshConfig.path) { return .parse("") }
        return .parse(try FileState.read(paths.sshConfig).text)
    }

    public func previewHost(_ draft: HostDraft) throws -> ChangePreview {
        let before = try FileState.read(paths.sshConfig)
        guard before.contents == nil || String(data: before.contents!, encoding: .utf8) != nil else { throw AppError.message("SSH config is not UTF-8. Use your editor to preserve its encoding.") }
        let block = try draft.block()
        let config = SSHConfigSnapshot.parse(before.text)
        guard !config.hosts.contains(where: { $0.patterns.split(separator: " ").contains(Substring(draft.alias)) }) else { throw AppError.message("That alias already exists. Open the config in your editor to change existing blocks safely.") }
        // Keep global directives global: insert after the preamble, before the first scope.
        // Any earlier global/Include value still wins, following OpenSSH semantics.
        var insertion = before.text.endIndex
        var cursor = before.text.startIndex
        while cursor < before.text.endIndex {
            let end = before.text[cursor...].firstIndex(of: "\n") ?? before.text.endIndex
            let line = before.text[cursor..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            let directive = line.split(whereSeparator: { $0.isWhitespace || $0 == "=" }).first?.lowercased()
            if directive == "host" || directive == "match" { insertion = cursor; break }
            cursor = end == before.text.endIndex ? end : before.text.index(after: end)
        }
        let prefix = String(before.text[..<insertion])
        let separator = prefix.isEmpty || prefix.hasSuffix("\n") ? "" : "\n"
        let after = FileState(contents: Data((prefix + separator + block + before.text[insertion...]).utf8))
        return ChangePreview(target: paths.sshConfig, before: before, after: after, summary: "Add SSH host \(draft.alias)")
    }

    private func askpassEnvironment(_ executable: String) -> [String: String] {
        var env = paths.environment
        env["SSH_ASKPASS"] = executable
        env["SSH_ASKPASS_REQUIRE"] = "force"
        env["GIT_SETTINGS_ASKPASS"] = "1"
        return env
    }

    public static func validateKeyName(_ name: String) throws {
        guard name.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$", options: .regularExpression) != nil else { throw AppError.message("Use 1–64 letters, numbers, dashes or underscores for the key name.") }
    }

    public func generate(name: String, comment: String, askpass: String) async throws {
        try Self.validateKeyName(name)
        guard comment.count < 256, !comment.contains(where: { $0.isNewline || $0 == "\0" }) else { throw AppError.message("Enter a short single-line comment.") }
        let fm = FileManager.default
        try fm.createDirectory(at: paths.ssh, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let target = paths.ssh.appendingPathComponent(name)
        guard !fm.fileExists(atPath: target.path), !fm.fileExists(atPath: target.path + ".pub") else { throw AppError.message("A file with that name already exists. Choose another name.") }
        // Generate in an isolated 0700 directory; publish with exclusive hard links, never overwrite.
        let stage = paths.ssh.appendingPathComponent(".git-settings-\(UUID().uuidString)")
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stage) }
        let key = stage.appendingPathComponent(name)
        _ = try await runner.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-a", "64", "-C", comment, "-f", key.path], environment: askpassEnvironment(askpass), timeout: 180).checked()
        try fm.linkItem(at: key, to: target)
        do { try fm.linkItem(at: URL(fileURLWithPath: key.path + ".pub"), to: URL(fileURLWithPath: target.path + ".pub")) }
        catch { try? fm.removeItem(at: target); throw error }
    }

    public func load(_ key: PublicKey, askpass: String) async throws {
        guard key.hasPrivateFile, key.url.deletingLastPathComponent() == paths.ssh else { throw AppError.message("The matching private key is unavailable.") }
        _ = try await runner.run("/usr/bin/ssh-add", [key.url.deletingPathExtension().path], environment: askpassEnvironment(askpass), timeout: 180).checked()
    }
    public func unload(_ key: PublicKey) async throws {
        // -d accepts public keys, so unloading never needs a private key or passphrase.
        _ = try await runner.run("/usr/bin/ssh-add", ["-d", key.url.path], environment: paths.environment).checked()
    }

    public static func validateDestination(_ destination: String) throws {
        guard destination.range(of: "^([A-Za-z_][A-Za-z0-9._-]*@)?[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil else { throw AppError.message("Enter a host alias, hostname, or user@hostname. URLs and command options are not supported.") }
    }

    public func diagnose(_ destination: String) async throws -> CommandResult {
        try Self.validateDestination(destination)
        let config = FileManager.default.fileExists(atPath: paths.sshConfig.path) ? paths.sshConfig.path : "/dev/null"
        return try await runner.run("/usr/bin/ssh", ["-F", config, "-T", "-o", "UserKnownHostsFile=" + paths.ssh.appendingPathComponent("known_hosts").path, "-o", "GlobalKnownHostsFile=/dev/null", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "ConnectionAttempts=1", "-o", "StrictHostKeyChecking=yes", "-o", "UpdateHostKeys=no", "-o", "ClearAllForwardings=yes", "-o", "PermitLocalCommand=no", "-o", "RemoteCommand=none", destination], environment: paths.environment, timeout: 15)
    }
}
