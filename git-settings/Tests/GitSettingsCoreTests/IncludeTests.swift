import XCTest
@testable import GitSettingsCore

final class IncludeTests: XCTestCase {
    var home: URL!
    var paths: AppPaths!
    var service: GitService { GitService(paths: paths) }
    var store: TransactionStore { TransactionStore(directory: paths.state.appendingPathComponent("backups")) }
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("git-includes-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        paths = AppPaths(home: home, environment: ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": home.appendingPathComponent(".gitconfig").path, "XDG_CONFIG_HOME": home.appendingPathComponent(".config").path], git: "/usr/bin/git")
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: home) }
    func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    func rules() async throws -> [IncludeRule] { try await service.includeRules() }
    func assertRefused(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Operation must be refused", file: file, line: line) } catch {}
    }

    func testInventoryIncludesEveryConditionDuplicateRelativeAndMissingPath() async throws {
        let profile = home.appendingPathComponent("public profile")
        try write("[user]\n email = public@example.com\n signingKey = fixture-key\n[http]\n extraHeader = hidden-fixture\n", profile)
        try write("[include]\n path = \"public profile\"\n path = ~/missing\n[includeIf \"gitdir:~/repos/\"]\n path = \"~/public profile\"\n[includeIf \"gitdir/i:~/REPOS/\"]\n path = \"public profile\"\n[includeIf \"onbranch:public/**\"]\n path = \"public profile\"\n[includeIf \"hasconfig:remote.*.url:https://example.com/**\"]\n path = \"public profile\"\n", paths.gitConfig)
        let inventory = try await rules()
        XCTAssertEqual(inventory.count, 6)
        XCTAssertEqual(inventory[0].target, profile)
        XCTAssertNil(inventory[0].condition)
        XCTAssertFalse(inventory[1].exists)
        XCTAssertNil(inventory[1].editIssue)
        XCTAssertEqual(inventory[2].condition, "gitdir:~/repos/")
        XCTAssertEqual(inventory[3].condition, "gitdir/i:~/REPOS/")
        XCTAssertEqual(inventory[4].condition, "onbranch:public/**")
        XCTAssertEqual(inventory[5].condition, "hasconfig:remote.*.url:https://example.com/**")
        XCTAssertEqual(inventory[0].overrides.map(\.key), ["user.email", "user.signingkey"])
        XCTAssertFalse(inventory[0].overrides.contains { $0.value == "hidden-fixture" })
    }

    func testProfileEditingPreservesUnrelatedContentAndRestores() async throws {
        let profile = home.appendingPathComponent("public")
        let original = "# profile\n[user]\n email = old@example.com\n[http]\n sslVerify = true\n"
        try write(original, profile)
        let root = "[includeIf \"gitdir:~/repos/\"]\n path = ~/public\n"
        try write(root, paths.gitConfig)
        let values = try await service.profileValues(profile)
        XCTAssertEqual(values["user.email"], "old@example.com")
        let preview = try await service.preview(changes: ["user.email": "new@example.com", "user.signingKey": "fixture-key"], target: profile)
        XCTAssertEqual(try String(contentsOf: profile), original)
        let record = try store.apply(preview)
        XCTAssertTrue(try String(contentsOf: profile).contains("sslVerify = true"))
        XCTAssertEqual(try String(contentsOf: paths.gitConfig), root)
        let decoded = try XCTUnwrap(store.records().first)
        XCTAssertNotNil(decoded.authorization)
        try store.restore(record)
        XCTAssertEqual(try String(contentsOf: profile), original)
    }

    func testCreateNewProfileAndSecondRuleThenRemoveKeepsFile() async throws {
        let profile = home.appendingPathComponent("profiles/public")
        _ = try store.apply(try await service.previewRule(draft: .init(condition: "gitdir:~/one/", path: "~/profiles/public")))
        let created = try store.apply(try await service.preview(changes: ["user.email": "public@example.com"], target: profile))
        _ = try store.apply(try await service.previewRule(draft: .init(condition: "gitdir:~/two/", path: "~/profiles/public")))
        let inventory = try await rules()
        XCTAssertEqual(inventory.count, 2)
        let remove = try await service.previewRule(inventory[0], draft: nil)
        _ = try store.apply(remove)
        let remaining = try await rules()
        XCTAssertEqual(remaining.map(\.condition), ["gitdir:~/two/"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: profile.path))
        XCTAssertThrowsError(try store.restore(created), "A changed authorization requires manual recovery")
    }

    func testRuleEditsPreserveDuplicatesCommentsOrderAndOtherSectionKeys() async throws {
        let initial = "# leading\n[Include] path = ~/first # first comment\n\tpath = \"~/sec\\\nond\" ; second comment\n other = preserve\n[user]\n email = fixture@example.com\n# trailing\n"
        try write(initial, paths.gitConfig)
        let inventory = try await rules()
        XCTAssertEqual(inventory.map(\.path), ["~/first", "~/second"])
        let preview = try await service.previewRule(inventory[1], draft: .init(condition: "onbranch:topic/**", path: "~/new # profile"))
        XCTAssertTrue(preview.after.text.hasPrefix("# leading\n[Include] path = ~/first # first comment\n"))
        XCTAssertTrue(preview.after.text.hasSuffix(" other = preserve\n[user]\n email = fixture@example.com\n# trailing\n"))
        XCTAssertTrue(preview.after.text.contains("; second comment"))
        let record = try store.apply(preview)
        let edited = try await rules()
        XCTAssertEqual(edited.map(\.path), ["~/first", "~/new # profile"])
        XCTAssertEqual(edited.map(\.condition), [nil, "onbranch:topic/**"])
        let command = try await service.runner.run(paths.git, ["config", "--file", paths.gitConfig.path, "--no-includes", "--get", "include.other"], environment: paths.environment).checked()
        XCTAssertEqual(command.output, "preserve\n")
        try store.restore(record)
        XCTAssertEqual(try String(contentsOf: paths.gitConfig), initial)
        let removal = try await service.previewRule(inventory[0], draft: nil)
        XCTAssertTrue(removal.after.text.contains("# first comment"))
        _ = try store.apply(removal)
        let remaining = try await rules()
        XCTAssertEqual(remaining.map(\.path), ["~/second"])
    }

    func testRuleEditingPreservesUnrelatedIncludeSubsectionsAndCRLF() async throws {
        let initial = "[include \"unrelated\"]\r\n path = keep\r\n[includeif]\r\n path = untouched\r\n[include]\r\n path = ~/first # comment\r\n"
        try write(initial, paths.gitConfig)
        let inventory = try await rules()
        XCTAssertEqual(inventory.count, 1)
        let preview = try await service.previewRule(inventory[0], draft: .init(path: "~/second"))
        XCTAssertEqual(preview.after.text, initial.replacingOccurrences(of: "~/first", with: "\"~/second\""))
        // Refuse byte-altering rule edits if unrelated content isn't UTF-8.
        try Data([0x23, 0xff, 0x0a] + Array("[include]\n path = ~/first\n".utf8)).write(to: paths.gitConfig)
        await assertRefused { _ = try await self.service.previewRule(draft: .init(path: "~/second")) }
    }

    func testRulePathOnlyChangeEscapesQuotesAndBackslashes() async throws {
        try write("[includeIf \"onbranch:topic/**\"]\n path = ~/first\n path = ~/second\n", paths.gitConfig)
        let rule = try await rules()[0]
        let literal = "~/quote\"and\\backslash"
        let preview = try await service.previewRule(rule, draft: .init(condition: rule.condition, path: literal))
        _ = try store.apply(preview)
        let edited = try await rules()
        XCTAssertEqual(edited.map(\.path), [literal, "~/second"])
        XCTAssertEqual(edited.map(\.condition), [rule.condition, rule.condition])
    }

    func testUnauthorizedOutsideTraversalNestedAndSymlinkProfilesAreRefused() async throws {
        let outside = home.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString)")
        try write("[user]\n email = outside@example.com\n", outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let nested = home.appendingPathComponent("nested")
        let linked = home.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)
        let inner = home.appendingPathComponent("inner")
        try write("[include]\n path = ~/nested\n", inner)
        try write("[include]\n path = ~/inner\n path = \(outside.path)\n path = ~/linked\n", paths.gitConfig)
        for target in [nested, outside, linked, home.appendingPathComponent("unreferenced")] {
            await assertRefused { _ = try await self.service.preview(changes: ["user.email": "new@example.com"], target: target) }
        }
        for path in [outside.path, "../\(outside.lastPathComponent)", "~/../\(outside.lastPathComponent)", "~/linked", "~someone/profile", "~/.gitconfig"] {
            await assertRefused { _ = try await self.service.previewRule(draft: .init(path: path)) }
        }
        let dir = home.appendingPathComponent("linked-dir")
        try FileManager.default.createSymbolicLink(at: dir, withDestinationURL: home)
        await assertRefused { _ = try await self.service.previewRule(draft: .init(path: "~/linked-dir/inside")) }
        XCTAssertEqual(try String(contentsOf: outside), "[user]\n email = outside@example.com\n")
    }

    func testProfileLocksStaleBytesRuleChangesAndSymlinkSwapRefused() async throws {
        let profile = home.appendingPathComponent("profile")
        try write("[include]\n path = ~/profile\n", paths.gitConfig)
        let preview = try await service.preview(changes: ["user.email": "public@example.com"], target: profile)
        let lock = URL(fileURLWithPath: profile.path + ".lock")
        let rootLock = URL(fileURLWithPath: paths.gitConfig.path + ".lock")
        try write("", rootLock)
        XCTAssertThrowsError(try store.apply(preview))
        try FileManager.default.removeItem(at: rootLock)
        try write("", lock)
        XCTAssertThrowsError(try store.apply(preview))
        try FileManager.default.removeItem(at: lock)
        try write("# later edit\n", profile)
        XCTAssertThrowsError(try store.apply(preview))
        let current = try await service.preview(changes: ["user.email": "public@example.com"], target: profile)
        let rule = try await rules()[0]
        _ = try store.apply(try await service.previewRule(rule, draft: nil))
        XCTAssertThrowsError(try store.apply(current))
        try write("[include]\n path = ~/profile\n", paths.gitConfig)
        let swap = try await service.preview(changes: ["user.email": "public@example.com"], target: profile)
        try FileManager.default.removeItem(at: profile)
        try FileManager.default.createSymbolicLink(at: profile, withDestinationURL: paths.gitConfig)
        XCTAssertThrowsError(try store.apply(swap))
    }

    func testStaleRuleSelectionPreviewAndRestoreRefused() async throws {
        try write("[include]\n path = ~/first\n", paths.gitConfig)
        let rule = try await rules()[0]
        let preview = try await service.previewRule(rule, draft: .init(path: "~/second"))
        try write(preview.before.text + "# later\n", paths.gitConfig)
        await assertRefused { _ = try await self.service.previewRule(rule, draft: nil) }
        XCTAssertThrowsError(try store.apply(preview))
        let fresh = try await rules()[0]
        let record = try store.apply(try await service.previewRule(fresh, draft: .init(path: "~/second")))
        try write(record.after.text + "# later\n", paths.gitConfig)
        XCTAssertThrowsError(try store.restore(record))
    }

    func testRejectInvalidConditionsAndPaths() async throws {
        for condition in ["", "gitdir:", "onbranch:", "hasconfig:remote.*.url:", "unknown:pattern", "gitdir:foo\nbar", "gitdir:foo\0bar"] {
            XCTAssertThrowsError(try GitService.validateCondition(condition))
        }
        for condition in ["gitdir:~/repo/", "gitdir/i:~/REPO/", "onbranch:topic/**", "hasconfig:remote.*.url:https://example.com/**"] {
            XCTAssertNoThrow(try GitService.validateCondition(condition))
            _ = try await service.previewRule(draft: .init(condition: condition, path: "~/profile"))
        }
        for path in ["", "~/bad\npath", "~/bad\0path"] {
            await assertRefused { _ = try await self.service.previewRule(draft: .init(path: path)) }
        }
    }

    func testRulesRejectMalformedProfilesCyclesAndHasconfigRemoteURLs() async throws {
        let profile = home.appendingPathComponent("profile")
        try write("[broken\n", profile)
        await assertRefused { _ = try await self.service.previewRule(draft: .init(path: "~/profile")) }
        try write("[include]\n path = ~/profile\n", profile)
        await assertRefused { _ = try await self.service.previewRule(draft: .init(path: "~/profile")) }
        try write("[include]\n path = ~/.gitconfig\n", profile)
        await assertRefused { _ = try await self.service.previewRule(draft: .init(path: "~/profile")) }
        try write("[remote \"origin\"]\n url = https://example.com/repo.git\n", profile)
        _ = try await service.previewRule(draft: .init(condition: "gitdir:~/repos/", path: "~/profile"))
        await assertRefused { _ = try await self.service.previewRule(draft: .init(condition: "hasconfig:remote.*.url:https://example.com/**", path: "~/profile")) }
        let outer = home.appendingPathComponent("outer")
        try write("[include]\n path = profile\n", outer)
        await assertRefused { _ = try await self.service.previewRule(draft: .init(condition: "hasconfig:remote.*.url:https://example.com/**", path: "~/outer")) }
    }

    func testEffectiveIdentityUsesFolderConditionalBranchRemoteAndLocalOrigins() async throws {
        let repo = home.appendingPathComponent("repos/public")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        _ = try await service.runner.run(paths.git, ["init", "-b", "topic/demo", repo.path], environment: paths.environment).checked()
        let publicFile = home.appendingPathComponent("public")
        try write("[user]\n email = public@example.com\n", publicFile)
        try write("[user]\n name = Fixture\n email = default@example.com\n[includeIf \"gitdir:~/repos/\"]\n path = ~/public\n", paths.gitConfig)
        let rootBefore = try Data(contentsOf: paths.gitConfig)
        let identity = try await service.effectiveIdentity(in: repo)
        XCTAssertEqual(identity.values.first { $0.key == "user.email" }?.value, "public@example.com")
        XCTAssertEqual(identity.values.first { $0.key == "user.email" }?.scope, "global")
        XCTAssertTrue(identity.values.first { $0.key == "user.email" }?.origin.contains("/public") == true)
        let other = try await service.effectiveIdentity(in: home)
        XCTAssertEqual(other.values.first { $0.key == "user.email" }?.value, "default@example.com")
        _ = try await service.runner.run(paths.git, ["-C", repo.path, "config", "user.email", "local@example.com"], environment: paths.environment).checked()
        let local = try await service.effectiveIdentity(in: repo)
        XCTAssertEqual(local.values.first { $0.key == "user.email" }?.value, "local@example.com")
        XCTAssertEqual(local.values.first { $0.key == "user.email" }?.scope, "local")
        XCTAssertEqual(try Data(contentsOf: paths.gitConfig), rootBefore)
        // Git evaluates branch and remote-url rules; the app doesn't emulate matching.
        try write("[user]\n email = default@example.com\n[includeIf \"onbranch:topic/**\"]\n path = ~/public\n", paths.gitConfig)
        _ = try await service.runner.run(paths.git, ["-C", repo.path, "config", "--unset", "user.email"], environment: paths.environment).checked()
        let branch = try await service.effectiveIdentity(in: repo)
        XCTAssertEqual(branch.values.first { $0.key == "user.email" }?.value, "public@example.com")
        try write("[user]\n email = default@example.com\n[includeIf \"hasconfig:remote.*.url:https://example.com/**\"]\n path = ~/public\n", paths.gitConfig)
        _ = try await service.runner.run(paths.git, ["-C", repo.path, "config", "remote.origin.url", "https://example.com/repo.git"], environment: paths.environment).checked()
        let remote = try await service.effectiveIdentity(in: repo)
        XCTAssertEqual(remote.values.first { $0.key == "user.email" }?.value, "public@example.com")
        await assertRefused { _ = try await self.service.effectiveIdentity(in: self.home.appendingPathComponent("absent")) }
    }
}
