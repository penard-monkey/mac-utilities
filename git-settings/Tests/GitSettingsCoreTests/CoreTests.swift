import XCTest
@testable import GitSettingsCore

final class CoreTests: XCTestCase {
    var home: URL!
    var paths: AppPaths!
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("git-settings-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        paths = AppPaths(home: home, environment: ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": home.appendingPathComponent(".gitconfig").path, "XDG_CONFIG_HOME": home.appendingPathComponent(".config").path], git: "/usr/bin/git")
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: home) }
    func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    var store: TransactionStore { TransactionStore(directory: paths.state.appendingPathComponent("backups")) }

    func testGitPreviewPreservesIncludesAndUnrelatedValues() async throws {
        let included = home.appendingPathComponent("included.gitconfig")
        try write("[user]\n email = included@example.com\n", included)
        let initial = "# keep me\n[include]\n path = \(included.path)\n[user]\n name = Original\n[http]\n extraHeader = secret-fixture\n"
        try write(initial, paths.gitConfig)
        let service = GitService(paths: paths)
        let snapshot = try await service.snapshot()
        XCTAssertEqual(snapshot.value("user.email"), "included@example.com")
        XCTAssertEqual(snapshot.editable["user.email"], "")
        XCTAssertTrue(snapshot.values.contains { $0.origin.contains("included.gitconfig") })
        XCTAssertFalse(snapshot.values.contains { $0.value.contains("secret-fixture") })
        let preview = try await service.preview(changes: ["user.name": "New Name", "commit.gpgSign": "true"])
        XCTAssertEqual(try String(contentsOf: paths.gitConfig), initial)
        XCTAssertTrue(preview.after.text.contains("extraHeader = secret-fixture"))
        XCTAssertTrue(preview.after.text.contains("path = \(included.path)"))
        XCTAssertFalse(preview.diff.contains("secret-fixture"))
        let record = try store.apply(preview)
        let applied = try await service.snapshot()
        XCTAssertEqual(applied.value("user.name"), "New Name")
        try store.restore(record)
        XCTAssertEqual(try String(contentsOf: paths.gitConfig), initial)
        XCTAssertEqual(try String(contentsOf: included), "[user]\n email = included@example.com\n")
    }

    func testStalePreviewAndRestoreRefuseToOverwrite() async throws {
        try write("[user]\n name = Before\n", paths.gitConfig)
        let service = GitService(paths: paths)
        let preview = try await service.preview(changes: ["user.name": "After"])
        try write(preview.before.text + "# intervening edit\n", paths.gitConfig)
        XCTAssertThrowsError(try store.apply(preview))
        XCTAssertTrue(try String(contentsOf: paths.gitConfig).contains("intervening edit"))
        let current = try await service.preview(changes: ["user.name": "After"])
        let record = try store.apply(current)
        try write(current.after.text + "# unrelated later edit\n", paths.gitConfig)
        XCTAssertThrowsError(try store.restore(record))
        XCTAssertTrue(try String(contentsOf: paths.gitConfig).contains("unrelated later edit"))
    }

    func testNewConfigRestoreRemovesOnlyCreatedFile() async throws {
        let preview = try await GitService(paths: paths).preview(changes: ["user.name": "Fixture"])
        let record = try store.apply(preview)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.gitConfig.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: store.directory.appendingPathComponent(record.id + ".json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try store.records().count, 1)
        try store.restore(record)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.gitConfig.path))
    }

    func testLockAndSymlinkAreRefused() async throws {
        let preview = try await GitService(paths: paths).preview(changes: ["user.name": "Fixture"])
        try write("", URL(fileURLWithPath: paths.gitConfig.path + ".lock"))
        XCTAssertThrowsError(try store.apply(preview))
        let other = home.appendingPathComponent("other")
        try write("[user]\nname = Linked\n", other)
        try FileManager.default.createSymbolicLink(at: paths.gitConfig, withDestinationURL: other)
        do { _ = try await GitService(paths: paths).preview(changes: ["user.name": "Changed"]); XCTFail("Symlink must be refused") } catch {}
        XCTAssertEqual(try String(contentsOf: other), "[user]\nname = Linked\n")
    }

    func testValidationRejectsInjectionAndUnknownKeys() throws {
        XCTAssertThrowsError(try GitService.validate(key: "http.extraHeader", value: "token"))
        XCTAssertThrowsError(try GitService.validate(key: "user.name", value: "Name\n[alias]"))
        XCTAssertThrowsError(try GitService.validate(key: "user.signingKey", value: "-----BEGIN PRIVATE KEY-----"))
        XCTAssertThrowsError(try GitService.validate(key: "commit.gpgSign", value: "maybe"))
        XCTAssertThrowsError(try GitService.validate(key: "gpg.format", value: "invalid"))
        XCTAssertThrowsError(try GitService.validate(key: "alias.a.b", value: "status"))
        XCTAssertNoThrow(try GitService.validate(key: "alias.st", value: "status --short"))
        XCTAssertThrowsError(try SSHService.validateKeyName("../existing"))
        XCTAssertThrowsError(try SSHService.validateDestination("-oProxyCommand=anything"))
        XCTAssertThrowsError(try SSHService.validateDestination("user@host;command"))
        XCTAssertNoThrow(try SSHService.validateDestination("git@github.com"))
        XCTAssertThrowsError(try HostDraft(alias: "new\nHost *", hostname: "github.com", user: "git").block())
        XCTAssertThrowsError(try HostDraft(alias: "new", hostname: "github.com", user: "git", identity: "~/foo\"\nProxyCommand x").block())
    }

    func testShellMetacharactersRemainLiteralArguments() async throws {
        let value = "Literal $(touch /tmp/git-settings-should-not-exist) `echo injected`"
        let service = GitService(paths: paths)
        let preview = try await service.preview(changes: ["user.name": value])
        _ = try store.apply(preview)
        let applied = try await service.snapshot()
        XCTAssertEqual(applied.value("user.name"), value)
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/git-settings-should-not-exist"))
    }

    func testUnsetDirectSettingRetainsIncludedValue() async throws {
        let include = home.appendingPathComponent("include")
        try write("[user]\n name = Included\n", include)
        try write("[include]\n path = \(include.path)\n[user]\n name = Direct\n", paths.gitConfig)
        let service = GitService(paths: paths)
        let preview = try await service.preview(changes: ["user.name": ""])
        _ = try store.apply(preview)
        let applied = try await service.snapshot()
        XCTAssertEqual(applied.value("user.name"), "Included")
    }

    func testHostInsertionPreservesGlobalPreambleWildcardsMatchAndIncludes() throws {
        let prefix = "# global\nServerAliveInterval 30\nIdentityAgent /tmp/fixture-agent\nInclude extra.conf\n\n"
        let suffix = "Host *\n    ForwardAgent no\nMatch host internal\n    User staff\n"
        let original = prefix + suffix
        try write(original, paths.sshConfig)
        let service = SSHService(paths: paths)
        let draft = HostDraft(alias: "work", hostname: "github.com", user: "git", identity: "~/.ssh/id_work")
        let preview = try service.previewHost(draft)
        XCTAssertEqual(preview.after.text, prefix + (try draft.block()) + suffix)
        XCTAssertEqual(try String(contentsOf: paths.sshConfig), original)
        _ = try store.apply(preview)
        let parsed = try service.config()
        XCTAssertTrue(parsed.hasIncludes)
        XCTAssertTrue(parsed.hasMatch)
        XCTAssertEqual(parsed.hosts.map(\.patterns), ["work", "*"])
        XCTAssertThrowsError(try service.previewHost(draft))
    }

    func testOnlyGlobalSSHConfigAppendsWithNewline() throws {
        try write("ServerAliveInterval 30", paths.sshConfig)
        let draft = HostDraft(alias: "host", hostname: "example.com", user: "git")
        let preview = try SSHService(paths: paths).previewHost(draft)
        XCTAssertEqual(preview.after.text, "ServerAliveInterval 30\n" + (try draft.block()))
    }

    func testPublicInventoryAndExclusiveKeyGeneration() async throws {
        let helper = home.appendingPathComponent("fixture-askpass")
        try write("#!/bin/sh\nprintf '\\n'\n", helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let service = SSHService(paths: paths)
        try await service.generate(name: "fixture_ed25519", comment: "fixture@example.com", askpass: helper.path)
        let publicFile = paths.ssh.appendingPathComponent("fixture_ed25519.pub")
        let text = try String(contentsOf: publicFile)
        XCTAssertTrue(text.hasPrefix("ssh-ed25519 "))
        let privateAttributes = try FileManager.default.attributesOfItem(atPath: paths.ssh.appendingPathComponent("fixture_ed25519").path)
        XCTAssertEqual((privateAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try FileManager.default.createSymbolicLink(at: paths.ssh.appendingPathComponent("symlink.pub"), withDestinationURL: publicFile)
        try write("not a public key", paths.ssh.appendingPathComponent("invalid.pub"))
        let noAgent = AgentSnapshot(socket: nil, description: "Fixture", fingerprints: [], available: false)
        let keys = try await service.keys(agent: noAgent)
        XCTAssertEqual(keys.count, 1)
        XCTAssertTrue(keys[0].hasPrivateFile)
        XCTAssertTrue(keys[0].fingerprint.hasPrefix("SHA256:"))
        do { try await service.generate(name: "fixture_ed25519", comment: "other", askpass: helper.path); XCTFail("Must not overwrite") } catch {}
        XCTAssertEqual(try String(contentsOf: publicFile), text)
        let agent = try await service.agent()
        XCTAssertFalse(agent.available)
    }

    func testRunnerTimeoutAndBoundedOutput() async throws {
        let runner = ProcessRunner()
        let timeout = try await runner.run("/bin/sleep", ["2"], environment: paths.environment, timeout: 0.1)
        XCTAssertTrue(timeout.timedOut)
        XCTAssertThrowsError(try timeout.checked())
        let source = home.appendingPathComponent("large-output")
        try Data(repeating: 65, count: 400_000).write(to: source)
        let output = try await runner.run("/bin/cat", [source.path], environment: paths.environment).checked()
        XCTAssertEqual(output.output.count, 262_144)
    }

    func testOriginParsingHandlesMultilineValues() {
        let values = GitService.parseValues("file:/tmp/a\0line1\nline2\0file:/tmp/b\0value\0", key: "user.name")
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(values[0].value, "line1\nline2")
        XCTAssertEqual(values[1].origin, "file:/tmp/b")
    }
}
