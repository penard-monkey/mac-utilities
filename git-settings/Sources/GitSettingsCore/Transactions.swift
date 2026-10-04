import Foundation
import Darwin

public struct FileState: Codable, Equatable, Sendable {
    public let contents: Data?
    public static func read(_ url: URL) throws -> FileState {
        // Explicitly refuse symlinks: replacing one could detach managed/dotfiles configs.
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        if values?.isSymbolicLink == true { throw AppError.message("\(url.path) is a symlink. Edit it with your dotfiles manager instead.") }
        if FileManager.default.fileExists(atPath: url.path) {
            guard values?.isRegularFile == true else { throw AppError.message("Expected a regular file: \(url.path)") }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard (attributes[.size] as? NSNumber)?.intValue ?? 0 < 2_000_000 else { throw AppError.message("Config is too large to edit safely in this app.") }
            return FileState(contents: try Data(contentsOf: url))
        }
        return FileState(contents: nil)
    }
    public var text: String { String(decoding: contents ?? Data(), as: UTF8.self) }
}

public struct ChangePreview: Identifiable, Sendable {
    public let id = UUID()
    public let target: URL
    public let before: FileState
    public let after: FileState
    public let summary: String
    public var authorization: GitAuthorization? = nil
    public var diff: String {
        let old = before.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let new = after.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let delta = new.difference(from: old)
        var lines = ["--- \(target.path)", "+++ proposed", ""]
        for change in delta {
            switch change {
            case .remove(let offset, let element, _): lines.append("- [line \(offset + 1)] \(element)")
            case .insert(let offset, let element, _): lines.append("+ [line \(offset + 1)] \(element)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

public struct BackupRecord: Codable, Identifiable, Sendable {
    public let id: String
    public let date: Date
    public let path: String
    public let before: FileState
    public let after: FileState
    public let summary: String
    public var authorization: GitAuthorization? = nil
}

public struct TransactionStore: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    private func locked<T>(_ target: URL, action: () throws -> T) throws -> T {
        let fm = FileManager.default
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = target.path + ".lock"
        let descriptor = open(lock, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard descriptor >= 0 else { throw AppError.message("Config is locked by another writer (\(lock)). Try again after it finishes.") }
        defer { close(descriptor); unlink(lock) }
        return try action()
    }

    private func authorized<T>(_ authorization: GitAuthorization?, target: URL, action: () throws -> T) throws -> T {
        guard let authorization else { return try action() }
        try authorization.validate(target)
        // Hold both Git locks while publishing a profile, so rule changes and
        // profile writes cannot race through the app or another Git writer.
        return try locked(authorization.root) {
            try authorization.validate(target)
            return try action()
        }
    }

    public func apply(_ preview: ChangePreview) throws -> BackupRecord {
        try authorized(preview.authorization, target: preview.target) {
            try locked(preview.target) {
                try preview.authorization?.validate(preview.target)
                guard try FileState.read(preview.target) == preview.before else { throw AppError.message("The file changed since this preview. Refresh and preview again.") }
                guard preview.before != preview.after else { throw AppError.message("There are no changes to apply.") }
                let fm = FileManager.default
                try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let record = BackupRecord(id: "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString)", date: Date(), path: preview.target.path, before: preview.before, after: preview.after, summary: preview.summary, authorization: preview.authorization)
                let location = directory.appendingPathComponent(record.id + ".json")
                try JSONEncoder().encode(record).write(to: location, options: .atomic)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: location.path)
                try write(preview.after, to: preview.target)
                return record
            }
        }
    }

    public func restore(_ record: BackupRecord) throws {
        let target = URL(fileURLWithPath: record.path)
        try authorized(record.authorization, target: target) {
            try locked(target) {
                try record.authorization?.validate(target)
                guard try FileState.read(target) == record.after else { throw AppError.message("Restore refused: the file has later edits. Use the backup for manual recovery so those edits are preserved.") }
                try write(record.before, to: target)
            }
        }
    }

    public func records() throws -> [BackupRecord] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(BackupRecord.self, from: Data(contentsOf: $0)) }
            .sorted { $0.date > $1.date }
    }

    private func write(_ state: FileState, to target: URL) throws {
        let fm = FileManager.default
        if let data = state.contents {
            let mode = (try? fm.attributesOfItem(atPath: target.path)[.posixPermissions]) ?? 0o600
            try data.write(to: target, options: .atomic)
            try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: target.path)
        } else if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
    }
}
