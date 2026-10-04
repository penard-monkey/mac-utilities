import XCTest
@testable import GIFStickers

final class StickerLibraryTests: XCTestCase {
    @MainActor func testBatchImportKeepsValidFileAndReportsInvalidFile() async throws {
        let home = try StickerFixtures.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let good = home.appendingPathComponent("good.webp"), bad = home.appendingPathComponent("bad.webp")
        try StickerFixtures.animated.get().write(to: good)
        try Data("invalid WebP".utf8).write(to: bad)
        let model = LibraryModel(store: StickerLibrary(home: home))
        model.importFiles([good, bad])
        let deadline = Date().addingTimeInterval(3)
        while model.stickers.isEmpty && Date() < deadline { await Task.yield() }
        XCTAssertEqual(model.stickers.count, 1)
        XCTAssertEqual(model.message, "Imported 1 sticker(s).")
        XCTAssertTrue(model.error?.contains("1 file(s) could not be imported") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: good.path))
    }
    func testAddsAndImportsPreserveBytesWithoutOverwriting() throws {
        let home = try StickerFixtures.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let library = StickerLibrary(home: home)
        let data = try StickerFixtures.animated.get()
        XCTAssertEqual(try library.folder(), home.appendingPathComponent("Pictures/GIF Stickers", isDirectory: true))
        XCTAssertTrue(try library.contents().stickers.isEmpty)
        let first = try library.save(data, name: "example.webp")
        let second = try library.save(data, name: "example.webp")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: first), data)
        let source = home.appendingPathComponent("import.webp")
        try data.write(to: source)
        let imported = try library.importFile(source)
        XCTAssertNotEqual(imported, source)
        XCTAssertEqual(try Data(contentsOf: imported), data)
        XCTAssertEqual(try Data(contentsOf: source), data, "Import must keep the original")
        XCTAssertEqual(try library.contents().stickers.count, 3)
    }
    func testDefaultNamesAreSafeAndUseCaseInsensitiveNumberedCollisions() throws {
        let home = try StickerFixtures.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let library = StickerLibrary(home: home), data = try StickerFixtures.still.get()
        XCTAssertEqual(try library.save(data, name: "Example.gif").lastPathComponent, "Example.webp")
        XCTAssertEqual(try library.save(data, name: "example.mov").lastPathComponent, "example 2.webp")
        XCTAssertEqual(try library.save(data, name: "example.mp4").lastPathComponent, "example 3.webp")
        XCTAssertEqual(try library.save(data, name: ".hidden\\bad:line\n.gif").lastPathComponent, "hidden_bad_line_.webp")
        XCTAssertEqual(try library.save(data, name: ".gif").lastPathComponent, "gif.webp")
        XCTAssertEqual(try library.save(data, name: "").lastPathComponent, "sticker.webp")
        let longName = String(repeating: "a", count: 250) + ".gif"
        let first = try library.save(data, name: longName), second = try library.save(data, name: longName)
        XCTAssertEqual(first.deletingPathExtension().lastPathComponent.count, 200)
        XCTAssertEqual(second.deletingPathExtension().lastPathComponent.count, 200)
        XCTAssertTrue(second.lastPathComponent.hasSuffix(" 2.webp"))
        let unicode = try library.save(data, name: String(repeating: "🐱", count: 200) + ".gif")
        XCTAssertLessThanOrEqual(unicode.lastPathComponent.utf8.count, 255)
        XCTAssertEqual(try Data(contentsOf: first), data)
    }
    func testRenamePreservesBytesExtensionAndSortsByName() throws {
        let home = try StickerFixtures.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let library = StickerLibrary(home: home), data = try StickerFixtures.animated.get()
        let original = try library.save(data, name: "Zebra.gif")
        _ = try library.save(data, name: "Middle.gif")
        let sticker = try XCTUnwrap(library.contents().stickers.first { $0.url == original })
        let renamed = try library.rename(sticker, to: "Alpha")
        XCTAssertEqual(renamed.lastPathComponent, "Alpha.webp")
        XCTAssertEqual(renamed.deletingLastPathComponent(), try library.folder().standardizedFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertEqual(try Data(contentsOf: renamed), data)
        XCTAssertEqual(try library.contents().stickers.map(\.name), ["Alpha", "Middle"])
        let current = try XCTUnwrap(library.contents().stickers.first)
        XCTAssertEqual(try library.rename(current, to: "Alpha"), renamed)
        let upper = try library.rename(current, to: "ALPHA")
        XCTAssertEqual(upper.lastPathComponent, "ALPHA.webp")
        let upperSticker = try XCTUnwrap(library.contents().stickers.first { $0.url == upper })
        let uuidName = "named-12345678-1234-1234-1234-123456789012"
        _ = try library.rename(upperSticker, to: uuidName)
        XCTAssertTrue(try library.contents().stickers.contains { $0.name == uuidName })
    }
    func testRenameRejectsEveryInvalidNameAndNeverChangesFiles() throws {
        let home = try StickerFixtures.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let library = StickerLibrary(home: home), data = try StickerFixtures.still.get()
        let original = try library.save(data, name: "original.gif")
        let sticker = try XCTUnwrap(library.contents().stickers.first)
        let invalid = ["", "   ", "../escaped", "sub/name", "sub\\name", "sub:name", ".hidden", ".", "..",
                       "line\nname", "tab\tname", "null\0name", "delete\u{7f}name", String(repeating: "a", count: 201),
                       String(repeating: "🐱", count: 200)]
        for name in invalid {
            XCTAssertThrowsError(try library.rename(sticker, to: name), name) { error in
                XCTAssertFalse(error.localizedDescription.isEmpty)
            }
            XCTAssertEqual(try Data(contentsOf: original), data)
            XCTAssertEqual(try library.contents().stickers.count, 1)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("Pictures/escaped.webp").path))
        XCTAssertEqual(try library.rename(sticker, to: String(repeating: "a", count: 200)).deletingPathExtension().lastPathComponent.count, 200)
    }
    func testRenameRefusesCaseInsensitiveCollisionIncludingNonStickerFiles() throws {
        let home = try StickerFixtures.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let library = StickerLibrary(home: home), data = try StickerFixtures.still.get()
        let original = try library.save(data, name: "original.gif")
        let sticker = try XCTUnwrap(library.contents().stickers.first)
        let existing = try library.save(StickerFixtures.animated.get(), name: "Taken.gif")
        let existingBytes = try Data(contentsOf: existing)
        for name in ["Taken", "taken", "TAKEN"] {
            XCTAssertThrowsError(try library.rename(sticker, to: name)) { error in
                XCTAssertTrue(error.localizedDescription.contains("already exists"))
            }
        }
        let invalid = (try library.folder()).appendingPathComponent("invalid.WEBP")
        try Data("invalid".utf8).write(to: invalid)
        XCTAssertThrowsError(try library.rename(sticker, to: "INVALID"))
        XCTAssertEqual(try Data(contentsOf: original), data)
        XCTAssertEqual(try Data(contentsOf: existing), existingBytes)
    }
    func testRenameRejectsOutsideStaleAndSymbolicLinkSources() throws {
        let home = try StickerFixtures.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let library = StickerLibrary(home: home), data = try StickerFixtures.still.get()
        let original = try library.save(data, name: "original.gif")
        let sticker = try XCTUnwrap(library.contents().stickers.first)
        let outside = home.appendingPathComponent("outside.webp")
        try data.write(to: outside)
        let outsideSticker = LibrarySticker(url: outside, modified: Date(), byteCount: data.count, frameCount: 1)
        XCTAssertThrowsError(try library.rename(outsideSticker, to: "escaped"))
        let linked = original.deletingLastPathComponent().appendingPathComponent("link.webp")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)
        XCTAssertThrowsError(try library.rename(LibrarySticker(url: linked, modified: Date(), byteCount: 0, frameCount: 1), to: "renamed"))
        try library.chooseFolder(home.appendingPathComponent("new-library"))
        XCTAssertThrowsError(try library.rename(sticker, to: "stale"))
        XCTAssertEqual(try Data(contentsOf: outside), data)
        XCTAssertEqual(try Data(contentsOf: original), data)
        XCTAssertTrue(try library.contents().stickers.isEmpty)
    }
    @MainActor func testEditorAddsCurrentPreviewDirectlyAndSelectsIt() async throws {
        let home = try StickerFixtures.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let library = LibraryModel(store: StickerLibrary(home: home))
        let editor = EditorModel(library: library)
        editor.save()
        XCTAssertTrue(try library.store.contents().stickers.isEmpty)
        editor.asset = try AnimationAsset(url: EngineTests().fixture(home, frames: 2))
        let data = try StickerFixtures.animated.get()
        editor.result = ExportResult(data: data, duration: 0.2, fps: 20, quality: 90, frameCount: 2, trimmed: false)
        editor.busy = true
        editor.save()
        XCTAssertTrue(try library.store.contents().stickers.isEmpty)
        editor.busy = false
        editor.save() // Returns without showing any panel; only the temporary library is written.
        let url = try XCTUnwrap(library.selectedURL)
        XCTAssertEqual(url.lastPathComponent, "sample.webp")
        XCTAssertEqual(try Data(contentsOf: url), data)
        XCTAssertEqual(editor.message, "Added 'sample' to the library")
        XCTAssertEqual(library.message, editor.message)
        let deadline = Date().addingTimeInterval(3)
        while library.loading && Date() < deadline { await Task.yield() }
        XCTAssertEqual(library.stickers.map(\.url), [url])
        editor.save()
        XCTAssertEqual(library.selectedURL?.lastPathComponent, "sample 2.webp")
        while library.loading && Date() < deadline { await Task.yield() }
    }
    func testFolderSettingPersistsPreservesOtherKeysAndLeavesOldFiles() throws {
        let home = try StickerFixtures.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let library = StickerLibrary(home: home)
        let oldFile = try library.save(StickerFixtures.still.get(), name: "first.webp")
        try FileManager.default.createDirectory(at: library.settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"other_option":true}"#.utf8).write(to: library.settingsURL)
        let folder = home.appendingPathComponent("other-library", isDirectory: true)
        try library.chooseFolder(folder)
        let reopened = StickerLibrary(home: home)
        XCTAssertEqual(try reopened.folder(), folder)
        XCTAssertTrue(try reopened.contents().stickers.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldFile.path))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: library.settingsURL)) as? [String: Any])
        XCTAssertEqual(json["other_option"] as? Bool, true)
        let newFile = try reopened.save(StickerFixtures.animated.get(), name: "second.webp")
        XCTAssertEqual(newFile.deletingLastPathComponent(), folder)
    }
    func testTrashMovesOnlySelectedLibraryFileAndRejectsOutsideFiles() throws {
        let home = try StickerFixtures.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let trash = home.appendingPathComponent("fake-trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let library = StickerLibrary(home: home, trash: {
            try FileManager.default.moveItem(at: $0, to: trash.appendingPathComponent($0.lastPathComponent))
        })
        let first = try library.save(StickerFixtures.animated.get(), name: "one.webp")
        let second = try library.save(StickerFixtures.still.get(), name: "two.webp")
        let contents = try library.contents()
        let selected = try XCTUnwrap(contents.stickers.first(where: { $0.url.standardizedFileURL == first.standardizedFileURL }),
            "Saved: \(first); listed: \(contents.stickers.map { $0.url })")
        try library.moveToTrash(selected)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.appendingPathComponent(first.lastPathComponent).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        XCTAssertEqual(try library.contents().stickers.count, 1)
        let outside = LibrarySticker(url: home.appendingPathComponent("outside.webp"), modified: Date(), byteCount: 0, frameCount: 1)
        XCTAssertThrowsError(try library.moveToTrash(outside))
    }
    func testInvalidImportsAreRejectedAndInvalidOrLinkedLibraryFilesSkipped() throws {
        let home = try StickerFixtures.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let library = StickerLibrary(home: home)
        let valid = try library.save(StickerFixtures.animated.get(), name: "valid.webp")
        let invalid = valid.deletingLastPathComponent().appendingPathComponent("invalid.webp")
        try Data("not WebP".utf8).write(to: invalid)
        XCTAssertThrowsError(try library.importFile(invalid))
        let linked = valid.deletingLastPathComponent().appendingPathComponent("linked.webp")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: valid)
        XCTAssertThrowsError(try library.importFile(linked))
        let contents = try library.contents()
        XCTAssertEqual(contents.stickers.count, 1)
        XCTAssertEqual(contents.skipped, 2)
    }
    func testValidationChecksDimensionsTimingContainerAndTwoSizeCaps() throws {
        let valid = try StickerFixtures.animated.get()
        XCTAssertNoThrow(try StickerValidation.check(valid))
        XCTAssertNoThrow(try StickerValidation.check(StickerFixtures.still.get()))
        var wrongSize = valid
        let vp8x = try XCTUnwrap(wrongSize.range(of: Data("VP8X".utf8))).lowerBound
        wrongSize[vp8x + 12] = 0
        XCTAssertThrowsError(try StickerValidation.check(wrongSize))
        var timing = valid
        let frame = try XCTUnwrap(timing.range(of: Data("ANMF".utf8))).lowerBound
        timing[frame + 20] = 1; timing[frame + 21] = 0; timing[frame + 22] = 0
        XCTAssertThrowsError(try StickerValidation.check(timing))
        timing[frame + 20] = 0x11; timing[frame + 21] = 0x27
        XCTAssertThrowsError(try StickerValidation.check(timing))
        XCTAssertThrowsError(try StickerValidation.check(valid.dropLast()))
        XCTAssertThrowsError(try StickerValidation.check(valid + Data([0])))
        XCTAssertThrowsError(try StickerValidation.check(Data(repeating: 0, count: 500_001)))
        var largeStill = try StickerFixtures.still.get()
        let padding = 100_002 - largeStill.count - 8
        largeStill.append(Data("JUNK".utf8))
        largeStill.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: padding >> (8*$0)) })
        largeStill.append(Data(repeating: 0, count: padding))
        for index in 0..<4 { largeStill[4+index] = UInt8(truncatingIfNeeded: (largeStill.count-8) >> (8*index)) }
        XCTAssertThrowsError(try StickerValidation.check(largeStill))
    }
    func testMalformedSettingsAreNotSilentlyOverwritten() throws {
        let home = try StickerFixtures.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let library = StickerLibrary(home: home)
        try FileManager.default.createDirectory(at: library.settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bad = Data("broken JSON".utf8)
        try bad.write(to: library.settingsURL)
        XCTAssertThrowsError(try library.chooseFolder(home.appendingPathComponent("chosen")))
        XCTAssertEqual(try Data(contentsOf: library.settingsURL), bad)
    }
}
