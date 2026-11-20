import Foundation

/// Turns a byte stream (pipe reads) into complete lines.
///
/// Bytes are buffered until a `\n` arrives, so a line split across reads, including a
/// multi-byte UTF-8 character cut in half, is only decoded once it is complete.
/// Blank lines are dropped and a trailing `\r` is stripped.
public struct NDJSONLineSplitter: Sendable {
    private var buffer = Data()

    public init() {}

    /// Feeds one read and returns the lines it completed.
    public mutating func append(_ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let line = Self.decode(lineData) { lines.append(line) }
        }
        return lines
    }

    /// Flushes a trailing line that never got its `\n` (end of stream).
    public mutating func finish() -> [String] {
        defer { buffer.removeAll() }
        return Self.decode(buffer).map { [$0] } ?? []
    }

    private static func decode(_ data: Data) -> String? {
        var bytes = data
        if bytes.last == 0x0D { bytes.removeLast() }
        let line = String(decoding: bytes, as: UTF8.self)
        return line.allSatisfy(\.isWhitespace) ? nil : line
    }
}
