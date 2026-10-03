import Foundation

/// Written only when the user changes something; an absent file means defaults.
public struct Settings: Codable, Equatable {
    public var historyEnabled: Bool
    public var historyLimit: Int
    public var offerRedirectResolution: Bool

    public static let defaults = Settings(historyEnabled: true, historyLimit: 100,
                                          offerRedirectResolution: true)

    public static func defaultURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".config/mac-utilities/qr-reader.json")
    }

    public static func load(from url: URL) -> Settings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(Settings.self, from: data)
        else { return .defaults }
        return settings
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
