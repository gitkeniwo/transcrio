import CryptoKit
import Foundation

/// A source file's content fingerprint: the file size plus a SHA-256 over
/// the first and last `edgeBytes` of the file. A renamed or moved copy has the same
/// fingerprint; any re-encode or trim changes it.
///
/// Sizes: 4 MiB from each end. That is ~0.1 s of reading on an SSD and well under a second
/// on most external disks, while covering several minutes of compressed audio at both ends,
/// so two different recordings of the same length practically never collide. Files up to
/// 8 MiB are hashed whole.
public struct SourceFingerprint: Codable, Sendable, Hashable, CustomStringConvertible {
    public static let edgeBytes = 4 * 1024 * 1024

    public var size: Int64
    /// Lower-case hex SHA-256 of head + tail.
    public var hash: String

    public init(size: Int64, hash: String) {
        self.size = size
        self.hash = hash
    }

    /// `"<size>:<hash>"`, the form stored in library.json.
    public var description: String { "\(size):\(hash)" }

    public init?(_ string: String) {
        let parts = string.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let size = Int64(parts[0]) else { return nil }
        self.init(size: size, hash: String(parts[1]))
    }

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let fp = SourceFingerprint(s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad fingerprint \(s)"))
        }
        self = fp
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }

    /// Reads the file synchronously. Call it off the main thread (see `compute`).
    public static func read(_ url: URL, edge: Int = edgeBytes) throws -> SourceFingerprint {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = Int64(try handle.seekToEnd())
        var hasher = SHA256()
        try handle.seek(toOffset: 0)
        if size <= Int64(edge) * 2 {
            if let data = try handle.readToEnd() { hasher.update(data: data) }
        } else {
            if let head = try handle.read(upToCount: edge) { hasher.update(data: head) }
            try handle.seek(toOffset: UInt64(size - Int64(edge)))
            if let tail = try handle.read(upToCount: edge) { hasher.update(data: tail) }
        }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return SourceFingerprint(size: size, hash: hex)
    }

    /// Off the main thread; nil when the file can't be read.
    public static func compute(_ url: URL) async -> SourceFingerprint? {
        await Task.detached(priority: .userInitiated) { try? read(url) }.value
    }
}
