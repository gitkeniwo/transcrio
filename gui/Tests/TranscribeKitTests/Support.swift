import Foundation
@testable import TranscribeKit

enum Fixtures {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    static let fakeCLI = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts/fake-transcribe.sh")

    static let fakeServe = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts/fake-serve.py")

    /// Lines of a recorded `serve` session: `dir` is "in" (op) or "out" (event), `line` the raw JSON.
    static func serveSession(_ name: String) throws -> [(dir: String, line: String)] {
        let text = try String(contentsOf: directory.appendingPathComponent("\(name)/session.ndjson"), encoding: .utf8)
        return try text.split(separator: "\n").map { raw in
            let obj = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as! [String: Any]
            let msg = try JSONSerialization.data(withJSONObject: obj["msg"]!)
            return (obj["dir"] as! String, String(decoding: msg, as: UTF8.self))
        }
    }

    /// The events a recorded `serve` session produced, decoded.
    static func serveEvents(_ name: String) throws -> [ServeEvent] {
        try serveSession(name).filter { $0.dir == "out" }.compactMap { ServeEvent.decode($0.line) }
    }

    static func lines(_ name: String) throws -> [String] {
        let text = try String(contentsOf: directory.appendingPathComponent("\(name)/stderr.ndjson"), encoding: .utf8)
        return text.split(separator: "\n").map(String.init)
    }

    static func events(_ name: String) throws -> [CLIEvent] {
        try lines(name).compactMap(CLIEvent.decode)
    }

    static func data(_ path: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(path))
    }

    /// Fixture inputs in order of appearance.
    static func inputs(_ name: String) throws -> [String] {
        var seen: [String] = []
        for e in try events(name) { if let f = e.file, !seen.contains(f) { seen.append(f) } }
        return seen
    }
}

/// A scratch directory removed on deinit.
final class TempDir {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("transcribekit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    func file(_ name: String, contents: String = "") throws -> URL {
        let u = url.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: u, atomically: true, encoding: .utf8)
        return u
    }
}

/// In-memory file system for `CLILocator`.
struct FakeProbe: FileProbe {
    var executables: Set<String> = []
    var files: Set<String> = []
    func isExecutableFile(atPath path: String) -> Bool { executables.contains(path) }
    func fileExists(atPath path: String) -> Bool { files.contains(path) || executables.contains(path) }
}

struct NothingToStart: Error {}

extension QueueModel {
    /// `startNext()` for tests: throws when nothing starts.
    mutating func next() throws -> (id: FileItem.ID, job: ServeJob) {
        guard let n = startNext() else { throw NothingToStart() }
        return n
    }
}
