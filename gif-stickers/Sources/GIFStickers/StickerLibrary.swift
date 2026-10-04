import Foundation
import ImageIO

/// Shared validation for library imports and sends. Never re-encode the sticker.
enum StickerValidation {
    static func check(_ data: Data) throws -> WebPMetadata {
        guard data.count >= 20, data.count <= 500_000 else {
            throw StickerError(message: "Choose a WebP sticker under 500 KB.")
        }
        let bytes = [UInt8](data)
        let length = (0..<4).reduce(0) { $0 | Int(bytes[4+$1]) << (8*$1) }
        guard length + 8 == data.count else {
            throw StickerError(message: "This WebP is incomplete or has extra data.")
        }
        let metadata = try WebPMetadata(data: data)
        guard metadata.width == 512, metadata.height == 512 else {
            throw StickerError(message: "Library stickers must be exactly 512 × 512 pixels.")
        }
        if metadata.delays.isEmpty {
            guard data.count <= 100_000 else {
                throw StickerError(message: "Static stickers must be under 100 KB.")
            }
        } else {
            guard metadata.delays.allSatisfy({ $0 >= 8 }), metadata.delays.reduce(0, +) <= 10_000 else {
                throw StickerError(message: "Animated stickers must last at most 10 seconds, with frames of at least 8 ms.")
            }
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
            throw StickerError(message: "This WebP cannot be decoded. Choose another sticker.")
        }
        return metadata
    }
}

