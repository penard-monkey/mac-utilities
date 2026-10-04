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
    func testExportsAndImportsPreserveBytesWithoutOverwriting() throws {
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
