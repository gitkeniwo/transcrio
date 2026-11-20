import AppKit
import Foundation
import Testing
@testable import TranscribeKit

@Suite struct AppIconCatalogTests {
    static let iconsDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("icons")

    @Test func idsMatchTheIconsFolder() throws {
        let ids = AppIconCatalog.all.map(\.id)
        #expect(ids.first == AppIconCatalog.defaultID)
        #expect(Set(ids).count == ids.count)
        let svgs = try FileManager.default.contentsOfDirectory(atPath: Self.iconsDir.path)
            .filter { $0.hasSuffix(".svg") }.map { String($0.dropLast(4)) }
        #expect(Set(ids) == Set(svgs))
    }

    @Test func idsMatchTheReadmeTable() throws {
        let readme = try String(contentsOf: Self.iconsDir.appendingPathComponent("README.md"), encoding: .utf8)
        // Rows look like: | `a3b-lcd-clay.svg` | design | role |
        let rows = readme.split(separator: "\n").filter { $0.hasPrefix("| `") }
        let ids = rows.compactMap { $0.split(separator: "`").dropFirst().first.map { String($0.dropLast(4)) } }
        #expect(ids == AppIconCatalog.all.map(\.id))
        #expect(rows.first?.contains("Default") == true)
    }

    @Test func everyIconIsAResourceAndRenders() throws {
        for entry in AppIconCatalog.all {
            let url = try #require(AppIconCatalog.url(for: entry.id), "\(entry.id) missing from the resource bundle")
            let image = try #require(NSImage(contentsOf: url))
            #expect(image.size == NSSize(width: 1024, height: 1024))
        }
        #expect(AppIconCatalog.url(for: "nope") == nil)
    }

    @Test func storedValueResolution() {
        #expect(AppIconCatalog.resolve(nil) == nil)
        #expect(AppIconCatalog.resolve("") == nil)
        #expect(AppIconCatalog.resolve("default") == nil)
        #expect(AppIconCatalog.resolve("h5")?.id == "h5")
        #expect(AppIconCatalog.resolve("a3b-lcd-clay")?.name == "LCD Clay")
        // Unknown ids (renamed, or from a newer build) fall back to Default.
        #expect(AppIconCatalog.resolve("h6") == nil)
        #expect(AppIconCatalog.resolve("H5") == nil)
    }
}