struct LibrarySticker: Identifiable {
    let url: URL
    let modified: Date
    let byteCount: Int
    let frameCount: Int
    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

struct LibraryContents {
    let folder: URL
    let stickers: [LibrarySticker]
    let skipped: Int
}

/// Files, not a database: other tools may add valid WebPs to the chosen folder.
struct StickerLibrary {
    let settingsURL: URL
    let defaultFolder: URL
    private let trash: (URL) throws -> Void

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         trash: @escaping (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        let home = home.resolvingSymlinksInPath()
        settingsURL = home.appendingPathComponent(".config/mac-utilities/gif-stickers.json")
        defaultFolder = home.appendingPathComponent("Pictures/GIF Stickers", isDirectory: true)
        self.trash = trash
    }
    private func settings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any] else {
            throw StickerError(message: "GIF Stickers settings must be a JSON object.")
        }
        return object
    }
    func folder() throws -> URL {
        let values = try settings()
        guard let path = values["library_folder"] as? String else { return defaultFolder }
        guard path.hasPrefix("/") else {
            throw StickerError(message: "The library folder in settings must be an absolute path. Choose a folder in Library.")
        }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
    }
    func chooseFolder(_ url: URL) throws {
        let destination = url.standardizedFileURL
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var values = try settings()
        values["library_folder"] = destination.path
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
            .write(to: settingsURL, options: .atomic)
    }
    @discardableResult func save(_ data: Data, name: String) throws -> URL {
        _ = try StickerValidation.check(data)
        let directory = try folder()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let basename = (name as NSString).lastPathComponent
        let stem = Self.safeStem((basename as NSString).deletingPathExtension)
        var suffix = 1
        while true {
            let tail = suffix == 1 ? "" : " \(suffix)"
            let candidate = Self.truncated(stem, characters: 200 - tail.count, bytes: 250 - tail.utf8.count) + tail + ".webp"
            let url = directory.appendingPathComponent(candidate)
            if try !containsName(candidate, in: directory) {
                do {
                    // Exclusive creation also protects against a file appearing after the listing.
                    try data.write(to: url, options: .withoutOverwriting)
                    return url.resolvingSymlinksInPath()
                } catch {
                    guard FileManager.default.fileExists(atPath: url.path) else { throw error }
                }
            }
            suffix += 1
        }
    }
    private static func truncated(_ value: String, characters: Int, bytes: Int) -> String {
        var result = ""
        for character in value.prefix(characters) {
            guard result.utf8.count + String(character).utf8.count <= bytes else { break }
            result.append(character)
        }
        return result
    }
    private static func safeStem(_ name: String) -> String {
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        let cleaned = String(name.unicodeScalars.map { forbidden.contains($0) ? "_" : String($0) }.joined())
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = String(cleaned.drop(while: { $0 == "." })).trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = truncated(visible, characters: 200, bytes: 250)
        return stem.isEmpty ? "sticker" : stem
    }
    private func containsName(_ name: String, in directory: URL, excluding: URL? = nil) throws -> Bool {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).contains {
            $0.standardizedFileURL != excluding?.standardizedFileURL &&
                $0.lastPathComponent.compare(name, options: [.caseInsensitive]) == .orderedSame
        }
    }
    @discardableResult func rename(_ sticker: LibrarySticker, to name: String) throws -> URL {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StickerError(message: "Enter a sticker name.")
        }
        guard !name.contains("/"), !name.contains("\\"), !name.contains(":") else {
            throw StickerError(message: "Sticker names cannot contain path separators (/, \\, or :).")
        }
        guard !name.hasPrefix(".") else {
            throw StickerError(message: "Sticker names cannot start with a dot.")
        }
        guard name.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw StickerError(message: "Sticker names cannot contain control characters.")
        }
        guard name.count <= 200 else {
            throw StickerError(message: "Sticker names must be at most 200 characters.")
        }
        guard name.utf8.count <= 250 else {
            throw StickerError(message: "This name is too long for a filename. Use a shorter name.")
        }
        let directory = try folder().standardizedFileURL
        guard sticker.url.standardizedFileURL.deletingLastPathComponent() == directory,
              sticker.url.pathExtension.lowercased() == "webp" else {
            throw StickerError(message: "That sticker is outside the current library. Refresh the library first.")
        }
        _ = try read(sticker.url) // Reject symlinks and invalid files before moving anything.
        let destination = directory.appendingPathComponent(name + ".webp")
        guard try !containsName(destination.lastPathComponent, in: directory, excluding: sticker.url) else {
            throw StickerError(message: "A sticker named '\(name)' already exists. Choose another name.")
        }
        if destination.standardizedFileURL != sticker.url.standardizedFileURL {
            // FileManager refuses to replace an existing destination.
            try FileManager.default.moveItem(at: sticker.url, to: destination)
        }
        return destination
    }
    @discardableResult func importFile(_ url: URL) throws -> URL {
        let data = try read(url)
        return try save(data, name: url.lastPathComponent)
    }
    func read(_ url: URL) throws -> Data {
        let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
        guard properties.isRegularFile == true, properties.isSymbolicLink != true,
              let size = properties.fileSize, size <= 500_000 else {
            throw StickerError(message: "Choose a regular WebP file under 500 KB.")
        }
        let data = try Data(contentsOf: url)
        _ = try StickerValidation.check(data)
        return data
    }
    func contents() throws -> LibraryContents {
        let directory = try folder()
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return LibraryContents(folder: directory, stickers: [], skipped: 0)
        }
        let urls = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
        var stickers: [LibrarySticker] = [], skipped = 0
        for url in urls where url.pathExtension.lowercased() == "webp" {
            do {
                let data = try read(url)
                let metadata = try WebPMetadata(data: data)
                let date = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
                stickers.append(LibrarySticker(url: url.standardizedFileURL, modified: date, byteCount: data.count,
                    frameCount: max(1, metadata.delays.count)))
            } catch { skipped += 1 }
        }
        return LibraryContents(folder: directory, stickers: stickers.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.url.lastPathComponent < $1.url.lastPathComponent : order == .orderedAscending
        }, skipped: skipped)
    }
    func moveToTrash(_ sticker: LibrarySticker) throws {
        guard sticker.url.standardizedFileURL.deletingLastPathComponent() == (try folder()).standardizedFileURL,
              sticker.url.pathExtension.lowercased() == "webp" else {
            throw StickerError(message: "That sticker is outside the current library. Refresh the library first.")
        }
        try trash(sticker.url)
    }
}
